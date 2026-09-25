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

-- The per-frame density natives the scene sets to 0 while it shows (a busy town like Saint Denis
-- otherwise streams passers-by, carts, dogs and birds into the shot). Several are underscore
-- (unnamed) natives in RDR3, so they are invoked by hash here rather than by a guessed name.
local DENSITY_THIS_FRAME = {
    0xAB0D553FE20A6E25, -- _SET_AMBIENT_PED_DENSITY_MULTIPLIER_THIS_FRAME
    0xBA0980B5C0A11924, -- _SET_AMBIENT_HUMAN_DENSITY_MULTIPLIER_THIS_FRAME
    0xC0258742B034DFAF, -- _SET_AMBIENT_ANIMAL_DENSITY_MULTIPLIER_THIS_FRAME
    0x7A556143A1C03898, -- SET_SCENARIO_PED_DENSITY_MULTIPLIER_THIS_FRAME
    0x28CB6391ACEDD9DB, -- _SET_SCENARIO_HUMAN_DENSITY_MULTIPLIER_THIS_FRAME
    0xDB48E99F8E064E56, -- _SET_SCENARIO_ANIMAL_DENSITY_MULTIPLIER_THIS_FRAME
    0x606374EBFC27B133, -- SET_VEHICLE_DENSITY_MULTIPLIER_THIS_FRAME
    0x1F91D44490E1EA0C, -- SET_RANDOM_VEHICLE_DENSITY_MULTIPLIER_THIS_FRAME
    0xFEDFA97638D61D4A, -- SET_PARKED_VEHICLE_DENSITY_MULTIPLIER_THIS_FRAME
}
WCNative.scene.DENSITY_THIS_FRAME = DENSITY_THIS_FRAME

--- The ambient population densities (peds, humans, animals, scenario peds, vehicles) for this frame
-- hash: DENSITY_THIS_FRAME (the nine above) · confidence: Likely (rdr3 native reference; the GTA V
--   counterparts are the standard way to empty a scene) · params: multiplier (float, 0.0 = none)
-- returns: nothing · limitations: per frame (call it every frame while the scene shows); peds that
--   already exist stay (CreatorScene.cleanup removes them once)
-- tested models: n/a · MP safe: yes (local streaming only) · OneSync tested here: no
function WCNative.scene.densityThisFrame(multiplier)
    local value = H.float(multiplier, 0.0)
    local all = true
    for _, hash in ipairs(DENSITY_THIS_FRAME) do
        if not H.invoke(hash, value) then all = false end
    end
    return all
end

--- ADD_SCENARIO_BLOCKING_AREA
-- hash: 0x1B5C85C612E5256E · confidence: Likely (rdr3 native reference)
-- params: x1, y1, z1, x2, y2, z2 (float box corners), p6 (bool, false), flags (int, 15 = every kind)
-- returns: the area handle (int) or nil · limitations: remove it with unblockScenarios(handle)
-- tested models: n/a · MP safe: yes (local) · OneSync tested here: no
function WCNative.scene.blockScenarios(x, y, z, radius)
    x, y, z = tonumber(x), tonumber(y), tonumber(z)
    if not (WCUtil.isFinite(x) and WCUtil.isFinite(y) and WCUtil.isFinite(z)) then
        return H.fail('blockScenarios', 'invalid coords')
    end
    local r = H.float(radius, 25.0)
    local ok, handle = H.invoke(0x1B5C85C612E5256E, H.float(x - r), H.float(y - r), H.float(z - r),
        H.float(x + r), H.float(y + r), H.float(z + r), false, 15, Citizen.ResultAsInteger())
    handle = ok and tonumber(handle) or nil
    return handle
end

