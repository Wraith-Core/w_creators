-- =====================================================================
--  config/clothing.lua
--  The clothing taxonomy, prices, tints, store/pricing profiles, the deterministic apply order,
--  the compatibility rules and the runtime clothing states (ARCHITECTURE.md §5.3–§5.5).
--
--  The catalogue itself is not copied: w_lib provides it through
--  w.component.getFullPedComponentList() and WCCatalog indexes it.
-- =====================================================================

Config.Clothing = {}

-- ---------------------------------------------------------------------
--  Taxonomy: ordered groups, each an ordered list of subcategories. Every subcategory owns
--  exactly one catalogue category and a category appears exactly once.
--    id       stable node id (= the catalogue category)
--    label    dictionary key
--    camera   camera preset (§8.6) applied when the node is selected
--    art      NUI glyph (web/build/tex/ui/<art>.png) where one exists
--    sex      optional: offered only to this sex (the catalogue must also have items). Enforced
--             on the server too: WCCatalog.offered / WCCatalog.available refuse it for the other sex.
-- ---------------------------------------------------------------------
Config.Clothing.taxonomy = {
    {
        id = 'head', label = 'الرأس', order = 1, camera = 'head',
        subs = {
            { id = 'hats',    category = 'hats',    label = 'القبعة',  order = 1, camera = 'head', art = 'hat' },
            { id = 'masks',   category = 'masks',   label = 'القناع',  order = 2, camera = 'face', art = 'mask' },
            { id = 'eyewear', category = 'eyewear', label = 'النظّارة', order = 3, camera = 'face' },
        },
    },
    {
        id = 'neck', label = 'الرقبة', order = 2, camera = 'upperBody',
        subs = {
            { id = 'neckwear', category = 'neckwear', label = 'وشاح الرقبة', order = 1, camera = 'upperBody' },
            { id = 'neckties', category = 'neckties', label = 'ربطة العنق',  order = 2, camera = 'upperBody' },
        },
    },
    {
        id = 'upper', label = 'الجزء العلوي', order = 3, camera = 'upperBody',
        subs = {
            { id = 'shirts_full',  category = 'shirts_full',  label = 'القميص',        order = 1, camera = 'upperBody', art = 'shirt' },
            { id = 'vests',        category = 'vests',        label = 'الصديري',       order = 2, camera = 'upperBody', art = 'vest' },
            { id = 'coats',        category = 'coats',        label = 'المعطف',        order = 3, camera = 'upperBody', art = 'coat' },
            { id = 'coats_closed', category = 'coats_closed', label = 'المعطف المغلق', order = 4, camera = 'upperBody', art = 'ccoat' },
            { id = 'ponchos',      category = 'ponchos',      label = 'البونشو',       order = 5, camera = 'upperBody' },
            { id = 'cloaks',       category = 'cloaks',       label = 'العباءة',       order = 6, camera = 'upperBody' },
            { id = 'dresses',      category = 'dresses',      label = 'الفساتين والأثواب', order = 7, camera = 'fullBody' },
            { id = 'armor',        category = 'armor',        label = 'الدرع',         order = 8, camera = 'upperBody' },
        },
    },
    {
        id = 'arms', label = 'الذراعان واليدان', order = 4, camera = 'hands',
        subs = {
            { id = 'gloves',              category = 'gloves',              label = 'القفازات',     order = 1, camera = 'hands', art = 'gloves' },
            { id = 'gauntlets',           category = 'gauntlets',           label = 'قفازات طويلة', order = 2, camera = 'hands' },
            { id = 'jewelry_bracelets',   category = 'jewelry_bracelets',   label = 'الأساور',      order = 3, camera = 'hands' },
            { id = 'jewelry_rings_left',  category = 'jewelry_rings_left',  label = 'خواتم اليسار', order = 4, camera = 'hands' },
            { id = 'jewelry_rings_right', category = 'jewelry_rings_right', label = 'خواتم اليمين', order = 5, camera = 'hands' },
        },
    },
    {
        id = 'lower', label = 'الجزء السفلي', order = 5, camera = 'lowerBody',
        subs = {
            { id = 'pants',           category = 'pants',           label = 'البنطال',       order = 1, camera = 'lowerBody' },
            { id = 'skirts',          category = 'skirts',          label = 'التنّورة',      order = 2, camera = 'lowerBody', sex = 'female' },
            { id = 'chaps',           category = 'chaps',           label = 'الشابز',        order = 3, camera = 'lowerBody' },
            { id = 'legs_acessories', category = 'legs_acessories', label = 'إكسسوار الساق', order = 4, camera = 'lowerBody' },
        },
    },
    {
        id = 'feet', label = 'القدمان', order = 6, camera = 'feet',
        subs = {
            { id = 'boots',            category = 'boots',            label = 'الحذاء',         order = 1, camera = 'feet', art = 'boots' },
            { id = 'spats',            category = 'spats',            label = 'الطماق',         order = 2, camera = 'feet' },
            { id = 'boot_accessories', category = 'boot_accessories', label = 'إكسسوار الحذاء', order = 3, camera = 'feet' },
        },
    },
    {
        id = 'accessories', label = 'الإكسسوارات', order = 7, camera = 'accessories',
        subs = {
            { id = 'suspenders',    category = 'suspenders',    label = 'الحمّالات',           order = 1,  camera = 'upperBody' },
            { id = 'belts',         category = 'belts',         label = 'الحزام',              order = 2,  camera = 'accessories' },
            { id = 'belt_buckles',  category = 'belt_buckles',  label = 'إبزيم الحزام',        order = 3,  camera = 'accessories' },
            { id = 'gunbelts',      category = 'gunbelts',      label = 'حزام المسدس',         order = 4,  camera = 'accessories', art = 'gunbelt' },
            { id = 'gunbelt_accs',  category = 'gunbelt_accs',  label = 'إكسسوار حزام المسدس', order = 5,  camera = 'accessories' },
            { id = 'holsters_left', category = 'holsters_left', label = 'الجراب الأيسر',       order = 6,  camera = 'accessories' },
            { id = 'loadouts',      category = 'loadouts',      label = 'العتاد',              order = 7,  camera = 'upperBody' },
            { id = 'satchels',      category = 'satchels',      label = 'الحقيبة',             order = 8,  camera = 'accessories' },
            { id = 'badges',        category = 'badges',        label = 'الشارة',              order = 9,  camera = 'upperBody' },
            { id = 'accessories',   category = 'accessories',   label = 'إكسسوارات أخرى',      order = 10, camera = 'fullBody' },
        },
    },
}

