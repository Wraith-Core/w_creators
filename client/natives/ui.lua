-- =====================================================================
--  client/natives/ui.lua  —  WCNative.ui
--  The cached objective / subtitle line of the native HUD (cleared by the creator so no stale
--  objective text shows over the scene).
-- =====================================================================

WCNative.ui = {}
local H = WCNative._

--- _CREATE_VAR_STRING
-- hash: 0xFA925AC00EB830B9 · confidence: Verified (pre-v3 creator release())
-- params: flags (int, 10), textType ('LITERAL_STRING'), text (string) · returns: var string handle
-- limitations: the handle is only valid for the current frame's text calls
-- tested models: n/a · MP safe: yes · OneSync tested here: no (see TESTING.md)
function WCNative.ui.varString(text)
    local ok, str = H.invoke(0xFA925AC00EB830B9, 10, 'LITERAL_STRING', tostring(text or ' '), Citizen.ResultAsLong())
    if not ok then return H.fail('varString', 'failed') end
    return str
end

--- _UI_PROMPT_DISABLE_PROMPTS_THIS_FRAME (1.0.9: the game's focus prompts under our voice card)
-- hash: 0xF1622CE88A1946FB · confidence: In use (w_stables client/natives.lua N.blindFrame)
-- params: none · returns: nothing
-- limitations: this frame only (call every frame); the game's controls still act (melee, emote)
-- tested models: n/a · MP safe: yes (local UI) · OneSync tested here: no
function WCNative.ui.hidePromptsThisFrame()
    local ok = H.invoke(0xF1622CE88A1946FB)
    if not ok then return H.fail('hidePromptsThisFrame', 'failed') end
    return true
end

--- _UILOG_SET_CACHED_OBJECTIVE
-- hash: 0xFA233F8FE190514C · confidence: Verified (pre-v3 creator state loop)
-- params: text (var string handle, or 0 to clear) · returns: nothing
-- limitations: only caches the text; printObjective shows it
-- tested models: n/a · MP safe: yes · OneSync tested here: no
function WCNative.ui.setObjective(str)
    local ok = H.invoke(0xFA233F8FE190514C, str or 0)
    return ok
end

--- _UILOG_PRINT_CACHED_OBJECTIVE
-- hash: 0xE9990552DEC71600 · confidence: Verified (pre-v3 creator state loop)
-- params: none · returns: nothing
-- limitations: none known
-- tested models: n/a · MP safe: yes · OneSync tested here: no
function WCNative.ui.printObjective()
    local ok = H.invoke(0xE9990552DEC71600)
    return ok
end

--- Clear the objective line: an empty objective (0) printed once.
function WCNative.ui.clearObjective()
    local a = WCNative.ui.setObjective(0)
    local b = WCNative.ui.printObjective()
    return a and b
end

--- Blank the objective line with a literal space (what the pre-v3 creator did when leaving).
function WCNative.ui.blankObjective()
    local str = WCNative.ui.varString(' ')
    if not str then return false end
    local a = WCNative.ui.setObjective(str)
    local b = WCNative.ui.printObjective()
    return a and b
end

--- DRAW_MARKER
-- hash: 0x2A32FAA57B937173 · confidence: Verified (w_doorlock client/board.lua: the door picker's box and dot)
-- params: kind (marker hash, e.g. 0x6EB7D3BB box, 0x50638AB9 sphere), x, y, z (floats), size (float),
--   r, g, b, a (0-255) · returns: nothing
-- limitations: one frame only (call it every frame); local to this client
-- tested models: n/a · MP safe: yes · OneSync tested here: no
function WCNative.ui.drawMarker(kind, x, y, z, size, r, g, b, a)
    x, y, z, size = tonumber(x), tonumber(y), tonumber(z), tonumber(size) or 0.5
    if not x or not y or not z then return false end
    local ok = H.invoke(0x2A32FAA57B937173, kind, x + 0.0, y + 0.0, z + 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0,
        size + 0.0, size + 0.0, size + 0.0, r or 255, g or 255, b or 255, a or 160, false, false, 0, false)
    return ok
end
