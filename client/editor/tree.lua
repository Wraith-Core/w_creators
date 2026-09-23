-- =====================================================================
--  client/editor/tree.lua  —  WCEditorTree (ARCHITECTURE.md §8)
--  Builds the semantic node tree of one editor session and the control registry that validates
--  every value the NUI sends back. The NUI never sees a component hash: choices carry model /
--  variant / tone indices and Lua maps them back to catalogue hashes here.
--
--  WCEditorTree.build(session) -> root, registry
--    session = { mode, working, saved, opts, context, sections (set), draft, cache, starter }
--    registry[controlId] = entry
--      entry.kind     'choice' | 'slider' | 'action' | 'text'
--      entry.values   choice: set of accepted option values
--      entry.range    choice: { min, max } (integers, clamped)
--      entry.min/max  slider bounds (clamped), entry.integer (rounded)
--      entry.maxLength text: characters kept
--      entry.apply(app, value, session) -> errorCode | nil        mutates a working copy
--      entry.hook(session, value) -> Result                        optional veto before apply
--      entry.call(session, value) -> Result                        side operation (no appearance change)
--  Every label is translated here (locale()); the tree is rebuilt on every push, so a language
--  change only needs a rebuild.
-- =====================================================================

WCEditorTree = {}
local T = WCEditorTree

-- Camera presets (§8.6)
T.PRESETS = { 'fullBody', 'upperBody', 'lowerBody', 'head', 'face', 'eyes', 'hair', 'facialHair', 'hands',
              'feet', 'accessories' }
T.PRESET_SET = {}
for _, name in ipairs(T.PRESETS) do T.PRESET_SET[name] = true end

