-- =====================================================================
--  server/surgery/surgery.lua  —  cosmetic surgery (ARCHITECTURE.md §9.3, §16.4)
--  A clinic is a Config.Locations entry of type 'surgery' (w_ambulancejob provides the interaction
--  and opens it through exports.w_creators:OpenCosmeticSurgery). The procedure may change only the
--  sections Config.CosmeticSurgery.allow permits; everything else is kept from the saved appearance
--  whatever the client submits.
--
--  Callbacks:
--    w_creators:surgery:open(clinicId)          -> { token, appearance, price, allow, sections = { [section] = true },
--                                                    clinic, expiresIn }
--    w_creators:surgery:commit(token, opId, app) -> { appearance, charged, sections = {...} }
--
--  allow key -> section: face -> face, body -> body, eyes -> eyes, skin -> skin, hair -> hair,
--  facialHair -> facialHair (male only), clothing -> clothing.
--  Price (server only): location.price or Config.CosmeticSurgery.price, times the location's pricing
--  profile multiplier, rounded to cents. A submission whose only changes are in sections the clinic
--  does not allow -> SURGERY_NOT_ALLOWED; no change at all -> NO_CHANGES; nothing is charged then.
--  Nothing is written before the commit: a disconnect or a resource stop leaves the saved appearance
--  untouched (WCSessions drops the session).
--  A clinic with prompt = false is opened only by another resource: open() then requires the
--  one-shot grant exports.w_creators:OpenCosmeticSurgery gives (Surgery.grant, GRANT_SECONDS) and
--  refuses a direct callback request (SURGERY_NOT_ALLOWED).
--  With allow.clothing, only owned items may be put on (the wardrobe rule): a new item the character
--  does not own -> ITEM_NOT_OWNED; every worn item keeps its owned (or saved) tint.
--  GlobalState['w_creators:clinics'] = { [clinicId] = true }: the clinics usable now (enabled, service
--  on, open), refreshed on the WCSessions clock tick; w_ambulancejob hides the prompt of the others.
-- =====================================================================

WCSurgeryService = {}
local Surgery = WCSurgeryService

local MAX_PAYLOAD = 64 * 1024
local MAX_TOKEN = 128
local MAX_CLINIC_ID = 64
Surgery.GRANT_SECONDS = 60

local grants = {} -- [src] = { clinicId, expires = GetGameTimer() ms }

Surgery.ALLOW_SECTIONS = {
    face = 'face', body = 'body', eyes = 'eyes', skin = 'skin',
    hair = 'hair', facialHair = 'facialHair', clothing = 'clothing',
}
local ALLOW_ORDER = { 'face', 'body', 'eyes', 'skin', 'hair', 'facialHair', 'clothing' }

-- Every section a player can edit in an appearance (used to tell "nothing changed" from
-- "only forbidden sections changed"); runtime clothing states are not a procedure.
local EDITABLE = { 'body', 'face', 'eyebrows', 'skin', 'eyes', 'hair', 'facialHair', 'makeup', 'clothing' }

local function fail(code, data) return WCResult.fail(code, data) end

local function config()
    return type(Config.CosmeticSurgery) == 'table' and Config.CosmeticSurgery or {}
end

--- The allow flags for a sex: { face = bool, ... } (facialHair is false for a female character).
function Surgery.allow(sex)
    local allow = type(config().allow) == 'table' and config().allow or {}
    local out = {}
    for _, key in ipairs(ALLOW_ORDER) do
        out[key] = allow[key] == true and (key ~= 'facialHair' or sex == 'male')
    end
    return out
end

--- The AppearanceSchema sections a procedure may change for a sex: { [section] = true }.
function Surgery.sections(sex)
    local out = {}
    for key, allowed in pairs(Surgery.allow(sex)) do
        if allowed then out[Surgery.ALLOW_SECTIONS[key]] = true end
    end
    return out
end

--- The pricing profile multiplier of a location, or nil (unknown profile / invalid multiplier).
local function multiplier(loc)
    local id = type(loc) == 'table' and loc.pricingProfile or nil
    local profiles = Config.Clothing and Config.Clothing.pricingProfiles or {}
    local profile = profiles[id or 'standard']
    local m = type(profile) == 'table' and tonumber(profile.multiplier) or nil
    if m == nil or not WCUtil.isFinite(m) or m < 0 then return nil end
    return m
