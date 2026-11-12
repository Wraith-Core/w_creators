-- =====================================================================
--  client/services/board.lua  —  WCBoard: the staff's services board (/servicesadmin, 2026-10-19)
--  The page (web/src/board, a second root of this resource's page) shows the places the server sends
--  (server/locations/store.lua); every change goes to the server (w_creators:board:action), which
--  checks the permission. This file does what the page cannot: the spots in the world, with the w_lib
--  placer (world editors look the same in every resource):
--    npc      the interaction point (where the staff member stands), then the NPC (optional)
--    preview  where the player stands while editing (the fitting stand / the patient's spot)
--    book     the clothing store's catalogue book
--    chair    a new chair prop at a barber
--    pickChair  look at a chair that is already in the map, J takes it
--  The board steps aside meanwhile (boardHide) and comes back with the new data. It opens only when no
--  editor, panel or service visit runs; while it is open WCServiceFlow.blocked() answers 'board'.
--  Page contract: ops/local/plans/creators-board-contract.md.
-- =====================================================================

WCBoard = {}
local B = WCBoard

local BOARD = Config.Board or {}
local open = false      -- on screen, or stepped aside while a world editor runs
local working = false   -- a world editor / the chair picker runs
local data = nil        -- the last board data from the server

local PICK_DISTANCE = 25.0

-- The page's words (ids the page asks for; Lua owns the text: locale keys = the Arabic text).
local STRINGS = {
    ['board.title'] = 'لوحة أماكن الخدمات',
    ['type.clothing'] = 'متاجر الملابس',
    ['type.barber'] = 'الحلاقون',
    ['type.surgery'] = 'عيادات التجميل',
    ['type.wardrobe'] = 'الخزائن',
    ['field.label'] = 'الاسم',
    ['field.town'] = 'المدينة',
    ['field.enabled'] = 'المكان يعمل',
    ['field.blip'] = 'علامة على الخريطة',
    ['field.radius'] = 'نطاق التفاعل (متر)',
    ['field.npcModel'] = 'شكل البوت',
    ['field.npcModelText'] = 'أو اكتب اسم الشكل',
    ['field.storeProfile'] = 'قائمة البضاعة',
    ['field.pricingProfile'] = 'قائمة الأسعار',
    ['field.chairModel'] = 'شكل الكرسي الجديد',
    ['sec.details'] = 'البيانات',
    ['sec.spots'] = 'الأماكن في العالم',
    ['btn.save'] = 'حفظ',
    ['btn.placeNpc'] = 'ضع البوت',
    ['btn.placePreview'] = 'مكان التعديل',
    ['btn.placeBook'] = 'كتاب الملابس',
    ['btn.placeChair'] = 'ضع كرسيًا جديدًا',
    ['btn.pickChair'] = 'اختر كرسيًا من الماب',
    ['btn.clear'] = 'إزالة',
    ['btn.teleport'] = 'انتقل',
    ['btn.delete'] = 'حذف المكان',
    ['btn.create'] = 'مكان جديد هنا',
    ['btn.close'] = 'إغلاق',
    ['note.createTitle'] = 'اسم المكان الجديد',
    ['note.createHint'] = 'يُنشأ المكان حيث تقف الآن.',
    ['note.deleteTitle'] = 'حذف «%s»؟',
    ['note.deleteBody'] = 'يُحذف المكان وكل ما وُضع له، ولا يمكن التراجع.',
    ['note.confirm'] = 'تأكيد',
    ['note.cancel'] = 'إلغاء',
    ['note.unsavedTitle'] = 'تعديلات لم تُحفظ',
    ['note.unsavedBody'] = 'إذا تابعت تضيع التعديلات التي لم تحفظها.',
    ['note.discard'] = 'تابع بدون حفظ',
    ['spot.npc'] = 'البوت',
    ['spot.preview'] = 'مكان التعديل',
    ['spot.book'] = 'الكتاب',
    ['spot.chair'] = 'الكرسي',
    ['spot.none'] = 'لم يُحدَّد بعد',
    ['spot.chairWorld'] = 'كرسي من الماب',
    ['state.on'] = 'مفعّل',
    ['state.off'] = 'معطّل',
    ['state.usable'] = 'مفتوح الآن',
    ['empty.places'] = 'لا توجد أماكن من هذا النوع بعد.',
    ['hint.pick'] = 'اختر مكانًا من القائمة، أو أنشئ مكانًا جديدًا حيث تقف.',
    ['hint.place'] = 'عند الضغط على زر الوضع تختفي اللوحة، ضع الشيء في مكانه ثم تعود اللوحة.',
    ['hint.rail'] = 'Q / E للتنقل بين الأقسام',
    ['ok.saved'] = 'تم الحفظ',
    ['ok.created'] = 'تم إنشاء المكان',
    ['ok.deleted'] = 'تم حذف المكان',
    ['ok.cleared'] = 'تمت الإزالة',
    ['ok.teleported'] = 'تم نقلك إلى المكان',
    ['err.generic'] = 'تعذّر تنفيذ الطلب',
    ['err.forbidden'] = 'ليست لديك صلاحية',
    ['err.not_found'] = 'المكان غير موجود',
    ['err.invalid'] = 'بيانات غير صالحة',
    ['err.too_far'] = 'أنت بعيد جدًا عن المكان',
    ['err.busy'] = 'انتظر قليلًا ثم حاول',
    ['err.cancelled'] = 'أُلغي التعديل',
    ['err.no_chair'] = 'لم يُختر كرسي',
    ['err.database_error'] = 'تعذّر الحفظ في قاعدة البيانات',
    ['err.mounted'] = 'انزل من الحصان أو العربة أولًا',
    -- 2026-11-12: the notebook (the builders' look)
    ['board.kicker'] = 'أماكن الخدمات',
    ['mast.places'] = 'مكانًا',
    ['tab.clothing'] = 'الملابس',
    ['tab.barber'] = 'الحلاقون',
    ['tab.surgery'] = 'التجميل',
    ['tab.wardrobe'] = 'الخزائن',
    ['type1.clothing'] = 'متجر ملابس',
    ['type1.barber'] = 'حلاق',
    ['type1.surgery'] = 'عيادة تجميل',
    ['type1.wardrobe'] = 'خزانة',
    ['list.ready'] = 'جاهز',
    ['list.off'] = 'مطفأ',
    ['pv.back'] = 'كل الأماكن',
    ['tag.unsaved'] = 'لم يُحفظ',
    ['sec.world'] = 'في العالم',
    ['sec.basic'] = 'الأساس',
    ['sec.adv'] = 'خيارات متقدمة',
    ['say.coords'] = 'يضغط اللاعب J هنا ليبدأ الخدمة',
    ['say.npc.clothing'] = 'الخياط يقف هنا ويستقبل اللاعب',
    ['say.npc.barber'] = 'الحلاق يقف هنا ويستقبل اللاعب',
    ['say.npc.surgery'] = 'الطبيب يقف هنا ويستقبل اللاعب',
    ['say.npc.wardrobe'] = 'موظف الخزانة يقف هنا',
    ['say.preview'] = 'يقف اللاعب هنا وهو يجرّب',
    ['say.book'] = 'كتاب الأزياء على الطاولة هنا',
    ['say.chair'] = 'يجلس اللاعب على كرسي الحلاقة هنا',
    ['what.coords'] = 'نقطة الخدمة',
    ['what.npc'] = 'الموظف',
    ['what.preview'] = 'مكان وقوف اللاعب',
    ['what.book'] = 'كتاب الأزياء',
    ['what.chair'] = 'كرسي الحلاقة',
    ['where.none'] = 'لم يُحدَّد بعد',
    ['where.set'] = 'محدَّد',
    ['btn.placePoint'] = 'حرّك النقطة',
    ['btn.world'] = 'في العالم',
    ['f.look'] = 'شكل الموظف',
    ['f.reach'] = 'يبدأ اللاعب الخدمة من',
    ['reach.1'] = 'قريب جدًا (1 م)',
    ['reach.2'] = 'قريب (2 م)',
    ['reach.4'] = 'بعيد قليلًا (4 م)',
    ['reach.custom'] = 'مخصص (%s م)',
    ['chair.look'] = 'شكل الكرسي',
    ['chair.n'] = 'الشكل %d',
    ['chair.prop'] = 'كرسي جديد وضعته',
    ['adv.id'] = 'رقم المكان',
    ['rd.need'] = 'ينقصه: %s',
    ['rd.sep'] = '، ',
    ['rd.fix'] = 'أصلحه',
    ['rd.opt'] = 'لم يُحدَّد بعد (اختياري): %s',
    ['rd.add'] = 'حدّده',
    ['where.opt'] = 'لم يُحدَّد، وهذا اختياري',
    ['btn.putNpc'] = 'ضع الموظف',
    ['btn.putPreview'] = 'حدّد مكان الوقوف',
    ['btn.putBook'] = 'ضع كتاب الأزياء',
    ['btn.putChair'] = 'ضع كرسيًا جديدًا',
    ['a.model'] = 'اسم شكل الموظف (بالإنجليزية)',
    ['rd.ok'] = 'جاهز ويعمل للاعبين',
    ['rd.okOff'] = 'جاهز، لكنه مطفأ',
    ['rd.label'] = 'الاسم',
    ['rd.town'] = 'المدينة',
    ['rd.radius'] = 'مسافة البدء',
    ['rd.npcModel'] = 'شكل الموظف',
    ['world.on'] = 'أنت في العالم: انظر إلى مكان واضغط J، أو انظر إلى علامة لتعدّلها. TAB يرجعك إلى اللوحة.',
    ['key.world'] = 'العالم',
    ['key.sections'] = 'الأقسام',
    ['key.pick'] = 'اختيار',
    ['key.list'] = 'كل الأماكن',
    ['err.no_world'] = 'البناء في العالم يحتاج نسخة أحدث من المكتبة',
    ['model.S_M_M_Tailor_01'] = 'خياط',
    ['model.u_m_m_nbxgeneralstoreowner_01'] = 'صاحب متجر',
    ['model.u_f_m_tumgeneralstoreowner_01'] = 'صاحبة متجر',
    ['model.s_m_m_barber_01'] = 'حلاق',
    ['model.u_m_m_valbarber_01'] = 'حلاق فالنتاين',
    ['model.a_m_m_valtownfolk_01'] = 'رجل من أهل المدينة',
    ['model.u_m_m_valdoctor_01'] = 'طبيب فالنتاين',
    ['model.a_f_m_valtownfolk_01'] = 'امرأة من أهل المدينة',
}
B.STRINGS = STRINGS

local function L(key) return locale(key) end

local function strings()
    local out = {}
    for id, key in pairs(STRINGS) do out[id] = L(key) end
    return out
end

local function send(message)
    if type(SendNUIMessage) == 'function' then SendNUIMessage(message) end
end

local function focus(on)
    if type(SetNuiFocus) == 'function' then SetNuiFocus(on, on) end
    if type(SetNuiFocusKeepInput) == 'function' then SetNuiFocusKeepInput(false) end
end

local function notify(code, kind)
    local key = STRINGS['err.' .. tostring(code)] or STRINGS['err.generic']
    pcall(w.notify, { description = L(key), type = kind or 'error' })
end

--- One call to the server: { ok, error?, data? }.
local function server(op, args)
    local ok, result = pcall(w.callback.await, 'w_creators:board:action', false, op, args or {})
    if not ok or type(result) ~= 'table' then return { ok = false, error = 'generic' } end
    if result.ok and type(result.data) == 'table' then data = result.data end
    return result
end

-- ── what the running w_lib offers (4.5.0: lib.place, lib.setPins, lib.worldEdit) ──
--  A store buyer's older w_lib has none of them: the board then keeps the placer buttons only (no TAB, no
--  place words; the advanced fold still shows the numbers).
local function libHas(path)
    local ok, s = pcall(LoadResourceFile, 'w_lib', path)
    return ok and type(s) == 'string' and s ~= ''
end
local can = nil
local function canDo()
    if can == nil then
        local started = GetResourceState('w_lib') == 'started'
        local place = started and libHas('imports/place/client.lua')
        can = {
            place = place,
            world = place and libHas('imports/worldEdit/client.lua') and libHas('resource/interface/client/pins.lua'),
        }
    end
    return can
end

--- The board data as sent to the page (the server's, plus what this client can do).
local function message(kind)
    return { type = kind or 'board', data = data, strings = strings(), dir = WCEditor.uiDir(), lang = WCEditor.uiLocale(),
             world = canDo().world == true, place = canDo().place == true }
end

local B_refreshWorld -- set below (the world mode redraws what the board holds after a change)

local function show()
    send(message())
    focus(true)
    if B_refreshWorld then B_refreshWorld() end
end

--- The new data to the page without taking the focus (a change made from the world).
local function push()
    send(message())
    if B_refreshWorld then B_refreshWorld() end
end

local function placeOf(id)
    for _, place in ipairs(type(data) == 'table' and data.places or {}) do
        if place.id == id then return place end
    end
    return nil
end

--- Is the board open (on screen or stepped aside for a world editor)?
function B.isOpen() return open end

--- Open the board (yields: asks the server). Refused while an editor, panel or visit runs.
function B.open()
    if open then return false end
    if WCServiceFlow.blocked() then
        notify('busy')
        return false
    end
    local result = server('list')
    if not result.ok then
        notify(result.error)
        return false
    end
    open = true
    show()
    return true
end

--- Close the board (a running world editor is cancelled).
function B.close()
    if not open then return end
    open = false
    if working and w.placer.isActive() then pcall(w.placer.cancel) end
    if B.stopWorld then B.stopWorld() end
    send({ type = 'boardClose' })
    focus(false)
end

-- ---------------------------------------------------------------------
--  The world editors
-- ---------------------------------------------------------------------
local function vec3(s)
    if type(s) ~= 'table' or not tonumber(s.x) then return nil end
    return vector3(s.x + 0.0, s.y + 0.0, s.z + 0.0)
end

local function vec4(s)
    if type(s) ~= 'table' or not tonumber(s.x) then return nil end
    return vector4(s.x + 0.0, s.y + 0.0, s.z + 0.0, (tonumber(s.h) or 0.0) + 0.0)
end

local function plain(v)
    if v == nil or v == false then return v end
    local x, y, z = WCUtil.xyz(v)
    if not x then return nil end
    local ok, h = pcall(function() return v.w end)
    return { x = x, y = y, z = z, h = ok and tonumber(h) or 0.0 }
end

local function chairModel(model)
    for _, m in ipairs(BOARD.chairModels or {}) do
        if m == model then return m end
    end
    return (BOARD.chairModels or {})[1]
end

--- The placer's steps for one kind of spot, and how its result becomes the server's args.
local function placerRun(place, what, model)
    local title = place.label ~= '' and place.label or nil
    local steps
    if what == 'npc' then
        steps = {
            { id = 'coords', kind = 'point', anchor = 'self', current = vec3(place.coords), ring = place.radius,
              text = L('قف حيث يضغط اللاعب زر الخدمة') },
            { id = 'npc', kind = 'ped', model = place.npcModel, anchor = 'front', current = vec4(place.npc),
              optional = true, removable = true, text = L('ضع البوت ووجّهه بعجلة الفأرة') },
        }
    elseif what == 'preview' then
        steps = {
            { id = 'preview', kind = 'ped', model = BOARD.previewModel or 'a_m_m_valtownfolk_01',
              current = vec4(place.preview), text = L('ضع مكان وقوف اللاعب أثناء التعديل') },
        }
    elseif what == 'book' then
        local catalogue = (Config.Clothing or {}).catalogue or {}
        steps = {
            { id = 'book', kind = 'object', model = catalogue.model, current = vec4(place.book), ground = false,
              text = L('ضع كتاب الملابس على الطاولة') },
        }
    elseif what == 'chair' then
        model = chairModel(model)
        if not model then return nil, 'no_chair' end
        steps = {
            { id = 'chair', kind = 'object', model = model, current = vec4(place.chair), text = L('ضع كرسي الحلاقة') },
        }
    else
        return nil, 'invalid'
    end
    local values, reason = w.placer.run({ title = title, steps = steps })
    if not values then return nil, reason == 'cancelled' and 'cancelled' or (reason or 'cancelled') end
    if what == 'npc' then
        if values.coords == nil and values.npc == nil then return nil, 'cancelled' end
        return { id = place.id, what = 'npc', at = plain(values.coords), value = plain(values.npc), model = place.npcModel }
    end
    local value = values[what]
    if not value then return nil, 'cancelled' end
    local args = { id = place.id, what = what, value = plain(value) }
    if what == 'chair' then args.value.kind, args.value.model = 'prop', model end
    return args
end

local function centreOf(entity)
    local min, max = GetModelDimensions(GetEntityModel(entity))
    return GetOffsetFromEntityInWorldCoords(entity, (min.x + max.x) / 2, (min.y + max.y) / 2, (min.z + max.z) / 2)
end

--- A barber chair of the game near a point (a chair the ray does not return as an object).
local function chairNear(at)
    for _, model in ipairs(BOARD.chairModels or {}) do
        local found = GetClosestObjectOfType(at.x, at.y, at.z, 1.5, joaat(model), false, false, false)
        if found and found ~= 0 and DoesEntityExist(found) then return found end
    end
    return nil
end

--- Look at a chair of the map: J takes the object under the crosshair, Backspace gives up.
local function pickChair(place)
    local pressed = { pick = false, back = false }
    local hints = w.prompt.createGroup(L('اختر كرسيًا من الماب'), WCEditor.uiDir() == 'rtl' and 'bottom-left' or 'bottom-right')
    hints.addPrompt('J', L('اختيار الكرسي'), false)
    hints.addPrompt('BACK', L('رجوع'), false)
    hints.display()
    local listeners = {
        w.rawKeys.listen('J', function(down) if down then pressed.pick = true end end),
        w.rawKeys.listen('BACK', function(down) if down then pressed.back = true end end),
    }
    local picked, reason = nil, nil
    while not picked and not reason and open do
        DisablePlayerFiring(PlayerId(), true)
        local hit, entity, endCoords = w.raycast.fromCamera(1 | 16, 4, PICK_DISTANCE)
        local object = hit and entity and entity ~= 0 and GetEntityType(entity) == 3 and entity or nil
        if not object and hit and endCoords then object = chairNear(endCoords) end
        -- the owner 2026-10-23: the game's glitter instead of DrawMarker (w_lib 4.1.0 w.glow.frame, look 2)
        if object then w.glow.frame('chair', 'point', centreOf(object), { look = 2, scale = 1.6 }) end
        if hit and endCoords then w.glow.frame('aim', 'point', endCoords, { look = 2, scale = 0.5 }) end
        if pressed.pick then
            pressed.pick = false
            if object then
                local at = GetEntityCoords(object)
                picked = { x = at.x, y = at.y, z = at.z, h = GetEntityHeading(object), kind = 'world',
                           model = GetEntityModel(object) }
            end
        end
        if pressed.back then reason = 'cancelled' end
        if IsEntityDead(PlayerPedId()) then reason = 'cancelled' end
        Wait(0)
    end
    for _, id in ipairs(listeners) do pcall(w.rawKeys.removeListener, id) end
    pcall(hints.hide)
    pcall(hints.delete)
    if not picked then return nil, reason or 'cancelled' end
    return { id = place.id, what = 'chair', value = picked }
end

--- Step aside, run the world editor for one spot, save it, come back with the new data.
local function placeSpot(args)
    local place = placeOf(args.id)
    local can, why = w.placer.canStart()
    if not place or not can then
        -- the board stays (re-sent: the page waits for it after a place call)
        notify(not place and 'not_found' or (why == 'mounted' and 'mounted' or why == 'busy' and 'busy' or 'invalid'))
        return show()
    end
    working = true
    send({ type = 'boardHide' })
    focus(false)
    local ok, payload, reason = pcall(function()
        if args.what == 'pickChair' then return pickChair(place) end
        return placerRun(place, args.what, args.model)
    end)
    working = false
    if not open then return end
    if not ok then
        WCDebug.warn('board', 'placing %s failed: %s', tostring(args.what), tostring(payload))
        notify('generic')
    elseif payload then
        local result = server('spot', payload)
        if result.ok then pcall(w.notify, { description = L('حُفظ المكان'), type = 'success' })
        else notify(result.error) end
    elseif reason ~= 'cancelled' then
        notify(reason)
    end
    show()
end

-- ---------------------------------------------------------------------
--  The places in words (lib.place): «فالنتاين · 12 م منك», sent every 2 s while the board shows
--  boardWhere { where = { [placeId] = { coords|npc|preview|book|chair = { t, m } } } }
-- ---------------------------------------------------------------------
local SPOT_FIELDS = { 'coords', 'npc', 'preview', 'book', 'chair' }

local function describe(s)
    local at = vec3(s)
    if not at then return nil end
    local ok, d = pcall(function() return lib.place.describe(at) end)
    if not ok or type(d) ~= 'table' or type(d.text) ~= 'string' then return nil end
    return { t = d.text, m = math.floor((tonumber(d.meters) or 0) + 0.5) }
end

local function sendWhere()
    if not canDo().place or type(data) ~= 'table' then return end
    local out = {}
    for i, place in ipairs(data.places or {}) do
        if i > 200 then break end
        local row = {}
        for _, k in ipairs(SPOT_FIELDS) do
            if type(place[k]) == 'table' then row[k] = describe(place[k]) end
        end
        out[place.id] = row
    end
    send({ type = 'boardWhere', where = out })
end

CreateThread(function()
    while true do
        if open and not working then sendWhere() end
        Wait(open and 2000 or 1000)
    end
end)

-- ---------------------------------------------------------------------
--  The world mode (w_lib 4.5.0 lib.worldEdit): TAB on the board, then J on the ground
--  «ماذا يحدث هنا؟» (this board's rows), J on a pin = move / turn / remove / open, the wheel turns,
--  Ctrl+Z undoes, TAB back to the board. Every change is a board op on the server (op spot / clear /
--  create), so its checks (the ACE, 80 m from the staff member) stay the only ones.
--  Item ids: '<placeId>|<what>' with what = coords | npc | preview | book | chair.
-- ---------------------------------------------------------------------
local edit = nil
local selected = nil   -- the place the page shows ('' / nil: none)
local undo = {}        -- { { id, what, before } } newest last (before = the spot as it was, or false)

local ROLE = { clothing = 'الخياط', barber = 'الحلاق', surgery = 'الطبيب', wardrobe = 'موظف الخزانة' }
local WHAT_WORD = {
    coords = 'نقطة الخدمة', preview = 'مكان وقوف اللاعب', book = 'كتاب الأزياء', chair = 'كرسي الحلاقة',
}

local function itemId(placeId, what) return placeId .. '|' .. what end
local function splitId(id)
    local placeId, what = tostring(id or ''):match('^(.+)|(%a+)$')
    return placeId, what
end

local function whatWord(place, what)
    if what == 'npc' then return L(ROLE[place.type] or 'الموظف') end
    return L(WHAT_WORD[what] or what)
end

local function copySpot(s)
    if type(s) ~= 'table' then return false end
    local out = {}
    for k, v in pairs(s) do out[k] = v end
    return out
end

--- One op from the world: the undo entry first, then the server; the page and the pins follow the answer.
local function change(op, args, before)
    local result = server(op, args)
    if not result.ok then
        notify(result.error)
        return false
    end
    if before then
        undo[#undo + 1] = before
        if #undo > 30 then table.remove(undo, 1) end
    end
    push()
    return true
end

local function remember(place, what)
    return { id = place.id, what = what, before = copySpot(place[what]), model = place.npcModel }
end

local function setSpot(place, what, spot, extra)
    local value = plain(spot)
    if not value then return end
    if what == 'coords' then
        return change('spot', { id = place.id, what = 'npc', at = { x = value.x, y = value.y, z = value.z } }, remember(place, 'coords'))
    end
    if what == 'npc' then
        return change('spot', { id = place.id, what = 'npc', value = value, model = place.npcModel }, remember(place, 'npc'))
    end
    if what == 'chair' then
        local chair = place.chair
        value.kind = extra and extra.kind or (type(chair) == 'table' and chair.kind) or 'prop'
        value.model = extra and extra.model or (type(chair) == 'table' and chair.model) or chairModel(nil)
        if not value.model then notify('no_chair') return end
    end
    return change('spot', { id = place.id, what = what, value = value }, remember(place, what))
end

local function undoLast()
    local last = table.remove(undo)
    if not last then return end
    local place = placeOf(last.id)
    if not place then return push() end
    local args
    if last.what == 'coords' then
        if not last.before then return push() end   -- a place always has its point
        args = { op = 'spot', a = { id = place.id, what = 'npc', at = last.before } }
    elseif not last.before then
        args = { op = 'clear', a = { id = place.id, what = last.what } }
    elseif last.what == 'npc' then
        args = { op = 'spot', a = { id = place.id, what = 'npc', value = last.before, model = last.before.model or last.model } }
    else
        args = { op = 'spot', a = { id = place.id, what = last.what, value = last.before } }
    end
    local result = server(args.op, args.a)
    if not result.ok then notify(result.error) end
    push()
end

local function ghostOf(place, what)
    if what == 'npc' then return place.npcModel or (type(place.npc) == 'table' and place.npc.model) or nil, 'ped' end
    if what == 'preview' then return BOARD.previewModel or 'a_m_m_valtownfolk_01', 'ped' end
    if what == 'book' then return ((Config.Clothing or {}).catalogue or {}).model, 'object' end
    if what == 'chair' and type(place.chair) == 'table' and place.chair.kind == 'prop' then return place.chair.model, 'object' end
    return nil, 'point'
end

local SPOTS_OF = {
    clothing = { 'coords', 'npc', 'preview', 'book' },
    barber = { 'coords', 'npc', 'preview', 'chair' },
    surgery = { 'coords', 'npc', 'preview' },
    wardrobe = { 'coords', 'npc', 'preview' },
}

local function items()
    local out = {}
    for _, place in ipairs(type(data) == 'table' and data.places or {}) do
        local cur = place.id == selected
        local name = (type(place.label) == 'string' and place.label ~= '') and place.label or place.id
        for n, what in ipairs(SPOTS_OF[place.type] or {}) do
            local s = place[what]
            if type(s) == 'table' and tonumber(s.x) and #out < 150 then
                local model, kind = ghostOf(place, what)
                out[#out + 1] = {
                    id = itemId(place.id, what), n = cur and n or nil,
                    label = cur and whatWord(place, what) or (name .. ' · ' .. whatWord(place, what)),
                    x = s.x + 0.0, y = s.y + 0.0, z = s.z + 0.0, h = (tonumber(s.h) or 0.0) + 0.0,
                    r = what == 'coords' and (tonumber(place.radius) or 2.0) or nil,
                    model = model, kind = model and kind or 'point',
                    state = cur and 'cur' or nil,
                    turn = what ~= 'coords' and not (what == 'chair' and s.kind == 'world'),
                    move = not (what == 'chair' and s.kind == 'world'),
                }
            end
        end
    end
    return out
end

local function refreshWorld()
    if edit then pcall(edit.setItems, edit, items()) end
end
B_refreshWorld = refreshWorld

local function backToBoard()
    if not open then return end
    send({ type = 'boardWorld', on = false })
    focus(true)
end

local function newPlace(placeType, at)
    local result = server('create', { type = placeType })
    if not result.ok then return notify(result.error) end
    local id = type(result.data) == 'table' and result.data.selected or nil
    local place = id and placeOf(id) or nil
    if place then
        -- the server put it where the staff member stands; the point goes where he looked
        server('spot', { id = place.id, what = 'npc', at = { x = at.x, y = at.y, z = at.z } })
        selected = place.id
        send({ type = 'boardOpen', id = place.id })
    end
    pcall(w.notify, { description = L('تم إنشاء المكان'), type = 'success' })
    push()
end

local function ground(at)
    local rows = {}
    local place = selected and placeOf(selected) or nil
    if place then
        local name = (place.label ~= '' and place.label) or place.id
        for _, what in ipairs(SPOTS_OF[place.type] or {}) do
            rows[#rows + 1] = {
                title = (L('%s هنا')):format(whatWord(place, what)),
                description = name,
                onSelect = function(spot) setSpot(place, what, spot) end,
            }
        end
        if place.type == 'barber' then
            rows[#rows + 1] = {
                title = L('استخدم كرسي الماب هذا'), description = L('الكرسي الذي تنظر إليه'),
                onSelect = function(spot)
                    local found = chairNear(vector3(spot.x, spot.y, spot.z))
                    if not found then return notify('no_chair') end
                    local c = GetEntityCoords(found)
                    setSpot(place, 'chair', vector4(c.x, c.y, c.z, GetEntityHeading(found)),
                        { kind = 'world', model = GetEntityModel(found) })
                end,
            }
        end
    end
    for _, t in ipairs({ 'clothing', 'barber', 'surgery', 'wardrobe' }) do
        rows[#rows + 1] = {
            title = (L('مكان جديد هنا: %s')):format(L(STRINGS['type1.' .. t] or t)),
            description = L('يُنشأ مكان جديد وتضبطه من اللوحة'),
            onSelect = function(spot) newPlace(t, spot) end,
        }
    end
    return rows
end

-- w_lib's pin-menu rows carry no id: «احذفه» / «افتح الخطوة» are matched by their words (w_lib's, or its English)
local words
local function word(k)
    if not words then
        local ok, got = pcall(function() return exports.w_lib:worldEditWords() end)
        words = (ok and type(got) == 'table') and got or {}
    end
    return words[k]
end
local EN_WORD = { open = 'Open the step', remove = 'Remove it' }
local function isWord(title, k) return title ~= nil and (title == word(k) or title == EN_WORD[k]) end
AddEventHandler('w_lib:setLocale', function() words = nil end)

local function startEdit()
    if edit or not canDo().world then return edit end
    local ok, e = pcall(function()
        return lib.worldEdit.start({
            key = 'w_creators_board', -- not 'w_creators:...' (the hygiene test reads those as callbacks)
            title = L('ماذا يحدث هنا؟'),
            items = items(),
            ground = ground,
            onMove = function(item, spot)
                local placeId, what = splitId(item.id)
                local place = placeId and placeOf(placeId)
                if place then setSpot(place, what, spot) end
            end,
            onTurn = function(item, heading)
                local placeId, what = splitId(item.id)
                local place = placeId and placeOf(placeId)
                local s = place and place[what]
                if type(s) ~= 'table' then return end
                setSpot(place, what, vector4(s.x, s.y, s.z, heading))
            end,
            onRadius = function(item, r)
                local placeId, what = splitId(item.id)
                local place = placeId and placeOf(placeId)
                if not place or what ~= 'coords' then return end
                local lim = BOARD.radius or {}
                r = math.max(lim.min or 0.5, math.min(lim.max or 10.0, tonumber(r) or 2.0))
                change('save', { id = place.id, radius = r })
            end,
            onRemove = function(item)
                local placeId, what = splitId(item.id)
                local place = placeId and placeOf(placeId)
                if not place then return end
                if what == 'coords' then
                    return pcall(w.notify, { description = L('لا تُحذف نقطة الخدمة، حرّكها أو احذف المكان من اللوحة'), type = 'inform' })
                end
                change('clear', { id = place.id, what = what }, remember(place, what))
            end,
            onOpen = function(item)
                local placeId = splitId(item.id)
                if placeId then
                    selected = placeId
                    send({ type = 'boardOpen', id = placeId })
                    refreshWorld()
                end
                backToBoard()
            end,
            pinMenu = function(item, rows)
                local _, what = splitId(item.id)
                local out = {}
                for _, r in ipairs(rows) do
                    if isWord(r.title, 'open') then
                        r.title, r.description = L('افتح المكان'), L('ارجع إلى اللوحة على هذا المكان')
                        out[#out + 1] = r
                    elseif isWord(r.title, 'remove') then
                        if what ~= 'coords' then out[#out + 1] = r end
                    else
                        out[#out + 1] = r
                    end
                end
                return out
            end,
            onUndo = undoLast,
            onBoard = backToBoard,
            range = 150.0,
        })
    end)
    if ok and type(e) == 'table' then edit = e
    else WCDebug.warn('board', 'the world mode failed to start: %s', tostring(e)) end
    return edit
end

local function stopEdit()
    if edit then pcall(edit.stop, edit, 'closed') end
    edit, undo = nil, {}
end
B.stopWorld = stopEdit

-- ---------------------------------------------------------------------
--  The page's calls
-- ---------------------------------------------------------------------
-- the place the page shows: its spots are numbered and marked in the world, J's rows are for it
RegisterNUICallback('board:sel', function(body, cb)
    selected = type(body) == 'table' and type(body.id) == 'string' and body.id ~= '' and body.id or nil
    cb({ ok = true })
    if open and canDo().world then startEdit() refreshWorld() end
end)

-- TAB on the board: build in the world (the page keeps showing, dimmed; the game has the keys)
RegisterNUICallback('board:world', function(body, cb)
    if not open or working then return cb({ ok = false, error = 'busy' }) end
    local e = startEdit()
    if not e then return cb({ ok = false, error = 'no_world' }) end
    focus(false)
    local ok, on = pcall(e.setWorld, e, true)
    if ok and on then
        send({ type = 'boardWorld', on = true })
        cb({ ok = true })
    else
        -- w_lib refuses a switch within 300 ms of the last one: stay on the board
        focus(true)
        cb({ ok = false, error = 'busy' })
    end
end)
RegisterNUICallback('board:action', function(body, cb)
    if not open or working then return cb({ ok = false, error = 'busy' }) end
    local op = type(body) == 'table' and body.op or nil
    local args = type(body) == 'table' and type(body.args) == 'table' and body.args or {}
    if op == 'place' then
        cb({ ok = true })
        CreateThread(function() placeSpot(args) end)
        return
    end
    if op == 'teleport' then
        local place = placeOf(args.id)
        local at = place and vec3(place.coords)
        if not at then return cb({ ok = false, error = 'not_found' }) end
        local ped = PlayerPedId()
        SetEntityCoords(ped, at.x, at.y, at.z, false, false, false, false)
        return cb({ ok = true })
    end
    cb(server(op, args))
end)

RegisterNUICallback('board:close', function(_, cb)
    cb({ ok = true })
    B.close()
end)

RegisterCommand(BOARD.command or 'servicesadmin', function()
    CreateThread(B.open)
end, false)

AddEventHandler('onResourceStop', function(resource)
    if resource ~= GetCurrentResourceName() or not open then return end
    open = false
    if B.stopWorld then pcall(B.stopWorld) end
    pcall(focus, false)
end)
