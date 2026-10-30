-- =====================================================================
--  shared/overlays.lua  —  WCOverlays
--  The 18 head texture layers applied through w.pedTexture. `id` is the legacy compType
--  (kept so stored data and the legacy projection stay stable), `library` the w.pedTexture layer,
--  `ids` the w.pedTexture texture ids in style order (style N = ids[N]).
--
--  The ids were derived by reversing the overlaysInfo hashes against RDR2's naming pattern
--  (mp_u_faov_<category>_<nnn>) rather than by position: the old arrays are ordered by hash value,
--  so the eyebrows' first style is texture 12, not 1. Two fixes are built in: ageing[1] was
--  mp_u_faov_acne_000 (removed) and hairov[4] was a hash with no known name (dropped).
--
--  Stored as app.overlays[id] = { style = 1..N, color = 1..64, opacity = 0..1 }; absent = off.
--  Optional, per layer:
--    color2, color3 = 1..64   the layer's second / third tint (layers with tints = 2 | 3: foundation,
--                             lipstick, eyeshadow); absent = tint 0, as before these existed
--    matchHair = true         eyebrows only: drawn in the hair's own tints (re-read from the ped)
--    extra = { { style, opacity }, ... }   scars only: further scars on top of the first one
--
--  Layer fields: grids = the texture sheet cell of each style (the makeup textures are sheets of
--  several designs: style N draws cell grids[N] of texture ids[1]); texSex = the texture set of each
--  style ('m' / 'f': the eyebrow textures exist in two sets and a style keeps its own set on either
--  sex); tints = how many of the palette's tints the layer draws (1..3); extra = how many further
--  instances may be stacked; names = a dictionary key per style (the game's style names).
--  The grid, texture set and style name data are the game's (w_lib's ped-texture variations).
-- =====================================================================

WCOverlays = {}

local HAIR_PALETTE, MAKEUP_PALETTE = 'metaped_tint_hair', 'metaped_tint_makeup'
local BOTH = { male = true, female = true }

