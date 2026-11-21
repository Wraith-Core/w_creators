-- =====================================================================
--  client/characters/selector.lua  —  WCSelector: the character selection screen
--  (ARCHITECTURE.md §9.1, §16.1, §17)
--
--  The VORP-style selection: one preview ped in the creator room (CreatorScene.create; the next
--  ped is created before the previous one is destroyed, the player ped is never a preview), the
--  WCCamera framing, the character card (WCEditor.showCard, §8.1) and a w_lib prompt group for the
--  keys (w.prompt.createGroup: the NUI prompts support Arabic, the native ones do not).
--
--  Flow: scene:prepare (also starts the server-tracked switch mid-game) → characters:list →
--  select → WCState + Appearance.SetPlayerModel/RestorePlayer → characters:loaded → spawn.
--  An empty slot hands over to the creator (WCCreator.start); a character without a saved
--  appearance ({needsAppearance, token}) opens the creator in appearance-only mode.
--  Delete: long press (holdTime) + confirmation dialog (+ the typed full name when the server
--  asks for it) → characters:delete → the list is reloaded.
--
--  Boot: session started → the ped really exists → playerSpawned (first login only; a resource
--  restart re-runs this file inside the session) → curtain → selection. A fade guard cancels any
--  other resource's fade (vorp_core) while the scene is visible.
--
--  Public: WCSelector.open(opts) | back(errorKey) | finish(spawnMode) | leave() | active()
--          | busy() | canSwitch(); command /characters (only with Config.Characters.allowSwitch);
--          local event w_creators:client:backToSelection(errorKey?).
-- =====================================================================

WCSelector = {}
local Sel = WCSelector

local INPUT_BARRIER_MS = 500        -- no key is accepted this long after the prompts appear
local SESSION_WAIT_STEP = 100
local PED_WAIT_MS = 30000           -- the player ped must exist with real coordinates
local SPAWN_EVENT_WAIT_MS = 20000   -- playerSpawned on the first login
local OTHER_FADE_WAIT_MS = 500      -- vorp_core's synchronous playerSpawned handler (its fade)
local FADE_GUARD_MS = 250
local FINAL_EXIT_TIMEOUT = 600000   -- the room maps are unloaded once the player left it
local FINAL_EXIT_STEP = 500
local EVENT_FADE_TIMEOUT = 15000    -- a framework spawn event must fade the screen in by then

local MSG_RETRY = 'تعذر عرض الشخصية. أعد المحاولة'
local MSG_RETRY_LABEL = 'إعادة المحاولة'
local MSG_RENDER = 'تعذر تطبيق التعديل'
local MSG_DELETED = 'تم حذف الشخصية.'
local MSG_TYPE_NAME = 'اكتب الاسم الكامل للشخصية لتأكيد الحذف'
local MSG_SWITCH_REFUSED = 'لا يمكنك تبديل الشخصية الآن'

local st = {
    inSelection = false,  -- the selection screen owns the scene
    sceneVisible = false, -- the scene really shows: any other fade is a mistake (fade guard)
    busy = false,         -- an open / action is running (rapid double actions are ignored)
    failed = false,       -- the retry prompt is shown
    slots = {},           -- { {char = card} | {empty = true} }
    index = 1,
    canCreate = false,
    deletion = { enabled = false, holdTime = 5000, typed = false },
    ped = nil,            -- the preview ped
    prompts = nil,        -- the w.prompt group
    deleteKey = nil,
    inputReadyAt = 0,
    ownsLock = false,     -- this module holds the WCState 'selection' lock
    generation = 0,       -- bumped on every open / stop: cancels a pending final exit
    guard = false,        -- the fade guard thread runs
}

-- ---------------------------------------------------------------------
--  Helpers
-- ---------------------------------------------------------------------

local function cfg() return (Config.Characters and Config.Characters.selection) or {} end
local function keys() return cfg().keys or {} end
local function labels() return cfg().labels or {} end

local function notify(key, kind, ...)
    if type(key) ~= 'string' then return end
    local text = locale(key, ...)
    pcall(w.notify, { description = text, type = kind or 'error' })
end

--- The locale key of a failed Result.
local function messageOf(result)
    if type(result) == 'table' then
        if type(result.message) == 'string' then return result.message end
        if type(result.code) == 'string' then return WCResult.messageKey(result.code) end
    end
    return WCResult.messageKey('INTERNAL_ERROR')
end

--- A server callback as §16 names it; anything that is not a Result becomes INTERNAL_ERROR.
local function await(name, ...)
    local ok, result = pcall(w.callback.await, name, false, ...)
    if not ok then
        WCDebug.warn('characters', '%s failed: %s', name, tostring(result))
        return WCResult.fail('INTERNAL_ERROR')
    end
    if not WCResult.is(result) then return WCResult.fail('INTERNAL_ERROR') end
    return result
end

