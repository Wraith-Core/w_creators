-- =====================================================================
--  creator/spawn.lua
--  The optional first-spawn wagon scene (Config.EnableCutscene): a stagecoach and its driver take
--  the new character into Saint Denis while the story notices play.
-- =====================================================================

local FirstSpawn = false
local wagon = nil
local ped = nil
local coordsSpawn = vector3(2539.83, -1129.33, 50.03)

--- The wagon scene's story notices: a plain w_lib notification in the player's language.
--  The keys are the Arabic source texts; locales/en.json translates them.
local function StoryNotify(key, duration)
    w.notify({ description = locale(key), duration = duration })
end

RegisterNetEvent("W:CREATOR:FirstSpawn", function()
    if not FirstSpawn and Config.EnableCutscene then
        TriggerMusicEvent("REHR_START")
        NetworkSetEntityOnlyExistsForParticipants(PlayerPedId(), true)
        Wait(100)
        SetEntityCoords(PlayerPedId(), 2520.09, -358.05, 41.61)
        Wait(2500)
        TriggerEvent('W:CREATOR:CreateVehicle', 'STAGECOACH001X')
        Wait(1000)
        TriggerEvent('W:CREATOR:CreatePedOnVehicle', 'CS_BivCoachDriver')
        Wait(3000)
        SetPedIntoVehicle(PlayerPedId(), wagon, 1)
        Wait(2000)
        TriggerEvent('W:CREATOR:StartNotify')
        FirstSpawn = true
    else
        TriggerEvent('W:CREATOR:StartNotify')
        SetEntityCoords(PlayerPedId(), Config.FirstSpawnCoords)
        FirstSpawn = false
    end
end)

Citizen.CreateThread(function()
    while true do
        Wait(10)
        if FirstSpawn then
            local pcoords = GetEntityCoords(PlayerPedId())
            local dst = #(coordsSpawn - pcoords)
            if dst < 5 then
                RemovePedFromGroup(ped, GetPedGroupIndex(PlayerPedId()))
                Wait(100)
                DisableAllControlActions(0)
                NetworkSetEntityOnlyExistsForParticipants(PlayerPedId(), false)
                SetEntityInvincible(PlayerPedId(), false)
                SetCinematicModeActive(0)
                FirstSpawn = false
                N_0x69d65e89ffd72313(false)
                Wait(1000)
                TaskLeaveVehicle(PlayerPedId(), wagon, 0, 0)
                Wait(2000)
                TaskVehicleDriveToCoord(ped, GetVehiclePedIsIn(ped, false), 2600.436, -1205.932, 53.323, 10.0, 1.0,
                    GetEntityModel(GetVehiclePedIsIn(PlayerPedId())), 67633207, 5.0, false)
                StoryNotify('فقدت كل ملابسك، هناك متجر ملابس على الجانب الآخر من الشارع، ما رأيك أن تذهب إليه لتبديل ثيابك؟', 10000)
                TriggerMusicEvent("MC_MUSIC_STOP")
                Wait(10000)
                w.entity.delete(wagon)
                Citizen.InvokeNative(0x971D38760FBC02EF, ped, false)
                w.entity.delete(ped)
            else
                N_0x69d65e89ffd72313(true)
                SetCinematicModeActive(1)
                DisableAllControlActions(1)
            end
        end
    end
end)

RegisterNetEvent("W:CREATOR:CreateVehicle", function(vModel)
    Citizen.CreateThread(function()
        -- the library streams the model, creates the wagon and deletes it when the resource stops
        wagon = w.entity.create(vModel, vector4(2520.09, -358.05, 41.61, 268.89169), true)
        if wagon then
            SetVehicleOnGroundProperly(wagon)
        end
    end)
end)

RegisterNetEvent("W:CREATOR:StartNotify", function()
    Wait(5000)
    StoryNotify('تحياتنا يا راعي البقر. أهلًا بك، انطلق واستكشف المناطق المختلفة واكتشف أسرار هذا العالم الجديد الذي ينتظرك.', 12000)
    Wait(15000)
    StoryNotify('اقرأ جدار القوانين لتبقى على اطّلاع بكل ما هو مسموح في السيرفر، وتتجنّب الأسئلة والمشاكل لاحقًا.', 10000)
    Wait(15000)
    StoryNotify('احذر وأنت تتجوّل عند الغسق في الغرب المتوحّش، فلا يبقى بعد حلول الظلام إلا المغامرون حقًا... يقولون إنه عالم مختلف تمامًا تحت ضوء القمر.', 12000)
    Wait(18000)
    StoryNotify('هذه سانت دينيس، أول مدينة تزورها. ستجد فيها متاجر عديدة: متجر ملابس، وحلّاق، ومركز شرطة، وغيرها. لكن تذكّر أن هناك عالمًا واسعًا في انتظارك لتستكشفه!', 18000)
end)

RegisterNetEvent("W:CREATOR:CreatePedOnVehicle", function(pedModel)
    if not IsModelValid(joaat(pedModel)) then
        return
    end
    -- the library streams the model, applies a random outfit and deletes the ped when the resource stops
    ped = w.entity.create(pedModel, vector4(coordsSpawn.x, coordsSpawn.y, coordsSpawn.z, GetEntityHeading(PlayerPedId())), false)
    if not ped then return end
    SetEntityNoCollisionEntity(PlayerPedId(), ped, false)
    SetEntityCanBeDamaged(ped, false)
    SetEntityInvincible(ped, true)
    Wait(1000)
    SetBlockingOfNonTemporaryEvents(ped, true)
    SetEntityAsMissionEntity(ped)
    Citizen.Wait(150)
    SetPedAsGroupMember(ped, GetPedGroupIndex(PlayerPedId()))
    SetEntityAsMissionEntity(wagon, false, false)
    SetEntityAsMissionEntity(ped, false, false)
    local npc_group = GetPedRelationshipGroupHash(ped)
    SetRelationshipBetweenGroups(1, joaat("PLAYER"), npc_group)
    SetPedIntoVehicle(ped, wagon, -1)
    TaskVehicleDriveToCoord(ped, GetVehiclePedIsIn(ped, false), 2539.83, -1129.33, 50.03, 10.0, 1.0,
        GetEntityModel(GetVehiclePedIsIn(PlayerPedId())), 67633207, 5.0, false)
    Citizen.InvokeNative(0x971D38760FBC02EF, ped, true)
    Citizen.Wait(250)
end)
