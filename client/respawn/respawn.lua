-- =====================================================================
--  client/respawn/respawn.lua  —  WCRespawn, the respawn service (ARCHITECTURE.md §12)
--
--  One explicit life-cycle state machine for the local player, polled every
--  Config.Respawn.pollMs (not every frame):
--
--      ALIVE → DYING → DEAD → RESPAWN_PENDING → RESPAWNING → ALIVE
--
--    ALIVE            the ped is alive
--    DYING            death was just observed (the ped is down); open editors / panels are closed
--                     here through their cancel path
--    DEAD             the ped is dead and waits for a resurrect (hospital, admin, another resource)
--    RESPAWN_PENDING  Resurrect() accepted a request and waits for an appearance render in flight
--    RESPAWNING       the resurrect native ran; waiting (Config.Respawn.resurrectTimeoutMs) for the
--                     alive ped, then the saved appearance is rendered on it
--
--  exports.w_creators:Resurrect(coords, heading, reason) is the single resurrect entry (used by
--  w_ambulancejob, which falls back to the plain native while w_creators is stopped). A second
--  call while one is in flight is refused (false). A successful resurrect fires the local event
--  w_creators:client:resurrected(reason) so a death system can clear its own dead state (a
--  listener skips the reasons it resurrected itself, e.g. 'hospital').
--
--  The watcher also restores the saved appearance once after an EXTERNAL resurrect (another
--  resource resurrected / respawned the player: the ped handle changed, or dead → alive). It
--  never touches weapons or inventory, never renders over an open editor, never changes a
--  non-MP model another resource chose, and ignores every transition while the player is in the
--  character scene (selector / creator / spawn in progress).
--
--    WCRespawn.STATES                         the state names
--    WCRespawn.state()                        the current state
--    WCRespawn.poll()                         one watcher step (the poll thread calls it)
--    WCRespawn.resurrect(coords, heading, reason) -> boolean   (= exports.w_creators:Resurrect)
--    WCRespawn.isDown(ped?)                   is the ped dying or dead
--    WCRespawn.inScene()                      is the player in the character scene
--    WCRespawn.closeEditors()                 cancel an open editor / close a panel -> all closed?
--    WCRespawn.reset()                        re-read the ped and settle the state (tests, restart)
-- =====================================================================

WCRespawn = {}
local R = WCRespawn

R.STATES = {
    ALIVE = 'ALIVE',
    DYING = 'DYING',
    DEAD = 'DEAD',
    RESPAWN_PENDING = 'RESPAWN_PENDING',
    RESPAWNING = 'RESPAWNING',
}
local S = R.STATES

R.DEFAULT_POLL_MS = 250
R.DEFAULT_RESURRECT_TIMEOUT = 10000
R.RENDER_WAIT_TIMEOUT = 15000 -- ms RESPAWN_PENDING waits for an appearance render in flight

local state = S.ALIVE
local lastPed = nil        -- the ped handle seen by the previous poll
local closePending = false -- an editor could not be cancelled yet (busy): retried every poll

local function cfg() return Config.Respawn or {} end

local function pollMs()
    return WCUtil.int(cfg().pollMs, 50, 5000, R.DEFAULT_POLL_MS)
end

local function resurrectTimeout()
    return WCUtil.int(cfg().resurrectTimeoutMs, 500, 120000, R.DEFAULT_RESURRECT_TIMEOUT)
end

local function pedExists(ped)
    return type(ped) == 'number' and ped ~= 0 and DoesEntityExist(ped) == true
end

-- A named native that may be missing on a build: a missing or failing call answers false.
local function call(name, ...)
    local fn = _ENV[name]
    if type(fn) ~= 'function' then return false end
    local ok, value = pcall(fn, ...)
    return ok and value
end

local function truthy(v) return v == true or v == 1 end

local function setState(new, why)
    if state == new then return end
    WCDebug.log('respawn', '%s -> %s (%s)', state, new, tostring(why))
    state = new
end

--- Is the ped dying or dead? (IsEntityDead, IsPedDeadOrDying(ped, true) — plain named natives.)
---@param ped? integer default PlayerPedId()
function R.isDown(ped)
    ped = ped or PlayerPedId()
    if not pedExists(ped) then return false end
    return truthy(call('IsEntityDead', ped)) or truthy(call('IsPedDeadOrDying', ped, true))
