-- =====================================================================
--  client/scene/environment.lua  —  WCPreviewEnv: the preview environment (ARCHITECTURE.md §3.2)
--  What the world looks like around the player while an appearance is being previewed: controls
--  disabled, HUD hidden, weapon holstered, time/weather overridden, the player frozen (and
--  optionally moved to a fitting stand). enter() records exactly what it changed; exit() undoes
--  exactly that and nothing else. Both are idempotent. One control-disabling thread runs only
--  while the environment is active.
--  On resource stop: the environment is exited, NUI focus is released, the cameras are destroyed
--  (WCCamera.close), an interrupted fade / loading curtain is lifted, and the player is unfrozen /
--  made visible / given the HUD back if it was changed here.
-- =====================================================================

WCPreviewEnv = {}
local Env = WCPreviewEnv

Env.COLLISION_TIMEOUT = 8000

local active = false
local changed = nil -- what enter() changed (nil while inactive)
local thread = nil  -- true while the control thread runs

local function pedExists(ped)
    return type(ped) == 'number' and ped ~= 0 and DoesEntityExist(ped) == true
end

--- Call a named native only when the runtime provides it (optional presentation natives).
local function call(name, ...)
    local fn = _ENV[name]
    if fn == nil then return false end
    return (pcall(fn, ...))
end

local function controlLoop()
    thread = true
    while active do
        if changed and changed.controls then DisableAllControlActions(0) end
        if changed and changed.hud then SuppressGameHud() end
        Wait(0)
    end
    thread = nil
end

--- Enter the preview environment.
--  opts (every field optional; defaults in brackets):
--    ped        the previewed ped [PlayerPedId()]
--    controls   disable all controls every frame [true]
--    hud        hide the game HUD, the radar and the w_hud HUD [true]
--    worldUi    also hide every server interface (SetWorldUiVisible) [false]
--    holster    holster the ped's weapon [true]
--    freeze     freeze the ped in place [true]
--    invincible make the ped invincible [false]
--    clearTasks clear the ped's tasks first [true]
--    coords     move the ped there ({x, y, z, heading}); restored on exit [nil]
--    time       { hour, minute } clock override [nil]
--    weather    weather type name override [nil]
---@return boolean entered (false when already active)
function Env.enter(opts)
    if active then return false end
    opts = type(opts) == 'table' and opts or {}
    local ped = opts.ped or PlayerPedId()
    local c = { ped = ped }

    if pedExists(ped) then
        if opts.clearTasks ~= false then ClearPedTasksImmediately(ped) end
        if opts.coords then
            local x, y, z, h = CreatorScene.coords(opts.coords)
            if x then
                local at = GetEntityCoords(ped)
                c.coords = { at.x, at.y, at.z, GetEntityHeading(ped) }
                SetEntityCoords(ped, x, y, z, false, false, false, false)
                SetEntityHeading(ped, h)
                RequestCollisionAtCoord(x, y, z)
                WCUtil.waitUntil(function() return HasCollisionLoadedAroundEntity(ped) end, Env.COLLISION_TIMEOUT, 0)
            end
        end
        if not c.coords then c.heading = GetEntityHeading(ped) end
        if opts.holster ~= false then
            c.holster = call('HidePedWeapons', ped, 2, true)
        end
        if opts.freeze ~= false then
            FreezeEntityPosition(ped, true)
            c.freeze = true
        end
        if opts.invincible then
            SetEntityInvincible(ped, true)
            c.invincible = true
        end
    end

    if opts.hud ~= false then
        SetCustomHudVisible(false)
        pcall(w.setRadarVisible, false)
        c.hud = true
    end
    if opts.worldUi then
        SetWorldUiVisible(false)
        c.worldUi = true
    end
    if type(opts.time) == 'table' then
        local hour = WCUtil.int(opts.time[1] or opts.time.hour, 0, 23, 12)
        local minute = WCUtil.int(opts.time[2] or opts.time.minute, 0, 59, 0)
        NetworkClockTimeOverride(hour, minute, 0, 0, true)
        c.time = true
    end
    if type(opts.weather) == 'string' and opts.weather ~= '' then
        c.weather = call('SetWeatherType', GetHashKey(opts.weather), true, true, true, 0.0, true)
    end
    c.controls = opts.controls ~= false

    changed = c
    active = true
    if (c.controls or c.hud) and not thread then CreateThread(controlLoop) end
    return true
end

--- Leave the preview environment: undo exactly what enter() changed. Idempotent.
---@return boolean left (false when not active)
function Env.exit()
    if not active then return false end
    local c = changed or {}
    active, changed = false, nil
    local ped = c.ped

    if c.weather then
        call('ClearOverrideWeather')
        call('ClearWeatherTypePersist')
    end
    if c.time then NetworkClearClockTimeOverride() end
    if c.worldUi then SetWorldUiVisible(true) end
    if c.hud then
        SetCustomHudVisible(true)
        -- w_lib is the one radar authority (HUD wish, radar mode, custom minimap): never
        -- DisplayRadar(true) directly. The game HUD was suppressed per frame, so it comes back.
        pcall(w.setRadarVisible, true)
        DisplayHud(true)
    end
    if pedExists(ped) then
        if c.invincible then SetEntityInvincible(ped, false) end
        if c.freeze then FreezeEntityPosition(ped, false) end
        if c.coords then
            SetEntityCoords(ped, c.coords[1], c.coords[2], c.coords[3], false, false, false, false)
            SetEntityHeading(ped, c.coords[4])
        elseif c.heading then
            SetEntityHeading(ped, c.heading)
        end
    end
    return true
end

--- Is the environment active?
function Env.active()
    return active
end

--- What the active environment changed (a copy; nil when inactive). For diagnostics and tests.
function Env.changes()
    return changed and WCUtil.copy(changed) or nil
end

--- Did a w_creators flow hold the player when the resource stopped?
local function heldByUs(c)
    if c then return true end
    if WCState.inEditor() then return true end
    for name in pairs(WCState.LOCKS) do
        if WCState.busy(name) then return true end
    end
    return false
end

AddEventHandler('onResourceStop', function(resource)
    if resource ~= GetCurrentResourceName() then return end
    local held = heldByUs(changed)
    pcall(Env.exit)
    pcall(SetNuiFocus, false, false)
    pcall(SetNuiFocusKeepInput, false)
    pcall(WCCamera.close)
    -- a transition cut short: never leave the screen black or the loading card up
    pcall(WCurtain.restore, held)
    if not held then return end
    -- a flow was interrupted: never leave the player frozen, invisible or without a HUD
    local ped = PlayerPedId()
    if pedExists(ped) then
        FreezeEntityPosition(ped, false)
        SetEntityVisible(ped, true)
    end
    pcall(SetWorldUiVisible, true)
    pcall(w.setRadarVisible, true)
    DisplayHud(true)
end)
