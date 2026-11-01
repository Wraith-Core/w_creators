-- =====================================================================
--  shared/locations.lua  —  WCLocations (ARCHITECTURE.md §7.2)
--  Config.Locations merged with Config.LocationDefaults[type], resolved once and validated:
--  a location with a missing/duplicate id, an unknown type or missing coords is skipped with a
--  warning. Opening hours (hours = { open, close }, whole hours 0..24) are evaluated in the
--  server's local time (WCLocations.hour); invalid hours are ignored with a warning.
--
--  The places are edited in game since 2026-10-19 (/servicesadmin): the server keeps them in the table
--  w_creators_locations (server/locations/store.lua) and hands the list to WCLocations.setList on both
--  sides; Config.Locations is only the first seed and the list used until the server has answered.
--  WCLocations.encode / decode turn a place into plain numbers (database JSON, network) and back.
-- =====================================================================

WCLocations = {}

local resolved, byId, byType
local list = nil -- the places from the server (WCLocations.setList); nil = Config.Locations

local TYPES = { clothing = true, barber = true, surgery = true, wardrobe = true }

local function merge(defaults, loc)
    local out = WCUtil.copy(defaults or {})
    for k, v in pairs(loc) do out[k] = WCUtil.copy(v) end
    -- Config values are kept as given (vectors stay vectors): WCUtil.copy would turn a vector4
    -- into a plain table and lose its heading field names
    out.coords, out.preview, out.book = loc.coords, loc.preview, loc.book
    if loc.npc ~= nil then out.npc = loc.npc end
    if loc.chair ~= nil then out.chair = loc.chair end
    return out
end

local function resolve()
    if resolved then return end
    resolved, byId, byType = {}, {}, {}
    for t in pairs(TYPES) do byType[t] = {} end
    local defaults = (Config and Config.LocationDefaults) or {}
    for index, loc in ipairs(list or (Config and Config.Locations) or {}) do
        local id = type(loc) == 'table' and loc.id
        if type(id) ~= 'string' or id == '' then
            WCDebug.warn('locations', 'location #%d has no id - skipped', index)
        elseif byId[id] then
            WCDebug.warn('locations', 'duplicate location id %s - skipped', id)
        elseif not TYPES[loc.type] then
            WCDebug.warn('locations', 'location %s has an unknown type %s - skipped', id, tostring(loc.type))
        elseif not WCUtil.xyz(loc.coords) then
            WCDebug.warn('locations', 'location %s has no valid coords - skipped', id)
        else
            local entry = merge(defaults[loc.type], loc)
            entry.enabled = loc.enabled ~= false
            entry.interactionRadius = WCUtil.number(entry.interactionRadius, 0.5, 50.0, 2.0)
            if entry.hours ~= nil then
                local h = type(entry.hours) == 'table' and entry.hours or {}
                local open, close = WCUtil.int(h.open, nil, nil, nil), WCUtil.int(h.close, nil, nil, nil)
                if open and close and open >= 0 and open <= 24 and close >= 0 and close <= 24 then
                    entry.hours = { open = open % 24, close = close % 24 }
                else
                    WCDebug.warn('locations', 'location %s has invalid hours - ignored', id)
                    entry.hours = nil
                end
            end
            entry.order = #resolved + 1
            resolved[#resolved + 1] = entry
            byId[id] = entry
            table.insert(byType[loc.type], entry)
        end
    end
end

--- Every valid location, in config order.
function WCLocations.all()
    resolve()
    return resolved
end

--- One location by id (enabled or not), or nil.
function WCLocations.byId(id)
    resolve()
    return byId[id]
end

--- Every location of a type (enabled and disabled).
function WCLocations.byType(locationType)
    resolve()
    return byType[locationType] or {}
end

--- The current hour (0..23) for opening hours: the server's local time (the server has no game
--  clock; WCUtil.today). The client reads the hour the server publishes; the server decides.
function WCLocations.hour()
    local t = WCUtil.today()
    return t and WCUtil.int(t.hour, 0, 23, 0) or 0
