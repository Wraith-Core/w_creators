-- =====================================================================
--  client/editor/editor.lua  —  WCEditor (ARCHITECTURE.md §3.2, §8)
--  The one appearance editor session (creator, surgery, barber, store, wardrobe).
--
--  session = { id, mode, ped, working, saved, history (undo, max 30), registry (control -> entry),
--              busy, opts, context, sections, draft, cache, camera, parkedCamera }
--  Every NUI value is validated against the session registry (built with the tree by
--  WCEditorTree) and clamped; mutations go through AppearanceSchema / WCRules on a copy of the
--  working appearance, the ped is updated with Appearance.ApplyDiff(ped, before, after) and a
--  failed render reverts to `before` (INVALID_COMPONENT). One operation at a time per session.
--
--  NUI callbacks: editor:action { id, op, control?, value?, values?, identity?, opId }
--                 editor:camera { id, preset? | rotate? | zoom? | reset? | pick? | hide? }
--  Both answer { ok, code?, message? (translated), payload?, closed?, camera? }. An operation made
--  while another runs is BUSY; a camera request is parked instead (latest wins) and answered once
--  applied, when the operation ends.
-- =====================================================================

WCEditor = {}
local E = WCEditor
-- WCEditorTree (client/editor/tree.lua) loads before this file (fxmanifest); it is read at call time.

local current = nil
local opening = false   -- an open in progress (it can yield while rendering)
local sequence = 0
local HISTORY_MAX = 30
local MAX_MANY = 8
local MAX_CONTROL = 96
local MAX_OPID = 64

local MODES = { creator = true, surgery = true, barber = true, store = true, wardrobe = true }

-- The chrome strings (all dictionary keys). Sent translated as payload.strings. The header wordmark
-- is not one of them: it is a fixed brand mark in the NUI (web/src/brand.js).
local STRINGS = {
    appearance = 'مظهر الشخصية',
    back = 'رجوع',
    close = 'إغلاق',
    undo = 'تراجع',
    reset = 'استعادة الأصل',
    random = 'مظهر عشوائي',
    search = 'بحث…',
    none = 'بدون',
    empty = 'لا توجد نتائج مطابقة.',
    saving = 'جارٍ التطبيق…',
    confirm = 'تأكيد',
    stay = 'متابعة التعديل',
    discard = 'تجاهل التعديلات',
    save = 'حفظ',
    leaveTitle = 'تعديلات غير محفوظة',
    leave = 'سيتم إلغاء التعديلات غير المحفوظة.',
    resetBody = 'ستعود كل التعديلات إلى المظهر الأصلي.',
    dangerBody = 'لا يمكن التراجع عن هذا الإجراء.',
    total = 'الإجمالي',
    free = 'مجاني',
    center = 'توسيط',
    padHelp = 'اسحب النقطة أو استخدم الأسهم · Shift لضبط أسرع',
    advanced = 'خيارات متقدمة',
    -- the notebook lines (web/src/Editor.jsx): the head sentence per mode, the money in it, the
    -- readiness line above the buttons ('%s' is a list of fields or an amount) and the keys row
    ['lead.creator'] = 'اصنع شخصيتك خطوة بعد خطوة، ثم اعتمدها',
    ['lead.surgery'] = 'غيّر ملامح الوجه والجسد',
    ['lead.barber'] = 'قصة وتسريحة',
    ['lead.store'] = 'جرّب الملابس وادفع لما تشتريه فقط',
    ['lead.wardrobe'] = 'البس من ملابسك واحفظ أطقمك',
    sumTotal = 'المجموع %s',
    youHave = 'معك %s',
    missingFor = 'ينقصه: %s',
    needsFix = 'يحتاج تصحيحًا: %s',
    fixIt = 'أصلحه',
    shortBy = 'ينقصك %s',
    readyPay = 'جاهز · ستدفع %s',
    willPay = 'ستدفع %s',
    ready = 'جاهز',
    readyFree = 'جاهز · بلا تكلفة',
    noChange = 'لم تغيّر شيئًا بعد',
    keyMove = 'تنقّل',
    keyPick = 'اختيار',
    -- 1.1.0: the board's wordmark (the masthead of the editor and the clothing panel), from the locales
    brand = 'ريد ريفر · استوديو الشخصيات',
    -- ★ The per-field identity messages. They SAY THE RULE: the old single 'INVALID_NAME' left the
    --   player guessing why "test2" was refused (the digit), after the whole character was built.
    INVALID_NAME = 'حروف فقط — بلا أرقام أو رموز (تُقبل المسافة والفاصلة العليا والشرطة)',
    INVALID_DOB = 'تاريخ ميلاد غير مقبول',
    identityInvalid = 'قيمة غير صالحة',
    camera = 'الكاميرا',
    clickZoom = 'اضغط على جزء لتقريبه',
    dragRotate = 'اسحب للتدوير',
    rightReset = 'زر يمين: الجسم كاملًا',
    nameHint = 'أكمل اسم الشخصية من قسم الهوية.',
    details = 'اختر القسم الذي تريد تعديله.',
    error = 'تعذر إكمال الطلب، حاول مجددًا.',
    owned = 'مملوكة',
    equipped = 'مرتداة',
    locked = 'مقفلة',
    new = 'جديدة',
    apply = 'تطبيق',
    price = 'السعر',
    variants = 'التنويعات',
    hideClothes = 'إخفاء الملابس',
    showClothes = 'إظهار الملابس',
    -- the store: an amount in gold ('%s' is the number) and the owned colours on an item card
    goldAmount = '%s ذهب',
    ownedColors = 'ألوانك المملوكة',
    -- the date of birth picker (web/src/DateField.jsx): its three parts and the month names; the
    -- value it sends is still 'YYYY-MM-DD' inside the field's min / max (dobBounds)
    day = 'اليوم',
    month = 'الشهر',
    year = 'السنة',
    ['month.1'] = 'يناير',
    ['month.2'] = 'فبراير',
    ['month.3'] = 'مارس',
    ['month.4'] = 'أبريل',
    ['month.5'] = 'مايو',
    ['month.6'] = 'يونيو',
    ['month.7'] = 'يوليو',
    ['month.8'] = 'أغسطس',
    ['month.9'] = 'سبتمبر',
    ['month.10'] = 'أكتوبر',
    ['month.11'] = 'نوفمبر',
    ['month.12'] = 'ديسمبر',
    ['view.fullBody'] = 'الجسم كاملًا',
    ['view.upperBody'] = 'الجزء العلوي',
    ['view.lowerBody'] = 'الجزء السفلي',
    ['view.head'] = 'الرأس',
    ['view.face'] = 'الوجه',
    ['view.eyes'] = 'العينان',
    ['view.teeth'] = 'الأسنان',
    ['view.hair'] = 'الشعر',
    ['view.facialHair'] = 'اللحية',
    ['view.hands'] = 'اليدان',
    ['view.handLeft'] = 'اليد اليسرى',
    ['view.handRight'] = 'اليد اليمنى',
    ['view.feet'] = 'القدمان',
    ['view.accessories'] = 'الإكسسوارات',
}
E.STRINGS = STRINGS

local TITLES = {
    creator = 'بناء الشخصية', surgery = 'عيادة التجميل', barber = 'الحلاق', store = 'متجر الملابس',
    wardrobe = 'خزانة الملابس',
}
local SAVE_LABELS = {
    creator = 'إنهاء الشخصية', surgery = 'تأكيد العملية', barber = 'تأكيد الحلاقة', store = 'شراء وارتداء',
    wardrobe = 'ارتداء',
}
local CONFIRM = {
    creator = { title = 'اعتماد المظهر؟', body = 'سيتم إنشاء الشخصية بهذا المظهر.' },
    surgery = { title = 'تأكيد العملية', body = 'ستُطبَّق التعديلات على مظهر الشخصية.' },
    barber = { title = 'اعتماد المظهر؟', body = 'سيتم حفظ المظهر الجديد.' },
    store = { title = 'اعتماد المظهر؟', body = 'سيتم شراء القطع الجديدة وارتداؤها.' },
    wardrobe = { title = 'اعتماد المظهر؟', body = 'سيتم حفظ المظهر الجديد.' },
}
local PROMPT_ROTATE, PROMPT_BACK = 'تدوير الشخصية', 'رجوع'

