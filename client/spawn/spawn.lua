-- =====================================================================
--  client/spawn/spawn.lua  —  WCSpawn, the client safe spawn (ARCHITECTURE.md §11, §16.3, §17)
--
--  w_creators:client:spawn(pos, meta {kind = 'initial'|'login'|'switch'})
--      The character enters the world (w_core listens to this event too: a fresh login). The
--      position always comes from the server. The safe spawn:
--        curtain / fade out → close the spawn selector → wait for an appearance render in flight
--        → move + request collision (timeout) → ground probe from above (a probe more than 20 m
--        from the target is rejected) → no collision / no ground: Config.Spawn.firstSpawn
--        → place + heading → unfreeze, visible, vulnerable → leave the private bucket
--        (w_creators:scene:release) and the character room (maps unloaded) → world UI and radar
--        back → loading screen dismissed → fade in → curtain down.
--      Kind 'initial' then starts the first-spawn cutscene when Config.Creator.enableCutscene
--      (TriggerEvent('W:CREATOR:FirstSpawn'), client/creator/cutscene.lua).
--
--  w_creators:client:respawn(pos, meta {kind = 'admin'|'death', point})
--      A player already in the world is moved (admin respawn, RespawnPlayer export, an admin spawn
--      choice): the same placement, reviving first when dead. No login flow, and the routing
--      bucket is never touched (§11). Ignored while the player is in the character scene (that
--      flow owns the ped and the bucket). Before the move:
--        - an open editor / clothing panel / service visit is cancelled and the respawn waits
--          (FLOW_TIMEOUT) until it has fully ended: the barber / clinic seat and the store's
--          fitting room put the player back from their own threads, which would undo the move.
--          A flow that does not end in time aborts the respawn (the player is not moved);
--        - the first-spawn wagon cutscene is stopped (its fallback would move the player later);
--        - a down player (or any player on kind 'death') is revived by the death system when it
--          runs (DEATH_OWNER: w_ambulancejob's hospital:client:Revive, which clears its own dead /
--          last-stand state and resurrects through exports.w_creators:Resurrect); otherwise, or
--          when that revive does not start, WCRespawn.resurrect.
--
--    WCSpawn.spawn(pos, meta)     WCSpawn.respawn(pos, meta)      (the event bodies; yield)
--    WCSpawn.place(pos) -> { x, y, z, heading }, fellBack           the safe placement
--    WCSpawn.probe(x, y, z) -> groundZ | nil                        the ground probe
--    WCSpawn.count() -> number of spawn/respawn events received (the selector's hand-off check)
--    WCSpawn.busy() -> is a placement running
-- =====================================================================

WCSpawn = {}
local Sp = WCSpawn

Sp.COLLISION_TIMEOUT = 10000   -- ms for the collision around the target
Sp.APPEARANCE_TIMEOUT = 20000  -- ms to wait for an appearance render in flight
Sp.LOCK_TIMEOUT = 30000        -- ms a second spawn waits for the one running
Sp.GROUND_MAX_DELTA = 20.0     -- a ground probe further than this from the target is rejected (m)
Sp.PROBE_ABOVE = { 2.0, 20.0 } -- probe heights above the target (m), nearest first
Sp.FADE_OUT = 400
Sp.FADE_IN = 500
Sp.FLOW_TIMEOUT = 15000        -- ms a respawn waits for an open editor / service visit to end
Sp.FLOW_STEP = 100             -- ms between two checks (and cancel retries) of that wait
Sp.REVIVE_START_TIMEOUT = 3000 -- ms for the death system's revive to start
Sp.REVIVE_TIMEOUT = 30000      -- ms for that revive to finish (resurrect + appearance)
-- The death system that owns the dead / last-stand state: a respawn revives through it so that
-- state is cleared (nil = always WCRespawn.resurrect).
--  inBed / endBed: the export that reports a hospital bed stay and the one that ends it (bed,
--  camera, lying animation, invincibility, pending AI heal): a world respawn ends the stay first.
-- (w_medic since 2026-10-14: it replaced w_ambulancejob, with the same events and exports)
Sp.DEATH_OWNER = { resource = 'w_medic', revive = 'hospital:client:Revive', isDead = 'IsDead',
                   inBed = 'InHospitalBed', endBed = 'EndBedStay' }

local LOGIN_KINDS = { initial = true, login = true, switch = true }
local WORLD_KINDS = { admin = true, death = true }

local received = 0   -- spawn/respawn events received
local running = 0    -- placements in progress
local lockHeld = 0   -- placements holding the WCState 'spawn' lock

local function pedExists(ped)
    -- BOOL natives answer 1 (not true) on this runtime: never compare them with == true
    return type(ped) == 'number' and ped ~= 0 and not not DoesEntityExist(ped)
end

-- A named native that may be missing on a build: never throws.
local function call(name, ...)
    local fn = _ENV[name]
    if type(fn) ~= 'function' then return false end
    local ok, value = pcall(fn, ...)
    return ok and value
end

function Sp.count() return received end
function Sp.busy() return running > 0 end

-- ---------------------------------------------------------------------
--  Placement
-- ---------------------------------------------------------------------

local function headingOf(pos)
    if type(pos) ~= 'table' and type(pos) ~= 'userdata' and type(pos) ~= 'vector4' then return nil end
    local ok, h = pcall(function() return pos.heading or pos.w or pos[4] end)
    h = ok and tonumber(h) or nil
    return WCUtil.isFinite(h) and h + 0.0 or nil
end

local function firstSpawn()
    local cfg = (Config.Spawn and Config.Spawn.firstSpawn) or {}
    local x, y, z = WCUtil.xyz(cfg.coords)
    if not x then
        -- a broken Config.Spawn.firstSpawn (the dev tool wc_catalog_validate reports it): the
        -- player stays where the ped is rather than at a position this file would have to invent
        WCDebug.warn('spawn', 'Config.Spawn.firstSpawn.coords is invalid: the player stays in place')
        x, y, z = WCUtil.xyz(GetEntityCoords(PlayerPedId()))
        x, y, z = x or 0.0, y or 0.0, z or 0.0
    end
    return x + 0.0, y + 0.0, z + 0.0, headingOf({ heading = cfg.heading }) or 0.0
end

local function snapEnabled()
    return not (Config.Spawn and Config.Spawn.snapToGround == false)
end

--- Probe the ground from above the target. Returns the ground height, or nil when no probe
--  found ground within GROUND_MAX_DELTA of the target (over water, outside the loaded area).
---@return number|nil
function Sp.probe(x, y, z)
    for _, above in ipairs(Sp.PROBE_ABOVE) do
        local ok, found, groundZ = pcall(GetGroundZAndNormalFor_3dCoord, x + 0.0, y + 0.0, z + above)
        groundZ = ok and tonumber(groundZ) or nil
        if (found == true or found == 1) and WCUtil.isFinite(groundZ)
            and math.abs(groundZ - z) <= Sp.GROUND_MAX_DELTA then
            return groundZ + 0.0
        end
    end
    return nil
end

-- Move the ped there, wait for the collision, snap it to the ground. Returns the final z or
-- nil, reason ('NO_COLLISION' | 'NO_GROUND').
--  The coordinates are floats from here on: a Lua integer (an integral coordinate decoded from a
--  framework row, a table-form config) reaches a float native as its integer bits (docs/NATIVES.md).
local function settle(ped, x, y, z, h)
    x, y, z, h = x + 0.0, y + 0.0, z + 0.0, (tonumber(h) or 0.0) + 0.0
    SetEntityCoords(ped, x, y, z, false, false, false, false)
    SetEntityHeading(ped, h)
    local collided = WCUtil.waitUntil(function()
        RequestCollisionAtCoord(x, y, z)
        return HasCollisionLoadedAroundEntity(ped) or nil
    end, Sp.COLLISION_TIMEOUT, 0)
    if not collided then return nil, 'NO_COLLISION' end
    if snapEnabled() then
        local groundZ = Sp.probe(x, y, z)
        if not groundZ then return nil, 'NO_GROUND' end
        z = groundZ
        SetEntityCoords(ped, x, y, z, false, false, false, false)
        SetEntityHeading(ped, h)
    end
    return z
end

--- Place the local player safely at pos ({x, y, z, heading} / vector3 / vector4); falls back to
--  Config.Spawn.firstSpawn when pos is invalid or has no collision / no ground. The ped stays
--  frozen (the caller releases it).
---@return table placed { x, y, z, heading }, boolean fellBack
function Sp.place(pos)
    local ped = PlayerPedId()
    FreezeEntityPosition(ped, true)
    local x, y, z = WCUtil.xyz(pos)
    if x then
        x, y, z = x + 0.0, y + 0.0, z + 0.0
        local h = headingOf(pos) or GetEntityHeading(ped)
        local groundZ, why = settle(ped, x, y, z, h)
        if groundZ then return { x = x, y = y, z = groundZ, heading = h }, false end
        WCDebug.warn('spawn', 'target %.1f %.1f %.1f rejected (%s): first spawn fallback', x, y, z, tostring(why))
    else
        WCDebug.warn('spawn', 'invalid spawn position: first spawn fallback')
    end
    local fx, fy, fz, fh = firstSpawn()
    local groundZ, why = settle(ped, fx, fy, fz, fh)
    if not groundZ then
        -- nothing better is known: the configured point as it is (already placed there)
        WCDebug.warn('spawn', 'first spawn not settled (%s): placed as configured', tostring(why))
        groundZ = fz
    end
    return { x = fx, y = fy, z = groundZ, heading = fh }, true
end

-- ---------------------------------------------------------------------
--  The steps around the placement
-- ---------------------------------------------------------------------

-- Serialise spawns: a second event waits for the one running (the newest position wins last).
local function acquire()
    local got = WCState.busy('spawn', true)
        or WCUtil.waitUntil(function() return WCState.busy('spawn', true) or nil end, Sp.LOCK_TIMEOUT, 50) == true
    if got then lockHeld = lockHeld + 1 else WCDebug.warn('spawn', 'spawn lock busy: going on without it') end
    running = running + 1
    return got
end

local function finish(mine)
    running = math.max(running - 1, 0)
    if mine and lockHeld > 0 then
        lockHeld = lockHeld - 1
        WCState.busy('spawn', false)
    end
end

local function applyingAppearance()
    local A = Appearance
    if type(A) ~= 'table' then return false end
    if type(A.IsPlayerApplying) == 'function' and A.IsPlayerApplying() then return true end
    local sync = A.Sync
    return type(sync) == 'table' and type(sync.applyingOwn) == 'function' and sync.applyingOwn() == true
end

--- Wait for an appearance render in flight (the ped must not be moved mid-render, nor shown half
--  dressed). Returns false on timeout (the spawn goes on).
local function waitAppearance()
    if not applyingAppearance() then return true end
    local done = WCUtil.waitUntil(function() return not applyingAppearance() or nil end, Sp.APPEARANCE_TIMEOUT, 20)
    if not done then WCDebug.warn('spawn', 'appearance still applying after %d ms', Sp.APPEARANCE_TIMEOUT) end
    return done == true
end

local function darken()
    if IsScreenFadedOut() then
        WCurtain.show('spawn')
    else
        StartFade(Sp.FADE_OUT, 'spawn')
    end
end

local function selector()
    local sel = WCSpawnSelector
    return type(sel) == 'table' and sel or nil
end

-- Close the spawn selector (its camera, prompts and focus); true when it held the player.
local function closeSelector()
    local sel = selector()
    if not sel then return false end
    local holding = sel.holding and sel.holding() or false
    pcall(sel.close)
    return holding
end

-- The in-world spawn selector (admin / death) still holds the player (frozen, hidden, invincible,
-- world UI off, screen faded out by its confirm) and the respawn gives up before placing him:
-- give him back where he stands. true when a hold was released.
local function releaseSelectorHold()
    local sel = selector()
    if not sel or not sel.holding or not sel.holding() then return false end
    local ok, err = pcall(sel.close, { restore = true })
    if not ok then WCDebug.warn('spawn', 'releasing the spawn selector hold failed: %s', tostring(err)) end
    return true
end

-- Give the player the world: unfrozen, and (full) visible, vulnerable, networked for all.
local function releasePed(full)
    local ped = PlayerPedId()
    if not pedExists(ped) then return end
    if full then
        call('NetworkSetEntityOnlyExistsForParticipants', ped, false)
        SetEntityVisible(ped, true)
        SetEntityInvincible(ped, false)
    end
    FreezeEntityPosition(ped, false)
end

-- mod[fn]() when the module and the function exist; true only for a truthy answer.
local function ask(mod, fn)
    if type(mod) ~= 'table' or type(mod[fn]) ~= 'function' then return false end
    local ok, value = pcall(mod[fn])
    return ok and value ~= nil and value ~= false
end

-- An editor, a clothing panel or a service visit is open, or still being torn down.
local function flowOpen()
    return ask(WCEditor, 'isOpen') or ask(WCPanel, 'isOpen')
        or ask(WCServiceFlow, 'current') or ask(WCServiceSeat, 'active')
end

-- Cancel what is open: the editor / panel through WCRespawn.closeEditors (the editor's cancel
-- path), a service flow still opening (no editor yet) through WCServiceFlow.abort.
local function cancelFlows(R)
    if type(R) == 'table' then R.closeEditors() end
    local F = WCServiceFlow
    if type(F) == 'table' and type(F.current) == 'function' and type(F.abort) == 'function' then
        local ok, flow = pcall(F.current)
        if ok and type(flow) == 'table' and not flow.committed then pcall(F.abort, flow, 'respawn') end
    end
end

--- Close the editors and service visits and wait until they have fully ended (the seat and the
--  fitting room put the player back from their own threads). A busy editor (a commit in flight)
--  is retried until it lets go. Returns false when something is still open after FLOW_TIMEOUT.
local function endFlows(R)
    if not flowOpen() then return true end
    cancelFlows(R)
    return WCUtil.waitUntil(function()
        if not flowOpen() then return true end
        cancelFlows(R)
        return nil
    end, Sp.FLOW_TIMEOUT, Sp.FLOW_STEP) == true
end

-- Stop the first-spawn wagon ride (its presentation loop and its fallback would take the player
-- back); the player is taken off the wagon first.
local function stopCutscene()
    local C = WCCutscene
    if not ask(C, 'active') then return end
    local ped = PlayerPedId()
    if pedExists(ped) and call('IsPedInAnyVehicle', ped, false) then call('ClearPedTasksImmediately', ped) end
    pcall(C.stop)
    WCDebug.log('spawn', 'first-spawn cutscene stopped by a respawn')
end

-- The death system's revive, when it runs: true once the player is back (alive, no resurrect in
-- flight), false when it is not running or its revive did not start / finish.
local function ownerRevive(R)
    local owner = Sp.DEATH_OWNER
    if type(owner) ~= 'table' or type(owner.resource) ~= 'string' or type(owner.revive) ~= 'string' then
        return false
    end
    if call('GetResourceState', owner.resource) ~= 'started' then return false end
    local S = R.STATES
    local function inFlight()
        local st = R.state()
        return st == S.RESPAWN_PENDING or st == S.RESPAWNING
    end
    TriggerEvent(owner.revive)
    local started = WCUtil.waitUntil(function()
        return (inFlight() or not R.isDown()) or nil
    end, Sp.REVIVE_START_TIMEOUT, 0)
    if not started then
        WCDebug.warn('spawn', '%s revive did not start: resurrecting here', owner.resource)
        return false
    end
    local back = WCUtil.waitUntil(function()
        return (not inFlight() and not R.isDown()) or nil
    end, Sp.REVIVE_TIMEOUT, 50)
    if not back then WCDebug.warn('spawn', '%s revive did not bring the player back', owner.resource) end
    return back == true