end

--- Is the location open at `hour` (default WCLocations.hour())? No hours = always open.
--  { open = 6, close = 22 } is open from 06:00 until 21:59; close < open spans midnight;
--  open == close is always open.
function WCLocations.isOpen(loc, hour)
    local hours = type(loc) == 'table' and loc.hours
    if type(hours) ~= 'table' then return true end
    local open, close = tonumber(hours.open), tonumber(hours.close)
    if not open or not close or open == close then return true end
    hour = WCUtil.int(hour, 0, 23, nil) or WCLocations.hour()
    if open < close then return hour >= open and hour < close end
    return hour >= open or hour < close
end

--- 1.0.6: why a location cannot be used now: 'LOCATION_CLOSED_HOURS' when it is switched on but outside
--  its opening hours, else 'LOCATION_DISABLED' (switched off, or gone).
function WCLocations.closedCode(loc)
    if type(loc) == 'table' and loc.enabled and not WCLocations.isOpen(loc) then return 'LOCATION_CLOSED_HOURS' end
    return 'LOCATION_DISABLED'
end

--- 1.0.6: the failure Result of a location that cannot be used now, with its opening hours when they
--  are the reason ("opens from 06:00 to 22:00").
function WCLocations.refusal(loc)
    local code = WCLocations.closedCode(loc)
    local r = WCResult.fail(code)
    if code == 'LOCATION_CLOSED_HOURS' then
        local function at(h) return ('%02d:00'):format(math.floor(tonumber(h) or 0) % 24) end
        WCResult.detail(r, 'hours', at(loc.hours.open), at(loc.hours.close))
    end
    return r
end

--- Is the location usable: enabled, open (hours) AND its service enabled?
function WCLocations.isUsable(loc)
    if type(loc) ~= 'table' or loc.enabled == false then return false end
    if not WCLocations.isOpen(loc) then return false end
    local service = WCServices.forLocationType(loc.type)
    return service ~= nil and WCServices.enabled(service)
end

