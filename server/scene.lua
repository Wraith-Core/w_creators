-- =====================================================================
--  server/scene.lua  —  WCScene: guarded scene isolation (ARCHITECTURE.md §16.2, A2/A3)
--  During the character selection/creation (and inside a store fitting room) the player is moved
--  into a routing bucket of his own (bucket = server id) so nobody sees him and he sees nobody.
--
--  Isolation is granted only while the server knows a reason for it:
--    'selection'  the player is in the character flow (no active character, a creation grant, a
--                 pending selection/creation, or a server-tracked character switch: WCCharacters.inFlow)
--    'fitting'    the player holds an open store session at a location with a fitting stand (preview)
--  Every bucket w_creators sets is tracked with the bucket the player was in before; release restores
--  that bucket only when the player is still in the one w_creators set (a bucket another resource set
--  meanwhile — jail, housing instance — is never touched).
--
--    WCScene.isolate(src, startSwitch?) -> Result { bucket, reason }
--        startSwitch (scene:prepare): a player with an active character and no fitting-room session
--        starts a server-tracked character switch (WCCharacters.beginSwitch, §9.1 rules) — the
--        selector's first call (§17). A refused switch answers its code (SERVICE_DISABLED / BUSY).
--    WCScene.registerPed(src, netId) -> Result { bucket }
--    WCScene.release(src)            -> Result { released }
--    WCScene.isIsolated(src)         -> boolean
--    WCScene.toWorld(src, reason)    the spawn path: bucket 0 and the tracking cleared
--
--  Callbacks: w_creators:scene:prepare | registerPed | release.
--  Legacy net events (same guarded functions): w_creators:server:isolate,
--  PersonaCreatorHandler.setPlayerRoutingBucket, PersonaCreatorHandler.setRoutingBucket (netId),
--  w_creators:server:rejoinWorld.
-- =====================================================================

WCScene = {}
local Scene = WCScene

local tracked = {} -- [src] = { bucket = src, previous = <bucket before>, reason = 'selection'|'fitting' }

local PED_TIMEOUT_MS = 5000
local MODELS = { male = 'mp_male', female = 'mp_female' }

local function valid(src)
    src = tonumber(src)
    if not src or src <= 0 or src % 1 ~= 0 then return nil end
    src = math.tointeger(src)
    if not GetPlayerName(src) then return nil end
    return src
end

local function logBucket(src, scope, after, reason, extra)
    local payload = { playerSource = src, scope = scope, after = after, reason = reason }
    for k, v in pairs(extra or {}) do payload[k] = v end
    pcall(CreatorLogs.Emit, 'routing_bucket_set', payload)
end

--- The store session that justifies a fitting-room isolation, or nil.
local function fittingSession(src)
    local session = WCSessions and WCSessions.current(src)
    if type(session) ~= 'table' or session.kind ~= 'store' then return nil end
    if type(session.location) ~= 'table' or session.location.preview == nil then return nil end
    return session
end

--- Why this player may be isolated now ('selection' | 'fitting'), or nil.
local function reasonFor(src)
    if type(WCCharacters) == 'table' and WCCharacters.inFlow(src) then return 'selection' end
    if fittingSession(src) then return 'fitting' end
    return nil
end

--- Is this player in a bucket w_creators set?
function Scene.isIsolated(src)
    local entry = tracked[tonumber(src) or -1]
    return entry ~= nil and GetPlayerRoutingBucket(entry.src) == entry.bucket
end

--- Isolate the player in bucket = src (guarded).
function Scene.isolate(src, startSwitch)
    src = valid(src)
    if not src then return WCResult.fail('INVALID_PAYLOAD') end
    if not WCSecurity.rate(src, 'scene:isolate', 6, 10000) then return WCResult.fail('RATE_LIMITED') end

    local current = GetPlayerRoutingBucket(src)
    local entry = tracked[src]
    -- Already in the bucket w_creators set (e.g. the spawn selector after loading): nothing changes.
    if entry and current == entry.bucket then
        return WCResult.ok({ bucket = entry.bucket, reason = entry.reason })
    end

    local reason = reasonFor(src)
    if not reason and startSwitch == true and type(WCCharacters) == 'table' and WCCharacters.active(src) then
        -- The selector opened mid-game (/characters): the switch rules decide, not a violation.
        local started, code = WCCharacters.beginSwitch(src)
        if not started then return WCResult.fail(code or 'BUSY') end
        reason = reasonFor(src)
    end
    if not reason then
        WCSecurity.violation(src, 'scene_isolation', { bucket = current })
        return WCResult.fail('SESSION_NOT_FOUND')
    end
    -- Tracked but moved elsewhere by another resource since: that bucket is the one to come back to.
    tracked[src] = { src = src, bucket = src, previous = current, reason = reason }
    SetPlayerRoutingBucket(src, src)
    logBucket(src, 'player', src, reason == 'fitting' and 'عزل غرفة القياس' or 'عزل مشهد الاختيار/الإنشاء',
        { before = current })
    if GetPlayerRoutingBucket(src) ~= src then
        tracked[src] = nil
        return WCResult.fail('INTERNAL_ERROR')
    end
    return WCResult.ok({ bucket = src, reason = reason })
end