end

--- A hospital bed stay of the death system (Sp.DEATH_OWNER.inBed) is ended before the player is
--  moved (Sp.DEATH_OWNER.endBed): otherwise he arrives still lying, invincible and seen through
--  the bed camera, with the bed reserved, and the pending AI heal re-poses him in the bed later.
--  true when a stay was ended.
function Sp.endBedStay()
    local owner = Sp.DEATH_OWNER
    if type(owner) ~= 'table' or type(owner.resource) ~= 'string' or type(owner.inBed) ~= 'string'
        or type(owner.endBed) ~= 'string' then
        return false
    end
    if call('GetResourceState', owner.resource) ~= 'started' then return false end
    local okBed, inBed = pcall(function() return exports[owner.resource][owner.inBed]() end)
    if not okBed or inBed ~= true then return false end
    local okEnd, ended = pcall(function() return exports[owner.resource][owner.endBed]() end)
    if not okEnd then
        WCDebug.warn('spawn', '%s could not end the bed stay: %s', owner.resource, tostring(ended))
        return false
    end
    return ended ~= false
end

--- Revive the player before a world respawn: through the death system when it runs (a down player,
--  or any player on kind 'death': it also clears its last stand), else WCRespawn.resurrect.
local function revive(R, pos, kind)
    if type(R) ~= 'table' then return end
    local down = R.isDown()
    if not down and kind ~= 'death' then return end
    if ownerRevive(R) then return end
    if R.isDown() and not R.resurrect(pos, headingOf(pos), kind) then
        WCDebug.warn('spawn', '%s respawn: the resurrect failed', kind)
    end
