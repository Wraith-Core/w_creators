"""Shared stubs for the clothing state controller tests (test_client_states_*.py).

make_states_client() returns the client infrastructure runtime of test_client_infra_support (shared
layer, natives, core, the real appearance pipeline, camera, scene, preview environment on the
recording fake of the RedM client natives) plus:
  - ped condition natives driven by Peds[h] flags: dead, dying, ragdoll, combat, melee, mounted,
    inVehicle, enteringVehicle,
  - the NUI boundary (RegisterNUICallback → NuiCallbacks, SendNUIMessage → NuiMessages, nui(name, data)),
  - w.notify (Notified), exports(...) (Exported[name] = fn), w.addKeybind (Keybinds),
  - w.requestAnimDict / w.playAnim / StopAnimTask recorded in Log (AnimMissing = true makes the
    dictionary fail to load),
then loads the editor (tree, editor, panel) and client/clothing/states.lua, and gives the player a
character wearing a hat, a shirt, a neckerchief and boots (no pants).
This module has no tests of its own.
"""
from test_client_infra_support import make_client

STATES_STUBS = r'''
local function rec(op, ...) Log[#Log + 1] = { op = op, args = table.pack(...) } end

local function flag(name) return function(e) return Peds[e] ~= nil and Peds[e][name] == true end end
IsEntityDead = flag('dead')
function IsPedDeadOrDying(e) return Peds[e] ~= nil and (Peds[e].dead == true or Peds[e].dying == true) end
IsPedRagdoll = flag('ragdoll')
IsPedInCombat = flag('combat')
IsPedInMeleeCombat = flag('melee')
IsPedOnMount = flag('mounted')
IsPedInAnyVehicle = flag('inVehicle')
IsPedGettingIntoAVehicle = flag('enteringVehicle')

NuiCallbacks, NuiMessages = {}, {}
function RegisterNUICallback(name, fn) NuiCallbacks[name] = fn end
function SendNUIMessage(m) NuiMessages[#NuiMessages + 1] = m end
function nui(name, data)
    local out
    NuiCallbacks[name](data, function(r) out = r end)
    return out
end
function lastMessage(kind)
    for i = #NuiMessages, 1, -1 do
        if NuiMessages[i].type == kind then return NuiMessages[i] end
    end
end

Notified = {}
w.notify = function(data) Notified[#Notified + 1] = data end
Exported = {}
getmetatable(exports).__call = function(_, name, fn) Exported[name] = fn end
Keybinds = {}
w.addKeybind = function(data) Keybinds[data.name] = data return data end

AnimMissing = false
w.requestAnimDict = function(dict, timeout)
    rec('requestAnimDict', dict, timeout)
    if AnimMissing then error("attempted to load invalid animDict '" .. dict .. "'") end
    return dict
end
w.playAnim = function(ped, dict, clip, ...) rec('playAnim', ped, dict, clip, ...) end
function StopAnimTask(ped, dict, clip, speed) rec('StopAnimTask', ped, dict, clip, speed) end

-- the server callback of §16.5: ok with the states unless CallbackResults says otherwise
CallbackResults = {}
function setStateCalls()
    local out = {}
    for _, e in ipairs(Log) do
        if e.op == 'callback:w_creators:clothing:setState' then out[#out + 1] = { e.args[2], e.args[3] } end
    end
    return out
end

-- a coroutine-driven perform (animations wait): Done / Result are set when it finishes
function performAsync(group, value, opts)
    Done, Result = false, nil
    CreateThread(function()
        Result = WCClothing.perform(group, value, opts)
        Done = true
    end)
end

HAT, SHIRT, NECK, BOOTS, PANTS, COAT = 1111, 2222, 3333, 4444, 5555, 6666
function giveCharacter(extra)
    local app = AppearanceSchema.default('male')
    app.clothing.equipped = { hats = HAT, shirts_full = SHIRT, neckwear = NECK, boots = BOOTS }
    app.clothing.states = {}
    for k, v in pairs(extra or {}) do app.clothing.equipped[k] = v end
    WCState.setCharacter(7, 'male')
    WCState.set(app)
end

-- every action node of a tree with the chain of its ancestors
function actionPaths(node, path, out)
    out = out or {}
    path = path or {}
    local here = {}
    for i, p in ipairs(path) do here[i] = p end
    here[#here + 1] = node
    if node.kind == 'action' then out[#out + 1] = here end
    for _, c in ipairs(node.children or {}) do actionPaths(c, here, out) end
    return out
end
function controlsOf(node, acc)
    acc = acc or {}
    if node.control then acc[#acc + 1] = node.control end
    for _, c in ipairs(node.children or {}) do controlsOf(c, acc) end
    return acc
end
'''


def make_states_client(setup=None):
    rt = make_client()
    rt.run(STATES_STUBS)
    if setup:
        rt.run(setup)
    rt.load('client/editor/tree.lua', 'client/editor/editor.lua', 'client/editor/panel.lua',
            'client/clothing/states.lua')
    rt.run('giveCharacter(); clearLog()')
    return rt


def lua_list(tbl):
    if tbl is None:
        return []
    return [tbl[i] for i in range(1, len(tbl) + 1)]