local DEFAULT_CAMERA = { creator = 'fullBody', surgery = 'face', barber = 'hair', store = 'fullBody',
                         wardrobe = 'fullBody' }

local function L(key, ...)
    if type(locale) == 'function' then return locale(key, ...) end
    return key
end

local function uiLocale()
    if type(UiLocale) == 'function' then
        local ok, value = pcall(UiLocale)
        if ok and value then return value end
    end
    return 'en'
end

local function uiDir()
    if type(UiDir) == 'function' then
        local ok, value = pcall(UiDir)
        if ok and value then return value end
    end
    return uiLocale() == 'ar' and 'rtl' or 'ltr'
end
E.uiLocale, E.uiDir = uiLocale, uiDir

--- The translated chrome strings.
function E.strings()
    local out = {}
    for key, value in pairs(STRINGS) do out[key] = L(value) end
    return out
end

-- Safe calls into services owned by other modules (camera, state, pipeline).
local function try(fn, ...)
    if type(fn) ~= 'function' then return false end
    local ok, a, b = pcall(fn, ...)
    if not ok then
        WCDebug.warn('editor', 'call failed: %s', tostring(a))
        return false
    end
    return true, a, b
end

local function camera(name, ...)
    local cam = WCCamera
    if type(cam) ~= 'table' then return false end
    return try(cam[name], ...)
end

-- The client 'editor' lock (WCState): taken on open, released on close only when this session took it.
local function lockEditor()
    if type(WCState) ~= 'table' or type(WCState.busy) ~= 'function' then return false end
    local ok, acquired = try(WCState.busy, 'editor', true)
    return ok and acquired == true
end

local function unlockEditor(s)
    if s.ownsLock and type(WCState) == 'table' and type(WCState.busy) == 'function' then
        try(WCState.busy, 'editor', false)
    end
    s.ownsLock = nil
end

local function focus(on)
    if type(SetNuiFocus) == 'function' then SetNuiFocus(on, on) end
    if type(SetNuiFocusKeepInput) == 'function' then SetNuiFocusKeepInput(false) end
end

local function send(message)
    if type(SendNUIMessage) == 'function' then SendNUIMessage(message) end
end

-- ---------------------------------------------------------------------
--  Character card (§8.1 charCard): the selector's info panel
-- ---------------------------------------------------------------------
-- The card labels (dictionary keys), sent translated as charCard.strings.
local CARD_STRINGS = {
    name = 'الاسم', age = 'العمر', dob = 'تاريخ الميلاد', gender = 'الجنس', lastLocation = 'آخر موقع',
    job = 'المهنة', cash = 'النقد', bank = 'البنك', gold = 'الذهب',
    citizenId = 'رقم المواطن', blocked = 'موقوفة — راجع الإدارة',
}
E.CARD_STRINGS = CARD_STRINGS

--- The translated card labels.
function E.cardStrings()
    local out = {}
    for key, value in pairs(CARD_STRINGS) do out[key] = L(value) end
    return out
end

local CARD_FIELDS = { 'citizenId', 'name', 'age', 'dob', 'gender', 'lastLocation', 'job', 'cash', 'bank', 'gold', 'blocked' }

--- The charCard message for a characters:list card ({ name, age, dob, sex|gender, lastLocation,
--  job, cash, bank, gold }); nil card = hide. lastLocation and a sex are locale keys / values and
--  are translated here; the NUI only displays.
function E.cardPayload(card)
    local msg = { type = 'charCard', show = type(card) == 'table', locale = uiLocale(), dir = uiDir(),
                  strings = E.cardStrings() }
    if type(card) ~= 'table' then return msg end
    for _, key in ipairs(CARD_FIELDS) do msg[key] = card[key] end
    if msg.gender == nil and (card.sex == 'male' or card.sex == 'female') then
        msg.gender = L(card.sex == 'male' and 'ذكر' or 'أنثى')
    end
    if type(msg.lastLocation) == 'string' then msg.lastLocation = L(msg.lastLocation) end
    return msg
end

--- Show (card) or hide (nil) the character card.
function E.showCard(card)
    send(E.cardPayload(card))
end

-- ---------------------------------------------------------------------
--  Sections
-- ---------------------------------------------------------------------
local function defaultSections(mode, sex)
    if mode == 'creator' then return AppearanceSchema.SECTIONS end
    if mode == 'store' then return { 'clothing' } end
    if mode == 'wardrobe' then return { 'clothing', 'states' } end
    if mode == 'barber' then return sex == 'male' and { 'hair', 'facialHair' } or { 'hair' } end
    if mode == 'surgery' then
        local out = {}
        for section, allowed in pairs(Config.CosmeticSurgery and Config.CosmeticSurgery.allow or {}) do
            if allowed then out[#out + 1] = section end
        end
        return out
    end
    return {}
end

local function sectionSet(mode, opts, sex)
    local list = opts.sections
    if type(list) ~= 'table' then list = defaultSections(mode, sex) end
    local set = {}
    for key, value in pairs(list) do
        if type(key) == 'number' and type(value) == 'string' then set[value] = true
        elseif type(key) == 'string' and value == true then set[key] = true end
    end
    if sex ~= 'male' then set.facialHair = nil end
    return set
end

-- ---------------------------------------------------------------------
--  Payload
-- ---------------------------------------------------------------------
local function isDirty(s)
    return not WCUtil.deepEqual(s.working, s.saved)
end

local function canSave(s)
    if s.mode == 'creator' then return true end
    return isDirty(s)
end

--- A locked identity (identity.locked = true: the repair path of a character whose framework
--  identity already exists) is shown read-only and never submitted.
local function identityLocked(s)
    return type(s.opts.identity) == 'table' and s.opts.identity.locked == true
end

local DAYS_IN = { 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 }
local function daysIn(y, m)
    if m == 2 and ((y % 4 == 0 and y % 100 ~= 0) or y % 400 == 0) then return 29 end
    return DAYS_IN[m]
end

--- The date-picker window of the DOB field: exactly the dates WCIdentity.validateDob accepts.
--  With a referenceYear the age is `referenceYear - year` (whole years); otherwise it is the exact
--  age on today's date (WCUtil.today), so the youngest birthday is today minAge years ago (Feb 29 in
--  a common year -> Feb 28) and the oldest the day after today maxAge + 1 years ago. Unknown date
--  -> no bounds (the server validates the age anyway). Returns min, max ('YYYY-MM-DD' | nil).
local function dobBounds(referenceYear, minAge, maxAge)
    if referenceYear then
        return ('%04d-01-01'):format(referenceYear - maxAge), ('%04d-12-31'):format(referenceYear - minAge)
    end
    local today = WCUtil.today()
    local y, m, d = today and tonumber(today.year), today and tonumber(today.month), today and tonumber(today.day)
    if not (y and m and d) or m < 1 or m > 12 or d < 1 then return nil, nil end
    local maxY = y - minAge
    local max = ('%04d-%02d-%02d'):format(maxY, m, math.min(d, daysIn(maxY, m)))
    local minY, minM, minD = y - maxAge - 1, m, d + 1
    if minD > daysIn(minY, minM) then
        minD, minM = 1, minM + 1
        if minM > 12 then minM, minY = 1, minY + 1 end
    end
    return ('%04d-%02d-%02d'):format(minY, minM, minD), max