--- Only the usable locations of a type (empty when the service is disabled).
function WCLocations.active(locationType)
    local out = {}
    for _, loc in ipairs(WCLocations.byType(locationType)) do
        if WCLocations.isUsable(loc) then out[#out + 1] = loc end
    end
    return out
end

--- The access rule of a location (Config.Locations[].access), cleaned:
--  { jobs = { [jobName] = minGrade }, ace = 'permission' | nil }, or nil when anyone may use it.
function WCLocations.access(loc)
    local rule = type(loc) == 'table' and loc.access
    if type(rule) ~= 'table' then return nil end
    local jobs, any = {}, false
    for name, grade in pairs(type(rule.jobs) == 'table' and rule.jobs or {}) do
        if type(name) == 'string' and name ~= '' then
            jobs[name] = WCUtil.int(grade, 0, nil, 0)
            any = true
        end
    end
    local ace = type(rule.ace) == 'string' and rule.ace ~= '' and rule.ace or nil
    if not any and not ace then return nil end
    return { jobs = jobs, ace = ace }
end

--- May a player with this job and grade use the location? `hasAce` is the answer to the rule's ACE
--  permission: true | false, or nil when it cannot be asked (the client). Returns true | false, or
--  nil when only the server can tell (an ACE rule the job does not satisfy, asked without hasAce).
---@return boolean|nil
function WCLocations.allows(loc, job, grade, hasAce)
    local rule = WCLocations.access(loc)
    if not rule then return true end
    local min = type(job) == 'string' and rule.jobs[job] or nil
    if min and (tonumber(grade) or 0) >= min then return true end
    if rule.ace then
        if hasAce == nil then return nil end
        return hasAce == true
    end
    return false
end

--- The proximity anchor of a location (vector3 when available, else { x, y, z }).
function WCLocations.anchor(loc)
    local x, y, z = WCUtil.xyz(type(loc) == 'table' and loc.coords)
    if not x then return nil end
    if vector3 then return vector3(x, y, z) end
    return { x = x, y = y, z = z }
end

--- Forget the resolved set (config reload / tests).
function WCLocations.reload()
    resolved, byId, byType = nil, nil, nil
end

--- Use these places instead of Config.Locations (decoded: the Config.Locations shape, vectors);
--  nil goes back to Config.Locations.
function WCLocations.setList(places)
    list = type(places) == 'table' and places or nil
    WCLocations.reload()
end

-- ---------------------------------------------------------------------
--  Plain form (database JSON, network): every spot is { x, y, z[, h] } with two decimals,
--  npc = { model, x, y, z, h } | false, chair = { kind = 'world' | 'prop', model, x, y, z, h }.
-- ---------------------------------------------------------------------
local SPOTS = { coords = false, preview = true, book = true }

local function round(n) return math.floor(n * 100 + 0.5) / 100 end

local function headingOf(v)
    local ok, h = pcall(function()
        if type(v) == 'table' and v.x == nil then return v[4] end
        if type(v) == 'table' and v.h ~= nil then return v.h end
        return v.w
    end)
    h = ok and tonumber(h) or nil
    if not h or not WCUtil.isFinite(h) then return 0.0 end
    return round(h % 360)
end

local function plainSpot(v, withHeading)
    local x, y, z = WCUtil.xyz(v)
    if not x then return nil end
    local out = { x = round(x), y = round(y), z = round(z) }
    if withHeading then out.h = headingOf(v) end
    return out
end

local function vectorOf(v, withHeading)
    local x, y, z = WCUtil.xyz(v)
    if not x then return nil end
    if withHeading then return vector4(x, y, z, headingOf(v)) end
    return vector3(x, y, z)
end

--- A place (Config.Locations shape) in plain form.
function WCLocations.encode(loc)
    if type(loc) ~= 'table' then return nil end
    local out = {}
    for k, v in pairs(loc) do
        if SPOTS[k] == nil and k ~= 'npc' and k ~= 'chair' then out[k] = WCUtil.copy(v) end
    end
    for k, withHeading in pairs(SPOTS) do out[k] = plainSpot(loc[k], withHeading) end
    if type(loc.npc) == 'table' then
        local spot = plainSpot(loc.npc.coords, true)
        if spot and type(loc.npc.model) == 'string' and loc.npc.model ~= '' then
            spot.model = loc.npc.model
            out.npc = spot
        else
            out.npc = false
        end
    elseif loc.npc == false then
        out.npc = false
    end
    if type(loc.chair) == 'table' then
        local spot = plainSpot(loc.chair.coords, true)
        if spot then
            spot.kind = loc.chair.kind == 'world' and 'world' or 'prop'
            spot.model = loc.chair.model
            out.chair = spot
        end
    end
    return out
end

--- A plain place back in the Config.Locations shape (vectors).
function WCLocations.decode(data)
    if type(data) ~= 'table' then return nil end
    local out = {}
    for k, v in pairs(data) do
        if SPOTS[k] == nil and k ~= 'npc' and k ~= 'chair' then out[k] = WCUtil.copy(v) end
    end
    for k, withHeading in pairs(SPOTS) do out[k] = vectorOf(data[k], withHeading) end
    if type(data.npc) == 'table' then
        local at = vectorOf(data.npc, true)
        out.npc = (at and type(data.npc.model) == 'string' and data.npc.model ~= '')
            and { model = data.npc.model, coords = at } or false
    elseif data.npc == false then
        out.npc = false
    end
    if type(data.chair) == 'table' then
        local at = vectorOf(data.chair, true)
        if at then
            out.chair = { kind = data.chair.kind == 'world' and 'world' or 'prop',
                          model = data.chair.model, coords = at }
        end
    end
    return out
end
