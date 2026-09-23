-- =====================================================================
--  server/dev/tools.lua  —  restricted development tools (ARCHITECTURE.md §1 A22, §15)
--  Nothing here is registered in production:
--    * Config.Admin.devTools = true registers
--        wc_catalog_validate   console, or a player holding the Config.Admin.devAce ACE: validates the
--                              clothing taxonomy against the w_lib catalogue, prices, pricing/store
--                              profiles, tint palettes, locations, barber/surgery config, spawn
--                              points, starting outfits and grooming stages; prints the report to
--                              the server console.
--    * Config.Admin.spawnProp = true registers
--        spawnprop <model>     the pre-v3 prop spawner: an ACE-restricted command (command.spawnprop)
--                              that sends W:ADMIN:SpawnObject to the caller's client (client dev tools).
--  The callback w_creators:dev:allowed(command) is always registered: it answers SERVICE_DISABLED
--  unless Config.Admin.devTools is on, and otherwise lets a player holding Config.Admin.devAce run
--  the client dev commands (wc_inspect, wc_apply, wc_remove, wc_restore; client/dev/tools.lua).
--  The console command wc_migrate_appearances (§6.2) is always available: it is registered by
--  server/appearance/repository.lua (console only, batches of 100) and is not duplicated here.
--
--  WCDevTools.validate() -> report { errors = {...}, warnings = {...}, checked = {...} } (tests use it).
-- =====================================================================

WCDevTools = {}
local Dev = WCDevTools

local SEXES = { 'male', 'female' }
local CAMERA_PRESETS = WCUtil.set({ 'fullBody', 'upperBody', 'lowerBody', 'head', 'face', 'eyes', 'hair',
                                    'facialHair', 'hands', 'feet', 'accessories' })
local BARBER_SERVICES = { hair = true, facialHair = true, details = true }
local SURGERY_ALLOW = { face = true, body = true, eyes = true, skin = true, hair = true, facialHair = true,
                        clothing = true }

local function finiteNonNegative(v)
    return type(v) == 'number' and WCUtil.isFinite(v) and v >= 0
end

