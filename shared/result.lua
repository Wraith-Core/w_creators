-- =====================================================================
--  shared/result.lua  —  WCResult / WCCodes (ARCHITECTURE.md §4)
--  Every callback answers a Result:
--    { ok = true,  code = 'OK', data = ... }
--    { ok = false, code = <WCCodes.*>, message = <locale key>, data = ... }
--  The client translates `message` only at the UI boundary.
-- =====================================================================

WCCodes = {}
WCResult = {}

-- code -> locale key (the Arabic source text)
local MESSAGES = {
    OK                           = 'تم',
    INVALID_PAYLOAD              = 'بيانات غير صالحة',
    RATE_LIMITED                 = 'طلبات كثيرة، انتظر قليلًا',
    BUSY                         = 'عملية أخرى قيد التنفيذ',
    SERVICE_DISABLED             = 'هذه الخدمة غير متاحة حاليًا',
    LOCATION_DISABLED            = 'هذا المكان مغلق حاليًا',
    LOCATION_CLOSED_HOURS        = 'هذا المكان مغلق الآن، خارج ساعات العمل',
    LOCATION_NOT_FOUND           = 'المكان غير موجود',
    TOO_FAR                      = 'أنت بعيد جدًا عن المكان',
    ACCESS_DENIED                = 'هذا المكان مخصّص لأصحاب صلاحية معيّنة',
    SESSION_EXPIRED              = 'انتهت الجلسة',
    SESSION_NOT_FOUND            = 'لا توجد جلسة مفتوحة',
    NO_CHARACTER                 = 'تعذّر تحديد الشخصية',
    NO_CHANGES                   = 'لا توجد تغييرات',
    CHARACTER_NOT_FOUND          = 'الشخصية غير موجودة',
    NOT_CHARACTER_OWNER          = 'هذه الشخصية ليست لك',
    CHARACTER_SLOT_LIMIT         = 'لا توجد خانة شخصية متاحة',
    CREATION_NOT_GRANTED         = 'إنشاء الشخصية غير مصرّح به',
    INVALID_NAME                 = 'الاسم غير صالح',
    INVALID_DOB                  = 'تاريخ الميلاد غير صالح',
    DELETE_CONFIRMATION_REQUIRED = 'يجب تأكيد الحذف',
    DELETE_DISABLED              = 'حذف الشخصيات معطّل',
    CREATION_DISABLED            = 'إنشاء الشخصيات معطّل',
    INVALID_COMPONENT            = 'قطعة غير صالحة لهذه الشخصية',
    COMPONENT_NOT_AVAILABLE      = 'هذه القطعة غير متوفرة هنا',
    ITEM_NOT_OWNED               = 'هذه القطعة غير مملوكة',
    INVALID_TINT                 = 'لون غير صالح',
    CONFLICTING_ITEMS            = 'هذه القطع لا تُلبس معًا',
    INSUFFICIENT_FUNDS           = 'لا تملك ما يكفي من المال',
    INVALID_PRICE                = 'سعر غير صالح',
    CURRENCY_NOT_ACCEPTED        = 'بعض القطع لا تُباع بهذه العملة',
    NOT_RESELLABLE               = 'لا يمكن بيع هذه القطعة',
    ITEM_IN_OUTFIT               = 'هذه القطعة محفوظة في أحد أطقمك',
    ITEM_WORN                    = 'اخلع القطعة أولًا',
    ITEMS_DISABLED               = 'تبادل الملابس معطّل',
    INVENTORY_FULL               = 'لا مكان لها في حقيبتك',
    WRONG_SEX                    = 'هذه القطعة لا تناسب شخصيتك',
    STORE_DISABLED               = 'متجر الملابس مغلق',
    BARBER_DISABLED              = 'الحلاق مغلق',
    SURGERY_DISABLED             = 'عمليات التجميل غير متاحة',
    SURGERY_NOT_ALLOWED          = 'هذا التعديل غير مسموح في عملية التجميل',
    WARDROBE_DISABLED            = 'الخزانة غير متاحة',
    OUTFITS_DISABLED             = 'حفظ الأطقم غير متاح',
    OUTFIT_LIMIT                 = 'وصلت إلى الحد الأقصى من الأطقم',
    OUTFIT_NOT_FOUND             = 'الطقم غير موجود',
    OUTFIT_LOCKED                = 'ملابس البداية ثابتة: يمكنك ارتداؤها وتغيير اسمها فقط',
    INVALID_OUTFIT_NAME          = 'اسم الطقم غير صالح',
    STATE_NOT_SUPPORTED          = 'هذه الحالة غير مدعومة',
    STATE_NOT_APPLICABLE         = 'لا يمكن تطبيق هذه الحالة الآن',
    ACTIONS_DISABLED             = 'إجراءات الملابس معطّلة',
    INVALID_SPAWN                = 'مكان ظهور غير صالح',
    SPAWN_NOT_PENDING            = 'لا يوجد ظهور بانتظارك',
    DATABASE_ERROR               = 'خطأ في قاعدة البيانات',
    ECONOMY_NOT_READY            = 'الاقتصاد غير جاهز بعد — حاول بعد قليل',
    REFUND_PENDING               = 'تعذر إتمام العملية ورد المبلغ الآن. حُفظ طلب الاسترداد؛ احتفظ برقم الإيصال وراجع الإدارة إذا تأخر.',
    REFUND_REVIEW                = 'هذه العملية المالية تحتاج مراجعة الإدارة قبل محاولة جديدة. احتفظ برقم الإيصال.',
    DELETE_HOLDS_FUNDS           = 'لا يمكن حذف شخصية ما زالت تملك مالًا — أنفقه أو حوّله أولًا',
    DELETE_HOLDS_LOAN            = 'لا يمكن حذف شخصية عليها قرض قائم',
    DELETE_HOLDS_ASSETS          = 'لا يمكن حذف شخصية تملك ممتلكات (متجر، خيول، حيوانات، سكن…) — تصرّف فيها أولًا',
    CHARACTER_BLOCKED            = 'هذه الشخصية موقوفة — راجع الإدارة',
    -- a player named by his citizen id (w.citizen): the same words as w_lib's citizen.* strings
    INVALID_CITIZEN_ID           = 'رقم المواطن غير صحيح',
    PLAYER_NOT_FOUND             = 'لا يوجد لاعب بهذا الرقم',
    PLAYER_OFFLINE               = 'اللاعب غير متصل الآن',
    INTERNAL_ERROR               = 'حدث خطأ داخلي',
}

