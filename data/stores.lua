-- =====================================================================
--  data/stores.lua
--  The clothing shops and the wardrobes (coordinates + prices). The logic and the interface are
--  w_creators + w_lib. Every displayed text here is a dictionary key (an Arabic source text).
--
--  The catalogue itself is not copied: w_lib provides it in full through
--  w.component.getFullPedComponentList() - more than 20,000 lines of pieces.
-- =====================================================================

StoreData = {}

--- The model's name is a string and not a backtick hash: the latter is a Cfx Lua extension that
--- plain luac does not accept, and the conversion happens at runtime with GetHashKey.
--- The clothing shops. book = the shop's catalogue spot, fittingRoom = the fitting stand.
StoreData.stores = {
    {
        name        = 'متجر الملابس',
        town        = 'فالنتاين',
        book        = vector4(-326.17, 773.757, 117.5, -170.0),
        fittingRoom = vector4(-329.31, 775.11, 120.63, 294.79),
        ped         = { coords = vector4(-325.67, 772.63, 116.44, 11.3), model = 'S_M_M_Tailor_01' },
        blip        = true,
    },
    {
        name        = 'متجر الملابس',
        town        = 'سانت دينيس',
        book        = vector4(2554.619, -1167.834, 53.746, 0.0),
        fittingRoom = vector4(2555.89, -1161.23, 52.7, 12.85),
        ped         = { coords = vector4(2554.6, -1166.83, 52.7, 180.95), model = 'S_M_M_Tailor_01' },
        blip        = true,
    },
    {
        name        = 'متجر الملابس',
        town        = 'بلاك ووتر',
        book        = vector4(-761.98, -1292.61, 43.885, 180.0),
        fittingRoom = vector4(-767.74, -1295.17, 42.84, 304.87),
        ped         = { coords = vector4(-761.75, -1293.92, 42.84, 357.16), model = 'S_M_M_Tailor_01' },
        blip        = true,
    },
    {
        name        = 'متجر الملابس',
        town        = 'تمبلويد',
        book        = vector4(-5486.660, -2936.75, -0.346, -144.0),
        fittingRoom = vector4(-5479.77, -2933.07, -1.36, 181.29),
        ped         = false, -- no tailor at this location
        blip        = true,
    },
}

--- The wardrobes: wearing what you already bought with no new purchase.
StoreData.wardrobes = {
    { coords = vector3(1223.55, -1288.67, 76.9),  blip = true },
    { coords = vector3(-184.5,  625.02,  114.09), blip = true },
    { coords = vector3(2549.82, -1169.58, 53.68), blip = true },
}

--- A piece's price according to its category. -1 disables the category (it is not shown in the shop).
StoreData.prices = {
    hats = 3.5, masks = 10, eyewear = 6, neckwear = 2.15, neckties = 2,
    shirts_full = 5, vests = 5, coats = 5, coats_closed = 5, ponchos = 4.25,
    cloaks = 5, armor = 20, suspenders = 1.5, gloves = 4.25, gauntlets = 3,
    belts = 2, belt_buckles = 1, gunbelts = 5, gunbelt_accs = 1, holsters_left = 3.12,
    pants = 5, skirts = 5, dresses = 5, chaps = 4, spats = 5,
    boots = 5, boot_accessories = 3.55, legs_acessories = 3,
    satchels = 10, loadouts = 6.7, badges = 2, accessories = 2,
    jewelry_bracelets = 2, jewelry_rings_left = 1.25, jewelry_rings_right = 1.25,
}

--- Category labels shared by the creator, wardrobe and tailor.
StoreData.categoryNames = {
    hats                   = 'القبعة',
    masks                  = 'القناع',
    eyewear                = 'النظّارة',
    neckwear               = 'وشاح الرقبة',
    neckties               = 'ربطة العنق',
    shirts_full            = 'القميص',
    vests                  = 'الصديري',
    suspenders             = 'الحمّالات',
    coats                  = 'المعطف',
    coats_closed           = 'المعطف المغلق',
    ponchos                = 'البونشو',
    cloaks                 = 'العباءة',
    armor                  = 'الدرع',
    gloves                 = 'القفازات',
    gauntlets              = 'قفازات طويلة',
    belts                  = 'الحزام',
    belt_buckles           = 'إبزيم الحزام',
    gunbelts               = 'حزام المسدس',
    gunbelt_accs           = 'إكسسوار حزام المسدس',
    holsters_left          = 'الجراب الأيسر',
    pants                  = 'البنطال',
    skirts                 = 'التنّورة',
    dresses                = 'الفستان',
    chaps                  = 'الشابز',
    spats                  = 'الطماق',
    boots                  = 'الحذاء',
    boot_accessories       = 'إكسسوار الحذاء',
    legs_acessories        = 'إكسسوار الساق',
    satchels               = 'الحقيبة',
    loadouts               = 'العتاد',
    badges                 = 'الشارة',
    accessories            = 'الإكسسوارات',
    jewelry_bracelets      = 'الأساور',
    jewelry_rings_left     = 'خواتم اليسار',
    jewelry_rings_right    = 'خواتم اليمين',
}

--- The key that opens the shop/wardrobe
StoreData.openKey = 'E'

--- An extra cost when a piece is tinted (the colours system).
StoreData.colorPrice = 2.5

--- The available palettes (the engine's palette names).
StoreData.palettes = {
    { id = 'tint_generic_clean', name = 'عام' },
    { id = 'tint_leather',       name = 'جلد' },
    { id = 'tint_hair',          name = 'شعر' },
    { id = 'tint_horse_leather', name = 'جلد الخيل' },
    { id = 'tint_makeup',        name = 'مكياج' },
}

--- The distance the prompt appears at.
StoreData.promptDistance = 2.0
