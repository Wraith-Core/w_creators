"""Remote appearance sync (client/appearance/sync.lua, ARCHITECTURE.md §9.4): the scope watcher
re-applies a cached appearance once per ped handle, clothing states update the cache, our own
appearance is queue-serialised and skipped while an editor is open."""
import unittest

from test_client_infra_support import make_client

SETUP = r'''
app = AppearanceSchema.default('male')
app.clothing.equipped.hats = WCCatalog.forSex('male').hats.models[1][1].hash
remote = makePed('mp_male', 10.0, 0.0, 0.0)
RemotePlayers[5] = remote
function fire(name, ...) fireEvent(name, nil, ...) end
'''


class SyncTests(unittest.TestCase):
    def setUp(self):
        self.rt = make_client()
        self.e = self.rt.eval
        self.run = self.rt.run
        self.run(SETUP)

    def renders(self):
        return self.e('count("preset")')

    def test_initial_request_after_session_start(self):
        self.assertEqual(self.e('count("TriggerServerEvent:w_creators:server:requestAppearances")'), 1)

    def test_applies_once_and_again_only_when_the_ped_changes(self):
        self.run('clearLog(); fire("w_creators:client:applyRemoteAppearance", 5, app)')
        self.assertEqual(self.renders(), 1)
        self.assertEqual(self.e('Log[indexOf("preset")].args[1]'), self.e('remote'))
        self.run('Appearance.Sync.tick(); Appearance.Sync.tick()')
        self.assertEqual(self.renders(), 1)
        # respawned: a new ped handle
        self.run('respawned = makePed("mp_male"); RemotePlayers[5] = respawned; tick(1000)')
        self.assertEqual(self.renders(), 2)
        self.assertEqual(self.e('Log[#Log].args[1]'), self.e('respawned'))
        self.run('tick(1000); tick(1000)')
        self.assertEqual(self.renders(), 2)

    def test_leaving_and_reentering_scope_reapplies(self):
        self.run('clearLog(); fire("w_creators:client:applyRemoteAppearance", 5, app)')
        self.run('RemotePlayers[5] = nil; tick(1000)')
        self.assertEqual(self.renders(), 1)
        # back in scope, even with the same handle number
        self.run('RemotePlayers[5] = remote; tick(1000)')
        self.assertEqual(self.renders(), 2)

    def test_appears_later_in_scope(self):
        self.run('RemotePlayers[7] = nil; clearLog(); fire("w_creators:client:applyRemoteAppearance", 7, app)')
        self.assertEqual(self.renders(), 0)
        self.run('p7 = makePed("mp_male"); RemotePlayers[7] = p7; tick(1000)')
        self.assertEqual(self.renders(), 1)

    def test_own_server_id_is_skipped(self):
        self.run('clearLog(); fire("w_creators:client:applyRemoteAppearance", MyServerId, app); tick(1000)')
        self.assertEqual(self.renders(), 0)
        self.assertIsNone(self.e('Appearance.Sync.get(MyServerId)'))

    def test_clothing_state_updates_the_cache_without_rerender(self):
        self.run('fire("w_creators:client:applyRemoteAppearance", 5, app); clearLog()')
        self.run('fire("w_creators:client:remoteClothingState", 5, "hat", "off")')
        self.assertEqual(self.renders(), 0)
        self.assertEqual(self.e('Log[1].op'), 'component.remove')
        self.assertEqual(self.e('Log[1].args[2]'), 'hats')
        self.assertEqual(self.e('count("updateVariation")'), 1)
        self.assertEqual(self.e('Appearance.Sync.get(5).clothing.states.hat'), 'off')
        self.run('tick(1000)')
        self.assertEqual(self.renders(), 0)
        # invalid values are ignored
        self.run('fire("w_creators:client:remoteClothingState", 5, "hat", "sideways")')
        self.assertEqual(self.e('Appearance.Sync.get(5).clothing.states.hat'), 'off')

    def test_state_before_render_is_part_of_the_next_render(self):
        self.run('RemotePlayers[5] = nil; fire("w_creators:client:applyRemoteAppearance", 5, app)')
        self.run('fire("w_creators:client:remoteClothingState", 5, "hat", "off")')
        self.run('RemotePlayers[5] = remote; clearLog(); tick(1000)')
        self.assertEqual(self.renders(), 1)
        self.assertEqual(self.e('''(function() for _, e in ipairs(Log) do
            if e.op == "component.apply" and e.args[2] == "hats" then return true end end return false end)()'''), False)

    def test_legacy_remote_payload_is_normalised(self):
        self.run('clearLog(); fire("w_creators:client:applyRemoteAppearance", 5, AppearanceSchema.toLegacy(app))')
        self.assertEqual(self.renders(), 1)
        self.assertEqual(self.e('Appearance.Sync.get(5).version'), 3)
        self.run('fire("w_creators:client:applyRemoteAppearance", 6, 42)')
        self.assertIsNone(self.e('Appearance.Sync.get(6)'))

    def test_forget(self):
        self.run('fire("w_creators:client:applyRemoteAppearance", 5, app); fire("w_creators:client:forgetRemote", 5)')
        self.run('respawned = makePed("mp_male"); RemotePlayers[5] = respawned; clearLog(); tick(1000)')
        self.assertEqual(self.renders(), 0)
        self.assertIsNone(self.e('Appearance.Sync.get(5)'))

    def test_failures_are_retried_then_given_up(self):
        # a female appearance on a (still) male ped: MODEL_MISMATCH, retried a bounded number of times
        self.run('clearLog(); fire("w_creators:client:applyRemoteAppearance", 5, AppearanceSchema.default("female"))')
        for _ in range(10):
            self.run('tick(1000)')
        self.assertEqual(self.renders(), 0)
        # the model switches: the new ped handle renders
        self.run('fp = makePed("mp_female"); RemotePlayers[5] = fp; tick(1000)')
        self.assertEqual(self.renders(), 1)

    def test_given_up_player_renders_again_after_reentering_scope_with_the_same_handle(self):
        self.run('Peds[remote].ready = false; clearLog(); fire("w_creators:client:applyRemoteAppearance", 5, app)')
        for _ in range(200):
            self.run('tick(1000)')
        attempts = self.renders()
        self.assertEqual(attempts, self.e('Appearance.Sync.MAX_FAILURES'))
        # given up: no more attempts on that fingerprint
        self.run('tick(1000); tick(1000)')
        self.assertEqual(self.renders(), attempts)
        # out of scope for one pass, then back with the same handle (now rendering)
        self.run('RemotePlayers[5] = nil; tick(1000); Peds[remote].ready = true; RemotePlayers[5] = remote')
        self.run('clearLog(); tick(1000); tick(1000)')
        self.assertEqual(self.renders(), 1)
        self.assertEqual(self.e('Log[indexOf("preset")].args[1]'), self.e('remote'))

    def test_watcher_does_not_rerender_during_a_state_refresh(self):
        self.run('fire("w_creators:client:applyRemoteAppearance", 5, app); clearLog()')
        # the refresh of the state blocks (ped not ready) while the watcher runs
        self.run('''Peds[remote].ready = false
            CreateThread(function() fire("w_creators:client:remoteClothingState", 5, "hat", "off") end)
            tick(1000)''')
        self.assertEqual(self.renders(), 0)
        self.run('Peds[remote].ready = true; tick(20000); tick(1000)')
        self.assertEqual(self.renders(), 0)
        self.assertEqual(self.e('count("updateVariation")'), 1)

    def test_state_during_a_render_is_rendered_by_the_next_pass(self):
        # a render is running (ped not ready) when the state arrives: no direct state on top of it
        self.run('''Peds[remote].ready = false; clearLog()
            CreateThread(function() fire("w_creators:client:applyRemoteAppearance", 5, app) end)
            fire("w_creators:client:remoteClothingState", 5, "hat", "off")''')
        self.run('Peds[remote].ready = true; tick(30000); tick(1000); tick(1000)')
        self.assertEqual(self.renders(), 2)
        self.assertEqual(self.e('''(function() local n = 0 for i = indexOf("preset", 2) or 1, #Log do
            local e = Log[i] if e.op == "preset" then n = i end end
            for i = n, #Log do local e = Log[i]
                if e.op == "component.apply" and e.args[2] == "hats" then return true end end
            return false end)()'''), False)
        self.assertEqual(self.e('Appearance.Sync.get(5).clothing.states.hat'), 'off')


