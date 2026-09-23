-- =====================================================================
--  server/api.lua  —  the public server API (ARCHITECTURE.md §13)
--  Every export is also a WCApi.<name> function (other server files and tests call those).
--
--    GetCharacterAppearance(src)          -> the active character's v3 appearance (copy) | nil
--    GetAppearance(src)                   -> { skin, clothes, appearance } for w_lib's w_core bridge
--                                            (framework-bridge standardizeSkin / standardizeClothes keys) | nil
--    SetClothes(src, clothes, overwrite)  -> Result { appearance, changed }  (catalogue-validated, persisted)
--    SetSkin(src, skin, overwrite)        -> Result { appearance, changed }
--    ApplyCharacterAppearance(src)        -> Result { appearance }  (re-sends the saved appearance)
--    OpenCosmeticSurgery({source, clinicId}) | (src, clinicId) -> Result { locationId }
--    OpenClothingStore(src, id)           -> Result { locationId }
--    OpenBarber(src, id)                  -> Result { locationId }
--    OpenWardrobe(src, id?)               -> Result { locationId }  (nil = remote, Config.Wardrobe.allowRemote)
--    OpenSpawnSelector(src)               -> Result { points, kind }   (WCSpawnServer grant + selectSpawn)
--    RespawnPlayer(src, pointId?, kind?)  -> Result { pos, kind, point } (WCSpawnServer.respawn)
--    GetActiveCharacter(src)              -> { charid, sex } | nil
--
--  The Open* exports validate the service, the location, the character and the distance, then send
--  w_creators:client:open<Kind>(locationId); the client requests the matching <kind>:open callback,
--  which validates everything again. OpenCosmeticSurgery also gives the one-shot clinic grant a
--  prompt-less clinic requires (WCSurgeryService.grant).
--  SetClothes / SetSkin validate every value against the catalogue for the character's sex (a hash
--  that is not an item of that category and sex is refused, a value out of range is refused, never
--  clamped or repaired; nothing is written), persist through WCAppearanceRepo.save, re-render the
--  owner (w_creators:client:applyAppearance) and broadcast.
-- =====================================================================

WCApi = {}
local Api = WCApi

local MAX_PAYLOAD = 64 * 1024
local MAX_ID = 64
local BUCKET_SECTIONS = { 'body', 'face', 'eyes', 'skin', 'hair', 'facialHair', 'eyebrows', 'makeup' }
local REMOVED = { [0] = true, [-1] = true }

local fail, ok = WCResult.fail, WCResult.ok
local writeCounter = 0

-- The waist type metaped outfit hashes; body.weight is the 1-based index. The shared list
-- (AppearanceSchema.WAIST_TYPES) the client renderer equips: the framework-bridge skin carries the
-- outfit hash (w.component.applySkin -> EquipMetaPedOutfit).
Api.WAIST_TYPES = AppearanceSchema.WAIST_TYPES

--- The body.weight index of a standard bodyWeight (a WAIST_TYPES outfit hash, signed or unsigned),
--  or nil when it is not one of them.
function Api.waistIndex(value)
    local hash = WCUtil.u32(value)
    if not hash then return nil end
    for index, waist in ipairs(Api.WAIST_TYPES) do
        if WCUtil.u32(waist) == hash then return index end
    end
    return nil
end

local function playerId(src)
    src = tonumber(src)
    if not src or src <= 0 or src % 1 ~= 0 then return nil end
    src = math.tointeger(src)
    if not GetPlayerName(src) then return nil end
    return src
end

local function activeOf(src)
    return src and WCSessions.activeCharacter(src) or nil
end

-- ---------------------------------------------------------------------
--  Reading
-- ---------------------------------------------------------------------

local function loadActive(src)
    local active = activeOf(src)
    if not active then return nil end
    local done, app = pcall(WCAppearanceRepo.load, active.charid)
    if not done or type(app) ~= 'table' then return nil end
    return app, active
