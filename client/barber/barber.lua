-- =====================================================================
--  client/barber/barber.lua  —  WCBarber: the barber chair (ARCHITECTURE.md §9.3, §16.4, §17)
--  w_creators:barber:open(locationId) -> the chair (the location's `preview` seat when it has one:
--  fade, move, fade in; otherwise in place) -> WCPreviewEnv -> WCEditor in 'barber' mode with the
--  open data as context (services, growth, multiplier, visitCap: the price preview matches the
--  server's charge) -> Save: w_creators:barber:commit(token, opId, working) -> the committed
--  appearance in WCState, rendered on the player.
--  Cancel, death, a server-forced close (w_creators:client:sessionClosed), an editor closed elsewhere
--  and resource stop restore the snapshot, close the server session and undo the preview:
--  WCServiceFlow (client/services/locations.lua) runs the flow; WCServiceSeat (below) moves the
--  player to the seat and back.
--
--  WCServiceSeat is shared with the cosmetic surgery client (client/surgery/surgery.lua loads after
--  this file). A barber or clinic never isolates the player: w_creators:scene:prepare is only for a
--  store's fitting room (for anything else it would start a character switch, §16.2).
-- =====================================================================

-- ---------------------------------------------------------------------
--  WCServiceSeat: the chair / clinic seat of a service visit
-- ---------------------------------------------------------------------
WCServiceSeat = {}
local Seat = WCServiceSeat

Seat.FADE_MS = 400
Seat.COLLISION_TIMEOUT = 8000   -- ms for the collision around the player after a move
Seat.WATCH_MS = 100             -- how often the seat checks whether its flow has ended

local seated = nil              -- { flow, saved = {x, y, z, heading}, faded, chair }
local standing = nil            -- the record being put back (the way back yields)
local CHAIR = (Config.Barber or {}).chair or {}

local function isDead(ped)
    local ok, dead = pcall(IsEntityDead, ped)
    return ok and (dead == true or dead == 1)
end

local function pedExists(ped)
    -- BOOL natives answer 1 (not true) on this runtime: never compare them with == true
    return type(ped) == 'number' and ped ~= 0 and not not DoesEntityExist(ped)
end

local function waitCollision(ped, x, y, z)
    RequestCollisionAtCoord(x, y, z)
    WCUtil.waitUntil(function() return HasCollisionLoadedAroundEntity(ped) or nil end, Seat.COLLISION_TIMEOUT, 0)
end

local function place(ped, c)
    SetEntityCoords(ped, c[1], c[2], c[3], false, false, false, false)
    SetEntityHeading(ped, c[4])
end

-- ---------------------------------------------------------------------
--  The barber chair (2026-10-19): a barber place with a chair (the services board placed a chair
--  prop or picked a chair of the map) seats the player in it with the game's own player scenario
--  for a barber chair (PROP_PLAYER_BARBER_SEAT, mech.meta; Config.Barber.chair). The arguments of
--  TaskStartScenarioAtPosition are w_baloot's proven order: (ped, hash, x, y, z, heading, -1, false,
--  true). No scenario that takes = he is held on the seat spot, frozen.
-- ---------------------------------------------------------------------

--- Where the seated player goes for a chair ({ coords = vector4 } or { x, y, z, h }): x, y, z,
--  heading. The chair's front is its -Y side: the sitter faces chair heading + 180.
function Seat.chairSpot(chair)
    local cx, cy, cz, ch = CreatorScene.coords(type(chair) == 'table' and (chair.coords or chair) or nil)
    if not cx then return nil end
    ch = tonumber(ch) or 0.0
    local o = type(CHAIR.offset) == 'table' and CHAIR.offset or {}
    local ox, oy, oz = tonumber(o.x) or 0.0, tonumber(o.y) or 0.0, tonumber(o.z) or 0.0
    local r = math.rad(ch)
    local x = cx + ox * math.cos(r) - oy * math.sin(r)
    local y = cy + ox * math.sin(r) + oy * math.cos(r)
    return x, y, cz + oz, (ch + 180.0) % 360.0
