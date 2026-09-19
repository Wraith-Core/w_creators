-- Shared actor-relative camera for selection, creation and clothing shops.
CamZoom, CamHeight = 0.0, 0.0
CamFollowSuspended = false
local camA, camB, activeCam
local currentDestination, currentPed, sceneHeading
local Destinations = {
    default   = {distance=3.15, side=.45, height=-.05, fov=42.0},
    selection = {distance=3.65, side=.20, height=-.05, fov=40.0},
    body      = {distance=2.1, side=.30, height=.08, fov=38.0},
    head      = {distance=1.2,  side=.18, bone=true, offset=.10, fov=34.0},
    eyes      = {distance=.65, side=.07, bone=true, offset=.13, fov=28.0},
    pant      = {distance=2.0, side=.25, height=-.45, fov=40.0},
    boot      = {distance=.95, side=.12, height=-.75, fov=34.0},
}
local function exists(cam) return cam and cam ~= 0 and DoesCamExist(cam) end
local function ensureCams()
    if not exists(activeCam) then activeCam = exists(gCamera) and gCamera or nil end
    if not exists(camA) then camA = CreateCam('DEFAULT_SCRIPTED_CAMERA', false) end
    if not exists(camB) then camB = CreateCam('DEFAULT_SCRIPTED_CAMERA', false) end
end

function MoveCreatorCam(destination, ped, force)
    if CamFollowSuspended then return false end
    destination = destination or 'default'
    ped = ped or GetCreatorPed()
    if not ped or ped == 0 or not DoesEntityExist(ped) then return false end
    if destination == currentDestination and ped == currentPed and not force and exists(activeCam) then return true end
    -- Keep the viewing direction when the player rotates the actor, changes a
    -- category or zooms. Reading its new heading would turn the camera with it.
    if ped ~= currentPed or not sceneHeading then sceneHeading = GetEntityHeading(ped) end
    local d = Destinations[destination] or Destinations.default
    local at = GetEntityCoords(ped)
    local height = d.height
    if d.bone then
        local head = GetPedBoneCoords(ped, 21030, 0.0, 0.0, 0.0)
        height = math.max(.25, math.min(1.2, head.z-at.z))+(d.offset or 0.0)
    end
    local side = d.side * (UiDir() == 'rtl' and -1 or 1)
    local angle = math.rad(sceneHeading)
    local rightX, rightY, frontX, frontY = math.cos(angle), math.sin(angle), -math.sin(angle), math.cos(angle)
    local tx, ty, tz = at.x+rightX*side, at.y+rightY*side, at.z+height+(CamHeight or 0.0)
    local cx, cy, cz = tx+frontX*d.distance, ty+frontY*d.distance, tz+.08
    ensureCams()
    local nextCam = activeCam == camA and camB or camA
    -- RedM/OAL native arguments are scalar; never rely on vector unpacking.
    SetCamCoord(nextCam, cx, cy, cz)
    PointCamAtCoord(nextCam, tx, ty, tz)
    SetCamFov(nextCam, math.max(22.0, math.min(60.0, d.fov-(CamZoom or 0.0))))
    if exists(activeCam) and activeCam ~= nextCam then
        SetCamActiveWithInterp(nextCam, activeCam, 450, true, true)
    else
        SetCamActive(nextCam, true)
    end
    RenderScriptCams(true, false, 0, true, true, 0)
    SetFocusPosAndVel(at.x, at.y, at.z, 0.0, 0.0, 0.0)
    activeCam, gCamera, currentPed, currentDestination = nextCam, nextCam, ped, destination
    return true
end

function ResetCreatorCamState()
    currentDestination, currentPed, sceneHeading = nil, nil, nil
    CamZoom, CamHeight, CamFollowSuspended = 0.0, 0.0, false
end

function DestroyCreatorCams()
    RenderScriptCams(false, false, 0, true, true, 0)
    local seen = {}
    for _,cam in pairs({camA, camB, activeCam, gCamera}) do
        if exists(cam) and not seen[cam] then DestroyCam(cam, false); seen[cam]=true end
    end
    camA, camB, activeCam, gCamera = nil, nil, nil, nil
    ResetCreatorCamState()
