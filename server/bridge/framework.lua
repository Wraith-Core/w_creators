-- =====================================================================
--  server/bridge/framework.lua
--  A compatibility layer that unifies the access to the framework (VORP / RSG-Core / QBR).
--  The idea: we never touch the frameworks' character tables - we take the character's identity from them
--  only, and save the appearance in a table of our own. So the players' characters are not affected.
-- =====================================================================

-- An already running server may keep the previous manifest after restart.
-- This file is in both manifests, so initialize optional logging here as well
-- when the new server_script entry has not been discovered yet.
if type(CreatorLogs) ~= 'table' then
    local code = LoadResourceFile(GetCurrentResourceName(), 'server/bridge/logging.lua')
    local ok, err = false, 'server/bridge/logging.lua is missing'
    if code then
        local loader
        loader, err = load(code, '@w_creators/server/bridge/logging.lua', 't', _ENV)
        if loader then ok, err = pcall(loader) end
    end
    if not ok then
        print(('^3[w_creators] Optional logging bootstrap failed: %s. Character flow continues.^0'):format(tostring(err)))
    end
end

-- Logging stays optional even if an incomplete resource update omits its file.
if type(CreatorLogs) ~= 'table' or type(CreatorLogs.Emit) ~= 'function'
    or type(CreatorLogs.Register) ~= 'function' then
    CreatorLogs = {
        Emit = function() return false end,
        Register = function() return false end,
    }
end

-- =====================================================================
--  The w_logs (Sentinel) integration
--  It registers once, and the bridge re-registers automatically whenever the core restarts.
--  Money is only ever charged by the clothing store, the barber and cosmetic surgery (WCEconomy).
-- =====================================================================
local logTypesRegistered = false

