-- =====================================================================
--  w_creators v3 - reference schema (ARCHITECTURE.md §5.7)
--  The resource migrates itself on start (server/core/migrations.lua, ids 001-006, recorded in
--  w_creators_migrations). This file is the equivalent end state for a fresh database, for
--  reference or a manual install. Nothing here touches the framework's own character tables.
--  Existing databases: let the resource migrate (every step is additive and idempotent).
--  This file deliberately records NO migration id: CREATE TABLE IF NOT EXISTS does nothing on an
--  existing (pre-v3) table, so the resource must still run every step on its next start. Each step
--  checks information_schema first, so on a database installed from here they change nothing, and
--  on a pre-v3 database that imported this file they add the missing v3 columns.
-- =====================================================================

-- 001_base_tables + 002_appearance_v3
CREATE TABLE IF NOT EXISTS `characters_appearence` (
    `id` INT NOT NULL AUTO_INCREMENT,
    `charid` VARCHAR(64) NOT NULL,              -- the framework character id (vorp charIdentifier / rsg-qbr citizenid)
    `isMale` TINYINT(1) NOT NULL DEFAULT 1,     -- legacy projection (derived from appearance, §6.1)
    `name` VARCHAR(60) DEFAULT NULL,
    `age` INT DEFAULT NULL,
    `faceFeatures` LONGTEXT DEFAULT NULL,       -- legacy projection
    `overlays` LONGTEXT DEFAULT NULL,           -- legacy projection
    `components` LONGTEXT DEFAULT NULL,         -- legacy projection
    `appearance` LONGTEXT NULL,                 -- the v3 appearance (JSON), authoritative when appearance_version >= 3
    `appearance_version` INT NOT NULL DEFAULT 2,
    `updated_at` TIMESTAMP NULL,
    PRIMARY KEY (`id`),
    KEY `charid` (`charid`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_general_ci;

-- 001_base_tables + 003_clothes_meta
CREATE TABLE IF NOT EXISTS `w_creators_clothes` (
    `id` INT NOT NULL AUTO_INCREMENT,
    `charid` VARCHAR(100) NOT NULL,
    `hash` BIGINT NOT NULL,
    `category` VARCHAR(64) NOT NULL,
    `palette` VARCHAR(64) NULL,
    `tint0` INT NULL,
    `tint1` INT NULL,
    `tint2` INT NULL,
    `source` VARCHAR(16) NULL,                  -- store | starter | legacy | admin | gift
    `acquired_at` TIMESTAMP NULL,
    `price_paid` DECIMAL(10,2) NULL,            -- 005_clothes_paid: what the store charged (resell)
    `currency` VARCHAR(8) NULL,                 -- cash | gold
    PRIMARY KEY (`id`),
    INDEX `charid_idx` (`charid`),
    UNIQUE KEY `char_item` (`charid`, `hash`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_general_ci;

-- 006_colorways: every colour a character owns of each garment
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
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_general_ci;

-- 004_outfits
CREATE TABLE IF NOT EXISTS `w_creators_outfits` (
    `id` INT NOT NULL AUTO_INCREMENT,
    `charid` VARCHAR(100) NOT NULL,
    `name` VARCHAR(64) NOT NULL,
    `data` LONGTEXT NOT NULL,                   -- { equipped = { [category] = hash }, states = {...}, tints = {...} }
    `created_at` TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
    `updated_at` TIMESTAMP NULL,
    PRIMARY KEY (`id`),
    INDEX `charid_idx` (`charid`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_general_ci;

-- The migration ledger. Left empty on purpose (see the header): the resource records each id
-- itself after the step has checked the real columns.
CREATE TABLE IF NOT EXISTS `w_creators_migrations` (
    `id` VARCHAR(64) NOT NULL,
    `applied_at` TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (`id`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_general_ci;
