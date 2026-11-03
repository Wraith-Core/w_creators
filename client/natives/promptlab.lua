-- =====================================================================
--  client/natives/promptlab.lua  —  WCNative.lab: the raw natives of the staff's /promptlab (2026-11-03)
--  Only client/lab/promptlab.lua calls these. Every hash below was checked on 2026-11-03 against alloc8or
--  rdr3-nativedb-data natives.json (name, namespace, parameter list); none is used anywhere else in this
--  resource. Every wrapper is pcall'd (H.invoke) and records a failed call in a small list the lab sends
--  with its report (WCNative.lab.takeErrors). Removing the lab = this file + the two lab files + their
--  three fxmanifest lines.
-- =====================================================================

WCNative.lab = {}
local H = WCNative._
local L = WCNative.lab

local errors = {}      -- { { n = wrapper, e = message } } since the last takeErrors()
local MAX_ERRORS = 20

local function call(name, hash, ...)
    local result = table.pack(H.invoke(hash, ...))
    if not result[1] then
        if #errors < MAX_ERRORS then errors[#errors + 1] = { n = name, e = tostring(result[2]):sub(1, 120) } end
        return false, nil
    end
    return true, result[2], result[3]
end

local function int(v) return math.tointeger(tonumber(v) or 0) or 0 end

--- The failed native calls since the last call (and the list emptied).
function L.takeErrors()
    local out = errors
    errors = {}
    return out
end

--- _UI_PROMPT_DISABLE_PROMPTS_THIS_FRAME (T1, the blind switch)
-- hash: 0xF1622CE88A1946FB · confidence: Verified (alloc8or HUD; in use: w_stables N.blindFrame, WCNative.ui)
-- params: none · returns: true when the call went through
-- limitations: this frame only; every native prompt of every script goes, with its action
-- tested models: n/a · MP safe: yes (local UI) · OneSync tested here: no
function L.blind()
    return (call('blind', 0xF1622CE88A1946FB))
end

--- _UI_PROMPT_DISABLE_PROMPT_TYPE_THIS_FRAME (T2)
-- hash: 0xFC094EF26DD153FA · confidence: Verified (alloc8or HUD, int p0; in use: w_stables N.typeFrame)
-- params: n (int: the per-frame prompt type list, femga: 1 food, 2 drawers, 3 loot, 5 carry, 7 lock-on, 8 sit, 12 mount)
-- returns: true when the call went through · limitations: this frame only; numbers beyond femga's list unknown
-- tested models: n/a · MP safe: yes (local UI) · OneSync tested here: no
function L.disableType(n)
    return (call('disableType', 0xFC094EF26DD153FA, int(n)))
end

--- _UI_PROMPT_ENABLE_PROMPT_TYPE_THIS_FRAME (T3)
-- hash: 0x06565032897BA861 · confidence: Likely (alloc8or HUD, int p0, comment: femga prompt_types)
-- params: n (int, the same list as disableType) · returns: true when the call went through
-- limitations: this frame only; whether it beats the blind switch is lab item L3
-- tested models: n/a · MP safe: yes (local UI) · OneSync tested here: no
function L.enableType(n)
    return (call('enableType', 0x06565032897BA861, int(n)))
end

--- _MODIFY_PLAYER_UI_PROMPT_FOR_PED (T4)
-- hash: 0xA3DB37EDF9A74635 · confidence: Likely (alloc8or PLAYER: player, ped, int promptType, int promptMode,
--   BOOL enabled; the meaning of the bool is lab item L1)
-- params: ped (entity), promptType (ePromptType 0-66), mode (0 block, 1 hide, 2 grey), value (boolean)
-- returns: true when the call went through · limitations: persistent for this player and that ped (undone by the lab)
-- tested models: ambient horses (in-game check pending) · MP safe: yes (this player only) · OneSync tested here: no
function L.modifyForPed(ped, promptType, mode, value)
    if not H.ped(ped) then return false end
    return (call('modifyForPed', 0xA3DB37EDF9A74635, PlayerId(), ped, int(promptType), int(mode), value == true))
end

--- _GET_PLAYER_UI_PROMPT_FOR_PED_IS_ENABLED (T6)
-- hash: 0xEA8F168A76A0B9BC · confidence: Likely (alloc8or PLAYER: player, ped, int promptType, int promptMode -> BOOL)
-- params: ped (entity), promptType (int), mode (int) · returns: true / false, or nil when the call failed
-- limitations: read-only; whether it follows modifyForPed is part of L1
-- tested models: ambient horses (in-game check pending) · MP safe: yes · OneSync tested here: no
function L.isEnabledForPed(ped, promptType, mode)
    if not H.ped(ped) then return nil end
    local ok, v = call('isEnabledForPed', 0xEA8F168A76A0B9BC, PlayerId(), ped, int(promptType), int(mode),
        Citizen.ResultAsInteger())
    if not ok then return nil end
    return H.bool(v)
