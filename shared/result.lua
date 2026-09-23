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
    LOCATION_NOT_FOUND           = 'المكان غير موجود',
    TOO_FAR                      = 'أنت بعيد جدًا عن المكان',
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
    STORE_DISABLED               = 'متجر الملابس مغلق',
    BARBER_DISABLED              = 'الحلاق مغلق',
    SURGERY_DISABLED             = 'عمليات التجميل غير متاحة',
    SURGERY_NOT_ALLOWED          = 'هذا التعديل غير مسموح في عملية التجميل',
    WARDROBE_DISABLED            = 'الخزانة غير متاحة',
    OUTFITS_DISABLED             = 'حفظ الأطقم غير متاح',
    OUTFIT_LIMIT                 = 'وصلت إلى الحد الأقصى من الأطقم',
    OUTFIT_NOT_FOUND             = 'الطقم غير موجود',
    INVALID_OUTFIT_NAME          = 'اسم الطقم غير صالح',
    STATE_NOT_SUPPORTED          = 'هذه الحالة غير مدعومة',
    STATE_NOT_APPLICABLE         = 'لا يمكن تطبيق هذه الحالة الآن',
    ACTIONS_DISABLED             = 'إجراءات الملابس معطّلة',
    INVALID_SPAWN                = 'مكان ظهور غير صالح',
    SPAWN_NOT_PENDING            = 'لا يوجد ظهور بانتظارك',
    DATABASE_ERROR               = 'خطأ في قاعدة البيانات',
    INTERNAL_ERROR               = 'حدث خطأ داخلي',
}

for code in pairs(MESSAGES) do WCCodes[code] = code end

WCResult.messages = MESSAGES

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

--- Is this value a Result table?
function WCResult.is(r)
    return type(r) == 'table' and type(r.ok) == 'boolean' and type(r.code) == 'string'
end
