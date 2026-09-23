"""Review round 1, client area: regressions for the confirmed client defects.

  * the restart boot of the selector whose scene:prepare the server refuses (the adopted character
    is in play: dead, switch window over, adoption still pending) leaves the player in the world
  * WCSpawn exports Resurrect is idempotent for a living player (no native, no re-render)
  * an uncertain service open (lost reply) asks the server to abandon the unused session
  * the 'event' spawn mode restores the radar / native HUD the selection loop muted
  * the overlay set of a remote ped that left scope is forgotten (no per-handle leak)
  * spawn placement always hands floats to the coordinate natives

Run: cd /home/user/w_creators && python3 -m unittest tests.test_review_client_r1
"""
import unittest

from test_client_characters_support import make_characters, settle

TWO = ('CallbackResults = { ["w_creators:characters:list"] = '
       'listResult({ card("1", "male"), card("2", "female") }, 3) }')

RELOAD_OK = ('CallbackResults["w_creators:appearance:reload"] = '
             '{ ok = true, code = "OK", data = { appearance = AppearanceSchema.default("female") } }')


def refused(code):
    return TWO + '; CallbackResults["w_creators:scene:prepare"] = WCResult.fail("%s"); %s' % (code, RELOAD_OK)


class RestartRefusalTests(unittest.TestCase):
    """selector.lua: a restart boot refused because the adopted character is in play."""

    def assert_left_in_world(self, rt):
        e = rt.eval
        self.assertFalse(e('WCSelector.active()'))
        self.assertTrue(e('Peds[MyPed].visible ~= false'))
        self.assertFalse(e('Peds[MyPed].frozen == true'))
        self.assertFalse(e('Peds[MyPed].participantsOnly == true'))
        self.assertFalse(e('WCState.busy("selection")'))
        self.assertEqual(e('liveGroups()'), 0)                 # no retry prompt
        self.assertEqual(e('called("w_creators:characters:list")'), 0)
        rt.run('clearLog()')
        settle(rt, 0, 5)
        self.assertEqual(e('count("DisableAllControlActions")'), 0)
        self.assertEqual(e('count("DisplayHud")'), 0)

    def test_dead_player_busy_is_left_in_the_world_and_state_reloaded(self):
        rt = make_characters(setup=refused('BUSY'))
        settle(rt, 0, 5)
        self.assert_left_in_world(rt)
        e = rt.eval
        self.assertEqual(e('WCState.appearance.sex'), 'female')
        self.assertIsNotNone(e('WCState.character'))
        self.assertEqual(e('called("w_creators:scene:prepare")'), 0)  # log cleared; no retry loop
        self.assertFalse(e('WCurtain.held()'))

    def test_switch_disabled_after_the_window_is_left_in_the_world(self):
        rt = make_characters(setup=refused('SERVICE_DISABLED'))
        settle(rt, 0, 5)
        self.assert_left_in_world(rt)
        self.assertEqual(rt.eval('WCState.appearance.sex'), 'female')
        # no prepare retry either: the character stays in play
        settle(rt, 30000, 5)
        self.assertEqual(rt.eval('called("w_creators:scene:prepare")'), 0)

    def test_adoption_pending_waits_for_the_character_then_reopens_once(self):
        setup = (TWO + '; PrepareAnswers = { WCResult.fail("SESSION_NOT_FOUND") }; ReloadAnswers = '
                 '{ WCResult.fail("NO_CHARACTER") }; '
                 'CallbackResults["w_creators:scene:prepare"] = function() '
                 '  return table.remove(PrepareAnswers, 1) or { ok = true, code = "OK" } end; '
                 'CallbackResults["w_creators:appearance:reload"] = function() '
                 '  return table.remove(ReloadAnswers, 1) or { ok = true, code = "OK", '
                 '    data = { appearance = AppearanceSchema.default("male") } } end')
        rt = make_characters(setup=setup)
        e = rt.eval
        settle(rt, 0, 5)
        self.assertFalse(e('WCSelector.active()'))
        self.assertTrue(e('Peds[MyPed].visible ~= false'))
        self.assertEqual(e('called("w_creators:appearance:reload")'), 1)
        self.assertEqual(e('called("w_creators:scene:prepare")'), 1)
        # the rate-limited reload is asked again; the adoption is done now: the selection reopens
        settle(rt, 11000, 10)
        self.assertEqual(e('called("w_creators:appearance:reload")'), 2)
        self.assertEqual(e('called("w_creators:scene:prepare")'), 2)
        self.assertTrue(e('WCSelector.active()'))
        self.assertEqual(e('called("w_creators:characters:list")'), 1)

    def test_first_login_refusal_is_still_a_failure(self):
        rt = make_characters(boot=False, setup=TWO + '; CallbackResults["w_creators:scene:prepare"] = '
                                                     'WCResult.fail("SESSION_NOT_FOUND")')
        rt.run('Peds[MyPed].coords = vector3(50.0, 50.0, 50.0); fireEvent("playerSpawned")')
        settle(rt, 600, 10)
        e = rt.eval
        self.assertTrue(e('WCSelector.active()'))    # the retry prompt of a real failure
        self.assertFalse(e('Peds[MyPed].visible'))
        self.assertEqual(e('called("w_creators:appearance:reload")'), 0)


