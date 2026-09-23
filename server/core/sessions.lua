-- =====================================================================
--  server/core/sessions.lua  —  WCSessions (ARCHITECTURE.md §3.3, §9.3)
--  The one server-side preview transaction for store | wardrobe | barber | surgery.
--    open   -> validates service, character, location, proximity, locks; snapshots the saved
--              appearance; returns a token.
--    commit -> serialised per character (CreatorAppearanceLocks), busy-guarded, idempotent per opId
--              (a repeated opId replays the cached Result), fn(session) runs in pcall; the session
--              closes on success.
--  Sessions expire, and are cleaned up on playerDropped and on resource stop.
-- =====================================================================

WCSessions = {}
local SS = WCSessions

--- Per-character appearance locks (shared with every appearance writer): [charid] = owner.
--  Take and release them through WCSessions.lockCharacter / unlockCharacter so a writer only ever
--  releases the lock it holds.
CreatorAppearanceLocks = CreatorAppearanceLocks or {}

local sessions = {}   -- [src] = session
local opening = {}    -- [src] = true while open() waits for the saved appearance
local replays = {}    -- [src] = { [opId] = { result, at } }
local closeHooks = {}
local counter = 0

local REPLAY_MS = 120000
local MAX_OP_ID = 64
local DEFAULT_TTL = 1800 -- seconds

-- kind -> service, location type, remote permission, lifetime
SS.KINDS = {
    store    = { service = 'clothingStores', locationType = 'clothing' },
    wardrobe = { service = 'wardrobe', locationType = 'wardrobe',
                 remote = function() return Config.Wardrobe.allowRemote == true end },
    barber   = { service = 'barbers', locationType = 'barber' },
    surgery  = { service = 'surgery', locationType = 'surgery',
                 ttl = function() return (tonumber(Config.CosmeticSurgery.sessionMinutes) or 20) * 60 end },
}

--- The active character of a player: { charid, sex? } or nil. WCCharacters when present,
--  otherwise the framework bridge.
function SS.activeCharacter(src)
    if type(WCCharacters) == 'table' and type(WCCharacters.active) == 'function' then
        local ok, active = pcall(WCCharacters.active, src)
        if ok and type(active) == 'table' and active.charid then
            return { charid = tostring(active.charid), sex = active.sex }
        end
        return nil
    end
    local ok, charid = pcall(Bridge.GetCharId, src)
    if ok and charid then return { charid = tostring(charid) } end
    return nil
end

local function now() return os.time() end

--- Take the per-character appearance lock for `owner` (any unique non-nil value, e.g.
--  'grooming:' .. charid). Returns true when taken, false when another owner holds it.
function SS.lockCharacter(charid, owner)
    if charid == nil or owner == nil or owner == false then return false end
    charid = tostring(charid)
    if CreatorAppearanceLocks[charid] then return false end
    CreatorAppearanceLocks[charid] = owner
    return true
end

--- Release the per-character lock, only when `owner` holds it. Returns true when released.
function SS.unlockCharacter(charid, owner)
    if charid == nil or owner == nil then return false end
    charid = tostring(charid)
    if CreatorAppearanceLocks[charid] ~= owner then return false end
    CreatorAppearanceLocks[charid] = nil
    return true
end

local function fail(code, data) return WCResult.fail(code, data) end

