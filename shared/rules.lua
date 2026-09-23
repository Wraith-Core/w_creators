-- =====================================================================
--  shared/rules.lua  —  WCRules (the clothing compatibility engine)
--  Built from Config.Clothing.rules:
--    conflicts[category] = { categories that cannot be worn with it }   (symmetric)
--    requires[category]  = { at least one of these must be equipped }
--  `equipped` is always a { [category] = u32 hash } map (app.clothing.equipped).
-- =====================================================================

WCRules = { conflicts = {}, requires = {} }
local R = WCRules

local orderIndex

local function addConflict(a, b)
    if type(a) ~= 'string' or type(b) ~= 'string' or a == b then return end
    R.conflicts[a] = R.conflicts[a] or {}
    for _, existing in ipairs(R.conflicts[a]) do
        if existing == b then return end
    end
    table.insert(R.conflicts[a], b)
end

--- (Re)build the rule tables from the config.
function R.build()
    R.conflicts, R.requires, orderIndex = {}, {}, nil
    local rules = Config and Config.Clothing and Config.Clothing.rules or {}
    for _, pair in ipairs(rules.conflicts or {}) do
        addConflict(pair[1], pair[2])
        addConflict(pair[2], pair[1])
    end
    for category, list in pairs(rules.requires or {}) do
        local copy = {}
        for _, name in ipairs(type(list) == 'table' and list or { list }) do copy[#copy + 1] = name end
        R.requires[category] = copy
    end
    for _, list in pairs(R.conflicts) do table.sort(list) end
end

-- The deterministic order used when rules must pick a winner: applyOrder, then alphabetical.
local function order()
    if orderIndex then return orderIndex end
    orderIndex = {}
    for i, category in ipairs(Config and Config.Clothing and Config.Clothing.applyOrder or {}) do
        orderIndex[category] = i
    end
    return orderIndex
end

local function sortedCategories(equipped)
    local idx = order()
    local list = {}
    for category, hash in pairs(equipped) do
        if hash and hash ~= 0 then list[#list + 1] = category end
    end
    table.sort(list, function(a, b)
        local ia, ib = idx[a] or math.huge, idx[b] or math.huge
        if ia ~= ib then return ia < ib end
        return tostring(a) < tostring(b)
    end)
    return list
end

local function satisfied(equipped, category)
    local needs = R.requires[category]
    if not needs or #needs == 0 then return true end
    for _, other in ipairs(needs) do
        local hash = equipped[other]
        if hash and hash ~= 0 then return true end
    end
    return false
end

--- Enforce the rules deterministically: a category conflicting with one kept earlier (applyOrder)
--  is dropped, then categories whose requirement is not met are dropped until stable.
--  Returns a new map and the list of violations { category, reason = 'conflict'|'requires', with }.
function R.normalize(equipped)
    local out, violations = {}, {}
    if type(equipped) ~= 'table' then return out, violations end
    for _, category in ipairs(sortedCategories(equipped)) do
        local clash
        for _, other in ipairs(R.conflicts[category] or {}) do
            if out[other] then clash = other break end
        end
        if clash then
            violations[#violations + 1] = { category = category, reason = 'conflict', with = clash }
        else
            out[category] = equipped[category]
        end
    end
    local changed = true
    while changed do
        changed = false
        for _, category in ipairs(sortedCategories(out)) do
            if not satisfied(out, category) then
                out[category] = nil
                violations[#violations + 1] = { category = category, reason = 'requires',
                                                with = R.requires[category][1] }
                changed = true
            end
        end
    end
    return out, violations
end

--- Equip (or with hash 0/nil remove) one category. The new item wins over the categories it
--  conflicts with; dependants left without a requirement are removed; an item whose own
--  requirement is not met is not equipped (it appears in removed).
--  Returns newEquipped (a copy) and the sorted list of removed categories. A non-string category
--  changes nothing.
function R.equip(equipped, category, hash)
    local out = WCUtil.copy(type(equipped) == 'table' and equipped or {})
    if type(category) ~= 'string' then return out, {} end
    local removedSet = {}
    if hash == nil or hash == 0 then
        if out[category] then removedSet[category] = true end
        out[category] = nil
    else
        out[category] = hash
        for _, other in ipairs(R.conflicts[category] or {}) do
            if out[other] then
                out[other] = nil
                removedSet[other] = true
            end
        end
    end
    local normalized = R.normalize(out)
    for name in pairs(out) do
        if not normalized[name] then removedSet[name] = true end
    end
    local removed = {}
    for name in pairs(removedSet) do removed[#removed + 1] = name end
    table.sort(removed)
    return normalized, removed
end

--- Can the player remove this category explicitly (essential body parts cannot)?
function R.canRemove(category)
    local essential = Config and Config.Clothing and Config.Clothing.essentialNotRemovable or {}
    return not essential[category]
end

R.build()