--- REMOVE_SCENARIO_BLOCKING_AREA
-- hash: 0x31D16B74C6E29D66 · confidence: Likely (rdr3 native reference)
-- params: handle (int, from blockScenarios), p1 (bool, false) · returns: nothing
-- limitations: only handles blockScenarios returned (CreatorScene keeps the one it added)
-- tested models: n/a · MP safe: yes (local) · OneSync tested here: no
function WCNative.scene.unblockScenarios(handle)
    handle = math.tointeger(tonumber(handle))
    if not handle then return H.fail('unblockScenarios', 'invalid handle') or false end
    local ok = H.invoke(0x31D16B74C6E29D66, handle, false)
    return ok
end

-- ---------------------------------------------------------------------
--  Anim scenes: the clothing store's catalogue (client/clothing/catalogue.lua). Several of these
--  are underscore (unnamed) natives in RDR3, so every one is invoked by hash here.
-- ---------------------------------------------------------------------

--- _CREATE_ANIM_SCENE
-- hash: 0x1FCA98E33C1437B3 · confidence: Likely (rdr3 native reference; the catalogue scene of the
--   clothing stores) · params: dict (string, the anim scene), flags (int, 0), playlist (string: the
--   playback list to run), p3 (bool, false), p4 (bool, true) · returns: the scene handle (int) or nil
-- limitations: the scene does nothing until it is loaded and started; delete it with deleteAnimScene
-- tested models: none here (needs an in-game check) · MP safe: yes (local) · OneSync tested here: no
function WCNative.scene.createAnimScene(dict, flags, playlist)
    if type(dict) ~= 'string' or dict == '' or type(playlist) ~= 'string' or playlist == '' then
        return H.fail('createAnimScene', 'invalid scene %s / %s', tostring(dict), tostring(playlist))
    end
    local ok, handle = H.invoke(0x1FCA98E33C1437B3, dict, math.tointeger(tonumber(flags) or 0) or 0, playlist,
        false, true, Citizen.ResultAsInteger())
    handle = ok and tonumber(handle) or nil
    if not handle or handle == 0 then return nil end
    return handle
end

--- SET_ANIM_SCENE_ORIGIN
-- hash: 0x020894BF17A02EF2 · confidence: Likely (rdr3 native reference)
-- params: scene (int), x, y, z (float), rotX, rotY, rotZ (float, degrees), order (int, 2)
-- returns: nothing · limitations: set before the scene loads
-- tested models: n/a · MP safe: yes (local) · OneSync tested here: no
function WCNative.scene.setAnimSceneOrigin(scene, x, y, z, heading)
    scene = math.tointeger(tonumber(scene))
    if not scene or not (WCUtil.isFinite(tonumber(x)) and WCUtil.isFinite(tonumber(y)) and WCUtil.isFinite(tonumber(z))) then
        return H.fail('setAnimSceneOrigin', 'invalid scene or coords') or false
    end
    local ok = H.invoke(0x020894BF17A02EF2, scene, H.float(x), H.float(y), H.float(z), 0.0, 0.0, H.float(heading), 2)
    return ok
end

