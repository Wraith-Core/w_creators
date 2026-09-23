-- =====================================================================
--  client/camera/camera.lua  —  WCCamera: the one camera service (ARCHITECTURE.md §3.2, §8.6)
--  An actor-relative framing camera used by the selector, the creator and every service editor.
--  Two scripted cameras alternate: each move places the idle one on the new framing and
--  interpolates from the active one, so framing changes glide instead of cutting.
--  The viewing direction is taken from the actor's heading when the camera opens (or the actor
--  changes) and then kept: rotating the actor, changing a category or zooming never swings the
--  camera around with it. The lateral offset is mirrored for right-to-left languages so the
--  actor stays clear of the panel.
--  Camera natives are the plain named ones (CreateCam, SetCamCoord, ...), as §0.4 allows.
-- =====================================================================

WCCamera = {}
local Cam = WCCamera

--- The framings: distance (m, along the view axis), side (lateral offset), height (above the
--  entity origin) or bone = true (relative to the head bone + offset), fov (degrees).
Cam.PRESETS = {
    fullBody    = { distance = 3.15, side = 0.45, height = -0.05, fov = 42.0 },
    upperBody   = { distance = 2.10, side = 0.30, height = 0.08, fov = 38.0 },
    lowerBody   = { distance = 2.00, side = 0.25, height = -0.45, fov = 40.0 },
    head        = { distance = 1.20, side = 0.18, bone = true, offset = 0.10, fov = 34.0 },
    face        = { distance = 0.90, side = 0.12, bone = true, offset = 0.12, fov = 30.0 },
    eyes        = { distance = 0.65, side = 0.07, bone = true, offset = 0.13, fov = 28.0 },
    hair        = { distance = 1.05, side = 0.15, bone = true, offset = 0.18, fov = 32.0 },
    facialHair  = { distance = 0.85, side = 0.10, bone = true, offset = 0.05, fov = 30.0 },
    hands       = { distance = 1.60, side = 0.30, height = -0.10, fov = 36.0 },
    feet        = { distance = 0.95, side = 0.12, height = -0.75, fov = 34.0 },
    accessories = { distance = 1.70, side = 0.28, height = -0.15, fov = 38.0 },
    -- the character selection framing (a wider shot, not an editor preset)
    selection   = { distance = 3.65, side = 0.20, height = -0.05, fov = 40.0 },
}

--- Pre-v3 destination names still accepted by focus().
Cam.ALIASES = { default = 'fullBody', body = 'upperBody', pant = 'lowerBody', boot = 'feet' }

--- w.raycast.pedPartFromScreen parts → presets (click = pick a body part).
Cam.PICK = { eyes = 'eyes', head = 'head', body = 'upperBody', pant = 'lowerBody', boot = 'feet' }

Cam.DEFAULT = 'fullBody'
Cam.INTERP_MS = 450
Cam.ZOOM_MIN, Cam.ZOOM_MAX = -10.0, 30.0     -- fov degrees subtracted from the preset's fov
Cam.HEIGHT_MIN, Cam.HEIGHT_MAX = -0.9, 0.9   -- metres added to the camera and its target
Cam.FOV_MIN, Cam.FOV_MAX = 22.0, 60.0

local st = {
    camA = nil, camB = nil, active = nil,
    ped = nil, preset = nil, initial = nil, heading = nil,
    zoom = 0.0, height = 0.0, open = false,
}

local function camExists(cam)
    return cam ~= nil and cam ~= 0 and DoesCamExist(cam) == true
end

local function pedExists(ped)
    return type(ped) == 'number' and ped ~= 0 and DoesEntityExist(ped) == true
end

local function resolve(preset)
    if type(preset) ~= 'string' then return nil end
    preset = Cam.ALIASES[preset] or preset
    return Cam.PRESETS[preset] and preset or nil
end

local function clamp(v, lo, hi)
    if v < lo then return lo elseif v > hi then return hi end
    return v
end

local function ensureCams()
    if not camExists(st.camA) then st.camA = CreateCam('DEFAULT_SCRIPTED_CAMERA', false) end
    if not camExists(st.camB) then st.camB = CreateCam('DEFAULT_SCRIPTED_CAMERA', false) end
    if st.active ~= st.camA and st.active ~= st.camB then st.active = nil end
end