local function registerLogTypes()
    if logTypesRegistered then return end
    logTypesRegistered = CreatorLogs.Register(function(logger)
        logger.RegisterScript({ label = 'Character Creator' })

        logger.RegisterLogType({
            key = 'character_created', label = 'Character Created',
            channel = 'character-create', severity = 'info', class = 'system',
            description = 'شخصية جديدة سُجّلت في النظام وحُفِظ مظهرها.',
            schema = {
                charid = { type = 'string', required = true },
                name = 'any', isMale = 'any', age = 'any',
                appearanceId = 'any', framework = 'any', multichar = 'any',
            },
        })

        logger.RegisterLogType({
            key = 'character_create_failed', label = 'Character Creation Failed',
            channel = 'character-create-failed', severity = 'warn', class = 'system',
            description = 'محاولة إنشاء رُفضت (هوية متعذّرة، حمولة مشوّهة، أو فشل إدراج).',
            schema = {
                charid = 'any', stage = { type = 'string', required = true },
                detail = 'any', framework = 'any',
            },
        })

        -- 2026-10-21: a name change bought in the server store (server/characters/rename.lua)
        logger.RegisterLogType({
            key = 'character_renamed', label = 'Character Renamed',
            channel = 'character-create', severity = 'info', class = 'system',
            description = 'لاعب غيّر اسم شخصيته بتذكرة تغيير اسم اشتراها من متجر السيرفر.',
            schema = {
                charid = 'any', from = 'any', to = { type = 'string', required = true },
            },
        })

        logger.RegisterLogType({
            key = 'character_selected', label = 'Character Selected',
            channel = 'character-select', severity = 'info', class = 'system',
            description = 'لاعب سجّل الدخول بشخصية موجودة (تُحمّل أموالها ووظيفتها).',
            schema = {
                charid = { type = 'string', required = true },
                appearanceFound = 'any', framework = 'any',
            },
        })

        -- Deletion is the one destructive operation in the resource: it deletes the character's row from
        -- the framework's own table (and with it the money and the property). It is recorded before and after.
        logger.RegisterLogType({
            key = 'character_deleted', label = 'Character DELETED',
            channel = 'character-delete', severity = 'warn', class = 'system',
            description = 'حُذفت شخصية نهائيًا من جدول الفريمورك ومعها مظهرها. عملية غير قابلة للتراجع.',
            schema = {
                charid = { type = 'string', required = true },
                charName = 'any', framework = 'any',
            },
        })

        -- An attempt to touch a character the player does not own = deliberate tampering. A legitimate client never fires it.
        logger.RegisterLogType({
            key = 'character_access_denied', label = 'Character Access Denied',
            channel = 'character-tamper', severity = 'error', class = 'system',
            description = 'لاعب حاول اختيار/حذف شخصية ليست له — حقن حدث يدوي.',
            schema = {
                charid = 'any', operation = { type = 'string', required = true },
            },
        })

        logger.RegisterLogType({
            key = 'clothes_bought', label = 'Clothes Bought',
            channel = 'clothing-store', severity = 'info', class = 'economy',
            description = 'شراء قطعة ملابس من متجر الملابس.',
            schema = {
                charid = { type = 'string', required = true },
                hash = 'any', category = 'any', price = 'any', colored = 'any',
            },
        })

        logger.RegisterLogType({
            key = 'appearance_loaded', label = 'Appearance Reloaded',
            channel = 'character-appearance', severity = 'debug', class = 'system',
            schema = { charid = 'any', found = { type = 'boolean', required = true } },
        })

        logger.RegisterLogType({
            key = 'routing_bucket_set', label = 'Routing Bucket Changed',
            channel = 'character-routing', severity = 'debug', class = 'system',
            schema = { scope = { type = 'string', required = true }, networkId = 'any' },
        })

        -- The development prop spawner (Config.Admin.spawnProp, off by default, ACE restricted).
        logger.RegisterLogType({
            key = 'prop_spawned', label = 'Prop Spawned (/spawnprop)',
            channel = 'admin-prop-spawn', severity = 'warn', class = 'admin.action',
            description = 'تنفيذ أمر /spawnprop — أداة تطوير مقيّدة بصلاحية ACE.',
            schema = {
                adminAction = { type = 'string', required = true },
                model = 'any', viaConsole = 'any',
            },
        })

        logger.RegisterLogType({
            key = 'appearance_changed', label = 'Appearance Changed',
            channel = 'character-appearance', severity = 'info', class = 'system',
            description = 'حُفظ تغيير على مظهر الشخصية (الأقسام المتغيّرة مذكورة).',
            schema = { charid = { type = 'string', required = true }, sections = 'any', kind = 'any' },
        })

        logger.RegisterLogType({
            key = 'surgery_completed', label = 'Cosmetic Surgery Completed',
            channel = 'character-surgery', severity = 'info', class = 'economy',
            description = 'اكتملت عملية تجميل ودُفع ثمنها.',
            schema = { charid = { type = 'string', required = true }, price = 'any', sections = 'any', clinic = 'any' },
        })

        logger.RegisterLogType({
            key = 'clothing_purchased', label = 'Clothing Purchased',
            channel = 'clothing-store', severity = 'info', class = 'economy',
            description = 'شراء قطع ملابس (وألوانها) من متجر الملابس.',
            schema = { charid = { type = 'string', required = true }, items = 'any', price = 'any', currency = 'any',
                       store = 'any' },
        })

        logger.RegisterLogType({
            key = 'clothing_sold', label = 'Clothing Sold Back',
            channel = 'clothing-store', severity = 'info', class = 'economy',
            description = 'بيع قطعة ملابس مشتراة إلى المتجر مقابل جزء من ثمنها.',
            schema = { charid = { type = 'string', required = true }, hash = 'any', category = 'any', price = 'any',
                       currency = 'any', paid = 'any', store = 'any' },
        })

        logger.RegisterLogType({
            key = 'clothing_item', label = 'Clothing Wrapped / Unwrapped',
            channel = 'clothing-items', severity = 'info', class = 'economy',
            description = 'قطعة ملابس لُفّت في الحقيبة أو فُتحت منها، أو بطاقة طقم أُعطيت.',
            schema = { charid = { type = 'string', required = true }, action = 'any', hash = 'any', category = 'any',
                       item = 'any' },
        })

        logger.RegisterLogType({
            key = 'outfit_saved', label = 'Outfit Saved',
            channel = 'character-wardrobe', severity = 'info', class = 'system',
            description = 'حُفظ طقم ملابس في الخزانة أو عُدّل.',
            schema = { charid = { type = 'string', required = true }, outfitId = 'any', name = 'any' },
        })

        logger.RegisterLogType({
            key = 'character_spawned', label = 'Character Spawned',
            channel = 'character-spawn', severity = 'info', class = 'system',
            description = 'ظهرت الشخصية في العالم (أول ظهور، دخول، تبديل، إحياء).',
            schema = { charid = 'any', kind = 'any', point = 'any' },
        })

        logger.RegisterLogType({
            key = 'security_violation', label = 'Security Violation',
            channel = 'character-tamper', severity = 'error', class = 'system',
            description = 'طلب رفضه الخادم لأنه لا يأتي من عميل سليم (حمولة، جلسة، ملكية، سعر...).',
            schema = { kind = { type = 'string', required = true }, detail = 'any' },
        })

        logger.RegisterLogType({
            key = 'haircut', label = 'Haircut',
            channel = 'barber', severity = 'info', class = 'economy',
            description = 'خدمة عند الحلاق (شعر، لحية، تفاصيل) ودُفع ثمنها.',
            schema = { charid = { type = 'string', required = true }, price = 'any', sections = 'any', barber = 'any' },
        })

        -- The services board (/servicesadmin): a staff member added, edited, moved or removed a place.
        logger.RegisterLogType({
            key = 'service_place_changed', label = 'Service Place Changed (/servicesadmin)',
            channel = 'admin-services', severity = 'warn', class = 'admin.action',
            description = 'تعديل أماكن الخدمات من لوحة الإدارة: متجر ملابس أو حلاق أو عيادة تجميل أو خزانة.',
            schema = {
                adminAction = { type = 'string', required = true },
                place = 'any', placeType = 'any', detail = 'any',
            },
        })
    end)
