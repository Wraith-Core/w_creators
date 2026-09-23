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
--  The scene values live in Config.Creator.cutscene (config/main.lua; the coordinates only there,
--  the other fields default to the constants below). WCCutscene.configured() is false without the
--  three coordinates: the ride is skipped and the character placed as without the cutscene.
--  The arrival is checked by a 250 ms loop that only runs during the cutscene; the input and the
--  cinematic bars need a per-frame request (DisableAllControlActions, _REQUEST_LETTER_BOX_NOW), so
--  a presentation loop runs every frame, also only during the cutscene.
--
--  Public: WCCutscene.active(), WCCutscene.stop(), WCCutscene.configured(); net event
--  W:CREATOR:FirstSpawn.
-- =====================================================================

WCCutscene = {}
local Cut = WCCutscene

-- The pre-v3 scene's settings (creator/spawn.lua). Config.Creator.cutscene overrides any of them
-- and holds the coordinates (start, arrival, departure: config/main.lua); a ride whose coordinates
-- are not all configured is not played (the new character is placed as without the cutscene).
local DEFAULTS = {
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
local COORD_KEYS = { start = true, arrival = true, departure = true } -- config only (no default)
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
            if DEFAULTS[k] == nil and not COORD_KEYS[k] then
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
    x, y, z = x + 0.0, y + 0.0, z + 0.0 -- a table-form config may hold integers (float natives)
    SetEntityCoords(ped, x, y, z, false, false, false, false)
    if heading then SetEntityHeading(ped, heading + 0.0) end
    RequestCollisionAtCoord(x, y, z)
    WCUtil.waitUntil(function() return HasCollisionLoadedAroundEntity(ped) end, COLLISION_TIMEOUT, 0)
end

--- A newer ride or a stop (Cut.stop: respawn, resource stop) took over since this ride began.
--- Every yield of a ride (fade, collision, model streaming, seating, departure) is followed by this
--- check: a stale ride only removes the entities it created itself and never touches the player,
--- the screen, the cinematic mode or st.wagon / st.driver again (those now belong to the newer owner).
local function stale(gen) return gen ~= st.generation end

--- The end of the ride: the player gets off, the driver takes the wagon away, then both go.
--- The handles are this ride's own: a newer ride (or a stop) may replace st.wagon / st.driver
--- meanwhile, and these must still go.
local function arrive(gen, s, wagon, driver)
    local ped = PlayerPedId()
    st.active = false
    if entityExists(driver) then RemovePedFromGroup(driver, GetPedGroupIndex(ped)) end
    releasePlayer()
    endPresentation()
    if entityExists(wagon) then
        TaskLeaveVehicle(ped, wagon, 0, 0)
        WCUtil.waitUntil(function() return not IsPedInVehicle(ped, wagon, false) end, SEAT_TIMEOUT, CHECK_MS)
        if stale(gen) then return deletePair(wagon, driver) end
        if entityExists(driver) then
            local dx, dy, dz = xyz(s.departure)
            TaskVehicleDriveToCoord(driver, wagon, dx, dy, dz, s.speed + 0.0, 1.0,
                GetEntityModel(wagon), s.drivingStyle, 5.0, false)
        end
    end
    storyNotify(ARRIVAL_NOTICE, ARRIVAL_NOTICE_MS)
    TriggerMusicEvent('MC_MUSIC_STOP')
    -- presentation pacing, not synchronisation: the empty wagon drives off before it is removed.
    Wait(s.departureDelay)
    deletePair(wagon, driver)
    if st.wagon == wagon then st.wagon = nil end
    if st.driver == driver then st.driver = nil end
end

--- Something went wrong (no wagon, no driver, never arrived): the player is placed at the arrival.
--- wagon / driver are this ride's own entities (either may be nil). A stale ride only removes them:
--- the player now belongs to whoever stopped it (respawn) or to the newer ride.
local function fallback(gen, s, reason, wagon, driver)
    if stale(gen) then return deletePair(wagon, driver) end
    WCDebug.warn('creator', 'first-spawn cutscene ended early: %s', tostring(reason))
    st.active = false
    endPresentation()
    deletePair(wagon, driver)
    deleteEntities()
    local ped = PlayerPedId()
    if IsPedInAnyVehicle(ped, false) then ClearPedTasksImmediately(ped) end
    local x, y, z = xyz(s.arrival)
    placePlayer(x, y, z)
    if stale(gen) then return end -- stopped while the collision loaded: the stop released him
    releasePlayer()
    TriggerMusicEvent('MC_MUSIC_STOP')
    reveal()
end

--- The driver of this ride's wagon. Returns nil when it cannot be created, or when the ride went
--- stale while its model streamed (the driver just created is removed again).
local function spawnDriver(gen, s, wagon)
    local model = GetHashKey(s.driver)
    if not IsModelValid(model) then return nil end
    local sx, sy, sz, sh = xyz(s.start)
    local driver = w.entity.create(s.driver, vector4(sx, sy, sz, sh), false)
    if stale(gen) then
        deletePair(nil, driver)
        return nil
    end
    if not entityExists(driver) then return nil end
    local ped = PlayerPedId()
    SetEntityNoCollisionEntity(ped, driver, false)
    SetEntityCanBeDamaged(driver, false)
    SetEntityInvincible(driver, true)
    SetBlockingOfNonTemporaryEvents(driver, true)
    SetEntityAsMissionEntity(driver, true, true)
    SetPedAsGroupMember(driver, GetPedGroupIndex(ped))
    SetRelationshipBetweenGroups(1, GetHashKey('PLAYER'), GetPedRelationshipGroupHash(driver))
    SetPedIntoVehicle(driver, wagon, SEAT_DRIVER)
    local ax, ay, az = xyz(s.arrival)
    TaskVehicleDriveToCoord(driver, wagon, ax, ay, az, s.speed + 0.0, 1.0, GetEntityModel(wagon),
        s.drivingStyle, 5.0, false)
    WCNative.ped.setKeepTask(driver, true)
    return driver
end

--- The ride. Every yield is followed by a stale(gen) check (see stale()); the wagon and driver are
--- kept in locals and published to st.wagon / st.driver only while this ride is still current, so
--- a stop during the setup (WCSpawn.respawn -> Cut.stop) is final: no entity leaks, no re-seat, no
--- cinematic mode left on.
local function play()
    local s = settings()
    st.generation = st.generation + 1
    local gen = st.generation
    st.active = true
    -- a previous ride still driving off: its wagon and driver go now
    deleteEntities()
    local ped = PlayerPedId()
    if not IsScreenFadedOut() then StartFade(500, 'spawn') end
    if stale(gen) then return end
    TriggerMusicEvent('REHR_START')
    NetworkSetEntityOnlyExistsForParticipants(ped, true)
    SetEntityInvincible(ped, true)
    local sx, sy, sz, sh = xyz(s.start)
    placePlayer(sx, sy, sz, sh)
    if stale(gen) then return end -- the stop released the player

    local wagon = w.entity.create(s.wagon, vector4(sx, sy, sz, sh), true)
    if stale(gen) then return deletePair(wagon, nil) end
    if not entityExists(wagon) then return fallback(gen, s, 'wagon') end
    st.wagon = wagon
    SetVehicleOnGroundProperly(wagon)
    local driver = spawnDriver(gen, s, wagon)
    if stale(gen) then return deletePair(wagon, driver) end
    if not driver then return fallback(gen, s, 'driver', wagon) end
    st.driver = driver
    SetPedIntoVehicle(ped, wagon, SEAT_PASSENGER)
    local seated = WCUtil.waitUntil(function() return IsPedInVehicle(ped, wagon, false) end, SEAT_TIMEOUT, 0)
    if stale(gen) then return deletePair(wagon, driver) end
    if not seated then return fallback(gen, s, 'seat', wagon, driver) end

    SetCinematicModeActive(true)
    presentation(gen)
    reveal()
    playStory(gen)

    -- the arrival check (4 Hz, only while the ride runs)
    local ax, ay, az = xyz(s.arrival)
    local target = vector3(ax, ay, az)
    local deadline = GetGameTimer() + s.maxDuration
    while st.active and not stale(gen) do
        local me = PlayerPedId()
        if #(GetEntityCoords(me) - target) < s.arriveRadius then return arrive(gen, s, wagon, driver) end
        if IsEntityDead(me) or not entityExists(wagon) or GetGameTimer() > deadline then
            return fallback(gen, s, 'interrupted', wagon, driver)
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
    if stale(gen) then return end -- a stop (respawn) during the collision wait owns the screen now
    reveal()
    playStory(gen)
end

--- Is the ride running?
function Cut.active() return st.active end

--- Are the ride's coordinates (start, arrival, departure) configured?
function Cut.configured()
    local s = settings()
    for key in pairs(COORD_KEYS) do
        if s[key] == nil then return false end
    end
    return true
end

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
        if Config.Creator.enableCutscene == true and Cut.configured() then
            ok, err = pcall(play)
        else
            if Config.Creator.enableCutscene == true then
                WCDebug.warn('creator', 'Config.Creator.cutscene needs start, arrival and departure: ride skipped')
            end
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