end

local function restoreUi()
    pcall(SetWorldUiVisible, true)
    pcall(w.setRadarVisible, true)
    DisplayHud(true)
end

-- Leave the private bucket and the character room for good (the player is out of it now).
local function leaveScene()
    local scene = CreatorScene
    local isolatedHere = type(scene) == 'table' and scene.isIsolated()
    if type(scene) == 'table' then
        pcall(scene.release, { unload = true })
        pcall(scene.cleanup)
    end
    if not isolatedHere then
        -- isolated by another path (the server's selector scene): the guarded release is
        -- idempotent and only restores a bucket w_creators set
        local ok, result = pcall(w.callback.await, 'w_creators:scene:release', false)
        if not ok or not WCResult.is(result) or not result.ok then
            WCDebug.log('spawn', 'scene release: %s', ok and type(result) == 'table' and tostring(result.code) or 'failed')
        end
    end
end

-- ---------------------------------------------------------------------
--  The two flows
-- ---------------------------------------------------------------------

--- w_creators:client:spawn — the character enters the world.
---@param pos table { x, y, z, heading }
---@param meta table|nil { kind }
function Sp.spawn(pos, meta)
    meta = type(meta) == 'table' and meta or {}
    local kind = LOGIN_KINDS[meta.kind] and meta.kind or 'login'
    local mine = acquire()
    local ok, err = pcall(function()
        darken()
        closeSelector()
        waitAppearance()
        local placed, fellBack = Sp.place(pos)
        WCDebug.log('spawn', '%s spawn at %.1f %.1f %.1f%s', kind, placed.x, placed.y, placed.z,
            fellBack and ' (fallback)' or '')
        releasePed(true)
        leaveScene()
        restoreUi()
        DismissLoadingScreen()
        EndFade(Sp.FADE_IN)
    end)
    if not ok then
        WCDebug.warn('spawn', 'spawn failed: %s', tostring(err))
        releasePed(true)
        restoreUi()
        pcall(WCurtain.restore, true)
    end
    finish(mine)
    if kind == 'initial' and Config.Creator and Config.Creator.enableCutscene then
        TriggerEvent('W:CREATOR:FirstSpawn')
    end
    return ok
end

--- w_creators:client:respawn — move a player already in the world (admin / death).
---@param pos table { x, y, z, heading }
---@param meta table|nil { kind, point }
function Sp.respawn(pos, meta)
    meta = type(meta) == 'table' and meta or {}
    local kind = WORLD_KINDS[meta.kind] and meta.kind or 'admin'
    local R = WCRespawn
    if type(R) == 'table' and R.inScene() then
        WCDebug.warn('spawn', '%s respawn ignored: the player is in the character scene', kind)
        return false
    end
    local mine = acquire()
    local fromSelector = false
    local aborted = false
    local ok, err = pcall(function()
        if not endFlows(R) then
            aborted = true
            WCDebug.warn('spawn', '%s respawn aborted: an editor / service visit did not end within %d ms',
                kind, Sp.FLOW_TIMEOUT)
            releaseSelectorHold()
            return
        end
        stopCutscene()
        darken()
        fromSelector = closeSelector()
        waitAppearance()
        -- before the revive: the death system's revive re-poses a patient still in his bed
        Sp.endBedStay()
        revive(R, pos, kind)
        local placed, fellBack = Sp.place(pos)
        WCDebug.log('spawn', '%s respawn at %.1f %.1f %.1f%s', kind, placed.x, placed.y, placed.z,
            fellBack and ' (fallback)' or '')
        releasePed(fromSelector)
        if fromSelector then restoreUi() end
        EndFade(Sp.FADE_IN)
    end)
    if not ok then
        WCDebug.warn('spawn', 'respawn failed: %s', tostring(err))
        -- a throw before closeSelector() leaves the selector's hold in place
        if releaseSelectorHold() then fromSelector = true end
        releasePed(fromSelector)
        if fromSelector then restoreUi() end
        pcall(WCurtain.restore, true)
    end
    finish(mine)
    return ok and not aborted
end

RegisterNetEvent('w_creators:client:spawn', function(pos, meta)
    received = received + 1
    -- the server put the player in bucket 0 before sending this (WCScene.toWorld): the private
    -- scene is over, whatever the room's final exit does later
    if type(CreatorScene) == 'table' and CreatorScene.forgetIsolation then pcall(CreatorScene.forgetIsolation) end
    CreateThread(function() Sp.spawn(pos, meta) end)
end)

RegisterNetEvent('w_creators:client:respawn', function(pos, meta)
    received = received + 1
    CreateThread(function() Sp.respawn(pos, meta) end)
end)

AddEventHandler('onResourceStop', function(resource)
    if resource ~= GetCurrentResourceName() then return end
    if running == 0 then return end
    -- a placement cut short: never leave the player frozen, hidden or in the dark
    running = 0
    pcall(releasePed, true)
    pcall(restoreUi)
    pcall(WCurtain.restore, true)
    if lockHeld > 0 then WCState.busy('spawn', false) end
    lockHeld = 0
end)
