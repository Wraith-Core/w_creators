-- =====================================================================
--  shared/appearance.lua  —  AppearanceSchema (ARCHITECTURE.md §5.1)
--  The one authoritative appearance shape (v3), its defaults, validation, legacy conversion
--  (v1 { model, variant } arrays and v2 hash maps) and the section model used by every domain.
--
--  app = {
--    version = 3, sex = 'male' | 'female',
--    body = { upper = u32, lower = u32, height = 0.9..1.1, weight = 1..21, build = 1..5 | absent },
--    head = { head = u32, eyes = u32, teeth = u32, eyesTint = { tint0, tint1, tint2 } | absent },
--    morph = { [expressionName] = -1..1 },               -- 0 values omitted
--    hair = { style = u32 | 0, facial = u32 | 0 },        -- facial = 0 for female
--    overlays = { [layerId] = { style, color, opacity, color2?, color3?, matchHair?, extra? } },
--    clothing = { equipped = { [category] = u32 }, tints = { [category] = tint },
--                 states = { [groupId] = value }, outfit = id | nil },
--    grooming = { hair = { stage, seconds }, beard = { stage, seconds } },
--  }
-- =====================================================================

AppearanceSchema = {}
local S = AppearanceSchema

S.VERSION = 3
S.SECTIONS = { 'identity', 'body', 'face', 'eyebrows', 'skin', 'eyes', 'hair', 'facialHair', 'makeup',
               'clothing', 'states' }

--- The waist type metaped outfit hashes (signed); body.weight is the 1-based index. The client
--  renderer equips them (Appearance.WAIST_TYPES) and the server API exposes them as the framework
--  bridge's bodyWeight (WCApi.WAIST_TYPES): one list for both sides.
S.WAIST_TYPES = {
    -2045421226, -1745814259, -325933489, -1065791927, -844699484,
    -1273449080, 927185840, 149872391, 399015098, -644349862,
    1745919061, 1004225511, 1278600348, 502499352, -2093198664,
    -1837436619, 1736416063, 2040610690, -1173634986, -867801909,
    1960266524,
}

--- The body build metaped outfits (the game's MP builds, signed hashes); body.build is the 1-based
--  index: skinny, athletic, average, heavy, brawny. Absent = no build outfit (the look every
--  character had before builds existed, so a stored character renders unchanged). Equipped before
--  the waist outfit (Appearance.SetBuild); the server API exposes it as the bridge's bodyType.
S.BODY_BUILDS = { -1241887289, 61606861, -369348190, -20262001, 32611963 }
-- 2026-10-19 (owner): the voice -- the game's player vocal sets (pain, breath, effort): three tones per sex.
-- `voice` (1..VOICE_TONES) picks the tone; the male or female set follows `sex`, so they never disagree.
-- No `voice` = tone 1 of the character's sex (a woman made before this sounds like a woman now).
S.VOICE_TONES = 3
local function voiceTone(voice)
    local tone = tonumber(voice)
    if not tone or tone < 1 or tone > S.VOICE_TONES or tone ~= math.floor(tone) then return 1 end
    return tone
end
function S.vofxName(sex, voice)
    return ('VOFX_PLAYER_%s%02d'):format(sex == 'female' and 'FEMALE' or 'MALE', voiceTone(voice))
end
-- The SPEAKING voice: mp_male / mp_female have no voice group of their own (metapeds.ymt), so the game speaks
-- for them in JOHN's voice. These are game voices that carry the greet / insult lines (femga audio_banks,
-- aaron1a12/wild line coverage); tone 1 normal, 2 rough, 3 refined.
S.SPEECH_VOICES = {
    female = { '0537_A_F_M_CIV_WHITE_06', '0859_A_F_M_CIV_POOR_WHITE_AGGRESSIVE_01', '0056_A_F_M_BLWUPPERCLASS_01_WHITE_01' },
    male = { '0583_A_M_M_CIV_WHITE_07', '0657_A_M_M_CIV_POOR_WHITE_AGGRESSIVE_18', '0294_A_M_M_NBXUPPERCLASS_01_WHITE_02' },
}
function S.speechVoice(sex, voice)
    return S.SPEECH_VOICES[sex == 'female' and 'female' or 'male'][voiceTone(voice)]
end

--- The palette of a custom eye tint (head.eyesTint) and the highest tint index it takes.
S.EYE_PALETTE = 'metaped_tint_eye'
S.EYE_TINT_MAX = 127

-- The essential part -> the section it belongs to (meta.defaultsUsed reports sections).
local ESSENTIAL_SECTION = { heads = 'face', teeth = 'face', eyes = 'eyes', BODIES_UPPER = 'body',
                            BODIES_LOWER = 'body' }

