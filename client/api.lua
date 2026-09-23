-- =====================================================================
--  client/api.lua  —  the public client API (ARCHITECTURE.md §13, §16.5, §17)
--  Client exports owned here (the others live with their modules: OpenWardrobe in
--  client/wardrobe/wardrobe.lua, the clothing-state exports in client/clothing/states.lua,
--  Resurrect in client/respawn/respawn.lua):
--    OpenCosmeticSurgery(clinicId) -> boolean   opens a clinic that has its own prompt (a clinic with
--                                               prompt = false needs the server export's grant)
--    GetAppearance()               -> v3 appearance (copy) | nil
--    GetCurrentOutfit()            -> { outfit, equipped, tints, states } (copies) | nil
--    GetEquippedCategory(category) -> hash (u32), tint (copy) | nil   clothing categories and the
--                                     body parts heads, eyes, teeth, BODIES_UPPER, BODIES_LOWER,
--                                     hair, mustache (beard)
--    RefreshAppearance()           -> boolean   reloads the saved appearance from the server
--                                               (w_creators:appearance:reload) and renders it; a
--                                               refused reload re-renders the local copy
--    IsInCharacterScene()          -> boolean   selection room, creator, login spawn selection
--  Server-opened services (§16.5): w_creators:client:openBarber(locationId) -> WCBarber.open.
--  (openStore / openWardrobe are handled by client/clothing/store.lua and client/wardrobe/wardrobe.lua,
--  openSurgery by client/surgery/surgery.lua.)
--  Command: /reloadappearance (pre-v3 name) -> RefreshAppearance().
--  Every read returns a copy: a caller can never change the local character's state.
-- =====================================================================

WCClientApi = {}
local Api = WCClientApi

local MAX_ID = 64
local RELOAD = 'w_creators:appearance:reload'

-- Body parts readable through GetEquippedCategory (category -> path in the v3 appearance).
local BODY_PARTS = {
    heads = { 'head', 'head' }, eyes = { 'head', 'eyes' }, teeth = { 'head', 'teeth' },
    BODIES_UPPER = { 'body', 'upper' }, BODIES_LOWER = { 'body', 'lower' },
    hair = { 'hair', 'style' }, mustache = { 'hair', 'facial' }, beards_complete = { 'hair', 'facial' },
}

local function notify(key)
    if type(key) ~= 'string' or key == '' then return end
    pcall(w.notify, { description = locale(key), type = 'error' })
end

--- mod[fn]() when the module and the function exist; true only for a truthy answer.
local function ask(mod, fn, ...)
    if type(mod) ~= 'table' or type(mod[fn]) ~= 'function' then return false end
    local ok, value = pcall(mod[fn], ...)
    return ok and value ~= nil and value ~= false
end

--- A server callback that always answers a WCResult (a throw or a lost reply is INTERNAL_ERROR).
local function call(name, ...)
    local ok, result = pcall(w.callback.await, name, false, ...)
    if not ok then
        WCDebug.warn('api', '%s failed: %s', name, tostring(result))
        return WCResult.fail('INTERNAL_ERROR')
    end
    if not WCResult.is(result) then return WCResult.fail('INTERNAL_ERROR') end
    return result
end

-- ---------------------------------------------------------------------
--  Reading
-- ---------------------------------------------------------------------

--- The saved v3 appearance of the local character (a copy), or nil.
function Api.appearance()
    return WCState.get()
end

--- The clothing of the local character: the outfit id it was last dressed from (or nil), the
--  equipped items, their tints and the clothing states (copies), or nil without a character.
function Api.currentOutfit()
    local app = WCState.appearance
    if type(app) ~= 'table' or type(app.clothing) ~= 'table' then return nil end
    local c = app.clothing
    return {
        outfit = c.outfit,
        equipped = WCUtil.copy(type(c.equipped) == 'table' and c.equipped or {}),
        tints = WCUtil.copy(type(c.tints) == 'table' and c.tints or {}),
        states = WCUtil.copy(type(c.states) == 'table' and c.states or {}),
    }
end

--- The item worn in a category: hash (u32) and tint (a copy, clothing only), or nil when nothing
--  is worn there. A clothing item hidden by a clothing state (hat off, §5.5) is still equipped.
---@param category string
---@return integer|nil hash, table|nil tint
function Api.equippedCategory(category)
    if type(category) ~= 'string' or category == '' or #category > MAX_ID then return nil end
    local app = WCState.appearance
    if type(app) ~= 'table' then return nil end
    local part = BODY_PARTS[category]
    if part then
        local section = app[part[1]]
        local value = type(section) == 'table' and WCUtil.u32(section[part[2]]) or nil
        if not value or value == 0 then return nil end
        return value
    end
    local clothing = type(app.clothing) == 'table' and app.clothing or {}
    local equipped = type(clothing.equipped) == 'table' and clothing.equipped or {}
    local hash = WCUtil.u32(equipped[category])
    if not hash or hash == 0 then return nil end
    local tints = type(clothing.tints) == 'table' and clothing.tints or {}
    local tint = type(tints[category]) == 'table' and WCUtil.copy(tints[category]) or nil
    return hash, tint
end

--- Is the player in the character scene: the selection room, the creator, or the spawn selection
--  of a login (an admin spawn selection happens in the world and does not count)?
function Api.inCharacterScene()
    if ask(CreatorScene, 'isLoaded') or ask(CreatorScene, 'isIsolated') then return true end
    if WCState.busy('selection') then return true end
    if ask(WCSelector, 'active') or ask(WCCreator, 'active') then return true end
    local sel = WCSpawnSelector
    if ask(sel, 'active') then
        local ok, kind = pcall(sel.kind)
        if not ok or kind ~= 'admin' then return true end
    end
    local okSession, s = pcall(WCEditor.session)
    return okSession and type(s) == 'table' and s.mode == 'creator'
end

-- ---------------------------------------------------------------------
--  Refresh
-- ---------------------------------------------------------------------

local refreshing = false

--- Why a refresh cannot run now (a WCResult code), or nil.
local function refreshBlocked()
    if type(WCState.appearance) ~= 'table' then return 'NO_CHARACTER' end
    if refreshing or Api.inCharacterScene() or WCState.inEditor() then return 'BUSY' end
    if ask(Appearance, 'IsPlayerApplying') then return 'BUSY' end
    return nil
end

--- Reload the saved appearance from the server and render it on the player (in its own thread).
--  The server refuses while a service session is open or a commit runs (BUSY) and rate-limits
--  (1 / 10 s); a refused reload re-renders the local saved copy instead. Nothing is rendered over
--  an open editor (Appearance.Sync.applyOwn stores it only).
---@return boolean started, string|nil code
function Api.refresh()
    local why = refreshBlocked()
    if why then return false, why end
    refreshing = true
    CreateThread(function()
        local ok, err = pcall(function()
            local result = call(RELOAD)
            local data = result.ok and type(result.data) == 'table' and result.data or nil
            if data and type(data.appearance) == 'table' then
                -- the reload answers the saved look; the runtime states (the raised bandana) the
                -- server keeps and broadcasts to the others stay on our ped as well
                Appearance.Sync.applyOwn(data.appearance, { keepRuntime = true })
                return
            end
            WCDebug.log('api', 'appearance reload refused (%s): re-rendering the local copy', tostring(result.code))
            local saved = WCState.get()
            if saved then Appearance.Sync.applyOwn(saved, { keepRuntime = true }) end
        end)
        if not ok then WCDebug.warn('api', 'appearance refresh failed: %s', tostring(err)) end
        refreshing = false
    end)
    return true
end

-- ---------------------------------------------------------------------
--  Services
-- ---------------------------------------------------------------------

--- Open a cosmetic surgery clinic (in its own thread: the flow waits on the server). Clinics with
--  prompt = false open only through the server export OpenCosmeticSurgery (its one-use grant).
---@param clinicId string
---@return boolean started
function Api.openSurgery(clinicId)
    if type(clinicId) ~= 'string' or clinicId == '' or #clinicId > MAX_ID then return false end
    CreateThread(function() WCSurgery.open(clinicId) end)
    return true
end

-- Server export OpenBarber (§13): the open callback re-validates everything.
RegisterNetEvent('w_creators:client:openBarber', function(locationId)
    CreateThread(function() WCBarber.open(locationId) end)
end)

-- ---------------------------------------------------------------------
--  Exports and the command
-- ---------------------------------------------------------------------
exports('OpenCosmeticSurgery', function(clinicId) return Api.openSurgery(clinicId) end)
exports('GetAppearance', function() return Api.appearance() end)
exports('GetCurrentOutfit', function() return Api.currentOutfit() end)
exports('GetEquippedCategory', function(category) return Api.equippedCategory(category) end)
exports('RefreshAppearance', function() return (Api.refresh()) end)
exports('IsInCharacterScene', function() return Api.inCharacterScene() end)

RegisterCommand('reloadappearance', function()
    local started, code = Api.refresh()
    if not started then notify(WCResult.messageKey(code)) end
end, false)
