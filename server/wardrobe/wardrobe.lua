-- =====================================================================
--  server/wardrobe/wardrobe.lua  —  the wardrobe (ARCHITECTURE.md §5.4, §5.6, §9.3, §16.4)
--  Wearing owned clothing, the clothing states and saved outfits; always free.
--  Callbacks:
--    w_creators:wardrobe:open(locationId | nil) -> { token, appearance, owned, outfits = [{id, name, data}],
--                                                    maxOutfits, outfitsEnabled, remote, expiresIn }
--       nil = a remote wardrobe (exports / job resources): only with Config.Wardrobe.allowRemote.
--       `owned` also lists the items worn now that have no ownership row, as { ..., source = 'worn',
--       worn = true } (display only: the wardrobe never writes ownership).
--    w_creators:wardrobe:commit(token, opId, app) -> { appearance }
--  Commit merges the clothing and states sections only; every worn item must be owned (the item
--  already worn in the saved appearance is kept in its category even when no ownership row exists),
--  every tint comes from ownership (the wardrobe cannot dye), and a state is kept only while its
--  item is worn.
-- =====================================================================

WCWardrobeService = {}
local Wardrobe = WCWardrobeService

local MAX_PAYLOAD = 64 * 1024
local MAX_TOKEN = 128

local function fail(code, data) return WCResult.fail(code, data) end

local function outfitsEnabled()
    return WCServices.enabled('savedOutfits')
end

local function maxOutfits()
    return WCUtil.int(Config.Wardrobe and Config.Wardrobe.maxSavedOutfits, 0, 100, 10)
end
Wardrobe.maxOutfits = maxOutfits

