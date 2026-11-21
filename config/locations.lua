-- =====================================================================
--  config/locations.lua
--  Every service location (ARCHITECTURE.md §7.2). Adding a shop is a config edit only.
--
--  A location = Config.LocationDefaults[type] merged with its own fields (its own fields win):
--    id                a fixed identifier - the only thing the client ever sends
--    type              'clothing' | 'barber' | 'surgery' | 'wardrobe'
--    enabled           false hides the location and makes the server refuse it (LOCATION_DISABLED)
--    label, town       dictionary keys
--    coords            vector3: the interaction point (prompt + server proximity anchor)
--    interactionRadius metres; the server allows interactionRadius + 3
--    npc               { model, coords = vector4 } | false
--    blip              { sprite, label } | false
--    prompt            false = another resource provides the interaction (surgery -> w_ambulancejob)
--    preview           vector4: where the player stands while editing (fitting stand / chair)
--    camera            the editor's initial camera preset
--    storeProfile      Config.Clothing.storeProfiles id (clothing)
--    pricingProfile    Config.Clothing.pricingProfiles id (clothing)
--    allowedServices   { hair = true, facialHair = true, details = true } | nil (barber)
--    hours             { open = 6, close = 22 } | nil: open from 06:00 until 21:59 in the server's local
--                      time (close < open spans midnight); a closed location is refused (LOCATION_CLOSED_HOURS,
--                      its text names the hours)
--    book              vector4 | nil (clothing): the catalogue book on the counter (x, y, z, heading).
--                      With Config.Clothing.catalogue on, the book prop stands there and the player
--                      reads it when the store opens and closes (client/services/locations.lua)
--    outfits           true | false (clothing): the store also offers the saved outfits (equip only)
--                      and "save this look as an outfit" on purchase (default true)
--    access            nil | { jobs = { [jobName] = minGrade }, ace = 'permission' } (any location):
--                      only players of one of the jobs (at that grade or above) or holding the ACE
--                      permission may open it; the server refuses the others (ACCESS_DENIED)
-- =====================================================================

-- The blip sprites are the game's own: blip_shop_tailor (the tailor's needle) and
-- blip_shop_wardrobe. The earlier 'blip_shop_clothing' is not a sprite of the game, so the map
-- drew it as a plain dot.
Config.LocationDefaults = {
    clothing = {
        interactionRadius = 2.0,
        prompt = true,
        npc = false,
        blip = { sprite = 'blip_shop_tailor', label = 'متجر الملابس' },
        camera = 'fullBody',
        storeProfile = 'general',
        pricingProfile = 'standard',
        outfits = true,
    },
    barber = {
        interactionRadius = 2.0,
        prompt = true,
        npc = false,
        blip = { sprite = 'blip_shop_barber', label = 'الحلاق' },
        camera = 'hair',
        allowedServices = nil,
    },
    surgery = {
        interactionRadius = 2.0,
        prompt = false, -- w_ambulancejob opens the clinic through exports.w_creators:OpenCosmeticSurgery
        npc = false,
        blip = false,
        camera = 'face',
    },
    wardrobe = {
        interactionRadius = 2.0,
        prompt = true,
        npc = false,
        blip = { sprite = 'blip_shop_wardrobe', label = 'الخزانة' },
        camera = 'fullBody',
    },
}

Config.Locations = {
    -- Clothing stores and wardrobes moved to standalone resource w_clothing.
    -- Barber shops moved to standalone resource w_barber.

    -- -----------------------------------------------------------------
    --  Cosmetic surgery clinics: the w_medic hospital stations. The interaction is
    --  provided by w_medic (prompt = false); the coords are the server proximity anchor.
    -- -----------------------------------------------------------------
    {
        id = 'valentine_surgery', type = 'surgery', enabled = true,
        label = 'عيادة التجميل', town = 'فالنتاين',
        coords = vector3(-284.49, 807.49, 119.38),
        prompt = false, blip = false,
    },
    {
        id = 'saintdenis_surgery', type = 'surgery', enabled = true,
        label = 'عيادة التجميل', town = 'سانت دينيس',
        coords = vector3(2387.306, -1369.280, 46.541),
        prompt = false, blip = false,
    },
    {
        id = 'armadillo_surgery', type = 'surgery', enabled = true,
        label = 'عيادة التجميل', town = 'أرماديلو',
        coords = vector3(-3651.82, -2649.4, -13.45),
        prompt = false, blip = false,
    },
}
