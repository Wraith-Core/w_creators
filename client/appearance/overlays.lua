-- =====================================================================
--  client/appearance/overlays.lua  —  Appearance.Overlays: the head texture layers
--  The 18 layers of WCOverlays (skin, makeup, eyebrows, hair, facial hair) go through
--  w.pedTexture only. w.pedTexture refuses unnetworked entities, so every ped that receives
--  layers is networked (the scene's preview peds and the player peds are).
--  The layers are built on top of each other, so the whole set of the 'heads' body part is
--  rewritten every time (a single-layer update would leave stale layers behind).
--
--  Stored shape (§5.1): app.overlays[layerId] = { style = 1..N, color = 1..64, opacity = 0..1 };
--  absent = off. Colour N is tint0 = N - 1 of the layer's palette (metaped_tint_hair for the
--  eyebrows / hair / beard layers, metaped_tint_makeup for the others), as before.
-- =====================================================================

Appearance.Overlays = {}
local O = Appearance.Overlays

--- The last set applied per ped: { [library layer] = payload }.
local applied = {}

--- Can w.pedTexture act on this ped?
local function usable(ped)
    if type(ped) ~= 'number' or ped == 0 or not DoesEntityExist(ped) then return false end
    if not NetworkGetEntityIsNetworked(ped) then return false end
    -- the export hands functions back as callable funcrefs (type 'table'): test presence only
    return w and w.pedTexture and w.pedTexture.overwriteBodyPart ~= nil
end

--- The w.pedTexture payload of one stored layer: layerName, payload (nil when not renderable).
---@param layerId string WCOverlays id (e.g. 'blush')
---@param o table { style, color, opacity }
---@param sex? string
---@return string|nil library, table|nil payload
function O.payload(layerId, o, sex)
    local layer = WCOverlays.byId[layerId]
    if not layer or type(o) ~= 'table' then return nil end
    if sex and not WCOverlays.allowed(layerId, sex) then return nil end
    local style = math.tointeger(tonumber(o.style))
    if not style or style < 1 then return nil end
    local id = layer.ids[style]
    if id == nil then return nil end
    local payload = { id = id }
    local opacity = tonumber(o.opacity)
    payload.opacity = (opacity and opacity >= 0.0 and opacity <= 1.0) and (opacity + 0.0) or 1.0
    local color = math.tointeger(tonumber(o.color))
    if color and color >= 1 then
        payload.palette = layer.palette
        payload.tint0 = color - 1
    end
    return layer.library, payload
end

--- The full layer set of an appearance: { [library layer] = payload }.
function O.build(app)
    local set = {}
    if type(app) ~= 'table' or type(app.overlays) ~= 'table' then return set end
    for _, layer in ipairs(WCOverlays.layers) do
        local library, payload = O.payload(layer.id, app.overlays[layer.id], app.sex)
        if library and payload then set[library] = payload end
    end
    return set
end

--- Rewrite the ped's head layers from the appearance. Returns true when w.pedTexture took it.
function O.apply(ped, app)
    if not usable(ped) then
        WCDebug.log('appearance', 'overlays skipped for ped %s (not networked or no w.pedTexture)', tostring(ped))
        return false
    end
    local set = O.build(app)
    applied[ped] = set
    local ok, err = pcall(function()
        w.pedTexture.overwriteBodyPart(ped, 'heads', set, true)
        if w.pedTexture.refreshNow then w.pedTexture.refreshNow(ped) end
    end)
    if not ok then WCDebug.warn('appearance', 'overlays failed on ped %s: %s', tostring(ped), tostring(err)) end
    return ok
end

--- The last set applied to a ped (a copy), or nil.
function O.applied(ped)
    return applied[ped] and WCUtil.copy(applied[ped]) or nil
end

--- Forget a ped's layers (the ped is deleted).
function O.forget(ped)
    applied[ped] = nil
end

--- Forget every ped's layers.
function O.reset()
    applied = {}
end
