-- Canonical multiplayer appearance rendering through w_lib.
-- data/appearance.lua resolves legacy indices; this file applies stable component hashes.

--- The list of waist type hashes (the weight) in the order shown in the interface.
WAIST_TYPES = {
    -2045421226, -1745814259, -325933489, -1065791927, -844699484,
    -1273449080, 927185840, 149872391, 399015098, -644349862,
    1745919061, 1004225511, 1278600348, 502499352, -2093198664,
    -1837436619, 1736416063, 2040610690, -1173634986, -867801909,
    1960266524
}

--- The body expressions (RDR2): the arm, the waist, the hip, the chest, the shoulder, the leg, the neck.
--  The hashes live in w_lib (w.component.data.expressions), so they are not repeated here.
--  Values use the same -1.0..1.0 range throughout the editor and storage.

--- Is this id a body expression? It returns the hash or nil.
function BodyExpressionHash(name)
    local tbl = w and w.component and w.component.data and w.component.data.expressions
    if type(tbl) ~= 'table' then return nil end
    return tbl[name]
end

--- Reapplying every saved expression (after switching the model or restoring an appearance).
function ApplyBodyExpressions(ped, stored)
    local src = stored or {}
    if type(src) ~= 'table' then return end
    for name, percent in pairs(src) do
        local hash = BodyExpressionHash(name)
        if hash then SetCharExpression(ped, hash, (tonumber(percent) or 0.0) + 0.0) end
    end
end

--- Setting the character's scale (height).
--  Not named SetPedScale: that shadows the native and recurses endlessly.
function ApplyPedScale(ped, num)
    num = tonumber(num)
    if num == nil or num == 0 then
        num = 1.0
    end
    -- Lua/JSON can supply integer 1. RedM's native needs a float: integer bits
    -- here collapse every bone to the origin even though the ped reports ready.
    SetPedScale(ped, num + 0.0)
end

--- Applying the appearance layers (overlays) to the character through w.pedTexture.
--  It accepts data either as a JSON string or as a table (the saved list of interface choices).
function SetPedOverlay(ped, data)
    local overlay
    if type(data) == "string" then
        local ok, decoded = pcall(json.decode, data)
        if not ok then
            w.print.error('could not decode the overlay JSON: %s', tostring(decoded))
            return
        end
        overlay = decoded
    elseif type(data) == "table" then
        overlay = data
    else
        w.print.error('overlay data must be a string or a table')
        return
    end

    if not ApplyOverlaySetViaLibrary(ped, overlay) then
        w.print.warn('the overlays could not be applied to ped %s (not networked?)', tostring(ped))
    end
end

--- Applying one component hash to a ped through the library.
--  The category is derived from the hash itself (w.component.apply does it too); a hash the
--  engine does not know is skipped with a message instead of an error.
---@param ped integer
---@param hash integer|string
---@param category? integer|string the category when it is already known
---@return boolean
function ApplyComponentHash(ped, hash, category)
    hash = tonumber(hash) or hash
    if not hash or hash == 0 then return false end

    local okCat, catHash = pcall(w.component.getComponentCategory, ped, hash)
    if not okCat or not catHash or catHash == 0 then
        w.print.debug('unknown component hash %s', tostring(hash))
        return false
    end

    local ok, err = pcall(w.component.apply, ped, category or catHash, hash)
    if not ok then
        w.print.error('could not apply component %s: %s', tostring(hash), tostring(err))
        return false
    end
    return true
end

--- Removing a category from a ped through the library.
function RemoveComponentCategory(ped, category)
    pcall(w.component.remove, ped, category)
end