-- Morph fields edited together on one FeaturePad (the pre-v3 web/src/FeaturePad.jsx PAIRS list,
-- re-expressed with w_lib's expression names and re-paired inside the v3 morphology nodes: both
-- fields of a pair must sit in the same WCMorph node, tests/test_review_nui_r1.py). Any other field
-- of a node with pads is a fine-tune slider (the NUI's collapsed "Additional details").
T.PAIRS = {
    { 'eyelidWidth', 'eyelidHeight' }, { 'eyesDistance', 'eyesHeight' }, { 'eyesAngle', 'eyesDepth' },
    { 'eyebrowWidth', 'eyebrowHeight' }, { 'eyelidLeft', 'eyelidRight' },
    { 'noseWidth', 'noseHeight' }, { 'noseSize', 'noseAngle' }, { 'noseCurvature', 'nostrilsDistance' },
    { 'mouthX', 'mouthY' }, { 'mouthWidth', 'mouthDepth' },
    { 'upperLipWidth', 'upperLipHeight' }, { 'lowerLipWidth', 'lowerLipHeight' },
    { 'mouthConerLeftWidth', 'mouthConerLeftHeight' }, { 'mouthConerRightWidth', 'mouthConerRightHeight' },
    { 'mouthConerLeftDepth', 'mouthConerLeftLipsDistance' }, { 'mouthConerRightDepth', 'mouthConerRightLipsDistance' },
    { 'chinWidth', 'chinHeight' }, { 'jawWidth', 'jawHeight' }, { 'jawDepth', 'jawY' },
    { 'cheekbonesWidth', 'cheekbonesHeight' }, { 'earsWidth', 'earsHeight' }, { 'earsAngle', 'earlobes' },
    { 'headWidth', 'faceWidth' }, { 'shoulders', 'shoulderThickness' }, { 'neckWidth', 'neckDepth' },
    { 'thighs', 'calves' }, { 'chest', 'arms' }, { 'waist', 'hip' },
}

-- Camera preset per morphology node
local MORPH_CAMERA = {
    face = 'face', ['face.base'] = 'face', ['face.shape'] = 'head', ['face.jaw'] = 'face', ['face.chin'] = 'face',
    ['face.nose'] = 'face', ['face.cheeks'] = 'face', ['face.mouth'] = 'face', ['face.mouth.left'] = 'face',
    ['face.mouth.right'] = 'face', ['face.lips'] = 'face', ['face.lips.upper'] = 'face',
    ['face.lips.lower'] = 'face', ['face.ears'] = 'head', ['face.eyes'] = 'eyes', ['face.eyebrows'] = 'eyes',
    ['face.teeth'] = 'face',
    body = 'fullBody', ['body.build'] = 'fullBody', ['body.upper'] = 'upperBody', ['body.torso'] = 'upperBody',
    ['body.legs'] = 'lowerBody', ['body.neck'] = 'upperBody',
}

-- Overlay layer -> camera
local OVERLAY_CAMERA = { eyebrows = 'eyes', eyeliners = 'eyes', shadows = 'eyes', hairov = 'hair',
                         beardstabble = 'facialHair' }

-- Dictionary keys of the tree
local K = {
    root = 'مظهر الشخصية',
    identity = 'الهوية', body = 'الجسد', face = 'الوجه', skin = 'البشرة', eyes = 'العينان', hair = 'الشعر',
    facialHair = 'شعر الوجه', makeup = 'المكياج', clothing = 'الملابس', review = 'المراجعة',
    eyebrows = 'الحاجبان', states = 'إجراءات الملابس',
    style = 'النمط', color = 'اللون', opacity = 'الكثافة', variant = 'التنويعة', palette = 'لوحة الألوان',
    tint0 = 'الدرجة الأولى', tint1 = 'الدرجة الثانية', tint2 = 'الدرجة الثالثة', originalColor = 'اللون الأصلي',
    remove = 'خلع القطعة', itemCard = 'تفاصيل القطعة',
    bodyType = 'شكل الجسم', height = 'الطول', weight = 'الوزن', head = 'الوجه', skinTone = 'لون البشرة',
    eyeColor = 'لون العينين', teeth = 'الأسنان', beard = 'اللحية والشارب',
    starter = 'الطقم الأولي', details = 'تفاصيل تجميلية', growth = 'نمو الشعر', hairTime = 'الشعر',
    beardTime = 'اللحية', growthLine = 'المرحلة %s · %s دقيقة للمرحلة التالية',
    outfits = 'الأطقم', outfitEquip = 'ارتداء الطقم', outfitUpdate = 'تحديث بالملابس الحالية',
    outfitRename = 'إعادة التسمية', outfitDelete = 'حذف الطقم',
    outfitDeleteBody = 'سيُحذف هذا الطقم نهائيًا ولا يمكن التراجع عن ذلك.', outfitNew = 'حفظ الطقم الحالي',
    outfitName = 'اسم الطقم', outfitSave = 'حفظ', apply = 'تطبيق',
    outfitLimit = 'وصلت إلى الحد الأقصى من الأطقم',
    sex = 'الجنس', male = 'ذكر', female = 'أنثى', clothingCount = 'قطع الملابس', changed = 'الأقسام المعدّلة',
    noChanges = 'لا توجد تغييرات', price = 'السعر', free = 'مجاني',
    reviewHint = 'راجع اختياراتك ثم اضغط إنهاء الشخصية.', surgeryHint = 'راجع التعديلات ثم أكّد العملية.',
    owned = 'مملوكة', equipped = 'مرتداة',
}

-- AppearanceSchema section -> label key (review lines)
local SECTION_LABELS = {
    body = K.body, face = K.face, eyebrows = K.eyebrows, skin = K.skin, eyes = K.eyes, hair = K.hair,
    facialHair = K.facialHair, makeup = K.makeup, clothing = K.clothing, states = K.states,
}

local function L(key, ...)
    if type(locale) == 'function' then return locale(key, ...) end
    return key
end

local function pad2(n) return ('%02d'):format(n) end

local function money(n)
    return ('$%.2f'):format(tonumber(n) or 0)
end

local function catalog(s, category)
    return WCCatalog.forSex(s.working.sex)[category]
end

local function badgeLabel(badge)
    if badge == 'owned' then return L(K.owned) end
    if badge == 'equipped' then return L(K.equipped) end
    return nil
end

-- ---------------------------------------------------------------------
--  Node / registry helpers
-- ---------------------------------------------------------------------
local function group(id, label, children, extra)
    local node = { id = id, kind = 'group', label = label, children = children or {} }
    for k, v in pairs(extra or {}) do node[k] = v end
    return node
end

local function nonEmpty(node)
    return node ~= nil and (node.kind ~= 'group' or #node.children > 0)
end

local function add(list, node)
    if nonEmpty(node) then list[#list + 1] = node end
    return node
end

--- A choice with explicit options: options = { {value, label, badge?} }.
local function choice(reg, control, label, value, options, apply, extra)
    local values = {}
    for _, o in ipairs(options) do
        values[o.value] = true
        o.badgeLabel = o.badge and badgeLabel(o.badge) or nil
    end
    local node = { id = control, kind = 'choice', label = label, control = control, value = value, options = options }
    for k, v in pairs(extra or {}) do node[k] = v end
    if not node.disabled then reg[control] = { kind = 'choice', values = values, apply = apply } end
    return node
end

--- A choice over a generated integer range (none => option 0).
local function rangeChoice(reg, control, label, value, min, max, none, apply, extra)
    local node = { id = control, kind = 'choice', label = label, control = control, value = value,
                   range = { min = min, max = max, none = none or nil } }
    for k, v in pairs(extra or {}) do node[k] = v end
    if not node.disabled then
        reg[control] = { kind = 'choice', range = { min = none and 0 or min, max = max }, apply = apply }
    end
    return node
end

local function slider(reg, control, label, value, min, max, step, display, apply, extra)
    local node = { id = control, kind = 'slider', label = label, control = control, value = value,
                   min = min, max = max, step = step, display = display }
    for k, v in pairs(extra or {}) do node[k] = v end
    if not node.disabled then
        reg[control] = { kind = 'slider', min = min, max = max, integer = step >= 1, apply = apply }
    end
    return node
end

local function action(reg, control, label, entry, extra)
    local node = { id = control, kind = 'action', label = label, control = control }
    for k, v in pairs(extra or {}) do node[k] = v end
    if not node.disabled then
        entry.kind = 'action'
        reg[control] = entry
    end
    return node
end

local function text(reg, control, label, value, maxLength, entry, extra)
    local node = { id = control, kind = 'text', label = label, control = control, value = value or '',
                   maxLength = maxLength, actionLabel = L(K.apply) }
    for k, v in pairs(extra or {}) do node[k] = v end
    if not node.disabled then
        entry.kind = 'text'
        entry.maxLength = maxLength
        reg[control] = entry
    end
    return node
end

-- ---------------------------------------------------------------------
--  Ownership (store / wardrobe)
-- ---------------------------------------------------------------------
local function ownedEntry(s, hash)
    local owned = s.context.owned
    if type(owned) ~= 'table' or not hash or hash == 0 then return nil end
    local key = tostring(WCUtil.u32(hash))
    local entry = owned[key]
    if entry == nil then entry = owned[WCUtil.u32(hash)] end
    if entry == true then return {} end
    if type(entry) == 'table' then return entry end
    return nil
end

--- The owned tint of an item ({ palette, tint0..2 }) or nil.
--  An owned dye is stored data (§5.4): it is checked structurally (WCCatalog.validStoredTint, as
--  the server's WCOwnership.tintOf does), never against the live Config.Clothing.tints, so an item
--  whose palette the config no longer offers is put on with its paid dye (the renderer skips the
--  forbidden dye; the store sees the item as undyed). Only newly chosen tints use validTint.
local function ownedTint(s, category, hash)
    local entry = ownedEntry(s, hash)
    local tints = s.context.ownedTints
    local t = entry
    if type(tints) == 'table' then t = tints[tostring(WCUtil.u32(hash))] or entry end
    if type(t) == 'table' and t.palette and WCCatalog.validStoredTint(category, t) then
        return { palette = t.palette, tint0 = math.tointeger(t.tint0), tint1 = math.tointeger(t.tint1),
                 tint2 = math.tointeger(t.tint2) }
    end
    return nil
end
T.ownedTint = ownedTint
T.ownedEntry = ownedEntry

-- ---------------------------------------------------------------------
--  Body parts
-- ---------------------------------------------------------------------
local function flatIndex(s, category, hash)
    local cat = catalog(s, category)
    local list, current = {}, 0
    for _, variants in ipairs(cat and cat.models or {}) do
        for _, v in ipairs(variants) do
            list[#list + 1] = v.hash
            if v.hash == hash then current = #list end
        end
    end
    return list, current
end

local function flatChoice(reg, s, control, label, category, get, set)
    local list, current = flatIndex(s, category, get(s.working))
    if #list == 0 then return nil end
    local options = {}
    for i = 1, #list do options[i] = { value = i, label = pad2(i) } end
    return choice(reg, control, label, current, options, function(app, value)
        local hash = list[value]
        if not hash then return 'INVALID_COMPONENT' end
        set(app, hash)
    end)
end

local function bodyType(reg, s)
    local cat = catalog(s, 'BODIES_UPPER')
    if not cat or #cat.models == 0 then return nil end
    local info = cat.hashes[s.working.body.upper]
    local options = {}
    for m = 1, #cat.models do options[m] = { value = m, label = WCCatalog.styleLabel('BODIES_UPPER', m) } end
    return choice(reg, 'body.type', L(K.bodyType), info and info.model or 0, options, function(app, value)
        if not AppearanceSchema.setBodyType(app, value) then return 'INVALID_COMPONENT' end
    end)
end

local function baseHead(reg, s)
    local cat = catalog(s, 'heads')
    if not cat or #cat.models == 0 then return nil end
    local info = cat.hashes[s.working.head.head]
    local options = {}
    for m = 1, #cat.models do options[m] = { value = m, label = WCCatalog.styleLabel('heads', m) } end
    return choice(reg, 'face.head', L(K.head), info and info.model or 0, options, function(app, value)
        if not AppearanceSchema.setHead(app, value) then return 'INVALID_COMPONENT' end
    end)
end

local function skinTone(reg, s)
    local cat = catalog(s, 'heads')
    local info = cat and cat.hashes[s.working.head.head]
    if not info then return nil end
    local tones, seen = {}, {}
    for _, v in ipairs(cat.models[info.model] or {}) do
        local tone = tonumber(v.name:match('_V_(%d+)'))
        if tone and not seen[tone] then
            seen[tone] = true
            tones[#tones + 1] = tone
        end
    end
    table.sort(tones)
    if #tones == 0 then return nil end
    local options = {}
    for i, tone in ipairs(tones) do options[i] = { value = tone, label = pad2(tone) } end
    return choice(reg, 'skin.tone', L(K.skinTone), AppearanceSchema.skinTone(s.working) or 0, options,
        function(app, value)
            if not AppearanceSchema.setSkinTone(app, value) then return 'INVALID_COMPONENT' end
        end)
end

local function eyeColor(reg, s)
    return flatChoice(reg, s, 'eyes.color', L(K.eyeColor), 'eyes',
        function(app) return app.head.eyes end, function(app, hash) app.head.eyes = hash end)
end

local function teeth(reg, s)
    return flatChoice(reg, s, 'face.teeth', L(K.teeth), 'teeth',
        function(app) return app.head.teeth end, function(app, hash) app.head.teeth = hash end)
end

-- ---------------------------------------------------------------------
--  Hair and facial hair (named colours)
-- ---------------------------------------------------------------------
local function colourSuffix(name)
    local upper = (name or ''):upper()
    return upper:match('_HAIR_%d+_(.+)$') or upper:match('_BEARD_%d+_(.+)$')
end

local function colourLabel(name, index)
    local key = WCCatalog.colorKey(name)
    return key and L(key) or pad2(index)
end

--- Style + colour nodes of a hair-like category ('hair' -> app.hair.style, 'mustache' -> app.hair.facial).
local function hairControls(reg, s, category, slot, prefix)
    local cat = catalog(s, category)
    if not cat or #cat.models == 0 then return {} end
    local hash = s.working.hair[slot] or 0
    local info = hash ~= 0 and cat.hashes[hash] or nil
    local styles = { { value = 0, label = L('بدون') } }
    for m = 1, #cat.models do styles[#styles + 1] = { value = m, label = WCCatalog.styleLabel(category, m) } end
    local nodes = {}
    nodes[1] = choice(reg, prefix .. '.style', L(K.style), info and info.model or 0, styles, function(app, value)
        if value == 0 then
            app.hair[slot] = 0
            return nil
        end
        local variants = cat.models[value]
        if not variants then return 'INVALID_COMPONENT' end
        local current = app.hair[slot] ~= 0 and cat.hashes[app.hair[slot]] or nil
        local suffix = current and colourSuffix(current.name)
        local pick = variants[1]
        for _, v in ipairs(variants) do
            if suffix and colourSuffix(v.name) == suffix then pick = v break end
        end
        app.hair[slot] = pick.hash
    end)
    if info then
        local colours = {}
        for i, v in ipairs(cat.models[info.model]) do colours[i] = { value = i, label = colourLabel(v.name, i) } end
        nodes[2] = choice(reg, prefix .. '.color', L(K.color), info.variant, colours, function(app, value)
            local current = app.hair[slot] ~= 0 and cat.hashes[app.hair[slot]] or nil
            local variant = current and cat.models[current.model][value]
            if not variant then return 'INVALID_COMPONENT' end
            app.hair[slot] = variant.hash
        end)
    end
    return nodes
end

-- ---------------------------------------------------------------------
--  Overlays
-- ---------------------------------------------------------------------
--- Does a layer's Color show on the ped (Appearance.Overlays.tintable)? A layer drawn without its
--  palette (blend type 1: complexion, discolouration, wrinkles, freckles, moles, spots, acne,
--  scars) gets no Color control, so a colour-only change can never be priced.
local function overlayTintable(layer)
    local O = type(Appearance) == 'table' and Appearance.Overlays or nil
    if type(O) == 'table' and type(O.tintable) == 'function' then return O.tintable(layer) == true end
    return layer.tint ~= false
end
T.overlayTintable = overlayTintable

local function overlayControls(reg, s, layer)
    local o = s.working.overlays[layer.id]
    local id = 'overlay.' .. layer.id
    local nodes = {}
    nodes[1] = rangeChoice(reg, id .. '.style', L(K.style), o and o.style or 0, 1, layer.styles, true,
        function(app, value)
            if value == 0 then
                app.overlays[layer.id] = nil
                return nil
            end
            local cur = app.overlays[layer.id]
            app.overlays[layer.id] = { style = value, color = cur and cur.color or 1,
                                       opacity = cur and cur.opacity or 1.0 }
        end)
    local off = o == nil
    if overlayTintable(layer) then
        nodes[#nodes + 1] = rangeChoice(reg, id .. '.color', L(K.color), o and o.color or 1, 1, WCOverlays.COLORS, false,
            function(app, value)
                local cur = app.overlays[layer.id]
                if not cur then return 'INVALID_COMPONENT' end
                cur.color = value
            end, { disabled = off or nil })
    end
    nodes[#nodes + 1] = slider(reg, id .. '.opacity', L(K.opacity), o and o.opacity or 1.0, 0, 1, 0.01,
        { scale = 100, decimals = 0 }, function(app, value)
            local cur = app.overlays[layer.id]
            if not cur then return 'INVALID_COMPONENT' end
            cur.opacity = value + 0.0
        end, { disabled = off or nil })
    return nodes
end

local function overlayGroup(reg, s, layer)
    if not WCOverlays.allowed(layer.id, s.working.sex) then return nil end
    local o = s.working.overlays[layer.id]
    return group('overlay.' .. layer.id, L(layer.label), overlayControls(reg, s, layer), {
        camera = OVERLAY_CAMERA[layer.id] or 'face',
        summary = o and pad2(o.style) or L('بدون'),
    })
end

local function overlayGroupsOf(reg, s, section)
    local out = {}
    for _, layer in ipairs(WCOverlays.layers) do
        if layer.section == section then add(out, overlayGroup(reg, s, layer)) end
    end
    return out
end

-- ---------------------------------------------------------------------
--  Morphology (face / body)
-- ---------------------------------------------------------------------
local function morphValue(s, id)
    return s.working.morph[id] or 0.0
end

local function morphApply(id)
    return function(app, value)
        if value == 0 then app.morph[id] = nil else app.morph[id] = value + 0.0 end
    end
end

local function morphLeaves(reg, s, fields)
    local present, used, out = {}, {}, {}
    for _, id in ipairs(fields) do present[id] = true end
    for _, pair in ipairs(T.PAIRS) do
        local a, b = pair[1], pair[2]
        if present[a] and present[b] and not used[a] and not used[b] then
            used[a], used[b] = true, true
            local fa, fb = WCMorph.byId[a], WCMorph.byId[b]
            local ca, cb = 'morph.' .. a, 'morph.' .. b
            reg[ca] = { kind = 'slider', min = -1, max = 1, apply = morphApply(a) }
            reg[cb] = { kind = 'slider', min = -1, max = 1, apply = morphApply(b) }
            out[#out + 1] = {
                id = 'pad.' .. a .. '.' .. b, kind = 'pad', label = L(fa.label) .. ' / ' .. L(fb.label),
                x = { control = ca, label = L(fa.label), value = morphValue(s, a) },
                y = { control = cb, label = L(fb.label), value = morphValue(s, b) },
                min = -1, max = 1, step = 0.01, display = { scale = 100, decimals = 0 },
            }
        end
    end
    for _, id in ipairs(fields) do
        if not used[id] then
            local field = WCMorph.byId[id]
            out[#out + 1] = slider(reg, 'morph.' .. id, L(field.label), morphValue(s, id), -1, 1, 0.01,
                { scale = 100, decimals = 0 }, morphApply(id))
        end
    end
    return out
end

-- The non-morph controls a morphology node hosts (WCMorph extras), filtered by section.
local function extraControls(reg, s, extra)
    local sec = s.sections
    if extra == 'face.head' and sec.face then return { baseHead(reg, s) } end
    if extra == 'face.teeth' and sec.face then return { teeth(reg, s) } end
    if extra == 'eyes.color' and sec.eyes then return { eyeColor(reg, s) } end
    if extra == 'overlay.eyebrows' and sec.eyebrows then
        return { overlayGroup(reg, s, WCOverlays.byId.eyebrows) }
    end
    if sec.body then
        if extra == 'body.type' then return { bodyType(reg, s) } end
        if extra == 'body.height' then
            return { slider(reg, 'body.height', L(K.height), s.working.body.height, 0.9, 1.1, 0.005,
                { scale = 100, decimals = 1 }, function(app, value) app.body.height = value + 0.0 end) }
        end
        if extra == 'body.weight' then
            return { slider(reg, 'body.weight', L(K.weight), s.working.body.weight, 1, 21, 1,
                { scale = 1, decimals = 0 }, function(app, value) app.body.weight = math.tointeger(value) end) }
        end
    end
    return {}
end

local function morphNode(reg, s, src)
    local children = {}
    for _, extra in ipairs(src.extras or {}) do
        for _, node in ipairs(extraControls(reg, s, extra)) do add(children, node) end
    end
    if s.sections[src.section] then
        for _, node in ipairs(morphLeaves(reg, s, src.fields or {})) do children[#children + 1] = node end
    end
    for _, child in ipairs(src.children or {}) do add(children, morphNode(reg, s, child)) end
    return group(src.id, L(src.label), children, { camera = MORPH_CAMERA[src.id] or 'face' })
end

local function morphRoot(s, id)
    for _, g in ipairs(WCMorph.groups or {}) do
        if g.id == id then return g end
    end
    return nil
end

-- ---------------------------------------------------------------------
--  Clothing
-- ---------------------------------------------------------------------
local function sectionAllowed(s, name) return s.sections[name] == true end

-- The catalogue models of a category a mode may offer, each with its allowed variants:
-- { { model = m, variants = { { index, hash, name } } } }. Cached per session (filters depend on
-- the context only).
local function allowedModels(s, category)
    s.cache.models = s.cache.models or {}
    local cached = s.cache.models[category]
    if cached then return cached end
    local cat = catalog(s, category)
    local out = {}
    if cat then
        local filter
        local sex = s.working.sex
        if s.mode == 'store' then
            local profile = s.context.storeProfile
            local savedHash = s.saved.clothing.equipped[category]
            filter = function(hash)
                return hash == savedHash or WCCatalog.available(profile, sex, category, hash)
            end
        elseif s.mode == 'wardrobe' then
            filter = function(hash) return ownedEntry(s, hash) ~= nil end
        elseif s.mode == 'surgery' then
            -- a clinic never hands out clothes: what the character wears or owns only
            local savedHash = s.saved.clothing.equipped[category]
            filter = function(hash) return hash == savedHash or ownedEntry(s, hash) ~= nil end
        else
            filter = function() return WCCatalog.offered(sex, category) end
        end
        for m, variants in ipairs(cat.models) do
            local list = {}
            for i, v in ipairs(variants) do
                if filter(v.hash) then list[#list + 1] = { index = i, hash = v.hash, name = v.name } end
            end
            if #list > 0 then out[#out + 1] = { model = m, variants = list } end
        end
    end
    s.cache.models[category] = out
    return out
end
T.allowedModels = allowedModels

local function categoryPrice(s, category)
    local prices = s.context.prices or s.context.pricing
    local p = type(prices) == 'table' and tonumber(prices[category]) or nil
    if p == nil then p = WCCatalog.price(category, nil, s.context.pricingProfile) end
    return p
end
T.categoryPrice = categoryPrice

-- A tint as the server compares it (WCOwnership.sameTint): anything without a palette is no tint.
local function sameTint(a, b)
    a = type(a) == 'table' and a.palette and a or nil
    b = type(b) == 'table' and b.palette and b or nil
    if a == nil or b == nil then return a == b end
    return a.palette == b.palette and a.tint0 == b.tint0 and a.tint1 == b.tint1 and a.tint2 == b.tint2
end

--- The item worn as saved, with its saved tint: never priced (WCClothingStore.plan's `untouched`).
local function untouched(s, category, hash, tint)
    return hash == s.saved.clothing.equipped[category] and sameTint(tint, s.saved.clothing.tints[category])
end

--- The colour an item has without a dye: its owned tint, else (the saved item) the saved one
--  (the server's baselineTint / WCOwnership.wornTint).
local function baselineTint(s, category, hash)
    local tint = ownedTint(s, category, hash)
    if tint == nil and hash ~= nil and hash == s.saved.clothing.equipped[category] then
        tint = s.saved.clothing.tints[category]
        if type(tint) == 'table' then tint = WCUtil.copy(tint) end
    end
    return tint
end

--- The server rule (WCClothingStore.plan `isNew`): any change to an item the character does not own
--  is a purchase of the item, a dye of the worn but unowned item included (a job uniform applied by
--  SetClothes has no ownership row). `tint` defaults to the working tint of the category.
local function isPurchase(s, category, hash, tint)
    if not hash or hash == 0 or ownedEntry(s, hash) then return false end
    if tint == nil then tint = s.working.clothing.tints[category] end
    return not untouched(s, category, hash, tint)
end
T.isPurchase = isPurchase

local function itemBadge(s, category, hash)
    if s.mode == 'creator' then return nil end
    if hash == s.saved.clothing.equipped[category] then return 'equipped' end
    if ownedEntry(s, hash) then return 'owned' end
    return nil
end

--- Equip a hash through the rules; the owned tint (if any) follows the item.
--  An item the rules drop (a requirement missing, e.g. a buckle without a belt) is a conflict, not
--  a silent no-op.
--- Store and surgery modes: the clothing states the server will save with this equipment
--  (WCOwnership.settleStates on the commit: WCClothingStore.plan, the clinic's ownedClothing). A
--  saved state is kept only while its items are still the saved ones and it still applies; a swapped
--  or removed item is shown in its default state. Neither mode edits states, so the saved states are
--  the ones settled.
local function settleStates(s, app)
    local out = {}
    local savedStates = s.saved.clothing.states or {}
    local savedEq, eq = s.saved.clothing.equipped, app.clothing.equipped
    for _, def in ipairs(WCClothingStates.groups) do
        local value = savedStates[def.id]
        if value ~= nil and def.persist and WCClothingStates.isValid(def.id, value) then
            local swapped = false
            for _, category in ipairs(def.categories or {}) do
                if eq[category] ~= savedEq[category] then swapped = true break end
            end
            if not swapped and WCClothingStates.applicable(app, def.id) then out[def.id] = value end
        end
    end
    return out
end
T.settleStates = settleStates
T.storeStates = settleStates
-- The modes whose server commit settles the clothing states of a swapped item.
local SETTLES_STATES = { store = true, surgery = true }

local function equipItem(s, app, category, hash)
    local _, removed, err = AppearanceSchema.equip(app, category, hash)
    if err then return err end
    if hash and hash ~= 0 then
        if not app.clothing.equipped[category] then return 'CONFLICTING_ITEMS' end
        for _, c in ipairs(type(removed) == 'table' and removed or {}) do
            if c == category then return 'CONFLICTING_ITEMS' end
        end
        -- the item's own colour as the server derives it (WCOwnership.wornTint): the owned tint,
        -- else (the unowned saved item put back on) the saved one, so that item is untouched again
        -- and never a purchase
        local tint = ownedTint(s, category, hash)
        if tint == nil and not ownedEntry(s, hash) and hash == s.saved.clothing.equipped[category] then
            tint = s.saved.clothing.tints[category] and WCUtil.copy(s.saved.clothing.tints[category]) or nil
        end
        app.clothing.tints[category] = tint
    end
    app.clothing.outfit = nil
    if SETTLES_STATES[s.mode] then
        if s.mode == 'surgery' and WCUtil.deepEqual(app.clothing.equipped, s.saved.clothing.equipped) then
            -- the clinic keeps the saved clothing (states included) as is when nothing was swapped
            app.clothing.states = WCUtil.copy(s.saved.clothing.states or {})
        else
            app.clothing.states = settleStates(s, app)
        end
    end
    return nil
end

local function tintNodes(reg, s, category)
    local palettes = WCCatalog.tintable(category)
    if not palettes then return nil end
    local labels = Config.Clothing.tints and Config.Clothing.tints.labels or {}
    local tint = s.working.clothing.tints[category]
    local options = { { value = 0, label = L(K.originalColor) } }
    local current = 0
    for i, name in ipairs(palettes) do
        options[#options + 1] = { value = i, label = L(labels[name] or name) }
        if tint and tint.palette == name then current = i end
    end
    local id = 'clothing.' .. category
    local children = {}
    children[1] = choice(reg, id .. '.palette', L(K.palette), current, options, function(app, value)
        if value == 0 then
            app.clothing.tints[category] = nil
            return nil
        end
        local cur = app.clothing.tints[category] or {}
        app.clothing.tints[category] = { palette = palettes[value], tint0 = cur.tint0 or 0, tint1 = cur.tint1 or 0,
                                         tint2 = cur.tint2 or 0 }
    end)
    for i, key in ipairs({ 'tint0', 'tint1', 'tint2' }) do
        children[i + 1] = slider(reg, id .. '.' .. key, L(K[key]), tint and tint[key] or 0, 0, 254, 1,
            { scale = 1, decimals = 0 }, function(app, value)
                local cur = app.clothing.tints[category]
                if not cur then return 'INVALID_TINT' end
                cur[key] = math.tointeger(value)
                if not WCCatalog.validTint(category, cur) then return 'INVALID_TINT' end
            end, { disabled = tint == nil or nil })
    end
    return group(id .. '.color', L(K.color), children)
end

--- The node of one clothing subcategory (Style / Variant / Color / Remove / item card).
local function clothingSub(reg, s, sub)
    local category = sub.category or sub.id
    local sex = s.working.sex
    if not WCCatalog.offered(sex, category) and s.mode ~= 'wardrobe' then return nil end
    local models = allowedModels(s, category)
    if #models == 0 then return nil end
    local cat = catalog(s, category)
    local hash = s.working.clothing.equipped[category]
    local info = hash and cat.hashes[hash] or nil
    local id = 'clothing.' .. category
    local removable = WCRules.canRemove(category)
    local children = {}

    local styleOptions, byModel = {}, {}
    if removable then styleOptions[1] = { value = 0, label = L('بدون') } end
    for _, entry in ipairs(models) do
        byModel[entry.model] = entry
        local badge
        for _, v in ipairs(entry.variants) do
            local b = itemBadge(s, category, v.hash)
            if b == 'equipped' then badge = 'equipped' break end
            if b == 'owned' then badge = 'owned' end
        end
        styleOptions[#styleOptions + 1] = { value = entry.model, label = WCCatalog.styleLabel(category, entry.model),
                                            badge = badge }
    end
    children[1] = choice(reg, id .. '.style', L(K.style), info and info.model or 0, styleOptions, function(app, value)
        if value == 0 then return equipItem(s, app, category, 0) end
        local entry = byModel[value]
        if not entry then return 'INVALID_COMPONENT' end
        local cur = app.clothing.equipped[category]
        local curInfo = cur and cat.hashes[cur]
        local pick = entry.variants[1]
        for _, v in ipairs(entry.variants) do
            if curInfo and v.index == curInfo.variant then pick = v break end
        end
        return equipItem(s, app, category, pick.hash)
    end)

    local current = info and byModel[info.model]
    if current then
        local variantOptions, byIndex = {}, {}
        for _, v in ipairs(current.variants) do
            byIndex[v.index] = v
            variantOptions[#variantOptions + 1] = { value = v.index, label = pad2(v.index),
                                                    badge = itemBadge(s, category, v.hash) }
        end
        children[#children + 1] = choice(reg, id .. '.variant', L(K.variant), info.variant, variantOptions,
            function(app, value)
                local v = byIndex[value]
                if not v then return 'INVALID_COMPONENT' end
                return equipItem(s, app, category, v.hash)
            end)
        -- a dye of an item the character does not own is a purchase of the item (the server rule):
        -- offered only where the store sells it (a worn uniform it does not sell is not dyed here)
        if s.mode == 'store' and (ownedEntry(s, hash) or WCCatalog.available(s.context.storeProfile, sex, category, hash)) then
            add(children, tintNodes(reg, s, category))
        end
        if removable then
            children[#children + 1] = action(reg, id .. '.remove', L(K.remove), {
                apply = function(app) return equipItem(s, app, category, 0) end,
            })
        end
    end

    local node = group('item.' .. category, L(sub.label), children, { camera = sub.camera, art = sub.art })
    if hash and s.mode ~= 'creator' then
        -- owned is the ownership row only: the saved item is worn ('equipped'), and a worn item
        -- without a row (a uniform) is bought by any change, so its price shows (WCClothingStore.plan)
        local owned = ownedEntry(s, hash) ~= nil
        local price = (s.mode == 'store' and not owned) and categoryPrice(s, category) or nil
        node.badge = hash == s.saved.clothing.equipped[category] and 'equipped' or (owned and 'owned' or nil)
        node.badgeLabel = badgeLabel(node.badge)
        if price then node.summary = money(price) end
        if s.mode == 'store' then
            children[#children + 1] = {
                id = id .. '.card', kind = 'itemcard', label = L(K.itemCard),
                item = { name = WCCatalog.styleLabel(category, info and info.model or 0) .. ' · ' .. pad2(info and info.variant or 0),
                         price = price, owned = owned, equipped = hash == s.saved.clothing.equipped[category],
                         variants = current and #current.variants or 0 },
            }
        end
    elseif hash then
        node.summary = WCCatalog.styleLabel(category, info and info.model or 0)
    elseif s.mode == 'store' then
        -- nothing worn: the category's price (per category, §16 store:open) before any try-on
        local price = categoryPrice(s, category)
        if price then node.summary = money(price) end
    end
    return node
end

local function startingCategories(s)
    local cfg = s.context.startingClothing or (Config.Creator and Config.Creator.startingClothing) or {}
    local list = cfg.categories or '*'
    if list == '*' then return nil, cfg end
    return WCUtil.set(list), cfg
end

--- A config list in its deterministic order (§5.3): by `order`, then by position (a stable tie-break,
--  the same comparator as WCClothing.available). Entries that are not tables are skipped.
local function ordered(list)
    local out = {}
    for i, entry in ipairs(type(list) == 'table' and list or {}) do
        if type(entry) == 'table' then out[#out + 1] = { entry = entry, index = i } end
    end
    table.sort(out, function(a, b)
        local oa, ob = tonumber(a.entry.order) or a.index, tonumber(b.entry.order) or b.index
        if oa ~= ob then return oa < ob end
        return a.index < b.index
    end)
    for i, e in ipairs(out) do out[i] = e.entry end
    return out
end
T.ordered = ordered

local function presetItems(sex, preset, only)
    local equipped = {}
    for _, item in ipairs(preset.items or {}) do
        local hash = WCCatalog.resolve(sex, item.category, { item.model, item.variant })
        if hash and WCCatalog.offered(sex, item.category) and (not only or only[item.category]) then
            equipped[item.category] = hash
        end
    end
    return WCRules.normalize(equipped)
end

--- The starting outfit presets (Config.StartingOutfits) as one choice. `only` (free mode) keeps
--  the items of the allowed starting categories (the server's restrictClothing drops the others).
local function starterPresets(reg, s, only)
    local presets = Config.StartingOutfits and Config.StartingOutfits[s.working.sex] or {}
    local options = { { value = 0, label = L('بدون') } }
    local current = 0
    for i, preset in ipairs(presets) do
        options[#options + 1] = { value = i, label = L(preset.label) }
        if next(s.working.clothing.equipped) and WCUtil.deepEqual(presetItems(s.working.sex, preset, only), s.working.clothing.equipped) then
            current = i
        end
    end
    return choice(reg, 'starter.preset', L(K.starter), current, options, function(app, value)
        local preset = presets[value]
        app.clothing.equipped = preset and presetItems(app.sex, preset, only) or {}
        app.clothing.tints, app.clothing.outfit = {}, nil
    end)
end

--- The taxonomy groups -> subcategories for the clothing of a mode, in their `order` (§5.3).
--  The creator (free mode) adds the 8th group, Outfits: the Config.StartingOutfits presets of the
--  character's sex. (The wardrobe adds its saved outfits there; stores sell items only.)
function T.taxonomy(reg, s)
    local only
    if s.mode == 'creator' then only = startingCategories(s) end
    local out = {}
    for _, g in ipairs(ordered(Config.Clothing.taxonomy)) do
        local subs = {}
        for _, sub in ipairs(ordered(g.subs)) do
            local category = sub.category or sub.id
            if not only or only[category] then add(subs, clothingSub(reg, s, sub)) end
        end
        add(out, group('tax.' .. g.id, L(g.label), subs, { camera = g.camera, searchable = #subs > 6 or nil }))
    end
    if s.mode == 'creator' then
        local presets = Config.StartingOutfits and Config.StartingOutfits[s.working.sex]
        if type(presets) == 'table' and #presets > 0 then
            add(out, group('tax.outfits', L(K.outfits), { starterPresets(reg, s, only) }, { camera = 'fullBody' }))
        end
    end
    return out
end

-- ---------------------------------------------------------------------
--  Clothing states (wardrobe "Clothing actions" and WCPanel trees)
-- ---------------------------------------------------------------------

-- The applicable actions, Group › Item › action (labels: locale keys). The quick panel's
-- WCClothing.available (client/clothing/states.lua) is the source of the grouping and of the action
-- labels: the item is the worn piece (a cloak, a closed coat, the shirt holding sleeves and collar)
-- and every action has its own verb ('Roll up sleeves', 'Take off cloak'). Without that module the
-- same hierarchy is built from WCClothingStates with the generic value labels.
local function availableActions(app)
    if type(WCClothing) == 'table' and type(WCClothing.available) == 'function' then
        local ok, list = pcall(WCClothing.available, app)
        if ok and type(list) == 'table' then return list end
    end
    local groupLabels, subLabels, groupRank, subRank = {}, {}, {}, {}
    for gi, g in ipairs(ordered(Config.Clothing.taxonomy)) do
        groupLabels[g.id], groupRank[g.id] = g.label, gi
        for si, sub in ipairs(ordered(g.subs)) do
            subLabels[sub.id] = sub.label
            subRank[sub.id] = subRank[sub.id] or si
            if sub.category then
                subLabels[sub.category] = subLabels[sub.category] or sub.label
                subRank[sub.category] = subRank[sub.category] or si
            end
        end
    end
    local valueLabels = Config.ClothingStates and Config.ClothingStates.valueLabels or {}
    local out, groupAt, itemAt = {}, {}, {}
    for _, a in ipairs(WCClothingStates.actions(app)) do
        local parent = type(a.parent) == 'table' and a.parent or {}
        local groupId = type(parent[1]) == 'string' and parent[1] or 'other'
        local itemId = type(parent[2]) == 'string' and parent[2] or a.group
        if not groupAt[groupId] then
            groupAt[groupId] = { id = groupId, label = groupLabels[groupId] or K.states, items = {} }
            out[#out + 1] = groupAt[groupId]
        end
        local key = groupId .. '/' .. itemId
        local item = itemAt[key]
        if not item then
            local category = WCClothingStates.category(app, a.group)
            item = { id = itemId, label = subLabels[category] or subLabels[itemId] or a.label, actions = {} }
            itemAt[key] = item
            groupAt[groupId].items[#groupAt[groupId].items + 1] = item
        end
        for _, value in ipairs(a.targets or {}) do
            item.actions[#item.actions + 1] = { group = a.group, value = value, label = valueLabels[value] or value,
                                                control = 'state.' .. a.group .. '.' .. value }
        end
    end
    -- the taxonomy order, as WCClothing.available sorts it (stable: first seen wins a tie)
    for i, g in ipairs(out) do g.order = groupRank[g.id] or (1000 + i) end
    out = ordered(out)
    for _, g in ipairs(out) do
        for i, item in ipairs(g.items) do item.order = subRank[item.id] or (1000 + i) end
        g.items = ordered(g.items)
    end
    return out
end

--- The clothing-action nodes for an appearance: taxonomy group -> worn item -> actions (only the
--  values that differ from the current state, so no summary is needed: each row is the change).
--  reg (optional) receives registry entries built by makeEntry(groupId, value); keep(groupId)
--  (optional) filters the state groups offered.
function T.clothingActions(app, reg, makeEntry, keep)
    local out = {}
    for _, g in ipairs(availableActions(app)) do
        local items = {}
        for _, item in ipairs(g.items or {}) do
            local children = {}
            for _, a in ipairs(item.actions or {}) do
                if not keep or keep(a.group) then
                    local control = 'state.' .. a.group .. '.' .. a.value
                    if reg then
                        local entry = makeEntry and makeEntry(a.group, a.value) or {}
                        entry.kind = 'action'
                        reg[control] = entry
                    end
                    children[#children + 1] = { id = control, kind = 'action', label = L(a.label), control = control }
                end
            end
            add(items, group('states.' .. g.id .. '.' .. item.id, L(item.label), children))
        end
        add(out, group('states.' .. g.id, L(g.label), items))
    end
    return out
end

-- ---------------------------------------------------------------------
--  Outfits (wardrobe)
-- ---------------------------------------------------------------------
local function outfitsOf(s)
    local list = s.context.outfits
    return type(list) == 'table' and list or {}
end

local function outfitEquip(s, outfit)
    return function(app)
        local data = WCUtil.decode(outfit.data)
        local equipped = {}
        for category, hash in pairs(type(data.equipped) == 'table' and data.equipped or {}) do
            local h = WCCatalog.isClothing(category) and WCCatalog.resolve(app.sex, category, hash)
            if h and ownedEntry(s, h) then equipped[category] = h end
        end
        equipped = WCRules.normalize(equipped)
        local tints = {}
        for category, h in pairs(equipped) do tints[category] = ownedTint(s, category, h) end
        local states = {}
        for groupId, value in pairs(type(data.states) == 'table' and data.states or {}) do
            if WCClothingStates.isValid(groupId, value) then states[groupId] = value end
        end
        app.clothing.equipped, app.clothing.tints, app.clothing.states = equipped, tints, states
        app.clothing.outfit = WCUtil.int(outfit.id, 1, nil, nil)
    end
end

local function outfitCall(op, id, valueOf)
    return function(s, value)
        local fn = s.opts.onOutfit
        if type(fn) ~= 'function' then return WCResult.fail('OUTFITS_DISABLED') end
        return fn(op, id, valueOf and valueOf(s, value) or value)
    end
end

local function currentClothes(s, name)
    return { name = name, equipped = WCUtil.copy(s.working.clothing.equipped),
             states = WCUtil.copy(s.working.clothing.states) }
end

local function outfitsNode(reg, s)
    local ctx = s.context
    if ctx.outfitsEnabled == false or (WCServices and not WCServices.enabled('savedOutfits')) then return nil end
    local maxName = Config.Wardrobe and Config.Wardrobe.outfitNameMax or 24
    local children = {}
    for _, outfit in ipairs(outfitsOf(s)) do
        local oid = WCUtil.int(outfit.id, 1, nil, nil)
        if oid then
            local prefix = 'outfit.' .. oid
            local name = WCUtil.clampString(tostring(outfit.name or ''), maxName)
            local sub = {}
            sub[1] = action(reg, prefix .. '.equip', L(K.outfitEquip), {
                apply = outfitEquip(s, outfit),
                hook = s.opts.onOutfit and function(session) return s.opts.onOutfit('equip', oid, nil, session) end or nil,
            })
            sub[2] = action(reg, prefix .. '.update', L(K.outfitUpdate), {
                call = outfitCall('update', oid, function(session) return currentClothes(session) end),
            })
            sub[3] = text(reg, prefix .. '.rename', L(K.outfitRename), name, maxName, {
                call = outfitCall('rename', oid),
            })
            sub[4] = action(reg, prefix .. '.delete', L(K.outfitDelete), { call = outfitCall('delete', oid) },
                { danger = true, confirmBody = L(K.outfitDeleteBody) })
            local equipped = s.working.clothing.outfit == oid
            children[#children + 1] = group(prefix, name, sub, {
                badge = equipped and 'equipped' or nil, badgeLabel = equipped and badgeLabel('equipped') or nil,
            })
        end
    end
    local max = WCUtil.int(ctx.maxOutfits or (Config.Wardrobe and Config.Wardrobe.maxSavedOutfits), 0, nil, 0)
    local full = #outfitsOf(s) >= max
    -- One field and its Save button: what is typed is saved in the same step (the NUI keeps the
    -- typing locally, so a separate Save row could never see it). A refused save keeps the name.
    local draft = s.draft.outfitName or ''
    local newChildren = {}
    newChildren[1] = text(reg, 'outfit.new.name', L(K.outfitName), draft, maxName, {
        call = function(session, value)
            local fn = session.opts.onOutfit
            if type(fn) ~= 'function' then return WCResult.fail('OUTFITS_DISABLED') end
            if type(value) ~= 'string' or value == '' then return WCResult.fail('INVALID_OUTFIT_NAME') end
            session.draft.outfitName = value
            local result = fn('save', nil, currentClothes(session, value))
            if WCResult.is(result) and result.ok then session.draft.outfitName = '' end
            return result
        end,
    }, { disabled = full or nil, placeholder = L(K.outfitName), actionLabel = L(K.outfitSave), required = true,
         clear = true, reason = full and L(K.outfitLimit) or nil })
    children[#children + 1] = group('outfit.new', L(K.outfitNew), newChildren)
    return group('outfits', L(K.outfits), children, { camera = 'fullBody' })
end

-- ---------------------------------------------------------------------
--  Info / review
-- ---------------------------------------------------------------------
local function growthNode(s)
    local growth = s.context.growth
    if type(growth) ~= 'table' then return nil end
    local items = {}
    for _, kind in ipairs({ 'hair', 'beard' }) do
        local g = growth[kind]
        if type(g) == 'table' and (kind == 'hair' or s.working.sex == 'male') then
            local minutes = math.ceil(WCUtil.number(g.remainingMinutes, 0, 1e6, 0))
            items[#items + 1] = { label = L(kind == 'hair' and K.hairTime or K.beardTime),
                                  value = L(K.growthLine, tostring(WCUtil.int(g.stage, 0, 99, 0)), tostring(minutes)) }
        end
    end
    if #items == 0 then return nil end
    return { id = 'growth', kind = 'info', label = L(K.growth), items = items }
end

local function creatorReview(s)
    local app = s.working
    local items = {
        { label = L(K.sex), value = L(app.sex == 'male' and K.male or K.female) },
    }
    local upper = catalog(s, 'BODIES_UPPER')
    local info = upper and upper.hashes[app.body.upper]
    if info then items[#items + 1] = { label = L(K.bodyType), value = WCCatalog.styleLabel('BODIES_UPPER', info.model) } end
    items[#items + 1] = { label = L(K.height), value = ('%d'):format(math.floor(app.body.height * 100 + 0.5)) }
    local heads = catalog(s, 'heads')
    local head = heads and heads.hashes[app.head.head]
    if head then items[#items + 1] = { label = L(K.head), value = WCCatalog.styleLabel('heads', head.model) } end
    local tone = AppearanceSchema.skinTone(app)
    if tone then items[#items + 1] = { label = L(K.skinTone), value = pad2(tone) } end
    local hairCat = catalog(s, 'hair')
    local hair = app.hair.style ~= 0 and hairCat and hairCat.hashes[app.hair.style]
    items[#items + 1] = { label = L(K.hair), value = hair and (WCCatalog.styleLabel('hair', hair.model) .. ' · ' .. colourLabel(hair.name, hair.variant)) or L('بدون') }
    if app.sex == 'male' then
        local beardCat = catalog(s, 'mustache')
        local beard = app.hair.facial ~= 0 and beardCat and beardCat.hashes[app.hair.facial]
        items[#items + 1] = { label = L(K.beard), value = beard and WCCatalog.styleLabel('mustache', beard.model) or L('بدون') }
    end
    local count = 0
    for _ in pairs(app.clothing.equipped) do count = count + 1 end
    items[#items + 1] = { label = L(K.clothingCount), value = tostring(count) }
    return { id = 'review', kind = 'review', label = L(K.review), hint = L(K.reviewHint), items = items,
             camera = 'fullBody' }
end

local function changesReview(s, hint)
    local changed = AppearanceSchema.changedSections(s.saved, s.working)
    local names = {}
    for _, section in ipairs(AppearanceSchema.SECTIONS) do
        if changed[section] and SECTION_LABELS[section] then names[#names + 1] = L(SECTION_LABELS[section]) end
    end
    local items = { { label = L(K.changed), value = #names > 0 and table.concat(names, L('، ')) or L(K.noChanges) } }
    local price = T.price(s)
    if price then items[#items + 1] = { label = L(K.price), value = money(price.total) } end
    return { id = 'review', kind = 'review', label = L(K.review), hint = L(hint), items = items, camera = 'fullBody' }
end

-- ---------------------------------------------------------------------
--  Display price (mirror of the server rules — display only, the server is authoritative)
-- ---------------------------------------------------------------------
function T.price(s)
    local lines, total = {}, 0
    local function line(label, amount)
        amount = tonumber(amount) or 0
        if amount > 0 then
            lines[#lines + 1] = { label = label, amount = WCUtil.round2(amount) }
            total = total + amount
        end
    end
    if s.mode == 'store' then
        -- WCClothingStore.plan per worn category: an unowned item changed in any way (a dye of the
        -- worn uniform included) is bought, and a tint differing from the item's own colour is a dye
        local equipped, tints = s.working.clothing.equipped, s.working.clothing.tints
        local tintPrice = tonumber(s.context.tintPrice) or (Config.Clothing.tints and Config.Clothing.tints.price) or 0
        local dyes = {}
        for _, category in ipairs(WCUtil.sortedKeys(equipped)) do
            local hash, tint = equipped[category], tints[category]
            if isPurchase(s, category, hash, tint) then line(L(WCCatalog.label(category)), categoryPrice(s, category)) end
            -- the saved item with its saved tint is free even when its owned tint differs
            if type(tint) == 'table' and tint.palette and not untouched(s, category, hash, tint)
                and not sameTint(tint, baselineTint(s, category, hash)) then
                dyes[#dyes + 1] = category
            end
        end
        for _, category in ipairs(dyes) do line(L(K.color) .. ' · ' .. L(WCCatalog.label(category)), tintPrice) end
    elseif s.mode == 'barber' then
        local changed = AppearanceSchema.changedSections(s.saved, s.working)
        local services = type(s.context.services) == 'table' and s.context.services or
            (Config.Barber and Config.Barber.services) or {}
        -- the server caps the sum of the BASE prices, then applies the location multiplier; the
        -- context prices are already multiplied, so the cap is scaled by the same multiplier
        local base, multiplier = 0, tonumber(s.context.multiplier)
        local baseServices = Config.Barber and Config.Barber.services or {}
        local function service(name, sections, label)
            local cfg = services[name]
            if type(cfg) ~= 'table' or cfg.enabled == false then return end
            for _, section in ipairs(sections) do
                if changed[section] then
                    local b = type(baseServices[name]) == 'table' and tonumber(baseServices[name].price) or nil
                    local p = tonumber(cfg.price)
                    if b then base = base + b end
                    if not multiplier and b and b > 0 and p then multiplier = p / b end
                    return line(L(label), cfg.price)
                end
            end
        end
        service('hair', { 'hair' }, K.hair)
        service('facialHair', { 'facialHair' }, K.facialHair)
        service('details', { 'eyebrows', 'makeup' }, K.details)
        local ctxCap = tonumber(s.context.visitCap)
        local cap = Config.Barber and Config.Barber.prices and tonumber(Config.Barber.prices.visitCap)
        if ctxCap then
            if total > ctxCap then total = ctxCap end
        elseif cap and base > cap then
            total = cap * (multiplier or 1)
        end
    elseif s.mode == 'surgery' then
        if next(AppearanceSchema.changedSections(s.saved, s.working)) then
            line(L('عيادة التجميل'), s.context.price or (Config.CosmeticSurgery and Config.CosmeticSurgery.price))
        end
    else
        return nil
    end
    return { total = WCUtil.round2(total) or 0, lines = lines }
end

-- ---------------------------------------------------------------------
--  Mode trees
-- ---------------------------------------------------------------------
local function hairGroup(reg, s)
    if not sectionAllowed(s, 'hair') then return nil end
    local children = hairControls(reg, s, 'hair', 'style', 'hair')
    add(children, overlayGroup(reg, s, WCOverlays.byId.hairov))
    return group('hair', L(K.hair), children, { camera = 'hair' })
end

local function facialGroup(reg, s)
    if s.working.sex ~= 'male' or not sectionAllowed(s, 'facialHair') then return nil end
    local beard = group('facial.beard', L(K.beard), hairControls(reg, s, 'mustache', 'facial', 'facial'),
        { camera = 'facialHair' })
    local children = {}
    add(children, beard)
    add(children, overlayGroup(reg, s, WCOverlays.byId.beardstabble))
    return group('facialHair', L(K.facialHair), children, { camera = 'facialHair' })
end

local function skinGroup(reg, s)
    if not sectionAllowed(s, 'skin') then return nil end
    local children = {}
    add(children, skinTone(reg, s))
    for _, node in ipairs(overlayGroupsOf(reg, s, 'skin')) do children[#children + 1] = node end
    return group('skin', L(K.skin), children, { camera = 'face' })
end

local function makeupGroup(reg, s)
    if not sectionAllowed(s, 'makeup') then return nil end
    return group('makeup', L(K.makeup), overlayGroupsOf(reg, s, 'makeup'), { camera = 'face' })
end

local function morphStage(reg, s, id)
    local src = morphRoot(s, id)
    if not src then return nil end
    return morphNode(reg, s, src)
end

local function clothingStage(reg, s)
    if not sectionAllowed(s, 'clothing') then return nil end
    local _, cfg = startingCategories(s)
    if cfg.mode == 'presets' then
        return group('clothing', L(K.clothing), { starterPresets(reg, s) }, { camera = 'fullBody' })
    end
    return group('clothing', L(K.clothing), T.taxonomy(reg, s), { camera = 'fullBody', searchable = true })
end

--- The creator's stages: Config.Creator.stages, with 'identity' first when a new character is
--  created (s.opts.identity: the names can only be typed there, and Finish needs them) and
--  'review' last, whenever the config leaves them out (warned once).
local stagesWarned = false
function T.creatorStages(s)
    local configured = (Config.Creator and type(Config.Creator.stages) == 'table') and Config.Creator.stages or {}
    local stages, seen = {}, {}
    for _, stage in ipairs(configured) do
        if type(stage) == 'string' and not seen[stage] then
            seen[stage] = true
            stages[#stages + 1] = stage
        end
    end
    local missing = {}
    if s.opts.identity and not seen.identity then
        table.insert(stages, 1, 'identity')
        missing[#missing + 1] = 'identity'
    end
    if not seen.review then
        stages[#stages + 1] = 'review'
        missing[#missing + 1] = 'review'
    end
    if #missing > 0 and not stagesWarned then
        stagesWarned = true
        WCDebug.warn('editor', 'Config.Creator.stages has no %s stage: added', table.concat(missing, ' / '))
    end
    return stages
end

local function creatorTree(reg, s)
    local children = {}
    local stages = T.creatorStages(s)
    for _, stage in ipairs(stages) do
        if stage == 'identity' then
            if s.opts.identity then
                children[#children + 1] = { id = 'identity', kind = 'identity', label = L(K.identity), camera = 'fullBody' }
            end
        elseif stage == 'body' then add(children, morphStage(reg, s, 'body'))
        elseif stage == 'face' then add(children, morphStage(reg, s, 'face'))
        elseif stage == 'skin' then add(children, skinGroup(reg, s))
        elseif stage == 'hair' then add(children, hairGroup(reg, s))
        elseif stage == 'facialHair' then add(children, facialGroup(reg, s))
        elseif stage == 'makeup' then add(children, makeupGroup(reg, s))
        elseif stage == 'clothing' then add(children, clothingStage(reg, s))
        elseif stage == 'review' then children[#children + 1] = creatorReview(s)
        end
    end
    return children
end

local function surgeryTree(reg, s)
    -- every section the clinic allows (opts.sections); each builder is gated by its section
    local children = {}
    add(children, morphStage(reg, s, 'body'))
    add(children, morphStage(reg, s, 'face'))
    add(children, skinGroup(reg, s))
    add(children, hairGroup(reg, s))
    add(children, facialGroup(reg, s))
    add(children, makeupGroup(reg, s))
    if sectionAllowed(s, 'clothing') then
        add(children, group('clothing', L(K.clothing), T.taxonomy(reg, s), { camera = 'fullBody' }))
    end
    if #children > 0 then children[#children + 1] = changesReview(s, K.surgeryHint) end
    return children
end

local function barberTree(reg, s)
    local children = {}
    add(children, hairGroup(reg, s))
    add(children, facialGroup(reg, s))
    local details = {}
    if sectionAllowed(s, 'eyebrows') then add(details, overlayGroup(reg, s, WCOverlays.byId.eyebrows)) end
    if sectionAllowed(s, 'makeup') then
        for _, node in ipairs(overlayGroupsOf(reg, s, 'makeup')) do details[#details + 1] = node end
    end
    add(children, group('details', L(K.details), details, { camera = 'face' }))
    add(children, growthNode(s))
    return children
end

local function storeTree(reg, s)
    if not sectionAllowed(s, 'clothing') then return {} end
    return T.taxonomy(reg, s)
end

local function persists(groupId)
    local def = WCClothingStates.byId[groupId]
    return def ~= nil and def.persist == true
end

local function wardrobeTree(reg, s)
    local children = {}
    local outfits = outfitsNode(reg, s)
    if sectionAllowed(s, 'clothing') then
        -- Outfits is the 8th taxonomy group (§5.3): the saved outfits sit beside Head … Accessories
        local groups = T.taxonomy(reg, s)
        add(groups, outfits)
        add(children, group('items', L(K.clothing), groups, { camera = 'fullBody', searchable = true }))
    else
        add(children, outfits)
    end
    if sectionAllowed(s, 'states') then
        -- only the states a wardrobe commit saves (§5.5): a non-persisting state (the bandana) is
        -- runtime-only, changed through the clothing actions panel, and the server drops it from a
        -- wardrobe commit, so offering it here would preview a change that can never be saved
        local actions = T.clothingActions(s.working, reg, function(groupId, value)
            return {
                apply = function(app) app.clothing.states[groupId] = value end,
                hook = s.opts.onState and function() return s.opts.onState(groupId, value) end or nil,
            }
        end, persists)
        add(children, group('actions', L(K.states), actions, { camera = 'fullBody' }))
    end
    return children
end

local BUILDERS = { creator = creatorTree, surgery = surgeryTree, barber = barberTree, store = storeTree,
                   wardrobe = wardrobeTree }

--- Build the tree and the registry of a session.
function T.build(s)
    local reg = {}
    local builder = BUILDERS[s.mode]
    local children = builder and builder(reg, s) or {}
    local rootLabel = (s.mode == 'store' or s.mode == 'wardrobe') and K.clothing or K.root
    local root = group('root', L(rootLabel), children, {
        camera = s.opts.camera or (s.mode == 'barber' and 'hair') or (s.mode == 'surgery' and 'face') or 'fullBody',
        searchable = (s.mode == 'store') or nil,
    })
    return root, reg
end

--- The stage tabs of a tree (creator / surgery): the root's children.
function T.stages(s, root)
    if s.mode ~= 'creator' and s.mode ~= 'surgery' then return nil end
    local out = {}
    for _, child in ipairs(root.children) do
        out[#out + 1] = { id = child.id, label = child.label }
    end
    return out
end

--- Random creator appearance: valid face / body / hair only, moderate morphology (±0.25).
function T.randomize(app)
    local sex = app.sex
    local cats = WCCatalog.forSex(sex)
    local function model(category, cap)
        local cat = cats[category]
        if not cat or #cat.models == 0 then return nil end
        return math.random(1, math.min(#cat.models, cap or #cat.models))
    end
    local m = model('heads')
    if m then AppearanceSchema.setHead(app, m) end
    m = model('BODIES_UPPER')
    if m then AppearanceSchema.setBodyType(app, m) end
    local heads = cats.heads
    local head = heads and heads.hashes[app.head.head]
    if head then
        local variant = heads.models[head.model][math.random(1, #heads.models[head.model])]
        local tone = variant and tonumber(variant.name:match('_V_(%d+)'))
        if tone then AppearanceSchema.setSkinTone(app, tone) end
    end
    local eyeCat = cats.eyes
    if eyeCat and #eyeCat.models > 0 then
        local variants = eyeCat.models[math.random(1, #eyeCat.models)]
        app.head.eyes = variants[math.random(1, #variants)].hash
    end
    m = model('hair', sex == 'male' and 25 or 27)
    if m then
        local variants = cats.hair.models[m]
        app.hair.style = variants[math.random(1, #variants)].hash
    end
    app.morph = {}
    for _, field in ipairs(WCMorph.fields or {}) do
        local value = math.random(-25, 25) / 100
        if value ~= 0 then app.morph[field.id] = value + 0.0 end
    end
    return app
end

--- The labels of a camera preset / of the tree chrome (used by the editor's strings).
T.KEYS = K
