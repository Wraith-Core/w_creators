-- =====================================================================
--  config/barber.lua
--  The barber services and prices, and hair/beard growth (grooming).
--  Barber locations live in config/locations.lua (type = 'barber').
-- =====================================================================

Config.Barber = {
    -- A visit costs the sum of the prices of the services it changes, capped at prices.visitCap.
    -- The defaults keep the pre-v3 price: one flat 10 per visit for any hair and/or beard change.
    services = {
        hair       = { enabled = true, price = 10 },  -- hair style and colour (+ the hairline overlay)
        facialHair = { enabled = true, price = 10 },  -- beard / moustache (male) (+ the stubble overlay)
        -- Details: eyebrow overlay and (optionally) makeup overlays.
        details    = { enabled = true, price = 5, eyebrows = true, makeup = false },
    },
    prices = {
        visitCap = 10, -- the most one visit can cost (nil = no cap)
    },
    -- The barber chair (2026-10-19): a barber place with a chair (/servicesadmin) seats the player in it.
    -- scenarios: tried in order; PROP_PLAYER_BARBER_SEAT is the game's own player scenario for a barber
    -- chair (mech.meta), PROP_HUMAN_SEAT_CHAIR the plain chair sit. offset: where the seated player goes in
    -- the chair's own frame (x right, y towards the back, z up), measured on the game's barber clips; if he
    -- sits too low in game (the scenario lowers him 0.3 m) set z = 1.04.
    chair = {
        scenarios = { 'PROP_PLAYER_BARBER_SEAT', 'PROP_HUMAN_SEAT_CHAIR' },
        offset = { x = -0.01, y = 0.15, z = 0.74 },
        verifyMs = 600, -- how long a scenario may take to start before the next one is tried
    },
}

-- ---------------------------------------------------------------------
--  Grooming: hair and beards grow while the character is online in the main world.
--  Appearance changes use existing multiplayer assets, never a change of ped model.
--  Stage entries name asset prefixes explicitly; the colour suffix of the current style is kept.
--  Growth accumulates in memory and is written on a stage change, every saveIntervalSeconds
--  and when the player drops (no per-tick database writes).
-- ---------------------------------------------------------------------
Config.Grooming = {
    enabled = false, -- owner 2026-11-01: no automatic growth; the barber is only for picking a style
    minutesPerStage = { hair = 120, beard = 60 },
    stages = {
        male = {
            hair  = { 'CLOTHING_ITEM_M_HAIR_001_', 'CLOTHING_ITEM_M_HAIR_006_', 'CLOTHING_ITEM_M_HAIR_008_' },
            beard = { 'CLOTHING_ITEM_M_BEARD_001_', 'CLOTHING_ITEM_M_BEARD_004_', 'CLOTHING_ITEM_M_BEARD_006_' },
        },
        female = {
            hair  = { 'CLOTHING_ITEM_F_HAIR_001_', 'CLOTHING_ITEM_F_HAIR_003_', 'CLOTHING_ITEM_F_HAIR_006_' },
        },
    },
    saveIntervalSeconds = 300,
}