local function pedExists(ped)
    -- BOOL natives answer 1 (not true) on this runtime: never compare them with == true
    return type(ped) == 'number' and ped ~= 0 and not not DoesEntityExist(ped)
end

-- characters:loaded answers after which the server may have loaded the character anyway (it
-- activates it and sends the spawn before it answers): a w_lib timeout, a lost reply.
local LOADED_UNCERTAIN = { INTERNAL_ERROR = true, TIMEOUT = true }
Sel.LOADED_HANDOFF_TIMEOUT = 15000 -- ms to wait for the spawn hand-off after an uncertain answer

local function spawnEvents()
    return (type(WCSpawn) == 'table' and type(WCSpawn.count) == 'function') and WCSpawn.count() or 0
end
local function handedOff(before)
    if spawnEvents() > before then return true end
    if type(WCSpawnSelector) == 'table' and type(WCSpawnSelector.active) == 'function' and WCSpawnSelector.active() then
        return true
    end
    return type(WCSpawn) == 'table' and type(WCSpawn.busy) == 'function' and WCSpawn.busy() == true
end

--- w_creators:characters:loaded, safe against an uncertain answer: the server activates the
--  character and hands the spawn off (selectSpawn / client:spawn) before it replies, so a timed-out
--  reply is not "not loaded". The spawn hand-off decides (the character was loaded: ok); without
--  it, one retry (a repeat after a real load answers NO_CHARACTER: loaded as well). Only a
--  certain refusal comes back as a failure.
---@return table Result
function Sel.awaitLoaded()
    local before = spawnEvents()
    local loaded = await('w_creators:characters:loaded')
    if loaded.ok or not LOADED_UNCERTAIN[loaded.code] then return loaded end
    WCDebug.warn('characters', 'characters:loaded answered %s: waiting for the spawn hand-off', tostring(loaded.code))
    if WCUtil.waitUntil(function() return handedOff(before) or nil end, Sel.LOADED_HANDOFF_TIMEOUT, 100) then
        return WCResult.ok({ uncertain = true })
    end
    local again = await('w_creators:characters:loaded')
    if again.ok then return again end
    if again.code == 'NO_CHARACTER' or handedOff(before) then return WCResult.ok({ uncertain = true }) end
    return again
end

local function takeLock()
    if st.ownsLock then return end
    st.ownsLock = WCState.busy('selection', true) == true
end

local function releaseLock()
    if st.ownsLock then WCState.busy('selection', false) end
    st.ownsLock = false
end

--- Hide the player in the room (frozen, invisible, invincible, not networked to others).
local function hidePlayer()
    local ped = PlayerPedId()
    if not pedExists(ped) then return end
    FreezeEntityPosition(ped, true)
    SetEntityInvincible(ped, true)
    SetEntityVisible(ped, false)
    NetworkSetEntityOnlyExistsForParticipants(ped, true)
end

--- Undo hidePlayer().
local function restorePlayer()
    local ped = PlayerPedId()
    if not pedExists(ped) then return end
    SetEntityVisible(ped, true)
    NetworkSetEntityOnlyExistsForParticipants(ped, false)
    SetEntityInvincible(ped, false)
    FreezeEntityPosition(ped, false)
end
Sel.hidePlayer, Sel.restorePlayer = hidePlayer, restorePlayer

--- Is the player still inside the creator room?
local function inRoom()
    local sc = Config.Scene or {}
    local x, y, z = CreatorScene.coords(sc.anchor)
    if not x then return false end
    local radius = tonumber(sc.cleanupRadius) or 25.0
    return #(GetEntityCoords(PlayerPedId()) - vector3(x, y, z)) < radius
end

-- ---------------------------------------------------------------------
--  The fade guard
--  vorp_core fades the screen out on playerSpawned and relies on vorp_character (replaced by this
--  resource) to fade it back in. While the selection scene is visible any fade that comes from
--  another resource is cancelled within FADE_GUARD_MS. Our own transitions clear sceneVisible first.
-- ---------------------------------------------------------------------
local function startFadeGuard()
    if st.guard then return end
    st.guard = true
    CreateThread(function()
        while st.sceneVisible do
            if IsScreenFadedOut() or IsScreenFadingOut() then
                DismissLoadingScreen()
                DoScreenFadeIn(0)
            end
            Wait(FADE_GUARD_MS)
        end
        st.guard = false
    end)
end

local function setVisible(visible)
    st.sceneVisible = visible == true
    if st.sceneVisible then startFadeGuard() end
end

-- ---------------------------------------------------------------------
--  The preview ped, the camera and the card
-- ---------------------------------------------------------------------

local function destroyPreview()
    if st.ped then CreatorScene.destroy(st.ped) end
    st.ped = nil
end

--- The appearance shown for a slot: the character's, or a default ped for an empty slot / a
--  character without a saved appearance.
local function previewApp(slot)
    local card = slot and slot.char
    if type(card) == 'table' and type(card.appearance) == 'table' then
        local app = AppearanceSchema.normalize(card.appearance)
        if type(app) == 'table' then return app end
    end
    local sex = (type(card) == 'table' and card.sex == 'female') and 'female' or 'male'
    return AppearanceSchema.default(sex)
