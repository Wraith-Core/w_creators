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
-- An unused session (no token-bearing call seen) is replaced by a new open of the same kind after
-- this long: past the w_lib callback timeout (30 s), the client gave up on the lost open reply.
SS.REPLACE_UNUSED_MS = 35000

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
--  'dropped'|'stopped'|'character'|'replaced'|'abandoned').
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

--- Is the player at the location (its anchor or its fitting stand, interactionRadius + 3)?
SS.withinRange = withinRange

--- May the player use a location that has an access rule (Config.Locations[].access)? The job and
--  its grade come from the framework user, the ACE permission from the server itself: the client
--  only hides the prompt, this is the decision.
function SS.accessAllowed(src, loc)
    local rule = WCLocations.access(loc)
    if not rule then return true end
    local job, grade
    local okU, u = pcall(function() return w.framework:getUser(src) end)
    if okU and type(u) == 'table' then
        local okJ, j = pcall(function() return u:getJob() end)
        local okG, g = pcall(function() return u:getJobGrade() end)
        job = okJ and type(j) == 'string' and j or nil
        grade = okG and tonumber(g) or 0
    end
    local hasAce = false
    if rule.ace then
        local okA, allowed = pcall(IsPlayerAceAllowed, tostring(src), rule.ace)
        -- BOOL natives answer 1 (not true) on this runtime
        hasAce = okA and (allowed == true or allowed == 1)
    end
    return WCLocations.allows(loc, job, grade, hasAce) == true
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
        elseif current.kind == kind and not current.busy and not current.used
            and GetGameTimer() - (current.openedAt or 0) >= SS.REPLACE_UNUSED_MS then
            -- The client never used that session (its open reply was lost or timed out, so it has
            -- no token to close it with): once the client could have given up on that reply, a
            -- new open replaces it instead of answering BUSY until the TTL.
            finish(src, 'replaced')
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
        if not SS.accessAllowed(src, loc) then return fail('ACCESS_DENIED') end
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
        openedAt = GetGameTimer(),
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
    s.used = true   -- the client knows this token: a new open no longer replaces the session
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
--  opts = { kind? }: when kind is given, a session of another kind is SESSION_NOT_FOUND.
function SS.commit(src, token, opId, fn, opts)
    if (type(opId) ~= 'string' and type(opId) ~= 'number') or #tostring(opId) > MAX_OP_ID
        or type(fn) ~= 'function' then
        return fail('INVALID_PAYLOAD')
    end
    local wantKind = type(opts) == 'table' and opts.kind or nil
    opId = tostring(opId)
    local cached = replayOf(src, opId, token)
    if cached then return cached end

    local s, code = SS.get(src, token)
    if not s then return fail(code) end
    if wantKind ~= nil and s.kind ~= wantKind then return fail('SESSION_NOT_FOUND') end
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
    if sessions[src] == s then
        if result.ok then finish(src, 'commit')
        elseif s.closeRequested then finish(src, 'close') end   -- the client left meanwhile
    end
    return result
end

--- The recorded answer of a commit (read only: nothing is ever executed here), for a client that
--  gave up on an uncertain commit. Result: the cached answer; BUSY while that session's commit
--  still runs; SESSION_NOT_FOUND when no answer was recorded (the commit never ran).
function SS.result(src, token, opId)
    if type(token) ~= 'string' or (type(opId) ~= 'string' and type(opId) ~= 'number')
        or #tostring(opId) > MAX_OP_ID then
        return fail('INVALID_PAYLOAD')
    end
    local cached = replayOf(src, tostring(opId), token)
    if cached then return cached end
    local s = sessions[src]
    if s and s.token == token and s.busy then return fail('BUSY') end
    return fail('SESSION_NOT_FOUND')
end

--- Close a session. While a commit is running the close is recorded and done by that commit when
--  it fails (a successful commit closes the session anyway). Returns true when closed now.
function SS.close(src, token)
    local s = sessions[src]
    if not s or s.token ~= token then return false end
    if s.busy then
        s.closeRequested = true
        return false
    end
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

