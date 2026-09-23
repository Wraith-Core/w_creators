-- =====================================================================
--  client/appearance/sync.lua  —  appearance sync between players (ARCHITECTURE.md §9.4)
--  RedM does not sync metaped components: every client renders the other players itself. The
--  server caches the last broadcast appearance per player; this client keeps a remote cache and a
--  1 s scope watcher. When a player's ped handle appears or changes (entered scope, respawned),
--  the cached appearance is re-applied to that ped once: a fingerprint per serverId + ped + cache
--  revision prevents re-applying. Own ped: the local client applies its own appearance
--  (w_creators:client:applyAppearance); remote application is skipped for our own server id.
-- =====================================================================

Appearance.Sync = {}
local Sync = Appearance.Sync

Sync.INTERVAL = 1000   -- ms between two watcher passes
Sync.MAX_FAILURES = 5  -- failed applications of one fingerprint before it is given up

local cache = {}       -- [serverId] = { app, rev }
local fingerprints = {} -- [serverId] = 'ped:rev' last applied successfully
local failures = {}    -- [serverId] = { fp, count }
local inFlight = {}    -- [serverId] = true while an application runs (event and watcher never overlap)
local revision = 0

local function ownServerId()
    return GetPlayerServerId(PlayerId())
end

local function sid(serverId)
    return math.tointeger(tonumber(serverId))
end

--- The ped of a remote player when it exists in our scope, else nil.
local function remotePed(serverId)
    local player = GetPlayerFromServerId(serverId)
    if player == nil or player == -1 then return nil end
    local ped = GetPlayerPed(player)
    if type(ped) ~= 'number' or ped == 0 or not DoesEntityExist(ped) then return nil end
    if ped == PlayerPedId() then return nil end
    return ped
end

--- Apply the cached appearance to the remote player's current ped when the fingerprint differs.
--  Returns true when an application was attempted.
function Sync.check(serverId)
    local entry = cache[serverId]
    if not entry then return false end
    local ped = remotePed(serverId)
    if not ped then
        -- out of scope: the next ped (even one reusing this handle) is rendered again, and a
        -- given-up fingerprint is forgotten with it
        fingerprints[serverId] = nil
        failures[serverId] = nil
        return false
    end
    local rev = entry.rev
    local fp = tostring(ped) .. ':' .. tostring(rev)
    if fingerprints[serverId] == fp then return false end
    local failure = failures[serverId]
    if failure and failure.fp == fp and failure.count >= Sync.MAX_FAILURES then return false end
    if inFlight[serverId] then return false end
    inFlight[serverId] = true
    local done, ok, err = pcall(Appearance.RestoreCharacter, ped, entry.app)
    inFlight[serverId] = nil
    if not done then ok, err = false, 'INTERNAL_ERROR' end
    if entry ~= cache[serverId] or entry.rev ~= rev then
        -- the cache changed while rendering: the next pass renders the newer appearance
        return true
    end
    if ok then
        fingerprints[serverId] = fp
        failures[serverId] = nil
    else
        if not failure or failure.fp ~= fp then failure = { fp = fp, count = 0 } end
        failure.count = failure.count + 1
        failures[serverId] = failure
        WCDebug.log('sync', 'remote %s ped %s: %s (attempt %d)', tostring(serverId), tostring(ped), tostring(err), failure.count)
    end
    return true
end

