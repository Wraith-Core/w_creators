-- =====================================================================
--  server/spawn/spawn.lua  —  WCSpawnServer, the spawn service (ARCHITECTURE.md §11, §16.3)
--  The client only ever sends a spawn point id ('__last' or a Config.Spawn.points[].id); the server
--  resolves the coordinates. No coordinate ever arrives from the client.
--
--  The permission to spawn is a one-shot grant (SpawnPending[src]) given when a character finishes
--  loading (WCSpawnServer.finish) and consumed by the choice. Spawn kinds:
--  'initial' (new character) | 'login' | 'switch' | 'death' | 'admin'.
--
--  1.0.8 (owner 2026-11-02): a returning character (login / switch) spawns at his valid last location
--  with no selector (Config.Spawn.lastLocation.direct); a house OWNER (w_housing GetHomeSpawn,
--  Config.Spawn.home) gets the selector with two choices, '__last' «آخر مكان» and '__home' «بيتي»
--  (no valid last location: «بيتي» and the towns); «بيتي» on a bed sends meta.bed (the client wakes
--  him up there). A new character, or no valid last location and no house: the selector as before.
--
--  Last location (only while Config.Services.lastLocation is on): read from the framework and
--  rejected when non-finite, all-zero, outside Config.Spawn.bounds or within
--  Config.Spawn.sceneExclusionRadius of the creator scene anchor; a rejected last location falls
--  back to the first enabled point (lowest order first).
--
--    WCSpawnServer.grant(src, kind)             the one-shot spawn grant
--    WCSpawnServer.pending(src)                 the granted kind, or nil
--    WCSpawnServer.cancel(src)                  withdraw a grant
--    WCSpawnServer.cancelLogin(src)             withdraw a login-kind grant (initial / login / switch):
--                                               the player left the character scene without spawning
--    WCSpawnServer.finish(src, kind, isNew)     -> 'selector' | 'direct' | 'event'
--    WCSpawnServer.resolve(pointId, src)        -> pos, pointId | nil, code
--    WCSpawnServer.validateLast(pos)            -> { x, y, z, heading } | nil
--    WCSpawnServer.lastPosition(src)            -> the valid last position | nil
--    WCSpawnServer.nearestLabel(pos)            -> locale key of the nearest enabled point | nil
--    WCSpawnServer.points() / pointIds()        enabled points in display order
--    WCSpawnServer.respawn(src, pointId, kind, extra?) -> Result { pos, kind, point } (client:respawn);
--                                               kind 'admin' is BUSY while heldByDeathOwner
--    WCSpawnServer.heldByDeathOwner(src)        w_ambulancejob (started) says dead / downed / in a bed
--
--  Events (§16.3):
--    w_creators:client:selectSpawn  { last = {x, y, z, heading, label} | nil, home = {x, y, z, heading} | nil,
--                                     points = { ids }, kind }
--    w_creators:client:spawn        (pos {x, y, z, heading}, meta {kind, bed = {x, y, z, heading} | nil})
--    w_creators:client:respawn      (pos, meta {kind, point})
--    w_creators:spawn:choose        callback (pointId) -> Result { pos, kind }
--    w_creators:server:spawnAt      legacy net event (pointId) -> same resolution, never refuses a
--                                   granted player (falls back to the first enabled point)
--    w_creators:server:spawnCancel  net event: the client cancelled an in-world ('admin') selector;
--                                   that grant is withdrawn
-- =====================================================================

WCSpawnServer = {}
local Spawn = WCSpawnServer

--- The players who are expected to pick a spawn location. The key's presence is the permission:
--  without it the spawn choice is refused, so an injected client cannot move itself to any town
--  whenever it likes.
SpawnPending = {}

local pendingKind = {} -- [src] = the spawn kind of the grant

Spawn.KINDS = { initial = true, login = true, switch = true, death = true, admin = true }
Spawn.LAST_ID = '__last'
local LAST_ID = Spawn.LAST_ID
-- 1.0.8: the house owner's «بيتي» (Config.Spawn.home, w_housing GetHomeSpawn)
Spawn.HOME_ID = '__home'
local HOME_ID = Spawn.HOME_ID
local MAX_ID_LEN = 64

