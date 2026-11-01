-- =====================================================================
--  shared/catalog.lua  —  WCCatalog
--  The single index of w_lib's player component catalogue (w.component.getFullPedComponentList()).
--  Built lazily, cached per sex, never rebuilt per click. Hashes are unsigned 32-bit (WCUtil.u32).
--
--  forSex(sex)[category] = {
--      models = { [m] = { { hash, name }, ... } },          -- m = 1.. over non-empty catalogue groups
--      hashes = { [hash] = { model, variant, name } },
--      legacy = { [g] = { { hash, name }, ... } },          -- split categories only (SPLIT_STYLES)
--  }
--  Model numbering matches the pre-v3 resource (empty groups are skipped) so legacy v1
--  { model, variant } appearances resolve to the same items. A category whose groups mix several
--  styles (SPLIT_STYLES: the beards) gets one model per style; its legacy values resolve through
--  `legacy`, the groups as the catalogue lists them.
-- =====================================================================

WCCatalog = {}
local C = WCCatalog

C.ESSENTIAL = { heads = true, eyes = true, teeth = true, BODIES_UPPER = true, BODIES_LOWER = true }
C.ESSENTIAL_LIST = { 'heads', 'eyes', 'teeth', 'BODIES_UPPER', 'BODIES_LOWER' }
-- Body parts: catalogue categories that are not clothing.
C.BODY_PARTS = { heads = true, eyes = true, teeth = true, BODIES_UPPER = true, BODIES_LOWER = true,
                 hair = true, mustache = true }

-- Labels of the body-part categories (clothing labels come from Config.Clothing.taxonomy).
local BODY_LABELS = {
    heads = 'الوجه', eyes = 'العينان', teeth = 'الأسنان', BODIES_UPPER = 'شكل الجسم',
    BODIES_LOWER = 'شكل الجسم', hair = 'الشعر', mustache = 'اللحية',
}

-- Hair / beard colour suffix (upper case) -> locale key
local COLOR_KEYS = {
    BLONDE = 'أشقر', LIGHT_BLONDE = 'أشقر فاتح', DARK_BLONDE = 'أشقر داكن', STRAWBERRY_BLONDE = 'أشقر فراولي',
    BROWN = 'بني', LIGHT_BROWN = 'بني فاتح', MEDIUM_BROWN = 'بني متوسط', DARKEST_BROWN = 'بني داكن جدًا',
    GINGER = 'أصهب', LIGHT_GINGER = 'أصهب فاتح', DARK_GINGER = 'أصهب داكن',
    GREY = 'رمادي', LIGHT_GREY = 'رمادي فاتح', DARK_GREY = 'رمادي داكن', UNCLE_GREY = 'رمادي فضي',
    SALT_PEPPER = 'ملح وفلفل', JET_BLACK = 'أسود فاحم',
}
C.COLOR_KEYS = COLOR_KEYS
-- The same colours in the catalogue's own order (as w_lib lists every named beard group).
local COLOR_ORDER = { 'BLONDE', 'BROWN', 'DARK_BLONDE', 'DARKEST_BROWN', 'DARK_GINGER', 'DARK_GREY', 'GINGER',
                      'GREY', 'JET_BLACK', 'LIGHT_BLONDE', 'LIGHT_BROWN', 'LIGHT_GINGER', 'LIGHT_GREY',
                      'MEDIUM_BROWN', 'SALT_PEPPER', 'STRAWBERRY_BLONDE', 'UNCLE_GREY' }

