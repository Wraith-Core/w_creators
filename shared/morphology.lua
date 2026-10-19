-- =====================================================================
--  shared/morphology.lua  —  WCMorph (ARCHITECTURE.md §5.2)
--  The face and body morphology hierarchy. Field ids are w_lib's expression names; the numeric
--  expression ids are read from w.component.data.expressions at runtime (never hardcoded here).
--  Storage is -1..1 (app.morph[id]); the NUI shows -100..+100.
--
--  Node = { id, label, section, fields = { expressionName... }, extras = { control ids... },
--           children = { Node... } }
--  extras name the non-morph controls that live at that node of the tree (§8.4) so the editor
--  tree builder can place them (base head, teeth, eye colour, eyebrow overlay, body build).
-- =====================================================================

WCMorph = {}

local FACE, BODY = 'face', 'body'

-- Each field: { expressionName, label key[, pose] }. The label keys are the pre-v3 creator's
-- (data/features.lua), including their direction hints ('· عريض' = the +100 end of the slider).
-- pose = 'profile': a depth the editor shows from the side (the character turns while it moves,
-- Config.Creator.profileTurn): a jaw's depth or an ear's angle cannot be judged from the front.
local TREE = {
    {
        id = 'face', label = 'الوجه', section = FACE,
        children = {
            { id = 'face.base', label = 'الهيئة', extras = { 'face.head' } },
            { id = 'face.shape', label = 'شكل الرأس', fields = {
                { 'headWidth', 'عرض الرأس' }, { 'faceWidth', 'عرض الوجه' } } },
            { id = 'face.jaw', label = 'الفكّ', fields = {
                { 'jawWidth', 'الفكّ · عريض' }, { 'jawHeight', 'الارتفاع' }, { 'jawDepth', 'الفكّ · غائر', 'profile' },
                { 'jawY', 'إزاحة الفكّ' } } },
            { id = 'face.chin', label = 'الذقن', fields = {
                { 'chinWidth', 'العرض' }, { 'chinHeight', 'الارتفاع' }, { 'chinDepth', 'العمق', 'profile' } } },
            { id = 'face.nose', label = 'الأنف', fields = {
                { 'noseWidth', 'الأنف · عريض' }, { 'noseHeight', 'الأنف · أسفل' }, { 'noseSize', 'الحجم' },
                { 'noseAngle', 'الزاوية' }, { 'noseCurvature', 'الانحناء', 'profile' }, { 'nostrilsDistance', 'فتحة الأنف' } } },
            { id = 'face.cheeks', label = 'عظام الوجنة', fields = {
                { 'cheekbonesWidth', 'عظام الوجنة · عريض' }, { 'cheekbonesHeight', 'الارتفاع' }, { 'cheekbonesDepth', 'عظام الوجنة · غائر', 'profile' } } },
            { id = 'face.mouth', label = 'الفم', fields = {
                { 'mouthWidth', 'العرض' }, { 'mouthDepth', 'العمق', 'profile' }, { 'mouthX', 'الموضع الأفقي' },
                { 'mouthY', 'الموضع العمودي' } },
              children = {
                { id = 'face.mouth.left', label = 'زاوية الفم اليسرى', fields = {
                    { 'mouthConerLeftWidth', 'زاوية الفم اليسرى — العرض' },
                    { 'mouthConerLeftDepth', 'زاوية الفم اليسرى — العمق' },
                    { 'mouthConerLeftHeight', 'زاوية الفم اليسرى — الارتفاع' },
                    { 'mouthConerLeftLipsDistance', 'زاوية الفم اليسرى — مسافة الشفة' } } },
                { id = 'face.mouth.right', label = 'زاوية الفم اليمنى', fields = {
                    { 'mouthConerRightWidth', 'زاوية الفم اليمنى — العرض' },
                    { 'mouthConerRightDepth', 'زاوية الفم اليمنى — العمق' },
                    { 'mouthConerRightHeight', 'زاوية الفم اليمنى — الارتفاع' },
                    { 'mouthConerRightLipsDistance', 'زاوية الفم اليمنى — مسافة الشفة' } } },
              } },
            { id = 'face.lips', label = 'الشفاه', children = {
                { id = 'face.lips.upper', label = 'الشفة العليا', fields = {
                    { 'upperLipWidth', 'العرض' }, { 'upperLipHeight', 'الارتفاع' }, { 'upperLipDepth', 'العمق', 'profile' } } },
                { id = 'face.lips.lower', label = 'الشفة السفلى', fields = {
                    { 'lowerLipWidth', 'العرض' }, { 'lowerLipHeight', 'الارتفاع' }, { 'lowerLipDepth', 'العمق', 'profile' } } },
            } },
            { id = 'face.ears', label = 'الأذنان', fields = {
                { 'earsWidth', 'العرض' }, { 'earsHeight', 'الارتفاع' }, { 'earsAngle', 'الزاوية', 'profile' },
                { 'earsDepth', 'عمق الأذنين', 'profile' }, { 'earlobes', 'الحجم', 'profile' } } },
            { id = 'face.eyes', label = 'العينان', extras = { 'eyes.color' }, fields = {
                { 'eyesDistance', 'موضع العين · متباعد' }, { 'eyesHeight', 'موضع العين · أسفل' },
                { 'eyesAngle', 'محجر العين · ميلٌ للخارج' }, { 'eyesDepth', 'محجر العين · ضحل', 'profile' }, { 'eyelidWidth', 'عرض الجفن' }, { 'eyelidHeight', 'ارتفاع الجفن' },
                { 'eyelidLeft', 'الجفن الأيسر' }, { 'eyelidRight', 'الجفن الأيمن' } } },
            { id = 'face.eyebrows', label = 'الحاجبان', extras = { 'overlay.eyebrows' }, fields = {
                { 'eyebrowWidth', 'العرض' }, { 'eyebrowHeight', 'الارتفاع' }, { 'eyebrowDepth', 'العمق', 'profile' } } },
            { id = 'face.teeth', label = 'الأسنان', extras = { 'face.teeth' } },
        },
    },
    {
        id = 'body', label = 'الجسد', section = BODY,
        children = {
            { id = 'body.build', label = 'البنية', extras = { 'body.type', 'body.shape', 'body.height', 'body.weight', 'body.voice' } },
            { id = 'body.upper', label = 'الجزء العلوي', fields = {
                { 'shoulders', 'الكتفان' }, { 'shoulderThickness', 'سماكة الكتف', 'profile' },
                { 'shoulderBlades', 'لوحا الكتف', 'profile' }, { 'chest', 'الصدر', 'profile' }, { 'arms', 'الذراعان' } } },
            { id = 'body.torso', label = 'الجذع', fields = {
                { 'waist', 'البطن' }, { 'hip', 'المؤخّرة' } } },
            { id = 'body.legs', label = 'الرجلان', fields = {
                { 'thighs', 'الفخذان' }, { 'calves', 'الساقان' } } },
            { id = 'body.neck', label = 'الرقبة', fields = {
                { 'neckWidth', 'عرض الرقبة' }, { 'neckDepth', 'عمق الرقبة', 'profile' } } },
        },
    },
}