end

AddEventHandler('w_logs:server:ready', registerLogTypes)
AddEventHandler('w_creators:server:logsReady', registerLogTypes)
CreateThread(function()
    if GetResourceState('w_logs') == 'started' then registerLogTypes() end
end)

Bridge = {}

--- Detecting the running framework.
local function detectFramework()
    local ok, status = pcall(function() return exports.w_lib:CompatStatus() end)
    if ok and status and status.inboundAliases then return 'rsg' end
    local native = exports.w_lib:FwName()
    if native then return native == 'rsgcore' and 'rsg' or native end
    if Config.Framework and Config.Framework ~= 'auto' then
        return Config.Framework
    end
    if GetResourceState('vorp_core') == 'started' then return 'vorp' end
    if GetResourceState('rsg-core') == 'started' then return 'rsg' end
    if GetResourceState('qbr-core') == 'started' then return 'qbr' end
    return 'unknown'
end

Bridge.Name = detectFramework()

-- The frameworks' object getters (lazily loaded to avoid start-order problems)
local _rsg, _qbr, _vorp
local function rsgCore()
    if not _rsg then _rsg = w.framework:getCore() end
    return _rsg
end
local function qbrCore()
    if not _qbr then _qbr = w.framework:getCore() end
    return _qbr
end

--- The VORP core object: through the modern GetCore() with the getCore event as a fallback.
local function vorpCore()
    if _vorp then return _vorp end
    local ok, core = pcall(function() return w.framework:getCore() end)
    if ok and core then _vorp = core end
    return _vorp
end

if Bridge.Name == 'vorp' then
    -- A fallback for the versions that do not provide GetCore as an export
    TriggerEvent("getCore", function(core)
        if core then _vorp = core end
    end)
end

--- The VORP user object.
local function vorpUser(source)
    local core = vorpCore()
    if not core or not core.getUser then return nil end
    local ok, user = pcall(function() return core.getUser(source) end)
    if ok then return user end
    return nil
end

--- Getting the player object according to the framework (rsg / qbr: the citizenid-based cores).
local function getFrameworkPlayer(source)
    if Bridge.Name == 'rsg' then
        return rsgCore().Functions.GetPlayer(source)
    elseif Bridge.Name == 'qbr' then
        return qbrCore().Functions.GetPlayer(source)
    end
    return nil
end

--- The current character's unique identity (it supports multicharacter automatically).
--  It returns a fixed string per character, or nil if it cannot be determined.
function Bridge.GetCharId(source)
    if Bridge.Name == 'vorp' then
        local user = vorpUser(source)
        if not user then return nil end
        local char = user.getUsedCharacter
        if not char or char.charIdentifier == nil then return nil end
        return 'vorp:' .. tostring(char.charIdentifier)
    else
        local Player = getFrameworkPlayer(source)
        if not Player or not Player.PlayerData then return nil end
        return Player.PlayerData.citizenid
    end
end

--- Notifying the player through w_lib, in the PLAYER's language.
--  `message` is a dictionary key (an Arabic source text): w.notify(playerId, data) fires
--  __w_notify_<resource> at the client, which runs the resource's locale() over the
--  description before showing it.
function Bridge.Notify(source, message, notifyType)
    w.notify(source, {
        type = notifyType or 'inform',
        description = message
    })
end

--- Setting the hunger/thirst (a best effort; safely ignored if the framework does not support it).
function Bridge.SetSurvival(source)
    if not Config.Characters.setSurvivalMetadata then return end
    if Bridge.Name == 'vorp' then return end -- VORP runs the metabolism with its own system
    local Player = getFrameworkPlayer(source)
    if Player and Player.Functions and Player.Functions.SetMetaData then
        pcall(function()
            Player.Functions.SetMetaData('hunger', 100)
            Player.Functions.SetMetaData('thirst', 100)
        end)
    end
end

--- The current character's last saved position, or nil if there is none.
--  It returns { x, y, z, heading } - not a vector3, because the heading is part of the position.
--
--  VORP saves the position in characters.coords as a JSON string on SaveUser
--  (vorp_core/server/class/user.lua:309-322), that is on disconnect and on the periodic
--  save. We only read it and do not write it - the saving stays the core's responsibility.
--  The first source is the core object (newer and with no query), and the fallback is the database
--  directly in case the character is not loaded yet.
function Bridge.GetLastPosition(source)
    local raw

    if Bridge.Name == 'vorp' then
        local user = vorpUser(source)
        if user then
            local char = user.getUsedCharacter
            if char and char.coords then raw = char.coords end
        end

        if not raw then
            local charid = Bridge.GetCharId(source)
            local id = charid and tonumber((tostring(charid):gsub('^vorp:', '')))
            if id then
                local ok, rows = pcall(w.database.query.await,
                    ('SELECT coords FROM %s WHERE charidentifier = ?'):format(Config.Characters.tables.vorp),
                    { id })
                if ok and rows and rows[1] then raw = rows[1].coords end
            end
        end
    else
        local Player = getFrameworkPlayer(source)
        if Player and Player.PlayerData then raw = Player.PlayerData.position end
    end

    if raw == nil then return nil end

    -- It may arrive as a ready table (rsg / qbr) or as a JSON string (vorp)
    if type(raw) == 'string' then
        if raw == '' then return nil end
        local ok, decoded = pcall(json.decode, raw)
        if not ok then return nil end
        raw = decoded
    end
    if type(raw) ~= 'table' then return nil end

    local x, y, z = tonumber(raw.x), tonumber(raw.y), tonumber(raw.z)
    if not x or not y or not z then return nil end
    -- An absolute zero = a row that never had a position saved in it, not a real location
    if x == 0.0 and y == 0.0 and z == 0.0 then return nil end

    return { x = x, y = y, z = z, heading = tonumber(raw.heading) or tonumber(raw.w) or 0.0 }