end

--- The price of a procedure at a clinic, or nil (invalid configuration).
function Surgery.price(loc)
    local base = type(loc) == 'table' and tonumber(loc.price) or nil
    if base == nil then base = tonumber(config().price) end
    if base == nil or not WCUtil.isFinite(base) or base < 0 then return nil end
    local m = multiplier(loc)
    if not m then return nil end
    return WCUtil.round2(base * m)
end

local function sectionList(set)
    local out = {}
    for _, section in ipairs(AppearanceSchema.SECTIONS) do
        if set[section] then out[#out + 1] = section end
    end
    return out
end

--- Give a player the one-shot right to open a clinic (OpenCosmeticSurgery, after its checks).
function Surgery.grant(src, clinicId)
    src = tonumber(src)
    if not src or type(clinicId) ~= 'string' then return false end
    grants[src] = { clinicId = clinicId, expires = GetGameTimer() + Surgery.GRANT_SECONDS * 1000 }
    return true
end

--- Does the player hold a live grant for the clinic?
function Surgery.granted(src, clinicId)
    local g = grants[tonumber(src) or src]
    if not g then return false end
    if g.expires < GetGameTimer() then
        grants[tonumber(src) or src] = nil
        return false
    end
    return g.clinicId == clinicId
end

AddEventHandler('playerDropped', function()
    grants[tonumber(source) or source] = nil
end)

-- A clinic whose interaction another resource provides (prompt = false) opens only through a grant.
local function needsGrant(clinicId)
    local loc = WCLocations.byId(clinicId)
    return loc ~= nil and loc.type == 'surgery' and loc.prompt == false
end

--- Open a clinic session. Result data per §16.4.
function Surgery.open(src, clinicId)
    if type(clinicId) ~= 'string' or #clinicId > MAX_CLINIC_ID then return fail('INVALID_PAYLOAD') end
    local opened = WCSessions.open(src, 'surgery', { locationId = clinicId })
    if not opened.ok then return opened end
    local s = opened.data.session
    -- A defaults-filled appearance can never be committed (the repository refuses to save over
    -- it): refused up front, before any grant is used or anything is charged (§9.3).
    if WCAppearanceRepo.degraded(s.charid) then
        WCSessions.close(src, s.token)
        return fail('INTERNAL_ERROR')
    end
    local grantNeeded = needsGrant(clinicId)
    if grantNeeded and not Surgery.granted(src, clinicId) then
        WCDebug.log('surgery', '%s requested %s without a grant', tostring(src), clinicId)
        WCSessions.close(src, s.token)
        return fail('SURGERY_NOT_ALLOWED')
    end
    local sections = Surgery.sections(s.sex)
    if next(sections) == nil then
        WCSessions.close(src, s.token)
        return fail('SURGERY_DISABLED')
    end
    local price = Surgery.price(s.location)
    if not price then
        WCDebug.warn('surgery', 'clinic %s has an invalid price or pricing profile', tostring(s.location.id))
        WCSessions.close(src, s.token)
        return fail('INVALID_PRICE')
    end
    local allow = Surgery.allow(s.sex)
    -- A clinic that allows clothing offers the owned items too (the editor's clothing filter reads
    -- context.owned, which is this open data).
    local owned
    if allow.clothing then
        local list, code = WCOwnership.list(s.charid)
        if not list then
            WCSessions.close(src, s.token)
            return fail(code or 'DATABASE_ERROR')
        end
        owned = list
    end
    -- The one-use grant is consumed only by an open that succeeded.
    if grantNeeded then grants[tonumber(src) or src] = nil end
    return WCResult.ok({
        token = s.token,
        appearance = WCUtil.copy(s.snapshot),
        price = price,
        allow = allow,
        sections = sections,
        owned = owned,
        clinic = s.location.id,
        expiresIn = math.max(0, s.expires - os.time()),
    })
end

-- The wardrobe rule on merged clothing: a worn item differing from the saved set must be owned,
-- essentials are never removed, the rules hold for the changed items, every tint is the owned one
-- (or the saved one of an untouched item). Mutates merged.clothing. true | nil, code, category.
local function ownedClothing(saved, merged, owned)
    local equipped = merged.clothing.equipped
    if WCUtil.deepEqual(equipped, saved.clothing.equipped) then
        merged.clothing.tints = WCUtil.copy(saved.clothing.tints)
        merged.clothing.outfit = saved.clothing.outfit
        return true
    end
    if type(owned) ~= 'table' then return nil, 'ITEM_NOT_OWNED' end
    local tints = {}
    for category, hash in pairs(equipped) do
        -- stored dyes (owned / saved): kept as stored even with tints disabled or narrowed (§5.4)
        local tint, notOwned = WCOwnership.wornTint(saved, owned, category, hash)
        if tint == false then return nil, notOwned, category end
        tints[category] = tint
    end
    local changed, code, category = WCOwnership.checkRules(saved.clothing.equipped, equipped)
    if not changed then return nil, code, category end
    merged.clothing.tints = tints
    merged.clothing.outfit = nil
    -- The saved visibility states are settled (the store rule): a swapped item starts visible and a
    -- state whose item is gone is dropped, so a stored 'off' never hides the item put on now.
    merged.clothing.states = WCOwnership.settleStates(merged, saved.clothing.states,
        WCOwnership.groupsOf(WCOwnership.changedCategories(saved.clothing.equipped, equipped)))
    return true
end

--- Validate and price a submission. owned = WCOwnership.list(charid) (needed only when the clinic
--  allows clothing). Returns plan { merged, changed, sections, total } | nil, code, detail.
function Surgery.plan(saved, submitted, loc, owned)
    if type(submitted) ~= 'table' then return nil, 'INVALID_PAYLOAD' end
    local allowed = Surgery.sections(saved.sex)
    if next(allowed) == nil then return nil, 'SURGERY_DISABLED' end
    local valid, invalidCode = WCBarberService.validStyles(saved.sex, submitted, allowed)
    if not valid then return nil, invalidCode end
    local merged = AppearanceSchema.mergeSections(saved, submitted, allowed)
    if allowed.clothing then
        local clothingOk, code, category = ownedClothing(saved, merged, owned)
        if not clothingOk then return nil, code, category end
    end
    local changed = {}
    for section in pairs(AppearanceSchema.changedSections(saved, merged)) do
        if allowed[section] then changed[section] = true end
    end
    if next(changed) == nil then
        -- Nothing allowed changed: did the submission try to change something else?
        local attempted = AppearanceSchema.changedSections(saved, AppearanceSchema.mergeSections(saved, submitted, EDITABLE))
        attempted.states, attempted.identity = nil, nil
        if next(attempted) ~= nil then return nil, 'SURGERY_NOT_ALLOWED' end
        return nil, 'NO_CHANGES'
    end
    local total = Surgery.price(loc)
    if not total then return nil, 'INVALID_PRICE' end
    if changed.hair or changed.facialHair then WCGrooming.cut(merged, saved) end
    return { merged = merged, changed = changed, sections = sectionList(changed), total = total }
end

local function commitSurgery(src, s, submitted)
    if s.kind ~= 'surgery' then return fail('SESSION_NOT_FOUND') end
    if not WCServices.enabled('surgery') then return fail(WCServices.code('surgery')) end
    local loc = s.location and WCLocations.byId(s.location.id) or nil
    if not loc or not loc.enabled or not WCLocations.isOpen(loc) then return fail('LOCATION_DISABLED') end

    local saved, meta = WCAppearanceRepo.load(s.charid)
    if not saved then return fail(type(meta) == 'table' and meta.error or 'CHARACTER_NOT_FOUND') end
    -- Refused before anything is charged: the save would refuse the degraded character anyway.
    if type(meta) == 'table' and meta.degraded then return fail('INTERNAL_ERROR') end

    local owned
    if Surgery.sections(saved.sex).clothing then
        local ownedCode
        owned, ownedCode = WCOwnership.list(s.charid)
        if not owned then return fail(ownedCode or 'DATABASE_ERROR') end
    end

    local plan, code, detail = Surgery.plan(saved, submitted, loc, owned)
    if not plan then
        WCDebug.log('surgery', 'commit by %s refused: %s %s', tostring(src), tostring(code), tostring(detail or ''))
        return fail(code, detail and { category = detail } or nil)
    end
    -- The in-memory growth since the last save: a cut kind drops it, the other kind keeps it.
    local folded = WCGroomingServer and WCGroomingServer.fold(s.charid, plan.merged, saved, meta) or 0

    local result = WCEconomy.withCharge(src, plan.total, 'surgery', function()
        local ok, app = WCAppearanceRepo.save(s.charid, plan.merged)
        if not ok then return WCResult.fail(app or 'DATABASE_ERROR') end
        return WCResult.ok({ appearance = app })
    end)
    if not result.ok then return result end

    local app = result.data.appearance
    result.data.charged = result.charged or 0
    result.data.sections = plan.sections
    if WCGroomingServer then WCGroomingServer.consumed(s.charid, folded) end
    WCSync.broadcast(src, app)
    CreatorLogs.Emit('surgery_completed', {
        playerSource = tonumber(src), charid = tostring(s.charid), price = result.data.charged,
        sections = plan.sections, clinic = loc.id,
    })
    CreatorLogs.Emit('appearance_changed', { playerSource = tonumber(src), charid = tostring(s.charid),
                                             sections = plan.sections, kind = 'surgery' })
    TriggerEvent('w_creators:server:appearanceChanged', src, s.charid, 'surgery')
    WCDebug.log('surgery', '%s paid %.2f at %s for %s', tostring(src), result.data.charged, loc.id,
        table.concat(plan.sections, ','))
    return result
end

--- Commit a clinic session. Result data { appearance, charged, sections }.
function Surgery.commit(src, token, opId, submitted)
    if not WCSecurity.rate(src, 'surgery:commit', 6, 10000) then return fail('RATE_LIMITED') end
    if type(token) ~= 'string' or #token > MAX_TOKEN or type(submitted) ~= 'table'
        or not WCSecurity.payload(submitted, MAX_PAYLOAD) then
        return fail('INVALID_PAYLOAD')
    end
    return WCSessions.commit(src, token, opId, function(s) return commitSurgery(src, s, submitted) end, { kind = 'surgery' })
end

-- ---------------------------------------------------------------------
--  The clinics that can be opened now, for w_ambulancejob (its surgery prompts, client/job.lua):
--  GlobalState['w_creators:clinics'] = { [clinicId] = true } for every surgery location that is
--  usable (enabled, surgery service on, inside its opening hours); a closed clinic is absent.
--  Published at start and on every WCSessions clock tick (60 s), only when it changed.
-- ---------------------------------------------------------------------
Surgery.CLINICS_KEY = 'w_creators:clinics'
local publishedClinics

--- The usable clinics now: { [clinicId] = true }.
function Surgery.clinics()
    local out = {}
    for _, loc in ipairs(WCLocations.byType('surgery')) do
        if type(loc.id) == 'string' and WCLocations.isUsable(loc) then out[loc.id] = true end
    end
    return out
end

--- Publish Surgery.clinics() to GlobalState when it differs from the last publication. Returns the
--  published set (nil when GlobalState is unavailable).
function Surgery.publishClinics()
    local clinics = Surgery.clinics()
    if publishedClinics and WCUtil.deepEqual(publishedClinics, clinics) then return clinics end
    local done = pcall(function() GlobalState[Surgery.CLINICS_KEY] = clinics end)
    if not done then return nil end
    publishedClinics = clinics
    return clinics
end

Surgery.publishClinics()
if WCSessions and WCSessions.onClock then WCSessions.onClock(Surgery.publishClinics) end

w.callback.register('w_creators:surgery:open', function(src, clinicId)
    return Surgery.open(src, clinicId)
end)

w.callback.register('w_creators:surgery:commit', function(src, token, opId, app)
    return Surgery.commit(src, token, opId, app)
end)