local function listOf(v)
    if type(v) ~= 'table' then return {} end
    local out = {}
    for _, name in ipairs(v) do out[#out + 1] = name end
    return out
end

-- ---------------------------------------------------------------------
--  Checks
-- ---------------------------------------------------------------------

local function checkCatalogue(r)
    for _, sex in ipairs(SEXES) do
        if next(WCCatalog.forSex(sex)) == nil then r.error('catalogue: the w_lib component catalogue has no %s items', sex) end
    end
end

local function checkTaxonomy(r)
    local seen, taxonomy = {}, Config.Clothing and Config.Clothing.taxonomy
    if type(taxonomy) ~= 'table' then
        r.error('taxonomy: Config.Clothing.taxonomy is missing')
        return seen
    end
    local groupIds = {}
    for gi, group in ipairs(taxonomy) do
        local gid = type(group) == 'table' and group.id or nil
        if type(gid) ~= 'string' then r.error('taxonomy: group #%d has no id', gi)
        elseif groupIds[gid] then r.error('taxonomy: duplicate group id %s', gid) end
        if gid then groupIds[gid] = true end
        if type(group) == 'table' and group.camera ~= nil and not CAMERA_PRESETS[group.camera] then
            r.warn('taxonomy: group %s has an unknown camera preset %s', tostring(gid), tostring(group.camera))
        end
        for si, sub in ipairs(type(group) == 'table' and group.subs or {}) do
            local category = type(sub) == 'table' and (sub.category or sub.id) or nil
            if type(category) ~= 'string' then
                r.error('taxonomy: %s sub #%d has no category', tostring(gid), si)
            elseif seen[category] then
                r.error('taxonomy: category %s appears twice (%s and %s)', category, seen[category], tostring(gid))
            elseif WCCatalog.BODY_PARTS[category] then
                r.error('taxonomy: %s is a body part, not clothing', category)
            else
                seen[category] = tostring(gid)
                local counts = {}
                for _, sex in ipairs(SEXES) do
                    local cat = WCCatalog.forSex(sex)[category]
                    counts[sex] = cat and #cat.models or 0
                end
                if counts.male == 0 and counts.female == 0 then
                    r.warn('taxonomy: %s has no items in the catalogue for either sex (never shown)', category)
                end
                if sub.sex ~= nil and sub.sex ~= 'male' and sub.sex ~= 'female' then
                    r.error('taxonomy: %s has an invalid sex hint %s', category, tostring(sub.sex))
                elseif sub.sex and counts[sub.sex] == 0 then
                    r.warn('taxonomy: %s is limited to %s but the catalogue has no %s items', category, sub.sex, sub.sex)
                end
                if sub.camera ~= nil and not CAMERA_PRESETS[sub.camera] then
                    r.warn('taxonomy: %s has an unknown camera preset %s', category, tostring(sub.camera))
                end
            end
        end
    end
    for _, sex in ipairs(SEXES) do
        for _, category in ipairs(WCUtil.sortedKeys(WCCatalog.forSex(sex))) do
            if not WCCatalog.BODY_PARTS[category] and not seen[category] then
                r.warn('taxonomy: catalogue category %s (%s) is not in the taxonomy (unreachable in the editors)', category, sex)
            end
        end
    end
    r.checked.taxonomy = true
    return seen
end

local function checkPrices(r, taxonomy)
    local prices = Config.Clothing and Config.Clothing.prices
    if type(prices) ~= 'table' then
        r.error('prices: Config.Clothing.prices is missing')
        return
    end
    for _, category in ipairs(WCUtil.sortedKeys(prices)) do
        if not finiteNonNegative(prices[category]) then
            r.error('prices: %s has an invalid price %s', tostring(category), tostring(prices[category]))
        end
        if not taxonomy[category] then r.warn('prices: %s is priced but not in the taxonomy', tostring(category)) end
    end
    for _, category in ipairs(WCUtil.sortedKeys(taxonomy)) do
        if prices[category] == nil then r.warn('prices: %s has no price (not sold in stores)', category) end
    end
    for _, id in ipairs(WCUtil.sortedKeys(Config.Clothing.pricingProfiles or {})) do
        local profile = Config.Clothing.pricingProfiles[id]
        if type(profile) ~= 'table' or not finiteNonNegative(profile.multiplier) then
            r.error('pricing profile %s: invalid multiplier', tostring(id))
        end
    end
    if type((Config.Clothing.pricingProfiles or {}).standard) ~= 'table' then
        r.error('pricing profile standard is missing (the default of every location)')
    end
    for _, id in ipairs(WCUtil.sortedKeys(Config.Clothing.storeProfiles or {})) do
        local profile = Config.Clothing.storeProfiles[id]
        if type(profile) ~= 'table' then
            r.error('store profile %s: not a table', tostring(id))
        else
            local include = profile.include or '*'
            if include ~= '*' then
                for _, category in ipairs(listOf(include)) do
                    if not taxonomy[category] then r.warn('store profile %s: includes unknown category %s', id, tostring(category)) end
                end
            end
            for _, category in ipairs(listOf(profile.exclude)) do
                if not taxonomy[category] then r.warn('store profile %s: excludes unknown category %s', id, tostring(category)) end
            end
            for category, range in pairs(type(profile.models) == 'table' and profile.models or {}) do
                local lo, hi = type(range) == 'table' and tonumber(range.min), type(range) == 'table' and tonumber(range.max)
                if not taxonomy[category] then r.warn('store profile %s: model range for unknown category %s', id, tostring(category)) end
                if lo and hi and lo > hi then r.error('store profile %s: %s model range min > max', id, tostring(category)) end
            end
        end
    end
    r.checked.prices = true
end

local function checkTints(r, taxonomy)
    local tints = Config.Clothing and Config.Clothing.tints
    if type(tints) ~= 'table' then
        r.warn('tints: Config.Clothing.tints is missing (tints disabled)')
        return
    end
    if not finiteNonNegative(tints.price) then r.error('tints: invalid price %s', tostring(tints.price)) end
    local known = WCUtil.set((w.component and w.component.data and w.component.data.palettes) or {})
    if next(known) == nil then r.warn('tints: w_lib provides no palette list (w.component.data.palettes)') end
    local function checkList(where, list)
        for _, name in ipairs(listOf(list)) do
            if next(known) ~= nil and not known[name] then r.warn('tints: %s lists an unknown palette %s', where, tostring(name)) end
        end
    end
    checkList('default', tints.default)
    for _, category in ipairs(WCUtil.sortedKeys(tints.palettes or {})) do
        if not taxonomy[category] then r.warn('tints: palettes for unknown category %s', tostring(category)) end
        local list = tints.palettes[category]
        if list ~= false then checkList(tostring(category), list) end
    end
    r.checked.tints = true
end

local function checkLocations(r)
    local seen = {}
    for index, loc in ipairs(Config.Locations or {}) do
        local id = type(loc) == 'table' and loc.id or nil
        if type(id) ~= 'string' then r.error('locations: #%d has no id', index)
        elseif seen[id] then r.error('locations: duplicate id %s', id)
        elseif not WCLocations.byId(id) then r.error('locations: %s is invalid (unknown type or coordinates) and skipped', id) end
        if type(id) == 'string' then seen[id] = true end
    end
    local profiles = Config.Clothing and Config.Clothing.storeProfiles or {}
    local pricing = Config.Clothing and Config.Clothing.pricingProfiles or {}
    for _, loc in ipairs(WCLocations.all()) do
        if loc.pricingProfile ~= nil and type(pricing[loc.pricingProfile]) ~= 'table' then
            r.error('locations: %s uses an unknown pricing profile %s', loc.id, tostring(loc.pricingProfile))
        end
        if loc.type == 'clothing' and type(profiles[loc.storeProfile or 'general']) ~= 'table' then
            r.error('locations: %s uses an unknown store profile %s', loc.id, tostring(loc.storeProfile))
        end
        if loc.camera ~= nil and not CAMERA_PRESETS[loc.camera] then
            r.warn('locations: %s has an unknown camera preset %s', loc.id, tostring(loc.camera))
        end
        if loc.preview ~= nil and not WCUtil.xyz(loc.preview) then
            r.error('locations: %s has an invalid preview position', loc.id)
        end
        if loc.type == 'barber' and loc.allowedServices ~= nil then
            if type(loc.allowedServices) ~= 'table' then
                r.error('locations: %s allowedServices must be a table', loc.id)
            else
                for key in pairs(loc.allowedServices) do
                    if not BARBER_SERVICES[key] then r.warn('locations: %s allows an unknown barber service %s', loc.id, tostring(key)) end
                end
            end
        end
        if loc.type == 'surgery' and loc.price ~= nil and not finiteNonNegative(loc.price) then
            r.error('locations: %s has an invalid price %s', loc.id, tostring(loc.price))
        end
    end
    for _, t in ipairs({ 'clothing', 'barber', 'surgery', 'wardrobe' }) do
        if #WCLocations.byType(t) > 0 and #WCLocations.active(t) == 0 then
            r.warn('locations: no usable %s location (service or every location disabled)', t)
        end
    end
    r.checked.locations = true
end

local function checkServices(r)
    local barber = Config.Barber or {}
    for key in pairs(BARBER_SERVICES) do
        local svc = barber.services and barber.services[key]
        if type(svc) ~= 'table' then r.warn('barber: service %s is not configured', key)
        elseif not finiteNonNegative(svc.price) then r.error('barber: service %s has an invalid price', key) end
    end
    local cap = barber.prices and barber.prices.visitCap
    if cap ~= nil and not finiteNonNegative(cap) then r.error('barber: invalid prices.visitCap %s', tostring(cap)) end
    local surgery = Config.CosmeticSurgery or {}
    if not finiteNonNegative(surgery.price) then r.error('surgery: invalid price %s', tostring(surgery.price)) end
    local any = false
    for key, value in pairs(type(surgery.allow) == 'table' and surgery.allow or {}) do
        if not SURGERY_ALLOW[key] then r.warn('surgery: allow has an unknown section %s', tostring(key)) end
        if value == true then any = true end
    end
    if not any then r.warn('surgery: allow permits no section (every procedure is refused)') end
    r.checked.services = true
end

local function checkSpawn(r)
    local spawn = Config.Spawn or {}
    local b = spawn.bounds
    local function inside(x, y, z)
        if type(b) ~= 'table' then return true end
        local lo = { tonumber(b.minX), tonumber(b.minY), tonumber(b.minZ) }
        local hi = { tonumber(b.maxX), tonumber(b.maxY), tonumber(b.maxZ) }
        for i, v in ipairs({ x, y, z }) do
            if (lo[i] and v < lo[i]) or (hi[i] and v > hi[i]) then return false end
        end
        return true
    end
    local seen, enabled = {}, 0
    for index, pt in ipairs(spawn.points or {}) do
        local id = type(pt) == 'table' and pt.id or nil
        if type(id) ~= 'string' or id == '' then r.error('spawn: point #%d has no id', index)
        elseif id == '__last' then r.error('spawn: point id __last is reserved')
        elseif seen[id] then r.error('spawn: duplicate point id %s', id) end
        if type(id) == 'string' then seen[id] = true end
        local x, y, z = WCUtil.xyz(type(pt) == 'table' and pt.coords)
        if not x then
            r.error('spawn: point %s has invalid coordinates', tostring(id))
        elseif not inside(x, y, z) then
            r.warn('spawn: point %s is outside Config.Spawn.bounds', tostring(id))
        end
        if type(pt) == 'table' and pt.order ~= nil and not (type(pt.order) == 'number' and WCUtil.isFinite(pt.order)) then
            r.error('spawn: point %s has an invalid order', tostring(id))
        end
        if type(pt) == 'table' and pt.enabled ~= false and x then enabled = enabled + 1 end
    end
    if enabled == 0 then r.warn('spawn: no enabled spawn point (firstSpawn is the only destination)') end
    if not WCUtil.xyz(spawn.firstSpawn and spawn.firstSpawn.coords) then r.error('spawn: firstSpawn has invalid coordinates') end
    r.checked.spawn = true
end

local function checkOutfits(r)
    for _, sex in ipairs(SEXES) do
        local ids = {}
        for index, preset in ipairs((Config.StartingOutfits or {})[sex] or {}) do
            local id = type(preset) == 'table' and preset.id or nil
            if type(id) ~= 'string' then r.error('starting outfits: %s #%d has no id', sex, index)
            elseif ids[id] then r.error('starting outfits: duplicate %s id %s', sex, id) end
            if type(id) == 'string' then ids[id] = true end
            local equipped = {}
            for _, item in ipairs(type(preset) == 'table' and preset.items or {}) do
                local category = type(item) == 'table' and item.category or nil
                local hash = type(category) == 'string' and WCCatalog.offered(sex, category)
                    and WCCatalog.resolve(sex, category, { item.model, item.variant }) or nil
                if not hash then
                    r.warn('starting outfits: %s %s item %s %s/%s does not resolve (skipped at runtime)', sex,
                        tostring(id), tostring(category), tostring(item and item.model), tostring(item and item.variant))
                else
                    equipped[category] = hash
                end
            end
            local _, violations = WCRules.normalize(equipped)
            for _, v in ipairs(violations or {}) do
                r.warn('starting outfits: %s %s breaks a clothing rule (%s %s)', sex, tostring(id),
                    tostring(v.category), tostring(v.reason))
            end
        end
    end
    r.checked.outfits = true
end

local function checkGrooming(r)
    local grooming = Config.Grooming or {}
    for _, sex in ipairs(SEXES) do
        for _, kind in ipairs({ 'hair', 'beard' }) do
            local stages = grooming.stages and grooming.stages[sex] and grooming.stages[sex][kind]
            local cat = WCCatalog.forSex(sex)[kind == 'beard' and 'mustache' or 'hair']
            for _, prefix in ipairs(listOf(stages)) do
                local found = false
                for _, info in pairs(cat and cat.hashes or {}) do
                    if info.name:upper():sub(1, #prefix) == prefix then found = true break end
                end
                if not found then r.warn('grooming: %s %s stage %s matches no catalogue item', sex, kind, tostring(prefix)) end
            end
            if stages and not finiteNonNegative(grooming.minutesPerStage and grooming.minutesPerStage[kind]) then
                r.error('grooming: minutesPerStage.%s is invalid', kind)
            end
        end
    end
    r.checked.grooming = true
end

--- Run every check. Returns { errors = { text... }, warnings = { text... }, checked = { [name] = true } }.
function Dev.validate()
    local report = { errors = {}, warnings = {}, checked = {} }
    report.error = function(fmt, ...) report.errors[#report.errors + 1] = fmt:format(...) end
    report.warn = function(fmt, ...) report.warnings[#report.warnings + 1] = fmt:format(...) end
    checkCatalogue(report)
    local taxonomy = checkTaxonomy(report)
    checkPrices(report, taxonomy)
    checkTints(report, taxonomy)
    checkLocations(report)
    checkServices(report)
    checkSpawn(report)
    checkOutfits(report)
    checkGrooming(report)
    report.error, report.warn = nil, nil
    return report
end

local function allowed(src, ace)
    if src == 0 then return true end
    if type(ace) ~= 'string' or ace == '' then return false end
    local done, result = pcall(IsPlayerAceAllowed, src, ace)
    return done and result == true
end

--- Print a report to the server console.
function Dev.printReport(report)
    w.print.info('[w_creators] wc_catalog_validate: %d error(s), %d warning(s)', #report.errors, #report.warnings)
    for _, line in ipairs(report.errors) do w.print.error('  ERROR  %s', line) end
    for _, line in ipairs(report.warnings) do w.print.warn('  WARN   %s', line) end
end

-- ---------------------------------------------------------------------
--  Commands
-- ---------------------------------------------------------------------
if Config.Admin and Config.Admin.devTools == true then
    RegisterCommand('wc_catalog_validate', function(src)
        src = tonumber(src) or 0
        if not allowed(src, Config.Admin.devAce) then
            WCSecurity.violation(src, 'dev_tools', 'wc_catalog_validate')
            return
        end
        local report = Dev.validate()
        Dev.printReport(report)
        if src ~= 0 then Bridge.Notify(src, 'تقرير فحص الكتالوج في وحدة تحكم الخادم', 'inform') end
    end, false)
end

-- w_creators:dev:allowed(command) -> Result: may this player run a client dev command
-- (client/dev/tools.lua asks before each one)? SERVICE_DISABLED unless Config.Admin.devTools is on;
-- only the four client dev commands; the player must hold Config.Admin.devAce. A refusal of an
-- enabled tool is logged as a security violation.
Dev.CLIENT_COMMANDS = { wc_inspect = true, wc_apply = true, wc_remove = true, wc_restore = true }
Dev.DENIED = 'هذا الأمر مخصص للمطورين'

function Dev.clientAllowed(src, command)
    if not (Config.Admin and Config.Admin.devTools == true) then return WCResult.fail('SERVICE_DISABLED') end
    if not WCSecurity.rate(src, 'dev:allowed', 10, 10000) then return WCResult.fail('RATE_LIMITED') end
    if type(command) ~= 'string' or not Dev.CLIENT_COMMANDS[command] then
        WCSecurity.violation(src, 'dev_tools', { command = tostring(command) })
        return WCResult.fail('INVALID_PAYLOAD')
    end
    if src == 0 or not allowed(src, Config.Admin.devAce) then
        WCSecurity.violation(src, 'dev_tools', { command = command })
        local refused = WCResult.fail('SERVICE_DISABLED')
        refused.message = Dev.DENIED
        return refused
    end
    return WCResult.ok()
end

w.callback.register('w_creators:dev:allowed', function(src, command)
    return Dev.clientAllowed(tonumber(src) or 0, command)
end)

if Config.Admin and Config.Admin.spawnProp == true then
    -- Restricted: only holders of the command.spawnprop ACE (group.admin has 'command') may use it.
    RegisterCommand('spawnprop', function(src, args)
        src = tonumber(src) or 0
        local model = args and args[1]
        if src == 0 or type(model) ~= 'string' or model == '' or #model > 64 then return end
        TriggerClientEvent('W:ADMIN:SpawnObject', src, model)
        CreatorLogs.Emit('prop_spawned', {
            playerSource = src,
            adminAction = 'object-spawn',
            model = model,
            viaConsole = false,
            reason = 'spawnprop command (ACE restricted)',
        })
    end, true)
end
