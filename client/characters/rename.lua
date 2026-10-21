-- =====================================================================
--  client/characters/rename.lua  —  the name change dialog (2026-10-21)
--  server/characters/rename.lua decides everything (the token, the names, the save); this only asks the
--  two names and shows the answer. The Arabic source texts are the dictionary keys (locales/en.json).
-- =====================================================================

local ERRORS = {
    no_token = 'ليس لديك تذكرة تغيير اسم. تقدر تشتريها من متجر السيرفر.',
    bad_name = 'الاسم غير صالح: استخدم الحروف فقط، من حرفين إلى 25 حرفًا.',
    no_character = 'اختر شخصيتك أولًا ثم اكتب الأمر.',
}

local function notify(text, kind)
    pcall(w.notify, { description = locale(text), type = kind or 'error' })
end

RegisterNetEvent('w_creators:client:renameAsk', function(left)
    local values = lib.inputDialog(locale('تغيير اسم الشخصية'), {
        { type = 'input', label = locale('الاسم الأول'), required = true, max = 25 },
        { type = 'input', label = locale('اسم العائلة'), required = true, max = 25 },
    }, { allowCancel = true, size = 'sm' })
    if not values then return end
    local ok, res = pcall(w.callback.await, 'w_creators:rename', false, values[1], values[2])
    if ok and type(res) == 'table' and res.ok then
        return notify(locale('تم تغيير اسم شخصيتك إلى: %s', tostring(res.name)), 'success')
    end
    local code = ok and type(res) == 'table' and res.error or nil
    notify(ERRORS[code] or 'تعذّر تغيير الاسم، حاول مرة ثانية.')
end)

CreateThread(function()
    TriggerEvent('chat:addSuggestion', '/changename', locale('تغيير اسم شخصيتك بتذكرة من متجر السيرفر'))
end)
