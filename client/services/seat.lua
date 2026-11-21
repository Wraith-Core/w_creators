-- =====================================================================
--  client/services/seat.lua  —  WCServiceSeat: clinic seat positioning for cosmetic surgery
-- =====================================================================

WCServiceSeat = {}
local Seat = WCServiceSeat

Seat.FADE_MS = 400
Seat.COLLISION_TIMEOUT = 8000
Seat.WATCH_MS = 100

local seated = nil
local standing = nil

local function isDead(ped)
    local ok, dead = pcall(IsEntityDead, ped)
    return ok and (dead == true or dead == 1)
end

local function pedExists(ped)
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

local function stand(record)
    if seated ~= record then return end
    seated, standing = nil, record
    local ped = PlayerPedId()
    if not pedExists(ped) or isDead(ped) then
        if record.faded then EndFade(Seat.FADE_MS) end
        record.faded = false
    else
        if not record.faded then StartFade(Seat.FADE_MS) end
        record.faded = true
        ped = PlayerPedId()
        place(ped, record.saved)
        waitCollision(ped, record.saved[1], record.saved[2], record.saved[3])
        record.faded = false
        EndFade(Seat.FADE_MS)
        WCDebug.log('services', 'left the seat of the %s visit', tostring(record.flow.kind))
    end
    if standing == record then standing = nil end
end

function Seat.take(flow, preview)
    if type(flow) ~= 'table' or flow.finished or seated then return false end
    local x, y, z, h = CreatorScene.coords(preview)
    if not x then return false end
    local ped = PlayerPedId()
    if not pedExists(ped) then return false end
    local at = GetEntityCoords(ped)
    local record = { flow = flow, saved = { at.x, at.y, at.z, GetEntityHeading(ped) }, faded = true, chair = false }
    seated = record
    StartFade(Seat.FADE_MS)
    ped = PlayerPedId()
    place(ped, { x, y, z, h })
    waitCollision(ped, x, y, z)
    record.faded = false
    EndFade(Seat.FADE_MS)
    CreateThread(function()
        while seated == record and not flow.finished do Wait(Seat.WATCH_MS) end
        stand(record)
    end)
    return true
end

function Seat.active() return seated ~= nil or standing ~= nil end
function Seat.onChair() return false end
function Seat.kind()
    local record = seated or standing
    return record and record.flow.kind or nil
end

AddEventHandler('onResourceStop', function(resource)
    if resource ~= GetCurrentResourceName() then return end
    local record = seated or standing
    seated, standing = nil, nil
    if not record then return end
    local ped = PlayerPedId()
    if pedExists(ped) and not isDead(ped) then
        pcall(place, ped, record.saved)
        pcall(FreezeEntityPosition, ped, false)
    end
    pcall(WCurtain.restore, record.faded == true)
end)
