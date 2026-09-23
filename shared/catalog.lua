-- =====================================================================
--  shared/catalog.lua  —  WCCatalog
--  The single index of w_lib's player component catalogue (w.component.getFullPedComponentList()).
--  Built lazily, cached per sex, never rebuilt per click. Hashes are unsigned 32-bit (WCUtil.u32).
--
--  forSex(sex)[category] = {
--      models = { [m] = { { hash, name }, ... } },          -- m = 1.. over non-empty catalogue groups
--      hashes = { [hash] = { model, variant, name } },
--  }
--  Model numbering matches the pre-v3 resource (empty groups are skipped) so legacy v1
--  { model, variant } appearances resolve to the same items.
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
        if type(groups) == 'table' then
            for _, group in ipairs(groups) do
                local variations = type(group) == 'table' and group.variations
                if type(variations) == 'table' and #variations > 0 then
                    local model = #entry.models + 1
                    local variants = {}
                    for _, variant in ipairs(variations) do
                        local hash = type(variant) == 'table' and WCUtil.u32(variant.hash)
                        -- Every numeric variant keeps its position (pre-v3 numbering); a duplicate
                        -- hash maps to its last position, as before.
                        if hash then
                            local name = type(variant.hashname) == 'string' and variant.hashname or ''
                            variants[#variants + 1] = { hash = hash, name = name }
                            entry.hashes[hash] = { model = model, variant = #variants, name = name }
                            if not index[hash] then index[hash] = category end
                        end
                    end
                    if #variants > 0 then entry.models[model] = variants end
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
        local model = cat.models[WCUtil.int(value[1] or value.model, nil, nil, 0)]
        if not model then return nil end
        local variant = model[WCUtil.int(value[2] or value.variant, nil, nil, 1)]
        return variant and variant.hash or nil
    end
    local hash = WCUtil.u32(type(value) == 'table' and value.hash or value)
    if hash and cat.hashes[hash] then return hash end
    return nil
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

--- Server-authoritative price of an item: base × pricing profile multiplier, rounded to cents.
--  nil = not for sale (unknown category/item, negative base, unknown profile).
function C.price(category, hash, pricingProfileId)
    local prices = Config.Clothing and Config.Clothing.prices or {}
    local base = tonumber(prices[category])
    if not WCUtil.isFinite(base) or base < 0 then return nil end
    if hash ~= nil and not itemInCategory(category, hash) then return nil end
    local profiles = Config.Clothing.pricingProfiles or {}
    local profile = profiles[pricingProfileId or 'standard']
    if type(profile) ~= 'table' then return nil end
    local multiplier = tonumber(profile.multiplier)
    if not WCUtil.isFinite(multiplier) or multiplier < 0 then return nil end
    return WCUtil.round2(base * multiplier)
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
    return C.price(category, h, 'standard') ~= nil
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

--- Is `tint` a valid { palette, tint0, tint1, tint2 } for the category under the live
--  Config.Clothing.tints (enabled, the category's palette list)? The rule for NEW edits (store plan,
--  SetClothes, owned tints, the editor, a changed tint in mergeSections).
function C.validTint(category, tint)
    if type(tint) ~= 'table' then return false end
    local palettes = C.tintable(category)
    if not palettes then return false end
    local found = false
    for _, name in ipairs(palettes) do
        if name == tint.palette then found = true break end
    end
    if not found then return false end
    return tintValuesOk(tint)
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
