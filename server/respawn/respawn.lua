-- =====================================================================
--  server/respawn/respawn.lua  —  admin respawn (ARCHITECTURE.md §12, §16.3)
--  Death respawn itself is client-driven (client/respawn/respawn.lua, exports Resurrect); the server
--  side only moves a living character to a spawn point on an administrator's request.
--
--  Command: wc_respawn <playerId> [pointId]
--    Console, or a player holding the Config.Admin.ace ACE. pointId = a Config.Spawn.points[].id,
--    '__last' (the target's validated last location) or omitted (the first enabled point).
--    Resolved and sent through WCSpawnServer.respawn(target, pointId, 'admin') ->
--    w_creators:client:respawn(pos, { kind = 'admin', point }) on the target.
--
--  WCRespawnServer.admin(adminSrc, target, pointId) -> Result (the command's logic).
-- =====================================================================

WCRespawnServer = {}

local function isAdmin(src)
    if src == 0 then return true end
    local ace = Config.Admin and Config.Admin.ace
    if type(ace) ~= 'string' or ace == '' then return false end
    local done, allowed = pcall(IsPlayerAceAllowed, src, ace)
    return done and allowed == true
end

local function feedback(src, key, kind, ...)
    if src == 0 then
        w.print.info('%s', locale(key, ...))
    else
        Bridge.Notify(src, key, kind)
    end
end

--- Respawn `target` at `pointId` on behalf of `adminSrc` (0 = console).
function WCRespawnServer.admin(adminSrc, target, pointId)
    adminSrc = tonumber(adminSrc) or -1
    -- Rate-limited before the permission check: the command is unrestricted (the ACE decides), so
    -- a non-admin spamming it writes at most a few security_violation entries.
    if adminSrc ~= 0 and not WCSecurity.rate(adminSrc, 'admin:respawn', 5, 10000) then
        return WCResult.fail('RATE_LIMITED')
    end
    if not isAdmin(adminSrc) then
        WCSecurity.violation(adminSrc, 'admin_respawn', { target = tostring(target) })
        return WCResult.fail('SERVICE_DISABLED')
    end
    target = tonumber(target)
    if not target or target % 1 ~= 0 or target < 1 or target > 65535 or not GetPlayerName(math.tointeger(target)) then
        return WCResult.fail('INVALID_PAYLOAD')
    end
    target = math.tointeger(target)
    if pointId ~= nil and (type(pointId) ~= 'string' or #pointId > 64) then return WCResult.fail('INVALID_SPAWN') end

    return WCSpawnServer.respawn(target, pointId, 'admin',
        { adminSource = adminSrc, reason = 'إعادة إظهار بأمر إداري' })
end

RegisterCommand('wc_respawn', function(src, args)
    src = tonumber(src) or 0
    local result = WCRespawnServer.admin(src, args and args[1], args and args[2])
    if result.ok then
        feedback(src, 'تمت إعادة إظهار اللاعب', 'success')
    elseif isAdmin(src) then
        feedback(src, result.message, 'error')
    end
end, false)