end

-- =====================================================================
--  The multicharacter functions
--  Set against the sources: vorp_core / vorp_character, rsg-multicharacter and
--  qbr-multicharacter. If your version's signatures differ, the edit is confined
--  to this file alone.
-- =====================================================================

--- The player's account identifier (used to list his characters).
--  ! VORP: the user object exposes getIdentifier() as a function and has no `identifier` field
--  at all (vorp_core/server/class/user.lua:129). Checking `user.identifier` used to
--  give nil always so it fell back to the Cfx license identifier - while VORP stores the Steam
--  identifier in characters.identifier (loadcharacter.lua:9). The result: every query
--  searched with a wrong identifier so it found no row - no characters listed, and the save failed after the creation.
function Bridge.GetLicense(source)
    if Bridge.Name == 'vorp' then
        local user = vorpUser(source)
        if user and type(user.getIdentifier) == 'function' then
            local ok, id = pcall(user.getIdentifier)
            if ok and id and id ~= '' then return id end
        end
        -- A fallback: the same thing vorp_core itself uses on connection
        return GetPlayerIdentifierByType(source, 'steam')
    end
    return GetPlayerIdentifierByType(source, 'license') or GetPlayerIdentifier(source, 0)
end

-- A character logged out (switch, re-selection, a creation mid-switch) is saved on the server
-- first, and the write is confirmed before the next Login reads the players row: the cores'
-- Logout never saves (w_core asks the client for it and waits 200 ms), so an unsaved logout rolled
-- the character back to its last periodic save (job / gang / metadata, and on stock rsg-core the
-- money only Player.Save writes).
Bridge.SAVE_CONFIRM_MS = 3000

--- A value as it reads back from JSON (the columns are JSON text).
local function jsonShape(v)
    if v == nil then return nil end
    local enc = WCUtil.encode(v)
    if not enc then return nil end
    local ok, dec = pcall(json.decode, enc)
    return ok and dec or nil
end

local function sameValue(a, b)
    if type(a) == 'number' and type(b) == 'number' then
        return math.abs(a - b) <= 1e-6 * math.max(1, math.abs(a), math.abs(b))
    end
    if type(a) ~= 'table' or type(b) ~= 'table' then return a == b end
    for k, v in pairs(a) do if not sameValue(v, b[k]) then return false end end
    for k in pairs(b) do if a[k] == nil then return false end end
    return true
end

