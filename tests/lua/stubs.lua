-- tests/lua/stubs.lua
-- CitizenFX + w_lib boundary stubs for unit tests (loaded by tests/harness.py).
-- Everything the resource touches outside its own globals is faked here and recorded so tests can
-- assert on it. No stub performs I/O.

-- ---------------------------------------------------------------------------------------------
-- Clock and threads: GetGameTimer() is a fake clock; Wait(ms) inside a thread yields until tick()
-- advances the clock past its wake time; Wait outside a thread just advances the clock.
-- ---------------------------------------------------------------------------------------------
Clock = { now = 100000 }
Threads = {}

function GetGameTimer() return Clock.now end

function CreateThread(fn)
    local co = coroutine.create(fn)
    local thread = { co = co, wake = Clock.now }
    Threads[#Threads + 1] = thread
    local ok, err = coroutine.resume(co)
    if not ok then error(err, 0) end
    return thread
end
Citizen = { CreateThread = CreateThread }

local function currentThread()
    local co = coroutine.running()
    for _, t in ipairs(Threads) do
        if t.co == co then return t end
    end
    return nil
end

function Wait(ms)
    ms = tonumber(ms) or 0
    local t = currentThread()
    if t and coroutine.isyieldable() then
        t.wake = Clock.now + math.max(ms, 0)
        coroutine.yield()
    else
        Clock.now = Clock.now + math.max(ms, 1)
    end
end
Citizen.Wait = Wait

function SetTimeout(ms, fn)
    CreateThread(function() Wait(ms) fn() end)
end

--- Advance the clock by ms and resume every thread whose wake time has passed.
function tick(ms)
    Clock.now = Clock.now + (ms or 0)
    local progressed = true
    local guard = 0
    while progressed and guard < 10000 do
        progressed = false
        guard = guard + 1
        for _, t in ipairs(Threads) do
            if coroutine.status(t.co) == 'suspended' and t.wake <= Clock.now then
                local before = t.wake
                local ok, err = coroutine.resume(t.co)
                if not ok then error(err, 0) end
                if coroutine.status(t.co) == 'dead' or t.wake ~= before then progressed = true end
            end
        end
    end
end

-- ---------------------------------------------------------------------------------------------
-- Hashes: RedM's GetHashKey returns a signed int32 (Jenkins one-at-a-time over the lower-cased
-- string); WCUtil.u32 normalises.
-- ---------------------------------------------------------------------------------------------
function joaat(s)
    s = tostring(s):lower()
    local h = 0
    for i = 1, #s do
        h = (h + s:byte(i)) & 0xffffffff
        h = (h + (h << 10)) & 0xffffffff
        h = h ~ (h >> 6)
    end
    h = (h + (h << 3)) & 0xffffffff
    h = h ~ (h >> 11)
    h = (h + (h << 15)) & 0xffffffff
    if h >= 0x80000000 then h = h - 0x100000000 end
    return h
end
GetHashKey = joaat

-- ---------------------------------------------------------------------------------------------
-- Vectors
-- ---------------------------------------------------------------------------------------------
local vmt = {}
vmt.__index = vmt
local function vec(x, y, z, w) return setmetatable({ x = x, y = y, z = z, w = w }, vmt) end
vmt.__sub = function(a, b) return vec(a.x - b.x, a.y - b.y, a.z - b.z) end
vmt.__add = function(a, b) return vec(a.x + b.x, a.y + b.y, a.z + b.z) end
vmt.__len = function(a) return math.sqrt(a.x * a.x + a.y * a.y + a.z * a.z) end
vmt.__eq = function(a, b) return a.x == b.x and a.y == b.y and a.z == b.z and a.w == b.w end
function vector3(x, y, z) return vec(x, y, z) end
function vector4(x, y, z, w) return vec(x, y, z, w) end

-- ---------------------------------------------------------------------------------------------
-- Events, commands, exports
-- ---------------------------------------------------------------------------------------------
Events = { handlers = {}, client = {}, commands = {} }

function AddEventHandler(name, fn)
    Events.handlers[name] = Events.handlers[name] or {}
    table.insert(Events.handlers[name], fn)
    return { name = name, fn = fn }
end
function RegisterNetEvent(name, fn)
    if fn then return AddEventHandler(name, fn) end
end
function RemoveEventHandler() end

--- Fire an event as the server/client would; src (optional) becomes the global `source`.
function fireEvent(name, src, ...)
    local previous = source
    source = src
    for _, fn in ipairs(Events.handlers[name] or {}) do fn(...) end
    source = previous
end
function TriggerEvent(name, ...) fireEvent(name, nil, ...) end

function TriggerClientEvent(name, player, ...)
    table.insert(Events.client, { name = name, player = player, args = { ... } })
end
function TriggerServerEvent() end

function RegisterCommand(name, fn, restricted)
    Events.commands[name] = { fn = fn, restricted = restricted }
end

