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
--  Stored as app.overlays[id] = { style = 1..#ids, color = 1..64, opacity = 0..1 }; absent = off.
-- =====================================================================

WCOverlays = {}

local HAIR_PALETTE, MAKEUP_PALETTE = 'metaped_tint_hair', 'metaped_tint_makeup'
local BOTH = { male = true, female = true }

local LAYERS = {
    -- skin
    { id = 'complex',  library = 'complex',  section = 'skin', label = 'البشرة الأساسية',
      ids = { 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13 } },
    { id = 'disc',     library = 'disc',     section = 'skin', label = 'تفاوت البشرة',
      ids = { 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15 } },
    { id = 'ageing',   library = 'ageing',   section = 'skin', label = 'التجاعيد',
      ids = { 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20, 21, 22, 23 } },
    { id = 'freckles', library = 'freckles', section = 'skin', label = 'النمش',
      ids = { 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14 } },
    { id = 'moles',    library = 'moles',    section = 'skin', label = 'الثآليل',
      ids = { 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15 } },
    { id = 'spots',    library = 'spots',    section = 'skin', label = 'البقع',
      ids = { 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15 } },
    { id = 'acne',     library = 'acne',     section = 'skin', label = 'البثور',
      ids = { 0 } },
    { id = 'scars',    library = 'scar',     section = 'skin', label = 'جراح',
      ids = { 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15 } },
    { id = 'grime',    library = 'grime',    section = 'skin', label = 'الأوساخ',
      ids = { 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15 } },
    -- makeup
    { id = 'foundation',   library = 'foundation', section = 'makeup', label = 'كريم الأساس',   ids = { 0 } },
    { id = 'blush',        library = 'blush',      section = 'makeup', label = 'أحمر الخدود',   ids = { 0, 1, 2, 3 } },
    { id = 'lipsticks',    library = 'lipstick',   section = 'makeup', label = 'أحمر الشفاه',   ids = { 0 } },
    { id = 'eyeliners',    library = 'eyeliner',   section = 'makeup', label = 'كحل العين',     ids = { 0 } },
    { id = 'shadows',      library = 'eyeshadow',  section = 'makeup', label = 'ظلال العين',    ids = { 0 } },
    { id = 'paintedmasks', library = 'masks',      section = 'makeup', label = 'طلاء الوجه',    ids = { 0 } },
    -- eyebrows
    { id = 'eyebrows', library = 'eyebrow', section = 'eyebrows', label = 'نمط الحاجبين', palette = HAIR_PALETTE,
      ids = { 12, 6, 3, 11, 2, 4, 13, 14, 15, 1, 3, 2, 6, 8, 5, 7, 7, 9, 0, 10, 5, 1, 0, 4 } },
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
        styles = #def.ids, tint = not WCOverlays.UNTINTED[def.library],
    }
    WCOverlays.layers[index] = layer
    WCOverlays.byId[def.id] = layer
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
