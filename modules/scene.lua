-- Selection and creation share one checked preview lifecycle. Appearance and
-- streaming stay in w_lib; the server acknowledges the private scene first.
CreatorScene = {}

local function requirePed(ped)
    assert(ped and ped ~= 0 and DoesEntityExist(ped), 'creator preview entity is missing')
end

function CreatorScene.isolate()
    local result = w.callback.await('w_creators:scene:prepare', false)
    assert(result and result.ok, 'could not prepare the private character scene')
end

function CreatorScene.ready(ped)
    w.waitFor(function()
        requirePed(ped)
        local ready = Citizen.InvokeNative(0xA0BC8FAED8CFEB3C, ped)
        if ready ~= true and ready ~= 1 then return nil end
        -- A zero-scale skeleton can be "ready" with every bone at its origin.
        local origin = GetEntityCoords(ped)
        local head = GetPedBoneCoords(ped, 21030, 0.0, 0.0, 0.0)
        return head.z - origin.z > 0.2 and true or nil
    end, 'creator appearance did not become ready to render', 15000)
end

function CreatorScene.show(ped)
    requirePed(ped)
    ResetEntityAlpha(ped)
    SetEntityVisible(ped, true)
    SetEntityInvincible(ped, true)
    SetBlockingOfNonTemporaryEvents(ped, true)
end

function CreatorScene.position(ped, coords)
    requirePed(ped)
    ClearPedTasksImmediately(ped)
    FreezeEntityPosition(ped, true)
    SetEntityCollision(ped, true, true)
    -- Scene coordinates describe the floor, as do w.entity.create coordinates.
    SetEntityCoords(ped, coords[1], coords[2], coords[3], false, false, false, false)
    SetEntityHeading(ped, coords[4] or 0.0)
    RequestCollisionAtCoord(coords[1], coords[2], coords[3])
    w.waitFor(function()
        requirePed(ped)
        return HasCollisionLoadedAroundEntity(ped) and true or nil
    end, 'creator room collision did not load', 10000)
    -- PLACE_ENTITY_ON_GROUND_PROPERLY accepts a ped; the OBJECT native does not.
    Citizen.InvokeNative(0x9587913B9E772D29, ped, true)
    FreezeEntityPosition(ped, true)
    TaskStandStill(ped, -1)
    local at = GetEntityCoords(ped)
    assert(math.abs(at.x-coords[1]) < 1.0 and math.abs(at.y-coords[2]) < 1.0
        and math.abs(at.z-coords[3]) < 3.0, 'creator preview is outside its scene position')
end

function CreatorScene.create(model, coords, appearance)
    local ped = w.entity.create(model, vector4(coords[1], coords[2], coords[3], coords[4] or 0.0),
        true, 0, {scriptHost=true})
    local ok, err = pcall(function()
        requirePed(ped)
        FreezeEntityPosition(ped, true)
        SetEntityVisible(ped, false)
        SetEntityAsMissionEntity(ped, true, true)
        local netId = w.waitFor(function()
            requirePed(ped)
            local id = NetworkGetNetworkIdFromEntity(ped)
            return id and id > 0 and id or nil
        end, 'creator preview did not register on the network', 5000)
        local result = w.callback.await('w_creators:scene:registerPed', false, netId)
        assert(result and result.ok, 'creator preview could not join the private scene')
        CreatorScene.position(ped, coords)
        ApplyCreatorAppearance(ped, appearance)
        CreatorScene.ready(ped)
        CreatorScene.show(ped)
    end)
    if not ok then
        if ped and ped ~= 0 and DoesEntityExist(ped) then
            if ForgetOverlays then ForgetOverlays(ped) end
            DeletePedHard(ped)
        end
        error(err, 0)
    end
    return ped
end
