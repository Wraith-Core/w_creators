-- =====================================================================
--  server/core/security.lua  —  WCSecurity (ARCHITECTURE.md §14)
--  Rate limiting, payload size caps, named locks, proximity and violation reporting. Every net
--  event / callback of the resource goes through these before touching state.
-- =====================================================================

WCSecurity = {}
local Sec = WCSecurity

local buckets = {}  -- [src] = { [key] = { timestamps... } }
local locks = {}    -- [key] = expiresAt (GetGameTimer ms)

local DEFAULT_LOCK_MS = 30000

--- Sliding-window rate limit: true when this call is allowed (at most `max` calls per `windowMs`).
function Sec.rate(src, key, max, windowMs)
    src = tonumber(src)
    if not src then return false end
    max = tonumber(max) or 1
    windowMs = tonumber(windowMs) or 1000
    local now = GetGameTimer()
    buckets[src] = buckets[src] or {}
    local list = buckets[src][key] or {}
    local kept = {}
    for _, t in ipairs(list) do
        if now - t < windowMs then kept[#kept + 1] = t end
    end
    if #kept >= max then
        buckets[src][key] = kept
        return false
    end
    kept[#kept + 1] = now
    buckets[src][key] = kept
    return true
end

--- Is the value encodable and at most maxBytes as JSON?
function Sec.payload(value, maxBytes)
    return WCUtil.jsonSize(value) <= (tonumber(maxBytes) or 0)
end

--- Take a named lock. false when it is held (a lock older than ttlMs is considered abandoned).
function Sec.lock(key, ttlMs)
    if key == nil then return false end
    local now = GetGameTimer()
    local expires = locks[key]
    if expires and expires > now then return false end
    locks[key] = now + (tonumber(ttlMs) or DEFAULT_LOCK_MS)
    return true
end

--- Release a named lock.
function Sec.unlock(key)
    if key ~= nil then locks[key] = nil end
end

--- Is the named lock currently held?
function Sec.locked(key)
    local expires = key ~= nil and locks[key]
    return expires ~= nil and expires ~= false and expires > GetGameTimer()
end

--- Report a request no legitimate client sends (logged as security_violation).
function Sec.violation(src, kind, detail)
    WCDebug.warn('security', 'violation by %s: %s %s', tostring(src), tostring(kind),
        type(detail) == 'table' and (WCUtil.encode(detail) or '') or tostring(detail or ''))
    CreatorLogs.Emit('security_violation', {
        playerSource = tonumber(src),
        kind = tostring(kind),
        detail = type(detail) == 'table' and WCUtil.copy(detail) or tostring(detail or ''),
        reason = tostring(kind),
    })
end

--- Is the player's ped within `radius` metres of `coords` (vector3/vector4/{x,y,z})?
function Sec.near(src, coords, radius)
    local ped = GetPlayerPed(src)
    if not ped or ped == 0 or not DoesEntityExist(ped) then return false end
    local d2 = WCUtil.dist2(GetEntityCoords(ped), coords)
    radius = tonumber(radius) or 0
    return d2 ~= nil and d2 <= radius * radius
end

--- Forget a player's rate-limit history.
function Sec.clear(src)
    buckets[tonumber(src) or src] = nil
end

AddEventHandler('playerDropped', function()
    Sec.clear(source)
end)