-- 1.0.15 (owner 2026-11-05): the only ids a returning character's grant accepts (an ordered list: «آخر مكان»,
-- «بيتي», or the one fallback point). nil = any enabled point (a new character, the admin selector).
local grantAllow = {} -- [src] = { id, ... }

AddEventHandler('playerDropped', function()
    SpawnPending[source] = nil
    pendingKind[source] = nil
    grantAllow[source] = nil
end)

local function selectorEnabled()
    return WCServices.enabled('spawnSelector') and Config.Spawn.selector.enabled ~= false
end

local function lastLocationEnabled()
    return WCServices.enabled('lastLocation') and Config.Spawn.lastLocation.enabled ~= false
end

--- The death system (w_ambulancejob): its server IsDead(playerId) answers dead, last stand or in a
--  hospital bed; InHospitalBed(playerId) the bed alone. Either export may be missing.
Spawn.DEATH_OWNER = { resource = 'w_medic', exports = { 'IsDead', 'InHospitalBed' } } -- w_ambulancejob before 2026-10-14

--- Is the player down or in a hospital bed for the death system (only while it is started)? An
--  in-world spawn selector or admin respawn then answers BUSY: the death system owns the player.
--  A missing, stopped or throwing export never blocks.
function Spawn.heldByDeathOwner(src)
    local owner = Spawn.DEATH_OWNER
    if type(owner) ~= 'table' or type(owner.resource) ~= 'string' or type(owner.exports) ~= 'table' then
        return false
    end
    local okState, state = pcall(GetResourceState, owner.resource)
    if not okState or state ~= 'started' then return false end
    for _, name in ipairs(owner.exports) do
        -- a CitizenFX export proxy member is function(self, ...): the player id is the second argument
        local done, held = pcall(function() return exports[owner.resource][name](nil, src) end)
        if done and held ~= nil and held ~= false then return true end
    end
    return false
end

-- { x, y, z, heading } of a config position, or nil when its coordinates are not finite.
local function position(coords, heading)
    local x, y, z = WCUtil.xyz(coords)
    if not x then return nil end
    heading = tonumber(heading)
    return { x = x, y = y, z = z, heading = WCUtil.isFinite(heading) and heading or 0.0 }
end

local function firstSpawn()
    local cfg = Config.Spawn.firstSpawn or {}
    return position(cfg.coords, cfg.heading) or { x = 0.0, y = 0.0, z = 0.0, heading = 0.0 }
end