end

--- UI_PROMPT_IS_CONTROL_ACTION_ACTIVE (L4)
-- hash: 0x1BE19185B8AFE299 · confidence: Likely (alloc8or HUD: Hash controlAction -> BOOL)
-- params: control (hash, e.g. joaat('INPUT_LOOT')) · returns: true / false, or nil when the call failed
-- limitations: read-only; read before any hide in the same frame
-- tested models: n/a · MP safe: yes · OneSync tested here: no
function L.controlPromptActive(control)
    local ok, v = call('controlPromptActive', 0x1BE19185B8AFE299, control, Citizen.ResultAsInteger())
    if not ok then return nil end
    return H.bool(v)
end

--- _SET_ENTITY_CARRYING_FLAG (T8)
-- hash: 0x18FF3110CF47115D · confidence: Likely (alloc8or ENTITY: entity, int flagId, BOOL value;
--   CCarryingFlags 37 = ForceHidePromptGroup)
-- params: entity, flag (int), value (boolean) · returns: true when the call went through
-- limitations: persistent on that entity (the lab puts the old value back)
-- tested models: carcasses (in-game check pending) · MP safe: yes · OneSync tested here: no
function L.setCarryingFlag(entity, flag, value)
    if not H.entity(entity) then return false end
    return (call('setCarryingFlag', 0x18FF3110CF47115D, entity, int(flag), value == true))
end

--- _GET_ENTITY_CARRYING_FLAG
-- hash: 0x808077647856DE62 · confidence: Likely (alloc8or ENTITY: entity, int flagId -> BOOL)
-- params: entity, flag (int) · returns: true / false, or nil when the call failed
-- limitations: read-only
-- tested models: carcasses (in-game check pending) · MP safe: yes · OneSync tested here: no
function L.getCarryingFlag(entity, flag)
    if not H.entity(entity) then return nil end
    local ok, v = call('getCarryingFlag', 0x808077647856DE62, entity, int(flag), Citizen.ResultAsInteger())
    if not ok then return nil end
    return H.bool(v)
end