class ResurrectLivingPlayerTests(unittest.TestCase):
    """respawn.lua: Resurrect is idempotent for a living player (w_ambulancejob's AI heal in bed)."""

    def setUp(self):
        from test_client_spawn_support import make_spawn_client
        self.rt = make_spawn_client()
        self.rt.run('WCRespawn.reset(); clearLog()')

    def test_second_resurrect_in_the_bed_runs_no_native_and_no_render(self):
        rt = self.rt
        rt.run('Peds[MyPed].dead = true; WCRespawn.poll(); WCRespawn.poll()')
        self.assertTrue(rt.eval("Exported.Resurrect(GetEntityCoords(PlayerPedId()), 90.0, 'hospital')"))
        self.assertEqual(rt.eval('count("NetworkResurrectLocalPlayer")'), 1)
        self.assertEqual(rt.eval('RestoreCalls'), 1)
        # 20 s later hospital:client:Revive resurrects the (now living) player again
        rt.run('clearLog()')
        self.assertTrue(rt.eval("Exported.Resurrect(GetEntityCoords(PlayerPedId()), 90.0, 'hospital')"))
        self.assertEqual(rt.eval('count("NetworkResurrectLocalPlayer")'), 0)
        self.assertEqual(rt.eval('RestoreCalls'), 1)
        self.assertEqual(rt.eval('count("SetEntityCoords")'), 0)
        self.assertEqual(rt.eval('count("TriggerEvent:w_creators:client:resurrected")'), 1)
        self.assertEqual(rt.eval('WCRespawn.state()'), 'ALIVE')
        self.assertFalse(rt.eval("WCState.busy('respawn')"))

    def test_living_player_is_still_moved_to_requested_coordinates_as_floats(self):
        rt = self.rt
        self.assertTrue(rt.eval("WCRespawn.resurrect({ x = 500, y = 600, z = 70 }, 180, 'admin')"))
        self.assertEqual(rt.eval('count("NetworkResurrectLocalPlayer")'), 0)
        self.assertEqual(rt.eval('RestoreCalls'), 0)
        self.assertEqual(rt.eval('count("SetEntityCoords")'), 1)
        for i in (2, 3, 4):
            self.assertEqual(rt.eval('math.type(Log[indexOf("SetEntityCoords")].args[%d])' % i), 'float')

    def test_dead_player_still_resurrects(self):
        rt = self.rt
        rt.run('Peds[MyPed].dying = true')
        self.assertTrue(rt.eval("Exported.Resurrect(nil, nil, 'medic')"))
        self.assertEqual(rt.eval('count("NetworkResurrectLocalPlayer")'), 1)