--- Forced closes the client did not ask for: tell it, so it restores its snapshot and leaves the
--  preview (§16.4 w_creators:client:sessionClosed(token, reason)). A drop has nobody to tell; a
--  commit or a client close already knows.
SS.NOTIFY_REASONS = { expired = true, stopped = true, character = true, replaced = true }

SS.onClose(function(s, reason)
    if not SS.NOTIFY_REASONS[reason] then return end
    TriggerClientEvent('w_creators:client:sessionClosed', s.src, s.token, reason)
end)

--- w_creators:session:close(token): the client left the editor (cancel, death, own cleanup).
--  Ok for any known or unknown token (idempotent); RATE_LIMITED / INVALID_PAYLOAD on abuse; a commit
--  still running keeps its session and closes it itself.
w.callback.register('w_creators:session:close', function(src, token)
    if not WCSecurity.rate(src, 'session:close', 10, 10000) then return fail('RATE_LIMITED') end
    if type(token) ~= 'string' or #token > 128 then return fail('INVALID_PAYLOAD') end
    SS.close(src, token)
    return WCResult.ok()
end)

--- w_creators:session:abandon(): the client lost the answer of its open (a reply timeout, a server
--  error, BUSY behind an earlier open of its own), so it may hold no token for a session the server
--  opened. Its session is closed only while unused (no token-bearing call seen) and no commit runs:
--  a session the client knows the token of is never closed this way. { closed }.
w.callback.register('w_creators:session:abandon', function(src)
    if not WCSecurity.rate(src, 'session:abandon', 5, 10000) then return fail('RATE_LIMITED') end
    local s = sessions[src]
    if not s or s.used or s.busy then return WCResult.ok({ closed = false }) end
    finish(src, 'abandoned')
    return WCResult.ok({ closed = true })
end)

--- w_creators:locations:access(): which of the locations with an access rule this player may use,
--  { [locationId] = boolean }. Only so the client can hide a prompt it would be refused at: every
--  open checks the rule again (SS.open).
w.callback.register('w_creators:locations:access', function(src)
    if not WCSecurity.rate(src, 'locations:access', 4, 10000) then return fail('RATE_LIMITED') end
    local out = {}
    for _, loc in ipairs(WCLocations.all()) do
        if WCLocations.access(loc) then out[loc.id] = SS.accessAllowed(src, loc) end
    end
    return WCResult.ok(out)
end)

--- w_creators:session:result(token, opId): the recorded answer of an uncertain commit (read only).
w.callback.register('w_creators:session:result', function(src, token, opId)
    if not WCSecurity.rate(src, 'session:result', 10, 10000) then return fail('RATE_LIMITED') end
    if type(token) ~= 'string' or #token > 128 then return fail('INVALID_PAYLOAD') end
    return SS.result(src, token, opId)
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

-- ---------------------------------------------------------------------
--  The server clock for the client (§7.2): the client runtime has no os library, so the server
--  publishes its local date and hour. The service prompts read the hour (opening hours;
--  WCServicePoints.HOUR_KEY), the creator the date (the date-of-birth window; WCUtil.today).
-- ---------------------------------------------------------------------
SS.HOUR_KEY = 'w_creators:hour'
SS.CLOCK_INTERVAL = 60000

local clockListeners = {}

--- Run fn() after every clock publication (the 60 s tick): what depends on the hour (the clinics
--  published for w_ambulancejob) is refreshed with it. A throwing listener is logged and skipped.
function SS.onClock(fn)
    if type(fn) == 'function' then clockListeners[#clockListeners + 1] = fn end
end

function SS.publishClock()
    local t = os.date('*t')
    if type(t) ~= 'table' then return false end
    local ok = pcall(function()
        GlobalState[SS.HOUR_KEY] = t.hour
        GlobalState[WCUtil.TODAY_KEY] = { year = t.year, month = t.month, day = t.day, hour = t.hour }
    end)
    for _, fn in ipairs(clockListeners) do
        local done, err = pcall(fn)
        if not done then WCDebug.warn('sessions', 'a clock listener failed: %s', tostring(err)) end
    end
    return ok
end

CreateThread(function()
    while true do
        SS.publishClock()
        Wait(SS.CLOCK_INTERVAL)
    end
end)
