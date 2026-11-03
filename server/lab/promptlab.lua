-- =====================================================================
--  server/lab/promptlab.lua  —  WCPromptLab: the server half of the staff's /promptlab (2026-11-03)
--  The gate: only a player with Config.Admin.ace (the /servicesadmin permission, held by the master rank on both
--  servers through w_core's ranks catalogue) may open the lab or send a report; anyone else gets { ok = false }
--  and nothing is written.
--  The report: every answer arrives as kind 'result', the end as kind 'final'. Each is cleaned (plain ASCII,
--  bounded size and depth) and appended as one JSON line to promptlab.jsonl in this resource's folder (git-ignored,
--  kept by the deploys). The final one also prints ONE console line (Citizen.Trace, so the quiet console does not
--  drop it): "[w_creators] PROMPTLAB <code> src=<id> lic=..<4> ... 01:y/F.M ..." - no names, no full identifiers.
--  The flags after an answer are measured by the lab, not said by the owner:
--    F fired our replay (Fc game control, Fk our card key)   M mounted   L looting started   E EVENT_LOOT_COMPLETE
--    for this player (E= the same body)   C carrying (Ct the target)   D dropped   S sat (scenario)   H hogtie changed
--    K skinned changed   P<n> the game's prompt was live in n % of the frames   R per-ped readback moved
--    X native call errors   #<n> the sweep numbers the owner marked
-- =====================================================================

WCPromptLab = {}
local PL = WCPromptLab

PL.FILE = 'promptlab.jsonl'
PL.PREFIX = 'PROMPTLAB'

local MAX_PAYLOAD = 49152      -- bytes of JSON one report may carry
local MAX_FILE = 1048576       -- the file keeps its newest lines below this size
local MAX_DEPTH = 8            -- report > results > result > attempts > attempt > err > item: 7
local MAX_ITEMS = 60
local MAX_KEYS = 48
local MAX_STRING = 160
-- words the console watcher of the deploy agent reads as a fault; never part of a report line
local FAULT_WORDS = { 'error', 'warn', 'fail', 'exception', 'traceback', 'blocked', 'mismatch', 'attempt to' }

local sessions = {}            -- [src] = { code, opened }