--- Open a wardrobe session. locationId nil = remote (Config.Wardrobe.allowRemote).
function Wardrobe.open(src, locationId)
    if locationId ~= nil and (type(locationId) ~= 'string' or #locationId > 64) then
        return fail('INVALID_PAYLOAD')
    end
    local opened = WCSessions.open(src, 'wardrobe', { locationId = locationId, remote = locationId == nil })
    if not opened.ok then return opened end
    local s = opened.data.session

    -- A defaults-filled appearance can never be committed (see commitWardrobe): refuse up front.
    if WCAppearanceRepo.degraded(s.charid) then
        WCSessions.close(src, s.token)
        return fail('INTERNAL_ERROR')
    end
    local owned, code = WCOwnership.list(s.charid)
    if not owned then
        WCSessions.close(src, s.token)
        return fail(code or 'DATABASE_ERROR')
    end
    -- The items worn now stay wearable in this wardrobe (Wardrobe.plan keeps them in their saved
    -- category) but are never made owned here: they are listed for the editor only, marked `worn`.
    -- (Clothing applied by another resource, e.g. a job uniform, must not become owned.)
    for _, category in ipairs(WCUtil.sortedKeys(s.snapshot.clothing.equipped)) do
        local hash = s.snapshot.clothing.equipped[category]
        local key = WCOwnership.key(hash)
        if key and hash ~= 0 and not owned[key] then
            local tint = WCOwnership.cleanTint(category, s.snapshot.clothing.tints[category]) or {}
            owned[key] = { category = category, palette = tint.palette, tint0 = tint.tint0,
                           tint1 = tint.tint1, tint2 = tint.tint2, source = 'worn', worn = true }
        end
    end

    local outfits = {}
    if outfitsEnabled() then
        local list, listCode = WCOutfits.list(s.charid, s.sex)
        if not list then
            WCSessions.close(src, s.token)
            return fail(listCode or 'DATABASE_ERROR')
        end
        outfits = list
    end
    return WCResult.ok({
        token = s.token,
        appearance = WCUtil.copy(s.snapshot),
        owned = owned,
        outfits = outfits,
        maxOutfits = maxOutfits(),
        outfitsEnabled = outfitsEnabled(),
        remote = s.remote == true,
        expiresIn = math.max(0, s.expires - os.time()),
    })
end

--- The submitted states that persist, are valid and apply to `app` (an appearance or
--  { clothing = { equipped } }); without `app` only persistence and validity are checked.
local function validStates(states, app)
    local out = {}
    if type(states) ~= 'table' then return out end
    for group, value in pairs(states) do
        local def = type(group) == 'string' and WCClothingStates.byId[group]
        if def and def.persist and WCClothingStates.isValid(group, value)
            and (app == nil or WCClothingStates.applicable(app, group)) then
            out[group] = value
        end
    end
    return out
end
Wardrobe.validStates = validStates

--- Validate a wardrobe submission against the saved appearance. Returns merged | nil, code, detail.
function Wardrobe.plan(saved, submitted, owned, outfitIds)
    if type(submitted) ~= 'table' or type(submitted.clothing) ~= 'table' then return nil, 'INVALID_PAYLOAD' end
    local clothing = submitted.clothing
    -- A missing equipped map is a malformed payload, never "remove everything".
    if type(clothing.equipped) ~= 'table' then return nil, 'INVALID_PAYLOAD' end
    if clothing.states ~= nil and type(clothing.states) ~= 'table' then return nil, 'INVALID_PAYLOAD' end

    local resolved, code, detail = WCOwnership.resolveEquipped(saved.sex, clothing.equipped)
    if not resolved then return nil, code, detail end
    local tints = {}
    for category, hash in pairs(resolved) do
        if WCOwnership.entry(owned, hash) then
            tints[category] = WCOwnership.tintOf(owned, hash, category)
        elseif saved.clothing.equipped[category] == hash then
            tints[category] = WCOwnership.cleanTint(category, saved.clothing.tints[category])
        else
            return nil, 'ITEM_NOT_OWNED', category
        end
    end
    local changed
    changed, code, detail = WCOwnership.checkRules(saved.clothing.equipped, resolved)
    if not changed then return nil, code, detail end

    local outfit = WCOwnership.exactId(clothing.outfit)
    if outfit and not (outfitIds and outfitIds[outfit]) then outfit = nil end

    local draft = WCUtil.copy(saved)
    draft.clothing = { equipped = resolved, tints = tints, states = validStates(clothing.states), outfit = outfit }
    local merged = AppearanceSchema.mergeSections(saved, draft, { clothing = true, states = true })
    for category in pairs(changed) do
        if merged.clothing.equipped[category] ~= resolved[category] then return nil, 'CONFLICTING_ITEMS', category end
    end
    -- A state is kept only while its item is worn (a stored 'off' would otherwise hide an item
    -- equipped later). States on swapped items are the player's choice here: the wardrobe edits
    -- them and its preview shows them.
    merged.clothing.states = validStates(merged.clothing.states, merged)
    local changes = AppearanceSchema.changedSections(saved, merged)
    if not changes.clothing and not changes.states then return nil, 'NO_CHANGES' end
    return merged
end

local function commitWardrobe(src, s, submitted)
    if s.kind ~= 'wardrobe' then return fail('SESSION_NOT_FOUND') end
    if not WCServices.enabled('wardrobe') then return fail(WCServices.code('wardrobe')) end
    if s.location then
        local loc = WCLocations.byId(s.location.id)
        if not loc or not loc.enabled or not WCLocations.isOpen(loc) then return fail('LOCATION_DISABLED') end
    elseif not (Config.Wardrobe and Config.Wardrobe.allowRemote == true) then
        return fail('LOCATION_NOT_FOUND')
    end

    local saved, meta = WCAppearanceRepo.load(s.charid)
    if not saved then return fail(type(meta) == 'table' and meta.error or 'CHARACTER_NOT_FOUND') end
    -- A defaults-filled appearance is never overwritten automatically (WCAppearanceRepo).
    if type(meta) == 'table' and meta.degraded then return fail('INTERNAL_ERROR') end
    local owned, ownedCode = WCOwnership.list(s.charid)
    if not owned then return fail(ownedCode or 'DATABASE_ERROR') end

    local outfitIds
    local wanted = type(submitted) == 'table' and type(submitted.clothing) == 'table' and submitted.clothing.outfit
    if wanted ~= nil and outfitsEnabled() then
        local list = WCOutfits.list(s.charid, s.sex)
        outfitIds = {}
        for _, o in ipairs(list or {}) do outfitIds[o.id] = true end
    end

    local merged, code, detail = Wardrobe.plan(saved, submitted, owned, outfitIds)
    if not merged then
        WCDebug.log('wardrobe', 'commit by %s refused: %s %s', tostring(src), tostring(code), tostring(detail or ''))
        return fail(code, detail and { category = detail } or nil)
    end

    local ok, app = WCAppearanceRepo.save(s.charid, merged)
    if not ok then return fail(app or 'DATABASE_ERROR') end
    WCSync.broadcast(src, app)
    CreatorLogs.Emit('appearance_changed', { playerSource = tonumber(src), charid = tostring(s.charid),
                                             sections = { 'clothing', 'states' }, kind = 'wardrobe' })
    TriggerEvent('w_creators:server:appearanceChanged', src, s.charid, 'wardrobe')
    return WCResult.ok({ appearance = app })
end

--- Commit a wardrobe session (free). Result data { appearance }.
function Wardrobe.commit(src, token, opId, submitted)
    if not WCSecurity.rate(src, 'wardrobe:commit', 6, 10000) then return fail('RATE_LIMITED') end
    if type(token) ~= 'string' or #token > MAX_TOKEN or type(submitted) ~= 'table'
        or not WCSecurity.payload(submitted, MAX_PAYLOAD) then
        return fail('INVALID_PAYLOAD')
    end
    return WCSessions.commit(src, token, opId, function(s) return commitWardrobe(src, s, submitted) end)
end

w.callback.register('w_creators:wardrobe:open', function(src, locationId)
    return Wardrobe.open(src, locationId)
end)

w.callback.register('w_creators:wardrobe:commit', function(src, token, opId, app)
    return Wardrobe.commit(src, token, opId, app)
end)
