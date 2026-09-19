-- =====================================================================
--  spawnselect/client.lua
--  The spawn location selection screen - an aerial camera flies over every town and the player
--  moves with the prompts and confirms.
--
--  Why a library prompt group (w.prompt.createGroup) and not the native prompt: RDR's prompts
--  pass through CreateVarString and do not support Arabic. And for the same reason the town's
--  name is shown in the prompt group's title rather than with DrawText - exactly as the character's
--  name is shown in the character selection screen (multichar/client.lua).
--
--  The security: this file sends a textual id only. Translating it into coordinates happens on the
--  server (server/server.lua) against Config.SpawnPoints.
-- =====================================================================

if not Config.SpawnSelector then return end

local LAST_ID = '__last' -- the id of the 'the last place you were' option

local active = false
local points = {}   -- { {id, label, region, coords, heading, cam} }
local index = 1
local cam = nil
local orbitAngle = 0.0
local promptGroup = nil -- the w.prompt.createGroup handle
local busy = false
local inputReadyAt = 0
local nextUiHide = 0 -- when the interface hiding is reasserted

-- ---------------------------------------------------------------------
--  The camera
-- ---------------------------------------------------------------------

--- A camera setting's value for this location: the location's override first then the default.
local function camCfg(pt, key)
    local override = pt.cam and pt.cam[key]
    if override ~= nil then return override end
    return Config.SpawnCamDefaults[key]
end

--- The camera's position on a horizontal orbit around the location.
--  Computed and not written: the camera is aimed at the point with PointCamAtCoord so the
--  framing is right for any town with no manual angle tuning for each one.
local function camPos(pt, angleDeg)
    local a = math.rad(angleDeg)
    local dist = camCfg(pt, 'dist')
    return
        pt.coords.x + dist * math.cos(a),
        pt.coords.y + dist * math.sin(a),
        pt.coords.z + camCfg(pt, 'height')
end

local function destroyCam()
    if cam and DoesCamExist(cam) then
        DestroyCam(cam, true)
    end
    cam = nil
end

--- Loading the location's area before showing it.
--  Without it the town appears as grey blocks with no buildings in the first moment: the focus is what
--  drives the streaming, and the player himself is still in the creator's room far away from it.
local function streamPoint(pt)
    local x, y, z = pt.coords.x, pt.coords.y, pt.coords.z

    SetFocusPosAndVel(x, y, z, 0.0, 0.0, 0.0)
    RequestCollisionAtCoord(x, y, z)

    local deadline = GetGameTimer() + (Config.SpawnSceneTimeout or 8000)
    LoadSceneStart(x, y, z, 0.0, 0.0, 0.0, 50.0, 0)
    while IsLoadSceneLoaded() == 0 and GetGameTimer() < deadline do
        Wait(0)
    end
    LoadSceneStop()
end

