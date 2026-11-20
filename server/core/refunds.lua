-- Durable compensation receipts. A crash during a debit/credit is quarantined for review;
-- only compensation that was never attempted may be retried. No SQL migration is needed.
WCRefunds = {}
local R = WCRefunds
local serial = 0
local PREFIX = 'w_creators:refund:'

local function character(src)
    local active = WCSessions and WCSessions.activeCharacter(src)
    return active and tostring(active.charid) or nil
end

local function capture(src)
    local charid = character(src)
    if not charid then return nil end
    local ok, owner = pcall(Bridge.GetLicense, src)
    if not ok or type(owner) ~= 'string' or owner == '' then return nil end
    local binding = { charid = charid, owner = owner }
    local okB, backend = pcall(function() return exports.w_lib:FwBackend() end)
    if okB and backend == 'wcore' then
        local loaded, _, id = pcall(function() return exports.w_lib:FwGetCharacterGeneration(src) end)
        if not loaded or type(id) ~= 'number' or id ~= id or id < 1 or id % 1 ~= 0 or id == math.huge then return nil end
        binding.generationId = id
    end
    return binding
end

local function storageKey(row)
    return PREFIX .. row.charid .. (row.generationId and (':core:' .. row.generationId) or (':owner:' .. row.owner))
end

local function read(binding)
    local ok, raw = pcall(GetResourceKvpString, storageKey(binding))
    if not ok then return nil, false end
    if not raw or raw == '' then return nil, true end
    local parsed, row = pcall(json.decode, raw)
    if not parsed or type(row) ~= 'table' or row.charid ~= binding.charid or (binding.owner ~= '' and row.owner ~= binding.owner) or row.generationId ~= binding.generationId or type(row.id) ~= 'string'
        or type(row.state) ~= 'string' or not WCEconomy.amount(row.amount)
        or not WCEconomy.currencyId(row.currency) then return nil, false end
    return row, true
end

local function store(row, state)
    local copy = {}
    for k, v in pairs(row) do copy[k] = v end
    copy.state, copy.updated = state, os.time()
    local ok, encoded = pcall(json.encode, copy)
    if not ok then return nil end
    local saved = pcall(SetResourceKvp, storageKey(row), encoded)
    local loaded, raw = pcall(GetResourceKvpString, storageKey(row))
    if not saved or not loaded or raw ~= encoded then
        WCDebug.warn('economy', 'refund receipt write failed for %s', row.id)
        return nil
    end
    return copy
end

local function settled(row)
    return row.state == 'delivered' or row.state == 'refunded' or row.state == 'cancelled'
end

function R.prepare(src, amount, currency, reason)
    local binding = capture(src)
    if not binding then return nil, WCResult.fail('ECONOMY_NOT_READY') end
    local prior, readable = read(binding)
    if not readable then return nil, WCResult.fail('REFUND_REVIEW') end
    if prior and not settled(prior) then
        return nil, WCResult.fail(prior.state == 'pending' and 'REFUND_PENDING' or 'REFUND_REVIEW', { refundId = prior.id })
    end
    serial = serial + 1
    local row = { id = ('R%d-%d-%d'):format(os.time(), GetGameTimer(), serial), charid = binding.charid, owner = binding.owner, generationId = binding.generationId,
        amount = amount, currency = currency or 'cash', reason = tostring(reason or ''):sub(1, 80) }
    row = store(row, 'prepared')
    if not row then return nil, WCResult.fail('ECONOMY_NOT_READY') end
    return row
end

R.update = store

function R.guard(src, row, fn)
    local live = capture(src)
    if not live or live.charid ~= row.charid or live.owner ~= row.owner or live.generationId ~= row.generationId then
        return false, 'generation_changed'
    end
    if row.generationId then
        local ok, result, reason = pcall(function()
            return exports.w_lib:FwWithCitizenGeneration(row.charid, row.generationId, function()
                -- The generation lookup may yield; a connection can select another character meanwhile.
                local current = capture(src)
                if not current or current.charid ~= row.charid or current.owner ~= row.owner
                    or current.generationId ~= row.generationId then return false, 'generation_changed' end
                return fn()
            end)
        end)
        if not ok then return false, 'generation_unavailable' end
        return result, reason
    end
    return fn()
end

function R.refund(src, row, held)
    if character(src) ~= row.charid then return false, store(row, row.generationId and 'pending' or 'review') or row end
    local live = capture(src)
    if not live or live.owner ~= row.owner or live.generationId ~= row.generationId then
        return false, store(row, 'review') or row
    end
    local function attempt()
        -- This transition is durable before money moves. An interrupted credit is never retried.
        local moving = store(row, 'refunding')
        if not moving then return { refunded = false, row = row } end
        local refunded, outcome = WCEconomy.refundOutcome(src, row.amount, row.reason, row.currency)
        if refunded then return { refunded = true, row = store(moving, 'refunded') or moving } end
        -- Other frameworks have no generation lease: failed compensation stays for review.
        local state = row.generationId and outcome == 'offline' and 'pending' or 'review'
        return { refunded = false, row = store(moving, state) or moving }
    end
    local result, reason
    if held then result = attempt() else result, reason = R.guard(src, row, attempt) end
    if type(result) == 'table' then return result.refunded, result.row end
    return false, store(row, reason == 'generation_busy' and 'pending' or 'review') or row
end

function R.retry(src)
    local binding = capture(src)
    if not binding or not binding.generationId then return false end
    local row, readable = read(binding)
    if not readable or not row or row.state ~= 'pending' then return false end
    return R.refund(src, row)
end

-- A server-local character event and a bounded online sweep recover confirmed failures.
AddEventHandler('w_creators:server:characterActivated', function(src) R.retry(src) end)
CreateThread(function()
    while true do
        Wait(60000)
        for _, id in ipairs(GetPlayers()) do R.retry(tonumber(id)) end
    end
end)

-- Operator inspection only: never credits money or changes a receipt.
RegisterCommand('creatorrefund', function(src, args)
    if src ~= 0 then return end
    local charid = type(args[1]) == 'string' and args[1]:sub(1, 100) or ''
    if charid == '' then WCDebug.warn('refund', 'usage creatorrefund <character-id> <generation-id> [owner-for-other-frameworks]') return end
    local generationId = tonumber(args[2])
    local owner = type(args[3]) == 'string' and args[3] or ''
    local row, readable = read({ charid = charid, owner = owner, generationId = generationId })
    if not readable then WCDebug.warn('refund', 'refund receipt is unreadable') return end
    if not row then WCDebug.warn('refund', 'no refund receipt for that character') return end
    WCDebug.warn('refund', 'receipt %s state %s amount %.2f %s', row.id, row.state, row.amount, row.currency)
end, true)
