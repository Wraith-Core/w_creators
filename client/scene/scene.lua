-- =====================================================================
--  client/scene/scene.lua  —  CreatorScene: the character room and its preview peds
--  (ARCHITECTURE.md §3.2, §9.1, §16.2)
--  The room is vorp_character's interior (Config.Scene). The selector and the creator share one
--  checked preview-ped lifecycle: the server acknowledges the private scene first
--  (w_creators:scene:prepare), every preview ped is networked and registered
--  (w_creators:scene:registerPed), positioned, rendered by Appearance.RestoreCharacter, waited on
--  until rendered, then shown. Preview peds are tracked and always deleted (destroy, cleanup,
--  resource stop). The player ped is never a preview ped.
--  Every function reports failure by its return value; none throws.
-- =====================================================================

CreatorScene = {}
local S = CreatorScene

S.TELEPORT_TIMEOUT = 15000   -- ms to get the player into the room
S.COLLISION_TIMEOUT = 10000  -- ms for the room collision
S.IMAP_TIMEOUT = 5000        -- ms for the room maps to activate
S.NETWORK_TIMEOUT = 5000     -- ms for a preview ped's network id
S.READY_TIMEOUT = 15000      -- ms for a preview ped to render

S.TELEPORT_RETRY = 250      -- ms between two attempts to move the player into the room

local tracked = {}           -- [ped] = true: preview peds created here
local isolated = false       -- this client asked the server for the private scene
local loaded = false         -- the room's focus / timecycle / clock override are active
local requestedMaps = {}     -- the room maps load() requested (not those already active)

local function cfg() return Config.Scene or {} end

local function pedExists(ped)
    return type(ped) == 'number' and ped ~= 0 and DoesEntityExist(ped) == true
end

--- x, y, z, heading of a coords value: { x, y, z, h } array, vector4, or { x, y, z, w|heading }.
local function xyzh(c)
    if type(c) ~= 'table' and type(c) ~= 'userdata' and type(c) ~= 'vector4' and type(c) ~= 'vector3' then
        return nil
    end
    local x, y, z, h
    local okArr = pcall(function() x, y, z, h = c[1], c[2], c[3], c[4] end)
    if not okArr or x == nil then
        local ok = pcall(function() x, y, z, h = c.x, c.y, c.z, c.w or c.heading end)
        if not ok then return nil end
    end
    x, y, z, h = tonumber(x), tonumber(y), tonumber(z), tonumber(h) or 0.0
    if not (WCUtil.isFinite(x) and WCUtil.isFinite(y) and WCUtil.isFinite(z)) then return nil end
    return x + 0.0, y + 0.0, z + 0.0, h + 0.0
end
S.coords = xyzh

local function sexOf(v)
    if v == true or v == 'male' then return 'male' end
    if v == false or v == 'female' then return 'female' end
    return nil
end

local function waitFor(fn, ms)
    return WCUtil.waitUntil(fn, ms, 0) ~= nil
end

-- ---------------------------------------------------------------------
--  The room
-- ---------------------------------------------------------------------

