-- =====================================================================
--  server/appearance/sync.lua  —  WCSync (ARCHITECTURE.md §9.4, §16.5)
--  RedM does not replicate MetaPed components: every client renders the other players' peds itself.
--  The server keeps the last broadcast appearance of every player so a player who joins later (or a
--  client whose scope watcher lost a ped) receives it, and pushes clothing state changes as small
--  deltas.
--
--    WCSync.broadcast(src, app)               cache + w_creators:client:applyRemoteAppearance to all
--    WCSync.broadcastState(src, group, value) cache + w_creators:client:remoteClothingState to all
--    WCSync.forget(src)                       drop the cache + w_creators:client:forgetRemote to all
--    WCSync.get(src)                          a copy of the cached appearance, or nil
--
--  Net events / callbacks:
--    w_creators:server:requestAppearances          (legacy, rate limited) the cached appearances of
--                                                  the other players, sent to the requester only
--    w_creators:appearance:reload                  callback -> Result { appearance } + re-broadcast
--    PersonaCreatorHandler.reloadCharacterAppearance legacy net event: same, answered with
--                                                  w_creators:client:applyAppearance
--  Both reload paths share one rate limit (1 per 10 s).
-- =====================================================================

WCSync = {}
local Sync = WCSync

local cache = {} -- [src] = v3 appearance (the last broadcast)

local RELOAD_KEY, RELOAD_MAX, RELOAD_WINDOW = 'appearance:reload', 1, 10000
local REQUEST_KEY, REQUEST_MAX, REQUEST_WINDOW = 'appearance:request', 2, 10000

local function playerId(src)
    src = tonumber(src)
    if not src or src <= 0 or src % 1 ~= 0 then return nil end
    return math.tointeger(src)
end

--- Cache a player's appearance and send it to every client (each client skips its own id).
---@return boolean sent
function Sync.broadcast(src, app)
    src = playerId(src)
    if not src or type(app) ~= 'table' then return false end
    cache[src] = WCUtil.copy(app)
    TriggerClientEvent('w_creators:client:applyRemoteAppearance', -1, src, app)
    return true
end

--- Update one clothing state of a player's cached appearance and send the delta to every client.
---@return boolean sent
function Sync.broadcastState(src, group, value)
    src = playerId(src)
    if not src or type(group) ~= 'string' then return false end
    local app = cache[src]
    if app then
        app.clothing = type(app.clothing) == 'table' and app.clothing or {}
        app.clothing.states = type(app.clothing.states) == 'table' and app.clothing.states or {}
        app.clothing.states[group] = value
    end
    TriggerClientEvent('w_creators:client:remoteClothingState', -1, src, group, value)
    return true
end

--- Forget a player's appearance (disconnect, character switch) on the server and every client.
function Sync.forget(src)
    src = playerId(src)
    if not src then return false end
    cache[src] = nil
    TriggerClientEvent('w_creators:client:forgetRemote', -1, src)
    return true
end

--- A copy of the cached appearance of a player, or nil.
function Sync.get(src)
    src = playerId(src)
    local app = src and cache[src]
    return app and WCUtil.copy(app) or nil
end

-- ---------------------------------------------------------------------
--  Late joiners
-- ---------------------------------------------------------------------
RegisterNetEvent('w_creators:server:requestAppearances', function()
    local src = playerId(source)
    if not src or not WCSecurity.rate(src, REQUEST_KEY, REQUEST_MAX, REQUEST_WINDOW) then return end
    for other, app in pairs(cache) do
        if other ~= src then
            TriggerClientEvent('w_creators:client:applyRemoteAppearance', src, other, app)
        end
    end
end)

-- ---------------------------------------------------------------------
--  Reload (the player's ped lost its look: re-read the saved appearance and re-apply it)
-- ---------------------------------------------------------------------

--- Load the active character's appearance and re-broadcast it. Result { appearance }.
function Sync.reload(src)
    src = playerId(src)
    if not src then return WCResult.fail('INVALID_PAYLOAD') end
    if not WCSecurity.rate(src, RELOAD_KEY, RELOAD_MAX, RELOAD_WINDOW) then return WCResult.fail('RATE_LIMITED') end
    local active = WCSessions.activeCharacter(src)
    if not active then return WCResult.fail('NO_CHARACTER') end
    -- An open preview session renders its own working copy; a commit in flight owns the appearance.
    if WCSessions.current(src) or CreatorAppearanceLocks[active.charid] then return WCResult.fail('BUSY') end

    local ok, app, meta = pcall(WCAppearanceRepo.load, active.charid)
    if not ok then
        WCDebug.warn('sync', 'reloading %s failed: %s', active.charid, tostring(app))
        app, meta = nil, { error = 'DATABASE_ERROR' }
    end
    CreatorLogs.Emit('appearance_loaded', { playerSource = src, charid = active.charid, found = app ~= nil })
    if not app then
        return WCResult.fail(type(meta) == 'table' and meta.error or 'CHARACTER_NOT_FOUND')
    end
    Sync.broadcast(src, app)
    return WCResult.ok({ appearance = app })
end

w.callback.register('w_creators:appearance:reload', function(src)
    return Sync.reload(src)
end)

RegisterNetEvent('PersonaCreatorHandler.reloadCharacterAppearance', function()
    local src = source
    local result = Sync.reload(src)
    if result.ok then
        TriggerClientEvent('w_creators:client:applyAppearance', src, result.data.appearance)
    end
end)

AddEventHandler('playerDropped', function()
    local src = playerId(source)
    if src and cache[src] then Sync.forget(src) end
end)
