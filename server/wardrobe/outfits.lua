-- =====================================================================
--  server/wardrobe/outfits.lua  —  WCOutfits (ARCHITECTURE.md §3.3, §5.6, §16.4)
--  Saved outfits: w_creators_outfits(id, charid, name, data, created_at, updated_at) with
--  data = { equipped = { [category] = hash }, states = { [groupId] = value },
--           tints = { [category] = { palette, tint0..2 } } } — references to owned hashes only, and
--  each tint one of the colours the character owns of that item (colourways). An outfit without
--  `tints` (saved before) wears each item in its owned (last worn) colour. Limit
--  Config.Wardrobe.maxSavedOutfits per character.
--  Equipping an outfit happens in the wardrobe editor (and in a store, read only); the wardrobe
--  commit re-validates ownership and colours. A store purchase can save its look as an outfit in
--  the same transaction (WCOutfits.insertQuery, server/clothing/store.lua).
--
--  Data API (charid-scoped; an id of another character is never found):
--    WCOutfits.list(charid, sex?)                  [{ id, name, data }] | nil, 'DATABASE_ERROR'
--    WCOutfits.get(charid, id, sex?)               outfit | nil
--    WCOutfits.validateName(name)                  cleaned | nil
--    WCOutfits.validateData(charid, sex, equipped, states, worn?, owned?)  data | nil, code, detail
--    WCOutfits.create(charid, name, data)          id | nil, code
--    WCOutfits.update(charid, id, data) / rename(charid, id, name) / remove(charid, id)  true | nil, code
--    WCOutfits.max()                               the per-character limit
--  Session operations (the callbacks): WCOutfits.save(src, token, name, equipped, states),
--    updateOutfit(src, token, id, equipped, states), renameOutfit(src, token, id, name),
--    deleteOutfit(src, token, id) -> Result.
--  Callbacks (all need an open wardrobe session token and the savedOutfits service):
--    w_creators:outfits:save(token, name, equipped, states, tints?)   -> { outfit, outfits }
--    w_creators:outfits:update(token, id, equipped, states, tints?)   -> { outfit, outfits }
--    w_creators:outfits:rename(token, id, name)               -> { outfit, outfits }
--    w_creators:outfits:delete(token, id)                     -> { outfits }
-- =====================================================================

WCOutfits = {}
local Outfits = WCOutfits

local MAX_TOKEN = 128
local MAX_PAYLOAD = 8 * 1024
local NAME_COLUMN_MAX = 64 -- w_creators_outfits.name VARCHAR(64)
local LOCK_MS = 15000
local MIGRATION_WAIT_MS = 10000

local SELECT_LIST = 'SELECT id, name, data FROM w_creators_outfits WHERE charid = ? ORDER BY id'
local INSERT_OUTFIT = 'INSERT INTO w_creators_outfits (charid, name, data, created_at, updated_at) VALUES (?, ?, ?, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP)'
local UPDATE_DATA = 'UPDATE w_creators_outfits SET data = ?, updated_at = CURRENT_TIMESTAMP WHERE id = ? AND charid = ?'
local UPDATE_NAME = 'UPDATE w_creators_outfits SET name = ?, updated_at = CURRENT_TIMESTAMP WHERE id = ? AND charid = ?'
local DELETE_OUTFIT = 'DELETE FROM w_creators_outfits WHERE id = ? AND charid = ?'

local function fail(code, data) return WCResult.fail(code, data) end

local function schemaReady()
    if type(WCMigrations) ~= 'table' or type(WCMigrations.waitReady) ~= 'function' then return true end
    return WCMigrations.waitReady(MIGRATION_WAIT_MS) == true
end

local function db(kind, sql, values)
    if not schemaReady() then return false, 'migrations not ready' end
    return pcall(w.database[kind].await, sql, values)
end

--- The maximum number of saved outfits per character.
function Outfits.max()
    return WCUtil.int(Config.Wardrobe and Config.Wardrobe.maxSavedOutfits, 0, 100, 10)
end

local function nameMax()
    return WCUtil.int(Config.Wardrobe and Config.Wardrobe.outfitNameMax, 1, NAME_COLUMN_MAX, 24)
end

