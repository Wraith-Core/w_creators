-- =====================================================================
--  client/editor/editor.lua  —  WCEditor (ARCHITECTURE.md §3.2, §8)
--  The one appearance editor session (creator, surgery, barber, store, wardrobe).
--
--  session = { id, mode, ped, working, saved, history (undo, max 30), registry (control -> entry),
--              busy, opts, context, sections, draft, cache, camera }
--  Every NUI value is validated against the session registry (built with the tree by
--  WCEditorTree) and clamped; mutations go through AppearanceSchema / WCRules on a copy of the
--  working appearance, the ped is updated with Appearance.ApplyDiff(ped, before, after) and a
--  failed render reverts to `before` (INVALID_COMPONENT). One operation at a time per session.
--
--  NUI callbacks: editor:action { id, op, control?, value?, values?, identity?, opId }
--                 editor:camera { id, preset? | rotate? | zoom? | reset? | pick? }
--  Both answer { ok, code?, message? (translated), payload?, closed?, camera? }.
-- =====================================================================

WCEditor = {}
local E = WCEditor
-- WCEditorTree (client/editor/tree.lua) loads after this file: it is always read at call time.

local current = nil
local opening = false   -- an open in progress (it can yield while rendering)
local sequence = 0
local HISTORY_MAX = 30
local MAX_MANY = 8
local MAX_CONTROL = 96
local MAX_OPID = 64

local MODES = { creator = true, surgery = true, barber = true, store = true, wardrobe = true }