--- Put a networked preview ped of the player into his private bucket.
--  Checks: the player is isolated by w_creators, the entity exists (waited with a timeout), it is a
--  ped owned by the player, not his own ped, an mp_male/mp_female model, near the scene anchor.
function Scene.registerPed(src, netId)
    src = valid(src)
    if not src then return WCResult.fail('INVALID_PAYLOAD') end
    if not WCSecurity.rate(src, 'scene:registerPed', 10, 10000) then return WCResult.fail('RATE_LIMITED') end
    if type(netId) ~= 'number' or netId % 1 ~= 0 or netId <= 0 or netId > 0xffff then
        return WCResult.fail('INVALID_PAYLOAD')
    end
    if not Scene.isIsolated(src) then return WCResult.fail('SESSION_NOT_FOUND') end

    -- The client can receive a network id before the server has the entity.
    local entity = WCUtil.waitUntil(function()
        if not GetPlayerName(src) then return nil end
        local e = NetworkGetEntityFromNetworkId(netId)
        if e and e ~= 0 and DoesEntityExist(e) then return e end
        return nil
    end, PED_TIMEOUT_MS, 50)
    if not entity or not Scene.isIsolated(src) then return WCResult.fail('SESSION_NOT_FOUND') end

    if NetworkGetEntityOwner(entity) ~= src or GetEntityType(entity) ~= 1 or entity == GetPlayerPed(src) then
        WCSecurity.violation(src, 'scene_register_ped', { netId = netId, reason = 'ownership' })
        return WCResult.fail('INVALID_PAYLOAD')
    end
    local model = GetEntityModel(entity)
    if model ~= GetHashKey(MODELS.male) and model ~= GetHashKey(MODELS.female) then
        WCSecurity.violation(src, 'scene_register_ped', { netId = netId, reason = 'model' })
        return WCResult.fail('INVALID_PAYLOAD')
    end
    local anchor = Config.Scene and Config.Scene.anchor
    local radius = tonumber(Config.Scene and Config.Scene.cleanupRadius) or 25.0
    local d2 = WCUtil.dist2(GetEntityCoords(entity), anchor)
    if not d2 or d2 > radius * radius then
        WCSecurity.violation(src, 'scene_register_ped', { netId = netId, reason = 'distance' })
        return WCResult.fail('TOO_FAR')
    end

    SetEntityRoutingBucket(entity, src)
    logBucket(src, 'entity', src, 'عزل شخصية المعاينة', { networkId = netId })
    if GetEntityRoutingBucket(entity) ~= src then return WCResult.fail('INTERNAL_ERROR') end
    return WCResult.ok({ bucket = src })
end

--- Leave the private bucket: the bucket the player came from is restored only when he is still in
--  the one w_creators set. Always ok (idempotent); data.released says whether anything changed.
function Scene.release(src)
    src = valid(src)
    if not src then return WCResult.fail('INVALID_PAYLOAD') end
    local entry = tracked[src]
    if not entry then return WCResult.ok({ released = false }) end
    tracked[src] = nil
    if GetPlayerRoutingBucket(src) ~= entry.bucket then return WCResult.ok({ released = false }) end
    local previous = math.tointeger(tonumber(entry.previous) or 0) or 0
    SetPlayerRoutingBucket(src, previous)
    logBucket(src, 'player', previous, 'العودة إلى العالم')
    return WCResult.ok({ released = true, bucket = previous })
end

--- The spawn path (§16.3): the character enters the world in bucket 0 and the tracking is dropped.
function Scene.toWorld(src, reason)
    src = tonumber(src)
    if not src then return false end
    tracked[src] = nil
    if GetPlayerRoutingBucket(src) ~= 0 then
        SetPlayerRoutingBucket(src, 0)
        logBucket(src, 'player', 0, reason or 'الظهور في العالم')
    end
    return true
end

--- Forget the tracking of a player without touching his bucket.
function Scene.forget(src)
    tracked[tonumber(src) or -1] = nil
end

-- ---------------------------------------------------------------------
--  Callbacks and legacy events
-- ---------------------------------------------------------------------
w.callback.register('w_creators:scene:prepare', function(src) return Scene.isolate(src, true) end)
w.callback.register('w_creators:scene:registerPed', function(src, netId) return Scene.registerPed(src, netId) end)
-- Client-requested releases are rate-limited here (the internal callers of Scene.release are not).
local function releaseRequest(src)
    if not WCSecurity.rate(src, 'scene:release', 6, 10000) then return WCResult.fail('RATE_LIMITED') end
    return Scene.release(src)
end
w.callback.register('w_creators:scene:release', function(src) return releaseRequest(src) end)

RegisterNetEvent('w_creators:server:isolate', function() Scene.isolate(source) end)
RegisterNetEvent('PersonaCreatorHandler.setPlayerRoutingBucket', function() Scene.isolate(source) end)
RegisterNetEvent('PersonaCreatorHandler.setRoutingBucket', function(netId)
    local src = source
    -- registerPed may wait for the entity: never block the event queue
    CreateThread(function() Scene.registerPed(src, netId) end)
end)
RegisterNetEvent('w_creators:server:rejoinWorld', function() releaseRequest(source) end)

-- A fitting-room isolation ends with its store session (expiry, cancel, commit, death).
if WCSessions and WCSessions.onClose then
    WCSessions.onClose(function(session, reason)
        local entry = session and tracked[session.src]
        if entry and entry.reason == 'fitting' and reason ~= 'dropped' then Scene.release(session.src) end
    end)
end

AddEventHandler('playerDropped', function()
    tracked[tonumber(source) or -1] = nil
end)

--- Resource stop: only the buckets w_creators set are restored.
AddEventHandler('onResourceStop', function(resource)
    if resource ~= GetCurrentResourceName() then return end
    for src, entry in pairs(tracked) do
        if GetPlayerName(src) and GetPlayerRoutingBucket(src) == entry.bucket then
            SetPlayerRoutingBucket(src, math.tointeger(tonumber(entry.previous) or 0) or 0)
        end
    end
    tracked = {}
end)
