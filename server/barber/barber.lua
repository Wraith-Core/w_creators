-- =====================================================================
--  server/barber/barber.lua  —  the barber (ARCHITECTURE.md §9.3, §16.4)
--  Hair, facial hair and the configured cosmetic details (eyebrow overlay, makeup overlays) only:
--  the barber never touches the face bones, the body or the skin. Every other section of a
--  submission is ignored; the saved appearance wins.
--
--  Callbacks:
--    w_creators:barber:open(locationId)        -> { token, appearance, growth, services = {
--                                                    hair = {enabled, price}, facialHair = {enabled, price},
--                                                    details = {enabled, price, eyebrows, makeup} },
--                                                    multiplier, visitCap, sections = { [section] = true },
--                                                    location, expiresIn }
--    w_creators:barber:commit(token, opId, app) -> { appearance, charged, sections = {...} }
--
--  Sections offered at a location (all must hold):
--    hair        Config.Barber.services.hair.enabled        and location.allowedServices.hair
--    facialHair  Config.Barber.services.facialHair.enabled  and location.allowedServices.facialHair and male
--    eyebrows    Config.Barber.services.details.enabled and details.eyebrows and allowedServices.details
--    makeup      Config.Barber.services.details.enabled and details.makeup   and allowedServices.details
--  (location.allowedServices = nil allows every service.)
--
--  Price (server only, never read from a payload): the sum of the prices of the services whose
--  sections changed (hair; facialHair; details once for eyebrows and/or makeup), capped at
--  Config.Barber.prices.visitCap (a base price, as the pre-v3 flat price was), then multiplied by the
--  location's pricing profile (Config.Clothing.pricingProfiles[location.pricingProfile or 'standard'])
--  and rounded to cents. No change -> NO_CHANGES and nothing is charged. The open() payload carries
--  the multiplied service prices, the multiplier and the multiplied cap (visitCap, nil = no cap).
--  A committed haircut restarts the growth of each kind whose style changed (WCGrooming.cut); the
--  pending in-memory growth of the kind that was not cut is saved with it (WCGroomingServer.fold).
-- =====================================================================

WCBarberService = {}
local Barber = WCBarberService

local MAX_PAYLOAD = 64 * 1024
local MAX_TOKEN = 128
local MAX_LOCATION_ID = 64

-- service -> the AppearanceSchema sections it covers
Barber.SERVICE_SECTIONS = {
    hair = { 'hair' },
    facialHair = { 'facialHair' },
    details = { 'eyebrows', 'makeup' },
}
local SERVICE_ORDER = { 'hair', 'facialHair', 'details' }

local function fail(code, data) return WCResult.fail(code, data) end

local function servicesConfig()
    local barber = Config.Barber
    return type(barber) == 'table' and type(barber.services) == 'table' and barber.services or {}
end

--- The base price of a service, or nil when it is missing or not a finite number >= 0 (a free
--  service is an explicit price = 0).
local function basePrice(key)
    local svc = servicesConfig()[key]
    local price = type(svc) == 'table' and tonumber(svc.price) or nil
    if price == nil or not WCUtil.isFinite(price) or price < 0 then return nil end
    return price
end

--- The configured visit cap (a base price), or nil (no cap).
local function baseCap()
    local prices = Config.Barber and Config.Barber.prices or {}
    local cap = tonumber(prices.visitCap)
    if cap ~= nil and WCUtil.isFinite(cap) and cap >= 0 then return cap end
    return nil
end

--- The pricing profile multiplier of a location, or nil (unknown profile / invalid multiplier).
function Barber.multiplier(loc)
    local id = type(loc) == 'table' and loc.pricingProfile or nil
    local profiles = Config.Clothing and Config.Clothing.pricingProfiles or {}
    local profile = profiles[id or 'standard']
    local multiplier = type(profile) == 'table' and tonumber(profile.multiplier) or nil
    if multiplier == nil or not WCUtil.isFinite(multiplier) or multiplier < 0 then return nil end
    return multiplier
end

--- The services and the allowed sections at a location for a sex.
--  Returns services { hair = {enabled}, facialHair = {enabled}, details = {enabled, eyebrows, makeup} },
--          sections { [section] = true }.
function Barber.offer(loc, sex)
    local cfg = servicesConfig()
    local allowedAt = type(loc) == 'table' and loc.allowedServices or nil
    local function on(key)
        local svc = cfg[key]
        if type(svc) ~= 'table' or svc.enabled == false then return false end
        return type(allowedAt) ~= 'table' or allowedAt[key] == true
    end
    local details = type(cfg.details) == 'table' and cfg.details or {}
    local detailsOn = on('details')
    local services = {
        hair = { enabled = on('hair') },
        facialHair = { enabled = on('facialHair') and sex == 'male' },
        details = {
            eyebrows = detailsOn and details.eyebrows == true,
            makeup = detailsOn and details.makeup == true,
        },
    }
    services.details.enabled = services.details.eyebrows or services.details.makeup
    local sections = {}
    if services.hair.enabled then sections.hair = true end
    if services.facialHair.enabled then sections.facialHair = true end
    if services.details.eyebrows then sections.eyebrows = true end
    if services.details.makeup then sections.makeup = true end
    return services, sections
