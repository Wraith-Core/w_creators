-- =====================================================================
--  server/characters/characters.lua  —  WCCharacters and the character callbacks
--  (ARCHITECTURE.md §9.1, §9.2, §14, §16.1)
--
--  WCCharacters tracks the active character of every player (the one that finished loading through
--  w_creators:characters:loaded). Sessions, the scene guard, the spawn service and every domain read
--  it; nothing trusts a charid sent by a client.
--
--    WCCharacters.active(src)             -> { charid, sex } | nil
--    WCCharacters.setActive(src, charid, sex)
--    WCCharacters.clear(src, reason?)      forgets the remote appearance too
--    WCCharacters.isSwitching(src)         a server-tracked character switch is in progress
--    WCCharacters.beginSwitch(src)         start a server-tracked switch (§9.1 rules) -> ok | false, code
--    WCCharacters.checkSwitches(now?)      lapse the switches held outside the character scene -> count
--    WCCharacters.inFlow(src)              in the character flow (selection / creation / switch)
--    WCCharacters.recover(src)             resolve an untracked logged-in player (restart) -> 'active' | 'flow' | nil, code
--    WCCharacters.slots(src)               character slots of the player (default + ACE permissions)
--    WCCharacters.ownerOf(charid)          the player whose active character this is, or nil
--    WCCharacters.purge(charid, ctx)       w_core's deletion (export PurgeCharacter): rows + memory
--                                          -> true, counts | false, reason
--
--  Callbacks (all answer a WCResult):
--    w_creators:characters:list          -> { characters = [card], slots, canCreate, deletion }
--    w_creators:characters:select        (charid) -> { appearance } | { needsAppearance, token, sex?,
--                                        appearance?, degraded?, repairSections? (degraded: the only
--                                        sections the repair saves; no clothing stage) }
--    w_creators:characters:loaded        -> { spawn = 'selector' | 'direct' | 'event' } (a repeated call
--                                           replays the last answer while its character is active)
--    w_creators:characters:beginCreate   (sex?) -> { token, sex?, locked? }
--    w_creators:characters:create        (token, identity, app) -> { appearance, charid }
--    w_creators:characters:keepAlive     (token) -> {}   renews the grant while the editor is open
--    w_creators:characters:cancelCreate  (token) -> {}
--    w_creators:characters:delete        (charid, confirmText?) -> { charid }
--  Legacy net event: w_creators:server:creationReady (= loaded).
--  Server-local events: w_creators:server:characterCreated (src) before the framework registration;
--  w_creators:server:characterActivated (src, charid, sex); w_creators:server:characterCleared
--  (src, charid, reason = 'switch' | 'dropped' | ...).
-- =====================================================================

WCCharacters = {}
local Chars = WCCharacters

local active = {}    -- [src] = { charid, sex, recoveredUntil? }
-- [src] = { from = charid, at = ms started, seen = ms last seen in the character scene }
local switching = {}
local pending = {}   -- [src] = { charid, sex, app, kind, isNew, token?, selected? } awaiting `loaded`
-- [src] = { entry = the active[src] it made, data }: the last successful `loaded` answer, replayed to a
-- repeated call (a retry after a lost reply) while that activation stands; cleared on drop, clear,
-- select and a new creation.
local lastLoaded = {}
local grants = {}    -- [src] = { token, kind = 'create' | 'repair', expires, sex?, charid?, provisioned?, identity? }
local busy = {}      -- [src] = operation name (one character operation per player at a time)
-- [src] = { [charid] = 'owed' | 'unconfirmed' }: 'owed' = the framework row is gone, the appearance
-- cleanup is still owed; 'unconfirmed' = the framework accepted the deletion but its row was still
-- there after DELETE_CONFIRM_MS (an asynchronous core): the w_creators data is kept until a retry
-- finds the row gone.
local cleanup = {}
-- [charid] = src while that player's characters:delete waits on the framework's deletion; set to
-- 'purged' when w_core purged this resource during it (Chars.purge). The delete then has nothing
-- left to remove and skips its own appearance delete. Always cleared when the framework call ends.
local deleting = {}
-- [src] = ms: a switch of this player lapsed outside the character scene; no new switch starts
-- before then (a lapse is a client that left the flow: repeating it kept him character-less).
local lapsed = {}

-- The sections the degraded repair takes from the creator; the clothing (owned, tinted, with its
-- states and outfit) and the server-owned grooming stay as saved. characters:select hands them to
-- the client (repairSections) so the repair editor offers these sections only — never a clothing
-- stage whose edits the save would drop.
local REPAIR_SECTIONS = { 'body', 'face', 'eyebrows', 'skin', 'eyes', 'hair', 'facialHair', 'makeup' }

local GRANT_TTL_MS = 30 * 60 * 1000
-- A character adopted after a resource restart may re-enter the selection (the restarted client
-- opens it) for this long even with allowSwitch off; afterwards the normal switch rules apply.
local RECOVERY_WINDOW_MS = 2 * 60 * 1000
local DELETE_CONFIRM_MS = 5000
-- w_core's refusal reasons (WCore.Player.DeleteCharacter, second return) -> result codes. w_core
-- now purges everything a deleted character has (money back to the reserve, assets released) and
-- no longer refuses for funds / a loan / assets; those codes stay mapped for an older w_core. A
-- purge a resource refused as 'busy' (a write in flight: w_creators' own PurgeCharacter answers
-- it) is a retry. Any other reason is DATABASE_ERROR.
local DELETE_REFUSALS = {
    economy_not_ready = 'ECONOMY_NOT_READY',
    busy              = 'BUSY',
    funds             = 'DELETE_HOLDS_FUNDS',
    loan              = 'DELETE_HOLDS_LOAN',
    assets            = 'DELETE_HOLDS_ASSETS',
}
local LOGIN_TIMEOUT_MS = 10000
local MAX_CHARID = 64
local MAX_APP_BYTES = 65536
local MAX_IDENTITY_BYTES = 1024
local MAX_CONFIRM = 128
Chars.SWITCH_LAPSE_COOLDOWN_MS = 5 * 60 * 1000
local tokenCounter = 0

local fail, ok = WCResult.fail, WCResult.ok

local function playerId(src)
    src = tonumber(src)
    if not src or src <= 0 or src % 1 ~= 0 then return nil end
    return math.tointeger(src)
end

local function sexOf(value)
    if value == 'male' or value == 'female' then return value end
    return nil
end

--- The charid the framework currently has logged in for the player (string) or nil.
local function frameworkCharid(src)
    local done, charid = pcall(Bridge.GetCharId, src)
    if done and charid ~= nil then return tostring(charid) end
    return nil
end

local function now() return GetGameTimer() end

--- The player's creation grant while it is valid (an expired grant is dropped).
local function grantValid(src)
    local g = grants[src]
    if g and g.expires <= now() then
        grants[src] = nil
        return nil
    end
    return g
end

-- ---------------------------------------------------------------------
--  Active character tracking
-- ---------------------------------------------------------------------

--- The active character of a player: { charid, sex } or nil.
function Chars.active(src)
    local entry = active[playerId(src) or -1]
    if not entry then return nil end
    return { charid = entry.charid, sex = entry.sex }
end

--- Mark a character as the player's active one.
function Chars.setActive(src, charid, sex)
    src = playerId(src)
    if not src or charid == nil then return false end
    active[src] = { charid = tostring(charid), sex = sexOf(sex) }
    switching[src] = nil
    -- A creation / repair grant never outlives the character flow.
    grants[src] = nil
    TriggerEvent('w_creators:server:characterActivated', src, tostring(charid), sexOf(sex))
    return true
end

--- Forget the player's active character (character switch, disconnect) and its remote appearance.
function Chars.clear(src, reason)
    src = playerId(src)
    if not src then return false end
    local entry = active[src]
    active[src] = nil
    lastLoaded[src] = nil
    if entry then
        WCSync.forget(src)
        TriggerEvent('w_creators:server:characterCleared', src, entry.charid, reason or 'clear')
    end
    return entry ~= nil
end

--- Is a server-tracked character switch in progress for this player?
function Chars.isSwitching(src)
    return switching[playerId(src) or -1] ~= nil
end

--- Is the player in the character flow (selection, creation, repair or a switch)? A player with no
--  active character and no framework character is at the selection screen.
function Chars.inFlow(src)
    src = playerId(src)
    if not src then return false end
    if active[src] then return false end
    if switching[src] or pending[src] or grantValid(src) then return true end
    return frameworkCharid(src) == nil
end

--- The player whose active character is `charid`, or nil.
function Chars.ownerOf(charid)
    charid = tostring(charid)
    for src, entry in pairs(active) do
        if entry.charid == charid then return src end
    end
    return nil
end