local LAYERS = {
    -- skin
    { id = 'complex',  library = 'complex',  section = 'skin', label = 'البشرة الأساسية',
      ids = { 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13 },
      names = { 'بشرة منهكة', 'بشرة محمرّة', 'بشرة متشقّقة', 'بشرة منقّطة', 'بشرة متورّدة', 'بشرة نضرة',
                'بشرة مدمن الشراب', 'بشرة لفحتها الريح', 'بشرة مائلة للحمرة', 'بشرة خشنة', 'بشرة محروقة بالشمس',
                'بشرة أنهكها الطقس', 'بشرة متعبة', 'بشرة متضرّرة' } },
    { id = 'disc',     library = 'disc',     section = 'skin', label = 'تفاوت البشرة',
      ids = { 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15 },
      names = { 'تفاوت خشن', 'تفاوت مبقّع', 'تفاوت مرقّط', 'تفاوت منقّط', 'تفاوت ثابت', 'تفاوت غير متساوٍ',
                'تفاوت ببقع', 'تفاوت طفيف', 'تفاوت واضح', 'تفاوت ملطّخ', 'تفاوت بنقاط', 'تفاوت عشوائي',
                'تفاوت متنوّع', 'تفاوت منتشر', 'تفاوت خشن جدًا', 'تفاوت متقطّع' } },
    { id = 'ageing',   library = 'ageing',   section = 'skin', label = 'التجاعيد',
      ids = { 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20, 21, 22, 23 } },
    { id = 'freckles', library = 'freckles', section = 'skin', label = 'النمش',
      ids = { 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14 },
      names = { 'نمش شمسي', 'نمش الخدّين', 'نمش عشوائي', 'نمش قليل', 'نمش متعدّد', 'نمش كثيف', 'نمش باهت',
                'نمش متناثر', 'نمش فاتح', 'نمش ظاهر', 'نمش منقّط', 'نمش دقيق', 'نمش الأنف',
                'نمش على الوجنتين', 'نمش كثيف على الوجنتين' } },
    { id = 'moles',    library = 'moles',    section = 'skin', label = 'الشامات',
      ids = { 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15 },
      names = { 'شامات متفرّقة', 'شامات خفيفة', 'شامات متنوّعة', 'شامات متجمّعة', 'شامات نادرة', 'شامات مرقّطة',
                'شامات منثورة', 'شامات بارزة', 'شامات منقّطة', 'شامات متناقصة', 'شامات ممتدّة', 'شامات مبعثرة',
                'شامات مصفوفة', 'شامات مرقّطة ٢', 'شامات مجتمعة', 'شامات قليلة' } },
    { id = 'spots',    library = 'spots',    section = 'skin', label = 'البقع',
      ids = { 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15 } },
    { id = 'acne',     library = 'acne',     section = 'skin', label = 'البثور',
      ids = { 0 } },
    -- a face can carry several scars: up to `extra` more are stacked on the first one
    { id = 'scars',    library = 'scar',     section = 'skin', label = 'جراح', extra = 3,
      ids = { 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15 },
      names = { 'ندبة جرح', 'ندبة مخلب', 'ندبة مشقوقة', 'ندبة ممزّقة', 'ندبة ضربة', 'ندبة قطع', 'ندبة ساطور',
                'ندبة متصدّعة', 'ندبة مهشّمة', 'ندبة مرقّعة', 'ندبة كشط', 'ندبة كسر', 'ندبة مشوِّهة',
                'ندبة بارزة', 'ندبة شائبة', 'ندبة فروة الرأس' } },
    { id = 'grime',    library = 'grime',    section = 'skin', label = 'الأوساخ',
      ids = { 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15 } },
    -- makeup (the eyeliner, eyeshadow and lipstick textures are sheets: one texture, a design per cell)
    { id = 'foundation',   library = 'foundation', section = 'makeup', label = 'كريم الأساس', tints = 2,
      ids = { 0 }, names = { 'بودرة الوجه' } },
    { id = 'blush',        library = 'blush',      section = 'makeup', label = 'أحمر الخدود',
      ids = { 0, 1, 2, 3 }, names = { 'خدود متورّدة', 'خدود وردية', 'خدود راقية', 'خدود منحوتة' } },
    { id = 'lipsticks',    library = 'lipstick',   section = 'makeup', label = 'أحمر الشفاه', tints = 2,
      ids = { 0 }, grids = { 0, 1, 2, 3, 4, 5, 7 },
      names = { 'أحمر مطفي', 'أحمر محدّد', 'أحمر مظلّل', 'أحمر ملطّخ', 'أحمر مربّع', 'أحمر على شكل قلب',
                'أحمر بحافّة' } },
    { id = 'eyeliners',    library = 'eyeliner',   section = 'makeup', label = 'كحل العين',
      ids = { 0 }, grids = { 0, 1, 2, 3, 4, 5, 6, 7, 13, 15, 8, 14, 9, 10, 11, 12 },
      names = { 'كحل بسيط', 'كحل مجنّح', 'كحل طويل', 'كحل سفلي', 'كحل معقوف', 'كحل منحنٍ', 'كحل درامي',
                'كحل هندي', 'كحل هندي عريض', 'كحل هندي كامل', 'كحل كلاسيكي', 'كحل كلاسيكي عريض', 'كحل كامل',
                'كحل مزدوج', 'كحل مزدوج علوي', 'كحل فرعوني' } },
    { id = 'shadows',      library = 'eyeshadow',  section = 'makeup', label = 'ظلال العين', tints = 3,
      ids = { 0 }, grids = { 0, 1, 2, 3, 4, 5 },
      names = { 'ظلال دخانية', 'ظلال بقوس مرتّب', 'ظلال بجناح كثيف', 'ظلال ممزوجة', 'ظلال بجناح بلونين',
                'ظلال مضيئة' } },
    { id = 'paintedmasks', library = 'masks',      section = 'makeup', label = 'طلاء الوجه',    ids = { 0 } },
    -- eyebrows. The 24 styles are the two texture sets in the order of the pre-v3 data (sorted by
    -- texture hash): 16 of the 'm' set and 8 of the 'f' set, mixed. Each style keeps ITS OWN set on
    -- either sex: without it a female ped looked for 'f' textures 8..15, which do not exist (8 styles
    -- drew nothing), and a male ped drew 8 styles twice.
    { id = 'eyebrows', library = 'eyebrow', section = 'eyebrows', label = 'نمط الحاجبين', palette = HAIR_PALETTE,
      ids =    { 12, 6, 3, 11, 2, 4, 13, 14, 15, 1, 3, 2, 6, 8, 5, 7, 7, 9, 0, 10, 5, 1, 0, 4 },
      texSex = { 'm', 'm', 'm', 'm', 'm', 'f', 'm', 'm', 'm', 'f', 'f', 'f', 'f', 'm', 'f', 'f', 'm', 'm', 'f',
                 'm', 'm', 'm', 'm', 'm' },
      names = { 'حاجبان حادّان', 'حاجبان رفيعان', 'حاجبان منفوشان', 'حاجبان مرتّبان', 'حاجبان مستقيما الطرف',
                'حاجبان سميكان ٢', 'حاجبان مدبّبان', 'حاجبان مشذّبان', 'حاجبان سميكان', 'حاجبان كاملان ٢',
                'حاجبان محدّدان', 'حاجبان مشذّبان ٢', 'حاجبان طبيعيان ٢', 'حاجبان منخفضان', 'حاجبان منفوشان ٢',
                'حاجبان ثقيلان', 'حاجبان كثّان', 'حاجبان منتوفان', 'حاجبان منتوفان ٢', 'حاجبان مقوّسان',
                'حاجبان طبيعيان', 'حاجبان قصيران', 'حاجبان كاملان', 'حاجبان خفيفان' } },
    -- hair
    { id = 'hairov', library = 'hair', section = 'hair', label = 'شعر الرأس الخفيف', palette = HAIR_PALETTE,
      ids = { 0, 2, 9 } },
    -- facial hair (male only)
    { id = 'beardstabble', library = 'beard', section = 'facialHair', label = 'ظل اللحية', palette = HAIR_PALETTE,
      ids = { 0 }, sexes = { male = true } },
}

