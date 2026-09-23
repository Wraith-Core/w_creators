"""Shared stubs for the spawn / respawn client tests (test_client_spawn_*.py).

make_spawn_client() returns the client infrastructure runtime of test_client_infra_support (shared
layer, natives, core, appearance, camera, scene, preview environment on the recording fake of the
RedM client natives) plus:
  - death natives driven by Peds[h].dead / Peds[h].dying (IsEntityDead, IsPedDeadOrDying),
  - NetworkResurrectLocalPlayer (a new alive ped handle, or the same ped revived when
    ResurrectSameHandle; nothing comes alive while ResurrectStuck),
  - the ground probe GetGroundZAndNormalFor_3dCoord (Ground = {found, z} or a function),
  - HasCollisionLoadedAroundEntity driven by CollisionLoaded,
  - load-scene natives, w.prompt.createGroup (recorded groups in PromptGroups; Pressed[key] = true
    completes a prompt once), w.notify (Notified), exports(...) (Exported[name] = fn),
  - Appearance.RestorePlayer counted in RestoreCalls and Appearance.IsPlayerApplying driven by
    Applying,
then loads client/spawn/selector.lua, client/spawn/spawn.lua and client/respawn/respawn.lua.
This module has no tests of its own.
"""
from test_client_infra_support import make_client

SPAWN_STUBS = r'''
local function rec(op, ...) Log[#Log + 1] = { op = op, args = table.pack(...) } end

-- death -------------------------------------------------------------------------------------
function IsEntityDead(e) return Peds[e] ~= nil and Peds[e].dead == true end
function IsPedDeadOrDying(e) return Peds[e] ~= nil and (Peds[e].dead == true or Peds[e].dying == true) end
ResurrectSameHandle = false
ResurrectStuck = false
function NetworkResurrectLocalPlayer(x, y, z, h, a, b)
    rec('NetworkResurrectLocalPlayer', x, y, z, h, a, b)
    StateAtResurrect = WCRespawn and WCRespawn.state() or nil
    if ResurrectStuck then return end
    if ResurrectSameHandle then
        Peds[MyPed].dead = false; Peds[MyPed].dying = false
        Peds[MyPed].coords = vector3(x, y, z)
    else
        local model = Peds[MyPed] and Peds[MyPed].model
        local old = MyPed
        MyPed = makePed('mp_male', x, y, z, h)
        Peds[MyPed].model = model or GetHashKey('mp_male')
        Peds[old] = nil
    end
end

-- ground and collision -----------------------------------------------------------------------
Ground = { true, nil }   -- { found, z } (z nil = the probe's own z minus its height above)
Probes = {}
function GetGroundZAndNormalFor_3dCoord(x, y, z)
    Probes[#Probes + 1] = { x, y, z }
    if type(Ground) == 'function' then return Ground(x, y, z) end
    return Ground[1], Ground[2] or (z - 2.0), vector3(0, 0, 1)
end
CollisionLoaded = true
function HasCollisionLoadedAroundEntity() return CollisionLoaded end

-- misc natives --------------------------------------------------------------------------------
for _, name in ipairs({ 'NetworkSetEntityOnlyExistsForParticipants', 'LoadSceneStart', 'LoadSceneStop' }) do
    _ENV[name] = function(...) rec(name, ...) end
end
function IsLoadSceneLoaded() return true end
Pressed = {}
PromptGroups = {}
w.prompt = {
    createGroup = function(title, position)
        local g = { title = title, prompts = {}, deleted = false, visible = false }
        function g.addPrompt(key, label) g.prompts[#g.prompts + 1] = { key = key, label = label } end
        function g.setLabel(key, label) for _, p in ipairs(g.prompts) do if p.key == key then p.label = label end end end
        function g.setTitle(t) g.title = t end
        function g.display() g.visible = true end
        function g.hide() g.visible = false end
        function g.delete() g.deleted = true; rec('prompt.delete') end
        function g.isCompleted(key) if Pressed[key] then Pressed[key] = nil return true end return false end
        PromptGroups[#PromptGroups + 1] = g
        return g
    end,
}
Notified = {}
w.notify = function(data) Notified[#Notified + 1] = data end
Exported = {}
getmetatable(exports).__call = function(_, name, fn) Exported[name] = fn end

-- appearance ----------------------------------------------------------------------------------
Applying = false
RestoreCalls = 0
Appearance.IsPlayerApplying = function() return Applying end
Appearance.RestorePlayer = function(app, opts)
    RestoreCalls = RestoreCalls + 1
    rec('RestorePlayer')
    return true
end
WCState.setCharacter('c1', 'male')
WCState.set(AppearanceSchema.default('male'))

function hudShown() return indexOf('TriggerEvent:hud:client:showui') ~= nil end
function lastCoords() local p = Peds[MyPed].coords return { p.x, p.y, p.z } end
function callbacks(name)
    local out = {}
    for _, e in ipairs(Log) do if e.op == 'callback:' .. name then out[#out + 1] = e.args end end
    return out
end
function threadsAlive()
    local n = 0
    for _, t in ipairs(Threads) do if coroutine.status(t.co) == 'suspended' then n = n + 1 end end
    return n
end
'''


def make_spawn_client():
    rt = make_client()
    rt.run(SPAWN_STUBS)
    rt.load('client/spawn/selector.lua', 'client/spawn/spawn.lua', 'client/respawn/respawn.lua')
    return rt


def count(rt, op):
    return rt.eval('count(%r)' % op)


def spin(rt, total_ms, step_ms=50):
    """Advance the fake clock in steps so threads waiting with Wait(0) make progress."""
    for _ in range(max(1, total_ms // step_ms)):
        rt.g.tick(step_ms)