class UncertainOpenAbandonTests(unittest.TestCase):
    """locations.lua: an open whose reply was lost asks the server to abandon an unused session."""

    def setUp(self):
        from test_client_commerce_support import make_commerce
        self.rt = make_commerce()

    def open_with(self, answer):
        self.rt.run('CallbackResults = { ["w_creators:store:open"] = %s }' % answer)
        self.rt.run('R = table.pack(WCStore.open("valentine_clothing"))')
        return self.rt.eval('R[2]')

    def test_a_lost_reply_abandons_the_unused_session(self):
        self.assertEqual(self.open_with('function() return nil end'), 'INTERNAL_ERROR')
        self.assertEqual(self.rt.eval('called("w_creators:session:abandon")'), 1)
        self.assertEqual(self.rt.eval('called("w_creators:session:close")'), 0)
        self.assertIsNone(self.rt.eval('WCServiceFlow.current()'))

    def test_busy_open_abandons_too(self):
        self.assertEqual(self.open_with('fail("BUSY")'), 'BUSY')
        self.assertEqual(self.rt.eval('called("w_creators:session:abandon")'), 1)

    def test_a_definite_refusal_abandons_nothing(self):
        self.assertEqual(self.open_with('fail("TOO_FAR")'), 'TOO_FAR')
        self.assertEqual(self.rt.eval('called("w_creators:session:abandon")'), 0)

    def test_a_session_opened_for_a_flow_stopped_meanwhile_is_closed(self):
        self.rt.run('CallbackResults = { ["w_creators:store:open"] = function() '
                    '  WCServiceFlow.finish(WCServiceFlow.current(), "stop") return storeData() end }')
        self.rt.run('R = table.pack(WCStore.open("valentine_clothing"))')
        self.assertFalse(self.rt.eval('R[1]'))
        self.assertEqual(self.rt.eval('callbacks("w_creators:session:close")[1][2]'), 'stok')


LAST_ARG = r"""
function lastArg(op)
    for i = #Log, 1, -1 do if Log[i].op == op then return Log[i].args[1] end end
end
"""


class EventSpawnUiTests(unittest.TestCase):
    """selector.lua: the 'event' spawn mode gives back the radar and the native HUD."""

    def test_event_spawn_restores_radar_and_hud(self):
        rt = make_characters(setup=TWO + '; CallbackResults["w_creators:characters:loaded"] = '
                                          '{ ok = true, code = "OK", data = { spawn = "event" } }')
        rt.run(LAST_ARG)
        settle(rt, 0, 3)
        self.assertGreater(rt.eval('count("DisableAllControlActions")'), 0)
        self.assertIs(rt.eval('lastArg("DisplayHud")'), False)       # the selection loop mutes it
        rt.run('press("RETURN")')
        settle(rt)
        e = rt.eval
        self.assertEqual(e('called("w_creators:characters:loaded")'), 1)
        self.assertFalse(e('WCSelector.active()'))
        settle(rt, 20000, 5)                                            # past the event fade wait
        self.assertIs(e('lastArg("DisplayHud")'), True)
        self.assertIs(e('lastArg("setRadarVisible")'), True)
        self.assertGreater(e('count("TriggerEvent:hud:client:showui")'), 0)


