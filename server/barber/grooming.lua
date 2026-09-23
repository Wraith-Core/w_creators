-- =====================================================================
--  server/barber/grooming.lua  —  WCGroomingServer: hair and beard growth (ARCHITECTURE.md §1 A14)
--  Same behaviour as the pre-v3 grooming thread: only time observed online in the main world
--  (routing bucket 0) with an active character counts; growth is paused while the player has an
--  open service session, a pending spawn, or no active character. Offline time never counts.
--
--  No per-tick database access: the online seconds accumulate in memory per active character; the
--  appearance is read from the WCAppearanceRepo cache and written only
--    * when the accumulated growth changes a stage (the style changes: broadcast +
--      w_creators:client:grooming(app) to the owner),
--    * every Config.Grooming.saveIntervalSeconds,
--    * when the player drops or leaves the character (switch).
--  A character whose stored appearance needed defaults (WCAppearanceRepo degraded) never grows.
--
--    WCGroomingServer.tick(nowMs?)     one pass over the online players (the thread calls it)
--    WCGroomingServer.pending(src)     { charid, seconds, savedAt } of a tracked player (copy) or nil
--    WCGroomingServer.flush(src, sync) write a player's pending growth now (sync = in this thread)
--    WCGroomingServer.fold(charid, app, previous, meta) -> seconds
--        another writer (barber, surgery, SetSkin) folds the pending growth into the appearance it is
--        about to save: a kind whose style it changed (a cut) gets none of it, the other kind grows
--    WCGroomingServer.consumed(charid, seconds)  that writer's save succeeded: the folded seconds
--        leave the in-memory counter (anything accumulated since stays)
-- =====================================================================

WCGroomingServer = {}
local GS = WCGroomingServer

GS.TICK_MS = 30000
local MAX_ELAPSED = 60       -- seconds counted per tick at most (a stalled server never jumps stages)
local FLUSH_WAIT_MS = 10000  -- how long a drop/switch flush waits for another writer's lock

local tracked = {} -- [src] = { charid, seconds, last = ms, savedAt = ms, paused = bool }

local function enabled()
    return type(Config.Grooming) == 'table' and Config.Grooming.enabled == true
end

local function saveIntervalMs()
    local seconds = WCUtil.number(Config.Grooming and Config.Grooming.saveIntervalSeconds, 30, 86400, 300)
    return seconds * 1000
end

local function stagesOf(app)
    local out = {}
    for kind, data in pairs(WCGrooming.state(app)) do out[kind] = data.stage end
    return out
end

-- Advance `app` by `seconds`. Returns visibleChange, stageChange.
local function grow(app, seconds)
    local before = stagesOf(app)
    local visible = WCGrooming.advance(app, seconds)
    local stageChanged = false
    for kind, data in pairs(app.grooming or {}) do
        if before[kind] ~= nil and data.stage ~= before[kind] then stageChanged = true end
    end
    return visible, stageChanged
end

--- Write the pending growth of a tracked entry. opts.notify = true informs the owner's client and
--  the other players when a stage changed. Returns true when written (or nothing to write).
local function persist(src, t, opts)
    opts = opts or {}
    local amount = t.seconds
    if amount <= 0 then return true end
    local owner = ('grooming:%s:%s'):format(t.charid, tostring(src))
    if not WCSessions.lockCharacter(t.charid, owner) then return false end
    local ok, written = pcall(function()
        local app, meta = WCAppearanceRepo.load(t.charid)
        if not app then return false end
        if type(meta) == 'table' and meta.degraded then
            t.seconds = 0
            return false
        end
        local visible, stageChanged = grow(app, amount)
        local saved, result = WCAppearanceRepo.save(t.charid, app)
        if not saved then
            WCDebug.warn('grooming', 'saving the growth of %s failed: %s', t.charid, tostring(result))
            return false
        end
        t.seconds = math.max(0, t.seconds - amount)
        if opts.notify and (visible or stageChanged) then
            WCSync.broadcast(src, result)
            TriggerClientEvent('w_creators:client:grooming', src, result)
            WCDebug.log('grooming', 'character %s grew a stage', t.charid)
        end
        return true
    end)
    WCSessions.unlockCharacter(t.charid, owner)
    t.savedAt = GetGameTimer()
    if not ok then
        WCDebug.warn('grooming', 'growth of %s failed: %s', t.charid, tostring(written))
        return false
    end
    return written == true
end

-- Is a write due (a stage would change, or the save interval elapsed)?
local function due(t, now)
    if t.seconds <= 0 then return false end
    if now - t.savedAt >= saveIntervalMs() then return true end
    local app, meta = WCAppearanceRepo.load(t.charid)
    if not app then return false end
    if type(meta) == 'table' and meta.degraded then
        t.seconds = 0
        return false
    end
    local visible, stageChanged = grow(app, t.seconds)
    return visible or stageChanged
end

-- Can the player's character grow right now?
local function eligible(src, active)
    if not active or not enabled() then return false end
    if GetPlayerRoutingBucket(src) ~= 0 then return false end
    if WCSessions.current(src) then return false end
    if SpawnPending and SpawnPending[src] then return false end
    if WCCharacters and WCCharacters.isSwitching and WCCharacters.isSwitching(src) then return false end
    return true
end

