-- =====================================================================
--  The language
--  The library decides it (w.getLocaleKey): the player's choice in /w_lib or the server convar
--  w_lib:locale. The Arabic texts in the code are the dictionary keys themselves and
--  locales/en.json translates them; the global locale() returns the key when it is missing.
--  Only 'ar' and 'en' exist: anything else is treated as 'en'.
-- =====================================================================

--- The effective language key, normalised to 'ar' | 'en'.
---@return string
function UiLocale()
    local ok, key = pcall(w.getLocaleKey)
    if ok and type(key) == 'string' and key:sub(1, 2):lower() == 'ar' then return 'ar' end
    return 'en'
end

--- The interface's writing direction for the current language: 'rtl' or 'ltr'.
---@return string
function UiDir()
    return UiLocale() == 'ar' and 'rtl' or 'ltr'
end

--- Single text fields that are translated in the menu tree.
local TRANSLATED_FIELDS = { name = true, subTitle = true, title = true }

--- Fields carrying an array of texts that are translated item by item (the pads' axis labels).
local TRANSLATED_LISTS = { xLabel = true, yLabel = true }

--- Translating every text field of the menu data tree (name/subTitle/title/xLabel/yLabel).
--  A new copy rather than an edit in place: the original data keeps the Arabic keys so the
--  translation is right again when the player switches his language during play.
---@param node any
---@return any
function TranslateTree(node)
    if type(node) ~= 'table' then return node end
    local out = {}
    for k, v in pairs(node) do
        if TRANSLATED_LISTS[k] and type(v) == 'table' then
            local list = {}
            for i = 1, #v do
                list[i] = type(v[i]) == 'string' and locale(v[i]) or v[i]
            end
            out[k] = list
        elseif type(v) == 'table' then
            out[k] = TranslateTree(v)
        elseif TRANSLATED_FIELDS[k] and type(v) == 'string' then
            out[k] = locale(v)
        else
            out[k] = v
        end
    end
    return out
end

-- ---------------------------------------------------------------------
--  Live switching
--  w_lib fires 'w_lib:setLocale'(key) when the player switches his language. The dictionary is
--  reloaded here first (the library's own handler may run after ours), then every screen that
--  built texts at load time re-applies them through the refreshers registered below.
-- ---------------------------------------------------------------------
local localeRefreshers = {}

--- Registering a function that re-applies the texts of a screen after a language switch.
---@param fn fun(key: string)
function OnLanguageChange(fn)
    localeRefreshers[#localeRefreshers + 1] = fn
end

AddEventHandler('w_lib:setLocale', function(key)
    -- only ar/en ship: anything else reads the English dictionary
    local normalised = (type(key) == 'string' and key:sub(1, 2):lower() == 'ar') and 'ar' or 'en'
    w.locale(normalised)
    for i = 1, #localeRefreshers do
        local ok, err = pcall(localeRefreshers[i], normalised)
        if not ok then w.print.error('language refresh failed: %s', tostring(err)) end
    end
end)

-- =====================================================================
--  natives.lua
--  Low-level wrappers for RedM's native calls + screen and model tools.
--  They depend on no other module, so they are loaded first.
-- =====================================================================

-- ---------------------------------------------------------------------
--  The creator's scene (the interior room) - the same mechanism as vorp_character
-- ---------------------------------------------------------------------

--- Loading the creator's room and moving the player into it.
--  The order comes from vorp_character/client/createCharacter.lua:Setup() - the move before
--  waiting for the collision, because HasCollisionLoadedAroundEntity checks around the player.
--
--  And we assume no step succeeds: on an early boot StartPlayerTeleport may fail
--  silently (the player has not spawned yet) so he stays where he is while the camera looks at an
--  unloaded room - and the result is a black screen with no message. So we verify he really arrived
--  and retry, with a direct SetEntityCoords as a fallback.
function LoadCreatorScene()
    local a = Config.SceneAnchor
    local target = vector3(a[1], a[2], a[3])

    local s = Config.SceneLoadSphere
    Citizen.InvokeNative(0x513F8AA5BF2F17CF, s[1], s[2], s[3], s[4], s[5]) -- load sphere

    for i = 1, #Config.SceneImaps do
        local hash = Config.SceneImaps[i]
        if not IsIplActiveByHash(hash) then
            RequestIplByHash(hash)
        end
    end

    NetworkClockTimeOverride(10, 0, 0, 0, true)
    SetTimecycleModifier('Online_Character_Editor')

    -- The move with a verification: we retry until he really arrives, not until the call returns
    local arrived = false
    local deadline = GetGameTimer() + 15000

    while not arrived and GetGameTimer() < deadline do
        StartPlayerTeleport(PlayerId(), a[1], a[2], a[3], a[4], true, true, true, true)

        local tdl = GetGameTimer() + 5000
        while IsPlayerTeleportActive() and GetGameTimer() < tdl do
            Citizen.Wait(0)
        end

        if #(GetEntityCoords(PlayerPedId()) - target) < 5.0 then
            arrived = true
            break
        end

        -- A direct fallback if the managed move refuses
        SetEntityCoords(PlayerPedId(), a[1], a[2], a[3], false, false, false, false)
        SetEntityHeading(PlayerPedId(), a[4])
        Citizen.Wait(250)

        if #(GetEntityCoords(PlayerPedId()) - target) < 5.0 then
            arrived = true
        end
    end

    if not arrived then
        w.print.error("could not move the player into the creator's room - the scene may show black")
    end

    -- Only now do we wait for the collision: the player is inside the room
    RequestCollisionAtCoord(a[1], a[2], a[3])
    deadline = GetGameTimer() + 10000
    while not HasCollisionLoadedAroundEntity(PlayerPedId()) and GetGameTimer() < deadline do
        RequestCollisionAtCoord(a[1], a[2], a[3])
        Citizen.Wait(0)
    end

    -- And we wait for the room's maps to really activate, not merely to be requested
    deadline = GetGameTimer() + 5000
    for i = 1, #Config.SceneImaps do
        local hash = Config.SceneImaps[i]
        while not IsIplActiveByHash(hash) and GetGameTimer() < deadline do
            Citizen.Wait(0)
        end
    end

    SetFocusPosAndVel(a[1], a[2], a[3], 0.0, 0.0, 0.0)

    w.print.debug('the scene is ready - the distance from the anchor is %.2fm', #(GetEntityCoords(PlayerPedId()) - target))
end

--- Releasing the scene (when leaving it for good into the game).
function ReleaseCreatorScene()
    ClearFocus()
    ClearTimecycleModifier()
    NetworkClearClockTimeOverride()
end

--- Dropping the loading screen for good (both layers together).
--  The loadingscreen resource declares loadscreen_manual_shutdown "yes" in its manifest,
--  that is, its interface never closes automatically. And it closes it on the playerSpawned event
--  only - and that event is fired by spawnmanager, while w_creators handles the spawn
--  itself so it is never fired. So the screen stays hanging above everything.
--  ShutdownLoadingScreen alone closes the game's internal screen and not the NUI interface.
function DismissLoadingScreen()
    ShutdownLoadingScreen()
    if ShutdownLoadingScreenNui then
        ShutdownLoadingScreenNui()
    end
end

--- Deleting a scene ped through the library. The mission-entity flag is set first so the
--  engine lets a script-owned ped go (w.entity.delete is a bare DeleteEntity).
function DeletePedHard(ped)
    if not ped or ped == 0 or not DoesEntityExist(ped) then return end
    SetEntityAsMissionEntity(ped, true, true)
    w.entity.delete(ped, true)
end

--- Cleaning up the peds stuck in the scene's area.
--  Necessary on a restart: onResourceStop does not run on a sudden reload
--  or a crash, so the earlier preview peds pile up in the room at every restart.
function CleanupScenePeds()
    local a = Config.SceneAnchor
    local center = vector3(a[1], a[2], a[3])
    local me = PlayerPedId()
    local removed = 0

    for _, ped in ipairs(GetGamePool('CPed')) do
        if ped ~= me and DoesEntityExist(ped) and not IsPedAPlayer(ped) then
            if #(GetEntityCoords(ped) - center) < Config.SceneCleanupRadius then
                DeletePedHard(ped)
                removed = removed + 1
            end
        end
    end

    if removed > 0 then
        w.print.warn("cleaned up %d stuck ped(s) from the scene's area", removed)
    end
end

--- Clothing the preview ped with the default outfit.
--  vorp_character ends DefaultPedSetup with EquipMetaPedOutfitPreset(ped, 3):
--  the components (heads/BODIES_UPPER/hair...) build the body and do not dress it, and the outfit is
--  what actually clothes it - which is why the ped used to show in trousers alone.


--- Arming the scene's ped: the revolver goes into the holster and not the hand.
--  bForceInHand = false and bForceInHolster = true, and we do not call
--  SetCurrentPedWeapon because it draws it into the hand so it hides the torso from the preview.
---@param ped integer
---@param isMale boolean
function ArmScenePed(ped, isMale)
    local cfg = Config.SceneWeapon
    if not cfg or not cfg.enabled then return end
    if not ped or ped == 0 or not DoesEntityExist(ped) then return end

    local name = isMale and cfg.male or cfg.female
    if not name then return end
    local hash = joaat(name)

    -- GiveWeaponToPed(ped, hash, ammo, bForceInHand, bForceInHolster)
    pcall(Citizen.InvokeNative, 0x5E3BDDBCB83F3D84, ped, hash, cfg.ammo or 6, false, true)
end

-- Playing the standing scenario on the scene's ped.
--  A scenario and not TaskPlayAnim: the same thing vorp_character does for the selection screen's
--  peds (client.lua:427). Clear existing tasks before starting the scenario.
--  Keep the actor anchored while its idle animates; it must not wander out of frame.
function PlaySceneIdle(ped, isMale)
    if not ped or ped == 0 or not DoesEntityExist(ped) then return end

    local list = Config.SceneScenarios[isMale and 'male' or 'female']
    if not list or #list == 0 then return end
    local name = list[math.random(1, #list)]
    local hash = joaat(name)

    FreezeEntityPosition(ped, true)
    SetEntityInvincible(ped, true)
    SetPedCanBeTargetted(ped, false)
    ClearPedTasks(ped)
    Citizen.Wait(100)

    -- TaskStartScenarioInPlaceHash
    Citizen.InvokeNative(0x524B54361229154F, ped, hash, -1, false, 0, GetEntityHeading(ped), false)
end

--- Muting the game's native HUD (the radar/the compass/the health rings).
--  Called every frame: these calls are repeated every frame or the HUD comes back.
function SuppressGameHud()
    DisplayRadar(false)
    DisplayHud(false)
end

--- Showing/hiding the w_hud HUD (the money/gold/needs).
--  Once on entering and on leaving, not every frame.
--  The two events come from w_hud/client/event.lua:41,45 - and if w_hud is stopped there is no listener
--  for the event and it is dropped with no error, so we do not force a hard dependency on the resource.
function SetCustomHudVisible(visible)
    TriggerEvent(visible and 'hud:client:showui' or 'hud:client:Hideui')
end

--- Hiding/showing all the server's interfaces during the introductory scenes.
--  The scene must be completely empty: no HUD and no map and no chat.
--
--  Why more than one event and not SetCustomHudVisible alone: 'hud:client:Hideui'
--  sets the show variable only, while the main gate in w_hud is hideStement
--  (thread.lua:79) and it is also what governs its DisplayRadar calls
--  (thread.lua:123,166) - so without it w_hud shows the map again every cycle
--  and overrides the DisplayRadar(false) we write.
--  And hideUiWithHoutStement is a setter and not a toggle (event.lua:79,80) unlike HideAllUI,
--  so it does not go out of step if it is called twice.
--
--  vorp_core: the money/gold counter. We deliberately do not show it again on the restore -
--  its own thread (uicore.lua:51-68) shows it by itself when the map comes back, and it respects
--  Config.HideUi on servers that hide it anyway.
--
--  The chat: the resource offers no hiding interface, but it hides itself unless a message arrives,
--  and opening it is blocked by DisableAllControlActions. What is left is clearing the log.
--
--  Every event with no listener is dropped with no error, so this forces no dependency on any resource.
function SetWorldUiVisible(visible)
    SetCustomHudVisible(visible)
    TriggerEvent(visible and 'hud:client:showUiWithHoutStement'
                          or 'hud:client:hideUiWithHoutStement')
    if not visible then
        TriggerEvent('vorp:showUi', false)
        TriggerEvent('chat:clear')
    end
end

--- Drawing the room's lights - called every frame (the room is interior and dark without them).
function DrawCreatorSceneLights()
    for i = 1, #Config.SceneLights do
        local lp = Config.SceneLights[i]
        DrawLightWithRange(lp[1], lp[2], lp[3], 255, 255, 255, lp[4], lp[5])
    end
end

--- Fading the screen out and waiting until the fade completes.
-- ── the loading curtain (w_loading) ───────────────────────────────────────────────
-- Every transition -- selection, creator, wardrobe, spawn -- is covered by w_loading's
-- curtain rather than a bare black fade: the card goes up before the fade-out starts and
-- comes down only once the next scene has faded in. Everything degrades to the plain fades
-- when w_loading is absent.
WCurtain = {}

function WCurtain.show(key)
    if GetResourceState('w_loading') ~= 'started' then return end
    pcall(function() exports.w_loading:Show(key or 'loading') end)
end

function WCurtain.hide()
    if GetResourceState('w_loading') ~= 'started' then return end
    pcall(function() exports.w_loading:Hide() end)
end

--- Fading the screen out; `key` names the curtain text (see w_loading's Config.Curtain).
function StartFade(timer, key)
    WCurtain.show(key)
    DoScreenFadeOut(timer)
    while IsScreenFadingOut() do
        Citizen.Wait(1)
    end
end

--- Fading the screen in after the loading screen is closed; the curtain lifts once the
--- scene is fully in.
function EndFade(timer)
    DismissLoadingScreen()
    DoScreenFadeIn(timer)
    while IsScreenFadingIn() do
        Citizen.Wait(1)
    end
    WCurtain.hide()
end

--- Switching the player's model and waiting until it loads.
function SetPlayerPed(model)
    local modelHash = joaat(model)
    if GetEntityModel(PlayerPedId()) == modelHash then return end
    -- w.requestModel yields until the model is streamed (it errors on an invalid model)
    local ok, err = pcall(w.requestModel, modelHash, 15000)
    if not ok then error(err) end
    SetPlayerModel(PlayerId(), modelHash, true)
    SetModelAsNoLongerNeeded(modelHash)
    Citizen.Wait(200)
end

function PlayerAsInitialized(bool)
    initializedPlayer = bool
end

function IsPlayerInitialized()
    return initializedPlayer
end

-- ---------------------------------------------------------------------
--  The native wrappers (what the library does not cover: face features, variation refresh)
-- ---------------------------------------------------------------------

function NativeSetPedFaceFeature(ped, index, value)
    Citizen.InvokeNative(0x5653AB26C82938CF, ped, index, value)
    NativeUpdatePedVariation(ped)
end



function NativeUpdatePedVariation(ped)
    Citizen.InvokeNative(0x704C908E9C405136, ped)
    Citizen.InvokeNative(0xCC8CA3E88256E58F, ped, false, true, true, true, false)
end
