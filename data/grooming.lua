-- Appearance changes use existing multiplayer assets, never a change of ped model.
-- Stage entries name assets explicitly; their order is configurable, not catalogue order.
GroomingConfig = {
    enabled = true,
    price = 10,
    minutesPerStage = { hair = 120, beard = 60 },
    stages = {
        male = { hair = { 'CLOTHING_ITEM_M_HAIR_001_', 'CLOTHING_ITEM_M_HAIR_006_', 'CLOTHING_ITEM_M_HAIR_008_' },
                 beard = { 'CLOTHING_ITEM_M_BEARD_001_', 'CLOTHING_ITEM_M_BEARD_004_', 'CLOTHING_ITEM_M_BEARD_006_' } },
        female = { hair = { 'CLOTHING_ITEM_F_HAIR_001_', 'CLOTHING_ITEM_F_HAIR_003_', 'CLOTHING_ITEM_F_HAIR_006_' } },
    },
    barbers = {
        { town='فالنتاين', coords=vector3(-307.51,813.96,118.99) },
        { town='بلاك ووتر', coords=vector3(-814.915,-1367.89,43.75) },
        { town='سانت دينيس', coords=vector3(2655.21,-1179.9,53.27) },
        { town='أنيسبرغ', coords=vector3(2924.3,1343.7,44.4) },
        { town='أرماديلو', coords=vector3(-3684.22,-2621.05,-13.44) },
        { town='تمبلويد', coords=vector3(-5493.4,-2940.7,-.46) },
        { town='ستروبري', coords=vector3(-1810.92,-372.15,162.89) },
    },
}
CreatorGrooming = {}
local G,A = CreatorGrooming,CreatorAppearance
local function stageFor(app,kind)
    local category=kind=='beard' and 'mustache' or 'hair'
    local hash=app.components[category] or 0
    if hash==0 then return 0 end
    local sex=A.sex(app.isMale)
    local info=A.catalog(sex)[category].hashes[hash]
    for index,prefix in ipairs(GroomingConfig.stages[sex][kind]) do
        if info and info.name:upper():sub(1,#prefix)==prefix then return index end
    end
    return 1
end
function G.state(app)
    local saved=A.decode(app.components.__grooming)
    local out={}
    for _,kind in ipairs({'hair','beard'}) do
        local stages=GroomingConfig.stages[A.sex(app.isMale)][kind]
        if stages then
            local data=A.decode(saved[kind])
            out[kind]={stage=math.floor(A.number(data.stage,0,#stages,stageFor(app,kind))),seconds=A.number(data.seconds,0,864000,0)}
        end
    end
    return out
end
function G.info(app)
    local out=G.state(app)
    for kind,data in pairs(out) do
        local cap=#GroomingConfig.stages[A.sex(app.isMale)][kind]
        data.remainingMinutes=data.stage==cap and 0 or math.max(0,GroomingConfig.minutesPerStage[kind]-data.seconds/60)
    end
    return out
end
function G.advance(app,seconds)
    local state=G.state(app); local changed=false
    local sex=A.sex(app.isMale)
    for kind,data in pairs(state) do
        local stages=GroomingConfig.stages[sex][kind]
        local interval=math.max(1,GroomingConfig.minutesPerStage[kind])*60
        data.seconds=data.seconds+math.max(0,seconds)
        while data.seconds>=interval and data.stage<#stages do
            data.seconds=data.seconds-interval;data.stage=data.stage+1
            local category=kind=='beard' and 'mustache' or 'hair'
            local cat=A.catalog(sex)[category]
            local previous=cat.hashes[app.components[category] or 0]
            local color=previous and previous.name:upper():match('_[HB][AE][IA][RR]D?_%d+_(.+)') or 'BROWN'
            local hash=A.resolve(sex,category,GetHashKey(stages[data.stage]..(color or 'BROWN')))
            if hash then app.components[category]=hash;changed=true end
        end
        if data.stage==#stages then data.seconds=0 end
    end
    app.components.__grooming=state
    return changed
end
function G.cut(app,previous)
    local state=G.state(previous)
    for kind,data in pairs(state) do
        local category=kind=='beard' and 'mustache' or 'hair'
        if app.components[category]~=previous.components[category] then
            data.stage=stageFor(app,kind);data.seconds=0
        end
    end
    app.components.__grooming=state
end
