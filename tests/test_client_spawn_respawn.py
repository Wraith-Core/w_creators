"""WCRespawn (client/respawn/respawn.lua): the ALIVE → DYING → DEAD → RESPAWN_PENDING → RESPAWNING →
ALIVE state machine, the Resurrect export (refused while in flight), the appearance restored once
after an external resurrect, the character-scene guard, and editors closed on death.

Run: python3 -m unittest discover -s tests -p 'test_client_spawn_*.py'
"""
import unittest

from test_client_spawn_support import make_spawn_client, count


class RespawnStateMachineTests(unittest.TestCase):
    def setUp(self):
        self.rt = make_spawn_client()
        self.rt.run('WCRespawn.reset(); clearLog()')

    def state(self):
        return self.rt.eval('WCRespawn.state()')

    def poll(self, n=1):
        for _ in range(n):
            self.rt.run('WCRespawn.poll()')

    def kill(self):
        self.rt.run('Peds[MyPed].dead = true')

    def test_full_cycle_through_every_state(self):
        self.assertEqual(self.state(), 'ALIVE')
        self.poll()
        self.assertEqual(self.state(), 'ALIVE')
        self.rt.run('Peds[MyPed].dying = true')
        self.poll()
        self.assertEqual(self.state(), 'DYING')
        self.rt.run('Peds[MyPed].dead = true')
        self.poll()
        self.assertEqual(self.state(), 'DEAD')
        self.poll(3)
        self.assertEqual(self.state(), 'DEAD')
        # Resurrect: RESPAWN_PENDING first (in flight), RESPAWNING when the native runs
        self.rt.run('Seen = {}; local orig = WCUtil.waitUntil; WCUtil.waitUntil = function(...) '
                    'Seen[#Seen + 1] = WCRespawn.state(); return orig(...) end')
        ok = self.rt.eval("Exported.Resurrect(vector3(10.0, 20.0, 30.0), 90.0, 'hospital')")
        self.assertTrue(ok)
        self.assertEqual(self.rt.eval('Seen[1]'), 'RESPAWN_PENDING')
        self.assertEqual(self.rt.eval('StateAtResurrect'), 'RESPAWNING')
        self.assertEqual(self.state(), 'ALIVE')
        self.assertEqual(self.rt.eval('RestoreCalls'), 1)
        self.assertFalse(self.rt.eval("WCState.busy('respawn')"))
        # the resurrect's ped is known: the watcher does not restore a second time
        self.poll(5)
        self.assertEqual(self.rt.eval('RestoreCalls'), 1)

    def test_resurrect_uses_the_native_wrapper_with_the_given_position(self):
        self.kill()
        self.poll(2)
        self.rt.eval("Exported.Resurrect({ x = 1.0, y = 2.0, z = 3.0 }, 45.0, 'hospital')")
        args = self.rt.eval("Log[indexOf('NetworkResurrectLocalPlayer')].args")
        self.assertEqual([args[1], args[2], args[3], args[4]], [1.0, 2.0, 3.0, 45.0])

    def test_recovering_while_dying_goes_back_to_alive(self):
        self.rt.run('Peds[MyPed].dying = true')
        self.poll()
        self.assertEqual(self.state(), 'DYING')
        self.rt.run('Peds[MyPed].dying = false')
        self.poll()
        self.assertEqual(self.state(), 'ALIVE')

    def test_second_resurrect_is_refused_while_the_first_runs(self):
        self.kill()
        self.poll(2)
        self.rt.run('ResurrectStuck = true')
        self.rt.run("CreateThread(function() First = WCRespawn.resurrect(vector3(0, 0, 0), 0.0, 'a') end)")
        self.rt.g.tick(10)
        self.assertEqual(self.state(), 'RESPAWNING')
        self.assertFalse(self.rt.eval("Exported.Resurrect(vector3(0, 0, 0), 0.0, 'b')"))
        self.assertEqual(count(self.rt, 'NetworkResurrectLocalPlayer'), 1)
        # the stuck one times out: false, state settles from the ped, lock released
        for _ in range(60):
            self.rt.g.tick(250)
        self.assertIs(self.rt.eval('First'), False)
        self.assertEqual(self.state(), 'DEAD')
        self.assertFalse(self.rt.eval("WCState.busy('respawn')"))
        # and a new one is accepted afterwards
        self.rt.run('ResurrectStuck = false')
        self.assertTrue(self.rt.eval("Exported.Resurrect(vector3(0, 0, 0), 0.0, 'c')"))

    def test_resurrect_refused_while_the_respawn_lock_is_held(self):
        self.rt.run("WCState.busy('respawn', true)")
        self.assertFalse(self.rt.eval("WCRespawn.resurrect(vector3(0, 0, 0), 0.0, 'x')"))
        self.assertEqual(count(self.rt, 'NetworkResurrectLocalPlayer'), 0)

    def test_invalid_coordinates_are_refused(self):
        self.assertFalse(self.rt.eval("WCRespawn.resurrect({ x = 0/0, y = 1, z = 1 }, 0.0, 'x')"))
        self.assertEqual(count(self.rt, 'NetworkResurrectLocalPlayer'), 0)
        self.assertFalse(self.rt.eval("WCState.busy('respawn')"))

    def test_resurrect_waits_for_an_appearance_render_in_flight(self):
        self.kill()
        self.poll(2)
        self.rt.run('Applying = true')
        self.rt.run("CreateThread(function() Done = WCRespawn.resurrect(vector3(0, 0, 0), 0.0, 'h') end)")
        self.rt.g.tick(200)
        self.assertEqual(self.state(), 'RESPAWN_PENDING')
        self.assertEqual(count(self.rt, 'NetworkResurrectLocalPlayer'), 0)
        self.rt.run('Applying = false')
        for _ in range(5):
            self.rt.g.tick(100)
        self.assertTrue(self.rt.eval('Done'))
        self.assertEqual(count(self.rt, 'NetworkResurrectLocalPlayer'), 1)

    def test_no_appearance_restore_when_disabled(self):
        for setup in ('Config.Respawn.restoreAppearance = false',
                      'Config.Services.deathRespawn = false'):
            rt = make_spawn_client()
            rt.run('WCRespawn.reset()')
            rt.run(setup)
            rt.run('Peds[MyPed].dead = true; WCRespawn.poll(); WCRespawn.poll()')
            self.assertTrue(rt.eval("WCRespawn.resurrect(vector3(0, 0, 0), 0.0, 'h')"), setup)
            self.assertEqual(rt.eval('RestoreCalls'), 0, setup)

    def test_resurrect_never_touches_weapons_or_inventory(self):
        self.kill()
        self.poll(2)
        self.rt.eval("WCRespawn.resurrect(vector3(0, 0, 0), 0.0, 'h')")
        ops = list(self.rt.eval('ops()').values())
        self.assertFalse([o for o in ops if 'Weapon' in o or 'inventory' in o.lower() or o == 'giveWeapon'])


