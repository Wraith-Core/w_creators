-- =====================================================================
--  bridge/client.lua
--  The built-in spawn after the character is created (used only when Config.SpawnEvent is not set).
-- =====================================================================

--- The actual spawn. The position always arrives from the server:
--    { x, y, z, heading }  - the location selector or the last saved position
--  or a vector3                - the old paths
RegisterNetEvent('w_creators:client:spawn', function(spawnCoords)
    WCurtain.show('spawn')
    local appearanceDeadline=GetGameTimer()+20000
    while IsCreatorAppearanceApplying and IsCreatorAppearanceApplying() and GetGameTimer()<appearanceDeadline do Wait(20) end
    local coords = spawnCoords or Config.FirstSpawnCoords
    -- The heading arrives with the position from the server as a table. The check is because the old paths
    -- may send a vector3, and indexing it by a non-component key is not guaranteed.
    local heading = (type(coords) == 'table' and coords.heading) or Config.FirstSpawnHeading
    local ped = PlayerPedId()

    RequestCollisionAtCoord(coords.x, coords.y, coords.z)
    SetEntityCoords(ped, coords.x, coords.y, coords.z, false, false, false, false)
    if heading then
        SetEntityHeading(ped, heading + 0.0)
    end

    local timeout = 0
    while not HasCollisionLoadedAroundEntity(ped) and timeout < 200 do
        Wait(10)
        timeout = timeout + 1
    end

    -- Snapping to the ground after the collision loads and not before it: before that the function returns
    -- a wrong height because the geometry has not loaded yet.
    -- The Z coordinates in the config are approximate, and this stops a spawn underground or hanging.
    -- The guard is a requirement, not a decoration: over water or outside the loaded area the function returns
    -- completely distant values, and applying them with no check drops the player into the void.
    if Config.SpawnSnapToGround then
        local ok, found, groundZ = pcall(GetGroundZAndNormalFor_3dCoord,
            coords.x, coords.y, coords.z + 2.0)
        if ok and found and groundZ and math.abs(groundZ - coords.z) < 20.0 then
            SetEntityCoords(ped, coords.x, coords.y, groundZ, false, false, false, false)
        end
    end

    SetEntityInvincible(ped, false)
    SetEntityVisible(ped, true)
    NetworkSetEntityOnlyExistsForParticipants(ped, false)
    FreezeEntityPosition(ped, false)

    -- The creator's scenes are over: back to the base world first then releasing the scene
    TriggerServerEvent('w_creators:server:rejoinWorld')
    ReleaseCreatorScene()

    -- Only now do the interfaces come back: this is 'after the respawn'.
    -- vorp_core's counter is deliberately not shown again here - its own thread shows it when
    -- the map comes back, and it respects Config.HideUi on servers that hide it.
    SetWorldUiVisible(true)
    w.setRadarVisible(true)

    DismissLoadingScreen()
    DoScreenFadeIn(500)
    while IsScreenFadingIn() do Wait(0) end
    WCurtain.hide()
end)


-- =====================================================================
--  Syncing the appearance between the players
--  RedM does not sync the ped's components automatically: every player sees his own details only.
--  So we broadcast the appearance from the server and apply it here to the remote player's ped.
-- =====================================================================

RegisterNetEvent('w_creators:client:applyRemoteAppearance', function(serverId, appearance)
    if not appearance then return end
    if serverId == GetPlayerServerId(PlayerId()) then return end -- another path applies our own appearance

    -- The ped may not be cloned at our end yet (far away or in another bucket)
    CreateThread(function()
        local deadline = GetGameTimer() + 20000
        while GetGameTimer() < deadline do
            local plyIdx = GetPlayerFromServerId(serverId)
            if plyIdx ~= -1 then
                local ped = GetPlayerPed(plyIdx)
                if ped and ped ~= 0 and DoesEntityExist(ped) then
                    pcall(ApplyCreatorAppearance, ped, appearance)
                    return
                end
            end
            Wait(500)
        end
    end)
end)

-- On joining: we ask for the appearances of those already in the world
CreateThread(function()
    while not NetworkIsSessionStarted() do Wait(200) end
    Wait(2000)
    TriggerServerEvent('w_creators:server:requestAppearances')
end)
