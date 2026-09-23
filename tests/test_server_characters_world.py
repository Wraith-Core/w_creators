"""Server scene isolation, spawn, admin respawn and appearance sync (ARCHITECTURE.md §9.4, §11, §16.2, §16.3, §16.5)."""
import os
import sys
import unittest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from test_server_characters_flow import server_runtime  # noqa: E402

ENTITIES = r'''
entities = {}
function NetworkGetEntityFromNetworkId(netId) return entities[netId] and (5000 + netId) or 0 end
local baseExists, baseCoords = DoesEntityExist, GetEntityCoords
function DoesEntityExist(e) if type(e) == 'number' and e >= 5000 then return entities[e - 5000] ~= nil end return baseExists(e) end
function GetEntityCoords(e) if type(e) == 'number' and e >= 5000 then return entities[e - 5000].coords end return baseCoords(e) end
function NetworkGetEntityOwner(e) return entities[e - 5000].owner end
function GetEntityType(e) return 1 end
function GetEntityModel(e) return GetHashKey(entities[e - 5000].model) end
function SetEntityRoutingBucket(e, b) entities[e - 5000].bucket = b end
function GetEntityRoutingBucket(e) return entities[e - 5000].bucket or 0 end
anchor = vector3(-561.22, -3776.26, 239.16)
'''


class Base(unittest.TestCase):
    def setUp(self):
        self.rt = server_runtime()
        self.rt.run(ENTITIES)
        self.e = self.rt.eval
        self.cb = self.e('cb')

    def call(self, name, src, *args):
        return self.cb(name, src, *args)

    def later(self, ms=11000):
        self.rt.run('Clock.now = Clock.now + %d' % ms)

    def bucket(self, src=1):
        return self.e('Players[%d].bucket' % src)

    def activate(self, src=1, charid='vorp:1'):
        self.assertTrue(self.call('characters:select', src, charid).ok)
        r = self.call('characters:loaded', src)
        self.assertTrue(r.ok, r.code)
        return r