--- The enabled spawn points with valid coordinates, sorted by order (then config position).
function Spawn.points()
    local list = {}
    for index, pt in ipairs(Config.Spawn.points or {}) do
        if type(pt) == 'table' and pt.enabled ~= false and type(pt.id) == 'string' and position(pt.coords) then
            list[#list + 1] = { pt = pt, order = tonumber(pt.order) or math.huge, index = index }
        end
    end
    table.sort(list, function(a, b)
        if a.order ~= b.order then return a.order < b.order end
        return a.index < b.index
    end)
    local out = {}
    for i, entry in ipairs(list) do out[i] = entry.pt end
    return out
end

--- The ids of the enabled spawn points, in display order.
function Spawn.pointIds()
    local ids = {}
    for i, pt in ipairs(Spawn.points()) do ids[i] = pt.id end
    return ids
end

-- The fallback position: the first enabled point, or firstSpawn when none is enabled.
local function fallback()
    local pt = Spawn.points()[1]
    if pt then return position(pt.coords, pt.heading), pt.id end
    return firstSpawn(), nil
end

--- Look up an enabled spawn point (with valid coordinates) by its id.
function Bridge.FindSpawnPoint(id)
    if type(id) ~= 'string' then return nil end
    for _, pt in ipairs(Spawn.points()) do
        if pt.id == id then return pt end
    end
    return nil
end

--- Validate a last position (§11). Returns a clean { x, y, z, heading } or nil.
function Spawn.validateLast(pos)
    if type(pos) ~= 'table' then return nil end
    local x, y, z = tonumber(pos.x), tonumber(pos.y), tonumber(pos.z)
    if not (WCUtil.isFinite(x) and WCUtil.isFinite(y) and WCUtil.isFinite(z)) then return nil end
    -- An absolute zero = a row that never had a position saved in it, not a real location
    if x == 0 and y == 0 and z == 0 then return nil end
    local b = Config.Spawn.bounds
    if type(b) == 'table' then
        local lo = { tonumber(b.minX), tonumber(b.minY), tonumber(b.minZ) }
        local hi = { tonumber(b.maxX), tonumber(b.maxY), tonumber(b.maxZ) }
        for i, v in ipairs({ x, y, z }) do
            if (lo[i] and v < lo[i]) or (hi[i] and v > hi[i]) then return nil end
        end
    end
    local radius = tonumber(Config.Spawn.sceneExclusionRadius)
    local anchor = Config.Scene and Config.Scene.anchor
    if anchor and WCUtil.isFinite(radius) and radius > 0 then
        local d2 = WCUtil.dist2({ x, y, z }, anchor)
        if d2 and d2 <= radius * radius then return nil end
    end
    local heading = tonumber(pos.heading or pos.w)
    return { x = x, y = y, z = z, heading = WCUtil.isFinite(heading) and heading or 0.0 }
end

--- The character's valid last position (lastLocation service on), or nil.
function Spawn.lastPosition(src)
    if not lastLocationEnabled() then return nil end
    local ok, pos = pcall(Bridge.GetLastPosition, src)
    if not ok then return nil end
    return Spawn.validateLast(pos)
end

--- 1.0.8: is a returning character spawned straight at his last location (Config.Spawn.lastLocation.direct)?
local function directLast()
    return lastLocationEnabled() and Config.Spawn.lastLocation.direct == true
end

--- 1.0.8: the house the character OWNS, as w_housing answers it (soft dependency: missing, stopped or throwing =
--  no home). Validated like a last location; the bed's sleep point is kept for the wake-up.
--  -> { x, y, z, heading, bed = { x, y, z, heading } | nil } | nil
function Spawn.home(src)
    local cfg = Config.Spawn.home
    if type(cfg) ~= 'table' or cfg.enabled ~= true or type(cfg.resource) ~= 'string' then return nil end
    local okState, state = pcall(GetResourceState, cfg.resource)
    if not okState or state ~= 'started' then return nil end
    local ok, home = pcall(function() return exports[cfg.resource]:GetHomeSpawn(tonumber(src)) end)
    if not ok or type(home) ~= 'table' then return nil end
    local pos = Spawn.validateLast(home)
    if not pos then return nil end
    if type(home.bed) == 'table' then
        local bed = Spawn.validateLast(home.bed)
        if bed then pos.bed = bed end
    end
    return pos
end

--- The locale key of the enabled spawn point nearest to a position (the region the player left).
function Spawn.nearestLabel(pos)
    local best, bestD
    for _, pt in ipairs(Spawn.points()) do
        local d = WCUtil.dist2(pos, pt.coords)
        if d and (not bestD or d < bestD) then best, bestD = pt, d end
    end
    return best and best.label or nil
end

--- Resolve a spawn point id to server coordinates.
--  '__last' needs the lastLocation service; an invalid last position falls back to the first
--  enabled point (§11). Any other id must be an enabled point.
--  Returns pos, pointId | nil, 'INVALID_SPAWN' | 'INVALID_PAYLOAD'.
function Spawn.resolve(pointId, src)
    if type(pointId) ~= 'string' or #pointId == 0 or #pointId > MAX_ID_LEN then return nil, 'INVALID_PAYLOAD' end
    if pointId == LAST_ID then
        if not lastLocationEnabled() then return nil, 'INVALID_SPAWN' end
        local last = src and Spawn.lastPosition(src)
        if last then return last, LAST_ID end
        return fallback()
    end
    -- 1.0.8: «بيتي», asked of w_housing again now (the house may have been sold since the choice was shown)
    if pointId == HOME_ID then
        local home = src and Spawn.home(src)
        if home then return home, HOME_ID end
        return nil, 'INVALID_SPAWN'
    end
    local pt = Bridge.FindSpawnPoint(pointId)
    local pos = pt and position(pt.coords, pt.heading)
    if not pos then return nil, 'INVALID_SPAWN' end
    return pos, pt.id
end

--- The character's spawn coordinates: the last saved position when it is valid (and the service
--  is enabled), otherwise the first enabled spawn point.
function Bridge.GetSpawnCoords(source)
    return Spawn.lastPosition(source) or (fallback())