--- Load the room and move the player into it (same order as vorp_character's Setup: the move
--  comes before the collision wait because HasCollisionLoadedAroundEntity checks around the
--  player). Nothing is assumed to succeed: on an early boot StartPlayerTeleport can fail silently,
--  so the arrival is verified and retried, with a direct SetEntityCoords fallback.
---@return boolean arrived
function S.load()
    local ax, ay, az, ah = xyzh(cfg().anchor)
    if not ax then
        WCDebug.warn('scene', 'Config.Scene.anchor is invalid')
        return false
    end
    local sphere = cfg().loadSphere
    if type(sphere) == 'table' then WCNative.scene.loadSphere(sphere[1], sphere[2], sphere[3], sphere[4], sphere[5]) end
    for _, hash in ipairs(cfg().imaps or {}) do
        if not IsIplActiveByHash(hash) then
            RequestIplByHash(hash)
            requestedMaps[hash] = true
        end
    end
    NetworkClockTimeOverride(10, 0, 0, 0, true)
    SetTimecycleModifier('Online_Character_Editor')
    loaded = true

    local target = vector3(ax, ay, az)
    local function near()
        return #(GetEntityCoords(PlayerPedId()) - target) < 5.0
    end
    -- one attempt every TELEPORT_RETRY ms (a teleport that has just started is not restarted)
    local arrived = WCUtil.waitUntil(function()
        StartPlayerTeleport(PlayerId(), ax, ay, az, ah, true, true, true, true)
        waitFor(function() return not IsPlayerTeleportActive() end, 5000)
        if near() then return true end
        -- the direct fallback when the managed teleport refuses
        SetEntityCoords(PlayerPedId(), ax, ay, az, false, false, false, false)
        SetEntityHeading(PlayerPedId(), ah)
        return near() or nil
    end, S.TELEPORT_TIMEOUT, S.TELEPORT_RETRY) ~= nil
    if not arrived then
        WCDebug.warn('scene', 'the player could not be moved into the creator room')
    end

    -- the collision around the player (now inside the room), then the maps really active
    waitFor(function()
        RequestCollisionAtCoord(ax, ay, az)
        return HasCollisionLoadedAroundEntity(PlayerPedId())
    end, S.COLLISION_TIMEOUT)
    waitFor(function()
        for _, hash in ipairs(cfg().imaps or {}) do
            if not IsIplActiveByHash(hash) then return nil end
        end
        return true
    end, S.IMAP_TIMEOUT)
    SetFocusPosAndVel(ax, ay, az, 0.0, 0.0, 0.0)
    WCDebug.log('scene', 'room ready (arrived: %s)', tostring(arrived))
    return arrived
end

--- Unload the room maps load() requested (maps another resource had already activated stay).
--  Call it once the player has left the room (a player standing in it would fall through).
---@return integer removed
function S.unload()
    local removed = 0
    for hash in pairs(requestedMaps) do
        -- the pre-v3 creator removed the room with RemoveImap; RemoveIplByHash is the counterpart
        -- of the RequestIplByHash used by load()
        local fn = RemoveIplByHash or RemoveImap
        if fn and pcall(fn, hash) then removed = removed + 1 end
    end
    requestedMaps = {}
    return removed
end

--- Leave the room for good: the focus, the timecycle and the clock override are cleared, the
--  server bucket is released when this client isolated itself (opts.keepBucket keeps it) and,
--  with opts.unload, the room maps are unloaded (the final exit, once the player is out).
---@param opts? table { keepBucket = bool, unload = bool }
---@return boolean
function S.release(opts)
    opts = type(opts) == 'table' and opts or {}
    if loaded then
        ClearFocus()
        ClearTimecycleModifier()
        NetworkClearClockTimeOverride()
        loaded = false
    end
    if opts.unload then S.unload() end
    if isolated and not opts.keepBucket then
        local ok, result = pcall(w.callback.await, 'w_creators:scene:release', false)
        isolated = false
        return ok and type(result) == 'table' and result.ok == true
    end
    return true
end

--- Is the room loaded / the player isolated by this client?
function S.isLoaded() return loaded end
function S.isIsolated() return isolated end

--- The server already moved the player out of the private scene (the spawn into the world, a
--  framework spawn event: WCScene.toWorld): forget the isolation without another release call.
function S.forgetIsolation()
    isolated = false
end

--- Ask the server for the private scene (routing bucket). The server grants it only for a
--  player without an active character, one switching characters, or one in a store fitting room.
---@return boolean ok, string|nil code
function S.isolate()
    local ok, result = pcall(w.callback.await, 'w_creators:scene:prepare', false)
    if ok and type(result) == 'table' and result.ok == true then
        isolated = true
        return true
    end
    local code = ok and type(result) == 'table' and result.code or 'INTERNAL_ERROR'
    WCDebug.warn('scene', 'private scene refused: %s', tostring(code))
    return false, code
end

--- The room lights; call every frame while the room shows (it is dark without them).
function S.drawLights()
    for _, light in ipairs(cfg().lights or {}) do
        DrawLightWithRange(light[1] + 0.0, light[2] + 0.0, light[3] + 0.0, 255, 255, 255, light[4] + 0.0, light[5] + 0.0)
    end
