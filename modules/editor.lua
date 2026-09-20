-- One editor and one serial mutation queue for creator, tailor, wardrobe and barber.
WCEditor = { session = nil }
local E, A = WCEditor, CreatorAppearance
local sequence = 0
local function label(key) return locale(key) end
local names = {heads='الوجه', BODIES_UPPER='شكل الجسم', hair='الشعر', mustache='اللحية', eyes='العينان', teeth='الأسنان'}
local function allowed(session, category)
    if session.mode == 'creator' then return true end
    if session.mode == 'barber' then return category == 'hair' or (session.app.isMale and category == 'mustache') end
    return StoreData.prices[category] ~= nil and StoreData.prices[category] >= 0
end
local function featureFields()
    local fields={}
    for _,field in ipairs(CreatorFeatureFields) do
        local hash=field.hash or w.component.data.expressions[field.expression]
        if hash then fields[#fields+1]={id=field.id,name=label(field.name),hash=hash,expression=field.expression,section=field.section} end
    end
    return fields
end
function E.payload(s)
    local cats, sex = {}, A.sex(s.app.isMale)
    local order = {'heads','eyes','teeth','BODIES_UPPER','hair','mustache'}
    local extras = {}; for category in pairs(StoreData.prices) do extras[#extras+1]=category end; table.sort(extras)
    for _, category in ipairs(extras) do order[#order+1]=category end
    for _, category in ipairs(order) do
        local cat = A.catalog(sex)[category]
        if cat and allowed(s, category) then
            local hash = s.app.components[category] or 0
            local selected = cat.hashes[hash]
            local models = {}
            for mi, variants in ipairs(cat.models) do
                local choices = {}
                for vi, variant in ipairs(variants) do
                    if s.mode ~= 'wardrobe' or s.owned[tostring(variant.hash)] or s.original.components[category] == variant.hash then
                        choices[#choices+1] = {index=vi,hash=variant.hash}
                    end
                end
                if #choices > 0 then models[#models+1]={index=mi,variants=choices} end
            end
            cats[#cats+1] = {id=category,name=label(names[category] or StoreData.categoryNames[category] or category),
                models=models,model=selected and selected.model or 0,variant=selected and selected.variant or 1,
                essential=A.essential[category] or false,price=StoreData.prices[category] or 0,
                owned=s.owned[tostring(hash)] or s.original.components[category] == hash,
                section=(category=='hair' or category=='mustache') and 'hair' or (A.essential[category] and 'base' or 'clothes')}
        end
    end
    local overlays = {}
    if s.mode == 'creator' then
        for category, def in pairs(OverlayMap) do
            local selected = {offsetModel=0, offsetVariation=1, opacity=1}
            for _, item in ipairs(s.app.overlays) do if item.compType == category then selected=item; break end end
            local models, seen = {}, {}
            for index, id in ipairs(def.ids) do if not seen[id] then models[#models+1]=index; seen[id]=true end end
            overlays[#overlays+1]={id=category,name=label(E.overlayNames[category] or category),models=models,value=selected}
        end
        table.sort(overlays,function(a,b) return a.id<b.id end)
    end
    local total = 0
    if s.mode == 'store' then
        for category, price in pairs(StoreData.prices) do
            local hash=s.app.components[category]
            if hash and hash~=0 and hash~=s.original.components[category] and not s.owned[tostring(hash)] then total=total+math.max(price,0) end
        end
    elseif s.mode == 'barber' and (s.app.components.hair~=s.original.components.hair or s.app.components.mustache~=s.original.components.mustache) then total=GroomingConfig.price end
    return {type='editor',id=s.id,mode=s.mode,locale=UiLocale(),title=label(s.title),app=s.app,categories=cats,
        features=s.mode=='creator' and featureFields() or {},overlays=overlays,price=total,growth=s.growth}
end
E.overlayNames = {acne='حب الشباب',ageing='التجاعيد',beardstabble='ظل اللحية',blush='أحمر الخدود',complex='البشرة',
    disc='تفاوت البشرة',eyebrows='الحاجبان',eyeliners='كحل العين',foundation='كريم الأساس',freckles='النمش',grime='الأوساخ',
    hairov='شعر الرأس الخفيف',lipsticks='أحمر الشفاه',moles='الشامات',paintedmasks='طلاء الوجه',scars='الندوب',shadows='ظلال العين',spots='البقع'}
function E.open(ped, mode, app, opts)
    if E.session then return false end
    assert(ped and ped ~= 0 and DoesEntityExist(ped), 'cannot edit a missing character')
    opts=opts or {}; sequence=sequence+1
    local snapshot=A.normalize(app)
    local s={id=sequence,ped=ped,mode=mode,app=snapshot,original=A.copy(snapshot),owned=opts.owned or {},
        title=opts.title or '',growth=opts.growth,finish=opts.finish,cancel=opts.cancel,history={}}
    ApplyCreatorAppearance(ped,s.app)
    CreatorScene.ready(ped)
    CreatorScene.show(ped)
    E.session=s
    SetNuiFocus(true,true); SetNuiFocusKeepInput(false)
    MouseControlEnabled=true
    ResetCreatorCamState(); assert(MoveCreatorCam(mode=='barber' and 'head' or 'default',ped,true), 'could not frame the edited character')
    s.prompts=w.prompt.createGroup(label(mode=='creator' and 'بناء الشخصية' or mode=='barber' and 'الحلاق' or 'متجر الملابس'), 'bottom-right')
    s.prompts.addPrompt('MOUSEDRAG',label('تدوير الشخصية'),false)
    s.prompts.addPrompt('ESCAPE',label('رجوع'),false)
    s.prompts.display()
    SendNUIMessage(E.payload(s))
    return true
end
function E.close()
    local s=E.session; if not s then return end
    E.session=nil
    if s.prompts then s.prompts.delete() end
    SetNuiFocus(false,false); SetNuiFocusKeepInput(false); MouseControlEnabled=false
    SendNUIMessage({type='editorClose'})
end
local function mutate(s,data)
    local updates
    if data.action=='features' then
        if s.mode~='creator' or type(data.values)~='table' then error('invalid feature edit') end
        updates={}
        local known={};for _,field in ipairs(featureFields()) do known[field.id]=field end
        for id,value in pairs(data.values) do
            if not known[id] or type(value)~='number' or value~=value or value < -1 or value > 1 or #updates>=2 then error('invalid feature axis') end
            updates[#updates+1]={field=known[id],value=value}
        end
        if #updates==0 then error('empty feature edit') end
    end
    if data.action=='undo' then
        if #s.history>0 then s.app=table.remove(s.history) end
        return
    end
    s.history[#s.history+1]=A.copy(s.app); if #s.history>30 then table.remove(s.history,1) end
    if data.action=='reset' then s.app=A.copy(s.original)
    elseif data.action=='component' and allowed(s,data.category) then
        if s.mode=='wardrobe' and tonumber(data.model)~=0 then
            local cat=A.catalog(A.sex(s.app.isMale))[data.category]
            local variants=cat and cat.models[tonumber(data.model)]
            local choice=variants and variants[tonumber(data.variant)]
            if not choice or (not s.owned[tostring(choice.hash)] and s.original.components[data.category]~=choice.hash) then
                data.variant=nil
                for index,variant in ipairs(variants or {}) do
                    if s.owned[tostring(variant.hash)] or s.original.components[data.category]==variant.hash then data.variant=index;break end
                end
                if not data.variant then return end
            end
        end
        A.setChoice(s.app,data.category,data.model,data.variant)
    elseif s.mode=='creator' and data.action=='random' then
        local sex=A.sex(s.app.isMale)
        local cats=A.catalog(sex)
        -- Randomize only valid face/body/hair entries. Clothing, masks and overlays stay deliberate choices.
        local tone=math.random(1,6)
        for _, category in ipairs({'heads','BODIES_UPPER','eyes','hair','teeth'}) do
            local cat=cats[category]
            local model=math.random(1,math.min(#cat.models,category=='hair' and (sex=='male' and 25 or 27) or #cat.models))
            A.setChoice(s.app,category,model,A.essential[category] and (category=='eyes' and math.random(1,14) or category=='teeth' and 1 or tone) or math.random(1,#cat.models[model]))
        end
        s.app.faceFeatures={}
        s.app.components.__expressions={}
        for _, field in ipairs(featureFields()) do
            if not field.expression then s.app.faceFeatures[#s.app.faceFeatures+1]={hash=field.hash,index=math.random(-25,25)/100} end
        end
    elseif updates then
        for _,update in ipairs(updates) do
            local field,value=update.field,update.value
            if field.expression then s.app.components.__expressions[field.expression]=value
            else
                local found=false
                for _,feature in ipairs(s.app.faceFeatures) do if feature.hash==field.hash then feature.index=value;found=true;break end end
                if not found then s.app.faceFeatures[#s.app.faceFeatures+1]={hash=field.hash,index=value} end
            end
        end
    elseif s.mode=='creator' and data.action=='feature' then
        for _, field in ipairs(featureFields()) do
            if field.id==data.field then
                local value=A.number(data.value,-1,1,0)
                if field.expression then s.app.components.__expressions[field.expression]=value
                else
                    local found=false
                    for _, f in ipairs(s.app.faceFeatures) do if f.hash==field.hash then f.index=value;found=true;break end end
                    if not found then s.app.faceFeatures[#s.app.faceFeatures+1]={hash=field.hash,index=value} end
                end
                break
            end
        end
    elseif s.mode=='creator' and data.action=='body' then
        if data.field=='scale' then s.app.components.__scale=A.number(data.value,.9,1.1,1)
        elseif data.field=='waist' then s.app.components.__waist=math.floor(A.number(data.value,1,21,11)) end
    elseif s.mode=='creator' and data.action=='overlay' and OverlayMap[data.category] then
        local found
        for _, item in ipairs(s.app.overlays) do if item.compType==data.category then found=item;break end end
        if not found then found={compType=data.category};s.app.overlays[#s.app.overlays+1]=found end
        found.offsetModel=data.model;found.offsetVariation=data.color;found.opacity=data.opacity
    end
    s.app=A.normalize(s.app)
end
RegisterNUICallback('editor:action',function(data,cb)
    local s=E.session
    if type(data)~='table' or not s or data.id~=s.id or s.busy then cb({ok=false,error='busy'});return end
    s.busy=true
    local original,history=A.copy(s.app),{table.unpack(s.history)}
    local ok,result=pcall(function()
        if data.action=='save' then
            return s.finish(A.copy(s.app),data.identity)
        elseif data.action=='cancel' then
            ApplyCreatorAppearance(s.ped,s.original)
            E.close(); if s.cancel then s.cancel() end
            return {ok=true,closed=true}
        else
            local previous=A.copy(s.app)
            mutate(s,data)
            UpdateCreatorAppearance(s.ped,previous,s.app)
            return {ok=true,payload=E.payload(s)}
        end
    end)
    s.busy=false
    if not ok then
        if E.session==s and data.action~='save' and data.action~='cancel' then
            s.app,s.history=original,history
            pcall(ApplyCreatorAppearance,s.ped,original)
        end
        w.print.error('editor action failed: %s',result);cb({ok=false,error=label('تعذر تطبيق التعديل')})
    else cb(result or {ok=true}) end
end)
RegisterNUICallback('editor:camera',function(data,cb)
    local s=E.session
    if type(data)~='table' or not s or (data.id and data.id~=s.id) or s.busy then cb({ok=false});return end
    if data.reset then ResetCamOffsets()
    elseif type(data.pick)=='table' then
        local part=w.raycast.pedPartFromScreen(s.ped,data.pick.x,data.pick.y,data.pick.aspect)
        if part then
            CamZoom,CamHeight=0.0,0.0
            MoveCreatorCam(part,s.ped,true)
        end
    elseif data.rotate then SetEntityHeading(s.ped,(GetEntityHeading(s.ped)+A.number(data.rotate,-180,180,0))%360)
    elseif data.zoom then NudgeCamZoom(A.number(data.zoom,-4,4,0))
    else MoveCreatorCam(data.part or 'default',s.ped,true) end
    cb({ok=true,part=CurrentCamDestination()})
end)
OnLanguageChange(function()
    local s=E.session
    if not s then return end
    SendNUIMessage(E.payload(s));MoveCreatorCam(CurrentCamDestination(),s.ped,true)
    if s.prompts then
        s.prompts.setTitle(label(s.mode=='creator' and 'بناء الشخصية' or s.mode=='barber' and 'الحلاق' or 'متجر الملابس'))
        s.prompts.setLabel('MOUSEDRAG',label('تدوير الشخصية'))
        s.prompts.setLabel('ESCAPE',label('رجوع'))
    end
end)
