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
    -- BOOL natives answer 1 (not true) on this runtime: never compare them with == true
    return type(ped) == 'number' and ped ~= 0 and not not DoesEntityExist(ped)
end

--- Call a named native only when the runtime provides it (optional presentation natives).
local function call(name, ...)
    local fn = _ENV[name]
    if fn == nil then return false end
    return (pcall(fn, ...))
end

--- The fitting-room light (opts.light): drawn every frame at an offset from the previewed ped, so
--  it follows the ped as it turns.
local function drawLight(c)
    local l = c.light
    if not l or not pedExists(c.ped) then return end
    local ok, at = pcall(GetOffsetFromEntityInWorldCoords, c.ped, l.x, l.y, l.z)
    if not ok or not at then return end
    DrawLightWithRange(at.x + 0.0, at.y + 0.0, at.z + 0.0, l.r, l.g, l.b, l.range, l.intensity)
end

local function controlLoop()
    thread = true
    while active do
        if changed and changed.controls then DisableAllControlActions(0) end
        if changed and changed.suppress then SuppressGameHud() end
        if changed and changed.light then drawLight(changed) end
        Wait(0)
    end
    thread = nil
end

--- A light spec from config ({ enabled, intensity, range, offset = {x, y, z}, color = {r, g, b} }),
--  cleaned, or nil (off or malformed).
function Env.lightOf(cfg)
    if type(cfg) ~= 'table' or cfg.enabled == false then return nil end
    local o = type(cfg.offset) == 'table' and cfg.offset or {}
    local c = type(cfg.color) == 'table' and cfg.color or {}
    return {
        x = WCUtil.number(o[1] or o.x, -10, 10, 0.0) + 0.0,
        y = WCUtil.number(o[2] or o.y, -10, 10, 0.0) + 0.0,
        z = WCUtil.number(o[3] or o.z, -10, 10, 0.0) + 0.0,
        r = WCUtil.int(c[1] or c.r, 0, 255, 255), g = WCUtil.int(c[2] or c.g, 0, 255, 255),
        b = WCUtil.int(c[3] or c.b, 0, 255, 255),
        range = WCUtil.number(cfg.range, 0.5, 100, 15.0) + 0.0,
        intensity = WCUtil.number(cfg.intensity, 0, 100, 10.0) + 0.0,
    }
end

--- Enter the preview environment.
--  opts (every field optional; defaults in brackets):
--    ped        the previewed ped [PlayerPedId()]
--    controls   disable all controls every frame [true]
--    hud        hide the game HUD and the w_hud HUD for the whole visit, and the radar when shown [true]
--    worldUi    also hide every server interface (SetWorldUiVisible) [false]
--    holster    holster the ped's weapon [true]
--    freeze     freeze the ped in place [true]
--    invincible make the ped invincible [false]
--    clearTasks clear the ped's tasks first [true]
--    coords     move the ped there ({x, y, z, heading}); restored on exit [nil]
--    time       { hour, minute } clock override [nil]
--    weather    weather type name override [nil]
--    light      a light drawn every frame at an offset from the ped (Env.lightOf) [nil]
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
        -- the game HUD is muted per frame
        c.suppress = true
        -- the w_hud HUD goes for the whole visit and comes back at exit, whatever the radar shows.
        -- It used to follow the radar, and in a store the radar is often off (an interior, a
        -- w_map minimap that keeps the native radar dormant): the HUD stayed up in the fitting
        -- room. SetPlayerHudVisible touches only the flags this visit sets, never the player's own
        -- HUD switch, so giving it back cannot show a HUD he had turned off.
        SetPlayerHudVisible(false)
        c.hud = true
        -- the radar wish is turned off (and back on at exit) only when it was on: a player who had
        -- hidden the radar keeps it hidden after the visit
        if IsRadarShown() then
            pcall(w.setRadarVisible, false)
            c.radar = true
        end
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
    if type(opts.light) == 'table' then c.light = opts.light end

    changed = c
    active = true
    if (c.controls or c.suppress or c.light) and not thread then CreateThread(controlLoop) end
    return true
end

--- Leave the preview environment: undo exactly what enter() changed. Idempotent.
---@return boolean left (false when not active)
function Env.exit()
    if not active then return false end
    local c = changed or {}
    active, changed = false, nil
    local ped = c.ped

    -- the HUD first: whatever fails further down, the player never leaves the visit without it
    if c.hud then pcall(SetPlayerHudVisible, true) end
    -- w_lib is the one radar authority (HUD wish, radar mode, custom minimap): never
    -- DisplayRadar(true) directly.
    if c.radar then pcall(w.setRadarVisible, true) end
    if c.weather then
        call('ClearOverrideWeather')
        call('ClearWeatherTypePersist')
    end
    if c.time then NetworkClearClockTimeOverride() end
    if c.worldUi then SetWorldUiVisible(true) end
    -- the game HUD was suppressed per frame, so it comes back
    if c.suppress then DisplayHud(true) end
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

-- w_hud restarted during a visit comes back with its HUD shown: it is hidden again for the rest of
-- the visit (exit gives it back as usual)
AddEventHandler('onClientResourceStart', function(resource)
    if resource == 'w_hud' and active and changed and changed.hud then pcall(SetPlayerHudVisible, false) end
end)

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
