-- =====================================================================
--  server/locations/store.lua  —  WCPlaces: the service places, edited in game (2026-10-19)
--  The rows of w_creators_locations (migration 007 copied Config.Locations in once) are the places.
--  They are loaded after the migrations and handed to WCLocations.setList, so every server check
--  (proximity, opening, sessions) uses them at once, and sent to every client
--  (w_creators:client:locations; a client that starts later asks w_creators:locations:list).
--  The staff's board (/servicesadmin, client/services/board.lua) edits them through the callback
--  w_creators:board:action: the ACE is checked on every call and every spot must be near the staff
--  member. The clinics' interaction points are published for w_medic's surgery prompts:
--  GlobalState['w_creators:clinicPoints'] = { [clinicId] = { x, y, z } } (enabled clinics).
-- =====================================================================

WCPlaces = { loaded = false }
local P = WCPlaces

P.TABLE = 'w_creators_locations'
P.CLINIC_POINTS_KEY = 'w_creators:clinicPoints'
P.TYPES = { 'surgery' }

local TYPE_SET = { surgery = true }
local TYPE_LABELS = { surgery = 'عيادة التجميل' }
local SPOT_KINDS = { npc = true, preview = true }
local MAX_ID = 64

local BOARD = Config.Board or {}
local places = {}   -- the rows in order, plain form (WCLocations.encode)
local publishedPoints = nil -- the last GlobalState[CLINIC_POINTS_KEY] (w_medic rebuilds its prompts on a change)

local function fail(code) return { ok = false, error = code } end

local function isAdmin(src)
    if src == 0 then return false end
    local ace = Config.Admin and Config.Admin.ace
    if type(ace) ~= 'string' or ace == '' then return false end
    local done, allowed = pcall(IsPlayerAceAllowed, src, ace)
    return done and (allowed == true or allowed == 1)
end
P.isAdmin = isAdmin

local function indexOf(id)
    for i, place in ipairs(places) do
        if place.id == id then return i end
    end
    return nil
end

local function find(id)
    local i = type(id) == 'string' and indexOf(id) or nil
    return i and places[i] or nil
end

local function text(value, fallback)
    if type(value) ~= 'string' then return fallback end
    value = WCUtil.trim(value)
    if value == '' then return fallback end
    return WCUtil.clampString(value, tonumber(BOARD.labelMax) or 48)
end

local function modelName(value)
    if type(value) == 'number' and math.tointeger(value) then return math.tointeger(value) end
    if type(value) ~= 'string' or #value > 64 or not value:match('^[%w_]+$') then return nil end
    return value
end

local function finite(n)
    n = tonumber(n)
    return n ~= nil and WCUtil.isFinite(n) and n or nil
end

--- A spot the page sent: { x, y, z[, h] } with finite numbers, or nil.
local function spot(value, withHeading)
    if type(value) ~= 'table' then return nil end
    local x, y, z = finite(value.x), finite(value.y), finite(value.z)
    if not x or not y or not z then return nil end
    local out = { x = math.floor(x * 100 + 0.5) / 100, y = math.floor(y * 100 + 0.5) / 100,
                  z = math.floor(z * 100 + 0.5) / 100 }
    if withHeading then out.h = math.floor(((finite(value.h) or 0.0) % 360) * 100 + 0.5) / 100 end
    return out
end

local function actor(src)
    local name = GetPlayerName(src)
    return WCUtil.clampString(('%s (%s)'):format(tostring(name or '?'), tostring(src)), 100)
end

local function log(src, action, place, detail)
    CreatorLogs.Emit('service_place_changed', {
        playerSource = tonumber(src),
        adminAction = action,
        place = place and place.id or nil,
        placeType = place and place.type or nil,
        detail = detail,
    })
end

