Config = {}

Config.EnableCutscene = false -- // turn it on if you have a first-spawn wagon scene
-- The default first-time spawn point (Valentine).
-- Used for a new character, and as a fallback when there is no saved position.
-- See the 'spawn system' section at the end of the file for the rest of the settings.
Config.FirstSpawnCoords = vector3(-274.09, 785.36, 119.29)
Config.FirstSpawnHeading = 90.0

-- =====================================================================
--  Framework compatibility
-- =====================================================================
-- The framework in use. 'auto' detects it automatically, or set it by hand:
--   'vorp' | 'rsg' | 'qbr'
Config.Framework = 'auto'

-- Setting the hunger/thirst automatically after the character is created (it works with rsg/qbr only, and is safely ignored elsewhere)
Config.SetSurvivalMetadata = true

-- The spawn event after the creation:
--   Leave it nil to use the built-in spawn (moving the player to Config.FirstSpawnCoords).
--   Or put the name of your framework's own spawn event, for instance: 'rsg-multicharacter:client:spawnDefault'
Config.SpawnEvent = nil

-- =====================================================================
--  The built-in multicharacter (standalone)
-- =====================================================================
-- When it is on the resource becomes a complete replacement for the multicharacter and spawn script:
-- it shows the character selection screen, registers the new character officially in the framework,
-- then spawns the player. Stop the original multicharacter script when you turn it on.
Config.Multicharacter = true

-- The number of character slots per player
Config.CharacterSlots = 3

-- Allowing characters to be deleted from the selection screen
Config.EnableDelete = true

-- The coordinates of the character preview spot in the selection screen and its camera
--   {x, y, z, heading}
-- ═════════════════════════════════════════════════════════════════════
--  The creator's scene - vorp_character's original coordinates
--  The source: [VORP]/vorp_character/client/functions.lua and createCharacter.lua
-- ═════════════════════════════════════════════════════════════════════

-- The room's maps (IPL). Mandatory: without them the place has no geometry so the screen shows black.
-- VORP requests them with RequestIplByHash guarded by IsIplActiveByHash - not RequestImap.
Config.SceneImaps = { 183712523, -1699673416, 1679934574 }

-- The loading sphere VORP uses to force the room's streaming { x, y, z, range, seconds }
Config.SceneLoadSphere = { -561.4, -3782.6, 237.6, 50.0, 20 }

-- The player's anchor inside the room (vorp: StartPlayerTeleport) { x, y, z, heading }
Config.SceneAnchor = { -561.22, -3776.26, 239.16, 93.2 }

-- The two genders' ped positions in the creation scene (vorp: functions.lua:214,221)
Config.ScenePeds = {
    { -558.52, -3775.6,  237.7, 93.2 }, -- male
    { -558.43, -3776.65, 237.7, 93.2 }, -- female
}

-- The scene's lights { x, y, z, intensity, range } - the room is interior and dark without them.
Config.SceneLights = {
    { -561.860, -3776.757, 238.590, 10.000, 50.000 },
    { -559.590, -3780.757, 238.590, 10.000, 50.000 },
}

-- Core body-part defaults are defined once in data/appearance.lua.

-- The preview ped's standing scenarios - one is picked at random each time.
-- A scenario and not TaskPlayAnim: this is what vorp_character uses for the selection screen's
-- peds (client.lua:428) and it is steadier, since the engine runs the loop itself.
Config.SceneScenarios = {
    male = {
        'WORLD_HUMAN_SMOKE_CARRYING',
        'MP_LOBBY_SCENARIO_08',
        'MP_LOBBY_SCENARIO_02',
    },
    female = {
        'WORLD_HUMAN_SMOKE_CARRYING',
        'MP_LOBBY_SCENARIO_08',
        'MP_LOBBY_SCENARIO_02',
    },
}

-- The scene ped's weapon: a revolver in the holster, not a weapon in the hand. The default
-- outfit puts on an empty holster, so the belt looks incomplete. We give it the revolver
-- holstered (with no forcing it into the hand) so the holster fills and the body is not hidden from the preview.
-- Cosmetic only: the scene ped cannot be targeted and is deleted with the scene.
Config.SceneWeapon = {
    enabled = true,
    male    = 'WEAPON_REVOLVER_CATTLEMAN',
    female  = 'WEAPON_REVOLVER_CATTLEMAN',
    ammo    = 6, -- a full cylinder: some builds do not equip the weapon with zero ammunition
}

