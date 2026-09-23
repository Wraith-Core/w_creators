"""Regression tests of the spawn / respawn review findings (client/spawn/spawn.lua,
client/spawn/selector.lua, client/respawn/respawn.lua):

  - an admin respawn during a barber seat visit waits for the seat to put the player back first
    (the seat's own thread would otherwise undo the move); a flow that never ends aborts the
    respawn without moving the player; a flow still opening is aborted through WCServiceFlow;
  - a respawn of a dead player revives through the death system when it runs (w_ambulancejob's
    hospital:client:Revive, which clears its own dead state), with a fallback to WCRespawn when that
    revive does not start; a successful resurrect fires w_creators:client:resurrected;
  - an admin respawn during the first-spawn wagon ride stops the cutscene.

Run: cd /home/user/w_creators && python3 -m unittest discover -s tests -p 'test_client_spawn_*.py'
"""
import unittest

from test_client_spawn_support import make_spawn_client, count, spin
from test_client_services_support import make_services, settle as settle_services
from test_client_characters_support import make_characters, settle as settle_characters

SPAWN_FILES = ('client/spawn/selector.lua', 'client/spawn/spawn.lua', 'client/respawn/respawn.lua')

# The natives the spawn files need on top of the services / characters runtimes.
EXTRA_NATIVES = r'''
IsEntityDead = IsEntityDead or function(e) return Peds[e] ~= nil and Peds[e].dead == true end
function IsPedDeadOrDying(e) return Peds[e] ~= nil and Peds[e].dead == true end
function GetGroundZAndNormalFor_3dCoord(x, y, z) return true, z - 2.0, vector3(0, 0, 1) end
Moves = {}
local setCoords = SetEntityCoords
SetEntityCoords = function(e, x, y, z, ...)
    Moves[#Moves + 1] = { x, y, z }
    return setCoords(e, x, y, z, ...)
end
'''

ADMIN_RESPAWN = ("fireEvent('w_creators:client:respawn', nil, { x = 500.0, y = 600.0, z = 70.0, heading = 10.0 }, "
                 "{ kind = 'admin', point = 'valentine' })")


def coords(rt):
    c = rt.eval('Peds[MyPed].coords')
    return (c.x, c.y, c.z)


class RespawnDuringServiceVisitTests(unittest.TestCase):
    def setUp(self):
        self.rt = make_services('setPreview("valentine_barber", 11.0, 22.0, 33.0, 180.0)')
        self.rt.run(EXTRA_NATIVES)
        self.rt.load(*SPAWN_FILES)
        self.rt.run('CallbackResults = { ["w_creators:barber:open"] = barberData() }')
        self.rt.run('R = table.pack(WCBarber.open("valentine_barber"))')
        self.assertTrue(self.rt.eval('R[1]'))
        self.assertTrue(self.rt.eval('WCServiceSeat.active()'))
        self.assertEqual(coords(self.rt), (11.0, 22.0, 33.0))

    def test_admin_respawn_lands_after_the_seat_put_the_player_back(self):
        self.rt.run('Moves = {}')
        self.rt.run(ADMIN_RESPAWN)
        settle_services(self.rt, 300, 40)
        self.assertEqual(coords(self.rt), (500.0, 600.0, 70.0))
        self.assertFalse(self.rt.eval('WCServiceSeat.active()'))
        self.assertIsNone(self.rt.eval('WCServiceFlow.current()'))
        self.assertFalse(self.rt.eval('WCEditor.isOpen()'))
        self.assertFalse(self.rt.eval('WCSpawn.busy()'))
        self.assertFalse(self.rt.eval("WCState.busy('spawn')"))
        # the last move is the respawn's: nothing moved the player after it
        last = self.rt.eval('Moves[#Moves]')
        self.assertEqual((last[1], last[2], last[3]), (500.0, 600.0, 70.0))


