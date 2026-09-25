-- =====================================================================
--  server/respawn/respawn.lua  —  admin respawn (ARCHITECTURE.md §12, §16.3)
--  Death respawn itself is client-driven (client/respawn/respawn.lua, exports Resurrect); the server
--  side only moves a living character to a spawn point on an administrator's request.
--
--  Command: wc_respawn <citizenId> [pointId]
--    Console, or a player holding the Config.Admin.ace ACE. The target is the citizen id staff
--    type ('12', the old 'OMG95204'); '#5' names whoever is on server id 5. A server id changes on
--    every connection and, now that citizen ids are plain digits, the two collide, so a bare number
--    is never read as a server id. A respawn moves a live ped: an offline citizen is refused
--    (PLAYER_OFFLINE). pointId = a Config.Spawn.points[].id,
--    '__last' (the target's validated last location) or omitted (the first enabled point).
--    Resolved and sent through WCSpawnServer.respawn(target, pointId, 'admin') ->
--    w_creators:client:respawn(pos, { kind = 'admin', point }) on the target.
--
--  WCRespawnServer.admin(adminSrc, target, pointId) -> Result (the command's logic; `target` is the
--  typed text, resolved by w.citizen).
-- =====================================================================

WCRespawnServer = {}

-- w.citizen's failure reasons as Result codes (shared/result.lua carries their messages)
local CITIZEN_FAILURE = {
    invalid_id = 'INVALID_CITIZEN_ID',
    not_found = 'PLAYER_NOT_FOUND',
    offline = 'PLAYER_OFFLINE',
}

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
    if type(target) ~= 'string' and type(target) ~= 'number' then return WCResult.fail('INVALID_PAYLOAD') end
    local who, reason, offline = w.citizen.requireOnline(target, { self = adminSrc > 0 and adminSrc or nil })
    if not who then
        return WCResult.fail(CITIZEN_FAILURE[reason] or 'PLAYER_NOT_FOUND',
            offline and { citizenid = offline.citizenid, label = w.citizen.label(offline) } or nil)
    end
    target = who.source
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