--- One watcher pass over every cached remote player.
function Sync.tick()
    local own = ownServerId()
    local ids = {}
    for serverId in pairs(cache) do ids[#ids + 1] = serverId end
    table.sort(ids)
    for _, serverId in ipairs(ids) do
        if serverId ~= own then
            local ok, err = pcall(Sync.check, serverId)
            if not ok then WCDebug.warn('sync', 'remote %s: %s', tostring(serverId), tostring(err)) end
        end
    end
end

--- The cached appearance of a remote player (a copy), or nil.
function Sync.get(serverId)
    local entry = cache[sid(serverId)]
    return entry and WCUtil.copy(entry.app) or nil
end

--- Cache (and apply on the next pass) a remote player's appearance.
function Sync.set(serverId, app)
    serverId = sid(serverId)
    if not serverId or serverId == ownServerId() then return false end
    if type(app) == 'string' or (type(app) == 'table' and tonumber(app.version) ~= AppearanceSchema.VERSION) then
        app = AppearanceSchema.normalize(app) -- a legacy payload during a rolling upgrade
    end
    if type(app) ~= 'table' then return false end
    revision = revision + 1
    cache[serverId] = { app = app, rev = revision }
    failures[serverId] = nil
    return true
end

--- Forget a remote player (dropped, or switched character).
function Sync.forget(serverId)
    serverId = sid(serverId)
    if not serverId then return end
    local ped = remotePed(serverId)
    if ped and Appearance.Overlays then Appearance.Overlays.forget(ped) end
    cache[serverId], fingerprints[serverId], failures[serverId] = nil, nil, nil
end

--- A remote clothing state change: update the cache; when the ped already shows the cached
--  appearance the state is applied directly (no full re-render).
function Sync.state(serverId, groupId, value)
    serverId = sid(serverId)
    local entry = serverId and cache[serverId]
    if not entry or serverId == ownServerId() then return false end
    if not WCClothingStates.isValid(groupId, value) then return false end
    local app = entry.app
    app.clothing = type(app.clothing) == 'table' and app.clothing or {}
    app.clothing.states = type(app.clothing.states) == 'table' and app.clothing.states or {}
    app.clothing.states[groupId] = value
    local ped = remotePed(serverId)
    local current = ped and not inFlight[serverId]
        and fingerprints[serverId] == tostring(ped) .. ':' .. tostring(entry.rev)
    revision = revision + 1
    entry.rev = revision
    if current then
        -- claimed like a render: a watcher pass during the refresh neither re-renders nor overlaps
        inFlight[serverId] = true
        local done, ok = pcall(Appearance.ApplyClothingState, ped, app, groupId, value)
        if done and ok then
            local fp = tostring(ped) .. ':' .. tostring(entry.rev)
            fingerprints[serverId] = fp
            pcall(Appearance.Refresh, ped)
            inFlight[serverId] = nil
            return true
        end
        inFlight[serverId] = nil
    end
    -- not rendered yet, a render is running, or the direct state failed: the watcher re-renders
    -- with the new state
    fingerprints[serverId] = nil
    return false
end

-- ---------------------------------------------------------------------
--  Server → client events
-- ---------------------------------------------------------------------
RegisterNetEvent('w_creators:client:applyRemoteAppearance', function(serverId, app)
    if Sync.set(serverId, app) then
        local ok, err = pcall(Sync.check, sid(serverId))
        if not ok then WCDebug.warn('sync', 'remote apply failed: %s', tostring(err)) end
    end
end)

RegisterNetEvent('w_creators:client:remoteClothingState', function(serverId, groupId, value)
    Sync.state(serverId, groupId, value)
end)

RegisterNetEvent('w_creators:client:forgetRemote', function(serverId)
    Sync.forget(serverId)
end)

-- ---------------------------------------------------------------------
--  Our own appearance: queue-serialised (the newest wins), never while an editor is open
-- ---------------------------------------------------------------------
local queued, applying = nil, false

--- Take the server's appearance of our character and render it on our ped.
function Sync.applyOwn(app)
    if type(app) ~= 'table' and type(app) ~= 'string' then return end
    queued = app
    if applying then return end
    applying = true
    while queued do
        local nextApp = queued
        queued = nil
        local ok, err = pcall(function()
            local normalized = AppearanceSchema.normalize(nextApp)
            WCState.set(normalized)
            if WCState.inEditor() then
                WCDebug.log('sync', 'own appearance stored; rendering skipped while an editor is open')
                return
            end
            local done, code = Appearance.RestorePlayer(normalized)
            if not done then WCDebug.warn('sync', 'own appearance could not be rendered: %s', tostring(code)) end
        end)
        if not ok then WCDebug.warn('sync', 'own appearance failed: %s', tostring(err)) end
    end
    applying = false
end

--- Is our own appearance being applied?
function Sync.applyingOwn()
    return applying
end

RegisterNetEvent('w_creators:client:applyAppearance', function(app) Sync.applyOwn(app) end)
-- legacy alias (kept event name, §13)
RegisterNetEvent('PersonaCreatorHandler.applyCharacterAppearance', function(app) Sync.applyOwn(app) end)
-- hair / beard grew a stage (server/barber/grooming.lua): the same store-and-render path (never
-- rendered over an open editor)
RegisterNetEvent('w_creators:client:grooming', function(app) Sync.applyOwn(app) end)

-- ---------------------------------------------------------------------
--  The scope watcher and the initial request
-- ---------------------------------------------------------------------
CreateThread(function()
    while true do
        Wait(Sync.INTERVAL)
        if next(cache) then Sync.tick() end
    end
end)

CreateThread(function()
    WCUtil.waitUntil(function() return NetworkIsSessionStarted() end, 600000, 200)
    TriggerServerEvent('w_creators:server:requestAppearances')
end)