--- Write a player's pending growth and stop tracking him. sync = true writes in the calling thread
--  (it may yield); otherwise a thread waits for any other writer's lock first.
function GS.flush(src, sync)
    local t = tracked[src]
    if not t then return false end
    tracked[src] = nil
    if not t.paused then
        -- The online time since the last tick counts too.
        t.seconds = t.seconds + WCUtil.number((GetGameTimer() - t.last) / 1000, 0, MAX_ELAPSED, 0)
    end
    if t.seconds <= 0 then return true end
    -- The character is no longer active on this player: its cached appearance is dropped after
    -- the write (the repository cache holds active characters only).
    local function write()
        local written = persist(src, t, {})
        WCAppearanceRepo.invalidate(t.charid)
        return written
    end
    if sync then return write() end
    CreateThread(function()
        WCUtil.waitUntil(function() return not CreatorAppearanceLocks[t.charid] end, FLUSH_WAIT_MS, 250)
        write()
    end)
    return true
end

local function entryOf(charid)
    if charid == nil then return nil end
    charid = tostring(charid)
    for _, t in pairs(tracked) do
        if t.charid == charid then return t end
    end
    return nil
end

local function slotOf(kind) return kind == 'beard' and 'facial' or 'style' end

--- Fold the pending growth of a character into `app`, the appearance another writer is about to
--  save, planned against `previous` (the saved appearance). A kind whose style differs from
--  `previous` was cut: it keeps its restarted state and gets none of the pre-cut growth; every other
--  kind grows by the pending seconds (a stage may advance). A degraded appearance (meta.degraded)
--  never grows. Mutates app; returns the seconds folded (0 = nothing), to pass to consumed() once
--  the save succeeded.
function GS.fold(charid, app, previous, meta)
    local t = entryOf(charid)
    if not t or t.seconds <= 0 or not enabled() then return 0 end
    if type(meta) == 'table' and meta.degraded then return 0 end
    if type(app) ~= 'table' or type(previous) ~= 'table' or type(app.hair) ~= 'table'
        or type(previous.hair) ~= 'table' then
        return 0
    end
    local seconds = t.seconds
    local grown = WCUtil.copy(app)
    WCGrooming.advance(grown, seconds)
    local state = WCGrooming.state(app)
    for kind, data in pairs(WCGrooming.state(grown)) do
        local slot = slotOf(kind)
        if app.hair[slot] == previous.hair[slot] then
            app.hair[slot] = grown.hair[slot]
            state[kind] = data
        end
    end
    app.grooming = state
    return seconds
end

--- The save of a folded appearance succeeded: its seconds leave the counter.
function GS.consumed(charid, seconds)
    local t = entryOf(charid)
    seconds = tonumber(seconds) or 0
    if not t or seconds <= 0 then return end
    t.seconds = math.max(0, t.seconds - seconds)
    t.savedAt = GetGameTimer()
end

--- The tracked growth of a player (a copy) or nil.
function GS.pending(src)
    local t = tracked[tonumber(src) or src]
    return t and { charid = t.charid, seconds = t.seconds, savedAt = t.savedAt, paused = t.paused } or nil
end

--- One pass over the online players.
function GS.tick(now)
    now = now or GetGameTimer()
    local online = {}
    for _, id in ipairs(GetPlayers()) do
        local src = tonumber(id)
        if src then
            online[src] = true
            local active = WCSessions.activeCharacter(src)
            local t = tracked[src]
            if t and (not active or active.charid ~= t.charid or not enabled()) then
                GS.flush(src, false)
                t = nil
            end
            if eligible(src, active) then
                if not t then
                    tracked[src] = { charid = active.charid, seconds = 0, last = now, savedAt = now, paused = false }
                else
                    if not t.paused then
                        t.seconds = t.seconds + WCUtil.number((now - t.last) / 1000, 0, MAX_ELAPSED, 0)
                    end
                    t.paused, t.last = false, now
                    if not CreatorAppearanceLocks[t.charid] then
                        local okDue, isDue = pcall(due, t, now)
                        if okDue and isDue then persist(src, t, { notify = true }) end
                    end
                end
            elseif t then
                t.paused, t.last = true, now
            end
        end
    end
    for src in pairs(tracked) do
        if not online[src] then GS.flush(src, false) end
    end
end

CreateThread(function()
    while true do
        Wait(GS.TICK_MS)
        local ok, err = pcall(GS.tick)
        if not ok then WCDebug.warn('grooming', 'tick failed: %s', tostring(err)) end
    end
end)

AddEventHandler('playerDropped', function()
    GS.flush(tonumber(source) or source, false)
end)

-- A character switch (or any other clear) writes the leaving character's growth.
AddEventHandler('w_creators:server:characterCleared', function(src, charid)
    local t = tracked[tonumber(src) or src]
    if t and (charid == nil or tostring(charid) == t.charid) then GS.flush(tonumber(src) or src, false) end
end)

-- A character became active: a leftover entry of another character is written first, and the new
-- one is tracked (paused until the next tick finds it eligible: the spawn grant is usually still
-- pending here) so it never waits for the polling pass to be noticed.
AddEventHandler('w_creators:server:characterActivated', function(src, charid)
    src = tonumber(src)
    if not src or charid == nil or not enabled() then return end
    charid = tostring(charid)
    local t = tracked[src]
    if t and t.charid == charid then return end
    if t then GS.flush(src, false) end
    local now = GetGameTimer()
    tracked[src] = { charid = charid, seconds = 0, last = now, savedAt = now, paused = true }
end)