for code in pairs(MESSAGES) do WCCodes[code] = code end

WCResult.messages = MESSAGES

-- 1.0.6 (owner 2026-11-01: a refusal says the reason): the specifics of a refusal, as locale keys with
-- %s. A screen that can show them reads WCResult.text; any other still shows the code's message above,
-- which reads right on its own.
local DETAILS = {
    hours      = 'مغلق الآن، يفتح من %s إلى %s',
    jobs       = 'هذا المكان خاص بوظيفة: %s',
    funds_cash = 'السعر %s$ ومعك %s$',
    funds_gold = 'السعر %s ذهب ومعك %s ذهب',
}
WCResult.details = DETAILS

--- The locale key for a code (unknown codes -> the INTERNAL_ERROR key).
function WCResult.messageKey(code)
    return MESSAGES[code] or MESSAGES.INTERNAL_ERROR
end

--- A success Result.
function WCResult.ok(data)
    return { ok = true, code = 'OK', data = data }
end

--- A failure Result. An unknown code is reported as INTERNAL_ERROR (the original is kept in data).
function WCResult.fail(code, data)
    if not MESSAGES[code] or code == 'OK' then
        data = { code = code, data = data }
        code = 'INTERNAL_ERROR'
    end
    return { ok = false, code = code, message = MESSAGES[code], data = data }
end

--- `r` (a failure Result) with its specifics: DETAILS[name] filled with the args. Returns `r`.
function WCResult.detail(r, name, ...)
    if type(r) == 'table' and r.ok == false and DETAILS[name] then
        r.detail = { key = DETAILS[name], args = { ... } }
    end
    return r
end

--- The text a player reads for a failure Result: its detail when it carries one, else its message.
---@param tr function the translator (locale / L): tr(key, ...) -> text
function WCResult.text(r, tr)
    if type(r) ~= 'table' then return tr(MESSAGES.INTERNAL_ERROR) end
    local d = r.detail
    if type(d) == 'table' and type(d.key) == 'string' and type(d.args) == 'table' then
        local ok, text = pcall(tr, d.key, table.unpack(d.args))
        if ok and type(text) == 'string' then return text end
    end
    return tr(r.message or WCResult.messageKey(r.code))
end

--- Is this value a Result table?
function WCResult.is(r)
    return type(r) == 'table' and type(r.ok) == 'boolean' and type(r.code) == 'string'
end