class RespawnFlowWaitTests(unittest.TestCase):
    """A fake WCServiceFlow on the plain spawn runtime: the wait, the retry and the abort."""

    def setUp(self):
        self.rt = make_spawn_client()
        self.rt.run('''
            WCRespawn.reset(); clearLog()
            FakeFlow = { kind = 'store', committed = false, finished = false }
            Aborts = 0
            WCServiceFlow = {
                current = function() if FakeFlow.finished then return nil end return FakeFlow end,
                abort = function(flow, reason) Aborts = Aborts + 1; AbortReason = reason; return false end,
            }
        ''')

    def respawn(self):
        self.rt.run("fireEvent('w_creators:client:respawn', nil, { x = 5.0, y = 6.0, z = 7.0, heading = 10.0 }, "
                    "{ kind = 'admin', point = 'valentine' })")

    def test_waits_for_the_flow_to_end_and_retries_the_cancel(self):
        start = coords(self.rt)
        self.respawn()
        spin(self.rt, 2000, 100)
        self.assertEqual(coords(self.rt), start)          # not moved while the flow runs
        self.assertTrue(self.rt.eval('WCSpawn.busy()'))
        self.assertGreater(self.rt.eval('Aborts'), 1)       # retried while it does not end
        self.assertEqual(self.rt.eval('AbortReason'), 'respawn')
        self.rt.run('FakeFlow.finished = true')
        spin(self.rt, 1000, 100)
        self.assertEqual(coords(self.rt)[:2], (5.0, 6.0))
        self.assertFalse(self.rt.eval('WCSpawn.busy()'))

    def test_a_committed_flow_is_not_aborted_but_waited_for(self):
        self.rt.run('FakeFlow.committed = true')
        self.respawn()
        spin(self.rt, 1000, 100)
        self.assertEqual(self.rt.eval('Aborts'), 0)
        self.rt.run('FakeFlow.finished = true')
        spin(self.rt, 1000, 100)
        self.assertEqual(coords(self.rt)[:2], (5.0, 6.0))

    def test_a_flow_that_never_ends_aborts_the_respawn_without_moving(self):
        start = coords(self.rt)
        self.respawn()
        spin(self.rt, 16000, 500)
        self.assertEqual(coords(self.rt), start)
        self.assertFalse(self.rt.eval('WCSpawn.busy()'))
        self.assertFalse(self.rt.eval("WCState.busy('spawn')"))
        self.assertIsNone(self.rt.eval("indexOf('DoScreenFadeOut')"))  # never darkened
        self.assertFalse(self.rt.eval('Peds[MyPed].frozen'))

    def test_no_flow_no_wait(self):
        self.rt.run('FakeFlow.finished = true')
        self.respawn()
        spin(self.rt, 1000)
        self.assertEqual(coords(self.rt)[:2], (5.0, 6.0))
        self.assertEqual(self.rt.eval('Aborts'), 0)


