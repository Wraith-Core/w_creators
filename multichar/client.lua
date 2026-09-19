-- =====================================================================
--  multichar/client.lua
--  The character selection screen in the VORP manner: a live preview ped with the character's appearance,
--  a camera pinned on it, and a library prompt group (w.prompt.createGroup) for the keys.
--
--  Why the library prompt and not the native prompt: RDR's native prompts pass through
--  CreateVarString/LITERAL_STRING and do not support Arabic (it shows mangled or empty).
--  The library draws the prompt cards in its own interface so Arabic and RTL work in full, and it
--  reads the raw keys itself: this file only asks the group whether a key completed.
-- =====================================================================

if not Config.Multicharacter then return end

local previewPed = nil
local inSelection = false
local slots = {}        -- { {char=...} | {empty=true} }
local slotIndex = 1
local canDelete = false
local busy = false      -- it stops two actions running in the same frame
local inputReadyAt = 0  -- we accept no presses before this time (the entry barrier)
local sceneVisible = false -- the scene really appeared: any fade after this moment is a mistake
local selectionFailed = false
local startSelection

-- Was the player already inside the game at the moment this script loaded?
--   a first login   -> the script loads during the connection, so there is no session and no ped with coordinates.
--   a restart       -> the player is already in the world, so all three are satisfied.
-- It is measured once at load time before any Wait, otherwise it loses its distinguishing value.
local bootedInSession = NetworkIsSessionStarted()
    and DoesEntityExist(PlayerPedId())
    and #(GetEntityCoords(PlayerPedId())) > 1.0

-- playerSpawned is fired by spawnmanager once at the first spawn. It is not fired again
-- when the resource restarts, so we only wait for it on the first-login path.
local spawnFired = false
AddEventHandler('playerSpawned', function() spawnFired = true end)

local promptGroup = nil  -- the w.prompt.createGroup handle
local deletePrompt = nil

-- ---------------------------------------------------------------------
--  The preview ped
-- ---------------------------------------------------------------------

local function destroyPreviewPed()
    if previewPed and ForgetOverlays then ForgetOverlays(previewPed) end
    DeletePedHard(previewPed) -- one call may not be enough (the same approach as vorp_character)
    previewPed = nil
end

--- Creating the preview ped and applying the character's appearance to it.
--  The same order as applyCharacterAppearance in creator/client.lua:
--  the clothes first then the face features then the layers.
local function buildPreviewPed(char)
    local app = CreatorAppearance.normalize(char and char.appearance or {
        isMale=true, components=CreatorAppearance.default('male')
    })
    local isMale = app.isMale
    -- Preserve the current preview if the next character fails to stream.
    local nextPed = CreatorScene.create(isMale and 'mp_male' or 'mp_female', Config.SelectionPed, app)
    destroyPreviewPed()
    previewPed = nextPed
    ArmScenePed(previewPed, isMale)
    PlaySceneIdle(previewPed, isMale)
end

-- ---------------------------------------------------------------------
--  The prompts (NUI - they support Arabic)
-- ---------------------------------------------------------------------

local function destroyPrompts()
    if promptGroup then
        pcall(promptGroup.hide)
        pcall(promptGroup.delete)
    end
    promptGroup = nil
    deletePrompt = nil
end

local function buildPrompts()
    destroyPrompts()
    local K = Config.SelectionKeys
    local L = Config.SelectionLabels

    promptGroup = w.prompt.createGroup(locale(L.title), Config.SelectionPromptPosition)
    promptGroup.addPrompt(K.select, locale(L.select), false)
    promptGroup.addPrompt(K.prev, locale(L.prev), false)
    promptGroup.addPrompt(K.next, locale(L.next), false)
    if canDelete then
        promptGroup.addPrompt(K.delete, locale(L.delete), Config.DeleteHoldTime)
        deletePrompt = K.delete
    end
    promptGroup.display()

    -- A half-second barrier: without it ENTER (or any key) may register on the first frame after
    -- the panel appears so it jumps straight to creating a character without the player seeing the screen.
    inputReadyAt = GetGameTimer() + 500
end

