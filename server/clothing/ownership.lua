-- =====================================================================
--  server/clothing/ownership.lua  —  WCOwnership (ARCHITECTURE.md §3.3, §5.4, §5.6)
--  Owned clothing: w_creators_clothes(charid, hash, category, palette, tint0..2, source,
--  acquired_at, price_paid, currency), unique (charid, hash). Sources: store | starter | legacy |
--  admin | gift. The row's palette columns are the colour the item was last worn in.
--  Owned colours (colourways): w_creators_colorways(charid, hash, palette, tint0..2, price_paid,
--  currency, acquired_at), unique (charid, hash, palette, tint0..2): every colour of an item the
--  character bought (or was given). The item's original colour is always owned with the item. The
--  store charges only a colour not owned yet; the wardrobe and the outfits pick among owned ones.
--
--    WCOwnership.list(charid)                     { [hashString] = { category, palette, tint0, tint1,
--                                                   tint2, source, pricePaid, currency,
--                                                   colors = { tint... } } } | nil, 'DATABASE_ERROR'
--    WCOwnership.owns(charid, hash)               boolean (nil, code on a database failure)
--    WCOwnership.entry(owned, hash)               the owned row of a hash in a list() result, or nil
--    WCOwnership.tintOf(owned, hash, category)    the owned (last worn) tint { palette, tint0..2 } or nil
--    WCOwnership.colorsOf(owned, hash, category)  every owned colour of the item (the last worn first)
--    WCOwnership.ownsColor(owned, hash, tint, category)  is `tint` (nil = the original) an owned colour?
--    WCOwnership.grantQueries(charid, items, source)  { {query, values}... } for a transaction
--    WCOwnership.grant(charid, items, source)     run grantQueries in one transaction -> boolean
--  Submitted clothing validation (store, wardrobe, outfits):
--    WCOwnership.resolveEquipped(sex, equipped)   { [category] = u32 } | nil, code, category
--    WCOwnership.changedCategories(before, after) { [category] = true }
--    WCOwnership.checkRules(savedEquipped, resolved)  changed | nil, code, category
--    WCOwnership.sameTint(a, b), WCOwnership.cleanTint(category, tint) (a new tint, live config),
--    WCOwnership.storedTint(category, tint) (a saved / owned dye), WCOwnership.key(hash)
--    WCOwnership.wornTint(saved, owned, category, hash)  the wardrobe-rule tint | false, 'ITEM_NOT_OWNED'
--    WCOwnership.settleStates(app, states, reset)  the persisting states that still apply to app
--    WCOwnership.exactId(v)                       a positive integer id (no rounding) | nil
-- =====================================================================

WCOwnership = {}
local O = WCOwnership

O.SOURCES = { store = true, starter = true, legacy = true, admin = true, gift = true }