local function expressions()
    local ok, tbl = pcall(function() return w.component.data.expressions end)
    return ok and type(tbl) == 'table' and tbl or nil
end

--- (Re)build fields/groups/byId/byExpression from the tree and w_lib's expression table.
function WCMorph.build()
    local ids = expressions()
    if not ids then
        WCDebug.warn('morph', 'w.component.data.expressions is unavailable - no morphology fields')
        ids = {}
    end
    local fields, byId, byExpression = {}, {}, {}

    local function node(src, section)
        local out = { id = src.id, label = src.label, section = src.section or section,
                      fields = {}, extras = src.extras and WCUtil.copy(src.extras) or {}, children = {} }
        for _, def in ipairs(src.fields or {}) do
            local name, label = def[1], def[2]
            local expression = tonumber(ids[name])
            if expression then
                local field = { id = name, expression = expression, group = src.id, label = label,
                                min = -1, max = 1, section = out.section, pose = def[3] }
                fields[#fields + 1] = field
                byId[name] = field
                byExpression[expression] = field
                out.fields[#out.fields + 1] = name
            end
        end
        for _, child in ipairs(src.children or {}) do
            out.children[#out.children + 1] = node(child, out.section)
        end
        return out
    end

    local groups = {}
    for _, top in ipairs(TREE) do groups[#groups + 1] = node(top, top.section) end

    for name in pairs(ids) do
        if not byId[name] then
            WCDebug.warn('morph', 'w_lib expression %s is not placed in the morphology tree', tostring(name))
        end
    end

    WCMorph.fields, WCMorph.groups, WCMorph.byId, WCMorph.byExpression = fields, groups, byId, byExpression
end

--- 'face' | 'body' for a field id (nil when unknown).
function WCMorph.sectionOf(id)
    local field = WCMorph.byId[id]
    return field and field.section or nil
end

WCMorph.build()
