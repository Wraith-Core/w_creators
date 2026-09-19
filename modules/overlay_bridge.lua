-- =====================================================================
--  modules/overlay_bridge.lua
--  The head layers (make-up, scars, freckles...) go through w.pedTexture. This is the only path:
--  the old manual texture pipeline is gone, so every ped that receives layers must be networked
--  (the creator's peds, the preview ped and the player peds all are).
--  The map from the interface's layer names to the library ids is in data/overlay_map.lua.
-- =====================================================================

--- The last thing applied per ped, so it can be rebuilt in full on any change.
--  w.pedTexture builds the layers on top of each other, so we pass the whole set every time
--  rather than one layer, otherwise the old layers stay stuck.
local applied = {}

--- Is w.pedTexture available and valid for this ped?
--  The library refuses unnetworked entities explicitly, so we check before the call.
local function canUsePedTexture(ped)
    if not ped or ped == 0 or not DoesEntityExist(ped) then return false end
    if not NetworkGetEntityIsNetworked(ped) then return false end
    -- the export hands functions back as callable funcrefs (type 'table'), so test presence only
    return w and w.pedTexture and w.pedTexture.overwriteBodyPart ~= nil
end

--- Converting the interface's choice into a w.pedTexture payload.
--  data = { compType, offsetModel, offsetVariation, opacity }
---@return string|nil layerName, table|false|nil payload (false = hide the layer)
function OverlayToLibrary(data)
    local entry = OverlayMap[data.compType]
    if not entry then return nil end

    local offset = tonumber(data.offsetModel) or 0
    -- 0 = hiding the layer
    if offset < 1 then return entry.layer, false end

    local id = entry.ids[offset]
    if id == nil then return nil end

    local payload = { id = id }

    local opacity = tonumber(data.opacity)
    payload.opacity = (opacity and opacity >= 0.0) and opacity or 1.0

    -- The layer's colour: the interface sends a palette index, and the library wants the palette's name and its shades
    local pal = tonumber(data.offsetVariation) or 0
    if pal >= 1 then
        payload.palette = (entry.layer == 'hair' or entry.layer == 'beard' or entry.layer == 'eyebrow')
            and 'metaped_tint_hair' or 'metaped_tint_makeup'
        payload.tint0 = pal - 1
    end

    return entry.layer, payload
end

--- Applying one interface choice to a ped, with the rest of the layers rebuilt.
--  'heads' is the skin tone message: the head component itself carries the tone (SetSkin
--  applies it), so the stored layers are only rebuilt on the new head texture.
---@return boolean done through the library?
function ApplyOverlayViaLibrary(ped, data)
    if not canUsePedTexture(ped) then return false end

    if data.compType == 'heads' then
        return pcall(w.pedTexture.refreshAll, ped)
    end

    local layer, payload = OverlayToLibrary(data)
    if not layer then return false end

    applied[ped] = applied[ped] or {}
    if payload == false then
        applied[ped][layer] = nil
    else
        applied[ped][layer] = payload
    end

    local ok = pcall(function()
        w.pedTexture.overwriteBodyPart(ped, 'heads', applied[ped], true)
    end)
    return ok
end

--- Applying one interface choice: the entry point creator/client.lua and the saved data use.
function SetOverlayData(ped, data)
    if type(data) ~= 'table' then return false end
    return ApplyOverlayViaLibrary(ped, data)
end

--- Restoring a saved set of layers (from the database) in one go.
function ApplyOverlaySetViaLibrary(ped, overlays)
    if not canUsePedTexture(ped) or type(overlays) ~= 'table' then return false end

    local set = {}
    for i = 1, #overlays do
        local item = overlays[i]
        if type(item) == 'table' then
            local layer, payload = OverlayToLibrary(item)
            if layer and payload then set[layer] = payload end
        end
    end

    applied[ped] = set
    local ok = pcall(function()
        w.pedTexture.overwriteBodyPart(ped, 'heads', set, true)
    end)
    return ok
end

--- Forgetting every ped's layers (when going back from the customisation to a fresh ped).
function ResetOverlayState()
    applied = {}
end

--- Cleanup when the ped is deleted.
function ForgetOverlays(ped)
    applied[ped] = nil
end
