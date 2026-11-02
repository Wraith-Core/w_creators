-- =====================================================================
--  server/clothing/items.lua  —  WCClothingItems: clothing as inventory items
--  (Config.Clothing.items, OFF by default)
--
--  Ownership stays in w_creators' own tables: an item never grants anything by being held. Two
--  items, both handed over through w_lib's framework bridge (w.framework:giveItem / removeItem /
--  registerUseItem) so any supported inventory carries them:
--
--    garment (Config.Clothing.items.garment)
--      w_creators:wardrobe:wrap(token, hash)   an owned item that is not worn, not in a saved outfit
--          and not a starting one leaves the character (its row and its owned colours, one
--          transaction) and becomes the item, metadata { sex, category, hash, tint, colors, label }.
--          A failed hand-over puts the rows back.
--      using it: the character (same sex) gets the item (source 'gift': never resold, since nothing
--          was paid for it) and its colours, THEN the item is taken; a failed take removes the rows
--          again. An item the character owns already is refused (the item is kept).
--
--    outfit card (Config.Clothing.items.outfitCard)
--      w_creators:outfits:share(token, id)     a saved outfit of the character becomes a card,
--          metadata { name, sex, items = { { category, hash, tint } } }. It grants nothing.
--      using it: at a clothing store (within its reach) the store opens with the card's look tried
--          on: owned pieces are free, the rest priced as usual (the store's own commit decides).
-- =====================================================================

WCClothingItems = {}
local I = WCClothingItems

local MAX_TOKEN = 128
local LOCK_MS = 15000

I.MSG_WRAPPED = 'لُفّت القطعة ووُضعت في حقيبتك'
I.MSG_UNWRAPPED = 'أُضيفت القطعة إلى ملابسك'
I.MSG_OWNED = 'تملك هذه القطعة بالفعل'
I.MSG_CARD = 'أُعطيت بطاقة الطقم'
I.MSG_NEED_STORE = 'استخدم بطاقة الطقم داخل متجر للملابس'

local function fail(code, data) return WCResult.fail(code, data) end

local function cfg()
    return Config.Clothing and type(Config.Clothing.items) == 'table' and Config.Clothing.items or {}
end

--- Is the inventory bridge on?
function I.enabled()
    return cfg().enabled == true
end

local function itemName(key)
    local name = cfg()[key]
    return type(name) == 'string' and name ~= '' and name or nil
end

local function notify(src, key, kind)
    pcall(Bridge.Notify, src, key, kind or 'inform')
end

--- The player's open wardrobe session of this token, at its location: session | nil, code.
local function wardrobeSession(src, token)
    if type(token) ~= 'string' or #token > MAX_TOKEN then return nil, 'SESSION_NOT_FOUND' end
    local s, code = WCSessions.get(src, token)
    if not s then return nil, code end
    if s.kind ~= 'wardrobe' then return nil, 'SESSION_NOT_FOUND' end
    if s.busy then return nil, 'BUSY' end
    -- the wardrobe commit's own gates: the service, the location as it is now (or, remote, only
    -- while remote wardrobes are allowed) and its access rule
    if not WCServices.enabled('wardrobe') then return nil, WCServices.code('wardrobe') end
    if s.location then
        local loc = WCLocations.byId(s.location.id)
        if not loc or not loc.enabled or not WCLocations.isOpen(loc) then return nil, WCLocations.closedCode(loc) end
        if not WCSessions.withinRange(src, s.location) then return nil, 'TOO_FAR' end
        if not WCSessions.accessAllowed(src, loc) then return nil, 'ACCESS_DENIED' end
    elseif not WCSessions.remoteAllowed(src, s) then -- 1.0.8: or a home wardrobe
        return nil, 'LOCATION_NOT_FOUND'
    end
    return s
end

--- Run fn() holding the character's appearance lock and its outfit lock (no commit, state write or
--  outfit save can see the item half gone). Result of fn, or BUSY / INTERNAL_ERROR.
local function locked(charid, owner, fn)
    if not WCSessions.lockCharacter(charid, owner) then return fail('BUSY') end
    local outfitLock = 'outfits:' .. tostring(charid)
    if not WCSecurity.lock(outfitLock, LOCK_MS) then
        WCSessions.unlockCharacter(charid, owner)
        return fail('BUSY')
    end
    local ok, result = pcall(fn)
    WCSecurity.unlock(outfitLock)
    WCSessions.unlockCharacter(charid, owner)
    if not ok then
        WCDebug.warn('items', 'clothing item operation failed: %s', tostring(result))
        return fail('INTERNAL_ERROR')
    end
    return result