end

local function isDead(ped)
    return pedExists(ped) and truthy(call('IsEntityDead', ped))
end

--- The player's appearance is being rendered by w_creators (the spawn and the editors wait too).
local function applying()
    local A = Appearance
    if type(A) ~= 'table' then return false end
    if type(A.IsPlayerApplying) == 'function' and A.IsPlayerApplying() then return true end
    local sync = A.Sync
    return type(sync) == 'table' and type(sync.applyingOwn) == 'function' and sync.applyingOwn() == true
end

local function editorSession()
    local E = WCEditor
    if type(E) ~= 'table' or type(E.session) ~= 'function' then return nil end
    local ok, s = pcall(E.session)
    return ok and s or nil
end

--- Is the player in the character scene (selection room, creator, spawn selector of a login)?
--  Transitions seen there belong to those flows (model switches, frozen invisible ped).
function R.inScene()
    if type(CreatorScene) == 'table' and type(CreatorScene.isLoaded) == 'function' and CreatorScene.isLoaded() then
        return true
    end
    if WCState.busy('selection') then return true end
    local sel = WCSpawnSelector
    if type(sel) == 'table' and type(sel.active) == 'function' and sel.active() and sel.kind() ~= 'admin' then
        return true
    end
    local s = editorSession()
    return s ~= nil and s.mode == 'creator'
end

-- In the character scene, or a spawn placement / resurrect of this resource is moving the ped.
local function ignored()
    return R.inScene() or WCState.busy('spawn')
end

