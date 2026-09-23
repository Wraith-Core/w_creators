-- =====================================================================
--  shared/debug.lua  —  WCDebug
--  Debug output (ARCHITECTURE.md §0.9). log() is silent unless Config.Debug.enabled and the domain
--  is selected (Config.Debug.domains empty = every domain). warn() always reports: it is used for
--  configuration and data problems an operator must see.
-- =====================================================================

WCDebug = {}

local function format(fmt, ...)
    if select('#', ...) == 0 then return tostring(fmt) end
    local ok, text = pcall(string.format, tostring(fmt), ...)
    if ok then return text end
    local parts = { tostring(fmt) }
    for i = 1, select('#', ...) do parts[#parts + 1] = tostring((select(i, ...))) end
    return table.concat(parts, ' ')
end

local function emit(level, domain, text)
    local line = ('[%s] %s'):format(tostring(domain or 'w_creators'), text)
    local printer = type(w) == 'table' and type(w.print) == 'table' and w.print[level]
    if printer then
        local ok = pcall(printer, '%s', line)
        if ok then return end
    end
    -- no w_lib printer (it failed to load): the runtime's console trace
    local trace = type(Citizen) == 'table' and Citizen.Trace
    if type(trace) == 'function' then pcall(trace, ('[w_creators] %s\n'):format(line)) end
end

--- Is debug output enabled (for this domain)?
function WCDebug.enabled(domain)
    local cfg = Config and Config.Debug
    if type(cfg) ~= 'table' or cfg.enabled ~= true then return false end
    if domain == nil then return true end
    local domains = cfg.domains
    if type(domains) ~= 'table' or next(domains) == nil then return true end
    if domains[domain] == true then return true end
    for _, name in ipairs(domains) do
        if name == domain then return true end
    end
    return false
end

--- Debug line (silent unless enabled for the domain).
function WCDebug.log(domain, fmt, ...)
    if not WCDebug.enabled(domain) then return end
    emit('debug', domain, format(fmt, ...))
end

--- Warning (always reported).
function WCDebug.warn(domain, fmt, ...)
    emit('warn', domain, format(fmt, ...))
end