end

local function inOutfit(list, hash)
    for _, outfit in ipairs(list or {}) do
        local data = type(outfit.data) == 'table' and outfit.data or {}
        for _, h in pairs(type(data.equipped) == 'table' and data.equipped or {}) do
            if WCUtil.u32(h) == hash then return true end
        end
    end
    return false
end

--- The queries that give an item and its colours to a character (source kept or 'gift').
local function grantAll(charid, category, hash, tint, colors, source)
    local queries = WCOwnership.grantQueries(charid, { { category = category, hash = hash, tint = tint } }, source)
    for _, color in ipairs(colors or {}) do
        if not WCOwnership.sameTint(color, tint) then
            for _, q in ipairs(WCOwnership.grantQueries(charid, { { category = category, hash = hash, tint = color } }, source)) do
                if q.query:find('w_creators_colorways', 1, true) then queries[#queries + 1] = q end
            end
        end
    end
    return queries
end

local function deleteRows(charid, hash)
    local id = tostring(charid)
    local ok, done = pcall(w.database.transaction.await, {
        { query = WCOwnership.DELETE_ITEM, values = { id, hash } },
        { query = WCOwnership.DELETE_COLORS, values = { id, hash } },
    })
    return ok and done == true
end

-- ---------------------------------------------------------------------
--  Garment: wrap and use
-- ---------------------------------------------------------------------

--- Wrap an owned item into a garment item (a wardrobe session). Result data { owned }.
function I.wrap(src, token, hash)
    if not WCSecurity.rate(src, 'items:wrap', 4, 10000) then return fail('RATE_LIMITED') end
    if not I.enabled() or not itemName('garment') then return fail('ITEMS_DISABLED') end
    local h = (type(hash) == 'number' or type(hash) == 'string') and WCUtil.u32(hash) or nil
    if not h or h == 0 then return fail('INVALID_PAYLOAD') end
    local s, code = wardrobeSession(src, token)
    if not s then return fail(code) end
    return locked(s.charid, 'wrap:' .. s.token, function()
        local owned, listCode = WCOwnership.list(s.charid)
        if not owned then return fail(listCode or 'DATABASE_ERROR') end
        local entry = WCOwnership.entry(owned, h)
        if not entry then return fail('ITEM_NOT_OWNED') end
        -- a starting outfit piece is the character's own and never leaves it
        if entry.source == 'starter' then return fail('NOT_RESELLABLE') end
        local saved, meta = WCAppearanceRepo.load(s.charid)
        if not saved then return fail(type(meta) == 'table' and meta.error or 'CHARACTER_NOT_FOUND') end
        for _, worn in pairs(saved.clothing.equipped) do
            if worn == h then return fail('ITEM_WORN') end
        end
        local outfits, outfitsCode = WCOutfits.list(s.charid, s.sex)
        if not outfits then return fail(outfitsCode or 'DATABASE_ERROR') end
        if inOutfit(outfits, h) then return fail('ITEM_IN_OUTFIT') end

        local tint = WCOwnership.tintOf(owned, h, entry.category)
        local colors = WCOwnership.colorsOf(owned, h, entry.category)
        local info = WCCatalog.item(s.sex, h)
        local metadata = {
            sex = s.sex, category = entry.category, hash = h, tint = tint, colors = colors,
            label = WCCatalog.styleLabel(entry.category, info and info.model or 0),
        }
        -- the rows leave first; the item is handed over after, and a failed hand-over puts them back
        if not deleteRows(s.charid, h) then return fail('DATABASE_ERROR') end
        local okGive, given = pcall(function() return w.framework:giveItem(src, itemName('garment'), 1, metadata) end)
        if not okGive or given ~= true then
            local okBack, back = pcall(w.database.transaction.await,
                grantAll(s.charid, entry.category, h, tint, colors, entry.source))
            if not okBack or back ~= true then
                CreatorLogs.Emit('security_violation', { playerSource = tonumber(src), kind = 'wrap_restore_failed',
                                                         detail = tostring(h), reason = 'wrap_restore_failed' })
            end
            return fail('INVENTORY_FULL')
        end
        CreatorLogs.Emit('clothing_item', { playerSource = tonumber(src), charid = tostring(s.charid), action = 'wrap',
                                            hash = h, category = entry.category, item = itemName('garment') })
        notify(src, I.MSG_WRAPPED, 'success')
        local fresh = WCOwnership.list(s.charid)
        return WCResult.ok({ owned = fresh })
    end)
end

--- The metadata of an item use (the bridge passes { metadata } or the metadata itself).
local function metadataOf(data)
    if type(data) ~= 'table' then return {} end
    if type(data.metadata) == 'table' then return data.metadata end
    if type(data.meta) == 'table' then return data.meta end
    return data
end

--- The active character and its sex: charid, sex | nil.
local function activeWithSex(src)
    local active = WCSessions.activeCharacter(src)
    if not active then return nil end
    local sex = active.sex
    if sex ~= 'male' and sex ~= 'female' then
        local app = WCAppearanceRepo.load(active.charid)
        sex = type(app) == 'table' and app.sex or nil
    end
    return active.charid, sex
end

--- Use a garment item: the character gets the item (and its colours), then the item is taken.
function I.useGarment(src, data)
    if not I.enabled() then return fail('ITEMS_DISABLED') end
    if not WCSecurity.rate(src, 'items:use', 4, 10000) then return fail('RATE_LIMITED') end
    local meta = metadataOf(data)
    local charid, sex = activeWithSex(src)
    if not charid or not sex then return fail('NO_CHARACTER') end
    if meta.sex ~= sex then return fail('WRONG_SEX') end
    local category = meta.category
    if type(category) ~= 'string' or not WCCatalog.isClothing(category) then return fail('INVALID_COMPONENT') end
    local h = WCCatalog.resolve(sex, category, meta.hash)
    if not h then return fail('INVALID_COMPONENT') end
    local tint = WCOwnership.storedTint(category, meta.tint)
    local colors = {}
    for _, t in ipairs(type(meta.colors) == 'table' and meta.colors or {}) do
        local clean = WCOwnership.storedTint(category, t)
        if clean then colors[#colors + 1] = clean end
    end
    return locked(charid, 'unwrap:' .. tostring(src), function()
        local owned, code = WCOwnership.list(charid)
        if not owned then return fail(code or 'DATABASE_ERROR') end
        if WCOwnership.entry(owned, h) then
            notify(src, I.MSG_OWNED, 'error')
            return fail('NO_CHANGES')
        end
        -- the grant first, then the item: a take that fails removes what was granted
        local okTx, done = pcall(w.database.transaction.await, grantAll(charid, category, h, tint, colors, 'gift'))
        if not okTx or done ~= true then return fail('DATABASE_ERROR') end
        local okTake, taken = pcall(function() return w.framework:removeItem(src, itemName('garment'), 1, meta) end)
        if not okTake or taken ~= true then
            if not deleteRows(charid, h) then
                CreatorLogs.Emit('security_violation', { playerSource = tonumber(src), kind = 'unwrap_rollback_failed',
                                                         detail = tostring(h), reason = 'unwrap_rollback_failed' })
            end
            return fail('INTERNAL_ERROR')
        end
        CreatorLogs.Emit('clothing_item', { playerSource = tonumber(src), charid = tostring(charid), action = 'unwrap',
                                            hash = h, category = category, item = itemName('garment') })
        notify(src, I.MSG_UNWRAPPED, 'success')
        return WCResult.ok({ hash = h })
    end)
end

-- ---------------------------------------------------------------------
--  Outfit card: share and use
-- ---------------------------------------------------------------------

--- Give a card of one of the character's saved outfits (a wardrobe session). Result data {}.
function I.share(src, token, id)
    if not WCSecurity.rate(src, 'items:share', 4, 10000) then return fail('RATE_LIMITED') end
    if not I.enabled() or not itemName('outfitCard') then return fail('ITEMS_DISABLED') end
    if not WCServices.enabled('savedOutfits') then return fail(WCServices.code('savedOutfits')) end
    local s, code = wardrobeSession(src, token)
    if not s then return fail(code) end
    local outfitId = WCOwnership.exactId(id)
    if not outfitId then return fail('OUTFIT_NOT_FOUND') end
    local outfit = WCOutfits.get(s.charid, outfitId, s.sex)
    if not outfit then return fail('OUTFIT_NOT_FOUND') end
    local owned = WCOwnership.list(s.charid) or {}
    local items = {}
    for _, category in ipairs(WCUtil.sortedKeys(outfit.data.equipped)) do
        local h = outfit.data.equipped[category]
        local want = type(outfit.data.tints) == 'table' and outfit.data.tints[category]
        local tint
        if want == false then tint = nil elseif type(want) == 'table' then tint = want else tint = WCOwnership.tintOf(owned, h, category) end
        items[#items + 1] = { category = category, hash = h, tint = tint }
    end
    local metadata = { name = outfit.name, sex = s.sex, items = items }
    local okGive, given = pcall(function() return w.framework:giveItem(src, itemName('outfitCard'), 1, metadata) end)
    if not okGive or given ~= true then return fail('INVENTORY_FULL') end
    CreatorLogs.Emit('clothing_item', { playerSource = tonumber(src), charid = tostring(s.charid), action = 'share',
                                        item = itemName('outfitCard') })
    notify(src, I.MSG_CARD, 'success')
    return WCResult.ok({})
end

--- The clothing store the player stands at (within its reach, open, usable, allowed), or nil.
local function storeHere(src)
    for _, loc in ipairs(WCLocations.byType('clothing')) do
        if WCLocations.isUsable(loc) and WCSessions.withinRange(src, loc) and WCSessions.accessAllowed(src, loc) then
            return loc
        end
    end
    return nil
end

--- Use an outfit card: at a clothing store, the store opens with the card's look tried on.
function I.useCard(src, data)
    if not I.enabled() then return fail('ITEMS_DISABLED') end
    if not WCSecurity.rate(src, 'items:use', 4, 10000) then return fail('RATE_LIMITED') end
    local meta = metadataOf(data)
    local charid, sex = activeWithSex(src)
    if not charid or not sex then return fail('NO_CHARACTER') end
    if meta.sex ~= sex then return fail('WRONG_SEX') end
    local loc = storeHere(src)
    if not loc then
        -- told as "use it inside a store" (the item handler shows the message)
        local far = fail('TOO_FAR')
        far.message = I.MSG_NEED_STORE
        return far
    end
    -- only real items of the sex travel to the client; the store's commit prices and checks them
    local look = { equipped = {}, tints = {} }
    for _, item in ipairs(type(meta.items) == 'table' and meta.items or {}) do
        local category = type(item) == 'table' and item.category
        local h = type(category) == 'string' and WCCatalog.isClothing(category) and WCCatalog.resolve(sex, category, item.hash)
        if h then
            look.equipped[category] = h
            look.tints[category] = WCOwnership.storedTint(category, item.tint) or false
        end
    end
    TriggerClientEvent('w_creators:client:openStore', src, loc.id, look)
    return WCResult.ok({ locationId = loc.id })
end

-- ---------------------------------------------------------------------
--  Registration
-- ---------------------------------------------------------------------

w.callback.register('w_creators:wardrobe:wrap', function(src, token, hash)
    return I.wrap(src, token, hash)
end)

w.callback.register('w_creators:outfits:share', function(src, token, id)
    return I.share(src, token, id)
end)

--- Register the two usable items with the inventory (once, when the bridge is on).
function I.registerItems()
    if not I.enabled() then return false end
    local registered = false
    for key, handler in pairs({ garment = I.useGarment, outfitCard = I.useCard }) do
        local name = itemName(key)
        if name then
            local ok, err = pcall(function()
                w.framework:registerUseItem(name, true, function(source, data)
                    local result = handler(source, data)
                    if type(result) == 'table' and result.ok == false and result.code ~= 'NO_CHANGES' then
                        notify(source, result.message or WCResult.messageKey(result.code), 'error')
                    end
                end)
            end)
            if ok then registered = true else WCDebug.warn('items', 'registering %s failed: %s', name, tostring(err)) end
        end
    end
    return registered
end

CreateThread(function()
    I.registerItems()
end)