--- SET_ANIM_SCENE_ENTITY
-- hash: 0x8B720AD451CA2AB3 · confidence: Likely (rdr3 native reference)
-- params: scene (int), name (string: the scene's own name for the role), entity, flags (int, 0)
-- returns: nothing · limitations: a name the scene does not know is ignored by the game
-- tested models: none here · MP safe: yes (local) · OneSync tested here: no
function WCNative.scene.setAnimSceneEntity(scene, name, entity)
    scene = math.tointeger(tonumber(scene))
    if not scene or type(name) ~= 'string' or name == '' then return H.fail('setAnimSceneEntity', 'invalid scene') or false end
    if not H.entity(entity) then return H.fail('setAnimSceneEntity', 'invalid entity %s', tostring(entity)) or false end
    local ok = H.invoke(0x8B720AD451CA2AB3, scene, name, entity, 0)
    return ok
end

--- LOAD_ANIM_SCENE
-- hash: 0xAF068580194D9DC7 · confidence: Likely (rdr3 native reference)
-- params: scene (int) · returns: nothing
-- limitations: asynchronous; callers wait on isAnimSceneLoaded with a timeout
-- tested models: n/a · MP safe: yes (local) · OneSync tested here: no
function WCNative.scene.loadAnimScene(scene)
    scene = math.tointeger(tonumber(scene))
    if not scene then return H.fail('loadAnimScene', 'invalid scene') or false end
    local ok = H.invoke(0xAF068580194D9DC7, scene)
    return ok
end

--- IS_ANIM_SCENE_LOADED
-- hash: 0x477122B8D05E7968 · confidence: Likely (rdr3 native reference)
-- params: scene (int), p1 (bool, true), p2 (bool, false) · returns: boolean (BOOL natives answer 1)
-- limitations: false until loadAnimScene streamed it in
-- tested models: n/a · MP safe: yes (local) · OneSync tested here: no
function WCNative.scene.isAnimSceneLoaded(scene)
    scene = math.tointeger(tonumber(scene))
    if not scene then return false end
    local ok, loaded = H.invoke(0x477122B8D05E7968, scene, true, false)
    return ok and H.bool(loaded)
end

--- START_ANIM_SCENE
-- hash: 0xF4D94AF761768700 · confidence: Likely (rdr3 native reference)
-- params: scene (int) · returns: nothing
-- limitations: the scene must be loaded first
-- tested models: n/a · MP safe: yes (local) · OneSync tested here: no
function WCNative.scene.startAnimScene(scene)
    scene = math.tointeger(tonumber(scene))
    if not scene then return H.fail('startAnimScene', 'invalid scene') or false end
    local ok = H.invoke(0xF4D94AF761768700, scene)
    return ok
end

--- IS_ANIM_SCENE_FINISHED
-- hash: 0xD8254CB2C586412B · confidence: Likely (rdr3 native reference)
-- params: scene (int), p1 (bool, false) · returns: boolean (BOOL natives answer 1)
-- limitations: a looping playlist never reports finished: callers wait with a timeout
-- tested models: n/a · MP safe: yes (local) · OneSync tested here: no
function WCNative.scene.isAnimSceneFinished(scene)
    scene = math.tointeger(tonumber(scene))
    if not scene then return true end
    local ok, finished = H.invoke(0xD8254CB2C586412B, scene, false)
    return ok and H.bool(finished)
end

--- REMOVE_ANIM_SCENE_ENTITY
-- hash: 0x2BF96692C67F3E53 · confidence: Likely (rdr3 native reference; a store lets its player go
--   of the catalogue scene with it before moving him to the fitting room)
-- params: scene (int), name (string: the scene's own name for the role), entity
-- returns: nothing · limitations: the scene keeps running without that entity; free it with
--   deleteAnimScene. A name the scene does not know is ignored by the game
-- tested models: none here (needs an in-game check) · MP safe: yes (local) · OneSync tested here: no
function WCNative.scene.removeAnimSceneEntity(scene, name, entity)
    scene = math.tointeger(tonumber(scene))
    if not scene or type(name) ~= 'string' or name == '' then return H.fail('removeAnimSceneEntity', 'invalid scene') or false end
    if not H.entity(entity) then return H.fail('removeAnimSceneEntity', 'invalid entity %s', tostring(entity)) or false end
    local ok = H.invoke(0x2BF96692C67F3E53, scene, name, entity)
    return ok
end

--- _DELETE_ANIM_SCENE
-- hash: 0x84EEDB2C6E650000 · confidence: Likely (rdr3 native reference)
-- params: scene (int) · returns: nothing
-- limitations: frees the scene at once (the entity is let go where it stands); never yields
-- tested models: n/a · MP safe: yes (local) · OneSync tested here: no
function WCNative.scene.deleteAnimScene(scene)
    scene = math.tointeger(tonumber(scene))
    if not scene then return H.fail('deleteAnimScene', 'invalid scene') or false end
    local ok = H.invoke(0x84EEDB2C6E650000, scene)
    return ok
end
