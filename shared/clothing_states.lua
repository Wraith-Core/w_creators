-- =====================================================================
--  shared/clothing_states.lua  —  WCClothingStates (ARCHITECTURE.md §5.5)
--  Runtime clothing states (hat on/off, bandana up/down, sleeves rolled, ...). A state never
--  removes an owned or equipped item: 'off' only hides the component on the ped and
--  app.clothing.equipped is unchanged. Definitions come from Config.ClothingStates.groups.
-- =====================================================================

WCClothingStates = { groups = {}, byId = {} }
local CS = WCClothingStates

--- (Re)build the ordered group definitions from the config.
function CS.build()
    CS.groups, CS.byId = {}, {}
    local cfg = Config and Config.ClothingStates or {}
    for index, def in ipairs(cfg.groups or {}) do
        if type(def.id) == 'string' and type(def.values) == 'table' and #def.values > 0 then
            local group = WCUtil.copy(def)
            group.order = index
            group.valueSet = WCUtil.set(def.values)
            group.default = group.valueSet[def.default] and def.default or def.values[1]
            group.categories = def.categories or {}
            group.requires = def.requires or {}
            CS.groups[#CS.groups + 1] = group
            CS.byId[group.id] = group
        end
    end
end

--- Is `value` a valid value of the group?
function CS.isValid(groupId, value)
    local group = CS.byId[groupId]
    return group ~= nil and type(value) == 'string' and group.valueSet[value] == true
end

local function equippedOf(app)
    return type(app) == 'table' and type(app.clothing) == 'table' and type(app.clothing.equipped) == 'table'
        and app.clothing.equipped or {}
end

--- The equipped category the group acts on (the first equipped of its categories), or nil.
function CS.category(app, groupId)
    local group = CS.byId[groupId]
    if not group then return nil end
    local equipped = equippedOf(app)
    for _, category in ipairs(group.categories) do
        if equipped[category] and equipped[category] ~= 0 then return category end
    end
    return nil
end

--- Can the group act on this appearance (its category equipped and its requirement met)?
function CS.applicable(app, groupId)
    local group = CS.byId[groupId]
    if not group or not CS.category(app, groupId) then return false end
    if #group.requires == 0 then return true end
    local equipped = equippedOf(app)
    for _, category in ipairs(group.requires) do
        if equipped[category] and equipped[category] ~= 0 then return true end
    end
    return false
end

--- The group's current value (the stored state, else the default).
function CS.current(app, groupId)
    local group = CS.byId[groupId]
    if not group then return nil end
    local states = type(app) == 'table' and type(app.clothing) == 'table' and app.clothing.states or {}
    local value = type(states) == 'table' and states[groupId] or nil
    if group.valueSet[value] then return value end
    return group.default
end

--- Do the clothing actions run (Config.ClothingStates.enabled and the clothingActions service)?
--  When off, no state a client submits is persisted anywhere (wardrobe, outfits, creation): every
--  writer keeps the saved states that still apply.
function CS.enabled()
    local cfg = Config and Config.ClothingStates or {}
    return cfg.enabled ~= false and WCServices.enabled('clothingActions')
end

--- The ordered actions available now: { group, parent, label, current, targets = { values } }.
--  Empty when the clothingActions service or Config.ClothingStates is disabled.
function CS.actions(app)
    local out = {}
    if not CS.enabled() then return out end
    for _, group in ipairs(CS.groups) do
        if CS.applicable(app, group.id) then
            local current = CS.current(app, group.id)
            local targets = {}
            for _, value in ipairs(group.values) do
                if value ~= current then targets[#targets + 1] = value end
            end
            if #targets > 0 then
                out[#out + 1] = { group = group.id, parent = group.parent, label = group.label,
                                  current = current, targets = targets }
            end
        end
    end
    return out
end

CS.build()
