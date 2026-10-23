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

local function show()
    send({ type = 'board', data = data, strings = strings(), dir = WCEditor.uiDir(), lang = WCEditor.uiLocale() })
    focus(true)
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
--  The page's calls
-- ---------------------------------------------------------------------
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
    pcall(focus, false)
end)
