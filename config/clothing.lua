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
--    icon     the game's own clothing icon (web/build/tex/cloth/<icon>.png), drawn in a round disc
--    sex      optional: offered only to this sex (the catalogue must also have items). Enforced
--             on the server too: WCCatalog.offered / WCCatalog.available refuse it for the other sex.
-- ---------------------------------------------------------------------
Config.Clothing.taxonomy = {
    {
        id = 'head', label = 'الرأس', order = 1, camera = 'head', icon = 'hat',
        subs = {
            { id = 'hats',    category = 'hats',    label = 'القبعة',  order = 1, camera = 'head', art = 'hat', icon = 'hat' },
            { id = 'masks',   category = 'masks',   label = 'القناع',  order = 2, camera = 'face', art = 'mask', icon = 'mask' },
            { id = 'eyewear', category = 'eyewear', label = 'النظّارة', order = 3, camera = 'face', icon = 'glasses' },
        },
    },
    {
        id = 'neck', label = 'الرقبة', order = 2, camera = 'upperBody', icon = 'neckerchief',
        subs = {
            { id = 'neckwear', category = 'neckwear', label = 'وشاح الرقبة', order = 1, camera = 'upperBody', icon = 'neckerchief' },
            { id = 'neckties', category = 'neckties', label = 'ربطة العنق',  order = 2, camera = 'upperBody', icon = 'scarf' },
        },
    },
    {
        id = 'upper', label = 'الجزء العلوي', order = 3, camera = 'upperBody', icon = 'shirt',
        subs = {
            { id = 'shirts_full',  category = 'shirts_full',  label = 'القميص',        order = 1, camera = 'upperBody', art = 'shirt', icon = 'shirt' },
            { id = 'vests',        category = 'vests',        label = 'الصديري',       order = 2, camera = 'upperBody', art = 'vest', icon = 'vest' },
            { id = 'coats',        category = 'coats',        label = 'المعطف',        order = 3, camera = 'upperBody', art = 'coat', icon = 'coat' },
            { id = 'coats_closed', category = 'coats_closed', label = 'المعطف المغلق', order = 4, camera = 'upperBody', art = 'ccoat', icon = 'coat' },
            { id = 'ponchos',      category = 'ponchos',      label = 'البونشو',       order = 5, camera = 'upperBody', icon = 'poncho' },
            { id = 'cloaks',       category = 'cloaks',       label = 'العباءة',       order = 6, camera = 'upperBody', icon = 'cloak' },
            { id = 'dresses',      category = 'dresses',      label = 'الفساتين والأثواب', order = 7, camera = 'fullBody', icon = 'dress' },
            { id = 'armor',        category = 'armor',        label = 'الدرع',         order = 8, camera = 'upperBody', icon = 'm_sweater' },
        },
    },
    {
        id = 'arms', label = 'الذراعان واليدان', order = 4, camera = 'hands', icon = 'glove',
        -- the per-hand framings (handLeft / handRight: the camera on that hand's bone): a ring or a
        -- bracelet is judged close up on the hand that wears it
        subs = {
            { id = 'gloves',              category = 'gloves',              label = 'القفازات',     order = 1, camera = 'handRight', art = 'gloves', icon = 'glove' },
            { id = 'gauntlets',           category = 'gauntlets',           label = 'قفازات طويلة', order = 2, camera = 'handRight', icon = 'bracers' },
            { id = 'jewelry_bracelets',   category = 'jewelry_bracelets',   label = 'الأساور',      order = 3, camera = 'handLeft', icon = 'bracelet' },
            { id = 'jewelry_rings_left',  category = 'jewelry_rings_left',  label = 'خواتم اليسار', order = 4, camera = 'handLeft', icon = 'ring' },
            { id = 'jewelry_rings_right', category = 'jewelry_rings_right', label = 'خواتم اليمين', order = 5, camera = 'handRight', icon = 'ring' },
        },
    },
    {
        id = 'lower', label = 'الجزء السفلي', order = 5, camera = 'lowerBody', icon = 'pants',
        subs = {
            { id = 'pants',           category = 'pants',           label = 'البنطال',       order = 1, camera = 'lowerBody', icon = 'pants' },
            { id = 'skirts',          category = 'skirts',          label = 'التنّورة',      order = 2, camera = 'lowerBody', sex = 'female', icon = 'skirt' },
            { id = 'chaps',           category = 'chaps',           label = 'الشابز',        order = 3, camera = 'lowerBody', icon = 'chaps' },
            { id = 'legs_acessories', category = 'legs_acessories', label = 'إكسسوار الساق', order = 4, camera = 'lowerBody', icon = 'socks' },
        },
    },
    {
        id = 'feet', label = 'القدمان', order = 6, camera = 'feet', icon = 'boots',
        subs = {
            { id = 'boots',            category = 'boots',            label = 'الحذاء',         order = 1, camera = 'feet', art = 'boots', icon = 'boots' },
            { id = 'spats',            category = 'spats',            label = 'الطماق',         order = 2, camera = 'feet', icon = 'spats' },
            { id = 'boot_accessories', category = 'boot_accessories', label = 'إكسسوار الحذاء', order = 3, camera = 'feet', icon = 'spurs' },
        },
    },
    {
        -- The belt and the satchel use the body view and the rest of the waist the accessories
        -- view: the clothing store frames them that way (WCCamera.SETS.shop, the Jump On store's
        -- mapping: belts and satchels 'body', buckles, gunbelts and holsters 'pants').
        id = 'accessories', label = 'الإكسسوارات', order = 7, camera = 'accessories', icon = 'gunbelt',
        subs = {
            { id = 'suspenders',    category = 'suspenders',    label = 'الحمّالات',           order = 1,  camera = 'upperBody', icon = 'suspenders' },
            { id = 'belts',         category = 'belts',         label = 'الحزام',              order = 2,  camera = 'upperBody', icon = 'belt' },
            { id = 'belt_buckles',  category = 'belt_buckles',  label = 'إبزيم الحزام',        order = 3,  camera = 'accessories', icon = 'belt' },
            { id = 'gunbelts',      category = 'gunbelts',      label = 'حزام المسدس',         order = 4,  camera = 'accessories', art = 'gunbelt', icon = 'gunbelt' },
            { id = 'gunbelt_accs',  category = 'gunbelt_accs',  label = 'إكسسوار حزام المسدس', order = 5,  camera = 'accessories', icon = 'gunbelt' },
            { id = 'holsters_left', category = 'holsters_left', label = 'الجراب الأيسر',       order = 6,  camera = 'accessories', icon = 'holster' },
            { id = 'loadouts',      category = 'loadouts',      label = 'العتاد',              order = 7,  camera = 'upperBody', icon = 'bandolier' },
            { id = 'satchels',      category = 'satchels',      label = 'الحقيبة',             order = 8,  camera = 'upperBody', icon = 'satchel' },
            { id = 'badges',        category = 'badges',        label = 'الشارة',              order = 9,  camera = 'upperBody', icon = 'outfit' },
            { id = 'accessories',   category = 'accessories',   label = 'إكسسوارات أخرى',      order = 10, camera = 'fullBody', icon = 'hair_accs' },
        },
    },
}

-- ---------------------------------------------------------------------
--  Base price per category (server authoritative). A negative price or a missing category
--  means "not for sale" (the category is not shown in stores).
--  A price is a number (cash), or a table naming its currencies: { cash = 5 }, { gold = 0.25 } or
--  { cash = 5, gold = 0.25 } (either one: the player picks the currency in the store). The same
--  shapes work in Config.Clothing.modelPrices and for the tint price.
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
    -- charged for each colour of an item the character does not own yet (a colour it owns, and the
    -- item's original colour, are free); a number (cash) or { cash = n, gold = n }
    price = 2.5,
    default = {
        'metaped_tint_generic_clean',
        'metaped_tint_leather',
        'metaped_tint_hair',
        'metaped_tint_horse_leather',
        'metaped_tint_makeup',
        'metaped_tint_horse',
    },
    -- Per-palette tint limits (WCCatalog.validTint; the tint sliders take their bounds from here):
    --   limits[palette] = { min = 0, max = 254, disabled = { 12, 13 } }
    -- An index outside min..max or listed in disabled is refused, and the sliders skip it.
    -- Empty = every palette 0..254.
    limits = {},
    -- The colour track of the tint sliders: a horizontal strip per palette at
    -- web/build/tex/palettes/<palette>.png (tint 0 at the left edge, the last tint at the right),
    -- exported from the game's own palette textures. A palette without a strip keeps the plain slider.
    swatches = true,
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
        metaped_tint_horse         = 'الخيل',
    },
}

