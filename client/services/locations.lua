-- =====================================================================
--  client/services/locations.lua  —  the service points and the service-editor flow
--  (ARCHITECTURE.md §7.2, §9.3, §17)
--
--  WCServicePoints: one w_lib walk-up prompt (w.prompt.at), one blip (w.blip.create) and one NPC
--  (w.entity.create) per enabled location of an enabled service (clothing, wardrobe, barber,
--  surgery), plus a barber's own chair prop. w_lib owns the distance handling: nothing here scans the
--  locations per frame. A location with prompt = false gets no prompt here (another resource provides
--  the interaction, e.g. the surgery clinics of w_medic through the server export OpenCosmeticSurgery);
--  its NPC and blip, when the board gave it any, are still drawn here. The places come from the
--  server (server/locations/store.lua, edited with /servicesadmin): config/locations.lua is used until
--  it answers, and every change rebuilds the points, never while a visit runs (WCServicePoints.rebuild).
--  Opening
--  hours hide the prompt while the location is closed: the rule of WCLocations.isOpen applied to the
--  hour the server publishes (GlobalState[WCServicePoints.HOUR_KEY]); the client has no os library
--  and the game clock is not the server's, so without a published hour the prompt shows and the
--  server's <kind>:open decides. Labels follow a language switch; everything is removed on stop.
--
--  WCServiceFlow: the client half of one WCSessions preview transaction, shared by the store, the
--  wardrobe, the barber and the surgery clinic (the last two seat the player through WCServiceSeat,
--  client/barber/barber.lua): <kind>:open -> (store: private fitting room, teleport) -> WCPreviewEnv -> WCEditor
--  -> <kind>:commit. Every way out (commit, cancel, death, a server-forced close, an editor closed
--  elsewhere) restores the snapshot when needed, closes the server session and undoes the preview:
--  coordinates, routing bucket, environment, fade. A running flow holds the WCState lock 'service'
--  from its first check until the player is back (open and leave phases included), so the
--  lock-based guards of the other flows see it. A resource stop undoes the preview without yielding.
-- =====================================================================

WCServiceFlow = {}
local F = WCServiceFlow

F.FADE_MS = 400
F.FADE_KEY = 'wardrobe'          -- the w_loading curtain text of a fitting-room transition
F.COLLISION_TIMEOUT = 8000       -- ms for the collision around the player after a move
F.WATCH_MS = 250                 -- the death / forced-close watcher period
F.FINISH_TIMEOUT = 10000         -- ms a committed flow waits for its editor to close
F.RECONCILE_TRIES = 3            -- asks for the recorded answer of an uncertain commit
F.RECONCILE_WAIT = 1000          -- ms between those asks while the server commit still runs
F.RELEASE_MS = 100               -- ms between letting the player go (reading, tasks) and the move
F.HEADING_HOLD_MS = 1500         -- ms the player is held on the stand's heading once the camera opens
F.STAND_TOLERANCE = 1.0          -- metres off the stand (flat) after which the player is put back on it
F.STAND_DROP = 2.5               -- metres off the stand's height (another floor) likewise
F.STAND_CHECKS = 3               -- times the move to the stand is checked (and made again) under the fade
F.STAND_CHECK_MS = 100           -- ms between those checks

F.LOCK = 'service'               -- the WCState lock a running service flow holds

local current = nil              -- the one running flow
local opSequence = 0

-- The client locks of other flows that make a service unavailable (WCState.LOCKS; 'service' is
-- also taken by a barber / surgery flow that follows the same rule).
local LOCKS = { 'selection', 'spawn', 'respawn', 'clothingAction', F.LOCK }
-- Commit answers after which the server may or may not have committed (a lost reply).
local UNCERTAIN = { INTERNAL_ERROR = true, BUSY = true }
-- Commit answers that mean the server session is gone.
local SESSION_GONE = { SESSION_NOT_FOUND = true, SESSION_EXPIRED = true }

local function notify(key)
    if type(key) ~= 'string' or key == '' then return end
    pcall(w.notify, { description = locale(key), type = 'error' })
end
F.notify = notify

--- 1.0.6: a failure Result as the player reads it, its specifics included (WCResult.text).
local function notifyResult(r)
    pcall(w.notify, { description = WCResult.text(r, locale), type = 'error' })
end

--- Call a server callback and always return a WCResult (a throw, a timeout or anything that is
--  not a Result is INTERNAL_ERROR).
---@return table Result
function F.call(name, ...)
    local ok, result = pcall(w.callback.await, name, false, ...)
    if not ok then
        WCDebug.warn('services', '%s failed: %s', name, tostring(result))
        return WCResult.fail('INTERNAL_ERROR')
    end
    if not WCResult.is(result) then return WCResult.fail('INTERNAL_ERROR') end
    return result
end
local call = F.call

--- Fire a server callback without waiting for the answer (resource stop: nothing may yield).
local function send(name, ...)
    local ok, err = pcall(w.callback.await, name, function() end, ...)
    if not ok then WCDebug.warn('services', '%s failed: %s', name, tostring(err)) end
end

local function isDead()
    local ok, dead = pcall(IsEntityDead, PlayerPedId())
    return ok and (dead == true or dead == 1)
end

--- Forget the running flow and give back its 'service' lock (only the flow that took it does).
local function release(flow)
    if current == flow then current = nil end
    if flow.ownsLock then
        flow.ownsLock = false
        WCState.busy(F.LOCK, false)
    end
end

--- mod[fn]() when the module and the function exist; true only for a truthy answer.
local function ask(mod, fn)
    if type(mod) ~= 'table' or type(mod[fn]) ~= 'function' then return false end
    local ok, value = pcall(mod[fn])
    return ok and value ~= nil and value ~= false
end

