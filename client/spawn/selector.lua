-- =====================================================================
--  client/spawn/selector.lua  —  WCSpawnSelector, the spawn location selector
--  (ARCHITECTURE.md §11, §16.3, §17)
--
--  An aerial camera orbits each town; the player steps with the prompts and confirms.
--  The server sends w_creators:client:selectSpawn { last = {x, y, z, heading, label} | nil,
--  points = { enabled point ids in order }, kind }. The ids are resolved against
--  Config.Spawn.points only for the camera and the labels: the confirmation sends the point ID
--  (w_creators:spawn:choose(id)) and never a coordinate — the server resolves it and answers with
--  w_creators:client:spawn (login kinds) or w_creators:client:respawn (admin), whose handler
--  (client/spawn/spawn.lua) places the player, closes this selector and fades in.
--
--  Why a library prompt group (w.prompt.createGroup) and not the native prompt: RDR's prompts go
--  through CreateVarString and do not support Arabic, so the town's name is the group's title.
--
--  Everything this file takes is given back: the camera (destroyed), the streaming focus
--  (cleared), the prompt group (deleted), and — when the flow ends without a spawn (a lost grant,
--  a spawn that never came, the resource stopping) — the player's freeze / invisibility /
--  invincibility, the world UI and the screen fade.
--
--    WCSpawnSelector.open(data) -> boolean     WCSpawnSelector.close(opts?)   opts.restore
--    WCSpawnSelector.active() / kind() / current() / points() / index()
--    WCSpawnSelector.resolve(data) -> points   WCSpawnSelector.move(delta)
--    WCSpawnSelector.confirm() -> boolean
-- =====================================================================

WCSpawnSelector = {}
local Sel = WCSpawnSelector

Sel.LAST_ID = '__last'           -- the 'the last place you were' option (server id)
Sel.INPUT_DELAY = 500            -- ms before the first input counts (an ENTER held from the previous screen)
Sel.UI_REASSERT = 2000           -- ms between two re-hides of the world UI (late HUD resources)
Sel.PROMPT_REASSERT = 250        -- ms between two checks that the prompt group is still displayed
-- The kinds opened on a player already in the world (not a login): the player may cancel.
Sel.CANCELABLE = { admin = true }
Sel.CANCEL_KEY = 'BACK'          -- [ BACKSPACE ] (Config.Spawn.selector.keys.cancel overrides it)
local CANCEL_LABEL = 'إلغاء'
local nextPromptCheck = 0
Sel.FADE_MARGIN = 2000           -- ms added to a fade's own duration when waiting for it
Sel.HANDOFF_TIMEOUT = 20000      -- ms to wait for the spawn event after an accepted choice
Sel.CONFIRM_FADE = 400

local active = false
local kind = nil
local points = {}       -- { {id, label, region, coords = vector3, heading, cam} }
local index = 1
local cam = nil
local orbitAngle = 0.0
local prompts = nil     -- the w.prompt.createGroup object
local busy = false      -- a transition or a confirmation is running
local inputReadyAt = 0
local nextUiHide = 0
local held = nil        -- { ped } while the player ped is frozen / hidden by the selector
local generation = 0    -- bumps on every open/close: stale frame threads stop
local focused = false   -- the streaming focus was moved by the selector

local function cfg() return (Config.Spawn and Config.Spawn.selector) or {} end
local function labels() return cfg().labels or {} end
local function keys() return cfg().keys or {} end
local function cancelKey()
    local key = keys().cancel
    return (type(key) == 'string' and key ~= '') and key or Sel.CANCEL_KEY
end

local function pedExists(ped)
    -- BOOL natives answer 1 (not true) on this runtime: never compare them with == true
    return type(ped) == 'number' and ped ~= 0 and not not DoesEntityExist(ped)
end

-- A named native that may be missing on a build (streaming helpers): never throws.
local function call(name, ...)
    local fn = _ENV[name]
    if type(fn) ~= 'function' then return false end
    local ok, value = pcall(fn, ...)
    return ok and value
end

local function notify(result)
    local key = type(result) == 'table' and (result.message or WCResult.messageKey(result.code))
        or WCResult.messageKey('INTERNAL_ERROR')
    pcall(w.notify, { description = locale(key) })
end

-- ---------------------------------------------------------------------
--  The points
-- ---------------------------------------------------------------------

local function configPoint(id)
    for _, pt in ipairs((Config.Spawn and Config.Spawn.points) or {}) do
        if type(pt) == 'table' and pt.id == id and pt.enabled ~= false then return pt end
    end
    return nil