-- The game's style names of the hair, beard and teeth assets (the MP creator's names), keyed by
-- the asset's base name without the CLOTHING_ITEM_ prefix and the colour: 'M_HAIR_016' is every
-- colour of CLOTHING_ITEM_M_HAIR_016_<colour>. Values are dictionary keys. Teeth are the same for
-- both sexes (TEETH_nnn).
local STYLE_NAMES = {
    M_HAIR_001 = 'مفروق يسارًا بعناية', M_HAIR_002 = 'ممشّط للخلف', M_HAIR_003 = 'خفيف متراجع',
    M_HAIR_004 = 'كثيف مفروق من الوسط', M_HAIR_005 = 'طويل مفروق يمينًا', M_HAIR_006 = 'مفروق من الوسط متدرّج',
    M_HAIR_007 = 'قصير مرفوع', M_HAIR_008 = 'مربوط بخشونة', M_HAIR_009 = 'مفروق يمينًا بخشونة',
    M_HAIR_010 = 'أشعث مع صلع', M_HAIR_011 = 'طويل ملمّع للخلف', M_HAIR_012 = 'منفوش بالريح',
    M_HAIR_013 = 'قصّة جامحة', M_HAIR_014 = 'بومبادور متدرّج', M_HAIR_015 = 'أفرو مجعّد قصير',
    M_HAIR_016 = 'أفرو مجعّد', M_HAIR_017 = 'أفرو مجعّد طويل', M_HAIR_018 = 'ملمّع للخلف متدرّج',
    M_HAIR_019 = 'معقود بمنديل', M_HAIR_020 = 'تموّجات حتى الكتف', M_HAIR_021 = 'مجعّد مفروق يسارًا',
    M_HAIR_022 = 'ضفائر قصيرة', M_HAIR_023 = 'طويل مفروق من الوسط', M_HAIR_024 = 'ذيل حصان طويل',
    M_HAIR_025 = 'مربوط بجانبين محلوقين', M_HAIR_028 = 'مفروق من الوسط بعناية', M_HAIR_300 = 'غير ممشّط مع صلع',
    M_HAIR_302 = 'قصّة مَلِت',
    F_HAIR_001 = 'بومبادور', F_HAIR_002 = 'كعكة بخصلات متدلّية', F_HAIR_003 = 'كعكة ملفوفة',
    F_HAIR_004 = 'ذيل حصان مجعّد كثيف', F_HAIR_005 = 'ذيل حصان مجعّد ناعم', F_HAIR_006 = 'تموّجات طويلة مربوطة',
    F_HAIR_007 = 'تموّجات منطلقة', F_HAIR_008 = 'كعكة حلزونية منسدلة', F_HAIR_009 = 'خصلات متدلّية مصفّفة',
    F_HAIR_010 = 'طبقات ممشّطة', F_HAIR_011 = 'منفوش معقود', F_HAIR_012 = 'ضفيرتان جانبيتان',
    F_HAIR_013 = 'جديلة فوضوية', F_HAIR_014 = 'جديلة جانبية', F_HAIR_015 = 'تموّجات ملفوفة',
    F_HAIR_016 = 'كعكة ملتفّة مرتّبة', F_HAIR_017 = 'كعكة بضفيرة تاجية', F_HAIR_018 = 'أفرو طبيعي قصير',
    F_HAIR_019 = 'كعكتان مجعّدتان', F_HAIR_020 = 'طبقات بجوانب قصيرة', F_HAIR_021 = 'مربوط بمنديل',
    F_HAIR_022 = 'تجاعيد طويلة مربوطة', F_HAIR_023 = 'ضفيرة تاج قصيرة', F_HAIR_024 = 'تموّجات فوضوية',
    F_HAIR_025 = 'تموّجات طويلة منسدلة', F_HAIR_026 = 'جديلة مرتّبة', F_HAIR_027 = 'ضفائر قصيرة',
    F_HAIR_028 = 'ملمّع للخلف', F_HAIR_301 = 'خصلات متشابكة', F_HAIR_302 = 'قصّة مَلِت',
    M_BEARD_001 = 'شارب الفظّ', M_BEARD_002 = 'لحية الساقي', M_BEARD_003 = 'لحية الأستاذ',
    M_BEARD_004 = 'ستارة الذقن', M_BEARD_005 = 'لحية البحّار', M_BEARD_006 = 'لحية الجنرال',
    M_BEARD_007 = 'لحية الحطّاب', M_BEARD_008 = 'لحية الهولندي العجوز', M_BEARD_009 = 'لحية مشذّبة كالسياج',
    M_BEARD_010 = 'سوالف عريضة', M_BEARD_011 = 'لحية النبيل', M_BEARD_012 = 'لحية الريفي',
    M_BEARD_013 = 'لحية القسّ', M_BEARD_014 = 'لحية الجندي', M_BEARD_015 = 'السكسوكة',
    M_BEARD_016 = 'لحية الفارس', M_BEARD_017 = 'لحية الكونت', M_BEARD_018 = 'لحية الرائد',
    M_BEARD_019 = 'لحية مضفورة بالخرز', M_BEARD_020 = 'لحية القوس', M_BEARD_021 = 'لحية المقبض',
    M_BEARD_022 = 'لحية المستنير', M_BEARD_023 = 'لحية الشقّين', M_BEARD_024 = 'لحية الياقة',
    TEETH_000 = 'الأسنان المتينة', TEETH_001 = 'الأسنان المذهّبة', TEETH_002 = 'الأسنان البالية',
    TEETH_003 = 'أسنان الريفي', TEETH_004 = 'الأسنان المتهالكة', TEETH_005 = 'فم بلا أسنان',
    TEETH_006 = 'أسنان القروي',
}
C.STYLE_NAMES = STYLE_NAMES