-- ---------------------------------------------------------------------
--  Store profiles: which items a store sells.
--    include = '*' | { categories... }, exclude = { categories... },
--    models = { [category] = { min = 1, max = 20 } } limits the catalogue models offered,
--    restricted = { [category] = { 3, 7 } } withholds those models (e.g. a uniform only a job's own
--    store sells: give that store a location `access` rule and a profile without the restriction).
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
--  Per-model prices (WCCatalog.price): modelPrices[sex][category][model] =
--    -1                          not sold (the model is hidden in stores)
--    5 | { cash = 5, gold = 1 }  the model's own price (replaces the category price)
--    { multiplier = 1.25 }       the category price × 1.25
--  `model` is the store's style number ("<category> 07" = 7). The location's pricing profile
--  applies after. Empty = every model at its category price.
-- ---------------------------------------------------------------------
Config.Clothing.modelPrices = {
    male = {
        -- hats = { [2] = { multiplier = 1.25 }, [6] = { cash = 7, gold = 0.35 }, [9] = -1 },
    },
    female = {},
}

-- ---------------------------------------------------------------------
--  Payment (server/core/economy.lua): the currencies a store takes, in the order of its Payment
--  choice. The choice shows only when an item on sale has a price in another currency than cash.
--  Every total is worked out on the server in the currency the player picked; an item without a
--  price in it cannot be bought with it (CURRENCY_NOT_ACCEPTED).
-- ---------------------------------------------------------------------
Config.Clothing.payment = {
    currencies = { 'cash', 'gold' },
}

