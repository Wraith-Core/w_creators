-- =====================================================================
--  client/creator/creator.lua  —  WCCreator: the character creator (ARCHITECTURE.md §9.2, §17)
--
--  Server grant first (characters:beginCreate) → the gender scene (two preview peds in the creator
--  room, the room lights, standing scenario idles, holstered revolvers, the w_lib gender prompts)
--  → beginCreate(sex) again (same token; the sex is locked server-side) → WCEditor in 'creator'
--  mode (every AppearanceSchema section, identity, the starting clothing) → characters:create →
--  render on the player ped → characters:loaded → spawn (WCSelector.finish).
--
--  Repair path: characters:select answered {needsAppearance, token, sex?} for a character without
--  a saved appearance → the creator in appearance-only mode (no identity; create(token, nil, app)).
--
--  Back in the gender scene → characters:cancelCreate + the selection screen. Cancel in the editor →
--  the gender scene again. Everything the creator takes (prompts, peds, cameras, the lights loop,
--  NUI, the player's frozen/hidden state, the 'selection' lock) is released on success, failure,
--  a lost grant and resource stop; the room itself (focus, timecycle, clock override, maps,
--  bucket) through CreatorScene.
--
--  Public: WCCreator.start(opts) -> true | false, code; WCCreator.active(); WCCreator.stage();
--          net event W:CHARCREATION:starting (compatibility: server-granted only).
-- =====================================================================

WCCreator = {}
local C = WCCreator

local SEXES = { 'male', 'female' }
local MSG_RETRY = 'تعذر عرض الشخصية. أعد المحاولة'
local TITLE = 'بناء الشخصية'
local SOUND_SET = 'RDRO_Character_Creator_Sounds'

-- Codes after which the creation grant is gone: back to the selection screen.
local GRANT_LOST = { CREATION_NOT_GRANTED = true, CREATION_DISABLED = true, CHARACTER_SLOT_LIMIT = true }

local st = {
    active = false,
    stage = nil,      -- 'starting' | 'gender' | 'waiting' | 'editor' | 'saving'
    token = nil,      -- the server creation grant
    repair = nil,     -- { token, sex?, charid, appearance? } for the appearance-only path
    sex = 'male',     -- the gender shown / picked
    peds = {},        -- [sex] = preview ped
    prompts = nil,
    busy = false,     -- a gender-scene action runs
    ownsLock = false,
    generation = 0,   -- bumped on every start / teardown: stale threads stop
}

-- ---------------------------------------------------------------------
--  Helpers
-- ---------------------------------------------------------------------

local function validSex(sex)
    return (sex == 'male' or sex == 'female') and sex or nil
end

local function notify(key, kind)
    if type(key) ~= 'string' then return end
    pcall(w.notify, { description = locale(key), type = kind or 'error' })
end

local function messageOf(result)
    if type(result) == 'table' then
        if type(result.message) == 'string' then return result.message end
        if type(result.code) == 'string' then return WCResult.messageKey(result.code) end
    end
    return WCResult.messageKey('INTERNAL_ERROR')
end

local function await(name, ...)
    local ok, result = pcall(w.callback.await, name, false, ...)
    if not ok then
        WCDebug.warn('creator', '%s failed: %s', name, tostring(result))
        return WCResult.fail('INTERNAL_ERROR')
    end
    if not WCResult.is(result) then return WCResult.fail('INTERNAL_ERROR') end
    return result
end

local function pedExists(ped)
    return type(ped) == 'number' and ped ~= 0 and DoesEntityExist(ped) == true
end

local function takeLock()
    if st.ownsLock then return end
    st.ownsLock = WCState.busy('selection', true) == true
end

local function releaseLock()
    if st.ownsLock then WCState.busy('selection', false) end
    st.ownsLock = false
end

local function hidePlayer()
    if type(WCSelector) == 'table' and WCSelector.hidePlayer then return WCSelector.hidePlayer() end
    local ped = PlayerPedId()
    FreezeEntityPosition(ped, true)
    SetEntityInvincible(ped, true)
    SetEntityVisible(ped, false)
    NetworkSetEntityOnlyExistsForParticipants(ped, true)
end

local function restorePlayer()
    if type(WCSelector) == 'table' and WCSelector.restorePlayer then return WCSelector.restorePlayer() end
    local ped = PlayerPedId()
    SetEntityVisible(ped, true)
    NetworkSetEntityOnlyExistsForParticipants(ped, false)
    SetEntityInvincible(ped, false)
    FreezeEntityPosition(ped, false)
end

local function sceneCoords(sex)
    local peds = (Config.Scene and Config.Scene.peds) or {}
    return peds[sex]
end

-- ---------------------------------------------------------------------
--  The gender prompts (w_lib NUI prompts: Arabic-capable)
-- ---------------------------------------------------------------------

local function promptCfg() return Config.Characters.genderPrompt or {} end

local function destroyPrompts()
    local group = st.prompts
    st.prompts = nil
    if group then
        pcall(group.hide)
        pcall(group.delete)
    end
end

local function buildPrompts()
    destroyPrompts()
    local P = promptCfg()
    local group = w.prompt.createGroup(locale(P.title), P.position)
    group.addPrompt(P.prev.key, locale(P.prev.label), false)
    group.addPrompt(P.next.key, locale(P.next.label), false)
    group.addPrompt(P.accept.key, locale(P.accept.label), false)
    group.addPrompt(P.back.key, locale(P.back.label), false)
    group.display()
    st.prompts = group
end

local function relabelPrompts()
    local group = st.prompts
    if not group then return end
    local P = promptCfg()
    pcall(function()
        group.setTitle(locale(P.title))
        group.setLabel(P.prev.key, locale(P.prev.label))
        group.setLabel(P.next.key, locale(P.next.label))
        group.setLabel(P.accept.key, locale(P.accept.label))
        group.setLabel(P.back.key, locale(P.back.label))
    end)
end

local function isCompleted(key)
    local group = st.prompts
    if not group or key == nil then return false end
    local ok, done = pcall(group.isCompleted, key)
    return ok and done == true
end

-- ---------------------------------------------------------------------
--  Teardown
-- ---------------------------------------------------------------------

local function destroyPeds()
    for sex, ped in pairs(st.peds) do
        CreatorScene.destroy(ped)
        st.peds[sex] = nil
    end
    st.peds = {}
end

--- Release everything the creator took. The room (maps, bucket) stays for the next owner:
--  the selection screen (back / failure) or the spawn (WCSelector.finish).
local function teardown()
    st.generation = st.generation + 1
    st.active, st.stage, st.busy = false, nil, false
    destroyPrompts()
    local session = WCEditor.session()
    if session and session.mode == 'creator' then WCEditor.close() end
    destroyPeds()
    WCCamera.close()
    pcall(WCNative.ui.blankObjective)
    releaseLock()
    st.token, st.repair = nil, nil
end

local function backToSelection(errorKey)
    if type(WCSelector) == 'table' and WCSelector.back then
        local ok = WCSelector.back(errorKey)
        if ok then return end
        WCDebug.warn('creator', 'the selection screen could not be reopened')
        return
    end
    TriggerEvent('w_creators:client:backToSelection', errorKey)
end

--- Give up the creation: release the grant and go back to the selection screen.
local function abort(errorKey)
    local token = st.token
    teardown()
    if token then await('w_creators:characters:cancelCreate', token) end
    backToSelection(errorKey)
end
C.abort = abort

-- ---------------------------------------------------------------------
--  The scene loop: lights, controls, HUD every frame while the creator is up
-- ---------------------------------------------------------------------

local selectSex, accept

local function genderInput()
    local P = promptCfg()
    if isCompleted(P.back.key) then
        st.busy = true
        CreateThread(function()
            destroyPrompts()
            abort(nil)
        end)
    elseif isCompleted(P.next.key) then
        selectSex('female')
    elseif isCompleted(P.prev.key) then
        selectSex('male')
    elseif isCompleted(P.accept.key) then
        st.busy = true
        CreateThread(function()
            local ok, err = pcall(accept)
            if not ok then
                if type(err) ~= 'table' then WCDebug.warn('creator', 'accept failed: %s', tostring(err)) end
                abort(type(err) == 'table' and err.key or MSG_RETRY)
            end
            st.busy = false
        end)
    end
end

local function startLoop()
    local gen = st.generation
    CreateThread(function()
        while st.active and gen == st.generation do
            DisableAllControlActions(0)
            SuppressGameHud()
            CreatorScene.drawLights()
            if st.stage == 'editor' or st.stage == 'saving' then
                -- no stale objective text over the editor (the pre-v3 state loop did the same)
                WCNative.ui.clearObjective()
            elseif st.stage == 'gender' and not st.busy then
                genderInput()
            end
            Wait(0)
        end
    end)
end

-- ---------------------------------------------------------------------
--  The gender scene
-- ---------------------------------------------------------------------

--- Place (or create) the preview ped of a sex in its gender-scene slot with the default look.
local function stagePed(sex)
    local app = AppearanceSchema.default(sex)
    local ped = st.peds[sex]
    if pedExists(ped) then
        local placed, code = CreatorScene.position(ped, sceneCoords(sex))
        if not placed then error('position ' .. sex .. ': ' .. tostring(code), 0) end
        local rendered, err = Appearance.RestoreCharacter(ped, app)
        if not rendered then error('render ' .. sex .. ': ' .. tostring(err), 0) end
        CreatorScene.ready(ped)
        SetEntityCollision(ped, true, true)
        CreatorScene.show(ped)
    else
        local created, err = CreatorScene.create(nil, sceneCoords(sex), app)
        if not created then error('preview ' .. sex .. ': ' .. tostring(err), 0) end
        ped = created
        st.peds[sex] = ped
    end
    CreatorScene.arm(ped, sex)
    CreatorScene.idle(ped, sex)
    return ped
end

local function showGenderScene()
    for _, sex in ipairs(SEXES) do stagePed(sex) end
    if not WCCamera.open(st.peds[st.sex], 'selection') then error('camera', 0) end
    buildPrompts()
    st.stage = 'gender'
end

selectSex = function(sex)
    if st.sex == sex then return end
    st.sex = sex
    PlaySoundFrontend(sex == 'female' and 'gender_right' or 'gender_left', SOUND_SET, true, 0)
    WCCamera.open(st.peds[sex], 'selection')
end

--- Back from the editor to the gender scene (the editor already restored and closed itself).
local function backToGender()
    if not st.active then return end
    if st.repair and validSex(st.repair.sex) then
        -- the server knows the sex of a repaired character: nothing to choose, back to the list
        abort(nil)
        return
    end
    StartFade(400, 'creator')
    local ok, err = pcall(showGenderScene)
    if not ok then
        WCDebug.warn('creator', 'the gender scene could not be restored: %s', tostring(err))
        abort(MSG_RETRY)
        return
    end
    EndFade(400)
end

-- ---------------------------------------------------------------------
--  The editor
-- ---------------------------------------------------------------------

local openEditor

--- Save: characters:create → render on the player → loaded (only after the render succeeded).
local function commit(working, extra)
    if not st.active or st.stage ~= 'editor' then return WCResult.fail('BUSY') end
    st.stage = 'saving'
    local identity = (not st.repair) and type(extra) == 'table' and extra.identity or nil
    local result = await('w_creators:characters:create', st.token, identity, working)
    if not result.ok then
        st.stage = 'editor'
        if GRANT_LOST[result.code] then
            -- the grant is gone (expired, disabled, no slot): the editor cannot succeed any more
            local key = messageOf(result)
            CreateThread(function() abort(key) end)
        end
        return result
    end

    local data = type(result.data) == 'table' and result.data or {}
    local app = AppearanceSchema.normalize(data.appearance or working)
    StartFade(300, 'creator')
    local rendered, err = Appearance.SetPlayerModel(app.sex)
    if rendered then rendered, err = Appearance.RestorePlayer(app) end
    if not rendered then
        -- the character exists; a retry of the same token replays the same create answer
        WCDebug.warn('creator', 'the created appearance could not be rendered: %s', tostring(err))
        hidePlayer()
        EndFade(300)
        st.stage = 'editor'
        return WCResult.fail('INTERNAL_ERROR')
    end

    local charid = data.charid ~= nil and tostring(data.charid) or (st.repair and st.repair.charid) or nil
    WCState.setCharacter(charid, app.sex)
    WCState.set(app)
    teardown()
    restorePlayer()

    local loaded = await('w_creators:characters:loaded')
    if not loaded.ok then
        WCState.clear()
        local key = messageOf(loaded)
        CreateThread(function() backToSelection(key) end)
        return result
    end
    if type(WCSelector) == 'table' and WCSelector.finish then
        WCSelector.finish(type(loaded.data) == 'table' and loaded.data.spawn or nil)
    else
        CreatorScene.release({ keepBucket = true })
    end
    return result
end

openEditor = function(sex)
    StartFade(250, 'creator')
    local ped = st.peds[sex]
    if not pedExists(ped) then ped = stagePed(sex) end
    -- the other gender's ped would show in every wide shot: hidden (deleted by the teardown)
    for other, p in pairs(st.peds) do
        if other ~= sex and pedExists(p) then
            SetEntityVisible(p, false)
            SetEntityCollision(p, false, false)
        end
    end
    local placed, code = CreatorScene.position(ped, (Config.Scene or {}).editingPed)
    if not placed then error('editing position: ' .. tostring(code), 0) end
    CreatorScene.show(ped)

    local app, render = AppearanceSchema.default(sex), false
    if st.repair and type(st.repair.appearance) == 'table' then
        local existing = AppearanceSchema.normalize(st.repair.appearance)
        if type(existing) == 'table' and existing.sex == sex then app, render = existing, true end
    end
    local opened, reason = WCEditor.open(ped, 'creator', app, {
        title = TITLE,
        sections = AppearanceSchema.SECTIONS,
        -- the repair path keeps the framework identity: no identity stage, create(token, nil, app)
        identity = (not st.repair) and { sex = sex, locked = false } or nil,
        context = {
            startingClothing = Config.Creator.startingClothing,
            presets = (Config.StartingOutfits and Config.StartingOutfits[sex]) or {},
        },
        render = render,
        onCommit = commit,
        onCancel = function() CreateThread(backToGender) end,
    })
    if not opened then error({ key = WCResult.messageKey(reason or 'INTERNAL_ERROR') }, 0) end
    st.stage = 'editor'
    EndFade(300)
end

accept = function()
    local sex = st.sex
    PlaySoundFrontend('gender_left', SOUND_SET, true, 0)
    destroyPrompts()
    st.stage = 'waiting'
    if not st.repair then
        local result = await('w_creators:characters:beginCreate', sex)
        if not result.ok then
            if GRANT_LOST[result.code] then
                abort(messageOf(result))
                return
            end
            notify(messageOf(result))
            buildPrompts()
            st.stage = 'gender'
            return
        end
        if type(result.data) == 'table' and type(result.data.token) == 'string' then st.token = result.data.token end
    end
    openEditor(sex)
end

-- ---------------------------------------------------------------------
--  Start
-- ---------------------------------------------------------------------

--- The room: isolated (the selection usually did it already), loaded, cleaned, the player hidden.
local function prepareRoom()
    if not CreatorScene.isIsolated() then
        local ok, code = CreatorScene.isolate()
        if not ok then error({ key = WCResult.messageKey(code or 'INTERNAL_ERROR') }, 0) end
    end
    if not CreatorScene.isLoaded() then CreatorScene.load() end
    CreatorScene.cleanup()
    hidePlayer()
    SetCustomHudVisible(false)
    WCCamera.close()
end

--- Start the creator. opts.repair = { token, sex?, charid, appearance? } for the appearance-only
--  path (the token comes from characters:select). Returns true | false, code.
function C.start(opts)
    opts = type(opts) == 'table' and opts or {}
    if st.active then return false, 'BUSY' end
    if WCEditor.isOpen() then return false, 'BUSY' end
    st.active, st.stage, st.busy = true, 'starting', false
    st.generation = st.generation + 1
    st.repair = type(opts.repair) == 'table' and type(opts.repair.token) == 'string' and opts.repair or nil
    st.token = st.repair and st.repair.token or nil
    st.sex = (st.repair and validSex(st.repair.sex)) or 'male'
    st.peds = {}
    takeLock()
    StartFade(500, 'creator')

    if not st.repair then
        local result = await('w_creators:characters:beginCreate')
        if not result.ok or type(result.data) ~= 'table' or type(result.data.token) ~= 'string' then
            -- no grant: back to the selection with the server's reason
            local key = result.ok and WCResult.messageKey('INTERNAL_ERROR') or messageOf(result)
            teardown()
            backToSelection(key)
            return false, result.ok and 'INTERNAL_ERROR' or result.code
        end
        st.token = result.data.token
    end

    local ok, err = pcall(function()
        prepareRoom()
        startLoop()
        if st.repair and validSex(st.repair.sex) then
            openEditor(st.repair.sex)
        else
            showGenderScene()
            EndFade(500)
        end
    end)
    if not ok then
        local key = type(err) == 'table' and err.key or MSG_RETRY
        if type(err) ~= 'table' then WCDebug.warn('creator', 'the creator scene failed: %s', tostring(err)) end
        abort(key)
        return false, 'INTERNAL_ERROR'
    end
    return true
end

--- Is the creator up?
function C.active() return st.active end

--- The creator stage ('starting' | 'gender' | 'waiting' | 'editor' | 'saving') or nil.
function C.stage() return st.stage end

-- ---------------------------------------------------------------------
--  Events and cleanup
-- ---------------------------------------------------------------------

--- Compatibility: other resources opened the creator with this event. It is honoured only as a
--  request: the server grant (beginCreate) decides, and a player with a character in play is
--  refused here (a character switch goes through /characters).
RegisterNetEvent('W:CHARCREATION:starting', function()
    CreateThread(function()
        if st.active then return end
        local selecting = type(WCSelector) == 'table' and WCSelector.active()
        if WCState.character and not selecting then
            WCDebug.warn('creator', 'W:CHARCREATION:starting ignored: a character is in play')
            return
        end
        if selecting then
            if WCSelector.busy() then return end
            WCSelector.leave()
        end
        C.start({})
    end)
end)

OnLanguageChange(function()
    if st.active then relabelPrompts() end
end)

AddEventHandler('onResourceStop', function(resource)
    if resource ~= GetCurrentResourceName() then return end
    if not st.active and not st.ownsLock and next(st.peds) == nil then return end
    st.generation = st.generation + 1
    st.active, st.stage = false, nil
    pcall(destroyPrompts)
    local okSession, session = pcall(WCEditor.session)
    if okSession and session and session.mode == 'creator' then pcall(WCEditor.close) end
    for _, ped in pairs(st.peds) do pcall(CreatorScene.destroy, ped) end
    st.peds = {}
    pcall(WCCamera.close)
    pcall(WCNative.ui.blankObjective)
    pcall(CreatorScene.release, { keepBucket = true })
    pcall(SetNuiFocus, false, false)
    pcall(restorePlayer)
    pcall(SetCustomHudVisible, true)
    releaseLock()
end)