local MIGRATION_WAIT_MS = 10000
local SELECT_OWNED = 'SELECT hash, category, palette, tint0, tint1, tint2, source, price_paid, currency FROM w_creators_clothes WHERE charid = ?'
local SELECT_COLORS = 'SELECT hash, palette, tint0, tint1, tint2 FROM w_creators_colorways WHERE charid = ?'
-- A plain grant never overwrites an existing row (its tint and source are kept).
local GRANT_KEEP = 'INSERT IGNORE INTO w_creators_clothes (charid, hash, category, source, acquired_at) VALUES (?, ?, ?, ?, CURRENT_TIMESTAMP)'
-- A grant that carries a tint (a purchase or a dye) sets the owned tint; the source is kept.
local GRANT_TINT = 'INSERT INTO w_creators_clothes (charid, hash, category, palette, tint0, tint1, tint2, source, acquired_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, CURRENT_TIMESTAMP) ON DUPLICATE KEY UPDATE category = VALUES(category), palette = VALUES(palette), tint0 = VALUES(tint0), tint1 = VALUES(tint1), tint2 = VALUES(tint2)'
-- A grant that resets the owned tint to the item's original colour (NULLs as literals: a nil in a
-- parameter array would end it early).
local GRANT_UNTINTED = 'INSERT INTO w_creators_clothes (charid, hash, category, palette, tint0, tint1, tint2, source, acquired_at) VALUES (?, ?, ?, NULL, NULL, NULL, NULL, ?, CURRENT_TIMESTAMP) ON DUPLICATE KEY UPDATE category = VALUES(category), palette = NULL, tint0 = NULL, tint1 = NULL, tint2 = NULL'
-- The same three for a store purchase: what was charged for the item is recorded with it (only a
-- garment with a recorded price can be sold back). The price and its currency go last so every
-- other value keeps its position.
local GRANT_KEEP_PAID = 'INSERT IGNORE INTO w_creators_clothes (charid, hash, category, source, acquired_at, price_paid, currency) VALUES (?, ?, ?, ?, CURRENT_TIMESTAMP, ?, ?)'
local GRANT_TINT_PAID = 'INSERT INTO w_creators_clothes (charid, hash, category, palette, tint0, tint1, tint2, source, acquired_at, price_paid, currency) VALUES (?, ?, ?, ?, ?, ?, ?, ?, CURRENT_TIMESTAMP, ?, ?) ON DUPLICATE KEY UPDATE category = VALUES(category), palette = VALUES(palette), tint0 = VALUES(tint0), tint1 = VALUES(tint1), tint2 = VALUES(tint2), price_paid = VALUES(price_paid), currency = VALUES(currency)'
local GRANT_UNTINTED_PAID = 'INSERT INTO w_creators_clothes (charid, hash, category, palette, tint0, tint1, tint2, source, acquired_at, price_paid, currency) VALUES (?, ?, ?, NULL, NULL, NULL, NULL, ?, CURRENT_TIMESTAMP, ?, ?) ON DUPLICATE KEY UPDATE category = VALUES(category), palette = NULL, tint0 = NULL, tint1 = NULL, tint2 = NULL, price_paid = VALUES(price_paid), currency = VALUES(currency)'
-- An owned colour: never duplicated (the unique key), and a colour owned already keeps its row.
local GRANT_COLOR = 'INSERT IGNORE INTO w_creators_colorways (charid, hash, palette, tint0, tint1, tint2, price_paid, currency, acquired_at) VALUES (?, ?, ?, ?, ?, ?, NULL, NULL, CURRENT_TIMESTAMP)'
local GRANT_COLOR_PAID = 'INSERT IGNORE INTO w_creators_colorways (charid, hash, palette, tint0, tint1, tint2, price_paid, currency, acquired_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, CURRENT_TIMESTAMP)'
O.DELETE_ITEM = 'DELETE FROM w_creators_clothes WHERE charid = ? AND hash = ?'
O.DELETE_COLORS = 'DELETE FROM w_creators_colorways WHERE charid = ? AND hash = ?'

local function key(hash)
    local h = WCUtil.u32(hash)
    return h and tostring(h) or nil
end
O.key = key

local function schemaReady()
    if type(WCMigrations) ~= 'table' or type(WCMigrations.waitReady) ~= 'function' then return true end
    return WCMigrations.waitReady(MIGRATION_WAIT_MS) == true
end

local function tintInt(v)
    local n = tonumber(v)
    if not WCUtil.isFinite(n) or n % 1 ~= 0 or n < 0 or n > 254 then return nil end
    return math.tointeger(n)
end