-- ---------------------------------------------------------------------
--  Publishing
-- ---------------------------------------------------------------------
local function decodedList()
    local out = {}
    for _, place in ipairs(places) do
        local loc = WCLocations.decode(place)
        if loc then out[#out + 1] = loc end
    end
    return out
end

--- The enabled clinics' interaction points: { [clinicId] = { x, y, z } }.
function P.clinicPoints()
    local out = {}
    for _, place in ipairs(places) do
        local c = place.type == 'surgery' and place.enabled ~= false and place.coords or nil
        if type(c) == 'table' then out[place.id] = { x = c.x, y = c.y, z = c.z } end
    end
    return out
end

--- Hand the places to everything that reads them: WCLocations (the server's checks), the clinics in
--  GlobalState (w_medic) and every client.
function P.publish()
    WCLocations.setList(decodedList())
    if type(Surgery) == 'table' and type(Surgery.publishClinics) == 'function' then pcall(Surgery.publishClinics) end
    local points = P.clinicPoints()
    if not (publishedPoints and WCUtil.deepEqual(publishedPoints, points)) then
        if pcall(function() GlobalState[P.CLINIC_POINTS_KEY] = points end) then publishedPoints = points end
    end
    TriggerClientEvent('w_creators:client:locations', -1, places)
end

--- The places in plain form (the client list), or nil before they are loaded.
function P.list()
    if not P.loaded then return nil end
    return places
end

-- ---------------------------------------------------------------------
--  Database
-- ---------------------------------------------------------------------
local SAVE_SQL = 'INSERT INTO `w_creators_locations` (`id`, `type`, `data`, `position`, `updated_by`) VALUES (?, ?, ?, ?, ?) '
    .. 'ON DUPLICATE KEY UPDATE `type` = VALUES(`type`), `data` = VALUES(`data`), `position` = VALUES(`position`), '
    .. '`updated_by` = VALUES(`updated_by`)'

local function persist(place, position, src)
    local encoded = WCUtil.encode(place)
    if not encoded then return false end
    local ok, err = pcall(w.database.query.await, SAVE_SQL, { place.id, place.type, encoded, position, actor(src) })
    if not ok then WCDebug.warn('locations', 'saving place %s failed: %s', place.id, tostring(err)) end
    return ok
end

local function remove(id)
    local ok, err = pcall(w.database.query.await, 'DELETE FROM `w_creators_locations` WHERE `id` = ?', { id })
    if not ok then WCDebug.warn('locations', 'deleting place %s failed: %s', id, tostring(err)) end
    return ok
end

--- Load the places from the database (after the migrations) and publish them. Until it succeeds the
--  places of config/locations.lua stay in use. Yields.
function P.load()
    if not WCMigrations.waitReady(60000) then
        WCDebug.warn('locations', 'migrations not ready: the places stay as in config/locations.lua')
        return false
    end
    local ok, rows = pcall(w.database.query.await,
        "SELECT `id`, `type`, `data` FROM `w_creators_locations` WHERE `type` = 'surgery' ORDER BY `position`, `id`")
    if not ok or type(rows) ~= 'table' then
        WCDebug.warn('locations', 'loading the places failed: %s', tostring(rows))
        return false
    end
    local list = {}
    for _, row in ipairs(rows) do
        local data = WCUtil.decode(row.data)
        if type(data) == 'table' and TYPE_SET[row.type] and type(row.id) == 'string' then
            data.id, data.type = row.id, row.type
            list[#list + 1] = data
        else
            WCDebug.warn('locations', 'place %s has invalid data - skipped', tostring(row.id))
        end
    end
    places = list
    P.loaded = true
    P.publish()
    return true
end

-- ---------------------------------------------------------------------
--  The board's data
-- ---------------------------------------------------------------------
local function sortedKeys(t)
    local out = {}
    for k in pairs(type(t) == 'table' and t or {}) do
        if type(k) == 'string' then out[#out + 1] = k end
    end
    table.sort(out)
    return out
end

local function defaultModel(placeType)
    local list = (BOARD.npcModels or {})[placeType]
    return type(list) == 'table' and list[1] or nil
end

local function boardPlace(place)
    local loc = WCLocations.byId(place.id)
    local out = WCUtil.copy(place)
    out.enabled = place.enabled ~= false
    out.label = type(place.label) == 'string' and place.label or ''
    out.town = type(place.town) == 'string' and place.town or ''
    out.blip = loc ~= nil and type(loc.blip) == 'table'
    out.radius = loc and loc.interactionRadius or (BOARD.radius or {}).default or 2.0
    if type(place.npc) ~= 'table' then out.npc = nil end
    out.npcModel = (type(place.npc) == 'table' and place.npc.model) or place.npcModel or defaultModel(place.type)
    out.usable = loc ~= nil and WCLocations.isUsable(loc) or false
    return out
end

--- The board's whole data (contract: ops/local/plans/creators-board-contract.md).
function P.board()
    local list, counts = {}, {}
    for _, t in ipairs(P.TYPES) do counts[t] = 0 end
    for _, place in ipairs(places) do
        list[#list + 1] = boardPlace(place)
        counts[place.type] = (counts[place.type] or 0) + 1
    end
    local types = {}
    for _, t in ipairs(P.TYPES) do types[#types + 1] = { id = t, count = counts[t] } end
    local clothing = Config.Clothing or {}
    return {
        ok = true,
        places = list,
        types = types,
        npcModels = BOARD.npcModels or {},
        chairModels = BOARD.chairModels or {},
        profiles = { store = sortedKeys(clothing.storeProfiles), pricing = sortedKeys(clothing.pricingProfiles) },
    }
end

-- ---------------------------------------------------------------------
--  Operations
-- ---------------------------------------------------------------------
local function near(src, at)
    return WCSecurity.near(src, at, tonumber(BOARD.maxDistance) or 80.0)
end

local function newId(placeType)
    for n = 1, 9999 do
        local id = ('%s_%d'):format(placeType, n)
        if not indexOf(id) and #id <= MAX_ID then return id end
    end
    return nil
end

local function blipFor(placeType, on)
    if not on then return false end
    local defaults = (Config.LocationDefaults or {})[placeType] or {}
    if type(defaults.blip) == 'table' then return nil end   -- the type's own blip
    return { sprite = (BOARD.blipSprites or {})[placeType] or 'blip_shop_tailor', label = TYPE_LABELS[placeType] }
end

local ops = {}

function ops.list() return true end

function ops.create(src, args)
    local placeType = args.type
    if not TYPE_SET[placeType] then return false, 'invalid' end
    local ped = GetPlayerPed(src)
    if not ped or ped == 0 then return false, 'invalid' end
    local id = newId(placeType)
    if not id then return false, 'invalid' end
    -- GetEntityCoords gives a vector3 (type() is 'vector3', not 'table'), so spot() refused it and every
    -- new place failed with 'invalid'
    local c = GetEntityCoords(ped)
    local at = spot({ x = c.x, y = c.y, z = c.z }, false)
    if not at then return false, 'invalid' end
    local place = { id = id, type = placeType, enabled = true, label = text(args.label, TYPE_LABELS[placeType]),
                    town = text(args.town, ''), coords = at, npc = false }
    if not persist(place, #places + 1, src) then return false, 'database_error' end
    places[#places + 1] = place
    log(src, 'create', place)
    return true, { selected = id }
end

function ops.save(src, args)
    local place = find(args.id)
    if not place then return false, 'not_found' end
    local copy = WCUtil.copy(place)
    copy.label = text(args.label, copy.label or TYPE_LABELS[copy.type])
    if args.town ~= nil then copy.town = text(args.town, '') end
    if args.enabled ~= nil then copy.enabled = args.enabled == true end
    if args.blip ~= nil then copy.blip = blipFor(copy.type, args.blip == true) end
    if args.radius ~= nil then
        local r = BOARD.radius or {}
        copy.interactionRadius = WCUtil.number(args.radius, r.min or 0.5, r.max or 10.0, r.default or 2.0)
    end
    if args.npcModel ~= nil then
        local model = modelName(args.npcModel)
        if not model then return false, 'invalid' end
        if type(copy.npc) == 'table' then copy.npc.model = model else copy.npcModel = model end
    end
    if copy.type == 'clothing' then
        local clothing = Config.Clothing or {}
        if args.storeProfile ~= nil then
            if (clothing.storeProfiles or {})[args.storeProfile] == nil then return false, 'invalid' end
            copy.storeProfile = args.storeProfile
        end
        if args.pricingProfile ~= nil then
            if (clothing.pricingProfiles or {})[args.pricingProfile] == nil then return false, 'invalid' end
            copy.pricingProfile = args.pricingProfile
        end
    end
    local i = indexOf(place.id)
    if not persist(copy, i, src) then return false, 'database_error' end
    places[i] = copy
    log(src, 'save', copy)
    return true
end

function ops.delete(src, args)
    local i = type(args.id) == 'string' and indexOf(args.id) or nil
    if not i then return false, 'not_found' end
    local place = places[i]
    if not remove(place.id) then return false, 'database_error' end
    table.remove(places, i)
    log(src, 'delete', place)
    return true
end

--- A spot set in the world (client/services/board.lua runs the editor):
--  what = 'npc'     value = { x, y, z, h } | false, at = { x, y, z } (the interaction point), model
--         'preview' | 'book'   value = { x, y, z, h }
--         'chair'   value = { x, y, z, h, kind = 'world' | 'prop', model }
function ops.spot(src, args)
    local place = find(args.id)
    if not place then return false, 'not_found' end
    local what = args.what
    local allowed = SPOT_KINDS[what]
    if not allowed or (allowed ~= true and allowed ~= place.type) then return false, 'invalid' end
    local copy = WCUtil.copy(place)
    if what == 'npc' then
        if args.at ~= nil then
            local at = spot(args.at, false)
            if not at or not near(src, at) then return false, at and 'too_far' or 'invalid' end
            copy.coords = at
        end
        if args.value == false then
            copy.npc = false
        elseif args.value ~= nil then
            local value = spot(args.value, true)
            local model = modelName(args.model) or copy.npcModel or defaultModel(copy.type)
            if not value or not model then return false, 'invalid' end
            if not near(src, value) then return false, 'too_far' end
            value.model = model
            copy.npc, copy.npcModel = value, nil
        end
    else
        local value = spot(args.value, true)
        if not value then return false, 'invalid' end
        if not near(src, value) then return false, 'too_far' end
        if what == 'chair' then
            local model = modelName(args.value.model)
            if not model then return false, 'no_chair' end
            value.kind = args.value.kind == 'world' and 'world' or 'prop'
            value.model = model
        end
        copy[what] = value
    end
    local i = indexOf(place.id)
    if not persist(copy, i, src) then return false, 'database_error' end
    places[i] = copy
    log(src, 'spot', copy, what)
    return true
end

function ops.clear(src, args)
    local place = find(args.id)
    if not place then return false, 'not_found' end
    local what = args.what
    local allowed = SPOT_KINDS[what]
    if not allowed or (allowed ~= true and allowed ~= place.type) then return false, 'invalid' end
    local copy = WCUtil.copy(place)
    if what == 'npc' then copy.npc = false else copy[what] = nil end
    local i = indexOf(place.id)
    if not persist(copy, i, src) then return false, 'database_error' end
    places[i] = copy
    log(src, 'clear', copy, what)
    return true
end

local WRITES = { create = true, save = true, delete = true, spot = true, clear = true }

--- One board call: { ok, error?, data? } (data = the whole board after the change).
function P.action(src, op, args)
    if not isAdmin(src) then return fail('forbidden') end
    if not WCSecurity.rate(src, 'board', 30, 10000) then return fail('busy') end
    local fn = type(op) == 'string' and ops[op] or nil
    if not fn then return fail('invalid') end
    if type(args) ~= 'table' then args = {} end
    if not WCSecurity.payload(args, 4096) then return fail('invalid') end
    if WRITES[op] and not P.loaded then return fail('database_error') end
    if WRITES[op] and not WCSecurity.lock('board:write', 10000) then return fail('busy') end
    local ok, done, extra = pcall(fn, src, args)
    if WRITES[op] then WCSecurity.unlock('board:write') end
    if not ok then
        WCDebug.warn('locations', 'board %s failed: %s', tostring(op), tostring(done))
        return fail('invalid')
    end
    if not done then return fail(extra or 'invalid') end
    if WRITES[op] then P.publish() end
    local data = P.board()
    if type(extra) == 'table' then
        for k, v in pairs(extra) do data[k] = v end
    end
    return { ok = true, data = data }
end

w.callback.register('w_creators:board:action', function(src, op, args)
    return P.action(src, op, args)
end)

--- The places for a client that started after the last publication (nil before they are loaded:
--  the client keeps config/locations.lua and the broadcast brings the list later).
w.callback.register('w_creators:locations:list', function(src)
    if not WCSecurity.rate(src, 'locations:list', 5, 10000) then return nil end
    return P.list()
end)

w.database.ready(function()
    CreateThread(P.load)
end)
