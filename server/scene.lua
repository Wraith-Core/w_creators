local function isolate(src)
    if not src or not GetPlayerName(src) then return {ok=false} end
    SetPlayerRoutingBucket(src, src)
    if CreatorLogs then
        pcall(CreatorLogs.Emit, 'routing_bucket_set', {
            playerSource=src, scope='player', after=src, reason='عزل مشهد الاختيار/الإنشاء',
        })
    end
    return {ok=GetPlayerRoutingBucket(src)==src}
end

local function registerPed(src, netId)
    if type(netId) ~= 'number' or netId <= 0 or netId % 1 ~= 0
        or GetPlayerRoutingBucket(src) ~= src then return {ok=false} end
    -- The client can receive a network ID before the server has the entity.
    local deadline = GetGameTimer() + 5000
    local entity
    repeat
        entity = NetworkGetEntityFromNetworkId(netId)
        if entity ~= 0 and DoesEntityExist(entity) then break end
        Wait(50)
    until GetGameTimer() >= deadline or not GetPlayerName(src)
    if not entity or entity == 0 or not DoesEntityExist(entity)
        or NetworkGetEntityOwner(entity) ~= src or GetEntityType(entity) ~= 1
        or entity == GetPlayerPed(src) or GetPlayerRoutingBucket(src) ~= src then return {ok=false} end
    local model = GetEntityModel(entity)
    if model ~= GetHashKey('mp_male') and model ~= GetHashKey('mp_female') then return {ok=false} end
    local at, anchor = GetEntityCoords(entity), Config.SceneAnchor
    local distance = (at.x-anchor[1])^2 + (at.y-anchor[2])^2 + (at.z-anchor[3])^2
    if distance > Config.SceneCleanupRadius^2 then return {ok=false} end
    SetEntityRoutingBucket(entity, src)
    if CreatorLogs then
        pcall(CreatorLogs.Emit, 'routing_bucket_set', {
            playerSource=src, scope='entity', networkId=netId, after=src, reason='عزل شخصية المعاينة',
        })
    end
    return {ok=GetEntityRoutingBucket(entity)==src}
end

w.callback.register('w_creators:scene:prepare', isolate)
w.callback.register('w_creators:scene:registerPed', registerPed)

-- Keep the existing entry points for clothing shops and older consumers.
RegisterNetEvent('w_creators:server:isolate', function() isolate(source) end)
RegisterNetEvent('PersonaCreatorHandler.setPlayerRoutingBucket', function() isolate(source) end)
RegisterNetEvent('PersonaCreatorHandler.setRoutingBucket', function(netId) registerPed(source, netId) end)