class SceneTests(Base):
    def test_selection_isolation_and_release(self):
        r = self.call('scene:prepare', 1)
        self.assertTrue(r.ok, r.code)
        self.assertEqual(self.bucket(), 1)
        self.assertTrue(self.e('WCScene.isIsolated(1)'))
        r = self.call('scene:release', 1)
        self.assertTrue(r.ok)
        self.assertTrue(r.data.released)
        self.assertEqual(self.bucket(), 0)
        self.assertFalse(self.call('scene:release', 1).data.released)       # idempotent

    def test_active_character_outside_a_fitting_session_is_refused(self):
        self.activate()
        self.rt.run('WCSpawnServer.cancel(1); WCScene.toWorld(1)')
        self.later()
        # the legacy events never start a switch: refused and logged
        for event in ('w_creators:server:isolate', 'PersonaCreatorHandler.setPlayerRoutingBucket'):
            self.rt.run('fireEvent("%s", 1)' % event)
            self.assertEqual(self.bucket(), 0, event)
        self.assertEqual(self.e('countLogs("security_violation")'), 2)
        self.assertEqual(self.e('WCScene.isolate(1).code'), 'SESSION_NOT_FOUND')
        # scene:prepare applies the switch rules: disabled / dead are refused without a violation
        self.later()
        self.rt.run('Config.Characters.allowSwitch = false')
        r = self.call('scene:prepare', 1)
        self.assertEqual(r.code, 'SERVICE_DISABLED')
        self.rt.run('Config.Characters.allowSwitch = true; health[1] = 0')
        self.assertEqual(self.call('scene:prepare', 1).code, 'BUSY')
        self.assertEqual(self.bucket(), 0)
        self.assertEqual(self.e('WCCharacters.active(1).charid'), 'vorp:1')
        self.assertEqual(self.e('countLogs("security_violation")'), 3)
        # a framework character that w_creators never activated is not "in selection" either
        self.rt.run('charids[2] = "vorp:9"')
        self.assertEqual(self.call('scene:prepare', 2).code, 'SESSION_NOT_FOUND')

    def test_fitting_room_session_allows_isolation_and_its_close_releases(self):
        self.activate()
        self.rt.run('WCSpawnServer.cancel(1); WCScene.toWorld(1); Players[1].coords = vector3(-326.17, 773.757, 117.5)')
        self.later()
        self.rt.run('s = WCSessions.open(1, "store", { locationId = "valentine_clothing" })')
        self.assertTrue(self.e('s.ok'))
        r = self.call('scene:prepare', 1)
        self.assertTrue(r.ok, r.code)
        self.assertEqual(r.data.reason, 'fitting')
        self.assertEqual(self.bucket(), 1)
        self.rt.run('WCSessions.close(1, s.data.token)')
        self.assertEqual(self.bucket(), 0)

    def test_prepare_first_starts_the_switch_as_the_selector_contract_orders(self):
        self.activate()
        self.rt.run('WCSpawnServer.cancel(1); WCScene.toWorld(1)')
        self.later()
        r = self.call('scene:prepare', 1)                                      # §17: prepare -> list
        self.assertTrue(r.ok, r.code)
        self.assertEqual(r.data.reason, 'selection')
        self.assertEqual(self.bucket(), 1)
        self.assertIsNone(self.e('WCCharacters.active(1)'))
        self.assertTrue(self.e('WCCharacters.isSwitching(1)'))
        self.assertEqual(self.e('countLogs("security_violation")'), 0)
        self.assertTrue(self.call('characters:list', 1).ok)
        self.assertTrue(self.call('characters:select', 1, 'vorp:2').ok)

    def test_switch_allows_isolation(self):
        self.activate()
        self.rt.run('WCSpawnServer.cancel(1); WCScene.toWorld(1)')
        self.later()
        self.assertTrue(self.call('characters:list', 1).ok)
        self.assertTrue(self.call('scene:prepare', 1).ok)
        self.assertEqual(self.bucket(), 1)

    def test_rejoin_resets_only_a_bucket_w_creators_set(self):
        self.rt.run('Players[1].bucket = 55')                                  # jail / housing instance
        self.rt.run('fireEvent("w_creators:server:rejoinWorld", 1)')
        self.assertEqual(self.bucket(), 55)
        self.assertTrue(self.call('scene:prepare', 1).ok)                     # remembers bucket 55
        self.assertEqual(self.bucket(), 1)
        self.rt.run('fireEvent("w_creators:server:rejoinWorld", 1)')
        self.assertEqual(self.bucket(), 55)
        self.later()
        self.assertTrue(self.call('scene:prepare', 1).ok)
        self.rt.run('Players[1].bucket = 77')                                  # another resource moved him
        self.assertTrue(self.call('scene:release', 1).ok)
        self.assertEqual(self.bucket(), 77)

    def test_resource_stop_and_drop_touch_only_tracked_buckets(self):
        self.rt.run('Players[3] = { name = "three", coords = vector3(0, 0, 0), bucket = 0 }')
        self.assertTrue(self.call('scene:prepare', 1).ok)
        self.assertTrue(self.call('scene:prepare', 3).ok)
        self.rt.run('Players[2].bucket = 42')
        self.rt.run('fireEvent("playerDropped", 3)')
        self.assertFalse(self.e('WCScene.isIsolated(3)'))
        self.rt.run('fireEvent("onResourceStop", nil, "w_creators")')
        self.assertEqual(self.bucket(1), 0)
        self.assertEqual(self.bucket(2), 42)
        self.assertEqual(self.bucket(3), 3)                                    # dropped: forgotten, not touched

    def test_register_ped_checks(self):
        self.rt.run(r'''
            entities[7] = { owner = 1, model = 'mp_male', coords = anchor }
            entities[8] = { owner = 2, model = 'mp_male', coords = anchor }
            entities[9] = { owner = 1, model = 'a_c_horse_arabian_white', coords = anchor }
            entities[10] = { owner = 1, model = 'mp_female', coords = vector3(0, 0, 0) }
        ''')
        self.assertEqual(self.call('scene:registerPed', 1, 7).code, 'SESSION_NOT_FOUND')   # not isolated
        self.assertTrue(self.call('scene:prepare', 1).ok)
        self.assertEqual(self.call('scene:registerPed', 1, 'x').code, 'INVALID_PAYLOAD')
        self.assertEqual(self.call('scene:registerPed', 1, 8).code, 'INVALID_PAYLOAD')     # someone else's
        self.assertEqual(self.call('scene:registerPed', 1, 9).code, 'INVALID_PAYLOAD')     # model
        self.assertEqual(self.call('scene:registerPed', 1, 10).code, 'TOO_FAR')
        r = self.call('scene:registerPed', 1, 7)
        self.assertTrue(r.ok, r.code)
        self.assertEqual(self.e('entities[7].bucket'), 1)
        start = self.e('Clock.now')
        self.later()
        self.assertEqual(self.call('scene:registerPed', 1, 99).code, 'SESSION_NOT_FOUND')  # never appears
        self.assertGreaterEqual(self.e('Clock.now') - start, 11000 + 5000)