end

-- ---------------------------------------------------------------------
--  Preview peds
-- ---------------------------------------------------------------------

--- Is the ped rendered (metaped ready and skeleton not collapsed), waiting up to timeoutMs.
---@return boolean
function S.ready(ped, timeoutMs)
    if not pedExists(ped) then return false end
    return Appearance.WaitReady(ped, tonumber(timeoutMs) or S.READY_TIMEOUT)
end

--- Make a preview ped visible and inert.
function S.show(ped)
    if not pedExists(ped) then return false end
    ResetEntityAlpha(ped)
    SetEntityVisible(ped, true)
    SetEntityInvincible(ped, true)
    SetBlockingOfNonTemporaryEvents(ped, true)
    return true
end

--- Place a preview ped on the floor of the scene at coords { x, y, z, heading } and hold it there.
---@return boolean ok, string|nil err
function S.position(ped, coords)
    if not pedExists(ped) then return false, 'INVALID_PED' end
    local x, y, z, h = xyzh(coords)
    if not x then return false, 'INVALID_PAYLOAD' end
    ClearPedTasksImmediately(ped)
    FreezeEntityPosition(ped, true)
    SetEntityCollision(ped, true, true)
    -- scene coordinates describe the floor, as w.entity.create coordinates do
    SetEntityCoords(ped, x, y, z, false, false, false, false)
    SetEntityHeading(ped, h)
    RequestCollisionAtCoord(x, y, z)
    local collided = waitFor(function()
        return pedExists(ped) and HasCollisionLoadedAroundEntity(ped) or nil
    end, S.COLLISION_TIMEOUT)
    if not collided then WCDebug.log('scene', 'collision around ped %s did not load', tostring(ped)) end
    if not pedExists(ped) then return false, 'INVALID_PED' end
    WCNative.ped.placeOnGround(ped)
    FreezeEntityPosition(ped, true)
    TaskStandStill(ped, -1)
    local at = GetEntityCoords(ped)
    if math.abs(at.x - x) >= 1.0 or math.abs(at.y - y) >= 1.0 or math.abs(at.z - z) >= 3.0 then
        return false, 'OUT_OF_POSITION'
    end
    return true
end

--- Holster the scene's cosmetic revolver on a preview ped (never in the hand: it hides the torso).
---@param sex string|boolean 'male'|'female' (or isMale)
function S.arm(ped, sex)
    local weapon = cfg().weapon
    if type(weapon) ~= 'table' or not weapon.enabled or not pedExists(ped) then return false end
    local name = weapon[sexOf(sex) or 'male']
    if not name then return false end
    return WCNative.ped.giveWeapon(ped, name, weapon.ammo or 6, false, true)
end