--- Save the logged-in rsg / qbr character and wait until the players row holds what was saved.
--  true | false, reason. A player with no framework character has nothing to save (true).
local function saveLoggedIn(source, Player)
    local data = type(Player) == 'table' and Player.PlayerData or nil
    local citizenid = type(data) == 'table' and data.citizenid or nil
    local save = type(Player) == 'table' and type(Player.Functions) == 'table' and Player.Functions.Save or nil
    if not citizenid or type(save) ~= 'function' then return false, 'the core offers no save' end
    -- w_core keeps money in the central ledger and never writes the players.money projection.
    local fields = { 'job', 'gang', 'metadata' }
    if GetResourceState('w_core') ~= 'started' then fields[#fields + 1] = 'money' end
    local expected = {}
    -- nil / JSON null reads back as {} (WCUtil.decode)
    for _, f in ipairs(fields) do expected[f] = jsonShape(data[f]) or {} end
    local saved, err = pcall(save)
    if not saved then return false, tostring(err) end
    local tableName = Bridge.Name == 'rsg' and Config.Characters.tables.rsg or Config.Characters.tables.qbr
    local sql = ('SELECT %s FROM %s WHERE citizenid = ? LIMIT 1'):format(table.concat(fields, ', '), tableName)
    local deadline = GetGameTimer() + Bridge.SAVE_CONFIRM_MS
    repeat
        local ok, rows = pcall(w.database.query.await, sql, { citizenid })
        local row = ok and type(rows) == 'table' and rows[1] or nil
        if type(row) == 'table' then
            local same = true
            for _, f in ipairs(fields) do
                local stored = row[f]
                if type(stored) == 'string' then stored = WCUtil.decode(stored) end
                if not sameValue(expected[f], stored) then same = false break end
            end
            if same then return true end
        end
        Wait(100)
    until GetGameTimer() >= deadline
    return false, 'the save was not confirmed in time'
end

--- Logging in on the citizenid-based cores (rsg / qbr).
--  citizenid = false with newData to create a new character (the framework generates the citizenid).
--  A character already logged in on the source is saved (and the write confirmed) first; a save
--  that cannot be confirmed refuses the login (false) and the character stays logged in.
local function coreLogin(source, citizenid, newData)
    if Bridge.Name ~= 'rsg' and Bridge.Name ~= 'qbr' then return false end
    if Bridge.Name == 'qbr' and GetResourceState('qbr-core') ~= 'started' then return false end
    local found, Player = pcall(getFrameworkPlayer, source)
    Player = found and Player or nil
    if Player then
        local saved, why = saveLoggedIn(source, Player)
        if not saved then
            WCDebug.warn('bridge', 'player %s: the logged-in character was not saved (%s): login refused',
                tostring(source), tostring(why))
            return false
        end
    end
    if Bridge.Name == 'rsg' then
        -- A re-selection on a source that is still logged in: log the previous character out
        -- first so OnPlayerUnload reaches the bag, the HUD and every job resource.
        local core = rsgCore()
        if Player then
            core.Player.Logout(source)
            Wait(250)
        end
        return core.Player.Login(source, citizenid, newData)
    end
    return exports.w_lib:FwNativeCoreCall('Login', source, citizenid, newData)
end

--- Deleting a character on the citizenid-based cores (rsg / qbr). Returns true when the core
--  accepted the request (upstream cores delete asynchronously and answer nothing; the caller
--  confirms the row is gone). An explicit false is a refusal: w_core's DeleteCharacter answers
--  false when the economy is not ready, the bank refuses (w_centralbank CanDeleteCharacter: an
--  open loan) or its transaction failed.
--- Returns accepted, reason. w_core answers `false, reason` ('economy_not_ready' | 'funds' |
--- 'loan' | 'assets' | 'database'); the upstream cores answer nothing, which is accepted.
local function coreDelete(source, citizenid)
    local called, answer, reason
    if Bridge.Name == 'rsg' then
        called, answer, reason = pcall(function() return rsgCore().Player.DeleteCharacter(source, citizenid) end)
    elseif Bridge.Name == 'qbr' then
        if GetResourceState('qbr-core') ~= 'started' then return false end
        called, answer, reason = pcall(function() return exports.w_lib:FwNativeCoreCall('DeleteCharacter', source, citizenid) end)
    else
        return false
    end
    if not called then
        WCDebug.warn('bridge', 'deleting %s: the core failed: %s', tostring(citizenid), tostring(answer))
        return false
    end
    if answer == false then return false, reason end
    return true
end

--- An approximate date of birth from the age (in YYYY-MM-DD form).
local function birthdateFromAge(age)
    local years = tonumber(age) or 20
    local year = tonumber(os.date('%Y')) - years
    return ('%04d-01-01'):format(year)
end

--- The date of birth to store: the validated identity dob (YYYY-MM-DD) when present, otherwise
--  derived from the age (the pre-v3 callers only sent an age).
local function birthdateOf(data)
    local dob = type(data.dob) == 'string' and data.dob:match('^(%d%d%d%d%-%d%d%-%d%d)$') or nil
    return dob or birthdateFromAge(data.age)
end

--- The age to store (VORP keeps an age column, not a date): the identity age, else computed from
--  the dob against the current year, else 20.
local function ageOf(data)
    local age = tonumber(data.age)
    if age then return math.floor(age) end
    local y, m, d = tostring(data.dob or ''):match('^(%d%d%d%d)%-(%d%d)%-(%d%d)$')
    if y then
        local now = os.date('*t')
        age = now.year - tonumber(y)
        if now.month < tonumber(m) or (now.month == tonumber(m) and now.day < tonumber(d)) then age = age - 1 end
        return age
    end
    return 20
end

--- The job label for the selection card (rsg / qbr): the players table keeps the job as a JSON
--  column ({ name, label, label_ar, grade... }, written by w_core's SetJob). It is decoded here the way
--  charinfo is, and the label is picked in the player's language: w_core's Shared.JobLabel when the
--  core is up, else label_ar / label by the w_lib locale key. Rows saved before label_ar existed get
--  it from the core's job catalogue (Shared.Jobs[name]).
local function storedJobLabel(source, raw)
    if type(raw) ~= 'string' or raw == '' then return nil end
    local ok, job = pcall(json.decode, raw)
    if not ok or type(job) ~= 'table' then return nil end

    local shared
    if Bridge.Name == 'rsg' then
        local okc, core = pcall(rsgCore)
        if okc and type(core) == 'table' then shared = core.Shared end
    end

    -- a row that lacks label_ar (or the label itself): completed from the catalogue
    local def = shared and type(shared.Jobs) == 'table' and job.name and shared.Jobs[job.name] or nil
    if type(def) == 'table' then
        if job.label == nil or job.label == '' then job.label = def.label end
        if job.label_ar == nil or job.label_ar == '' then job.label_ar = def.label_ar end
    end

    if shared and type(shared.JobLabel) == 'function' then
        local okl, label = pcall(shared.JobLabel, job, source)
        if okl and type(label) == 'string' and label ~= '' then return label end
    end

    local okk, key = pcall(function() return exports.w_lib:getPlayerLocaleKey(source) end)
    local label = (okk and key == 'ar') and job.label_ar or nil
    if type(label) ~= 'string' or label == '' then label = job.label end
    if type(label) ~= 'string' or label == '' then label = job.name end
    return (type(label) == 'string' and label ~= '') and label or nil
end

-- rsg / qbr balances of a listed character: { cash, bank, gold } (a field is nil when unknown).
--  * the central ledger (w_centralbank, ready): it owns the balances behind w_core — players.money
--    is only a projection there (written on the row's creation, never updated), so it is not read;
--  * w_core without a ready ledger: unknown (nil), never the stale column;
--  * stock rsg-core / qbr-core: players.money (JSON; gold is the 'gold' or 'bloodmoney' type).
local function ledgerReady()
    if GetResourceState('w_centralbank') ~= 'started' then return false end
    local ok, ready = pcall(function() return exports.w_centralbank:IsReady() end)
    return ok and ready == true
end

local function ledgerBalance(citizenid, kind)
    local ok, balance = pcall(function()
        return exports.w_centralbank:GetBalance(('player:%s:%s'):format(citizenid, kind))
    end)
    balance = ok and tonumber(balance) or nil
    return WCUtil.isFinite(balance) and balance or nil
end

local function columnBalance(money, ...)
    for _, kind in ipairs({ ... }) do
        local v = tonumber(money[kind])
        if WCUtil.isFinite(v) then return v end
    end
    return nil
end

local function coreBalances(citizenid, moneyColumn)
    if ledgerReady() then
        return { cash = ledgerBalance(citizenid, 'cash'), bank = ledgerBalance(citizenid, 'bank'),
                 gold = ledgerBalance(citizenid, 'gold') }
    end
    if GetResourceState('w_core') == 'started' then return {} end
    local money = type(moneyColumn) == 'string' and WCUtil.decode(moneyColumn)
        or (type(moneyColumn) == 'table' and moneyColumn) or {}
    return { cash = columnBalance(money, 'cash'), bank = columnBalance(money, 'bank'),
             gold = columnBalance(money, 'gold', 'bloodmoney') }
end
Bridge.CoreBalances = coreBalances

--- Listing the player's characters. It returns an array: { {charid=, name=, ...}, ... }
function Bridge.GetCharacters(source)
    local license = Bridge.GetLicense(source)
    if not license then return {} end

    if Bridge.Name == 'vorp' then
        local rows = w.database.query.await(
            ('SELECT charidentifier, firstname, lastname, money, gold, job, joblabel FROM %s WHERE identifier = ?')
                :format(Config.Characters.tables.vorp),
            { license }) or {}

        -- The bank balances: the vorp_banking table is separate and a player may hold an account in more
        -- than one bank, so we total them per character. Protected with a pcall: the bank is an optional resource
        -- and its absence must not bring the character listing down.
        local bank = {}
        local ok, bankRows = pcall(w.database.query.await,
            'SELECT charidentifier, SUM(money) AS money, SUM(gold) AS gold FROM bank_users WHERE identifier = ? GROUP BY charidentifier',
            { license })
        if ok and bankRows then
            for _, r in ipairs(bankRows) do
                bank[tostring(r.charidentifier)] = { money = r.money or 0, gold = r.gold or 0 }
            end
        end

        local list = {}
        for _, r in ipairs(rows) do
            local acc = bank[tostring(r.charidentifier)] or {}
            list[#list + 1] = {
                charid = 'vorp:' .. tostring(r.charidentifier),
                raw = r.charidentifier,
                name = ((r.firstname or '') .. ' ' .. (r.lastname or '')):gsub('^%s+', ''),
                cash = tonumber(r.money) or 0,
                gold = tonumber(r.gold) or 0,
                bank = tonumber(acc.money) or 0,
                bankGold = tonumber(acc.gold) or 0,
                job = (r.joblabel ~= nil and r.joblabel ~= '') and r.joblabel or r.job,
            }
        end
        return list
    else
        local table_ = Bridge.Name == 'rsg' and Config.Characters.tables.rsg or Config.Characters.tables.qbr
        local ok, rows = pcall(w.database.query.await,
            ('SELECT citizenid, charinfo, job, money FROM %s WHERE license = ?'):format(table_),
            { license })
        if not ok or type(rows) ~= 'table' then
            -- nil, never {}: a failed listing must not read as 'the player owns nothing' (a
            -- deletion confirms the row is gone through NOT_CHARACTER_OWNER; §9.2).
            WCDebug.warn('bridge', 'Bridge.GetCharacters query failed: %s', tostring(rows))
            return nil
        end
        local list = {}
        for _, r in ipairs(rows) do
            local name = r.citizenid
            if r.charinfo then
                local okInfo, info = pcall(json.decode, r.charinfo)
                if okInfo and info and info.firstname then
                    name = (info.firstname or '') .. ' ' .. (info.lastname or '')
                end
            end
            local balances = coreBalances(tostring(r.citizenid), r.money)
            list[#list + 1] = { charid = r.citizenid, raw = r.citizenid, name = name, job = storedJobLabel(source, r.job),
                                cash = balances.cash, bank = balances.bank, gold = balances.gold }
        end
        return list
    end
end

--- The ceiling on each half of the name (in characters, not bytes).
local MAX_NAME_LEN = 25

--- Sanitising a name that came from the client.
--  The interface's field limits it to 25 characters, but the event can be injected so it is not relied on.
--  The trim is by characters and not by bytes: an Arabic letter is two bytes in UTF-8, and a blind
--  trim splits it so a dangling byte is stored and corrupts the text when it is read.
local function sanitizeName(value, fallback)
    if type(value) ~= 'string' then return fallback end

    local v = value:match('^%s*(.-)%s*$')
    if v == '' then return fallback end

    local len = utf8 and utf8.len(v)
    if len and len > MAX_NAME_LEN then
        local cut = utf8.offset(v, MAX_NAME_LEN + 1)
        if cut then v = v:sub(1, cut - 1) end
    elseif not len and #v > MAX_NAME_LEN * 4 then
        -- A text that is not valid UTF-8: we trim by bytes with a generous limit
        v = v:sub(1, MAX_NAME_LEN * 4)
    end

    return v
end

--- The sanitiser is available to the whole resource: every name written into the database goes through it,
--  not the framework's name alone.
Bridge.SanitizeName = sanitizeName

--- The full display name, built from the two sanitised halves and not from the client's raw text.
function Bridge.DisplayName(data)
    local first = sanitizeName(data.firstname, nil)
    local last  = sanitizeName(data.lastname, nil)
    if first and last then return first .. ' ' .. last end
    if first then return first end
    return sanitizeName(data.name, 'Character')
end

--- The VORP character ids of an account as a set ({ [id] = true }), or nil when the query failed.
local function vorpCharacterIds(license)
    local ok, rows = pcall(w.database.query.await,
        ('SELECT charidentifier FROM %s WHERE identifier = ?'):format(Config.Characters.tables.vorp), { license })
    if not ok or type(rows) ~= 'table' then return nil end
    local ids = {}
    for _, r in ipairs(rows) do
        local id = tonumber(r.charidentifier)
        if id then ids[id] = true end
    end
    return ids
end

--- Registering a new character officially in the framework. It returns the charid on success or nil.
--  data = { firstname, lastname, name, isMale, dob?, age? } — dob (YYYY-MM-DD, validated by
--  WCIdentity) is the rsg/qbr charinfo.birthdate; VORP stores the age (from data.age or the dob).
--  firstname/lastname are the source: VORP and every framework here store them in two
--  separate columns. name stays for display only.
function Bridge.RegisterCharacter(source, data)
    local first = sanitizeName(data.firstname, nil)
    local last  = sanitizeName(data.lastname, nil)

    -- A fallback for the calls that still send a single name (the old paths)
    if not first then
        local f, l = tostring(data.name or ''):match('^(%S+)%s*(.*)$')
        first = sanitizeName(f, 'Character')
        last = last or sanitizeName(l, nil)
    end

    -- VORP does not accept an empty surname in its screens, so we keep vorp_character's fallback
    if not last then last = '.' end

    local gender = data.isMale and 'm' or 'f'

    if Bridge.Name == 'vorp' then
        -- VORP: addCharacter takes one data table (as in vorp_character).
        local user = vorpUser(source)
        if not user or not user.addCharacter then return nil end
        -- SaveNewCharacterInDb is asynchronous and answers nothing: the new row is found by its id.
        -- The player's existing ids are read first, so only an id that was not there before counts
        -- (the newest existing row is never taken for the new one on a slow database).
        local license = Bridge.GetLicense(source)
        local existing = vorpCharacterIds(license)
        if not existing then
            pcall(CreatorLogs.Emit, 'character_create_failed', {
                playerSource = source, stage = 'vorp_existing_ids', framework = Bridge.Name,
                reason = 'تعذّرت قراءة شخصيات اللاعب قبل الإنشاء',
            })
            return nil
        end
        local added, addErr = pcall(function()
            user.addCharacter({
                firstname = first,
                lastname = last,
                charDescription = 'New Character',
                nickname = first,
                age = ageOf(data),
                gender = data.isMale and 'm' or 'f',
                skin = '{}',
                comps = '{}',
            })
        end)
        if not added then
            pcall(CreatorLogs.Emit, 'character_create_failed', {
                playerSource = source, stage = 'vorp_addcharacter_error', framework = Bridge.Name,
                reason = tostring(addErr),
            })
            return nil
        end
        local newId
        for _ = 1, 40 do -- up to 4 seconds
            Wait(100)
            for id in pairs(vorpCharacterIds(license) or {}) do
                if not existing[id] and (newId == nil or id > newId) then newId = id end
            end
            if newId then break end
        end
        if newId then
            -- Activating the new character straight away (loading the money/job)
            pcall(function() user.setUsedCharacter(newId) end)
            return 'vorp:' .. tostring(newId)
        end
        CreatorLogs.Emit('character_create_failed', {
            playerSource = source,
            stage = 'vorp_addcharacter_no_row',
            framework = Bridge.Name,
            reason = 'addCharacter لم يُنتج صفًّا خلال مهلة الانتظار',
        })
        return nil
    else
        -- rsg / qbr: a Login with citizenid=false creates the character
        -- and generates the citizenid internally (as in rsg-multicharacter / qbr-multicharacter).
        local listed = Bridge.GetCharacters(source)
        if type(listed) ~= 'table' then return nil end
        local cid = #listed + 1
        local newData = {
            cid = cid,
            charinfo = {
                firstname = first,
                lastname = last,
                birthdate = birthdateOf(data),
                gender = data.isMale and 0 or 1,
                nationality = 'USA',
            },
        }
        local ok = coreLogin(source, false, newData)
        if not ok then
            CreatorLogs.Emit('character_create_failed', {
                playerSource = source,
                stage = 'core_login_failed',
                framework = Bridge.Name,
                reason = 'Login(source, false, newData) أرجع false',
            })
            return nil
        end
        Wait(100)
        local Player = getFrameworkPlayer(source)
        if Player and Player.PlayerData then
            return Player.PlayerData.citizenid
        end
        return nil
    end
end

--- Logging in with an existing character (it loads the money/job/inventory).
function Bridge.LoginCharacter(source, charid)
    if Bridge.Name == 'vorp' then
        local raw = tonumber((charid:gsub('^vorp:', '')))
        local user = vorpUser(source)
        if user and raw then
            -- setUsedCharacter loads the character (money/job) and fires vorp:SelectedCharacter
            pcall(function() user.setUsedCharacter(raw) end)
            return true
        end
        return false
    else
        -- Logging in with an existing character (the citizenid alone, with no newData)
        return coreLogin(source, charid)
    end
end

--- Deleting the framework character only (the character_deleted log is emitted first, while the
--  name can still be read). Returns true when the framework accepted the deletion, false when it
--  refused or failed. rsg / qbr delete asynchronously: true there means the core accepted the
--  request, and the caller confirms that the row is gone before touching anything else.
function Bridge.DeleteFrameworkCharacter(source, charid)
    charid = tostring(charid)
    -- It is recorded before the deletion: after it the character's name is unrecoverable. The
    -- logger is optional and never blocks the deletion.
    local deletedName
    local listed, list = pcall(Bridge.GetCharacters, source)
    for _, c in ipairs(listed and type(list) == 'table' and list or {}) do
        if c.charid == charid then deletedName = c.name break end
    end
    pcall(CreatorLogs.Emit, 'character_deleted', {
        playerSource = source,
        charid = charid,
        charName = deletedName,
        framework = Bridge.Name,
        transactionId = ('wcdel-%s-%s'):format(charid, os.time()),
        reason = 'حذف من شاشة اختيار الشخصيات',
    })

    if Bridge.Name == 'vorp' then
        local raw = tonumber((charid:gsub('^vorp:', '')))
        return raw ~= nil and (pcall(w.database.query.await,
            ('DELETE FROM %s WHERE charidentifier = ?'):format(Config.Characters.tables.vorp), { raw })) == true
    end
    local accepted, reason = coreDelete(source, charid)
    return accepted == true, reason
end

--- Deleting a character: the framework row, then the appearance, owned clothes and outfits (one
--  transaction in WCAppearanceRepo.delete). The w_creators data is touched only when the framework
--  accepted the deletion. Returns true when both succeeded, otherwise false, stage ('framework' |
--  'appearance'). rsg / qbr delete asynchronously: characters:delete does not use this helper (it
--  deletes the w_creators data only once the framework row is really gone).
function Bridge.DeleteCharacter(source, charid)
    charid = tostring(charid)
    if not Bridge.DeleteFrameworkCharacter(source, charid) then return false, 'framework' end

    local appearanceOk
    if WCAppearanceRepo and WCAppearanceRepo.delete then
        local called, done = pcall(WCAppearanceRepo.delete, charid)
        appearanceOk = called and done == true
    else
        appearanceOk = (pcall(w.database.query.await, 'DELETE FROM characters_appearence WHERE charid = ?', { charid }))
    end
    if not appearanceOk then return false, 'appearance' end
    return true
end

CreateThread(function()
    if Bridge.Name == 'unknown' then
        print('^1[w_creators] no supported framework was detected (vorp/rsg/qbr). Set Config.Framework by hand.^0')
    else
        print(('^2[w_creators] Framework detected: %s^0'):format(Bridge.Name))
    end
end)