end

--- The next preview ped is created (rendered and shown) before the previous one is destroyed, so
--  the screen never shows an empty room. On failure the current preview stays.
local function buildPreview(slot)
    local app = previewApp(slot)
    local nextPed, err = CreatorScene.create(nil, (Config.Scene or {}).selectionPed, app)
    if not nextPed then return false, err end
    local previous = st.ped
    st.ped = nextPed
    if previous and previous ~= nextPed then CreatorScene.destroy(previous) end
    CreatorScene.arm(nextPed, app.sex)
    CreatorScene.idle(nextPed, app.sex)
    return true
end

local function showCard(slot)
    local card = slot and not slot.empty and slot.char or nil
    pcall(WCEditor.showCard, card)
end

-- ---------------------------------------------------------------------
--  The prompts
-- ---------------------------------------------------------------------

local function destroyPrompts()
    local group = st.prompts
    st.prompts, st.deleteKey = nil, nil
    if group then
        pcall(group.hide)
        pcall(group.delete)
    end
end

local function canDelete()
    if not st.deletion.enabled then return false end
    for _, slot in ipairs(st.slots) do
        if not slot.empty then return true end
    end
    return false
end

local function currentTitle()
    local L = labels()
    local slot = st.slots[st.index]
    if not slot then return locale(L.title or 'اختيار الشخصية') end
    if slot.empty then
        return ('%s  (%d/%d)'):format(locale(L.emptySlot or 'خانة فارغة — إنشاء شخصية'), st.index, #st.slots)
    end
    local card = slot.char
    local name = (type(card.name) == 'string' and card.name ~= '') and card.name or tostring(card.charid)
    return ('%s  (%d/%d)'):format(name, st.index, #st.slots)
end

--- The title follows the shown slot; the delete prompt is hidden on an empty slot.
local function refreshPrompts()
    local group = st.prompts
    if not group then return end
    pcall(group.setTitle, currentTitle())
    if st.deleteKey then
        local slot = st.slots[st.index]
        pcall(group.setVisible, st.deleteKey, slot ~= nil and not slot.empty)
    end
end

local function buildPrompts()
    destroyPrompts()
    local K, L = keys(), labels()
    local group = w.prompt.createGroup(locale(L.title), cfg().promptPosition)
    group.addPrompt(K.select, locale(L.select), false)
    group.addPrompt(K.prev, locale(L.prev), false)
    group.addPrompt(K.next, locale(L.next), false)
    if canDelete() then
        group.addPrompt(K.delete, locale(L.delete), st.deletion.holdTime)
        st.deleteKey = K.delete
    end
    group.display()
    st.prompts = group
    -- without the barrier the key that opened the screen may register on its first frame
    st.inputReadyAt = GetGameTimer() + INPUT_BARRIER_MS
    refreshPrompts()
end

--- The retry prompt shown when the selection could not be opened (as before v3).
local function buildRetryPrompt()
    destroyPrompts()
    local ok, group = pcall(w.prompt.createGroup, locale(MSG_RETRY), cfg().promptPosition)
    if not ok or type(group) ~= 'table' then return end
    pcall(function()
        group.addPrompt(keys().select, locale(MSG_RETRY_LABEL), false)
        group.display()
    end)
    st.prompts = group
    st.inputReadyAt = GetGameTimer() + INPUT_BARRIER_MS
end

-- Another group displayed over ours (a w_lib walk-up prompt, a death prompt re-displayed by its
-- owner) hides it, and w_lib only reports completions of the visible group: ours is displayed
-- again (checked every PROMPT_REASSERT_MS), or the screen could never be left.
local PROMPT_REASSERT_MS = 250
local function reassertPrompts(group)
    local now = GetGameTimer()
    if st.promptCheckAt and now < st.promptCheckAt then return end
    st.promptCheckAt = now + PROMPT_REASSERT_MS
    local ok, visible = pcall(group.isVisible)
    if ok and visible == false then pcall(group.display) end
end

local function isCompleted(key)
    local group = st.prompts
    if not group or key == nil then return false end
    reassertPrompts(group)
    local ok, done = pcall(group.isCompleted, key)
    return ok and done == true
end

-- ---------------------------------------------------------------------
--  Slots
-- ---------------------------------------------------------------------

--- Show a slot (wraps around). Errors while the scene is not visible yet or when strict (a new
--  list: the preview on screen belongs to the old one, so the caller turns it into the retry
--  prompt); otherwise (browsing) a failure keeps the previous slot and notifies.
local function showSlot(index, strict)
    if #st.slots == 0 then return end
    local previous = st.index
    if st.sceneVisible then WCurtain.show('selection') end
    st.index = ((index - 1) % #st.slots) + 1
    local slot = st.slots[st.index]
    local ok, err = pcall(function()
        local built, code = buildPreview(slot)
        if not built then error('preview: ' .. tostring(code), 0) end
        if not WCCamera.open(st.ped, slot.empty and 'selection' or 'fullBody') then
            error('camera', 0)
        end
    end)
    if st.sceneVisible then WCurtain.hide() end
    if not ok then
        st.index = previous
        if strict or not st.sceneVisible then error(err, 0) end
        WCDebug.warn('characters', 'could not switch the preview: %s', tostring(err))
        notify(MSG_RETRY)
        return
    end
    showCard(slot)
    refreshPrompts()
end

--- characters:list → slots → the first slot → the prompts.
local function loadList()
    local result = await('w_creators:characters:list')
    if not result.ok then error({ key = messageOf(result) }, 0) end
    local data = type(result.data) == 'table' and result.data or {}
    local deletion = type(data.deletion) == 'table' and data.deletion or {}
    local defaults = Config.Characters.deletion or {}
    st.deletion = {
        enabled = deletion.enabled == true,
        holdTime = WCUtil.int(deletion.holdTime, 0, 60000, WCUtil.int(defaults.holdTime, 0, 60000, 5000)),
        typed = deletion.typed == true,
    }
    st.canCreate = data.canCreate == true

    local slots = {}
    for _, card in ipairs(type(data.characters) == 'table' and data.characters or {}) do
        if type(card) == 'table' and card.charid ~= nil then slots[#slots + 1] = { char = card } end
    end
    if st.canCreate then
        local total = WCUtil.int(data.slots, 0, 64, #slots)
        for _ = 1, math.max(0, total - #slots) do slots[#slots + 1] = { empty = true } end
    end
    -- never an empty screen: the creation slot answers with the server's reason when refused
    if #slots == 0 then slots[1] = { empty = true } end
    st.slots, st.index = slots, 1
    showSlot(1, true)
    buildPrompts()
end

-- ---------------------------------------------------------------------
--  Entering / leaving the selection state
-- ---------------------------------------------------------------------

local function enterScene()
    st.inSelection = true
    SetCustomHudVisible(false)
    -- the move before the collision wait (vorp_character's order), then stray peds of an
    -- earlier run are only in the pool once we are near them
    CreatorScene.load()
    CreatorScene.cleanup()
    hidePlayer()
    WCCamera.close()
end

--- Leave the selection screen. The room and the bucket stay (the creator uses the same room;
--  finish() releases them on the way to the world).
local function leaveSelection()
    st.inSelection = false
    st.failed = false
    setVisible(false)
    showCard(nil)
    destroyPreview()
    destroyPrompts()
    WCCamera.close()
end

--- The failure path: keep the player isolated and hidden, show the retry prompt.
local function showFailure(key)
    WCDebug.warn('characters', 'character selection failed: %s', tostring(key))
    destroyPreview()
    showCard(nil)
    WCCamera.close()
    st.inSelection = true
    st.failed = true
    st.retryOpts = { back = true } -- the retry fades out before it rebuilds the scene
    st.slots = {}
    hidePlayer()
    notify(type(key) == 'string' and key or MSG_RETRY)
    buildRetryPrompt()
    -- the retry never spawns an unselected character: only the screen comes back
    EndFade(300)
end

-- ---------------------------------------------------------------------
--  A resource restart whose selection the server refuses
--  The restarted server adopts every player whose framework character is still logged in (§9.1);
--  scene:prepare then starts a switch away from that character. The switch is refused while the
--  player is dead (BUSY), in a session (BUSY), after the 2-minute window with allowSwitch off
--  (SERVICE_DISABLED), and answers SESSION_NOT_FOUND while the adoption has not run yet (a
--  framework character that is not active yet is never "in the flow"). None of these is a failure:
--  the character is in play, so the player is left untouched in the world (never hidden, frozen or
--  held by the retry prompt) and the client state is refilled from the saved appearance.
-- ---------------------------------------------------------------------
local RESTART_IN_PLAY = { BUSY = true, SERVICE_DISABLED = true, SESSION_NOT_FOUND = true }
local RELOAD = 'w_creators:appearance:reload' -- §16: {appearance} of the active character (1 / 10 s)
local RESTART_RELOAD_STEP_MS = 10500   -- appearance:reload is rate limited to 1 / 10 s
local RESTART_RELOAD_TIMEOUT_MS = 180000 -- the adoption waits up to 120 s for the database

--- Fill WCState with the adopted character's saved look (no render: the ped kept its look over the
--  restart). A selection still pending on the adoption (SESSION_NOT_FOUND) is opened again once,
--  when the server knows the character: inside the restart window the switch is then allowed.
local function resumeInWorld(code, gen, reopen)
    CreateThread(function()
        local deadline = GetGameTimer() + RESTART_RELOAD_TIMEOUT_MS
        local adopted = type(WCState.appearance) == 'table'
        while not adopted do
            if gen ~= st.generation or st.inSelection then return end
            local result = await(RELOAD)
            local data = result.ok and type(result.data) == 'table' and result.data or nil
            if data and type(data.appearance) == 'table' then
                local app = AppearanceSchema.normalize(data.appearance)
                if gen ~= st.generation or st.inSelection then return end
                if type(app) == 'table' then
                    WCState.set(app)
                    if data.charid ~= nil then
                        WCState.setCharacter(tostring(data.charid), app.sex)
                    elseif not WCState.character then
                        -- the reload does not name the character; the flows only need to know one is
                        -- in play (W:CHARCREATION:starting is refused then)
                        WCState.character = { sex = app.sex }
                    end
                    adopted = true
                end
            end
            if not adopted then
                if GetGameTimer() >= deadline then
                    WCDebug.warn('characters', 'restart: the character in play could not be reloaded (%s)',
                        tostring(result.code))
                    return
                end
                Wait(RESTART_RELOAD_STEP_MS)
            end
        end
        WCDebug.log('characters', 'restart: the selection was refused (%s); the character stays in play',
            tostring(code))
        if reopen and code == 'SESSION_NOT_FOUND' and gen == st.generation and not st.inSelection then
            Sel.open({ restart = true, reopened = true })
        end
    end)
end

--- The opening (the caller holds st.busy).
--  opts.manual:  /characters mid-game — a refused switch leaves the player where he is.
--  opts.restart: the boot after a resource restart — a refusal because the adopted character is
--                in play leaves the player where he is as well (resumeInWorld).
--  opts.error:   a locale key shown once the screen is up (back from the creator).
local function openInternal(opts)
    opts = type(opts) == 'table' and opts or {}
    st.generation = st.generation + 1
    setVisible(false)
    if opts.manual or opts.back then StartFade(400, 'selection') else WCurtain.show('selection') end

    local isolated, code = CreatorScene.isolate()
    if not isolated and opts.restart and RESTART_IN_PLAY[code] then
        -- the character adopted after the resource restart stays in play: nothing was changed
        EndFade(300)
        resumeInWorld(code, st.generation, not opts.reopened)
        return false, code
    end
    if not isolated and opts.manual then
        -- SERVICE_DISABLED / BUSY: the server refused the switch; nothing was changed
        EndFade(300)
        notify(WCResult.messageKey(code or 'INTERNAL_ERROR'))
        return false, code
    end
    takeLock()
    if isolated and opts.manual then WCState.clear() end -- the server cleared the active character

    local ok, err = pcall(function()
        destroyPreview()
        destroyPrompts()
        st.failed = false
        if not isolated then error({ key = WCResult.messageKey(code or 'INTERNAL_ERROR') }, 0) end
        enterScene()
        loadList()
    end)
    if not ok then
        local key = type(err) == 'table' and err.key or MSG_RETRY
        if type(err) ~= 'table' then WCDebug.warn('characters', 'selection error: %s', tostring(err)) end
        showFailure(key)
        return false, 'INTERNAL_ERROR'
    end
    EndFade(500)
    setVisible(true)
    if opts.error then notify(opts.error) end
    return true
end

-- ---------------------------------------------------------------------
--  Actions
-- ---------------------------------------------------------------------

--- Run an action in its own thread (the input loop keeps drawing the room); st.busy blocks
--  every other action until it ends.
local function action(fn)
    st.busy = true
    CreateThread(function()
        local ok, err = pcall(fn)
        if not ok then WCDebug.warn('characters', 'selection action failed: %s', tostring(err)) end
        st.busy = false
    end)
end

--- The creator did not start: reopen the selection unless the creator already handed the room
--  back (WCSelector.back reopened it: every refusal after the creator took the room does that).
local function reopenAfterCreator(code)
    if st.inSelection or st.busy then return end
    if type(WCCreator) == 'table' and WCCreator.active() then return end
    st.busy = true
    openInternal({ error = WCResult.messageKey(code or 'INTERNAL_ERROR') })
end

--- An empty slot: hand the room over to the creator.
local function startCreation()
    WCDebug.log('characters', 'empty slot: character creation')
    leaveSelection()
    releaseLock()
    st.busy = false -- the creator may come straight back (WCSelector.back)
    if type(WCCreator) ~= 'table' then
        st.busy = true
        return openInternal({ error = MSG_RETRY })
    end
    local started, code = WCCreator.start({})
    if not started then reopenAfterCreator(code) end
end

--- Select → render on the player → loaded (only after the render succeeded).
local function play(card)
    setVisible(false)
    StartFade(300, 'spawn')
    local result = await('w_creators:characters:select', tostring(card.charid))
    if not result.ok then
        notify(messageOf(result))
        EndFade(300)
        setVisible(true)
        refreshPrompts()
        return
    end
    local data = type(result.data) == 'table' and result.data or {}

    if data.needsAppearance then
        -- no saved appearance (a creation whose save failed): the creator, appearance only
        leaveSelection()
        releaseLock()
        st.busy = false
        local started, code = WCCreator.start({ repair = {
            token = data.token, sex = data.sex or card.sex, charid = card.charid, appearance = card.appearance,
            -- shown read-only by the creator (the framework identity is kept)
            identity = { firstname = card.firstname, lastname = card.lastname, dob = card.dob },
        } })
        if not started then reopenAfterCreator(code) end
        return
    end

    local app = AppearanceSchema.normalize(data.appearance)
    WCState.setCharacter(tostring(card.charid), app.sex)
    WCState.set(app)
    local rendered, err = Appearance.SetPlayerModel(app.sex)
    if rendered then rendered, err = Appearance.RestorePlayer(app) end
    if not rendered then
        WCDebug.warn('characters', 'the selected appearance could not be rendered: %s', tostring(err))
        WCState.clear()
        hidePlayer() -- a model change made a new player ped
        notify(MSG_RENDER)
        EndFade(300)
        setVisible(true)
        refreshPrompts()
        return
    end

    leaveSelection()
    restorePlayer()
    local loaded = Sel.awaitLoaded()
    if not loaded.ok then
        WCState.clear()
        notify(messageOf(loaded))
        openInternal({})
        return
    end
    Sel.finish(type(loaded.data) == 'table' and loaded.data.spawn or nil)
end

--- Long press → confirmation (→ the typed full name) → characters:delete → the list again.
local function deleteCharacter(card)
    local L = labels()
    local name = (type(card.name) == 'string' and card.name ~= '') and card.name or tostring(card.charid)
    local okDialog, answer = pcall(w.alertDialog, {
        header = locale(L.deleteHeader),
        content = locale(L.deleteBody, name),
        centered = true,
        cancel = true,
    })
    if not okDialog or answer ~= 'confirm' then
        refreshPrompts()
        return
    end
    local typed
    if st.deletion.typed then
        local okInput, input = pcall(w.inputDialog, locale(L.deleteHeader), {
            { type = 'input', label = locale(MSG_TYPE_NAME), placeholder = name, required = true },
        }, { allowCancel = true })
        typed = okInput and type(input) == 'table' and input[1] or nil
        if type(typed) ~= 'string' or WCUtil.trim(typed) == '' then
            refreshPrompts()
            return
        end
    end
    local result = await('w_creators:characters:delete', tostring(card.charid), typed)
    if not result.ok then
        notify(messageOf(result))
        refreshPrompts()
        return
    end
    notify(MSG_DELETED, 'success')
    local ok, err = pcall(loadList)
    if not ok then showFailure(type(err) == 'table' and err.key or MSG_RETRY) end
end

local function drainInput()
    if not st.prompts then return end
    local K = keys()
    for _, key in ipairs({ K.select, K.prev, K.next, st.deleteKey }) do isCompleted(key) end
end

local function handleInput()
    local K = keys()
    if st.failed then
        if isCompleted(K.select) then
            local opts = st.retryOpts
            action(function() openInternal(opts) end)
        end
        return
    end
    local slot = st.slots[st.index]
    if not slot then return end
    if isCompleted(K.prev) then
        action(function() showSlot(st.index - 1) end)
    elseif isCompleted(K.next) then
        action(function() showSlot(st.index + 1) end)
    elseif isCompleted(K.select) then
        if slot.empty then action(startCreation) else action(function() play(slot.char) end) end
    elseif st.deleteKey and not slot.empty and isCompleted(K.delete) then
        action(function() deleteCharacter(slot.char) end)
    end
end

-- The selection loop: controls off, HUD muted and the room lit every frame while the screen is
-- up; idle (4 Hz) otherwise.
CreateThread(function()
    while true do
        if st.inSelection and st.prompts and (#st.slots > 0 or st.failed) then
            DisableAllControlActions(0)
            SuppressGameHud()
            CreatorScene.drawLights()
            CreatorScene.suppressAmbient()
            if not st.busy and GetGameTimer() >= st.inputReadyAt then
                handleInput()
            else
                drainInput() -- a key pressed while an action runs is dropped, never queued
            end
            Wait(0)
        else
            Wait(250)
        end
    end
end)

-- ---------------------------------------------------------------------
--  Public API
-- ---------------------------------------------------------------------

--- Open the selection screen. Returns true | false, code ('BUSY' while another open, an action
--  or the creator runs).
function Sel.open(opts)
    if st.busy then return false, 'BUSY' end
    if type(WCCreator) == 'table' and WCCreator.active() then return false, 'BUSY' end
    st.busy = true
    local ok, a, b = pcall(openInternal, opts)
    st.busy = false
    if not ok then
        WCDebug.warn('characters', 'opening the selection failed: %s', tostring(a))
        return false, 'INTERNAL_ERROR'
    end
    return a, b
end

--- Back to the selection from the creator (error: a locale key shown on arrival).
function Sel.back(errorKey)
    return Sel.open({ back = true, error = errorKey })
end

--- Leave the selection screen without entering the world (another flow takes the room).
function Sel.leave()
    leaveSelection()
    releaseLock()
end

--- The character is loaded: release the room for the spawn (the server moves the bucket on the
--  spawn choice) and unload the room maps once the player has left it. spawnMode is the
--  characters:loaded answer ('selector' | 'direct' | 'event').
function Sel.finish(spawnMode)
    st.generation = st.generation + 1
    local gen = st.generation
    releaseLock()
    CreatorScene.release({ keepBucket = true })
    if spawnMode == 'event' then
        -- a framework spawn event (Config.Creator.spawnEvent) owns the next screen; the server
        -- already put the player in bucket 0; the HUD comes back now and the screen is faded in
        -- if that event does not do it
        if CreatorScene.forgetIsolation then CreatorScene.forgetIsolation() end
        -- the selection / creator loops muted the radar and the native HUD every frame; every other
        -- exit gets them back through WCSpawn's restoreUi (w_creators:client:spawn never comes here)
        pcall(SetWorldUiVisible, true)
        pcall(w.setRadarVisible, true)
        pcall(DisplayHud, true)
        CreateThread(function()
            local shown = WCUtil.waitUntil(function()
                if gen ~= st.generation then return true end
                return (not IsScreenFadedOut() and not IsScreenFadingOut()) or nil
            end, EVENT_FADE_TIMEOUT, 250)
            if gen ~= st.generation then return end
            if shown then WCurtain.restore() else EndFade(500) end
        end)
    end
    -- the final exit: the maps are unloaded (and a bucket still held released) once the player
    -- stands outside the room and the spawn flow is over. No deadline: a player idling in the
    -- spawn selector for a long time must still get the isolation flag cleared when he leaves
    -- (it would otherwise block every service); only a new selection generation ends the wait.
    CreateThread(function()
        while gen == st.generation do
            local left = WCUtil.waitUntil(function()
                if gen ~= st.generation then return true end
                return (not inRoom() and not WCState.busy('spawn')) or nil
            end, FINAL_EXIT_TIMEOUT, FINAL_EXIT_STEP)
            if gen ~= st.generation then return end
            if left and not inRoom() then
                CreatorScene.release({ unload = true })
                WCDebug.log('characters', 'creator room unloaded')
                return
            end
        end
    end)
end

--- Is the selection screen up (or its retry prompt)?
function Sel.active() return st.inSelection end

--- Is an open or an action running?
function Sel.busy() return st.busy end

-- The death system's own down state (WCSpawn.DEATH_OWNER): dead or in last stand while the ped
-- is alive (hospital bed heal timer, a dead character logging in). The server checks it as well.
local function deathOwnerSaysDead()
    local owner = type(WCSpawn) == 'table' and WCSpawn.DEATH_OWNER or nil
    if type(owner) ~= 'table' or type(owner.resource) ~= 'string' or type(owner.isDead) ~= 'string' then
        return false
    end
    local okState, state = pcall(GetResourceState, owner.resource)
    if not okState or state ~= 'started' then return false end
    local done, dead = pcall(function() return exports[owner.resource][owner.isDead]() end)
    return done and dead ~= nil and dead ~= false
end

--- May the player open the selection mid-game? true | false, localeKey. The server validates
--  again (scene:prepare → WCCharacters.beginSwitch).
function Sel.canSwitch()
    if Config.Characters.allowSwitch ~= true then return false, WCResult.messageKey('SERVICE_DISABLED') end
    local ped = PlayerPedId()
    if IsEntityDead(ped) or WCState.busy('respawn') or deathOwnerSaysDead() then return false, MSG_SWITCH_REFUSED end
    if WCState.inEditor() or WCEditor.isOpen() or (type(WCPanel) == 'table' and WCPanel.isOpen()) then
        return false, MSG_SWITCH_REFUSED
    end
    if st.busy or st.inSelection or WCState.busy('selection') or WCState.busy('spawn')
        or WCState.busy('clothingAction') or (type(WCCreator) == 'table' and WCCreator.active()) then
        return false, MSG_SWITCH_REFUSED
    end
    -- a store / wardrobe / barber / surgery visit, from its opening phase to the walk back
    if WCState.busy('service') or (type(WCPreviewEnv) == 'table' and WCPreviewEnv.active()) then
        return false, MSG_SWITCH_REFUSED
    end
    -- the first-spawn ride and the spawn selector / respawn flow own the player until they end
    -- (the spawn selector takes no WCState lock)
    if (type(WCCutscene) == 'table' and WCCutscene.active())
        or (type(WCSpawnSelector) == 'table' and WCSpawnSelector.active())
        or (type(WCSpawn) == 'table' and type(WCSpawn.busy) == 'function' and WCSpawn.busy()) then
        return false, MSG_SWITCH_REFUSED
    end
    return true
end

-- ---------------------------------------------------------------------
--  Language switch: prompt labels, title and card re-applied in place
-- ---------------------------------------------------------------------
OnLanguageChange(function()
    if not st.inSelection or not st.prompts then return end
    if st.failed then
        buildRetryPrompt()
        return
    end
    local K, L = keys(), labels()
    local group = st.prompts
    pcall(function()
        group.setLabel(K.select, locale(L.select))
        group.setLabel(K.prev, locale(L.prev))
        group.setLabel(K.next, locale(L.next))
        if st.deleteKey then group.setLabel(st.deleteKey, locale(L.delete)) end
    end)
    refreshPrompts()
    showCard(st.slots[st.index])
end)

-- ---------------------------------------------------------------------
--  Boot
--  Measured once at load, before any Wait: on a first login the script loads during the
--  connection (no session, no placed ped); on a resource restart the player is in the world.
-- ---------------------------------------------------------------------
local bootedInSession = NetworkIsSessionStarted()
    and DoesEntityExist(PlayerPedId())
    and #(GetEntityCoords(PlayerPedId())) > 1.0

-- spawnmanager fires playerSpawned once, at the first spawn (never again on a restart).
local spawnFired = false
local spawnedAt = 0
AddEventHandler('playerSpawned', function()
    if not spawnFired then spawnedAt = GetGameTimer() end
    spawnFired = true
end)

local function pedPlaced()
    local ped = PlayerPedId()
    return (ped ~= 0 and ped ~= -1 and DoesEntityExist(ped) and #(GetEntityCoords(ped)) > 1.0) or nil
end

CreateThread(function()
    -- 1) the session: an open wait (a heavy server may take long before the session starts)
    while not NetworkIsSessionStarted() do Wait(SESSION_WAIT_STEP) end
    -- 2) the ped handle is valid before the player exists in the world: wait for real coords
    if not WCUtil.waitUntil(pedPlaced, PED_WAIT_MS, SESSION_WAIT_STEP) then
        WCDebug.warn('characters', 'the player ped wait timed out; opening the selection anyway')
    end
    -- 3) first login: vorp_core's playerSpawned handler fades the screen out; opening before it
    --    would leave its fade over our scene. Stock RSG-Core / QBR-Core do not fire playerSpawned
    --    before character selection, so skip the 20 s wait there.
    local stockRsgOrQbr = type(GetResourceState) == 'function'
        and GetResourceState('vorp_core') ~= 'started'
        and GetResourceState('w_core') ~= 'started'
        and (GetResourceState('rsg-core') == 'started' or GetResourceState('qbr-core') == 'started')
    if not bootedInSession and not stockRsgOrQbr then
        if WCUtil.waitUntil(function() return spawnFired or nil end, SPAWN_EVENT_WAIT_MS, 50) then
            WCUtil.waitUntil(function() return (IsScreenFadingOut() or IsScreenFadedOut()) or nil end,
                OTHER_FADE_WAIT_MS, 0)
            WCUtil.waitUntil(function() return GetGameTimer() >= spawnedAt + OTHER_FADE_WAIT_MS or nil end,
                OTHER_FADE_WAIT_MS, 50)
        else
            WCDebug.warn('characters', 'playerSpawned never arrived; opening the selection without it')
        end
    end
    -- the curtain goes up before the loading screen is dropped: the player goes from the loading
    -- screen to the loading card to the selection, never through the unloaded world
    StartFade(0, 'preparing')
    DismissLoadingScreen()
    WCDebug.log('characters', 'opening the character selection')
    -- after a resource restart the adopted character may be in play (dead, in a session, the
    -- switch window over): a refusal then leaves the player in the world (resumeInWorld)
    Sel.open({ restart = bootedInSession })
end)

-- ---------------------------------------------------------------------
--  Events, command, cleanup
-- ---------------------------------------------------------------------

--- Back from the creator (kept local event name).
AddEventHandler('w_creators:client:backToSelection', function(errorKey)
    CreateThread(function() Sel.back(type(errorKey) == 'string' and errorKey or nil) end)
end)

-- Character switch mid-game (§9.1). The old /starting command is gone (audit A1).
if Config.Characters.allowSwitch == true then
    RegisterCommand('characters', function()
        local allowed, key = Sel.canSwitch()
        if not allowed then
            notify(key)
            return
        end
        CreateThread(function() Sel.open({ manual = true }) end)
    end, false)
end

AddEventHandler('onResourceStop', function(resource)
    if resource ~= GetCurrentResourceName() then return end
    local held = st.inSelection or st.ownsLock or st.ped ~= nil
    st.generation = st.generation + 1
    st.sceneVisible = false
    pcall(destroyPrompts)
    if st.ped then pcall(CreatorScene.destroy, st.ped) end
    st.ped = nil
    pcall(WCEditor.showCard, nil)
    if held then
        pcall(WCCamera.close)
        pcall(restorePlayer)
        pcall(SetCustomHudVisible, true)
    end
    st.inSelection, st.failed = false, false
    releaseLock()
end)
