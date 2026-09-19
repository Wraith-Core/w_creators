-- =====================================================================
--  creator.lua
--  The character creation scene's logic: the state machine, creating the characters, the NUI replies,
--  and saving/applying the appearance. It relies on natives.lua and appearance.lua and camera.lua.
-- =====================================================================

local pedHandle = nil
local appearanceOnly = false   -- true: an existing character without a saved look (repair path)

--- The current customisation ped.
--  pedHandle is local to this file: the other files in the resource see an empty
--  global rather than the real value. This function is the only way to it.
function GetCreatorPed()
    if WCEditor and WCEditor.session then return WCEditor.session.ped end
    if pedHandle and pedHandle ~= 0 and DoesEntityExist(pedHandle) then
        return pedHandle
    end
    -- A fallback: the chosen gender's ped before the customisation begins
    if gPeds and gPedsSelectedPedIndex then
        local p = gPeds[gPedsSelectedPedIndex]
        if p and p ~= 0 and DoesEntityExist(p) then return p end
    end
    return nil
end

State = {
    NONE = 0,
    WAITING = 1,
    SELECTING = 2,
    CUSTOMIZING = 3,
    TRANSITION_TO_SELECTING = 4,
    TRANSITION_TO_CUSTOMIZING = 5
}

gState = nil
gIsCamInterpolating = nil
CreationMode = false
gPedsSelectedPedIndex = 1
gPedSelectedSex = "none"

-- ---------------------------------------------------------------------
--  Helper tools
-- ---------------------------------------------------------------------

--- Deciding the character's gender from the model (assuming male when it is not recognised).
function isPedMale(ped)
    local model = GetEntityModel(ped)
    if model == GetHashKey("mp_male") then
        return true
    elseif model == GetHashKey("mp_female") then
        return false
    else
        return true
    end
end

-- ---------------------------------------------------------------------
--  The interface's texts
-- ---------------------------------------------------------------------

--- The strings the page draws itself (the character card, the random buttons), translated to the
--  current language. The keys are the Arabic source texts. Every key hint is a library prompt
--  (BuildCreatorCamPrompts), never a text drawn by the page.
function UiStrings()
    return {
        random = locale('عشوائي'), appearance = locale('مظهر'), clothes = locale('ملابس'), all = locale('الكل'),
        cash = locale('الكاش'), bank = locale('البنك'), gold = locale('الذهب'),
        name = locale('الاسم'), job = locale('الوظيفة'),
    }
end