end

local function activeCharid(src)
    local active = WCSessions and WCSessions.activeCharacter(src)
    if active then return active.charid end
    local ok, charid = pcall(Bridge.GetCharId, src)
    return ok and charid and tostring(charid) or nil
end

local function logSpawn(src, kind, point, extra)
    local payload = { playerSource = src, charid = activeCharid(src), kind = kind, point = point }
    for k, v in pairs(extra or {}) do payload[k] = v end
    pcall(CreatorLogs.Emit, 'character_spawned', payload)
end

-- The login-kind entry into the world: the private scene bucket (the one w_creators set) becomes
-- bucket 0; a bucket another resource set since (jail, instance) is kept (WCScene.toWorld).
local function toWorld(src)
    if WCScene and WCScene.toWorld then
        WCScene.toWorld(src)
    else
        SetPlayerRoutingBucket(src, 0)
    end
end

--- Kinds of a player who is already in the world (the character is logged in and playing): the
--  move goes through w_creators:client:respawn and the routing bucket is left alone. w_core treats
--  w_creators:client:spawn as a fresh login (OnPlayerLoaded), and a bucket another resource set
--  after the grant (jail, instance) must not be reset to 0.
local IN_WORLD = { admin = true, death = true }

-- Move the player into the world at pos (the grant, if any, is consumed).
local function spawnNow(src, pos, point, kind)
    SpawnPending[src] = nil
    pendingKind[src] = nil
    grantAllow[src] = nil
    if IN_WORLD[kind] then
        TriggerClientEvent('w_creators:client:respawn', src, pos, { kind = kind, point = point })
    else
        toWorld(src)
        -- 1.0.8: «بيتي» on the bed: the client lies the player there and wakes him up (meta.bed)
        local bed = point == HOME_ID and type(pos) == 'table' and pos.bed or nil
        TriggerClientEvent('w_creators:client:spawn', src, pos, { kind = kind, bed = bed })
    end
    logSpawn(src, kind, point)
    return kind
end

--- Give the one-shot spawn grant.
function Spawn.grant(src, kind)
    src = tonumber(src)
    if not src then return false end
    SpawnPending[src] = true
    pendingKind[src] = Spawn.KINDS[kind] and kind or 'login'
    grantAllow[src] = nil
    return true
end

--- 1.0.15: may the pending grant spawn at this id? (a returning character: only the ids he was shown)
function Spawn.allowed(src, pointId)
    local allow = grantAllow[src]
    if not allow then return true end
    for _, id in ipairs(allow) do
        if id == pointId then return true end
    end
    return false
end

--- The kind of the player's pending spawn grant, or nil.
function Spawn.pending(src)
    return SpawnPending[src] and (pendingKind[src] or 'login') or nil
end

--- Withdraw a pending grant (character switch, disconnect).
function Spawn.cancel(src)
    SpawnPending[src] = nil
    pendingKind[src] = nil
    grantAllow[src] = nil
end

--- Withdraw a pending login-kind grant (initial / login / switch); an in-world one is kept.
--  The client released the character scene without spawning: the grant belongs to that scene.
function Spawn.cancelLogin(src)
    local kind = Spawn.pending(src)
    if kind and not IN_WORLD[kind] then
        Spawn.cancel(src)
        WCDebug.log('spawn', 'the %s spawn grant of %s was withdrawn: the character scene was left', kind, tostring(src))
        return true
    end
    return false