class ExternalResurrectTests(unittest.TestCase):
    def setUp(self):
        self.rt = make_spawn_client()
        self.rt.run('WCRespawn.reset(); clearLog()')

    def poll(self, n=1):
        for _ in range(n):
            self.rt.run('WCRespawn.poll()')

    def test_appearance_restored_once_after_an_external_resurrect_with_a_new_handle(self):
        self.rt.run('Peds[MyPed].dead = true')
        self.poll(2)
        self.assertEqual(self.rt.eval('WCRespawn.state()'), 'DEAD')
        # another resource resurrects the player (new ped handle)
        self.rt.run('NetworkResurrectLocalPlayer(5.0, 5.0, 5.0, 0.0, true, false)')
        self.poll(10)
        self.assertEqual(self.rt.eval('RestoreCalls'), 1)
        self.assertEqual(self.rt.eval('WCRespawn.state()'), 'ALIVE')

    def test_appearance_restored_once_after_dead_to_alive_on_the_same_handle(self):
        self.rt.run('Peds[MyPed].dead = true')
        self.poll(2)
        self.rt.run('Peds[MyPed].dead = false')
        self.poll(10)
        self.assertEqual(self.rt.eval('RestoreCalls'), 1)

    def test_handle_change_while_alive_restores_once(self):
        self.poll()
        self.rt.run("local old = MyPed; MyPed = makePed('mp_male'); Peds[old] = nil")
        self.poll(6)
        self.assertEqual(self.rt.eval('RestoreCalls'), 1)

    def test_a_non_mp_model_chosen_by_another_resource_is_left_alone(self):
        self.poll()
        self.rt.run("local old = MyPed; MyPed = makePed('a_c_horse_01'); Peds[old] = nil")
        self.poll(4)
        self.assertEqual(self.rt.eval('RestoreCalls'), 0)

    def test_handle_change_during_our_own_render_is_not_an_external_respawn(self):
        self.poll()
        self.rt.run("Applying = true; local old = MyPed; MyPed = makePed('mp_male'); Peds[old] = nil")
        self.poll(2)
        self.rt.run('Applying = false')
        self.poll(3)
        self.assertEqual(self.rt.eval('RestoreCalls'), 0)

    def test_transitions_are_ignored_in_the_character_scene(self):
        self.rt.run('CreatorScene.isLoaded = function() return true end')
        self.rt.run('Peds[MyPed].dead = true')
        self.poll(3)
        self.assertEqual(self.rt.eval('WCRespawn.state()'), 'ALIVE')
        self.rt.run("local old = MyPed; MyPed = makePed('mp_female'); Peds[old] = nil")
        self.poll(3)
        self.assertEqual(self.rt.eval('RestoreCalls'), 0)
        # leaving the scene: the handle seen in the scene is not a respawn
        self.rt.run('CreatorScene.isLoaded = function() return false end')
        self.poll(3)
        self.assertEqual(self.rt.eval('RestoreCalls'), 0)

    def test_transitions_are_ignored_during_the_selection_and_the_creator(self):
        self.rt.run("WCState.busy('selection', true)")
        self.rt.run('Peds[MyPed].dead = true')
        self.poll(2)
        self.assertEqual(self.rt.eval('WCRespawn.state()'), 'ALIVE')
        self.rt.run("WCState.busy('selection', false); Peds[MyPed].dead = false")
        self.rt.run("WCEditor = { session = function() return { id = 1, mode = 'creator' } end, "
                    "action = function() Cancelled = true end, isOpen = function() return true end }")
        self.rt.run('Peds[MyPed].dead = true')
        self.poll(2)
        self.assertEqual(self.rt.eval('WCRespawn.state()'), 'ALIVE')
        self.assertIsNone(self.rt.eval('Cancelled'))


