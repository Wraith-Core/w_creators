"""Review round 1, area "ambulance": w_medic's integration hooks, loaded for real
(config.lua, client/main.lua, client/laststand.lua, client/dead.lua, client/job.lua) over the
harness stubs plus a catch-all for the game natives.

1. The resurrect helper never blocks on exports.w_creators:Resurrect: a w_creators stop or
   restart in the middle of the call (its runtime is gone, the async return value is never
   settled) no longer leaves SetBedCam / the revive hanging; a player still down gets the native.
2. The hospital's cosmetic surgery prompt follows w_creators' published clinic availability
   (GlobalState['w_creators:clinics']): a disabled or closed clinic has no prompt.
3. While a revive is resurrecting the player (the export yields through the appearance
   restore) the respawn key, the help key and the last stand countdown stand still.
"""
import unittest

from harness import Runtime
from test_client_services_ambulance import CLIENT_STUBS, WCORE_STUBS, ambulance_source

NATIVES = r'''
function IsDuplicityVersion() return false end
Natives = {}; NativeReturns = {}
NotNatives = { Laststand = true, LaststandTime = true, InLaststand = true }
-- any other capitalised global a script reads is a game native: recorded, typed default answer
setmetatable(_G, { __index = function(_, k)
    if type(k) ~= 'string' or not k:match('^%u') or NotNatives[k] then return nil end
    return function(...)
        Natives[#Natives + 1] = { k, ... }
        local r = NativeReturns[k]
        if type(r) == 'function' then return r(...) end
        if r ~= nil then return r end
        if k:match('^Is') or k:match('^Does') or k:match('^Has') or k:match('^Network') then return false end
        return 0
    end
end })
function called(name)
    local n = 0
    for _, c in ipairs(Natives) do if c[1] == name then n = n + 1 end end
    return n
end

PedDead = false
NativeReturns.IsEntityDead = function() return PedDead end
NativeReturns.IsPedDeadOrDying = function() return PedDead end
NativeReturns.IsScreenFadedOut = true
NativeReturns.NetworkIsPlayerActive = false -- dead.lua's death watcher stays out of these scenarios
NativeReturns.NetworkGetPlayerIndexFromPed = -1
NativeReturns.GetPlayerName = 'Player'
Citizen.InvokeNative = function() end
WCore.Shared = { GetWeapon = function() return nil end }
LocalPlayer = { state = { set = function() end } }
NativeReturns.NetworkResurrectLocalPlayer = function() PedDead = false end
GetEntityCoords = function() return vector3(1.0, 2.0, 3.0) end
NativeReturns.GetEntityHeading = 90.0
NativeReturns.GetEntityMaxHealth = 200
NativeReturns.PlayerPedId = 1
DoesEntityExist = function() return true end -- (the harness stub knows only its own peds)

w.blip = { create = function() return 1 end }
w.requestAnimDict = function() end
w.progressBar = function() return true end
Groups = {}
w.prompt = w.prompt or {}
w.prompt.createGroup = function(title, position)
    local g = { id = 'group' .. (#Groups + 1), title = title, visible = {}, enabled = {}, shown = false }
    function g.addPrompt(key, label, hold) g.visible[key] = true; g.enabled[key] = true end
    function g.display() g.shown = true end
    function g.hide() g.shown = false end
    function g.isVisible() return g.shown end
    function g.delete() g.deleted = true end
    function g.setTitle(t) g.title = t end
    function g.setVisible(k, v) g.visible[k] = v end
    function g.setEnabled(k, v) g.enabled[k] = v end
    function g.setLabel() end
    Groups[#Groups + 1] = g
    return g
end
function deathGroup() for i = #Groups, 1, -1 do if not Groups[i].deleted then return Groups[i] end end end

-- exports.w_creators:Resurrect, scripted per test
ResurrectCalls = 0
ResurrectMode = 'ok'            -- ok | hang | false | error | alive_then_hang
ResurrectMs = 2000              -- how long an 'ok' resurrect takes (the appearance restore)
exports.w_creators.Resurrect = function(_, pos, heading, reason)
    ResurrectCalls = ResurrectCalls + 1
    if ResurrectMode == 'error' then error('No such export Resurrect in resource w_creators') end
    if ResurrectMode == 'false' then return false end
    if ResurrectMode == 'hang' then Wait(1e12) end                 -- w_creators torn down: never answers
    PedDead = false                                                -- its native
    if ResurrectMode == 'alive_then_hang' then Wait(1e12) end
    Wait(ResurrectMs)                                              -- restoreAppearance
    return true
end
RespawnRequests = 0
AddEventHandler('hospital:client:RespawnAtHospital', function() RespawnRequests = RespawnRequests + 1 end)
function spawnEvent(name, ...)
    local args = table.pack(...)
    CreateThread(function() fireEvent(name, nil, table.unpack(args, 1, args.n)) end)
end
'''


