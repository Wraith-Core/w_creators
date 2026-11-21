-- =====================================================================
--  config/main.lua
--  Global switches, the character lifecycle and the creator scene.
--  Every player-visible string below is a dictionary key: the Arabic source text, translated
--  by locales/en.json through locale(). The language itself is the library's (w.getLocaleKey).
--  This file is loaded first: the other config/*.lua files extend the tables created here.
-- =====================================================================

Config = {}
Config.Barber = {}   -- moved to standalone resource w_barber
Config.Wardrobe = {} -- moved to standalone resource w_clothing

-- ---------------------------------------------------------------------
--  Debug output (WCDebug.log). Silent unless enabled.
--  domains: { appearance = true, sessions = true, ... } limits the output to those domains;
--  an empty table means every domain.
--
--  Off by default, as the line above says. With domains = {} an enabled switch means EVERY
--  domain speaks, which on a live server is console noise on every boot, and debug lines carry
--  player identifiers. Turn it on while working on the resource.
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
    clothingStores    = false, -- moved to standalone resource w_clothing
    barbers           = false, -- moved to standalone resource w_barber
    surgery           = true,
    wardrobe          = false, -- moved to standalone resource w_clothing
    savedOutfits      = false, -- moved to standalone resource w_clothing
    clothingActions   = false, -- moved to standalone resource w_clothing
    spawnSelector     = true,
    lastLocation      = true,
    deathRespawn      = true,
}

-- ---------------------------------------------------------------------
--  Characters (multicharacter, identity, deletion)
-- ---------------------------------------------------------------------
Config.Characters = {
    -- Character slots per account.
    -- owner 2026-11-06: ONE character per person, VIP included (no VIP slot, no store slot any more).
    defaultSlots = 1,
    -- Extra slots by ACE permission: { ['w_creators.slots.x'] = 2 }. The highest granted value wins.
    -- Empty since 2026-11-06 (it held the VIP's 4).
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

    -- The gender selection prompt of the creator. Picking a side opens the editor on that
    -- character at once (LEFT = the man, RIGHT = the woman): there is no separate confirm step, so
    -- `accept` is kept only so older configs still load, and is not shown or read any more.
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

    -- A new character's eyebrows take the colour of the hair (re-read whenever the hair changes).
    -- The player can turn it off in the eyebrows panel; the colour chosen there comes back then.
    eyebrowsFollowHair = true,
    -- Offer a custom eye tint (the game's eye palette, 3 tints) on top of the eye colour.
    customEyeColor = true,
    -- Depth sliders (the jaw's depth, the ears' angle...) turn the character to its profile while
    -- they are moved: a depth cannot be judged from the front. The character turns back afterwards.
    profileTurn = true,
    -- The height slider reads as the character's real height, measured on the ped: 'm' (metres),
    -- 'ft' (feet) or false (the bare scale ×100, as before).
    heightUnit = 'm',
    -- The teeth view opens the mouth with the game's own "dentistry" face clips; nil turns it off.
    teethAnimation = {
        dict  = 'FACE_HUMAN@GEN_MALE@BASE',
        enter = 'Face_Dentistry_In',
        loop  = 'Face_Dentistry_Loop',
        exit  = 'Face_Dentistry_Out',
    },
}

-- ---------------------------------------------------------------------
--  Colour chips drawn next to a choice (our own approximations of how each value looks in game).
--  skinOrder is the order the six skin tones are offered in: lightest first. The game numbers the
--  tones 1..6 but not by shade (tone 2 is one of the darkest), so the list is re-ordered.
-- ---------------------------------------------------------------------
Config.Swatches = {
    skinOrder = { 1, 4, 3, 5, 2, 6 },
    skin = {
        [1] = '#f1d3b8', [4] = '#dcb08b', [3] = '#c38c62', [5] = '#9e6a45', [2] = '#76492d', [6] = '#4a2d1c',
    },
    -- hair / beard colour suffix (the asset name's last part) -> chip colour
    hair = {
        BLONDE = '#b58d4c', LIGHT_BLONDE = '#d8bc7d', DARK_BLONDE = '#8c6834', STRAWBERRY_BLONDE = '#c0835a',
        BROWN = '#5b3b23', LIGHT_BROWN = '#7b5332', MEDIUM_BROWN = '#4a2e1b', DARKEST_BROWN = '#2a1a10',
        GINGER = '#a3522a', LIGHT_GINGER = '#c17040', DARK_GINGER = '#793a1e',
        GREY = '#8c8985', LIGHT_GREY = '#bab7b2', DARK_GREY = '#5a5855', UNCLE_GREY = '#a8a8ad',
        SALT_PEPPER = '#6e6b67', JET_BLACK = '#151313',
    },
}

-- ---------------------------------------------------------------------
--  The creator scene: the Saint Denis theatre stage (the Jump On creator's places)
--  Both characters stand side by side on the stage, 2 m apart, facing the stalls; the camera starts
--  on the pair and glides to whichever the player picks. The selection screen uses the same room.
--  The previous room (vorp_character's floating studio) for reference:
--    imaps = { 183712523, -1699673416, 1679934574 }, loadSphere = { -561.4, -3782.6, 237.6, 50.0, 20 },
--    anchor = { -561.22, -3776.26, 239.16, 93.2 }, peds.male = { -558.52, -3775.6, 237.7, 93.2 },
--    peds.female = { -558.43, -3776.65, 237.7, 93.2 }, timecycle = 'Online_Character_Editor'
-- ---------------------------------------------------------------------
Config.Scene = {
    -- The room's maps (IPL). The theatre is a regular interior of the world: none are needed.
    imaps = {},
    -- Wait until the interior at the anchor is streamed and ready before the scene shows (an
    -- interior that is not ready yet renders as an empty shell).
    interior = true,
    -- The loading sphere that forces the room's streaming { x, y, z, range, seconds }: on the pair.
    loadSphere = { 2546.0, -1309.95, 48.0, 50.0, 20 },
    -- The player's anchor inside the room { x, y, z, heading } (hidden and frozen there)
    anchor = { 2542.655, -1305.585, 48.014, 192.761 },
    -- The two genders' ped positions in the gender scene { x, y, z, heading }
    peds = {
        male   = { 2547.0, -1310.0, 48.0, 358.732 },
        female = { 2545.0, -1309.9, 48.0, 358.337 },
    },
    -- The clock while the scene shows { hour, minute } (false = the world's time) and the
    -- timecycle modifier (false = none: the theatre is lit by the lights below).
    clock = { 10, 0 },
    timecycle = false,
    -- Ambient life in the scene: false keeps passers-by, carts and scenario peds out of the shot
    -- (Saint Denis is busy), true leaves the town as it is.
    ambient = false,
    -- The stage lights, drawn every frame while the scene shows.
    --   { at = 'male' | 'female' | 'pair', offset = { right, forward, up }, range, intensity, color = { r, g, b } }
    --     placed relative to a ped spot (its heading turns the offset; 'pair' is the middle of both),
    --     so moving the spots above moves the lights with them;
    --   or an absolute light { x, y, z, range, intensity[, r, g, b] }. Colour defaults to white.
    lights = {
        { at = 'male',   offset = { 0.0, 1.0, 0.5 },  range = 4.0,  intensity = 1500.0 },                          -- key
        { at = 'female', offset = { 0.0, 1.0, 0.5 },  range = 4.0,  intensity = 1500.0 },                          -- key
        { at = 'pair',   offset = { 0.0, 1.0, 2.5 },  range = 15.0, intensity = 500.0, color = { 255, 204, 153 } }, -- warm fill
        { at = 'male',   offset = { 0.3, 1.0, 0.0 },  range = 2.0,  intensity = 1500.0, color = { 255, 0, 0 } },    -- red rim
        { at = 'female', offset = { -0.3, 1.0, 0.0 }, range = 2.0,  intensity = 1500.0, color = { 255, 0, 0 } },    -- red rim
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
    -- Stuck-ped cleanup radius around the anchor (metres); also "the player is still in the room"
    cleanupRadius = 25.0,
    -- nil = the picked character is edited where it stands. A { x, y, z, heading } moves it there
    -- first (the old single editing spot).
    editingPed = nil,
    -- Hide the other character while one is edited: the full-body shot is about 4 m wide, so a
    -- neighbour 2 m away would stand half in frame.
    hideOtherWhileEditing = true,
    -- The gender scene's cameras. pair frames both characters from the middle of their two spots:
    -- distance metres in front of them (along their heading), height above their origin, fov.
    -- pair.coords / pair.target ({ x, y, z }) place it absolutely instead.
    -- glideMs is the camera glide between the pair and the picked character.
    cameras = {
        pair = { distance = 4.0, height = 0.0, fov = 45.0 },
        glideMs = 1000,
    },
    -- The selection screen's preview ped { x, y, z, heading }: the man's spot of the same stage
    selectionPed = { 2547.0, -1310.0, 48.0, 358.732 },
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
    -- Short animations for clothing state changes (Config.ClothingStates.animations). ON: every clip
    -- is the game's own, checked against the full RDR3 animation list; a clip the game lacks is skipped
    -- and the state still changes. Read by client/clothing/states.lua.
    clothingAnimations = true,
    -- Unlocks the unconfirmed variation preset wrapper (0xFFA1594703ED27CA,
    -- WCNative.metaped.setVariationPreset). Research only: no production path calls it.
    variationPreset = false,
}

-- ---------------------------------------------------------------------
--  Keys shared by the service prompts
-- ---------------------------------------------------------------------
Config.Keys = {
    interact = 'J', -- opens a shop / barber / wardrobe (not E: E grabs the player next to you)
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