end

--- Finish the creation/selection: a freshly created character gets its starting survival
--  metadata (Config.Characters.setSurvivalMetadata: hunger / thirst, set after the creation only —
--  a login or a switch keeps the needs the character had, so re-selecting a character is never a
--  free refill), then either open the location selector (the player stays in his isolated bucket
--  until he picks), hand over to the framework's spawn event (Config.Creator.spawnEvent), or spawn
--  directly.
--  isNew = true for a freshly created character (it has no saved position).
--  Returns 'selector' | 'direct' | 'event'.
function Spawn.finish(src, kind, isNew)
    kind = Spawn.KINDS[kind] and kind or (isNew and 'initial' or 'login')
    if isNew == true or kind == 'initial' then pcall(Bridge.SetSurvival, src) end

    local spawnEvent = Config.Creator.spawnEvent
    -- 1.0.8 (owner 2026-11-02): a returning character goes straight to his last location; a house owner chooses
    -- «آخر مكان» / «بيتي». A new character always takes the selector with the towns.
    -- 1.0.15 (owner 2026-11-05): a returning character never picks a town: «آخر مكان» only, plus «بيتي» for a
    -- house owner. With direct off (the 2026-11-04 crash) the last location alone is still shown in the selector
    -- (the path that works). No valid last location: «بيتي», else the one fallback point. The grant accepts only
    -- the ids shown (Spawn.allowed).
    if selectorEnabled() and not spawnEvent and not isNew and kind ~= 'initial' then
        local last = Spawn.lastPosition(src)
        local home = Spawn.home(src)
        if last and not home and directLast() then
            spawnNow(src, last, LAST_ID, kind)
            return 'direct'
        end
        local allow, points = {}, {}
        if last then allow[#allow + 1] = LAST_ID end
        if home then allow[#allow + 1] = HOME_ID end
        if #allow == 0 then
            local _, id = fallback()
            if id then allow[1] = id; points[1] = id end
        end
        Spawn.grant(src, kind)
        grantAllow[src] = allow
        if last then last.label = Spawn.nearestLabel(last) end
        TriggerClientEvent('w_creators:client:selectSpawn', src, {
            last = last, home = home and { x = home.x, y = home.y, z = home.z, heading = home.heading } or nil,
            points = points, kind = kind,
        })
        return 'selector'
    end
    if selectorEnabled() and not spawnEvent then
        Spawn.grant(src, kind)
        local last = (not isNew) and Spawn.lastPosition(src) or nil
        if last then last.label = Spawn.nearestLabel(last) end
        TriggerClientEvent('w_creators:client:selectSpawn', src, { last = last, points = Spawn.pointIds(), kind = kind })
        return 'selector'
    end

    if spawnEvent then
        Spawn.cancel(src)
        toWorld(src)
        TriggerClientEvent(spawnEvent, src)
        logSpawn(src, kind, 'event')
        return 'event'
    end

    if isNew then
        spawnNow(src, firstSpawn(), 'firstSpawn', kind)
    else
        local last = Spawn.lastPosition(src)
        if last then
            spawnNow(src, last, LAST_ID, kind)
        else
            local pos, id = fallback()
            spawnNow(src, pos, id, kind)
        end
    end
    return 'direct'
end

--- Kept bridge entry point: Bridge.FinishCharacter(src, isNew, kind?) = WCSpawnServer.finish.
function Bridge.FinishCharacter(source, isNew, kind)
    return Spawn.finish(source, kind, isNew)
end

local function denied(src, pointId)
    pcall(CreatorLogs.Emit, 'character_access_denied', {
        playerSource = src,
        operation = 'spawn',
        -- client text: never logged beyond the longest valid point id
        charid = tostring(pointId):sub(1, MAX_ID_LEN),
        reason = 'حدث spawnAt خارج مسار اختيار موقع الظهور',
    })
end

--- The spawn choice (§16.3). A refused choice keeps the grant.
w.callback.register('w_creators:spawn:choose', function(src, pointId)
    if not WCSecurity.rate(src, 'spawn:choose', 5, 5000) then return WCResult.fail('RATE_LIMITED') end
    if not SpawnPending[src] then
        denied(src, pointId)
        return WCResult.fail('SPAWN_NOT_PENDING')
    end
    local pos, point = Spawn.resolve(pointId, src)
    if not pos then return WCResult.fail(point) end
    if not Spawn.allowed(src, pointId) then return WCResult.fail('INVALID_SPAWN') end
    local kind = spawnNow(src, pos, point, pendingKind[src] or 'login')
    return WCResult.ok({ pos = pos, kind = kind })
end)

--- Legacy event: same resolution; an unknown id or a missing saved position spawns at the first
--  enabled point rather than leaving the player hanging (the event cannot answer).
RegisterNetEvent('w_creators:server:spawnAt', function(pointId)
    local src = source
    -- Rate-limited first (as the spawn:choose callback): a refused event is logged, and an
    -- ungranted client must not be able to flood the logger with it.
    if not WCSecurity.rate(src, 'spawn:choose', 5, 5000) then return end
    -- The permission is one-shot: granted in finish() and withdrawn as soon as it is used.
    if not SpawnPending[src] then
        denied(src, pointId)
        return
    end
    -- 1.0.15: a returning character's id outside what he was shown -> the first id he was shown
    if not Spawn.allowed(src, pointId) then pointId = grantAllow[src][1] end
    local pos, point
    if pointId then pos, point = Spawn.resolve(pointId, src) end
    if not pos then pos, point = fallback() end
    spawnNow(src, pos, point, pendingKind[src] or 'login')
end)

--- The client handed back an in-world selector it cancelled (or refused while the death system
--  holds the player): its one-shot 'admin' grant is withdrawn. A login-kind or death grant is never
--  withdrawn from here (the character scene / the death flow own them).
RegisterNetEvent('w_creators:server:spawnCancel', function()
    local src = source
    if not WCSecurity.rate(src, 'spawn:cancel', 5, 5000) then return end
    if Spawn.pending(src) == 'admin' then
        Spawn.cancel(src)
        WCDebug.log('spawn', 'the admin spawn grant of %s was handed back', tostring(src))
    end
end)

--- Move a player who is already in the world to a spawn point (admin respawn, RespawnPlayer export).
--  pointId nil = the first enabled point; '__last' = the last location (§11 validation).
--  The client event w_creators:client:respawn(pos, { kind, point }) performs the move.
--  extra (optional) = additional fields of the character_spawned log (e.g. { adminSource }).
function Spawn.respawn(src, pointId, kind, extra)
    src = tonumber(src)
    if not src or not GetPlayerName(src) then return WCResult.fail('INVALID_PAYLOAD') end
    kind = Spawn.KINDS[kind] and kind or 'admin'
    local active = WCSessions and WCSessions.activeCharacter(src)
    if not active then return WCResult.fail('NO_CHARACTER') end
    -- a dead / downed player or one in a hospital bed belongs to the death system
    if kind == 'admin' and Spawn.heldByDeathOwner(src) then return WCResult.fail('BUSY') end
    -- A pending login grant belongs to the character scene, where the client ignores world
    -- respawns: refused. An in-world grant ('admin' / 'death' spawn selector) is withdrawn: the
    -- client respawn closes that selector without a spawn:choose, and a grant left behind would
    -- let the client move itself later and keep OpenSpawnSelector BUSY.
    local pendingNow = Spawn.pending(src)
    if pendingNow and not IN_WORLD[pendingNow] then return WCResult.fail('BUSY') end
    local pos, point
    if pointId == nil then
        pos, point = fallback()
    else
        pos, point = Spawn.resolve(pointId, src)
        if not pos then return WCResult.fail(point) end
    end
    if pendingNow then Spawn.cancel(src) end
    TriggerClientEvent('w_creators:client:respawn', src, pos, { kind = kind, point = point })
    logSpawn(src, kind, point, type(extra) == 'table' and extra or nil)
    return WCResult.ok({ pos = pos, kind = kind, point = point })
end
