-- =====================================================================
--  client/natives/camera.lua  —  WCNative.camera
--  Cinematic presentation natives and the store camera's wall probe (the camera itself uses named
--  natives in client/camera/).
-- =====================================================================

WCNative.camera = {}
local H = WCNative._

--- _REQUEST_LETTER_BOX_NOW (cinematic bars)
-- hash: 0x69D65E89FFD72313 · confidence: Verified (pre-v3 first-spawn wagon cutscene)
-- params: enable (bool), p1 (bool, false) · returns: nothing
-- limitations: must be re-requested every frame while active (the cutscene loop does)
-- tested models: n/a · MP safe: yes (local presentation only) · OneSync tested here: no
function WCNative.camera.letterbox(enable, p1)
    local ok = H.invoke(0x69D65E89FFD72313, enable == true, p1 == true)
    return ok
end

--- START_EXPENSIVE_SYNCHRONOUS_SHAPE_TEST_LOS_PROBE + GET_SHAPE_TEST_RESULT (by name): the first wall
--  on a line (the store camera keeps its framings in front of it, client/camera/camera.lua)
-- hash: 0x377906D8A31E5586 · confidence: Likely (w_butcher/client/aim.lua:106-111, wraith_cinema/client/shapetest.lua:43-46)
-- params: x1, y1, z1, x2, y2, z2 (float), flags 1 (map / mover collision only: peds, vehicles and
--         props are never hit), entity to ignore (or 0), options 7 (skip glass, see-through and
--         no-collision surfaces) · returns: hit (bool), x, y, z of the hit point
-- limitations: synchronous (read in the same frame); the map collision must be loaded around the line
-- tested models: n/a · MP safe: yes (local query only) · OneSync tested here: no
function WCNative.camera.firstWall(x1, y1, z1, x2, y2, z2, ignore)
    local ok, handle = H.invoke(0x377906D8A31E5586, H.float(x1), H.float(y1), H.float(z1),
        H.float(x2), H.float(y2), H.float(z2), 1, H.entity(ignore) and ignore or 0, 7, Citizen.ResultAsInteger())
    if not ok or not handle or type(GetShapeTestResult) ~= 'function' then return false end
    local okR, _, hit, at = pcall(GetShapeTestResult, handle)
    if not okR or not H.bool(hit) or not at then return false end
    local x, y, z = tonumber(at.x), tonumber(at.y), tonumber(at.z)
    if not (x and y and z) then return false end
    return true, x, y, z
end
