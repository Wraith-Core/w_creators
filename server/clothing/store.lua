-- =====================================================================
--  server/clothing/store.lua  —  the clothing store (ARCHITECTURE.md §5.3, §5.4, §9.3, §16.4)
--  Callbacks:
--    w_creators:store:open(locationId)        -> { token, appearance, owned, prices, tintPrice,
--                                                  storeProfile, pricingProfile, preview, expiresIn }
--    w_creators:store:commit(token, opId, app) -> { appearance, charged, purchases }
--  (w_creators:session:close belongs to WCSessions.)
--
--  Commit: the session is valid (WCSessions.commit, idempotent per opId) -> the saved appearance is
--  re-read -> only the clothing section of the submission is used -> every changed item is checked
--  (item of the sex, sold by the store profile, priced by the pricing profile, tint valid, rules)
--  -> the total is computed on the server (no price is ever read from the payload) ->
--  WCEconomy.withCharge(save + grants in one transaction) -> broadcast.
-- =====================================================================

WCClothingStore = {}
local Store = WCClothingStore

local MAX_PAYLOAD = 64 * 1024
local MAX_TOKEN = 128

local function fail(code, data) return WCResult.fail(code, data) end

local function tintPrice()
    local tints = Config.Clothing and Config.Clothing.tints or {}
    if tints.enabled == false then return 0 end
    local price = tonumber(tints.price)
    if not WCUtil.isFinite(price) or price < 0 then return 0 end
    return WCUtil.round2(price)
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

