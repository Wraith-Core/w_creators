-- =====================================================================
--  client/creator/cutscene.lua  —  WCCutscene: the optional first-spawn wagon scene
--  (Config.Creator.enableCutscene; ported from the pre-v3 creator/spawn.lua)
--
--  A stagecoach and its driver take the new character into Saint Denis while the story notices
--  play. It runs on the event W:CREATOR:FirstSpawn, which the spawn module (client/spawn/spawn.lua)
--  raises after the first spawn of a NEW character when Config.Creator.enableCutscene = true.
--  Config.Creator.spawnEvent must NOT be set to W:CREATOR:FirstSpawn: the server fires spawnEvent
--  for every spawn (login and switch too), so every existing character would take the ride (or,
--  with the cutscene disabled, lose his last location to Config.Spawn.firstSpawn).
--  With the cutscene disabled the event places the player at Config.Spawn.firstSpawn and plays the
--  notices only.
--
--  The scene values live in Config.Creator.cutscene when it exists (any field may be overridden);
--  otherwise the constants below (the pre-v3 coordinates) are used.
--  The arrival is checked by a 250 ms loop that only runs during the cutscene; the input and the
--  cinematic bars need a per-frame request (DisableAllControlActions, _REQUEST_LETTER_BOX_NOW), so
--  a presentation loop runs every frame, also only during the cutscene.
--
--  Public: WCCutscene.active(), WCCutscene.stop(); net event W:CREATOR:FirstSpawn.
-- =====================================================================

WCCutscene = {}
local Cut = WCCutscene

-- The pre-v3 scene (creator/spawn.lua). Config.Creator.cutscene overrides any of these fields.
local DEFAULTS = {
    start        = { 2520.09, -358.05, 41.61, 268.89169 }, -- the wagon and the player start here
    arrival      = { 2539.83, -1129.33, 50.03 },           -- Saint Denis: the ride ends here
    departure    = { 2600.436, -1205.932, 53.323 },        -- the driver takes the empty wagon here
    wagon        = 'STAGECOACH001X',
    driver       = 'CS_BivCoachDriver',
    arriveRadius = 5.0,
    speed        = 10.0,
    drivingStyle = 67633207,
    maxDuration  = 600000, -- a wagon that never arrives: the player is placed at the arrival
    departureDelay = 10000, -- the empty wagon drives off this long before it is removed
}

local CHECK_MS = 250
local COLLISION_TIMEOUT = 5000
local SEAT_TIMEOUT = 5000
local SEAT_PASSENGER = 1
local SEAT_DRIVER = -1

-- The story notices: { delay before it (ms), locale key, duration (ms) }.
local STORY = {
    { 5000, 'تحياتنا يا راعي البقر. أهلًا بك، انطلق واستكشف المناطق المختلفة واكتشف أسرار هذا العالم الجديد الذي ينتظرك.', 12000 },
    { 15000, 'اقرأ جدار القوانين لتبقى على اطّلاع بكل ما هو مسموح في السيرفر، وتتجنّب الأسئلة والمشاكل لاحقًا.', 10000 },
    { 15000, 'احذر وأنت تتجوّل عند الغسق في الغرب المتوحّش، فلا يبقى بعد حلول الظلام إلا المغامرون حقًا... يقولون إنه عالم مختلف تمامًا تحت ضوء القمر.', 12000 },
    { 18000, 'هذه سانت دينيس، أول مدينة تزورها. ستجد فيها متاجر عديدة: متجر ملابس، وحلّاق، ومركز شرطة، وغيرها. لكن تذكّر أن هناك عالمًا واسعًا في انتظارك لتستكشفه!', 18000 },
}
local ARRIVAL_NOTICE = 'فقدت كل ملابسك، هناك متجر ملابس على الجانب الآخر من الشارع، ما رأيك أن تذهب إليه لتبديل ثيابك؟'
local ARRIVAL_NOTICE_MS = 10000

local st = {
    active = false,     -- the ride is running
    presenting = false, -- the per-frame presentation loop runs
    wagon = nil,
    driver = nil,
    generation = 0,     -- bumped on every start / stop: stale threads end
}

-- How an override of each field is accepted: coordinates in any form CreatorScene.coords reads
-- (vector3 / vector4 at runtime, { x, y, z[, h] } arrays, { x =, y =, z = } tables), finite
-- numbers, non-empty model names.
local COORD_KEYS = { start = true, arrival = true, departure = true }
local MODEL_KEYS = { wagon = true, driver = true }

local function override(k, v)
    if COORD_KEYS[k] then
        local x = CreatorScene.coords(v)
        if x ~= nil then return v end
    elseif MODEL_KEYS[k] then
        if type(v) == 'string' and v ~= '' then return v end
    else
        local n = tonumber(v)
        if n ~= nil and WCUtil.isFinite(n) then return n end
    end
    return nil
end

