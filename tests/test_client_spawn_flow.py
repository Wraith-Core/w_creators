"""WCSpawnSelector (client/spawn/selector.lua) and WCSpawn (client/spawn/spawn.lua): the selector sends
only point ids, shows / cleans up its camera, prompts and focus, the safe spawn waits for the
appearance, probes the ground with the 20 m rule, falls back to Config.Spawn.firstSpawn, releases
the player and the scene, and the admin/death respawn path.

Run: python3 -m unittest discover -s tests -p 'test_client_spawn_*.py'
"""
import unittest

from test_client_spawn_support import make_spawn_client, count, spin

SELECT = "{ points = { 'saintdenis', 'nowhere', 'valentine', 'saintdenis' }, kind = 'login', last = %s }"
LAST = "{ x = 100.0, y = 200.0, z = 50.0, heading = 12.0, label = 'فالنتاين' }"


def open_selector(rt, last='nil', kind='login'):
    data = (SELECT % last).replace("'login'", repr(kind))
    rt.run("fireEvent('w_creators:client:selectSpawn', nil, %s)" % data)


class SelectorTests(unittest.TestCase):
    def setUp(self):
        self.rt = make_spawn_client()
        self.rt.run('clearLog()')

    def test_resolve_keeps_the_server_order_skips_unknown_ids_and_puts_last_first(self):
        pts = self.rt.eval("WCSpawnSelector.resolve(%s)" % (SELECT % LAST))
        ids = [pts[i].id for i in range(1, len(pts) + 1)]
        self.assertEqual(ids, ['__last', 'saintdenis', 'valentine'])
        self.assertEqual(pts[1].label, self.rt.eval('Config.Spawn.selector.labels.lastPosition'))
        self.assertEqual(pts[1].region, 'فالنتاين')
        self.assertEqual(pts[1].coords.x, 100.0)

    def test_disabled_points_are_not_shown(self):
        self.rt.run("for _, p in ipairs(Config.Spawn.points) do if p.id == 'valentine' then p.enabled = false end end")
        pts = self.rt.eval("WCSpawnSelector.resolve(%s)" % (SELECT % 'nil'))
        self.assertEqual([pts[i].id for i in range(1, len(pts) + 1)], ['saintdenis'])

    def test_open_holds_the_player_and_shows_a_camera_and_prompts(self):
        open_selector(self.rt, LAST)
        self.assertTrue(self.rt.eval('WCSpawnSelector.active()'))
        self.assertEqual(self.rt.eval('WCSpawnSelector.kind()'), 'login')
        self.assertTrue(self.rt.eval('Peds[MyPed].frozen'))
        self.assertFalse(self.rt.eval('Peds[MyPed].visible'))
        self.assertTrue(self.rt.eval('Peds[MyPed].invincible'))
        self.assertEqual(count(self.rt, 'CreateCam'), 1)
        self.assertEqual(self.rt.eval('#PromptGroups'), 1)
        self.assertIn('(1/3)', self.rt.eval('PromptGroups[1].title'))
        self.assertIsNotNone(self.rt.eval("indexOf('TriggerEvent:hud:client:Hideui')"))
        self.assertIsNotNone(self.rt.eval("indexOf('SetFocusPosAndVel')"))

    def test_confirm_sends_only_the_point_id(self):
        open_selector(self.rt, LAST)
        self.rt.run("WCSpawnSelector.move(1)")
        self.assertEqual(self.rt.eval('WCSpawnSelector.current().id'), 'saintdenis')
        self.assertTrue(self.rt.eval('WCSpawnSelector.confirm()'))
        calls = self.rt.eval("callbacks('w_creators:spawn:choose')")
        self.assertEqual(len(calls), 1)
        args = calls[1]
        self.assertEqual(args.n, 2)
        self.assertIs(args[1], False)
        self.assertEqual(args[2], 'saintdenis')
        # the last location goes as its id too, never as coordinates
        rt = make_spawn_client()
        open_selector(rt, LAST)
        rt.eval('WCSpawnSelector.confirm()')
        args = rt.eval("callbacks('w_creators:spawn:choose')[1]")
        self.assertEqual((args.n, args[2]), (2, '__last'))

    def test_the_select_prompt_confirms_from_the_frame_loop(self):
        open_selector(self.rt)
        self.rt.run("Pressed[Config.Spawn.selector.keys.select] = true")
        self.rt.g.tick(10)  # inside the input delay: nothing yet
        self.assertEqual(len(self.rt.eval("callbacks('w_creators:spawn:choose')")), 0)
        self.rt.g.tick(600)
        self.assertEqual(len(self.rt.eval("callbacks('w_creators:spawn:choose')")), 1)

    def test_move_wraps_and_replaces_the_camera(self):
        open_selector(self.rt)
        self.rt.run('WCSpawnSelector.move(-1)')
        self.assertEqual(self.rt.eval('WCSpawnSelector.current().id'), 'valentine')
        self.assertEqual(count(self.rt, 'CreateCam'), 2)
        self.assertEqual(count(self.rt, 'DestroyCam'), 1)
        self.assertEqual(self.rt.eval('#Cams == nil and 0 or (function() local n = 0 for _ in pairs(Cams) do n = n + 1 end return n end)()'), 1)

    def test_a_refused_choice_is_shown_and_the_selector_stays(self):
        self.rt.run("CallbackResults = { ['w_creators:spawn:choose'] = WCResult.fail('INVALID_SPAWN') }")
        open_selector(self.rt)
        self.assertFalse(self.rt.eval('WCSpawnSelector.confirm()'))
        self.assertTrue(self.rt.eval('WCSpawnSelector.active()'))
        self.assertEqual(self.rt.eval('Notified[1].description'), self.rt.eval("WCResult.messageKey('INVALID_SPAWN')"))
        self.assertTrue(self.rt.eval('Peds[MyPed].frozen'))

    def test_a_lost_grant_gives_the_player_back(self):
        self.rt.run("CallbackResults = { ['w_creators:spawn:choose'] = WCResult.fail('SPAWN_NOT_PENDING') }")
        open_selector(self.rt)
        self.assertFalse(self.rt.eval('WCSpawnSelector.confirm()'))
        self.assertFalse(self.rt.eval('WCSpawnSelector.active()'))
        self.assertFalse(self.rt.eval('Peds[MyPed].frozen'))
        self.assertTrue(self.rt.eval('Peds[MyPed].visible'))
        self.assertFalse(self.rt.eval('Peds[MyPed].invincible'))
        self.assertTrue(self.rt.eval('PromptGroups[1].deleted'))
        self.assertEqual(self.rt.eval('next(Cams)'), None)

    def test_an_accepted_choice_without_a_spawn_event_gives_the_player_back(self):
        open_selector(self.rt)
        self.assertTrue(self.rt.eval('WCSpawnSelector.confirm()'))
        self.assertFalse(self.rt.eval('WCSpawnSelector.active()'))
        self.assertTrue(self.rt.eval('Peds[MyPed].frozen'))  # handed to the spawn event
        spin(self.rt, 21000, 500)
        self.assertFalse(self.rt.eval('Peds[MyPed].frozen'))
        self.assertTrue(self.rt.eval('Peds[MyPed].visible'))

    def test_an_empty_list_falls_back_through_the_server_without_coordinates(self):
        self.rt.run("fireEvent('w_creators:client:selectSpawn', nil, { points = { 'nowhere' }, kind = 'login' })")
        self.assertFalse(self.rt.eval('WCSpawnSelector.active()'))
        args = self.rt.eval("Log[indexOf('TriggerServerEvent:w_creators:server:spawnAt')].args")
        # not '__last': a new character must never be sent to a saved position the server withheld
        self.assertEqual((args.n, args[1]), (1, False))

    def test_resource_stop_cleans_up_the_selector(self):
        open_selector(self.rt, LAST)
        self.rt.run("fireEvent('onResourceStop', nil, 'w_creators')")
        self.assertFalse(self.rt.eval('WCSpawnSelector.active()'))
        self.assertTrue(self.rt.eval('PromptGroups[1].deleted'))
        self.assertEqual(self.rt.eval('next(Cams)'), None)
        self.assertIsNotNone(self.rt.eval("indexOf('ClearFocus')"))
        rs = self.rt.eval("(function() local out = {} for _, e in ipairs(Log) do if e.op == 'RenderScriptCams' then out[#out + 1] = e.args[1] end end return out end)()")
        self.assertIs(rs[len(rs)], False)
        self.assertFalse(self.rt.eval('Peds[MyPed].frozen'))
        self.assertTrue(self.rt.eval('Peds[MyPed].visible'))
        self.assertFalse(self.rt.eval('Peds[MyPed].invincible'))
        # the frame loop ended
        before = self.rt.eval("count('DisableAllControlActions')")
        self.rt.g.tick(100)
        self.assertEqual(self.rt.eval("count('DisableAllControlActions')"), before)

    def test_language_change_relabels_the_prompts(self):
        open_selector(self.rt)
        self.rt.run("PromptGroups[1].prompts[1].label = 'stale'; PromptGroups[1].title = 'stale'")
        self.rt.run("fireEvent('w_lib:setLocale', nil, 'en')")
        self.assertEqual(self.rt.eval("PromptGroups[1].prompts[1].label"),
                         self.rt.eval("locale(Config.Spawn.selector.labels.select)"))
        self.assertIn('(1/2)', self.rt.eval('PromptGroups[1].title'))