--- Character slots: max(Config.Characters.defaultSlots, every slotPermissions ACE the player has).
function Chars.slots(src)
    local cfg = Config.Characters or {}
    local slots = WCUtil.int(cfg.defaultSlots, 0, 100, 3)
    for ace, value in pairs(type(cfg.slotPermissions) == 'table' and cfg.slotPermissions or {}) do
        local n = WCUtil.int(value, 0, 100, nil)
        if n and n > slots and type(ace) == 'string' then
            local allowed, granted = pcall(IsPlayerAceAllowed, src, ace)
            if allowed and granted then slots = n end
        end
    end
    return slots
end

-- ---------------------------------------------------------------------
--  Helpers
-- ---------------------------------------------------------------------

local function newToken(src)
    tokenCounter = tokenCounter + 1
    return ('%d-%d-%d-%06d'):format(src, tokenCounter, now(), math.random(0, 999999))
end

local function log(event, payload)
    pcall(CreatorLogs.Emit, event, payload)
end

local function denied(src, operation, charid, reason)
    WCDebug.warn('characters', 'player %s: %s of character %s denied (%s)', tostring(src), operation,
        tostring(charid), reason)
    log('character_access_denied', { playerSource = src, charid = tostring(charid), operation = operation,
                                     reason = reason })
end

--- Run fn under the per-player operation lock; a thrown error becomes INTERNAL_ERROR.
local function guarded(src, name, fn)
    if busy[src] then return fail('BUSY') end
    busy[src] = name
    local done, result = pcall(fn)
    busy[src] = nil
    if not done then
        WCDebug.warn('characters', '%s for %s failed: %s', name, tostring(src), tostring(result))
        return fail('INTERNAL_ERROR')
    end
    return result
end

--- The player dropped while a call yielded (a database read / write, the framework login): the
--  playerDropped handlers already ran and found nothing, so what the call cached for these
--  characters is released here and nothing is written for the player. true when gone.
local function dropped(src, ...)
    if GetPlayerName(src) ~= nil then return false end
    for i = 1, select('#', ...) do
        local charid = select(i, ...)
        if charid ~= nil and not Chars.ownerOf(charid) then WCAppearanceRepo.invalidate(charid) end
    end
    grants[src], pending[src] = nil, nil
    return true
end

--- The player's characters from the framework (array) or nil when the listing failed.
local function ownedCharacters(src)
    local done, list = pcall(Bridge.GetCharacters, src)
    if not done or type(list) ~= 'table' then
        WCDebug.warn('characters', 'listing the characters of %s failed: %s', tostring(src), tostring(list))
        return nil
    end
    return list
end

--- Is the framework row of a character gone? Read by charid alone (the player may have dropped):
--  true only when the query succeeded and found nothing.
local function frameworkRowGone(charid)
    local tables = Config.Characters.tables or {}
    local sql, value
    if Bridge.Name == 'vorp' then
        value = tonumber((tostring(charid):gsub('^vorp:', '')))
        sql = ('SELECT 1 FROM %s WHERE charidentifier = ? LIMIT 1'):format(tables.vorp or 'characters')
    else
        value = tostring(charid)
        sql = ('SELECT 1 FROM %s WHERE citizenid = ? LIMIT 1')
            :format((Bridge.Name == 'rsg' and tables.rsg or tables.qbr) or 'players')
    end
    if value == nil then return false end
    local done, found = pcall(w.database.scalar.await, sql, { value })
    return done and found == nil
end

--- The framework row of a character the player owns: row | nil, code.
local function findOwned(src, charid)
    local list = ownedCharacters(src)
    if not list then return nil, 'DATABASE_ERROR' end
    for _, row in ipairs(list) do
        if type(row) == 'table' and tostring(row.charid) == charid then return row end
    end
    return nil, 'NOT_CHARACTER_OWNER'
end

-- The death system (mirrors the client WCSpawn.DEATH_OWNER): it keeps its own dead / last-stand
-- state while the ped is alive (the hospital bed heal timer, a dead character logging in), so its
-- answer counts as dead too. Its IsDead(src) export answers metadata isdead or inlaststand.
Chars.DEATH_OWNER = { resource = 'w_ambulancejob', export = 'IsDead' }