local function settings()
    local out = {}
    for k, v in pairs(DEFAULTS) do out[k] = v end
    local custom = Config.Creator and Config.Creator.cutscene
    if type(custom) == 'table' then
        for k, v in pairs(custom) do
            if DEFAULTS[k] == nil then
                WCDebug.warn('creator', 'Config.Creator.cutscene.%s is not a cutscene setting; ignored', tostring(k))
            else
                local accepted = override(k, v)
                if accepted ~= nil then
                    out[k] = accepted
                else
                    WCDebug.warn('creator', 'Config.Creator.cutscene.%s has an invalid value; the default is used',
                        tostring(k))
                end
            end
        end
    end
    return out
end

local function xyz(c)
    local x, y, z, h = CreatorScene.coords(c)
    return x, y, z, h
end

local function entityExists(e)
    return type(e) == 'number' and e ~= 0 and DoesEntityExist(e) == true
end

local function storyNotify(key, duration)
    pcall(w.notify, { description = locale(key), duration = duration })
end

--- The story notices, paced as before; they stop when a newer scene starts or the resource stops.
local function playStory(gen)
    CreateThread(function()
        for _, notice in ipairs(STORY) do
            Wait(notice[1])
            if gen ~= st.generation then return end
            storyNotify(notice[2], notice[3])
        end
    end)
end

local function presentation(gen)
    st.presenting = true
    CreateThread(function()
        while st.presenting and gen == st.generation do
            DisableAllControlActions(0)
            WCNative.camera.letterbox(true, false)
            Wait(0)
        end
    end)
end

local function endPresentation()
    st.presenting = false
    pcall(SetCinematicModeActive, false)
    WCNative.camera.letterbox(false, false)
end

local function deletePair(wagon, driver)
    if entityExists(driver) then
        WCNative.ped.setKeepTask(driver, false)
        pcall(w.entity.delete, driver)
    end
    if entityExists(wagon) then pcall(w.entity.delete, wagon) end
end

local function deleteEntities()
    deletePair(st.wagon, st.driver)
    st.driver, st.wagon = nil, nil
end

--- Give the player back: visible to everybody, mortal, in control.
local function releasePlayer()
    local ped = PlayerPedId()
    NetworkSetEntityOnlyExistsForParticipants(ped, false)
    SetEntityInvincible(ped, false)
end

--- Fade in when this resource (or the previous screen) left the screen dark.
local function reveal()
    if WCurtain.held() or IsScreenFadedOut() or IsScreenFadingOut() then EndFade(500) end
end

local function placePlayer(x, y, z, heading)
    local ped = PlayerPedId()
    SetEntityCoords(ped, x, y, z, false, false, false, false)
    if heading then SetEntityHeading(ped, heading + 0.0) end
    RequestCollisionAtCoord(x, y, z)
    WCUtil.waitUntil(function() return HasCollisionLoadedAroundEntity(ped) end, COLLISION_TIMEOUT, 0)
end

--- The end of the ride: the player gets off, the driver takes the wagon away, then both go.
local function arrive(gen, s)
    local ped = PlayerPedId()
    st.active = false
    if entityExists(st.driver) then RemovePedFromGroup(st.driver, GetPedGroupIndex(ped)) end
    releasePlayer()
    endPresentation()
    if entityExists(st.wagon) then
        TaskLeaveVehicle(ped, st.wagon, 0, 0)
        WCUtil.waitUntil(function() return not IsPedInVehicle(ped, st.wagon, false) end, SEAT_TIMEOUT, CHECK_MS)
        if entityExists(st.driver) then
            local dx, dy, dz = xyz(s.departure)
            TaskVehicleDriveToCoord(st.driver, st.wagon, dx, dy, dz, s.speed + 0.0, 1.0,
                GetEntityModel(st.wagon), s.drivingStyle, 5.0, false)
        end
    end
    storyNotify(ARRIVAL_NOTICE, ARRIVAL_NOTICE_MS)
    TriggerMusicEvent('MC_MUSIC_STOP')
    -- presentation pacing, not synchronisation: the empty wagon drives off before it is removed.
    -- The handles are this ride's own: a newer ride (or a stop) may have replaced st.wagon /
    -- st.driver meanwhile, and these must still go.
    local wagon, driver = st.wagon, st.driver
    Wait(s.departureDelay)
    deletePair(wagon, driver)
    if st.wagon == wagon then st.wagon = nil end
    if st.driver == driver then st.driver = nil end
end

--- Something went wrong (no wagon, no driver, never arrived): the player is placed at the arrival.
local function fallback(gen, s, reason)
    WCDebug.warn('creator', 'first-spawn cutscene ended early: %s', tostring(reason))
    st.active = false
    endPresentation()
    deleteEntities()
    local ped = PlayerPedId()
    if IsPedInAnyVehicle(ped, false) then ClearPedTasksImmediately(ped) end
    local x, y, z = xyz(s.arrival)
    placePlayer(x, y, z)
    releasePlayer()
    TriggerMusicEvent('MC_MUSIC_STOP')
    if gen == st.generation then reveal() end
