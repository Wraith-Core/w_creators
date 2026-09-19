-- =====================================================================
--  server/server.lua
--  Saving/restoring the character's appearance in the resource's own table, through the Bridge compatibility layer.
--  No framework table is touched - only the character's identity is taken.
-- =====================================================================


-- The resource's own table is created on start (idempotent), so a fresh database never
-- swallows a creation: without it the appearance insert failed silently and the player
-- was left hanging in the creator scene.
w.database.ready(function()
    w.database.query.await([[
        CREATE TABLE IF NOT EXISTS `characters_appearence` (
            `id` INT NOT NULL AUTO_INCREMENT,
            `charid` VARCHAR(64) NOT NULL,
            `isMale` TINYINT(1) NOT NULL DEFAULT 1,
            `name` VARCHAR(60) DEFAULT NULL,
            `age` INT DEFAULT NULL,
            `faceFeatures` LONGTEXT DEFAULT NULL,
            `overlays` LONGTEXT DEFAULT NULL,
            `components` LONGTEXT DEFAULT NULL,
            PRIMARY KEY (`id`),
            KEY `charid` (`charid`)
        ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4
    ]])
end)

-- =====================================================================
--  The isolation and the appearance syncing
--  During the selection/creation the player is put in a bucket of his own (the number = source) so
--  nobody sees him and he sees nobody - no clashes and no strangers' peds in the scene. And he goes back to
--  bucket 0 (the base world) on entering or leaving.
--  And the appearance is broadcast to everyone and not to its owner alone, otherwise only he would see it.
-- =====================================================================

local appearanceCache = {} -- [serverId] = appearanceData

--- Returning the player to the base world.
RegisterNetEvent('w_creators:server:rejoinWorld', function()
    local _source = source
    SetPlayerRoutingBucket(_source, 0)
    CreatorLogs.Emit('routing_bucket_set', {
        playerSource = _source, scope = 'player', after = 0,
        reason = 'العودة إلى العالم الأساسي',
    })
end)

--- Broadcasting a player's appearance to everyone + storing it so it reaches whoever joins later.
function BroadcastAppearance(src, appearanceData)
    if not appearanceData then return end
    appearanceCache[src] = appearanceData
    TriggerClientEvent('w_creators:client:applyRemoteAppearance', -1, src, appearanceData)
end

--- Whoever has just joined asks for the appearances of those already present.
RegisterNetEvent('w_creators:server:requestAppearances', function()
    local _source = source
    for src, data in pairs(appearanceCache) do
        if src ~= _source then
            TriggerClientEvent('w_creators:client:applyRemoteAppearance', _source, src, data)
        end
    end
end)

AddEventHandler('playerDropped', function()
    appearanceCache[source] = nil
end)

CreatorAppearanceLocks = {}
CreatorShopSessions = {}
local creating, pendingCreation, provisioned = {}, {}, {}
function ReadCreatorAppearance(charid)
    local row=w.database.single.await('SELECT * FROM characters_appearence WHERE charid = ? ORDER BY id DESC LIMIT 1',{charid})
    if not row then return nil end
    return CreatorAppearance.normalize(row),row
end
function SaveCreatorAppearance(charid,app,row)
    local query='UPDATE characters_appearence SET components=?,faceFeatures=?,overlays=? WHERE id=? AND charid=?'
    return w.database.update.await(query,{json.encode(app.components),json.encode(app.faceFeatures),json.encode(app.overlays),row.id,charid})
end
w.callback.register('w_creators:saveCharacter',function(src,data)
    if pendingCreation[src] then return {ok=true,appearance=pendingCreation[src].appearance} end
    if creating[src] then return {ok=false,error='busy'} end
    creating[src]=true
    local ok,result=pcall(function()
        if type(data)~='table' or type(data.appearance)~='table' or type(data.identity)~='table' then return {ok=false,error='بيانات غير صالحة'} end
        local identity=data.identity
        for _,field in ipairs({'firstname','lastname'}) do
            if type(identity[field])~='string' or not identity[field]:match('%S') or #identity[field]>100 then return {ok=false,error='أدخل الاسم الأول واسم العائلة'} end
        end
        local app=CreatorAppearance.normalize(data.appearance)
        app.components.__grooming={}
        identity.age=math.floor(CreatorAppearance.number(identity.age,18,100,28))
        identity.isMale=app.isMale
        local charid=Bridge.GetCharId(src)
        local retry=provisioned[src] and tostring(provisioned[src])==tostring(charid)
        local isNew=retry or not (data.appearanceOnly==true and charid)
        if retry then
            -- Keep the just-created framework identity if the appearance database was temporarily unavailable.
        elseif not isNew then
            local existing=ReadCreatorAppearance(charid)
            if existing then return {ok=false,error='مظهر الشخصية محفوظ مسبقًا'} end
        elseif Config.Multicharacter then
            if #Bridge.GetCharacters(src)>=(Config.CharacterSlots or 3) then return {ok=false,error='لا توجد خانة شخصية متاحة'} end
            charid=Bridge.RegisterCharacter(src,identity)
            provisioned[src]=charid
        end
        if not charid then return {ok=false,error='تعذر تسجيل الشخصية'} end
        local id=w.database.insert.await('INSERT INTO characters_appearence (charid,isMale,name,age,faceFeatures,overlays,components) VALUES (?,?,?,?,?,?,?)',
            {charid,app.isMale and 1 or 0,Bridge.DisplayName(identity),identity.age,json.encode(app.faceFeatures),json.encode(app.overlays),json.encode(app.components)})
        if not id then error('appearance insert failed') end
        pendingCreation[src]={charid=charid,isNew=isNew,appearance=app}
        CreatorLogs.Emit('character_created',{playerSource=src,charid=tostring(charid),appearanceId=id,reason='اكتمل المنشئ'})
        return {ok=true,appearance=app}
    end)
    creating[src]=nil
    if not ok then
        w.print.error('character save failed: %s',result)
        return {ok=false,error='تعذر حفظ الشخصية'}
    end
    return result
end)
RegisterNetEvent('w_creators:server:creationReady',function()
    local src=source;local pending=pendingCreation[src]
    if not pending or tostring(Bridge.GetCharId(src))~=tostring(pending.charid) then return end
    pendingCreation[src]=nil;provisioned[src]=nil
    BroadcastAppearance(src,pending.appearance)
    Bridge.FinishCharacter(src,pending.isNew)
end)
RegisterNetEvent('PersonaCreatorHandler.reloadCharacterAppearance',function()
    local src=source;local charid=Bridge.GetCharId(src)
    if not charid or CreatorShopSessions[src] then return end
    local app=ReadCreatorAppearance(charid)
    if app then TriggerClientEvent('PersonaCreatorHandler.applyCharacterAppearance',src,app);BroadcastAppearance(src,app) end
end)
AddEventHandler('playerDropped',function() creating[source]=nil;pendingCreation[source]=nil;provisioned[source]=nil;CreatorShopSessions[source]=nil end)

-- restricted: only holders of the command.spawnprop ACE (group.admin has 'command') may use it
RegisterCommand("spawnprop", function(source, args)
    if #args >= 1 then
        TriggerClientEvent("W:ADMIN:SpawnObject", source, args[1])
        CreatorLogs.Emit('prop_spawned', {
            playerSource = (source ~= 0) and source or nil,
            adminAction = 'object-spawn',
            model = tostring(args[1]),
            viaConsole = (source == 0),
            reason = 'spawnprop command (ACE restricted)',
        })
    end
end, true)

-- =====================================================================
--  The spawn location selector (Config.SpawnSelector)
--  The client sends a textual id only ('valentine' or '__last'), and the server translates it
--  into coordinates from Config.SpawnPoints. No coordinate ever arrives from the client,
--  so an injected client cannot move himself to a coordinate of his own choosing.
-- =====================================================================

RegisterNetEvent('w_creators:server:spawnAt', function(pointId)
    local _source = source

    -- The permission is temporary: it is granted in FinishCharacter and withdrawn here as soon as it is used.
    -- Without it the event becomes an instant teleport available at any time to any player.
    if not SpawnPending[_source] then
        CreatorLogs.Emit('character_access_denied', {
            playerSource = _source,
            operation = 'spawn',
            charid = tostring(pointId),
            reason = 'حدث spawnAt خارج مسار اختيار موقع الظهور',
        })
        return
    end
    SpawnPending[_source] = nil

    local pos

    if pointId == '__last' then
        pos = Bridge.GetLastPosition(_source)
    elseif type(pointId) == 'string' then
        local pt = Bridge.FindSpawnPoint(pointId)
        if pt then
            pos = { x = pt.coords.x, y = pt.coords.y, z = pt.coords.z, heading = pt.heading or 0.0 }
        end
    end

    -- An unknown id or a missing saved position: the starting point rather than leaving the player hanging
    if not pos then
        pos = {
            x = Config.FirstSpawnCoords.x,
            y = Config.FirstSpawnCoords.y,
            z = Config.FirstSpawnCoords.z,
            heading = Config.FirstSpawnHeading or 0.0,
        }
    end

    SetPlayerRoutingBucket(_source, 0)
    TriggerClientEvent('w_creators:client:spawn', _source, pos)
end)