-- Morph fields the pre-v3 creator stored as raw faceFeatures (by hash); every other morph field
-- was stored by name in components.__expressions. toLegacy keeps that split.
local LEGACY_FACE_FEATURES = WCUtil.set({
    'headWidth', 'eyelidWidth', 'eyelidHeight', 'eyebrowDepth', 'eyebrowWidth', 'eyebrowHeight',
    'earlobes', 'earsAngle', 'earsWidth', 'earsHeight', 'noseSize', 'noseAngle', 'noseCurvature',
    'nostrilsDistance', 'mouthDepth', 'mouthWidth', 'mouthX', 'mouthY', 'chinDepth', 'chinWidth',
    'chinHeight', 'jawHeight', 'cheekbonesHeight', 'upperLipDepth', 'upperLipWidth', 'upperLipHeight',
    'lowerLipDepth', 'lowerLipWidth', 'lowerLipHeight', 'eyesAngle', 'eyesDepth', 'eyesDistance',
    'eyesHeight', 'cheekbonesWidth', 'cheekbonesDepth', 'jawWidth', 'jawDepth', 'noseWidth', 'noseHeight',
})

local DEFAULT_HEIGHT, DEFAULT_WEIGHT = 1.0, 11
local MAX_GROWTH_SECONDS = 864000
local MAX_OUTFIT_ID = 2147483647

local function nameHash(name)
    return WCUtil.u32(GetHashKey(name))
end

--- The sex of a legacy row's isMale column (true / 1 / '1' / 'male' -> 'male').
function S.sexOf(isMale)
    if isMale == true or isMale == 1 or isMale == '1' or isMale == 'male' or isMale == 'true' then
        return 'male'
    end
    return 'female'
end

-- ---------------------------------------------------------------------
--  Defaults
-- ---------------------------------------------------------------------
local defaultCache = {}

local function pick(sex, category, name)
    local hash = name and WCCatalog.resolve(sex, category, nameHash(name))
    if hash then return hash end
    local cat = WCCatalog.forSex(sex)[category]
    local first = cat and cat.models[1] and cat.models[1][1]
    if first then return first.hash end
    return name and nameHash(name) or 0
end

--- The default parts of a sex: { heads, eyes, teeth, BODIES_UPPER, BODIES_LOWER, hair, clothing }.
function S.defaults(sex)
    if defaultCache[sex] then return defaultCache[sex] end
    local s = sex == 'male' and 'M' or 'F'
    local d = {
        heads = pick(sex, 'heads', ('CLOTHING_ITEM_%s_HEAD_%03d_V_001'):format(s, sex == 'male' and 8 or 1)),
        BODIES_UPPER = pick(sex, 'BODIES_UPPER', ('CLOTHING_ITEM_%s_BODIES_UPPER_001_V_001'):format(s)),
        BODIES_LOWER = pick(sex, 'BODIES_LOWER', ('CLOTHING_ITEM_%s_BODIES_LOWER_001_V_001'):format(s)),
        eyes = pick(sex, 'eyes', ('CLOTHING_ITEM_%s_EYES_001_TINT_014'):format(s)),
        teeth = pick(sex, 'teeth', ('CLOTHING_ITEM_%s_TEETH_000'):format(s)),
        hair = pick(sex, 'hair', ('CLOTHING_ITEM_%s_HAIR_001_BLONDE'):format(s)),
        clothing = {},
    }
    for _, category in ipairs({ 'shirts_full', 'pants', 'boots' }) do
        local cat = WCCatalog.forSex(sex)[category]
        if cat and cat.models[1] and cat.models[1][1] then d.clothing[category] = cat.models[1][1].hash end
    end
    if next(WCCatalog.forSex(sex)) then defaultCache[sex] = d end
    return d
end

--- A complete, valid v3 appearance for a sex.
function S.default(sex)
    sex = (sex == 'female') and 'female' or 'male'
    local d = S.defaults(sex)
    return {
        version = 3,
        sex = sex,
        body = { upper = d.BODIES_UPPER, lower = d.BODIES_LOWER, height = DEFAULT_HEIGHT, weight = DEFAULT_WEIGHT },
        head = { head = d.heads, eyes = d.eyes, teeth = d.teeth },
        morph = {},
        hair = { style = d.hair, facial = 0 },
        overlays = { eyebrows = { style = 1, color = 1, opacity = 0.85 } },
        clothing = { equipped = WCUtil.copy(d.clothing), tints = {}, states = {} },
        grooming = {},
    }
end

-- ---------------------------------------------------------------------
--  Skin tone: the shared _V_nnn variant of heads, BODIES_UPPER and BODIES_LOWER
-- ---------------------------------------------------------------------
local function info(sex, category, hash)
    local cat = WCCatalog.forSex(sex)[category]
    return cat and cat.hashes[WCUtil.u32(hash) or -1] or nil
end

local function toneOf(sex, category, hash)
    local i = info(sex, category, hash)
    return i and tonumber(i.name:match('_V_(%d+)')) or nil
end

local function withTone(sex, category, hash, tone)
    local i = info(sex, category, hash)
    if not i or i.name == '' or not tone then return nil end
    if not i.name:match('_V_%d+') then return nil end
    local name = i.name:gsub('_V_%d+', ('_V_%03d'):format(tone))
    return WCCatalog.resolve(sex, category, nameHash(name))
