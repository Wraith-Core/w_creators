"""Server services: hair and beard growth (server/barber/grooming.lua)."""
import unittest

from test_server_services_barber import services_server

HELPERS = r'''
function step(seconds)
    Clock.now = Clock.now + seconds * 1000
    WCGroomingServer.tick()
end
function saves()
    local n = 0
    for _, tx in ipairs(FakeDB.transactions) do
        if tx[1] and tx[1].query:find('UPDATE characters_appearence SET appearance', 1, true) then n = n + 1 end
    end
    return n
end
function reads() return FakeDB.count('SELECT %* FROM characters_appearence') end
'''


class GroomingTests(unittest.TestCase):
    def setUp(self):
        self.rt = services_server()
        self.e = self.rt.eval
        self.rt.run(HELPERS)
        # growth ships off (config/barber.lua); these tests cover the feature, which stays in the code
        self.rt.run('Config.Grooming.enabled = true; Config.Grooming.saveIntervalSeconds = 300')

    def test_saves_only_at_the_interval_without_per_tick_database_access(self):
        self.rt.run('step(0)')  # starts tracking
        self.assertIsNotNone(self.e('WCGroomingServer.pending(1)'))
        reads = self.e('reads()')
        for _ in range(9):     # 270 s: below the interval, no stage change (hair 120 min, beard 60 min)
            self.rt.run('step(30)')
        self.assertEqual(self.e('saves()'), 0)
        self.assertLessEqual(self.e('reads()'), reads + 1)  # the first probe may fill the cache
        self.assertEqual(self.e('WCGroomingServer.pending(1).seconds'), 270)
        self.rt.run('step(30)')  # 300 s -> interval save
        self.assertEqual(self.e('saves()'), 1)
        self.assertEqual(self.e('WCGroomingServer.pending(1).seconds'), 0)
        self.assertEqual(self.e('lastSaved().grooming.hair.seconds'), 300)
        self.assertEqual(self.e('lastSaved().grooming.beard.seconds'), 300)
        # an interval save is silent: the style did not change
        self.assertEqual(len(self.rt.client_events('w_creators:client:grooming')), 0)
        reads = self.e('reads()')
        for _ in range(5):
            self.rt.run('step(30)')
        self.assertEqual(self.e('reads()'), reads)
        self.assertEqual(self.e('saves()'), 1)

    def test_stage_change_saves_and_notifies(self):
        self.rt.run('Config.Grooming.minutesPerStage.hair = 1; Config.Grooming.saveIntervalSeconds = 3600')
        before = self.e('savedApp.hair.style')
        self.rt.run('step(0); step(30)')
        self.assertEqual(self.e('saves()'), 0)
        self.rt.run('step(30)')  # 60 s -> hair stage 2
        self.assertEqual(self.e('saves()'), 1)
        self.rt.run('saved = lastSaved()')
        self.assertEqual(self.e('saved.grooming.hair.stage'), 2)
        self.assertNotEqual(self.e('saved.hair.style'), before)
        self.assertTrue(self.e('WCCatalog.item("male", saved.hair.style).name:upper():find("HAIR_006_BLONDE", 1, true) ~= nil'))
        events = self.rt.client_events('w_creators:client:grooming')
        self.assertEqual(len(events), 1)
        self.assertEqual(events[0].player, 1)
        self.assertEqual(len(self.rt.client_events('w_creators:client:applyRemoteAppearance')), 1)

    def test_paused_outside_the_main_world_in_a_session_or_spawn(self):
        self.rt.run('step(0); step(30)')
        self.assertEqual(self.e('WCGroomingServer.pending(1).seconds'), 30)
        self.rt.run('Players[1].bucket = 5; step(30); step(30)')
        self.assertEqual(self.e('WCGroomingServer.pending(1).seconds'), 30)
        self.rt.run('Players[1].bucket = 0; step(30)')  # resumes without counting the paused time
        self.assertEqual(self.e('WCGroomingServer.pending(1).seconds'), 30)
        self.rt.run('step(30)')
        self.assertEqual(self.e('WCGroomingServer.pending(1).seconds'), 60)
        self.rt.run('SpawnPending[1] = true; step(30); SpawnPending[1] = nil; step(30)')
        self.assertEqual(self.e('WCGroomingServer.pending(1).seconds'), 60)
        self.rt.run('Players[1].coords = vector3(-307.51, 813.96, 118.99); o = WCBarberService.open(1, "valentine_barber")')
        self.assertTrue(self.e('o.ok'))
        self.rt.run('step(30); step(30)')
        self.assertEqual(self.e('WCGroomingServer.pending(1).seconds'), 60)
        self.rt.run('Config.Grooming.enabled = false; WCSessions.clear(1); step(30)')
        self.assertIsNone(self.e('WCGroomingServer.pending(1)'))

    def test_elapsed_time_is_capped_per_tick(self):
        self.rt.run('Config.Grooming.saveIntervalSeconds = 3600; step(0); step(600)')
        self.assertEqual(self.e('WCGroomingServer.pending(1).seconds'), 60)

    def test_no_character_no_growth(self):
        self.rt.run('charids[1] = nil; step(0); step(30)')
        self.assertIsNone(self.e('WCGroomingServer.pending(1)'))

    def test_drop_writes_the_pending_growth(self):
        self.rt.run('step(0); step(30); step(30); Clock.now = Clock.now + 10000')
        self.rt.run('fireEvent("playerDropped", 1)')
        self.assertEqual(self.e('saves()'), 1)
        self.assertIsNone(self.e('WCGroomingServer.pending(1)'))
        tx = self.e('FakeDB.transactions[1][1]')
        self.assertIn('"seconds":70', tx['values'][1].replace(' ', ''))
        self.assertIsNone(self.e('WCAppearanceRepo.cache["vorp:1"]'))

    def test_character_switch_writes_the_leaving_character(self):
        self.rt.run('step(0); step(30)')
        self.rt.run('TriggerEvent("w_creators:server:characterCleared", 1, "vorp:1", "switch")')
        self.assertEqual(self.e('saves()'), 1)
        self.assertIsNone(self.e('WCGroomingServer.pending(1)'))
        # a different active character on the next tick starts from zero
        self.rt.run('''
            charids[1] = "vorp:2"
            rows["vorp:2"] = { id = 12, charid = "vorp:2", appearance = json.encode(S.default("male")), appearance_version = 3 }
            step(30)
        ''')
        self.assertEqual(self.e('WCGroomingServer.pending(1).charid'), 'vorp:2')
        self.assertEqual(self.e('WCGroomingServer.pending(1).seconds'), 0)

    def test_character_change_between_ticks_flushes(self):
        self.rt.run('step(0); step(30); charids[1] = "vorp:2"')
        self.rt.run('rows["vorp:2"] = { id = 12, charid = "vorp:2", appearance = json.encode(S.default("male")), appearance_version = 3 }')
        self.rt.run('step(30)')
        self.assertEqual(self.e('saves()'), 1)
        self.assertEqual(self.e('FakeDB.transactions[1][1].values[8]'), 'vorp:1')

    def test_activation_tracks_at_once_and_writes_a_leftover_character(self):
        self.rt.run('TriggerEvent("w_creators:server:characterActivated", 1, "vorp:1", "male")')
        self.assertEqual(self.e('WCGroomingServer.pending(1).charid'), 'vorp:1')
        self.assertTrue(self.e('WCGroomingServer.pending(1).paused'), 'paused until a tick finds it eligible')
        self.rt.run('step(0); step(30)')
        self.assertEqual(self.e('WCGroomingServer.pending(1).seconds'), 30)
        # a repeated activation of the same character keeps the counter
        self.rt.run('TriggerEvent("w_creators:server:characterActivated", 1, "vorp:1", "male")')
        self.assertEqual(self.e('WCGroomingServer.pending(1).seconds'), 30)
        # another character activated without a clear: the leftover growth is written first
        self.rt.run('rows["vorp:2"] = { id = 12, charid = "vorp:2", appearance = json.encode(S.default("male")), appearance_version = 3 }')
        self.rt.run('charids[1] = "vorp:2"; TriggerEvent("w_creators:server:characterActivated", 1, "vorp:2", "male"); tick(1000)')
        self.assertEqual(self.e('saves()'), 1)
        self.assertEqual(self.e('WCGroomingServer.pending(1).charid'), 'vorp:2')

    def test_a_locked_character_defers_the_write(self):
        self.rt.run('Config.Grooming.saveIntervalSeconds = 30; step(0); CreatorAppearanceLocks["vorp:1"] = "other"; step(30); step(30)')
        self.assertEqual(self.e('saves()'), 0)
        self.assertEqual(self.e('WCGroomingServer.pending(1).seconds'), 60)
        self.rt.run('CreatorAppearanceLocks["vorp:1"] = nil; step(30)')
        self.assertEqual(self.e('saves()'), 1)
        self.assertIsNone(self.e('CreatorAppearanceLocks["vorp:1"]'))

    def test_database_failure_keeps_the_growth(self):
        self.rt.run('Config.Grooming.saveIntervalSeconds = 30; FakeDB.transactionOk = false; step(0); step(30)')
        self.assertEqual(self.e('WCGroomingServer.pending(1).seconds'), 30)
        self.rt.run('FakeDB.transactionOk = true; step(30)')
        self.assertEqual(self.e('WCGroomingServer.pending(1).seconds'), 0)
        self.assertEqual(self.e('lastSaved().grooming.hair.seconds'), 60)

    def test_degraded_appearance_never_grows(self):
        self.rt.run('''
            local broken = S.default("male"); broken.head.head = 1
            rows["vorp:1"].appearance = json.encode(broken); WCAppearanceRepo.invalidate("vorp:1")
            Config.Grooming.saveIntervalSeconds = 30
            step(0); step(30); step(30)
        ''')
        self.assertEqual(self.e('saves()'), 0)

    def grow(self, ticks=9):
        self.rt.run('Config.Grooming.saveIntervalSeconds = 3600; step(0)')
        for _ in range(ticks):
            self.rt.run('step(30)')
        self.assertEqual(self.e('WCGroomingServer.pending(1).seconds'), ticks * 30)

    def barber(self, edit):
        self.rt.run('WCSecurity.clear(1); o = WCBarberService.open(1, "valentine_barber")')
        self.assertTrue(self.e('o.ok'), self.e('o.code'))
        self.rt.run('app = WCUtil.copy(o.data.appearance); %s; c = WCBarberService.commit(1, o.data.token, "op", app)' % edit)
        return self.e('c')

    def test_haircut_keeps_the_growth_of_the_kind_not_cut(self):
        self.grow()
        c = self.barber('app.hair.style = h("male", "hair", 3)')
        self.assertTrue(c.ok, c.code)
        self.assertEqual(c.data.charged, 10)  # growth is free
        self.assertEqual(self.e('lastSaved().grooming.hair.seconds'), 0)
        self.assertEqual(self.e('lastSaved().grooming.beard.seconds'), 270)
        self.assertEqual(self.e('WCGroomingServer.pending(1).seconds'), 0)
        self.assertEqual(self.e('c.data.appearance.grooming.beard.seconds'), 270)

    def test_beard_trim_keeps_the_hair_growth(self):
        self.grow()
        c = self.barber('app.hair.facial = h("male", "mustache", 2)')
        self.assertTrue(c.ok, c.code)
        self.assertEqual(self.e('lastSaved().grooming.hair.seconds'), 270)
        self.assertEqual(self.e('lastSaved().grooming.beard.seconds'), 0)

    def test_folded_growth_may_advance_a_stage_of_the_kind_not_cut(self):
        before = self.e('savedApp.hair.facial')
        self.grow()  # 270 s pending
        self.rt.run('Config.Grooming.minutesPerStage.beard = 4')  # 240 s: the pending growth crosses a stage
        c = self.barber('app.hair.style = h("male", "hair", 3)')
        self.assertTrue(c.ok, c.code)
        self.assertEqual(c.data.charged, 10)  # the grown beard is not a paid service
        self.assertEqual(list(self.rt.py(c.data.sections).values()), ['hair'])
        self.assertEqual(self.e('lastSaved().grooming.beard.stage'), 1)  # clean shaven (0) -> stubble (1)
        self.assertEqual(self.e('lastSaved().grooming.beard.seconds'), 30)
        self.assertNotEqual(self.e('lastSaved().hair.facial'), before)
        self.assertEqual(self.e('lastSaved().grooming.hair.seconds'), 0)

    def test_refused_or_failed_commit_keeps_the_counter(self):
        self.grow()
        self.rt.run('FakeUsers[1].money = 0')
        c = self.barber('app.hair.style = h("male", "hair", 3)')
        self.assertEqual(c.code, 'INSUFFICIENT_FUNDS')
        self.assertEqual(self.e('WCGroomingServer.pending(1).seconds'), 270)
        self.rt.run('WCSessions.clear(1); FakeUsers[1].money = 100; FakeDB.transactionOk = false')
        c = self.barber('app.hair.style = h("male", "hair", 3)')
        self.assertEqual(c.code, 'DATABASE_ERROR')
        self.assertEqual(self.e('WCGroomingServer.pending(1).seconds'), 270)

    def test_surgery_saves_the_growth_of_both_kinds(self):
        self.grow()
        self.rt.run('''
            Players[1].coords = vector3(-284.49, 807.49, 119.38); FakeUsers[1].money = 1000
            WCSurgeryService.grant(1, "valentine_surgery"); o = WCSurgeryService.open(1, "valentine_surgery")
            app = WCUtil.copy(o.data.appearance); app.morph.jawWidth = 0.5
            c = WCSurgeryService.commit(1, o.data.token, "op", app)
        ''')
        self.assertTrue(self.e('c.ok'), self.e('c.code'))
        self.assertEqual(self.e('lastSaved().grooming.hair.seconds'), 270)
        self.assertEqual(self.e('lastSaved().grooming.beard.seconds'), 270)
        self.assertEqual(self.e('WCGroomingServer.pending(1).seconds'), 0)

    def test_fold_never_grows_a_degraded_appearance(self):
        self.grow()
        self.rt.run('a = WCUtil.copy(savedApp); n = WCGroomingServer.fold("vorp:1", a, savedApp, { degraded = true })')
        self.assertEqual(self.e('n'), 0)
        self.assertEqual(self.e('WCGroomingServer.fold("nobody", WCUtil.copy(savedApp), savedApp, {})'), 0)

    def test_thread_drives_the_ticks(self):
        self.rt.run('tick(0); tick(WCGroomingServer.TICK_MS); tick(WCGroomingServer.TICK_MS)')
        self.assertEqual(self.e('WCGroomingServer.pending(1).seconds'), 30)


if __name__ == '__main__':
    unittest.main()