--- The STYLE_NAMES key of an asset name ('CLOTHING_ITEM_M_HAIR_016_Blonde' -> 'M_HAIR_016'), or nil.
local function styleKeyOf(hashname)
    if type(hashname) ~= 'string' or hashname == '' then return nil end
    local upper = hashname:upper()
    local teeth = upper:match('^CLOTHING_ITEM_[MF]_(TEETH_%d+)')
    if teeth then return STYLE_NAMES[teeth] and teeth or nil end
    local base = upper:match('^CLOTHING_ITEM_([MF]_%u+_%d+)')
    return base and STYLE_NAMES[base] and base or nil
end

-- A few catalogue groups carry no asset names (only hashes): their style is found by hashing every
-- named base with every hair colour once (a lazy hash -> key index, with the asset name).
local hashStyle, hashName
local function hashIndex()
    if not hashStyle then
        hashStyle, hashName = {}, {}
        for base in pairs(STYLE_NAMES) do
            if base:find('_HAIR_') or base:find('_BEARD_') then
                for colour in pairs(COLOR_KEYS) do
                    local name = ('CLOTHING_ITEM_%s_%s'):format(base, colour)
                    local h = WCUtil.u32(GetHashKey(name))
                    if h then hashStyle[h], hashName[h] = base, name end
                end
            end
        end
    end
end
local function styleKeyOfHash(hash)
    hashIndex()
    return hashStyle[WCUtil.u32(hash) or -1]
end
--- The asset name of a nameless catalogue hash ('CLOTHING_ITEM_M_BEARD_019_BLONDE'), or nil.
local function nameOfHash(hash)
    hashIndex()
    return hashName[WCUtil.u32(hash) or -1]
end

--- The style-name key of one catalogue variant { hash, name }, or nil.
function C.variantStyleKey(variant)
    if type(variant) ~= 'table' then return nil end
    return styleKeyOf(variant.name) or styleKeyOfHash(variant.hash)
end

--- The translated name of a style (a catalogue model of hair / mustache / teeth): the game's name
--  when most of its variants are one named asset, else the numbered "<category> NN" label. A group
--  that mixes several styles keeps its number (the beard group that held six beards is split into
--  one model per beard, SPLIT_STYLES).
function C.styleName(sex, category, model)
    local cat = C.forSex(sex)[category]
    local variants = cat and cat.models[WCUtil.int(model, 1, nil, 0)] or nil
    if type(variants) == 'table' and #variants > 0 then
        local counts, best, bestN = {}, nil, 0
        for _, v in ipairs(variants) do
            local key = C.variantStyleKey(v)
            if key then
                counts[key] = (counts[key] or 0) + 1
                if counts[key] > bestN then best, bestN = key, counts[key] end
            end
        end
        if best and bestN * 10 >= #variants * 6 then
            local text = STYLE_NAMES[best]
            return type(locale) == 'function' and locale(text) or text
        end
    end
    return C.styleLabel(category, model)
