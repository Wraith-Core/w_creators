-- =====================================================================
--  client/camera/camera.lua  —  WCCamera: the one camera service (ARCHITECTURE.md §3.2, §8.6)
--  An actor-relative framing camera used by the selector, the creator and every service editor.
--  Two scripted cameras alternate: each move places the idle one on the new framing and
--  interpolates from the active one, so framing changes glide instead of cutting.
--  The viewing direction is taken from the actor's heading when the camera opens (or the actor
--  changes) and then kept: rotating the actor, changing a category or zooming never swings the
--  camera around with it. The lateral offset is mirrored for right-to-left languages so the
--  actor stays clear of the panel.
--  A service flow can fix that direction and the framings first (Cam.anchor): the clothing store
--  and the wardrobe frame from the fitting stand's own heading with the store framings
--  (Cam.SETS.shop), never from whatever heading the player happens to have when the camera opens.
--  A store framing that a wall would hide is kept in front of that wall (keepInRoom).
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
    -- ⚠️ On a `bone` preset `offset` is metres measured FROM THE HEAD BONE: 0 aims straight at it,
    --    so the head sits in the middle of the frame. It used to be added on top of the head height
    --    (0.10 - 0.18), which aimed the camera 10-18 cm ABOVE the skull — the head then rendered low
    --    in the frame with empty room over it, which is what the face editor looked like.
    head        = { distance = 1.20, side = 0.18, bone = true, offset = 0.00, fov = 34.0 },
    face        = { distance = 0.90, side = 0.12, bone = true, offset = -0.02, fov = 30.0 },
    eyes        = { distance = 0.65, side = 0.07, bone = true, offset = 0.01, fov = 28.0 },
    hair        = { distance = 1.05, side = 0.15, bone = true, offset = 0.06, fov = 32.0 },
    facialHair  = { distance = 0.85, side = 0.10, bone = true, offset = -0.06, fov = 30.0 },
    -- the teeth are a component you cannot judge from the 'face' framing: this sits on the mouth
    teeth       = { distance = 0.55, side = 0.04, bone = true, offset = -0.085, fov = 26.0 },
    hands       = { distance = 1.60, side = 0.30, height = -0.10, fov = 36.0 },
    -- one hand close up (a ring, a bracelet, a glove): `bone` names the hand's bone, and the camera
    -- aims at where that hand is now (it falls back to 'hands' while the skeleton cannot be read)
    handLeft    = { distance = 0.80, side = 0.0, bone = 'SKEL_L_Hand', offset = 0.02, fov = 30.0 },
    handRight   = { distance = 0.80, side = 0.0, bone = 'SKEL_R_Hand', offset = 0.02, fov = 30.0 },
    feet        = { distance = 0.95, side = 0.12, height = -0.75, fov = 34.0 },
    accessories = { distance = 1.70, side = 0.28, height = -0.15, fov = 38.0 },
    -- the character selection framing (a wider shot, not an editor preset)
    selection   = { distance = 3.65, side = 0.20, height = -0.05, fov = 40.0 },
}