-- Code points that are never allowed in a name: C0/C1 controls and DEL, the soft hyphen, the
-- Arabic letter mark, the Mongolian vowel separator, zero-width spaces/joiners and LRM/RLM,
-- line/paragraph separators, bidi embeddings/overrides/isolates, the word joiner and the other
-- invisible operators, Hangul fillers, the BOM, interlinear annotations and tag characters (they
-- reorder, hide or blank text in other UIs).
local function forbidden(cp)
    return cp < 0x20 or (cp >= 0x7F and cp <= 0x9F) or cp == 0xAD or cp == 0x034F or cp == 0x061C
        or cp == 0x115F or cp == 0x1160 or cp == 0x180E or (cp >= 0x200B and cp <= 0x200F)
        or cp == 0x2028 or cp == 0x2029 or (cp >= 0x202A and cp <= 0x202E) or (cp >= 0x2060 and cp <= 0x206F)
        or cp == 0x3164 or cp == 0xFEFF or cp == 0xFFA0 or (cp >= 0xFFF9 and cp <= 0xFFFB)
        or (cp >= 0xE0000 and cp <= 0xE007F)
end

-- Space characters that count as one ordinary space (trimmed and collapsed like it).
local function isSpace(cp)
    return cp == 0x20 or cp == 0xA0 or cp == 0x1680 or (cp >= 0x2000 and cp <= 0x200A) or cp == 0x202F
        or cp == 0x205F or cp == 0x3000
end