end

--- The colour suffix of a hair / beard asset name ('..._HAIR_001_Blonde' -> 'BLONDE'), or nil.
function C.colorSuffix(hashname)
    if type(hashname) ~= 'string' then return nil end
    local upper = hashname:upper()
    return upper:match('_HAIR_%d+_(.+)$') or upper:match('_BEARD_%d+_(.+)$')
end

-- Categories whose catalogue groups can mix several styles. w_lib's last male beard group holds
-- M_BEARD_019..024 (17 colours each) mixed together, sorted by hash and without asset names, plus two
-- hashes of no known beard: as one model, every colour step put on another beard. Such a group is
-- split into one model per style (its colours in the catalogue's colour order) and one model per
-- variant of no known style, so a colour change never changes the shape. A nameless variant gets
-- its asset name back from its hash (colour label and swatch, the colour kept on a style change).
local SPLIT_STYLES = { mustache = true }

local COLOR_RANK = {}
for i, colour in ipairs(COLOR_ORDER) do COLOR_RANK[colour] = i end

--- The models of one catalogue group: the group itself when it is one style (or holds no known
--  style at all), else one model per style key in key order, then one per variant of no known style.
local function splitByStyle(variants)
    local byKey, keys, rest, pos = {}, {}, {}, {}
    for i, v in ipairs(variants) do
        pos[v] = i
        local key = C.variantStyleKey(v)
        if key then
            if not byKey[key] then
                byKey[key] = {}
                keys[#keys + 1] = key
            end
            local list = byKey[key]
            list[#list + 1] = v
        else
            rest[#rest + 1] = v
        end
    end
    if #keys == 0 or (#keys == 1 and #rest == 0) then return { variants } end
    table.sort(keys)
    local last = #COLOR_ORDER + 1
    local function before(a, b)
        local ra, rb = COLOR_RANK[C.colorSuffix(a.name) or ''] or last, COLOR_RANK[C.colorSuffix(b.name) or ''] or last
        if ra ~= rb then return ra < rb end
        return pos[a] < pos[b]
    end
    local out = {}
    for _, key in ipairs(keys) do
        table.sort(byKey[key], before)
        out[#out + 1] = byKey[key]
    end
    for _, v in ipairs(rest) do out[#out + 1] = { v } end
    return out
end

local cache = {}
local itemIndex = {}
local taxonomyIndex

local function rawCatalog()
    local ok, data = pcall(function() return w.component.getFullPedComponentList() end)
    if ok and type(data) == 'table' then return data end
    return nil
end

local function normSex(sex)
    if sex == 'male' or sex == 'female' then return sex end
    return nil
end

--- The indexed catalogue of one sex ('male' | 'female'). Empty table when unavailable (not cached).
function C.forSex(sex)
    sex = normSex(sex)
    if not sex then return {} end
    if cache[sex] then return cache[sex] end
    local data = rawCatalog()
    local source = data and data[sex]
    if type(source) ~= 'table' then return {} end
    local out, index = {}, {}
    for _, category in ipairs(WCUtil.sortedKeys(source)) do
        local groups = source[category]
        local entry = { models = {}, hashes = {} }
        local split = SPLIT_STYLES[category]
        if split then entry.legacy = {} end
        if type(groups) == 'table' then
            for _, group in ipairs(groups) do
                local variations = type(group) == 'table' and group.variations
                if type(variations) == 'table' and #variations > 0 then
                    local variants = {}
                    for _, variant in ipairs(variations) do
                        local hash = type(variant) == 'table' and WCUtil.u32(variant.hash)
                        if hash then
                            local name = type(variant.hashname) == 'string' and variant.hashname or ''
                            if name == '' and split then name = nameOfHash(hash) or '' end
                            variants[#variants + 1] = { hash = hash, name = name }
                            if not index[hash] then index[hash] = category end
                        end
                    end
                    if #variants > 0 then
                        -- the group as the catalogue lists it: the pre-v3 { model, variant } numbering
                        if split then entry.legacy[#entry.legacy + 1] = variants end
                        for _, part in ipairs(split and splitByStyle(variants) or { variants }) do
                            local model = #entry.models + 1
                            entry.models[model] = part
                            -- Every numeric variant keeps its position (pre-v3 numbering outside the
                            -- split categories); a duplicate hash maps to its last position, as before.
                            for i, v in ipairs(part) do
                                entry.hashes[v.hash] = { model = model, variant = i, name = v.name }
                            end
                        end
                    end
                end
            end
        end
        out[category] = entry
    end
    if next(out) then
        cache[sex] = out
        itemIndex[sex] = index
    end
    return out
end

--- Drop the cached index (tests / catalogue reload).
function C.reset()
    cache, itemIndex, taxonomyIndex = {}, {}, nil
end

--- A catalogue category of a sex, or nil.
function C.category(sex, category)
    return C.forSex(sex)[category]
end

--- Resolve a value to a u32 hash of `category` for `sex`, or nil.
--  Accepts a hash (signed/unsigned/numeric string), { hash = h } or a legacy { model, variant } array.
function C.resolve(sex, category, value)
    local cat = C.forSex(sex)[category]
    if not cat then return nil end
    if type(value) == 'table' and value.hash == nil then
        -- a split category keeps the catalogue's own numbering for these (cat.legacy)
        local model = (cat.legacy or cat.models)[WCUtil.int(value[1] or value.model, nil, nil, 0)]
        if not model then return nil end
        local variant = model[WCUtil.int(value[2] or value.variant, nil, nil, 1)]
        return variant and variant.hash or nil
    end
    local hash = WCUtil.u32(type(value) == 'table' and value.hash or value)
    if hash and cat.hashes[hash] then return hash end
    return nil
end

--- The hash of a starting-outfit item (Config.StartingOutfits): { category, item = 'ASSET_NAME' }
--  names the game's asset (stable whatever order the catalogue lists it in); { category, model,
--  variant } gives the 1-based catalogue position. nil when it does not resolve for the sex.
function C.presetHash(sex, item)
    if type(item) ~= 'table' or type(item.category) ~= 'string' then return nil end
    if type(item.item) == 'string' then return C.resolve(sex, item.category, GetHashKey(item.item)) end
    return C.resolve(sex, item.category, { model = item.model, variant = item.variant })
end

--- The catalogue item of a hash for a sex: { category, model, variant, name } or nil.
function C.item(sex, hash)
    hash = WCUtil.u32(hash)
    if not hash then return nil end
    local catalog = C.forSex(sex)
    local index = itemIndex[normSex(sex) or ''] or {}
    local category = index[hash]
    if not category then return nil end
    local info = catalog[category].hashes[hash]
    return { category = category, model = info.model, variant = info.variant, name = info.name }
end

local function taxonomy()
    if taxonomyIndex then return taxonomyIndex end
    local out = {}
    local tax = Config and Config.Clothing and Config.Clothing.taxonomy or {}
    for _, group in ipairs(tax) do
        for _, sub in ipairs(group.subs or {}) do
            local category = sub.category or sub.id
            if category and not out[category] then
                out[category] = { group = group.id, sub = sub.id, label = sub.label, camera = sub.camera,
                                  art = sub.art, sex = sub.sex }
            end
        end
    end
    taxonomyIndex = out
    return out
end

--- { group = <groupId>, sub = <subId> } for a clothing category (nil when not in the taxonomy).
function C.groupOf(category)
    local entry = taxonomy()[category]
    if not entry then return nil end
    return { group = entry.group, sub = entry.sub }
end

--- Is this a clothing category (not a body part, and known to the taxonomy or the catalogue)?
function C.isClothing(category)
    if type(category) ~= 'string' or C.BODY_PARTS[category] then return false end
    if taxonomy()[category] then return true end
    return C.forSex('male')[category] ~= nil or C.forSex('female')[category] ~= nil
end

--- Is a clothing category offered to a sex: the taxonomy's optional sex hint allows it and the
--  catalogue has items of that category for the sex (§5.3)?
function C.offered(sex, category)
    if not normSex(sex) or not C.isClothing(category) then return false end
    local entry = taxonomy()[category]
    if entry and entry.sex and entry.sex ~= sex then return false end
    local cat = C.forSex(sex)[category]
    return cat ~= nil and next(cat.models) ~= nil
end

--- The locale key of a category's label.
function C.label(category)
    local entry = taxonomy()[category]
    return (entry and entry.label) or BODY_LABELS[category] or tostring(category)
end

local function itemInCategory(category, hash)
    hash = WCUtil.u32(hash)
    if not hash then return false end
    for _, sex in ipairs({ 'male', 'female' }) do
        local cat = C.forSex(sex)[category]
        if cat and cat.hashes[hash] then return true end
    end
    return false
end

-- The currencies a price can name, in display order (WCEconomy maps them to the framework's ids).
C.CURRENCIES = { 'cash', 'gold' }
C.CURRENCY_SET = { cash = true, gold = true }

--- A price value of the config as { cash = n?, gold = n? }, or nil (not for sale): a number is cash,
--  a table names its currencies ({ cash = 5, gold = 0.2 } = either). A negative or non-finite amount
--  is left out.
function C.priceSpec(value)
    if type(value) == 'number' then
        if not WCUtil.isFinite(value) or value < 0 then return nil end
        return { cash = value }
    end
    if type(value) ~= 'table' then return nil end
    local out, any = {}, false
    for _, currency in ipairs(C.CURRENCIES) do
        local n = tonumber(value[currency])
        if WCUtil.isFinite(n) and n >= 0 then
            out[currency] = n
            any = true
        end
    end
    return any and out or nil
end

--- The catalogue model number of an item (the store's "<category> NN"), for a sex or, without one,
--  the first sex that has the item.
local function modelOf(sex, category, hash)
    local h = WCUtil.u32(hash)
    if not h then return nil end
    for _, s in ipairs(sex and { sex } or { 'male', 'female' }) do
        local cat = C.forSex(s)[category]
        local info = cat and cat.hashes[h]
        if info then return info.model end
    end
    return nil
end
C.modelOf = modelOf

--- The per-model price entry (Config.Clothing.modelPrices[sex][category][model]), or nil.
local function modelEntry(sex, category, model)
    local all = Config.Clothing and Config.Clothing.modelPrices
    if type(all) ~= 'table' or not model then return nil end
    for _, s in ipairs(sex and { sex } or { 'male', 'female' }) do
        local byCategory = type(all[s]) == 'table' and all[s][category] or nil
        local entry = type(byCategory) == 'table' and byCategory[model] or nil
        if entry ~= nil then return entry end
    end
    return nil
end

--- The per-model price entry that applies to an item (Config.Clothing.modelPrices), or nil.
function C.modelPriceEntry(sex, category, hash)
    return modelEntry(sex, category, modelOf(sex, category, hash))
end

--- The base price of an item before the pricing profile: the model's own price (or the category
--  price × its multiplier) over the category price. nil = not sold.
local function baseSpec(category, hash, sex)
    local prices = Config.Clothing and Config.Clothing.prices or {}
    local raw = prices[category]
    -- a negative category price withholds the whole category, whatever a model says
    if type(raw) == 'number' and raw < 0 then return nil end
    local spec = C.priceSpec(raw)
    local entry = hash ~= nil and modelEntry(sex, category, modelOf(sex, category, hash)) or nil
    if entry == nil then return spec end
    if type(entry) == 'number' and entry < 0 then return nil end
    if type(entry) == 'table' and entry.multiplier ~= nil then
        local m = tonumber(entry.multiplier)
        if not spec or not WCUtil.isFinite(m) or m < 0 then return nil end
        local out = {}
        for currency, n in pairs(spec) do out[currency] = n * m end
        return out
    end
    return C.priceSpec(entry)
end

--- Server-authoritative price of an item in every currency it is sold for: the base price (per model
--  or per category) × the pricing profile's multiplier, rounded to cents: { cash = n?, gold = n? }.
--  nil = not for sale (unknown category/item, a negative price, a withheld model, unknown profile).
function C.priceSpecOf(category, hash, pricingProfileId, sex)
    if hash ~= nil and not itemInCategory(category, hash) then return nil end
    local spec = baseSpec(category, hash, sex)
    if not spec then return nil end
    local profiles = Config.Clothing.pricingProfiles or {}
    local profile = profiles[pricingProfileId or 'standard']
    if type(profile) ~= 'table' then return nil end
    local multiplier = tonumber(profile.multiplier)
    if not WCUtil.isFinite(multiplier) or multiplier < 0 then return nil end
    local out = {}
    for currency, n in pairs(spec) do out[currency] = WCUtil.round2(n * multiplier) end
    return out
end

--- The price of an item in one currency ('cash' by default), or nil when it is not sold for it.
function C.priceIn(category, hash, pricingProfileId, sex, currency)
    local spec = C.priceSpecOf(category, hash, pricingProfileId, sex)
    return spec and spec[currency or 'cash'] or nil
end

--- Server-authoritative cash price of an item (the per-model price when the config names one):
--  base × pricing profile multiplier, rounded to cents. nil = not for sale for cash.
function C.price(category, hash, pricingProfileId, sex)
    return C.priceIn(category, hash, pricingProfileId, sex, 'cash')
end

--- The price of one colour an item does not own yet ({ cash = n?, gold = n? }), or nil when a new
--  colour is free (no price, or tints disabled).
function C.tintPriceSpec()
    local tints = Config.Clothing and Config.Clothing.tints or {}
    if tints.enabled == false then return nil end
    local spec = C.priceSpec(tints.price)
    if not spec then return nil end
    local out = {}
    for currency, n in pairs(spec) do out[currency] = WCUtil.round2(n) end
    return out
end

local function listed(list, category)
    if list == '*' then return true end
    if type(list) ~= 'table' then return false end
    for _, name in ipairs(list) do
        if name == category then return true end
    end
    return list[category] == true
end

--- Is the item sold by a store profile to this sex (offered to the sex + profile filters +
--  catalogue + price)?
function C.available(storeProfileId, sex, category, hash)
    local profiles = Config.Clothing and Config.Clothing.storeProfiles or {}
    local profile = profiles[storeProfileId or 'general']
    if type(profile) ~= 'table' then return false end
    if not C.offered(sex, category) then return false end
    if not listed(profile.include or '*', category) then return false end
    if profile.exclude and listed(profile.exclude, category) then return false end
    local cat = C.forSex(sex)[category]
    local h = WCUtil.u32(hash)
    local info = cat and h and cat.hashes[h]
    if not info then return false end
    local range = profile.models and profile.models[category]
    if type(range) == 'table' then
        local lo, hi = tonumber(range.min) or 1, tonumber(range.max) or math.huge
        if info.model < lo or info.model > hi then return false end
    end
    -- models the profile withholds (a job's uniform sold only in that job's own store)
    local restricted = type(profile.restricted) == 'table' and profile.restricted[category] or nil
    if type(restricted) == 'table' then
        for _, m in ipairs(restricted) do
            if tonumber(m) == info.model then return false end
        end
    end
    return C.priceSpecOf(category, h, 'standard', sex) ~= nil
end

local validPalettes

local function paletteSet()
    if validPalettes then return validPalettes end
    local ok, list = pcall(function() return w.component.data.palettes end)
    validPalettes = WCUtil.set(ok and list or {})
    return validPalettes
end

--- The palette names a category can be tinted with, or nil (not tintable / tints disabled).
function C.tintable(category)
    local tints = Config.Clothing and Config.Clothing.tints
    if type(tints) ~= 'table' or tints.enabled == false or not C.isClothing(category) then return nil end
    local list = tints.palettes and tints.palettes[category]
    if list == false then return nil end
    if type(list) ~= 'table' then list = tints.default end
    if type(list) ~= 'table' then return nil end
    local known, out = paletteSet(), {}
    for _, name in ipairs(list) do
        if known[name] then out[#out + 1] = name end
    end
    return #out > 0 and out or nil
end

local function tintValuesOk(tint)
    for _, key in ipairs({ 'tint0', 'tint1', 'tint2' }) do
        local v = tint[key]
        if type(v) ~= 'number' or not WCUtil.isFinite(v) or v % 1 ~= 0 or v < 0 or v > 254 then return false end
    end
    return true
end

--- The tint bounds of a palette (Config.Clothing.tints.limits[palette]): min, max (0..254) and the
--  set of disabled indices ({ [i] = true }). A palette without limits is 0, 254, {}.
function C.tintLimits(palette)
    local tints = Config.Clothing and Config.Clothing.tints or {}
    local limit = type(tints.limits) == 'table' and tints.limits[palette] or nil
    if type(limit) ~= 'table' then return 0, 254, {} end
    local lo = WCUtil.int(limit.min, 0, 254, 0)
    local hi = WCUtil.int(limit.max, 0, 254, 254)
    if hi < lo then lo, hi = hi, lo end
    local disabled = {}
    for _, i in ipairs(type(limit.disabled) == 'table' and limit.disabled or {}) do
        local n = WCUtil.int(i, 0, 254, nil)
        if n then disabled[n] = true end
    end
    return lo, hi, disabled
end

--- Is one tint index allowed by the palette's limits?
function C.tintIndexAllowed(palette, value)
    local lo, hi, disabled = C.tintLimits(palette)
    return type(value) == 'number' and value >= lo and value <= hi and not disabled[value]
end

--- Is `tint` a valid { palette, tint0, tint1, tint2 } for the category under the live
--  Config.Clothing.tints (enabled, the category's palette list, the palette's limits)? The rule for
--  NEW edits (store plan, SetClothes, owned tints, the editor, a changed tint in mergeSections).
function C.validTint(category, tint)
    if type(tint) ~= 'table' then return false end
    local palettes = C.tintable(category)
    if not palettes then return false end
    local found = false
    for _, name in ipairs(palettes) do
        if name == tint.palette then found = true break end
    end
    if not found then return false end
    if not tintValuesOk(tint) then return false end
    for _, key in ipairs({ 'tint0', 'tint1', 'tint2' }) do
        if not C.tintIndexAllowed(tint.palette, tint[key]) then return false end
    end
    return true
end

--- Is `tint` a structurally valid stored tint: a clothing category, a palette w_lib knows
--  (w.component.data.palettes) and integers 0..254? Independent of Config.Clothing.tints, so a
--  stored dye survives tints being disabled or a palette list narrowed (AppearanceSchema.sanitize
--  with rules = false; ARCHITECTURE.md §5.4). Whether it is drawn is the renderer's decision.
function C.validStoredTint(category, tint)
    if type(tint) ~= 'table' or type(tint.palette) ~= 'string' or not C.isClothing(category) then return false end
    if not paletteSet()[tint.palette] then return false end
    return tintValuesOk(tint)
end

--- The locale key of a hair/beard colour from its asset name (e.g. ..._HAIR_001_Blonde), or nil.
function C.colorKey(hashname)
    if type(hashname) ~= 'string' then return nil end
    local upper = hashname:upper()
    local suffix = upper:match('_HAIR_%d+_(.+)$') or upper:match('_BEARD_%d+_(.+)$')
    return suffix and COLOR_KEYS[suffix] or nil
end

--- The translated "<category label> <nn>" style label.
function C.styleLabel(category, model)
    local key = C.label(category)
    local text = type(locale) == 'function' and locale(key) or key
    return ('%s %02d'):format(tostring(text), WCUtil.int(model, 0, nil, 0))
end
