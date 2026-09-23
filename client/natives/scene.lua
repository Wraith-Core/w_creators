-- =====================================================================
--  client/natives/scene.lua  —  WCNative.scene
--  Streaming and ambient-task natives of the creator / selection scene.
-- =====================================================================

WCNative.scene = {}
local H = WCNative._

--- _NEW_LOAD_SCENE_START_SPHERE (load sphere)
-- hash: 0x513F8AA5BF2F17CF · confidence: Verified (pre-v3 LoadCreatorScene, vorp_character)
-- params: x, y, z (float), radius (float), p4 (int: seconds / flags as vorp_character passes)
-- returns: nothing
-- limitations: asynchronous; callers wait on collision/IPL state with a timeout
-- tested models: n/a · MP safe: yes · OneSync tested here: no (see TESTING.md)
function WCNative.scene.loadSphere(x, y, z, radius, p4)
    if not (WCUtil.isFinite(tonumber(x)) and WCUtil.isFinite(tonumber(y)) and WCUtil.isFinite(tonumber(z))) then
        return H.fail('loadSphere', 'invalid coords') or false
    end
    local ok = H.invoke(0x513F8AA5BF2F17CF, H.float(x), H.float(y), H.float(z), H.float(radius, 50.0),
        math.tointeger(tonumber(p4) or 0) or 0)
    return ok
end

--- TASK_START_SCENARIO_IN_PLACE_HASH
-- hash: 0x524B54361229154F · confidence: Verified (pre-v3 PlaySceneIdle, vorp_character selection peds)
-- params: ped (entity), scenarioHash (u32 or name), duration (int, -1), playEnterAnim (bool),
--   p4 (int, 0), heading (float), p6 (bool) · returns: nothing
-- limitations: an unknown scenario name does nothing (no error); heading defaults to the ped's
-- tested models: mp_male, mp_female · MP safe: yes · OneSync tested here: no
function WCNative.scene.startScenario(ped, scenario, duration, heading)
    if not H.ped(ped) then return H.fail('startScenario', 'invalid ped %s', tostring(ped)) or false end
    local hash = type(scenario) == 'string' and GetHashKey(scenario) or tonumber(scenario)
    if not hash then return H.fail('startScenario', 'invalid scenario %s', tostring(scenario)) or false end
    local ok = H.invoke(0x524B54361229154F, ped, hash, math.tointeger(tonumber(duration) or -1) or -1, false, 0,
        H.float(heading, GetEntityHeading(ped)), false)
    return ok
end