class SafeSpawnTests(unittest.TestCase):
    def setUp(self):
        self.rt = make_spawn_client()
        self.rt.run('clearLog()')

    def spawn(self, pos="{ x = 10.0, y = 20.0, z = 100.0, heading = 33.0 }", kind='login', ms=500):
        self.rt.run("fireEvent('w_creators:client:spawn', nil, %s, { kind = %r })" % (pos, kind))
        spin(self.rt, ms)

    def test_spawn_places_on_the_probed_ground_and_releases_everything(self):
        self.rt.run('Ground = { true, 98.5 }')
        self.rt.run("FreezeEntityPosition(MyPed, true); SetEntityVisible(MyPed, false); SetEntityInvincible(MyPed, true)")
        self.spawn()
        self.assertEqual(list(self.rt.eval('lastCoords()').values()), [10.0, 20.0, 98.5])
        self.assertEqual(self.rt.eval('Peds[MyPed].heading'), 33.0)
        self.assertFalse(self.rt.eval('Peds[MyPed].frozen'))
        self.assertTrue(self.rt.eval('Peds[MyPed].visible'))
        self.assertFalse(self.rt.eval('Peds[MyPed].invincible'))
        self.assertEqual(len(self.rt.eval("callbacks('w_creators:scene:release')")), 1)
        self.assertTrue(self.rt.eval('hudShown()'))
        self.assertIsNotNone(self.rt.eval("indexOf('setRadarVisible')"))
        self.assertIsNotNone(self.rt.eval("indexOf('ShutdownLoadingScreen')"))
        self.assertIsNotNone(self.rt.eval("indexOf('DoScreenFadeIn')"))
        self.assertFalse(self.rt.eval("WCState.busy('spawn')"))
        self.assertFalse(self.rt.eval('WCSpawn.busy()'))

    def test_the_probe_starts_above_the_target(self):
        self.spawn()
        self.assertGreater(self.rt.eval('Probes[1][3]'), 100.0)

    def test_no_ground_falls_back_to_the_first_spawn(self):
        self.rt.run('Ground = { false, 0.0 }')
        self.spawn()
        fs = self.rt.eval('Config.Spawn.firstSpawn.coords')
        x, y, z = self.rt.eval('lastCoords()').values()
        self.assertEqual((x, y), (fs.x, fs.y))
        self.assertEqual(self.rt.eval('Peds[MyPed].heading'), self.rt.eval('Config.Spawn.firstSpawn.heading'))

    def test_ground_more_than_20_m_away_falls_back(self):
        self.rt.run('Ground = function(x, y, z) if x == 10.0 then return true, 60.0 end return true, z - 2.0 end')
        self.spawn()
        fs = self.rt.eval('Config.Spawn.firstSpawn.coords')
        x, y, _ = self.rt.eval('lastCoords()').values()
        self.assertEqual((x, y), (fs.x, fs.y))

    def test_ground_within_20_m_is_accepted(self):
        self.rt.run('Ground = function(x, y, z) return true, 85.0 end')
        self.spawn()
        self.assertEqual(list(self.rt.eval('lastCoords()').values()), [10.0, 20.0, 85.0])

    def test_no_collision_falls_back_and_still_releases_the_player(self):
        self.rt.run('CollisionLoaded = false')
        self.spawn(ms=25000)
        fs = self.rt.eval('Config.Spawn.firstSpawn.coords')
        x, y, z = self.rt.eval('lastCoords()').values()
        self.assertEqual((x, y, z), (fs.x, fs.y, fs.z))
        self.assertFalse(self.rt.eval('Peds[MyPed].frozen'))
        self.assertFalse(self.rt.eval("WCState.busy('spawn')"))

    def test_invalid_position_falls_back(self):
        self.spawn(pos="{ x = 0/0, y = 1.0, z = 1.0 }")
        fs = self.rt.eval('Config.Spawn.firstSpawn.coords')
        self.assertEqual(self.rt.eval('lastCoords()')[1], fs.x)

    def test_spawn_waits_for_the_appearance_application(self):
        self.rt.run('Applying = true')
        self.spawn(ms=1000)
        self.assertIsNone(self.rt.eval("indexOf('SetEntityCoords')"))
        self.assertTrue(self.rt.eval('WCSpawn.busy()'))
        self.rt.run('Applying = false')
        spin(self.rt, 500)
        self.assertEqual(list(self.rt.eval('lastCoords()').values())[:2], [10.0, 20.0])
        self.assertFalse(self.rt.eval('WCSpawn.busy()'))

    def test_spawn_also_waits_for_the_own_appearance_queue(self):
        self.rt.run('Appearance.Sync.applyingOwn = function() return OwnApplying end; OwnApplying = true')
        self.spawn(ms=1000)
        self.assertIsNone(self.rt.eval("indexOf('SetEntityCoords')"))
        self.rt.run('OwnApplying = false')
        spin(self.rt, 500)
        self.assertIsNotNone(self.rt.eval("indexOf('SetEntityCoords')"))

    def test_initial_spawn_starts_the_cutscene_only_when_enabled(self):
        self.rt.run('Config.Creator.enableCutscene = true')
        self.spawn(kind='initial')
        self.assertIsNotNone(self.rt.eval("indexOf('TriggerEvent:W:CREATOR:FirstSpawn')"))
        rt = make_spawn_client()
        rt.run('Config.Creator.enableCutscene = true')
        rt.run("fireEvent('w_creators:client:spawn', nil, { x = 1.0, y = 1.0, z = 1.0 }, { kind = 'login' })")
        spin(rt, 500)
        self.assertIsNone(rt.eval("indexOf('TriggerEvent:W:CREATOR:FirstSpawn')"))
        rt = make_spawn_client()
        rt.run("fireEvent('w_creators:client:spawn', nil, { x = 1.0, y = 1.0, z = 1.0 }, { kind = 'initial' })")
        spin(rt, 500)
        self.assertIsNone(rt.eval("indexOf('TriggerEvent:W:CREATOR:FirstSpawn')"))

    def test_spawn_closes_the_selector_and_leaves_the_room(self):
        self.rt.run("CreatorScene.release = function(opts) Released = opts end")
        open_selector(self.rt)
        self.rt.eval('WCSpawnSelector.confirm()')
        self.spawn()
        self.assertFalse(self.rt.eval('WCSpawnSelector.active()'))
        self.assertTrue(self.rt.eval('Released.unload'))
        self.assertEqual(self.rt.eval('next(Cams)'), None)
        self.assertTrue(self.rt.eval('Peds[MyPed].visible'))
        # the hand-off happened: the watchdog does not act later
        spin(self.rt, 21000, 1000)
        warned = self.rt.eval("(function() for _, p in ipairs(Printed) do if p.text:find('no spawn event') then return true end end return false end)()")
        self.assertFalse(warned)

    def test_resource_stop_during_a_spawn_releases_the_player(self):
        self.rt.run('Applying = true')
        self.rt.run('FreezeEntityPosition(MyPed, true); SetEntityVisible(MyPed, false)')
        self.spawn(ms=200)
        self.assertTrue(self.rt.eval("WCState.busy('spawn')"))
        self.rt.run("fireEvent('onResourceStop', nil, 'w_creators')")
        self.assertFalse(self.rt.eval("WCState.busy('spawn')"))
        self.assertFalse(self.rt.eval('Peds[MyPed].frozen'))
        self.assertTrue(self.rt.eval('Peds[MyPed].visible'))