end

--- Sit the player down on the chair spot. Returns true when a scenario took him.
local function sitDown(ped, x, y, z, h)
    local scenarios = type(CHAIR.scenarios) == 'table' and CHAIR.scenarios or {}
    -- the visit froze him (WCPreviewEnv); the scenario holds him in the chair instead
    FreezeEntityPosition(ped, false)
    for _, name in ipairs(scenarios) do
        TaskStartScenarioAtPosition(ped, joaat(name), x, y, z, h, -1, false, true)
        local deadline = GetGameTimer() + (tonumber(CHAIR.verifyMs) or 600)
        while GetGameTimer() < deadline do
            if IsPedUsingAnyScenario(ped) then return true end
            Wait(0)
        end
        ClearPedTasksImmediately(ped)
    end
    WCDebug.warn('services', 'no barber chair scenario took the player: held on the seat instead')
    SetEntityCoordsNoOffset(ped, x, y, z, false, false, false)
    SetEntityHeading(ped, h)
    FreezeEntityPosition(ped, true)
    return false
end

--- Get the player off the chair (no yield).
local function getUp(ped)
    pcall(ClearPedTasksImmediately, ped)
    pcall(FreezeEntityPosition, ped, false)
end

--- Put the player back where the visit started (fade, move, collision, fade in). Yields.
local function stand(record)
    if seated ~= record then return end
    seated, standing = nil, record
    local ped = PlayerPedId()
    if not pedExists(ped) or isDead(ped) then
        -- a corpse stays where it fell (the respawn service owns it); lift a fade still held
        if record.faded then EndFade(Seat.FADE_MS) end
        record.faded = false
    else
        if not record.faded then StartFade(Seat.FADE_MS) end
        record.faded = true
        ped = PlayerPedId()
        if record.chair then getUp(ped) end
        place(ped, record.saved)
        waitCollision(ped, record.saved[1], record.saved[2], record.saved[3])
        record.faded = false
        EndFade(Seat.FADE_MS)
        WCDebug.log('services', 'left the seat of the %s visit', tostring(record.flow.kind))
    end
    if standing == record then standing = nil end
end