class SpawnTests(Base):
    def spawns(self):
        return self.rt.client_events('w_creators:client:spawn')

    def choose(self, point, src=1):
        return self.call('spawn:choose', src, point)

    def test_choose_needs_the_grant_and_an_enabled_point(self):
        r = self.choose('valentine')
        self.assertEqual(r.code, 'SPAWN_NOT_PENDING')
        self.assertEqual(self.e('countLogs("character_access_denied")'), 1)
        self.assertTrue(self.call('scene:prepare', 1).ok)
        self.activate()
        self.assertEqual(self.choose('nowhere').code, 'INVALID_SPAWN')
        self.rt.run('Config.Spawn.points[3].enabled = false')                 # rhodes
        self.assertEqual(self.choose('rhodes').code, 'INVALID_SPAWN')
        self.assertTrue(self.e('SpawnPending[1]'))
        self.later()
        r = self.choose('saintdenis')
        self.assertTrue(r.ok, r.code)
        self.assertAlmostEqual(r.data.pos.x, 2645.11)
        self.assertEqual(r.data.kind, 'login')
        self.assertEqual(self.bucket(), 0)
        self.assertFalse(self.e('WCScene.isIsolated(1)'))
        spawn = self.spawns()[-1]
        self.assertEqual(spawn.args[2].kind, 'login')
        self.assertEqual(self.e('countLogs("character_spawned")'), 1)
        self.assertEqual(self.choose('saintdenis').code, 'SPAWN_NOT_PENDING')

    def test_selector_lists_enabled_points_in_order(self):
        self.rt.run('Config.Spawn.points[1].enabled = false; Config.Spawn.points[2].order = 50')
        self.activate()
        payload = self.rt.client_events('w_creators:client:selectSpawn')[-1].args[1]
        self.assertEqual(list(payload.points.values()),
                         ['rhodes', 'blackwater', 'strawberry', 'armadillo', 'tumbleweed', 'vanhorn', 'annesburg', 'saintdenis'])

    def test_last_location_out_of_bounds_is_never_used(self):
        self.rt.run('lastPos = { x = 9000.0, y = 0.0, z = 50.0 }')
        self.activate()
        payload = self.rt.client_events('w_creators:client:selectSpawn')[-1].args[1]
        self.assertIsNone(payload.last)
        r = self.choose('__last')
        self.assertTrue(r.ok, r.code)
        self.assertAlmostEqual(r.data.pos.x, -274.09)                         # the first enabled point

    def test_last_location_valid_and_when_disabled(self):
        self.rt.run('lastPos = { x = 1230.0, y = -1290.0, z = 76.0, heading = 33.0 }')
        self.activate()
        payload = self.rt.client_events('w_creators:client:selectSpawn')[-1].args[1]
        self.assertEqual((payload.last.x, payload.last.label), (1230.0, 'رودز'))
        self.rt.run('Config.Services.lastLocation = false')
        self.assertEqual(self.choose('__last').code, 'INVALID_SPAWN')
        self.rt.run('Config.Services.lastLocation = true')
        self.later()
        r = self.choose('__last')
        self.assertEqual((r.data.pos.x, r.data.pos.heading), (1230.0, 33.0))

    def test_validate_last(self):
        v = self.e('WCSpawnServer.validateLast')
        for bad in ('{ x = 1/0, y = 1, z = 1 }', '{ x = 0, y = 0, z = 0 }', '{ x = -561.0, y = -3776.0, z = 239.0 }',
                    '{ x = 1, y = 1, z = 9000 }', '"str"', '{ x = "a", y = 1, z = 1 }'):
            self.assertIsNone(v(self.e(bad)), bad)
        self.assertEqual(v(self.e('{ x = "5", y = 6, z = 7, w = 90 }')).heading, 90)

    def test_spawn_event_and_direct_paths(self):
        self.rt.run('Config.Creator.spawnEvent = "rsg-multicharacter:client:spawnDefault"')
        self.assertTrue(self.call('scene:prepare', 1).ok)
        r = self.activate()
        self.assertEqual(r.data.spawn, 'event')
        self.assertEqual(len(self.rt.client_events('rsg-multicharacter:client:spawnDefault')), 1)
        self.assertEqual(self.bucket(), 0)
        self.assertIsNone(self.e('SpawnPending[1]'))
        self.rt.run('Config.Creator.spawnEvent = nil; Config.Services.spawnSelector = false')
        self.later()
        self.assertTrue(self.call('characters:list', 1).ok)                  # switch
        self.later()
        r = self.activate()
        self.assertEqual(r.data.spawn, 'direct')
        spawn = self.spawns()[-1]
        self.assertEqual(spawn.args[2].kind, 'switch')
        self.assertAlmostEqual(spawn.args[1].x, -274.09)

    def test_legacy_spawn_at(self):
        self.rt.run('fireEvent("w_creators:server:spawnAt", 1, "rhodes")')
        self.assertEqual(len(self.spawns()), 0)
        self.activate()
        self.rt.run('fireEvent("w_creators:server:spawnAt", 1, "nowhere")')
        self.assertAlmostEqual(self.spawns()[-1].args[1].x, -274.09)
        self.assertIsNone(self.e('SpawnPending[1]'))


