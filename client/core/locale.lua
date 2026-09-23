-- =====================================================================
--  client/core/locale.lua  —  the locale helpers (ARCHITECTURE.md §3.2, §0.7)
--  The language is the library's (w.getLocaleKey): the player's choice in /w_lib or the server
--  convar w_lib:locale. The Arabic source texts are the dictionary keys; locales/en.json
--  translates them and the global locale() returns the key when a translation is missing.
--  Only 'ar' and 'en' ship: anything else is treated as 'en'.
-- =====================================================================

--- Normalise any language key to 'ar' | 'en'.
local function normalise(key)
    return (type(key) == 'string' and key:sub(1, 2):lower() == 'ar') and 'ar' or 'en'
end

--- The effective language key, normalised to 'ar' | 'en'.
---@return string
function UiLocale()
    local ok, key = pcall(function() return w.getLocaleKey() end)
    return normalise(ok and key or nil)
end

--- The interface's writing direction for the current language: 'rtl' or 'ltr'.
---@return string
function UiDir()
    return UiLocale() == 'ar' and 'rtl' or 'ltr'
end

--- Single text fields translated in a tree (the legacy menu fields and the v3 Node fields).
local TRANSLATED_FIELDS = {
    name = true, subTitle = true, title = true,
    label = true, hint = true, summary = true, badgeLabel = true, reason = true,
    actionLabel = true, placeholder = true,
}

--- Fields carrying a list of texts translated item by item (the pads' axis labels).
local TRANSLATED_LISTS = { xLabel = true, yLabel = true }

--- Translate every text field of a data tree into a new copy.
--  A copy rather than an edit in place: the source keeps its Arabic keys so it translates
--  correctly again when the player switches language during play.
---@param node any
---@return any
function TranslateTree(node)
    if type(node) ~= 'table' then return node end
    local out = {}
    for k, v in pairs(node) do
        if TRANSLATED_LISTS[k] and type(v) == 'table' then
            local list = {}
            for i = 1, #v do
                list[i] = type(v[i]) == 'string' and locale(v[i]) or v[i]
            end
            out[k] = list
        elseif type(v) == 'table' then
            out[k] = TranslateTree(v)
        elseif TRANSLATED_FIELDS[k] and type(v) == 'string' then
            out[k] = locale(v)
        else
            out[k] = v
        end
    end
    return out
end

-- ---------------------------------------------------------------------
--  Live switching
--  w_lib fires 'w_lib:setLocale'(key) when the player switches language. The dictionary is
--  reloaded here first (the library's own handler may run after ours), then every screen that
--  built texts re-applies them through the refreshers registered with OnLanguageChange.
-- ---------------------------------------------------------------------
local refreshers = {}

--- Register a function that re-applies a screen's texts after a language switch.
---@param fn fun(key: string)
function OnLanguageChange(fn)
    if type(fn) == 'function' or (type(fn) == 'table' and getmetatable(fn) and getmetatable(fn).__call) then
        refreshers[#refreshers + 1] = fn
    end
end

AddEventHandler('w_lib:setLocale', function(key)
    local normalised = normalise(key)
    local ok, err = pcall(function() w.locale(normalised) end)
    if not ok then WCDebug.warn('locale', 'dictionary reload failed: %s', tostring(err)) end
    for i = 1, #refreshers do
        local done, failure = pcall(refreshers[i], normalised)
        if not done then WCDebug.warn('locale', 'language refresh failed: %s', tostring(failure)) end
    end
end)
