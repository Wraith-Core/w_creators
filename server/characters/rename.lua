-- =====================================================================
--  server/characters/rename.lua  —  a character name change bought in the server store (2026-10-21)
--  The owner sells «تغيير اسم الشخصية (مرة واحدة)»: the purchase reaches the game as a w_vip token
--  (rename_tokens, F:\store src/server/extras.ts -> w_vip 1.1.0). /changename asks the new first and last
--  name (client/characters/rename.lua); the server checks the token and the names with the creation's own
--  rules (WCIdentity.validateName), spends the token, writes the names into w_core's charinfo and saves the
--  row at once. Without w_vip or w_core nothing changes (the command answers that there is no token).
-- =====================================================================

local COMMAND = 'changename'
local TOKEN = 'rename_tokens'
local busy = {}

local function tokensLeft(src)
    if GetResourceState('w_vip') ~= 'started' then return 0 end
    local ok, n = pcall(function() return exports.w_vip:TokensLeft(src, TOKEN) end)
    return ok and math.floor(tonumber(n) or 0) or 0
end

--- The framework player snapshot of a connected source, or nil.
local function corePlayer(src)
    local ok, pd = pcall(function() return exports.w_lib:FwGetPlayerData(src) end)
    if ok and type(pd) == 'table' and pd.citizenid then return pd end
    return nil
end

RegisterCommand(COMMAND, function(src)
    src = tonumber(src) or 0
    if src <= 0 then return end
    local left = tokensLeft(src)
    if left < 1 then return Bridge.Notify(src, 'ليس لديك تذكرة تغيير اسم. تقدر تشتريها من متجر السيرفر.', 'error') end
    if not corePlayer(src) then return Bridge.Notify(src, 'اختر شخصيتك أولًا ثم اكتب الأمر.', 'error') end
    TriggerClientEvent('w_creators:client:renameAsk', src, left)
end, false)

w.callback.register('w_creators:rename', function(src, first, last)
    src = tonumber(src) or 0
    if src <= 0 or busy[src] then return { ok = false, error = 'busy' } end
    busy[src] = true
    local ok, res = pcall(function()
        if tokensLeft(src) < 1 then return { ok = false, error = 'no_token' } end
        local okF, f = WCIdentity.validateName(first)
        local okL, l = WCIdentity.validateName(last)
        if not okF or not okL then return { ok = false, error = 'bad_name' } end
        local player = corePlayer(src)
        if not player then return { ok = false, error = 'no_character' } end
        local used = false
        pcall(function() used = exports.w_vip:UseToken(src, TOKEN) end)
        if not used then return { ok = false, error = 'no_token' } end
        local info = type(player.charinfo) == 'table' and player.charinfo or {}
        local before = WCUtil.trim(('%s %s'):format(info.firstname or '', info.lastname or ''))
        exports.w_lib:FwSetCharInfo(src, { firstname = f, lastname = l })
        local after = ('%s %s'):format(f, l)
        pcall(CreatorLogs.Emit, 'character_renamed', {
            playerSource = src, charid = player.citizenid, from = before, to = after,
        })
        return { ok = true, name = after }
    end)
    busy[src] = nil
    if not ok then
        WCDebug.warn('rename', 'a name change failed for %s: %s', tostring(src), tostring(res))
        return { ok = false, error = 'internal' }
    end
    return res
end)

AddEventHandler('playerDropped', function()
    busy[source] = nil
end)