class DeathOwnerReviveTests(unittest.TestCase):
    def setUp(self):
        self.rt = make_spawn_client()
        self.rt.run('''
            WCRespawn.reset(); clearLog()
            ReviveEvents = 0
            AmbulanceDead = true
            Resurrected = {}
            AddEventHandler('w_creators:client:resurrected', function(reason) Resurrected[#Resurrected + 1] = reason end)
            -- w_ambulancejob's revive: resurrects through the export only when it knows the player is down
            AddEventHandler('hospital:client:Revive', function()
                ReviveEvents = ReviveEvents + 1
                if AmbulanceDead then
                    local p = GetEntityCoords(PlayerPedId())
                    Exported.Resurrect(p, 0.0, 'hospital')
                    AmbulanceDead = false
                end
            end)
        ''')

    def kill(self):
        self.rt.run('Peds[MyPed].dead = true; WCRespawn.poll(); WCRespawn.poll()')

    def respawn(self, kind='admin', ms=6000):
        self.rt.run("fireEvent('w_creators:client:respawn', nil, { x = 5.0, y = 6.0, z = 7.0, heading = 10.0 }, "
                    "{ kind = %r, point = 'valentine' })" % kind)
        spin(self.rt, ms, 100)

    def test_dead_player_is_revived_by_the_running_death_system(self):
        self.rt.run("ResourceStates['w_ambulancejob'] = 'started'")
        self.kill()
        self.respawn()
        self.assertEqual(self.rt.eval('ReviveEvents'), 1)
        self.assertFalse(self.rt.eval('AmbulanceDead'))       # its own dead state was cleared
        self.assertEqual(count(self.rt, 'NetworkResurrectLocalPlayer'), 1)
        self.assertEqual(self.rt.eval("NetworkResurrectLocalPlayer and Resurrected[1]"), 'hospital')
        self.assertEqual(coords(self.rt)[:2], (5.0, 6.0))
        self.assertLess(self.rt.eval("indexOf('NetworkResurrectLocalPlayer')"),
                        self.rt.eval("indexOf('SetEntityCoords', indexOf('NetworkResurrectLocalPlayer'))"))
        self.assertEqual(self.rt.eval('WCRespawn.state()'), 'ALIVE')

    def test_a_revive_that_does_not_start_falls_back_to_the_service(self):
        self.rt.run("ResourceStates['w_ambulancejob'] = 'started'; AmbulanceDead = false")
        self.kill()
        self.respawn()
        self.assertEqual(self.rt.eval('ReviveEvents'), 1)
        self.assertEqual(count(self.rt, 'NetworkResurrectLocalPlayer'), 1)
        self.assertEqual(self.rt.eval('Resurrected[1]'), 'admin')
        self.assertEqual(coords(self.rt)[:2], (5.0, 6.0))
        self.assertFalse(self.rt.eval('IsEntityDead(MyPed)'))

    def test_without_the_death_system_the_service_resurrects_and_announces_it(self):
        self.kill()
        self.respawn()
        self.assertEqual(self.rt.eval('ReviveEvents'), 0)
        self.assertEqual(count(self.rt, 'NetworkResurrectLocalPlayer'), 1)
        self.assertEqual(self.rt.eval('Resurrected[1]'), 'admin')
        self.assertEqual(self.rt.eval('#Resurrected'), 1)

    def test_death_kind_revives_a_living_player_through_the_death_system(self):
        # last stand is alive for the natives: kind 'death' still clears the death system's state
        self.rt.run("ResourceStates['w_ambulancejob'] = 'started'")
        self.respawn(kind='death', ms=2000)
        self.assertEqual(self.rt.eval('ReviveEvents'), 1)
        self.assertEqual(coords(self.rt)[:2], (5.0, 6.0))

    def test_admin_respawn_of_a_living_player_does_not_revive(self):
        self.rt.run("ResourceStates['w_ambulancejob'] = 'started'")
        self.respawn(ms=2000)
        self.assertEqual(self.rt.eval('ReviveEvents'), 0)
        self.assertEqual(count(self.rt, 'NetworkResurrectLocalPlayer'), 0)
        self.assertEqual(self.rt.eval('#Resurrected'), 0)

    def test_a_failed_resurrect_is_not_announced(self):
        self.rt.run('ResurrectStuck = true')
        self.kill()
        self.assertFalse(self.rt.eval("Exported.Resurrect(vector3(1.0, 2.0, 3.0), 0.0, 'hospital')"))
        self.assertEqual(self.rt.eval('#Resurrected'), 0)


class RespawnDuringCutsceneTests(unittest.TestCase):
    def setUp(self):
        self.rt = make_characters(boot=False)
        self.rt.run(EXTRA_NATIVES)
        self.rt.load(*SPAWN_FILES)
        self.rt.run('Config.Creator.enableCutscene = true; clearLog(); fireEvent("W:CREATOR:FirstSpawn")')
        settle_characters(self.rt, 0, 5, barrier=False)
        self.assertTrue(self.rt.eval('WCCutscene.active()'))

    def test_admin_respawn_stops_the_ride(self):
        wagons = self.rt.eval('count("entity.create")')
        self.assertEqual(wagons, 2)
        self.rt.run(ADMIN_RESPAWN)
        settle_characters(self.rt, 100, 20, barrier=False)
        self.assertEqual(coords(self.rt), (500.0, 600.0, 70.0))
        self.assertFalse(self.rt.eval('WCCutscene.active()'))
        self.assertGreaterEqual(self.rt.eval('count("entity.delete")'), 2)   # wagon and driver gone
        self.assertLess(self.rt.eval("indexOf('ClearPedTasksImmediately')"),
                        self.rt.eval("indexOf('SetEntityCoords', indexOf('ClearPedTasksImmediately'))"))
        self.assertFalse(self.rt.eval('Peds[MyPed].invincible'))
        # the presentation loop has ended: no more per-frame letterbox requests
        self.rt.run('clearLog()')
        settle_characters(self.rt, 0, 10, barrier=False)
        self.assertEqual(self.rt.eval('count("native:0x69D65E89FFD72313")'), 0)


if __name__ == '__main__':
    unittest.main()