-- ---------------------------------------------------------------------
--  Selling clothes back (w_creators:store:resell): only an item this character bought in a store
--  (the price it paid is recorded), not worn and not in a saved outfit. The refund is the paid
--  price × percent, in the currency it was paid in. Starting, legacy, admin and gifted clothes were
--  never paid for and cannot be sold. inWardrobe = true also offers it in the wardrobes.
-- ---------------------------------------------------------------------
Config.Clothing.resell = {
    enabled = true,
    percent = 0.33,
    inWardrobe = false,
}

-- ---------------------------------------------------------------------
--  The tailor's suggestions: ready looks in the store's Outfits group. Putting one on dresses the
--  working look in it (the items this store sells, each priced as usual; nothing is free).
--  useStartingOutfits = true also lists the creator's starting outfits (config/outfits.lua).
--  { id, label (dictionary key), items = { { category, item = 'ASSET_NAME' } | { category, model, variant } } }
-- ---------------------------------------------------------------------
Config.Clothing.suggestions = {
    useStartingOutfits = true,
    male = {},
    female = {},
}

-- ---------------------------------------------------------------------
--  The fitting room's light: a white light in front of the player while the store or the wardrobe
--  editor is open, so the colours read true in a dim shop. offset = metres from the player
--  (right, forward, up); drawn every frame by WCPreviewEnv.
-- ---------------------------------------------------------------------
Config.Clothing.fittingLight = {
    enabled = true,
    intensity = 10.0,
    range = 15.0,
    offset = { 0.5, 2.0, 0.3 },
    color = { 255, 255, 255 },
}