--- Place the idle camera on the preset's framing and blend to it.
local function frame(presetName)
    local ped = st.ped
    if not pedExists(ped) then return false end
    local d = Cam.PRESETS[presetName]
    if not st.heading then st.heading = GetEntityHeading(ped) end
    local at = GetEntityCoords(ped)
    local height = d.height or 0.0
    if d.bone then
        local head = GetPedBoneCoords(ped, 21030, 0.0, 0.0, 0.0)
        height = clamp(head.z - at.z, 0.25, 1.2) + (d.offset or 0.0)
    end
    local side = d.side * (UiDir() == 'rtl' and -1 or 1)
    local angle = math.rad(st.heading)
    local rightX, rightY = math.cos(angle), math.sin(angle)
    local frontX, frontY = -math.sin(angle), math.cos(angle)
    local tx, ty, tz = at.x + rightX * side, at.y + rightY * side, at.z + height + st.height
    local cx, cy, cz = tx + frontX * d.distance, ty + frontY * d.distance, tz + 0.08

    ensureCams()
    local nextCam = st.active == st.camA and st.camB or st.camA
    -- RedM native arguments are scalars: never rely on vector unpacking
    SetCamCoord(nextCam, cx + 0.0, cy + 0.0, cz + 0.0)
    PointCamAtCoord(nextCam, tx + 0.0, ty + 0.0, tz + 0.0)
    SetCamFov(nextCam, clamp(d.fov - st.zoom, Cam.FOV_MIN, Cam.FOV_MAX) + 0.0)
    if camExists(st.active) and st.active ~= nextCam then
        SetCamActiveWithInterp(nextCam, st.active, Cam.INTERP_MS, true, true)
    else
        SetCamActive(nextCam, true)
    end
    RenderScriptCams(true, false, 0, true, true, 0)
    SetFocusPosAndVel(at.x + 0.0, at.y + 0.0, at.z + 0.0, 0.0, 0.0, 0.0)
    st.active, st.preset = nextCam, presetName
    return true
end

--- Open the camera on an actor (or move an open camera to a new actor) at a preset.
---@param ped integer
---@param preset? string (default 'fullBody')
---@return boolean
function Cam.open(ped, preset)
    if not pedExists(ped) then return false end
    local name = resolve(preset) or Cam.DEFAULT
    if st.ped ~= ped then st.heading = nil end
    st.ped, st.initial, st.open = ped, name, true
    st.zoom, st.height = 0.0, 0.0
    return frame(name)
end

--- Move to a preset. Unknown presets are ignored. Without force, re-focusing the current preset
--  does nothing.
---@return boolean
function Cam.focus(preset, force)
    if not st.open then return false end
    local name = resolve(preset)
    if not name then return false end
    if name == st.preset and not force and camExists(st.active) then return true end
    return frame(name)
end

--- Rotate the actor by `deg` degrees; the camera keeps its viewing direction.
function Cam.rotate(deg)
    if not st.open or not pedExists(st.ped) then return false end
    local delta = WCUtil.number(deg, -180, 180, 0)
    SetEntityHeading(st.ped, ((GetEntityHeading(st.ped) + delta) % 360) + 0.0)
    return true
end

--- Zoom in (positive delta) or out; clamped.
function Cam.zoom(delta)
    if not st.open then return false end
    st.zoom = clamp(st.zoom + WCUtil.number(delta, -10, 10, 0), Cam.ZOOM_MIN, Cam.ZOOM_MAX)
    return frame(st.preset or st.initial or Cam.DEFAULT)
end

--- Raise (positive) or lower the camera and its target; clamped.
function Cam.height(delta)
    if not st.open then return false end
    st.height = clamp(st.height + WCUtil.number(delta, -1, 1, 0), Cam.HEIGHT_MIN, Cam.HEIGHT_MAX)
    return frame(st.preset or st.initial or Cam.DEFAULT)
end

--- Back to the full-body framing without zoom/height offsets (right-click), as before v3.
function Cam.reset()
    if not st.open then return false end
    st.zoom, st.height = 0.0, 0.0
    return frame(Cam.DEFAULT)
end

--- The preset under a screen point (x, y in 0..1 from the top-left, aspect = frame width/height),
--  focused when found. Returns the preset or nil (the click missed the actor).
---@return string|nil
function Cam.pick(x, y, aspect)
    if not st.open or not pedExists(st.ped) then return nil end
    local raycast = w and w.raycast
    if not raycast or not raycast.pedPartFromScreen then return nil end
    local ok, part = pcall(raycast.pedPartFromScreen, st.ped, WCUtil.number(x, 0, 1, 0.5),
        WCUtil.number(y, 0, 1, 0.5), tonumber(aspect))
    local preset = ok and Cam.PICK[part] or nil
    if not preset then return nil end
    st.zoom, st.height = 0.0, 0.0
    frame(preset)
    return preset
end

--- The current preset, or nil when closed.
function Cam.current()
    return st.open and st.preset or nil
end

--- Is the camera open?
function Cam.isOpen()
    return st.open
end

--- The framed actor, or nil.
function Cam.ped()
    return st.open and st.ped or nil
end

--- Stop rendering, destroy both cameras, release the focus and forget every offset.
function Cam.close()
    local had = st.open or camExists(st.camA) or camExists(st.camB)
    if had then RenderScriptCams(false, false, 0, true, true, 0) end
    local seen = {}
    for _, cam in ipairs({ st.camA, st.camB, st.active }) do
        if camExists(cam) and not seen[cam] then
            DestroyCam(cam, false)
            seen[cam] = true
        end
    end
    if had then ClearFocus() end
    st.camA, st.camB, st.active = nil, nil, nil
    st.ped, st.preset, st.initial, st.heading = nil, nil, nil, nil
    st.zoom, st.height, st.open = 0.0, 0.0, false
end

--- Re-frame after a language switch (the lateral offset follows the writing direction).
OnLanguageChange(function()
    if st.open and st.preset then frame(st.preset) end
end)

AddEventHandler('onResourceStop', function(resource)
    if resource ~= GetCurrentResourceName() then return end
    Cam.close()
end)