exports = setmetatable({}, { __index = function() return setmetatable({}, { __index = function() return function() end end }) end,
                             __call = function() end })

function GetCurrentResourceName() return 'w_creators' end
function GetResourceState() return 'missing' end
function IsDuplicityVersion() return true end
function LoadResourceFile() return nil end

-- ---------------------------------------------------------------------------------------------
-- Players, peds, routing buckets
-- ---------------------------------------------------------------------------------------------
Players = { [1] = { name = 'player one', coords = vector3(0, 0, 0), bucket = 0 } }

function GetPlayerName(src)
    local p = Players[tonumber(src) or -1]
    return p and p.name or nil
end
function GetPlayers()
    local out = {}
    for id in pairs(Players) do out[#out + 1] = tostring(id) end
    table.sort(out)
    return out
end
function GetPlayerPed(src)
    if Players[tonumber(src) or -1] then return 1000 + src end
    return 0
end
-- BOOL natives answer 1 (not true) on the RedM runtime; the stub does the same.
function DoesEntityExist(entity)
    if type(entity) == 'number' and Players[entity - 1000] ~= nil then return 1 end
    return false
end
function GetEntityCoords(entity)
    local p = Players[(tonumber(entity) or 0) - 1000]
    return p and p.coords or vector3(0, 0, 0)
end
function SetPlayerRoutingBucket(src, bucket) if Players[src] then Players[src].bucket = bucket end end
function GetPlayerRoutingBucket(src) return Players[src] and Players[src].bucket or 0 end
function GetPlayerIdentifierByType(src, kind) return kind .. ':' .. tostring(src) end
function GetPlayerIdentifier(src) return 'license:' .. tostring(src) end
function IsPlayerAceAllowed() return false end

-- ---------------------------------------------------------------------------------------------
-- Locale
-- ---------------------------------------------------------------------------------------------
function locale(key, ...)
    if select('#', ...) > 0 then
        local ok, text = pcall(string.format, key, ...)
        if ok then return text end
    end
    return key
end

-- ---------------------------------------------------------------------------------------------
-- w_lib
-- ---------------------------------------------------------------------------------------------
Printed = {}
local function printer(level)
    return function(fmt, ...)
        local ok, text = pcall(string.format, tostring(fmt), ...)
        table.insert(Printed, { level = level, text = ok and text or tostring(fmt) })
    end
end

-- print() is captured (startup/fatal diagnostics) so test output stays clean.
function print(...)
    local parts = {}
    for i = 1, select('#', ...) do parts[#parts + 1] = tostring((select(i, ...))) end
    table.insert(Printed, { level = 'print', text = table.concat(parts, ' ') })
end

Callbacks = {}
Notifications = {}
LogEmits = {}
LogTypes = {}

w = {
    print = { debug = printer('debug'), info = printer('info'), warn = printer('warn'), error = printer('error') },
    notify = function(src, data) table.insert(Notifications, { src = src, data = data }) end,
    callback = { register = function(name, fn) Callbacks[name] = fn end },
    component = { data = {} },
    logs = {
        IsReady = function() return false end,
        Emit = function(event, payload) table.insert(LogEmits, { event = event, payload = payload }) return true end,
        RegisterScript = function() return { ok = true } end,
        RegisterLogType = function(data) table.insert(LogTypes, data.key) return { ok = true } end,
    },
    waitFor = function(fn, message, timeout)
        local value = WCUtil and WCUtil.waitUntil(fn, timeout or 5000) or fn()
        if not value then error(message or 'waitFor timed out') end
        return value
    end,
}

function setComponentData(catalog, data)
    w.component.data.expressions = data.expressions
    w.component.data.palettes = data.palettes
    w.component.data.wearableStates = data.wearableStates
    w.component.getFullPedComponentList = function() return catalog end
end

-- ---------------------------------------------------------------------------------------------
-- Fake database (w.database): scripted handlers, recorded queries, a small schema simulator for
-- migrations, and a transaction success toggle.
--   FakeDB.on(pattern, result)   result = value | function(sql, params, kind) -> value
--   FakeDB.transactionOk = false makes transaction.await return false
--   FakeDB.transactionError = 'msg' makes transaction.await throw
--   FakeDB.fail = pattern         any matching statement throws
-- ---------------------------------------------------------------------------------------------
FakeDB = {
    queries = {}, handlers = {}, transactions = {}, readyCallbacks = {},
    transactionOk = true, transactionError = nil, fail = nil,
    schema = {}, migrations = {}, nextId = 1,
}

function FakeDB.on(pattern, result)
    table.insert(FakeDB.handlers, { pattern = pattern, result = result })
end

function FakeDB.reset()
    FakeDB.queries, FakeDB.handlers, FakeDB.transactions = {}, {}, {}
    FakeDB.transactionOk, FakeDB.transactionError, FakeDB.fail = true, nil, nil
end

function FakeDB.count(pattern)
    local n = 0
    for _, q in ipairs(FakeDB.queries) do
        if q.sql:find(pattern) then n = n + 1 end
    end
    return n
end

local function simulate(kind, sql, params)
    local upper = sql:upper()
    local tname = sql:match('CREATE TABLE IF NOT EXISTS `([%w_]+)`')
    if tname then
        if not FakeDB.schema[tname] then
            local cols = {}
            for col in sql:gmatch('\n%s*`([%w_]+)`%s') do cols[col] = true end
            FakeDB.schema[tname] = cols
        end
        return 0
    end
    local alter = sql:match('ALTER TABLE `([%w_]+)`')
    if alter then
        local t = FakeDB.schema[alter]
        if not t then error('Table ' .. alter .. " doesn't exist") end
        for col in sql:gmatch('ADD COLUMN `([%w_]+)`') do
            if t[col] then error("Duplicate column name '" .. col .. "'") end
            t[col] = true
        end
        return 0
    end
    if upper:find('INFORMATION_SCHEMA.COLUMNS', 1, true) then
        local t = FakeDB.schema[params[1]]
        return (t and t[params[2]]) and 1 or 0
    end
    if upper:find('INFORMATION_SCHEMA.TABLES', 1, true) then
        return FakeDB.schema[params[1]] and 1 or 0
    end
    if upper:find('FROM W_CREATORS_MIGRATIONS', 1, true) then
        local rows = {}
        for _, id in ipairs(FakeDB.migrations) do rows[#rows + 1] = { id = id } end
        return rows
    end
    if upper:find('INSERT INTO W_CREATORS_MIGRATIONS', 1, true) then
        table.insert(FakeDB.migrations, params[1])
        return 1
    end
    return nil
end

local DEFAULTS = { query = function() return {} end, single = function() return nil end,
                   scalar = function() return nil end,
                   insert = function() FakeDB.nextId = FakeDB.nextId + 1 return FakeDB.nextId end,
                   update = function() return 1 end }

local function run(kind, sql, params)
    params = params or {}
    table.insert(FakeDB.queries, { kind = kind, sql = sql, params = params })
    if FakeDB.fail and sql:find(FakeDB.fail) then error('database failure: ' .. FakeDB.fail) end
    for i = #FakeDB.handlers, 1, -1 do
        local h = FakeDB.handlers[i]
        if sql:find(h.pattern) then
            if type(h.result) == 'function' then return h.result(sql, params, kind) end
            return h.result
        end
    end
    local simulated = simulate(kind, sql, params)
    if simulated ~= nil then
        if kind == 'single' and type(simulated) == 'table' then return simulated[1] end
        if kind == 'scalar' and type(simulated) == 'table' then return simulated[1] and simulated[1].id end
        return simulated
    end
    return DEFAULTS[kind]()
end

local function api(kind)
    return setmetatable({ await = function(sql, params) return run(kind, sql, params) end }, {
        __call = function(_, sql, params, cb)
            local result = run(kind, sql, params)
            if type(params) == 'function' then params(result) elseif cb then cb(result) end
        end,
    })
end

w.database = {
    query = api('query'), single = api('single'), scalar = api('scalar'),
    insert = api('insert'), update = api('update'),
    transaction = {
        await = function(queries)
            table.insert(FakeDB.transactions, queries)
            for _, q in ipairs(queries or {}) do
                table.insert(FakeDB.queries, { kind = 'transaction', sql = q.query or q[1], params = q.values or q[2] or {} })
            end
            if FakeDB.transactionError then error(FakeDB.transactionError) end
            return FakeDB.transactionOk
        end,
    },
    ready = function(fn) table.insert(FakeDB.readyCallbacks, fn) end,
}

function FakeDB.fireReady()
    for _, fn in ipairs(FakeDB.readyCallbacks) do fn() end
end

-- ---------------------------------------------------------------------------------------------
-- Fake framework users (w.framework:getUser(src))
--   FakeUsers[src] = { money = 100, failRemove = false, failAdd = false }
-- ---------------------------------------------------------------------------------------------
FakeUsers = {}
MoneyCalls = {}

local User = {}
User.__index = User
function User:getMoney() return self.state.money end
function User:canBuy(price, moneyType, removeIfCan)
    table.insert(MoneyCalls, { op = 'canBuy', src = self.src, amount = price, moneyType = moneyType, remove = removeIfCan })
    price = math.abs(price)
    local enough = self.state.money >= price
    if removeIfCan == true and enough then
        if price == 0 then return true end
        if self.state.failRemove then return false end
        self.state.money = self.state.money - price
        return true
    end
    return enough
end
function User:addMoney(amount, moneyType)
    table.insert(MoneyCalls, { op = 'addMoney', src = self.src, amount = amount, moneyType = moneyType })
    if self.state.failAdd then return false end
    self.state.money = self.state.money + amount
    return true
end

w.framework = {}
function w.framework:getUser(src)
    local state = FakeUsers[src]
    if not state then return nil end
    return setmetatable({ src = src, state = state }, User)
end
