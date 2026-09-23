-- =====================================================================
--  client/dev/tools.lua  —  restricted development tools (ARCHITECTURE.md §1 A22, §10, §16.5, §17)
--  Nothing here is registered in production:
--    * Config.Admin.devTools = true registers the inspection commands. Each one first asks the server
--      (w_creators:dev:allowed(command) -> Result: the player holds Config.Admin.devAce) and does
--      nothing without an ok answer (a missing or silent callback counts as a refusal):
--        wc_inspect            lists the player ped's metaped categories through the category
--                              discovery natives (WCNative.metaped.numCategories / categoryAt): the
--                              category name, the equipped hash and its wearable state; printed to
--                              the client console (F8)
--        wc_apply <hash>       puts one shop item (decimal, 0x hex or a name) on the player ped
--        wc_remove <category>  removes one category from the player ped
--        wc_restore            renders the saved appearance again (Appearance.RestorePlayer)
--      wc_apply / wc_remove change only the local ped (nothing is saved or synced); wc_restore
--      undoes them. All four refuse while an editor, a service visit or the character scene runs.
--    * Config.Admin.spawnProp = true registers the handler of W:ADMIN:SpawnObject(model), sent by the
--      ACE-restricted server command `spawnprop <model>` (server/dev/tools.lua): a valid model (name
--      or hash) is created on the ground at the player's position through w.entity.create (the
--      library deletes it when the resource stops).
-- =====================================================================

WCDevClient = {}
local Dev = WCDevClient

Dev.ALLOWED = 'w_creators:dev:allowed'
Dev.MAX_ARG = 64

local DENIED = 'هذا الأمر مخصص للمطورين'
local REPORTED = 'تمت طباعة التقرير في وحدة التحكم (F8)'
local DONE = 'تم'

local function devTools() return type(Config.Admin) == 'table' and Config.Admin.devTools == true end
local function spawnProp() return type(Config.Admin) == 'table' and Config.Admin.spawnProp == true end

local function notify(key, kind)
    if type(key) ~= 'string' or key == '' then return end
    pcall(w.notify, { description = locale(key), type = kind or 'error' })
end