-- The radius for cleaning up stuck peds around the scene (metres)
Config.SceneCleanupRadius = 25.0

-- Keep the editing pose inside the visible selection room. The former south
-- position (-3781.13) is behind the room's wall/portal and hides the actor.
Config.EditingPed = { -558.52, -3775.6, 237.7, 93.2 }
-- Selection camera framing follows this actor through modules/camera.lua.
Config.SelectionPed = { -558.52, -3775.6, 237.7, 93.2 }

-- =====================================================================
--  The texts
--  Every label below is a dictionary key: the Arabic source text, translated by locales/en.json
--  through locale(). The language itself is the library's (w.getLocaleKey): the player's choice
--  in /w_lib or the server convar w_lib:locale - the resource keeps no language setting of its own.
-- =====================================================================

-- The selection screen's buttons. The same keys as vorp_character, but as keyboard key
-- names because the NUI prompt reads the VK directly (w_lib/modules/rawKeys/vk_qwerty.lua)
-- and not the RDR control hashes.
Config.SelectionKeys = {
    select = 'RETURN', -- [ ENTER ]      enter the game / create a character
    delete = 'DELETE', -- [ DELETE ]     delete (with a long press)
    prev   = 'LEFT',   -- [ LEFT ARROW ] the previous character
    next   = 'RIGHT',  -- [ RIGHT ARROW ] the next character
}

-- The prompt panel's position on the screen:
-- 'bottom-right' | 'center-right' | 'top-right' | 'bottom-left' | 'center-left' | 'top-left'
Config.SelectionPromptPosition = 'bottom-right'

-- The long-press duration for deleting a character (milliseconds). VORP uses 5000.
Config.DeleteHoldTime = 5000

-- The selection screen's texts (dictionary keys)
Config.SelectionLabels = {
    title       = 'اختيار الشخصية',
    emptySlot   = 'خانة فارغة — إنشاء شخصية',
    select      = 'دخول',
    prev        = 'السابق',
    next        = 'التالي',
    delete      = 'حذف',
    deleteHeader= 'حذف الشخصية',
    deleteBody  = 'هل أنت متأكد من حذف "%s"؟ لا يمكن التراجع — تُحذف الشخصية وأموالها وممتلكاتها نهائيًا.',
}

-- The database table names per framework (change them only if they differ on your server)
Config.CharactersTable = {
    vorp = 'characters', -- the identifier column: identifier / the character id column: charidentifier
    rsg  = 'players',    -- the identifier column: license   / the character id column: citizenid
    qbr  = 'players',    -- the identifier column: license   / the character id column: citizenid
}

-- The gender selection prompt (instead of the text at the top: the text does not make the keys clear)
Config.GenderPrompt = {
    position = 'bottom-right',
    title    = 'اختيار الشخصية',
    prev     = { key = 'LEFT',   label = 'ذكر' },
    next     = { key = 'RIGHT',  label = 'أنثى' },
    accept   = { key = 'RETURN', label = 'تأكيد' },
    -- Going back to the characters screen: complete freedom for whoever picked the wrong slot
    back     = { key = 'BACK',   label = 'رجوع' },
}

-- =====================================================================
--  The spawn system
--  Two systems governed by one key: Config.SpawnSelector
--
--  [1] off (false) - the default system:
--        a new character -> Config.FirstSpawnCoords (Valentine)
--        an existing character -> the last coordinate the framework saved for it, and if there is none
--                       then FirstSpawnCoords.
--        VORP saves the position in characters.coords on disconnect and on the periodic
--        save (vorp_core/server/class/user.lua:317) - we read it, we do not write it.
--
--  [2] on (true) - the cinematic location selection screen:
--        the camera flies over every town and the player moves with the prompts and confirms.
--        An existing character sees 'the last place you were' first and preselected,
--        so whoever presses ENTER straight away goes back to his place as usual.
-- =====================================================================
Config.SpawnSelector = true

-- Showing the 'the last place you were' option for an existing character (at the top of the list).
-- Make it false to force everyone to pick a town on every login.
Config.SpawnLastOption = true

-- Correcting the spawn height onto the ground after the move.
-- The Z coordinates below are approximate; this stops a spawn underground or hanging above it.
Config.SpawnSnapToGround = true