local function deathOwnerSaysDead(src)
    local owner = Chars.DEATH_OWNER
    if type(owner) ~= 'table' or type(owner.resource) ~= 'string' or type(owner.export) ~= 'string' then
        return false
    end
    local okState, state = pcall(GetResourceState, owner.resource)
    if not okState or state ~= 'started' then return false end
    -- A CitizenFX export proxy member is function(self, ...): the receiver comes first and is
    -- dropped, so the player id must be the second argument (w_lib's convention: nil, ...).
    local done, dead = pcall(function() return exports[owner.resource][owner.export](nil, src) end)
    if not done then
        WCDebug.warn('characters', 'the death state of %s could not be read: %s', tostring(src), tostring(dead))
        return false
    end
    return dead ~= nil and dead ~= false
end

-- The framework's own flags too (the only ones when the death system is not running):
-- metadata.isdead / inlaststand on the RSG family, the character's isdead on VORP.
local function frameworkSaysDead(src)
    local done, char = pcall(function() return exports.w_lib:FwGetCharacter(src) end)
    if not done or type(char) ~= 'table' then return false end
    local flags = type(char.metadata) == 'table' and char.metadata or char
    return flags.isdead == true or flags.isdead == 1 or flags.inlaststand == true or flags.inlaststand == 1
end

-- ⚠️ Never GetEntityHealth(ped) here: on this RedM build the server reads 0 for a LIVING player's
--    ped, so every player counted as dead and every character switch answered BUSY.
local function isDead(src)
    return deathOwnerSaysDead(src) or frameworkSaysDead(src)
end

-- ★ Held by the law: cuffed or serving time (the core's flags, kept by w_policejob on the
--   server). Re-selecting the same character loaded it afresh, which cleared the cuffs, and the spawn
--   selector then placed him anywhere -- a free escape from an arrest.
local function isRestrained(src)
    local done, char = pcall(function() return exports.w_lib:FwGetCharacter(src) end)
    if not done or type(char) ~= 'table' then return false end
    local meta = type(char.metadata) == 'table' and char.metadata or char
    return meta.ishandcuffed == true or (tonumber(meta.injail) or 0) > 0
end

--- Can the player leave his active character now (§9.1)? ok | false, code.
local function canSwitch(src)
    local current = active[src]
    if not current then return true end
    -- A character adopted after a resource restart may be re-selected for a short while (the
    -- restarted client reopens the selection).
    local recovered = current.recoveredUntil ~= nil and current.recoveredUntil > now()
    if Config.Characters.allowSwitch ~= true and not recovered then return false, 'SERVICE_DISABLED' end
    if isDead(src) then return false, 'BUSY' end
    if isRestrained(src) then return false, 'BUSY' end
    if WCSessions.current(src) then return false, 'BUSY' end
    if CreatorAppearanceLocks[current.charid] then return false, 'BUSY' end
    return true
end

--- Enter the character flow: a player with an active character starts a server-tracked switch
--  (his appearance is forgotten remotely and the active character cleared). ok | false, code.
--  A switch already in progress while the framework still has the character being left logged in
--  is checked again (§9.1: never while dead or in a session): the rules hold for every step of the
--  switch, not only its start.
local function ensureSelecting(src)
    local current = active[src]
    if not current then
        local s = switching[src]
        if s and frameworkCharid(src) == s.from then
            if isDead(src) then return false, 'BUSY' end
            if WCSessions.current(src) then return false, 'BUSY' end
        end
        return true
    end
    local allowed, code = canSwitch(src)
    if not allowed then return false, code end
    if lapsed[src] then
        if lapsed[src] > now() then return false, 'BUSY' end
        lapsed[src] = nil
    end
    switching[src] = { from = current.charid, at = now(), seen = now() }
    if WCSpawnServer then WCSpawnServer.cancel(src) end
    Chars.clear(src, 'switch')
    WCDebug.log('characters', 'player %s switches away from %s', tostring(src), current.charid)
    return true
end

-- ---------------------------------------------------------------------
--  A switch belongs to the character scene
-- ---------------------------------------------------------------------
-- A switch is started by the first of scene:prepare, characters:list / select / beginCreate
-- (§9.1), and the legitimate client runs it isolated in the character room until the spawn. A
-- switch the player is not isolated for (never isolated, or released / returned to the world by
-- the scene guard) lapses after Scene.ROOM_GRACE_MS: the character the framework still has logged
-- in becomes active again (the one switched away from, or one selected and never loaded) and its
-- look is broadcast, so no switch is left open in the world — with the active character cleared
-- (the API refusing NO_CHARACTER) and the §9.1 checks skipped by a later select / loaded.

local function switchGraceMs()
    return tonumber(WCScene and WCScene.ROOM_GRACE_MS) or 30000
end

local function inScene(src)
    return type(WCScene) == 'table' and type(WCScene.isIsolated) == 'function' and WCScene.isIsolated(src) == true
end

--- The block staff put on a character (w_core_character_blocks, w_admin's characters page):
--- { reason, blocked_by, blocked_at } or nil. Without w_core nothing is blocked.
local function blockOf(charid)
    if GetResourceState('w_core') ~= 'started' then return nil end
    local done, block = pcall(function() return exports.w_core:GetCharacterBlock(charid) end)
    return done and type(block) == 'table' and block or nil
end

local restoreSwitch

--- A lapsed switch whose logged-in framework character has no usable look (a provisioned creation,
--  a repair never finished): the flow is cancelled and the character switched away from is logged
--  in again (tried once per grace period). true when restored.
local function relogSwitch(src, s)
    local nowMs = now()
    if s.relogAt and nowMs - s.relogAt < switchGraceMs() then return false end
    s.relogAt = nowMs
    if Chars.ownerOf(s.from) then return false end
    local p, g = pending[src], grants[src]
    -- ⚠️ the lock first: blockOf waits on the database, and nothing else may start a flow for this
    --    player while it waits
    busy[src] = 'switchLapsed'
    -- a character staff blocked meanwhile is not logged in again (w_core Login refuses it too)
    if blockOf(s.from) then busy[src] = nil return false end
    local called, loggedIn = pcall(Bridge.LoginCharacter, src, s.from)
    local ready = called and loggedIn ~= false and WCUtil.waitUntil(function()
        return GetPlayerName(src) ~= nil and frameworkCharid(src) == s.from
    end, LOGIN_TIMEOUT_MS, 100)
    busy[src] = nil
    if not ready then
        WCDebug.warn('characters', 'the lapsed switch of %s could not log %s in again: %s', tostring(src), s.from,
            tostring(called and loggedIn or 'timeout'))
        return false
    end
    if switching[src] ~= s or active[src] then return false end
    for _, charid in ipairs({ p and p.charid or false, g and (g.charid or g.provisioned) or false }) do
        if charid and charid ~= s.from and not Chars.ownerOf(charid) then WCAppearanceRepo.invalidate(charid) end
    end
    if pending[src] == p then pending[src] = nil end
    if grants[src] == g then grants[src] = nil end
    return restoreSwitch(src, s)
end

--- End a lapsed switch: the framework character becomes active again. true when restored.
--  Every switch lapses: a character selected, created or repaired but never loaded is finished
--  (active + broadcast, as loaded does, without a spawn); a creation / repair grant still open is
--  cancelled (the character switched away from comes back, logged in again when needed). A lapse
--  is logged as a security_violation and no new switch starts for SWITCH_LAPSE_COOLDOWN_MS.
restoreSwitch = function(src, s)
    if busy[src] or active[src] then return false end
    local fw = frameworkCharid(src)
    local p = pending[src]
    local target, app
    if p and fw ~= nil and fw == p.charid and type(p.app) == 'table' then
        -- a character selected / created / repaired (logged in) but never loaded
        target, app = p.charid, p.app
    elseif fw ~= nil and fw == s.from then
        -- still the character switched away from: an open creation / repair grant is cancelled
        target = s.from
    else
        return relogSwitch(src, s)
    end
    if Chars.ownerOf(target) then return false end
    local done, meta = true, nil
    if not app then
        busy[src] = 'switchLapsed'
        done, app, meta = pcall(WCAppearanceRepo.load, target)
        busy[src] = nil
    end
    -- The load yields: the player may have dropped or moved on.
    if switching[src] ~= s or active[src] or pending[src] ~= p or GetPlayerName(src) == nil
        or frameworkCharid(src) ~= target or Chars.ownerOf(target) then
        return false
    end
    if not done or type(app) ~= 'table' then
        WCDebug.warn('characters', 'the lapsed switch of %s could not restore %s: %s', tostring(src), target,
            tostring(done and (type(meta) == 'table' and meta.error) or app))
        return false
    end
    local g = grants[src]
    if g and (g.charid or g.provisioned) and (g.charid or g.provisioned) ~= target
        and not Chars.ownerOf(g.charid or g.provisioned) then
        WCAppearanceRepo.invalidate(g.charid or g.provisioned)
    end
    pending[src], grants[src] = nil, nil
    Chars.setActive(src, target, app.sex)
    WCSync.broadcast(src, app)
    lapsed[src] = now() + (tonumber(Chars.SWITCH_LAPSE_COOLDOWN_MS) or 0)
    WCSecurity.violation(src, 'character_switch_lapsed', { charid = target, from = s.from,
                                                           pending = p ~= nil and p.charid or nil })
    WCDebug.warn('characters', 'player %s: a switch outside the character scene lapsed - %s is active again',
        tostring(src), target)
    return true
end

--- Settle the player's switch: refreshed while he is isolated in the character scene, restored once
--  it lapsed. true when the switch was ended (a character is active again).
local function settleSwitch(src, nowMs)
    local s = switching[src]
    if not s then return false end
    nowMs = nowMs or now()
    if inScene(src) then
        s.seen = nowMs
        return false
    end
    if nowMs - (s.seen or s.at or nowMs) < switchGraceMs() then return false end
    return restoreSwitch(src, s)
end

--- The periodic pass over the switches in progress. Returns the count restored.
function Chars.checkSwitches(nowMs)
    local list = {}
    for src in pairs(switching) do list[#list + 1] = src end
    local restored = 0
    for _, src in ipairs(list) do
        if GetPlayerName(src) ~= nil and settleSwitch(src, nowMs) then restored = restored + 1 end
    end
    return restored
end

--- Start a server-tracked character switch (the scene guard calls it for scene:prepare).
--  ok | false, code ('SERVICE_DISABLED' | 'BUSY'); true without effect when nothing is active.
function Chars.beginSwitch(src)
    src = playerId(src)
    if not src then return false, 'INVALID_PAYLOAD' end
    if busy[src] then return false, 'BUSY' end
    settleSwitch(src)
    return ensureSelecting(src)
end

-- ---------------------------------------------------------------------
--  Selection card data
-- ---------------------------------------------------------------------

local function sexFromFramework(value)
    if value == 0 or value == '0' then return 'male' end
    if value == 1 or value == '1' then return 'female' end
    if type(value) ~= 'string' then return nil end
    local first = value:sub(1, 1):lower()
    if first == 'm' then return 'male' end
    if first == 'f' then return 'female' end
    return nil
end

local function validDob(value)
    if type(value) ~= 'string' then return nil end
    local y, m, d = value:match('^(%d%d%d%d)%-(%d%d)%-(%d%d)')
    if not y then return nil end
    return ('%s-%s-%s'):format(y, m, d), tonumber(y), tonumber(m), tonumber(d)
end

local function ageFromDob(dob)
    local _, y, m, d = validDob(dob)
    if not y then return nil end
    local ref = Config.Characters.identity and tonumber(Config.Characters.identity.referenceYear)
    if ref then return ref - y end
    local t = os.date('*t')
    local age = t.year - y
    if t.month < m or (t.month == m and t.day < d) then age = age - 1 end
    return age
end

local function nameText(v)
    if type(v) ~= 'string' then return nil end
    v = WCUtil.clampString(WCUtil.trim(v), 40)
    return v ~= '' and v or nil
end

--- The framework rows keyed by charid: { firstname, lastname, dob, age, sex, coords }.
--  VORP: characters (identifier); rsg / qbr: players.charinfo + players.position (JSON).
local function frameworkDetails(src)
    local out = {}
    local okLicense, license = pcall(Bridge.GetLicense, src)
    if not okLicense or not license then return out end
    local tables = Config.Characters.tables or {}
    if Bridge.Name == 'vorp' then
        local done, rows = pcall(w.database.query.await,
            ('SELECT charidentifier, firstname, lastname, age, gender, coords FROM %s WHERE identifier = ?')
                :format(tables.vorp or 'characters'), { license })
        if not done or type(rows) ~= 'table' then return out end
        for _, r in ipairs(rows) do
            out['vorp:' .. tostring(r.charidentifier)] = {
                firstname = nameText(r.firstname), lastname = nameText(r.lastname),
                age = WCUtil.int(r.age, 0, 200, nil), sex = sexFromFramework(r.gender),
                coords = WCUtil.decode(r.coords),
            }
        end
    else
        local tableName = Bridge.Name == 'rsg' and tables.rsg or tables.qbr
        local done, rows = pcall(w.database.query.await,
            ('SELECT citizenid, charinfo, position FROM %s WHERE license = ?'):format(tableName or 'players'),
            { license })
        if not done or type(rows) ~= 'table' then return out end
        for _, r in ipairs(rows) do
            local info = WCUtil.decode(r.charinfo)
            local dob = validDob(info.birthdate)
            out[tostring(r.citizenid)] = {
                firstname = nameText(info.firstname), lastname = nameText(info.lastname),
                dob = dob, age = ageFromDob(dob), sex = sexFromFramework(info.gender),
                coords = WCUtil.decode(r.position),
            }
        end
    end
    return out
end

--- The characters_appearence row of a character (name/age/isMale fallback), or {}.
local function appearanceRow(charid)
    local done, row = pcall(w.database.single.await,
        'SELECT name, age, isMale FROM characters_appearence WHERE charid = ? ORDER BY id DESC LIMIT 1', { charid })
    if done and type(row) == 'table' then return row end
    return {}
end

local function lastLocationLabel(coords)
    if type(coords) ~= 'table' or not WCSpawnServer then return nil end
    local pos = WCSpawnServer.validateLast(coords)
    return pos and WCSpawnServer.nearestLabel(pos) or nil
end

--- The selection card of a character. The appearance is read without caching (the repository
--  cache holds the characters in play, not every listed one), and its row supplies the stored
--  name / age / isMale, so a card costs one read of characters_appearence.
local function buildCard(row, fw, withAppearance)
    local charid = tostring(row.charid)
    fw = fw or {}
    local app, stored
    if withAppearance then
        local done, loaded, meta = pcall(WCAppearanceRepo.load, charid, { cache = false })
        if done then
            app = loaded
            if type(meta) == 'table' then stored = meta.row or (meta.missing and {} or nil) end
        end
    end
    stored = stored or appearanceRow(charid)
    local storedFirst, storedLast
    if type(stored.name) == 'string' then storedFirst, storedLast = stored.name:match('^(%S+)%s*(.-)$') end
    -- rsg / qbr list a character without charinfo under its citizenid: not a name
    local rowName = type(row.name) == 'string' and row.name ~= charid and row.name or nil
    local rowFirst, rowLast
    if rowName then rowFirst, rowLast = rowName:match('^(%S+)%s*(.-)$') end
    local firstname = fw.firstname or nameText(rowFirst) or nameText(storedFirst)
    local lastname = fw.lastname or nameText(rowLast) or nameText(storedLast)
    if lastname == '.' then lastname = nil end -- VORP's placeholder for an empty surname
    local name = WCUtil.trim(('%s %s'):format(firstname or '', lastname or ''))
    if name == '' then name = nameText(rowName) or nameText(stored.name) or charid end
    local sex = fw.sex or (app and app.sex)
    if not sex and stored.isMale ~= nil then sex = AppearanceSchema.sexOf(stored.isMale) end
    return {
        charid = charid,
        name = name,
        firstname = firstname,
        lastname = lastname,
        dob = fw.dob,
        age = fw.age or WCUtil.int(stored.age, 0, 200, nil),
        sex = sex,
        lastLocation = lastLocationLabel(fw.coords),
        job = row.job,
        cash = tonumber(row.cash),
        bank = tonumber(row.bank),
        gold = tonumber(row.gold),
        appearance = app,
        -- the citizen id is shown on the card; a character staff blocked says so (and why)
        citizenId = charid,
        blocked = (function() local b = blockOf(charid) return b and (b.reason ~= '' and b.reason or true) or nil end)(),
    }
end

local function normalizedName(s)
    if type(s) ~= 'string' then return nil end
    return WCUtil.trim(s):gsub('%s+', ' '):lower()
end

-- ---------------------------------------------------------------------
--  Starting clothing (Config.Creator.startingClothing)
-- ---------------------------------------------------------------------

local function categoryAllowed(sex, category)
    local cfg = Config.Creator.startingClothing or {}
    if not WCCatalog.offered(sex, category) then return false end
    local categories = cfg.categories
    if categories == nil or categories == '*' then return true end
    if type(categories) ~= 'table' then return false end
    return WCUtil.set(categories)[category] == true
end

local function presetEquipped(sex, preset)
    local equipped = {}
    for _, item in ipairs(type(preset.items) == 'table' and preset.items or {}) do
        if type(item) == 'table' and WCCatalog.isClothing(item.category) then
            local hash = WCCatalog.presetHash(sex, item)
            if hash then equipped[item.category] = hash end
        end
    end
    return (WCRules.normalize(equipped))
end

--- Restrict a sanitized creator appearance to the starting clothing. app | nil, code.
local function restrictClothing(app, sex)
    local cfg = Config.Creator.startingClothing or {}
    local clothing = app.clothing
    clothing.outfit = nil
    if cfg.mode == 'presets' then
        local presets = Config.StartingOutfits and Config.StartingOutfits[sex] or {}
        if type(presets) ~= 'table' or #presets == 0 then
            clothing.equipped, clothing.tints = {}, {}
        else
            local matched
            for _, preset in ipairs(presets) do
                local equipped = type(preset) == 'table' and presetEquipped(sex, preset)
                if equipped and WCUtil.deepEqual(equipped, clothing.equipped) then matched = equipped break end
            end
            if not matched then return nil, 'INVALID_COMPONENT' end
            clothing.equipped, clothing.tints = matched, {}
        end
    else
        local kept = {}
        for category, hash in pairs(clothing.equipped) do
            if categoryAllowed(sex, category) then kept[category] = hash end
        end
        clothing.equipped = (WCRules.normalize(kept))
    end
    for category in pairs(clothing.tints) do
        if not clothing.equipped[category] then clothing.tints[category] = nil end
    end
    local statesOn = WCClothingStates.enabled()
    for group, _ in pairs(clothing.states) do
        -- the clothing actions off: a creation never starts with a state the player cannot undo
        if not statesOn or not WCClothingStates.applicable(app, group, true) then clothing.states[group] = nil end
    end
    return app
end

--- Validate a creator appearance for a sex. app | nil, code.
local function prepareAppearance(raw, sex)
    if type(raw) ~= 'table' then return nil, 'INVALID_PAYLOAD' end
    local app = AppearanceSchema.sanitize(raw, { sex = sex, grooming = false })
    return restrictClothing(app, sex)
end

--- The starter ownership items of an appearance (WCOwnership.grantQueries item shape):
--  { hash, category, tint = { palette, tint0, tint1, tint2 } | nil } per equipped clothing item.
local function starterItems(app)
    local items = {}
    for _, category in ipairs(WCUtil.sortedKeys(app.clothing.equipped)) do
        local tint = app.clothing.tints[category]
        items[#items + 1] = { hash = app.clothing.equipped[category], category = category,
                              tint = tint and WCUtil.copy(tint) or nil }
    end
    return items
end

local function starterQueries(charid, app)
    local items = starterItems(app)
    if #items == 0 then return {} end
    return WCOwnership.grantQueries(charid, items, 'starter')
end

-- ---------------------------------------------------------------------
--  Callbacks
-- ---------------------------------------------------------------------

--- w_creators:characters:list
function Chars.list(src)
    src = playerId(src)
    if not src then return fail('INVALID_PAYLOAD') end
    if not WCSecurity.rate(src, 'characters:list', 5, 10000) then return fail('RATE_LIMITED') end
    settleSwitch(src)
    local allowed, code = ensureSelecting(src)
    if not allowed then return fail(code) end

    local list = ownedCharacters(src)
    if not list then return fail('DATABASE_ERROR') end
    local details = frameworkDetails(src)
    local cards = {}
    for _, row in ipairs(list) do
        if type(row) == 'table' and row.charid ~= nil then
            cards[#cards + 1] = buildCard(row, details[tostring(row.charid)], true)
        end
    end
    local slots = Chars.slots(src)
    local deletion = Config.Characters.deletion or {}
    return ok({
        characters = cards,
        slots = slots,
        canCreate = WCServices.enabled('characterCreation') and #cards < slots,
        deletion = {
            enabled = WCServices.enabled('characterDeletion'),
            holdTime = WCUtil.int(deletion.holdTime, 0, 60000, 5000),
            typed = deletion.typedConfirmation == true,
        },
    })
end

--- w_creators:characters:select
function Chars.select(src, charid)
    src = playerId(src)
    if not src then return fail('INVALID_PAYLOAD') end
    if not WCSecurity.rate(src, 'characters:select', 5, 10000) then return fail('RATE_LIMITED') end
    if type(charid) ~= 'string' or #charid == 0 or #charid > MAX_CHARID then return fail('INVALID_PAYLOAD') end
    if busy[src] then return fail('BUSY') end
    settleSwitch(src)

    -- A repeated select of the character already logged in answers the same result (no second login).
    local p = pending[src]
    if p and p.selected and p.charid == charid and frameworkCharid(src) == charid then
        return ok({ appearance = WCUtil.copy(p.app) })
    end

    local allowed, code = ensureSelecting(src)
    if not allowed then return fail(code) end

    return guarded(src, 'select', function()
        local row, ownCode = findOwned(src, charid)
        if not row then
            if ownCode == 'NOT_CHARACTER_OWNER' then
                denied(src, 'select', charid, 'اختيار شخصية لا يملكها اللاعب')
            end
            return fail(ownCode)
        end
        -- ★ a blocked character is not played: "contact the administration"; the account's
        --   other characters stay selectable (w_core Login refuses it as well)
        local block = blockOf(charid)
        if block then return fail('CHARACTER_BLOCKED', { reason = block.reason }) end
        if Chars.ownerOf(charid) then return fail('BUSY') end

        grants[src], lastLoaded[src] = nil, nil
        -- another character selected before this one was loaded: its cached look is not in play
        local previous = pending[src]
        if previous and previous.charid ~= charid and not Chars.ownerOf(previous.charid) then
            WCAppearanceRepo.invalidate(previous.charid)
        end
        pending[src] = nil
        -- The character the framework already has logged in (re-selected after a switch) is never
        -- logged out and in again: a reload reads the players row as last saved (§9.1).
        if frameworkCharid(src) ~= charid then
            local called, loggedIn = pcall(Bridge.LoginCharacter, src, charid)
            if not called or loggedIn == false then
                WCDebug.warn('characters', 'login of %s for %s failed: %s', charid, tostring(src), tostring(loggedIn))
                return fail('INTERNAL_ERROR')
            end
            local ready = WCUtil.waitUntil(function()
                return GetPlayerName(src) ~= nil and frameworkCharid(src) == charid
            end, LOGIN_TIMEOUT_MS, 100)
            if not ready then
                WCDebug.warn('characters', 'the framework did not log %s into %s in time', tostring(src), charid)
                return fail('INTERNAL_ERROR')
            end
        end

        local app, meta = WCAppearanceRepo.load(charid)
        if dropped(src, charid) then return fail('NO_CHARACTER') end
        meta = type(meta) == 'table' and meta or {}
        local kind = switching[src] and 'switch' or 'login'
        log('character_selected', { playerSource = src, charid = charid, appearanceFound = app ~= nil,
                                    framework = Bridge.Name, reason = 'اختيار من شاشة الشخصيات' })
        if not app then
            if not meta.missing then return fail(meta.error or 'DATABASE_ERROR') end
            -- No saved look (a creation whose save failed): the creator in appearance-only mode.
            local details = frameworkDetails(src)[charid] or {}
            local token = newToken(src)
            grants[src] = { token = token, kind = 'repair', charid = charid, sex = details.sex,
                            expires = now() + GRANT_TTL_MS }
            return ok({ needsAppearance = true, token = token, sex = details.sex })
        end
        if meta.degraded then
            -- The stored look needed essential defaults (a part missing or unknown to the catalogue):
            -- no writer may persist them, so the character is repaired explicitly — the creator in
            -- appearance-only mode, starting from the defaults-filled look; its clothing is kept.
            local token = newToken(src)
            grants[src] = { token = token, kind = 'repair', charid = charid, sex = app.sex, degraded = true,
                            expires = now() + GRANT_TTL_MS }
            return ok({ needsAppearance = true, token = token, sex = app.sex, appearance = WCUtil.copy(app),
                        degraded = WCUtil.copy(meta.defaultsUsed), repairSections = WCUtil.copy(REPAIR_SECTIONS) })
        end
        pending[src] = { charid = charid, sex = app.sex, app = app, kind = kind, isNew = false, selected = true }
        return ok({ appearance = WCUtil.copy(app) })
    end)
end

--- w_creators:characters:loaded
function Chars.loaded(src)
    src = playerId(src)
    if not src then return fail('INVALID_PAYLOAD') end
    if not WCSecurity.rate(src, 'characters:loaded', 5, 10000) then return fail('RATE_LIMITED') end
    -- a lapsed switch (outside the character scene) ends here: no spawn grant is given for it
    settleSwitch(src)
    local p = pending[src]
    if not p then
        -- A repeated call after a successful one (its reply was lost) answers the same, while the
        -- character it activated is still the active one; nothing runs twice (no second spawn).
        local last = lastLoaded[src]
        if last and active[src] == last.entry then return ok(WCUtil.copy(last.data)) end
        return fail('NO_CHARACTER')
    end

    return guarded(src, 'loaded', function()
        if pending[src] ~= p then return fail('NO_CHARACTER') end
        pending[src] = nil
        local ready = WCUtil.waitUntil(function()
            return GetPlayerName(src) ~= nil and frameworkCharid(src) == p.charid
        end, LOGIN_TIMEOUT_MS, 100)
        if not ready then return fail('NO_CHARACTER') end
        Chars.setActive(src, p.charid, p.sex)
        WCSync.broadcast(src, p.app)
        local mode = WCSpawnServer.finish(src, p.kind, p.isNew)
        lastLoaded[src] = { entry = active[src], data = { spawn = mode } }
        return ok({ spawn = mode })
    end)
end

--- w_creators:characters:beginCreate
function Chars.beginCreate(src, sex)
    src = playerId(src)
    if not src then return fail('INVALID_PAYLOAD') end
    if not WCSecurity.rate(src, 'characters:beginCreate', 5, 10000) then return fail('RATE_LIMITED') end
    if not WCServices.enabled('characterCreation') then return fail('CREATION_DISABLED') end
    if sex ~= nil and not sexOf(sex) then return fail('INVALID_PAYLOAD') end
    if busy[src] then return fail('BUSY') end
    settleSwitch(src)

    -- A creation that already completed (its answer or its render was lost on the client) is never
    -- started over: the same token replays the stored create result, so no second framework
    -- character is registered and the first one is not orphaned.
    local done = pending[src]
    -- locked = true: that sex can no longer change, so the creator offers only it (the gender
    -- scene refuses the other one at once instead of after a whole design was built for it)
    if done and done.isNew and done.token then return ok({ token = done.token, sex = done.sex, locked = true }) end

    local g = grantValid(src)
    if g and g.kind == 'create' then
        -- The sex is locked once the framework character exists (a half-finished creation): the
        -- answer carries the server's sex and says it is locked; before that it only records the
        -- sex of the design about to be saved.
        if sex and not g.provisioned then g.sex = sex end
        return ok({ token = g.token, sex = g.sex, locked = (g.provisioned ~= nil and g.sex ~= nil) or nil })
    end
    local allowed, code = ensureSelecting(src)
    if not allowed then return fail(code) end

    -- Under the per-player lock: no select / loaded can complete while the slot count is read.
    return guarded(src, 'beginCreate', function()
        local list = ownedCharacters(src)
        if not list then return fail('DATABASE_ERROR') end
        if active[src] then return fail('BUSY') end
        if #list >= Chars.slots(src) then return fail('CHARACTER_SLOT_LIMIT') end
        local token = newToken(src)
        grants[src] = { token = token, kind = 'create', sex = sex, expires = now() + GRANT_TTL_MS }
        pending[src], lastLoaded[src] = nil, nil
        return ok({ token = token, sex = sex })
    end)
end

local function createNew(src, g, identity, raw)
    if not WCServices.enabled('characterCreation') then return fail('CREATION_DISABLED') end
    if type(identity) ~= 'table' or not WCSecurity.payload(identity, MAX_IDENTITY_BYTES) then
        return fail('INVALID_PAYLOAD')
    end
    local valid, ident = WCIdentity.validate(identity)
    if not valid then return fail(ident) end
    local sex = g.sex or sexOf(raw.sex)
    if not sex then return fail('INVALID_PAYLOAD') end
    -- A design for the other sex after the framework character exists would be force-sanitised
    -- into a default look of the locked sex: refused instead of saved silently.
    if g.provisioned and raw.sex ~= nil and sexOf(raw.sex) ~= sex then return fail('INVALID_PAYLOAD') end
    local app, code = prepareAppearance(raw, sex)
    if not app then return fail(code) end

    local charid
    if g.provisioned and frameworkCharid(src) == g.provisioned then
        -- Retry: the framework character exists already (the appearance write failed before).
        charid = g.provisioned
        ident = g.identity or ident
    else
        local list = ownedCharacters(src)
        if not list then return fail('DATABASE_ERROR') end
        if #list >= Chars.slots(src) then return fail('CHARACTER_SLOT_LIMIT') end
        -- w_lib's w_core bridge listens for this before the framework login of the new character.
        TriggerEvent('w_creators:server:characterCreated', src)
        local called, registered = pcall(Bridge.RegisterCharacter, src, {
            firstname = ident.firstname, lastname = ident.lastname, dob = ident.dob, age = ident.age,
            isMale = sex == 'male',
        })
        if not called or registered == nil or registered == false then
            WCDebug.warn('characters', 'registering a character for %s failed: %s', tostring(src), tostring(registered))
            log('character_create_failed', { playerSource = src, stage = 'register', framework = Bridge.Name,
                                            detail = called and 'no charid' or tostring(registered) })
            return fail('INTERNAL_ERROR')
        end
        charid = tostring(registered)
        -- A registration that answers a character the player already had (a framework that handed
        -- back an existing row) is never bound to this creation: its look and ownership stay his.
        for _, row in ipairs(list) do
            if type(row) == 'table' and tostring(row.charid) == charid then
                WCDebug.warn('characters', 'registering a character for %s answered the existing %s: refused',
                    tostring(src), charid)
                log('character_create_failed', { playerSource = src, charid = charid, stage = 'register_existing',
                                                framework = Bridge.Name, detail = 'existing charid' })
                return fail('INTERNAL_ERROR')
            end
        end
        g.provisioned, g.identity, g.sex = charid, ident, sex
        if dropped(src) then return fail('NO_CHARACTER') end
    end

    local saved, result = WCAppearanceRepo.create(charid, ident, app, starterQueries(charid, app))
    if dropped(src, charid) then return fail('NO_CHARACTER') end
    if not saved then
        log('character_create_failed', { playerSource = src, charid = charid, stage = 'appearance',
                                        framework = Bridge.Name, detail = tostring(result) })
        return fail(result or 'DATABASE_ERROR')
    end
    grants[src] = nil
    pending[src] = { charid = charid, sex = sex, app = result, kind = 'initial', isNew = true, token = g.token }
    log('character_created', { playerSource = src, charid = charid,
                               name = ('%s %s'):format(ident.firstname, ident.lastname),
                               isMale = sex == 'male', age = ident.age, framework = Bridge.Name,
                               multichar = true, reason = 'اكتمل المنشئ' })
    return ok({ appearance = WCUtil.copy(result), charid = charid })
end


--- The explicit repair of a degraded character (its stored look needed essential defaults): the
--  creator's look replaces the defaults-filled one (Repo.save with replaceDegraded).
local function repairDegraded(src, g, charid, existing, raw, kind)
    local sex = existing.sex
    if raw.sex ~= nil and sexOf(raw.sex) ~= sex then return fail('INVALID_PAYLOAD') end
    local merged = AppearanceSchema.mergeSections(existing, raw, REPAIR_SECTIONS)
    if merged.hair.style ~= existing.hair.style or merged.hair.facial ~= existing.hair.facial then
        WCGrooming.cut(merged, existing)
    end
    local saved, result = WCAppearanceRepo.save(charid, merged, nil, { replaceDegraded = true })
    if dropped(src, charid) then return fail('NO_CHARACTER') end
    if not saved then
        log('character_create_failed', { playerSource = src, charid = charid, stage = 'repair',
                                        framework = Bridge.Name, detail = tostring(result) })
        return fail(result or 'DATABASE_ERROR')
    end
    grants[src] = nil
    pending[src] = { charid = charid, sex = sex, app = result, kind = kind, isNew = false, token = g.token }
    log('appearance_changed', { playerSource = src, charid = charid, sections = REPAIR_SECTIONS, kind = 'repair' })
    return ok({ appearance = WCUtil.copy(result), charid = charid })
end

local function createRepair(src, g, raw)
    local charid = g.charid
    if frameworkCharid(src) ~= charid then return fail('NO_CHARACTER') end
    local row, ownCode = findOwned(src, charid)
    if not row then
        if ownCode == 'NOT_CHARACTER_OWNER' then denied(src, 'repair', charid, 'إصلاح مظهر شخصية لا يملكها اللاعب') end
        return fail(ownCode)
    end
    local kind = switching[src] and 'switch' or 'login'
    local existing, meta = WCAppearanceRepo.load(charid)
    if dropped(src, charid) then return fail('NO_CHARACTER') end
    if existing and type(meta) == 'table' and meta.degraded then
        return repairDegraded(src, g, charid, existing, raw, kind)
    end
    if existing then
        grants[src] = nil
        pending[src] = { charid = charid, sex = existing.sex, app = existing, kind = kind, isNew = false,
                         token = g.token }
        return ok({ appearance = WCUtil.copy(existing), charid = charid })
    end
    if type(meta) == 'table' and not meta.missing then return fail(meta.error or 'DATABASE_ERROR') end

    local sex = g.sex or sexOf(raw.sex)
    if not sex then return fail('INVALID_PAYLOAD') end
    local app, code = prepareAppearance(raw, sex)
    if not app then return fail(code) end
    local card = buildCard(row, frameworkDetails(src)[charid], false)
    if dropped(src, charid) then return fail('NO_CHARACTER') end
    local ident = { firstname = card.firstname or card.name, lastname = card.lastname, age = card.age }
    local saved, result = WCAppearanceRepo.create(charid, ident, app, starterQueries(charid, app))
    if dropped(src, charid) then return fail('NO_CHARACTER') end
    if not saved then
        log('character_create_failed', { playerSource = src, charid = charid, stage = 'repair',
                                        framework = Bridge.Name, detail = tostring(result) })
        return fail(result or 'DATABASE_ERROR')
    end
    grants[src] = nil
    pending[src] = { charid = charid, sex = sex, app = result, kind = kind, isNew = false, token = g.token }
    log('character_created', { playerSource = src, charid = charid, isMale = sex == 'male', framework = Bridge.Name,
                               reason = 'إصلاح مظهر شخصية بلا مظهر محفوظ' })
    return ok({ appearance = WCUtil.copy(result), charid = charid })
end

--- w_creators:characters:create
function Chars.create(src, token, identity, raw)
    src = playerId(src)
    if not src then return fail('INVALID_PAYLOAD') end
    if not WCSecurity.rate(src, 'characters:create', 5, 10000) then return fail('RATE_LIMITED') end
    if type(token) ~= 'string' or #token > 64 then return fail('CREATION_NOT_GRANTED') end
    if busy[src] then return fail('BUSY') end
    -- Creation belongs to the character flow: never while a character is in play.
    if active[src] then
        grants[src] = nil
        return fail('CREATION_NOT_GRANTED')
    end

    -- A repeated request for a creation that already completed answers the same result.
    local p = pending[src]
    if p and p.token == token then return ok({ appearance = WCUtil.copy(p.app), charid = p.charid }) end

    local held = grants[src]
    local g = grantValid(src)
    if not g or g.token ~= token then
        -- ⚠️ All three of these produced one indistinguishable message. Name the cause: an EXPIRED
        --    grant means the player worked longer than GRANT_TTL_MS and the heartbeat never arrived.
        local why = (not held and 'no grant on record')
            or (held ~= g and 'the grant expired')
            or 'the token does not match the grant'
        WCDebug.warn('characters', 'player %s: create refused — %s', tostring(src), why)
        return fail('CREATION_NOT_GRANTED')
    end
    if type(raw) ~= 'table' or not WCSecurity.payload(raw, MAX_APP_BYTES) then return fail('INVALID_PAYLOAD') end

    return guarded(src, 'create', function()
        if grants[src] ~= g or active[src] then return fail('CREATION_NOT_GRANTED') end
        if g.kind == 'repair' then return createRepair(src, g, raw) end
        return createNew(src, g, identity, raw)
    end)
end

--- w_creators:characters:keepAlive — renew the creation grant while the creator is really open.
--  ⚠️ GRANT_TTL_MS is 30 minutes and the grant was issued once and NEVER renewed, while the editor
--     makes no server call at all between beginCreate and create. A player who spent longer than
--     that building a character had the save refused with CREATION_NOT_GRANTED and lost every bit of
--     the work. The TTL still does its job (a grant dies with an idle or vanished client); it just no
--     longer punishes someone who is actively working.
---@return table Result
function Chars.keepAlive(src, token)
    src = playerId(src)
    if not src then return fail('INVALID_PAYLOAD') end
    -- one renewal per 10 s is plenty for the client's 60 s heartbeat
    if not WCSecurity.rate(src, 'characters:keepAlive', 3, 10000) then return fail('RATE_LIMITED') end
    if type(token) ~= 'string' or #token > 64 then return fail('CREATION_NOT_GRANTED') end
    if active[src] then return fail('CREATION_NOT_GRANTED') end
    local g = grantValid(src)
    if not g or g.token ~= token then return fail('CREATION_NOT_GRANTED') end
    g.expires = now() + GRANT_TTL_MS
    return ok({ expires = GRANT_TTL_MS })
end

--- w_creators:characters:cancelCreate
function Chars.cancelCreate(src, token)
    src = playerId(src)
    if not src then return fail('INVALID_PAYLOAD') end
    if not WCSecurity.rate(src, 'characters:cancelCreate', 10, 10000) then return fail('RATE_LIMITED') end
    local g = grants[src]
    if g and g.token == token and not busy[src] then grants[src] = nil end
    return ok({})
end

--- w_creators:characters:delete
function Chars.delete(src, charid, confirmText)
    src = playerId(src)
    if not src then return fail('INVALID_PAYLOAD') end
    if not WCSecurity.rate(src, 'characters:delete', 3, 10000) then return fail('RATE_LIMITED') end
    if not WCServices.enabled('characterDeletion') then return fail('DELETE_DISABLED') end
    if type(charid) ~= 'string' or #charid == 0 or #charid > MAX_CHARID then return fail('INVALID_PAYLOAD') end
    if confirmText ~= nil and (type(confirmText) ~= 'string' or #confirmText > MAX_CONFIRM) then
        return fail('INVALID_PAYLOAD')
    end
    -- Only from the selection screen, never the character in play, one being loaded, the one the
    -- framework still has logged in (after a switch, a repair grant or a provisioned creation) or
    -- the one being switched away from.
    if active[src] or (pending[src] and pending[src].charid == charid) or Chars.ownerOf(charid)
        or (switching[src] and switching[src].from == charid) or frameworkCharid(src) == charid then
        return fail('BUSY')
    end

    return guarded(src, 'delete', function()
        -- A previous deletion removed (or had the framework accept removing) the framework row but
        -- not the appearance data: once the row is gone the retry only finishes that cleanup (no
        -- ownership check can succeed then); a row still present is deleted again below.
        local owedState = cleanup[src] and cleanup[src][charid]
        if owedState then
            local rowGone = owedState == 'owed'
            if not rowGone then
                local _, code = findOwned(src, charid)
                if code == 'DATABASE_ERROR' then return fail('DATABASE_ERROR') end
                rowGone = code == 'NOT_CHARACTER_OWNER'
            end
            if rowGone then
                local removed, repoDone = pcall(WCAppearanceRepo.delete, charid)
                if not removed or repoDone ~= true then
                    WCDebug.warn('characters', 'deleting the appearance data of %s failed again: %s', charid, tostring(repoDone))
                    cleanup[src][charid] = 'owed'
                    return fail('DATABASE_ERROR')
                end
            end
            cleanup[src][charid] = nil
            if next(cleanup[src]) == nil then cleanup[src] = nil end
            if rowGone then return ok({ charid = charid }) end
        end
        local row, ownCode = findOwned(src, charid)
        if not row then
            if ownCode == 'NOT_CHARACTER_OWNER' then
                denied(src, 'delete', charid, 'حذف شخصية لا يملكها اللاعب')
            end
            return fail(ownCode)
        end
        local deletion = Config.Characters.deletion or {}
        if deletion.typedConfirmation == true then
            local card = buildCard(row, frameworkDetails(src)[charid], false)
            local expected = normalizedName(card.name)
            if not expected or normalizedName(confirmText) ~= expected then
                return fail('DELETE_CONFIRMATION_REQUIRED')
            end
        end
        -- The framework row first, alone: the appearance, owned clothes and outfits are deleted
        -- (one transaction in WCAppearanceRepo.delete) only once the framework row is really gone,
        -- so a refused, failed or rolled-back framework deletion leaves the character intact.
        -- w_core purges every resource during its deletion, this one included (PurgeCharacter:
        -- Chars.purge, which never waits on this player's `busy` lock): the delete below then finds
        -- nothing and succeeds (it stays for the other cores and as the safety net).
        -- The framework's own reason, when it gives one, is the player's message: an older w_core
        -- refuses a character that still holds money, a loan or property for that, not for "the
        -- database".
        deleting[charid] = src
        local called, accepted, reason = pcall(Bridge.DeleteFrameworkCharacter, src, charid)
        local purgedMeanwhile = deleting[charid] == 'purged'
        deleting[charid] = nil
        if not called or accepted ~= true then
            local code = called and DELETE_REFUSALS[reason] or 'DATABASE_ERROR'
            WCDebug.warn('characters', 'deleting %s: the framework refused or failed: %s', charid,
                tostring(called and (reason or accepted) or accepted))
            return fail(code)
        end
        -- rsg / qbr delete asynchronously: the framework row must really be gone.
        local gone = WCUtil.waitUntil(function()
            local _, code = findOwned(src, charid)
            return code == 'NOT_CHARACTER_OWNER'
        end, DELETE_CONFIRM_MS, 250)
        if not gone then
            WCDebug.warn('characters', 'the framework row of %s is still present after the deletion', charid)
            -- nothing of w_creators is owed once w_core purged it: a retry deletes the row again
            if not purgedMeanwhile then
                cleanup[src] = cleanup[src] or {}
                cleanup[src][charid] = 'unconfirmed'
            end
            return fail('DATABASE_ERROR')
        end
        local g = grants[src]
        if g and (g.charid == charid or g.provisioned == charid) then grants[src] = nil end
        -- w_core purged this resource during its deletion: nothing is left to delete, and no
        -- cleanup is recorded that could later run against the number once it is reassigned.
        if purgedMeanwhile then return ok({ charid = charid }) end
        local removed, repoDone = pcall(WCAppearanceRepo.delete, charid)
        if not removed or repoDone ~= true then
            WCDebug.warn('characters', 'deleting the appearance data of %s failed: %s', charid, tostring(repoDone))
            cleanup[src] = cleanup[src] or {}
            cleanup[src][charid] = 'owed'
            return fail('DATABASE_ERROR')
        end
        return ok({ charid = charid })
    end)
end

-- ---------------------------------------------------------------------
--  Purge (w_core's character deletion: exports.w_creators:PurgeCharacter)
-- ---------------------------------------------------------------------
-- A deleted character's number can be handed to another character later (a vanity id that was
-- not renewed), so nothing of it may stay: not its rows, and not a reference in memory that would
-- attach its look, its pending flow or a re-login to whoever gets the number next.

-- How long a purge waits for the writers of the character (a save in flight, the grooming write
-- of a player w_core just kicked, an outfit write) before it refuses and changes nothing.
Chars.PURGE_LOCK_WAIT_MS = 10000
local PURGE_OUTFIT_LOCK_MS = 60000
local purgeCounter = 0

-- The id a purge is asked for: a non-empty string of at most MAX_CHARID characters without
-- whitespace or control characters (an integer is accepted as its digits), or nil.
local function purgeId(citizenid)
    if math.type(citizenid) == 'integer' then citizenid = tostring(citizenid) end
    if type(citizenid) ~= 'string' or #citizenid == 0 or #citizenid > MAX_CHARID then return nil end
    if citizenid:find('[%s%c]') then return nil end
    return citizenid
end

-- Is `src` connected with the framework having `charid` logged in?
local function loggedInOn(src, charid)
    return GetPlayerName(src) ~= nil and frameworkCharid(src) == charid
end

-- The connected player who holds the character right now (in play, or in the flow with it logged
-- in: selected, being repaired, provisioned by a creation, being switched away from), or nil.
-- w_core kicks the owner before it purges; one still here means the character is in use.
local function purgeHolder(charid)
    for src, entry in pairs(active) do
        if entry.charid == charid and GetPlayerName(src) ~= nil then return src end
    end
    for src, p in pairs(pending) do
        if p.charid == charid and loggedInOn(src, charid) then return src end
    end
    for src, g in pairs(grants) do
        if (g.charid == charid or g.provisioned == charid) and loggedInOn(src, charid) then return src end
    end
    for src, s in pairs(switching) do
        if s.from == charid and loggedInOn(src, charid) then return src end
    end
    return nil
end

-- Drop every stale reference to a purged character (players who left or moved on). A lapsed
-- switch would log its player back into `from` (relogSwitch), and a pending selection or grant
-- would finish on it: on a reused number that is someone else's character. The active entries of
-- players who left are the playerDropped handler's (it fires characterCleared). Returns the count.
local function forgetPurged(charid)
    local n = 0
    for src, p in pairs(pending) do
        if p.charid == charid then pending[src] = nil n = n + 1 end
    end
    for src, g in pairs(grants) do
        if g.charid == charid or g.provisioned == charid then grants[src] = nil n = n + 1 end
    end
    for src, s in pairs(switching) do
        if s.from == charid then switching[src] = nil n = n + 1 end
    end
    for src, last in pairs(lastLoaded) do
        if type(last.entry) == 'table' and last.entry.charid == charid then lastLoaded[src] = nil n = n + 1 end
    end
    for src, owed in pairs(cleanup) do
        if owed[charid] then
            owed[charid] = nil
            n = n + 1
            if next(owed) == nil then cleanup[src] = nil end
        end
    end
    return n
end

--- Purge everything w_creators keeps for a deleted character: its appearance, owned clothing and
--  outfits (WCAppearanceRepo.purge, one transaction) and every reference in memory. Called by
--  w_core (server thread, may yield) with the owner already kicked. It holds the character's
--  appearance lock and outfit lock while it deletes, so a write in flight finishes first and a
--  later one finds no row (every writer loads under the lock; saves are UPDATEs, so nothing is
--  recreated). Refused before anything changes when the id is invalid, the character is still in
--  use, a writer does not finish in time or the schema is not ready. No money and no history here.
--  Returns true, { characters_appearence, w_creators_clothes, w_creators_outfits, memory? } |
--  false, 'invalid_id' | 'online' | 'busy' | 'database_not_ready' | 'database'.
function Chars.purge(citizenid, ctx)
    local charid = purgeId(citizenid)
    if not charid then return false, 'invalid_id' end
    ctx = type(ctx) == 'table' and ctx or {}
    local holder = purgeHolder(charid)
    if holder then
        WCDebug.warn('characters', 'purging %s refused: player %s still holds it', charid, tostring(holder))
        return false, 'online'
    end

    purgeCounter = purgeCounter + 1
    local owner = ('purge:%s:%d'):format(charid, purgeCounter)
    local outfitKey = 'outfits:' .. charid
    local waitMs = tonumber(Chars.PURGE_LOCK_WAIT_MS) or 10000
    if not WCUtil.waitUntil(function() return WCSessions.lockCharacter(charid, owner) end, waitMs, 250) then
        WCDebug.warn('characters', 'purging %s refused: its appearance is still being written', charid)
        return false, 'busy'
    end
    local done, removed, counts = pcall(function()
        if not WCUtil.waitUntil(function() return WCSecurity.lock(outfitKey, PURGE_OUTFIT_LOCK_MS) end, waitMs, 250) then
            return false, 'busy'
        end
        local inner, purged, result = pcall(function()
            -- the waits yielded: the character may have been taken in the meantime
            if purgeHolder(charid) then return false, 'online' end
            local purgedOk, rows = WCAppearanceRepo.purge(charid)
            if not purgedOk then return false, rows end
            -- a characters:delete of this character waiting on w_core: its own delete is not needed
            if deleting[charid] then deleting[charid] = 'purged' end
            local forgotten = forgetPurged(charid)
            if forgotten > 0 then rows.memory = forgotten end
            return true, rows
        end)
        WCSecurity.unlock(outfitKey)
        if not inner then error(purged, 0) end
        return purged, result
    end)
    WCSessions.unlockCharacter(charid, owner)
    if not done then
        WCDebug.warn('characters', 'purging %s failed: %s', charid, tostring(removed))
        return false, 'database'
    end
    if removed ~= true then
        WCDebug.warn('characters', 'purging %s refused: %s', charid, tostring(counts))
        return false, counts or 'database'
    end
    WCDebug.log('characters', 'character %s purged (by %s): %d appearance, %d clothing, %d outfit row(s)', charid,
        tostring(ctx.by or '?'), counts.characters_appearence, counts.w_creators_clothes, counts.w_creators_outfits)
    return true, counts
end

w.callback.register('w_creators:characters:list', function(src) return Chars.list(src) end)
w.callback.register('w_creators:characters:select', function(src, charid) return Chars.select(src, charid) end)
w.callback.register('w_creators:characters:loaded', function(src) return Chars.loaded(src) end)
w.callback.register('w_creators:characters:beginCreate', function(src, sex) return Chars.beginCreate(src, sex) end)
w.callback.register('w_creators:characters:create', function(src, token, identity, app)
    return Chars.create(src, token, identity, app)
end)
w.callback.register('w_creators:characters:keepAlive', function(src, token) return Chars.keepAlive(src, token) end)
w.callback.register('w_creators:characters:cancelCreate', function(src, token) return Chars.cancelCreate(src, token) end)
w.callback.register('w_creators:characters:delete', function(src, charid, confirmText)
    return Chars.delete(src, charid, confirmText)
end)

-- Legacy: the pre-v3 creator announced the end of the creation with this event.
RegisterNetEvent('w_creators:server:creationReady', function()
    local src = source
    CreateThread(function() Chars.loaded(src) end)
end)

-- ---------------------------------------------------------------------
--  Lifecycle
-- ---------------------------------------------------------------------
AddEventHandler('playerDropped', function()
    local src = playerId(source)
    if not src then return end
    -- A character selected (or being repaired) but never loaded leaves the repository cache with
    -- the player (the cache holds the characters in play; the active one is dropped by the repository).
    for _, charid in ipairs({ pending[src] and pending[src].charid, grants[src] and grants[src].charid }) do
        if charid and not Chars.ownerOf(charid) then WCAppearanceRepo.invalidate(charid) end
    end
    busy[src], grants[src], pending[src], switching[src], lapsed[src] = nil, nil, nil, nil, nil
    lastLoaded[src] = nil
    -- Appearance cleanups the player did not retry: one last attempt in the background.
    local owed = cleanup[src]
    cleanup[src] = nil
    if owed then
        CreateThread(function()
            for charid, state in pairs(owed) do
                -- an unconfirmed framework deletion: the data goes only when the row is gone
                local gone = state == 'owed' or frameworkRowGone(charid)
                local removed, repoDone = true, true
                if gone then removed, repoDone = pcall(WCAppearanceRepo.delete, charid) end
                if not removed or repoDone ~= true then
                    WCDebug.warn('characters', 'the appearance data of the deleted character %s is left behind: %s',
                        charid, tostring(repoDone))
                end
            end
        end)
    end
    -- The active character is kept until the end of this tick so the playerDropped handlers of
    -- later files (grooming, domains) can still read it.
    local entry = active[src]
    if entry then
        SetTimeout(0, function()
            if active[src] == entry then
                active[src] = nil
                TriggerEvent('w_creators:server:characterCleared', src, entry.charid, 'dropped')
            end
        end)
    end
end)

-- A resource restart loses the in-memory tracking while players are in the world: the characters
-- the framework still has logged in are adopted (startup pass once the database is ready, or on
-- demand: WCCharacters.recover, the scene guard's call for a player the pass has not reached).

local function untracked(src)
    return not active[src] and not pending[src] and not grants[src] and not switching[src]
end

local function adopt(src, charid, app)
    active[src] = { charid = charid, sex = app.sex, recoveredUntil = now() + RECOVERY_WINDOW_MS }
    TriggerEvent('w_creators:server:characterActivated', src, charid, app.sex)
    WCSync.broadcast(src, app)
end

--- Resolve a logged-in player the server does not track (a resource restart): his framework
--  character is adopted as active (as the startup pass does: the 2-minute re-selection window), or,
--  when it has no saved appearance, he gets a repair grant (the character flow: select hands out a
--  fresh one). Returns 'active' | 'flow' | nil, code (nil without a code: nothing to resolve).
function Chars.recover(src)
    src = playerId(src)
    if not src then return nil, 'INVALID_PAYLOAD' end
    if active[src] then return 'active' end
    if Chars.inFlow(src) then return 'flow' end
    if busy[src] then return nil, 'BUSY' end
    local charid = frameworkCharid(src)
    if not charid or Chars.ownerOf(charid) then return nil end
    busy[src] = 'recover'
    local done, app, meta = pcall(WCAppearanceRepo.load, charid)
    busy[src] = nil
    -- The load yields: the player may have dropped, entered the flow or changed character.
    if GetPlayerName(src) == nil or frameworkCharid(src) ~= charid then return nil, 'BUSY' end
    if active[src] then return 'active' end
    if not untracked(src) then return 'flow' end
    if Chars.ownerOf(charid) then return nil end
    if not done then return nil, 'INTERNAL_ERROR' end
    if type(app) == 'table' then
        adopt(src, charid, app)
        WCDebug.log('characters', 'player %s: character %s adopted on demand', tostring(src), charid)
        return 'active'
    end
    if type(meta) == 'table' and meta.missing then
        local details = frameworkDetails(src)[charid] or {}
        grants[src] = { token = newToken(src), kind = 'repair', charid = charid, sex = details.sex,
                        expires = now() + GRANT_TTL_MS }
        return 'flow'
    end
    return nil, type(meta) == 'table' and meta.error or 'DATABASE_ERROR'
end

Chars.SWITCH_CHECK_MS = 5000
CreateThread(function()
    while true do
        Wait(Chars.SWITCH_CHECK_MS)
        local done, err = pcall(Chars.checkSwitches)
        if not done then WCDebug.warn('characters', 'switch check failed: %s', tostring(err)) end
    end
end)

CreateThread(function()
    if WCMigrations and WCMigrations.waitReady and not WCMigrations.waitReady(120000) then return end
    for _, id in ipairs(GetPlayers()) do
        local src = playerId(id)
        if src and untracked(src) and not busy[src] then
            local charid = frameworkCharid(src)
            if charid then
                local done, app = pcall(WCAppearanceRepo.load, charid)
                -- The load yields: the player may have dropped, entered the flow or changed character.
                if done and type(app) == 'table' and GetPlayerName(src) ~= nil and frameworkCharid(src) == charid
                    and untracked(src) and not busy[src] and not Chars.ownerOf(charid) then
                    adopt(src, charid, app)
                end
            end
        end
    end
end)