-- ---------------------------------------------------------------------
--  Base price per category (server authoritative). A negative price or a missing category
--  means "not for sale" (the category is not shown in stores).
-- ---------------------------------------------------------------------
Config.Clothing.prices = {
    hats = 3.5, masks = 10, eyewear = 6, neckwear = 2.15, neckties = 2,
    shirts_full = 5, vests = 5, coats = 5, coats_closed = 5, ponchos = 4.25,
    cloaks = 5, armor = 20, suspenders = 1.5, gloves = 4.25, gauntlets = 3,
    belts = 2, belt_buckles = 1, gunbelts = 5, gunbelt_accs = 1, holsters_left = 3.12,
    pants = 5, skirts = 5, dresses = 5, chaps = 4, spats = 5,
    boots = 5, boot_accessories = 3.55, legs_acessories = 3,
    satchels = 10, loadouts = 6.7, badges = 2, accessories = 2,
    jewelry_bracelets = 2, jewelry_rings_left = 1.25, jewelry_rings_right = 1.25,
}

-- ---------------------------------------------------------------------
--  Tints (§5.4). A tint is { palette, tint0, tint1, tint2 } with integers 0..254.
--  palettes[category] = { ... } overrides the default list; false = the category cannot be tinted.
--  Only palette names present in w_lib's w.component.data.palettes are valid.
-- ---------------------------------------------------------------------
local LEATHER = { 'metaped_tint_leather', 'metaped_tint_horse_leather', 'metaped_tint_generic_clean' }

Config.Clothing.tints = {
    enabled = true,
    price = 2.5, -- charged when a purchase's tint differs from the item's owned tint
    default = {
        'metaped_tint_generic_clean',
        'metaped_tint_leather',
        'metaped_tint_hair',
        'metaped_tint_horse_leather',
        'metaped_tint_makeup',
    },
    palettes = {
        hats             = { 'metaped_tint_hat', 'metaped_tint_hat_clean', 'metaped_tint_generic_clean' },
        boots            = LEATHER,
        gloves           = LEATHER,
        gauntlets        = LEATHER,
        belts            = LEATHER,
        gunbelts         = LEATHER,
        gunbelt_accs     = LEATHER,
        holsters_left    = LEATHER,
        satchels         = LEATHER,
        loadouts         = LEATHER,
        chaps            = LEATHER,
        spats            = LEATHER,
        boot_accessories = LEATHER,
        skirts           = { 'metaped_tint_skirt_clean', 'metaped_tint_generic_clean' },
        jewelry_bracelets   = false,
        jewelry_rings_left  = false,
        jewelry_rings_right = false,
        badges              = false,
    },
    -- Palette display names (dictionary keys)
    labels = {
        metaped_tint_generic_clean = 'عام',
        metaped_tint_leather       = 'جلد',
        metaped_tint_hair          = 'شعر',
        metaped_tint_horse_leather = 'جلد الخيل',
        metaped_tint_makeup        = 'مكياج',
        metaped_tint_hat           = 'القبعة',
        metaped_tint_hat_clean     = 'قبعة نظيفة',
        metaped_tint_skirt_clean   = 'التنّورة',
    },
}

