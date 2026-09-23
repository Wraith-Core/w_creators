-- =====================================================================
--  shared/util.lua  —  WCUtil
--  Small, dependency-free helpers shared by client and server. Nothing here throws on bad input.
-- =====================================================================

WCUtil = {}
local U = WCUtil

local HUGE = math.huge

--- Deep copy of a value (tables are copied recursively; metatables are not carried).
function U.copy(value, seen)
    if type(value) ~= 'table' then return value end
    seen = seen or {}
    if seen[value] then return seen[value] end
    local out = {}
    seen[value] = out
    for k, v in pairs(value) do out[U.copy(k, seen)] = U.copy(v, seen) end
    return out
end

--- Structural equality (numbers compare by value, so 1 == 1.0).
function U.deepEqual(a, b)
    if a == b then return true end
    if type(a) ~= 'table' or type(b) ~= 'table' then return false end
    for k, v in pairs(a) do
        if not U.deepEqual(v, b[k]) then return false end
    end
    for k in pairs(b) do
        if a[k] == nil then return false end
    end
    return true
end

--- A real, finite number (not NaN, not ±inf).
function U.isFinite(n)
    return type(n) == 'number' and n == n and n ~= HUGE and n ~= -HUGE
end

--- A finite number clamped to [lo, hi]; anything else (nil, NaN, inf, garbage) -> fallback.
function U.number(v, lo, hi, fallback)
    v = tonumber(v)
    if not U.isFinite(v) then return fallback end
    if lo and v < lo then v = lo end
    if hi and v > hi then v = hi end
    return v
end

--- An integer (floored) clamped to [lo, hi]; invalid -> fallback. A value that has no integer
--  representation after clamping (e.g. 1e300 without a hi bound) is invalid too.
function U.int(v, lo, hi, fallback)
    v = tonumber(v)
    if not U.isFinite(v) then return fallback end
    v = math.floor(v)
    if lo and v < lo then v = lo end
    if hi and v > hi then v = hi end
    local i = math.tointeger(v)
    if i == nil then return fallback end
    return i
end

--- JSON string | table -> table. Invalid JSON, nil or any other type -> {} (never throws).
function U.decode(v)
    if type(v) == 'table' then return v end
    if type(v) ~= 'string' or v == '' then return {} end
    local ok, data = pcall(json.decode, v)
    if ok and type(data) == 'table' then return data end
    return {}
end

--- table -> JSON string, or nil (+ error) when the value cannot be encoded (NaN, cycles, mixed keys).
function U.encode(v)
    local ok, out = pcall(json.encode, v)
    if ok and type(out) == 'string' then return out end
    return nil, out
end

local TYPE_ORDER = { number = 1, string = 2, boolean = 3 }

--- The keys of t in a stable order (numbers first, then strings; or by cmp).
function U.sortedKeys(t, cmp)
    local keys = {}
    if type(t) ~= 'table' then return keys end
    for k in pairs(t) do keys[#keys + 1] = k end
    table.sort(keys, cmp or function(a, b)
        local ta, tb = type(a), type(b)
        if ta ~= tb then return (TYPE_ORDER[ta] or 9) < (TYPE_ORDER[tb] or 9) end
        if ta == 'number' or ta == 'string' then return a < b end
        return tostring(a) < tostring(b)
    end)
    return keys
end

--- Strip leading/trailing whitespace. Non-strings -> ''.
function U.trim(s)
    if type(s) ~= 'string' then return '' end
    return (s:gsub('^%s+', ''):gsub('%s+$', ''))
end

--- Number of UTF-8 characters, or nil for a non-string / invalid UTF-8.
function U.utf8len(s)
    if type(s) ~= 'string' then return nil end
    local ok, n = pcall(utf8.len, s)
    if ok and n then return n end
    return nil
end

--- Round to cents (half away from zero). Non-finite -> nil.
function U.round2(n)
    n = tonumber(n)
    if not U.isFinite(n) then return nil end
    local sign = n < 0 and -1 or 1
    local cents = math.floor(math.abs(n) * 100 + 0.5 + 1e-9)
    local out = sign * cents / 100
    if not U.isFinite(out) then return nil end
    return out
end

--- Normalise a (possibly signed) 32-bit hash to its unsigned value. Non-integers -> nil.
function U.u32(h)
    h = tonumber(h)
    if not U.isFinite(h) or h % 1 ~= 0 then return nil end
    local i = math.tointeger(h)
    if not i then return nil end
    return i & 0xffffffff
end

--- Poll fn until it returns a truthy value or the timeout elapses. Returns that value or nil.
--  Never a blind sleep: this is the condition wait of ARCHITECTURE.md §0.8. An error in fn counts as
--  "not yet".
function U.waitUntil(fn, timeoutMs, stepMs)
    local timer = GetGameTimer
    local start = timer()
    timeoutMs = tonumber(timeoutMs) or 5000
    while true do
        local ok, value = pcall(fn)
        if ok and value then return value end
        if timer() - start >= timeoutMs then return nil end
        Wait(stepMs or 0)
    end
end

local CHAR_PATTERN = utf8.charpattern

--- Keep only valid UTF-8 characters and truncate to maxChars characters.
function U.clampString(s, maxChars)
    if type(s) ~= 'string' then return '' end
    local out, n = {}, 0
    maxChars = tonumber(maxChars) or HUGE
    for ch in s:gmatch(CHAR_PATTERN) do
        local ok, len = pcall(utf8.len, ch)
        if ok and len == 1 then
            if n >= maxChars then break end
            n = n + 1
            out[n] = ch
        end
    end
    return table.concat(out)
end

--- Bytes of the JSON-encoded value (math.huge when it cannot be encoded).
function U.jsonSize(v)
    local encoded = U.encode(v)
    return encoded and #encoded or HUGE
end

--- x, y, z of a vector3/vector4 or a { x, y, z } / { [1], [2], [3] } table; nil when not finite.
function U.xyz(v)
    if v == nil then return nil end
    local ok, x, y, z = pcall(function()
        if type(v) == 'table' and v.x == nil then return v[1], v[2], v[3] end
        return v.x, v.y, v.z
    end)
    if not ok then return nil end
    x, y, z = tonumber(x), tonumber(y), tonumber(z)
    if not (U.isFinite(x) and U.isFinite(y) and U.isFinite(z)) then return nil end
    return x, y, z
end

--- Squared distance between two coordinates (see U.xyz); nil when either is invalid.
function U.dist2(a, b)
    local ax, ay, az = U.xyz(a)
    local bx, by, bz = U.xyz(b)
    if not ax or not bx then return nil end
    return (ax - bx) ^ 2 + (ay - by) ^ 2 + (az - bz) ^ 2
end

--- Set of a list: { 'a', 'b' } -> { a = true, b = true }. A set passes through (copied).
function U.set(list)
    local out = {}
    if type(list) ~= 'table' then return out end
    for k, v in pairs(list) do
        if type(k) == 'number' and type(v) == 'string' then out[v] = true
        elseif type(k) == 'string' and v then out[k] = true end
    end
    return out
end