--- Every owned item of a character, keyed by the unsigned hash as a string.
--  Returns the map, or nil, 'DATABASE_ERROR'.
function O.list(charid)
    if charid == nil then return {} end
    if not schemaReady() then return nil, 'DATABASE_ERROR' end
    local ok, rows = pcall(w.database.query.await, SELECT_OWNED, { tostring(charid) })
    if not ok or (rows ~= nil and type(rows) ~= 'table') then
        WCDebug.warn('ownership', 'reading the owned clothing of %s failed: %s', tostring(charid), tostring(rows))
        return nil, 'DATABASE_ERROR'
    end
    local out = {}
    for _, row in ipairs(rows or {}) do
        local k = type(row) == 'table' and key(row.hash)
        if k and type(row.category) == 'string' then
            local paid = tonumber(row.price_paid)
            out[k] = {
                category = row.category,
                palette = type(row.palette) == 'string' and row.palette ~= '' and row.palette or nil,
                tint0 = tintInt(row.tint0), tint1 = tintInt(row.tint1), tint2 = tintInt(row.tint2),
                source = type(row.source) == 'string' and row.source or nil,
                pricePaid = WCUtil.isFinite(paid) and paid > 0 and WCUtil.round2(paid) or nil,
                currency = WCCatalog.CURRENCY_SET[row.currency] and row.currency or nil,
            }
        end
    end
    -- the owned colours of each owned item (a colour row of an item no longer owned is ignored)
    local okC, colorRows = pcall(w.database.query.await, SELECT_COLORS, { tostring(charid) })
    if not okC or (colorRows ~= nil and type(colorRows) ~= 'table') then
        WCDebug.warn('ownership', 'reading the owned colours of %s failed: %s', tostring(charid), tostring(colorRows))
        return nil, 'DATABASE_ERROR'
    end
    for _, row in ipairs(colorRows or {}) do
        local entry = type(row) == 'table' and out[key(row.hash) or '']
        if entry and type(row.palette) == 'string' and row.palette ~= '' then
            local t0, t1, t2 = tintInt(row.tint0), tintInt(row.tint1), tintInt(row.tint2)
            if t0 and t1 and t2 then
                entry.colors = entry.colors or {}
                entry.colors[#entry.colors + 1] = { palette = row.palette, tint0 = t0, tint1 = t1, tint2 = t2 }
            end
        end
    end
    return out
end

--- The owned row of a hash in a list() result, or nil.
function O.entry(owned, hash)
    local k = key(hash)
    if type(owned) ~= 'table' or not k then return nil end
    local entry = owned[k]
    return type(entry) == 'table' and entry or nil
end

--- Does the character own the item? nil, code when the database cannot be read.
function O.owns(charid, hash)
    local owned, code = O.list(charid)
    if not owned then return nil, code end
    return O.entry(owned, hash) ~= nil
end

--- The owned tint of an item ({ palette, tint0, tint1, tint2 }) when it is a structurally valid
--  stored tint for the category (WCCatalog.validStoredTint: an owned dye is stored data and
--  survives tints being disabled or a palette list narrowed, §5.4), otherwise nil (the item's
--  original colour).
function O.tintOf(owned, hash, category)
    local entry = O.entry(owned, hash)
    if not entry or not entry.palette then return nil end
    local tint = { palette = entry.palette, tint0 = entry.tint0, tint1 = entry.tint1, tint2 = entry.tint2 }
    category = category or entry.category
    if not WCCatalog.validStoredTint(category, tint) then return nil end
    return tint
end

--- A paid amount and its currency as query values, or nil (nothing recorded).
local function paidOf(paid)
    if type(paid) ~= 'table' then return nil end
    local amount = tonumber(paid.amount)
    if not WCUtil.isFinite(amount) or amount <= 0 or not WCCatalog.CURRENCY_SET[paid.currency] then return nil end
    return WCUtil.round2(amount), paid.currency
end

--- Grant queries for a transaction.
--  items = { { category, hash, tint = { palette, tint0..2 } | false | nil, paid?, colorPaid? }... }
--    tint == nil    INSERT IGNORE: an existing row (tint, source) is kept
--    tint == table  the owned (last worn) tint is set (purchase / dye) and the colour is owned
--    tint == false  the owned tint is reset to the item's original colour
--    paid           { amount, currency }: what a store purchase charged for the item (resell)
--    colorPaid      { amount, currency }: what a new colour cost
--  source: store | starter | legacy | admin | gift (anything else -> 'admin').
--  The owned-colour rows follow the item rows, so an item row exists before its colours.
function O.grantQueries(charid, items, source)
    local queries, colors = {}, {}
    if charid == nil or type(items) ~= 'table' then return queries end
    source = O.SOURCES[source] and source or 'admin'
    local id = tostring(charid)
    for _, item in ipairs(items) do
        local hash = type(item) == 'table' and WCUtil.u32(item.hash)
        local category = type(item) == 'table' and item.category
        if hash and type(category) == 'string' then
            local tint = item.tint
            local t0, t1, t2
            if type(tint) == 'table' and type(tint.palette) == 'string' then
                t0, t1, t2 = tintInt(tint.tint0), tintInt(tint.tint1), tintInt(tint.tint2)
            end
            local amount, currency = paidOf(item.paid)
            if tint == nil then
                queries[#queries + 1] = amount
                    and { query = GRANT_KEEP_PAID, values = { id, hash, category, source, amount, currency } }
                    or { query = GRANT_KEEP, values = { id, hash, category, source } }
            elseif t0 and t1 and t2 then
                queries[#queries + 1] = amount
                    and { query = GRANT_TINT_PAID, values = { id, hash, category, tint.palette, t0, t1, t2, source, amount, currency } }
                    or { query = GRANT_TINT, values = { id, hash, category, tint.palette, t0, t1, t2, source } }
                local colorAmount, colorCurrency = paidOf(item.colorPaid)
                colors[#colors + 1] = colorAmount
                    and { query = GRANT_COLOR_PAID, values = { id, hash, tint.palette, t0, t1, t2, colorAmount, colorCurrency } }
                    or { query = GRANT_COLOR, values = { id, hash, tint.palette, t0, t1, t2 } }
            else
                queries[#queries + 1] = amount
                    and { query = GRANT_UNTINTED_PAID, values = { id, hash, category, source, amount, currency } }
                    or { query = GRANT_UNTINTED, values = { id, hash, category, source } }
            end
        end
    end
    for _, q in ipairs(colors) do queries[#queries + 1] = q end
    return queries
end

--- Grant items in one transaction (admin / starter tools). Returns true | false, code.
function O.grant(charid, items, source)
    local queries = O.grantQueries(charid, items, source)
    if #queries == 0 then return true end
    if not schemaReady() then return false, 'DATABASE_ERROR' end
    local ok, done = pcall(w.database.transaction.await, queries)
    if not ok or done ~= true then
        WCDebug.warn('ownership', 'granting clothing to %s failed: %s', tostring(charid), tostring(done))
        return false, 'DATABASE_ERROR'
    end
    return true
end

-- ---------------------------------------------------------------------
--  Submitted clothing validation (store, wardrobe, outfits)
-- ---------------------------------------------------------------------
local MAX_CATEGORIES = 64

--- Resolve a submitted { [category] = hash } map for a sex. 0 / false / nil entries mean "not worn".
--  Every other entry must be a clothing category and an item of that category for the sex (a hash
--  that sanitize would silently drop is refused here).
--  Returns resolved { [category] = u32 } | nil, 'INVALID_PAYLOAD' | 'INVALID_COMPONENT', category.
function O.resolveEquipped(sex, equipped)
    if equipped == nil then return {} end
    if type(equipped) ~= 'table' then return nil, 'INVALID_PAYLOAD' end
    local out, n = {}, 0
    for category, value in pairs(equipped) do
        n = n + 1
        if n > MAX_CATEGORIES then return nil, 'INVALID_PAYLOAD' end
        if value ~= nil and value ~= false and value ~= 0 then
            if type(category) ~= 'string' or not WCCatalog.isClothing(category) then
                return nil, 'INVALID_COMPONENT', tostring(category)
            end
            if type(value) ~= 'number' and type(value) ~= 'string' then return nil, 'INVALID_COMPONENT', category end
            local hash = WCCatalog.resolve(sex, category, value)
            if not hash then return nil, 'INVALID_COMPONENT', category end
            out[category] = hash
        end
    end
    return out
end

--- The categories whose worn item differs between two equipped maps: { [category] = true }.
function O.changedCategories(before, after)
    local out = {}
    before, after = type(before) == 'table' and before or {}, type(after) == 'table' and after or {}
    for category, hash in pairs(after) do
        if before[category] ~= hash then out[category] = true end
    end
    for category in pairs(before) do
        if after[category] == nil then out[category] = true end
    end
    return out
end

--- Check a resolved equipped set against the saved one: an essential (non-removable) category is
--  never removed, and the compatibility rules must hold for every changed category (a conflict
--  between two untouched stored items is left to AppearanceSchema.mergeSections).
--  Returns changed { [category] = true } | nil, 'INVALID_COMPONENT' | 'CONFLICTING_ITEMS', category.
function O.checkRules(savedEquipped, resolved)
    local changed = O.changedCategories(savedEquipped, resolved)
    for category in pairs(changed) do
        if resolved[category] == nil and not WCRules.canRemove(category) then
            return nil, 'INVALID_COMPONENT', category
        end
    end
    local _, violations = WCRules.normalize(resolved)
    for _, v in ipairs(violations) do
        if changed[v.category] or (v.with and changed[v.with]) then
            return nil, 'CONFLICTING_ITEMS', v.category
        end
    end
    return changed
end

--- Is `a` the same tint as `b` (both nil = the original colour)?
function O.sameTint(a, b)
    a = type(a) == 'table' and a.palette and a or nil
    b = type(b) == 'table' and b.palette and b or nil
    if a == nil or b == nil then return a == b end
    return a.palette == b.palette and a.tint0 == b.tint0 and a.tint1 == b.tint1 and a.tint2 == b.tint2
end

local function tintCopy(tint)
    return { palette = tint.palette, tint0 = math.tointeger(tint.tint0), tint1 = math.tointeger(tint.tint1),
             tint2 = math.tointeger(tint.tint2) }
end

--- A clean copy of a valid NEW tint ({ palette, tint0..2 } with integers) under the live
--  Config.Clothing.tints (WCCatalog.validTint), or nil.
function O.cleanTint(category, tint)
    if not WCCatalog.validTint(category, tint) then return nil end
    return tintCopy(tint)
end

--- A clean copy of a stored tint (a saved or owned dye: WCCatalog.validStoredTint, independent of
--  the live tint config, §5.4), or nil.
function O.storedTint(category, tint)
    if not WCCatalog.validStoredTint(category, tint) then return nil end
    return tintCopy(tint)
end

--- Every owned colour of an item: the colour it was last worn in first, then its other owned
--  colours (each a valid stored tint, no duplicates). Empty when it has none (the original only).
function O.colorsOf(owned, hash, category)
    local entry = O.entry(owned, hash)
    local out = {}
    if not entry then return out end
    category = category or entry.category
    local function push(tint)
        local clean = O.storedTint(category, tint)
        if not clean then return end
        for _, t in ipairs(out) do
            if O.sameTint(t, clean) then return end
        end
        out[#out + 1] = clean
    end
    push(O.tintOf(owned, hash, category))
    for _, t in ipairs(type(entry.colors) == 'table' and entry.colors or {}) do push(t) end
    return out
end

--- Is `tint` a colour the character owns of the item? The original colour (nil / no palette) is
--  owned with the item; any other must be its last-worn colour or one of its owned colours.
function O.ownsColor(owned, hash, tint, category)
    if not O.entry(owned, hash) then return false end
    if type(tint) ~= 'table' or not tint.palette then return true end
    for _, t in ipairs(O.colorsOf(owned, hash, category)) do
        if O.sameTint(t, tint) then return true end
    end
    return false
end

--- The tint of an item under the wardrobe rule (wardrobe, surgery clothing): the owned tint of an
--  owned item; the saved tint of the item worn in the saved look without an ownership row (a
--  uniform). Both are stored dyes, never re-validated against the live tint config, so an unchanged
--  item keeps its dye when tints are disabled or narrowed.
--  `submitted` (the wardrobe's colour choice): nil keeps that rule; false is the item's original
--  colour; a tint is taken when the character owns that colour of the item (an unowned colour
--  falls back to the rule: the wardrobe never dyes).
--  Returns tint | nil (the original colour), or false, 'ITEM_NOT_OWNED' for any other item.
function O.wornTint(saved, owned, category, hash, submitted)
    local entry = O.entry(owned, hash)
    local isSaved = saved.clothing.equipped[category] == hash
    if not entry and not isSaved then return false, 'ITEM_NOT_OWNED' end
    if submitted == false then return nil end
    if type(submitted) == 'table' and submitted.palette then
        if entry and O.ownsColor(owned, hash, submitted, category) then return O.storedTint(category, submitted) end
        if not entry and O.sameTint(submitted, saved.clothing.tints[category]) then
            return O.storedTint(category, submitted)
        end
    end
    if entry then return O.tintOf(owned, hash, category) end
    return O.storedTint(category, saved.clothing.tints[category])
end

--- The persisting, valid states of `states` that apply to `app`'s equipped items. A group listed in
--  `reset` ({ [groupId] = true }) is dropped (its item was swapped: the new item starts visible).
--  A state whose garment is only hidden (the sleeves of a shirt taken off) is kept: it is drawn
--  again when the garment goes back on.
function O.settleStates(app, states, reset)
    local out = {}
    if type(states) ~= 'table' then return out end
    for group, value in pairs(states) do
        local def = type(group) == 'string' and WCClothingStates.byId[group]
        if def and def.persist and WCClothingStates.isValid(group, value)
            and not (reset and reset[group]) and WCClothingStates.applicable(app, group, true) then
            out[group] = value
        end
    end
    return out
end

--- The state groups that act on any of the given categories: { [groupId] = true }.
function O.groupsOf(categories)
    local out = {}
    if type(categories) ~= 'table' then return out end
    for _, def in ipairs(WCClothingStates.groups) do
        for _, category in ipairs(def.categories or {}) do
            if categories[category] then out[def.id] = true end
        end
    end
    return out
end

--- A positive 32-bit integer id given exactly (5, 5.0 or "5"); anything else (0, -7, 2.9, 1e12,
--  "5abc", NaN) is nil — an id is never rounded or clamped onto another row.
function O.exactId(v)
    local n = type(v) == 'number' and v or (type(v) == 'string' and #v <= 12 and v:match('^%d+$') and tonumber(v)) or nil
    if not WCUtil.isFinite(n) or n % 1 ~= 0 or n < 1 or n > 2147483647 then return nil end
    return math.tointeger(n)
end