--- May this player use the lab? (the services board's permission; the console never)
function PL.isStaff(src)
    src = tonumber(src)
    if not src or src <= 0 then return false end
    local ace = Config.Admin and Config.Admin.ace
    if type(ace) ~= 'string' or ace == '' then return false end
    local done, allowed = pcall(IsPlayerAceAllowed, tostring(src), ace)
    return done and (allowed == true or allowed == 1)
end

--- A copy of a client value that is safe to store and print: ASCII strings (cut), finite numbers, booleans,
--  tables of bounded depth / size with [A-Za-z0-9_] keys. Everything else is dropped.
function PL.clean(value, depth)
    depth = depth or 0
    local kind = type(value)
    if kind == 'number' then
        if value ~= value or value == math.huge or value == -math.huge then return nil end
        return value
    elseif kind == 'boolean' then
        return value
    elseif kind == 'string' then
        return (value:gsub('[^\32-\126]', '?'):sub(1, MAX_STRING))
    elseif kind ~= 'table' or depth >= MAX_DEPTH then
        return nil
    end
    local out = {}
    if #value > 0 then
        for i = 1, math.min(#value, MAX_ITEMS) do
            local v = PL.clean(value[i], depth + 1)
            if v ~= nil then out[#out + 1] = v end
        end
        return out
    end
    local n = 0
    for k, v in pairs(value) do
        if type(k) == 'string' and #k <= 32 and k:match('^[%w_]+$') then
            local c = PL.clean(v, depth + 1)
            if c ~= nil then
                n = n + 1
                if n > MAX_KEYS then break end
                out[k] = c
            end
        end
    end
    return out
end

--- The last four characters of the player's license (enough to tell two testers apart, nothing more).
function PL.mask(src)
    local ok, id = pcall(GetPlayerIdentifierByType, tostring(src), 'license')
    if not ok or type(id) ~= 'string' or #id < 4 then return '..' end
    return '..' .. id:sub(-4):gsub('[^%w]', '')
end

--- The flags of one result (see the header), from its last attempt.
function PL.flags(result)
    local attempts = type(result) == 'table' and result.attempts
    local a = type(attempts) == 'table' and attempts[#attempts] or nil
    if type(a) ~= 'table' then return '' end
    local f = {}
    local function add(s) f[#f + 1] = s end
    if type(a.fire) == 'table' then add(a.fire.src == 'card' and 'Fk' or 'Fc') end
    if a.mount then add('M') end
    if a.loot then add('L') end
    if type(a.ev) == 'table' then add(a.ev.same and 'E=' or 'E') end
    if a.carry then add(a.carryT and 'Ct' or 'C') end
    if a.drop then add('D') end
    if a.sat then add('S') end
    if a.melee then add('B') end
    if a.hog0 ~= nil and a.hog1 ~= nil and a.hog0 ~= a.hog1 then add('H') end
    if a.skin0 ~= nil and a.skin1 ~= nil and a.skin0 ~= a.skin1 then add('K') end
    if tonumber(a.pf) and a.pf > 0 then add('P' .. math.floor((tonumber(a.pa) or 0) * 100 / a.pf + 0.5)) end
    if type(a.rb) == 'table' and a.rb.r0 ~= nil and a.rb.r1 ~= nil and a.rb.r0 ~= a.rb.r1 then add('R') end
    if type(a.err) == 'table' and #a.err > 0 then add('X' .. #a.err) end
    if type(a.hits) == 'table' and #a.hits > 0 then
        local marks = {}
        for i = 1, math.min(#a.hits, 8) do marks[#marks + 1] = tostring(math.tointeger(tonumber(a.hits[i].n) or 0)) end
        add('#' .. table.concat(marks, '+'))
    end
    return table.concat(f, '.')
end

--- Strip the agent's fault words (case-insensitive) from a console line.
local function quiet(line)
    for _, word in ipairs(FAULT_WORDS) do
        local pattern = word:gsub('%a', function(c) return '[' .. c:lower() .. c:upper() .. ']' end)
        line = line:gsub(pattern, '*')
    end
    return line
end

--- The one console line of a final report.
function PL.consoleLine(src, code, report)
    local parts = { ('[w_creators] %s %s src=%s lic=%s'):format(PL.PREFIX, tostring(code), tostring(src), PL.mask(src)) }
    report = type(report) == 'table' and report or {}
    parts[#parts + 1] = ('kb=%s n=%s last=%s end=%s'):format(report.kb and 1 or 0, tostring(report.n or '?'),
        tostring(report.last or '?'), tostring(report.reason or '?'))
    for _, r in ipairs(type(report.results) == 'table' and report.results or {}) do
        if type(r) == 'table' then
            local flags = PL.flags(r)
            parts[#parts + 1] = ('%s:%s%s'):format(tostring(r.id or '?'), tostring(r.answer or '?'),
                flags ~= '' and ('/' .. flags) or '')
        end
    end
    parts[#parts + 1] = '(full: ' .. PL.FILE .. ')'
    return quiet((table.concat(parts, ' '):gsub('[^\32-\126]', '?')))
end

--- Append one JSON line to promptlab.jsonl (the oldest lines go once the file passes MAX_FILE).
function PL.append(record)
    local line = WCUtil.encode(record)
    if type(line) ~= 'string' then return false end
    local resource = GetCurrentResourceName()
    local old = LoadResourceFile(resource, PL.FILE) or ''
    local content = old .. line .. '\n'
    if #content > MAX_FILE then
        local cut = content:find('\n', #content - math.floor(MAX_FILE / 2), true)
        content = cut and content:sub(cut + 1) or (line .. '\n')
    end
    local ok, saved = pcall(SaveResourceFile, resource, PL.FILE, content, -1)
    return ok and saved ~= false
end

local function stamp() return os.date('!%Y-%m-%dT%H:%M:%SZ') end

function PL.open(src)
    if not PL.isStaff(src) then return { ok = false } end
    if not WCSecurity.rate(src, 'promptlab:open', 5, 10000) then return { ok = false } end
    local seed = ('%s:%s:%s'):format(tostring(src), tostring(os.time()), tostring(GetGameTimer()))
    local code = ('PL-%04X'):format(GetHashKey(seed) & 0xFFFF)
    sessions[tonumber(src)] = { code = code, opened = stamp() }
    PL.append({ k = 'open', code = code, src = tonumber(src), lic = PL.mask(src), at = stamp() })
    return { ok = true, code = code }
end

function PL.report(src, kind, payload)
    if not PL.isStaff(src) then return { ok = false, error = 'denied' } end
    if kind ~= 'result' and kind ~= 'final' then return { ok = false, error = 'kind' } end
    if not WCSecurity.rate(src, 'promptlab:report', 40, 60000) then return { ok = false, error = 'rate' } end
    if type(payload) ~= 'table' or not WCSecurity.payload(payload, MAX_PAYLOAD) then
        return { ok = false, error = 'payload' }
    end
    local session = sessions[tonumber(src)]
    local code = session and session.code or 'PL-0000'
    local data = PL.clean(payload)
    local saved = PL.append({ k = kind, code = code, src = tonumber(src), lic = PL.mask(src), at = stamp(), data = data })
    if kind == 'final' then
        local trace = type(Citizen) == 'table' and Citizen.Trace
        if type(trace) == 'function' then pcall(trace, PL.consoleLine(src, code, data) .. '\n') end
        sessions[tonumber(src)] = nil
    end
    return { ok = true, code = code, saved = saved }
end

-- the names are written out here (the static tests match a client's callbacks to these registrations)
w.callback.register('w_creators:promptlab:open', function(src) return PL.open(src) end)
w.callback.register('w_creators:promptlab:report', function(src, kind, payload) return PL.report(src, kind, payload) end)

AddEventHandler('playerDropped', function()
    sessions[tonumber(source)] = nil
end)
