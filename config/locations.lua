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
    -- -----------------------------------------------------------------
    --  Clothing stores (coords = the catalogue book, preview = the fitting stand)
    -- -----------------------------------------------------------------
    {
        id = 'valentine_clothing', type = 'clothing', enabled = true,
        label = 'متجر الملابس', town = 'فالنتاين',
        coords = vector3(-326.17, 773.757, 117.5),
        book = vector4(-326.17, 773.757, 117.5, -170.0),
        preview = vector4(-329.31, 775.11, 120.63, 294.79),
        npc = { model = 'S_M_M_Tailor_01', coords = vector4(-325.67, 772.63, 116.44, 11.3) },
    },
    {
        id = 'saintdenis_clothing', type = 'clothing', enabled = true,
        label = 'متجر الملابس', town = 'سانت دينيس',
        coords = vector3(2554.619, -1167.834, 53.746),
        book = vector4(2554.619, -1167.834, 53.746, 0.0),
        preview = vector4(2555.89, -1161.23, 52.7, 12.85),
        npc = { model = 'S_M_M_Tailor_01', coords = vector4(2554.6, -1166.83, 52.7, 180.95) },
    },
    {
        id = 'blackwater_clothing', type = 'clothing', enabled = true,
        label = 'متجر الملابس', town = 'بلاك ووتر',
        coords = vector3(-761.98, -1292.61, 43.885),
        book = vector4(-761.98, -1292.61, 43.885, 180.0),
        preview = vector4(-767.74, -1295.17, 42.84, 304.87),
        npc = { model = 'S_M_M_Tailor_01', coords = vector4(-761.75, -1293.92, 42.84, 357.16) },
    },
    {
        id = 'tumbleweed_clothing', type = 'clothing', enabled = true,
        label = 'متجر الملابس', town = 'تمبلويد',
        coords = vector3(-5486.660, -2936.75, -0.346),
        book = vector4(-5486.660, -2936.75, -0.346, -144.0),
        preview = vector4(-5479.77, -2933.07, -1.36, 181.29),
        npc = false, -- no tailor at this location
    },

    -- -----------------------------------------------------------------
    --  Wardrobes: wearing what the character already owns, with no purchase
    -- -----------------------------------------------------------------
    {
        id = 'rhodes_wardrobe', type = 'wardrobe', enabled = true,
        label = 'الخزانة', town = 'رودز',
        coords = vector3(1223.55, -1288.67, 76.9),
    },
    {
        id = 'valentine_wardrobe', type = 'wardrobe', enabled = true,
        label = 'الخزانة', town = 'فالنتاين',
        coords = vector3(-184.5, 625.02, 114.09),
    },
    {
        id = 'saintdenis_wardrobe', type = 'wardrobe', enabled = true,
        label = 'الخزانة', town = 'سانت دينيس',
        coords = vector3(2549.82, -1169.58, 53.68),
    },

    -- -----------------------------------------------------------------
    --  Barbers
    -- -----------------------------------------------------------------
    {
        id = 'valentine_barber', type = 'barber', enabled = true,
        label = 'الحلاق', town = 'فالنتاين',
        coords = vector3(-307.51, 813.96, 118.99),
    },
    {
        id = 'blackwater_barber', type = 'barber', enabled = true,
        label = 'الحلاق', town = 'بلاك ووتر',
        coords = vector3(-814.915, -1367.89, 43.75),
    },
    {
        id = 'saintdenis_barber', type = 'barber', enabled = true,
        label = 'الحلاق', town = 'سانت دينيس',
        coords = vector3(2655.21, -1179.9, 53.27),
    },
    {
        id = 'annesburg_barber', type = 'barber', enabled = true,
        label = 'الحلاق', town = 'آنسبرغ',
        coords = vector3(2924.3, 1343.7, 44.4),
    },
    {
        id = 'armadillo_barber', type = 'barber', enabled = true,
        label = 'الحلاق', town = 'أرماديلو',
        coords = vector3(-3684.22, -2621.05, -13.44),
    },
    {
        id = 'tumbleweed_barber', type = 'barber', enabled = true,
        label = 'الحلاق', town = 'تمبلويد',
        coords = vector3(-5493.4, -2940.7, -0.46),
    },
    {
        id = 'strawberry_barber', type = 'barber', enabled = true,
        label = 'الحلاق', town = 'ستروبيري',
        coords = vector3(-1810.92, -372.15, 162.89),
    },

    -- -----------------------------------------------------------------
    --  Cosmetic surgery clinics: the w_ambulancejob hospital stations. The interaction is
    --  provided by w_ambulancejob (prompt = false); the coords are the server proximity anchor.
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