-- ---------------------------------------------------------------------
--  Store profiles: which items a store sells.
--    include = '*' | { categories... }, exclude = { categories... },
--    models = { [category] = { min = 1, max = 20 } } limits the catalogue models offered.
--  A location picks one with storeProfile (default 'general').
-- ---------------------------------------------------------------------
Config.Clothing.storeProfiles = {
    general = { include = '*' },
    -- Example, not assigned to any location by default: a tailor selling formal wear only.
    premium = {
        include = { 'hats', 'neckties', 'shirts_full', 'vests', 'coats', 'coats_closed', 'pants',
                    'skirts', 'dresses', 'gloves', 'boots', 'jewelry_bracelets', 'jewelry_rings_left',
                    'jewelry_rings_right' },
        exclude = {},
        models = { hats = { min = 1, max = 60 } },
    },
}

-- Pricing profiles: base price × multiplier, rounded to cents. A location picks one with pricingProfile.
Config.Clothing.pricingProfiles = {
    standard = { multiplier = 1.0 },
}

-- ---------------------------------------------------------------------
--  The deterministic apply order (the render pipeline, §3.2): body parts first, then clothing
--  from the innermost layer to the outermost. Categories missing here are applied after, sorted.
-- ---------------------------------------------------------------------
Config.Clothing.applyOrder = {
    'BODIES_LOWER', 'BODIES_UPPER', 'heads', 'eyes', 'teeth', 'hair', 'mustache',
    'pants', 'skirts', 'dresses', 'shirts_full', 'boots', 'spats', 'chaps', 'legs_acessories',
    'boot_accessories', 'vests', 'suspenders', 'neckwear', 'neckties',
    'coats', 'coats_closed', 'ponchos', 'cloaks', 'armor',
    'gloves', 'gauntlets', 'jewelry_bracelets', 'jewelry_rings_left', 'jewelry_rings_right',
    'belts', 'belt_buckles', 'gunbelts', 'gunbelt_accs', 'holsters_left', 'loadouts', 'satchels',
    'badges', 'accessories', 'eyewear', 'masks', 'hats',
}

-- ---------------------------------------------------------------------
--  Compatibility rules (WCRules).
--    conflicts: pairs that cannot be worn together (symmetric). The category equipped last wins
--               in WCRules.equip; WCRules.normalize keeps the one earlier in applyOrder.
--    requires:  a category needs at least one of the listed categories to be equipped.
-- ---------------------------------------------------------------------
Config.Clothing.rules = {
    conflicts = {
        { 'coats', 'coats_closed' },
        { 'ponchos', 'cloaks' },
        { 'pants', 'skirts' },
        { 'dresses', 'pants' },
        { 'dresses', 'skirts' },
    },
    requires = {
        gunbelt_accs = { 'gunbelts' },
        belt_buckles = { 'belts' },
    },
}

-- The essential body parts: always present, never removable.
Config.Clothing.essentialNotRemovable = {
    heads = true, eyes = true, teeth = true, BODIES_UPPER = true, BODIES_LOWER = true,
}

