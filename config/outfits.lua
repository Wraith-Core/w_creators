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
--  Preset items reference the catalogue by { category, model, variant } (1-based, per sex) or by
--  the game's asset name { category, item = 'CLOTHING_ITEM_...' } (stable whatever order the
--  catalogue lists it in), so a config edit never needs a hash; they are resolved and validated
--  through WCCatalog at runtime and an item that does not resolve is skipped.
--  In 'free' mode the presets are the creator's Outfits group: a starting look to dress from.
--  After the first two, each preset is one of the game's own matching clothing sets (its pieces
--  share a name: FRONTIER, OUTLAW, RANCHER, ROUGHRIDER, VAQUERO), for both sexes.
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
        {
            id = 'frontier', label = 'طقم الحدود',
            items = {
                { category = 'shirts_full', item = 'CLOTHING_ITEM_M_FRONTIER_SHIRT_000' },
                { category = 'pants',       item = 'CLOTHING_ITEM_M_FRONTIER_PANTS_000' },
                { category = 'boots',       item = 'CLOTHING_ITEM_M_FRONTIER_BOOTS_000' },
                { category = 'hats',        item = 'CLOTHING_ITEM_M_FRONTIER_HAT_000' },
                { category = 'coats',       item = 'CLOTHING_ITEM_M_FRONTIER_COAT_000' },
                { category = 'neckwear',    item = 'CLOTHING_ITEM_M_FRONTIER_NECKWEAR_000' },
            },
        },
        {
            id = 'outlaw', label = 'طقم الخارج عن القانون',
            items = {
                { category = 'shirts_full', item = 'CLOTHING_ITEM_M_OUTLAW_SHIRT_000' },
                { category = 'pants',       item = 'CLOTHING_ITEM_M_OUTLAW_PANTS_000' },
                { category = 'boots',       item = 'CLOTHING_ITEM_M_OUTLAW_BOOTS_000' },
                { category = 'hats',        item = 'CLOTHING_ITEM_M_OUTLAW_HAT_000' },
                { category = 'coats',       item = 'CLOTHING_ITEM_M_OUTLAW_COAT_000' },
                { category = 'neckwear',    item = 'CLOTHING_ITEM_M_OUTLAW_NECKWEAR_000' },
            },
        },
        {
            id = 'rancher', label = 'طقم المزرعة',
            items = {
                { category = 'shirts_full', item = 'CLOTHING_ITEM_M_RANCHER_SHIRT_VAR_001' },
                { category = 'pants',       item = 'CLOTHING_ITEM_M_RANCHER_PANTS_VAR_001' },
                { category = 'boots',       item = 'CLOTHING_ITEM_M_RANCHER_BOOTS_VAR_001' },
                { category = 'hats',        item = 'CLOTHING_ITEM_M_RANCHER_HAT_VAR_001' },
                { category = 'suspenders',  item = 'CLOTHING_ITEM_M_RANCHER_SUSPENDERS_VAR_001' },
            },
        },
        {
            id = 'roughrider', label = 'طقم الفارس',
            items = {
                { category = 'shirts_full', item = 'CLOTHING_ITEM_M_ROUGHRIDER_SHIRT_000' },
                { category = 'pants',       item = 'CLOTHING_ITEM_M_ROUGHRIDER_PANTS_000' },
                { category = 'boots',       item = 'CLOTHING_ITEM_M_ROUGHRIDER_BOOTS_000' },
                { category = 'hats',        item = 'CLOTHING_ITEM_M_ROUGHRIDER_HAT_000' },
                { category = 'suspenders',  item = 'CLOTHING_ITEM_M_ROUGHRIDER_SUSPENDERS_000' },
                { category = 'gloves',      item = 'CLOTHING_ITEM_M_ROUGHRIDER_GLOVES_000' },
                { category = 'neckwear',    item = 'CLOTHING_ITEM_M_ROUGHRIDER_SCARF_000' },
                { category = 'spats',       item = 'CLOTHING_ITEM_M_ROUGHRIDER_SPATS_000' },
            },
        },
        {
            id = 'vaquero', label = 'طقم الفاكيرو',
            items = {
                { category = 'shirts_full', item = 'CLOTHING_ITEM_M_VAQUERO_SHIRT_000' },
                { category = 'vests',       item = 'CLOTHING_ITEM_M_VAQUERO_VEST_000' },
                { category = 'pants',       item = 'CLOTHING_ITEM_M_VAQUERO_PANTS_000' },
                { category = 'boots',       item = 'CLOTHING_ITEM_M_VAQUERO_BOOTS_000' },
                { category = 'hats',        item = 'CLOTHING_ITEM_M_VAQUERO_HAT_000' },
                { category = 'neckwear',    item = 'CLOTHING_ITEM_M_VAQUERO_NECKWEAR_000' },
                { category = 'spats',       item = 'CLOTHING_ITEM_M_VAQUERO_SPATS_000' },
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
        {
            id = 'frontier', label = 'طقم الحدود',
            items = {
                { category = 'shirts_full', item = 'CLOTHING_ITEM_F_FRONTIER_SHIRT_000' },
                { category = 'pants',       item = 'CLOTHING_ITEM_F_FRONTIER_PANTS_000' },
                { category = 'boots',       item = 'CLOTHING_ITEM_F_FRONTIER_BOOTS_000' },
                { category = 'hats',        item = 'CLOTHING_ITEM_F_FRONTIER_HAT_000' },
                { category = 'coats',       item = 'CLOTHING_ITEM_F_FRONTIER_COAT_000' },
                { category = 'neckwear',    item = 'CLOTHING_ITEM_F_FRONTIER_NECKWEAR_000' },
            },
        },
        {
            id = 'outlaw', label = 'طقم الخارج عن القانون',
            items = {
                { category = 'shirts_full', item = 'CLOTHING_ITEM_F_OUTLAW_SHIRT_000' },
                { category = 'pants',       item = 'CLOTHING_ITEM_F_OUTLAW_PANTS_000' },
                { category = 'boots',       item = 'CLOTHING_ITEM_F_OUTLAW_BOOTS_000' },
                { category = 'hats',        item = 'CLOTHING_ITEM_F_OUTLAW_HAT_000' },
                { category = 'coats',       item = 'CLOTHING_ITEM_F_OUTLAW_COAT_000' },
                { category = 'neckwear',    item = 'CLOTHING_ITEM_F_OUTLAW_NECKWEAR_000' },
            },
        },
        {
            id = 'rancher', label = 'طقم المزرعة',
            items = {
                { category = 'shirts_full', item = 'CLOTHING_ITEM_F_RANCHER_SHIRT_VAR_001' },
                { category = 'pants',       item = 'CLOTHING_ITEM_F_RANCHER_PANTS_VAR_001' },
                { category = 'boots',       item = 'CLOTHING_ITEM_F_RANCHER_BOOTS_VAR_001' },
                { category = 'hats',        item = 'CLOTHING_ITEM_F_RANCHER_HAT_VAR_001' },
                { category = 'suspenders',  item = 'CLOTHING_ITEM_F_RANCHER_SUSPENDERS_VAR_001' },
            },
        },
        {
            id = 'roughrider', label = 'طقم الفارس',
            items = {
                { category = 'shirts_full', item = 'CLOTHING_ITEM_F_ROUGHRIDER_SHIRT_000' },
                { category = 'pants',       item = 'CLOTHING_ITEM_F_ROUGHRIDER_PANTS_000' },
                { category = 'boots',       item = 'CLOTHING_ITEM_F_ROUGHRIDER_BOOTS_000' },
                { category = 'hats',        item = 'CLOTHING_ITEM_F_ROUGHRIDER_HAT_000' },
                { category = 'suspenders',  item = 'CLOTHING_ITEM_F_ROUGHRIDER_SUSPENDERS_000' },
                { category = 'gloves',      item = 'CLOTHING_ITEM_F_ROUGHRIDER_GLOVES_000' },
                { category = 'neckwear',    item = 'CLOTHING_ITEM_F_ROUGHRIDER_SCARF_000' },
                { category = 'spats',       item = 'CLOTHING_ITEM_F_ROUGHRIDER_SPATS_000' },
            },
        },
        {
            id = 'vaquero', label = 'طقم الفاكيرو',
            items = {
                { category = 'shirts_full', item = 'CLOTHING_ITEM_F_VAQUERO_SHIRT_000' },
                { category = 'vests',       item = 'CLOTHING_ITEM_F_VAQUERO_VEST_000' },
                { category = 'pants',       item = 'CLOTHING_ITEM_F_VAQUERO_PANTS_000' },
                { category = 'boots',       item = 'CLOTHING_ITEM_F_VAQUERO_BOOTS_000' },
                { category = 'hats',        item = 'CLOTHING_ITEM_F_VAQUERO_HAT_000' },
                { category = 'neckwear',    item = 'CLOTHING_ITEM_F_VAQUERO_NECKWEAR_000' },
                { category = 'spats',       item = 'CLOTHING_ITEM_F_VAQUERO_SPATS_000' },
            },
        },
    },
}