--- Register fn(session, reason) called whenever a session closes ('commit'|'close'|'expired'|
--  'dropped'|'stopped'|'character').
function SS.onClose(fn)
    closeHooks[#closeHooks + 1] = fn
end

local function finish(src, reason)
    local s = sessions[src]
    if not s then return end
    sessions[src] = nil
    for _, fn in ipairs(closeHooks) do
        local ok, err = pcall(fn, s, reason)
        if not ok then WCDebug.warn('sessions', 'close hook failed: %s', tostring(err)) end
    end
end

local function expired(s)
    return s.expires <= now()
end

local function withinRange(src, loc)
    local radius = (tonumber(loc.interactionRadius) or 2.0) + 3.0
    if WCSecurity.near(src, WCLocations.anchor(loc), radius) then return true end
    return loc.preview ~= nil and WCSecurity.near(src, loc.preview, radius)
end

--- Open a session. opts = { locationId?, remote? }.
--  Result: ok({ token, session }) or INVALID_PAYLOAD | RATE_LIMITED | *_DISABLED | NO_CHARACTER |
--  BUSY | LOCATION_NOT_FOUND | LOCATION_DISABLED | TOO_FAR | CHARACTER_NOT_FOUND | DATABASE_ERROR.
function SS.open(src, kind, opts)
    opts = type(opts) == 'table' and opts or {}
    local def = SS.KINDS[kind]
    if not def then return fail('INVALID_PAYLOAD') end
    if not WCSecurity.rate(src, 'session:open', 5, 10000) then return fail('RATE_LIMITED') end
    if not WCServices.enabled(def.service) then return fail(WCServices.code(def.service)) end

    local active = SS.activeCharacter(src)
    if not active then return fail('NO_CHARACTER') end

    if opening[src] then return fail('BUSY') end
    local current = sessions[src]
    if current then
        if expired(current) and not current.busy then finish(src, 'expired')
        else return fail('BUSY') end
    end
    if CreatorAppearanceLocks[active.charid] then return fail('BUSY') end

    local loc
    local remote = opts.remote == true and opts.locationId == nil and def.remote ~= nil and def.remote()
    if not remote then
        if type(opts.locationId) ~= 'string' then return fail('LOCATION_NOT_FOUND') end
        loc = WCLocations.byId(opts.locationId)
        if not loc or loc.type ~= def.locationType then return fail('LOCATION_NOT_FOUND') end
        if not loc.enabled or not WCLocations.isOpen(loc) then return fail('LOCATION_DISABLED') end
        if not WCLocations.isUsable(loc) then return fail(WCServices.code(def.service)) end
        if not withinRange(src, loc) then return fail('TOO_FAR') end
    end

    -- The load may yield (database): reserve the player's slot so a second open() in that window
    -- is refused, and re-check everything that can change meanwhile.
    opening[src] = true
    local ok, snapshot, meta = pcall(WCAppearanceRepo.load, active.charid)
    opening[src] = nil
    if not ok then
        WCDebug.warn('sessions', 'loading %s failed: %s', active.charid, tostring(snapshot))
        return fail('DATABASE_ERROR')
    end
    if not snapshot then
        return fail(type(meta) == 'table' and meta.error or 'CHARACTER_NOT_FOUND')
    end
    if sessions[src] or CreatorAppearanceLocks[active.charid] then return fail('BUSY') end
    local still = SS.activeCharacter(src)
    if not still or still.charid ~= active.charid then return fail('NO_CHARACTER') end

    counter = counter + 1
    local ttl = def.ttl and def.ttl() or DEFAULT_TTL
    local session = {
        token = ('%d:%d:%d:%06d'):format(src, counter, GetGameTimer(), math.random(0, 999999)),
        src = src,
        kind = kind,
        charid = active.charid,
        sex = snapshot.sex,
        location = loc,
        remote = remote,
        snapshot = snapshot,
        opened = now(),
        expires = now() + ttl,
        busy = false,
    }
    sessions[src] = session
    WCDebug.log('sessions', 'opened %s for %s (%s)', kind, tostring(src), loc and loc.id or 'remote')
    return WCResult.ok({ token = session.token, session = session })
end

--- The player's session for this token: session | nil, code (SESSION_NOT_FOUND | SESSION_EXPIRED |
--  NO_CHARACTER).
function SS.get(src, token)
    local s = sessions[src]
    if not s or type(token) ~= 'string' or s.token ~= token then return nil, 'SESSION_NOT_FOUND' end
    if expired(s) and not s.busy then
        finish(src, 'expired')
        return nil, 'SESSION_EXPIRED'
    end
    local active = SS.activeCharacter(src)
    if not active or active.charid ~= s.charid then
        if not s.busy then finish(src, 'character') end
        return nil, 'NO_CHARACTER'
    end
    return s
end

--- The player's open session (any token), or nil.
function SS.current(src)
    return sessions[src]
end

local function cacheReplay(src, opId, token, result)
    replays[src] = replays[src] or {}
    replays[src][opId] = { result = result, token = token, at = GetGameTimer() }
end

local function replayOf(src, opId, token)
    local list = replays[src]
    local entry = list and list[opId]
    if not entry then return nil end
    if GetGameTimer() - entry.at > REPLAY_MS or entry.token ~= token then
        list[opId] = nil
        return nil
    end
    return entry.result
end

--- Commit: fn(session) -> Result | value (a thrown error becomes INTERNAL_ERROR).
function SS.commit(src, token, opId, fn)
    if (type(opId) ~= 'string' and type(opId) ~= 'number') or #tostring(opId) > MAX_OP_ID
        or type(fn) ~= 'function' then
        return fail('INVALID_PAYLOAD')
    end
    opId = tostring(opId)
    local cached = replayOf(src, opId, token)
    if cached then return cached end

    local s, code = SS.get(src, token)
    if not s then return fail(code) end
    if s.busy or CreatorAppearanceLocks[s.charid] then return fail('BUSY') end
    if s.location and not withinRange(src, s.location) then return fail('TOO_FAR') end

    local owner = ('commit:%s:%s'):format(s.token, opId)
    if not SS.lockCharacter(s.charid, owner) then return fail('BUSY') end
    s.busy = true
    local ok, result = pcall(fn, s)
    SS.unlockCharacter(s.charid, owner)
    s.busy = false

    if not ok then
        WCDebug.warn('sessions', '%s commit for %s failed: %s', s.kind, tostring(src), tostring(result))
        result = fail('INTERNAL_ERROR')
    elseif not WCResult.is(result) then
        result = WCResult.ok(result)
    end
    cacheReplay(src, opId, token, result)
    if result.ok and sessions[src] == s then finish(src, 'commit') end
    return result
end

--- Close a session (not while a commit is running). Returns true when closed.
function SS.close(src, token)
    local s = sessions[src]
    if not s or s.token ~= token or s.busy then return false end
    finish(src, 'close')
    return true
end

--- Drop everything a player holds (disconnect). A commit still running keeps its character lock
--  and releases it itself when it finishes (the session is only detached here).
function SS.clear(src, reason)
    finish(src, reason or 'dropped')
    opening[src] = nil
    replays[src] = nil
end

AddEventHandler('playerDropped', function()
    SS.clear(source, 'dropped')
end)

AddEventHandler('onResourceStop', function(resource)
    if resource ~= GetCurrentResourceName() then return end
    for src in pairs(sessions) do SS.clear(src, 'stopped') end
end)

CreateThread(function()
    while true do
        Wait(30000)
        for src, s in pairs(sessions) do
            if expired(s) and not s.busy then finish(src, 'expired') end
        end
        local t = GetGameTimer()
        for src, list in pairs(replays) do
            for opId, entry in pairs(list) do
                if t - entry.at > REPLAY_MS then list[opId] = nil end
            end
            if next(list) == nil then replays[src] = nil end
        end
    end
end)