class RespawnTests(Base):
    def events(self):
        return self.rt.client_events('w_creators:client:respawn')

    def command(self, src, *args):
        self.rt.run('Events.commands.wc_respawn.fn(%d, { %s })' % (src, ', '.join('"%s"' % a for a in args)))

    def test_console_and_ace_admins_respawn_an_active_player(self):
        self.command(0, '1')
        self.assertEqual(len(self.events()), 0)                               # no active character
        self.activate()
        self.command(0, '1')
        ev = self.events()[-1]
        self.assertEqual(ev.player, 1)
        self.assertAlmostEqual(ev.args[1].x, -274.09)
        self.assertEqual((ev.args[2].kind, ev.args[2].point), ('admin', 'valentine'))
        logs = [l for l in self.e('logs').values() if l.event == 'character_spawned']
        self.assertEqual(logs[-1].payload.adminSource, 0)
        self.assertEqual(logs[-1].payload.kind, 'admin')
        self.rt.run('function IsPlayerAceAllowed(src, ace) return src == 2 and ace == Config.Admin.ace end')
        self.command(2, '1', 'rhodes')
        self.assertAlmostEqual(self.events()[-1].args[1].x, 1233.28)
        self.command(2, '1', 'nowhere')
        self.assertEqual(len(self.events()), 2)
        self.assertEqual(self.e('Notifications[#Notifications].data.description'), 'مكان ظهور غير صالح')

    def test_non_admin_is_refused_and_logged(self):
        self.activate()
        self.command(2, '1')
        self.assertEqual(len(self.events()), 0)
        self.assertEqual(self.e('countLogs("security_violation")'), 1)
        self.assertEqual(self.e('#Notifications'), 0)
        for _ in range(20):                                                   # spam: rate-limited first
            self.command(2, '1')
        self.assertEqual(self.e('countLogs("security_violation")'), 5)
        self.assertEqual(self.e('#Notifications'), 0)
        self.assertEqual(self.e('WCRespawnServer.admin(0, "0").code'), 'INVALID_PAYLOAD')
        self.assertEqual(self.e('WCRespawnServer.admin(0, "1.5").code'), 'INVALID_PAYLOAD')


