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
            schema = { charid = { type = 'string', required = true }, items = 'any', price = 'any', store = 'any' },
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

--- Logging in on the citizenid-based cores (rsg / qbr).
--  citizenid = false with newData to create a new character (the framework generates the citizenid).
local function coreLogin(source, citizenid, newData)
    if Bridge.Name == 'rsg' then
        -- A re-selection on a source that is still logged in: log the previous character out
        -- first so OnPlayerUnload reaches the bag, the HUD and every job resource.
        local core = rsgCore()
        if core.Functions.GetPlayer(source) then
            core.Player.Logout(source)
            Wait(250)
        end
        return core.Player.Login(source, citizenid, newData)
    elseif Bridge.Name == 'qbr' then
        if GetResourceState('qbr-core') == 'started' then
            return exports.w_lib:FwNativeCoreCall('Login',source,citizenid,newData)
        end
    end
    return false
end

--- Deleting a character on the citizenid-based cores (rsg / qbr).
local function coreDelete(source, citizenid)
    if Bridge.Name == 'rsg' then
        pcall(function() rsgCore().Player.DeleteCharacter(source, citizenid) end)
    elseif Bridge.Name == 'qbr' then
        if GetResourceState('qbr-core') == 'started' then
            pcall(function() exports.w_lib:FwNativeCoreCall('DeleteCharacter',source,citizenid) end)
        end
    end
end

--- An approximate date of birth from the age (in YYYY-MM-DD form).
local function birthdateFromAge(age)
    local years = tonumber(age) or 20
    local year = tonumber(os.date('%Y')) - years
    return ('%04d-01-01'):format(year)
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
            ('SELECT citizenid, charinfo, job FROM %s WHERE license = ?'):format(table_),
            { license })
        if not ok or type(rows) ~= 'table' then
            print(('^1[w_creators] Bridge.GetCharacters query failed: %s^0'):format(tostring(rows)))
            return {}
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
            list[#list + 1] = { charid = r.citizenid, raw = r.citizenid, name = name, job = storedJobLabel(source, r.job) }
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

--- Registering a new character officially in the framework. It returns the charid on success or nil.
--  data = { firstname, lastname, name, isMale, age }
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
        pcall(function()
            user.addCharacter({
                firstname = first,
                lastname = last,
                charDescription = 'New Character',
                nickname = first,
                age = data.age or 20,
                gender = data.isMale and 'm' or 'f',
                skin = '{}',
                comps = '{}',
            })
        end)
        -- SaveNewCharacterInDb is asynchronous: we wait for the character to really appear rather than
        -- a fixed timeout that may run ahead of the save on a slow database.
        local license = Bridge.GetLicense(source)
        local row
        for _ = 1, 40 do -- up to 4 seconds
            Wait(100)
            local ok, res = pcall(w.database.query.await,
                ('SELECT charidentifier FROM %s WHERE identifier = ? ORDER BY charidentifier DESC LIMIT 1'):format(Config.Characters.tables.vorp),
                { license })
            if ok and res and res[1] then row = res break end
        end
        if row and row[1] then
            -- Activating the new character straight away (loading the money/job)
            pcall(function() user.setUsedCharacter(row[1].charidentifier) end)
            return 'vorp:' .. tostring(row[1].charidentifier)
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
        local cid = #Bridge.GetCharacters(source) + 1
        local newData = {
            cid = cid,
            charinfo = {
                firstname = first,
                lastname = last,
                birthdate = birthdateFromAge(data.age),
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

--- Deleting a character.
function Bridge.DeleteCharacter(source, charid)
    -- It is recorded before the deletion: after it the character's name is unrecoverable.
    local deletedName
    for _, c in ipairs(Bridge.GetCharacters(source)) do
        if c.charid == charid then deletedName = c.name break end
    end
    CreatorLogs.Emit('character_deleted', {
        playerSource = source,
        charid = tostring(charid),
        charName = deletedName,
        framework = Bridge.Name,
        transactionId = ('wcdel-%s-%s'):format(tostring(charid), os.time()),
        reason = 'حذف من شاشة اختيار الشخصيات',
    })
    if Bridge.Name == 'vorp' then
        local raw = tonumber((charid:gsub('^vorp:', '')))
        if raw then
            w.database.query.await(('DELETE FROM %s WHERE charidentifier = ?'):format(Config.Characters.tables.vorp), { raw })
        end
    else
        coreDelete(source, charid)
    end
    -- The appearance, the owned clothing and the outfits go in one transaction (WCAppearanceRepo).
    if WCAppearanceRepo and WCAppearanceRepo.delete then
        WCAppearanceRepo.delete(charid)
    else
        w.database.query.await('DELETE FROM characters_appearence WHERE charid = ?', { charid })
    end
end

CreateThread(function()
    if Bridge.Name == 'unknown' then
        print('^1[w_creators] no supported framework was detected (vorp/rsg/qbr). Set Config.Framework by hand.^0')
    else
        print(('^2[w_creators] Framework detected: %s^0'):format(Bridge.Name))
    end
end)