--- A report line on the client console (w_lib's printer; WCDebug.warn when it is unavailable).
local function report(fmt, ...)
    local ok, line = pcall(string.format, fmt, ...)
    if not ok then line = tostring(fmt) end
    local printer = type(w) == 'table' and type(w.print) == 'table' and w.print.info
    if printer and pcall(printer, '%s', line) then return end
    WCDebug.warn('dev', '%s', line)
end

local function pedExists(ped)
    return type(ped) == 'number' and ped ~= 0 and DoesEntityExist(ped) == true
end

--- A u32 hash as the signed int32 the game and w_lib use.
local function signed(u)
    if type(u) ~= 'number' then return nil end
    return u >= 0x80000000 and u - 0x100000000 or u
end

--- A shop item / model argument: decimal, 0x hex (signed or unsigned) or a name (joaat). u32 | nil.
function Dev.parseHash(arg)
    if type(arg) == 'number' then return WCUtil.u32(math.tointeger(arg)) end
    if type(arg) ~= 'string' or arg == '' or #arg > Dev.MAX_ARG then return nil end
    local number = tonumber(arg)
    if number then return WCUtil.u32(math.tointeger(number)) end
    if not arg:match('^[%w_]+$') then return nil end
    return WCUtil.u32(GetHashKey(arg))
end

--- Why a dev command cannot run now (a WCResult code), or nil.
local function blocked()
    if WCState.inEditor() then return 'BUSY' end
    if type(WCServiceFlow) == 'table' and type(WCServiceFlow.current) == 'function' and WCServiceFlow.current() then
        return 'BUSY'
    end
    if type(WCClientApi) == 'table' and WCClientApi.inCharacterScene() then return 'BUSY' end
    for _, lock in ipairs({ 'selection', 'spawn', 'respawn', 'clothingAction' }) do
        if WCState.busy(lock) then return 'BUSY' end
    end
    return nil
end

--- Ask the server whether this player may use a dev command. Yields. true | false (the refusal
--  has been shown).
function Dev.allowed(command)
    local ok, result = pcall(w.callback.await, Dev.ALLOWED, false, command)
    if ok and WCResult.is(result) and result.ok then return true end
    local code = ok and WCResult.is(result) and result.code or 'INTERNAL_ERROR'
    WCDebug.log('dev', '%s refused: %s', tostring(command), tostring(code))
    if code == 'INTERNAL_ERROR' or type(result) ~= 'table' or type(result.message) ~= 'string' then
        notify(DENIED)
    else
        notify(result.message)
    end
    return false
end

-- ---------------------------------------------------------------------
--  The commands' actions (callable directly by tests; the commands gate them)
-- ---------------------------------------------------------------------

--- The metaped categories of a ped: { { index, hash (u32), name, equipped (u32|nil), state } } or
--  nil when the discovery natives are unavailable (Config.Admin.devTools off, invalid ped).
function Dev.inspect(ped)
    local n = WCNative.metaped.numCategories(ped)
    if type(n) ~= 'number' then return nil end
    local rows = {}
    for index = 0, math.max(0, math.tointeger(n) or 0) - 1 do
        local hash = WCNative.metaped.categoryAt(ped, index)
        if hash then
            local s = signed(hash)
            local okName, name = pcall(w.component.getCategoryNameFromHash, s)
            if not okName or type(name) ~= 'string' or name == 'unknown' then
                okName, name = pcall(w.component.getCategoryNameFromHash, hash)
            end
            local okItem, item = pcall(w.component.getComponentEquiped, ped, s)
            local okState, state = pcall(w.component.getWearableState, ped, s)
            rows[#rows + 1] = {
                index = index,
                hash = hash,
                name = okName and type(name) == 'string' and name or 'unknown',
                equipped = okItem and type(item) == 'number' and item ~= 0 and WCUtil.u32(item) or nil,
                state = okState and type(state) == 'string' and state or 'unknown',
            }
        end
    end
    return rows
end

--- Print the inspection of the player ped. Returns the rows, or nil when the discovery natives are
--  unavailable.
function Dev.printInspection()
    local ped = PlayerPedId()
    local rows = Dev.inspect(ped)
    if not rows then return nil end
    local saved = type(WCState.appearance) == 'table' and WCState.appearance.clothing or {}
    local equipped = type(saved) == 'table' and type(saved.equipped) == 'table' and saved.equipped or {}
    local savedByHash = {}
    for category, hash in pairs(equipped) do
        local u = WCUtil.u32(hash)
        if u then savedByHash[u] = category end
    end
    report('[w_creators] wc_inspect: %d metaped categories on ped %s', #rows, tostring(ped))
    for _, row in ipairs(rows) do
        report('  [%02d] 0x%08X %-24s equipped=%s state=%s%s', row.index, row.hash, row.name,
            row.equipped and ('0x%08X'):format(row.equipped) or '-', row.state,
            row.equipped and savedByHash[row.equipped] and (' (saved: ' .. savedByHash[row.equipped] .. ')') or '')
    end
    notify(REPORTED, 'inform')
    return rows
end

--- Put one shop item on the player ped (local preview only). Returns true | false, code.
function Dev.apply(arg)
    local hash = Dev.parseHash(arg)
    if not hash or hash == 0 then return false, 'INVALID_PAYLOAD' end
    local ped = PlayerPedId()
    if not pedExists(ped) then return false, 'INVALID_PAYLOAD' end
    local sex = type(WCState.appearance) == 'table' and WCState.appearance.sex or nil
    local item = sex and WCCatalog.item(sex, hash) or nil
    local category = item and item.category or nil
    if not category then
        local ok, catHash = pcall(w.component.getComponentCategory, ped, signed(hash))
        if not ok or not catHash or catHash == 0 then return false, 'INVALID_COMPONENT' end
        category = catHash
    end
    local done = Appearance.ApplyComponent(ped, category, hash)
    if not done then return false, 'INVALID_COMPONENT' end
    Appearance.Refresh(ped)
    WCDebug.log('dev', 'applied 0x%08X (%s)', hash, tostring(category))
    return true
end

--- Remove one category from the player ped (local preview only). Returns true | false, code.
function Dev.remove(category)
    if type(category) ~= 'string' or category == '' or #category > Dev.MAX_ARG or not category:match('^[%w_]+$') then
        return false, 'INVALID_PAYLOAD'
    end
    local ped = PlayerPedId()
    if not pedExists(ped) then return false, 'INVALID_PAYLOAD' end
    if not Appearance.RemoveCategory(ped, category) then return false, 'INVALID_COMPONENT' end
    Appearance.Refresh(ped)
    return true
end

--- Render the saved appearance again. Returns true | false, code.
function Dev.restore()
    if type(WCState.appearance) ~= 'table' then return false, 'NO_CHARACTER' end
    local done, err = Appearance.RestorePlayer()
    if not done then
        WCDebug.warn('dev', 'wc_restore failed: %s', tostring(err))
        return false, 'INTERNAL_ERROR'
    end
    return true
end

--- Run one dev command: the local guards, the server's permission, then the action. Yields.
---@return boolean ran
function Dev.run(command, action, ...)
    local why = blocked()
    if why then
        notify(WCResult.messageKey(why))
        return false
    end
    if not Dev.allowed(command) then return false end
    -- the permission round trip yields: a flow may have started meanwhile
    why = blocked()
    if why then
        notify(WCResult.messageKey(why))
        return false
    end
    local ok, done, code = pcall(action, ...)
    if not ok then
        WCDebug.warn('dev', '%s failed: %s', command, tostring(done))
        notify(WCResult.messageKey('INTERNAL_ERROR'))
        return false
    end
    if done == false then
        notify(WCResult.messageKey(code or 'INTERNAL_ERROR'))
        return false
    end
    if command ~= 'wc_inspect' then notify(DONE, 'success') end
    return true
end

-- ---------------------------------------------------------------------
--  Registration (only with the config flags)
-- ---------------------------------------------------------------------
Dev.COMMANDS = {
    wc_inspect = function()
        if not Dev.printInspection() then return false, 'SERVICE_DISABLED' end
        return true
    end,
    wc_apply = function(args) return Dev.apply(args[1]) end,
    wc_remove = function(args) return Dev.remove(args[1]) end,
    wc_restore = function() return Dev.restore() end,
}

if devTools() then
    for name, action in pairs(Dev.COMMANDS) do
        RegisterCommand(name, function(_, args)
            args = type(args) == 'table' and args or {}
            CreateThread(function() Dev.run(name, action, args) end)
        end, false)
    end
end

local props = {}

--- Create a prop on the ground at the player's position. Returns the entity or nil.
function Dev.spawnObject(model)
    local hash = Dev.parseHash(model)
    if not hash or hash == 0 then return nil end
    local modelHash = signed(hash)
    if not IsModelValid(modelHash) then
        WCDebug.log('dev', 'spawnprop: invalid model %s', tostring(model))
        return nil
    end
    local ped = PlayerPedId()
    if not pedExists(ped) then return nil end
    local c = GetEntityCoords(ped)
    local found, groundZ = GetGroundZAndNormalFor_3dCoord(c.x, c.y, c.z)
    local z = (found and type(groundZ) == 'number') and groundZ or c.z
    local ok, entity = pcall(w.entity.create, modelHash, vector3(c.x, c.y, z + 0.02), 0.0, true)
    if not ok or type(entity) ~= 'number' or entity == 0 then
        WCDebug.warn('dev', 'spawnprop %s failed: %s', tostring(model), tostring(entity))
        return nil
    end
    props[#props + 1] = entity
    return entity
end

if spawnProp() then
    RegisterNetEvent('W:ADMIN:SpawnObject', function(model)
        if type(model) ~= 'string' and type(model) ~= 'number' then return end
        CreateThread(function() Dev.spawnObject(model) end)
    end)

    -- the library deletes what it created; anything still there goes with the resource
    AddEventHandler('onResourceStop', function(resource)
        if resource ~= GetCurrentResourceName() then return end
        for _, entity in ipairs(props) do
            if DoesEntityExist(entity) then pcall(w.entity.delete, entity) end
        end
        props = {}
    end)
end
