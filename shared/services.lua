-- =====================================================================
--  shared/services.lua  —  WCServices (ARCHITECTURE.md §7.1)
--  A disabled service: no prompts, no blips, no NPCs, and every server callback of that service
--  answers its *_DISABLED code (or SERVICE_DISABLED).
-- =====================================================================

WCServices = {}

WCServices.names = {
    'characterCreation', 'characterDeletion', 'clothingStores', 'barbers', 'surgery', 'wardrobe',
    'savedOutfits', 'clothingActions', 'spawnSelector', 'lastLocation', 'deathRespawn',
}

-- service -> the Result code of a refused request
local CODES = {
    characterCreation = 'CREATION_DISABLED',
    characterDeletion = 'DELETE_DISABLED',
    clothingStores    = 'STORE_DISABLED',
    barbers           = 'BARBER_DISABLED',
    surgery           = 'SURGERY_DISABLED',
    wardrobe          = 'WARDROBE_DISABLED',
    savedOutfits      = 'OUTFITS_DISABLED',
    clothingActions   = 'ACTIONS_DISABLED',
}

-- location type -> service
local BY_LOCATION_TYPE = {
    clothing = 'clothingStores',
    barber   = 'barbers',
    surgery  = 'surgery',
    wardrobe = 'wardrobe',
}

-- Services that a second config switch can also turn off (both must be on).
local SECOND_SWITCH = {
    surgery = function() return Config.CosmeticSurgery and Config.CosmeticSurgery.enabled end,
    characterDeletion = function()
        return Config.Characters and Config.Characters.deletion and Config.Characters.deletion.enabled
    end,
}

--- Is the named service enabled? Unknown names -> false.
--  surgery also needs Config.CosmeticSurgery.enabled, characterDeletion also needs
--  Config.Characters.deletion.enabled (a missing switch counts as on).
function WCServices.enabled(name)
    local services = Config and Config.Services
    if type(services) ~= 'table' or type(name) ~= 'string' then return false end
    local second = SECOND_SWITCH[name]
    if second and second() == false then return false end
    return services[name] == true
end

--- The Result code for a disabled service (SERVICE_DISABLED when it has no specific code).
function WCServices.code(name)
    return CODES[name] or 'SERVICE_DISABLED'
end

--- The service that governs a location type ('clothing' -> 'clothingStores'), or nil.
function WCServices.forLocationType(locationType)
    return BY_LOCATION_TYPE[locationType]
end