end
E.dobBounds = dobBounds

-- The sex line of the identity form: the sex was chosen on the stage, so the NUI shows it as the
-- two-way switch (choices) with the chosen side marked, never as an input. The hint says how to
-- change it, only when the editor's root Back returns to the gender choice (opts.keepDraft).
local SEX_HINT = 'اختير على المسرح، ولتغييره «تغيير الجنس».'

local function sexField(s)
    return { key = 'sex', label = L('الجنس'), type = 'info',
             value = L(s.working.sex == 'male' and 'ذكر' or 'أنثى'),
             choices = { L('ذكر'), L('أنثى') },
             hint = s.opts.keepDraft == true and L(SEX_HINT) or nil }
end

local function identityPayload(s)
    local id = s.opts.identity
    if type(id) ~= 'table' then return nil end
    local function text(v) return type(v) == 'string' and v or '' end
    if id.locked == true then
        return {
            locked = true,
            fields = {
                { key = 'firstname', label = L('الاسم الأول'), type = 'info', value = text(id.firstname) },
                { key = 'lastname', label = L('اسم العائلة'), type = 'info', value = text(id.lastname) },
                { key = 'dob', label = L('تاريخ الميلاد'), type = 'info', value = text(id.dob) },
                sexField(s),
            },
        }
    end
    local cfg = Config.Characters and Config.Characters.identity or {}
    -- the client has no os library: the reference year, else the date the server publishes
    -- (WCUtil.today); unknown -> no min/max on the field (the server validates the age anyway)
    local minAge, maxAge = tonumber(cfg.minAge) or 18, tonumber(cfg.maxAge) or 90
    local dobMin, dobMax = dobBounds(tonumber(cfg.referenceYear), minAge, maxAge)
    local nameMax = tonumber(cfg.nameMax) or 25
    return {
        fields = {
            { key = 'firstname', label = L('الاسم الأول'), type = 'text', maxLength = nameMax,
              value = type(id.firstname) == 'string' and id.firstname or '' },
            { key = 'lastname', label = L('اسم العائلة'), type = 'text', maxLength = nameMax,
              value = type(id.lastname) == 'string' and id.lastname or '' },
            { key = 'dob', label = L('تاريخ الميلاد'), type = 'date',
              min = dobMin, max = dobMax,
              value = type(id.dob) == 'string' and id.dob or '' },
            sexField(s),
        },
    }
end

--- The store's "save this look as an outfit" field of the save confirmation: offered while the
--  store lists the saved outfits (Config.Locations[].outfits, the savedOutfits service) and the
--  character is under the limit. nil otherwise.
local function saveOutfitField(s)
    if s.mode ~= 'store' or s.context.outfitsEnabled ~= true or type(s.context.outfits) ~= 'table' then return nil end
    local max = WCUtil.int(s.context.maxOutfits, 0, nil, 0)
    if #s.context.outfits >= max then return nil end
    return { label = L(WCEditorTree.KEYS.saveOutfit), placeholder = L(WCEditorTree.KEYS.outfitName),
             maxLength = WCUtil.int(Config.Wardrobe and Config.Wardrobe.outfitNameMax, 1, 64, 24) }
end

--- Build the NUI payload of a session (rebuilds the tree and the control registry).
-- The player's own money for the head sentence ("you have $85") and the readiness line ("$4 short")
-- of a paid visit: the framework's local player data (RSG / QBR / w_core through w_lib), read at most
-- every 2 s (a slider drag pushes many payloads). nil (VORP keeps no local data, an error) = not shown;
-- the server still checks the money at the commit, this is only a hint.
local WALLET_TTL = 2000
local walletCache = { at = nil, value = nil }
local function wallet()
    local now = type(GetGameTimer) == 'function' and GetGameTimer() or 0
    if walletCache.at and now - walletCache.at < WALLET_TTL and now >= walletCache.at then return walletCache.value end
    walletCache.at = now
    local ok, pd = pcall(function() return exports.w_lib:FwGetPlayerData() end)
    local m = ok and type(pd) == 'table' and type(pd.money) == 'table' and pd.money or nil
    local cash, gold = m and tonumber(m.cash), m and tonumber(m.gold)
    walletCache.value = (cash or gold) and { cash = cash, gold = gold } or nil
    return walletCache.value
end

function E.payload(s)
    s = s or current
    if not s then return nil end
    local root, registry = WCEditorTree.build(s)
    s.registry = registry
    local confirm = CONFIRM[s.mode] or CONFIRM.store
    local price = WCEditorTree.price(s)
    -- an item without a price in the chosen currency: the save waits until the player picks another
    local blocked = price and type(price.missing) == 'table' and #price.missing > 0
        and L(WCEditorTree.KEYS.missingCurrency, table.concat(price.missing, L('، '))) or nil
    return {
        type = 'editor',
        session = { id = s.id, mode = s.mode, title = L(s.opts.title or TITLES[s.mode]),
                    subtitle = s.opts.subtitle and L(s.opts.subtitle) or nil, locale = uiLocale(), dir = uiDir() },
        strings = E.strings(),
        stages = WCEditorTree.stages(s, root),
        tree = root,
        price = price,
        wallet = price and s.mode ~= 'creator' and wallet() or nil,
        identity = s.mode == 'creator' and identityPayload(s) or nil,
        dirty = isDirty(s),
        canSave = canSave(s) and not blocked,
        saveBlocked = blocked,
        saveOutfit = saveOutfitField(s),
        canUndo = #s.history > 0,
        canRandom = s.mode == 'creator',
        saveLabel = L(s.opts.saveLabel or SAVE_LABELS[s.mode]),
        -- The root Back of the creator returns to the gender choice and keeps the look as a draft:
        -- it gets its own label and closes without the "unsaved changes" question (nothing is lost).
        backLabel = s.opts.backLabel and L(s.opts.backLabel) or nil,
        backDirect = s.opts.keepDraft == true or nil,
        -- the clothes / hair can be taken off the preview to judge the face and body (creator only:
        -- the private scene; a player ped elsewhere would be seen undressed by others)
        canHide = s.mode == 'creator' or nil,
        hidden = s.hidden == true or nil,
        confirm = { title = L(confirm.title), body = L(confirm.body), confirmLabel = L('تأكيد') },
        camera = s.camera,
    }
end

local function push(s)
    if s and current == s then send(E.payload(s)) end
end

-- ---------------------------------------------------------------------
--  Prompts (the pre-v3 on-screen hints; optional)
-- ---------------------------------------------------------------------
-- The board stands at the start side of the screen (the right in Arabic), so the key hints go to
-- the bottom corner of the other side, where nothing covers them.
local function promptPosition()
    return uiDir() == 'rtl' and 'bottom-left' or 'bottom-right'
end

local function openPrompts(s)
    if type(w) ~= 'table' or type(w.prompt) ~= 'table' or type(w.prompt.createGroup) ~= 'function' then return end
    local ok, group = pcall(w.prompt.createGroup, L(s.opts.title or TITLES[s.mode]), promptPosition())
    if not ok or type(group) ~= 'table' then return end
    pcall(function()
        group.addPrompt('MOUSEDRAG', L(PROMPT_ROTATE), false)
        group.addPrompt('ESCAPE', L(PROMPT_BACK), false)
        group.display()
    end)
    s.prompts = group
end

local function closePrompts(s)
    if s.prompts then pcall(s.prompts.delete) end
    s.prompts = nil
end

local function relabelPrompts(s)
    if not s.prompts then return end
    pcall(function()
        s.prompts.setTitle(L(s.opts.title or TITLES[s.mode]))
        s.prompts.setLabel('MOUSEDRAG', L(PROMPT_ROTATE))
        s.prompts.setLabel('ESCAPE', L(PROMPT_BACK))
    end)