end

--- Resolve the server's selectSpawn data into the selector's points (camera and labels only).
--  Unknown / disabled ids and invalid coordinates are skipped; the order is the server's.
---@param data table { last, points, kind }
---@return table points
function Sel.resolve(data)
    data = type(data) == 'table' and data or {}
    local out, seen = {}, {}
    local L = labels()
    local last
    if type(data.last) == 'table' then
        local x, y, z = WCUtil.xyz(data.last)
        if x then
            local heading = tonumber(data.last.heading)
            last = {
                id = Sel.LAST_ID,
                label = L.lastPosition,
                region = type(data.last.label) == 'string' and data.last.label or L.lastRegion,
                coords = vector3(x, y, z),
                heading = WCUtil.isFinite(heading) and heading or 0.0,
            }
        end
    end
    local preselect = not (Config.Spawn and Config.Spawn.lastLocation and Config.Spawn.lastLocation.preselect == false)
    if last and preselect then out[#out + 1] = last end
    for _, id in ipairs(type(data.points) == 'table' and data.points or {}) do
        local pt = type(id) == 'string' and not seen[id] and id ~= Sel.LAST_ID and configPoint(id) or nil
        local x, y, z
        if pt then x, y, z = WCUtil.xyz(pt.coords) end
        if x then
            seen[id] = true
            out[#out + 1] = {
                id = pt.id, label = pt.label, region = pt.region, coords = vector3(x, y, z),
                heading = tonumber(pt.heading) or 0.0, cam = type(pt.cam) == 'table' and pt.cam or nil,
            }
        end
    end
    if last and not preselect then out[#out + 1] = last end
    return out
end

-- ---------------------------------------------------------------------
--  The camera
-- ---------------------------------------------------------------------

local CAM_DEFAULTS = { dist = 110.0, height = 55.0, angle = 135.0, fov = 50.0, orbit = 1.5 }

--- A camera value for a point: the point's override, then Config.Spawn.camera, then the default.
local function camCfg(pt, key)
    local v = pt and pt.cam and tonumber(pt.cam[key])
    if v == nil then v = tonumber((Config.Spawn and Config.Spawn.camera or {})[key]) end
    if not WCUtil.isFinite(v) then v = CAM_DEFAULTS[key] end
    return v + 0.0
end

--- The camera position on a horizontal orbit around the point (aimed with PointCamAtCoord).
local function camPos(pt, angleDeg)
    local a = math.rad(angleDeg)
    local dist = camCfg(pt, 'dist')
    return pt.coords.x + dist * math.cos(a), pt.coords.y + dist * math.sin(a), pt.coords.z + camCfg(pt, 'height')
end

local function destroyCam()
    if cam and DoesCamExist(cam) then DestroyCam(cam, false) end
    cam = nil
end

--- Stream the point's area (the focus drives streaming; the player stands far away).
local function streamPoint(pt)
    local x, y, z = pt.coords.x, pt.coords.y, pt.coords.z
    SetFocusPosAndVel(x, y, z, 0.0, 0.0, 0.0)
    focused = true
    RequestCollisionAtCoord(x, y, z)
    local timeout = WCUtil.int(cfg().sceneTimeout, 0, 60000, 8000)
    if type(LoadSceneStart) == 'function' then
        call('LoadSceneStart', x, y, z, 0.0, 0.0, 0.0, 50.0, 0)
        WCUtil.waitUntil(function()
            local loaded = call('IsLoadSceneLoaded')
            return (loaded == true or loaded == 1) or nil
        end, timeout, 0)
        call('LoadSceneStop')
    end
end

local function fadeOut(ms)
    if IsScreenFadedOut() then return end
    DoScreenFadeOut(ms)
    WCUtil.waitUntil(function() return not IsScreenFadingOut() or nil end, ms + Sel.FADE_MARGIN, 0)
end

local function fadeIn(ms)
    DoScreenFadeIn(ms)
    WCUtil.waitUntil(function() return not IsScreenFadingIn() or nil end, ms + Sel.FADE_MARGIN, 0)
end

-- The prompt group's title: the town, its region and the position in the list.
local function currentTitle()
    local pt = points[index]
    if not pt then return locale(labels().title or '') end
    local name = locale(pt.label or '')
    if type(pt.region) == 'string' and pt.region ~= '' then
        name = ('%s — %s'):format(name, locale(pt.region))
    end
    return ('%s  (%d/%d)'):format(name, index, #points)
end

--- Show point i: fade out (unless withFade == false), stream, place a new camera, fade in.
local function showPoint(i, withFade)
    if #points == 0 then return end
    local dur = WCUtil.int(cfg().transition, 0, 5000, 350)
    if withFade ~= false then fadeOut(dur) end

    index = ((i - 1) % #points) + 1
    local pt = points[index]
    streamPoint(pt)
    if not active then return end -- closed while streaming

    orbitAngle = camCfg(pt, 'angle')
    local x, y, z = camPos(pt, orbitAngle)
    local previous = cam
    cam = CreateCam('DEFAULT_SCRIPTED_CAMERA', true)
    SetCamCoord(cam, x, y, z)
    SetCamFov(cam, camCfg(pt, 'fov'))
    PointCamAtCoord(cam, pt.coords.x, pt.coords.y, pt.coords.z)
    SetCamActive(cam, true)
    RenderScriptCams(true, false, 0, true, true, 0)
    if previous and previous ~= cam and DoesCamExist(previous) then DestroyCam(previous, false) end

    if prompts then pcall(prompts.setTitle, currentTitle()) end
    if withFade ~= false then fadeIn(dur) end
end

-- ---------------------------------------------------------------------
--  The prompts
-- ---------------------------------------------------------------------

local function destroyPrompts()
    if prompts then
        pcall(prompts.hide)
        pcall(prompts.delete)
    end
    prompts = nil
end

local function buildPrompts()
    destroyPrompts()
    local K, L = keys(), labels()
    local ok, group = pcall(w.prompt.createGroup, locale(L.title or ''), cfg().promptPosition or 'bottom-right')
    if not ok or type(group) ~= 'table' then
        WCDebug.warn('spawn', 'the selector prompt group could not be created: %s', tostring(group))
        return false
    end
    prompts = group
    pcall(group.addPrompt, K.select, locale(L.select or ''), false)
    pcall(group.addPrompt, K.prev, locale(L.prev or ''), false)
    pcall(group.addPrompt, K.next, locale(L.next or ''), false)
    if Sel.CANCELABLE[kind] then pcall(group.addPrompt, cancelKey(), locale(L.cancel or CANCEL_LABEL), false) end
    pcall(group.display)
    nextPromptCheck = GetGameTimer() + Sel.PROMPT_REASSERT
    inputReadyAt = GetGameTimer() + Sel.INPUT_DELAY
    return true
end

local function completed(key)
    if not prompts or key == nil then return false end
    local ok, done = pcall(prompts.isCompleted, key)
    return ok and done == true
end

--- Another group displayed over ours (a w_lib walk-up prompt the player stands at, a death
--  prompt re-displayed by its owner) hides it, and w_lib only reports completions of the visible
--  group: display ours again (throttled), or the selector could never be left.
local function reassertPrompts(now)
    if not prompts or now < nextPromptCheck then return end
    nextPromptCheck = now + Sel.PROMPT_REASSERT
    local ok, visible = pcall(prompts.isVisible)
    if ok and visible == false then pcall(prompts.display) end
end

OnLanguageChange(function()
    if not active or not prompts then return end
    local K, L = keys(), labels()
    pcall(prompts.setLabel, K.select, locale(L.select or ''))
    pcall(prompts.setLabel, K.prev, locale(L.prev or ''))
    pcall(prompts.setLabel, K.next, locale(L.next or ''))
    if Sel.CANCELABLE[kind] then pcall(prompts.setLabel, cancelKey(), locale(L.cancel or CANCEL_LABEL)) end
    pcall(prompts.setTitle, currentTitle())
end)

-- ---------------------------------------------------------------------
--  The player while the selector shows
-- ---------------------------------------------------------------------

local function holdPlayer()
    local ped = PlayerPedId()
    if not pedExists(ped) then return end
    FreezeEntityPosition(ped, true)
    SetEntityInvincible(ped, true)
    SetEntityVisible(ped, false)
    call('NetworkSetEntityOnlyExistsForParticipants', ped, true)
    held = { ped = ped }
end

-- Give back what holdPlayer() and the UI hiding took (a flow that ends without a spawn).
local function releasePlayer()
    if not held then return end
    held = nil
    local ped = PlayerPedId()
    if pedExists(ped) then
        call('NetworkSetEntityOnlyExistsForParticipants', ped, false)
        SetEntityVisible(ped, true)
        SetEntityInvincible(ped, false)
        FreezeEntityPosition(ped, false)
    end
    pcall(SetWorldUiVisible, true)
    pcall(w.setRadarVisible, true)
    DisplayHud(true)
end

-- ---------------------------------------------------------------------
--  Entering and leaving
-- ---------------------------------------------------------------------

-- The camera, the prompts and the focus (the ped state stays for the spawn handler).
local function leave()
    active = false
    generation = generation + 1
    destroyPrompts()
    if focused then
        ClearFocus()
        focused = false
    end
    if cam then
        RenderScriptCams(false, false, 0, true, true, 0)
        destroyCam()
    end
end

--- Close the selector (idempotent). opts.restore also gives the player back (unfrozen, visible,
--  vulnerable, world UI shown, screen faded in) — for a flow that ends without a spawn. The
--  spawn handler closes it without restore: it places the player itself.
---@param opts? table { restore = boolean }
function Sel.close(opts)
    leave()
    kind = nil
    if type(opts) == 'table' and opts.restore then
        releasePlayer()
        pcall(WCurtain.restore, true)
    else
        held = nil
    end
    busy = false
end

function Sel.active() return active end
function Sel.kind() return active and kind or nil end
--- Is the player ped frozen / hidden by the selector (released by the spawn handler)?
function Sel.holding() return held ~= nil end
function Sel.index() return index end
function Sel.current()
    local pt = active and points[index] or nil
    return pt and WCUtil.copy(pt) or nil
end
function Sel.points() return WCUtil.copy(points) end

--- Step to the previous (-1) / next (+1) point.
function Sel.move(delta)
    if not active or busy or #points == 0 then return false end
    busy = true
    local ok, err = pcall(showPoint, index + (delta < 0 and -1 or 1))
    busy = false
    if not ok then WCDebug.warn('spawn', 'selector move failed: %s', tostring(err)) end
    return ok
end

-- The death system's own hold (WCSpawn.DEATH_OWNER.isDead: dead, last stand or a hospital bed).
local function deathOwnerHolds()
    if IsEntityDead(PlayerPedId()) then return true end
    local owner = type(WCSpawn) == 'table' and WCSpawn.DEATH_OWNER or nil
    if type(owner) ~= 'table' or type(owner.resource) ~= 'string' or type(owner.isDead) ~= 'string' then
        return false
    end
    if call('GetResourceState', owner.resource) ~= 'started' then return false end
    local done, dead = pcall(function() return exports[owner.resource][owner.isDead]() end)
    return done and dead ~= nil and dead ~= false
end

--- Cancel an in-world selector (Sel.CANCELABLE kinds): the player stays where he stood and is given
--  back; the server is told to withdraw the one-shot grant (w_creators:server:spawnCancel).
---@return boolean cancelled
function Sel.cancel()
    if not active or busy or not Sel.CANCELABLE[kind] then return false end
    TriggerServerEvent('w_creators:server:spawnCancel')
    Sel.close({ restore = true })
    return true
end

local function spawnCount()
    return (type(WCSpawn) == 'table' and type(WCSpawn.count) == 'function') and WCSpawn.count() or 0
end

--- Confirm the current point: w_creators:spawn:choose(id). On success the spawn event performs
--  the move (this only closes the camera and the prompts and waits for it); a refusal is shown
--  and the selector stays, except SPAWN_NOT_PENDING (the grant is gone), which gives the player
--  back where it stands.
---@return boolean accepted
function Sel.confirm()
    local pt = active and points[index] or nil
    if not pt or busy then return false end
    busy = true
    local before = spawnCount()
    StartFade(Sel.CONFIRM_FADE, 'spawn')
    local ok, result = pcall(w.callback.await, 'w_creators:spawn:choose', false, pt.id)
    if not ok or not WCResult.is(result) then result = WCResult.fail('INTERNAL_ERROR') end
    if result.ok then
        leave()
        busy = false
        -- the spawn event normally arrives before the answer; if it never does, give the player back
        CreateThread(function()
            local arrived = WCUtil.waitUntil(function() return spawnCount() > before or nil end, Sel.HANDOFF_TIMEOUT, 100)
            if not arrived and held then
                WCDebug.warn('spawn', 'no spawn event after the accepted choice %s', tostring(pt.id))
                Sel.close({ restore = true })
            end
        end)
        return true
    end
    WCDebug.log('spawn', 'choice %s refused: %s', tostring(pt.id), tostring(result.code))
    notify(result)
    if result.code == 'SPAWN_NOT_PENDING' then
        Sel.close({ restore = true })
        return false
    end
    EndFade(Sel.CONFIRM_FADE)
    inputReadyAt = GetGameTimer() + Sel.INPUT_DELAY
    busy = false
    return false
end

-- The per-frame loop of one open selector (ends when it closes).
local function frameLoop(gen)
    local K = keys()
    local last = GetGameTimer()
    while active and generation == gen do
        DisableAllControlActions(0)
        SuppressGameHud()
        local now = GetGameTimer()
        if now >= nextUiHide then
            nextUiHide = now + Sel.UI_REASSERT
            SetWorldUiVisible(false)
        end
        local dt = (now - last) / 1000.0
        last = now
        local pt = points[index]
        local orbit = pt and camCfg(pt, 'orbit') or 0.0
        if orbit ~= 0.0 and cam and DoesCamExist(cam) then
            orbitAngle = (orbitAngle + orbit * dt) % 360.0
            local x, y, z = camPos(pt, orbitAngle)
            SetCamCoord(cam, x, y, z)
            PointCamAtCoord(cam, pt.coords.x, pt.coords.y, pt.coords.z)
        end
        reassertPrompts(now)
        if not busy and now >= inputReadyAt then
            if Sel.CANCELABLE[kind] and completed(cancelKey()) then
                Sel.cancel()
            elseif completed(K.prev) then
                Sel.move(-1)
            elseif completed(K.next) then
                Sel.move(1)
            elseif completed(K.select) then
                local done, err = pcall(Sel.confirm)
                if not done then
                    WCDebug.warn('spawn', 'selector confirm failed: %s', tostring(err))
                    busy = false
                    pcall(EndFade, Sel.CONFIRM_FADE)
                end
            end
        end
        Wait(0)
    end
end

--- Open the selector with the server's selectSpawn data. Returns false when nothing could be
--  shown (no usable point: the legacy spawnAt event lets the server fall back).
---@param data table { last, points, kind }
---@return boolean
function Sel.open(data)
    if active then Sel.close() end
    data = type(data) == 'table' and data or {}
    points = Sel.resolve(data)
    index = 1
    kind = type(data.kind) == 'string' and data.kind or 'login'

    -- an in-world selector on a player the death system holds (dead, last stand, hospital bed):
    -- the hold, the camera and the prompts would fight its own (its death prompt is re-displayed
    -- every few hundred ms), so it is refused and the one-shot grant handed back
    if Sel.CANCELABLE[kind] and deathOwnerHolds() then
        WCDebug.warn('spawn', '%s spawn selector refused: the death system holds the player', kind)
        TriggerServerEvent('w_creators:server:spawnCancel')
        notify(WCResult.fail('BUSY'))
        kind = nil
        return false
    end

    if #points == 0 then
        -- nothing to show: never leave the player on an empty screen. The legacy event with a
        -- value that is no point id falls back to the first enabled point (or the first spawn) for
        -- a player holding the grant. Never '__last': the server would resolve the saved position
        -- even for a new character, whose last position it deliberately withheld.
        WCDebug.warn('spawn', 'no usable spawn point in selectSpawn: the server falls back')
        TriggerServerEvent('w_creators:server:spawnAt', false)
        return false
    end

    active = true
    busy = false
    generation = generation + 1
    local gen = generation

    -- an empty scene: no HUD, map or chat (re-asserted: late HUD resources wake after the login)
    SetWorldUiVisible(false)
    nextUiHide = GetGameTimer() + Sel.UI_REASSERT
    holdPlayer()

    -- leaving the character room's look (its time and colour tweaks) but not its bucket: the
    -- server moves the player into the world when the choice is made
    if type(CreatorScene) == 'table' then pcall(CreatorScene.release, { keepBucket = true }) end
    if type(WCCamera) == 'table' and WCCamera.isOpen() then pcall(WCCamera.close) end

    buildPrompts()
    local ok, err = pcall(showPoint, 1, false)
    if not ok then WCDebug.warn('spawn', 'selector first point failed: %s', tostring(err)) end
    if not active or generation ~= gen then return false end
    EndFade(600)
    CreateThread(function() frameLoop(gen) end)
    return true
end

RegisterNetEvent('w_creators:client:selectSpawn', function(data)
    local ok, err = pcall(Sel.open, data)
    if not ok then
        WCDebug.warn('spawn', 'selector open failed: %s', tostring(err))
        Sel.close({ restore = true })
    end
end)

AddEventHandler('onResourceStop', function(resource)
    if resource ~= GetCurrentResourceName() then return end
    local wasHeld = held ~= nil
    pcall(leave)
    busy = false
    if wasHeld then pcall(releasePlayer) end
    pcall(WCurtain.restore, wasHeld)
end)