end

--- The skin tone (the head's _V_ number) or nil.
function S.skinTone(app)
    if type(app) ~= 'table' or type(app.head) ~= 'table' then return nil end
    return toneOf(app.sex, 'heads', app.head.head)
end

--- Rewrite head + both body parts to a tone. Returns true when the head took the tone.
function S.setSkinTone(app, tone)
    tone = WCUtil.int(tone, 1, 999, nil)
    if not tone or type(app) ~= 'table' then return false end
    local head = withTone(app.sex, 'heads', app.head.head, tone)
    local upper = withTone(app.sex, 'BODIES_UPPER', app.body.upper, tone)
    local lower = withTone(app.sex, 'BODIES_LOWER', app.body.lower, tone)
    if head then app.head.head = head end
    if upper then app.body.upper = upper end
    if lower then app.body.lower = lower end
    return head ~= nil
end

local function variantWithTone(variants, tone)
    for _, variant in ipairs(variants) do
        if tone and tonumber(variant.name:match('_V_(%d+)')) == tone then return variant end
    end
    return variants[math.min(math.max(tone or 1, 1), #variants)] or variants[1]
end

--- Body type = the BODIES_UPPER model; keeps the skin tone and pairs the lower body by name.
function S.setBodyType(app, model)
    local cat = WCCatalog.forSex(app.sex).BODIES_UPPER
    local variants = cat and cat.models[WCUtil.int(model, nil, nil, 0)]
    if not variants then return false end
    local tone = S.skinTone(app)
    local upper = variantWithTone(variants, tone)
    app.body.upper = upper.hash
    local lower = upper.name ~= '' and WCCatalog.resolve(app.sex, 'BODIES_LOWER', nameHash((upper.name:gsub('UPPER', 'LOWER'))))
    app.body.lower = lower or withTone(app.sex, 'BODIES_LOWER', app.body.lower, tone) or app.body.lower
    return true
end

--- Base head = the heads model; keeps the skin tone.
function S.setHead(app, model)
    local cat = WCCatalog.forSex(app.sex).heads
    local variants = cat and cat.models[WCUtil.int(model, nil, nil, 0)]
    if not variants then return false end
    local tone = S.skinTone(app)
    app.head.head = variantWithTone(variants, tone).hash
    return true
end

-- ---------------------------------------------------------------------
--  Validation
-- ---------------------------------------------------------------------
local function sanitizeGrooming(src)
    local out = {}
    if type(src) ~= 'table' then return out end
    for _, kind in ipairs({ 'hair', 'beard' }) do
        local g = src[kind]
        if type(g) == 'string' then g = WCUtil.decode(g) end
        if type(g) == 'table' then
            out[kind] = { stage = WCUtil.int(g.stage, 0, 99, 0),
                          seconds = WCUtil.number(g.seconds, 0, MAX_GROWTH_SECONDS, 0) }
        end
    end
    return out
end

local function tableOr(v) return type(v) == 'table' and v or {} end

local function exactInt(v, lo, hi)
    local n = tonumber(v)
    if not WCUtil.isFinite(n) or n % 1 ~= 0 or n < lo or n > hi then return nil end
    return math.tointeger(n)
end

--- A custom eye tint { tint0, tint1, tint2 } (integers 0..EYE_TINT_MAX) or nil.
function S.eyeTint(t)
    if type(t) ~= 'table' then return nil end
    local out = {}
    for _, key in ipairs({ 'tint0', 'tint1', 'tint2' }) do
        out[key] = exactInt(t[key], 0, S.EYE_TINT_MAX)
        if out[key] == nil then return nil end
    end
    return out
end

--- Copy an overlay's optional fields (WCOverlays: color2 / color3, matchHair, extra) from the
--  source `o` onto the sanitised `entry`, each only where the layer supports it; bad(field) reports
--  a value that is dropped.
function S.overlayExtras(entry, layer, o, bad)
    for n, key in ipairs({ 'color2', 'color3' }) do
        if o[key] ~= nil then
            local v = (layer.tints or 1) > n and WCOverlays.tintable(layer) and exactInt(o[key], 1, WCOverlays.COLORS)
            if v then entry[key] = v else bad(key) end
        end
    end
    if o.matchHair ~= nil and o.matchHair ~= false then
        if o.matchHair == true and layer.id == 'eyebrows' then entry.matchHair = true else bad('matchHair') end
    end
    if o.extra ~= nil then
        local list, max = {}, layer.extra or 0
        if type(o.extra) ~= 'table' or max == 0 then
            bad('extra')
        else
            for _, e in ipairs(o.extra) do
                local style = type(e) == 'table' and exactInt(e.style, 1, layer.styles) or nil
                if style and #list < max then
                    list[#list + 1] = { style = style, opacity = WCUtil.number(e.opacity, 0, 1, 1) + 0.0 }
                else
                    bad('extra')
                end
            end
        end
        if #list > 0 then entry.extra = list end
    end
end

--- Validate and repair an appearance. Returns app, violations, defaultsUsed (sections).
--  Every hash is checked against WCCatalog for the sex, numbers are clamped, unknown keys are
--  dropped, essentials are enforced (defaults) and WCRules applied.
--  opts.sex      authoritative sex ('male' | 'female'): overrides the input's sex (the server-granted
--                creation session, the saved character); without it the input's sex is used.
--  opts.rules    false = keep the equipped set as stored (WCRules not applied). Persisted data is
--                read and written with rules = false; the rules apply where the player edits
--                (mergeSections, equip) so a rule never silently drops stored clothing.
--                rules = false also checks tints structurally only (WCCatalog.validStoredTint): a
--                stored dye survives Config.Clothing.tints being disabled or narrowed. The live tint
--                config (WCCatalog.validTint) applies to the default (edit) mode and to changed
--                tints in mergeSections.
--                rules = false also keeps a stored overlay layer of the other sex (pre-v3 data).
--  opts.grooming false = drop the input's grooming (server-owned; client-submitted appearances).
function S.sanitize(app, opts)
    opts = type(opts) == 'table' and opts or {}
    local src = tableOr(app)
    local violations, defaultsSet = {}, {}
    local function violate(field, reason) violations[#violations + 1] = { field = field, reason = reason } end

    local sex = src.sex
    local forced = (opts.sex == 'male' or opts.sex == 'female') and opts.sex or nil
    if sex ~= 'male' and sex ~= 'female' then
        violate('sex', 'invalid')
        sex = forced or 'male'
    elseif forced and sex ~= forced then
        violate('sex', 'overridden')
        sex = forced
    end
    local d = S.defaults(sex)

    local function essential(category, value)
        local hash = WCCatalog.resolve(sex, category, value)
        if hash then return hash end
        violate(category, value == nil and 'missing' or 'invalid')
        defaultsSet[ESSENTIAL_SECTION[category]] = true
        return d[category]
    end

    local body, head = tableOr(src.body), tableOr(src.head)
    local out = { version = S.VERSION, sex = sex }
    out.body = {
        upper = essential('BODIES_UPPER', body.upper),
        lower = essential('BODIES_LOWER', body.lower),
        height = WCUtil.number(body.height, 0.9, 1.1, DEFAULT_HEIGHT) + 0.0,
        weight = WCUtil.int(body.weight, 1, 21, DEFAULT_WEIGHT),
    }
    out.head = {
        head = essential('heads', head.head),
        eyes = essential('eyes', head.eyes),
        teeth = essential('teeth', head.teeth),
    }
    -- the optional fields exist only when set, so an appearance without them sanitises to exactly
    -- what it was before they were added
    if body.build ~= nil and body.build ~= 0 then
        local build = WCUtil.int(body.build, 1, #S.BODY_BUILDS, nil)
        if build and build == tonumber(body.build) then out.body.build = build else violate('body.build', 'invalid') end
    end
    if head.eyesTint ~= nil then
        local tint = S.eyeTint(head.eyesTint)
        if tint then out.head.eyesTint = tint else violate('eyes.tint', 'invalid') end
    end
    if src.voice ~= nil then
        local voice = WCUtil.int(src.voice, 1, S.VOICE_TONES, nil)
        if voice and voice == tonumber(src.voice) then out.voice = voice else violate('voice', 'invalid') end
    end

    -- Skin tone repair: the bodies adopt the head's tone.
    local tone = toneOf(sex, 'heads', out.head.head)
    if tone then
        for _, part in ipairs({ { 'BODIES_UPPER', 'upper' }, { 'BODIES_LOWER', 'lower' } }) do
            local current = toneOf(sex, part[1], out.body[part[2]])
            if current and current ~= tone then
                local fixed = withTone(sex, part[1], out.body[part[2]], tone)
                if fixed then
                    out.body[part[2]] = fixed
                    violate(part[1], 'tone')
                else
                    -- This body model has no variant in the head's tone: reported, not guessed.
                    violate(part[1], 'tone_unavailable')
                end
            end
        end
    end

    out.morph = {}
    for id, value in pairs(tableOr(src.morph)) do
        if WCMorph.byId[id] then
            local n = WCUtil.number(value, -1, 1, nil)
            if n == nil then violate('morph.' .. tostring(id), 'invalid')
            elseif n ~= 0 then out.morph[id] = n + 0.0 end
        elseif id ~= nil then
            violate('morph.' .. tostring(id), 'unknown')
        end
    end

    local hair = tableOr(src.hair)
    out.hair = { style = 0, facial = 0 }
    if hair.style ~= nil and hair.style ~= 0 then
        out.hair.style = WCCatalog.resolve(sex, 'hair', hair.style) or 0
        if out.hair.style == 0 then violate('hair', 'invalid') end
    end
    if hair.facial ~= nil and hair.facial ~= 0 then
        out.hair.facial = sex == 'male' and WCCatalog.resolve(sex, 'mustache', hair.facial) or 0
        if out.hair.facial == 0 then violate('mustache', 'invalid') end
    end

    out.overlays = {}
    for id, o in pairs(tableOr(src.overlays)) do
        local layer = WCOverlays.byId[id]
        -- Stored data (rules = false) keeps a layer of the other sex: the pre-v3 creator offered
        -- every layer to both sexes (a female's beard shadow), and an upgrade never drops it silently.
        -- The editors never add one (mergeSections keeps such a layer as saved).
        if layer and (layer.sexes[sex] or opts.rules == false) and type(o) == 'table' then
            local style = WCUtil.int(o.style, nil, nil, nil)
            if style and style >= 1 then
                local entry = {
                    style = math.min(style, layer.styles),
                    -- a layer drawn without its palette stores colour 1: its colour never shows, so a
                    -- colour-only change is no change (never charged, NO_CHANGES)
                    color = WCOverlays.tintable(layer) and WCUtil.int(o.color, 1, WCOverlays.COLORS, 1) or 1,
                    opacity = WCUtil.number(o.opacity, 0, 1, 1) + 0.0,
                }
                S.overlayExtras(entry, layer, o, function(field) violate('overlay.' .. tostring(id) .. '.' .. field, 'invalid') end)
                out.overlays[id] = entry
            end
        else
            violate('overlay.' .. tostring(id), 'invalid')
        end
    end

    local clothing = tableOr(src.clothing)
    local equipped = {}
    for category, value in pairs(tableOr(clothing.equipped)) do
        if value ~= 0 and value ~= nil then
            local hash = WCCatalog.isClothing(category) and WCCatalog.resolve(sex, category, value) or nil
            if hash then equipped[category] = hash else violate('clothing.' .. tostring(category), 'invalid') end
        end
    end
    local ruled = equipped
    if opts.rules ~= false then
        local ruleViolations
        ruled, ruleViolations = WCRules.normalize(equipped)
        for _, v in ipairs(ruleViolations) do violate('clothing.' .. v.category, v.reason) end
    end
    out.clothing = { equipped = ruled, tints = {}, states = {} }
    local tintOk = opts.rules == false and WCCatalog.validStoredTint or WCCatalog.validTint
    for category, tint in pairs(tableOr(clothing.tints)) do
        if ruled[category] and tintOk(category, tint) then
            out.clothing.tints[category] = { palette = tint.palette, tint0 = math.tointeger(tint.tint0),
                                             tint1 = math.tointeger(tint.tint1), tint2 = math.tointeger(tint.tint2) }
        else
            violate('tint.' .. tostring(category), 'invalid')
        end
    end
    for group, value in pairs(tableOr(clothing.states)) do
        local def = WCClothingStates and WCClothingStates.byId[group]
        if def and def.persist and WCClothingStates.isValid(group, value) then
            out.clothing.states[group] = value
        else
            violate('state.' .. tostring(group), 'invalid')
        end
    end
    out.clothing.outfit = WCUtil.int(clothing.outfit, 1, MAX_OUTFIT_ID, nil)

    out.grooming = opts.grooming == false and {} or sanitizeGrooming(src.grooming)

    local defaultsUsed = {}
    for _, section in ipairs(S.SECTIONS) do
        if defaultsSet[section] then defaultsUsed[#defaultsUsed + 1] = section end
    end
    return out, violations, defaultsUsed
end

-- ---------------------------------------------------------------------
--  Legacy conversion
-- ---------------------------------------------------------------------

--- Convert a legacy row { isMale, components, faceFeatures, overlays } (v1 { model, variant }
--  arrays or v2 hashes, JSON strings or tables) to v3.
--  The equipped clothing is kept as the pre-v3 renderer drew it: WCRules (new in v3) are not
--  applied, so a legacy combination the new rules forbid is never dropped by the conversion.
--  Returns app, meta = { version = 1|2, defaultsUsed = { section... }, violations = {...},
--                        dropped = { category... } (clothing that is not in the catalogue) }.
function S.fromLegacy(row)
    row = WCUtil.decode(row)
    local sex = S.sexOf(row.isMale)
    local comps = WCUtil.decode(row.components)
    local d = S.defaults(sex)
    local defaultsSet = {}

    local version = 2
    for key, value in pairs(comps) do
        if type(key) == 'string' and key:sub(1, 2) ~= '__' and type(value) == 'table' and value.hash == nil then
            version = 1
            break
        end
    end

    local function part(category)
        local value = comps[category]
        if value == nil then return nil end
        return WCCatalog.resolve(sex, category, value)
    end
    local function essential(category)
        local hash = part(category)
        if hash then return hash end
        defaultsSet[ESSENTIAL_SECTION[category]] = true
        return d[category]
    end

    local app = { version = S.VERSION, sex = sex, morph = {}, overlays = {},
                  clothing = { equipped = {}, tints = {}, states = {} } }
    app.head = { head = essential('heads'), eyes = essential('eyes'), teeth = essential('teeth'),
                 eyesTint = comps.__eyesTint }
    local upper = essential('BODIES_UPPER')
    local lower = part('BODIES_LOWER')
    if not lower and comps.BODIES_LOWER == nil then
        -- Old creators stored only the upper body: pair the lower body by the asset name.
        local i = info(sex, 'BODIES_UPPER', upper)
        if i and i.name ~= '' then
            lower = WCCatalog.resolve(sex, 'BODIES_LOWER', nameHash((i.name:gsub('UPPER', 'LOWER'))))
        end
    end
    if not lower then
        defaultsSet.body = true
        lower = d.BODIES_LOWER
    end
    app.body = {
        upper = upper, lower = lower,
        height = WCUtil.number(comps.__scale, 0.9, 1.1, DEFAULT_HEIGHT),
        weight = WCUtil.int(comps.__waist, 1, 21, DEFAULT_WEIGHT),
        build = comps.__build,
    }
    app.voice = comps.__voice

    local hair = comps.hair == nil and d.hair or (part('hair') or 0)
    app.hair = { style = hair, facial = sex == 'male' and (part('mustache') or 0) or 0 }

    -- Morphology: components.__expressions (by name) and faceFeatures (by expression id) merge into
    -- one map; faceFeatures win for the same field.
    for name, value in pairs(WCUtil.decode(comps.__expressions)) do
        if WCMorph.byId[name] then app.morph[name] = value end
    end
    for _, feature in pairs(WCUtil.decode(row.faceFeatures)) do
        local hash = type(feature) == 'table' and tonumber(feature.hash)
        local field = hash and WCMorph.byExpression[hash]
        if field then app.morph[field.id] = feature.index end
    end

    if row.overlays == nil then
        app.overlays.eyebrows = { style = 1, color = 1, opacity = 0.85 }
    else
        for _, item in pairs(WCUtil.decode(row.overlays)) do
            local layer = type(item) == 'table' and WCOverlays.byId[item.compType]
            local style = layer and WCUtil.int(item.offsetModel, nil, nil, 0) or 0
            if layer and style >= 1 and not app.overlays[layer.id] then
                app.overlays[layer.id] = { style = style, color = item.offsetVariation, opacity = item.opacity }
            end
        end
    end

    local dropped = {}
    for category, value in pairs(comps) do
        if type(category) == 'string' and category:sub(1, 2) ~= '__' and WCCatalog.isClothing(category) then
            local hash = value ~= 0 and WCCatalog.resolve(sex, category, value) or nil
            if hash then app.clothing.equipped[category] = hash
            elseif value ~= 0 and value ~= nil then dropped[#dropped + 1] = category end
        end
    end
    table.sort(dropped)

    app.grooming = WCUtil.decode(comps.__grooming)

    local out, violations, sanitizeDefaults = S.sanitize(app, { sex = sex, rules = false })
    for _, section in ipairs(sanitizeDefaults) do defaultsSet[section] = true end
    local defaultsUsed = {}
    for _, section in ipairs(S.SECTIONS) do
        if defaultsSet[section] then defaultsUsed[#defaultsUsed + 1] = section end
    end
    return out, { version = version, defaultsUsed = defaultsUsed, violations = violations, dropped = dropped }
end

--- Any input -> v3. Accepts a v3 table, a JSON string or a legacy row. Never throws.
--  Returns app, meta (meta.version = the source version, meta.defaultsUsed = sections).
function S.normalize(raw)
    local ok, app, meta = pcall(function()
        local data = raw
        if type(data) == 'string' then data = WCUtil.decode(data) end
        if type(data) ~= 'table' or next(data) == nil then
            return S.default('male'), { version = 0, defaultsUsed = { 'body', 'face', 'eyes' }, violations = {} }
        end
        if tonumber(data.version) == S.VERSION then
            local out, violations, defaultsUsed = S.sanitize(data, { rules = false })
            return out, { version = S.VERSION, defaultsUsed = defaultsUsed, violations = violations }
        end
        return S.fromLegacy(data)
    end)
    if ok and type(app) == 'table' then return app, meta end
    WCDebug.warn('appearance', 'appearance normalisation failed: %s', tostring(app))
    return S.default('male'), { version = 0, defaultsUsed = { 'body', 'face', 'eyes' }, violations = {},
                                error = tostring(app) }
end

--- The derived compatibility projection (§6.1): { isMale = 0|1, components, faceFeatures, overlays }
--  as JSON strings in the v2 shape, so a rollback to the previous release still loads the character.
function S.toLegacy(app)
    app = S.sanitize(app, { rules = false })
    local comps = {
        heads = app.head.head, eyes = app.head.eyes, teeth = app.head.teeth,
        BODIES_UPPER = app.body.upper, BODIES_LOWER = app.body.lower,
        hair = app.hair.style,
    }
    if app.sex == 'male' then comps.mustache = app.hair.facial end
    for category, hash in pairs(app.clothing.equipped) do comps[category] = hash end
    comps.__version = 2
    comps.__scale = app.body.height
    comps.__waist = app.body.weight
    -- the newer optional fields ride along (the previous release ignores them; a later upgrade of
    -- this row gets them back through fromLegacy)
    comps.__build = app.body.build
    comps.__voice = app.voice
    comps.__eyesTint = app.head.eyesTint and WCUtil.copy(app.head.eyesTint) or nil
    comps.__expressions = {}
    comps.__grooming = WCUtil.copy(app.grooming)
    local features = {}
    for id, value in pairs(app.morph) do
        if LEGACY_FACE_FEATURES[id] then
            features[#features + 1] = { hash = WCMorph.byId[id].expression, index = value }
        else
            comps.__expressions[id] = value
        end
    end
    table.sort(features, function(a, b) return a.hash < b.hash end)
    local overlays = {}
    for _, layer in ipairs(WCOverlays.layers) do
        local o = app.overlays[layer.id]
        if o then
            overlays[#overlays + 1] = { compType = layer.id, offsetModel = o.style,
                                        offsetVariation = o.color, opacity = o.opacity }
        end
    end
    return {
        isMale = app.sex == 'male' and 1 or 0,
        components = WCUtil.encode(comps) or '{}',
        faceFeatures = WCUtil.encode(features) or '[]',
        overlays = WCUtil.encode(overlays) or '[]',
    }
end

-- ---------------------------------------------------------------------
--  Sections
-- ---------------------------------------------------------------------
local function morphOf(app, section)
    local out = {}
    for id, value in pairs(app.morph) do
        if WCMorph.sectionOf(id) == section then out[id] = value end
    end
    return out
end

local function overlaysOf(app, section)
    local out = {}
    for id, value in pairs(app.overlays) do
        if WCOverlays.sectionOf(id) == section then out[id] = value end
    end
    return out
end

local function modelOf(sex, category, hash)
    local i = info(sex, category, hash)
    return i and i.model or hash
end

-- The tone-independent projection of one section (used by changedSections).
local function project(app, section)
    if section == 'body' then
        return { modelOf(app.sex, 'BODIES_UPPER', app.body.upper), modelOf(app.sex, 'BODIES_LOWER', app.body.lower),
                 app.body.height, app.body.weight, morphOf(app, 'body'), app.body.build or 0, app.voice or 1 }
    elseif section == 'face' then
        return { modelOf(app.sex, 'heads', app.head.head), app.head.teeth, morphOf(app, 'face') }
    elseif section == 'skin' then
        return { S.skinTone(app) or app.head.head, overlaysOf(app, 'skin') }
    elseif section == 'eyes' then
        return { app.head.eyes, app.head.eyesTint or false }
    elseif section == 'eyebrows' then
        return { overlaysOf(app, 'eyebrows') }
    elseif section == 'hair' then
        return { app.hair.style, overlaysOf(app, 'hair') }
    elseif section == 'facialHair' then
        return { app.hair.facial, overlaysOf(app, 'facialHair') }
    elseif section == 'makeup' then
        return { overlaysOf(app, 'makeup') }
    elseif section == 'clothing' then
        return { app.clothing.equipped, app.clothing.tints, app.clothing.outfit or false }
    elseif section == 'states' then
        return { app.clothing.states }
    end
    return {}
end

--- The set { [section] = true } of sections that differ between two appearances.
function S.changedSections(a, b)
    a, b = S.sanitize(a, { rules = false }), S.sanitize(b, { rules = false })
    local out = {}
    for _, section in ipairs(S.SECTIONS) do
        if section ~= 'identity' and (a.sex ~= b.sex or not WCUtil.deepEqual(project(a, section), project(b, section))) then
            out[section] = true
        end
    end
    return out
end

--- Merge: only the `allowed` sections are taken from `submitted`; everything else (and grooming,
--  which is server-owned) comes from `saved`. The sex never changes. The result is sanitized.
--  WCRules apply to the submitted clothing only when it differs from the saved set (an untouched
--  saved set is kept as stored). A skin tone never changes unless `skin` is allowed: a submitted
--  head or body model that has no variant in the kept tone falls back to the saved part.
--  allowed: a list { 'hair', ... } or a set { hair = true }.
--  opts.storedTints { [category] = tint }: stored dyes the caller vouches for (an owned item's dye,
--  WCOwnership.tintOf): a submitted tint equal to it is kept as stored (structural check only, like
--  the saved item's saved dye), never re-validated against the live Config.Clothing.tints.
function S.mergeSections(saved, submitted, allowed, opts)
    local storedTints = type(opts) == 'table' and type(opts.storedTints) == 'table' and opts.storedTints or {}
    local base = S.sanitize(saved, { rules = false })
    local draft = WCUtil.copy(tableOr(submitted))
    draft.sex, draft.version = base.sex, S.VERSION
    -- An invalid submitted essential falls back to the saved part, never to a default.
    draft.body, draft.head = tableOr(draft.body), tableOr(draft.head)
    for _, e in ipairs({ { draft.body, 'upper', 'BODIES_UPPER', base.body.upper },
                         { draft.body, 'lower', 'BODIES_LOWER', base.body.lower },
                         { draft.head, 'head', 'heads', base.head.head },
                         { draft.head, 'eyes', 'eyes', base.head.eyes },
                         { draft.head, 'teeth', 'teeth', base.head.teeth } }) do
        if not WCCatalog.resolve(base.sex, e[3], e[1][e[2]]) then e[1][e[2]] = e[4] end
    end
    local sub = S.sanitize(draft, { sex = base.sex, rules = false })
    allowed = WCUtil.set(allowed)
    local out = WCUtil.copy(base)

    local function takeMorph(section)
        for id in pairs(morphOf(out, section)) do out.morph[id] = nil end
        for id, value in pairs(morphOf(sub, section)) do out.morph[id] = value end
    end

    if allowed.body then
        out.body = WCUtil.copy(sub.body)
        takeMorph('body')
        -- the voice belongs to the body (the surgeon may change it); a submission without one (SetSkin, a
        -- repair) keeps the saved voice
        if sub.voice ~= nil then out.voice = sub.voice end
    end
    if allowed.face then
        out.head.head = sub.head.head
        out.head.teeth = sub.head.teeth
        takeMorph('face')
    end
    if allowed.eyes then
        out.head.eyes = sub.head.eyes
        out.head.eyesTint = sub.head.eyesTint and WCUtil.copy(sub.head.eyesTint) or nil
    end
    if allowed.hair then out.hair.style = sub.hair.style end
    if allowed.facialHair then out.hair.facial = sub.hair.facial end
    for _, layer in ipairs(WCOverlays.layers) do
        -- a layer of the other sex is only ever kept as stored, never taken from a submission
        if allowed[layer.section] and layer.sexes[base.sex] then
            out.overlays[layer.id] = WCUtil.copy(sub.overlays[layer.id])
        end
    end
    if allowed.clothing then
        local equipped = WCUtil.copy(sub.clothing.equipped)
        if not WCUtil.deepEqual(equipped, base.clothing.equipped) then equipped = WCRules.normalize(equipped) end
        out.clothing.equipped = equipped
        out.clothing.tints = {}
        for category, tint in pairs(sub.clothing.tints) do
            -- A saved item with its saved tint, or an item with the stored dye the caller vouches for
            -- (its owned tint), keeps it as stored; any other (new) tint must satisfy the live
            -- Config.Clothing.tints (enabled, the category's palettes).
            local kept = (equipped[category] == base.clothing.equipped[category]
                    and WCUtil.deepEqual(tint, base.clothing.tints[category]))
                or (storedTints[category] ~= nil and WCUtil.deepEqual(tint, storedTints[category]))
            if equipped[category] and (kept or WCCatalog.validTint(category, tint)) then
                out.clothing.tints[category] = WCUtil.copy(tint)
            end
        end
        out.clothing.outfit = sub.clothing.outfit
    end
    if allowed.states then out.clothing.states = WCUtil.copy(sub.clothing.states) end

    local tone = allowed.skin and S.skinTone(sub) or S.skinTone(base)
    if tone then
        S.setSkinTone(out, tone)
        -- A part whose model has no variant in that tone would carry another tone: keep the saved
        -- model (re-toned) instead, so the tone only ever changes through the skin section.
        local function off(category, hash)
            local t = toneOf(out.sex, category, hash)
            return t ~= nil and t ~= tone
        end
        if off('heads', out.head.head) then out.head.head = base.head.head end
        if off('BODIES_UPPER', out.body.upper) or off('BODIES_LOWER', out.body.lower) then
            out.body.upper, out.body.lower = base.body.upper, base.body.lower
        end
        S.setSkinTone(out, tone)
    end

    return (S.sanitize(out, { rules = false }))
end

--- Structural equality of two appearances.
function S.equal(a, b)
    return WCUtil.deepEqual(a, b)
end

--- Equip (hash) or remove (0/nil) one clothing category through WCRules. Mutates app.
--  Returns app, removedCategories, errorCode (INVALID_COMPONENT when the category is not a clothing
--  category or the hash is not an item of that category for the sex; app is unchanged then).
function S.equip(app, category, hash)
    if type(category) ~= 'string' or not WCCatalog.isClothing(category) then return app, {}, 'INVALID_COMPONENT' end
    if hash ~= nil and hash ~= 0 then
        local resolved = WCCatalog.isClothing(category) and WCCatalog.resolve(app.sex, category, hash)
        if not resolved then return app, {}, 'INVALID_COMPONENT' end
        hash = resolved
    end
    local equipped, removed = WCRules.equip(app.clothing.equipped, category, hash)
    app.clothing.equipped = equipped
    for _, name in ipairs(removed) do app.clothing.tints[name] = nil end
    if not equipped[category] then app.clothing.tints[category] = nil end
    return app, removed, nil
end