end

-- ---------------------------------------------------------------------
--  Lifecycle
-- ---------------------------------------------------------------------

-- Build a session, take the editor lock, render (opts.render) and build its first payload.
-- Returns s | nil, code; on failure everything taken here is released again.
local function prepareSession(ped, mode, app, opts)
    local saved = AppearanceSchema.normalize(app)
    -- opts.working: the look to resume (the creator's draft of this gender, kept while the player
    -- went back to the gender choice). Reset still goes back to `saved`. A draft of another sex is
    -- not this session's look and is ignored.
    local working = WCUtil.copy(saved)
    if type(opts.working) == 'table' then
        local draft = AppearanceSchema.normalize(opts.working)
        if type(draft) == 'table' and draft.sex == saved.sex then working = draft end
    end
    sequence = sequence + 1
    local s = {
        id = sequence, mode = mode, ped = ped, saved = saved, working = working, history = {},
        registry = {}, busy = false, opts = opts, revision = 0,
        context = type(opts.context) == 'table' and opts.context or {},
        sections = sectionSet(mode, opts, saved.sex), draft = { outfitName = '' }, cache = {},
    }
    s.camera = WCEditorTree.PRESET_SET[opts.camera] and opts.camera or DEFAULT_CAMERA[mode]
    s.ownsLock = lockEditor()
    if type(WCPanel) == 'table' and WCPanel.isOpen() then try(WCPanel.close) end
    if opts.render then
        local called, done, err = try(Appearance and Appearance.RestoreCharacter, ped, s.working)
        if not called or not done then
            WCDebug.log('editor', 'initial render failed: %s', tostring(err))
            unlockEditor(s)
            return nil, 'INVALID_COMPONENT'
        end
    end
    local built, payload = pcall(E.payload, s)
    if not built or type(payload) ~= 'table' then
        WCDebug.warn('editor', 'first payload failed: %s', tostring(payload))
        unlockEditor(s)
        return nil, 'INTERNAL_ERROR'
    end
    s.firstPayload = payload
    return s
end

--- Open an editor session. Returns true | false, code.
--  opts: title, subtitle, sections, context, identity (creator), onCommit(working, extra) -> Result,
--        onCancel(working?, identity?), onOutfit(op, id, value, session) -> Result (op 'equip' is a
--        veto hook: nil or ok applies the owned outfit locally, a failed Result refuses it;
--        'update' | 'rename' | 'delete' | 'save' call the server and may return data.outfits),
--        onState(group, value) -> Result, camera,
--        saveLabel, render (true = render the working look on the ped first),
--        working (the look to resume instead of a copy of `app`),
--        keepDraft (cancel leaves the ped showing the working look and hands it, with the typed
--          identity, to onCancel; the root Back closes without asking), backLabel (its label),
--        keepCamera (closing leaves WCCamera to the caller, so its next shot glides from here).
function E.open(ped, mode, app, opts)
    if current or opening then return false, 'BUSY' end
    if not MODES[mode] then return false, 'INVALID_PAYLOAD' end
    if not ped or ped == 0 or (type(DoesEntityExist) == 'function' and not DoesEntityExist(ped)) then
        return false, 'INVALID_PAYLOAD'
    end
    opts = type(opts) == 'table' and opts or {}
    -- reserved before anything that can yield (the render waits on the ped): a second open from
    -- another thread is BUSY until this one is committed or rolled back
    opening = true
    local ok, s, code = pcall(prepareSession, ped, mode, app, opts)
    if not ok then
        WCDebug.warn('editor', 'open failed: %s', tostring(s))
        s, code = nil, 'INTERNAL_ERROR'
    end
    if not s then
        opening = false
        return false, code or 'INTERNAL_ERROR'
    end
    -- committed only once the first payload exists: no focus without a rendered NUI
    current = s
    opening = false
    -- the column stands on the right in both languages: the actor is framed clear of it
    camera('open', ped, s.camera, { panel = 'right' })
    focus(true)
    openPrompts(s)
    send(s.firstPayload)
    s.firstPayload = nil
    WCDebug.log('editor', 'open %s session %d', mode, s.id)
    return true
end

-- ---------------------------------------------------------------------
--  The mouth on the teeth view (Config.Creator.teethAnimation): the game's own "dentistry" face
--  clips open the mouth so the teeth can be judged; they close again when the view changes.
-- ---------------------------------------------------------------------
local MOUTH_DICT_MS, MOUTH_ENTER_MS = 1500, 1500

local function animDictLoaded(dict)
    if type(RequestAnimDict) ~= 'function' or type(HasAnimDictLoaded) ~= 'function' then return false end
    pcall(RequestAnimDict, dict)
    return WCUtil.waitUntil(function()
        local ok, loaded = pcall(HasAnimDictLoaded, dict)
        -- BOOL natives answer 1 (not true) on this runtime
        return (ok and (loaded == true or loaded == 1)) or nil
    end, MOUTH_DICT_MS, 0) ~= nil
end

local function clipPlaying(ped, dict, clip)
    if type(IsEntityPlayingAnim) ~= 'function' then return false end
    local ok, playing = pcall(IsEntityPlayingAnim, ped, dict, clip, 3)
    return ok and (playing == true or playing == 1)
end

--- Open (true) or close (false) the mouth of the session's ped. Upper-body clips (flag 16, looped
--  17) so a frozen preview ped keeps standing; a newer call supersedes a pending one.
local function mouth(s, open)
    local clips = Config.Creator and Config.Creator.teethAnimation
    if type(clips) ~= 'table' or type(clips.dict) ~= 'string' then return end
    open = open == true
    if (s.mouthOpen == true) == open then return end
    s.mouthOpen = open
    s.mouthGen = (s.mouthGen or 0) + 1
    local gen, ped = s.mouthGen, s.ped
    CreateThread(function()
        if not animDictLoaded(clips.dict) or s.mouthGen ~= gen then return end
        if type(TaskPlayAnim) ~= 'function' or not ped or not DoesEntityExist(ped) then return end
        if not open then
            pcall(TaskPlayAnim, ped, clips.dict, clips.exit, 4.0, -2.0, -1, 16, 0.0, false, 0, false)
            return
        end
        pcall(TaskPlayAnim, ped, clips.dict, clips.enter, 2.0, -2.0, -1, 16, 0.0, false, 0, false)
        -- the loop takes over once the opening clip has played (MOUTH_ENTER_MS at most)
        WCUtil.waitUntil(function()
            return (s.mouthGen ~= gen or not clipPlaying(ped, clips.dict, clips.enter)) or nil
        end, MOUTH_ENTER_MS, 50)
        if s.mouthGen ~= gen or not DoesEntityExist(ped) then return end
        pcall(TaskPlayAnim, ped, clips.dict, clips.loop, 8.0, -2.0, -1, 17, 0.0, false, 0, false)
    end)
end
E.mouth = mouth