--- TASK_LOOT_ENTITY (replay of loot / skin / pluck)
-- hash: 0x48FAE038401A2888 · confidence: Likely (alloc8or TASK: Ped ped, Entity entity)
-- params: ped (the player's), entity (the body / carcass) · returns: true when the call went through
-- limitations: whether it equals the game's prompt (animation, EVENT_LOOT_COMPLETE) is L6
-- tested models: ambient peds, animals (in-game check pending) · MP safe: yes · OneSync tested here: no
function L.taskLoot(ped, entity)
    if not H.ped(ped) or not H.entity(entity) then return false end
    return (call('taskLoot', 0x48FAE038401A2888, ped, entity))
end

--- TASK_PICKUP_CARRIABLE_ENTITY (replay of pick up)
-- hash: 0x502EC17B1BED4BFA · confidence: Likely (alloc8or TASK: Ped ped, Entity entity)
-- params: ped, entity · returns: true when the call went through · limitations: L7 checks the carry state
-- tested models: carcasses (in-game check pending) · MP safe: yes · OneSync tested here: no
function L.taskPickup(ped, entity)
    if not H.ped(ped) or not H.entity(entity) then return false end
    return (call('taskPickup', 0x502EC17B1BED4BFA, ped, entity))
end

--- TASK_MOUNT_ANIMAL (replay of get on)
-- hash: 0x92DB0739813C5186 · confidence: Verified (alloc8or TASK; in use: w_stables N.mountTask, same arguments)
-- params: ped, mount (horse) · returns: true when the call went through
-- limitations: timer 10000 ms then the game warps the rider; seat -1, speed 2.0, style 1
-- tested models: ambient horses (in-game check pending) · MP safe: yes · OneSync tested here: no
function L.taskMount(ped, mount)
    if not H.ped(ped) or not H.ped(mount) then return false end
    return (call('taskMount', 0x92DB0739813C5186, ped, mount, 10000, -1, 2.0, 1, 0, 0))
end

--- TASK_HOGTIE_TARGET_PED (replay of hogtie)
-- hash: 0x27829AFD3E03AC1A · confidence: Likely (alloc8or TASK: Ped ped, Ped targetPed)
-- params: ped, target · returns: true when the call went through · limitations: on a standing ped unknown
-- tested models: ambient peds (in-game check pending) · MP safe: yes · OneSync tested here: no
function L.taskHogtie(ped, target)
    if not H.ped(ped) or not H.ped(target) then return false end
    return (call('taskHogtie', 0x27829AFD3E03AC1A, ped, target))
end

--- _TASK_CUT_FREE_HOGTIED_TARGET_PED (replay of cut free)
-- hash: 0x81D16C4FF3A77ADF · confidence: Likely (alloc8or TASK: Ped ped, Ped targetPed)
-- params: ped, target · returns: true when the call went through · limitations: none known
-- tested models: ambient peds (in-game check pending) · MP safe: yes · OneSync tested here: no
function L.taskCutFree(ped, target)
    if not H.ped(ped) or not H.ped(target) then return false end
    return (call('taskCutFree', 0x81D16C4FF3A77ADF, ped, target))
end

--- TASK_USE_SCENARIO_POINT (replay of sit)
-- hash: 0xCCDAE6324B6A821C · confidence: Likely (alloc8or TASK: ped, int scenario, const char* conditionalAnim,
--   int p3, BOOL p4, BOOL p5, Hash p6, BOOL p7, float p8, BOOL p9; the arguments of vorp_barbershop / rakan-water)
-- params: ped, point (scenario point handle) · returns: true when the call went through
-- limitations: the meaning of p3..p9 is not documented
-- tested models: chairs / benches (in-game check pending) · MP safe: yes · OneSync tested here: no
function L.taskUsePoint(ped, point)
    if not H.ped(ped) then return false end
    return (call('taskUsePoint', 0xCCDAE6324B6A821C, ped, int(point), '', -1, true, false, 0, false, -1.0, true))
end

--- _TASK_USE_NEAREST_SCENARIO_TO_COORD (the sit replay when no point handle was found)
-- hash: 0x322BFDEA666E2B0E · confidence: Likely (alloc8or TASK: ped, x, y, z, float distance, int duration,
--   BOOL p6..p9; FRP / vorp_barbershop pass -1, true, true, true, true)
-- params: ped, x, y, z, distance (float) · returns: true when the call went through
-- limitations: p6..p9 undocumented
-- tested models: chairs / benches (in-game check pending) · MP safe: yes · OneSync tested here: no
function L.taskNearestScenario(ped, x, y, z, distance)
    if not H.ped(ped) then return false end
    return (call('taskNearestScenario', 0x322BFDEA666E2B0E, ped, H.float(x), H.float(y), H.float(z),
        H.float(distance, 1.5), -1, true, true, true, true))
end

--- GET_SCENARIO_POINTS_IN_AREA
-- hash: 0x345EC3B7EBDE1CB5 · confidence: Likely (alloc8or TASK: x, y, z, radius, Any* array, int size -> int;
--   the array is 8-byte slots, read the way w_lib's entity module does)
-- params: x, y, z, radius (floats), max (int) · returns: { count, slots = { int, ... } } or nil
-- limitations: needs w_lib's DataView; whether slot 0 holds the count is recorded by the lab
-- tested models: n/a · MP safe: yes · OneSync tested here: no
function L.scenarioPoints(x, y, z, radius, max)
    if type(DataView) ~= 'table' or type(DataView.ArrayBuffer) ~= 'function' then return nil end
    max = math.max(1, math.min(16, int(max)))
    local buf = DataView.ArrayBuffer(8 * (max + 2))
    local ok, n = call('scenarioPoints', 0x345EC3B7EBDE1CB5, H.float(x), H.float(y), H.float(z), H.float(radius, 1.5),
        buf:Buffer(), max, Citizen.ResultAsInteger())
    if not ok then return nil end
    local slots = {}
    for i = 0, max + 1 do slots[#slots + 1] = buf:GetInt32(i * 8) end
    return { count = int(n), slots = slots }
end

--- DOES_SCENARIO_POINT_EXIST
-- hash: 0x841475AC96E794D1 · confidence: Likely (alloc8or TASK: int scenario -> BOOL)
-- params: point (int) · returns: boolean · limitations: read-only
-- tested models: n/a · MP safe: yes · OneSync tested here: no
function L.pointExists(point)
    if int(point) == 0 then return false end
    local ok, v = call('pointExists', 0x841475AC96E794D1, int(point), Citizen.ResultAsInteger())
    return ok and H.bool(v)
end

--- _GET_SCENARIO_POINT_COORDS
-- hash: 0xA8452DD321607029 · confidence: Likely (alloc8or TASK: int scenario, BOOL p1 -> Vector3)
-- params: point (int) · returns: vector3 or nil · limitations: read-only
-- tested models: n/a · MP safe: yes · OneSync tested here: no
function L.pointCoords(point)
    local ok, v = call('pointCoords', 0xA8452DD321607029, int(point), true, Citizen.ResultAsVector())
    if not ok or type(v) ~= 'vector3' and type(v) ~= 'table' and type(v) ~= 'userdata' then return nil end
    return v
end

--- IS_PED_USING_ANY_SCENARIO
-- hash: 0x57AB4A3080F85143 · confidence: Likely (alloc8or PED: Ped ped -> BOOL)
-- params: ped · returns: boolean · limitations: read-only
-- tested models: mp_male, mp_female · MP safe: yes · OneSync tested here: no
function L.usingScenario(ped)
    if not H.ped(ped) then return false end
    local ok, v = call('usingScenario', 0x57AB4A3080F85143, ped, Citizen.ResultAsInteger())
    return ok and H.bool(v)
end

--- _GET_FIRST_ENTITY_PED_IS_CARRYING
-- hash: 0xD806CD2A4F2C2996 · confidence: Verified (alloc8or PED; in use: w_butcher's carcass check)
-- params: ped · returns: entity handle or 0 · limitations: read-only
-- tested models: mp_male, mp_female · MP safe: yes · OneSync tested here: no
function L.carrying(ped)
    if not H.ped(ped) then return 0 end
    local ok, v = call('carrying', 0xD806CD2A4F2C2996, ped, Citizen.ResultAsInteger())
    return ok and int(v) or 0
end

--- IS_PED_CARRYING_SOMETHING
-- hash: 0xA911EE21EDF69DAF · confidence: Likely (alloc8or PED: Ped ped -> BOOL)
-- params: ped · returns: boolean · limitations: read-only
-- tested models: mp_male, mp_female · MP safe: yes · OneSync tested here: no
function L.carryingSomething(ped)
    if not H.ped(ped) then return false end
    local ok, v = call('carryingSomething', 0xA911EE21EDF69DAF, ped, Citizen.ResultAsInteger())
    return ok and H.bool(v)
end

--- _GET_CARRIER_AS_PED
-- hash: 0x09B83E68DE004CD4 · confidence: Likely (alloc8or PED: Entity entity -> Ped)
-- params: entity · returns: ped handle or 0 · limitations: read-only
-- tested models: n/a · MP safe: yes · OneSync tested here: no
function L.carrier(entity)
    if not H.entity(entity) then return 0 end
    local ok, v = call('carrier', 0x09B83E68DE004CD4, entity, Citizen.ResultAsInteger())
    return ok and int(v) or 0
end

--- GET_IS_CARRIABLE_ENTITY
-- hash: 0x0CCFE72B43C9CF96 · confidence: Likely (alloc8or TASK: Entity entity -> BOOL)
-- params: entity · returns: boolean · limitations: read-only
-- tested models: n/a · MP safe: yes · OneSync tested here: no
function L.isCarriable(entity)
    if not H.entity(entity) then return false end
    local ok, v = call('isCarriable', 0x0CCFE72B43C9CF96, entity, Citizen.ResultAsInteger())
    return ok and H.bool(v)
end

--- _IS_ENTITY_FULLY_LOOTED
-- hash: 0x8DE41E9902E85756 · confidence: Likely (alloc8or ENTITY: Entity entity -> BOOL)
-- params: entity · returns: boolean · limitations: read-only
-- tested models: n/a · MP safe: yes · OneSync tested here: no
function L.fullyLooted(entity)
    if not H.entity(entity) then return false end
    local ok, v = call('fullyLooted', 0x8DE41E9902E85756, entity, Citizen.ResultAsInteger())
    return ok and H.bool(v)
end

--- _FIND_ENTITY_LOOTING_PED
-- hash: 0xEF2D9ED7CE684F08 · confidence: Likely (alloc8or ENTITY: Entity entity -> Ped, only while looting runs)
-- params: entity · returns: ped handle or 0 · limitations: read-only
-- tested models: n/a · MP safe: yes · OneSync tested here: no
function L.lootingPed(entity)
    if not H.entity(entity) then return 0 end
    local ok, v = call('lootingPed', 0xEF2D9ED7CE684F08, entity, Citizen.ResultAsInteger())
    return ok and int(v) or 0
end

--- _IS_ANIMAL_SKINNED
-- hash: 0x88A5564B19C15391 · confidence: Likely (alloc8or PED: Ped ped -> BOOL)
-- params: ped · returns: boolean · limitations: read-only
-- tested models: animals (in-game check pending) · MP safe: yes · OneSync tested here: no
function L.skinned(ped)
    if not H.ped(ped) then return false end
    local ok, v = call('skinned', 0x88A5564B19C15391, ped, Citizen.ResultAsInteger())
    return ok and H.bool(v)
end

--- GET_IS_ANIMAL
-- hash: 0x9A100F1CF4546629 · confidence: Likely (alloc8or ENTITY: Entity entity -> BOOL)
-- params: entity · returns: boolean · limitations: read-only
-- tested models: n/a · MP safe: yes · OneSync tested here: no
function L.isAnimal(entity)
    if not H.entity(entity) then return false end
    local ok, v = call('isAnimal', 0x9A100F1CF4546629, entity, Citizen.ResultAsInteger())
    return ok and H.bool(v)
end

--- _IS_THIS_MODEL_A_HORSE
-- hash: 0x772A1969F649E902 · confidence: Verified (alloc8or PED; in use: w_stables)
-- params: model (hash) · returns: boolean · limitations: read-only
-- tested models: horses · MP safe: yes · OneSync tested here: no
function L.isHorseModel(model)
    local ok, v = call('isHorseModel', 0x772A1969F649E902, model, Citizen.ResultAsInteger())
    return ok and H.bool(v)
end

--- IS_PED_HOGTIED
-- hash: 0x3AA24CCC0D451379 · confidence: Likely (alloc8or PED: Ped ped -> BOOL)
-- params: ped · returns: boolean · limitations: read-only
-- tested models: ambient peds · MP safe: yes · OneSync tested here: no
function L.hogtied(ped)
    if not H.ped(ped) then return false end
    local ok, v = call('hogtied', 0x3AA24CCC0D451379, ped, Citizen.ResultAsInteger())
    return ok and H.bool(v)
end

--- IS_USING_KEYBOARD_AND_MOUSE (L8: which device pressed)
-- hash: 0xA571D46727E2B718 · confidence: Likely (alloc8or PAD: int control -> BOOL)
-- params: none · returns: boolean · limitations: read-only
-- tested models: n/a · MP safe: yes · OneSync tested here: no
function L.keyboard()
    local ok, v = call('keyboard', 0xA571D46727E2B718, 0, Citizen.ResultAsInteger())
    return ok and H.bool(v)
end

--- GET_NUMBER_OF_EVENTS
-- hash: 0x5CE8DE5909565748 · confidence: Verified (alloc8or SCRIPT; w_butcher reads the same queue by name)
-- params: group (int, 0 = the AI queue) · returns: int · limitations: read-only; the queue is shared, never consumed
-- tested models: n/a · MP safe: yes · OneSync tested here: no
function L.eventCount(group)
    local ok, v = call('eventCount', 0x5CE8DE5909565748, int(group), Citizen.ResultAsInteger())
    return ok and int(v) or 0
end

--- GET_EVENT_AT_INDEX
-- hash: 0xA85E614430EFF816 · confidence: Verified (alloc8or SCRIPT; w_butcher reads the same queue by name)
-- params: group (int), index (int) · returns: event hash (int) or 0 · limitations: read-only
-- tested models: n/a · MP safe: yes · OneSync tested here: no
function L.eventAt(group, index)
    local ok, v = call('eventAt', 0xA85E614430EFF816, int(group), int(index), Citizen.ResultAsInteger())
    return ok and int(v) or 0
end

--- GET_EVENT_DATA (EVENT_LOOT_COMPLETE: looter, ped, success; w_butcher's three slots)
-- hash: 0x57EC5FA4D4D6AFCA · confidence: Verified (alloc8or SCRIPT; in use: w_butcher, the same 24-byte struct)
-- params: group (int), index (int) · returns: looter, ped, success (ints) or nil
-- limitations: needs w_lib's DataView
-- tested models: n/a · MP safe: yes · OneSync tested here: no
function L.lootEventData(group, index)
    if type(DataView) ~= 'table' or type(DataView.ArrayBuffer) ~= 'function' then return nil end
    local view = DataView.ArrayBuffer(24)
    view:SetInt32(0, 0)
    view:SetInt32(8, 0)
    view:SetInt32(16, 0)
    local ok, exists = call('lootEventData', 0x57EC5FA4D4D6AFCA, int(group), int(index), view:Buffer(), 3,
        Citizen.ResultAsInteger())
    if not ok or not H.bool(exists) then return nil end
    return view:GetInt32(0), view:GetInt32(8), view:GetInt32(16)
end
