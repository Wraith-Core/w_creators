-- =====================================================================
--  client/services/locations.lua  —  the service points and the service-editor flow
--  (ARCHITECTURE.md §7.2, §9.3, §17)
--
--  WCServicePoints: one w_lib walk-up prompt (w.prompt.at), one blip (w.blip.create) and one NPC
--  (w.entity.create) per enabled location of an enabled service (clothing, wardrobe, barber,
--  surgery). w_lib owns the distance handling: nothing here scans the locations per frame. A
--  location with prompt = false gets nothing here (another resource provides the interaction, e.g.
--  the surgery clinics of w_ambulancejob through the server export OpenCosmeticSurgery). Opening
--  hours hide the prompt while the location is closed: the rule of WCLocations.isOpen applied to the
--  hour the server publishes (GlobalState[WCServicePoints.HOUR_KEY]); the client has no os library
--  and the game clock is not the server's, so without a published hour the prompt shows and the
--  server's <kind>:open decides. Labels follow a language switch; everything is removed on stop.
--
--  WCServiceFlow: the client half of one WCSessions preview transaction, shared by the store and
--  the wardrobe: <kind>:open -> (store: private fitting room, teleport) -> WCPreviewEnv -> WCEditor
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

--- Private bucket, fade, then the move to the fitting stand. Returns true | false, Result.
local function enterFittingRoom(flow, preview)
    local x, y, z, h = CreatorScene.coords(preview)
    if not x then return false, WCResult.fail('INVALID_PAYLOAD') end
    local prepared = call('w_creators:scene:prepare')
    if not prepared.ok then return false, prepared end
    flow.isolated = true
    local ped = PlayerPedId()
    local at = GetEntityCoords(ped)
    flow.saved = { at.x, at.y, at.z, GetEntityHeading(ped) }
    flow.faded = true
    StartFade(F.FADE_MS, F.FADE_KEY)
    ped = PlayerPedId()
    SetEntityCoords(ped, x, y, z, false, false, false, false)
    SetEntityHeading(ped, h)
    flow.moved = true
    waitCollision(ped, x, y, z)
    return true
end

--- Undo the preview: the fitting room (coordinates, bucket), then the environment (freeze, HUD,
--  controls: the player stays frozen and WCPreviewEnv.active() stays true until back on the shop
--  floor) and the fade. Each step runs once.
local function leave(flow)
    if flow.moved and not flow.faded then
        flow.faded = true
        StartFade(F.FADE_MS, F.FADE_KEY)
    end
    if flow.moved then
        flow.moved = false
        local c, ped = flow.saved, PlayerPedId()
        SetEntityCoords(ped, c[1], c[2], c[3], false, false, false, false)
        SetEntityHeading(ped, c[4])
        waitCollision(ped, c[1], c[2], c[3])
    end
    if flow.isolated then
        flow.isolated = false
        local released = call('w_creators:scene:release')
        if not released.ok then WCDebug.warn('services', 'fitting room bucket release: %s', released.code) end
    end
    if flow.env then
        flow.env = false
        WCPreviewEnv.exit()
    end
    if flow.faded then
        flow.faded = false
        EndFade(F.FADE_MS)
    end
end

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
    local result = call(flow.spec.commit, flow.token, opId, working)
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
        notify(result.message or WCResult.messageKey(result.code))
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

