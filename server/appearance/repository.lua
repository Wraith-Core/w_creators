-- =====================================================================
--  server/appearance/repository.lua  —  WCAppearanceRepo (ARCHITECTURE.md §6)
--  Persistence of the v3 appearance in characters_appearence.appearance (JSON) with
--  appearance_version = 3. The legacy columns (isMale / components / faceFeatures / overlays) are
--  rewritten on every save from AppearanceSchema.toLegacy(app) as a derived compatibility
--  projection; they are never read when appearance_version >= 3.
--
--  Lazy upgrade (§6.2): a row below v3 (or with a NULL/corrupt appearance) is converted with
--  AppearanceSchema.fromLegacy. When the conversion needed no essential defaults the v3 appearance
--  is written back together with 'legacy' ownership grants for the equipped clothing (INSERT
--  IGNORE) in one transaction. When defaults were needed nothing is written (data is never
--  silently replaced): the in-memory appearance uses the defaults and a warning is logged.
--
--  Degraded appearances: an appearance that needed essential defaults (legacy or stored v3) is
--  remembered as degraded; save() refuses to overwrite that character unless the caller passes
--  opts.replaceDegraded (an explicit repair), so no automatic writer persists the defaults.
--  Every read/write waits for the schema migrations (WCMigrations.waitReady) and needs the w_lib
--  catalogue: without it the appearance cannot be validated, so nothing is loaded or written.
--  Stored clothing is read and written as stored (AppearanceSchema.sanitize with rules = false).
-- =====================================================================

WCAppearanceRepo = { cache = {} }
local Repo = WCAppearanceRepo

local MIGRATION_WAIT_MS = 10000
local degraded = {} -- [charid] = { section... }: the loaded appearance needed essential defaults
local PERSISTED = { rules = false }

local SELECT_LATEST = 'SELECT * FROM characters_appearence WHERE charid = ? ORDER BY id DESC LIMIT 1'
local GRANT_LEGACY = "INSERT IGNORE INTO w_creators_clothes (charid, hash, category, source, acquired_at) VALUES (?, ?, ?, 'legacy', CURRENT_TIMESTAMP)"

local function key(charid) return tostring(charid) end

--- Forget the cached appearance of a character.
function Repo.invalidate(charid)
    Repo.cache[key(charid)] = nil
end

local function remember(charid, app, id, defaultsUsed)
    defaultsUsed = defaultsUsed or {}
    local isDegraded = #defaultsUsed > 0
    Repo.cache[key(charid)] = { app = WCUtil.copy(app), id = id, defaultsUsed = WCUtil.copy(defaultsUsed),
                                degraded = isDegraded }
    degraded[key(charid)] = isDegraded and WCUtil.copy(defaultsUsed) or nil
end

-- The schema migrations have run (waits with a timeout on a fresh start).
local function schemaReady()
    if type(WCMigrations) ~= 'table' or type(WCMigrations.waitReady) ~= 'function' then return true end
    return WCMigrations.waitReady(MIGRATION_WAIT_MS) == true
end

-- The w_lib catalogue is available for the sex (an appearance cannot be validated without it).
local function catalogueReady(sex)
    return next(WCCatalog.forSex(sex == 'female' and 'female' or 'male')) ~= nil
end

--- The sections of a character whose loaded appearance needed essential defaults, or nil.
function Repo.degraded(charid)
    local sections = charid ~= nil and degraded[key(charid)]
    return sections and WCUtil.copy(sections) or nil
end

local function decodeV3(row)
    if (tonumber(row.appearance_version) or 0) < AppearanceSchema.VERSION then return nil end
    local data = WCUtil.decode(row.appearance)
    if tonumber(data.version) ~= AppearanceSchema.VERSION then return nil end
    return data
end

