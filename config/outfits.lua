-- =====================================================================
--  config/outfits.lua
--  The creator's clothing stage and the optional starting outfit presets.
--
--  startingClothing.mode
--    'free'     the creator's clothing stage offers the allowed categories freely (creation is free);
--               whatever the new character wears is granted to it (source 'starter').
--    'presets'  the clothing stage offers only Config.StartingOutfits (one choice, control
--               'starter.preset'); the chosen preset's items are equipped and granted.
--  Presets are optional: they are only used in 'presets' mode.
--
--  Preset items reference the catalogue by { category, model, variant } (1-based, per sex) so a
--  config edit never needs a hash; they are resolved and validated through WCCatalog at runtime and
--  an item that does not resolve is skipped.
-- =====================================================================

Config.Creator.startingClothing = {
    mode = 'free',
    -- '*' = every clothing category offered to the character's sex (WCCatalog.offered), as the
    -- pre-v3 creator allowed; or a list of categories, e.g. { 'shirts_full', 'pants', 'boots' }.
    categories = '*',
}

Config.StartingOutfits = {
    male = {
        {
            id = 'worker', label = 'ملابس العامل',
            items = {
                { category = 'shirts_full', model = 1, variant = 1 },
                { category = 'pants',       model = 1, variant = 1 },
                { category = 'boots',       model = 1, variant = 1 },
            },
        },
        {
            id = 'traveler', label = 'ملابس المسافر',
            items = {
                { category = 'shirts_full', model = 2, variant = 1 },
                { category = 'pants',       model = 2, variant = 1 },
                { category = 'boots',       model = 2, variant = 1 },
                { category = 'hats',        model = 1, variant = 1 },
                { category = 'vests',       model = 1, variant = 1 },
            },
        },
    },
    female = {
        {
            id = 'worker', label = 'ملابس العاملة',
            items = {
                { category = 'shirts_full', model = 1, variant = 1 },
                { category = 'skirts',      model = 1, variant = 1 },
                { category = 'boots',       model = 1, variant = 1 },
            },
        },
        {
            id = 'traveler', label = 'ملابس المسافرة',
            items = {
                { category = 'shirts_full', model = 2, variant = 1 },
                { category = 'pants',       model = 1, variant = 1 },
                { category = 'boots',       model = 2, variant = 1 },
                { category = 'hats',        model = 1, variant = 1 },
            },
        },
    },
}
