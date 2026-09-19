local OWNED_TABLE = 'w_creators_clothes'
CreateThread(function()
    w.database.query.await([[
        CREATE TABLE IF NOT EXISTS `]] .. OWNED_TABLE .. [[` (
            `id` INT NOT NULL AUTO_INCREMENT,
            `charid` VARCHAR(100) NOT NULL,
            `hash` BIGINT NOT NULL,
            `category` VARCHAR(64) NOT NULL,
            `palette` VARCHAR(64) NULL,
            `tint0` INT NULL, `tint1` INT NULL, `tint2` INT NULL,
            PRIMARY KEY (`id`),
            INDEX `charid_idx` (`charid`),
            UNIQUE KEY `char_item` (`charid`, `hash`)
        ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
    ]], {})
end)

local A=CreatorAppearance
local ticket=0
local function near(src,coords,radius)
    local ped=GetPlayerPed(src)
    if not ped or ped==0 then return false end
    local p=GetEntityCoords(ped)
    return (p.x-coords.x)^2+(p.y-coords.y)^2+(p.z-coords.z)^2<=(radius or 5)^2
end
local function owned(charid)
    local out={}
    for _,row in ipairs(w.database.query.await('SELECT hash FROM w_creators_clothes WHERE charid=?',{charid}) or {}) do
        out[tostring(tonumber(row.hash))]=true
    end
    return out
end
w.callback.register('w_creators:store:open',function(src,mode,index)
    if mode~='store' and mode~='wardrobe' and mode~='barber' then return {ok=false} end
    local charid=Bridge.GetCharId(src)
    if not charid or CreatorAppearanceLocks[tostring(charid)] then return {ok=false} end
    local list=mode=='store' and StoreData.stores or mode=='barber' and GroomingConfig.barbers or StoreData.wardrobes
    local place=list[tonumber(index) or 0]
    local coords=place and (place.book or place.coords)
    -- Exported wardrobes are also used by job resources away from a fixed wardrobe.
    if mode~='wardrobe' or index~=nil then
        if not coords or not near(src,coords) then return {ok=false,error='ابتعدت عن المتجر'} end
    else coords=GetEntityCoords(GetPlayerPed(src)) end
    local app,row=ReadCreatorAppearance(charid)
    if not app then return {ok=false,error='لم يُعثر على مظهر الشخصية'} end
    ticket=ticket+1
    local session={charid=tostring(charid),row=row,original=app,mode=mode,owned=owned(charid),
        token=('%s:%s:%s'):format(src,ticket,GetGameTimer()),expires=os.time()+1800,
        coords=place and place.fittingRoom or coords}
    CreatorShopSessions[src]=session
    return {ok=true,token=session.token,appearance=app,owned=session.owned,growth=CreatorGrooming.info(app)}
end)

w.callback.register('w_creators:store:save',function(src,token,submitted)
    local s=CreatorShopSessions[src]
    if not s or s.token~=token or s.expires<os.time() or tostring(Bridge.GetCharId(src))~=s.charid or not near(src,s.coords,8) then
        return {ok=false,error='انتهت جلسة المتجر'}
    end
    if s.busy or CreatorAppearanceLocks[s.charid] then return {ok=false,error='busy'} end
    s.busy=true;CreatorAppearanceLocks[s.charid]=true
    local charged,user,committed=0,nil,false
    local ok,result=pcall(function()
        if type(submitted)~='table' then return {ok=false,error='بيانات غير صالحة'} end
        local app,row=ReadCreatorAppearance(s.charid)
        if not app then return {ok=false,error='لم يُعثر على مظهر الشخصية'} end
        local before=A.copy(app)
        local categories=s.mode=='barber' and {hair=0,mustache=0} or StoreData.prices
        local purchases={};local price=0;local changed=false
        for category,cost in pairs(categories) do
            if (cost>=0) and (app.isMale or category~='mustache') then
                local requested=A.decode(submitted.components)[category]
                if requested~=nil then
                    local hash=tonumber(requested)
                    if hash~=0 then hash=A.resolve(A.sex(app.isMale),category,hash) end
                    if not hash then return {ok=false,error='قطعة غير صالحة لهذه الشخصية'} end
                    if app.components[category]~=hash then
                        changed=true
                        if s.mode~='barber' and hash~=0 and not s.owned[tostring(hash)] and s.original.components[category]~=hash then
                            if s.mode=='wardrobe' then return {ok=false,error='هذه القطعة غير مملوكة'} end
                            price=price+cost;purchases[#purchases+1]={hash=hash,category=category}
                        end
                        app.components[category]=hash
                    end
                end
            end
        end
        if s.mode=='barber' then
            if changed then price=GroomingConfig.price end
            CreatorGrooming.cut(app,before)
        end
        price=math.floor(price*100+.5)/100
        user=w.framework:getUser(src)
        if not user or not user:canBuy(price,0,true) then return {ok=false,error='لا تملك ما يكفي من المال'} end
        charged=price
        local queries={}
        for _,item in ipairs(purchases) do
            queries[#queries+1]={query='INSERT INTO w_creators_clothes (charid,hash,category) VALUES (?,?,?) ON DUPLICATE KEY UPDATE category=VALUES(category)',values={s.charid,item.hash,item.category}}
        end
        -- Keep the outfit the player arrived wearing in the wardrobe too.
        for category in pairs(StoreData.prices) do
            local hash=before.components[category]
            if hash and hash~=0 then queries[#queries+1]={query='INSERT IGNORE INTO w_creators_clothes (charid,hash,category) VALUES (?,?,?)',values={s.charid,hash,category}} end
        end
        queries[#queries+1]={query='UPDATE characters_appearence SET components=? WHERE id=? AND charid=?',values={json.encode(app.components),row.id,s.charid}}
        if w.database.transaction.await(queries)~=true then error('outfit transaction failed') end
        committed=true
        CreatorShopSessions[src]=nil
        BroadcastAppearance(src,app)
        CreatorLogs.Emit(s.mode=='barber' and 'haircut' or 'clothes_bought',{playerSource=src,charid=s.charid,price=price,reason=s.mode})
        return {ok=true,appearance=app,price=price}
    end)
    CreatorAppearanceLocks[s.charid]=nil;s.busy=false
    if not ok then
        if charged>0 and not committed and user then
            if not user:addMoney(charged,0) then w.print.error('refund pending for character %s: %.2f',s.charid,charged) end
        end
        w.print.error('outfit save failed: %s',result)
        return {ok=false,error='تعذر حفظ التعديلات'}
    end
    return result
end)
RegisterNetEvent('w_creators:store:close',function(token)
    local s=CreatorShopSessions[source]
    if s and s.token==token and not s.busy then CreatorShopSessions[source]=nil end
end)

