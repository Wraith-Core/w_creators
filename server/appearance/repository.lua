-- =====================================================================
--  server/appearance/repository.lua  —  WCAppearanceRepo (ARCHITECTURE.md §6)
--  Persistence of the v3 appearance in characters_appearence.appearance (JSON) with
--  appearance_version = 3. The legacy columns (isMale / components / faceFeatures / overlays) are
--  rewritten on every save from AppearanceSchema.toLegacy(app) as a derived compatibility
--  projection; the v3 JSON is authoritative while they are unchanged.
--
--  Projection fingerprint (§6.1): every v3 write stores, inside the appearance JSON (top-level key
--  `projection`, never part of the returned appearance), a fingerprint of the legacy columns as they
--  are in the row after that write. A previous release (a rollback) writes only the legacy columns
--  (haircuts, store purchases, grooming growth); when a v3 row is loaded whose legacy columns no
--  longer match its fingerprint, that newer data is taken back: the appearance is rebuilt with
--  AppearanceSchema.fromLegacy and keeps the v3-only data that still applies (the tints of the items
--  still worn, the states whose items are unchanged, the outfit id when the worn set is unchanged),
--  written back and logged. A rebuild that would need essential defaults keeps the v3 JSON. Rows
--  written before the fingerprint existed carry none: their JSON is trusted as before.
--
--  Lazy upgrade (§6.2): a row below v3 (or with a NULL/corrupt appearance) is converted with
--  AppearanceSchema.fromLegacy. When the conversion needed no essential defaults the v3 appearance
--  is written back together with 'legacy' ownership grants for the equipped clothing (INSERT
--  IGNORE) in one transaction. When that write fails, the grants are owed: they join the next
--  save's transaction (that save makes the row v3, so the upgrade never runs again). When defaults
--  were needed nothing is written (data is never silently replaced): the in-memory appearance uses
--  the defaults and a warning is logged. A row already at v3 whose JSON is unreadable is recovered
--  the same way but without any 'legacy' grant (its ownership is authoritative already; meta.recovered).
--
--  Cache generations: every write and invalidation bumps the character's generation; a load caches
--  what it read only when the generation did not move while it yielded (a pre-save read never
--  replaces what a save cached after its commit).
--
--  Degraded appearances: an appearance that needed essential defaults (legacy or stored v3) is
--  remembered as degraded; save() refuses to overwrite that character unless the caller passes
--  opts.replaceDegraded (the explicit repair: the creator's appearance-only path, which
--  characters:select offers for a degraded character), so no automatic writer persists the defaults.
--
--  The cache holds the characters loaded for play (per active character). load(charid, { cache =
--  false }) reads without caching (the selection cards of every owned character) and without
--  touching the degraded flags. meta.row = { name, age, isMale } of the row read (card fallbacks).
--  Every read/write waits for the schema migrations (WCMigrations.waitReady) and needs the w_lib
--  catalogue: without it the appearance cannot be validated, so nothing is loaded or written.
--  Stored clothing is read and written as stored (AppearanceSchema.sanitize with rules = false).
-- =====================================================================

WCAppearanceRepo = { cache = {} }
local Repo = WCAppearanceRepo

local MIGRATION_WAIT_MS = 10000
local degraded = {} -- [charid] = { section... }: the loaded appearance needed essential defaults
-- [charid] = { {query, values}... }: the 'legacy' grants of a lazy upgrade whose write failed. They
-- are built from the pre-v3 appearance as loaded and join the next save's transaction (the row is
-- v3 after it and the upgrade never runs again); cleared once a transaction carrying them commits.
local pendingLegacy = {}
local PERSISTED = { rules = false }

local SELECT_LATEST = 'SELECT * FROM characters_appearence WHERE charid = ? ORDER BY id DESC LIMIT 1'
local GRANT_LEGACY = "INSERT IGNORE INTO w_creators_clothes (charid, hash, category, source, acquired_at) VALUES (?, ?, ?, 'legacy', CURRENT_TIMESTAMP)"
local WRITE_JSON = 'UPDATE characters_appearence SET appearance = ?, appearance_version = ?, updated_at = CURRENT_TIMESTAMP WHERE id = ?'

