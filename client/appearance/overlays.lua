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

--- The last set applied per ped: { [library layer] = payload }. Only live peds are kept: a remote
--  player that leaves scope and comes back is a new ped with a new handle, and the old handle's
--  set is pruned on the next apply (no entry per handle ever seen).
local applied = {}

local function prune()
    for ped in pairs(applied) do
        if not DoesEntityExist(ped) then applied[ped] = nil end
    end
end

--- Can w.pedTexture act on this ped?
local function usable(ped)
    if type(ped) ~= 'number' or ped == 0 or not DoesEntityExist(ped) then return false end
    if not NetworkGetEntityIsNetworked(ped) then return false end
    -- the export hands functions back as callable funcrefs (type 'table'): test presence only
    return w and w.pedTexture and w.pedTexture.overwriteBodyPart ~= nil
end

--- The layers w.pedTexture draws with blend type 1 (never tinted): the shared list
--  (WCOverlays.UNTINTED, shared/overlays.lua), keyed by library name.
O.UNTINTED = WCOverlays.UNTINTED

--- Does the colour of a layer show? (WCOverlays.tintable: layer.tint = false marks a layer as not
--  tintable; a table without the flag falls back to the blend-type-1 list.)
---@param layer table|string a WCOverlays layer or its id
---@return boolean
function O.tintable(layer)
    return WCOverlays.tintable(layer)
end

local function opacityOf(v)
    local opacity = tonumber(v)
    return (opacity and opacity >= 0.0 and opacity <= 1.0) and (opacity + 0.0) or 1.0
end

--- One texture of a layer: { id, opacity, sheetGrid?, sexe? } or nil when the style does not exist.
--  sheetGrid picks the design on a sheet texture (the makeup), sexe the texture set a style
--  belongs to (the eyebrows: without it w.pedTexture takes the ped's own set).
local function texturePayload(layer, style, opacity)
    local id, grid, set = WCOverlays.texture(layer, style)
    if id == nil then return nil end
    local payload = { id = id, opacity = opacityOf(opacity) }
    if grid then payload.sheetGrid = grid end
    if set then payload.sexe = set end
    return payload
end

--- The w.pedTexture payload of one stored layer: layerName, payload (nil when not renderable).
--  A layer with stacked instances (the scars' `extra`) answers a list of payloads: w.pedTexture
--  draws every entry of an array as its own texture layer.
---@param layerId string WCOverlays id (e.g. 'blush')
---@param o table { style, color, opacity, color2?, color3?, extra? }
---@param sex? string
---@return string|nil library, table|nil payload
function O.payload(layerId, o, sex)
    local layer = WCOverlays.byId[layerId]
    if not layer or type(o) ~= 'table' then return nil end
    if sex and not WCOverlays.allowed(layerId, sex) then return nil end
    local payload = texturePayload(layer, o.style, o.opacity)
    if not payload then return nil end
    local color = math.tointeger(tonumber(o.color))
    if color and color >= 1 and O.tintable(layer) then
        payload.palette = layer.palette
        payload.tint0 = color - 1
        -- the 2nd / 3rd tint of a multi-tint texture (foundation, lipstick, eyeshadow); absent = 0
        local c2, c3 = math.tointeger(tonumber(o.color2)), math.tointeger(tonumber(o.color3))
        if c2 and c2 >= 1 and (layer.tints or 1) >= 2 then payload.tint1 = c2 - 1 end
        if c3 and c3 >= 1 and (layer.tints or 1) >= 3 then payload.tint2 = c3 - 1 end
    end
    if (layer.extra or 0) > 0 and type(o.extra) == 'table' and #o.extra > 0 then
        local list = { payload }
        for i, e in ipairs(o.extra) do
            if i > layer.extra then break end
            local more = type(e) == 'table' and texturePayload(layer, e.style, e.opacity) or nil
            if more then list[#list + 1] = more end
        end
        return layer.library, list
    end
    return layer.library, payload
end

--- The eyebrows drawn in the hair's colour (overlays.eyebrows.matchHair): the hair component's
--  own palette tints, read back from the ped once the hair is on it. nil = no hair (or no tint):
--  the colour chosen in the eyebrows panel is drawn instead.
local function hairTint(ped, app)
    if type(app.hair) ~= 'table' or not app.hair.style or app.hair.style == 0 then return nil end
    if not (w and w.component and w.component.getCategoryTint) then return nil end
    local ok, tint = pcall(w.component.getCategoryTint, ped, 'hair', true)
    if not ok or type(tint) ~= 'table' then return nil end
    local t0, t1, t2 = math.tointeger(tonumber(tint.tint0)), math.tointeger(tonumber(tint.tint1)), math.tointeger(tonumber(tint.tint2))
    if not t0 then return nil end
    return { tint0 = t0, tint1 = t1 or 0, tint2 = t2 or 0 }
end
O.hairTint = hairTint

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
    local brows = type(app) == 'table' and type(app.overlays) == 'table' and app.overlays.eyebrows or nil
    local browLayer = WCOverlays.byId.eyebrows
    if type(brows) == 'table' and brows.matchHair and browLayer and type(set[browLayer.library]) == 'table' then
        local tint = hairTint(ped, app)
        if tint then
            local payload = set[browLayer.library]
            payload.palette = browLayer.palette
            payload.tint0, payload.tint1, payload.tint2 = tint.tint0, tint.tint1, tint.tint2
        end
    end
    prune()
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