-- The chrome strings (all dictionary keys). Sent translated as payload.strings.
local STRINGS = {
    brand = 'رايث · استوديو الشخصيات',
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
    advanced = 'تفاصيل إضافية',
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
    ['view.fullBody'] = 'الجسم كاملًا',
    ['view.upperBody'] = 'الجزء العلوي',
    ['view.lowerBody'] = 'الجزء السفلي',
    ['view.head'] = 'الرأس',
    ['view.face'] = 'الوجه',
    ['view.eyes'] = 'العينان',
    ['view.hair'] = 'الشعر',
    ['view.facialHair'] = 'اللحية',
    ['view.hands'] = 'اليدان',
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

local function identityPayload(s)
    local id = s.opts.identity
    if type(id) ~= 'table' then return nil end
    local cfg = Config.Characters and Config.Characters.identity or {}
    local year = tonumber(cfg.referenceYear)
    if not year then
        local ok, now = pcall(os.date, '*t')
        year = ok and type(now) == 'table' and now.year or 1900
    end
    local minAge, maxAge = tonumber(cfg.minAge) or 18, tonumber(cfg.maxAge) or 90
    local nameMax = tonumber(cfg.nameMax) or 25
    return {
        fields = {
            { key = 'firstname', label = L('الاسم الأول'), type = 'text', maxLength = nameMax,
              value = type(id.firstname) == 'string' and id.firstname or '' },
            { key = 'lastname', label = L('اسم العائلة'), type = 'text', maxLength = nameMax,
              value = type(id.lastname) == 'string' and id.lastname or '' },
            { key = 'dob', label = L('تاريخ الميلاد'), type = 'date',
              min = ('%04d-01-01'):format(year - maxAge), max = ('%04d-12-31'):format(year - minAge),
              value = type(id.dob) == 'string' and id.dob or '' },
            { key = 'sex', label = L('الجنس'), type = 'info',
              value = L(s.working.sex == 'male' and 'ذكر' or 'أنثى') },
        },
    }
end

--- Build the NUI payload of a session (rebuilds the tree and the control registry).
function E.payload(s)
    s = s or current
    if not s then return nil end
    local root, registry = WCEditorTree.build(s)
    s.registry = registry
    local confirm = CONFIRM[s.mode] or CONFIRM.store
    return {
        type = 'editor',
        session = { id = s.id, mode = s.mode, title = L(s.opts.title or TITLES[s.mode]),
                    subtitle = s.opts.subtitle and L(s.opts.subtitle) or nil, locale = uiLocale(), dir = uiDir() },
        strings = E.strings(),
        stages = WCEditorTree.stages(s, root),
        tree = root,
        price = WCEditorTree.price(s),
        identity = s.mode == 'creator' and identityPayload(s) or nil,
        dirty = isDirty(s),
        canSave = canSave(s),
        canUndo = #s.history > 0,
        canRandom = s.mode == 'creator',
        saveLabel = L(s.opts.saveLabel or SAVE_LABELS[s.mode]),
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
local function openPrompts(s)
    if type(w) ~= 'table' or type(w.prompt) ~= 'table' or type(w.prompt.createGroup) ~= 'function' then return end
    local ok, group = pcall(w.prompt.createGroup, L(s.opts.title or TITLES[s.mode]), 'bottom-right')
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
    sequence = sequence + 1
    local s = {
        id = sequence, mode = mode, ped = ped, saved = saved, working = WCUtil.copy(saved), history = {},
        registry = {}, busy = false, opts = opts, revision = 0,
        context = type(opts.context) == 'table' and opts.context or {},
        sections = sectionSet(mode, opts, saved.sex), draft = { outfitName = '' }, cache = {},
    }
    s.camera = WCEditorTree.PRESET_SET[opts.camera] and opts.camera or DEFAULT_CAMERA[mode]
    s.ownsLock = lockEditor()
    if type(WCPanel) == 'table' and WCPanel.isOpen() then try(WCPanel.close) end
    if opts.render then
        local called, done, err = try(Appearance and Appearance.RestoreCharacter, ped, saved)
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
--        onCancel(), onOutfit(op, id, value) -> Result, onState(group, value) -> Result, camera,
--        saveLabel, render (true = render `app` on the ped first).
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
    camera('open', ped, s.camera)
    focus(true)
    openPrompts(s)
    send(s.firstPayload)
    s.firstPayload = nil
    WCDebug.log('editor', 'open %s session %d', mode, s.id)
    return true
end

local function closeSession(s)
    if current ~= s then return end
    current = nil
    s.closed = true
    closePrompts(s)
    send({ type = 'editorClose' })
    focus(false)
    camera('close')
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

local function render(s, before, after)
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

local function restoreOnPed(s, app)
    if type(Appearance) == 'table' then try(Appearance.RestoreCharacter, s.ped, app) end
end

local function pushHistory(s, app)
    s.history[#s.history + 1] = app
    if #s.history > HISTORY_MAX then table.remove(s.history, 1) end
end

--- Move the working appearance to `after` (rendered first). Records one undo step.
local function transition(s, after, record)
    local before = s.working
    if WCUtil.deepEqual(before, after) then return WCResult.ok() end
    if not render(s, before, after) then
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
end

OPS.invoke = function(s, data)
    local entry, value = validate(s, data.control, data.value, 'invoke')
    if not entry then return WCResult.fail(value) end
    if entry.call then
        local result = entry.call(s, value)
        if not WCResult.is(result) then return WCResult.fail('INTERNAL_ERROR') end
        adoptContext(s, result)
        return result
    end
    if entry.hook then
        local result = entry.hook(s, value)
        if not WCResult.is(result) then return WCResult.fail('INTERNAL_ERROR') end
        if not result.ok then return result end
        adoptContext(s, result)
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
    if type(s.opts.identity) == 'table' then
        local submitted = type(data.identity) == 'table' and data.identity or {}
        local ok, valid, cleaned = pcall(WCIdentity.validate, {
            firstname = submitted.firstname, lastname = submitted.lastname, dob = submitted.dob })
        if not ok then return WCResult.fail('INVALID_PAYLOAD') end
        if not valid then return WCResult.fail(cleaned) end
        extra.identity = cleaned
    end
    extra.opId = saveOpId(s, data.opId, extra.identity)
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

OPS.cancel = function(s)
    restoreOnPed(s, s.saved)
    closeSession(s)
    if type(s.opts.onCancel) == 'function' then try(s.opts.onCancel) end
    return WCResult.ok()
end

local function respond(s, result)
    local out = { ok = result.ok == true }
    if not out.ok then
        out.code = result.code
        out.message = L(result.message or WCResult.messageKey(result.code))
    end
    if s.closed then
        out.closed = true
    elseif current == s then
        out.payload = E.payload(s)
    end
    return out
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
    s.busy = true
    local ok, result = pcall(handler, s, data)
    s.busy = false
    if not ok then
        WCDebug.warn('editor', 'operation %s failed: %s', tostring(data.op), tostring(result))
        result = WCResult.fail('INTERNAL_ERROR')
    elseif not WCResult.is(result) then
        result = WCResult.fail('INTERNAL_ERROR')
    end
    return respond(s, result)
end

--- Handle one editor:camera request.
function E.cameraAction(data)
    local s = current
    if type(data) ~= 'table' or not s or (data.id ~= nil and data.id ~= s.id) or s.busy then return { ok = false } end
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
    return { ok = true, camera = s.camera }
end

if type(RegisterNUICallback) == 'function' then
    RegisterNUICallback('editor:action', function(data, cb) cb(E.action(data)) end)
    RegisterNUICallback('editor:camera', function(data, cb) cb(E.cameraAction(data)) end)
end

if type(OnLanguageChange) == 'function' then
    OnLanguageChange(function()
        local s = current
        if not s then return end
        relabelPrompts(s)
        push(s)
    end)
end
