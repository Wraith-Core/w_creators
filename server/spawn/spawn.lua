-- =====================================================================
--  server/spawn/spawn.lua  —  the spawn service (ARCHITECTURE.md §11, §16.3)
--  The spawn grant and the spawn location resolution (moved out of the framework bridge).
--  The client only ever sends a spawn point id ('__last' or a Config.Spawn.points[].id); the
--  server translates it into coordinates. No coordinate ever arrives from the client.
--
--  Last location: read from the framework and rejected when non-finite, all-zero, outside
--  Config.Spawn.bounds or within Config.Spawn.sceneExclusionRadius of the creator scene anchor;
--  a rejected last location falls back to the first enabled point (lowest order first).
--
--  Events (§16.3):
--    w_creators:client:selectSpawn  { last = {x, y, z, heading, label} | nil, points = { ids }, kind }
--    w_creators:client:spawn        (pos {x, y, z, heading}, meta {kind})
--    w_creators:spawn:choose        callback (pointId) -> Result { pos, kind }
--    w_creators:server:spawnAt      legacy net event (pointId) -> same resolution
-- =====================================================================

--- The players who are expected to pick a spawn location. The key's presence is the permission:
--  without it the spawn choice is refused, so an injected client cannot move itself to any town
--  whenever it likes.
SpawnPending = {}

local pendingKind = {} -- [src] = the spawn kind of the grant

local KINDS = { initial = true, login = true, switch = true, death = true, admin = true }
local LAST_ID = '__last'

AddEventHandler('playerDropped', function()
    SpawnPending[source] = nil
    pendingKind[source] = nil
end)

local function selectorEnabled()
    return WCServices.enabled('spawnSelector') and Config.Spawn.selector.enabled ~= false
end

local function lastLocationEnabled()
    return WCServices.enabled('lastLocation') and Config.Spawn.lastLocation.enabled ~= false
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

-- The enabled spawn points with valid coordinates, sorted by order (then config position).
local function enabledPoints()
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
local function pointIds()
    local ids = {}
    for i, pt in ipairs(enabledPoints()) do ids[i] = pt.id end
    return ids
end

-- The fallback position: the first enabled point, or firstSpawn when none is enabled.
local function fallback()
    local pt = enabledPoints()[1]
    return pt and position(pt.coords, pt.heading) or firstSpawn()
end

--- Look up an enabled spawn point by its id.
function Bridge.FindSpawnPoint(id)
    for _, pt in ipairs(Config.Spawn.points or {}) do
        if pt.id == id and pt.enabled ~= false then return pt end
    end
    return nil
end

--- Validate a last position (§11). Returns a clean { x, y, z, heading } or nil.
local function validLast(pos)
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
    local heading = tonumber(pos.heading)
    return { x = x, y = y, z = z, heading = WCUtil.isFinite(heading) and heading or 0.0 }
end

--- The character's valid last position (lastLocation service on), or nil.
local function lastPosition(src)
    if not lastLocationEnabled() then return nil end
    local ok, pos = pcall(Bridge.GetLastPosition, src)
    if not ok then return nil end
    return validLast(pos)
end

-- The locale key of the enabled spawn point nearest to a position (the region the player left).
local function nearestLabel(pos)
    local best, bestD
    for _, pt in ipairs(enabledPoints()) do
        local d = WCUtil.dist2(pos, pt.coords)
        if d and (not bestD or d < bestD) then best, bestD = pt, d end
    end
    return best and best.label or nil
end

--- The character's spawn coordinates: the last saved position when it is valid (and the service
--  is enabled), otherwise the first enabled spawn point.
function Bridge.GetSpawnCoords(source)
    return lastPosition(source) or fallback()
end

-- Consume the grant and move the player into the world.
local function spawnNow(src, pos)
    local kind = pendingKind[src] or 'login'
    SpawnPending[src] = nil
    pendingKind[src] = nil
    SetPlayerRoutingBucket(src, 0)
    TriggerClientEvent('w_creators:client:spawn', src, pos, { kind = kind })
    return kind
end

--- Finish the creation/selection: set the survival metadata, then either open the location
--  selector (the player stays in his isolated bucket until he picks) or spawn directly.
--  isNew = true for a freshly created character (it has no saved position).
--  kind (optional) = 'initial' | 'login' | 'switch' | 'death' | 'admin'; default from isNew.
function Bridge.FinishCharacter(source, isNew, kind)
    kind = KINDS[kind] and kind or (isNew and 'initial' or 'login')
    Bridge.SetSurvival(source)

    local spawnEvent = Config.Creator.spawnEvent
    if selectorEnabled() and not spawnEvent then
        SpawnPending[source] = true
        pendingKind[source] = kind
        local last = (not isNew) and lastPosition(source) or nil
        if last then last.label = nearestLabel(last) end
        TriggerClientEvent('w_creators:client:selectSpawn', source, { last = last, points = pointIds(), kind = kind })
        return
    end

    SetPlayerRoutingBucket(source, 0)

    if spawnEvent then
        TriggerClientEvent(spawnEvent, source)
        return
    end

    TriggerClientEvent('w_creators:client:spawn', source, isNew and firstSpawn() or Bridge.GetSpawnCoords(source),
        { kind = kind })
end

local function denied(src, pointId)
    CreatorLogs.Emit('character_access_denied', {
        playerSource = src,
        operation = 'spawn',
        charid = tostring(pointId),
        reason = 'حدث spawnAt خارج مسار اختيار موقع الظهور',
    })
end

--- The spawn choice (§16.3). '__last' needs the lastLocation service; an invalid last position
--  falls back to the first enabled point. Any other id must be an enabled point.
w.callback.register('w_creators:spawn:choose', function(src, pointId)
    if not WCSecurity.rate(src, 'spawn:choose', 5, 5000) then return WCResult.fail('RATE_LIMITED') end
    if not SpawnPending[src] then
        denied(src, pointId)
        return WCResult.fail('SPAWN_NOT_PENDING')
    end
    if type(pointId) ~= 'string' or #pointId > 64 then return WCResult.fail('INVALID_PAYLOAD') end

    local pos
    if pointId == LAST_ID then
        if not lastLocationEnabled() then return WCResult.fail('INVALID_SPAWN') end
        pos = lastPosition(src) or fallback()
    else
        local pt = Bridge.FindSpawnPoint(pointId)
        pos = pt and position(pt.coords, pt.heading)
        if not pos then return WCResult.fail('INVALID_SPAWN') end
    end
    local kind = spawnNow(src, pos)
    return WCResult.ok({ pos = pos, kind = kind })
end)

--- Legacy event: same resolution; an unknown id or a missing saved position spawns at the first
--  enabled point rather than leaving the player hanging (the event cannot answer).
RegisterNetEvent('w_creators:server:spawnAt', function(pointId)
    local src = source

    -- The permission is one-shot: granted in FinishCharacter and withdrawn as soon as it is used.
    if not SpawnPending[src] then
        denied(src, pointId)
        return
    end

    local pos
    if pointId == LAST_ID then
        pos = lastPosition(src)
    elseif type(pointId) == 'string' then
        local pt = Bridge.FindSpawnPoint(pointId)
        pos = pt and position(pt.coords, pt.heading)
    end

    spawnNow(src, pos or fallback())
end)