class DeathClosesEditorsTests(unittest.TestCase):
    def setUp(self):
        self.rt = make_spawn_client()
        self.rt.run('WCRespawn.reset(); clearLog()')
        self.rt.run('''
            Session = { id = 7, mode = 'store' }
            Actions = {}
            CancelBusy = false
            WCEditor = {
                session = function() return Session end,
                isOpen = function() return Session ~= nil end,
                action = function(data)
                    Actions[#Actions + 1] = data
                    if CancelBusy then return { ok = false, code = 'BUSY' } end
                    if data.op == 'cancel' then Session = nil end
                    return { ok = true }
                end,
            }
            PanelOpen = true
            WCPanel = { isOpen = function() return PanelOpen end, close = function() PanelOpen = false; PanelClosed = true end }
        ''')

    def test_death_cancels_the_editor_through_its_cancel_path_and_closes_the_panel(self):
        self.rt.run('Peds[MyPed].dead = true; WCRespawn.poll()')
        self.assertEqual(self.rt.eval('WCRespawn.state()'), 'DYING')
        self.assertEqual(self.rt.eval('Actions[1].op'), 'cancel')
        self.assertEqual(self.rt.eval('Actions[1].id'), 7)
        self.assertIsNone(self.rt.eval('Session'))
        self.assertTrue(self.rt.eval('PanelClosed'))

    def test_a_busy_editor_is_cancelled_on_a_later_poll(self):
        self.rt.run('CancelBusy = true; Peds[MyPed].dead = true; WCRespawn.poll()')
        self.assertIsNotNone(self.rt.eval('Session'))
        self.rt.run('CancelBusy = false; WCRespawn.poll()')
        self.assertIsNone(self.rt.eval('Session'))
        self.assertEqual(self.rt.eval('#Actions'), 2)
        self.assertEqual(self.rt.eval('WCRespawn.state()'), 'DEAD')

    def test_the_poll_thread_runs_at_the_configured_interval(self):
        self.rt.run('Peds[MyPed].dead = true')
        self.rt.g.tick(self.rt.eval('Config.Respawn.pollMs') - 1)
        self.assertEqual(self.rt.eval('WCRespawn.state()'), 'ALIVE')
        self.rt.g.tick(1)
        self.assertEqual(self.rt.eval('WCRespawn.state()'), 'DYING')