-- The fade duration between one location and another (milliseconds).
-- The transition is by a fade and not by a camera move: the focus shifts to the new town so the old
-- one begins to fall apart into grey blocks, and the blackness hides that instead of showing it.
Config.SpawnTransition = 350

-- The aerial camera around every location. The position is computed from the location's own coordinates
-- (a distance + a height + an angle) and the camera is pointed at it with PointCamAtCoord, so the
-- framing is right whatever the town is. Every location can override any value through the cam field.
Config.SpawnCamDefaults = {
    dist   = 110.0, -- the camera's horizontal distance from the location's centre (metres)
    height = 55.0,  -- its height above it (metres)
    angle  = 135.0, -- the starting orbit angle (degrees)
    fov    = 50.0,
    orbit  = 1.5,   -- a slow rotation around the location (degrees/second). 0 stops it.
}

-- How long to wait for the area to load before showing it (milliseconds).
-- Without it the town appears as grey blocks with no buildings in the first moment.
Config.SpawnSceneTimeout = 8000

-- =====================================================================
--  The spawn locations
--  id       a fixed identifier - it alone is what the client sends, and the server translates it into
--           coordinates from this table. No coordinate ever arrives from the client.
--  label    the town's name and region: dictionary keys (Arabic source texts)
--  coords   the location's centre (the spawn point and the camera's target together)
--  heading  the player's heading on spawning
--  cam      optional: { dist=, height=, angle=, fov=, orbit= } to override the default
--
--  Note: the coordinates are approximate and set on the town centres. Change them to suit
--  your server, and Config.SpawnSnapToGround takes care of correcting the height.
-- =====================================================================
Config.SpawnPoints = {
    { id = 'valentine',  label = 'فالنتاين',    region = 'الأراضي الوسطى، نيو هانوفر',
      coords = vector3(-274.09, 785.36, 119.29),   heading = 90.0 },

    { id = 'saintdenis', label = 'سانت دينيس',  region = 'باييو نوا، ليمويّه',
      coords = vector3(2645.11, -1214.66, 52.50),  heading = 180.0 },

    { id = 'rhodes',     label = 'رودز',        region = 'سكارليت ميدوز، ليمويّه',
      coords = vector3(1233.28, -1299.24, 76.90),  heading = 0.0 },

    { id = 'blackwater', label = 'بلاك ووتر',   region = 'غريت بلينز، غرب إليزابيث',
      coords = vector3(-871.71, -1348.29, 43.60),  heading = 90.0 },

    { id = 'strawberry', label = 'ستروبيري',    region = 'بيغ فالي، غرب إليزابيث',
      coords = vector3(-1789.00, -389.00, 156.00), heading = 180.0 },

    { id = 'armadillo',  label = 'أرماديلو',    region = 'تشولا سبرينغز، نيو أوستن',
      coords = vector3(-3688.00, -2606.00, -14.00), heading = 270.0 },

    { id = 'tumbleweed', label = 'تمبلويد',     region = 'غابتوث ريدج، نيو أوستن',
      coords = vector3(-5518.00, -2938.00, -2.00), heading = 0.0 },

    { id = 'vanhorn',    label = 'فان هورن',    region = 'روانوك ريدج، نيو هانوفر',
      coords = vector3(2941.00, 553.00, 44.00),    heading = 180.0 },

    { id = 'annesburg',  label = 'آنسبرغ',      region = 'روانوك ريدج، نيو هانوفر',
      coords = vector3(2931.00, 1355.00, 44.00),   heading = 180.0 },
}

-- The location selection screen's keys (the same logic as Config.SelectionKeys: keyboard key
-- names because the NUI prompt reads the VK directly)
Config.SpawnSelectKeys = {
    select = 'RETURN', -- [ ENTER ]       spawn here
    prev   = 'LEFT',   -- [ LEFT ARROW ]  the previous location
    next   = 'RIGHT',  -- [ RIGHT ARROW ] the next location
}

Config.SpawnSelectPromptPosition = 'bottom-right'

-- The location selection screen's texts (dictionary keys)
Config.SpawnSelectLabels = {
    title        = 'مكان الظهور',
    select       = 'الظهور هنا',
    prev         = 'السابق',
    next         = 'التالي',
    lastPosition = 'آخر موقع كنت فيه',
    lastRegion   = 'حيث غادرت آخر مرّة',
}