class SyncTests(Base):
    def test_late_joiners_receive_cached_appearances_rate_limited(self):
        self.activate()
        self.rt.run('fireEvent("w_creators:server:requestAppearances", 2)')
        sent = [e for e in self.rt.client_events('w_creators:client:applyRemoteAppearance') if e.player == 2]
        self.assertEqual(len(sent), 1)
        self.assertEqual(sent[0].args[1], 1)
        self.rt.run('fireEvent("w_creators:server:requestAppearances", 1)')      # own appearance not echoed
        self.assertEqual(len([e for e in self.rt.client_events('w_creators:client:applyRemoteAppearance')
                              if e.player == 1]), 0)
        for _ in range(3):
            self.rt.run('fireEvent("w_creators:server:requestAppearances", 2)')
        sent = [e for e in self.rt.client_events('w_creators:client:applyRemoteAppearance') if e.player == 2]
        self.assertEqual(len(sent), 2)                                         # 2 per 10 s

    def test_state_delta_updates_the_cache(self):
        self.activate()
        self.rt.run('WCSync.broadcastState(1, "hat", "off")')
        self.assertEqual(self.e('WCSync.get(1).clothing.states.hat'), 'off')
        ev = self.rt.client_events('w_creators:client:remoteClothingState')[-1]
        self.assertEqual((ev.player, ev.args[1], ev.args[2], ev.args[3]), (-1, 1, 'hat', 'off'))
        self.rt.run('fireEvent("playerDropped", 1)')
        self.assertEqual(self.rt.client_events('w_creators:client:forgetRemote')[-1].args[1], 1)

    def test_reload_is_rate_limited_and_shared_with_the_legacy_event(self):
        self.assertEqual(self.call('appearance:reload', 1).code, 'NO_CHARACTER')
        self.later()
        self.activate()
        before = len(self.rt.client_events('w_creators:client:applyRemoteAppearance'))
        r = self.call('appearance:reload', 1)
        self.assertTrue(r.ok, r.code)
        self.assertEqual(r.data.appearance.sex, 'male')
        self.assertEqual(len(self.rt.client_events('w_creators:client:applyRemoteAppearance')), before + 1)
        self.assertEqual(self.call('appearance:reload', 1).code, 'RATE_LIMITED')
        self.rt.run('fireEvent("PersonaCreatorHandler.reloadCharacterAppearance", 1)')
        self.assertEqual(len(self.rt.client_events('w_creators:client:applyAppearance')), 0)
        self.later(10000)
        self.rt.run('fireEvent("PersonaCreatorHandler.reloadCharacterAppearance", 1)')
        own = self.rt.client_events('w_creators:client:applyAppearance')
        self.assertEqual(len(own), 1)
        self.assertEqual(own[0].player, 1)
        self.assertEqual(self.call('appearance:reload', 1).code, 'RATE_LIMITED')

    def test_reload_refused_during_a_session(self):
        self.activate()
        self.rt.run('Players[1].coords = vector3(-326.17, 773.757, 117.5)')
        self.later()
        self.assertTrue(self.e('WCSessions.open(1, "store", { locationId = "valentine_clothing" }).ok'))
        self.assertEqual(self.call('appearance:reload', 1).code, 'BUSY')


class RecoveryTests(unittest.TestCase):
    def test_restart_adopts_framework_characters_once_the_database_is_ready(self):
        from harness import Runtime, manifest_scripts
        from test_server_characters_flow import WANTED, SETUP, fake_ownership
        rt = Runtime().load_shared()
        for path in manifest_scripts('server'):
            if path.startswith(WANTED):
                rt.load(path)
        fake_ownership(rt)
        rt.run(SETUP)
        rt.run('charids[1] = "vorp:1"')                 # the framework still has player 1 logged in
        self.assertIsNone(rt.eval('WCCharacters.active(1)'))
        rt.run('FakeDB.fireReady(); tick(200)')
        self.assertEqual(rt.eval('WCCharacters.active(1).charid'), 'vorp:1')
        self.assertEqual(rt.eval('WCSync.get(1).sex'), 'male')
        # an adopted character can re-enter the selection with allowSwitch off only while the
        # restarted client reopens it (a short window), not for the rest of the session
        rt.run('Config.Characters.allowSwitch = false')
        rt.run('Clock.now = Clock.now + 121000')
        self.assertEqual(rt.eval('cb("characters:list", 1).code'), 'SERVICE_DISABLED')
        self.assertEqual(rt.eval('WCCharacters.active(1).charid'), 'vorp:1')

    def _restart(self):
        from harness import Runtime, manifest_scripts
        from test_server_characters_flow import WANTED, SETUP, fake_ownership
        rt = Runtime().load_shared()
        for path in manifest_scripts('server'):
            if path.startswith(WANTED):
                rt.load(path)
        fake_ownership(rt)
        rt.run(SETUP)
        rt.run('charids[1] = "vorp:1"')
        return rt

    def test_adopted_character_may_reselect_right_after_the_restart(self):
        rt = self._restart()
        rt.run('FakeDB.fireReady(); tick(200)')
        rt.run('Config.Characters.allowSwitch = false')
        self.assertTrue(rt.eval('cb("characters:list", 1).ok'))
        self.assertIsNone(rt.eval('WCCharacters.active(1)'))

    def test_player_dropping_during_the_adoption_load_is_not_adopted(self):
        rt = self._restart()
        rt.run(r'''
            local load = WCAppearanceRepo.load
            WCAppearanceRepo.load = function(...) Wait(100) return load(...) end
            FakeDB.fireReady()
            tick(10)
            Players[1] = nil
            fireEvent("playerDropped", 1)
            tick(0) tick(200) tick(200)
        ''')
        self.assertIsNone(rt.eval('WCCharacters.active(1)'))
        self.assertIsNone(rt.eval('WCCharacters.ownerOf("vorp:1")'))
        self.assertIsNone(rt.eval('WCSync.get(1)'))


if __name__ == '__main__':
    unittest.main()
