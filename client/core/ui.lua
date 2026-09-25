-- =====================================================================
--  client/core/ui.lua  —  screen transitions and HUD visibility (ARCHITECTURE.md §3.2)
--  Kept globals: WCurtain, StartFade, EndFade, DismissLoadingScreen, SuppressGameHud,
--  SetCustomHudVisible, SetPlayerHudVisible, SetWorldUiVisible. Every optional integration
--  (w_loading, w_hud, vorp_core, chat) is reached through events/exports that are silently
--  dropped when the resource is absent, so none of them is a hard dependency.
-- =====================================================================

-- ---------------------------------------------------------------------
--  The loading curtain (w_loading)
--  Every transition (selection, creator, wardrobe, spawn) is covered by w_loading's curtain rather
--  than a bare black fade: the card goes up before the fade-out and comes down only once the next
--  scene has faded in. Everything degrades to the plain fades when w_loading is absent.
-- ---------------------------------------------------------------------
WCurtain = {}

local curtainUp = false  -- this resource raised the curtain and has not lowered it yet
local fadeHeld = false   -- this resource faded the screen out and has not faded it in yet

local function loadingStarted()
    local ok, state = pcall(GetResourceState, 'w_loading')
    return ok and state == 'started'
end

--- Raise the curtain; `key` names the curtain text (w_loading's Config.Curtain).
function WCurtain.show(key)
    if not loadingStarted() then return end
    curtainUp = true
    pcall(function() exports.w_loading:Show(key or 'loading') end)
end

--- Lower the curtain.
function WCurtain.hide()
    curtainUp = false
    if not loadingStarted() then return end
    pcall(function() exports.w_loading:Hide() end)
end

--- Is a curtain or a screen fade of this resource still up?
function WCurtain.held()
    return curtainUp or fadeHeld
end

--- Undo an interrupted transition: fade the screen back in and lower the curtain when this
--  resource left them up (or always with `force`). Used by the resource-stop cleanup.
---@param force? boolean
function WCurtain.restore(force)
    if force or fadeHeld then
        local out = false
        pcall(function() out = IsScreenFadedOut() or IsScreenFadingOut() end)
        if out then pcall(DoScreenFadeIn, 0) end
    end
    fadeHeld = false
    if force or curtainUp then WCurtain.hide() end
end

-- The fade waits are condition waits bounded by the fade time plus a margin (§0.8).
local FADE_MARGIN = 2000

--- Fade the screen out (curtain first) and wait until the fade completes.
---@param ms? integer
---@param key? string the curtain text key
function StartFade(ms, key)
    ms = math.tointeger(tonumber(ms)) or 500
    WCurtain.show(key)
    fadeHeld = true
    DoScreenFadeOut(ms)
    WCUtil.waitUntil(function() return not IsScreenFadingOut() end, ms + FADE_MARGIN, 0)
end

--- Dismiss the loading screen, fade the screen in and wait, then lower the curtain.
---@param ms? integer
function EndFade(ms)
    ms = math.tointeger(tonumber(ms)) or 500
    DismissLoadingScreen()
    DoScreenFadeIn(ms)
    fadeHeld = false
    WCUtil.waitUntil(function() return not IsScreenFadingIn() end, ms + FADE_MARGIN, 0)
    WCurtain.hide()
end

--- Drop the loading screen for good (both layers).
--  The loadingscreen resource declares loadscreen_manual_shutdown and closes on playerSpawned,
--  which spawnmanager fires; w_creators spawns the player itself so that event never comes.
--  ShutdownLoadingScreen alone closes the game's screen and not the NUI one.
function DismissLoadingScreen()
    pcall(ShutdownLoadingScreen)
    if ShutdownLoadingScreenNui then pcall(ShutdownLoadingScreenNui) end
end

--- Mute the game's native HUD (radar, compass, health cores). Per frame: it comes back otherwise.
function SuppressGameHud()
    DisplayRadar(false)
    DisplayHud(false)
end

--- Is the native radar on screen right now? Read before a flow hides the HUD so it only gives back
--  what it hid: a player who hid his HUD / radar (w_hud hides the radar with its HUD) keeps it
--  hidden afterwards. IS_RADAR_HIDDEN is optional here: without it the radar counts as shown
--  (the previous behaviour: hide, then show again).
---@return boolean
function IsRadarShown()
    if type(IsRadarHidden) ~= 'function' then return true end
    local ok, hidden = pcall(IsRadarHidden)
    if not ok then return true end
    return hidden ~= true and hidden ~= 1
end

--- Show/hide the w_hud HUD (money, gold, needs). Once on enter/leave, not per frame.
--  The events come from w_hud; with w_hud stopped there is no listener and they are dropped.
---@param visible boolean
function SetCustomHudVisible(visible)
    TriggerEvent(visible and 'hud:client:showui' or 'hud:client:Hideui')
end

--- Show/hide the w_hud HUD for good, also for a player in play (the fitting room, the wardrobe,
--  the barber's and the surgeon's chair). 'hud:client:Hideui' only sets w_hud's show flag, and
--  for a logged-in player w_hud's own tick sets that flag back within 50 ms; its main gate
--  (hideStement) holds, and also governs its DisplayRadar calls, so the stement setter goes with
--  it. Both are setters, not toggles (safe to repeat), and neither is the player's own HUD switch
--  (w_hud's showUI): showing them again never undoes a HUD the player had turned off himself.
---@param visible boolean
function SetPlayerHudVisible(visible)
    SetCustomHudVisible(visible)
    TriggerEvent(visible and 'hud:client:showUiWithHoutStement' or 'hud:client:hideUiWithHoutStement')
end

--- Show/hide every server interface around the character scenes (HUD, map, counters, chat).
--  vorp_core's counter is deliberately not re-shown: its own thread shows it when the map comes
--  back and respects Config.HideUi. The chat hides itself; only its log is cleared.
---@param visible boolean
function SetWorldUiVisible(visible)
    SetPlayerHudVisible(visible)
    if not visible then
        TriggerEvent('vorp:showUi', false)
        TriggerEvent('chat:clear')
    end
end