--- Why no service can be opened now (a short reason), or nil when one can: the player is dead,
--  a service session runs, an editor / clothing panel / preview is open, the character scene or
--  another flow (selection, spawn, respawn, clothing action) holds the player.
---@return string|nil
function F.blocked()
    if current then return 'session' end
    if isDead() then return 'dead' end
    if WCState.inEditor() or ask(WCEditor, 'isOpen') then return 'editor' end
    if ask(WCPanel, 'isOpen') then return 'panel' end
    if ask(WCBoard, 'isOpen') then return 'board' end -- the staff's services board (client/services/board.lua)
    if ask(WCPreviewEnv, 'active') then return 'preview' end
    if ask(CreatorScene, 'isLoaded') or ask(CreatorScene, 'isIsolated') then return 'scene' end
    for _, lock in ipairs(LOCKS) do
        if WCState.busy(lock) then return lock end
    end
    if ask(WCCreator, 'active') or ask(WCSpawnSelector, 'active') then return 'scene' end
    for _, mod in ipairs({ WCBarber, WCSurgery }) do
        if ask(mod, 'busy') then return 'session' end
    end
    return nil
end

--- The running flow (store or wardrobe), or nil.
function F.current() return current end

--- Is a store / wardrobe flow running?
function F.busy() return current ~= nil end

-- ---------------------------------------------------------------------
--  Flow internals
-- ---------------------------------------------------------------------

--- The open editor session of this flow, or nil.
local function editorSession(flow)
    if not flow.editorId or type(WCEditor) ~= 'table' then return nil end
    local ok, s = pcall(WCEditor.session)
    if ok and type(s) == 'table' and s.id == flow.editorId then return s end
    return nil
end

local function restore(app, why)
    if type(app) ~= 'table' then return false end
    local ok, done, err = pcall(Appearance.RestorePlayer, app)
    if not ok or not done then
        WCDebug.warn('services', 'appearance restore (%s) failed: %s', why, tostring(ok and err or done))
        return false
    end
    return true
end

local function waitCollision(ped, x, y, z)
    RequestCollisionAtCoord(x, y, z)
    WCUtil.waitUntil(function() return HasCollisionLoadedAroundEntity(ped) or nil end, F.COLLISION_TIMEOUT, 0)
end

