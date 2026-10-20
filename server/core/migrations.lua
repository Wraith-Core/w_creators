-- =====================================================================
--  server/core/migrations.lua  —  WCMigrations (ARCHITECTURE.md §5.7)
--  Additive, versioned, idempotent schema migrations. Applied ids are stored in
--  w_creators_migrations; every step also checks information_schema first (ADD COLUMN IF NOT
--  EXISTS is MariaDB-only), so a partially migrated or hand-edited database converges.
--  The ledger is a record, not the proof: a recorded step's end state (its tables / columns) is
--  verified on every start and the step is applied again when something is missing (a table
--  restored from a pre-v3 dump while the ledger kept its ids), so waitReady never reports a
--  schema the code cannot write to. Nothing is ever dropped. run() is called once on
--  w.database.ready.
-- =====================================================================

WCMigrations = { list = {}, done = false, ok = nil, applied = {} }
local M = WCMigrations

--- Register a migration (applied in registration order). verify (optional) checks the step's end
--  state (true when everything it creates exists); a recorded step that fails it runs again.
function M.register(id, fn, verify)
    assert(type(id) == 'string' and type(fn) == 'function', 'WCMigrations.register(id, fn, verify?)')
    assert(verify == nil or type(verify) == 'function', 'WCMigrations.register: verify must be a function')
    for _, m in ipairs(M.list) do
        if m.id == id then error('duplicate migration id ' .. id) end
    end
    M.list[#M.list + 1] = { id = id, fn = fn, verify = verify }
end

--- Do all the columns exist in the table?
function M.columnsExist(t, columns)
    for _, c in ipairs(columns) do
        if not M.columnExists(t, c) then return false end
    end
    return true
end

--- Does the table exist in the current database?
function M.tableExists(t)
    local n = w.database.scalar.await(
        'SELECT COUNT(*) FROM information_schema.TABLES WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = ?', { t })
    return (tonumber(n) or 0) > 0
end

--- Does the column exist in the table?
function M.columnExists(t, c)
    local n = w.database.scalar.await(
        'SELECT COUNT(*) FROM information_schema.COLUMNS WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = ? AND COLUMN_NAME = ?',
        { t, c })
    return (tonumber(n) or 0) > 0
end

--- Add a column only when it is missing. Returns true when it was added.
function M.addColumn(t, c, definition)
    if M.columnExists(t, c) then return false end
    w.database.query.await(('ALTER TABLE `%s` ADD COLUMN `%s` %s'):format(t, c, definition))
    return true
end

--- Wait (with a timeout) until run() has finished. Returns true when every migration applied.
function M.waitReady(timeoutMs)
    WCUtil.waitUntil(function() return M.done end, timeoutMs or 30000, 100)
    return M.done and M.ok == true
end

--- Apply every registered migration that is not recorded yet. Stops at the first failure (later
--  migrations may depend on it). Returns ok, appliedIds.
function M.run()
    if M.running then return false, {} end
    M.running = true
    local applied = {}
    local ok, err = pcall(function()
        w.database.query.await([[
            CREATE TABLE IF NOT EXISTS `w_creators_migrations` (
                `id` VARCHAR(64) NOT NULL,
                `applied_at` TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
                PRIMARY KEY (`id`)
            ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_general_ci
        ]])
        local seen = {}
        for _, row in ipairs(w.database.query.await('SELECT id FROM w_creators_migrations') or {}) do
            seen[row.id] = true
        end
        for _, m in ipairs(M.list) do
            if not seen[m.id] then
                local stepOk, stepErr = pcall(m.fn)
                if not stepOk then error(('migration %s failed: %s'):format(m.id, tostring(stepErr)), 0) end
                w.database.insert.await('INSERT INTO w_creators_migrations (id) VALUES (?)', { m.id })
                applied[#applied + 1] = m.id
                WCDebug.log('migrations', 'applied %s', m.id)
            elseif m.verify and not m.verify() then
                -- Recorded, but its tables / columns are gone (a partial restore): applied again
                -- (every step is idempotent); the ledger row is kept.
                WCDebug.warn('migrations', '%s is recorded but its schema is missing: applying it again', m.id)
                local stepOk, stepErr = pcall(m.fn)
                if not stepOk then error(('migration %s failed: %s'):format(m.id, tostring(stepErr)), 0) end
                if not m.verify() then error(('migration %s: the schema is still incomplete'):format(m.id), 0) end
                applied[#applied + 1] = m.id
                WCDebug.log('migrations', 'repaired %s', m.id)
            end
        end
    end)
    M.running = false
    M.done, M.ok, M.applied = true, ok, applied
    if not ok then
        print(('^1[w_creators] database migration stopped: %s^0'):format(tostring(err)))
        return false, applied
    end
    if #applied > 0 then
        print(('^2[w_creators] database migrations applied: %s^0'):format(table.concat(applied, ', ')))
    end
    return true, applied
end

-- ---------------------------------------------------------------------
--  The migrations
-- ---------------------------------------------------------------------

M.register('001_base_tables', function()
    w.database.query.await([[
        CREATE TABLE IF NOT EXISTS `characters_appearence` (
            `id` INT NOT NULL AUTO_INCREMENT,
            `charid` VARCHAR(64) NOT NULL,
            `isMale` TINYINT(1) NOT NULL DEFAULT 1,
            `name` VARCHAR(60) DEFAULT NULL,
            `age` INT DEFAULT NULL,
            `faceFeatures` LONGTEXT DEFAULT NULL,
            `overlays` LONGTEXT DEFAULT NULL,
            `components` LONGTEXT DEFAULT NULL,
            PRIMARY KEY (`id`),
            KEY `charid` (`charid`)
        ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_general_ci
    ]])
    w.database.query.await([[
        CREATE TABLE IF NOT EXISTS `w_creators_clothes` (
            `id` INT NOT NULL AUTO_INCREMENT,
            `charid` VARCHAR(100) NOT NULL,
            `hash` BIGINT NOT NULL,
            `category` VARCHAR(64) NOT NULL,
            `palette` VARCHAR(64) NULL,
            `tint0` INT NULL,
            `tint1` INT NULL,
            `tint2` INT NULL,
            PRIMARY KEY (`id`),
            INDEX `charid_idx` (`charid`),
            UNIQUE KEY `char_item` (`charid`, `hash`)
        ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_general_ci
    ]])
end, function()
    return M.tableExists('characters_appearence') and M.tableExists('w_creators_clothes')
end)

M.register('002_appearance_v3', function()
    M.addColumn('characters_appearence', 'appearance', 'LONGTEXT NULL')
    M.addColumn('characters_appearence', 'appearance_version', 'INT NOT NULL DEFAULT 2')
    M.addColumn('characters_appearence', 'updated_at', 'TIMESTAMP NULL')
end, function()
    return M.columnsExist('characters_appearence', { 'appearance', 'appearance_version', 'updated_at' })
end)

M.register('003_clothes_meta', function()
    M.addColumn('w_creators_clothes', 'source', 'VARCHAR(16) NULL')
    M.addColumn('w_creators_clothes', 'acquired_at', 'TIMESTAMP NULL')
end, function()
    return M.columnsExist('w_creators_clothes', { 'source', 'acquired_at' })
end)

M.register('004_outfits', function()
    w.database.query.await([[
        CREATE TABLE IF NOT EXISTS `w_creators_outfits` (
            `id` INT NOT NULL AUTO_INCREMENT,
            `charid` VARCHAR(100) NOT NULL,
            `name` VARCHAR(64) NOT NULL,
            `data` LONGTEXT NOT NULL,
            `created_at` TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
            `updated_at` TIMESTAMP NULL,
            PRIMARY KEY (`id`),
            INDEX `charid_idx` (`charid`)
        ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_general_ci
    ]])
end, function()
    return M.tableExists('w_creators_outfits')
end)

-- What each store purchase actually cost, and in which currency: only a garment bought with a
-- recorded price can be sold back (Config.Clothing.resell). Rows from before have none (NULL).
M.register('005_clothes_paid', function()
    M.addColumn('w_creators_clothes', 'price_paid', 'DECIMAL(10,2) NULL')
    M.addColumn('w_creators_clothes', 'currency', 'VARCHAR(8) NULL')
end, function()
    return M.columnsExist('w_creators_clothes', { 'price_paid', 'currency' })
end)

-- Colourways: every colour a character owns of each garment (the palette columns of
-- w_creators_clothes stay the colour it was last worn in). The backfill makes every dye owned so
-- far an owned colour; INSERT IGNORE on the unique key keeps it idempotent.
M.register('006_colorways', function()
    w.database.query.await([[
        CREATE TABLE IF NOT EXISTS `w_creators_colorways` (
            `id` INT NOT NULL AUTO_INCREMENT,
            `charid` VARCHAR(100) NOT NULL,
            `hash` BIGINT NOT NULL,
            `palette` VARCHAR(64) NOT NULL,
            `tint0` INT NOT NULL,
            `tint1` INT NOT NULL,
            `tint2` INT NOT NULL,
            `price_paid` DECIMAL(10,2) NULL,
            `currency` VARCHAR(8) NULL,
            `acquired_at` TIMESTAMP NULL,
            PRIMARY KEY (`id`),
            INDEX `charid_idx` (`charid`),
            UNIQUE KEY `char_colorway` (`charid`, `hash`, `palette`, `tint0`, `tint1`, `tint2`)
        ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_general_ci
    ]])
    w.database.query.await([[
        INSERT IGNORE INTO w_creators_colorways (charid, hash, palette, tint0, tint1, tint2, acquired_at)
        SELECT charid, hash, palette, tint0, tint1, tint2, acquired_at FROM w_creators_clothes
        WHERE palette IS NOT NULL AND tint0 IS NOT NULL AND tint1 IS NOT NULL AND tint2 IS NOT NULL
    ]])
end, function()
    return M.tableExists('w_creators_colorways')
end)

-- 2026-10-19: the service locations become editable in game (server/locations/store.lua, /servicesadmin): one row
-- per place, its fields as JSON (WCLocations.encode). The step also copies Config.Locations in, once: the ledger
-- keeps it from running again, so a place the staff deleted never comes back.
M.register('007_locations', function()
    w.database.query.await([[
        CREATE TABLE IF NOT EXISTS `w_creators_locations` (
            `id` VARCHAR(64) NOT NULL,
            `type` VARCHAR(16) NOT NULL,
            `data` LONGTEXT NOT NULL,
            `position` INT NOT NULL DEFAULT 0,
            `updated_by` VARCHAR(100) NULL,
            `updated_at` TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
            PRIMARY KEY (`id`)
        ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_general_ci
    ]])
    for index, loc in ipairs((Config and Config.Locations) or {}) do
        local data = type(loc) == 'table' and type(loc.id) == 'string' and WCLocations.encode(loc) or nil
        local encoded = data and WCUtil.encode(data)
        if encoded then
            w.database.query.await('INSERT IGNORE INTO `w_creators_locations` (`id`, `type`, `data`, `position`) VALUES (?, ?, ?, ?)',
                { loc.id, tostring(loc.type), encoded, index })
        end
    end
end, function()
    return M.tableExists('w_creators_locations')
end)

w.database.ready(function()
    M.run()
end)