local function key(charid) return tostring(charid) end

-- [charid] = n: bumped by every write and invalidation. A load remembers what it read only when
-- no write or invalidation happened while its SELECT (and its own writes) yielded: a pre-save row
-- read during a save must never replace the entry the save cached after its commit.
local generation = {}

local function bump(charid)
    local k = key(charid)
    generation[k] = (generation[k] or 0) + 1
end

--- Forget the cached appearance of a character.
function Repo.invalidate(charid)
    Repo.cache[key(charid)] = nil
    bump(charid)
end

local function rowInfo(row)
    return { name = row.name, age = row.age, isMale = row.isMale }
end

local function remember(charid, app, id, defaultsUsed, info)
    defaultsUsed = defaultsUsed or {}
    local isDegraded = #defaultsUsed > 0
    Repo.cache[key(charid)] = { app = WCUtil.copy(app), id = id, defaultsUsed = WCUtil.copy(defaultsUsed),
                                degraded = isDegraded, row = info and WCUtil.copy(info) or nil }
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

-- ---------------------------------------------------------------------
--  Projection fingerprint
-- ---------------------------------------------------------------------

-- 32-bit FNV-1a of a string, from a given offset basis.
local function fnv1a(s, basis)
    local h = basis
    for i = 1, #s do
        h = ((h ~ s:byte(i)) * 16777619) & 0xffffffff
    end
    return h
end