-- Every preview, spawn and editor applies this same ordered snapshot.
local appliedFeatures = {}
function SetSkin(ped, components)
    local sex = GetEntityModel(ped) == GetHashKey('mp_female') and 'female' or 'male'
    local app = CreatorAppearance.normalize({isMale = sex == 'male', components = components})
    -- A preset first establishes valid drawable slots; it must never run after the saved face.
    EquipMetaPedOutfitPreset(ped, 3)
    NativeUpdatePedVariation(ped)
    w.component.waitPedLoaded(ped)
    w.component.removeAllClothes(ped)
    for _, category in ipairs({'masks', 'hair', 'mustache'}) do
        RemoveComponentCategory(ped, category == 'mustache' and 0xF8016BCA or category)
    end
    local ordered = {'BODIES_LOWER', 'BODIES_UPPER', 'heads', 'eyes', 'teeth', 'hair', 'mustache'}
    local body = {}; for _, category in ipairs(ordered) do body[category] = true end
    local clothes = {}
    for category in pairs(app.components) do
        if not body[category] and category:sub(1,2) ~= '__' then clothes[#clothes+1] = category end
    end
    table.sort(clothes)
    for _, category in ipairs(clothes) do ordered[#ordered+1] = category end
    for _, category in ipairs(ordered) do
        local hash = app.components[category]
        if hash and hash ~= 0 then ApplyComponentHash(ped, hash, category == 'mustache' and 0xF8016BCA or category) end
    end
    ApplyPedScale(ped, app.components.__scale)
    w.component.setWaistType(ped, WAIST_TYPES[app.components.__waist])
    -- Reset known expression channels before applying this character's values.
    for _, hash in pairs(w.component.data.expressions) do SetCharExpression(ped, hash, 0.0) end
    ApplyBodyExpressions(ped, app.components.__expressions)
    w.component.refreshPed(ped)
    w.component.waitPedLoaded(ped)
    return app
end

function SetPedFaceFeature(ped, data)
    local features = CreatorAppearance.decode(data)
    for hash in pairs(appliedFeatures[ped] or {}) do NativeSetPedFaceFeature(ped, hash, 0.0) end
    appliedFeatures[ped] = {}
    for _, feature in pairs(features) do
        if type(feature) == 'table' and tonumber(feature.hash) then
            local hash = tonumber(feature.hash)
            NativeSetPedFaceFeature(ped, hash, CreatorAppearance.number(feature.index, -1, 1, 0))
            appliedFeatures[ped][hash] = true
        end
    end
    NativeUpdatePedVariation(ped)
end

function ApplyCreatorAppearance(ped, raw)
    local app = CreatorAppearance.normalize(raw)
    SetSkin(ped, app.components)
    SetPedFaceFeature(ped, app.faceFeatures)
    SetPedOverlay(ped, app.overlays)
    if w and w.pedTexture and w.pedTexture.refreshNow then
        pcall(w.pedTexture.refreshNow, ped)
    end
    NativeUpdatePedVariation(ped)
    return app
end

-- Incremental previews preserve the established head and drawable slots.
function UpdateCreatorAppearance(ped, previous, current)
    for _,category in ipairs({'heads','BODIES_UPPER','BODIES_LOWER'}) do
        if previous.components[category]~=current.components[category] then
            return ApplyCreatorAppearance(ped,current)
        end
    end
    local removals, additions = {}, {}
    local categories={}
    for category in pairs(previous.components) do categories[category]=true end
    for category in pairs(current.components) do categories[category]=true end
    for category in pairs(categories) do
        local hash=current.components[category] or 0
        if category:sub(1,2)~='__' and hash~=previous.components[category] then
            if hash==0 then removals[#removals+1]=category else additions[#additions+1]=category end
        end
    end
    table.sort(removals);table.sort(additions)
    for _,category in ipairs(removals) do RemoveComponentCategory(ped,category=='mustache' and 0xF8016BCA or category) end
    for _,category in ipairs(additions) do ApplyComponentHash(ped,current.components[category],category=='mustache' and 0xF8016BCA or category) end
    ApplyPedScale(ped,current.components.__scale)
    if current.components.__waist~=previous.components.__waist then w.component.setWaistType(ped,WAIST_TYPES[current.components.__waist]) end
    local before,after=previous.components.__expressions,current.components.__expressions
    for name in pairs(before) do if after[name]==nil then SetCharExpression(ped,BodyExpressionHash(name),0.0) end end
    ApplyBodyExpressions(ped,after)
    SetPedFaceFeature(ped,current.faceFeatures)
    if json.encode(previous.overlays)~=json.encode(current.overlays) then
        SetPedOverlay(ped,current.overlays)
        if w and w.pedTexture and w.pedTexture.refreshNow then
            pcall(w.pedTexture.refreshNow, ped)
        end
    end
    w.component.refreshPed(ped)
    w.component.waitPedLoaded(ped)
    return current
end