--- Play a random standing scenario on a preview ped, anchored so it cannot wander out of frame.
---@param sex string|boolean
function S.idle(ped, sex)
    if not pedExists(ped) then return false end
    local list = (cfg().scenarios or {})[sexOf(sex) or 'male']
    if type(list) ~= 'table' or #list == 0 then return false end
    FreezeEntityPosition(ped, true)
    SetEntityInvincible(ped, true)
    SetPedCanBeTargetted(ped, false)
    ClearPedTasks(ped)
    return WCNative.scene.startScenario(ped, list[math.random(1, #list)], -1, GetEntityHeading(ped))
end

--- Delete a preview ped (its overlay state included). Never deletes a player ped.
function S.destroy(ped)
    tracked[ped] = nil
    if Appearance.Overlays then Appearance.Overlays.forget(ped) end
    if not pedExists(ped) or ped == PlayerPedId() or IsPedAPlayer(ped) then return false end
    SetEntityAsMissionEntity(ped, true, true)
    pcall(w.entity.delete, ped, true)
    return true
end

--- Create a preview ped at coords and render an appearance on it; returns the ped only once it
--  is registered in the private scene, positioned, rendered and shown. On any failure the ped is
--  deleted and nil, err is returned.
---@param model? string model name; default 'mp_' .. app.sex
---@param coords table { x, y, z, heading }
---@param app table v3 appearance
---@return integer|nil ped, string|nil err
function S.create(model, coords, app)
    local x, y, z, h = xyzh(coords)
    if not x then return nil, 'INVALID_PAYLOAD' end
    if model == nil and type(app) == 'table' and sexOf(app.sex) then model = 'mp_' .. app.sex end
    if type(model) ~= 'string' then return nil, 'INVALID_PAYLOAD' end

    local okCreate, ped = pcall(w.entity.create, model, vector4(x, y, z, h), true, 0, { scriptHost = true })
    if not okCreate or not pedExists(ped) then return nil, 'INTERNAL_ERROR' end
    tracked[ped] = true

    local ok, err = pcall(function()
        FreezeEntityPosition(ped, true)
        SetEntityVisible(ped, false)
        SetEntityAsMissionEntity(ped, true, true)
        local netId = WCUtil.waitUntil(function()
            if not pedExists(ped) then return nil end
            local id = NetworkGetNetworkIdFromEntity(ped)
            return (id and id > 0) and id or nil
        end, S.NETWORK_TIMEOUT, 0)
        if not netId then return 'NOT_NETWORKED' end
        local result = w.callback.await('w_creators:scene:registerPed', false, netId)
        if type(result) ~= 'table' or result.ok ~= true then
            return type(result) == 'table' and result.code or 'INTERNAL_ERROR'
        end
        local placed, code = S.position(ped, { x, y, z, h })
        if not placed then return code end
        local rendered, reason = Appearance.RestoreCharacter(ped, app)
        if not rendered then return reason or 'INTERNAL_ERROR' end
        if not S.ready(ped) then return 'NOT_READY' end
        S.show(ped)
        return nil
    end)
    if not ok or err then
        WCDebug.warn('scene', 'preview ped failed: %s', tostring(err))
        S.destroy(ped)
        return nil, ok and err or 'INTERNAL_ERROR'
    end
    return ped
end

--- Delete every tracked preview ped and every stray non-player ped left in the room (a sudden
--  restart skips onResourceStop, so previews of the previous run can remain there).
---@return integer removed
function S.cleanup()
    local removed = 0
    for ped in pairs(tracked) do
        if S.destroy(ped) then removed = removed + 1 end
    end
    tracked = {}
    local ax, ay, az = xyzh(cfg().anchor)
    local radius = tonumber(cfg().cleanupRadius) or 25.0
    if ax then
        local center = vector3(ax, ay, az)
        local me = PlayerPedId()
        local ok, pool = pcall(GetGamePool, 'CPed')
        for _, ped in ipairs(ok and pool or {}) do
            if ped ~= me and pedExists(ped) and not IsPedAPlayer(ped)
                and #(GetEntityCoords(ped) - center) < radius then
                if S.destroy(ped) then removed = removed + 1 end
            end
        end
    end
    if removed > 0 then WCDebug.log('scene', 'removed %d preview ped(s)', removed) end
    return removed
end

--- The tracked preview peds (a list).
function S.peds()
    local out = {}
    for ped in pairs(tracked) do out[#out + 1] = ped end
    return out
end

AddEventHandler('onResourceStop', function(resource)
    if resource ~= GetCurrentResourceName() then return end
    for ped in pairs(tracked) do pcall(S.destroy, ped) end
    tracked = {}
    if loaded then
        ClearFocus()
        ClearTimecycleModifier()
        NetworkClearClockTimeOverride()
        loaded = false
    end
    -- the room maps go too, unless the player still stands in the room (it floats: removing its
    -- floor under the player would drop them)
    local ok, inRoom = pcall(function()
        local ax, ay, az = xyzh(cfg().anchor)
        if not ax then return false end
        local radius = tonumber(cfg().cleanupRadius) or 25.0
        return #(GetEntityCoords(PlayerPedId()) - vector3(ax, ay, az)) < radius
    end)
    if ok and not inRoom then pcall(S.unload) end
end)