class OwnAppearanceTests(unittest.TestCase):
    def setUp(self):
        self.rt = make_client()
        self.e = self.rt.eval
        self.run = self.rt.run
        self.run(SETUP)

    def test_apply_appearance_renders_our_ped_and_stores_it(self):
        self.run('clearLog(); fire("w_creators:client:applyAppearance", app)')
        self.assertEqual(self.e('count("preset")'), 1)
        self.assertEqual(self.e('Log[indexOf("preset")].args[1]'), self.e('MyPed'))
        self.assertTrue(self.e('AppearanceSchema.equal(WCState.appearance, app)'))

    def test_legacy_alias_and_legacy_payload(self):
        self.run('clearLog(); fire("PersonaCreatorHandler.applyCharacterAppearance", AppearanceSchema.toLegacy(app))')
        self.assertEqual(self.e('count("preset")'), 1)
        self.assertEqual(self.e('WCState.appearance.version'), 3)

    def test_skipped_while_in_editor(self):
        self.run('WCState.busy("editor", true); clearLog(); fire("w_creators:client:applyAppearance", app)')
        self.assertEqual(self.e('count("preset")'), 0)
        self.assertTrue(self.e('AppearanceSchema.equal(WCState.appearance, app)'))
        self.run('WCState.busy("editor", false); WCEditor = { session = function() return { id = 1 } end }')
        self.run('clearLog(); fire("w_creators:client:applyAppearance", app)')
        self.assertEqual(self.e('count("preset")'), 0)

    def test_queue_keeps_only_the_newest(self):
        # the first application blocks on readiness inside a thread; two more arrive meanwhile
        self.run('''Peds[MyPed].ready = false; clearLog()
            female = AppearanceSchema.default("female")
            CreateThread(function() fire("w_creators:client:applyAppearance", app) end)
            fire("w_creators:client:applyAppearance", female)
            fire("w_creators:client:applyAppearance", app)''')
        self.assertTrue(self.e('Appearance.Sync.applyingOwn()'))
        self.assertEqual(self.e('count("preset")'), 1)
        self.run('Peds[MyPed].ready = true; tick(20000)')
        self.assertFalse(self.e('Appearance.Sync.applyingOwn()'))
        # first + only the newest queued one (the female one was superseded)
        self.assertEqual(self.e('count("preset")'), 2)
        self.assertEqual(self.e('count("SetPlayerModel")'), 0)


if __name__ == '__main__':
    unittest.main()