end

--- The active character: { charid, sex } or nil.
function Api.GetActiveCharacter(src)
    src = playerId(src)
    local active = activeOf(src)
    if not active then return nil end
    local sex = active.sex
    if sex ~= 'male' and sex ~= 'female' then
        local app = loadActive(src)
        sex = app and app.sex or nil
    end
    return { charid = active.charid, sex = sex }
end

--- The active character's v3 appearance (a copy), or nil.
function Api.GetCharacterAppearance(src)
    local app = loadActive(playerId(src))
    return app and WCUtil.copy(app) or nil
end

--- The framework-bridge "standard" skin of a v3 appearance (w_lib framework-bridge keys: model,
--  headHash, bodyUpperHash, bodyLowerHash, eyesHash, teethHash, hair, beards_complete, bodyWeight,
--  bodyScale, expressions, overlays). bodyWeight is the waist outfit hash w.component.applySkin
--  equips; bodyType is left out: the body type is the BODIES_UPPER model (bodyUpperHash) and has
--  no outfit hash of its own.
function Api.standardSkin(app)
    local skin = {
        model = 'mp_' .. app.sex,
        sex = app.sex == 'male' and 1 or 2,
        headHash = app.head.head,
        bodyUpperHash = app.body.upper,
        bodyLowerHash = app.body.lower,
        eyesHash = app.head.eyes,
        teethHash = app.head.teeth,
        bodyWeight = Api.WAIST_TYPES[app.body.weight],
        bodyScale = app.body.height,
        expressions = WCUtil.copy(app.morph),
        overlays = {},
    }
    if app.hair.style ~= 0 then skin.hair = { hash = app.hair.style } end
    if app.sex == 'male' and app.hair.facial ~= 0 then skin.beards_complete = { hash = app.hair.facial } end
    for _, layer in ipairs(WCOverlays.layers) do
        local o = app.overlays[layer.id]
        local id = o and layer.ids[o.style]
        if id ~= nil and layer.sexes[app.sex] then
            skin.overlays[layer.library] = { id = id, opacity = o.opacity, palette = layer.palette, tint0 = o.color - 1 }
        end
    end
    return skin
end

--- The framework-bridge "standard" clothes of a v3 appearance: { [category] = { hash, palette?, tint0..2? } }.
function Api.standardClothes(app)
    local clothes = {}
    for category, hash in pairs(app.clothing.equipped) do
        local entry = { hash = hash }
        local tint = app.clothing.tints[category]
        if type(tint) == 'table' then
            entry.palette, entry.tint0, entry.tint1, entry.tint2 = tint.palette, tint.tint0, tint.tint1, tint.tint2
        end
        clothes[category] = entry
    end
    return clothes
end

--- w_lib w_core bridge compatibility: { skin, clothes, appearance } or nil (no active character).
function Api.GetAppearance(src)
    local app = loadActive(playerId(src))
    if not app then return nil end
    return { skin = Api.standardSkin(app), clothes = Api.standardClothes(app), appearance = WCUtil.copy(app) }
end

-- ---------------------------------------------------------------------
--  Writing
-- ---------------------------------------------------------------------