-- =====================================================================
--  Runtime clothing states (§5.5). Changing a state never removes an owned or equipped item:
--  'off' only hides the component on the ped; clothing.equipped is unchanged.
--    verified   'likely' (documented, used by w_lib) | 'experimental' (research only)
--    persist    true: the state is saved in app.clothing.states and restored on login
--    mechanism  'visibility' (remove / re-apply the equipped hash) | 'wearable' (w_lib wearable state)
--    wearable   value -> w_lib wearable state name (w.component.data.wearableStates)
--    lib        value -> w.component function name (the shirt's combined collar/sleeve state)
--    requires   the state is offered only when one of these categories is also equipped
-- =====================================================================
Config.ClothingStates = {
    enabled = Config.Services.clothingActions,
    groups = {
        { id = 'hat', parent = { 'head', 'hats' }, categories = { 'hats' }, label = 'القبعة',
          values = { 'on', 'off' }, default = 'on', mechanism = 'visibility',
          verified = 'likely', persist = true },
        { id = 'eyewear', parent = { 'head', 'eyewear' }, categories = { 'eyewear' }, label = 'النظّارة',
          values = { 'on', 'off' }, default = 'on', mechanism = 'visibility',
          verified = 'likely', persist = true },
        { id = 'mask', parent = { 'head', 'masks' }, categories = { 'masks' }, label = 'القناع',
          values = { 'on', 'off' }, default = 'on', mechanism = 'visibility',
          verified = 'likely', persist = true },
        { id = 'bandana', parent = { 'neck', 'neckwear' }, categories = { 'neckwear' }, label = 'وشاح الرقبة',
          values = { 'down', 'up' }, default = 'down', mechanism = 'wearable',
          wearable = { down = 'base', up = 'mask_up' },
          verified = 'likely', persist = false },
        { id = 'sleeves', parent = { 'upper', 'shirts_full' }, categories = { 'shirts_full' }, label = 'الأكمام',
          values = { 'down', 'rolled' }, default = 'down', mechanism = 'wearable',
          lib = { down = 'sleeveUnroll', rolled = 'sleeveRoll' },
          verified = 'likely', persist = true },
        { id = 'collar', parent = { 'upper', 'shirts_full' }, categories = { 'shirts_full' }, label = 'الياقة',
          values = { 'closed', 'open' }, default = 'closed', mechanism = 'wearable',
          lib = { closed = 'collarClose', open = 'collarOpen' },
          verified = 'likely', persist = true },
        { id = 'coat', parent = { 'upper', 'coats' }, categories = { 'coats', 'coats_closed' }, label = 'المعطف',
          values = { 'on', 'off' }, default = 'on', mechanism = 'visibility',
          verified = 'likely', persist = true },
        { id = 'vest', parent = { 'upper', 'vests' }, categories = { 'vests' }, label = 'الصديري',
          values = { 'on', 'off' }, default = 'on', mechanism = 'visibility',
          verified = 'likely', persist = true },
        { id = 'poncho', parent = { 'upper', 'ponchos' }, categories = { 'ponchos', 'cloaks' }, label = 'البونشو',
          values = { 'on', 'off' }, default = 'on', mechanism = 'visibility',
          verified = 'likely', persist = true },
        { id = 'gloves', parent = { 'arms', 'gloves' }, categories = { 'gloves' }, label = 'القفازات',
          values = { 'on', 'off' }, default = 'on', mechanism = 'visibility',
          verified = 'likely', persist = true },
        { id = 'boots', parent = { 'feet', 'boots' }, categories = { 'boots' }, label = 'الحذاء',
          values = { 'over', 'under' }, default = 'over', mechanism = 'wearable',
          wearable = { over = 'base', under = 'under_pants' }, requires = { 'pants' },
          verified = 'likely', persist = true },
    },
    -- State value display names (dictionary keys)
    valueLabels = {
        on = 'ارتداء', off = 'خلع', up = 'رفع', down = 'إنزال', rolled = 'طيّ الأكمام',
        open = 'فتح', closed = 'إغلاق', over = 'فوق البنطال', under = 'تحت البنطال',
    },
    -- EXPERIMENTAL (Config.Experimental.clothingAnimations): short upper-body clips played while a
    -- state changes. The dictionary/clip names come from community research and are not verified
    -- on every game build; a missing clip is skipped and the state still changes.
    --   clips     target state value -> clip (read first; `up` / `down` are the fallback by direction)
    --   duration  ms the clip plays; midpoint = ms at which the state changes (default duration / 2)
    animations = {
        hat     = { dict = 'mech_inventory@clothing@hat', duration = 1200, midpoint = 600,
                    clips = { off = 'hat_off', on = 'hat_on' } },
        mask    = { dict = 'mech_inventory@clothing@bandana', duration = 1000, midpoint = 500,
                    clips = { on = 'neck_2_face', off = 'face_2_neck' } },
        bandana = { dict = 'mech_inventory@clothing@bandana', duration = 1000, midpoint = 500,
                    clips = { up = 'neck_2_face', down = 'face_2_neck' } },
        sleeves = { dict = 'mech_inventory@clothing@sleeves', duration = 1500, midpoint = 750,
                    clips = { rolled = 'roll_up', down = 'roll_down' } },
        gloves  = { dict = 'mech_inventory@clothing@gloves', duration = 1500, midpoint = 750,
                    clips = { off = 'gloves_off', on = 'gloves_on' } },
    },
}