--- Close an open appearance editor through its cancel path (the editor restores the saved look,
--  runs the domain's onCancel: snapshot, session:close, preview exit) and close a clothing panel
--  (its onClose runs). The creator is never cancelled here. Returns true when nothing is left open.
---@return boolean
function R.closeEditors()
    local closed = true
    local E = WCEditor
    local s = editorSession()
    if s and s.mode ~= 'creator' then
        local ok, err = pcall(E.action, { id = s.id, op = 'cancel' })
        if not ok then WCDebug.warn('respawn', 'editor cancel failed: %s', tostring(err)) end
        if editorSession() == s then closed = false end
    elseif not s and type(E) == 'table' and type(E.isOpen) == 'function' and E.isOpen() then
        closed = false -- being opened: cancelled on a later poll once it exists
    end
    local P = WCPanel
    if type(P) == 'table' and type(P.isOpen) == 'function' and P.isOpen() then
        pcall(P.close)
        if P.isOpen() then closed = false end
    end
    return closed
end

local function modelIsMp(ped)
    local model = WCUtil.u32(GetEntityModel(ped))
    return model ~= nil and (model == WCUtil.u32(GetHashKey('mp_male')) or model == WCUtil.u32(GetHashKey('mp_female')))
end

--- May the saved appearance be rendered on the player now?
local function mayRestore()
    if cfg().restoreAppearance == false then return false end
    if not WCServices.enabled('deathRespawn') then return false end
    if type(WCState.appearance) ~= 'table' then return false end
    if WCState.inEditor() or R.inScene() then return false end
    return true
end

local function restoreAppearance(why)
    if not mayRestore() then return false end
    local ok, done, err = pcall(Appearance.RestorePlayer)
    if not ok or not done then
        WCDebug.warn('respawn', 'appearance restore after %s failed: %s', why, tostring(ok and err or done))
        return false
    end
    WCDebug.log('respawn', 'appearance restored after %s', why)
    return true
end

--- Settle the state from what the ped shows now (after a failed resurrect or a reset).
local function settle()
    local ped = PlayerPedId()
    lastPed = ped
    if isDead(ped) then
        setState(S.DEAD, 'settle')
    elseif R.isDown(ped) then
        setState(S.DYING, 'settle')
    else
        setState(S.ALIVE, 'settle')
    end
end

function R.state() return state end

function R.reset()
    closePending = false
    settle()
end

-- An external resurrect/respawn: render the saved appearance once on the new ped.
local function external(ped, why)
    lastPed = ped
    setState(S.ALIVE, why)
    if not modelIsMp(ped) then
        WCDebug.log('respawn', 'external %s on a non-MP model: appearance left alone', why)
        return
    end
    restoreAppearance(why)
    lastPed = PlayerPedId() -- a model switch inside the restore changes the handle
end

--- One watcher step.
function R.poll()
    if state == S.RESPAWN_PENDING or state == S.RESPAWNING then return end
    local ped = PlayerPedId()
    if not pedExists(ped) then return end

    if ignored() then
        -- the scene / spawn flows own the ped: follow it without reacting
        lastPed = ped
        if state ~= S.ALIVE and not R.isDown(ped) then setState(S.ALIVE, 'scene') end
        return
    end

    local down = R.isDown(ped)
    local changed = lastPed ~= nil and ped ~= lastPed

    if state == S.ALIVE then
        if down then
            lastPed = ped
            setState(S.DYING, 'death observed')
            closePending = not R.closeEditors()
            return
        end
        if changed and not applying() and not WCState.inEditor() then
            external(ped, 'respawn')
            return
        end
        lastPed = ped
        return
    end

    -- DYING / DEAD
    if closePending then closePending = not R.closeEditors() end
    if not down then
        closePending = false
        if applying() then
            lastPed = ped
            setState(S.ALIVE, 'revived while rendering')
            return
        end
        external(ped, 'resurrect')
        return
    end
    lastPed = ped
    if state == S.DYING and isDead(ped) then setState(S.DEAD, 'dead') end
end

-- The body of a resurrect (runs inside pcall; the lock is held by the caller).
local function run(coords, heading, reason)
    local ped = PlayerPedId()
    local x, y, z = WCUtil.xyz(coords)
    if not x then
        if coords ~= nil or not pedExists(ped) then return false end
        local at = GetEntityCoords(ped)
        x, y, z = at.x, at.y, at.z
    end
    heading = tonumber(heading)
    if not WCUtil.isFinite(heading) then heading = pedExists(ped) and GetEntityHeading(ped) or 0.0 end

    -- RESPAWN_PENDING: an appearance render in flight would be left on a stale handle
    WCUtil.waitUntil(function() return not applying() or nil end, R.RENDER_WAIT_TIMEOUT, 50)

    setState(S.RESPAWNING, reason)
    if not WCNative.respawn.resurrect(vector3(x, y, z), heading) then
        settle()
        return false
    end
    local alive = WCUtil.waitUntil(function()
        local p = PlayerPedId()
        if pedExists(p) and not R.isDown(p) then return p end
        return nil
    end, resurrectTimeout(), 0)
    if not alive then
        WCDebug.warn('respawn', 'resurrect (%s): the player did not come back within %d ms', reason, resurrectTimeout())
        settle()
        return false
    end
    lastPed = alive
    closePending = false
    restoreAppearance('resurrect (' .. reason .. ')')
    lastPed = PlayerPedId()
    setState(S.ALIVE, reason)
    return true
end

--- Resurrect the local player at coords (nil = where it stands) facing heading, then render the
--  saved appearance (Config.Respawn.restoreAppearance and the deathRespawn service). Yields.
--  Refused (false) while another resurrect is pending or running.
---@param coords table|vector3|nil
---@param heading number|nil
---@param reason string|nil free text for the debug log ('hospital', 'admin', ...)
---@return boolean
function R.resurrect(coords, heading, reason)
    reason = type(reason) == 'string' and reason:sub(1, 32) or 'external'
    if state == S.RESPAWN_PENDING or state == S.RESPAWNING then return false end
    if not WCState.busy('respawn', true) then return false end
    setState(S.RESPAWN_PENDING, reason)
    local ok, result = pcall(run, coords, heading, reason)
    if not ok then
        WCDebug.warn('respawn', 'resurrect (%s) failed: %s', reason, tostring(result))
        settle()
        result = false
    end
    WCState.busy('respawn', false)
    if result == true then TriggerEvent('w_creators:client:resurrected', reason) end
    return result == true
end

exports('Resurrect', function(coords, heading, reason)
    return R.resurrect(coords, heading, reason)
end)

CreateThread(function()
    lastPed = PlayerPedId()
    while true do
        Wait(pollMs())
        local ok, err = pcall(R.poll)
        if not ok then WCDebug.warn('respawn', 'poll failed: %s', tostring(err)) end
    end
end)

AddEventHandler('onResourceStop', function(resource)
    if resource ~= GetCurrentResourceName() then return end
    closePending = false
    WCState.busy('respawn', false)
end)