end

function CurrentCamDestination() return currentDestination or 'default' end

--- The destination belonging to a particular edit category.
-- The category -> the camera's destination (the Destinations keys above)
local DestByCategory = {
    -- the whole body
    pedSize = 'default', ['char-weight'] = 'default', skin_tone = 'body',
    BODIES_UPPER = 'body',
    -- the head
    heads = 'head', hair = 'head', ['hair-color'] = 'head', hairov = 'head',
    ['hairov_color'] = 'head', teeth = 'head', mustache = 'head',
    ['mustache-color'] = 'head', beardstabble = 'head', beardstabble_color = 'head',
    hats = 'head', masks = 'head',
    -- the eyes (a closer shot)
    eyes = 'eyes', eyebrows = 'eyes', eyewear = 'eyes',
    -- the torso
    shirts_full = 'body', vests = 'body', coats = 'body', coats_closed = 'body',
    ponchos = 'body', cloaks = 'body', armor = 'body', suspenders = 'body',
    neckwear = 'body', neckties = 'body', badges = 'body', satchels = 'body',
    loadouts = 'body', accessories = 'body', gloves = 'body', gauntlets = 'body',
    jewelry_bracelets = 'body', jewelry_rings_left = 'body', jewelry_rings_right = 'body',
    -- the legs
    pants = 'pant', skirts = 'pant', chaps = 'pant', spats = 'pant',
    belts = 'pant', belt_buckles = 'pant', gunbelts = 'pant', holsters_left = 'pant',
    -- the feet
    boots = 'boot', boot_accessories = 'boot', legs_acessories = 'boot',
}

-- The face feature prefixes: dozens of ids (nose_width, jaw_depth...) all of them the head.
local FacePrefixes = {
    'nose', 'mouth', 'lip', 'upper_lip', 'lower_lip', 'chin', 'jaw', 'cheek',
    'ear', 'face', 'nostrils', 'blush', 'lipstick', 'foundation', 'freckle',
    'acne', 'mole', 'spot', 'grime', 'ageing', 'complex', 'scar', 'paintedmask',
    'disc', 'porte',
}
-- The prefixes that belong to the eyes specifically (a closer shot than the head)
local EyePrefixes = { 'eye', 'eyelid', 'eyebrow', 'eyeliner', 'shadow' }

--- The camera destination belonging to an edit category.
---@param id string
---@return string
function CategoryBodyPart(id)
    if type(id) ~= 'string' then return 'default' end
    local explicit = DestByCategory[id]
    if explicit then return explicit end
    for i = 1, #EyePrefixes do
        if id:sub(1, #EyePrefixes[i]) == EyePrefixes[i] then return 'eyes' end
    end
    for i = 1, #FacePrefixes do
        if id:sub(1, #FacePrefixes[i]) == FacePrefixes[i] then return 'head' end
    end
    return 'default'
end

--- Moving the camera to a destination - the public interface the editor calls.
---@param part string
---@param force? boolean
function FocusBodyPart(part, force)
    MoveCreatorCam(part, nil, force)
end

--- Zooming in/out. A positive delta = coming closer.
function NudgeCamZoom(delta)
    CamZoom = CamZoom + (delta or 0.0)
    if CamZoom < -10.0 then CamZoom = -10.0 elseif CamZoom > 30.0 then CamZoom = 30.0 end
    MoveCreatorCam(CurrentCamDestination(), nil, true)
end

--- Raising/lowering the camera (it offsets the camera and the look-at point together).
function NudgeCamHeight(delta)
    CamHeight = CamHeight + (delta or 0.0)
    if CamHeight < -0.9 then CamHeight = -0.9 elseif CamHeight > 0.9 then CamHeight = 0.9 end
    MoveCreatorCam(CurrentCamDestination(), nil, true)
end

--- Returning the camera to its default framing.
function ResetCamOffsets()
    CamZoom, CamHeight = 0.0, 0.0
    MoveCreatorCam('default', nil, true)
end

function ResetBodyView()
    currentBodyView = nil
end