end

--- The services with their prices after the location's pricing profile (the open() payload).
local function pricedServices(loc, services)
    local multiplier = Barber.multiplier(loc)
    local out = {}
    for _, key in ipairs(SERVICE_ORDER) do
        local entry = WCUtil.copy(services[key])
        local base = basePrice(key)
        entry.price = (base and multiplier) and WCUtil.round2(base * multiplier) or nil
        out[key] = entry
    end
    return out
end

--- The price of a visit that changed `changed` ({ [section] = true }) at `loc`.
--  Returns total, services (the service keys charged, in order) | nil, 'INVALID_PRICE'.
function Barber.price(loc, changed)
    changed = type(changed) == 'table' and changed or {}
    local sum, charged = 0, {}
    for _, key in ipairs(SERVICE_ORDER) do
        local hit = false
        for _, section in ipairs(Barber.SERVICE_SECTIONS[key]) do
            if changed[section] then hit = true end
        end
        if hit then
            local base = basePrice(key)
            if not base then return nil, 'INVALID_PRICE' end
            sum = sum + base
            charged[#charged + 1] = key
        end
    end
    local cap = baseCap()
    if cap ~= nil and sum > cap then sum = cap end
    local multiplier = Barber.multiplier(loc)
    if not multiplier then return nil, 'INVALID_PRICE' end
    local total = WCUtil.round2(sum * multiplier)
    if not total then return nil, 'INVALID_PRICE' end
    return total, charged
end

-- The sections of a set as a list in AppearanceSchema.SECTIONS order.
local function sectionList(set)
    local out = {}
    for _, section in ipairs(AppearanceSchema.SECTIONS) do
        if set[section] then out[#out + 1] = section end
    end
    return out
end
Barber.sectionList = sectionList

-- The hair / beard growth plate of the barber: only while grooming runs (Config.Grooming.enabled:
-- with the growth loop off, a countdown would announce growth that never happens). Each kind is
-- { stage, seconds, remainingMinutes, stages = <stage count>, fullyGrown = bool }: at the last stage
-- there is no next one (fullyGrown; remainingMinutes stays 0 for older clients).
local function growthInfo(app)
    if type(Config.Grooming) ~= 'table' or Config.Grooming.enabled ~= true then return nil end
    local info = WCGrooming.info(app)
    local stages = type(Config.Grooming.stages) == 'table' and Config.Grooming.stages[app.sex] or nil
    for kind, data in pairs(info) do
        local list = type(stages) == 'table' and stages[kind] or nil
        local count = type(list) == 'table' and #list or 0
        data.stages = count
        data.fullyGrown = count > 0 and data.stage >= count
    end
    return next(info) ~= nil and info or nil
end
Barber.growthInfo = growthInfo

--- Open a barber session. Result data per §16.4.
function Barber.open(src, locationId)
    if type(locationId) ~= 'string' or #locationId > MAX_LOCATION_ID then return fail('INVALID_PAYLOAD') end
    local opened = WCSessions.open(src, 'barber', { locationId = locationId })
    if not opened.ok then return opened end
    local s = opened.data.session
    -- A defaults-filled appearance can never be committed (the repository refuses to save over
    -- it): refused up front, before any grant is used or anything is charged (§9.3).
    if WCAppearanceRepo.degraded(s.charid) then
        WCSessions.close(src, s.token)
        return fail('INTERNAL_ERROR')
    end
    local services, sections = Barber.offer(s.location, s.sex)
    if next(sections) == nil then
        WCSessions.close(src, s.token)
        return fail('BARBER_DISABLED')
    end
    local multiplier = Barber.multiplier(s.location)
    if not multiplier then
        WCDebug.warn('barber', 'location %s has an unknown pricing profile %s', tostring(s.location.id),
            tostring(s.location.pricingProfile))
        WCSessions.close(src, s.token)
        return fail('INVALID_PRICE')
    end
    for _, key in ipairs(SERVICE_ORDER) do
        if services[key].enabled and not basePrice(key) then
            WCDebug.warn('barber', 'service %s has an invalid price %s', key,
                tostring(type(servicesConfig()[key]) == 'table' and servicesConfig()[key].price or nil))
            WCSessions.close(src, s.token)
            return fail('INVALID_PRICE')
        end
    end
    local cap = baseCap()
    return WCResult.ok({
        token = s.token,
        appearance = WCUtil.copy(s.snapshot),
        growth = growthInfo(s.snapshot),
        services = pricedServices(s.location, services),
        -- the prices above already carry the multiplier; so does the cap the client applies to
        -- their sum (min(sum, cap) * m == min(sum * m, cap * m)), so its preview matches the charge
        multiplier = multiplier,
        visitCap = cap and WCUtil.round2(cap * multiplier) or nil,
        sections = sections,
        location = s.location.id,
        expiresIn = math.max(0, s.expires - os.time()),
    })
end

--- A submitted hair / facial hair style of an allowed section must be an item of the sex (or 0):
--  an unknown hash is refused instead of being turned into "bald". Returns true | false, code.
function Barber.validStyles(sex, submitted, sections)
    local hair = type(submitted) == 'table' and submitted.hair
    if hair == nil then return true end
    if type(hair) ~= 'table' then return false, 'INVALID_PAYLOAD' end
    local function valid(value, category)
        if value == nil or value == 0 then return true end
        return WCCatalog.resolve(sex, category, value) ~= nil
    end
    if sections.hair and not valid(hair.style, 'hair') then return false, 'INVALID_COMPONENT' end
    if sections.facialHair and sex == 'male' and not valid(hair.facial, 'mustache') then return false, 'INVALID_COMPONENT' end
    return true
end

--- Validate and price a submission against the saved appearance at a location.
--  Returns plan { merged, changed = {set}, sections = {list}, total, services } | nil, code.
function Barber.plan(saved, submitted, loc)
    if type(submitted) ~= 'table' then return nil, 'INVALID_PAYLOAD' end
    local _, sections = Barber.offer(loc, saved.sex)
    if next(sections) == nil then return nil, 'BARBER_DISABLED' end
    local valid, invalidCode = Barber.validStyles(saved.sex, submitted, sections)
    if not valid then return nil, invalidCode end
    local merged = AppearanceSchema.mergeSections(saved, submitted, sections)
    local changes = AppearanceSchema.changedSections(saved, merged)
    local changed = {}
    for section in pairs(changes) do
        if sections[section] then changed[section] = true end
    end
    if next(changed) == nil then return nil, 'NO_CHANGES' end
    local total, services = Barber.price(loc, changed)
    if not total then return nil, services end
    WCGrooming.cut(merged, saved)
    return { merged = merged, changed = changed, sections = sectionList(changed), total = total, services = services }
end

local function commitBarber(src, s, submitted)
    if s.kind ~= 'barber' then return fail('SESSION_NOT_FOUND') end
    if not WCServices.enabled('barbers') then return fail(WCServices.code('barbers')) end
    local loc = s.location and WCLocations.byId(s.location.id) or nil
    if not loc or not loc.enabled or not WCLocations.isOpen(loc) then return WCLocations.refusal(loc) end

    local saved, meta = WCAppearanceRepo.load(s.charid)
    if not saved then return fail(type(meta) == 'table' and meta.error or 'CHARACTER_NOT_FOUND') end
    -- Refused before anything is charged: the save would refuse the degraded character anyway.
    if type(meta) == 'table' and meta.degraded then return fail('INTERNAL_ERROR') end

    local plan, code = Barber.plan(saved, submitted, loc)
    if not plan then
        WCDebug.log('barber', 'commit by %s refused: %s', tostring(src), tostring(code))
        return fail(code)
    end
    -- The growth accumulated in memory since the last save: the kind that was cut drops it (it
    -- belongs to the old style), the other kind keeps it. Priced before the fold: growth is free.
    local folded = WCGroomingServer and WCGroomingServer.fold(s.charid, plan.merged, saved, meta) or 0

    local result = WCEconomy.withCharge(src, plan.total, 'barber', function()
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
    CreatorLogs.Emit('haircut', {
        playerSource = tonumber(src), charid = tostring(s.charid), price = result.data.charged,
        sections = plan.sections, services = plan.services, barber = loc.id,
    })
    CreatorLogs.Emit('appearance_changed', { playerSource = tonumber(src), charid = tostring(s.charid),
                                             sections = plan.sections, kind = 'barber' })
    TriggerEvent('w_creators:server:appearanceChanged', src, s.charid, 'barber')
    WCDebug.log('barber', '%s paid %.2f at %s for %s', tostring(src), result.data.charged, loc.id,
        table.concat(plan.sections, ','))
    return result
end

--- Commit a barber session. Result data { appearance, charged, sections }.
function Barber.commit(src, token, opId, submitted)
    if not WCSecurity.rate(src, 'barber:commit', 6, 10000) then return fail('RATE_LIMITED') end
    if type(token) ~= 'string' or #token > MAX_TOKEN or type(submitted) ~= 'table'
        or not WCSecurity.payload(submitted, MAX_PAYLOAD) then
        return fail('INVALID_PAYLOAD')
    end
    return WCSessions.commit(src, token, opId, function(s) return commitBarber(src, s, submitted) end, { kind = 'barber' })
end

w.callback.register('w_creators:barber:open', function(src, locationId)
    return Barber.open(src, locationId)
end)

w.callback.register('w_creators:barber:commit', function(src, token, opId, app)
    return Barber.commit(src, token, opId, app)
end)