class RespawnEventTests(unittest.TestCase):
    def setUp(self):
        self.rt = make_spawn_client()
        self.rt.run('WCRespawn.reset(); clearLog()')

    def respawn(self, kind='admin', ms=1000):
        self.rt.run("fireEvent('w_creators:client:respawn', nil, { x = 5.0, y = 6.0, z = 7.0, heading = 10.0 }, "
                    "{ kind = %r, point = 'valentine' })" % kind)
        spin(self.rt, ms)

    def test_admin_respawn_moves_the_living_player_without_touching_the_bucket(self):
        self.respawn()
        self.assertEqual(list(self.rt.eval('lastCoords()').values())[:2], [5.0, 6.0])
        self.assertEqual(len(self.rt.eval("callbacks('w_creators:scene:release')")), 0)
        self.assertEqual(count(self.rt, 'NetworkResurrectLocalPlayer'), 0)
        self.assertFalse(self.rt.eval('Peds[MyPed].frozen'))
        self.assertFalse(self.rt.eval('hudShown()'))  # the player's HUD choice is left alone
        self.assertIsNone(self.rt.eval("indexOf('TriggerEvent:W:CREATOR:FirstSpawn')"))

    def test_a_dead_player_is_resurrected_then_placed(self):
        self.rt.run('Peds[MyPed].dead = true; WCRespawn.poll(); WCRespawn.poll()')
        self.respawn(kind='death')
        self.assertEqual(count(self.rt, 'NetworkResurrectLocalPlayer'), 1)
        self.assertLess(self.rt.eval("indexOf('NetworkResurrectLocalPlayer')"),
                        self.rt.eval("indexOf('SetEntityCoords', indexOf('NetworkResurrectLocalPlayer'))"))
        self.assertEqual(self.rt.eval('WCRespawn.state()'), 'ALIVE')
        self.assertEqual(self.rt.eval('RestoreCalls'), 1)
        self.assertFalse(self.rt.eval('IsEntityDead(MyPed)'))

    def test_admin_selector_choice_releases_the_hidden_player(self):
        open_selector(self.rt, kind='admin')
        self.assertEqual(self.rt.eval('WCSpawnSelector.kind()'), 'admin')
        self.respawn()
        self.assertFalse(self.rt.eval('WCSpawnSelector.active()'))
        self.assertTrue(self.rt.eval('Peds[MyPed].visible'))
        self.assertFalse(self.rt.eval('Peds[MyPed].invincible'))
        self.assertTrue(self.rt.eval('hudShown()'))

    def test_respawn_in_the_character_scene_is_ignored(self):
        open_selector(self.rt, kind='login')
        self.respawn()
        self.assertTrue(self.rt.eval('WCSpawnSelector.active()'))
        self.assertIsNone(self.rt.eval("indexOf('SetEntityCoords')"))


if __name__ == '__main__':
    unittest.main()