-- ---------------------------------------------------------------------
--  Camera requests that arrive while the editor is busy
--  An operation (a live preview, a set, a save) can yield while the ped renders. A camera request
--  that came in meanwhile used to be refused and was lost: the owner opened head › mask during a
--  preview, the camera stayed on the whole body and the header kept naming it. Such a request is
--  parked instead, applied the moment the operation ends (before the next one can start) and only
--  then answered, so the view the NUI names is always the one the camera took. Latest wins, per slot:
--    view  a preset, a pick or a reset: a newer one replaces the parked one. It is applied before
--          the parked turn / zoom, so a pick hits the framing the player clicked on. No view resets
--          the heading the player gave the character and a preset keeps the zoom, so those stay and
--          end where arrival order leaves them; a reset or a pick zeroes the zoom, so it drops a
--          parked zoom (applied after it, the zoom would land on the new framing);
--    turn, zoom  relative steps (a drag sends many): a newer step is added to the parked one;
--    hide  the hide-clothes toggle changes what is drawn, not where the camera looks: its own slot,
--          so the clothing stage's "put the clothes back on" is never lost to the view sent with it.
--  A replaced request is answered { ok = false } at once: the NUI keeps what it shows until the
--  latest one lands.
-- ---------------------------------------------------------------------
local PARK_ORDER = { 'hide', 'view', 'turn', 'zoom' }
local PARK_STEPS = {
    -- a turn is an angle: the sum wraps (a 340° drag is -20°) instead of stopping at 180°
    turn = { key = 'rotate', min = -180, max = 180, wrap = true },
    -- one zoom request is 4 at most (E.cameraAction), but a wheel burst adds up past it: the sum is
    -- kept up to the camera's whole range (40) and applied in steps of 4 (applyParked)
    zoom = { key = 'zoom', min = -4, max = 4, total = 40 },
}

local function answerCamera(cb, out)
    if type(cb) ~= 'function' then return end
    local ok, err = pcall(cb, out)
    if not ok then WCDebug.warn('editor', 'camera answer failed: %s', tostring(err)) end
end

--- The slot of a camera request, in the branch order of E.cameraAction; nil = nothing to park.
local function parkSlot(data)
    if data.hide ~= nil then return 'hide' end
    if data.reset or type(data.pick) == 'table' then return 'view' end
    if data.rotate ~= nil then return 'turn' end
    if data.zoom ~= nil then return 'zoom' end
    if data.preset ~= nil then return 'view' end
    return nil
end

--- Park a camera request behind the running operation (the latest per slot). Returns false when
--  there is nothing to park (the caller refuses it right away, as before).
local function parkCamera(s, data, cb)
    local slot = parkSlot(data)
    if not slot then return false end
    local parked = s.parkedCamera or {}
    local req = { data = data, cb = cb }
    local step = PARK_STEPS[slot]
    if step then
        local value = WCUtil.number(data[step.key], step.min, step.max, nil)
        if not value then return false end
        local prev = parked[slot]
        if prev then
            value = value + prev.data[step.key]
            if step.wrap then
                value = (value + 180) % 360 - 180
            else
                value = math.max(-step.total, math.min(step.total, value))
            end
            answerCamera(prev.cb, { ok = false })
        end
        req.data = { id = data.id, [step.key] = value }
    else
        if parked[slot] then answerCamera(parked[slot].cb, { ok = false }) end
        if slot == 'view' and (data.reset or type(data.pick) == 'table') and parked.zoom then
            answerCamera(parked.zoom.cb, { ok = false })
            parked.zoom = nil
        end
    end
    parked[slot] = req
    s.parkedCamera = parked
    return true
end

--- Apply one parked request. A summed zoom can be larger than one request may be (E.cameraAction
--  takes 4 at most): it goes in steps, and the last step's answer is the request's.
local function applyParked(slot, data)
    local left = data.zoom
    if slot ~= 'zoom' or type(left) ~= 'number' then return E.cameraAction(data) end
    local max = PARK_STEPS.zoom.max
    local out
    repeat
        local stepValue = math.max(-max, math.min(max, left))
        out = E.cameraAction({ id = data.id, zoom = stepValue })
        left = left - stepValue
    until not out.ok or math.abs(left) < 1e-6
    return out
end

--- Apply what was parked, now that the editor is free, each answered with what it did. A parked
--  hide renders (the editor is busy again meanwhile): what arrives then is parked and applied by
--  this same loop.
local function flushCamera(s)
    while current == s and not s.busy and s.parkedCamera do
        local parked, req, taken = s.parkedCamera, nil, nil
        for _, slot in ipairs(PARK_ORDER) do
            if parked[slot] then
                req, taken, parked[slot] = parked[slot], slot, nil
                break
            end
        end
        if not req then
            s.parkedCamera = nil
            break
        end
        local ok, out = pcall(applyParked, taken, req.data)
        if not ok then WCDebug.warn('editor', 'parked camera request failed: %s', tostring(out)) end
        answerCamera(req.cb, ok and out or { ok = false })
    end
end

--- The session closes: nothing parked can be applied any more.
local function dropCamera(s)
    local parked = s.parkedCamera
    s.parkedCamera = nil
    if not parked then return end
    for _, slot in ipairs(PARK_ORDER) do
        if parked[slot] then answerCamera(parked[slot].cb, { ok = false }) end
    end
end

local function closeSession(s)
    if current ~= s then return end
    current = nil
    s.closed = true
    dropCamera(s)
    closePrompts(s)
    send({ type = 'editorClose' })
    focus(false)
    -- the ped leaves the editor facing where it did and with its mouth closed
    mouth(s, false)
    camera('pose', 'front')
    if not s.opts.keepCamera then camera('close') end
    unlockEditor(s)
    WCDebug.log('editor', 'close session %d', s.id)
end

--- Close the current session (no restore: the caller owns what the ped shows next).
function E.close()
    if current then closeSession(current) end
end

function E.session() return current end
--- True while a session is open or being opened.
function E.isOpen() return current ~= nil or opening end
function E.working() return current and WCUtil.copy(current.working) or nil end
function E.saved() return current and WCUtil.copy(current.saved) or nil end
function E.dirty() return current ~= nil and isDirty(current) end

--- Rebuild the tree and push it (e.g. after the context changed).
function E.refresh()
    push(current)
end

-- ---------------------------------------------------------------------
--  Validation
-- ---------------------------------------------------------------------
local function cleanNumber(v)
    if type(v) == 'string' then v = tonumber(v) end
    if type(v) ~= 'number' or not WCUtil.isFinite(v) then return nil end
    return v
end

--- Validate one control/value against the session registry. Returns entry, cleanValue | nil, code.
local function validate(s, control, value, op)
    if type(control) ~= 'string' or #control == 0 or #control > MAX_CONTROL then return nil, 'INVALID_PAYLOAD' end
    local entry = s.registry[control]
    if not entry then return nil, 'INVALID_PAYLOAD' end
    local settable = entry.kind == 'choice' or entry.kind == 'slider'
    if (op == 'set') ~= settable then return nil, 'INVALID_PAYLOAD' end
    if entry.kind == 'choice' then
        local n = cleanNumber(value)
        if not n or n % 1 ~= 0 then return nil, 'INVALID_PAYLOAD' end
        n = math.tointeger(n)
        if entry.range then
            n = math.max(entry.range.min, math.min(entry.range.max, n))
        elseif not entry.values[n] then
            return nil, 'INVALID_PAYLOAD'
        end
        return entry, n
    elseif entry.kind == 'slider' then
        local n = cleanNumber(value)
        if not n then return nil, 'INVALID_PAYLOAD' end
        n = math.max(entry.min, math.min(entry.max, n))
        if entry.integer then n = math.tointeger(math.floor(n + 0.5)) end
        return entry, n
    elseif entry.kind == 'text' then
        if type(value) ~= 'string' then return nil, 'INVALID_PAYLOAD' end
        return entry, WCUtil.trim(WCUtil.clampString(value, entry.maxLength or 64) or '')
    end
    return entry, nil
end
E.validate = validate

-- ---------------------------------------------------------------------
--  Mutations
-- ---------------------------------------------------------------------
local function tbl(v) return type(v) == 'table' and v or {} end

