-- =====================================================================
--  server/clothing/states.lua  —  runtime clothing states (ARCHITECTURE.md §5.5, §16.5)
--  Callback w_creators:clothing:setState(group, value) -> { states }
--    service clothingActions (ACTIONS_DISABLED), rate limited (12 / 10 s), the group and value exist
--    (STATE_NOT_SUPPORTED), the group applies to the saved appearance's equipped items
--    (STATE_NOT_APPLICABLE). A persisting group is written into app.clothing.states (one save);
--    every change is broadcast as w_creators:client:remoteClothingState. A state never removes an
--    owned or equipped item.
--  Non-persisting states (e.g. the bandana) live only in memory for the player's current character.
--
--    WCClothingActions.setState(src, group, value)  -> Result { states }
--    WCClothingActions.states(src, app?, charid?)   the current states (saved + runtime)
--    WCClothingActions.forget(src)                  drop the runtime states
-- =====================================================================

WCClothingActions = {}
local Actions = WCClothingActions

local RATE_KEY, RATE_MAX, RATE_WINDOW = 'clothing:setState', 12, 10000
local MAX_ID = 32

local runtime = {} -- [src] = { charid, states = { [group] = value } }

local function fail(code, data) return WCResult.fail(code, data) end

local function enabled()
    return WCClothingStates.enabled()
end

local function runtimeOf(src, charid)
    src = tonumber(src) or src
    local entry = runtime[src]
    if entry and entry.charid ~= charid then
        runtime[src] = nil
        entry = nil
    end
    return entry
end

-- The player's open session when it still counts: a commit is running, or it has not expired.
local function liveSession(src)
    local cur = WCSessions.current(src)
    if not cur then return nil end
    if cur.busy or (tonumber(cur.expires) or 0) > os.time() then return cur end
    return nil
end

--- The current states of the player: the saved (persisting) states plus the runtime ones.
function Actions.states(src, app, charid)
    local out = {}
    local saved = type(app) == 'table' and type(app.clothing) == 'table' and app.clothing.states or {}
    for group, value in pairs(type(saved) == 'table' and saved or {}) do out[group] = value end
    local entry = charid and runtimeOf(src, charid) or runtime[tonumber(src) or src]
    for group, value in pairs(entry and entry.states or {}) do out[group] = value end
    return out
end

--- The player state bag other resources read for a raised bandana (Config.ClothingStates.bandanaStateBag).
local function bandanaBag()
    local name = Config.ClothingStates and Config.ClothingStates.bandanaStateBag
    return type(name) == 'string' and name ~= '' and name or nil
end

--- Publish whether the player's face is covered by the bandana: a replicated player state bag, so
--  a wanted or police resource can read it without asking this one. Only a change is written.
local function publishBandana(src, up)
    local bag = bandanaBag()
    if not bag then return end
    local ok, err = pcall(function()
        local state = Player(src).state
        if (state[bag] == true) ~= (up == true) then state:set(bag, up == true, true) end
    end)
    if not ok then WCDebug.log('clothing', 'bandana state bag of %s: %s', tostring(src), tostring(err)) end
end

--- Is the player's bandana raised (the runtime state of the current character)?
function Actions.bandanaUp(src)
    local entry = runtime[tonumber(src) or src]
    return entry ~= nil and entry.states.bandana == 'up'
end

--- Forget the runtime states of a player (disconnect, character change, new appearance).
function Actions.forget(src)
    local key = tonumber(src) or src
    local had = runtime[key] ~= nil and runtime[key].states.bandana == 'up'
    runtime[key] = nil
    if had then publishBandana(key, false) end
end

local function persist(src, charid, group, value)
    local owner = ('state:%s:%s'):format(tostring(src), group)
    if not WCSessions.lockCharacter(charid, owner) then return nil, 'BUSY' end
    local ok, app, code = pcall(function()
        local saved, meta = WCAppearanceRepo.load(charid)
        if not saved then return nil, type(meta) == 'table' and meta.error or 'CHARACTER_NOT_FOUND' end
        if not WCClothingStates.applicable(saved, group) then return nil, 'STATE_NOT_APPLICABLE' end
        if WCClothingStates.current(saved, group) == value then return saved end
        saved.clothing.states[group] = value
        local saveOk, result = WCAppearanceRepo.save(charid, saved)
        if not saveOk then return nil, result or 'DATABASE_ERROR' end
        return result, 'saved'
    end)
    WCSessions.unlockCharacter(charid, owner)
    if not ok then
        WCDebug.warn('clothing', 'persisting state %s for %s failed: %s', group, tostring(charid), tostring(app))
        return nil, 'INTERNAL_ERROR'
    end
    return app, code
end

--- Set one clothing state of the player's active character. Result { states }.
function Actions.setState(src, group, value)
    if not WCSecurity.rate(src, RATE_KEY, RATE_MAX, RATE_WINDOW) then return fail('RATE_LIMITED') end
    if not enabled() then return fail('ACTIONS_DISABLED') end
    if type(group) ~= 'string' or type(value) ~= 'string' or #group > MAX_ID or #value > MAX_ID then
        return fail('STATE_NOT_SUPPORTED')
    end
    if not WCClothingStates.isValid(group, value) then return fail('STATE_NOT_SUPPORTED') end
    local active = WCSessions.activeCharacter(src)
    if not active then return fail('NO_CHARACTER') end
    -- A live editor session renders its own working copy; a commit in flight owns the appearance.
    -- An expired session that was not swept yet (or one left behind) does not block.
    if liveSession(src) or CreatorAppearanceLocks[active.charid] then return fail('BUSY') end

    local def = WCClothingStates.byId[group]
    local app, code
    if def.persist then
        app, code = persist(src, active.charid, group, value)
        if not app then return fail(code) end
        local entry = runtimeOf(src, active.charid)
        if entry then entry.states[group] = nil end
    else
        local meta
        app, meta = WCAppearanceRepo.load(active.charid)
        if not app then return fail(type(meta) == 'table' and meta.error or 'CHARACTER_NOT_FOUND') end
        if not WCClothingStates.applicable(app, group) then return fail('STATE_NOT_APPLICABLE') end
        local entry = runtimeOf(src, active.charid)
        if not entry then
            entry = { charid = active.charid, states = {} }
            runtime[tonumber(src) or src] = entry
        end
        entry.states[group] = value
        if group == 'bandana' then publishBandana(tonumber(src) or src, value == 'up') end
    end

    WCSync.broadcastState(src, group, value)
    if code == 'saved' then
        TriggerEvent('w_creators:server:appearanceChanged', src, active.charid, 'clothingState')
    end
    WCDebug.log('clothing', '%s set %s = %s', tostring(src), group, value)
    return WCResult.ok({ states = Actions.states(src, app, active.charid) })
end

w.callback.register('w_creators:clothing:setState', function(src, group, value)
    return Actions.setState(src, group, value)
end)

AddEventHandler('w_creators:server:appearanceChanged', function(src, _, kind)
    if kind ~= 'clothingState' and src ~= nil then Actions.forget(src) end
end)

-- A character change (switch, any clear): the leaving character's runtime states go with it, so a
-- raised bandana never comes back on its own when the same character is picked again.
AddEventHandler('w_creators:server:characterCleared', function(src)
    if src ~= nil then Actions.forget(tonumber(src) or src) end
end)

AddEventHandler('playerDropped', function()
    Actions.forget(tonumber(source) or source)
end)