--- The fingerprint of legacy columns { isMale, components, faceFeatures, overlays } (a row or a
--  toLegacy result), or nil when they cannot be fingerprinted (a column that is not text).
function Repo.fingerprint(cols)
    if type(cols) ~= 'table' then return nil end
    local parts = { AppearanceSchema.sexOf(cols.isMale) }
    for _, name in ipairs({ 'components', 'faceFeatures', 'overlays' }) do
        local v = cols[name]
        if v ~= nil and type(v) ~= 'string' then return nil end
        parts[#parts + 1] = v == nil and '\0' or v
    end
    local text = table.concat(parts, '\31')
    return ('%08x%08x:%d'):format(fnv1a(text, 2166136261), fnv1a(text, 0x811c9dc5 ~ 0x5bd1e995), #text)
end

-- The JSON of an appearance with the fingerprint of the legacy columns the row holds after the write.
local function encodeWith(app, fingerprint)
    local data = WCUtil.copy(app)
    data.projection = fingerprint
    return WCUtil.encode(data)
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

-- The v3-only data (tints, states, outfit) of `v3app` carried onto `rebuilt` (fromLegacy of legacy
-- columns an older release wrote): only where it still applies to what the columns now wear.
local function carryOver(v3app, rebuilt)
    local out = WCUtil.copy(rebuilt)
    local before, after = v3app.clothing.equipped, out.clothing.equipped
    out.clothing.tints = {}
    for category, tint in pairs(v3app.clothing.tints) do
        if after[category] ~= nil and after[category] == before[category] then
            out.clothing.tints[category] = WCUtil.copy(tint)
        end
    end
    local swapped = WCOwnership.changedCategories(before, after)
    out.clothing.states = WCOwnership.settleStates(out, v3app.clothing.states, WCOwnership.groupsOf(swapped))
    out.clothing.outfit = next(swapped) == nil and v3app.clothing.outfit or nil
    return (AppearanceSchema.sanitize(out, PERSISTED))
end

local LEGACY_COLUMNS = { 'components', 'faceFeatures', 'overlays' }

-- Is a legacy column real data an older release wrote: a non-empty string that decodes to a JSON
-- table (object or array)?
local function legacyColumnUsable(v)
    if type(v) ~= 'string' or v == '' then return false end
    local ok, data = pcall(json.decode, v)
    return ok and type(data) == 'table'
end

-- A v3 row whose legacy columns were written after its v3 JSON (a rollback to an older release):
-- the appearance to use, and whether it was reconciled. Never replaces data with defaults.
local function reconcile(charid, row, v3, app)
    local stored = v3.projection
    if type(stored) ~= 'string' then return app, false end
    local current = Repo.fingerprint(row)
    if current == nil or current == stored then return app, false end
    if type(WCOwnership) ~= 'table' or type(WCOwnership.settleStates) ~= 'function' then return app, false end
    -- Only real legacy data is taken back: an older release always writes every column as JSON. A
    -- NULL, empty or undecodable column (cleared or damaged outside the resource) would rebuild as
    -- "no face morph / no overlays" without any essential default being reported: the v3 JSON is
    -- kept and the fingerprint left as it is (as for a rebuild that needs defaults).
    local unusable = {}
    for _, name in ipairs(LEGACY_COLUMNS) do
        if not legacyColumnUsable(row[name]) then unusable[#unusable + 1] = name end
    end
    if #unusable > 0 then
        WCDebug.warn('appearance', 'character %s: its legacy columns changed after the v3 write but %s cannot be read - the v3 appearance is kept',
            key(charid), table.concat(unusable, ','))
        return app, false
    end

    local rebuilt, lmeta = AppearanceSchema.fromLegacy(row)
    if #lmeta.defaultsUsed > 0 then
        WCDebug.warn('appearance', 'character %s: its legacy columns changed after the v3 write but need defaults for %s - the v3 appearance is kept',
            key(charid), table.concat(lmeta.defaultsUsed, ','))
        return app, false
    end
    local merged = carryOver(app, rebuilt)
    local same = AppearanceSchema.equal(merged, app)
    -- The JSON is written back with the fingerprint of the columns as they are now (they are left
    -- alone): an unchanged look (columns only re-encoded by the older release) just moves the
    -- fingerprint; a changed one replaces the stale JSON. A failed write keeps the result in memory
    -- (the next save writes it).
    local encoded = encodeWith(same and app or merged, current)
    local written = false
    if encoded then
        local txOk, result = pcall(w.database.transaction.await,
            { { query = WRITE_JSON, values = { encoded, AppearanceSchema.VERSION, row.id } } })
        written = txOk and result == true
    end
    if same then return app, false end
    WCDebug.warn('appearance', 'character %s: its legacy columns were changed by an older release after the last v3 write - the appearance was rebuilt from them (%s)',
        key(charid), written and 'written back' or 'write failed, kept in memory')
    return merged, true
end

-- ---------------------------------------------------------------------
--  Load / save
-- ---------------------------------------------------------------------

--- Load a character's appearance: app, meta | nil, meta.
--  meta = { version = <source version>, defaultsUsed = {...}, degraded = bool, upgraded = bool,
--           cached = bool, reconciled = bool, row = { name, age, isMale } (the row read; also on a
--           refusal after the read), missing = true (no row) | error = 'DATABASE_ERROR' | 'INTERNAL_ERROR' }
--  opts.cache = false: read without caching (and without touching the degraded flags).
function Repo.load(charid, opts)
    if charid == nil then return nil, { missing = true } end
    local useCache = not (type(opts) == 'table' and opts.cache == false)
    local cached = Repo.cache[key(charid)]
    if cached then
        return WCUtil.copy(cached.app), { version = AppearanceSchema.VERSION, cached = true,
                                          defaultsUsed = WCUtil.copy(cached.defaultsUsed or {}),
                                          degraded = cached.degraded == true,
                                          row = cached.row and WCUtil.copy(cached.row) or nil }
    end
    if not schemaReady() then
        WCDebug.warn('appearance', 'reading %s refused: the database migrations have not completed', key(charid))
        return nil, { error = 'DATABASE_ERROR' }
    end

    local gen = generation[key(charid)]
    local function keep(...)
        if useCache and generation[key(charid)] == gen then remember(...) end
    end
    local ok, row = pcall(w.database.single.await, SELECT_LATEST, { key(charid) })
    if not ok then
        WCDebug.warn('appearance', 'reading %s failed: %s', key(charid), tostring(row))
        return nil, { error = 'DATABASE_ERROR' }
    end
    if type(row) ~= 'table' then return nil, { missing = true } end
    local info = rowInfo(row)

    local v3 = decodeV3(row)
    local sex = v3 and v3.sex or AppearanceSchema.sexOf(row.isMale)
    if not catalogueReady(sex) then
        WCDebug.warn('appearance', 'reading %s refused: the w_lib component catalogue is unavailable', key(charid))
        return nil, { error = 'INTERNAL_ERROR', row = info }
    end

    if v3 then
        local app, violations, defaultsUsed = AppearanceSchema.sanitize(v3, PERSISTED)
        local reconciled = false
        if #defaultsUsed > 0 then
            WCDebug.warn('appearance', 'character %s: stored appearance needed defaults for %s - it will not be overwritten',
                key(charid), table.concat(defaultsUsed, ','))
        else
            app, reconciled = reconcile(charid, row, v3, app)
        end
        pendingLegacy[key(charid)] = nil
        keep(charid, app, row.id, defaultsUsed, info)
        return app, { version = AppearanceSchema.VERSION, defaultsUsed = defaultsUsed, violations = violations,
                      degraded = #defaultsUsed > 0, upgraded = false, cached = false, reconciled = reconciled,
                      row = info }
    end

    local app, meta = AppearanceSchema.fromLegacy(row)
    meta.upgraded, meta.cached, meta.degraded = false, false, #meta.defaultsUsed > 0
    meta.row = info
    -- A row already marked v3 whose JSON cannot be read: recovered from its projection, but its
    -- ownership is authoritative already — no 'legacy' grants (the projection may carry clothing
    -- applied through SetClothes, a job uniform the character does not own).
    local recovering = (tonumber(row.appearance_version) or 0) >= AppearanceSchema.VERSION
    meta.recovered = recovering or nil
    if recovering then
        WCDebug.warn('appearance', 'character %s: its v3 appearance JSON is unreadable - recovered from the legacy projection (tints, states and outfit lost; no ownership granted)',
            key(charid))
    end
    if meta.dropped and #meta.dropped > 0 then
        WCDebug.warn('appearance', 'character %s: legacy clothing not in the catalogue was left out: %s',
            key(charid), table.concat(meta.dropped, ','))
    end
    if #meta.defaultsUsed == 0 then
        -- The legacy columns are not rewritten here: the fingerprint is the one of the row as it is.
        local encoded = encodeWith(app, Repo.fingerprint(row))
        local queries = { { query = WRITE_JSON, values = { encoded, AppearanceSchema.VERSION, row.id } } }
        local owedGrants = recovering and {} or Repo.legacyGrants(charid, app)
        for _, q in ipairs(owedGrants) do queries[#queries + 1] = q end
        local txOk, done = pcall(w.database.transaction.await, queries)
        meta.upgraded = encoded ~= nil and txOk and done == true
        if meta.upgraded then
            pendingLegacy[key(charid)] = nil
        else
            WCDebug.warn('appearance', 'character %s: v3 upgrade write failed: %s', key(charid), tostring(done))
            pendingLegacy[key(charid)] = #owedGrants > 0 and owedGrants or nil
        end
    else
        WCDebug.warn('appearance', 'character %s: legacy appearance needed defaults for %s - not upgraded',
            key(charid), table.concat(meta.defaultsUsed, ','))
        -- Nothing is written, but the pre-v3 outfit is still owed its 'legacy' ownership: the
        -- clothing is never an essential section (fromLegacy keeps it as stored) and the explicit
        -- repair (save with replaceDegraded) keeps it, so the grants join that save's transaction —
        -- the one that makes the row v3, after which the lazy upgrade never runs again.
        pendingLegacy[key(charid)] = (not recovering) and Repo.legacyGrants(charid, app) or nil
    end
    keep(charid, app, row.id, meta.defaultsUsed, info)
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

-- The v3 JSON (with the fingerprint of the projection written alongside) and the legacy projection.
local function columns(app)
    local legacy = AppearanceSchema.toLegacy(app)
    return encodeWith(app, Repo.fingerprint(legacy)), legacy
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
    -- The legacy grants a failed lazy upgrade still owes come before `extra`: a grant there (a
    -- purchase with its tint) is applied after them and wins.
    local owed = pendingLegacy[key(charid)]
    for _, q in ipairs(owed or {}) do queries[#queries + 1] = q end
    for _, q in ipairs(type(extra) == 'table' and extra or {}) do queries[#queries + 1] = q end
    local info = Repo.cache[key(charid)] and Repo.cache[key(charid)].row
    Repo.invalidate(charid)
    local ok, done = pcall(w.database.transaction.await, queries)
    if not ok or done ~= true then
        WCDebug.warn('appearance', 'saving %s failed: %s', key(charid), tostring(done))
        return false, 'DATABASE_ERROR'
    end
    if owed and pendingLegacy[key(charid)] == owed then pendingLegacy[key(charid)] = nil end
    if info then info.isMale = legacy.isMale end
    bump(charid)
    remember(charid, app, id, {}, info)
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
    bump(charid)
    degraded[key(charid)] = nil
    pendingLegacy[key(charid)] = nil
    return true, app
end

--- Delete a character's appearance, owned clothing (and its owned colours) and outfits in one
--  transaction.
function Repo.delete(charid)
    if charid == nil then return false end
    local id = key(charid)
    Repo.invalidate(charid)
    if not schemaReady() then return false end
    local ok, done = pcall(w.database.transaction.await, {
        { query = 'DELETE FROM characters_appearence WHERE charid = ?', values = { id } },
        { query = 'DELETE FROM w_creators_clothes WHERE charid = ?', values = { id } },
        { query = 'DELETE FROM w_creators_colorways WHERE charid = ?', values = { id } },
        { query = 'DELETE FROM w_creators_outfits WHERE charid = ?', values = { id } },
    })
    if not ok or done ~= true then
        WCDebug.warn('appearance', 'deleting %s failed: %s', id, tostring(done))
        return false
    end
    bump(charid)
    degraded[id] = nil
    pendingLegacy[id] = nil
    return true
end

local COUNT_OWNED = 'SELECT (SELECT COUNT(*) FROM characters_appearence WHERE charid = ?) AS appearance, '
    .. '(SELECT COUNT(*) FROM w_creators_clothes WHERE charid = ?) AS clothes, '
    .. '(SELECT COUNT(*) FROM w_creators_outfits WHERE charid = ?) AS outfits, '
    .. '(SELECT COUNT(*) FROM w_creators_colorways WHERE charid = ?) AS colorways'

--- Purge a deleted character (w_core's PurgeCharacter, through WCCharacters.purge): its rows go in
--  one transaction (Repo.delete) together with everything the repository remembers about it — the
--  cache, the degraded flag and the 'legacy' grants a failed upgrade still owed (the next save of
--  whoever gets the number would otherwise insert them). The rows are counted first for the staff
--  report. Idempotent: a second run counts nothing and succeeds. The generation is bumped, never
--  cleared: a load still in flight must not cache the row it read before the delete.
--  Returns true, { characters_appearence, w_creators_clothes, w_creators_outfits, w_creators_colorways }
--  (counts) |
--  false, 'invalid_id' | 'database_not_ready' | 'database'.
function Repo.purge(charid)
    if charid == nil then return false, 'invalid_id' end
    local id = key(charid)
    if not schemaReady() then return false, 'database_not_ready' end
    local counted, row = pcall(w.database.single.await, COUNT_OWNED, { id, id, id, id })
    if not counted or type(row) ~= 'table' then
        WCDebug.warn('appearance', 'purging %s: counting its rows failed: %s', id, tostring(row))
        return false, 'database'
    end
    if not Repo.delete(charid) then return false, 'database' end
    return true, {
        characters_appearence = math.tointeger(tonumber(row.appearance) or 0) or 0,
        w_creators_clothes = math.tointeger(tonumber(row.clothes) or 0) or 0,
        w_creators_outfits = math.tointeger(tonumber(row.outfits) or 0) or 0,
        w_creators_colorways = math.tointeger(tonumber(row.colorways) or 0) or 0,
    }
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

AddEventHandler('w_appearance:updated', function(_, charid)
    if charid ~= nil then Repo.invalidate(charid) end
end)

AddEventHandler('playerDropped', function()
    local active = WCSessions and WCSessions.activeCharacter and WCSessions.activeCharacter(source)
    if active then Repo.invalidate(active.charid) end
end)