end

local function spawnDriver(s)
    local model = GetHashKey(s.driver)
    if not IsModelValid(model) then return nil end
    local sx, sy, sz, sh = xyz(s.start)
    local driver = w.entity.create(s.driver, vector4(sx, sy, sz, sh), false)
    if not entityExists(driver) then return nil end
    local ped = PlayerPedId()
    SetEntityNoCollisionEntity(ped, driver, false)
    SetEntityCanBeDamaged(driver, false)
    SetEntityInvincible(driver, true)
    SetBlockingOfNonTemporaryEvents(driver, true)
    SetEntityAsMissionEntity(driver, true, true)
    SetPedAsGroupMember(driver, GetPedGroupIndex(ped))
    SetRelationshipBetweenGroups(1, GetHashKey('PLAYER'), GetPedRelationshipGroupHash(driver))
    SetPedIntoVehicle(driver, st.wagon, SEAT_DRIVER)
    local ax, ay, az = xyz(s.arrival)
    TaskVehicleDriveToCoord(driver, st.wagon, ax, ay, az, s.speed + 0.0, 1.0, GetEntityModel(st.wagon),
        s.drivingStyle, 5.0, false)
    WCNative.ped.setKeepTask(driver, true)
    return driver
end

--- The ride.
local function play()
    local s = settings()
    st.generation = st.generation + 1
    local gen = st.generation
    st.active = true
    -- a previous ride still driving off: its wagon and driver go now
    deleteEntities()
    local ped = PlayerPedId()
    if not IsScreenFadedOut() then StartFade(500, 'spawn') end
    TriggerMusicEvent('REHR_START')
    NetworkSetEntityOnlyExistsForParticipants(ped, true)
    SetEntityInvincible(ped, true)
    local sx, sy, sz, sh = xyz(s.start)
    placePlayer(sx, sy, sz, sh)

    st.wagon = w.entity.create(s.wagon, vector4(sx, sy, sz, sh), true)
    if not entityExists(st.wagon) then return fallback(gen, s, 'wagon') end
    SetVehicleOnGroundProperly(st.wagon)
    st.driver = spawnDriver(s)
    if not st.driver then return fallback(gen, s, 'driver') end
    SetPedIntoVehicle(ped, st.wagon, SEAT_PASSENGER)
    if not WCUtil.waitUntil(function() return IsPedInVehicle(ped, st.wagon, false) end, SEAT_TIMEOUT, 0) then
        return fallback(gen, s, 'seat')
    end

    SetCinematicModeActive(true)
    presentation(gen)
    reveal()
    playStory(gen)

    -- the arrival check (4 Hz, only while the ride runs)
    local ax, ay, az = xyz(s.arrival)
    local target = vector3(ax, ay, az)
    local deadline = GetGameTimer() + s.maxDuration
    while st.active and gen == st.generation do
        local me = PlayerPedId()
        if #(GetEntityCoords(me) - target) < s.arriveRadius then return arrive(gen, s) end
        if IsEntityDead(me) or not entityExists(st.wagon) or GetGameTimer() > deadline then
            return fallback(gen, s, 'interrupted')
        end
        Wait(CHECK_MS)
    end
end

--- Without the cutscene: the new character is placed at Config.Spawn.firstSpawn.
local function plain()
    st.generation = st.generation + 1
    local gen = st.generation
    local first = Config.Spawn and Config.Spawn.firstSpawn or {}
    local x, y, z = WCUtil.xyz(first.coords)
    if x then placePlayer(x, y, z, tonumber(first.heading)) end
    reveal()
    playStory(gen)
end

--- Is the ride running?
function Cut.active() return st.active end

--- Stop everything the cutscene holds (resource stop, another flow taking over).
function Cut.stop()
    local held = st.active or st.presenting or st.wagon ~= nil or st.driver ~= nil
    st.generation = st.generation + 1
    st.active = false
    endPresentation()
    deleteEntities()
    if held then
        releasePlayer()
        pcall(TriggerMusicEvent, 'MC_MUSIC_STOP')
    end
end

RegisterNetEvent('W:CREATOR:FirstSpawn', function()
    CreateThread(function()
        if st.active then return end -- a second event during the ride is ignored
        local ok, err
        if Config.Creator.enableCutscene == true then
            ok, err = pcall(play)
        else
            ok, err = pcall(plain)
        end
        if not ok then
            WCDebug.warn('creator', 'first spawn failed: %s', tostring(err))
            Cut.stop()
            reveal()
        end
    end)
end)

AddEventHandler('onResourceStop', function(resource)
    if resource ~= GetCurrentResourceName() then return end
    pcall(Cut.stop)
end)
