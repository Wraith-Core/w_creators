-- A small pure-Lua JSON codec for the tests, behaving like the rxi json.lua bundled with the
-- CitizenFX Lua runtime: encode errors on NaN/inf, on mixed or sparse tables and on cycles;
-- an empty table encodes as []; decode errors on malformed input; null decodes to nil.

local json = {}

local escapes = { ['\\'] = '\\\\', ['"'] = '\\"', ['\b'] = '\\b', ['\f'] = '\\f', ['\n'] = '\\n',
                  ['\r'] = '\\r', ['\t'] = '\\t' }

local function escape(s)
    return (s:gsub('[%c"\\]', function(c)
        return escapes[c] or ('\\u%04x'):format(c:byte())
    end))
end

local encode

local function encodeTable(t, stack)
    if stack[t] then error('circular reference') end
    stack[t] = true
    local out = {}
    if rawget(t, 1) ~= nil or next(t) == nil then
        local n = 0
        for k in pairs(t) do
            if type(k) ~= 'number' then error('invalid table: mixed or invalid key types') end
            n = n + 1
        end
        if n ~= #t then error('invalid table: sparse array') end
        for i = 1, n do out[i] = encode(t[i], stack) end
        stack[t] = nil
        return '[' .. table.concat(out, ',') .. ']'
    end
    for k, v in pairs(t) do
        if type(k) ~= 'string' then error('invalid table: mixed or invalid key types') end
        out[#out + 1] = encode(k, stack) .. ':' .. encode(v, stack)
    end
    table.sort(out)
    stack[t] = nil
    return '{' .. table.concat(out, ',') .. '}'
end

encode = function(v, stack)
    local t = type(v)
    if t == 'nil' then return 'null' end
    if t == 'boolean' then return tostring(v) end
    if t == 'number' then
        if v ~= v or v == math.huge or v == -math.huge then
            error("unexpected number value '" .. tostring(v) .. "'")
        end
        if math.type(v) == 'integer' then return tostring(v) end
        return ('%.14g'):format(v)
    end
    if t == 'string' then return '"' .. escape(v) .. '"' end
    if t == 'table' then return encodeTable(v, stack or {}) end
    error("unexpected type '" .. t .. "'")
end

function json.encode(v)
    return encode(v, {})
end

local function decodeError(str, idx, msg)
    error(('%s at char %d'):format(msg, idx))
end

local function skip(str, i)
    local _, e = str:find('^[ \n\r\t]*', i)
    return e + 1
end

local decodeValue

local function decodeString(str, i)
    local out, j = {}, i + 1
    while true do
        local c = str:sub(j, j)
        if c == '' then decodeError(str, j, 'unterminated string') end
        if c == '"' then return table.concat(out), j + 1 end
        if c == '\\' then
            local n = str:sub(j + 1, j + 1)
            local map = { b = '\b', f = '\f', n = '\n', r = '\r', t = '\t', ['"'] = '"', ['\\'] = '\\', ['/'] = '/' }
            if map[n] then
                out[#out + 1] = map[n]
                j = j + 2
            elseif n == 'u' then
                local hex = str:sub(j + 2, j + 5)
                if not hex:match('^%x%x%x%x$') then decodeError(str, j, 'invalid unicode escape') end
                local cp = tonumber(hex, 16)
                j = j + 6
                if cp >= 0xD800 and cp <= 0xDBFF and str:sub(j, j + 1) == '\\u' then
                    local lo = tonumber(str:sub(j + 2, j + 5), 16)
                    if lo and lo >= 0xDC00 and lo <= 0xDFFF then
                        cp = 0x10000 + (cp - 0xD800) * 0x400 + (lo - 0xDC00)
                        j = j + 6
                    end
                end
                out[#out + 1] = utf8.char(cp)
            else
                decodeError(str, j, 'invalid escape char')
            end
        else
            if c:byte() < 32 then decodeError(str, j, 'control character in string') end
            out[#out + 1] = c
            j = j + 1
        end
    end
end

local function decodeNumber(str, i)
    local s = str:match('^-?%d+%.?%d*[eE]?[-+]?%d*', i)
    if not s or s == '' or s == '-' then decodeError(str, i, 'invalid number') end
    local n = tonumber(s)
    if not n then decodeError(str, i, "invalid number '" .. s .. "'") end
    return n, i + #s
end

local literals = { ['true'] = true, ['false'] = false }

decodeValue = function(str, i)
    i = skip(str, i)
    local c = str:sub(i, i)
    if c == '{' then
        local out = {}
        i = skip(str, i + 1)
        if str:sub(i, i) == '}' then return out, i + 1 end
        while true do
            i = skip(str, i)
            if str:sub(i, i) ~= '"' then decodeError(str, i, 'expected string for key') end
            local key
            key, i = decodeString(str, i)
            i = skip(str, i)
            if str:sub(i, i) ~= ':' then decodeError(str, i, "expected ':' after key") end
            local value
            value, i = decodeValue(str, i + 1)
            out[key] = value
            i = skip(str, i)
            local d = str:sub(i, i)
            i = i + 1
            if d == '}' then return out, i end
            if d ~= ',' then decodeError(str, i, "expected '}' or ','") end
        end
    elseif c == '[' then
        local out, n = {}, 0
        i = skip(str, i + 1)
        if str:sub(i, i) == ']' then return out, i + 1 end
        while true do
            local value
            value, i = decodeValue(str, i)
            n = n + 1
            out[n] = value
            i = skip(str, i)
            local d = str:sub(i, i)
            i = i + 1
            if d == ']' then return out, i end
            if d ~= ',' then decodeError(str, i, "expected ']' or ','") end
        end
    elseif c == '"' then
        return decodeString(str, i)
    elseif c == '-' or c:match('%d') then
        return decodeNumber(str, i)
    elseif str:sub(i, i + 3) == 'null' then
        return nil, i + 4
    elseif str:sub(i, i + 3) == 'true' then
        return true, i + 4
    elseif str:sub(i, i + 4) == 'false' then
        return literals['false'], i + 5
    end
    decodeError(str, i, "unexpected character '" .. c .. "'")
end

function json.decode(str)
    if type(str) ~= 'string' then error("expected argument of type string, got " .. type(str)) end
    local value, i = decodeValue(str, 1)
    i = skip(str, i)
    if i <= #str then decodeError(str, i, 'trailing garbage') end
    return value
end

return json
