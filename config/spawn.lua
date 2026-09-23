-- =====================================================================
--  config/spawn.lua
--  Spawn (ARCHITECTURE.md §11) and death respawn (§12).
--
--  The client only ever sends a spawn point id ('__last' or a points[].id); the server resolves the
--  coordinates. Service toggles: Config.Services.spawnSelector, .lastLocation, .deathRespawn.
-- =====================================================================

Config.Spawn = {
    -- A new character's spawn (and the fallback when no spawn point is enabled): Valentine.
    firstSpawn = {
        coords = vector3(-274.09, 785.36, 119.29),
        heading = 90.0,
    },

    -- The cinematic location selector: the camera flies over each town and the player confirms.
    selector = {
        -- Mirrors Config.Services.spawnSelector (the service toggle is the authority).
        enabled = Config.Services.spawnSelector,
        -- The fade between one location and the next (ms).
        transition = 350,
        -- How long to wait for the area to stream before showing it (ms).
        sceneTimeout = 8000,
        keys = {
            select = 'RETURN', -- [ ENTER ]       spawn here
            prev   = 'LEFT',   -- [ LEFT ARROW ]  the previous location
            next   = 'RIGHT',  -- [ RIGHT ARROW ] the next location
        },
        promptPosition = 'bottom-right',
        labels = {
            title        = 'مكان الظهور',
            select       = 'الظهور هنا',
            prev         = 'السابق',
            next         = 'التالي',
            lastPosition = 'آخر موقع كنت فيه',
            lastRegion   = 'حيث غادرت آخر مرّة',
        },
    },

    -- The selector's aerial camera around a location; a point can override any value with cam = {...}.
    camera = {
        dist   = 110.0, -- horizontal distance from the location (metres)
        height = 55.0,  -- height above it (metres)
        angle  = 135.0, -- starting orbit angle (degrees)
        fov    = 50.0,
        orbit  = 1.5,   -- slow rotation (degrees/second). 0 stops it.
    },

    -- The character's last saved position (read from the framework, never written here).
    lastLocation = {
        -- Mirrors Config.Services.lastLocation (the service toggle is the authority).
        enabled = Config.Services.lastLocation,
        -- Shown first and preselected in the selector for an existing character.
        preselect = true,
    },

    -- Correct the spawn height onto the ground after the move (the Z values below are approximate).
    snapToGround = true,

    -- World bounds: a last location outside them is rejected (falls back to the first enabled point,
    -- lowest order first).
    bounds = { minX = -8000.0, maxX = 5000.0, minY = -6000.0, maxY = 3000.0, minZ = -150.0, maxZ = 1500.0 },

    -- A last location within this radius of the creator scene anchor is rejected.
    sceneExclusionRadius = 150.0,

    -- -----------------------------------------------------------------
    --  The spawn points
    --  id       a fixed identifier - the only thing the client sends
    --  label    the town's name, region its area (dictionary keys)
    --  coords   the spawn point and the camera's target
    --  heading  the player's heading on spawning
    --  cam      optional: overrides Config.Spawn.camera { dist=, height=, angle=, fov=, orbit= }
    --  enabled  false hides the point and the server refuses it
    --  order    display order in the selector
    -- -----------------------------------------------------------------
    points = {
        { id = 'valentine',  label = 'فالنتاين',   region = 'الأراضي الوسطى، نيو هانوفر', enabled = true, order = 1,
          coords = vector3(-274.09, 785.36, 119.29),   heading = 90.0 },

        { id = 'saintdenis', label = 'سانت دينيس', region = 'باييو نوا، ليمويّه', enabled = true, order = 2,
          coords = vector3(2645.11, -1214.66, 52.50),  heading = 180.0 },

        { id = 'rhodes',     label = 'رودز',       region = 'سكارليت ميدوز، ليمويّه', enabled = true, order = 3,
          coords = vector3(1233.28, -1299.24, 76.90),  heading = 0.0 },

        { id = 'blackwater', label = 'بلاك ووتر',  region = 'غريت بلينز، غرب إليزابيث', enabled = true, order = 4,
          coords = vector3(-871.71, -1348.29, 43.60),  heading = 90.0 },

        { id = 'strawberry', label = 'ستروبيري',   region = 'بيغ فالي، غرب إليزابيث', enabled = true, order = 5,
          coords = vector3(-1789.00, -389.00, 156.00), heading = 180.0 },

        { id = 'armadillo',  label = 'أرماديلو',   region = 'تشولا سبرينغز، نيو أوستن', enabled = true, order = 6,
          coords = vector3(-3688.00, -2606.00, -14.00), heading = 270.0 },

        { id = 'tumbleweed', label = 'تمبلويد',    region = 'غابتوث ريدج، نيو أوستن', enabled = true, order = 7,
          coords = vector3(-5518.00, -2938.00, -2.00), heading = 0.0 },

        { id = 'vanhorn',    label = 'فان هورن',   region = 'روانوك ريدج، نيو هانوفر', enabled = true, order = 8,
          coords = vector3(2941.00, 553.00, 44.00),    heading = 180.0 },

        { id = 'annesburg',  label = 'آنسبرغ',     region = 'روانوك ريدج، نيو هانوفر', enabled = true, order = 9,
          coords = vector3(2931.00, 1355.00, 44.00),   heading = 180.0 },
    },
}

-- ---------------------------------------------------------------------
--  Death respawn (§12). Resurrection goes through exports.w_creators:Resurrect.
-- ---------------------------------------------------------------------
Config.Respawn = {
    restoreAppearance = true,   -- re-apply the saved appearance after any resurrect
    pollMs = 250,               -- the state machine's poll interval (not every frame)
    resurrectTimeoutMs = 10000, -- how long to wait for the new ped after a resurrect
}