--- The legacy ownership grants for the equipped clothing of an appearance.
function Repo.legacyGrants(charid, app)
    local queries = {}
    for _, category in ipairs(WCUtil.sortedKeys(app.clothing.equipped)) do
        queries[#queries + 1] = { query = GRANT_LEGACY, values = { key(charid), app.clothing.equipped[category], category } }
    end
    return queries
end

--- Load a character's appearance: app, meta | nil, meta.
--  meta = { version = <source version>, defaultsUsed = {...}, degraded = bool, upgraded = bool,
--           cached = bool, missing = true (no row) | error = 'DATABASE_ERROR' | 'INTERNAL_ERROR' }
function Repo.load(charid)
    if charid == nil then return nil, { missing = true } end
    local cached = Repo.cache[key(charid)]
    if cached then
        return WCUtil.copy(cached.app), { version = AppearanceSchema.VERSION, cached = true,
                                          defaultsUsed = WCUtil.copy(cached.defaultsUsed or {}),
                                          degraded = cached.degraded == true }
    end
    if not schemaReady() then
        WCDebug.warn('appearance', 'reading %s refused: the database migrations have not completed', key(charid))
        return nil, { error = 'DATABASE_ERROR' }
    end

    local ok, row = pcall(w.database.single.await, SELECT_LATEST, { key(charid) })
    if not ok then
        WCDebug.warn('appearance', 'reading %s failed: %s', key(charid), tostring(row))
        return nil, { error = 'DATABASE_ERROR' }
    end
    if type(row) ~= 'table' then return nil, { missing = true } end

    local v3 = decodeV3(row)
    local sex = v3 and v3.sex or AppearanceSchema.sexOf(row.isMale)
    if not catalogueReady(sex) then
        WCDebug.warn('appearance', 'reading %s refused: the w_lib component catalogue is unavailable', key(charid))
        return nil, { error = 'INTERNAL_ERROR' }
    end

    if v3 then
        local app, violations, defaultsUsed = AppearanceSchema.sanitize(v3, PERSISTED)
        if #defaultsUsed > 0 then
            WCDebug.warn('appearance', 'character %s: stored appearance needed defaults for %s - it will not be overwritten',
                key(charid), table.concat(defaultsUsed, ','))
        end
        remember(charid, app, row.id, defaultsUsed)
        return app, { version = AppearanceSchema.VERSION, defaultsUsed = defaultsUsed, violations = violations,
                      degraded = #defaultsUsed > 0, upgraded = false, cached = false }
    end

    local app, meta = AppearanceSchema.fromLegacy(row)
    meta.upgraded, meta.cached, meta.degraded = false, false, #meta.defaultsUsed > 0
    if meta.dropped and #meta.dropped > 0 then
        WCDebug.warn('appearance', 'character %s: legacy clothing not in the catalogue was left out: %s',
            key(charid), table.concat(meta.dropped, ','))
    end
    if #meta.defaultsUsed == 0 then
        local encoded = WCUtil.encode(app)
        local queries = {
            { query = 'UPDATE characters_appearence SET appearance = ?, appearance_version = ?, updated_at = CURRENT_TIMESTAMP WHERE id = ?',
              values = { encoded, AppearanceSchema.VERSION, row.id } },
        }
        for _, q in ipairs(Repo.legacyGrants(charid, app)) do queries[#queries + 1] = q end
        local txOk, done = pcall(w.database.transaction.await, queries)
        meta.upgraded = encoded ~= nil and txOk and done == true
        if not meta.upgraded then
            WCDebug.warn('appearance', 'character %s: v3 upgrade write failed: %s', key(charid), tostring(done))
        end
    else
        WCDebug.warn('appearance', 'character %s: legacy appearance needed defaults for %s - not upgraded',
            key(charid), table.concat(meta.defaultsUsed, ','))
    end
    remember(charid, app, row.id, meta.defaultsUsed)
    return app, meta
end

local function rowId(charid)
    local cached = Repo.cache[key(charid)]
    if cached and cached.id then return cached.id end
    local ok, id = pcall(w.database.scalar.await,
        'SELECT id FROM characters_appearence WHERE charid = ? ORDER BY id DESC LIMIT 1', { key(charid) })
    if ok then return id end
    return nil
end

local function columns(app)
    local legacy = AppearanceSchema.toLegacy(app)
    return WCUtil.encode(app), legacy
end

--- Save an appearance (sanitized first, clothing as given) and `extra` { {query, values}... } in one
--  transaction. opts.replaceDegraded = true allows overwriting a character whose loaded appearance
--  needed essential defaults (an explicit repair); every other writer is refused then.
--  Returns true, app | false, code (CHARACTER_NOT_FOUND | DATABASE_ERROR | INTERNAL_ERROR | INVALID_PAYLOAD).
function Repo.save(charid, app, extra, opts)
    if charid == nil then return false, 'CHARACTER_NOT_FOUND' end
    opts = type(opts) == 'table' and opts or {}
    if degraded[key(charid)] and opts.replaceDegraded ~= true then
        WCDebug.warn('appearance', 'saving %s refused: its stored appearance needed defaults (%s)', key(charid),
            table.concat(degraded[key(charid)], ','))
        return false, 'INTERNAL_ERROR'
    end
    if not catalogueReady(type(app) == 'table' and app.sex) then return false, 'INTERNAL_ERROR' end
    if not schemaReady() then return false, 'DATABASE_ERROR' end
    app = AppearanceSchema.sanitize(app, PERSISTED)
    local id = rowId(charid)
    if not id then return false, 'CHARACTER_NOT_FOUND' end
    local encoded, legacy = columns(app)
    if not encoded then return false, 'INVALID_PAYLOAD' end
    local queries = {
        { query = 'UPDATE characters_appearence SET appearance = ?, appearance_version = ?, updated_at = CURRENT_TIMESTAMP, isMale = ?, components = ?, faceFeatures = ?, overlays = ? WHERE id = ? AND charid = ?',
          values = { encoded, AppearanceSchema.VERSION, legacy.isMale, legacy.components, legacy.faceFeatures,
                     legacy.overlays, id, key(charid) } },
    }
    for _, q in ipairs(type(extra) == 'table' and extra or {}) do queries[#queries + 1] = q end
    Repo.invalidate(charid)
    local ok, done = pcall(w.database.transaction.await, queries)
    if not ok or done ~= true then
        WCDebug.warn('appearance', 'saving %s failed: %s', key(charid), tostring(done))
        return false, 'DATABASE_ERROR'
    end
    remember(charid, app, id, {})
    return true, app
end

--- Create the appearance row of a new character (+ `extra` queries, e.g. starter grants) in one
--  transaction. identity = { firstname, lastname, age? }. Returns true, app | false, code.
function Repo.create(charid, identity, app, extra)
    if charid == nil then return false, 'CHARACTER_NOT_FOUND' end
    if not catalogueReady(type(app) == 'table' and app.sex) then return false, 'INTERNAL_ERROR' end
    if not schemaReady() then return false, 'DATABASE_ERROR' end
    app = AppearanceSchema.sanitize(app, PERSISTED)
    identity = type(identity) == 'table' and identity or {}
    local name = WCUtil.clampString(WCUtil.trim(('%s %s'):format(identity.firstname or '', identity.lastname or '')), 60)
    local encoded, legacy = columns(app)
    if not encoded then return false, 'INVALID_PAYLOAD' end
    local queries = {
        { query = 'INSERT INTO characters_appearence (charid, isMale, name, age, faceFeatures, overlays, components, appearance, appearance_version, updated_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, CURRENT_TIMESTAMP)',
          values = { key(charid), legacy.isMale, name, WCUtil.int(identity.age, 0, 200, nil), legacy.faceFeatures,
                     legacy.overlays, legacy.components, encoded, AppearanceSchema.VERSION } },
    }
    for _, q in ipairs(type(extra) == 'table' and extra or {}) do queries[#queries + 1] = q end
    Repo.invalidate(charid)
    local ok, done = pcall(w.database.transaction.await, queries)
    if not ok or done ~= true then
        WCDebug.warn('appearance', 'creating %s failed: %s', key(charid), tostring(done))
        return false, 'DATABASE_ERROR'
    end
    degraded[key(charid)] = nil
    return true, app
end

--- Delete a character's appearance, owned clothing and outfits in one transaction.
function Repo.delete(charid)
    if charid == nil then return false end
    local id = key(charid)
    Repo.invalidate(charid)
    if not schemaReady() then return false end
    local ok, done = pcall(w.database.transaction.await, {
        { query = 'DELETE FROM characters_appearence WHERE charid = ?', values = { id } },
        { query = 'DELETE FROM w_creators_clothes WHERE charid = ?', values = { id } },
        { query = 'DELETE FROM w_creators_outfits WHERE charid = ?', values = { id } },
    })
    if not ok or done ~= true then
        WCDebug.warn('appearance', 'deleting %s failed: %s', id, tostring(done))
        return false
    end
    degraded[id] = nil
    return true
end

--- Upgrade every legacy row, in batches (console command wc_migrate_appearances).
--  Returns scanned, upgraded.
function Repo.migrateAll(batchSize)
    batchSize = WCUtil.int(batchSize, 1, 1000, 100)
    local lastId, scanned, upgraded = 0, 0, 0
    while true do
        local rows = w.database.query.await(
            'SELECT id, charid FROM characters_appearence WHERE id > ? AND (appearance IS NULL OR appearance_version < ?) ORDER BY id LIMIT ?',
            { lastId, AppearanceSchema.VERSION, batchSize }) or {}
        if #rows == 0 then break end
        for _, row in ipairs(rows) do
            lastId = math.max(lastId, tonumber(row.id) or lastId)
            scanned = scanned + 1
            Repo.invalidate(row.charid)
            local _, meta = Repo.load(row.charid)
            if meta and meta.upgraded then upgraded = upgraded + 1 end
            Repo.invalidate(row.charid)
        end
        if #rows < batchSize then break end
    end
    return scanned, upgraded
end

RegisterCommand('wc_migrate_appearances', function(src)
    if src ~= 0 then return end
    CreateThread(function()
        local scanned, upgraded = Repo.migrateAll(100)
        print(('[w_creators] wc_migrate_appearances: %d legacy row(s) scanned, %d upgraded'):format(scanned, upgraded))
    end)
end, true)

AddEventHandler('playerDropped', function()
    local active = WCSessions and WCSessions.activeCharacter and WCSessions.activeCharacter(source)
    if active then Repo.invalidate(active.charid) end
end)
