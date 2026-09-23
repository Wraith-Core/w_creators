-- =====================================================================
--  client/natives/camera.lua  —  WCNative.camera
--  Cinematic presentation natives (the camera itself uses named natives in client/camera/).
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