-- ---------------------------------------------------------------------
--  The catalogue book on the store's counter (Config.Locations[].book): the game's own catalogue
--  prop, and the game's catalogue anim scene the player reads it with when the store opens
--  (scene.enter) and closes (scene.exit). scene.drop lowers the scene's origin from the book to the
--  floor the player stands on; scene.entity is the scene's name for the player (bookEntity the
--  book's, when the scene animates it). waitMs caps the reading before the fade.
--  ⚠️ Needs a check in game at the four books (the scene's entity names in particular).
-- ---------------------------------------------------------------------
Config.Clothing.catalogue = {
    enabled = true,
    model = 'mp001_s_mp_catalogue01x_store',
    scene = {
        dict = 'script@ambient@shop@CATALOG_PLAYER',
        enter = 'PBL_ENTER',
        exit = 'PBL_EXIT_INDEX',
        entity = 'player',
        bookEntity = nil,
        drop = 1.065,
        waitMs = 2500,
        exitMs = 4000,
        loadMs = 1500,
    },
    -- the clips of the exit playlist, loaded before it plays
    exitDict = 'mech_inspection@catalog',
}

-- ---------------------------------------------------------------------
--  Clothing as inventory items (optional, off): trade or gift a garment, share a look.
--    garment      'wrap' an owned item from the wardrobe into this item (the ownership leaves the
--                 character); using the item gives it back to whoever uses it (same sex).
--    outfitCard   'share' a saved outfit as a card; using the card near a clothing store opens it
--                 with the card's look tried on (owned pieces free, the rest priced as usual).
--  The items must exist in the inventory (w_inventory: add them to its item list). Holding an item
--  never grants anything; only using it does, once.
-- ---------------------------------------------------------------------
Config.Clothing.items = {
    enabled = false,
    garment = 'w_garment',
    outfitCard = 'w_outfit_card',
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
        -- spurs and boot straps sit on the boots
        boot_accessories = { 'boots' },
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
--               | 'bodyWearable' (a wearable state of the body itself: body = 'upper' | 'lower',
--               the BODIES_UPPER / BODIES_LOWER item; 'auto' leaves the game's own state)
--    wearable   value -> w_lib wearable state name (w.component.data.wearableStates)
--    valuesFrom 'wearableStates': every state name w_lib knows is a valid value too (the body-part
--               fix); the client offers only the states the worn item really has
--    lib        value -> w.component function name (the shirt's combined collar/sleeve state)
--    requires   the state is offered only when one of these categories is also equipped
--    hiddenBy   the state is not offered while that group is 'off' (no sleeves to roll without the shirt)
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
          lib = { down = 'sleeveUnroll', rolled = 'sleeveRoll' }, hiddenBy = 'shirt',
          verified = 'likely', persist = true },
        { id = 'collar', parent = { 'upper', 'shirts_full' }, categories = { 'shirts_full' }, label = 'الياقة',
          values = { 'closed', 'open' }, default = 'closed', mechanism = 'wearable',
          lib = { closed = 'collarClose', open = 'collarOpen' }, hiddenBy = 'shirt',
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
          wearable = { over = 'base', under = 'under_pants' }, requires = { 'pants' }, hiddenBy = 'pants',
          verified = 'likely', persist = true },
        -- ★ the shirt and the trousers come off too (the body underneath shows); last in the list so a
        --   full restore draws the sleeves / collar / boots states before these hide their garment.
        --   w_lib remembers a rolled sleeve and re-applies it when the shirt goes back on.
        { id = 'shirt', parent = { 'upper', 'shirts_full' }, categories = { 'shirts_full' }, label = 'القميص',
          values = { 'on', 'off' }, default = 'on', mechanism = 'visibility',
          verified = 'likely', persist = true },
        { id = 'pants', parent = { 'lower', 'pants' }, categories = { 'pants' }, label = 'البنطال',
          values = { 'on', 'off' }, default = 'on', mechanism = 'visibility',
          verified = 'likely', persist = true },
        -- ★ the loadout (bandolier) on the right shoulder or the left one, and the vest (a corset
        --   on a woman) over or tucked under the trousers: w_lib's own state names for them
        --   (w.component.data.wearableStates.loadouts / .vests). Experimental until seen in game.
        { id = 'loadout', parent = { 'accessories', 'loadouts' }, categories = { 'loadouts' }, label = 'العتاد',
          values = { 'right', 'left' }, default = 'right', mechanism = 'wearable',
          wearable = { right = 'base', left = 'base_right' },
          verified = 'experimental', persist = true },
        { id = 'vestTuck', parent = { 'upper', 'vests' }, categories = { 'vests' }, label = 'الصديري',
          values = { 'over', 'under' }, default = 'over', mechanism = 'wearable',
          wearable = { over = 'base', under = 'under_pants' }, requires = { 'pants' }, hiddenBy = 'vest',
          verified = 'experimental', persist = true },
        -- ★ the body-part fix: a wearable state of the body itself, for when skin shows through a
        --   garment. 'auto' leaves the game's choice; any other value is one of the states the worn
        --   body item has (the client asks the game). Experimental until seen in game.
        { id = 'bodyUpper', parent = { 'upper', 'bodyUpper' }, body = 'upper', categories = { 'BODIES_UPPER' },
          label = 'الجزء العلوي من الجسم', values = { 'auto' }, valuesFrom = 'wearableStates', default = 'auto',
          mechanism = 'bodyWearable', verified = 'experimental', persist = true },
        { id = 'bodyLower', parent = { 'lower', 'bodyLower' }, body = 'lower', categories = { 'BODIES_LOWER' },
          label = 'الجزء السفلي من الجسم', values = { 'auto' }, valuesFrom = 'wearableStates', default = 'auto',
          mechanism = 'bodyWearable', verified = 'experimental', persist = true },
    },
    -- State value display names (dictionary keys)
    valueLabels = {
        on = 'ارتداء', off = 'خلع', up = 'رفع', down = 'إنزال', rolled = 'طيّ الأكمام',
        open = 'فتح', closed = 'إغلاق', over = 'فوق البنطال', under = 'تحت البنطال',
        right = 'على الكتف الأيمن', left = 'على الكتف الأيسر', auto = 'تلقائي',
    },
    -- ★ One chat command per state group: /<command> flips it (the same guards, animation and
    --   server check as the /clothing panel). Remove a line to drop its command; a name another
    --   resource already registered, or one given twice, is skipped with a warning at start.
    commands = {
        hat = 'hat', eyewear = 'glasses', mask = 'mask', bandana = 'bandana', sleeves = 'sleeves',
        collar = 'collar', coat = 'coat', vest = 'vest', poncho = 'poncho', gloves = 'gloves',
        boots = 'boots', shirt = 'shirt', pants = 'pants', loadout = 'loadout', vestTuck = 'tuck',
    },
    -- The player state bag other resources read to know the face is covered (a raised bandana):
    -- Player(src).state[bandanaStateBag] = true | false (also the IsBandanaUp exports).
    bandanaStateBag = 'wcBandanaUp',
    -- ★ The game's own clips, every dictionary and clip checked against the full RDR3 animation list
    --   (spooner's data/rdr3/animations.lua): the satchel's bandana / mask moves, the item-selection
    --   gestures (hat, gloves), the tailor's try-on clips (coat, boots, sleeves, trousers) and the
    --   outfit change. Played on the upper body only: the player keeps walking.
    --     clips     target value -> { dict?, clip, at? }  (dict defaults to the group's)
    --     at        share of the clip at which the garment changes (default .5)
    --     maxMs     the clip is cut at this length (the tailor clips run long); its real length is read
    --               from the game (GetAnimDuration), a clip the game lacks plays nothing
    --     onMount   the clip plays on a horse / in a wagon too (the satchel moves); without it a rider
    --               changes the garment with no clip
    animations = {
        hat     = { dict = 'mech_loco_m@character@arthur@fidgets@item_selection@hat', onMount = true, maxMs = 1600,
                    clips = { off = { clip = 'hat_b', at = .45 }, on = { clip = 'hat_b', at = .55 } } },
        eyewear = { dict = 'script_common@tailor_shop', maxMs = 1800,
                    clips = { off = { clip = 'adjust', at = .5 }, on = { clip = 'adjust', at = .5 } } },
        mask    = { dict = 'mech_inventory@clothing@mask', onMount = true, maxMs = 1800,
                    clips = { off = { clip = 'face_2_satchel', at = .5 }, on = { clip = 'satchel_2_face', at = .55 } } },
        bandana = { dict = 'mech_inventory@clothing@bandana', onMount = true, maxMs = 1600,
                    clips = { up = { clip = 'neck_2_face', at = .55 },
                              down = { dict = 'mech_inventory@clothing@mask', clip = 'face_2_neck', at = .5 } } },
        sleeves = { dict = 'script_common@tailor_shop', maxMs = 2600,
                    clips = { rolled = { clip = 'checkout_gloves_both', at = .6 }, down = { clip = 'checkout_right_glove', at = .6 } } },
        collar  = { dict = 'script_common@tailor_shop', maxMs = 1800,
                    clips = { open = { clip = 'adjust', at = .5 }, closed = { clip = 'adjust', at = .5 } } },
        coat    = { dict = 'mech_inventory@clothing@outfit_change', maxMs = 2600,
                    clips = { off = { clip = 'outfit_change_unarmed', at = .5 }, on = { clip = 'outfit_change_unarmed', at = .55 } } },
        vest    = { dict = 'script_common@tailor_shop', maxMs = 2200,
                    clips = { off = { clip = 'shoulder_roll_double', at = .5 }, on = { clip = 'shoulder_roll', at = .55 } } },
        poncho  = { dict = 'mech_inventory@clothing@outfit_change', maxMs = 2600,
                    clips = { off = { clip = 'outfit_change_unarmed', at = .5 }, on = { clip = 'outfit_change_unarmed', at = .55 } } },
        gloves  = { dict = 'mech_loco_m@character@arthur@fidgets@item_selection@gloves', maxMs = 2000,
                    clips = { off = { clip = 'gloves_a', at = .5 }, on = { clip = 'gloves_b', at = .55 } } },
        boots   = { dict = 'script_common@tailor_shop', maxMs = 2400,
                    clips = { under = { clip = 'checkout_boot_right', at = .55 }, over = { clip = 'checkout_boot_left', at = .55 } } },
        shirt   = { dict = 'mech_inventory@clothing@outfit_change', maxMs = 2600,
                    clips = { off = { clip = 'outfit_change_unarmed', at = .5 }, on = { clip = 'outfit_change_unarmed', at = .55 } } },
        pants   = { dict = 'script_common@tailor_shop', maxMs = 2600,
                    clips = { off = { clip = 'checkout_pants_v1', at = .55 }, on = { clip = 'checkout_pants_v2', at = .55 } } },
    },
}
