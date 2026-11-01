-- =====================================================================
--  server/clothing/store.lua  —  the clothing store (ARCHITECTURE.md §5.3, §5.4, §9.3, §16.4)
--  Callbacks:
--    w_creators:store:open(locationId)        -> { token, appearance, owned, prices, priceSpecs,
--                                                  currencies, tintPrice, tintPrices, storeProfile,
--                                                  pricingProfile, preview, outfits, maxOutfits,
--                                                  outfitsEnabled, resell, expiresIn }
--    w_creators:store:commit(token, opId, app, extra?) -> { appearance, charged, currency, purchases,
--                                                  outfit? }
--       extra = { currency = 'cash' | 'gold', outfitName = 'name' } (both optional)
--    w_creators:store:resell(token, hash)     -> { refunded, currency, owned }
--  (w_creators:session:close belongs to WCSessions.)
--
--  Commit: the session is valid (WCSessions.commit, idempotent per opId) -> the saved appearance is
--  re-read -> only the clothing section of the submission is used -> every changed item is checked
--  (item of the sex, sold by the store profile, priced by the pricing profile in the chosen
--  currency, tint valid, rules) -> the total is computed on the server (no price is ever read from
--  the payload) -> WCEconomy.withCharge(save + grants [+ the new outfit] in one transaction, in the
--  chosen currency) -> broadcast. A colour the character owns of an item is free (colourways).
--  Resell: an item bought here (a recorded price), not worn, in no saved outfit -> its rows are
--  deleted in one transaction -> the paid price × Config.Clothing.resell.percent is paid back.
-- =====================================================================

WCClothingStore = {}
local Store = WCClothingStore

local MAX_PAYLOAD = 64 * 1024
local MAX_TOKEN = 128

local function fail(code, data) return WCResult.fail(code, data) end

--- The cash price of one new colour (0 when free or not sold for cash).
local function tintPrice()
    local spec = WCCatalog.tintPriceSpec()
    return spec and spec.cash or 0
end
Store.tintPrice = tintPrice

local function profiles(loc)
    loc = type(loc) == 'table' and loc or {}
    return loc.storeProfile or 'general', loc.pricingProfile or 'standard'
end

--- Does the store sell at least one item of the category to the sex?
local function sellsCategory(storeProfile, sex, category)
    local cat = WCCatalog.category(sex, category)
    if not cat then return false end
    for _, model in ipairs(WCUtil.sortedKeys(cat.models)) do
        for _, variant in ipairs(cat.models[model]) do
            if WCCatalog.available(storeProfile, sex, category, variant.hash) then return true end
        end
    end
    return false
end

--- The price of every category the store sells to the sex, after the pricing profile, in every
--  currency it is sold for: { [category] = { cash?, gold? } }. A model's own price
--  (Config.Clothing.modelPrices) is worked out per item (WCCatalog.priceSpecOf).
function Store.priceSpecs(loc, sex)
    local storeProfile, pricingProfile = profiles(loc)
    local out = {}
    local prices = Config.Clothing and Config.Clothing.prices or {}
    for _, category in ipairs(WCUtil.sortedKeys(prices)) do
        if type(category) == 'string' and WCCatalog.offered(sex, category) then
            local spec = WCCatalog.priceSpecOf(category, nil, pricingProfile, sex)
            if spec and sellsCategory(storeProfile, sex, category) then out[category] = spec end
        end
    end
    return out
end

--- The cash price of every category the store sells to the sex (the categories sold for cash).
function Store.prices(loc, sex)
    local out = {}
    for category, spec in pairs(Store.priceSpecs(loc, sex)) do
        if spec.cash then out[category] = spec.cash end
    end
    return out
end