--- Is the player on the fitting stand { x, y, z, heading }? His origin is about a metre above the
--  floor the stand gives, so the height is compared loosely: the shop counter is several metres away
--  or on another floor (Valentine's stand is upstairs), never within these tolerances.
local function onStand(ped, stand)
    local at = GetEntityCoords(ped)
    local dx, dy = at.x - stand[1], at.y - stand[2]
    return dx * dx + dy * dy <= F.STAND_TOLERANCE * F.STAND_TOLERANCE and math.abs(at.z - stand[3]) <= F.STAND_DROP
end

--- Put the player on the fitting stand again: set down on its floor (a frozen player is not settled
--  by the game) and turned to its heading.
local function placeOnStand(ped, stand)
    SetEntityCoords(ped, stand[1], stand[2], stand[3], false, false, false, false)
    pcall(WCNative.ped.placeOnGround, ped)
    SetEntityHeading(ped, stand[4])
end

--- Private bucket, fade, then the move to the fitting stand. Returns true | false, Result.
local function enterFittingRoom(flow, preview)
    local x, y, z, h = CreatorScene.coords(preview)
    if not x then return false, WCResult.fail('INVALID_PAYLOAD') end
    local ped = PlayerPedId()
    local at = GetEntityCoords(ped)
    flow.saved = { at.x, at.y, at.z, GetEntityHeading(ped) }
    -- a store with a catalogue book: the player leafs through it first, in the shared world where
    -- the others see it (bounded; a failed or cut-short reading never stops the visit)
    if flow.kind == 'store' and flow.location and WCCatalogue.book(flow.location) then
        local okRead, read = pcall(WCCatalogue.enter, flow.location)
        flow.reading = okRead and read == true
        -- the reading yielded for seconds: a flow stopped meanwhile (death, the server closing the
        -- session) must not reach the prepare. Without a session the server would take it for the
        -- start of a character switch, and the player would be faded and moved for nothing.
        if flow.finished or flow.abortReason or isDead() then
            if flow.reading then
                flow.reading = false
                pcall(WCCatalogue.stop)
            end
            return nil
        end
    end
    local prepared = call('w_creators:scene:prepare')
    if not prepared.ok then return false, prepared end
    flow.isolated = true
    flow.faded = true
    StartFade(F.FADE_MS, F.FADE_KEY)
    -- ⚠️ The reading ends under the fade, and the player is let go BEFORE he is moved. The scene
    --    holds the player where it plays him (at the counter, facing the book); it was freed and the
    --    player moved in the same frame, and the scene's release put him back: he never reached the
    --    fitting room. The editor then opened on him at the counter, and its camera, in front of him,
    --    stood behind the tailor across the counter: the tailor's back filled the screen, his head
    --    above the frame (the owner's screenshot of Valentine). Now: out of the scene, his tasks
    --    cleared, a moment for the game to settle, then the move (the Jump On store does the same,
    --    with the same 100 ms), checked again below before the screen fades in.
    ped = PlayerPedId()
    if flow.reading then pcall(WCCatalogue.release, ped) end
    ClearPedTasksImmediately(ped)
    Wait(F.RELEASE_MS)
    -- a flow stopped during that moment is not moved (leave() undoes the bucket and the fade)
    if flow.finished or flow.abortReason or isDead() then return nil end
    ped = PlayerPedId()
    local stand = { x, y, z, h }
    SetEntityCoords(ped, x, y, z, false, false, false, false)
    SetEntityHeading(ped, h)
    flow.stand = stand
    flow.moved = true
    waitCollision(ped, x, y, z)
    -- the stand's coordinates are the floor he stands on: set him down on it before he is frozen
    -- (a frozen player is not settled by the game, and a stand given a little high left him floating)
    pcall(WCNative.ped.placeOnGround, ped)
    SetEntityHeading(ped, h)
    -- a release that lands late (the scene still ending his part in it) pulls him back to the
    -- counter after the move: looked at again a few frames on, still under the fade, and made again
    -- when it did not hold, so nobody sees him at the counter nor a jump once the screen is back
    for _ = 1, F.STAND_CHECKS do
        Wait(F.STAND_CHECK_MS)
        ped = PlayerPedId()
        if onStand(ped, stand) then break end
        WCDebug.warn('services', 'the move to the fitting stand did not hold: made again')
        placeOnStand(ped, stand)
    end
    return true
end

-- The editors that dress the player (the store, the wardrobe) frame him with the store framings
-- (WCCamera.SETS.shop); the barber and the clinic keep their own.
local SHOP_CAMERA = { store = true, wardrobe = true }

--- Right before the editor opens its camera: put the player back on his stand if something moved
--  him off it, turn him to the stand's heading, and tell the camera to frame from that heading
--  with the store framings (a wardrobe: where he stands, the way he faces).
--  ⚠️ The camera frames whatever spot the player is on when it opens, from the way he faces then,
--     and keeps that direction for the whole visit. A player left at the counter was framed from
--     behind the tailor; one turned for an instant (WCPreviewEnv.enter clears his tasks after the
--     move turned him) would be framed from his side. So the last check of the stand is here, the
--     stand's heading is what the camera frames from, and he is held on it for a moment
--     (WCCamera.anchor).
local function anchorCamera(flow)
    if not SHOP_CAMERA[flow.kind] or type(WCCamera) ~= 'table' or type(WCCamera.anchor) ~= 'function' then return end
    local ped = PlayerPedId()
    local heading
    local stand = flow.stand
    if stand then
        if not onStand(ped, stand) then
            WCDebug.warn('services', 'the player was off the fitting stand: put back on it')
            placeOnStand(ped, stand)
        end
        heading = stand[4]
        SetEntityHeading(ped, heading)
    else
        heading = GetEntityHeading(ped)
    end
    pcall(WCCamera.anchor, ped, { heading = heading, set = 'shop', hold = F.HEADING_HOLD_MS })
end

--- Undo the preview: the fitting room (coordinates, bucket), then the environment (freeze, HUD,
--  controls: the player stays frozen and WCPreviewEnv.active() stays true until back on the shop
--  floor) and the fade. Each step runs once.
local function leave(flow)
    local returned = flow.moved == true
    if flow.moved and not flow.faded then
        flow.faded = true
        StartFade(F.FADE_MS, F.FADE_KEY)
    end
    if flow.moved then
        flow.moved = false
        local c, ped = flow.saved, PlayerPedId()
        SetEntityCoords(ped, c[1], c[2], c[3], false, false, false, false)
        SetEntityHeading(ped, c[4])
        flow.returnHeading = c[4]
        waitCollision(ped, c[1], c[2], c[3])
        -- the saved point is where his body was (GetEntityCoords), and SetEntityCoords takes a
        -- floor: he came back a metre up and dropped onto the shop floor once unfrozen
        pcall(WCNative.ped.placeOnGround, ped)
    end
    if flow.isolated then
        flow.isolated = false
        local released = call('w_creators:scene:release')
        if not released.ok then WCDebug.warn('services', 'fitting room bucket release: %s', released.code) end
    end
    if flow.env then
        flow.env = false
        WCPreviewEnv.exit()
        -- the environment was entered on the fitting stand and restores that stand's heading:
        -- the player faces the way he stood on the shop floor again
        if flow.returnHeading then SetEntityHeading(PlayerPedId(), flow.returnHeading) end
    end
    flow.returnHeading = nil
    if flow.faded then
        flow.faded = false
        EndFade(F.FADE_MS)
    end
    -- back at the counter: the player closes the catalogue (its own thread: the flow is over)
    if flow.reading then
        flow.reading = false
        local loc = flow.location
        if returned and not isDead() then
            CreateThread(function() pcall(WCCatalogue.exit, loc) end)
        else
            pcall(WCCatalogue.stop)
        end
    end
end

--- A flow that ends without a commit after an uncertain commit answer (a lost reply, a w_lib
--  timeout, BUSY): the server may have committed (charged, saved, broadcast). Its recorded answer
--  (w_creators:session:result, read only) decides: ok → the committed look is taken and rendered;
--  a recorded refusal or no record → nothing was committed; still unknown → the saved look is
--  reloaded. Runs after the session close, so nothing can commit any more.
local function reconcile(flow)
    local pending = flow.pending
    flow.pending = nil
    if type(pending) ~= 'table' or not flow.token then return end
    local answer
    for attempt = 1, F.RECONCILE_TRIES do
        answer = call('w_creators:session:result', flow.token, pending.opId)
        if not UNCERTAIN[answer.code] then break end
        if attempt < F.RECONCILE_TRIES then Wait(F.RECONCILE_WAIT) end
    end
    if answer.ok then
        local data = type(answer.data) == 'table' and answer.data or {}
        local app = type(data.appearance) == 'table' and data.appearance or pending.app
        flow.reconciled = 'committed'
        WCState.set(app)
        restore(app, 'reconcile')
        return
    end
    if not UNCERTAIN[answer.code] then
        flow.reconciled = 'refused'
        return
    end
    flow.reconciled = 'reload'
    local reloaded = call('w_creators:appearance:reload')
    local data = reloaded.ok and type(reloaded.data) == 'table' and reloaded.data or nil
    if data and type(data.appearance) == 'table' then
        WCState.set(data.appearance)
        restore(data.appearance, 'reload')
    else
        WCDebug.warn('services', 'reconciling an uncertain %s commit failed: %s', tostring(flow.kind),
            tostring(reloaded.code))
    end
end

--- The non-persisting clothing states of the local character (e.g. the bandana raised) live only in
--  WCState.appearance and the server's runtime table: the visit's snapshot (the stored look) does
--  not carry them, so a visit that ended by restoring it draws them on the ped again. Returns the
--  count drawn.
local function reapplyRuntimeStates()
    local app = WCState.appearance
    local states = type(app) == 'table' and type(app.clothing) == 'table' and app.clothing.states or nil
    if type(states) ~= 'table' or type(WCClothingStates) ~= 'table' then return 0 end
    local ped, drawn = PlayerPedId(), 0
    for group, value in pairs(states) do
        local def = WCClothingStates.byId[group]
        if def and def.persist ~= true and value ~= def.default and WCClothingStates.applicable(app, group) then
            local ok, done, err = pcall(Appearance.ApplyClothingState, ped, app, group, value)
            if ok and done then
                drawn = drawn + 1
            else
                WCDebug.log('services', 'state %s=%s not drawn again: %s', tostring(group), tostring(value),
                    tostring(ok and err or done))
            end
        end
    end
    if drawn > 0 then pcall(Appearance.Refresh, ped) end
    return drawn
end
F.reapplyRuntimeStates = reapplyRuntimeStates

--- End a flow once (idempotent). reason: 'commit' (the committed appearance is rendered),
--  'cancel' (the editor already restored the snapshot), anything else (the snapshot is restored
--  when the preview could have changed the ped). The server session is closed unless it was
--  committed or closed by the server.
---@return boolean ended (false when it had already ended)
function F.finish(flow, reason)
    if type(flow) ~= 'table' or flow.finished then return false end
    flow.finished = true
    flow.reason = reason
    if editorSession(flow) then pcall(WCEditor.close) end
    if reason == 'commit' then
        restore(flow.result, 'commit')
    elseif reason ~= 'cancel' and flow.editorId then
        restore(flow.snapshot, reason)
    end
    if flow.token and not flow.committed and not flow.serverClosed then
        flow.closeSent = true
        local closed = call('w_creators:session:close', flow.token)
        if not closed.ok then WCDebug.warn('services', 'session close: %s', closed.code) end
    end
    if flow.pending and not flow.committed then
        local okSync, errSync = pcall(reconcile, flow)
        if not okSync then WCDebug.warn('services', 'reconcile failed: %s', tostring(errSync)) end
    end
    -- the snapshot was rendered (cancel, death, forced close): the runtime-only states come back
    -- (a commit replaced the look and the server forgot them; a reload replaced WCState)
    if not flow.committed and flow.editorId and flow.reconciled ~= 'committed' and flow.reconciled ~= 'reload' then
        pcall(reapplyRuntimeStates)
    end
    local ok, err = pcall(leave, flow)
    if not ok then WCDebug.warn('services', 'leaving the %s failed: %s', tostring(flow.kind), tostring(err)) end
    release(flow)
    WCDebug.log('services', '%s flow ended (%s)', tostring(flow.kind), tostring(reason))
    return true
end

--- Stop a flow that has not committed: its editor is cancelled through the editor's own cancel
--  path (the saved look is restored, onCancel ends the flow); a flow still opening stops at its
--  next checkpoint. An editor busy with an operation is retried by the watcher.
---@return boolean ended
function F.abort(flow, reason)
    if type(flow) ~= 'table' or flow.finished or flow.committed then return false end
    flow.abortReason = flow.abortReason or reason
    if not flow.editorId then return false end
    local s = editorSession(flow)
    if s then
        if s.busy then return false end
        local ok, err = pcall(WCEditor.action, { id = s.id, op = 'cancel' })
        if not ok then WCDebug.warn('services', 'editor cancel failed: %s', tostring(err)) end
        if not flow.finished then F.finish(flow, flow.abortReason) end
        return true
    end
    return F.finish(flow, flow.abortReason)
end

--- The watcher of an open editor: death, a pending forced close, an editor closed elsewhere.
local function watch(flow)
    CreateThread(function()
        while current == flow and not flow.finished do
            if not flow.committed then
                if isDead() then
                    F.abort(flow, 'death')
                elseif flow.abortReason then
                    F.abort(flow, flow.abortReason)
                elseif not editorSession(flow) then
                    F.finish(flow, 'closed')
                end
            end
            if flow.finished then break end
            Wait(F.WATCH_MS)
        end
    end)
end

--- The opId of a commit when the editor did not supply one: reused for a retry of the same
--  working appearance after an uncertain answer.
local function fallbackOpId(flow, working)
    local pending = flow.pending
    if pending and WCUtil.deepEqual(pending.app, working) then return pending.opId end
    opSequence = opSequence + 1
    return ('%s-%d-%d-%d'):format(flow.kind, GetGameTimer(), opSequence, math.random(1, 1000000))
end

local function commit(flow, working, extra)
    if flow.finished or flow.committed then return WCResult.fail('SESSION_NOT_FOUND') end
    local opId = type(extra) == 'table' and type(extra.opId) == 'string' and extra.opId or fallbackOpId(flow, working)
    -- what else the commit carries (the store: the payment currency, the outfit to save the look as)
    local more = type(flow.spec.commitExtra) == 'function' and flow.spec.commitExtra(extra) or nil
    local result = more and call(flow.spec.commit, flow.token, opId, working, more)
        or call(flow.spec.commit, flow.token, opId, working)
    flow.lastOpId = opId
    if result.ok then
        local data = type(result.data) == 'table' and result.data or {}
        local app = type(data.appearance) == 'table' and data.appearance or working
        flow.committed = true
        flow.pending = nil
        flow.result = WCUtil.copy(app)
        WCState.set(app)
        -- the editor closes when this returns; the look is rendered and the preview left after it
        CreateThread(function()
            WCUtil.waitUntil(function() return not editorSession(flow) or nil end, F.FINISH_TIMEOUT, 0)
            F.finish(flow, 'commit')
        end)
        return result
    end
    flow.pending = UNCERTAIN[result.code] and { opId = opId, app = WCUtil.copy(working) } or nil
    if SESSION_GONE[result.code] then
        -- nothing can be saved any more: the watcher cancels the editor once this answer is shown
        flow.serverClosed = true
        flow.abortReason = flow.abortReason or 'session'
        notifyResult(result)
    end
    return result
end

-- A checkpoint after a yield of the open sequence: true when the flow was stopped meanwhile.
local function stopped(flow)
    if flow.finished then return true end
    if flow.abortReason or isDead() then
        F.finish(flow, flow.abortReason or 'death')
        return true
    end
    return false
end

local function stopCode(flow)
    return flow.serverClosed and 'SESSION_NOT_FOUND' or 'BUSY'
end

--- An open whose answer is uncertain (a reply lost to the callback timeout, a server error, BUSY
--  because an earlier open of ours left a session behind) may have left a session on the server
--  that this client never got the token of. The client runs one flow at a time, so a session of
--  this player that was never used is abandoned: the server closes it (token-less, unused only).
F.ABANDON = 'w_creators:session:abandon'
local UNCERTAIN_OPEN = { INTERNAL_ERROR = true, BUSY = true }

local function openFlow(flow)
    local spec = flow.spec
    local result = call(spec.open, spec.locationId)
    if flow.finished then
        -- stopped while the open ran (resource stop, forced close): a session opened meanwhile is
        -- closed now rather than left to its TTL
        local late = result.ok and type(result.data) == 'table' and result.data.token or nil
        if type(late) == 'string' then send('w_creators:session:close', late)
        elseif UNCERTAIN_OPEN[result.code] then send(F.ABANDON) end
        return false, stopCode(flow)
    end
    if not result.ok then
        if UNCERTAIN_OPEN[result.code] then send(F.ABANDON) end
        notifyResult(result)
        flow.finished = true
        release(flow)
        return false, result.code
    end
    local data = type(result.data) == 'table' and result.data or {}
    if type(data.token) ~= 'string' or type(data.appearance) ~= 'table' then
        flow.token = type(data.token) == 'string' and data.token or nil
        notify(WCResult.messageKey('INTERNAL_ERROR'))
        F.finish(flow, 'error')
        return false, 'INTERNAL_ERROR'
    end
    flow.token = data.token
    flow.snapshot = WCUtil.copy(data.appearance)
    flow.location = spec.locationId and WCLocations.byId(spec.locationId) or nil
    if stopped(flow) then return false, stopCode(flow) end

    if spec.fittingRoom and data.preview ~= nil and data.preview ~= false then
        local entered, failure = enterFittingRoom(flow, data.preview)
        -- nil: stopped while the player read the catalogue (nothing was prepared or moved), or
        -- while he was let go before the move (not moved; finishing undoes the bucket and fade)
        if entered == nil then
            stopped(flow)
            return false, stopCode(flow)
        end
        if not entered then
            notifyResult(failure)
            F.finish(flow, 'error')
            return false, failure.code
        end
        if stopped(flow) then return false, stopCode(flow) end
    end

    -- the store and the wardrobe light the player (Config.Clothing.fittingLight): the colours on
    -- sale are judged in a dim shop
    local light = (spec.kind == 'store' or spec.kind == 'wardrobe') and Config.Clothing
        and WCPreviewEnv.lightOf(Config.Clothing.fittingLight) or nil
    flow.env = WCPreviewEnv.enter({ ped = PlayerPedId(), freeze = true, hud = true, controls = true,
                                    holster = true, clearTasks = true, light = light }) == true
    if not flow.env then
        F.finish(flow, 'error')
        return false, 'BUSY'
    end
    -- the fitting room's fade stays down until the editor's camera is up (below); a flow stopped
    -- meanwhile fades back in from leave()
    if stopped(flow) then return false, stopCode(flow) end

    local opts = spec.options(flow, data, flow.location)
    opts.onCommit = function(working, extra) return commit(flow, working, extra) end
    opts.onCancel = function() F.finish(flow, 'cancel') end
    -- after the options: a barber / clinic seat is taken inside them, and it is the last move
    anchorCamera(flow)
    local opened, code = WCEditor.open(PlayerPedId(), spec.mode, data.appearance, opts)
    if not opened then
        -- the anchor was made for this editor's camera: never for the next open of the player
        if type(WCCamera) == 'table' and type(WCCamera.clearAnchor) == 'function' then pcall(WCCamera.clearAnchor) end
        notify(WCResult.messageKey(code or 'INTERNAL_ERROR'))
        F.finish(flow, 'error')
        return false, code or 'INTERNAL_ERROR'
    end
    local s = WCEditor.session()
    flow.editorId = s and s.id or nil
    -- ⚠️ The screen comes back only now, on the editor's camera. Faded in before the editor opened,
    --    it showed the game's own third-person camera first, behind the player, until the editor's
    --    camera cut in (the Jump On store shows its camera at once). The panel is already up; the
    --    fade-in is the last step of the open.
    if flow.faded then
        flow.faded = false
        EndFade(F.FADE_MS)
    end
    watch(flow)
    return true
end

--- Run one service-editor flow. Yields (call it from a thread). Returns true once the editor is
--  open, or false, code (every failure shows its message and leaves nothing behind).
--  spec = { kind, mode (WCEditor mode), locationId, open (callback), commit (callback),
--           fittingRoom (use the open data's preview stand + a private bucket),
--           options(flow, data, location) -> WCEditor opts (onCommit / onCancel are set here) }
---@return boolean ok, string|nil code
function F.run(spec)
    if type(spec) ~= 'table' or type(spec.options) ~= 'function' then return false, 'INVALID_PAYLOAD' end
    local why = F.blocked()
    if why then
        WCDebug.log('services', '%s refused: %s', tostring(spec.kind), why)
        return false, 'BUSY'
    end
    if not WCState.busy(F.LOCK, true) then return false, 'BUSY' end
    local flow = { spec = spec, kind = spec.kind, locationId = spec.locationId, ownsLock = true }
    current = flow -- reserved before the first yield: a second open is BUSY
    local ok, done, code = pcall(openFlow, flow)
    if not ok then
        WCDebug.warn('services', '%s open failed: %s', tostring(spec.kind), tostring(done))
        notify(WCResult.messageKey('INTERNAL_ERROR'))
        F.finish(flow, 'error')
        release(flow)
        return false, 'INTERNAL_ERROR'
    end
    return done == true, code
end

-- A close the client did not ask for (expired, stopped, character change): same as a cancel.
RegisterNetEvent('w_creators:client:sessionClosed', function(token, reason)
    local flow = current
    if not flow or type(token) ~= 'string' or flow.token ~= token then return end
    flow.serverClosed = true
    if reason == 'expired' then notify(WCResult.messageKey('SESSION_EXPIRED')) end
    F.abort(flow, 'sessionClosed')
end)

--- Resource stop mid-flow (also while a flow is ending): nothing here yields (a coroutine is never
--  resumed once the runtime is torn down). The editor is closed, the environment left, the player
--  put back where they stood, unfrozen and given the HUD back; the bucket release and the session
--  close are sent without waiting. The ped keeps the preview look: an appearance render yields
--  (and would stop half-way, on the stock metaped preset), and the next start renders the player
--  again (restart adoption, then the selector or applyAppearance). The server drops the
--  uncommitted session, so nothing of the preview is saved.
local function stopFlow()
    local flow = current
    if not flow then return end
    release(flow)
    flow.finished = true
    local ped = PlayerPedId()
    pcall(WCCatalogue.stop)
    if editorSession(flow) then pcall(WCEditor.close) end
    if flow.env then
        flow.env = false
        pcall(WCPreviewEnv.exit)
    end
    if flow.moved and flow.saved then
        flow.moved = false
        pcall(SetEntityCoords, ped, flow.saved[1], flow.saved[2], flow.saved[3], false, false, false, false)
        pcall(SetEntityHeading, ped, flow.saved[4])
    end
    pcall(FreezeEntityPosition, ped, false)
    pcall(SetCustomHudVisible, true)
    pcall(w.setRadarVisible, true)
    if flow.isolated then
        flow.isolated = false
        send('w_creators:scene:release')
    end
    if flow.token and not flow.committed and not flow.serverClosed and not flow.closeSent then
        send('w_creators:session:close', flow.token)
    end
    pcall(WCurtain.restore, flow.faded == true)
    flow.faded = false
end

-- =====================================================================
--  WCServicePoints: prompts, blips and NPCs
-- =====================================================================

WCServicePoints = {}
local P = WCServicePoints

P.TYPES = { 'clothing', 'wardrobe', 'barber', 'surgery' }
P.HOUR_KEY = 'w_creators:hour' -- the GlobalState key holding the server's current hour (0..23)

local OPEN_LABEL = 'فتح'
local CLOSED_TITLE = 'مغلق · يفتح الساعة %s'
local TYPE_LABELS = { clothing = 'متجر الملابس', wardrobe = 'الخزانة', barber = 'الحلاق', surgery = 'عيادة التجميل' }
-- A real sprite of the game: the older 'blip_shop_clothing' does not exist and drew a plain dot
local DEFAULT_SPRITE = 'blip_shop_tailor'

P.ACCESS_REFRESH_MS = 30000 -- how often the answer of w_creators:locations:access is refreshed
local accessCache = {}      -- [locationId] = boolean: the server's last answer (the rule's locations only)
local accessWatch = false

-- The client entry point of each location type (read at call time: they load after this file).
local ENTRY = {
    clothing = function() return WCStore end,
    wardrobe = function() return WCWardrobe end,
    barber = function() return WCBarber end,
    surgery = function() return WCSurgery end,
}

local points = {}   -- { loc, prompt, blip, npc, book, chair }

local function interactKey()
    local key = Config.Keys and Config.Keys.interact
    return (type(key) == 'string' and key ~= '') and key or 'J'
end

local function labelOf(loc)
    return (type(loc.label) == 'string' and loc.label ~= '') and loc.label or TYPE_LABELS[loc.type] or OPEN_LABEL
end

--- The prompt title: "<label> · <town>" (translated).
function P.title(loc)
    local text = locale(labelOf(loc))
    if type(loc.town) == 'string' and loc.town ~= '' then text = text .. ' · ' .. locale(loc.town) end
    return text
end

local function blipName(loc)
    local blip = type(loc.blip) == 'table' and loc.blip or {}
    return locale((type(blip.label) == 'string' and blip.label ~= '') and blip.label or labelOf(loc))
end

--- The server's current hour (the clock WCSessions.open checks with WCLocations.isOpen), as the
--  server publishes it in GlobalState[HOUR_KEY]; nil when it is not published. Never os.date (the
--  client runtime has no os library) and never the game clock (a 48-minute day the server ignores).
---@return integer|nil
local function currentHour()
    local ok, hour = pcall(function() return GlobalState[P.HOUR_KEY] end)
    if not ok then return nil end
    return WCUtil.int(hour, 0, 23, nil)
end

--- Is the location open now? No hours = always; no published server hour = open (the server's
--  <kind>:open refuses a closed location with its own message).
function P.isOpen(loc)
    if type(loc) ~= 'table' or type(loc.hours) ~= 'table' then return true end
    local hour = currentHour()
    if hour == nil then return true end
    return WCLocations.isOpen(loc, hour)
end

--- May this player use the location (its access rule, Config.Locations[].access)? Without a rule
--  always; with one, the server's last answer, and yes until it has answered (the server's open
--  refuses anyway: this only hides a prompt the player would be refused at).
local ruled = setmetatable({}, { __mode = 'k' }) -- [location table] = has an access rule (the prompt asks per frame)

function P.accessible(loc)
    if type(loc) ~= 'table' then return true end
    local rule = ruled[loc]
    if rule == nil then
        rule = WCLocations.access(loc) ~= nil
        ruled[loc] = rule
    end
    if not rule then return true end
    return accessCache[loc.id] ~= false
end

--- Ask the server again which of the rule-bound locations this player may use.
function P.refreshAccess()
    local result = call('w_creators:locations:access')
    if not result.ok or type(result.data) ~= 'table' then return false end
    local fresh = {}
    for id, allowed in pairs(result.data) do
        if type(id) == 'string' then fresh[id] = allowed == true end
    end
    accessCache = fresh
    return true
end

--- Keep the access answers fresh (a job can change at any time) while a rule-bound location exists.
local function watchAccess()
    if accessWatch then return end
    accessWatch = true
    CreateThread(function()
        while accessWatch do
            local ok, err = pcall(P.refreshAccess)
            if not ok then WCDebug.warn('services', 'access refresh failed: %s', tostring(err)) end
            Wait(P.ACCESS_REFRESH_MS)
        end
    end)
end

--- May the prompt of this location be shown / used now?
function P.canInteract(loc)
    return P.isOpen(loc) and P.accessible(loc) and F.blocked() == nil
end

--- The prompt title while the location is closed: "<label> · <town> · Closed · opens at 06:00".
function P.closedTitle(loc)
    local open = type(loc) == 'table' and type(loc.hours) == 'table' and tonumber(loc.hours.open) or 0
    return P.title(loc) .. ' · ' .. locale(CLOSED_TITLE):format(('%02d:00'):format(math.floor(open) % 24))
end

--- Keep a built prompt in step with the opening hours: outside them the prompt stays (the player
--  who followed the blip sees the location is closed and when it opens) with its action disabled.
--  Only a change of state touches the prompt.
local function syncHours(point)
    local rec = point and point.prompt
    if type(rec) ~= 'table' then return end
    local closed = not P.isOpen(point.loc)
    if point.closed == closed then return end
    point.closed = closed
    if type(rec.setEnabled) == 'function' then pcall(rec.setEnabled, interactKey(), not closed) end
    if type(rec.setTitle) == 'function' then
        pcall(rec.setTitle, closed and P.closedTitle(point.loc) or P.title(point.loc))
    end
end

--- The walk-up prompt's canInteract: shown whenever no flow blocks it; its action is disabled
--  (and its title says so) while the location is closed. The action itself re-checks the hours.
function P.promptAllowed(point)
    syncHours(point)
    return F.blocked() == nil and P.accessible(point.loc)
end

--- Open the service of a location (the prompt's action; runs in the prompt's thread).
---@return boolean dispatched
function P.dispatch(loc)
    if type(loc) ~= 'table' or not P.canInteract(loc) then return false end
    local getter = ENTRY[loc.type]
    local mod = getter and getter() or nil
    if type(mod) ~= 'table' or type(mod.open) ~= 'function' then
        WCDebug.warn('services', 'no client entry point for %s locations', tostring(loc.type))
        return false
    end
    local ok, err = pcall(mod.open, loc.id)
    if not ok then WCDebug.warn('services', 'opening %s failed: %s', tostring(loc.id), tostring(err)) end
    return ok
end

-- An enabled location of an enabled service (opening hours are checked when the prompt shows).
local function listed(loc)
    if type(loc) ~= 'table' or loc.enabled == false then return false end
    local service = WCServices.forLocationType(loc.type)
    return service ~= nil and WCServices.enabled(service)
end

local function createPrompt(point, anchor)
    local loc = point.loc
    local ok, rec = pcall(w.prompt.at, {
        coords = anchor,
        distance = loc.interactionRadius,
        title = P.title(loc),
        prompts = { { key = interactKey(), label = locale(OPEN_LABEL), hold = false,
                      onComplete = function() P.dispatch(loc) end } },
        canInteract = function() return P.promptAllowed(point) end,
    })
    if not ok or type(rec) ~= 'table' then
        WCDebug.warn('services', 'prompt of %s failed: %s', loc.id, tostring(rec))
        return nil
    end
    return rec
end

local function createBlip(loc, anchor)
    local ok, blip = pcall(w.blip.create, anchor, blipName(loc), loc.blip.sprite or DEFAULT_SPRITE)
    if not ok or not blip then
        WCDebug.warn('services', 'blip of %s failed: %s', loc.id, tostring(blip))
        return nil
    end
    return blip
end

local function setNpc(ped, name, ...)
    local fn = _ENV[name]
    if type(fn) == 'function' then pcall(fn, ped, ...) end
end

local function createNpc(loc)
    local npc = loc.npc
    local x, y, z, h = CreatorScene.coords(npc.coords)
    if not x or type(npc.model) ~= 'string' or npc.model == '' then
        WCDebug.warn('services', 'npc of %s has no model or coords', loc.id)
        return nil
    end
    local ok, ped = pcall(w.entity.create, npc.model, vector4(x, y, z, h), false)
    if not ok or type(ped) ~= 'number' or ped == 0 or not DoesEntityExist(ped) then
        WCDebug.warn('services', 'npc of %s failed: %s', loc.id, tostring(ped))
        return nil
    end
    pcall(WCNative.ped.updateVariation, ped)
    setNpc(ped, 'SetEntityCanBeDamaged', false)
    setNpc(ped, 'SetEntityInvincible', true)
    setNpc(ped, 'FreezeEntityPosition', true)
    setNpc(ped, 'SetBlockingOfNonTemporaryEvents', true)
    return ped
end

--- A barber's own chair (the board placed a prop; a chair of the map is already there).
local function createChair(loc)
    local chair = loc.chair
    local x, y, z, h = CreatorScene.coords(chair.coords)
    if not x or type(chair.model) ~= 'string' or chair.model == '' then return nil end
    local ok, entity = pcall(w.entity.create, chair.model, vector4(x, y, z, h), false)
    if not ok or type(entity) ~= 'number' or entity == 0 or not DoesEntityExist(entity) then
        WCDebug.warn('services', 'chair of %s failed: %s', loc.id, tostring(entity))
        return nil
    end
    pcall(FreezeEntityPosition, entity, true)
    return entity
end

--- Remove every prompt, blip, NPC, catalogue book and chair.
function P.clear()
    for _, point in ipairs(points) do
        if point.prompt then pcall(point.prompt.remove) end
        if point.blip then pcall(w.blip.remove, point.blip) end
        if point.npc then pcall(w.entity.delete, point.npc) end
        if point.book then pcall(WCCatalogue.remove, point.book) end
        if point.chair then pcall(w.entity.delete, point.chair) end
    end
    points = {}
end

--- (Re)build the prompts, blips, NPCs, books and chairs of every enabled location of every enabled
--  service. A location with prompt = false gets no prompt (another resource owns its interaction).
--  Yields (the models stream in). Returns the number of locations with something built.
---@return integer
function P.build()
    P.clear()
    for _, locationType in ipairs(P.TYPES) do
        for _, loc in ipairs(WCLocations.byType(locationType)) do
            local anchor = listed(loc) and WCLocations.anchor(loc) or nil
            if anchor then
                local point = { loc = loc }
                if loc.prompt ~= false then
                    point.prompt = createPrompt(point, anchor)
                    syncHours(point)
                end
                if type(loc.blip) == 'table' then point.blip = createBlip(loc, anchor) end
                if type(loc.npc) == 'table' then point.npc = createNpc(loc) end
                -- the catalogue book on a clothing store's counter (Config.Clothing.catalogue)
                if loc.book ~= nil then point.book = WCCatalogue.spawn(loc) end
                if type(loc.chair) == 'table' and loc.chair.kind == 'prop' then point.chair = createChair(loc) end
                if WCLocations.access(loc) then watchAccess() end
                if point.prompt or point.blip or point.npc or point.book or point.chair then points[#points + 1] = point end
            end
        end
    end
    WCDebug.log('services', '%d service locations built', #points)
    return #points
end

-- ---------------------------------------------------------------------
--  The places from the server (server/locations/store.lua)
-- ---------------------------------------------------------------------
local building, wanted = false, false

--- A visit is running (its NPC, book or chair must not vanish under the player).
local function visiting()
    if F.busy() then return true end
    return type(WCServiceSeat) == 'table' and WCServiceSeat.active() or false
end

--- Rebuild the points: one build at a time, and only once no visit runs.
function P.rebuild()
    wanted = true
    if building then return end
    building = true
    CreateThread(function()
        while wanted do
            while visiting() do Wait(1000) end
            wanted = false
            local ok, err = pcall(P.build)
            if not ok then WCDebug.warn('services', 'building the service locations failed: %s', tostring(err)) end
        end
        building = false
    end)
end

--- Use the places the server sent (plain form, WCLocations.encode). Returns true when they were taken.
function P.setPlaces(list)
    if type(list) ~= 'table' or list.ok ~= nil then return false end
    local decoded = {}
    for _, data in ipairs(list) do
        local loc = type(data) == 'table' and type(data.id) == 'string' and WCLocations.decode(data) or nil
        if loc then decoded[#decoded + 1] = loc end
    end
    WCLocations.setList(decoded)
    return true
end

RegisterNetEvent('w_creators:client:locations', function(list)
    if P.setPlaces(list) then P.rebuild() end
end)

--- Re-apply the translated labels (language switch).
function P.relabel()
    for _, point in ipairs(points) do
        if point.prompt then
            pcall(point.prompt.setTitle, point.closed and P.closedTitle(point.loc) or P.title(point.loc))
            pcall(point.prompt.setLabel, interactKey(), locale(OPEN_LABEL))
        end
        if point.blip then
            if type(w.blip.setName) == 'function' then
                pcall(w.blip.setName, point.blip, blipName(point.loc))
            else
                pcall(w.blip.remove, point.blip)
                point.blip = createBlip(point.loc, WCLocations.anchor(point.loc))
            end
        end
    end
end

--- The built points (for diagnostics and tests).
function P.points() return points end

CreateThread(function()
    -- the server's places first (nil while it has not loaded them: the broadcast brings them later)
    local ok, list = pcall(w.callback.await, 'w_creators:locations:list', false)
    if ok then P.setPlaces(list) end
    P.rebuild()
end)

OnLanguageChange(function() P.relabel() end)

AddEventHandler('onResourceStop', function(resource)
    if resource ~= GetCurrentResourceName() then return end
    accessWatch = false
    wanted = false
    local cleared, clearErr = pcall(P.clear)
    if not cleared then WCDebug.warn('services', 'removing the service locations failed: %s', tostring(clearErr)) end
    local ok, err = pcall(stopFlow)
    if not ok then WCDebug.warn('services', 'stop cleanup failed: %s', tostring(err)) end
end)