local function openFlow(flow)
    local spec = flow.spec
    local result = call(spec.open, spec.locationId)
    if flow.finished then return false, stopCode(flow) end
    if not result.ok then
        notify(result.message or WCResult.messageKey(result.code))
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
        if not entered then
            notify(failure.message or WCResult.messageKey(failure.code))
            F.finish(flow, 'error')
            return false, failure.code
        end
        if stopped(flow) then return false, stopCode(flow) end
    end

    flow.env = WCPreviewEnv.enter({ ped = PlayerPedId(), freeze = true, hud = true, controls = true,
                                    holster = true, clearTasks = true }) == true
    if not flow.env then
        F.finish(flow, 'error')
        return false, 'BUSY'
    end
    if flow.faded then
        flow.faded = false
        EndFade(F.FADE_MS)
    end
    if stopped(flow) then return false, stopCode(flow) end

    local opts = spec.options(flow, data, flow.location)
    opts.onCommit = function(working, extra) return commit(flow, working, extra) end
    opts.onCancel = function() F.finish(flow, 'cancel') end
    local opened, code = WCEditor.open(PlayerPedId(), spec.mode, data.appearance, opts)
    if not opened then
        notify(WCResult.messageKey(code or 'INTERNAL_ERROR'))
        F.finish(flow, 'error')
        return false, code or 'INTERNAL_ERROR'
    end
    local s = WCEditor.session()
    flow.editorId = s and s.id or nil
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
local TYPE_LABELS = { clothing = 'متجر الملابس', wardrobe = 'الخزانة', barber = 'الحلاق', surgery = 'عيادة التجميل' }
local DEFAULT_SPRITE = 'blip_shop_clothing'

-- The client entry point of each location type (read at call time: they load after this file).
local ENTRY = {
    clothing = function() return WCStore end,
    wardrobe = function() return WCWardrobe end,
    barber = function() return WCBarber end,
    surgery = function() return WCSurgery end,
}

local points = {}   -- { loc, prompt, blip, npc }

local function interactKey()
    local key = Config.Keys and Config.Keys.interact
    return (type(key) == 'string' and key ~= '') and key or 'E'
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

--- May the prompt of this location be shown / used now?
function P.canInteract(loc)
    return P.isOpen(loc) and F.blocked() == nil
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

local function createPrompt(loc, anchor)
    local ok, rec = pcall(w.prompt.at, {
        coords = anchor,
        distance = loc.interactionRadius,
        title = P.title(loc),
        prompts = { { key = interactKey(), label = locale(OPEN_LABEL), hold = false,
                      onComplete = function() P.dispatch(loc) end } },
        canInteract = function() return P.canInteract(loc) end,
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

--- Remove every prompt, blip and NPC.
function P.clear()
    for _, point in ipairs(points) do
        if point.prompt then pcall(point.prompt.remove) end
        if point.blip then pcall(w.blip.remove, point.blip) end
        if point.npc then pcall(w.entity.delete, point.npc) end
    end
    points = {}
end

--- (Re)build the prompts, blips and NPCs of every enabled location of every enabled service,
--  except the locations with prompt = false (another resource owns them: no prompt, blip or NPC).
--  Yields (the NPC models stream in). Returns the number of locations with something built.
---@return integer
function P.build()
    P.clear()
    for _, locationType in ipairs(P.TYPES) do
        for _, loc in ipairs(WCLocations.byType(locationType)) do
            local anchor = loc.prompt ~= false and listed(loc) and WCLocations.anchor(loc) or nil
            if anchor then
                local point = { loc = loc }
                point.prompt = createPrompt(loc, anchor)
                if type(loc.blip) == 'table' then point.blip = createBlip(loc, anchor) end
                if type(loc.npc) == 'table' then point.npc = createNpc(loc) end
                if point.prompt or point.blip or point.npc then points[#points + 1] = point end
            end
        end
    end
    WCDebug.log('services', '%d service locations built', #points)
    return #points
end

--- Re-apply the translated labels (language switch).
function P.relabel()
    for _, point in ipairs(points) do
        if point.prompt then
            pcall(point.prompt.setTitle, P.title(point.loc))
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
    local ok, err = pcall(P.build)
    if not ok then WCDebug.warn('services', 'building the service locations failed: %s', tostring(err)) end
end)

OnLanguageChange(function() P.relabel() end)

AddEventHandler('onResourceStop', function(resource)
    if resource ~= GetCurrentResourceName() then return end
    local cleared, clearErr = pcall(P.clear)
    if not cleared then WCDebug.warn('services', 'removing the service locations failed: %s', tostring(clearErr)) end
    local ok, err = pcall(stopFlow)
    if not ok then WCDebug.warn('services', 'stop cleanup failed: %s', tostring(err)) end
end)