--- A cleaned outfit name (every kind of space made an ordinary one, trimmed, inner spaces collapsed)
--  of 1..Config.Wardrobe.outfitNameMax UTF-8 characters with at least one visible character and no
--  control or invisible format character, or nil.
function Outfits.validateName(name)
    if type(name) ~= 'string' or #name > NAME_COLUMN_MAX * 4 + 16 then return nil end
    if not WCUtil.utf8len(name) then return nil end
    local chars = {}
    for _, cp in utf8.codes(name) do
        if forbidden(cp) then return nil end
        chars[#chars + 1] = isSpace(cp) and ' ' or utf8.char(cp)
    end
    local cleaned = table.concat(chars):gsub(' +', ' '):gsub('^ ', ''):gsub(' $', '')
    local len = WCUtil.utf8len(cleaned)
    if not len or len < 1 or len > nameMax() then return nil end
    return cleaned
end

-- A stored data column -> { equipped = { [category] = u32 }, states = { [group] = value },
-- tints = { [category] = tint } | nil }.
local function decodeData(raw, sex)
    local data = WCUtil.decode(raw)
    local equipped, states = {}, {}
    for category, hash in pairs(type(data.equipped) == 'table' and data.equipped or {}) do
        if WCCatalog.isClothing(category) then
            local h = sex and WCCatalog.resolve(sex, category, hash) or WCUtil.u32(hash)
            if h then equipped[category] = h end
        end
    end
    for group, value in pairs(type(data.states) == 'table' and data.states or {}) do
        if WCClothingStates.isValid(group, value) then states[group] = value end
    end
    local out = { equipped = equipped, states = states }
    -- the colour of each item (colourways): structurally valid stored tints of worn items only;
    -- `false` keeps an item's original colour
    if type(data.tints) == 'table' then
        out.tints = {}
        for category, tint in pairs(data.tints) do
            if equipped[category] then
                if tint == false then
                    out.tints[category] = false
                else
                    local clean = WCOwnership.storedTint(category, tint)
                    if clean then out.tints[category] = clean end
                end
            end
        end
    end
    return out
end

--- Every outfit of a character, ordered by id: [{ id, name, data = { equipped, states } }].
--  nil, 'DATABASE_ERROR' when the table cannot be read.
function Outfits.list(charid, sex)
    if charid == nil then return {} end
    local ok, rows = db('query', SELECT_LIST, { tostring(charid) })
    if not ok or (rows ~= nil and type(rows) ~= 'table') then
        WCDebug.warn('outfits', 'reading the outfits of %s failed: %s', tostring(charid), tostring(rows))
        return nil, 'DATABASE_ERROR'
    end
    local out = {}
    for _, row in ipairs(rows or {}) do
        local id = type(row) == 'table' and WCUtil.int(row.id, 1, nil, nil)
        if id then
            out[#out + 1] = { id = id, name = type(row.name) == 'string' and row.name or '',
                              data = decodeData(row.data, sex) }
        end
    end
    return out
end

--- One outfit of the character (by id) from a list, or nil.
local function find(list, id)
    for _, outfit in ipairs(list or {}) do
        if outfit.id == id then return outfit end
    end
    return nil
end

--- One outfit of a character, or nil.
function Outfits.get(charid, id, sex)
    id = WCOwnership.exactId(id)
    if not id then return nil end
    local list = Outfits.list(charid, sex)
    return list and find(list, id) or nil
end

--- Validate outfit contents for a character: every item a clothing item of the sex that the
--  character owns (or wears in `worn`, the saved equipped map), the rules hold, states valid, and
--  each tint (optional) a colour the character owns of that item (the original colour always; an
--  unowned worn item only its saved colour, `wornTints`). Returns data | nil, code, detail.
function Outfits.validateData(charid, sex, equipped, states, worn, owned, tints, wornTints)
    if type(equipped) ~= 'table' or (states ~= nil and type(states) ~= 'table')
        or (tints ~= nil and type(tints) ~= 'table') then
        return nil, 'INVALID_PAYLOAD'
    end
    local resolved, code, detail = WCOwnership.resolveEquipped(sex, equipped)
    if not resolved then return nil, code, detail end
    if not owned then
        owned, code = WCOwnership.list(charid)
        if not owned then return nil, code end
    end
    worn = type(worn) == 'table' and worn or {}
    for category, hash in pairs(resolved) do
        if not WCOwnership.entry(owned, hash) and worn[category] ~= hash then
            return nil, 'ITEM_NOT_OWNED', category
        end
    end
    local _, violations = WCRules.normalize(resolved)
    if #violations > 0 then return nil, 'CONFLICTING_ITEMS', violations[1].category end
    local cleanStates = {}
    local app = { clothing = { equipped = resolved } }
    -- With the clothing actions off no state is stored with an outfit (a later wardrobe commit of
    -- it would persist a state the player can no longer change).
    if not WCClothingStates.enabled() then states = nil end
    for group, value in pairs(states or {}) do
        if not WCClothingStates.isValid(group, value) then return nil, 'STATE_NOT_SUPPORTED', tostring(group) end
        -- Only persisting states of items the outfit wears are kept (a state of an item the outfit
        -- does not wear would hide the next item of that category).
        local def = WCClothingStates.byId[group]
        if def.persist and WCClothingStates.applicable(app, group, true) then cleanStates[group] = value end
    end
    local out = { equipped = resolved, states = cleanStates }
    if tints ~= nil then
        -- each item's colour: one the character owns of it (colourways); false is the item's
        -- original colour; an item without a tint wears its owned (last worn) colour
        out.tints = {}
        wornTints = type(wornTints) == 'table' and wornTints or {}
        for category, hash in pairs(resolved) do
            local tint = tints[category]
            if tint == false then
                out.tints[category] = false
            elseif type(tint) == 'table' and tint.palette then
                local ownedColor = WCOwnership.entry(owned, hash) and WCOwnership.ownsColor(owned, hash, tint, category)
                local wornColor = not WCOwnership.entry(owned, hash) and WCOwnership.sameTint(tint, wornTints[category])
                if not ownedColor and not wornColor then return nil, 'INVALID_TINT', category end
                local clean = WCOwnership.storedTint(category, tint)
                if not clean then return nil, 'INVALID_TINT', category end
                out.tints[category] = clean
            elseif tint ~= nil then
                return nil, 'INVALID_TINT', category
            end
        end
    end
    return out
end

local function encodeData(data)
    local encoded = WCUtil.encode({ equipped = data.equipped, states = data.states, tints = data.tints })
    if not encoded then return nil end
    return encoded
end

--- The INSERT of a new outfit as a transaction query (a store purchase saved as an outfit: the
--  outfit and the purchase commit together). nil when the data cannot be encoded.
function Outfits.insertQuery(charid, name, data)
    local encoded = encodeData(data)
    if not encoded then return nil end
    return { query = INSERT_OUTFIT, values = { tostring(charid), name, encoded } }
end

--- Insert an outfit. Returns id | nil, code.
function Outfits.create(charid, name, data)
    local encoded = encodeData(data)
    if not encoded then return nil, 'INVALID_PAYLOAD' end
    local ok, id = db('insert', INSERT_OUTFIT, { tostring(charid), name, encoded })
    id = ok and WCUtil.int(id, 1, nil, nil) or nil
    if not id then
        WCDebug.warn('outfits', 'saving an outfit of %s failed: %s', tostring(charid), tostring(id))
        return nil, 'DATABASE_ERROR'
    end
    return id
end

local function write(sql, values)
    local ok, affected = db('update', sql, values)
    if not ok then
        WCDebug.warn('outfits', 'outfit write failed: %s', tostring(affected))
        return nil, 'DATABASE_ERROR'
    end
    -- The id was checked against the character's list under the outfit lock; the affected-row count
    -- is not used (an UPDATE that changes nothing may report 0 rows).
    return true
end

--- Replace an outfit's contents. true | nil, code.
function Outfits.update(charid, id, data)
    local encoded = encodeData(data)
    if not encoded then return nil, 'INVALID_PAYLOAD' end
    return write(UPDATE_DATA, { encoded, id, tostring(charid) })
end

--- Rename an outfit. true | nil, code.
function Outfits.rename(charid, id, name)
    return write(UPDATE_NAME, { name, id, tostring(charid) })
end

--- Delete an outfit. true | nil, code.
function Outfits.remove(charid, id)
    return write(DELETE_OUTFIT, { id, tostring(charid) })
end

-- ---------------------------------------------------------------------
--  Callbacks
-- ---------------------------------------------------------------------

local function withinRange(src, loc)
    local radius = (tonumber(loc.interactionRadius) or 2.0) + 3.0
    if WCSecurity.near(src, WCLocations.anchor(loc), radius) then return true end
    return loc.preview ~= nil and WCSecurity.near(src, loc.preview, radius)
end

-- The open wardrobe session of the token: session | nil, code.
local function wardrobeSession(src, token)
    if not WCSecurity.rate(src, 'outfits', 10, 10000) then return nil, 'RATE_LIMITED' end
    if not WCServices.enabled('savedOutfits') then return nil, WCServices.code('savedOutfits') end
    if not WCServices.enabled('wardrobe') then return nil, WCServices.code('wardrobe') end
    if type(token) ~= 'string' or #token > MAX_TOKEN then return nil, 'SESSION_NOT_FOUND' end
    local s, code = WCSessions.get(src, token)
    if not s then return nil, code end
    if s.kind ~= 'wardrobe' then return nil, 'SESSION_NOT_FOUND' end
    if s.busy then return nil, 'BUSY' end
    if s.location then
        -- The location as it is now (same gate as the wardrobe commit): once it closes (hours) or
        -- is disabled, the session opened before can no longer write outfits either.
        local loc = WCLocations.byId(s.location.id)
        if not loc or not loc.enabled or not WCLocations.isOpen(loc) then return nil, 'LOCATION_DISABLED' end
        if not withinRange(src, s.location) then return nil, 'TOO_FAR' end
    elseif not (Config.Wardrobe and Config.Wardrobe.allowRemote == true) then
        -- A remote session opened before remote wardrobes were turned off (same as the commit).
        return nil, 'LOCATION_NOT_FOUND'
    end
    return s
end

-- Run fn(session, list) under the character's outfit lock with the current outfit list.
local function run(src, token, fn)
    local s, code = wardrobeSession(src, token)
    if not s then return fail(code) end
    local lockKey = 'outfits:' .. s.charid
    if not WCSecurity.lock(lockKey, LOCK_MS) then return fail('BUSY') end
    local ok, result = pcall(function()
        local list, listCode = Outfits.list(s.charid, s.sex)
        if not list then return fail(listCode or 'DATABASE_ERROR') end
        return fn(s, list)
    end)
    WCSecurity.unlock(lockKey)
    if not ok then
        WCDebug.warn('outfits', 'outfit operation by %s failed: %s', tostring(src), tostring(result))
        return fail('INTERNAL_ERROR')
    end
    return result
end

-- The saved equipped map of the session's character (items worn now count as owned) and its tints.
local function wornOf(s)
    local saved = WCAppearanceRepo.load(s.charid)
    saved = saved or s.snapshot
    local clothing = type(saved) == 'table' and type(saved.clothing) == 'table' and saved.clothing or {}
    return type(clothing.equipped) == 'table' and clothing.equipped or {},
        type(clothing.tints) == 'table' and clothing.tints or {}
end

local function contents(s, equipped, states, tints)
    if not WCSecurity.payload({ equipped = equipped, states = states, tints = tints }, MAX_PAYLOAD) then
        return nil, 'INVALID_PAYLOAD'
    end
    local worn, wornTints = wornOf(s)
    return Outfits.validateData(s.charid, s.sex, equipped, states, worn, nil, tints, wornTints)
end

local function answer(s, id)
    local list, code = Outfits.list(s.charid, s.sex)
    if not list then return fail(code or 'DATABASE_ERROR') end
    return WCResult.ok({ outfit = id and find(list, id) or nil, outfits = list })
end

-- An outfit id exactly as stored (never rounded or clamped onto another outfit).
local function outfitId(id)
    return WCOwnership.exactId(id)
end

local function logSaved(src, s, id, name)
    CreatorLogs.Emit('outfit_saved', { playerSource = tonumber(src), charid = tostring(s.charid),
                                       outfitId = id, name = name })
end

--- Save the current clothes as a new outfit.
function Outfits.save(src, token, name, equipped, states, tints)
    return run(src, token, function(s, list)
        local cleaned = Outfits.validateName(name)
        if not cleaned then return fail('INVALID_OUTFIT_NAME') end
        if #list >= Outfits.max() then return fail('OUTFIT_LIMIT') end
        local data, code, detail = contents(s, equipped, states, tints)
        if not data then return fail(code, detail and { category = detail } or nil) end
        local id, createCode = Outfits.create(s.charid, cleaned, data)
        if not id then return fail(createCode) end
        WCDebug.log('outfits', '%s saved outfit %d', s.charid, id)
        logSaved(src, s, id, cleaned)
        return answer(s, id)
    end)
end

--- Replace an outfit's contents with the current clothes.
function Outfits.updateOutfit(src, token, id, equipped, states, tints)
    return run(src, token, function(s, list)
        id = outfitId(id)
        if not id or not find(list, id) then return fail('OUTFIT_NOT_FOUND') end
        local data, code, detail = contents(s, equipped, states, tints)
        if not data then return fail(code, detail and { category = detail } or nil) end
        local ok, writeCode = Outfits.update(s.charid, id, data)
        if not ok then return fail(writeCode) end
        logSaved(src, s, id, find(list, id).name)
        return answer(s, id)
    end)
end

--- Rename an outfit.
function Outfits.renameOutfit(src, token, id, name)
    return run(src, token, function(s, list)
        id = outfitId(id)
        if not id or not find(list, id) then return fail('OUTFIT_NOT_FOUND') end
        local cleaned = Outfits.validateName(name)
        if not cleaned then return fail('INVALID_OUTFIT_NAME') end
        local ok, writeCode = Outfits.rename(s.charid, id, cleaned)
        if not ok then return fail(writeCode) end
        logSaved(src, s, id, cleaned)
        return answer(s, id)
    end)
end

--- Delete an outfit.
function Outfits.deleteOutfit(src, token, id)
    return run(src, token, function(s, list)
        id = outfitId(id)
        if not id or not find(list, id) then return fail('OUTFIT_NOT_FOUND') end
        local ok, writeCode = Outfits.remove(s.charid, id)
        if not ok then return fail(writeCode) end
        local result = answer(s, nil)
        if result.ok then result.data.outfit = nil end
        return result
    end)
end

w.callback.register('w_creators:outfits:save', function(src, token, name, equipped, states, tints)
    return Outfits.save(src, token, name, equipped, states, tints)
end)

w.callback.register('w_creators:outfits:update', function(src, token, id, equipped, states, tints)
    return Outfits.updateOutfit(src, token, id, equipped, states, tints)
end)

w.callback.register('w_creators:outfits:rename', function(src, token, id, name)
    return Outfits.renameOutfit(src, token, id, name)
end)

w.callback.register('w_creators:outfits:delete', function(src, token, id)
    return Outfits.deleteOutfit(src, token, id)
end)