class OverlayCacheLeakTests(unittest.TestCase):
    """overlays.lua / sync.lua: a remote ped's overlay set does not outlive the ped."""

    def setUp(self):
        from test_client_infra_support import make_client
        self.rt = make_client()
        self.rt.run(r"""
            app = AppearanceSchema.default('male')
            Handles = {}
            function enterScope()
                local ped = makePed('mp_male', 10.0, 0.0, 0.0)
                Handles[#Handles + 1] = ped
                RemotePlayers[5] = ped
                tick(1000)
            end
            function leaveScope()
                local ped = RemotePlayers[5]
                RemotePlayers[5] = nil
                Peds[ped] = nil          -- the entity is gone for this client
                tick(1000)
            end
            function liveSets()
                local n = 0
                for _, h in ipairs(Handles) do
                    if Appearance.Overlays.applied(h) then n = n + 1 end
                end
                return n
            end
        """)

    def test_scope_churn_keeps_at_most_the_current_ped(self):
        rt = self.rt
        rt.run('enterScope(); fireEvent("w_creators:client:applyRemoteAppearance", nil, 5, app)')
        self.assertEqual(rt.eval('liveSets()'), 1)
        for _ in range(50):
            rt.run('leaveScope(); enterScope()')
        self.assertEqual(rt.eval('#Handles'), 51)
        self.assertEqual(rt.eval('liveSets()'), 1)
        self.assertIsNotNone(rt.eval('Appearance.Overlays.applied(RemotePlayers[5])'))

    def test_leaving_scope_forgets_the_set(self):
        rt = self.rt
        rt.run('enterScope(); fireEvent("w_creators:client:applyRemoteAppearance", nil, 5, app)')
        rt.run('leaveScope()')
        self.assertEqual(rt.eval('liveSets()'), 0)

    def test_forget_after_the_ped_left_scope(self):
        rt = self.rt
        rt.run('enterScope(); fireEvent("w_creators:client:applyRemoteAppearance", nil, 5, app)')
        rt.run('RemotePlayers[5] = nil; fireEvent("w_creators:client:forgetRemote", nil, 5)')
        self.assertEqual(rt.eval('liveSets()'), 0)


FLOAT_ARGS = r"""
function allFloat(op, first, last)
    local n = 0
    for _, e in ipairs(Log) do
        if e.op == op then
            n = n + 1
            for i = first, last do
                if math.type(e.args[i]) ~= 'float' then return false, i end
            end
        end
    end
    return n > 0
end
"""


class FloatCoordinateTests(unittest.TestCase):
    """spawn.lua / cutscene.lua: integral coordinates reach the float natives as floats."""

    def test_integer_last_position_is_placed_with_floats(self):
        from test_client_spawn_support import make_spawn_client, spin
        rt = make_spawn_client()
        rt.run(FLOAT_ARGS)
        rt.run('Ground = function(x, y, z) return true, 44 end; clearLog()')
        rt.run("fireEvent('w_creators:client:spawn', nil, { x = 2941, y = 553, z = 44, heading = 90 }, "
               "{ kind = 'login' })")
        spin(rt, 500)
        self.assertTrue(rt.eval('(allFloat("SetEntityCoords", 2, 4))'))
        self.assertTrue(rt.eval('(allFloat("RequestCollisionAtCoord", 1, 3))'))
        self.assertEqual(rt.eval('math.type(Peds[MyPed].heading)'), 'float')

    def test_integer_first_spawn_is_placed_with_floats(self):
        from test_client_spawn_support import make_spawn_client, spin
        rt = make_spawn_client()
        rt.run(FLOAT_ARGS)
        rt.run('Config.Spawn.firstSpawn = { coords = { x = -274, y = 785, z = 119 }, heading = 10 }')
        rt.run('Ground = { false, 0.0 }; clearLog()')
        rt.run("fireEvent('w_creators:client:spawn', nil, { x = 1, y = 2 }, { kind = 'login' })")
        spin(rt, 500)
        self.assertTrue(rt.eval('(allFloat("SetEntityCoords", 2, 4))'))

    def test_plain_first_spawn_with_an_integer_table_config(self):
        rt = make_characters(boot=False)
        rt.run(FLOAT_ARGS)
        rt.run('Config.Creator.enableCutscene = false; '
               'Config.Spawn.firstSpawn = { coords = { x = -274, y = 785, z = 119 }, heading = 10 }')
        rt.run('clearLog(); fireEvent("W:CREATOR:FirstSpawn")')
        settle(rt, 0, 5, barrier=False)
        self.assertTrue(rt.eval('(allFloat("SetEntityCoords", 2, 4))'))
        self.assertTrue(rt.eval('(allFloat("RequestCollisionAtCoord", 1, 3))'))


if __name__ == '__main__':
    unittest.main()
