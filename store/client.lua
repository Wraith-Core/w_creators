-- =====================================================================
--  store/client.lua
--  The clothing shops and the wardrobes: w_lib prompts, blips and peds, and a w_creators interface.
-- =====================================================================

local storePeds = {}      -- [index] = ped
local storeBlips = {}
local activeStore = nil   -- the shop we are standing at right now
local storePrompts = {}   -- { rec = w.prompt.at record, label = the title's dictionary key }
local inFittingRoom = false
local uiOpen = false      -- the shop/wardrobe interface is on screen
local savedCoords = nil   -- the player's position before entering the fitting room
local enterFittingRoom    -- defined below the prompts that call it

-- ---------------------------------------------------------------------
--  The blips
-- ---------------------------------------------------------------------

--- The blips through the library (removed by it when the resource stops). The names are
--  dictionary keys, so the blips are rebuilt on a language switch.
local function createBlips()
    for _, b in ipairs(storeBlips) do RemoveBlip(b) end
    storeBlips = {}
    for _,place in ipairs(GroomingConfig.barbers) do
        local b=w.blip.create(place.coords,locale('الحلاق'),'blip_shop_barber')
        if b then storeBlips[#storeBlips+1]=b end
    end

    for i = 1, #StoreData.stores do
        local s = StoreData.stores[i]
        if s.blip then
            local b = w.blip.create(vector3(s.book.x, s.book.y, s.book.z), locale(s.name), 'blip_shop_clothing')
            if b then storeBlips[#storeBlips + 1] = b end
        end
    end
    for i = 1, #StoreData.wardrobes do
        local w_ = StoreData.wardrobes[i]
        if w_.blip then
            local b = w.blip.create(w_.coords, locale('الخزانة'), 'blip_shop_clothing')
            if b then storeBlips[#storeBlips + 1] = b end
        end
    end
end

-- ---------------------------------------------------------------------
--  The tailors
-- ---------------------------------------------------------------------

--- The tailors through the library: it streams the model, applies a random outfit and deletes
--  the peds when the resource stops. The frozen/invincible flags are applied after.
local function spawnTailors()
    for i = 1, #StoreData.stores do
        local s = StoreData.stores[i]
        if s.ped and s.ped.coords then
            local ped = w.entity.create(s.ped.model, s.ped.coords, false)
            if ped then
                NativeUpdatePedVariation(ped)
                SetEntityCanBeDamaged(ped, false)
                SetEntityInvincible(ped, true)
                FreezeEntityPosition(ped, true)
                SetBlockingOfNonTemporaryEvents(ped, true)
                storePeds[i] = ped
            end
        end
    end
end

-- ---------------------------------------------------------------------
--  The prompts: one library proximity prompt (w.prompt.at) per shop and per wardrobe.
--  The library shows the group while the player stands within StoreData.promptDistance of the
--  spot, reads the key itself and runs onComplete; nothing here polls a key or a distance.
-- ---------------------------------------------------------------------

local function openKey()
    return StoreData.openKey or 'E'
end

--- The prompt is usable outside the fitting room and while the interface is closed.
local function canInteract()
    return not inFittingRoom and not uiOpen and not CreationMode and not IsEntityDead(PlayerPedId())
end

---@param coords vector3 the spot the prompt sits at
---@param label string the title's dictionary key (the shop's name or the wardrobe)
---@param kind 'store'|'wardrobe'
---@param place table the StoreData entry (activeStore while standing there)
local function createStorePrompt(coords, label, kind, place, index)
    local rec = w.prompt.at({
        coords = coords,
        distance = StoreData.promptDistance,
        title = locale(label),
        prompts = {
            {
                key = openKey(),
                label = locale('فتح'),
                hold = false,
                onComplete = function()
                    OpenStoreUI(kind,index,place)
                end,
            },
        },
        canInteract = canInteract,
        onEnter = function() activeStore = place end,
        onExit = function() if activeStore == place then activeStore = nil end end,
    })
    storePrompts[#storePrompts + 1] = { rec = rec, label = label }
end

local function createPrompts()
    for i,place in ipairs(GroomingConfig.barbers) do
        createStorePrompt(place.coords,'الحلاق','barber',place,i)
    end
    for i = 1, #StoreData.stores do
        local s = StoreData.stores[i]
        createStorePrompt(vector3(s.book.x, s.book.y, s.book.z), s.name, 'store', s, i)
    end
    for i = 1, #StoreData.wardrobes do
        local w_ = StoreData.wardrobes[i]
        createStorePrompt(w_.coords, 'الخزانة', 'wardrobe', w_, i)
    end
end

local function destroyPrompts()
    for i = 1, #storePrompts do
        pcall(storePrompts[i].rec.remove)
    end
    storePrompts = {}
    activeStore = nil
end

-- ---------------------------------------------------------------------
--  The fitting room: isolation in a world of its own so nobody clashes with anybody
-- ---------------------------------------------------------------------

enterFittingRoom = function(store)
    if inFittingRoom then return end
    inFittingRoom = true

    local ped = PlayerPedId()
    savedCoords = GetEntityCoords(ped)

    TriggerServerEvent('w_creators:server:isolate')

    StartFade(400, 'wardrobe')
    local f = store.fittingRoom
    SetEntityCoords(ped, f.x, f.y, f.z, false, false, false, false)
    SetEntityHeading(ped, f.w)
    RequestCollisionAtCoord(f.x, f.y, f.z)

    local deadline = GetGameTimer() + 8000
    while not HasCollisionLoadedAroundEntity(ped) and GetGameTimer() < deadline do Wait(0) end

    SuppressGameHud()
    SetCustomHudVisible(false)
    EndFade(400)
end

function LeaveFittingRoom()
    if not inFittingRoom then return end
    inFittingRoom = false

    StartFade(400, 'wardrobe')
    local ped = PlayerPedId()
    if savedCoords then
        SetEntityCoords(ped, savedCoords.x, savedCoords.y, savedCoords.z, false, false, false, false)
        savedCoords = nil
    end

    TriggerServerEvent('w_creators:server:rejoinWorld')
    SetCustomHudVisible(true)
    w.setRadarVisible(true)
    EndFade(400)
end

function IsInFittingRoom() return inFittingRoom end
function GetActiveStore() return activeStore end

-- ---------------------------------------------------------------------
--  The world objects: the blips, the tailors and the prompts
-- ---------------------------------------------------------------------

CreateThread(function()
    createBlips()
    spawnTailors()
    createPrompts()
end)

--- The language switch: the blip names and the prompts are relabelled from the dictionary.
--  The tailors and the blips themselves are removed by the library when the resource stops.
OnLanguageChange(function()
    createBlips()
    for i = 1, #storePrompts do
        local p = storePrompts[i]
        pcall(function()
            p.rec.setTitle(locale(p.label))
            p.rec.setLabel(openKey(), locale('فتح'))
        end)
    end
end)

AddEventHandler('onResourceStop', function(resource)
    if resource ~= GetCurrentResourceName() then return end
    destroyPrompts()
end)

-- All three shop modes use the same editor, camera and cancellation snapshot.
local shopToken
local function finishShop()
    local ped=PlayerPedId()
    FreezeEntityPosition(ped,false)
    RenderScriptCams(false,false,0,true,true,0)
    DestroyAllCams(true);ResetCreatorCamState();ClearFocus()
    SetNuiFocus(false,false);SetNuiFocusKeepInput(false)
    uiOpen=false
    if shopToken then TriggerServerEvent('w_creators:store:close',shopToken);shopToken=nil end
    LeaveFittingRoom()
    SetCustomHudVisible(true);w.setRadarVisible(true)
end
function OpenStoreUI(kind,index,place)
    if uiOpen or CreationMode or WCEditor.session then return end
    uiOpen=true
    local ok,err=pcall(function()
        local response=w.callback.await('w_creators:store:open',false,kind,index)
        if not response or not response.ok then
            uiOpen=false
            w.notify({description=locale(response and response.error or 'تعذر فتح المتجر'),type='error'})
            return
        end
        shopToken=response.token
        if kind=='store' and place then enterFittingRoom(place) end
        local ped=PlayerPedId()
        ClearPedTasksImmediately(ped);FreezeEntityPosition(ped,true)
        SetCustomHudVisible(false);w.setRadarVisible(false)
        WCEditor.open(ped,kind,response.appearance,{
            title=place and (place.town or place.name or '') or 'الخزانة',
            owned=response.owned,growth=response.growth,
            finish=function(app)
                local result=w.callback.await('w_creators:store:save',false,shopToken,app)
                if not result or not result.ok then
                    return {ok=false,error=locale(result and result.error or 'تعذر حفظ التعديلات')}
                end
                ApplyCreatorAppearance(ped,result.appearance)
                CurrentCharacterAppearance=result.appearance
                WCEditor.close();finishShop()
                return {ok=true,closed=true}
            end,
            cancel=finishShop,
        })
    end)
    if not ok then
        w.print.error('could not open appearance editor: %s',err)
        WCEditor.close();finishShop()
    end
end
exports('OpenWardrobe',function() OpenStoreUI('wardrobe') end)
function IsCreatorShopOpen() return uiOpen end
CreateThread(function()
    while true do
        if uiOpen then
            DisableAllControlActions(0);SuppressGameHud()
            if IsEntityDead(PlayerPedId()) then
                WCEditor.close();finishShop()
            end
            Wait(0)
        else Wait(250) end
    end
end)
RegisterNetEvent('w_creators:client:grooming',function(app)
    if uiOpen or CreationMode then return end
    -- Only hair slots change during play. Do not reset health, clothes, morphs or tasks.
    local ped=PlayerPedId();local normalized=CreatorAppearance.normalize(app)
    for _,category in ipairs({'hair','mustache'}) do
        local hash=normalized.components[category]
        if hash and hash~=0 then ApplyComponentHash(ped,hash,category=='mustache' and 0xF8016BCA or category)
        elseif hash==0 then RemoveComponentCategory(ped,category=='mustache' and 0xF8016BCA or category) end
    end
    NativeUpdatePedVariation(ped)
    CurrentCharacterAppearance=normalized
end)
AddEventHandler('onResourceStop',function(resource)
    if resource~=GetCurrentResourceName() or not uiOpen then return end
    if WCEditor.session then pcall(ApplyCreatorAppearance,PlayerPedId(),WCEditor.session.original) end
    WCEditor.close();FreezeEntityPosition(PlayerPedId(),false)
    if savedCoords then SetEntityCoords(PlayerPedId(),savedCoords.x,savedCoords.y,savedCoords.z,false,false,false,false) end
    RenderScriptCams(false,false,0,true,true,0);SetCustomHudVisible(true);w.setRadarVisible(true)
    TriggerServerEvent('w_creators:server:rejoinWorld')
end)