--- The price of every category the store sells to the sex, after the pricing profile.
function Store.prices(loc, sex)
    local storeProfile, pricingProfile = profiles(loc)
    local out = {}
    local prices = Config.Clothing and Config.Clothing.prices or {}
    for _, category in ipairs(WCUtil.sortedKeys(prices)) do
        if type(category) == 'string' and WCCatalog.offered(sex, category) then
            local price = WCCatalog.price(category, nil, pricingProfile)
            if price and sellsCategory(storeProfile, sex, category) then out[category] = price end
        end
    end
    return out
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
    local storeProfile, pricingProfile = profiles(s.location)
    return WCResult.ok({
        token = s.token,
        appearance = WCUtil.copy(s.snapshot),
        owned = owned,
        prices = Store.prices(s.location, s.sex),
        tintPrice = tintPrice(),
        storeProfile = storeProfile,
        pricingProfile = pricingProfile,
        preview = previewOf(s.location),
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

--- Validate and price a submission against the saved appearance. Never reads a price from the
--  payload. Returns plan | nil, code, detail.
--  plan = { merged, total, purchases = { {category, hash, price, tint?, dyed?}... }, grants }
function Store.plan(saved, submitted, owned, loc)
    if type(submitted) ~= 'table' or type(submitted.clothing) ~= 'table' then return nil, 'INVALID_PAYLOAD' end
    local clothing = submitted.clothing
    -- A missing equipped map is a malformed payload, never "remove everything".
    if type(clothing.equipped) ~= 'table' then return nil, 'INVALID_PAYLOAD' end
    if clothing.tints ~= nil and type(clothing.tints) ~= 'table' then return nil, 'INVALID_PAYLOAD' end
    local sex = saved.sex
    local storeProfile, pricingProfile = profiles(loc)

    local resolved, code, detail = WCOwnership.resolveEquipped(sex, clothing.equipped)
    if not resolved then return nil, code, detail end
    local changed
    changed, code, detail = WCOwnership.checkRules(saved.clothing.equipped, resolved)
    if not changed then return nil, code, detail end

    local tints = {}
    for category, hash in pairs(resolved) do
        local raw = clothing.tints and clothing.tints[category]
        if raw ~= nil and raw ~= false then
            -- The saved item with its saved dye, unchanged, is stored data: checked structurally
            -- only (it survives tints being disabled or a palette list narrowed, §5.4). Only a
            -- changed or new tint must satisfy the live Config.Clothing.tints.
            local savedTint = saved.clothing.tints[category]
            local tint
            if hash == saved.clothing.equipped[category] and WCOwnership.sameTint(raw, savedTint) then
                tint = WCOwnership.storedTint(category, savedTint)
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
    local merged = AppearanceSchema.mergeSections(saved, draft, { clothing = true })
    local final = merged.clothing.equipped
    for category in pairs(changed) do
        if final[category] ~= resolved[category] then return nil, 'CONFLICTING_ITEMS', category end
    end
    -- A saved visibility state never carries over to a swapped item (a hat bought while the old one
    -- was 'off' is worn visibly), and a state whose item is gone is dropped.
    local swapped = WCOwnership.changedCategories(saved.clothing.equipped, final)
    merged.clothing.states = WCOwnership.settleStates(merged, saved.clothing.states, WCOwnership.groupsOf(swapped))

    local total, purchases, grants = 0, {}, {}
    local perTint = tintPrice()
    for _, category in ipairs(WCUtil.sortedKeys(final)) do
        local hash = final[category]
        local tint = merged.clothing.tints[category]
        -- Only what the player changed is priced: an item worn as saved, with its saved tint, is
        -- never charged and its owned row is never rewritten.
        local untouched = hash == saved.clothing.equipped[category]
            and WCOwnership.sameTint(tint, saved.clothing.tints[category])
        -- Any change to an item the character does not own is a purchase, a dye of a worn but
        -- unowned item (a uniform applied by another resource) included: it must be sold here and
        -- is charged, never granted for the tint price alone.
        local isNew = not untouched and WCOwnership.entry(owned, hash) == nil
        local dyed = not untouched and not WCOwnership.sameTint(tint, baselineTint(saved, owned, category, hash))
        local cost = 0
        if isNew then
            if not WCCatalog.available(storeProfile, sex, category, hash) then
                return nil, 'COMPONENT_NOT_AVAILABLE', category
            end
            local price = WCCatalog.price(category, hash, pricingProfile)
            if not price then return nil, 'COMPONENT_NOT_AVAILABLE', category end
            cost = cost + price
        end
        if dyed and tint then cost = cost + perTint end
        if isNew or dyed then
            purchases[#purchases + 1] = { category = category, hash = hash, price = WCUtil.round2(cost),
                                          tint = tint and WCUtil.copy(tint) or nil, dyed = dyed and tint ~= nil,
                                          new = isNew }
            -- A new item without a tint is a plain grant; a dye (or a reset to the original colour)
            -- rewrites the owned tint.
            local grantTint
            if dyed then grantTint = tint or false elseif tint then grantTint = tint end
            grants[#grants + 1] = { category = category, hash = hash, tint = grantTint }
        end
        total = total + cost
    end
    total = WCUtil.round2(total)
    if not total then return nil, 'INVALID_PRICE' end

    local changes = AppearanceSchema.changedSections(saved, merged)
    return {
        merged = merged, total = total, purchases = purchases, grants = grants,
        empty = not changes.clothing, statesChanged = changes.states == true,
    }
end

local function emitPurchases(src, charid, loc, purchases)
    for _, item in ipairs(purchases) do
        CreatorLogs.Emit('clothing_purchased', {
            playerSource = tonumber(src), charid = tostring(charid),
            items = { { category = item.category, hash = item.hash, tint = item.tint, dyed = item.dyed } },
            price = item.price, store = loc and loc.id or nil,
        })
    end
end

local function commitStore(src, s, submitted)
    if s.kind ~= 'store' then return fail('SESSION_NOT_FOUND') end
    if not WCServices.enabled('clothingStores') then return fail(WCServices.code('clothingStores')) end
    local loc = s.location and WCLocations.byId(s.location.id) or nil
    if not loc or not loc.enabled or not WCLocations.isOpen(loc) then return fail('LOCATION_DISABLED') end

    local saved, meta = WCAppearanceRepo.load(s.charid)
    if not saved then return fail(type(meta) == 'table' and meta.error or 'CHARACTER_NOT_FOUND') end
    -- A defaults-filled appearance is never overwritten automatically (WCAppearanceRepo): refuse
    -- before anything is charged.
    if type(meta) == 'table' and meta.degraded then return fail('INTERNAL_ERROR') end
    local owned, ownedCode = WCOwnership.list(s.charid)
    if not owned then return fail(ownedCode or 'DATABASE_ERROR') end

    local plan, code, detail = Store.plan(saved, submitted, owned, loc)
    if not plan then
        WCDebug.log('store', 'commit by %s refused: %s %s', tostring(src), tostring(code), tostring(detail or ''))
        return fail(code, detail and { category = detail } or nil)
    end
    if plan.empty then return fail('NO_CHANGES') end

    -- Only what is bought (or dyed) here becomes owned. The clothing the player arrived in is not
    -- granted: the pre-v3 outfit is owned since its lazy upgrade ('legacy', WCAppearanceRepo) and a
    -- worn item without an ownership row was applied by another resource (SetClothes: a job
    -- uniform), which must never become owned (the wardrobe rule, §5.6).
    local extra = {}
    for _, q in ipairs(WCOwnership.grantQueries(s.charid, plan.grants, 'store')) do extra[#extra + 1] = q end

    local result = WCEconomy.withCharge(src, plan.total, 'clothing', function()
        local ok, app = WCAppearanceRepo.save(s.charid, plan.merged, extra)
        if not ok then return WCResult.fail(app or 'DATABASE_ERROR') end
        return WCResult.ok({ appearance = app })
    end)
    if not result.ok then return result end

    local app = result.data.appearance
    local purchases = {}
    for _, item in ipairs(plan.purchases) do
        purchases[#purchases + 1] = { category = item.category, hash = item.hash, price = item.price,
                                      tint = item.tint, dyed = item.dyed }
    end
    result.data.charged = result.charged or 0
    result.data.purchases = purchases
    WCSync.broadcast(src, app)
    emitPurchases(src, s.charid, loc, plan.purchases)
    CreatorLogs.Emit('appearance_changed', { playerSource = tonumber(src), charid = tostring(s.charid),
                                             sections = plan.statesChanged and { 'clothing', 'states' } or { 'clothing' },
                                             kind = 'store' })
    TriggerEvent('w_creators:server:appearanceChanged', src, s.charid, 'store')
    WCDebug.log('store', '%s bought %d item(s) for %.2f at %s', tostring(src), #purchases, result.data.charged, loc.id)
    return result
end

--- Commit a store session. Result data { appearance, charged, purchases = [{category, hash, ...}] }.
function Store.commit(src, token, opId, submitted)
    if not WCSecurity.rate(src, 'store:commit', 6, 10000) then return fail('RATE_LIMITED') end
    if type(token) ~= 'string' or #token > MAX_TOKEN or type(submitted) ~= 'table'
        or not WCSecurity.payload(submitted, MAX_PAYLOAD) then
        return fail('INVALID_PAYLOAD')
    end
    return WCSessions.commit(src, token, opId, function(s) return commitStore(src, s, submitted) end, { kind = 'store' })
end

w.callback.register('w_creators:store:open', function(src, locationId)
    return Store.open(src, locationId)
end)

w.callback.register('w_creators:store:commit', function(src, token, opId, app)
    return Store.commit(src, token, opId, app)
end)