--- The prompt group's title = the location's name and its region and its order.
local function currentTitle()
    local pt = points[index]
    if not pt then return locale(Config.SpawnSelectLabels.title) end
    local name = locale(pt.label)
    if pt.region and pt.region ~= '' then
        name = ('%s — %s'):format(name, locale(pt.region))
    end
    return ('%s  (%d/%d)'):format(name, index, #points)
end

--- Moving to a location: a fade, a load, a new camera, then showing it.
--  The fade is not decoration: streamPoint moves the focus to the new town so the old one
--  begins to fall apart before our eyes. And because the screen is black during the load there is no need
--  for a smooth camera transition - we place the new one directly.
--  fadeIn = false for the first call: the caller is the one that shows the screen after the load.
local function showPoint(i, fadeIn)
    if #points == 0 then return end
    if fadeIn == nil then fadeIn = true end

    local dur = Config.SpawnTransition or 350

    if fadeIn and not IsScreenFadedOut() then
        DoScreenFadeOut(dur)
        while IsScreenFadingOut() do Wait(0) end
    end

    index = ((i - 1) % #points) + 1
    local pt = points[index]

    streamPoint(pt)

    orbitAngle = camCfg(pt, 'angle')
    local x, y, z = camPos(pt, orbitAngle)

    local prev = cam
    local newCam = CreateCam('DEFAULT_SCRIPTED_CAMERA', true)
    SetCamCoord(newCam, x, y, z)
    SetCamFov(newCam, camCfg(pt, 'fov'))
    PointCamAtCoord(newCam, pt.coords.x, pt.coords.y, pt.coords.z)

    cam = newCam
    SetCamActive(newCam, true)
    RenderScriptCams(true, false, 0, true, true, 0)

    if prev and prev ~= newCam and DoesCamExist(prev) then
        DestroyCam(prev, false)
    end

    if promptGroup then
        promptGroup.setTitle(currentTitle())
    end

    if fadeIn then
        DoScreenFadeIn(dur)
    end
end

-- ---------------------------------------------------------------------
--  The prompts
-- ---------------------------------------------------------------------

local function destroyPrompts()
    if promptGroup then
        pcall(promptGroup.hide)
        pcall(promptGroup.delete)
    end
    promptGroup = nil
end

local function buildPrompts()
    destroyPrompts()
    local K = Config.SpawnSelectKeys
    local L = Config.SpawnSelectLabels

    promptGroup = w.prompt.createGroup(locale(L.title), Config.SpawnSelectPromptPosition)
    promptGroup.addPrompt(K.select, locale(L.select), false)
    promptGroup.addPrompt(K.prev, locale(L.prev), false)
    promptGroup.addPrompt(K.next, locale(L.next), false)
    promptGroup.display()

    -- The same barrier as the characters screen: without it ENTER may register on the first frame after
    -- the panel appears so the player spawns at the first location without seeing the screen at all.
    inputReadyAt = GetGameTimer() + 500
end

--- The language switch: the labels and the title are re-applied in place.
OnLanguageChange(function()
    if not active or not promptGroup then return end
    local K = Config.SpawnSelectKeys
    local L = Config.SpawnSelectLabels
    pcall(function()
        promptGroup.setLabel(K.select, locale(L.select))
        promptGroup.setLabel(K.prev, locale(L.prev))
        promptGroup.setLabel(K.next, locale(L.next))
        promptGroup.setTitle(currentTitle())
    end)
end)

-- ---------------------------------------------------------------------
--  Entering and leaving
-- ---------------------------------------------------------------------

local function leave()
    active = false
    destroyPrompts()
    ClearFocus() -- returning the streaming focus to the player before moving him
    if cam then
        RenderScriptCams(false, false, 0, true, true, 0)
        destroyCam()
    end
end

--- Confirming the choice: we close the scene then leave the server to spawn the player.
--  We do not move ourselves here: w_creators:client:spawn is the only spawn path,
--  and the server is the one that translates the id into coordinates.
local function confirm()
    local pt = points[index]
    if not pt then return end

    WCurtain.show('spawn')
    DoScreenFadeOut(400)
    while IsScreenFadingOut() do Wait(0) end

    leave()
    TriggerServerEvent('w_creators:server:spawnAt', pt.id)
end

RegisterNetEvent('w_creators:client:selectSpawn', function(data)
    data = data or {}

    points = {}

    -- 'The last place' first and preselected: whoever presses ENTER straight away goes back to his place
    -- as if there were no screen at all.
    if data.last then
        points[#points + 1] = {
            id      = LAST_ID,
            label   = Config.SpawnSelectLabels.lastPosition,
            region  = Config.SpawnSelectLabels.lastRegion,
            coords  = vector3(data.last.x, data.last.y, data.last.z),
            heading = data.last.heading or 0.0,
        }
    end

    for _, pt in ipairs(Config.SpawnPoints or {}) do
        points[#points + 1] = pt
    end

    if #points == 0 then
        -- An empty config: we do not leave the player on a screen with no options. The server falls back to
        -- the starting point on any unknown id.
        w.print.error('Config.SpawnPoints is empty - spawning straight at the starting point')
        TriggerServerEvent('w_creators:server:spawnAt', false)
        return
    end

    active = true
    busy = false

    -- The scene is completely empty: no HUD and no map and no chat.
    -- Mandatory here in particular: vorp:SelectedCharacter happened before this moment
    -- (setUsedCharacter on the server), and that is what wakes w_hud and brings the map back -
    -- so the location selection screen is the only screen that comes after the login.
    SetWorldUiVisible(false)
    nextUiHide = GetGameTimer() + 2000

    local ped = PlayerPedId()
    FreezeEntityPosition(ped, true)
    SetEntityInvincible(ped, true)
    SetEntityVisible(ped, false, false)
    NetworkSetEntityOnlyExistsForParticipants(ped, true)

    -- Leaving the creator's room: its time and colour tweaks do not belong to the towns' scene
    ReleaseCreatorScene()

    DestroyAllCams(true)
    cam = nil

    buildPrompts()
    showPoint(1, false)

    -- Showing after the load completes and not before it (showPoint waits for the scene)
    EndFade(600)
end)

-- ---------------------------------------------------------------------
--  The screen's loop
-- ---------------------------------------------------------------------

CreateThread(function()
    local K = Config.SpawnSelectKeys
    local last = GetGameTimer()

    while true do
        if active and promptGroup and #points > 0 then
            DisableAllControlActions(0) -- it blocks opening the chat and the map together
            SuppressGameHud()

            -- A periodic reassertion: vorp_core shows its counter ten seconds after
            -- vorp:SelectedCharacter (uicore.lua:34-35), and any other resource may
            -- wake with a similar delay. Twice a second costs nothing.
            if GetGameTimer() >= nextUiHide then
                nextUiHide = GetGameTimer() + 2000
                SetWorldUiVisible(false)
            end

            -- A slow rotation around the location: it brings the shot alive and shows the town from its sides
            local now = GetGameTimer()
            local dt = (now - last) / 1000.0
            last = now

            local pt = points[index]
            local orbit = camCfg(pt, 'orbit') or 0.0
            if orbit ~= 0.0 and cam and DoesCamExist(cam) then
                orbitAngle = (orbitAngle + orbit * dt) % 360.0
                local x, y, z = camPos(pt, orbitAngle)
                SetCamCoord(cam, x, y, z)
                PointCamAtCoord(cam, pt.coords.x, pt.coords.y, pt.coords.z)
            end

            if not busy and now >= inputReadyAt then
                if promptGroup.isCompleted(K.prev) then
                    busy = true
                    showPoint(index - 1)
                    busy = false
                elseif promptGroup.isCompleted(K.next) then
                    busy = true
                    showPoint(index + 1)
                    busy = false
                elseif promptGroup.isCompleted(K.select) then
                    busy = true
                    confirm()
                    busy = false
                end
            end

            Wait(0)
        else
            last = GetGameTimer()
            Wait(250)
        end
    end
end)

AddEventHandler('onResourceStop', function(resource)
    if resource == GetCurrentResourceName() then
        destroyPrompts()
        ClearFocus()
        if cam then
            RenderScriptCams(false, false, 0, true, true, 0)
            destroyCam()
        end
    end
end)