--- The body expression ids: the interface needs them to confine its randomness to a narrow
--  range (±0.25 of a -1..1 range, that is ±25 on the interface's scale).
local function expressionIds()
    local out = {}
    local tbl = w and w.component and w.component.data and w.component.data.expressions
    if type(tbl) == 'table' then
        for name in pairs(tbl) do out[#out + 1] = name end
    end
    return out
end

--- The menu payload: the language, the direction, the translated menu tree and the page strings.
--  Built on every send rather than once at boot, so a language switch during play is honoured.
---@param msgType string 'receivedata' (a fresh open) or 'setLocale' (re-apply the texts in place)
function BuildMenuPayload(msgType)
    return {
        type = msgType,
        locale = UiLocale(),
        dir = UiDir(),
        expressionIds = expressionIds(),
        strings = UiStrings(),
    }
end

-- ---------------------------------------------------------------------
--  The customisation scene
-- ---------------------------------------------------------------------

RegisterNetEvent("W:CHARCREATION:startCustomizationScene", function(characterData)
    local ok, err = pcall(startCustomizationScene, characterData)
    if not ok then
        w.print.error('could not open the creator scene: %s', err)
        WCEditor.close()
        release()
        TriggerEvent('w_creators:client:backToSelection')
    end
end)

function startCustomizationScene(characterData)
    pedHandle = gPeds and gPeds[gPedsSelectedPedIndex]
    if not pedHandle or pedHandle == 0 or not DoesEntityExist(pedHandle) then
        error('the selected creator preview is missing')
    end
    local isMale = isPedMale(pedHandle)
    StartFade(250, 'creator')
    HideUnselectedGenderPed()
    CreatorScene.position(pedHandle, Config.EditingPed)
    CreatorScene.show(pedHandle)
    gState = State.CUSTOMIZING

    WCEditor.open(pedHandle, 'creator', {isMale=isMale, components=characterData}, {
        finish=function(app, identity)
            identity = type(identity)=='table' and identity or {}
            identity.firstname = tostring(identity.firstname or ''):match('^%s*(.-)%s*$')
            identity.lastname = tostring(identity.lastname or ''):match('^%s*(.-)%s*$')
            if identity.firstname=='' or identity.lastname=='' then return {ok=false,error=locale('أدخل الاسم الأول واسم العائلة')} end
            local result=w.callback.await('w_creators:saveCharacter',false,{appearance=app,identity=identity,appearanceOnly=appearanceOnly})
            if not result or not result.ok then return {ok=false,error=locale(result and result.error or 'تعذر حفظ الشخصية')} end
            StartFade(300,'creator')
            local applied,applyError=pcall(function()
                SetPlayerPed(app.isMale and 'mp_male' or 'mp_female')
                ApplyCreatorAppearance(PlayerPedId(),result.appearance)
            end)
            if not applied then
                w.print.error('saved appearance could not be rendered: %s',applyError)
                EndFade(300)
                return {ok=false,error=locale('تعذر تطبيق التعديل')}
            end
            WCEditor.close()
            CurrentCharacterAppearance=result.appearance
            release()
            TriggerServerEvent('w_creators:server:creationReady')
            return {ok=true,closed=true}
        end,
        cancel=function() RestoreGenderScene() end,
    })
    EndFade(300)
end

-- ---------------------------------------------------------------------
--  Reloading the saved appearance
-- ---------------------------------------------------------------------

RegisterCommand("reloadappearance", function()
    TriggerServerEvent("PersonaCreatorHandler.reloadCharacterAppearance")
end)

local applyingAppearance=false
function IsCreatorAppearanceApplying() return applyingAppearance end
local queuedAppearance
RegisterNetEvent('PersonaCreatorHandler.applyCharacterAppearance', function(app)
    queuedAppearance=app
    if applyingAppearance then return end
    applyingAppearance=true
    while queuedAppearance do
        local nextApp=queuedAppearance; queuedAppearance=nil
        if not (WCEditor and WCEditor.session) then
            local ok,err=pcall(function()
                local normalized=CreatorAppearance.normalize(nextApp)
                SetPlayerPed(normalized.isMale and 'mp_male' or 'mp_female')
                CurrentCharacterAppearance=ApplyCreatorAppearance(PlayerPedId(),normalized)
            end)
            if not ok then w.print.error('appearance load failed: %s',err) end
        end
    end
    applyingAppearance=false
end)

-- ---------------------------------------------------------------------
--  Creating the scene and the characters
-- ---------------------------------------------------------------------

local genderPromptGroup = nil -- the w.prompt.createGroup handle

--- The gender selection prompt group (library prompts: they support Arabic, unlike the native text).
--  The library reads the keys itself; the scene loop only asks the group which key completed.
function BuildGenderPrompts()
    if genderPromptGroup then return end
    local P = Config.GenderPrompt
    genderPromptGroup = w.prompt.createGroup(locale(P.title), P.position)
    genderPromptGroup.addPrompt(P.prev.key,   locale(P.prev.label),   false)
    genderPromptGroup.addPrompt(P.next.key,   locale(P.next.label),   false)
    genderPromptGroup.addPrompt(P.accept.key, locale(P.accept.label), false)
    genderPromptGroup.addPrompt(P.back.key,   locale(P.back.label),   false)
    genderPromptGroup.display()
end

--- Re-labelling the gender prompts after a language switch.
local function relabelGenderPrompts()
    if not genderPromptGroup then return end
    local P = Config.GenderPrompt
    pcall(function()
        genderPromptGroup.setTitle(locale(P.title))
        genderPromptGroup.setLabel(P.prev.key,   locale(P.prev.label))
        genderPromptGroup.setLabel(P.next.key,   locale(P.next.label))
        genderPromptGroup.setLabel(P.accept.key, locale(P.accept.label))
        genderPromptGroup.setLabel(P.back.key,   locale(P.back.label))
    end)
end

--- Rebuilding the gender selection scene when coming back from the customisation.
--  startCustomizationScene changes the scene in a way that switching the prompts does not undo:
--  it positions the ped for customisation, stops the scenario, and then the
--  interface applies dozens of edits to it. Going back without this used to swap the buttons alone
--  so the scene stayed as it was - which is what the player reads as 'it did not go back'.
--  We return each ped to its slot and its default shape behind a short fade.
function RestoreGenderScene()
    StartFade(400, 'creator')

    ResetOverlayState()
    ResetCreatorCamState()


    for i = 1, 2 do
        local p = gPeds and gPeds[i]
        if p and p ~= 0 and DoesEntityExist(p) then
            local c = staticPedPositions[i]

            CreatorScene.position(p, c)
            local pedSex = isPedMale(p) and 'male' or 'female'
            ApplyCreatorAppearance(p,{isMale=pedSex=='male',components=defaultPedComponents[pedSex]})
            CreatorScene.ready(p)
            CreatorScene.show(p)
            ArmScenePed(p, pedSex == 'male')
            PlaySceneIdle(p, pedSex == 'male')
        end
    end

    pedHandle = nil
    gPedsSelectedPedIndex = gPedSelectedSex == 'female' and 2 or 1
    MoveCreatorCam('selection', gPeds and gPeds[gPedsSelectedPedIndex], true)

    gState = State.SELECTING
    BuildGenderPrompts()

    EndFade(400)
end

--- Hiding the gender ped that was not chosen.
--  Leaving it in the scene makes any wide shot during the customisation show two peds, so the player
--  thinks he has gone back to the gender selection screen. We hide it and do not delete it: release()
--  takes care of the deletion, and RestoreGenderScene shows it again on the way back.
function HideUnselectedGenderPed()
    if not gPeds then return end
    for i = 1, #gPeds do
        if i ~= gPedsSelectedPedIndex and gPeds[i] and DoesEntityExist(gPeds[i]) then
            SetEntityVisible(gPeds[i], false, false)
            SetEntityCollision(gPeds[i], false, false)
        end
    end
end

function DestroyGenderPrompts()
    if not genderPromptGroup then return end
    pcall(genderPromptGroup.hide)
    pcall(genderPromptGroup.delete)
    genderPromptGroup = nil
end

function request()
    gState = State.NONE
    gPedsSelectedPedIndex, gPedSelectedSex = 1, 'male'
    CreatorScene.isolate()

    staticPedModels = { 'mp_male', 'mp_female' }

    defaultPedComponents = {male=CreatorAppearance.default('male'),female=CreatorAppearance.default('female')}

    staticPedPositions = Config.ScenePeds

    staticLightPositions = Config.SceneLights

    -- The same mechanism as vorp_character: an IPL + a loading sphere + waiting for the collision.
    -- RequestImap alone does not activate this room reliably.
    gImaps = Config.SceneImaps
    LoadCreatorScene()

    -- Peds from an earlier scene may remain after a restart, so they pile up in the room
    CleanupScenePeds()

    gPeds = {}

    SendNUIMessage(BuildMenuPayload('receivedata'))

    local player = PlayerPedId()
    FreezeEntityPosition(player, true)
    SetEntityInvincible(player, true)
    SetEntityVisible(player, false)
    for i = 1, 2 do
        local male = i == 1
        gPeds[i] = CreatorScene.create(staticPedModels[i], staticPedPositions[i],
            {isMale=male, components=defaultPedComponents[male and 'male' or 'female']})
        ArmScenePed(gPeds[i], male)
        PlaySceneIdle(gPeds[i], male)
    end
    ResetCreatorCamState()
    assert(MoveCreatorCam('selection', gPeds[1], true), 'could not frame the creator preview')

    SetCustomHudVisible(false) -- no HUD during the creation

    CreationMode = true
    MouseControlEnabled = true -- rotating with the mouse and zooming with a click
    BuildGenderPrompts()
    gState = State.SELECTING

    EndFade(500) -- it drops the loading screen (both layers) then shows the scene

    TriggerEvent("W:CHARCREATION:sceneSelect")
end

-- ---------------------------------------------------------------------
--  The gender selection and scene loop
-- ---------------------------------------------------------------------

RegisterNetEvent("W:CHARCREATION:sceneSelect", function()
    local P = Config.GenderPrompt

    while CreationMode do
        Wait(0)

        DisableAllControlActions(0)
        SuppressGameHud() -- it used to be DisplayHud(true) so the HUD showed during the creation
        NetworkClockTimeOverride(8, 0, 0, 0, false)

        for i = 1, #staticLightPositions do
            local lp = staticLightPositions[i]
            DrawLightWithRange(lp[1], lp[2], lp[3], 255, 255, 255, lp[4], lp[5])
        end

        if gState == State.SELECTING and genderPromptGroup then
            -- Going back to the character selection screen
            if genderPromptGroup.isCompleted(P.back.key) then
                DestroyGenderPrompts()
                release()
                TriggerEvent('w_creators:client:backToSelection')
                return
            end

            if genderPromptGroup.isCompleted(P.next.key) then
                gPedsSelectedPedIndex = 2
                gPedSelectedSex = "female"
                PlaySoundFrontend("gender_right", "RDRO_Character_Creator_Sounds", true, 0)
                MoveCreatorCam('selection', gPeds and gPeds[2], true)
            end

            if genderPromptGroup.isCompleted(P.prev.key) then
                gPedsSelectedPedIndex = 1
                gPedSelectedSex = "male"
                PlaySoundFrontend("gender_left", "RDRO_Character_Creator_Sounds", true, 0)
                MoveCreatorCam('selection', gPeds and gPeds[1], true)
            end

            if genderPromptGroup.isCompleted(P.accept.key) then
                gPedSelectedSex = gPedsSelectedPedIndex == 1 and "male" or "female"
                PlaySoundFrontend("gender_left", "RDRO_Character_Creator_Sounds", true, 0)
                gState = State.WAITING
                DestroyGenderPrompts()
                TriggerEvent("W:CHARCREATION:startCustomizationScene", defaultPedComponents[gPedSelectedSex])
            end

        elseif gState == State.TRANSITION_TO_SELECTING then
            gState = State.TRANSITION_TO_CUSTOMIZING
            Citizen.InvokeNative(0xFA233F8FE190514C, 0)
            Citizen.InvokeNative(0xE9990552DEC71600)

        elseif gState == State.TRANSITION_TO_CUSTOMIZING then
            Citizen.InvokeNative(0xFA233F8FE190514C, 0)
            Citizen.InvokeNative(0xE9990552DEC71600)
            -- The state used to stop here so it never reached CUSTOMIZING, and the camera prompt
            -- thread requires it - so the camera keys stayed dead all through the customisation.
            gState = State.CUSTOMIZING

        elseif gState == State.CUSTOMIZING then
            Citizen.InvokeNative(0xFA233F8FE190514C, 0)
            Citizen.InvokeNative(0xE9990552DEC71600)
        end
    end
end)

OnLanguageChange(function()
    relabelGenderPrompts()
    SendNUIMessage(BuildMenuPayload('setLocale'))
end)

-- ---------------------------------------------------------------------
--  Ending the scene and cleaning up the resources
-- ---------------------------------------------------------------------

function release()
    MouseControlEnabled = false
    DestroyGenderPrompts()
    WCEditor.close()
    if gPeds ~= nil then
        for i = 1, 2 do
            if gPeds[i] and ForgetOverlays then ForgetOverlays(gPeds[i]) end
            DeletePedHard(gPeds[i])
        end
        gPeds = nil
    end

    if gImaps ~= nil then
        for i = 1, #gImaps do
            RemoveImap(gImaps[i])
        end
        gImaps = nil
    end

    gState = nil
    pedHandle = nil

    local playerPed = PlayerPedId()
    SetFocusEntity(playerPed)
    SetEntityInvincible(playerPed, false)
    ResetEntityAlpha(playerPed)
    SetEntityVisible(playerPed, true)
    FreezeEntityPosition(playerPed, false)
    NetworkSetEntityOnlyExistsForParticipants(playerPed, false)

    CreationMode = false

    DestroyCreatorCams()

    local str = Citizen.InvokeNative(0xFA925AC00EB830B9, 10, "LITERAL_STRING", " ", Citizen.ResultAsLong())
    Citizen.InvokeNative(0xFA233F8FE190514C, str)
    Citizen.InvokeNative(0xE9990552DEC71600)
end

-- ---------------------------------------------------------------------
--  The public commands and events
-- ---------------------------------------------------------------------

RegisterCommand('starting', function()
    TriggerEvent("W:CHARCREATION:starting")
end)

--- opts.appearanceOnly: the server found a logged-in character without an appearance row
--  (a creation whose save failed); the creator runs again and saves the look for that character.
RegisterNetEvent("W:CHARCREATION:starting", function(opts)
    appearanceOnly = type(opts) == 'table' and opts.appearanceOnly == true or false
    WCurtain.show('creator')
    DoScreenFadeOut(500)
    Wait(1100)
    local ok, err = pcall(request)
    if not ok then
        w.print.error('character scene failed: %s', err)
        release()
        TriggerEvent('w_creators:client:backToSelection')
    end
end)

RegisterNetEvent("W:ADMIN:SpawnObject", function(model)
    local modelHash = tonumber(model) == nil and joaat(model) or tonumber(model)
    if not IsModelValid(modelHash) then
        return
    end
    local x, y, z = table.unpack(GetEntityCoords(PlayerPedId()))
    local _, groundZ = GetGroundZAndNormalFor_3dCoord(x, y, z)
    -- the library streams the model and creates the object (deleted when the resource stops)
    w.entity.create(modelHash, vector3(x, y, groundZ + 0.02), 0.0, true)
end)

AddEventHandler("onResourceStop", function(resourceName)
    if resourceName == GetCurrentResourceName() or resourceName == "_core" then
        release()
    end
end)
