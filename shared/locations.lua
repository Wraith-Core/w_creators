-- =====================================================================
--  shared/locations.lua  —  WCLocations (ARCHITECTURE.md §7.2)
--  Config.Locations merged with Config.LocationDefaults[type], resolved once and validated:
--  a location with a missing/duplicate id, an unknown type or missing coords is skipped with a
--  warning. Opening hours (hours = { open, close }, whole hours 0..24) are evaluated in the
--  server's local time (WCLocations.hour); invalid hours are ignored with a warning.
-- =====================================================================

WCLocations = {}

local resolved, byId, byType

local TYPES = { clothing = true, barber = true, surgery = true, wardrobe = true }

local function merge(defaults, loc)
    local out = WCUtil.copy(defaults or {})
    for k, v in pairs(loc) do out[k] = WCUtil.copy(v) end
    -- Config values are kept as given (vectors stay vectors)
    out.coords, out.preview = loc.coords, loc.preview
    if loc.npc ~= nil then out.npc = loc.npc end
    return out
end

local function resolve()
    if resolved then return end
    resolved, byId, byType = {}, {}, {}
    for t in pairs(TYPES) do byType[t] = {} end
    local defaults = (Config and Config.LocationDefaults) or {}
    for index, loc in ipairs((Config and Config.Locations) or {}) do
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
--  clock). The client uses the same rule; the server decides.
function WCLocations.hour()
    local t = os.date('*t')
    return type(t) == 'table' and tonumber(t.hour) or 0
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