def ambulance_runtime():
    rt = Runtime()
    rt.run(WCORE_STUBS)
    rt.run(NATIVES)
    for rel in ('config.lua', 'client/main.lua', 'client/laststand.lua', 'client/dead.lua'):
        rt.lua.execute(ambulance_source(rel), name='@w_medic/' + rel)
    return rt


def advance(rt, ms, step=50):
    """Let ms of game time pass in steps (tick() resumes each due thread once per call)."""
    for _ in range(int(ms // step)):
        rt.g.tick(step)


BED = "{ coords = vector4(10.0, 20.0, 30.0, 45.0), model = 1 }"


class ResurrectDoesNotHangTests(unittest.TestCase):
    """Defect 1: a w_creators stop during exports.w_creators:Resurrect."""

    def setUp(self):
        self.rt = ambulance_runtime()
        self.run, self.eval = self.rt.run, self.rt.eval
        self.run('isDead = true; deathTime = 0; PedDead = true')

    def bed_placed(self):
        return self.eval('called("SetEntityCoords")') > 0

    def test_w_creators_stopping_mid_call_does_not_hang_the_hospital_bed(self):
        self.run('ResurrectMode = "hang"')
        self.run('spawnEvent("hospital:client:SendToBed", 1, %s, true)' % BED)
        advance(self.rt, 1000)
        self.assertEqual(self.eval('ResurrectCalls'), 1)
        self.assertTrue(self.eval('isReviving'))
        self.assertFalse(self.bed_placed())
        # w_creators stops (or restarts): its call will never answer
        self.run('ResourceStates.w_creators = "stopped"')
        advance(self.rt, 100)
        self.assertEqual(self.eval('called("NetworkResurrectLocalPlayer")'), 1)
        self.assertFalse(self.eval('PedDead'))
        self.assertFalse(self.eval('isReviving'))
        self.assertTrue(self.bed_placed())
        # the heal timer still runs and ends the downed state
        advance(self.rt, self.eval('Config.AIHealTimer') * 1000 + 2000)
        self.assertFalse(self.eval('isDead'))

    def test_w_creators_stopping_after_its_native_does_not_resurrect_twice(self):
        self.run('ResurrectMode = "alive_then_hang"')
        self.run('spawnEvent("hospital:client:SendToBed", 1, %s, true)' % BED)
        advance(self.rt, 500)
        self.run('ResourceStates.w_creators = "stopped"')
        advance(self.rt, 100)
        self.assertEqual(self.eval('called("NetworkResurrectLocalPlayer")'), 0)
        self.assertTrue(self.bed_placed())

    def test_a_call_that_never_answers_is_bounded(self):
        self.run('ResurrectMode = "hang"')
        self.run('spawnEvent("hospital:client:Revive")')
        advance(self.rt, 10000)
        self.assertTrue(self.eval('isDead'))
        advance(self.rt, 40000)
        self.assertEqual(self.eval('called("NetworkResurrectLocalPlayer")'), 1)
        self.assertFalse(self.eval('isDead'))
        self.assertFalse(self.eval('isReviving'))

    def test_a_normal_resurrect_uses_only_the_export(self):
        self.run('spawnEvent("hospital:client:SendToBed", 1, %s, true)' % BED)
        advance(self.rt, 100)
        self.assertFalse(self.bed_placed())            # waits for the appearance restore
        advance(self.rt, 3000)
        self.assertTrue(self.bed_placed())
        self.assertEqual(self.eval('ResurrectCalls'), 1)
        self.assertEqual(self.eval('called("NetworkResurrectLocalPlayer")'), 0)

    def test_a_missing_export_falls_back_to_the_native(self):
        self.run('ResurrectMode = "error"')
        self.run('spawnEvent("hospital:client:Revive")')
        advance(self.rt, 100)
        self.assertEqual(self.eval('called("NetworkResurrectLocalPlayer")'), 1)
        self.assertFalse(self.eval('isDead'))

    def test_a_refused_resurrect_is_not_raced_by_the_native(self):
        # false = another resurrect is in flight (it finishes the job) or w_creators already tried
        self.run('ResurrectMode = "false"')
        self.run('spawnEvent("hospital:client:Revive")')
        advance(self.rt, 100)
        self.assertEqual(self.eval('called("NetworkResurrectLocalPlayer")'), 0)
        self.assertFalse(self.eval('isReviving'))

    def test_stopped_w_creators_uses_the_native_at_once(self):
        self.run('ResourceStates.w_creators = "stopped"')
        self.run('spawnEvent("hospital:client:Revive")')
        self.assertEqual(self.eval('ResurrectCalls'), 0)
        self.assertEqual(self.eval('called("NetworkResurrectLocalPlayer")'), 1)
        self.assertFalse(self.eval('isDead'))


class ReviveKeepsThePromptOffTests(unittest.TestCase):
    """Defect 3: the downed state stays set while the export restores the appearance; nothing may
    act on it meanwhile (respawn key, help key, the last stand countdown)."""

    def setUp(self):
        self.rt = ambulance_runtime()
        self.run, self.eval = self.rt.run, self.rt.eval
        self.run('ResurrectMs = 3000')

    def test_the_respawn_key_is_off_and_ignored_during_a_revive(self):
        self.run('isDead = true; deathTime = 0; PedDead = true')
        advance(self.rt, 1000)
        self.assertTrue(self.eval('deathGroup().enabled.J'))
        self.run('spawnEvent("hospital:client:Revive")')
        advance(self.rt, 500)
        self.assertTrue(self.eval('isDead'))           # still resurrecting
        self.assertFalse(self.eval('deathGroup().enabled.J'))
        self.run('fireEvent("w_lib:promptCompleted", nil, deathGroup().id, "J")')
        self.assertEqual(self.eval('RespawnRequests'), 0)
        advance(self.rt, 3000)
        self.assertFalse(self.eval('isDead'))
        self.assertEqual(self.eval('RespawnRequests'), 0)

    def test_the_last_stand_does_not_bleed_out_during_a_revive(self):
        # w_medic starts the countdown full (Laststand.ReviveInterval), so the test shortens that
        self.run('Laststand.ReviveInterval = 3; PedDead = true')
        self.run('CreateThread(function() SetLaststand(true) end)')
        advance(self.rt, 1000)                         # SetLaststand's own 1 s wait
        self.assertTrue(self.eval('InLaststand'))
        self.assertEqual(self.eval('LaststandTime'), 2)  # the countdown runs: 2 s to bleed out
        self.run('spawnEvent("hospital:client:Revive")')
        advance(self.rt, 2500)
        self.assertFalse(self.eval('isDead'))          # no OnDeath while being revived
        self.assertTrue(self.eval('InLaststand'))
        self.run('fireEvent("w_lib:promptCompleted", nil, deathGroup().id, "G")')
        advance(self.rt, 1000)
        self.assertFalse(self.eval('InLaststand'))
        self.assertFalse(self.eval('isDead'))
        self.assertFalse(self.eval('isReviving'))

    def test_the_key_comes_back_when_the_revive_ends(self):
        self.run('isDead = true; deathTime = 0; PedDead = true')
        advance(self.rt, 1000)
        self.assertTrue(self.eval('deathGroup().enabled.J'))
        self.run('CreateThread(function() isReviving = true; Wait(600); isReviving = false end)')
        advance(self.rt, 300)
        self.assertFalse(self.eval('deathGroup().enabled.J'))
        advance(self.rt, 600)
        self.assertTrue(self.eval('deathGroup().enabled.J'))


class SurgeryPromptAvailabilityTests(unittest.TestCase):
    """Defect 2: the clinic prompt follows GlobalState['w_creators:clinics']."""

    def setUp(self):
        self.rt = rt = Runtime()
        rt.run(WCORE_STUBS)
        rt.run(CLIENT_STUBS)
        for rel in ('config.lua', 'client/job.lua'):
            rt.lua.execute(ambulance_source(rel), name='@w_medic/' + rel)
        rt.run('Label = locale("prompt.cosmetic_surgery"); createAmbuPrompts()')

    def can(self, clinic_id):
        return self.rt.eval('''(function()
            for _, p in ipairs(surgeryPrompts()) do
                if p.opts.coords.x == (function()
                    for _, c in ipairs(Config.CosmeticSurgery.clinics) do
                        if c.clinicId == %r then return c.coords.x end
                    end
                end)() then return p.opts.canInteract() end
            end
        end)()''' % clinic_id)

    def test_nothing_published_leaves_the_decision_to_the_server(self):
        self.rt.run('GlobalState = nil')
        self.assertTrue(self.can('valentine_surgery'))
        self.rt.run('GlobalState = {}')
        self.assertTrue(self.can('valentine_surgery'))

    def test_only_published_clinics_have_a_prompt(self):
        self.rt.run('GlobalState = { ["w_creators:clinics"] = { valentine_surgery = true } }')
        self.assertTrue(self.can('valentine_surgery'))
        self.assertFalse(self.can('saintdenis_surgery'))
        self.assertFalse(self.can('armadillo_surgery'))

    def test_a_disabled_service_hides_every_clinic(self):
        self.rt.run('GlobalState = { ["w_creators:clinics"] = {} }')
        for cid in ('valentine_surgery', 'saintdenis_surgery', 'armadillo_surgery'):
            self.assertFalse(self.can(cid), cid)

    def test_upright_and_started_are_still_required(self):
        self.rt.run('GlobalState = { ["w_creators:clinics"] = { valentine_surgery = true } }')
        self.rt.run('isDead = true')
        self.assertFalse(self.can('valentine_surgery'))
        self.rt.run('isDead = false; ResourceStates.w_creators = "stopped"')
        self.assertFalse(self.can('valentine_surgery'))


if __name__ == '__main__':
    unittest.main()