--- The currencies the store takes, in Config.Clothing.payment order: cash, and any other one
--  that a category, a model of the sex or a new colour is priced in.
function Store.currencies(loc, sex)
    local seen = { cash = true }
    for _, spec in pairs(Store.priceSpecs(loc, sex)) do
        for currency in pairs(spec) do seen[currency] = true end
    end
    local models = Config.Clothing and Config.Clothing.modelPrices
    for _, byModel in pairs(type(models) == 'table' and type(models[sex]) == 'table' and models[sex] or {}) do
        for _, entry in pairs(type(byModel) == 'table' and byModel or {}) do
            for currency in pairs(WCCatalog.priceSpec(entry) or {}) do seen[currency] = true end
        end
    end
    for currency in pairs(WCCatalog.tintPriceSpec() or {}) do seen[currency] = true end
    local order = Config.Clothing and Config.Clothing.payment and Config.Clothing.payment.currencies
    local out = {}
    for _, currency in ipairs(type(order) == 'table' and order or WCCatalog.CURRENCIES) do
        if seen[currency] and WCCatalog.CURRENCY_SET[currency] then out[#out + 1] = currency end
    end
    if #out == 0 then out[1] = 'cash' end
    return out
end

--- Does the store take this currency (Config.Clothing.payment.currencies)?
function Store.acceptsCurrency(currency)
    if not WCCatalog.CURRENCY_SET[currency] then return false end
    local order = Config.Clothing and Config.Clothing.payment and Config.Clothing.payment.currencies
    if type(order) ~= 'table' then return currency == 'cash' end
    for _, c in ipairs(order) do
        if c == currency then return true end
    end
    return false
end

--- Selling back (Config.Clothing.resell), for display: { enabled, percent, inWardrobe }.
function Store.resellConfig()
    local cfg = Config.Clothing and Config.Clothing.resell or {}
    return { enabled = cfg.enabled == true, percent = WCUtil.number(cfg.percent, 0, 1, 0), inWardrobe = cfg.inWardrobe == true }
end

--- Does this store offer the saved outfits (the location's `outfits` and the savedOutfits service)?
local function storeOutfits(loc)
    return type(loc) == 'table' and loc.outfits ~= false and WCServices.enabled('savedOutfits')
end

local function previewOf(loc)
    local v = type(loc) == 'table' and loc.preview
    local x, y, z = WCUtil.xyz(v)
    if not x then return nil end
    local ok, heading = pcall(function() return v.w or v.heading or v[4] end)
    heading = ok and WCUtil.number(heading, nil, nil, 0.0) or 0.0
    return { x = x, y = y, z = z, w = heading, heading = heading }
end

--- Open a store session. Result data per §16.4.
function Store.open(src, locationId)
    if locationId ~= nil and (type(locationId) ~= 'string' or #locationId > 64) then
        return fail('INVALID_PAYLOAD')
    end
    local opened = WCSessions.open(src, 'store', { locationId = locationId })
    if not opened.ok then return opened end
    local s = opened.data.session
    -- A defaults-filled appearance can never be committed (see commitStore): refuse up front.
    if WCAppearanceRepo.degraded(s.charid) then
        WCSessions.close(src, s.token)
        return fail('INTERNAL_ERROR')
    end
    local owned, code = WCOwnership.list(s.charid)
    if not owned then
        WCSessions.close(src, s.token)
        return fail(code or 'DATABASE_ERROR')
    end
    -- the saved outfits, read only (equip: a starting look), when this store offers them
    local outfits = {}
    local withOutfits = storeOutfits(s.location)
    if withOutfits then
        local list, listCode = WCOutfits.list(s.charid, s.sex)
        if not list then
            WCSessions.close(src, s.token)
            return fail(listCode or 'DATABASE_ERROR')
        end
        outfits = list
    end
    local storeProfile, pricingProfile = profiles(s.location)
    return WCResult.ok({
        token = s.token,
        appearance = WCUtil.copy(s.snapshot),
        owned = owned,
        prices = Store.prices(s.location, s.sex),
        priceSpecs = Store.priceSpecs(s.location, s.sex),
        currencies = Store.currencies(s.location, s.sex),
        tintPrice = tintPrice(),
        tintPrices = WCCatalog.tintPriceSpec(),
        storeProfile = storeProfile,
        pricingProfile = pricingProfile,
        preview = previewOf(s.location),
        outfits = outfits,
        outfitsEnabled = withOutfits,
        maxOutfits = WCOutfits.max(),
        resell = Store.resellConfig(),
        expiresIn = math.max(0, s.expires - os.time()),
    })
end

-- The tint a changed item is compared against: its owned tint; when it has none and the item is
-- the one worn in the saved appearance, its saved tint (the editor's price table, T.price, uses the
-- same baseline).
local function baselineTint(saved, owned, category, hash)
    local tint = WCOwnership.tintOf(owned, hash, category)
    if tint == nil and saved.clothing.equipped[category] == hash then return saved.clothing.tints[category] end
    return tint
end

--- Validate and price a submission against the saved appearance, in `currency` ('cash' when nil).
--  Never reads a price from the payload. Returns plan | nil, code, detail.
--  plan = { merged, total, currency, purchases = { {category, hash, price, tint?, dyed?, new?,
--           newColor?}... }, grants }
function Store.plan(saved, submitted, owned, loc, currency)
    if type(submitted) ~= 'table' or type(submitted.clothing) ~= 'table' then return nil, 'INVALID_PAYLOAD' end
    local clothing = submitted.clothing
    -- A missing equipped map is a malformed payload, never "remove everything".
    if type(clothing.equipped) ~= 'table' then return nil, 'INVALID_PAYLOAD' end
    if clothing.tints ~= nil and type(clothing.tints) ~= 'table' then return nil, 'INVALID_PAYLOAD' end
    currency = currency == nil and 'cash' or currency
    if not Store.acceptsCurrency(currency) then return nil, 'CURRENCY_NOT_ACCEPTED' end
    local sex = saved.sex
    local storeProfile, pricingProfile = profiles(loc)

    local resolved, code, detail = WCOwnership.resolveEquipped(sex, clothing.equipped)
    if not resolved then return nil, code, detail end
    local changed
    changed, code, detail = WCOwnership.checkRules(saved.clothing.equipped, resolved)
    if not changed then return nil, code, detail end

    -- A category without a tint (nil / false) is the item's original colour: an owned dye is reset
    -- only by that explicit choice, never because a submitted dye was dropped (see the pricing loop).
    local tints, stored = {}, {}
    for category, hash in pairs(resolved) do
        local raw = clothing.tints and clothing.tints[category]
        if raw ~= nil and raw ~= false then
            -- The saved item with its saved dye, unchanged, and an owned item with its owned dye (the
            -- stored form, WCOwnership.tintOf: re-wearing it) are stored data: checked structurally
            -- only (they survive tints being disabled or a palette list narrowed, §5.4). Only a
            -- changed or new tint must satisfy the live Config.Clothing.tints.
            local savedTint = saved.clothing.tints[category]
            local ownedTint = WCOwnership.tintOf(owned, hash, category)
            local tint
            if hash == saved.clothing.equipped[category] and WCOwnership.sameTint(raw, savedTint) then
                tint = WCOwnership.storedTint(category, savedTint)
            elseif ownedTint and WCOwnership.sameTint(raw, ownedTint) then
                tint = ownedTint
                stored[category] = WCUtil.copy(ownedTint)
            elseif WCOwnership.entry(owned, hash) and WCOwnership.ownsColor(owned, hash, raw, category) then
                -- another owned colour of the item (colourways): stored data as well
                tint = WCOwnership.storedTint(category, raw)
                if tint then stored[category] = WCUtil.copy(tint) end
            else
                tint = WCOwnership.cleanTint(category, raw)
            end
            if not tint then return nil, 'INVALID_TINT', category end
            tints[category] = tint
        end
    end

    local draft = WCUtil.copy(saved)
    draft.clothing = {
        equipped = resolved,
        tints = tints,
        states = WCUtil.copy(saved.clothing.states),
        outfit = next(changed) == nil and saved.clothing.outfit or nil,
    }
    local merged = AppearanceSchema.mergeSections(saved, draft, { clothing = true }, { storedTints = stored })
    local final = merged.clothing.equipped
    for category in pairs(changed) do
        if final[category] ~= resolved[category] then return nil, 'CONFLICTING_ITEMS', category end
    end
    -- A saved visibility state never carries over to a swapped item (a hat bought while the old one
    -- was 'off' is worn visibly), and a state whose item is gone is dropped.
    local swapped = WCOwnership.changedCategories(saved.clothing.equipped, final)
    merged.clothing.states = WCOwnership.settleStates(merged, saved.clothing.states, WCOwnership.groupsOf(swapped))

    local total, purchases, grants = 0, {}, {}
    local tintSpec = WCCatalog.tintPriceSpec()
    for _, category in ipairs(WCUtil.sortedKeys(final)) do
        local hash = final[category]
        local tint = merged.clothing.tints[category]
        -- a submitted dye the merge did not keep is refused, never turned into a reset of the dye
        if tint == nil and tints[category] ~= nil and hash == resolved[category] then
            return nil, 'INVALID_TINT', category
        end
        -- Only what the player changed is priced: an item worn as saved, with its saved tint, is
        -- never charged and its owned row is never rewritten.
        local untouched = hash == saved.clothing.equipped[category]
            and WCOwnership.sameTint(tint, saved.clothing.tints[category])
        -- Any change to an item the character does not own is a purchase, a dye of a worn but
        -- unowned item (a uniform applied by another resource) included: it must be sold here and
        -- is charged, never granted for the tint price alone.
        local isNew = not untouched and WCOwnership.entry(owned, hash) == nil
        local dyed = not untouched and not WCOwnership.sameTint(tint, baselineTint(saved, owned, category, hash))
        -- colourways: a colour the character owns of the item is free (it only becomes the colour
        -- the item is worn in); only a colour it does not own yet costs the tint price
        local newColor = dyed and tint ~= nil and (isNew or not WCOwnership.ownsColor(owned, hash, tint, category))
        local cost, itemPrice, colorPrice = 0, nil, nil
        if isNew then
            if not WCCatalog.available(storeProfile, sex, category, hash) then
                return nil, 'COMPONENT_NOT_AVAILABLE', category
            end
            local spec = WCCatalog.priceSpecOf(category, hash, pricingProfile, sex)
            if not spec then return nil, 'COMPONENT_NOT_AVAILABLE', category end
            itemPrice = spec[currency]
            if not itemPrice then return nil, 'CURRENCY_NOT_ACCEPTED', category end
            cost = cost + itemPrice
        end
        if newColor and tintSpec then
            colorPrice = tintSpec[currency]
            if not colorPrice then return nil, 'CURRENCY_NOT_ACCEPTED', category end
            cost = cost + colorPrice
        end
        if isNew or dyed then
            purchases[#purchases + 1] = { category = category, hash = hash, price = WCUtil.round2(cost),
                                          tint = tint and WCUtil.copy(tint) or nil, dyed = dyed and tint ~= nil,
                                          new = isNew, newColor = newColor or nil }
            -- A new item without a tint is a plain grant; a dye (or a reset to the original colour)
            -- rewrites the owned (last worn) tint and owns the colour. What was charged is recorded
            -- (the item's price for a resale, the colour's).
            local grantTint
            if dyed then grantTint = tint or false elseif tint then grantTint = tint end
            grants[#grants + 1] = {
                category = category, hash = hash, tint = grantTint,
                paid = (itemPrice and itemPrice > 0) and { amount = itemPrice, currency = currency } or nil,
                colorPaid = (colorPrice and colorPrice > 0) and { amount = colorPrice, currency = currency } or nil,
            }
        end
        total = total + cost
    end
    total = WCUtil.round2(total)
    if not total then return nil, 'INVALID_PRICE' end

    local changes = AppearanceSchema.changedSections(saved, merged)
    return {
        merged = merged, total = total, currency = currency, purchases = purchases, grants = grants,
        empty = not changes.clothing, statesChanged = changes.states == true,
    }
end

local function emitPurchases(src, charid, loc, purchases, currency)
    for _, item in ipairs(purchases) do
        CreatorLogs.Emit('clothing_purchased', {
            playerSource = tonumber(src), charid = tostring(charid),
            items = { { category = item.category, hash = item.hash, tint = item.tint, dyed = item.dyed } },
            price = item.price, currency = currency, store = loc and loc.id or nil,
        })
    end
end

--- The ownership list as it will be once the plan's grants are written: an outfit saved with the
--  purchase may wear what is bought in the same transaction (and in the colours bought with it).
local function ownedAfter(owned, grants)
    local out = WCUtil.copy(owned)
    for _, g in ipairs(grants) do
        local k = WCOwnership.key(g.hash)
        if k then
            local entry = out[k] or { category = g.category, source = 'store' }
            if type(g.tint) == 'table' then
                entry.palette, entry.tint0, entry.tint1, entry.tint2 = g.tint.palette, g.tint.tint0, g.tint.tint1, g.tint.tint2
                entry.colors = entry.colors or {}
                entry.colors[#entry.colors + 1] = WCUtil.copy(g.tint)
            elseif g.tint == false then
                entry.palette, entry.tint0, entry.tint1, entry.tint2 = nil, nil, nil, nil
            end
            out[k] = entry
        end
    end
    return out
end

--- "Buy and save as outfit": the outfit INSERT for the plan's look, checked before anything is
--  charged (the name, the store's outfits, the limit, the contents). query | nil, code, detail.
local function outfitQuery(s, loc, saved, owned, plan, name)
    if not storeOutfits(loc) then return nil, 'OUTFITS_DISABLED' end
    local cleaned = WCOutfits.validateName(name)
    if not cleaned then return nil, 'INVALID_OUTFIT_NAME' end
    local list, listCode = WCOutfits.list(s.charid, s.sex)
    if not list then return nil, listCode or 'DATABASE_ERROR' end
    if #list >= WCOutfits.max() then return nil, 'OUTFIT_LIMIT' end
    local clothing = plan.merged.clothing
    -- the outfit wears each item in the colour bought (false: its original colour)
    local tints = {}
    for category in pairs(clothing.equipped) do tints[category] = (clothing.tints or {})[category] or false end
    local data, code, detail = WCOutfits.validateData(s.charid, s.sex, clothing.equipped, clothing.states,
        saved.clothing.equipped, ownedAfter(owned, plan.grants), tints, saved.clothing.tints)
    if not data then return nil, code, detail end
    local query = WCOutfits.insertQuery(s.charid, cleaned, data)
    if not query then return nil, 'INVALID_PAYLOAD' end
    return query, nil, nil, cleaned
end

local MAX_EXTRA = 1024
local OUTFIT_LOCK_MS = 15000

local function commitStore(src, s, submitted, extra)
    if s.kind ~= 'store' then return fail('SESSION_NOT_FOUND') end
    if not WCServices.enabled('clothingStores') then return fail(WCServices.code('clothingStores')) end
    local loc = s.location and WCLocations.byId(s.location.id) or nil
    if not loc or not loc.enabled or not WCLocations.isOpen(loc) then return WCLocations.refusal(loc) end
    if not WCSessions.accessAllowed(src, loc) then return WCSessions.accessRefusal(src, loc) end
    extra = type(extra) == 'table' and extra or {}
    if extra.currency ~= nil and type(extra.currency) ~= 'string' then return fail('INVALID_PAYLOAD') end
    local outfitName = extra.outfitName
    if outfitName ~= nil and type(outfitName) ~= 'string' then return fail('INVALID_PAYLOAD') end
    if outfitName == '' then outfitName = nil end

    local saved, meta = WCAppearanceRepo.load(s.charid)
    if not saved then return fail(type(meta) == 'table' and meta.error or 'CHARACTER_NOT_FOUND') end
    -- A defaults-filled appearance is never overwritten automatically (WCAppearanceRepo): refuse
    -- before anything is charged.
    if type(meta) == 'table' and meta.degraded then return fail('INTERNAL_ERROR') end
    local owned, ownedCode = WCOwnership.list(s.charid)
    if not owned then return fail(ownedCode or 'DATABASE_ERROR') end

    local plan, code, detail = Store.plan(saved, submitted, owned, loc, extra.currency)
    if not plan then
        WCDebug.log('store', 'commit by %s refused: %s %s', tostring(src), tostring(code), tostring(detail or ''))
        return fail(code, detail and { category = detail } or nil)
    end
    -- saving the look as an outfit is a change of its own, even with nothing bought
    if plan.empty and not outfitName then return fail('NO_CHANGES') end

    -- Only what is bought (or dyed) here becomes owned. The clothing the player arrived in is not
    -- granted: the pre-v3 outfit is owned since its lazy upgrade ('legacy', WCAppearanceRepo) and a
    -- worn item without an ownership row was applied by another resource (SetClothes: a job
    -- uniform), which must never become owned (the wardrobe rule, §5.6).
    local queries = {}
    for _, q in ipairs(WCOwnership.grantQueries(s.charid, plan.grants, 'store')) do queries[#queries + 1] = q end

    -- "buy and save as outfit": its INSERT joins the same transaction, under the character's outfit
    -- lock (the limit holds against a wardrobe save racing it); refused before any charge
    local outfitLock, savedName
    if outfitName then
        outfitLock = 'outfits:' .. s.charid
        if not WCSecurity.lock(outfitLock, OUTFIT_LOCK_MS) then return fail('BUSY') end
        local okQ, query, qCode, qDetail, cleaned = pcall(outfitQuery, s, loc, saved, owned, plan, outfitName)
        if not okQ or not query then
            WCSecurity.unlock(outfitLock)
            if not okQ then
                WCDebug.warn('store', 'the outfit of %s failed: %s', tostring(src), tostring(query))
                return fail('INTERNAL_ERROR')
            end
            return fail(qCode, qDetail and { category = qDetail } or nil)
        end
        queries[#queries + 1] = query
        savedName = cleaned
    end

    local okCharge, result = pcall(WCEconomy.withCharge, src, plan.total, 'clothing', function()
        local ok, app = WCAppearanceRepo.save(s.charid, plan.merged, queries)
        if not ok then return WCResult.fail(app or 'DATABASE_ERROR') end
        return WCResult.ok({ appearance = app })
    end, plan.currency)
    if outfitLock then WCSecurity.unlock(outfitLock) end
    if not okCharge then error(result, 0) end
    if not result.ok then return result end

    local app = result.data.appearance
    local purchases = {}
    for _, item in ipairs(plan.purchases) do
        purchases[#purchases + 1] = { category = item.category, hash = item.hash, price = item.price,
                                      tint = item.tint, dyed = item.dyed }
    end
    result.data.charged = result.charged or 0
    result.data.currency = plan.currency
    result.data.purchases = purchases
    if savedName then
        result.data.outfit = savedName
        CreatorLogs.Emit('outfit_saved', { playerSource = tonumber(src), charid = tostring(s.charid), name = savedName })
    end
    WCSync.broadcast(src, app)
    emitPurchases(src, s.charid, loc, plan.purchases, plan.currency)
    CreatorLogs.Emit('appearance_changed', { playerSource = tonumber(src), charid = tostring(s.charid),
                                             sections = plan.statesChanged and { 'clothing', 'states' } or { 'clothing' },
                                             kind = 'store' })
    TriggerEvent('w_creators:server:appearanceChanged', src, s.charid, 'store')
    WCDebug.log('store', '%s bought %d item(s) for %.2f %s at %s', tostring(src), #purchases, result.data.charged,
        plan.currency, loc.id)
    return result
end

--- Commit a store session. Result data { appearance, charged, currency, purchases =
--  [{category, hash, ...}], outfit? }. extra = { currency?, outfitName? }.
function Store.commit(src, token, opId, submitted, extra)
    if not WCSecurity.rate(src, 'store:commit', 6, 10000) then return fail('RATE_LIMITED') end
    if type(token) ~= 'string' or #token > MAX_TOKEN or type(submitted) ~= 'table'
        or not WCSecurity.payload(submitted, MAX_PAYLOAD) then
        return fail('INVALID_PAYLOAD')
    end
    if extra ~= nil and (type(extra) ~= 'table' or not WCSecurity.payload(extra, MAX_EXTRA)) then
        return fail('INVALID_PAYLOAD')
    end
    return WCSessions.commit(src, token, opId, function(s) return commitStore(src, s, submitted, extra) end,
        { kind = 'store' })
end

-- ---------------------------------------------------------------------
--  Selling back (Config.Clothing.resell)
-- ---------------------------------------------------------------------

--- Is the item in one of the character's saved outfits?
local function inOutfit(list, hash)
    for _, outfit in ipairs(list or {}) do
        local data = type(outfit.data) == 'table' and outfit.data or {}
        for _, h in pairs(type(data.equipped) == 'table' and data.equipped or {}) do
            if WCUtil.u32(h) == hash then return true end
        end
    end
    return false
end

--- The queries that put a sold item's rows back (the refund could not be paid): the item with its
--  price and last-worn colour, then every other colour it owned.
local function restoreQueries(charid, hash, entry, owned)
    local tint = WCOwnership.tintOf(owned, hash, entry.category)
    local queries = WCOwnership.grantQueries(charid, { {
        category = entry.category, hash = hash, tint = tint,
        paid = entry.pricePaid and { amount = entry.pricePaid, currency = entry.currency } or nil,
    } }, entry.source or 'store')
    for _, color in ipairs(WCOwnership.colorsOf(owned, hash, entry.category)) do
        if not WCOwnership.sameTint(color, tint) then
            for _, q in ipairs(WCOwnership.grantQueries(charid, { { category = entry.category, hash = hash, tint = color } }, 'store')) do
                -- only the colour row: the item row keeps the last-worn colour restored above
                if q.query:find('w_creators_colorways', 1, true) then queries[#queries + 1] = q end
            end
        end
    end
    return queries
end

local function sell(src, s, hash, cfg)
    local owned, code = WCOwnership.list(s.charid)
    if not owned then return fail(code or 'DATABASE_ERROR') end
    local entry = WCOwnership.entry(owned, hash)
    if not entry then return fail('ITEM_NOT_OWNED') end
    -- only a garment bought here with a recorded price: a starting, legacy, admin or gifted one was
    -- never paid for, so selling it would make money out of nothing
    if entry.source ~= 'store' or not entry.pricePaid or not entry.currency then return fail('NOT_RESELLABLE') end
    local saved, meta = WCAppearanceRepo.load(s.charid)
    if not saved then return fail(type(meta) == 'table' and meta.error or 'CHARACTER_NOT_FOUND') end
    for _, h in pairs(saved.clothing.equipped) do
        if h == hash then return fail('ITEM_WORN') end
    end
    local outfits, listCode = WCOutfits.list(s.charid, s.sex)
    if not outfits then return fail(listCode or 'DATABASE_ERROR') end
    if inOutfit(outfits, hash) then return fail('ITEM_IN_OUTFIT') end
    local refund = WCUtil.round2(entry.pricePaid * cfg.percent) or 0

    -- the rows go first, in one transaction; the money follows
    local id = tostring(s.charid)
    local okTx, done = pcall(w.database.transaction.await, {
        { query = WCOwnership.DELETE_ITEM, values = { id, hash } },
        { query = WCOwnership.DELETE_COLORS, values = { id, hash } },
    })
    if not okTx or done ~= true then
        WCDebug.warn('store', 'selling %s for %s failed: %s', tostring(hash), id, tostring(done))
        return fail('DATABASE_ERROR')
    end
    if refund > 0 and not WCEconomy.refund(src, refund, 'clothing_resell', entry.currency) then
        -- the money could not be paid: the sale did not happen, the rows come back
        local okBack, back = pcall(w.database.transaction.await, restoreQueries(s.charid, hash, entry, owned))
        if not okBack or back ~= true then
            CreatorLogs.Emit('security_violation', {
                playerSource = tonumber(src), kind = 'refund_failed',
                detail = ('resell %s %.2f %s'):format(tostring(hash), refund, entry.currency), reason = 'refund_failed',
            })
        end
        return fail('INTERNAL_ERROR')
    end
    CreatorLogs.Emit('clothing_sold', {
        playerSource = tonumber(src), charid = id, hash = hash, category = entry.category,
        price = refund, currency = entry.currency, paid = entry.pricePaid,
        store = s.location and s.location.id or nil,
    })
    WCDebug.log('store', '%s sold %s back for %.2f %s', tostring(src), tostring(hash), refund, entry.currency)
    local fresh = WCOwnership.list(s.charid)
    return WCResult.ok({ refunded = refund, currency = entry.currency, hash = hash, owned = fresh })
end

--- Sell an owned item back (the store, or a wardrobe with resell.inWardrobe). Result data
--  { refunded, currency, hash, owned } (the new ownership list for the editor).
function Store.resell(src, token, hash)
    if not WCSecurity.rate(src, 'store:resell', 6, 10000) then return fail('RATE_LIMITED') end
    local cfg = Store.resellConfig()
    if not cfg.enabled then return fail('SERVICE_DISABLED') end
    if type(token) ~= 'string' or #token > MAX_TOKEN then return fail('SESSION_NOT_FOUND') end
    local h = (type(hash) == 'number' or type(hash) == 'string') and WCUtil.u32(hash) or nil
    if not h or h == 0 then return fail('INVALID_PAYLOAD') end
    local s, code = WCSessions.get(src, token)
    if not s then return fail(code) end
    if s.kind ~= 'store' and not (s.kind == 'wardrobe' and cfg.inWardrobe) then return fail('SESSION_NOT_FOUND') end
    if s.busy then return fail('BUSY') end
    -- the same gates as the commit of that session: a sale pays money out, so it must never be
    -- easier to reach than a purchase (the service off, the location closed, the access rule no
    -- longer met, a remote wardrobe after remote wardrobes were turned off)
    local service = s.kind == 'store' and 'clothingStores' or 'wardrobe'
    if not WCServices.enabled(service) then return fail(WCServices.code(service)) end
    if s.location then
        local loc = WCLocations.byId(s.location.id)
        if not loc or not loc.enabled or not WCLocations.isOpen(loc) then return WCLocations.refusal(loc) end
        if not WCSessions.withinRange(src, s.location) then return fail('TOO_FAR') end
        if not WCSessions.accessAllowed(src, loc) then return WCSessions.accessRefusal(src, loc) end
    elseif s.kind ~= 'wardrobe' or not (Config.Wardrobe and Config.Wardrobe.allowRemote == true) then
        return fail('LOCATION_NOT_FOUND')
    end
    -- the appearance lock (no commit or state write meanwhile) and the outfit lock (no outfit saved
    -- with the item while it is being sold)
    local owner = 'resell:' .. s.token
    if not WCSessions.lockCharacter(s.charid, owner) then return fail('BUSY') end
    local outfitLock = 'outfits:' .. s.charid
    if not WCSecurity.lock(outfitLock, OUTFIT_LOCK_MS) then
        WCSessions.unlockCharacter(s.charid, owner)
        return fail('BUSY')
    end
    local ok, result = pcall(sell, src, s, h, cfg)
    WCSecurity.unlock(outfitLock)
    WCSessions.unlockCharacter(s.charid, owner)
    if not ok then
        WCDebug.warn('store', 'resell by %s failed: %s', tostring(src), tostring(result))
        return fail('INTERNAL_ERROR')
    end
    return result
end

w.callback.register('w_creators:store:open', function(src, locationId)
    return Store.open(src, locationId)
end)

w.callback.register('w_creators:store:commit', function(src, token, opId, app, extra)
    return Store.commit(src, token, opId, app, extra)
end)

w.callback.register('w_creators:store:resell', function(src, token, hash)
    return Store.resell(src, token, hash)
end)