--- The component categories the transition before -> after changes (the pipeline's category names).
--  nil = everything (the sex changed).
local function touchedCategories(before, after)
    if tbl(before).sex ~= tbl(after).sex then return nil end
    local touched = {}
    local function mark(category, a, b) if a ~= b then touched[category] = true end end
    local bb, ab, bh, ah = tbl(before.body), tbl(after.body), tbl(before.head), tbl(after.head)
    mark('BODIES_LOWER', bb.lower, ab.lower)
    mark('BODIES_UPPER', bb.upper, ab.upper)
    mark('heads', bh.head, ah.head)
    mark('eyes', bh.eyes, ah.eyes)
    if not WCUtil.deepEqual(bh.eyesTint, ah.eyesTint) then touched.eyes = true end
    mark('teeth', bh.teeth, ah.teeth)
    local bhair, ahair = tbl(before.hair), tbl(after.hair)
    mark('hair', bhair.style, ahair.style)
    mark('mustache', bhair.facial, ahair.facial)
    local bc, ac = tbl(before.clothing), tbl(after.clothing)
    local be, ae, bt, at = tbl(bc.equipped), tbl(ac.equipped), tbl(bc.tints), tbl(ac.tints)
    local statesChanged = not WCUtil.deepEqual(tbl(bc.states), tbl(ac.states))
    local categories = {}
    for category in pairs(be) do categories[category] = true end
    for category in pairs(ae) do categories[category] = true end
    for category in pairs(categories) do
        if statesChanged or be[category] ~= ae[category] or not WCUtil.deepEqual(tbl(bt[category]), tbl(at[category])) then
            touched[category] = true
        end
    end
    return touched
end

--- What the ped shows of an appearance: with the clothes hidden (s.hidden, the creator's "hide
--  clothes" toggle) the clothing, the hair and the beard are left off. Only the view changes:
--  `working` keeps every piece, so turning the toggle off (or saving) puts them all back.
local function view(s, app)
    if not s.hidden or type(app) ~= 'table' then return app end
    local out = WCUtil.copy(app)
    out.clothing = { equipped = {}, tints = {}, states = {} }
    out.hair = { style = 0, facial = 0 }
    return out
end
E.view = view

--- Render the transition between two views on the ped (Appearance.ApplyDiff).
local function draw(s, before, after)
    local pipeline = Appearance
    if type(pipeline) ~= 'table' or type(pipeline.ApplyDiff) ~= 'function' then return true end
    -- ApplyDiff -> ok, failedCategories, err. A category the edit changed that did not apply is a
    -- failed preview; a full restore (head/body/tone change) also reports untouched categories that
    -- already failed on the saved look: those are logged, not held against this edit.
    local ok, result, failed, err = pcall(pipeline.ApplyDiff, s.ped, before, after)
    if not ok then
        WCDebug.warn('editor', 'preview failed: %s', tostring(result))
        return false
    end
    if result == false then
        WCDebug.log('editor', 'preview refused: %s', tostring(err))
        return false
    end
    if type(failed) == 'table' and next(failed) ~= nil then
        local touched = touchedCategories(before, after)
        for _, category in pairs(failed) do
            if touched == nil or touched[category] then
                WCDebug.log('editor', 'preview refused: %s did not apply', tostring(category))
                return false
            end
            WCDebug.log('editor', 'untouched category %s did not apply', tostring(category))
        end
    end
    return true
end
E.touchedCategories = touchedCategories

--- Render the transition from `before` to `after` as the ped shows them (view).
local function render(s, before, after)
    return draw(s, view(s, before), view(s, after))
end

local function restoreOnPed(s, app)
    if type(Appearance) == 'table' then try(Appearance.RestoreCharacter, s.ped, view(s, app)) end
end

--- Show (hidden = false) or hide the clothes, hair and beard on the ped, from what it shows now.
local function setHidden(s, hidden)
    hidden = hidden == true
    if (s.hidden == true) == hidden then return true end
    local from = view(s, s.previewed or s.working)
    s.hidden, s.previewed = hidden, nil
    if draw(s, from, view(s, s.working)) then return true end
    restoreOnPed(s, s.working)
    return false
end

local function pushHistory(s, app)
    s.history[#s.history + 1] = app
    if #s.history > HISTORY_MAX then table.remove(s.history, 1) end
end

--- Move the working appearance to `after` (rendered first). Records one undo step.
--- ! Rendered from what the ped SHOWS (a live preview, if one is up), not from `working`: a drag
---   previews every frame and commits once, and the diff must start from the last frame drawn.
local function transition(s, after, record)
    local before = s.working
    local shown = s.previewed or before
    s.previewed = nil
    if WCUtil.deepEqual(before, after) then
        -- a preview is up and the commit folds back onto working: diff back incrementally, and
        -- only if that refuses fall back to the full restore
        if shown ~= before and not WCUtil.deepEqual(shown, after) and not render(s, shown, before) then
            restoreOnPed(s, before)
        end
        return WCResult.ok()
    end
    -- a clothing change while the clothes are hidden shows them again: the player is dressing the
    -- character and has to see what he picks
    local from = view(s, shown)
    if s.hidden and not WCUtil.deepEqual(before.clothing, after.clothing) then s.hidden = false end
    if not draw(s, from, view(s, after)) then
        restoreOnPed(s, before)
        return WCResult.fail('INVALID_COMPONENT')
    end
    if record ~= false then pushHistory(s, before) end
    s.working = after
    s.revision = s.revision + 1
    return WCResult.ok()
end

--- Apply a list of { entry, value } to a copy of the working appearance, as one step.
local function mutate(s, changes)
    local after = WCUtil.copy(s.working)
    for _, change in ipairs(changes) do
        local ok, code = pcall(change[1].apply, after, change[2], s)
        if not ok then
            WCDebug.warn('editor', 'mutation failed: %s', tostring(code))
            return WCResult.fail('INVALID_COMPONENT')
        end
        if code then return WCResult.fail(code) end
    end
    return transition(s, after)
end

-- ---------------------------------------------------------------------
--  Operations
-- ---------------------------------------------------------------------
local OPS = {}

OPS.set = function(s, data)
    local entry, value = validate(s, data.control, data.value, 'set')
    if not entry then return WCResult.fail(value) end
    return mutate(s, { { entry, value } })
end

--- Live preview of a drag: the values are drawn on the ped and nothing else moves — no history,
--- no working copy, no revision — so a slider or the two-axis pad follows the hand at frame rate.
--- values = {} (or absent) puts the working look back: a drag that ended where it began, or was
--- cancelled. The commit that follows renders from the previewed look (transition), so a preview
--- never has to be undone by hand.
OPS.preview = function(s, data)
    local values = type(data.values) == 'table' and data.values or {}
    local controls = {}
    for control in pairs(values) do
        if type(control) ~= 'string' then return WCResult.fail('INVALID_PAYLOAD') end
        controls[#controls + 1] = control
    end
    if #controls > MAX_MANY then return WCResult.fail('INVALID_PAYLOAD') end
    table.sort(controls)
    local after = WCUtil.copy(s.working)
    for _, control in ipairs(controls) do
        local entry, value = validate(s, control, values[control], 'set')
        if not entry then return WCResult.fail(value) end
        local ok, code = pcall(entry.apply, after, value, s)
        if not ok then return WCResult.fail('INVALID_COMPONENT') end
        if code then return WCResult.fail(code) end
    end
    local shown = s.previewed or s.working
    if WCUtil.deepEqual(shown, after) then return WCResult.ok() end
    if not render(s, shown, after) then
        restoreOnPed(s, s.working)
        s.previewed = nil
        return WCResult.fail('INVALID_COMPONENT')
    end
    s.previewed = (#controls > 0) and after or nil
    return WCResult.ok()
end

OPS.setMany = function(s, data)
    if type(data.values) ~= 'table' then return WCResult.fail('INVALID_PAYLOAD') end
    local controls = {}
    for control in pairs(data.values) do
        if type(control) ~= 'string' then return WCResult.fail('INVALID_PAYLOAD') end
        controls[#controls + 1] = control
    end
    if #controls == 0 or #controls > MAX_MANY then return WCResult.fail('INVALID_PAYLOAD') end
    table.sort(controls)
    local changes = {}
    for _, control in ipairs(controls) do
        local entry, value = validate(s, control, data.values[control], 'set')
        if not entry then return WCResult.fail(value) end
        changes[#changes + 1] = { entry, value }
    end
    return mutate(s, changes)
end

local function adoptContext(s, result)
    local data = WCResult.is(result) and result.ok and type(result.data) == 'table' and result.data or nil
    if data and type(data.outfits) == 'table' then s.context.outfits = data.outfits end
    -- a sale or a wrap changed what the character owns: the tree's cached item lists go with it
    if data and type(data.owned) == 'table' then
        s.context.owned = data.owned
        s.cache = {}
    end
end

OPS.invoke = function(s, data)
    local entry, value = validate(s, data.control, data.value, 'invoke')
    if not entry then return WCResult.fail(value) end
    if entry.call then
        local result = entry.call(s, value)
        if not WCResult.is(result) then return WCResult.fail('INTERNAL_ERROR') end
        adoptContext(s, result)
        -- entry.after: the working look follows what the server did (a sold item comes off)
        if result.ok and type(entry.after) == 'function' then
            local followed = mutate(s, { { { apply = entry.after }, value } })
            if not followed.ok then return followed end
        end
        return result
    end
    if entry.hook then
        -- a veto hook (onOutfit('equip', ...)): nil or an ok Result lets the local apply run, a
        -- failed Result stops it, anything else is an INTERNAL_ERROR
        local result = entry.hook(s, value)
        if result ~= nil then
            if not WCResult.is(result) then return WCResult.fail('INTERNAL_ERROR') end
            if not result.ok then return result end
            adoptContext(s, result)
        end
    end
    if entry.apply then return mutate(s, { { entry, value } }) end
    return WCResult.ok()
end

OPS.undo = function(s)
    local previous = s.history[#s.history]
    if not previous then return WCResult.ok() end
    local result = transition(s, previous, false)
    if result.ok then table.remove(s.history) end
    return result
end

OPS.reset = function(s)
    return transition(s, WCUtil.copy(s.saved))
end

OPS.random = function(s)
    if s.mode ~= 'creator' then return WCResult.fail('INVALID_PAYLOAD') end
    local after = WCEditorTree.randomize(WCUtil.copy(s.working))
    return transition(s, after)
end

local function cleanOpId(s, value)
    if type(value) == 'string' and #value > 0 and #value <= MAX_OPID and not value:find('[^%w%-_:.]') then
        return value
    end
    return ('%d-%d-%d'):format(s.id, type(GetGameTimer) == 'function' and GetGameTimer() or 0, math.random(1, 1e6))
end

-- Results after which the server may or may not have committed (the reply was lost / not a Result).
local UNCERTAIN = { INTERNAL_ERROR = true, BUSY = true }

--- The opId of a save: the same one while an attempt with the same working appearance (revision)
--  and identity is unresolved, so a retry after a lost reply is replayed by the server, not repeated.
local function saveOpId(s, submitted, identity)
    local pending = s.pendingSave
    if pending and pending.revision == s.revision and WCUtil.deepEqual(pending.identity or {}, identity or {}) then
        return pending.opId
    end
    local opId = cleanOpId(s, submitted)
    s.pendingSave = { opId = opId, revision = s.revision, identity = identity and WCUtil.copy(identity) or nil }
    return opId
end

OPS.save = function(s, data)
    if type(s.opts.onCommit) ~= 'function' then return WCResult.fail('INTERNAL_ERROR') end
    if not canSave(s) then return WCResult.fail('NO_CHANGES') end
    local extra = {}
    if type(s.opts.identity) == 'table' and not identityLocked(s) then
        local submitted = type(data.identity) == 'table' and data.identity or {}
        local ok, valid, cleaned = pcall(WCIdentity.validate, {
            firstname = submitted.firstname, lastname = submitted.lastname, dob = submitted.dob })
        if not ok then return WCResult.fail('INVALID_PAYLOAD') end
        if not valid then
            -- ★ Name the offending field. WCIdentity.validate checks firstname, then lastname, then the
            --   date, and answers one bare code for all three — the player was told "the name is invalid"
            --   with no way to know which of the two it meant.
            local field
            if cleaned == 'INVALID_NAME' then
                field = (not (WCIdentity.validateName(submitted.firstname))) and 'firstname' or 'lastname'
            elseif cleaned == 'INVALID_DOB' then
                field = 'dob'
            end
            local result = WCResult.fail(cleaned)
            result.field = field
            return result
        end
        extra.identity = cleaned
    end
    extra.opId = saveOpId(s, data.opId, extra.identity)
    if s.mode == 'store' then
        -- the store's payment currency and the optional outfit to save the look as; the server
        -- re-checks both (the currency it takes, the name, the outfit limit) before any charge
        -- the currency the prices were shown in (WCEditorTree.currencyOf: the choice, else the store's
        -- first); cash, the server's default, is left out so a plain purchase stays as it was
        local currency = WCEditorTree.currencyOf(s)
        extra.currency = (type(s.draft.currency) == 'string' or currency ~= 'cash') and currency or nil
        if type(data.outfitName) == 'string' and saveOutfitField(s) then
            local name = WCUtil.trim(WCUtil.clampString(data.outfitName, 64) or '')
            if name ~= '' then extra.outfitName = name end
        end
    end
    -- the clothes go back on before the look is committed: what is saved is what the ped shows
    if s.hidden then setHidden(s, false) end
    local ok, result = pcall(s.opts.onCommit, WCUtil.copy(s.working), extra)
    if not ok then
        WCDebug.warn('editor', 'commit failed: %s', tostring(result))
        return WCResult.fail('INTERNAL_ERROR')
    end
    if not WCResult.is(result) then return WCResult.fail('INTERNAL_ERROR') end
    -- a definite answer ends the attempt; an uncertain one (a lost reply) keeps its opId so the
    -- retry is served by the server's replay cache instead of a second commit
    if not UNCERTAIN[result.code] then s.pendingSave = nil end
    if result.ok then closeSession(s) end
    return result
end

--- Check an identity field by field, for the form to report while the player is still typing.
--  ★ The rules live in WCIdentity and ONLY there. The form asks Lua instead of carrying a second
--    copy of the character classes in JavaScript, so the two can never drift apart.
--  ⚠️ Until this existed the NUI only checked that the fields were non-empty (missingIdentity in
--    web/src/treeState.js); the real rules ran once, inside OPS.save, at the very end. A player who
--    typed a digit in a name ("test2") built the whole character and was only told "الاسم غير صالح"
--    at the final save, with no field named and no reason given.
---@return table { ok, fields = { [key] = 'OK' | code } }
function E.identityCheck(data)
    local s = current
    if type(data) ~= 'table' or not s or (data.id ~= nil and data.id ~= s.id) then return { ok = false } end
    if type(s.opts.identity) ~= 'table' or identityLocked(s) then return { ok = true, fields = {} } end
    local submitted = type(data.identity) == 'table' and data.identity or {}
    local fields = {}
    local function name(key)
        local value = submitted[key]
        -- an untouched (empty) field is not "wrong" yet: the form marks it missing, not invalid
        if value == nil or value == '' then return end
        local ok, code = WCIdentity.validateName(value)
        fields[key] = ok and 'OK' or (code or 'INVALID_NAME')
    end
    name('firstname')
    name('lastname')
    if type(submitted.dob) == 'string' and submitted.dob ~= '' then
        local ok, code = WCIdentity.validateDob(submitted.dob)
        fields.dob = ok and 'OK' or (code or 'INVALID_DOB')
    end
    local allOk = true
    for _, state in pairs(fields) do
        if state ~= 'OK' then allOk = false end
    end
    return { ok = true, valid = allOk, fields = fields }
end

--- The identity typed in the form, as plain strings (never validated here: it is a draft the form
--  gets back next time, and the save validates it). nil when the session has no editable identity.
local function identityDraft(s, submitted)
    if type(s.opts.identity) ~= 'table' or identityLocked(s) or type(submitted) ~= 'table' then return nil end
    local cfg = Config.Characters and Config.Characters.identity or {}
    local max = tonumber(cfg.nameMax) or 25
    local out = {}
    for key, limit in pairs({ firstname = max, lastname = max, dob = 10 }) do
        local v = submitted[key]
        if type(v) == 'string' then out[key] = WCUtil.clampString(v, limit) or '' end
    end
    return out
end

OPS.cancel = function(s, data)
    local draft
    if s.opts.keepDraft then
        -- the look is kept: the ped keeps showing it (clothes back on, a live preview dropped) and
        -- the caller gets it back with the typed identity
        if s.hidden or s.previewed then
            local from = view(s, s.previewed or s.working)
            s.hidden, s.previewed = false, nil
            if not draw(s, from, s.working) then restoreOnPed(s, s.working) end
        end
        draft = { working = WCUtil.copy(s.working), identity = identityDraft(s, data and data.identity) }
    else
        s.hidden = false
        restoreOnPed(s, s.saved)
    end
    closeSession(s)
    if type(s.opts.onCancel) == 'function' then
        if draft then try(s.opts.onCancel, draft.working, draft.identity) else try(s.opts.onCancel) end
    end
    return WCResult.ok()
end

local function respond(s, result, light)
    local out = { ok = result.ok == true }
    if not out.ok then
        out.code = result.code
        out.message = WCResult.text(result, L)
        local receipt = type(result.data) == 'table' and result.data.refundId
        if type(receipt) == 'string' then out.message = out.message .. ' ' .. L('رقم الإيصال: %s', receipt) end
    end
    if s.closed then
        out.closed = true
    elseif current == s and not light then
        out.payload = E.payload(s)
    end
    return out
end

--- The pose a change asks for (Config.Creator.profileTurn): 'profile' while a depth control is
--  moved (registry entry pose = 'profile'), 'front' for any other morphology control, nil for
--  everything else (a colour or a garment leaves the character as it stands).
local function poseFor(s, data)
    if not (Config.Creator and Config.Creator.profileTurn) then return nil end
    local controls = {}
    if data.op == 'set' then
        controls[1] = data.control
    elseif (data.op == 'setMany' or data.op == 'preview') and type(data.values) == 'table' then
        for control in pairs(data.values) do controls[#controls + 1] = control end
    end
    local pose
    for _, control in ipairs(controls) do
        local entry = type(control) == 'string' and s.registry[control] or nil
        if entry and entry.pose == 'profile' then return 'profile' end
        if entry and entry.morph then pose = 'front' end
    end
    return pose
end

--- Handle one editor:action request. Returns the NUI response.
function E.action(data)
    local s = current
    if type(data) ~= 'table' then
        local r = WCResult.fail('INVALID_PAYLOAD')
        return { ok = false, code = r.code, message = L(r.message) }
    end
    if not s or data.id ~= s.id then
        local r = WCResult.fail('SESSION_NOT_FOUND')
        return { ok = false, code = r.code, message = L(r.message), closed = s == nil or nil }
    end
    if s.busy then
        local r = WCResult.fail('BUSY')
        return { ok = false, code = r.code, message = L(r.message) }
    end
    local handler = type(data.op) == 'string' and OPS[data.op] or nil
    if not handler then return respond(s, WCResult.fail('INVALID_PAYLOAD')) end
    local pose = poseFor(s, data)
    if pose then camera('pose', pose) end
    s.busy = true
    local ok, result = pcall(handler, s, data)
    s.busy = false
    if not ok then
        WCDebug.warn('editor', 'operation %s failed: %s', tostring(data.op), tostring(result))
        result = WCResult.fail('INTERNAL_ERROR')
    elseif not WCResult.is(result) then
        result = WCResult.fail('INTERNAL_ERROR')
    end
    -- the camera requests that came in while this ran go now, before the next operation can start
    -- and before the answer is built: a parked hide toggle changes the payload's `hidden`
    flushCamera(s)
    -- a preview runs at frame rate and the frame does not read its answer: no tree rebuilt for it
    return respond(s, result, data.op == 'preview')
end

--- Apply one editor:camera request now and return its answer ({ ok = false } while busy).
function E.cameraAction(data)
    local s = current
    if type(data) ~= 'table' or not s or (data.id ~= nil and data.id ~= s.id) or s.busy then return { ok = false } end
    if data.hide ~= nil then
        -- the "hide clothes" toggle: a view of the working look, never a change of it
        if s.mode ~= 'creator' or type(data.hide) ~= 'boolean' then return { ok = false } end
        s.busy = true
        local done, shown = pcall(setHidden, s, data.hide)
        s.busy = false
        if not done then WCDebug.warn('editor', 'hide clothes failed: %s', tostring(shown)) end
        return { ok = done and shown ~= false, camera = s.camera, hidden = s.hidden == true }
    end
    -- a new view (another part picked, the view reset) faces the character forward again
    if data.reset or type(data.pick) == 'table' or data.preset ~= nil then camera('pose', 'front') end
    if data.reset then
        camera('reset')
        s.camera = 'fullBody'
    elseif type(data.pick) == 'table' then
        local x = WCUtil.number(data.pick.x, 0, 1, nil)
        local y = WCUtil.number(data.pick.y, 0, 1, nil)
        local aspect = WCUtil.number(data.pick.aspect, 0.2, 5, nil)
        if not x or not y or not aspect then return { ok = false } end
        local ok, preset = camera('pick', x, y, aspect)
        if ok and WCEditorTree.PRESET_SET[preset] then s.camera = preset end
    elseif data.rotate ~= nil then
        local deg = WCUtil.number(data.rotate, -180, 180, nil)
        if not deg then return { ok = false } end
        camera('rotate', deg)
    elseif data.zoom ~= nil then
        local delta = WCUtil.number(data.zoom, -4, 4, nil)
        if not delta then return { ok = false } end
        camera('zoom', delta)
    elseif data.preset ~= nil then
        if not WCEditorTree.PRESET_SET[data.preset] then return { ok = false } end
        camera('focus', data.preset)
        s.camera = data.preset
    else
        return { ok = false }
    end
    local ok, preset = camera('current')
    if ok and WCEditorTree.PRESET_SET[preset] then s.camera = preset end
    -- the teeth view opens the mouth; any other view closes it
    mouth(s, s.camera == 'teeth')
    return { ok = true, camera = s.camera }
end

--- The editor:camera NUI callback. A request of this session that arrives while an operation
--  runs is parked and answered once applied (flushCamera); any other is applied and answered now.
function E.cameraRequest(data, cb)
    local s = current
    if s and s.busy and type(data) == 'table' and (data.id == nil or data.id == s.id)
        and parkCamera(s, data, cb) then
        return
    end
    answerCamera(cb, E.cameraAction(data))
    -- a hide toggle renders with the editor busy: what was parked meanwhile goes now
    if s then flushCamera(s) end
end

if type(RegisterNUICallback) == 'function' then
    RegisterNUICallback('editor:action', function(data, cb) cb(E.action(data)) end)
    RegisterNUICallback('editor:camera', function(data, cb) E.cameraRequest(data, cb) end)
    RegisterNUICallback('editor:identity', function(data, cb) cb(E.identityCheck(data)) end)
end

if type(OnLanguageChange) == 'function' then
    OnLanguageChange(function()
        local s = current
        if not s then return end
        relabelPrompts(s)
        push(s)
    end)
end