--- Framing sets a service flow picks with Cam.anchor. The presets above stay the default: the
--  selector, the creator, the barber and the clinic keep them. A name a set lacks falls back to
--  Cam.PRESETS.
--  'shop' (the clothing store and the wardrobe) is the framing of the Jump On clothing store, the
--  store the owner measures ours against. Its ped-relative numbers are taken as they are (metres
--  to the ped's right, ahead of it and above its origin; field of view in degrees) and laid out on
--  our preset fields, plus three the default presets do not need:
--    rise     the camera's height above its target (default 0.08, or 0 on a head-bone preset)
--    camSide  the camera's own offset to the right when it differs from the target's (the boots
--             are seen a little from the side)
--    boneId, camera, target
--             a framing measured on one bone: the camera and the target are that bone's position
--             moved by these offsets, the way GetPedBoneCoords moves them (along the bone's own
--             axes, which only the game knows). `fallback` names the default preset used while
--             the skeleton cannot be read or when the result would not stand in front of the ped.
--  side and camSide are mirrored for right-to-left languages like every preset; the bone framings
--  are not (each hand is one side of the body).
--  The categories map to these framings as the Jump On store maps them (config/clothing.lua).
Cam.SETS = {
    shop = {
        -- the whole body: camera (0.5, 2.0, 0.3), target (0.5, 0.0, 0.0), fov 60
        fullBody    = { distance = 2.0, side = 0.5, height = 0.0, rise = 0.3, fov = 60.0 },
        -- the body (shirts, vests, coats, neckwear, belts, satchels): camera (0.3, 1.5, 0.5),
        -- target (0.3, 0.0, 0.3), fov 45
        upperBody   = { distance = 1.5, side = 0.3, height = 0.3, rise = 0.2, fov = 45.0 },
        -- the pants (pants, chaps, gunbelts, holsters, buckles): camera (0.3, 2.0, 0.0),
        -- target (0.3, 0.0, -0.4), fov 40
        lowerBody   = { distance = 2.0, side = 0.3, height = -0.4, rise = 0.4, fov = 40.0 },
        -- the boots: camera (1.0, 1.5, 0.0), target (0.3, 0.0, -0.6), fov 30
        feet        = { distance = 1.5, side = 0.3, camSide = 1.0, height = -0.6, rise = 0.6, fov = 30.0 },
        -- the head (hats, masks, eyewear): head bone 57278, camera (0.1, 1.0, 0.5), target (0.0, 0.1, 0.0), fov 30
        head        = { boneId = 57278, camera = { 0.1, 1.0, 0.5 }, target = { 0.0, 0.1, 0.0 }, fov = 30.0, fallback = 'head' },
        face        = { boneId = 57278, camera = { 0.1, 1.0, 0.5 }, target = { 0.0, 0.1, 0.0 }, fov = 30.0, fallback = 'face' },
        -- the right hand (gloves, gauntlets, right rings): bone 7966, camera (0.1, 0.5, 1.0),
        -- target (-0.3, -0.3, -0.5), fov 30
        handRight   = { boneId = 7966, camera = { 0.1, 0.5, 1.0 }, target = { -0.3, -0.3, -0.5 }, fov = 30.0, fallback = 'handRight' },
        -- the left hand (bracelets, left rings): bone 37709, camera (0.3, 1.0, -1.0), target (0.0, 0.15, 0.0), fov 25
        handLeft    = { boneId = 37709, camera = { 0.3, 1.0, -1.0 }, target = { 0.0, 0.15, 0.0 }, fov = 25.0, fallback = 'handLeft' },
        -- the group views that stand for several categories: the arms as the body view, the
        -- accessories (worn at the waist) as the pants view
        hands       = { distance = 1.5, side = 0.3, height = 0.3, rise = 0.2, fov = 45.0 },
        accessories = { distance = 2.0, side = 0.3, height = -0.4, rise = 0.4, fov = 40.0 },
    },
}

--- Pre-v3 destination names still accepted by focus().
Cam.ALIASES = { default = 'fullBody', body = 'upperBody', pant = 'lowerBody', boot = 'feet' }

--- w.raycast.pedPartFromScreen parts → presets (click = pick a body part).
Cam.PICK = { eyes = 'eyes', head = 'head', body = 'upperBody', pant = 'lowerBody', boot = 'feet' }

Cam.DEFAULT = 'fullBody'
Cam.INTERP_MS = 450
--- The creator's pair shot and the glide from it to the picked character (Config.Scene.cameras).
Cam.PAIR = 'pair'
Cam.PAIR_DISTANCE, Cam.PAIR_FOV = 4.0, 45.0
--- Degrees the actor turns for a profile view (Cam.pose), from wherever it faced before.
Cam.PROFILE_TURN = 90.0
Cam.ZOOM_MIN, Cam.ZOOM_MAX = -10.0, 30.0     -- fov degrees subtracted from the preset's fov
Cam.HEIGHT_MIN, Cam.HEIGHT_MAX = -0.9, 0.9   -- metres added to the camera and its target
Cam.FOV_MIN, Cam.FOV_MAX = 22.0, 60.0
--- Head height above the entity origin used when the head bone cannot be read yet (metres).
Cam.HEAD_RISE_FALLBACK = 0.62
--- Degrees the actor may drift from the heading it is held on (Cam.anchor's hold) before it is
--  turned back.
Cam.HOLD_TOLERANCE = 1.0
--- A bone framing (Cam.SETS) is used only when its camera stands at least BONE_MIN_AHEAD metres
--  in front of the ped, no lower than BONE_MIN_RISE below the ped's origin (the origin is about a
--  metre above the feet), and between BONE_MIN_REACH and BONE_MAX_REACH metres from its target.
Cam.BONE_MIN_AHEAD = 0.25
Cam.BONE_MIN_RISE = 0.85
Cam.BONE_MIN_REACH, Cam.BONE_MAX_REACH = 0.2, 3.0
--- A store camera that a wall hides (keepInRoom, the 'shop' set only) is pulled in to WALL_MARGIN
--  metres short of the wall, never nearer than WALL_MIN metres to the player.
Cam.WALL_MARGIN = 0.15
Cam.WALL_MIN = 0.45

local st = {
    camA = nil, camB = nil, active = nil,
    ped = nil, preset = nil, initial = nil, heading = nil,
    zoom = 0.0, height = 0.0, open = false,
    glide = nil,                  -- one-shot blend duration (ms) for the next move (Cam.glide)
    pose = nil, poseBase = nil,   -- 'profile' while the actor is turned by Cam.pose, its heading before
    set = nil,                    -- the Cam.SETS framing set of this open (Cam.anchor), or nil
    pedHeading = nil,             -- the heading the actor is held on (Cam.anchor's hold)
}
local pending = nil               -- Cam.anchor: how the next Cam.open of one ped frames it
local holdGen = 0                 -- bumped by every open / close: an older hold stops

local function camExists(cam)
    return cam ~= nil and cam ~= 0 and not not DoesCamExist(cam)
end

local function pedExists(ped)
    -- BOOL natives answer 1 (not true) on this runtime: never compare them with == true
    return type(ped) == 'number' and ped ~= 0 and not not DoesEntityExist(ped)
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

--- The preset table of a name: the open's framing set first (Cam.anchor), else the default.
local function presetOf(name)
    local set = st.set and Cam.SETS[st.set]
    return set and set[name] or Cam.PRESETS[name]
end

--- The angle between two headings, in degrees (0..180).
local function turn(a, b)
    local d = (a - b) % 360.0
    return d > 180.0 and 360.0 - d or d
end

--- Hold the actor on `heading` for ms (Cam.anchor's hold). The fitting-room move clears the
--  player's tasks and turns him to the stand, yet a task the game ends a moment later can still
--  turn him back; the camera does not follow the actor, so he would then be seen from the side or
--  from behind for the whole visit. Cam.rotate and Cam.pose move the held heading with them, so
--  the player's own turns are never undone.
local function hold(ped, heading, ms)
    holdGen = holdGen + 1
    st.pedHeading = heading
    if not ms or ms <= 0 then return end
    local gen, stopAt = holdGen, GetGameTimer() + ms
    CreateThread(function()
        while gen == holdGen and st.open and st.ped == ped and GetGameTimer() < stopAt do
            if pedExists(ped) and st.pedHeading and turn(GetEntityHeading(ped), st.pedHeading) > Cam.HOLD_TOLERANCE then
                SetEntityHeading(ped, st.pedHeading + 0.0)
            end
            Wait(0)
        end
    end)
end

local function ensureCams()
    if not camExists(st.camA) then st.camA = CreateCam('DEFAULT_SCRIPTED_CAMERA', false) end
    if not camExists(st.camB) then st.camB = CreateCam('DEFAULT_SCRIPTED_CAMERA', false) end
    if st.active ~= st.camA and st.active ~= st.camB then st.active = nil end
end

--- Put the idle camera at c, aimed at t, and blend to it from the active one (a one-shot
--  Cam.glide duration applies to this move only). f = the streaming focus point.
local function place(cx, cy, cz, tx, ty, tz, fov, fx, fy, fz)
    ensureCams()
    local nextCam = st.active == st.camA and st.camB or st.camA
    -- RedM native arguments are scalars: never rely on vector unpacking
    SetCamCoord(nextCam, cx + 0.0, cy + 0.0, cz + 0.0)
    PointCamAtCoord(nextCam, tx + 0.0, ty + 0.0, tz + 0.0)
    SetCamFov(nextCam, clamp(fov, Cam.FOV_MIN, Cam.FOV_MAX) + 0.0)
    local interp = st.glide or Cam.INTERP_MS
    st.glide = nil
    if camExists(st.active) and st.active ~= nextCam then
        SetCamActiveWithInterp(nextCam, st.active, interp, true, true)
    else
        SetCamActive(nextCam, true)
    end
    RenderScriptCams(true, false, 0, true, true, 0)
    SetFocusPosAndVel(fx + 0.0, fy + 0.0, fz + 0.0, 0.0, 0.0, 0.0)
    st.active = nextCam
end

--- The world position of a named bone of the ped (x, y, z), or nil while it cannot be read.
local function namedBone(ped, name)
    if type(GetEntityBoneIndexByName) ~= 'function' or type(GetWorldPositionOfEntityBone) ~= 'function' then return nil end
    local okI, index = pcall(GetEntityBoneIndexByName, ped, name)
    if not okI or type(index) ~= 'number' or index < 0 then return nil end
    local okP, pos = pcall(GetWorldPositionOfEntityBone, ped, index)
    if not okP or not pos then return nil end
    local x, y, z = tonumber(pos.x), tonumber(pos.y), tonumber(pos.z)
    if not (WCUtil.isFinite(x) and WCUtil.isFinite(y) and WCUtil.isFinite(z)) then return nil end
    -- a skeleton not rendered yet answers the entity origin for every bone
    local at = GetEntityCoords(ped)
    if math.abs(x - at.x) + math.abs(y - at.y) + math.abs(z - at.z) < 0.05 then return nil end
    return x, y, z
end

--- The camera at (cx, cy, cz) moved in front of the first wall on the level line from the ped to
--  it: x, y, and whether a wall was in the way (unchanged when the line is clear).
local function pullIn(ped, cx, cy, cz)
    local at = GetEntityCoords(ped)
    local hit, hx, hy = WCNative.camera.firstWall(at.x, at.y, cz, cx, cy, cz, ped)
    if not hit then return cx, cy, false end
    local dx, dy = cx - at.x, cy - at.y
    local len = math.sqrt(dx * dx + dy * dy)
    if len <= 0 then return cx, cy, true end
    local free = math.sqrt((hx - at.x) ^ 2 + (hy - at.y) ^ 2)
    -- never pushed further out than the framing itself (WALL_MIN could exceed a short line)
    local keep = math.min(math.max(free - Cam.WALL_MARGIN, Cam.WALL_MIN), len)
    return at.x + dx * keep / len, at.y + dy * keep / len, true
end

--- The store framings (Cam.SETS.shop) are Jump On's numbers, measured on its own stands without
--  the mirror and with nothing checking for walls. At some of our stands the mirrored camera
--  (right-to-left languages) or even the plain one stood inside or behind a wall (the Valentine
--  hotel room in Arabic, the Tumbleweed booth), and since it keeps aiming at the player the screen
--  showed the wall. A store camera at (cx, cy, cz) aimed at (tx, ty) therefore:
--    1. stays where it is when no wall is in the way (a clear stand looks exactly as before);
--    2. else takes the unmirrored framing alt = { cx, cy, tx, ty } (Jump On's tested side), when
--       the mirror moved it and that side is clear;
--    3. else is pulled in along its line to the player (pullIn).
--  Returns the camera's x, y and its target's x, y (the heights never change).
local function keepInRoom(ped, cx, cy, cz, tx, ty, alt)
    local px, py, blocked = pullIn(ped, cx, cy, cz)
    if not blocked then return cx, cy, tx, ty end
    if alt then
        local _, _, altBlocked = pullIn(ped, alt[1], alt[2], cz)
        if not altBlocked then return alt[1], alt[2], alt[3], alt[4] end
    end
    return px, py, tx, ty
end

--- A framing measured on one bone (a Cam.SETS preset with boneId): the camera and its target are
--  the bone's position moved by the preset's offsets, exactly as GetPedBoneCoords moves them. Both
--  are then taken into the ped's own frame (right, ahead, up at its live heading) and laid out
--  along the fixed viewing direction, so a ped the player has turned is still seen from where the
--  camera opened (a ped not turned gets exactly those positions). Returns false (the caller uses
--  the preset's fallback) while the skeleton cannot be read, or when the camera would not stand in
--  front of the ped, above its feet and within reach of its target: the offsets follow the bone's
--  own axes, and a framing that turns out behind or under the ped is never shown.
local function frameBone(ped, d)
    if type(GetPedBoneCoords) ~= 'function' then return false end
    local id, c, t = d.boneId, d.camera, d.target
    local okB, bone = pcall(GetPedBoneCoords, ped, id, 0.0, 0.0, 0.0)
    local okC, cw = pcall(GetPedBoneCoords, ped, id, c[1] + 0.0, c[2] + 0.0, c[3] + 0.0)
    local okT, tw = pcall(GetPedBoneCoords, ped, id, t[1] + 0.0, t[2] + 0.0, t[3] + 0.0)
    if not (okB and okC and okT and bone and cw and tw) then return false end
    local at = GetEntityCoords(ped)
    -- a skeleton not rendered yet (or a bone this ped lacks) answers the entity origin
    if math.abs(bone.x - at.x) + math.abs(bone.y - at.y) + math.abs(bone.z - at.z) < 0.05 then return false end
    local live = math.rad(GetEntityHeading(ped))
    local liveRX, liveRY = math.cos(live), math.sin(live)
    local liveFX, liveFY = -math.sin(live), math.cos(live)
    local angle = math.rad(st.heading)
    local rightX, rightY = math.cos(angle), math.sin(angle)
    local frontX, frontY = -math.sin(angle), math.cos(angle)
    local function relay(p)
        local dx, dy = p.x - at.x, p.y - at.y
        local r, f = dx * liveRX + dy * liveRY, dx * liveFX + dy * liveFY
        return at.x + rightX * r + frontX * f, at.y + rightY * r + frontY * f, p.z + 0.0, f
    end
    local cx, cy, cz, ahead = relay(cw)
    local tx, ty, tz = relay(tw)
    local reach = math.sqrt((cx - tx) ^ 2 + (cy - ty) ^ 2 + (cz - tz) ^ 2)
    if ahead < Cam.BONE_MIN_AHEAD or cz < at.z - Cam.BONE_MIN_RISE
        or reach < Cam.BONE_MIN_REACH or reach > Cam.BONE_MAX_REACH then
        return false
    end
    -- the bone framings are never mirrored: no other side to try
    if st.set == 'shop' then cx, cy = keepInRoom(ped, cx, cy, cz + st.height, tx, ty) end
    place(cx, cy, cz + st.height, tx, ty, tz + st.height, d.fov - st.zoom, bone.x, bone.y, bone.z)
    return true
end

--- Place the idle camera on the preset's framing and blend to it.
local function frame(presetName)
    local ped = st.ped
    if not pedExists(ped) then return false end
    local d = presetOf(presetName)
    if not st.heading then st.heading = GetEntityHeading(ped) end
    if d.boneId then
        if frameBone(ped, d) then
            st.preset = presetName
            return true
        end
        d = Cam.PRESETS[d.fallback] or Cam.PRESETS[Cam.DEFAULT]
    end
    if type(d.bone) == 'string' then
        -- a named bone (one hand): the camera looks at the bone from the fixed viewing direction
        local bx, by, bz = namedBone(ped, d.bone)
        if bx then
            local side = d.side * (UiDir() == 'rtl' and -1 or 1)
            local angle = math.rad(st.heading)
            local rightX, rightY = math.cos(angle), math.sin(angle)
            local frontX, frontY = -math.sin(angle), math.cos(angle)
            local tx, ty = bx + rightX * side, by + rightY * side
            local tz = bz + (d.offset or 0.0) + st.height
            local cx, cy = tx + frontX * d.distance, ty + frontY * d.distance
            if st.set == 'shop' then
                -- the unmirrored framing, when the mirror moved this one
                local alt = side ~= d.side and {
                    bx + rightX * d.side + frontX * d.distance, by + rightY * d.side + frontY * d.distance,
                    bx + rightX * d.side, by + rightY * d.side,
                } or nil
                cx, cy, tx, ty = keepInRoom(ped, cx, cy, tz, tx, ty, alt)
            end
            place(cx, cy, tz, tx, ty, tz, d.fov - st.zoom, bx, by, bz)
            st.preset = presetName
            return true
        end
        d = Cam.PRESETS.hands
    end
    local at = GetEntityCoords(ped)
    local height = d.height or 0.0
    if d.bone then
        -- ⚠️ The old clamp was clamp(rise, 0.25, 1.2). Whether GetEntityCoords answers the feet or the
        --    centre of a ped, that upper bound could saturate, and every ped was then framed at the same
        --    height regardless of how tall it actually is. The head bone is the thing being edited, so
        --    it is what the camera aims at; the bounds below are only a sanity net for a ped whose
        --    skeleton has not rendered yet (GetPedBoneCoords then answers at the entity origin).
        local head = GetPedBoneCoords(ped, 21030, 0.0, 0.0, 0.0)
        local rise = head and (head.z - at.z) or 0.0
        if rise < 0.15 or rise > 2.20 then rise = Cam.HEAD_RISE_FALLBACK end
        height = rise + (d.offset or 0.0)
    end
    local mirror = UiDir() == 'rtl' and -1 or 1
    local side = d.side * mirror
    -- the camera stands as far to the side as its target unless the preset says otherwise
    -- (camSide: the store's boots view looks at the feet a little from the side)
    local camSide = (d.camSide or d.side) * mirror
    local angle = math.rad(st.heading)
    local rightX, rightY = math.cos(angle), math.sin(angle)
    local frontX, frontY = -math.sin(angle), math.cos(angle)
    local tx, ty, tz = at.x + rightX * side, at.y + rightY * side, at.z + height + st.height
    -- the lens rides slightly above the target on the wide shots (it reads as a portrait), but on a
    -- head-bone framing that tilt alone pushed the face down again — aim level there. A preset
    -- can set its own rise (the store framings look down on the pants and the boots).
    local rise = d.rise or (d.bone and 0.0 or 0.08)
    local cx = at.x + rightX * camSide + frontX * d.distance
    local cy = at.y + rightY * camSide + frontY * d.distance
    local cz = tz + rise
    if st.set == 'shop' then
        -- the unmirrored framing, when the mirror moved this one
        local alt = (side ~= d.side or camSide ~= (d.camSide or d.side)) and {
            at.x + rightX * (d.camSide or d.side) + frontX * d.distance,
            at.y + rightY * (d.camSide or d.side) + frontY * d.distance,
            at.x + rightX * d.side, at.y + rightY * d.side,
        } or nil
        cx, cy, tx, ty = keepInRoom(ped, cx, cy, cz, tx, ty, alt)
    end
    place(cx, cy, cz, tx, ty, tz, d.fov - st.zoom, at.x, at.y, at.z)
    st.preset = presetName
    return true
end

--- Open the camera on an actor (or move an open camera to a new actor) at a preset.
---@param ped integer
---@param preset? string (default 'fullBody')
---@return boolean
function Cam.open(ped, preset)
    if not pedExists(ped) then return false end
    local name = resolve(preset) or Cam.DEFAULT
    local anchor = pending
    pending = nil
    if anchor and anchor.ped ~= ped then anchor = nil end
    if st.ped ~= ped then st.heading, st.pose, st.poseBase = nil, nil, nil end
    holdGen = holdGen + 1 -- a hold of an earlier open ends here
    st.set, st.pedHeading = anchor and anchor.set or nil, nil
    if anchor and anchor.heading then
        -- ⚠️ The viewing direction is the flow's (the fitting stand's heading, the one the Jump On
        --    store frames from), not a reading of GetEntityHeading at this instant: the camera keeps
        --    its direction for the whole visit, so a heading the player had only for a moment (a
        --    task the fitting-room move ended) would leave it at his side or behind him until he left.
        st.heading, st.pose, st.poseBase = anchor.heading, nil, nil
        if turn(GetEntityHeading(ped), anchor.heading) > Cam.HOLD_TOLERANCE then
            SetEntityHeading(ped, anchor.heading + 0.0)
        end
    end
    st.ped, st.initial, st.open = ped, name, true
    st.zoom, st.height = 0.0, 0.0
    if anchor and anchor.heading then hold(ped, anchor.heading, anchor.hold) end
    return frame(name)
end

--- How the next Cam.open of `ped` frames it. A service flow calls this right before its editor
--  opens the camera; an open of another ped ignores it, and the open after that is plain again.
--    heading  the viewing direction: the camera stands in front of this heading and the actor is
--             turned to it, instead of whatever heading the actor has at that instant
--    set      a Cam.SETS framing set ('shop'), or nil for the default presets
--    hold     ms the actor is held on that heading after the open (0 = not held)
---@param ped integer
---@param opts table
---@return boolean
function Cam.anchor(ped, opts)
    if not pedExists(ped) then
        pending = nil
        return false
    end
    opts = type(opts) == 'table' and opts or {}
    local heading = tonumber(opts.heading)
    pending = {
        ped = ped,
        heading = WCUtil.isFinite(heading) and (heading % 360.0) or nil,
        set = type(opts.set) == 'string' and Cam.SETS[opts.set] ~= nil and opts.set or nil,
        hold = WCUtil.int(opts.hold, 0, 10000, 0),
    }
    return true
end

--- Forget an anchor no open has taken (the editor it was made for did not open). Left pending, it
--  would frame the next open of that ped, another service's (the barber's chair), from the store's
--  stand with the store framings, and turn the player to that stand's heading.
function Cam.clearAnchor()
    pending = nil
end

--- The framing set of the open camera ('shop'), or nil (the default presets or closed).
function Cam.currentSet()
    return st.open and st.set or nil
end

local function coords3(c)
    if type(c) ~= 'table' and type(c) ~= 'vector3' and type(c) ~= 'vector4' then return nil end
    local ok, x, y, z = pcall(function() return c.x or c[1], c.y or c[2], c.z or c[3] end)
    x, y, z = ok and tonumber(x), ok and tonumber(y), ok and tonumber(z)
    if not (WCUtil.isFinite(x) and WCUtil.isFinite(y) and WCUtil.isFinite(z)) then return nil end
    return x, y, z
end

--- Frame several actors standing side by side (the creator's gender scene): the camera sits
--  `distance` metres in front of the middle of them, along their mean heading, and looks at that
--  middle. framing = { distance, height, fov } or absolute { coords = {x,y,z}, target = {x,y,z}, fov }.
--  The camera stays one of the same two scripted cameras, so the next Cam.open glides from here.
---@param peds table list or map of ped handles
---@param framing? table
---@return boolean
function Cam.openPair(peds, framing)
    framing = type(framing) == 'table' and framing or {}
    local n, sx, sy, sz, ss, sc = 0, 0.0, 0.0, 0.0, 0.0, 0.0
    for _, ped in pairs(type(peds) == 'table' and peds or {}) do
        if pedExists(ped) then
            local at = GetEntityCoords(ped)
            local h = math.rad(GetEntityHeading(ped))
            n = n + 1
            sx, sy, sz = sx + at.x, sy + at.y, sz + at.z
            ss, sc = ss + math.sin(h), sc + math.cos(h)
        end
    end
    if n == 0 then return false end
    local mx, my, mz = sx / n, sy / n, sz / n
    local fov = tonumber(framing.fov) or Cam.PAIR_FOV
    local cx, cy, cz = coords3(framing.coords)
    local tx, ty, tz = coords3(framing.target)
    if not (cx and tx) then
        -- the mean heading on the circle (358° and 2° average to 0°, not 180°)
        local angle = math.atan(ss, sc)
        local frontX, frontY = -math.sin(angle), math.cos(angle)
        local distance = tonumber(framing.distance) or Cam.PAIR_DISTANCE
        local lift = tonumber(framing.height) or 0.0
        tx, ty, tz = mx, my, mz + lift
        cx, cy, cz = mx + frontX * distance, my + frontY * distance, mz + lift
    end
    st.ped, st.preset, st.initial, st.heading, st.open = nil, Cam.PAIR, Cam.PAIR, nil, true
    st.zoom, st.height, st.pose, st.poseBase = 0.0, 0.0, nil, nil
    place(cx, cy, cz, tx, ty, tz, fov, mx, my, mz)
    return true
end

--- The next camera move blends over `ms` instead of Cam.INTERP_MS (one move only): the creator's
--  glide between the pair shot and the picked character is slower than a preset change.
function Cam.glide(ms)
    local n = tonumber(ms)
    st.glide = (n and n >= 0 and n <= 10000) and math.floor(n) or nil
end

--- Turn the actor to show its profile ('profile') or back to where it faced before ('front').
--  The camera does not move (its direction was fixed when it opened), so the actor turns in front
--  of it; turning back restores the heading it had, a rotation the player made included.
---@param name string 'profile' | 'front'
---@return boolean
function Cam.pose(name)
    if not st.open or not pedExists(st.ped) then return false end
    if name == 'profile' then
        if st.pose == 'profile' then return true end
        st.poseBase = GetEntityHeading(st.ped)
        local h = ((st.poseBase + Cam.PROFILE_TURN) % 360) + 0.0
        SetEntityHeading(st.ped, h)
        st.pedHeading = h -- a held heading follows the pose (never turned back by the hold)
        st.pose = 'profile'
    elseif st.pose == 'profile' then
        local h = (st.poseBase or GetEntityHeading(st.ped)) + 0.0
        SetEntityHeading(st.ped, h)
        st.pedHeading = h
        st.pose, st.poseBase = nil, nil
    end
    return true
end

--- The current pose ('profile') or nil.
function Cam.currentPose()
    return st.open and st.pose or nil
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
    -- a player sitting in a barber chair stays as the chair holds him
    if type(WCServiceSeat) == 'table' and WCServiceSeat.onChair() then return false end
    local delta = WCUtil.number(deg, -180, 180, 0)
    local h = ((GetEntityHeading(st.ped) + delta) % 360) + 0.0
    SetEntityHeading(st.ped, h)
    st.pedHeading = h -- the player's own turn: a hold keeps this heading, not the old one
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
    st.glide, st.pose, st.poseBase = nil, nil, nil
    st.set, st.pedHeading, pending = nil, nil, nil
    holdGen = holdGen + 1
end

--- Re-frame after a language switch (the lateral offset follows the writing direction).
OnLanguageChange(function()
    if st.open and st.preset then frame(st.preset) end
end)

AddEventHandler('onResourceStop', function(resource)
    if resource ~= GetCurrentResourceName() then return end
    Cam.close()
end)

-- ---------------------------------------------------------------------
--  /wc_cam — nudge the open editor camera and report its geometry.
--  Cam.height was public but nothing ever called it, so the framing could only be changed by
--  editing the presets and restarting. This makes it adjustable in place: the number it prints is
--  the one to fold back into Cam.PRESETS[<preset>].offset once it looks right.
--    /wc_cam            what the camera is doing now
--    /wc_cam 0.05       raise the aim by 5 cm   (negative lowers it)
--    /wc_cam reset      back to the preset
-- ---------------------------------------------------------------------
RegisterCommand('wc_cam', function(_, args)
    if not st.open then
        return WCDebug.warn('camera', 'the editor camera is not open')
    end
    local word = tostring((args or {})[1] or '')
    if word == 'reset' then
        st.height = 0.0
        frame(st.preset or Cam.DEFAULT)
    else
        local delta = tonumber(word)
        if delta then Cam.height(delta) end
    end

    local ped, preset = st.ped, st.preset or Cam.DEFAULT
    local d = presetOf(preset) or {}
    local rise
    if pedExists(ped) then
        local at, head = GetEntityCoords(ped), GetPedBoneCoords(ped, 21030, 0.0, 0.0, 0.0)
        rise = head and (head.z - at.z) or nil
    end
    WCDebug.warn('camera', 'preset=%s offset=%s headRise=%s nudge=%+.3f  → effective offset %s',
        preset, tostring(d.offset), rise and ('%.3f'):format(rise) or 'n/a', st.height,
        d.offset and ('%.3f'):format((d.offset or 0.0) + st.height) or 'n/a')
end, false)