--- Take the seat of a service visit: fade out, move the player to `preview` ({x, y, z, heading}
--  or a vector4) - or, given a barber `chair`, sit him in it - wait for the collision, fade in. The
--  player is put back automatically once the flow ends (commit, cancel, death, forced close,
--  error). Yields (call it from the flow's thread). Returns true when the player was moved.
---@param flow table the WCServiceFlow flow of the visit
---@param preview table|vector4|nil
---@param chair table|nil the location's chair ({ kind, model, coords = vector4 })
---@return boolean moved
function Seat.take(flow, preview, chair)
    if type(flow) ~= 'table' or flow.finished or seated then return false end
    local x, y, z, h, onChair
    if chair ~= nil and chair ~= false then
        x, y, z, h = Seat.chairSpot(chair)
        onChair = x ~= nil
    end
    if not x then x, y, z, h = CreatorScene.coords(preview) end
    if not x then return false end
    local ped = PlayerPedId()
    if not pedExists(ped) then return false end
    local at = GetEntityCoords(ped)
    local record = { flow = flow, saved = { at.x, at.y, at.z, GetEntityHeading(ped) }, faded = true,
                     chair = onChair == true }
    seated = record
    StartFade(Seat.FADE_MS)
    ped = PlayerPedId()
    place(ped, { x, y, z, h })
    waitCollision(ped, x, y, z)
    if record.chair and seated == record and not flow.finished then sitDown(ped, x, y, z, h) end
    record.faded = false
    EndFade(Seat.FADE_MS)
    CreateThread(function()
        while seated == record and not flow.finished do Wait(Seat.WATCH_MS) end
        stand(record)
    end)
    return true
end

--- Is the player on a service seat, or being put back from one? The barber and clinic report
--  themselves busy meanwhile, so no other service opens before the player is back.
function Seat.active() return seated ~= nil or standing ~= nil end

--- Is the player sitting in a barber chair (the editor must not turn him)?
function Seat.onChair() return seated ~= nil and seated.chair == true end

--- The kind of the visit whose seat is taken or being left ('barber' | 'surgery'), or nil.
function Seat.kind()
    local record = seated or standing
    return record and record.flow.kind or nil
end

-- Resource stop mid-visit: nothing may yield; the player is put back where he stood (the flow's
-- own stop handler has already exited the environment and closed the session).
AddEventHandler('onResourceStop', function(resource)
    if resource ~= GetCurrentResourceName() then return end
    local record = seated or standing
    seated, standing = nil, nil
    if not record then return end
    local ped = PlayerPedId()
    if pedExists(ped) and not isDead(ped) then
        if record.chair then getUp(ped) end
        pcall(place, ped, record.saved)
        pcall(FreezeEntityPosition, ped, false)
    end
    pcall(WCurtain.restore, record.faded == true)
end)

-- ---------------------------------------------------------------------
--  WCBarber
-- ---------------------------------------------------------------------
WCBarber = {}
local B = WCBarber

local DEFAULT_TITLE = 'الحلاق'
local MAX_ID = 64

local function validId(id)
    return type(id) == 'string' and id ~= '' and #id <= MAX_ID
end

--- The editor context of a barber visit: the open data as the server sent it (services with their
--  multiplied prices, growth, multiplier, visitCap, sections), the location record instead of its id.
local function contextOf(data, loc)
    return {
        services = data.services,
        growth = data.growth,
        multiplier = data.multiplier,
        visitCap = data.visitCap,
        sections = data.sections,
        expiresIn = data.expiresIn,
        locationId = data.location,
        location = loc,
    }
end

--- The editor options of a barber visit (runs in the flow's thread after the preview environment
--  is entered and before the editor opens): the seat first, when the location has one - its chair
--  (the services board) before its preview spot.
local function options(flow, data, loc)
    local chair = loc and type(loc.chair) == 'table' and loc.chair or nil
    if chair or (loc and loc.preview ~= nil and loc.preview ~= false) then Seat.take(flow, loc.preview, chair) end
    return {
        title = loc and loc.label or DEFAULT_TITLE,
        subtitle = loc and loc.town or nil,
        -- the server's set of allowed sections, unchanged (hair, facialHair, eyebrows/makeup)
        sections = data.sections,
        context = contextOf(data, loc),
        camera = loc and loc.camera or 'hair',
    }
end

--- Open the barber of a location. Yields (call it from a thread); returns true once the editor is
--  open, or false, code (the failure's message has been shown, except to a dead player).
--  A refusal because another flow holds the player is shown here: WCServiceFlow.run only logs it,
--  and on the server-opened paths (events, the OpenCosmeticSurgery export) nothing else would.
---@param locationId string
---@return boolean ok, string|nil code
function B.open(locationId)
    if not validId(locationId) then
        WCServiceFlow.notify(WCResult.messageKey('INVALID_PAYLOAD'))
        return false, 'INVALID_PAYLOAD'
    end
    local why = WCServiceFlow.blocked()
    if why then
        if why ~= 'dead' then WCServiceFlow.notify(WCResult.messageKey('BUSY')) end
        return false, 'BUSY'
    end
    return WCServiceFlow.run({
        kind = 'barber', mode = 'barber', locationId = locationId,
        open = 'w_creators:barber:open', commit = 'w_creators:barber:commit',
        fittingRoom = false, options = options,
    })
end

--- Is a barber visit running?
function B.busy()
    local flow = WCServiceFlow.current()
    if flow ~= nil and flow.kind == 'barber' then return true end
    return Seat.kind() == 'barber'
end
