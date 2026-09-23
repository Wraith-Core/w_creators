-- =====================================================================
--  config/main.lua
--  Global switches, the character lifecycle and the creator scene.
--  Every player-visible string below is a dictionary key: the Arabic source text, translated
--  by locales/en.json through locale(). The language itself is the library's (w.getLocaleKey).
--  This file is loaded first: the other config/*.lua files extend the tables created here.
-- =====================================================================

Config = {}

-- ---------------------------------------------------------------------
--  Debug output (WCDebug.log). Silent unless enabled.
--  domains: { appearance = true, sessions = true, ... } limits the output to those domains;
--  an empty table means every domain.
-- ---------------------------------------------------------------------
Config.Debug = {
    enabled = false,
    domains = {},
}

-- The framework in use. 'auto' detects it automatically, or set it by hand: 'vorp' | 'rsg' | 'qbr'
Config.Framework = 'auto'

-- ---------------------------------------------------------------------
--  Service toggles (ARCHITECTURE.md §7.1). A disabled service shows no prompts, no blips and
--  no NPCs, and every server callback of that service answers *_DISABLED / SERVICE_DISABLED.
-- ---------------------------------------------------------------------
Config.Services = {
    characterCreation = true,
    characterDeletion = true,
    clothingStores    = true,
    barbers           = true,
    surgery           = true,
    wardrobe          = true,
    savedOutfits      = true,
    clothingActions   = true,
    spawnSelector     = true,
    lastLocation      = true,
    deathRespawn      = true,
}

-- ---------------------------------------------------------------------
--  Characters (multicharacter, identity, deletion)
-- ---------------------------------------------------------------------
Config.Characters = {
    -- Character slots per account.
    defaultSlots = 3,
    -- Extra slots by ACE permission: { ['w_creators.slots.vip'] = 5 }. The highest granted value wins.
    slotPermissions = {},
    -- Switching characters mid-game (/characters). Refused while dead, in an editor or in a session.
    allowSwitch = true,

    -- enabled mirrors Config.Services.characterDeletion: deletion is allowed only when both are on.
    deletion = {
        enabled = true,
        holdTime = 5000,           -- long-press duration on the selection screen (ms). VORP uses 5000.
        typedConfirmation = false, -- true: the player must type the character's name to delete it
    },

    -- Identity validation (ARCHITECTURE.md §6.3). referenceYear = nil uses the current real date;
    -- set it (e.g. 1899) to validate ages against the in-game year.
    identity = {
        minAge = 18,
        maxAge = 90,
        referenceYear = nil,
        nameMin = 2,
        nameMax = 25,
    },

    -- The framework character tables (change them only if they differ on your server)
    tables = {
        vorp = 'characters', -- identifier column: identifier / character id column: charidentifier
        rsg  = 'players',    -- identifier column: license   / character id column: citizenid
        qbr  = 'players',    -- identifier column: license   / character id column: citizenid
    },

    -- The selection screen. Keys are keyboard key names: the NUI prompt reads the VK directly
    -- (w_lib/modules/rawKeys/vk_qwerty.lua) and not the RDR control hashes.
    selection = {
        keys = {
            select = 'RETURN', -- [ ENTER ]       enter the game / create a character
            delete = 'DELETE', -- [ DELETE ]      delete (with a long press)
            prev   = 'LEFT',   -- [ LEFT ARROW ]  the previous character
            next   = 'RIGHT',  -- [ RIGHT ARROW ] the next character
        },
        -- 'bottom-right' | 'center-right' | 'top-right' | 'bottom-left' | 'center-left' | 'top-left'
        promptPosition = 'bottom-right',
        labels = {
            title        = 'اختيار الشخصية',
            emptySlot    = 'خانة فارغة — إنشاء شخصية',
            select       = 'دخول',
            prev         = 'السابق',
            next         = 'التالي',
            delete       = 'حذف',
            deleteHeader = 'حذف الشخصية',
            deleteBody   = 'هل أنت متأكد من حذف "%s"؟ لا يمكن التراجع — تُحذف الشخصية وأموالها وممتلكاتها نهائيًا.',
        },
    },

    -- The gender selection prompt of the creator
    genderPrompt = {
        position = 'bottom-right',
        title    = 'اختيار الشخصية',
        prev     = { key = 'LEFT',   label = 'ذكر' },
        next     = { key = 'RIGHT',  label = 'أنثى' },
        accept   = { key = 'RETURN', label = 'تأكيد' },
        back     = { key = 'BACK',   label = 'رجوع' },
    },

    -- Hunger/thirst set after creation (rsg/qbr only; safely ignored elsewhere)
    setSurvivalMetadata = true,
}

-- ---------------------------------------------------------------------
--  The creator
-- ---------------------------------------------------------------------
Config.Creator = {
    -- The optional first-spawn wagon scene (client/creator/cutscene.lua). The spawn module raises
    -- W:CREATOR:FirstSpawn for a new character's first spawn when this is on.
    enableCutscene = false,
    -- The wagon scene. Any field may be changed or left out (the built-in value is used then);
    -- coordinates may be { x, y, z[, heading] } or vector3 / vector4.
    cutscene = {
        start          = { 2520.09, -358.05, 41.61, 268.89169 }, -- the wagon and the player start here
        arrival        = { 2539.83, -1129.33, 50.03 },           -- Saint Denis: the ride ends here
        departure      = { 2600.436, -1205.932, 53.323 },        -- the driver takes the empty wagon here
        wagon          = 'STAGECOACH001X',
        driver         = 'CS_BivCoachDriver',
        arriveRadius   = 5.0,
        speed          = 10.0,
        drivingStyle   = 67633207,
        maxDuration    = 600000, -- ms; a wagon that never arrives: the player is placed at the arrival
        departureDelay = 10000,  -- ms the empty wagon drives off before it is removed
    },
    -- nil = the built-in spawn. Or your framework's own spawn event, e.g. 'rsg-multicharacter:client:spawnDefault'.
    -- The server fires it on EVERY spawn (login, switch, first spawn). Never set it to
    -- 'W:CREATOR:FirstSpawn' (the cutscene event): every existing character would take the ride.
    spawnEvent = nil,
    -- The wizard stages, in order. facialHair is shown to male characters only.
    stages = { 'identity', 'body', 'face', 'skin', 'hair', 'facialHair', 'makeup', 'clothing', 'review' },
    -- startingClothing lives in config/outfits.lua
}

-- ---------------------------------------------------------------------
--  The creator scene — vorp_character's original coordinates
--  Source: [VORP]/vorp_character/client/functions.lua and createCharacter.lua
-- ---------------------------------------------------------------------
Config.Scene = {
    -- The room's maps (IPL). Without them the room has no geometry and the screen stays black.
    imaps = { 183712523, -1699673416, 1679934574 },
    -- The loading sphere that forces the room's streaming { x, y, z, range, seconds }
    loadSphere = { -561.4, -3782.6, 237.6, 50.0, 20 },
    -- The player's anchor inside the room { x, y, z, heading }
    anchor = { -561.22, -3776.26, 239.16, 93.2 },
    -- The two genders' ped positions in the gender scene
    peds = {
        male   = { -558.52, -3775.6,  237.7, 93.2 },
        female = { -558.43, -3776.65, 237.7, 93.2 },
    },
    -- The room lights { x, y, z, intensity, range }
    lights = {
        { -561.860, -3776.757, 238.590, 10.000, 50.000 },
        { -559.590, -3780.757, 238.590, 10.000, 50.000 },
    },
    -- The preview ped's standing scenarios - one is picked at random each time.
    scenarios = {
        male   = { 'WORLD_HUMAN_SMOKE_CARRYING', 'MP_LOBBY_SCENARIO_08', 'MP_LOBBY_SCENARIO_02' },
        female = { 'WORLD_HUMAN_SMOKE_CARRYING', 'MP_LOBBY_SCENARIO_08', 'MP_LOBBY_SCENARIO_02' },
    },
    -- The preview ped's holstered revolver (cosmetic; the preview ped is deleted with the scene)
    weapon = {
        enabled = true,
        male    = 'WEAPON_REVOLVER_CATTLEMAN',
        female  = 'WEAPON_REVOLVER_CATTLEMAN',
        ammo    = 6,
    },
    -- Stuck-ped cleanup radius around the anchor (metres)
    cleanupRadius = 25.0,
    -- The editing pose inside the visible room { x, y, z, heading }
    editingPed = { -558.52, -3775.6, 237.7, 93.2 },
    -- The selection screen's preview ped { x, y, z, heading }
    selectionPed = { -558.52, -3775.6, 237.7, 93.2 },
}

-- ---------------------------------------------------------------------
--  Research features (docs/NATIVES.md). Default off unless stated.
--  Only clothingAnimations changes gameplay. The other flags only unlock a research wrapper in
--  client/natives/ (it returns nil/false while its flag is off); no production path calls those
--  wrappers, so turning them on changes nothing in game by itself.
-- ---------------------------------------------------------------------
Config.Experimental = {
    -- Unlocks the MetaPed asset request wrappers (WCNative.metaped.requestPed / createPed / ...).
    -- Research only: no production path calls them; preview peds are always created by model.
    metapedRequestPath = false,
    -- Unlocks the _SET_PLAYER_HAT_ACCESS wrapper (WCNative.clothing.setHatAccess). Research only:
    -- no production path calls it; the hat state always removes and re-applies the hat hash.
    hatAccess = false,
    -- Short animations for clothing state changes (Config.ClothingStates.animations: research-only
    -- clip names, not verified on every build). Read by client/clothing/states.lua.
    clothingAnimations = false,
    -- Unlocks the unconfirmed variation preset wrapper (0xFFA1594703ED27CA,
    -- WCNative.metaped.setVariationPreset). Research only: no production path calls it.
    variationPreset = false,
}

-- ---------------------------------------------------------------------
--  Keys shared by the service prompts
-- ---------------------------------------------------------------------
Config.Keys = {
    interact = 'E', -- opens a shop / barber / wardrobe
    -- The default key of the clothing actions keybind (wc_clothing_actions; players can rebind it in
    -- the game settings). A key name such as 'K'; nil = unbound (the /clothing command still works).
    clothingActions = nil,
}

-- ---------------------------------------------------------------------
--  Administration. Dev tools and the prop spawner are off in production.
-- ---------------------------------------------------------------------
Config.Admin = {
    spawnProp = false,
    devTools  = false,
    ace       = 'w_creators.admin',
    devAce    = 'w_creators.dev',
}