class AmbulanceRoutingTests(unittest.TestCase):
    """w_ambulancejob/client/main.lua routes its resurrects through exports.w_creators:Resurrect."""

    def source(self):
        from harness import RESOURCE, read
        path = RESOURCE.parent / 'w_ambulancejob' / 'client' / 'main.lua'
        if not path.exists():
            self.skipTest('w_ambulancejob not checked out')
        return read(path)

    def helper(self, started, export_fails=False):
        import re
        from lupa.lua54 import LuaRuntime
        code = self.source()
        m = re.search(r'local function resurrect\(pos, heading\).*?\nend\n', code, re.S)
        self.assertIsNotNone(m)
        lua = LuaRuntime(unpack_returned_tuples=True)
        lua.execute('''
            Calls = {}
            -- the helper's file-level locals and the CitizenFX scheduler (the export answers at
            -- once here, so its thread runs to completion inside CreateThread)
            reviving, RESURRECT_WAIT_MS = 0, 45000
            function CreateThread(fn) fn() end
            function Wait() end
            function GetGameTimer() return 0 end
            function GetResourceState(name) return STATE end
            function NetworkResurrectLocalPlayer(x, y, z, h, a, b) Calls[#Calls + 1] = { 'native', x, y, z, h } end
            exports = { w_creators = setmetatable({}, { __index = function(_, name)
                if FAIL then error('No such export') end
                return function(self, pos, heading, reason) Calls[#Calls + 1] = { name, pos.x, heading, reason } return true end
            end }) }
        ''')
        lua.globals().STATE = 'started' if started else 'stopped'
        lua.globals().FAIL = export_fails
        lua.execute(m.group(0) + '\nresurrect({ x = 1.0, y = 2.0, z = 3.0 }, 90.0)')
        calls = lua.globals().Calls
        return [calls[i][1] for i in range(1, len(calls) + 1)], calls

    def test_only_the_helper_calls_the_native(self):
        code = self.source()
        self.assertEqual(code.count('NetworkResurrectLocalPlayer('), 1)
        self.assertEqual(code.count('resurrect(pos, GetEntityHeading(player))'), 2)

    def test_started_w_creators_gets_the_export(self):
        names, calls = self.helper(True)
        self.assertEqual(names, ['Resurrect'])
        self.assertEqual(calls[1][4], 'hospital')

    def test_stopped_w_creators_falls_back_to_the_native(self):
        names, _ = self.helper(False)
        self.assertEqual(names, ['native'])

    def test_a_missing_export_falls_back_to_the_native(self):
        names, _ = self.helper(True, export_fails=True)
        self.assertEqual(names, ['native'])


if __name__ == '__main__':
    unittest.main()