--- The group's title = the displayed character's name (as VORP does).
local function currentTitle()
    local slot = slots[slotIndex]
    if not slot then return locale(Config.SelectionLabels.title) end
    if slot.empty then
        return ('%s  (%d/%d)'):format(locale(Config.SelectionLabels.emptySlot), slotIndex, #slots)
    end
    local name = (slot.char.name ~= '' and slot.char.name) or slot.char.charid
    return ('%s  (%d/%d)'):format(name, slotIndex, #slots)
end

--- Updating the title and hiding the delete button on an empty slot.
local function refreshPrompts()
    if not promptGroup then return end
    promptGroup.setTitle(currentTitle())
    if deletePrompt then
        local slot = slots[slotIndex]
        promptGroup.setVisible(deletePrompt, slot ~= nil and not slot.empty)
    end
end

-- ---------------------------------------------------------------------
--  The actions
-- ---------------------------------------------------------------------

local openSelection -- a forward declaration

local function setSelectionZoom(zoomed)
    assert(MoveCreatorCam(zoomed and 'default' or 'selection', previewPed, true),
        'could not frame the character selection preview')
end

--- The character's info card on the right of the screen (the w_creators interface).
--  Display only with no interaction, so we ask for no SetNuiFocus and block no prompt keys.
--  It sends its labels with it: receivedata (the source of the interface's texts) is only sent from
--  the editor's scene, so if the player went straight into the characters screen the labels would stay
--  on their Arabic defaults whatever the server's language was.
local function sendCharacterCard(slot)
    if not slot or slot.empty or not slot.char then
        SendNUIMessage({ type = 'charCard', show = false })
        return
    end

    local c = slot.char
    SendNUIMessage({
        type = 'charCard',
        show   = true,
        -- The card may come before receivedata, so it carries the direction with it as it carries its strings
        locale = UiLocale(),
        dir    = UiDir(),
        name   = (c.name ~= nil and c.name ~= '') and c.name or tostring(c.charid),
        cash   = c.cash or 0,
        bank   = c.bank or 0,
        gold   = c.gold or 0,
        -- The job's name itself goes through the dictionary: with a key it is translated, otherwise it comes back as it is
        job    = (c.job and c.job ~= '') and locale(c.job) or locale('بلا وظيفة'),
        strings = UiStrings(),
    })
end

--- The language switch: the prompt labels, the title and the card are re-applied in place.
OnLanguageChange(function()
    if not inSelection then return end
    if promptGroup then
        local K = Config.SelectionKeys
        local L = Config.SelectionLabels
        pcall(function()
            promptGroup.setLabel(K.select, locale(L.select))
            promptGroup.setLabel(K.prev, locale(L.prev))
            promptGroup.setLabel(K.next, locale(L.next))
            if deletePrompt then
                promptGroup.setLabel(deletePrompt, locale(L.delete))
            end
        end)
        refreshPrompts()
    end
    sendCharacterCard(slots[slotIndex])
end)

local function showSlot(index)
    if #slots == 0 then return end
    local previousIndex, wasBusy = slotIndex, busy
    busy = true
    if sceneVisible then WCurtain.show('selection') end
    slotIndex = ((index - 1) % #slots) + 1
    local slot = slots[slotIndex]
    local ok, err = pcall(function()
        buildPreviewPed(not slot.empty and slot.char or nil)
        setSelectionZoom(not slot.empty)
    end)
    busy = wasBusy
    if sceneVisible then WCurtain.hide() end
    if not ok then
        slotIndex = previousIndex
        if not sceneVisible then error(err, 0) end
        w.print.error('could not switch the preview: %s', err)
        w.notify({description=locale('تعذر عرض الشخصية. أعد المحاولة'),type='error'})
        return
    end
    sendCharacterCard(slot)
    refreshPrompts()
end

-- ---------------------------------------------------------------------
--  The camera and the selection state
-- ---------------------------------------------------------------------

local function enterSelectionState()
    inSelection = true
    SetCustomHudVisible(false) -- no HUD during the character selection

    -- A world of the player's own: he sees nobody and nobody sees him during the selection
    CreatorScene.isolate()

    -- Loading the room + moving the player + waiting for the collision (in vorp_character's order:
    -- the move before waiting for the collision, otherwise the collision is checked around the old position)
    LoadCreatorScene()

    -- The cleanup after the move: stuck peds only appear in the pool when
    -- we are really near them (preview peds that survive a restart)
    CleanupScenePeds()

    local ped = PlayerPedId()
    FreezeEntityPosition(ped, true)
    SetEntityInvincible(ped, true)
    SetEntityVisible(ped, false, false)
    NetworkSetEntityOnlyExistsForParticipants(ped, true)

    DestroyCreatorCams()
    -- Keep the curtain until showSlot has rendered the actor and aimed its camera.
    sceneVisible = false
end

local function leaveSelectionState()
    inSelection = false
    sceneVisible = false
    SendNUIMessage({ type = 'charCard', show = false })
    ClearFocus() -- returning the loading focus to the player (the creator sets its own focus)
    -- We do not remove the maps here: the natural transition from the selection is to the creator
    -- and it uses the same room, and removing them then requesting them again makes the scene blink.
    -- The creator takes care of RemoveImap on its final exit.
    destroyPreviewPed()
    destroyPrompts()
    DestroyCreatorCams()
end

local function startCreation()
    w.print.debug('an empty slot -> starting a character creation')
    WCurtain.show('creator')
    leaveSelectionState()
    TriggerEvent("W:CHARCREATION:starting")
end

local function playCharacter(charid)
    WCurtain.show('spawn')
    leaveSelectionState()
    local ped = PlayerPedId()
    SetEntityVisible(ped, true, false)
    NetworkSetEntityOnlyExistsForParticipants(ped, false)
    SetEntityInvincible(ped, false)
    FreezeEntityPosition(ped, false)
    DoScreenFadeOut(300)
    Wait(350)
    TriggerServerEvent('w_creators:server:selectCharacter', charid)
end

local function deleteCharacter(char)
    local name = (char.name ~= '' and char.name) or char.charid
    local confirm = w.alertDialog({
        header = locale(Config.SelectionLabels.deleteHeader),
        content = locale(Config.SelectionLabels.deleteBody, name),
        centered = true,
        cancel = true,
    })
    if confirm == 'confirm' then
        TriggerServerEvent('w_creators:server:deleteCharacter', char.charid)
        Wait(400)
        openSelection()
    else
        refreshPrompts()
    end
end

-- ---------------------------------------------------------------------
--  The selection loop
-- ---------------------------------------------------------------------

openSelection = function()
    local data = w.callback.await('w_creators:getCharacters', false)
    if not data then
        w.print.error("the characters' data did not arrive from the server")
        error('the characters data did not arrive from the server')
    end

    canDelete = data.canDelete and #data.characters > 0
    slots = {}
    for _, char in ipairs(data.characters) do
        slots[#slots + 1] = { char = char }
    end
    for _ = 1, math.max(0, (data.slots or 1) - #data.characters) do
        slots[#slots + 1] = { empty = true }
    end
    if #slots == 0 then slots[1] = { empty = true } end

    showSlot(1)
    buildPrompts()
    refreshPrompts()
end

CreateThread(function()
    local K = Config.SelectionKeys
    while true do
        if inSelection and promptGroup and (#slots > 0 or selectionFailed) then
            DisableAllControlActions(0)
            SuppressGameHud()
            DrawCreatorSceneLights() -- the room is interior and dark without them

            if not busy and GetGameTimer() >= inputReadyAt then
                local slot = slots[slotIndex]

                if selectionFailed then
                    if promptGroup.isCompleted(K.select) then startSelection() end
                elseif promptGroup.isCompleted(K.prev) then
                    showSlot(slotIndex - 1)
                elseif promptGroup.isCompleted(K.next) then
                    showSlot(slotIndex + 1)
                elseif promptGroup.isCompleted(K.select) then
                    busy = true
                    if slot.empty then
                        startCreation()
                    else
                        playCharacter(slot.char.charid)
                    end
                    busy = false
                elseif canDelete and not slot.empty
                    and promptGroup.isCompleted(K.delete) then
                    busy = true
                    deleteCharacter(slot.char)
                    busy = false
                end
            end
            Wait(0)
        else
            Wait(250)
        end
    end
end)

-- ---------------------------------------------------------------------
--  The entry point
--  It works automatically in both cases: when the player joins, and when the resource restarts
--  (the client scripts are re-executed on a restart so this thread runs again).
-- ---------------------------------------------------------------------

--- The single opening point - the automatic boot and the manual /characters command both call it.
startSelection = function()
    if busy then return end
    busy, sceneVisible = true, false
    WCurtain.show('selection')
    local ok, err = pcall(function()
        destroyPreviewPed()
        destroyPrompts()
        selectionFailed = false
        enterSelectionState()
        openSelection()
    end)
    busy = false
    if not ok then
        w.print.error('character selection failed: %s', err)
        destroyPreviewPed()
        destroyPrompts()
        w.notify({description=locale('تعذر عرض الشخصية. أعد المحاولة'),type='error'})
        selectionFailed = true
        promptGroup = w.prompt.createGroup(locale('تعذر عرض الشخصية. أعد المحاولة'), Config.SelectionPromptPosition)
        promptGroup.addPrompt(Config.SelectionKeys.select, locale('إعادة المحاولة'), false)
        promptGroup.display()
        inputReadyAt = GetGameTimer() + 500
        -- Keep the player isolated; retry never spawns an unselected character.
        EndFade(300)
        return
    end
    EndFade(500)
    sceneVisible = true
end

-- ---------------------------------------------------------------------
--  The fade guard
--  vorp_core listens for playerSpawned so it runs DoScreenFadeOut(0) and shows the RDR
--  loading screen (spawnplayer.lua:51-67), then relies on vorp_character to restore
--  the view through vorp:initCharacter - and that is the disabled resource w_creators
--  replaced, so nobody fires that event and nobody restores the view.
--  On a first login its fade happens after our own EndFade (spawnmanager spawns the player
--  late) so the screen stays black under the waiting screen forever - and that is why
--  the player had to restart the resource to get in.
--  The guard voids this whole class of faults: as long as we are in a visible scene, any fade
--  coming from another resource is cancelled within a quarter second.
-- ---------------------------------------------------------------------
CreateThread(function()
    while true do
        if sceneVisible and (IsScreenFadedOut() or IsScreenFadingOut()) then
            DismissLoadingScreen()
            DoScreenFadeIn(0)
        end
        Wait(250)
    end
end)

CreateThread(function()
    -- 1) The session: an open wait, not a short timeout.
    --    The old timeout started from the moment the script loaded - that is, during the connection -
    --    and a heavy server may take more than thirty seconds before the session even begins,
    --    so the counter runs out and the thread goes on to open the screen for a player who does not exist yet.
    while not NetworkIsSessionStarted() do Wait(100) end

    -- 2) The readiness timeout starts here: after the session exists, not before it.
    --    The ped's id becomes valid before the player really exists in the world; a move
    --    at that moment fails silently. We wait for real coordinates (not the origin).
    local deadline = GetGameTimer() + 30000
    while GetGameTimer() < deadline do
        local ped = PlayerPedId()
        if ped ~= 0 and ped ~= -1 and DoesEntityExist(ped)
            and #(GetEntityCoords(ped)) > 1.0 then
            break
        end
        Wait(100)
    end

    if PlayerPedId() == 0 or PlayerPedId() == -1 then
        w.print.warn('the wait for the ped timed out - we go on and open the selection screen')
    end

    -- 3) We wait for playerSpawned before opening the screen - an ordering, not a decoration.
    --    vorp_core's handler for that event fades the screen out and shows the RDR loading screen, and nothing
    --    after it restores the view. So had we opened before it, its fade would land over our scene.
    --    We wait for it to happen first, then drop its screen and show ours last of all.
    --    On a resource restart the event has already happened before we registered, so we do not wait for it.
    if not bootedInSession then
        local spawnDeadline = GetGameTimer() + 20000
        while not spawnFired and GetGameTimer() < spawnDeadline do Wait(50) end
        if spawnFired then
            -- The synchronous part of vorp_core's handler (the fade + the loading screen +
            -- vorp:playerSpawn) finishes before its first Wait. Half a second is enough for it,
            -- and it guarantees our bucket isolation arrives after its own so it does not cancel it.
            Wait(500)
        else
            w.print.warn('playerSpawned never arrived - we go on without it')
        end
    end

    -- The order is deliberate: we darken the screen first then drop the loading screen.
    -- The reverse exposes the unloaded world for a moment between the two.
    -- And the drop is unconditional: it stays above everything until it is closed, so if anything stumbles after
    -- this point the player sees the game and not a silent blackness.
    -- The curtain goes up BEFORE the loading screen is dropped: the player goes from the
    -- loading screen to the loading card to the selection scene, and never sees the world.
    WCurtain.show('preparing')
    DoScreenFadeOut(0)
    Wait(200)
    DismissLoadingScreen()

    w.print.debug('opening the character selection screen')
    startSelection() -- it ends with EndFade so it shows the scene once its loading is complete
end)

AddEventHandler('onResourceStop', function(resource)
    if resource == GetCurrentResourceName() then
        if inSelection then leaveSelectionState() end
    end
end)

--- Going back from the creator to the characters screen.
--  creator/client.lua fires it when the player presses 'back' in the gender selection.
AddEventHandler('w_creators:client:backToSelection', function()
    StartFade(400, 'selection')
    startSelection()
    EndFade(400)
end)

-- A manual command to reopen the selection screen (the same path as the automatic boot)
RegisterCommand('characters', function()
    DismissLoadingScreen()
    startSelection()
end, false)
