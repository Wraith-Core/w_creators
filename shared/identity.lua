-- =====================================================================
--  shared/identity.lua  —  WCIdentity (ARCHITECTURE.md §6.3)
--  firstname / lastname: Config.Characters.identity.nameMin..nameMax UTF-8 characters of letters
--  (Latin incl. Latin-1 letters, Arabic U+0621–U+064A and U+066E–U+06D3), space, apostrophe and
--  hyphen; starting and ending with a letter (not the tatweel U+0640). Surrounding spaces are
--  trimmed and inner runs of spaces collapsed. Digits, symbols, emoji and invalid UTF-8 are rejected.
--  dob: YYYY-MM-DD, a real calendar date, the age within minAge..maxAge relative to referenceYear
--  (nil = the current real date).
--  The sex is not part of the identity: it comes from the server-granted creation session.
-- =====================================================================

WCIdentity = {}

local function settings()
    local cfg = Config and Config.Characters and Config.Characters.identity or {}
    return {
        minAge = tonumber(cfg.minAge) or 18,
        maxAge = tonumber(cfg.maxAge) or 90,
        referenceYear = tonumber(cfg.referenceYear),
        nameMin = tonumber(cfg.nameMin) or 2,
        nameMax = tonumber(cfg.nameMax) or 25,
    }
end

local function isLetter(cp)
    return (cp >= 0x41 and cp <= 0x5A) or (cp >= 0x61 and cp <= 0x7A)
        or (cp >= 0xC0 and cp <= 0xFF and cp ~= 0xD7 and cp ~= 0xF7)
        or (cp >= 0x0621 and cp <= 0x064A)
        or (cp >= 0x066E and cp <= 0x06D3)
end

local SPACE, APOSTROPHE, HYPHEN, TATWEEL = 0x20, 0x27, 0x2D, 0x0640

-- Arabic diacritics (harakat U+064B–U+0652, superscript alef U+0670): allowed inside a name
-- after a letter (e.g. مُحَمَّد), never as its first or last character.
local function isMark(cp)
    return (cp >= 0x064B and cp <= 0x0652) or cp == 0x0670
end

-- The first and last character: a letter other than the tatweel (a stretching mark, not a letter
-- of its own), so a name is never made of tatweel alone.
local function isBoundaryLetter(cp)
    return cp ~= TATWEEL and isLetter(cp)
end

--- Validate a first or last name. Returns true, cleaned | false, 'INVALID_NAME'.
function WCIdentity.validateName(s)
    if type(s) ~= 'string' then return false, 'INVALID_NAME' end
    local cleaned = WCUtil.trim(s):gsub('%s+', ' ')
    local codes = {}
    local ok = pcall(function()
        for _, cp in utf8.codes(cleaned) do codes[#codes + 1] = cp end
    end)
    if not ok then return false, 'INVALID_NAME' end
    local cfg = settings()
    if #codes < cfg.nameMin or #codes > cfg.nameMax then return false, 'INVALID_NAME' end
    for _, cp in ipairs(codes) do
        if not (isLetter(cp) or isMark(cp) or cp == SPACE or cp == APOSTROPHE or cp == HYPHEN) then
            return false, 'INVALID_NAME'
        end
    end
    for i = 2, #codes do
        -- a mark must follow a letter (no stacked marks after spaces/punctuation)
        if isMark(codes[i]) and not (isLetter(codes[i - 1]) or isMark(codes[i - 1])) then return false, 'INVALID_NAME' end
    end
    local last = #codes
    while last > 1 and isMark(codes[last]) do last = last - 1 end
    if not isBoundaryLetter(codes[1]) or not isBoundaryLetter(codes[last]) then return false, 'INVALID_NAME' end
    return true, cleaned
end

local DAYS = { 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 }

local function isLeap(y)
    return (y % 4 == 0 and y % 100 ~= 0) or y % 400 == 0
end

--- Validate a date of birth. Returns true, 'YYYY-MM-DD', age | false, 'INVALID_DOB'.
function WCIdentity.validateDob(s)
    if type(s) ~= 'string' then return false, 'INVALID_DOB' end
    local ys, ms, ds = WCUtil.trim(s):match('^(%d%d%d%d)%-(%d%d)%-(%d%d)$')
    if not ys then return false, 'INVALID_DOB' end
    local y, m, d = tonumber(ys), tonumber(ms), tonumber(ds)
    if y < 1 or m < 1 or m > 12 or d < 1 then return false, 'INVALID_DOB' end
    local maxDay = (m == 2 and isLeap(y)) and 29 or DAYS[m]
    if d > maxDay then return false, 'INVALID_DOB' end

    local cfg = settings()
    local age
    if cfg.referenceYear then
        age = cfg.referenceYear - y
    else
        local now = os.date('*t')
        age = now.year - y
        if now.month < m or (now.month == m and now.day < d) then age = age - 1 end
    end
    if age < cfg.minAge or age > cfg.maxAge then return false, 'INVALID_DOB' end
    return true, ('%04d-%02d-%02d'):format(y, m, d), age
end

--- Validate a whole identity { firstname, lastname, dob }.
--  Returns true, { firstname, lastname, dob, age } | false, 'INVALID_NAME' | 'INVALID_DOB' | 'INVALID_PAYLOAD'.
function WCIdentity.validate(identity)
    if type(identity) ~= 'table' then return false, 'INVALID_PAYLOAD' end
    local okFirst, first = WCIdentity.validateName(identity.firstname)
    if not okFirst then return false, first end
    local okLast, last = WCIdentity.validateName(identity.lastname)
    if not okLast then return false, last end
    local okDob, dob, age = WCIdentity.validateDob(identity.dob)
    if not okDob then return false, dob end
    return true, { firstname = first, lastname = last, dob = dob, age = age }
end