WCOverlays.COLORS = 64
WCOverlays.layers = {}
WCOverlays.byId = {}

--- The w.pedTexture layers drawn with blend type 1 (w_lib ped-texture applyLayer): no palette or
--  tint is ever applied to them, so their colour has no visible effect. Keyed by library name. Their
--  WCOverlays layers carry tint = false: the editors offer no Color for them and
--  AppearanceSchema.sanitize stores their color as 1 (a colour-only change is never a change).
WCOverlays.UNTINTED = { scar = true, spots = true, disc = true, complex = true, acne = true, ageing = true,
                        moles = true, freckles = true }

for index, def in ipairs(LAYERS) do
    local layer = {
        id = def.id, library = def.library, ids = def.ids, section = def.section, label = def.label,
        palette = def.palette or MAKEUP_PALETTE, sexes = def.sexes or BOTH, order = index,
        -- a sheet layer has a style per cell of its one texture
        styles = def.grids and #def.grids or #def.ids, tint = not WCOverlays.UNTINTED[def.library],
        grids = def.grids, texSex = def.texSex, names = def.names,
        tints = def.tints or 1, extra = def.extra or 0,
    }
    WCOverlays.layers[index] = layer
    WCOverlays.byId[def.id] = layer
end

--- The texture of a style: texture id, sheet cell (nil = 0), texture set ('m' | 'f' | nil = the
--  ped's own), or nil when the style does not exist.
---@param layer table|string a WCOverlays layer or its id
---@param style integer 1..layer.styles
function WCOverlays.texture(layer, style)
    if type(layer) == 'string' then layer = WCOverlays.byId[layer] end
    style = math.tointeger(tonumber(style))
    if type(layer) ~= 'table' or not style or style < 1 or style > layer.styles then return nil end
    local id = layer.grids and layer.ids[1] or layer.ids[style]
    if id == nil then return nil end
    return id, layer.grids and layer.grids[style] or nil, layer.texSex and layer.texSex[style] or nil
end

--- 'skin' | 'makeup' | 'eyebrows' | 'hair' | 'facialHair' for a layer id (nil when unknown).
function WCOverlays.sectionOf(id)
    local layer = WCOverlays.byId[id]
    return layer and layer.section or nil
end

--- Is the layer available for this sex?
function WCOverlays.allowed(id, sex)
    local layer = WCOverlays.byId[id]
    return layer ~= nil and layer.sexes[sex] == true
end

--- Does the colour of a layer show? A layer table's own tint flag decides (false = drawn without
--  its palette); a table without one falls back to the blend-type-1 list.
---@param layer table|string a WCOverlays layer or its id
---@return boolean
function WCOverlays.tintable(layer)
    if type(layer) == 'string' then layer = WCOverlays.byId[layer] end
    if type(layer) ~= 'table' then return false end
    if layer.tint ~= nil then return layer.tint ~= false end
    return not WCOverlays.UNTINTED[layer.library]
end