-- Run fn(active, saved) holding the character's appearance lock. The result of fn is returned.
-- fn(active, saved, meta) (meta = the repository's load meta).
local function withCharacter(src, tag, fn)
    local active = activeOf(src)
    if not active then return fail('NO_CHARACTER') end
    if WCSessions.current(src) then return fail('BUSY') end
    writeCounter = writeCounter + 1
    local owner = ('api:%s:%d'):format(tag, writeCounter)
    if not WCSessions.lockCharacter(active.charid, owner) then return fail('BUSY') end
    local done, result = pcall(function()
        local saved, meta = WCAppearanceRepo.load(active.charid)
        if not saved then return fail(type(meta) == 'table' and meta.error or 'CHARACTER_NOT_FOUND') end
        return fn(active, saved, meta)
    end)
    WCSessions.unlockCharacter(active.charid, owner)
    if not done then
        WCDebug.warn('api', '%s for %s failed: %s', tag, tostring(src), tostring(result))
        return fail('INTERNAL_ERROR')
    end
    return result
end

-- Persist a merged appearance, re-render the owner and inform everyone. Result { appearance, changed }.
-- groomingMeta (the load meta) = fold the pending in-memory growth in first (a hair / beard write:
-- the cut kind drops it, the other kind keeps it); the changed sections are the caller's only.
local function commit(src, active, saved, merged, kind, groomingMeta)
    local changes = AppearanceSchema.changedSections(saved, merged)
    if next(changes) == nil then return ok({ appearance = saved, changed = false }) end
    local folded = 0
    if groomingMeta ~= nil and WCGroomingServer then
        folded = WCGroomingServer.fold(active.charid, merged, saved, groomingMeta)
    end
    local saveOk, app = WCAppearanceRepo.save(active.charid, merged)
    if not saveOk then return fail(app or 'DATABASE_ERROR') end
    if WCGroomingServer then WCGroomingServer.consumed(active.charid, folded) end
    local sections = {}
    for _, section in ipairs(AppearanceSchema.SECTIONS) do
        if changes[section] then sections[#sections + 1] = section end
    end
    TriggerClientEvent('w_creators:client:applyAppearance', src, app)
    WCSync.broadcast(src, app)
    CreatorLogs.Emit('appearance_changed', { playerSource = src, charid = tostring(active.charid),
                                             sections = sections, kind = kind })
    TriggerEvent('w_creators:server:appearanceChanged', src, active.charid, kind)
    return ok({ appearance = app, changed = true, sections = sections })
end

local function isRemoval(value)
    if value == nil or value == false or REMOVED[value] then return true end
    if type(value) == 'table' then
        local hash = value.hash or value.comp
        if value[1] == nil and (hash == nil or hash == false or REMOVED[hash]) then return true end
    end
    return false
end

-- The palette name of a submitted palette (a name, or the hash of one of the category's palettes).
local function paletteName(category, palette)
    local names = WCCatalog.tintable(category) or {}
    if type(palette) == 'string' then
        for _, name in ipairs(names) do
            if name == palette then return name end
        end
        return nil
    end
    local hash = WCUtil.u32(tonumber(palette))
    if not hash then return nil end
    for _, name in ipairs(names) do
        if WCUtil.u32(GetHashKey(name)) == hash then return name end
    end
    return nil
end

-- A submitted tint { palette, tint0, tint1, tint2 } -> a valid tint, false (none given) or nil (invalid).
local function tintOf(category, value)
    if type(value) ~= 'table' or value.palette == nil or value.palette == 0 or value.palette == false then return false end
    local tint = {
        palette = paletteName(category, value.palette),
        tint0 = math.tointeger(tonumber(value.tint0) or 0),
        tint1 = math.tointeger(tonumber(value.tint1) or 0),
        tint2 = math.tointeger(tonumber(value.tint2) or 0),
    }
    if not tint.palette or not WCCatalog.validTint(category, tint) then return nil end
    return tint
end

local applyIndex
local function orderOf(category)
    if not applyIndex then
        applyIndex = {}
        for index, name in ipairs(Config.Clothing.applyOrder or {}) do applyIndex[name] = index end
    end
    return applyIndex[category] or math.huge
end

--- Set clothing. clothes = { [category] = hash | { hash, palette?, tint0..2? } | 0 (remove) }.
--  overwrite = true replaces the whole equipped set; otherwise the given categories are merged into
--  it. Every category must be a clothing category and every hash an item of it for the character's
--  sex (INVALID_COMPONENT / INVALID_TINT, nothing written). Items are equipped through the clothing
--  rules (the new item wins); a requested item the rules cannot keep -> CONFLICTING_ITEMS.
function Api.SetClothes(src, clothes, overwrite)
    src = playerId(src)
    if not src then return fail('INVALID_PAYLOAD') end
    if type(clothes) ~= 'table' or not WCSecurity.payload(clothes, MAX_PAYLOAD) then return fail('INVALID_PAYLOAD') end
    return withCharacter(src, 'clothes', function(active, saved)
        local sex = saved.sex
        local requests = {}
        for category, value in pairs(clothes) do
            if type(category) ~= 'string' or not WCCatalog.isClothing(category) then
                return fail('INVALID_COMPONENT', { category = tostring(category) })
            end
            if isRemoval(value) then
                requests[#requests + 1] = { category = category, hash = 0 }
            else
                local hash = WCCatalog.offered(sex, category) and WCCatalog.resolve(sex, category, value) or nil
                if not hash then return fail('INVALID_COMPONENT', { category = category }) end
                local tint = tintOf(category, value)
                if tint == nil then return fail('INVALID_TINT', { category = category }) end
                requests[#requests + 1] = { category = category, hash = hash, tint = tint }
            end
        end
        table.sort(requests, function(a, b)
            local oa, ob = orderOf(a.category), orderOf(b.category)
            if oa ~= ob then return oa < ob end
            return a.category < b.category
        end)

        local draft = WCUtil.copy(saved)
        if overwrite == true then
            draft.clothing.equipped, draft.clothing.tints = {}, {}
        end
        for _, r in ipairs(requests) do
            local previous = draft.clothing.equipped[r.category]
            local _, _, code = AppearanceSchema.equip(draft, r.category, r.hash ~= 0 and r.hash or nil)
            if code then return fail(code, { category = r.category }) end
            if r.tint then
                draft.clothing.tints[r.category] = r.tint
            elseif previous ~= r.hash then
                draft.clothing.tints[r.category] = nil
            end
        end
        local merged = AppearanceSchema.mergeSections(saved, draft, { clothing = true })
        for _, r in ipairs(requests) do
            if r.hash ~= 0 and merged.clothing.equipped[r.category] ~= r.hash then
                return fail('CONFLICTING_ITEMS', { category = r.category })
            end
        end
        if not WCUtil.deepEqual(merged.clothing.equipped, saved.clothing.equipped) then merged.clothing.outfit = nil end
        return commit(src, active, saved, merged, 'api')
    end)
end

-- A body part given as a hash or { hash = h }: u32 hash, nil (not given) or false (invalid).
local function partOf(sex, category, value)
    if value == nil then return nil end
    local hash = WCCatalog.resolve(sex, category, value)
    return hash or false
end

local function sexOfSkin(skin)
    local v = skin.model
    if v == nil then v = skin.sex end
    if v == 'mp_male' or v == 'male' or v == 1 then return 'male' end
    if v == 'mp_female' or v == 'female' or v == 2 then return 'female' end
    local hash = type(v) == 'number' and WCUtil.u32(v) or nil
    if hash and hash == WCUtil.u32(GetHashKey('mp_male')) then return 'male' end
    if hash and hash == WCUtil.u32(GetHashKey('mp_female')) then return 'female' end
    return nil
end

-- The layer of a standard overlay key (the w.pedTexture library name) or a v3 layer id.
local function layerOf(key)
    if WCOverlays.byId[key] then return WCOverlays.byId[key] end
    for _, layer in ipairs(WCOverlays.layers) do
        if layer.library == key then return layer end
    end
    return nil
end

-- An integer given exactly (5, 5.0 or "5") within [lo, hi], or nil (never clamped).
local function exactInt(v, lo, hi)
    v = tonumber(v)
    if not WCUtil.isFinite(v) or v % 1 ~= 0 then return nil end
    v = math.tointeger(v)
    if v == nil or (lo and v < lo) or (hi and v > hi) then return nil end
    return v
end

-- A standard overlay { id, tint0, opacity } (or a v3 { style, color, opacity }) -> v3 overlay,
-- false (off) or nil (invalid).
local function overlayOf(layer, value)
    if value == nil or value == false or value == 0 then return false end
    if type(value) ~= 'table' then return nil end
    local opacity = value.opacity == nil and 1.0 or WCUtil.number(value.opacity, nil, nil, nil)
    if opacity == nil then return nil end
    if opacity > 1 then opacity = opacity / 100 end
    if opacity <= 0 then return false end
    local style
    if value.style ~= nil then
        style = exactInt(value.style, 1, layer.styles)
    else
        local id = exactInt(value.id)
        for index, texture in ipairs(layer.ids) do
            if texture == id then style = index break end
        end
    end
    if not style then return nil end
    local color
    if value.color ~= nil then
        color = exactInt(value.color, 1, WCOverlays.COLORS)
    elseif value.tint0 ~= nil then
        local tint0 = exactInt(value.tint0)
        color = tint0 and exactInt(tint0 + 1, 1, WCOverlays.COLORS) or nil
    else
        color = 1
    end
    if not color then return nil end
    return { style = style, color = color, opacity = math.min(opacity, 1.0) + 0.0 }
end

-- Build the v3 draft of a standard skin over the saved appearance. draft | nil, code, detail.
local function skinDraft(saved, skin, overwrite)
    local sex = saved.sex
    local given = sexOfSkin(skin)
    if (skin.model ~= nil or skin.sex ~= nil) and given ~= sex then return nil, 'INVALID_PAYLOAD', 'sex' end
    local draft = WCUtil.copy(saved)

    for _, p in ipairs({ { 'headHash', 'heads', draft.head, 'head' }, { 'eyesHash', 'eyes', draft.head, 'eyes' },
                         { 'teethHash', 'teeth', draft.head, 'teeth' },
                         { 'bodyUpperHash', 'BODIES_UPPER', draft.body, 'upper' },
                         { 'bodyLowerHash', 'BODIES_LOWER', draft.body, 'lower' } }) do
        local hash = partOf(sex, p[2], skin[p[1]])
        if hash == false then return nil, 'INVALID_COMPONENT', p[2] end
        if hash then p[3][p[4]] = hash end
    end

    if skin.hair ~= nil then
        if isRemoval(skin.hair) then draft.hair.style = 0
        else
            local hash = partOf(sex, 'hair', skin.hair)
            if not hash then return nil, 'INVALID_COMPONENT', 'hair' end
            draft.hair.style = hash
        end
    end
    local beard = skin.beards_complete
    if beard == nil then beard = skin.mustache end
    if beard ~= nil then
        if isRemoval(beard) then draft.hair.facial = 0
        else
            local hash = sex == 'male' and partOf(sex, 'mustache', beard) or nil
            if not hash then return nil, 'INVALID_COMPONENT', 'mustache' end
            draft.hair.facial = hash
        end
    end

    if skin.bodyScale ~= nil then
        local v = skin.bodyScale
        if type(v) ~= 'number' or not WCUtil.isFinite(v) then return nil, 'INVALID_PAYLOAD', 'bodyScale' end
        draft.body.height = v
    end
    if skin.bodyWeight ~= nil then
        -- a waist outfit hash (the bridge's value), or the 1-based index itself
        local index = Api.waistIndex(skin.bodyWeight) or exactInt(skin.bodyWeight, 1, #Api.WAIST_TYPES)
        if not index then return nil, 'INVALID_PAYLOAD', 'bodyWeight' end
        draft.body.weight = index
    end
    -- bodyType (a framework body-type outfit) has no v3 counterpart: the body type is bodyUpperHash.

    if skin.expressions ~= nil then
        if type(skin.expressions) ~= 'table' then return nil, 'INVALID_PAYLOAD', 'expressions' end
        if overwrite == true then draft.morph = {} end
        for id, value in pairs(skin.expressions) do
            if not WCMorph.byId[id] then return nil, 'INVALID_PAYLOAD', 'expressions.' .. tostring(id) end
            local n = tonumber(value)
            if n == nil or not WCUtil.isFinite(n) then return nil, 'INVALID_PAYLOAD', 'expressions.' .. id end
            if n > 1 or n < -1 then n = n / 100 end -- the bridge's percent convention
            draft.morph[id] = WCUtil.number(n, -1, 1, 0)
        end
    elseif overwrite == true then
        draft.morph = {}
    end

    if skin.overlays ~= nil then
        if type(skin.overlays) ~= 'table' then return nil, 'INVALID_PAYLOAD', 'overlays' end
        if overwrite == true then draft.overlays = {} end
        for key, value in pairs(skin.overlays) do
            local layer = type(key) == 'string' and layerOf(key) or nil
            if not layer or not layer.sexes[sex] then return nil, 'INVALID_COMPONENT', 'overlay.' .. tostring(key) end
            local o = overlayOf(layer, value)
            if o == nil then return nil, 'INVALID_COMPONENT', 'overlay.' .. layer.id end
            draft.overlays[layer.id] = o or nil
        end
    elseif overwrite == true then
        draft.overlays = {}
    end
    return draft
end

-- The sanitize reports a v3 SetSkin submission may carry: a missing part keeps the saved one
-- (mergeSections), a tone repair is the schema's own; clothing is ignored by SetSkin.
local V3_TOLERATED = { missing = true, tone = true, tone_unavailable = true }
local V3_IGNORED = { 'clothing.', 'tint.', 'state.' }

-- Validate a v3 appearance submitted to SetSkin for `sex` without repairing anything: every value
-- sanitize would replace or clamp is refused. nil (valid) | code, field.
local function v3Invalid(sex, skin)
    local _, violations = AppearanceSchema.sanitize(skin, { sex = sex, rules = false, grooming = false })
    for _, v in ipairs(violations) do
        local field = tostring(v.field)
        local ignored = field == 'sex' or V3_TOLERATED[v.reason] == true
        for _, prefix in ipairs(V3_IGNORED) do
            if field:sub(1, #prefix) == prefix then ignored = true end
        end
        if not ignored then
            return field:sub(1, 6) == 'morph.' and 'INVALID_PAYLOAD' or 'INVALID_COMPONENT', field
        end
    end
    for _, key in ipairs({ 'body', 'head', 'hair', 'morph', 'overlays' }) do
        if skin[key] ~= nil and type(skin[key]) ~= 'table' then return 'INVALID_PAYLOAD', key end
    end
    local body = skin.body or {}
    if body.height ~= nil then
        local h = tonumber(body.height)
        if not WCUtil.isFinite(h) or h < 0.9 or h > 1.1 then return 'INVALID_PAYLOAD', 'body.height' end
    end
    if body.weight ~= nil and not exactInt(body.weight, 1, #Api.WAIST_TYPES) then
        return 'INVALID_PAYLOAD', 'body.weight'
    end
    for id, value in pairs(skin.morph or {}) do
        local n = tonumber(value)
        if not WCUtil.isFinite(n) or n < -1 or n > 1 then return 'INVALID_PAYLOAD', 'morph.' .. tostring(id) end
    end
    for id, o in pairs(skin.overlays or {}) do
        local layer = WCOverlays.byId[id]
        local field = 'overlay.' .. tostring(id)
        if not exactInt(o.style, 1, layer.styles) then return 'INVALID_COMPONENT', field end
        if o.color ~= nil and not exactInt(o.color, 1, WCOverlays.COLORS) then return 'INVALID_COMPONENT', field end
        if o.opacity ~= nil then
            local opacity = tonumber(o.opacity)
            if not WCUtil.isFinite(opacity) or opacity < 0 or opacity > 1 then return 'INVALID_COMPONENT', field end
        end
    end
    return nil
end

--- Set the skin (body, face, eyes, skin tone, hair, facial hair, overlays) from a framework-bridge
--  standard skin (or a v3 appearance: its non-clothing sections). overwrite = true replaces the
--  morphology and the overlays; otherwise the given values are merged. The sex never changes.
function Api.SetSkin(src, skin, overwrite)
    src = playerId(src)
    if not src then return fail('INVALID_PAYLOAD') end
    if type(skin) ~= 'table' or not WCSecurity.payload(skin, MAX_PAYLOAD) then return fail('INVALID_PAYLOAD') end
    return withCharacter(src, 'skin', function(active, saved, meta)
        local draft, code, detail
        if tonumber(skin.version) == AppearanceSchema.VERSION then
            if skin.sex ~= saved.sex then return fail('INVALID_PAYLOAD', { field = 'sex' }) end
            code, detail = v3Invalid(saved.sex, skin)
            if code then return fail(code, { field = detail }) end
            draft = skin
        else
            draft, code, detail = skinDraft(saved, skin, overwrite)
            if not draft then return fail(code, { field = detail }) end
        end
        local merged = AppearanceSchema.mergeSections(saved, draft, BUCKET_SECTIONS)
        WCGrooming.cut(merged, saved)
        return commit(src, active, saved, merged, 'api', type(meta) == 'table' and meta or {})
    end)
end

--- Re-send the saved appearance to its owner and every other player. Result { appearance }.
function Api.ApplyCharacterAppearance(src)
    src = playerId(src)
    if not src then return fail('INVALID_PAYLOAD') end
    local active = activeOf(src)
    if not active then return fail('NO_CHARACTER') end
    local done, app, meta = pcall(WCAppearanceRepo.load, active.charid)
    if not done then return fail('DATABASE_ERROR') end
    if not app then return fail(type(meta) == 'table' and meta.error or 'CHARACTER_NOT_FOUND') end
    TriggerClientEvent('w_creators:client:applyAppearance', src, app)
    WCSync.broadcast(src, app)
    return ok({ appearance = app })
end

-- ---------------------------------------------------------------------
--  Opening the service editors
-- ---------------------------------------------------------------------

local OPEN_EVENTS = {
    store = 'w_creators:client:openStore',
    barber = 'w_creators:client:openBarber',
    wardrobe = 'w_creators:client:openWardrobe',
    surgery = 'w_creators:client:openSurgery',
}

local function near(src, loc)
    local radius = (tonumber(loc.interactionRadius) or 2.0) + 3.0
    if WCSecurity.near(src, WCLocations.anchor(loc), radius) then return true end
    return loc.preview ~= nil and WCSecurity.near(src, loc.preview, radius)
end

-- Validate and send the client open event. Result { locationId }.
local function openService(src, kind, locationId)
    src = playerId(src)
    if not src then return fail('INVALID_PAYLOAD') end
    local def = WCSessions.KINDS[kind]
    if not WCServices.enabled(def.service) then return fail(WCServices.code(def.service)) end
    if not activeOf(src) then return fail('NO_CHARACTER') end
    if WCSessions.current(src) then return fail('BUSY') end
    if locationId == nil and kind == 'wardrobe' then
        if not (def.remote and def.remote()) then return fail('LOCATION_NOT_FOUND') end
    else
        if type(locationId) ~= 'string' or #locationId > MAX_ID then return fail('LOCATION_NOT_FOUND') end
        local loc = WCLocations.byId(locationId)
        if not loc or loc.type ~= def.locationType then return fail('LOCATION_NOT_FOUND') end
        if not loc.enabled or not WCLocations.isOpen(loc) then return fail('LOCATION_DISABLED') end
        if not WCLocations.isUsable(loc) then return fail(WCServices.code(def.service)) end
        if not near(src, loc) then return fail('TOO_FAR') end
        if kind == 'surgery' and WCSurgeryService then
            local app = loadActive(src)
            if app and next(WCSurgeryService.sections(app.sex)) == nil then return fail('SURGERY_DISABLED') end
        end
    end
    -- A clinic without its own prompt opens only through this export (one-shot grant).
    if kind == 'surgery' and WCSurgeryService then WCSurgeryService.grant(src, locationId) end
    TriggerClientEvent(OPEN_EVENTS[kind], src, locationId)
    return ok({ locationId = locationId })
end

--- OpenCosmeticSurgery({ source, clinicId }) (w_ambulancejob) or OpenCosmeticSurgery(src, clinicId).
function Api.OpenCosmeticSurgery(data, clinicId)
    local src = data
    if type(data) == 'table' then
        src = data.source or data.src or data.playerId
        clinicId = data.clinicId or data.clinic or data.locationId
    end
    return openService(src, 'surgery', clinicId)
end

function Api.OpenClothingStore(src, id) return openService(src, 'store', id) end
function Api.OpenBarber(src, id) return openService(src, 'barber', id) end
function Api.OpenWardrobe(src, id) return openService(src, 'wardrobe', id) end

-- ---------------------------------------------------------------------
--  Spawn
-- ---------------------------------------------------------------------

--- Open the spawn location selector for a player in the world (one-shot grant, kind 'admin').
--  Refused (BUSY) while a spawn is already pending (a login / switch / death grant is never
--  replaced) and while the player is outside the main world (routing bucket ~= 0: another
--  resource's instance, jail, housing; the spawn would move him to bucket 0).
--  Result { points, kind } | SERVICE_DISABLED | NO_CHARACTER | BUSY.
function Api.OpenSpawnSelector(src)
    src = playerId(src)
    if not src then return fail('INVALID_PAYLOAD') end
    local selector = Config.Spawn and Config.Spawn.selector or {}
    if not WCServices.enabled('spawnSelector') or selector.enabled == false then return fail('SERVICE_DISABLED') end
    if not WCSpawnServer then return fail('INTERNAL_ERROR') end
    if not activeOf(src) then return fail('NO_CHARACTER') end
    if WCSessions.current(src) then return fail('BUSY') end
    if WCSpawnServer.pending(src) then return fail('BUSY') end
    if GetPlayerRoutingBucket(src) ~= 0 then return fail('BUSY') end
    local points = WCSpawnServer.pointIds()
    local last = WCSpawnServer.lastPosition(src)
    if last then last.label = WCSpawnServer.nearestLabel(last) end
    WCSpawnServer.grant(src, 'admin')
    TriggerClientEvent('w_creators:client:selectSpawn', src, { last = last, points = points, kind = 'admin' })
    return ok({ points = points, kind = 'admin' })
end

--- Move a player to a spawn point (nil = the first enabled point, '__last' = the validated last
--  location). kind 'admin' (default) or 'death'. Result { pos, kind, point }.
function Api.RespawnPlayer(src, pointId, kind)
    src = playerId(src)
    if not src then return fail('INVALID_PAYLOAD') end
    if pointId ~= nil and (type(pointId) ~= 'string' or #pointId > MAX_ID) then return fail('INVALID_SPAWN') end
    if not WCSpawnServer then return fail('INTERNAL_ERROR') end
    if kind ~= 'death' then kind = 'admin' end
    return WCSpawnServer.respawn(src, pointId, kind)
end

-- ---------------------------------------------------------------------
--  Exports
-- ---------------------------------------------------------------------
for _, name in ipairs({
    'GetCharacterAppearance', 'GetAppearance', 'SetClothes', 'SetSkin', 'ApplyCharacterAppearance',
    'OpenCosmeticSurgery', 'OpenClothingStore', 'OpenBarber', 'OpenWardrobe', 'OpenSpawnSelector',
    'RespawnPlayer', 'GetActiveCharacter',
}) do
    exports(name, Api[name])
end
