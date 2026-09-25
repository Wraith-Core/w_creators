-- =====================================================================
--  client/natives/ped.lua  —  WCNative.ped
--  Ped morphology, variation refresh, placement and small ped state natives.
-- =====================================================================

WCNative.ped = {}
local H = WCNative._

--- _SET_CHAR_EXPRESSION (SetCharExpression)
-- hash: 0x5653AB26C82938CF · confidence: Verified (pre-v3 face features and body expressions)
-- params: ped (entity), expressionId (int, w.component.data.expressions), value (float -1.0..1.0)
-- returns: nothing · limitations: the value MUST be a float (an integer is read as raw bits);
--   does not refresh the ped - batch with WCNative.ped.refresh once per apply
-- tested models: mp_male, mp_female · MP safe: yes · OneSync tested here: no (see TESTING.md)
function WCNative.ped.setExpression(ped, expressionId, value)
    if not H.ped(ped) then return H.fail('setExpression', 'invalid ped %s', tostring(ped)) or false end
    local id = math.tointeger(tonumber(expressionId))
    if not id then return H.fail('setExpression', 'invalid expression %s', tostring(expressionId)) or false end
    local v = math.max(-1.0, math.min(1.0, H.float(value)))
    local ok = H.invoke(0x5653AB26C82938CF, ped, id, v)
    return ok
end

--- Pre-refresh (clears the pending metaped update request) — _0x704C908E9C405136
-- hash: 0x704C908E9C405136 · confidence: Verified (w_lib component/ped-texture refresh, pre-v3 refresh)
-- params: ped (entity) · returns: nothing
-- limitations: no visible effect on its own; always followed by updateVariation (WCNative.ped.refresh)
-- tested models: mp_male, mp_female · MP safe: yes · OneSync tested here: no
function WCNative.ped.preRefresh(ped)
    if not H.ped(ped) then return H.fail('preRefresh', 'invalid ped %s', tostring(ped)) or false end
    local ok = H.invoke(0x704C908E9C405136, ped)
    return ok
end

--- _UPDATE_PED_VARIATION
-- hash: 0xCC8CA3E88256E58F · confidence: Verified (w_lib, pre-v3 NativeUpdatePedVariation)
-- params: ped (entity), p1 (false), p2 (true), p3 (true), p4 (true), p5 (false)
-- returns: nothing · limitations: expensive; call once per batch (A11)
-- tested models: mp_male, mp_female, story NPCs (tailors) · MP safe: yes · OneSync tested here: no
function WCNative.ped.updateVariation(ped)
    if not H.ped(ped) then return H.fail('updateVariation', 'invalid ped %s', tostring(ped)) or false end
    local ok = H.invoke(0xCC8CA3E88256E58F, ped, false, true, true, true, false)
    return ok
end

--- The batch refresh: 0x704C908E9C405136 then 0xCC8CA3E88256E58F, once.
function WCNative.ped.refresh(ped)
    if not H.ped(ped) then return H.fail('refresh', 'invalid ped %s', tostring(ped)) or false end
    local a = WCNative.ped.preRefresh(ped)
    local b = WCNative.ped.updateVariation(ped)
    return a and b
end

--- SET_PED_SCALE (named native; wrapped for the float coercion)
-- hash: called by name (SetPedScale) · confidence: Verified (pre-v3 ApplyPedScale)
-- params: ped (entity), scale (float 0.9..1.1 here) · returns: nothing
-- limitations: an integer scale collapses every bone to the origin while the ped reports ready
-- tested models: mp_male, mp_female · MP safe: yes · OneSync tested here: no
function WCNative.ped.setScale(ped, scale)
    if not H.ped(ped) then return H.fail('setScale', 'invalid ped %s', tostring(ped)) or false end
    local ok = pcall(SetPedScale, ped, H.float(scale, 1.0))
    return ok
end

--- _PLACE_ENTITY_ON_GROUND_PROPERLY
-- hash: 0x9587913B9E772D29 · confidence: Verified (pre-v3 CreatorScene.position)
-- params: entity (ped or object), p1 (bool, true) · returns: nothing
-- limitations: collision must be loaded around the entity first
-- tested models: mp_male, mp_female · MP safe: yes · OneSync tested here: no
function WCNative.ped.placeOnGround(entity)
    if not H.entity(entity) then return H.fail('placeOnGround', 'invalid entity %s', tostring(entity)) or false end
    local ok = H.invoke(0x9587913B9E772D29, entity, true)
    return ok
end

--- _GET_PED_HEIGHT (GetPedHeight)
-- hash: 0x1D491CCF7211FB74 · confidence: Likely (rdr3 native reference; the MP character creators
--   read the character's height from it right after SET_PED_SCALE, so it follows the scale)
-- params: ped (entity) · returns: the standing height in metres (float), or nil
-- limitations: read-only; an answer outside 0.5..3.0 m (a ped not rendered yet) is reported as nil,
--   so the caller keeps its plain readout (the creator's height slider, WCEditorTree.heightDisplay)
-- tested models: none here (needs an in-game check) · MP safe: yes (read only) · OneSync tested here: no
function WCNative.ped.height(ped)
    if not H.ped(ped) then return H.fail('height', 'invalid ped %s', tostring(ped)) end
    local asFloat = Citizen.ResultAsFloat and Citizen.ResultAsFloat() or nil
    local ok, value = H.invoke(0x1D491CCF7211FB74, ped, asFloat)
    value = ok and tonumber(value) or nil
    if not value or value ~= value or value < 0.5 or value > 3.0 then return nil end
    return value + 0.0
end

--- SET_PED_KEEP_TASK
-- hash: 0x971D38760FBC02EF · confidence: Verified (pre-v3 first-spawn wagon driver)
-- params: ped (entity), toggle (bool) · returns: nothing
-- limitations: none known (the task must be given before the ped is released)
-- tested models: CS_BivCoachDriver · MP safe: yes · OneSync tested here: no
function WCNative.ped.setKeepTask(ped, toggle)
    if not H.ped(ped) then return H.fail('setKeepTask', 'invalid ped %s', tostring(ped)) or false end
    local ok = H.invoke(0x971D38760FBC02EF, ped, toggle == true)
    return ok
end

--- _GIVE_WEAPON_TO_PED_2 (GiveWeaponToPed)
-- hash: 0x5E3BDDBCB83F3D84 · confidence: Verified (pre-v3 ArmScenePed: holstered revolver)
-- params: ped (entity), weaponHash (u32/int), ammo (int), forceInHand (bool), forceInHolster (bool)
--   (the trailing attach/flags parameters are left at their zero defaults, as before)
-- returns: nothing · limitations: cosmetic use only (preview peds); never used on the player ped
-- tested models: mp_male, mp_female · MP safe: yes · OneSync tested here: no
function WCNative.ped.giveWeapon(ped, weapon, ammo, forceInHand, forceInHolster)
    if not H.ped(ped) then return H.fail('giveWeapon', 'invalid ped %s', tostring(ped)) or false end
    local hash = type(weapon) == 'string' and GetHashKey(weapon) or tonumber(weapon)
    if not hash then return H.fail('giveWeapon', 'invalid weapon %s', tostring(weapon)) or false end
    local ok = H.invoke(0x5E3BDDBCB83F3D84, ped, hash, math.tointeger(tonumber(ammo) or 0) or 0,
        forceInHand == true, forceInHolster == true)
    return ok
end
