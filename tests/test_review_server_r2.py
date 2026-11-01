"""Review round 2 — server fixes (regressions for the confirmed server defects).

1  a character switch belongs to the character scene: it lapses outside it (the framework
   character becomes active again) and the §9.1 death / session checks hold for every step
2  hunger / thirst are set after a creation only (a login or a switch is never a free refill)
3  the legacy spawnAt event is rate-limited before its access-denied log, and the logged id clamped
4  outfit writes follow the wardrobe location's hours / enabled flag (as the wardrobe commit)
5  a stored dye that the live tint config no longer allows survives store, wardrobe and surgery
6  a grooming stage (and a reload / ApplyCharacterAppearance) keeps the runtime clothing states
7  a degraded legacy character gets its 'legacy' ownership in the explicit repair save
8  NULL / undecodable legacy columns never overwrite an intact v3 appearance
9  a recorded migration whose schema is gone is applied again (waitReady tells the truth)
10 rsg / qbr character cards carry the balances (central ledger > stock players.money; never
   w_core's stale column)
11 the barber growth plate is sent only while grooming runs, and marks the last stage
"""
import json
import os
import sys
import unittest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from harness import Runtime  # noqa: E402
from test_server_characters_flow import server_runtime  # noqa: E402
from test_server_characters_world import ENTITIES  # noqa: E402
from test_server_commerce_store import commerce  # noqa: E402
from test_server_commerce_wardrobe import wardrobe  # noqa: E402
from test_server_services_barber import services_server  # noqa: E402
from test_server_core import server as core_server  # noqa: E402
from test_review_server_r1 import STORE_ROW  # noqa: E402


class Flow(unittest.TestCase):
    def setUp(self):
        self.rt = server_runtime()
        self.rt.run(ENTITIES)
        self.e = self.rt.eval
        self.cb = self.e('cb')

    def call(self, name, src, *args):
        return self.cb(name, src, *args)

    def later(self, ms=11000):
        self.rt.run('Clock.now = Clock.now + %d' % ms)

    def past_grace(self):
        self.later(self.e('WCScene.ROOM_GRACE_MS') + 1000)

    def activate(self, src=1, charid='vorp:1'):
        self.assertTrue(self.call('characters:select', src, charid).ok)
        r = self.call('characters:loaded', src)
        self.assertTrue(r.ok, r.code)
        return r

    def in_world(self):
        self.activate()
        self.rt.run('WCSpawnServer.cancel(1); WCScene.toWorld(1); Players[1].coords = vector3(1230.0, -1290.0, 76.0)')
        self.later()

    def active(self):
        a = self.e('WCCharacters.active(1)')
        return a.charid if a else None


# ---------------------------------------------------------------------------------------------
# 1  A switch belongs to the character scene
# ---------------------------------------------------------------------------------------------
class SwitchSceneTests(Flow):
    def test_death_is_checked_again_while_the_switch_is_open(self):
        self.in_world()
        self.assertTrue(self.call('characters:list', 1).ok)        # an injected list: switch started in the world
        self.assertIsNone(self.active())
        self.rt.run('dead[1] = true')
        self.later()
        self.assertEqual(self.call('characters:select', 1, 'vorp:1').code, 'BUSY')
        self.assertEqual(self.call('characters:beginCreate', 1).code, 'BUSY')
        self.assertEqual(self.call('characters:list', 1).code, 'BUSY')
        self.assertEqual(self.e('#loginCalls'), 1, 'no second framework login')
        self.assertIsNone(self.e('WCSpawnServer.pending(1)'))

    def test_the_death_owner_is_asked_again_too(self):
        self.in_world()
        self.assertTrue(self.call('characters:list', 1).ok)
        self.rt.run('''
            local base = GetResourceState
            GetResourceState = function(n) if n == 'w_medic' then return 'started' end return base(n) end
            exports = setmetatable({}, { __index = function(_, res) return setmetatable({}, { __index = function(_, name)
                return function(self, id) return res == 'w_medic' and name == 'IsDead' and id == 1 end
            end }) end })
        ''')
        self.later()
        self.assertEqual(self.call('characters:select', 1, 'vorp:2').code, 'BUSY')

    def test_a_switch_outside_the_scene_lapses_and_restores_the_character(self):
        self.in_world()
        self.assertTrue(self.call('characters:list', 1).ok)
        self.assertIsNone(self.e('WCSessions.activeCharacter(1)'))
        self.rt.run('Clock.now = Clock.now + WCScene.ROOM_GRACE_MS - 1000; n0 = WCCharacters.checkSwitches()')
        self.assertEqual(self.e('n0'), 0, 'within the grace')
        self.assertTrue(self.e('WCCharacters.isSwitching(1)'))
        self.rt.run('Clock.now = Clock.now + 2000; n1 = WCCharacters.checkSwitches()')
        self.assertEqual(self.e('n1'), 1)
        self.assertEqual(self.active(), 'vorp:1')
        self.assertFalse(self.e('WCCharacters.isSwitching(1)'))
        self.assertEqual(self.e('WCSessions.activeCharacter(1).charid'), 'vorp:1')
        self.assertIsNotNone(self.e('WCSync.get(1)'), 'the look is broadcast again')
        self.assertEqual(self.rt.client_events('w_creators:client:applyRemoteAppearance')[-1].args[1], 1)
        self.assertIsNone(self.e('WCSpawnServer.pending(1)'), 'no spawn grant for a lapsed switch')
        # the §9.1 rules apply to the next attempt again
        self.rt.run('dead[1] = true')
        self.later()
        self.assertEqual(self.call('characters:select', 1, 'vorp:1').code, 'BUSY')
        self.assertEqual(self.active(), 'vorp:1')

    def test_the_periodic_thread_runs_the_check(self):
        self.in_world()
        self.assertTrue(self.call('characters:list', 1).ok)
        for _ in range(8):
            self.rt.run('tick(WCCharacters.SWITCH_CHECK_MS)')
        self.assertEqual(self.active(), 'vorp:1')

    def test_a_lapsed_switch_is_settled_by_the_next_callback(self):
        self.in_world()
        self.assertTrue(self.call('characters:list', 1).ok)
        self.past_grace()
        self.rt.run('dead[1] = true')
        self.assertEqual(self.call('characters:select', 1, 'vorp:1').code, 'BUSY')
        self.assertEqual(self.active(), 'vorp:1')
        self.assertEqual(self.call('characters:loaded', 1).code, 'NO_CHARACTER')
        self.assertEqual(len(self.rt.client_events('w_creators:client:spawn')), 0)

    def test_the_restart_window_does_not_last_through_a_lapsed_switch(self):
        self.rt.run('Config.Characters.allowSwitch = false; charids[1] = "vorp:1"')
        self.assertEqual(self.e('(WCCharacters.recover(1))'), 'active')
        self.rt.run('Players[1].coords = vector3(1230.0, -1290.0, 76.0)')
        self.assertTrue(self.call('characters:list', 1).ok)         # inside the 2-minute window
        self.later(3600 * 1000)
        self.rt.run('dead[1] = true')
        r = self.call('characters:select', 1, 'vorp:2')
        self.assertFalse(r.ok)
        self.assertIn(r.code, ('SERVICE_DISABLED', 'BUSY'))
        self.assertEqual(self.active(), 'vorp:1')
        self.assertEqual(self.call('characters:loaded', 1).code, 'NO_CHARACTER')
        self.assertEqual(self.e('#loginCalls'), 0)

    def test_a_selected_but_never_loaded_character_is_adopted_when_the_switch_lapses(self):
        self.rt.run("rows['vorp:2'] = { id = 12, charid = 'vorp:2', appearance = json.encode(S.default('female')), appearance_version = 3 }")
        self.in_world()
        r = self.call('characters:select', 1, 'vorp:2')             # an injected select starts the switch
        self.assertTrue(r.ok, r.code)
        self.assertEqual(self.e('charids[1]'), 'vorp:2')
        self.past_grace()
        self.rt.run('dead[1] = true')                                # died in the world meanwhile
        self.assertEqual(self.call('characters:loaded', 1).code, 'NO_CHARACTER')
        self.assertEqual(self.active(), 'vorp:2')
        self.assertIsNone(self.e('WCSpawnServer.pending(1)'))
        self.assertEqual(len(self.rt.client_events('w_creators:client:spawn')), 0)
        self.assertEqual(self.e('WCSync.get(1).sex'), 'female')

    def test_the_legitimate_switch_in_the_room_never_lapses(self):
        self.in_world()
        self.assertTrue(self.call('scene:prepare', 1).ok)
        self.rt.run('Players[1].coords = anchor')
        for _ in range(30):                                          # 2.5 minutes at the selection screen
            self.rt.run('tick(WCCharacters.SWITCH_CHECK_MS)')
        self.assertTrue(self.e('WCCharacters.isSwitching(1)'))
        self.assertEqual(self.e('Players[1].bucket'), 1)
        self.assertTrue(self.call('characters:list', 1).ok)
        self.later()
        self.assertTrue(self.call('characters:select', 1, 'vorp:1').ok)
        for _ in range(10):
            self.rt.run('tick(WCCharacters.SWITCH_CHECK_MS)')
        r = self.call('characters:loaded', 1)
        self.assertTrue(r.ok, r.code)
        self.assertEqual(r.data.spawn, 'selector')
        self.assertEqual(self.e('WCSpawnServer.pending(1)'), 'switch')


# ---------------------------------------------------------------------------------------------
# 2  Survival metadata after a creation only
# ---------------------------------------------------------------------------------------------
class SurvivalTests(Flow):
    def setUp(self):
        super().setUp()
        self.rt.run('survival = 0; Bridge.SetSurvival = function() survival = survival + 1 end')

    def test_login_and_switch_keep_the_needs(self):
        self.activate()
        self.assertEqual(self.e('survival'), 0)
        self.rt.run('SpawnPending[1] = nil')
        self.later()
        self.assertTrue(self.call('characters:list', 1).ok)
        self.later()
        self.activate()                                              # the same character again
        self.assertEqual(self.e('WCSpawnServer.pending(1)'), 'switch')
        self.assertEqual(self.e('survival'), 0)
        for kind in ('login', 'switch', 'death', 'admin'):
            self.rt.run('WCSpawnServer.finish(1, "%s", false)' % kind)
        self.assertEqual(self.e('survival'), 0)

    def test_a_new_character_gets_them(self):
        self.rt.run('WCSpawnServer.finish(1, "initial", true)')
        self.assertEqual(self.e('survival'), 1)
        self.rt.run('Bridge.FinishCharacter(1, true)')
        self.assertEqual(self.e('survival'), 2)


# ---------------------------------------------------------------------------------------------
# 3  Legacy spawnAt: rate limit first, clamped log
# ---------------------------------------------------------------------------------------------
class SpawnAtFloodTests(Flow):
    def test_an_ungranted_flood_is_rate_limited_and_clamped(self):
        self.rt.run('''
            spam = string.rep('@everyone ', 800)
            for _ = 1, 200 do fireEvent('w_creators:server:spawnAt', 1, spam) end
        ''')
        denied = [l for l in self.e('logs').values() if l.event == 'character_access_denied']
        self.assertLessEqual(len(denied), 5)
        self.assertGreaterEqual(len(denied), 1)
        for entry in denied:
            self.assertLessEqual(len(entry.payload.charid), 64)
        self.assertEqual(len(self.rt.client_events('w_creators:client:spawn')), 0)

    def test_a_granted_player_still_spawns(self):
        self.activate()
        self.later()
        self.rt.run('fireEvent("w_creators:server:spawnAt", 1, "valentine")')
        self.assertEqual(len(self.rt.client_events('w_creators:client:spawn')), 1)


# ---------------------------------------------------------------------------------------------
# 4  Outfit writes follow the wardrobe location
# ---------------------------------------------------------------------------------------------
class OutfitLocationTests(unittest.TestCase):
    def setUp(self):
        self.rt = wardrobe()
        self.e = self.rt.eval
        self.rt.run('''
            testHour = 21
            WCLocations.hour = function() return testHour end
            WCLocations.byId('valentine_wardrobe').hours = { open = 6, close = 22 }
            own('vorp:1', 'hats', hat)
            r = openWardrobe(1, 'valentine_wardrobe'); wardrobeToken = r.data.token
            eq = working().clothing.equipped
            eq.hats = hat
        ''')
        self.assertTrue(self.e('r.ok'), self.e('r.code'))

    def test_closed_after_the_open_refuses_like_the_commit(self):
        self.assertTrue(self.e('outfit("save", wardrobeToken, "day", eq, {}).ok'))
        self.rt.run('testHour = 22')
        # 1.0.6: closed by its hours is its own refusal (LOCATION_DISABLED = switched off)
        self.assertEqual(self.e('wear(working()).code'), 'LOCATION_CLOSED_HOURS')
        for op in ('outfit("save", wardrobeToken, "night", eq, {})',
                   'outfit("update", wardrobeToken, 1, eq, {})',
                   'outfit("rename", wardrobeToken, 1, "x")',
                   'outfit("delete", wardrobeToken, 1)'):
            self.assertEqual(self.e(op).code, 'LOCATION_CLOSED_HOURS', op)
        self.assertEqual(self.e('#outfitRows'), 1)
        self.rt.run('testHour = 7')                                 # open again, same session
        self.assertTrue(self.e('outfit("rename", wardrobeToken, 1, "morning").ok'))

    def test_a_disabled_location_refuses(self):
        self.rt.run("WCLocations.byId('valentine_wardrobe').enabled = false")
        self.assertEqual(self.e('outfit("save", wardrobeToken, "x", eq, {}).code'), 'LOCATION_DISABLED')
        self.assertEqual(self.e('#outfitRows'), 0)


# ---------------------------------------------------------------------------------------------
# 5  Stored dyes survive the live tint config
# ---------------------------------------------------------------------------------------------
DYE = "{ palette = 'metaped_tint_hat', tint0 = 10, tint1 = 20, tint2 = 30 }"


class StoredDyeCommerceTests(unittest.TestCase):
    def setUp(self):
        self.rt = commerce()
        self.e = self.rt.eval
        self.rt.run('''
            dyedHat = h('male', 'hats', 1)
            newBoots = h('male', 'boots', 2)
            base = S.default('male'); base.clothing.equipped.hats = dyedHat; base.clothing.tints.hats = %s
            own('vorp:1', 'hats', dyedHat, %s, 'store')
            own('vorp:1', 'boots', newBoots, nil, 'store')
            setSaved('vorp:1', base)
            Config.Clothing.tints.enabled = false
        ''' % (DYE, DYE))
        self.assertEqual(self.e('saved().clothing.tints.hats.tint1'), 20, 'the load keeps the stored dye')

    def test_a_store_purchase_with_the_dyed_hat_worn(self):
        self.rt.run('''
            r = openStore(); storeToken = r.data.token
            a = working(); a.clothing.equipped.boots = h('male', 'boots', 3)
            res = buy(a)
        ''')
        self.assertTrue(self.e('r.ok'), self.e('r.code'))
        self.assertTrue(self.e('res.ok'), self.e('res.code'))
        cats = [p.category for p in self.e('res.data.purchases').values()]
        self.assertEqual(cats, ['boots'], 'the unchanged dye is neither charged nor rewritten')
        self.assertEqual(self.e('saved().clothing.tints.hats.tint2'), 30)
        self.assertEqual(self.e('ownedRow("vorp:1", dyedHat).tint0'), 10)

    def test_a_new_tint_still_follows_the_live_config(self):
        self.rt.run('''
            r = openStore(); storeToken = r.data.token
            a = working(); a.clothing.tints.hats = { palette = 'metaped_tint_hat', tint0 = 1, tint1 = 2, tint2 = 3 }
            res = buy(a)
        ''')
        self.assertEqual(self.e('res.code'), 'INVALID_TINT')

    def test_the_wardrobe_keeps_the_dye(self):
        self.rt.run('''
            Players[1].coords = WARDROBE
            WCSecurity.clear(1)
            w1 = call('w_creators:wardrobe:open', 1, 'valentine_wardrobe')
            ownedList = WCOwnership.list('vorp:1')
            same = WCWardrobeService.plan(saved(), working(), ownedList)
            a = working(); a.clothing.equipped.boots = newBoots
            merged = WCWardrobeService.plan(saved(), a, ownedList)
            WCSecurity.clear(1)
            res = call('w_creators:wardrobe:commit', 1, w1.data.token, 'op-w', a)
        ''')
        self.assertTrue(self.e('w1.ok'), self.e('w1.code'))
        self.assertEqual(self.e('w1.data.owned[tostring(dyedHat)].palette'), 'metaped_tint_hat')
        self.assertIsNone(self.e('same'), 'an identical submission changes nothing (NO_CHANGES)')
        self.assertEqual(self.e('merged.clothing.tints.hats.tint0'), 10)
        self.assertTrue(self.e('res.ok'), self.e('res.code'))
        self.assertEqual(self.e('saved().clothing.tints.hats.tint1'), 20)
        self.assertEqual(self.e('saved().clothing.equipped.boots'), self.e('newBoots'))

    def test_a_narrowed_palette_list_keeps_the_dye(self):
        self.rt.run('''
            Config.Clothing.tints.enabled = true
            Config.Clothing.tints.palettes = Config.Clothing.tints.palettes or {}
            Config.Clothing.tints.palettes.hats = false
            r = openStore(); storeToken = r.data.token
            a = working(); a.clothing.equipped.boots = h('male', 'boots', 3)
            res = buy(a)
        ''')
        self.assertTrue(self.e('res.ok'), self.e('res.code'))
        self.assertEqual(self.e('saved().clothing.tints.hats.tint0'), 10)


class StoredDyeSurgeryTests(unittest.TestCase):
    def test_surgery_clothing_keeps_the_dye_of_an_untouched_item(self):
        rt = services_server()
        rt.run('''
            dyedHat, hatY = h('male', 'hats', 1), h('male', 'boots', 2)
            base = S.default('male'); base.clothing.equipped.hats = dyedHat; base.clothing.tints.hats = %s
            setSaved(base)
            Config.Clothing.tints.enabled = false
            Config.CosmeticSurgery.allow.clothing = true
            saved = WCAppearanceRepo.load('vorp:1')
            sub = WCUtil.copy(saved); sub.clothing.equipped.boots = hatY
            owned = { [WCOwnership.key(dyedHat)] = { category = 'hats', palette = 'metaped_tint_hat', tint0 = 10, tint1 = 20, tint2 = 30 },
                      [WCOwnership.key(hatY)] = { category = 'boots' } }
            plan, code = WCSurgeryService.plan(saved, sub, { price = 10 }, owned)
        ''' % DYE)
        self.assertIsNotNone(rt.eval('plan'), rt.eval('code'))
        self.assertEqual(rt.eval('plan.merged.clothing.tints.hats.tint2'), 30)


# ---------------------------------------------------------------------------------------------
# 6  Runtime clothing states survive a grooming stage / reload / re-apply
# ---------------------------------------------------------------------------------------------
class RuntimeStateTests(unittest.TestCase):
    def setUp(self):
        self.rt = services_server()
        self.rt.load('server/clothing/states.lua')
        self.e = self.rt.eval
        self.rt.run('''
            scarf = h('male', 'neckwear', 1)
            base = S.default('male'); base.clothing.equipped.neckwear = scarf
            setSaved(base)
            r = WCClothingActions.setState(1, 'bandana', 'up')
        ''')
        self.assertTrue(self.e('r.ok'), self.e('r.code'))

    def remote(self):
        return self.rt.client_events('w_creators:client:applyRemoteAppearance')[-1].args[2]

    def test_a_grown_stage_keeps_the_raised_bandana(self):
        self.rt.run('''
            Config.Grooming.enabled = true -- growth ships off; this covers the feature
            Config.Grooming.minutesPerStage.hair = 1; Config.Grooming.saveIntervalSeconds = 3600
            Clock.now = Clock.now + 0; WCGroomingServer.tick()
            Clock.now = Clock.now + 30000; WCGroomingServer.tick()
            Clock.now = Clock.now + 30000; WCGroomingServer.tick()
        ''')
        own = self.rt.client_events('w_creators:client:grooming')
        self.assertEqual(len(own), 1)
        self.assertEqual(own[0].args[1].clothing.states.bandana, 'up')
        self.assertEqual(self.remote().clothing.states.bandana, 'up')
        self.assertEqual(self.e('WCSync.get(1).clothing.states.bandana'), 'up')
        states = json.loads(self.e('rows["vorp:1"].appearance'))['clothing'].get('states') or {}
        self.assertNotIn('bandana', states if isinstance(states, dict) else {}, 'never persisted')

    def test_reload_and_apply_keep_it(self):
        self.assertTrue(self.e('WCSync.reload(1).ok'))
        self.assertEqual(self.remote().clothing.states.bandana, 'up')
        self.rt.run('Clock.now = Clock.now + 11000')
        self.rt.run('r2 = WCApi.ApplyCharacterAppearance(1)')
        self.assertTrue(self.e('r2.ok'))
        self.assertEqual(self.remote().clothing.states.bandana, 'up')
        self.assertEqual(self.rt.client_events('w_creators:client:applyAppearance')[-1].args[1].clothing.states.bandana, 'up')
        self.assertIsNone(self.e('r2.data.appearance.clothing.states.bandana'), 'the answer is the saved look')

    def test_not_carried_once_the_item_is_gone(self):
        self.rt.run('b2 = S.default("male"); setSaved(b2)')
        self.assertTrue(self.e('WCSync.reload(1).ok'))
        self.assertIsNone(self.remote().clothing.states.bandana)


# ---------------------------------------------------------------------------------------------
# 7  A degraded legacy character is granted its pre-v3 outfit by the repair save
# ---------------------------------------------------------------------------------------------
class DegradedLegacyGrantTests(unittest.TestCase):
    def test_the_repair_save_carries_the_legacy_grants(self):
        rt = core_server()
        e = rt.eval
        rt.run(r'''
            comps = { heads = h("male", "heads", 2, 1), eyes = h("male", "eyes", 1, 2),
                      BODIES_UPPER = h("male", "BODIES_UPPER", 1, 1), hats = h("male", "hats", 1, 1),
                      boots = h("male", "boots", 2, 1), __version = 2 }          -- no teeth: essential default
            rows["vorp:1"] = { id = 11, charid = "vorp:1", isMale = 1, components = json.encode(comps),
                               faceFeatures = "[]", overlays = "[]", appearance = nil, appearance_version = 2 }
            app, meta = WCAppearanceRepo.load("vorp:1")
            n0 = #FakeDB.transactions
            refused = WCAppearanceRepo.save("vorp:1", app)                      -- no automatic writer
            ok1 = WCAppearanceRepo.save("vorp:1", app, nil, { replaceDegraded = true })
            tx1 = FakeDB.transactions[#FakeDB.transactions]
            ok2 = WCAppearanceRepo.save("vorp:1", app)
            tx2 = FakeDB.transactions[#FakeDB.transactions]
        ''')
        self.assertTrue(e('meta.degraded'))
        self.assertEqual(e('n0'), 0, 'nothing written by the load')
        self.assertFalse(e('refused'))
        self.assertTrue(e('ok1'))
        grants = sorted(q['values'][3] for q in e('tx1').values() if "'legacy'" in q.query)
        self.assertEqual(grants, ['boots', 'hats'])
        self.assertTrue(e('ok2'))
        self.assertEqual(len(e('tx2')), 1, 'granted once')


# ---------------------------------------------------------------------------------------------
# 8  Reconcile only from real legacy data
# ---------------------------------------------------------------------------------------------
class ReconcileColumnsTests(unittest.TestCase):
    def setUp(self):
        self.rt = core_server()
        self.rt.load('server/clothing/ownership.lua')
        self.rt.run(STORE_ROW)
        self.e = self.rt.eval
        self.rt.run(r'''
            v3 = S.default('male')
            v3.morph.jawWidth, v3.morph.noseWidth = 0.6, -0.4
            assert(WCAppearanceRepo.save('vorp:1', v3))
            stored = WCAppearanceRepo.load('vorp:1')
            WCAppearanceRepo.invalidate('vorp:1')
            json0 = rows['vorp:1'].appearance
        ''')
        self.assertAlmostEqual(self.e('stored.morph.jawWidth'), 0.6)

    def check_kept(self):
        n = self.e('#FakeDB.transactions')
        self.rt.run('app, meta = WCAppearanceRepo.load("vorp:1")')
        self.assertFalse(self.e('meta.reconciled'))
        self.assertAlmostEqual(self.e('app.morph.jawWidth'), 0.6)
        self.assertAlmostEqual(self.e('app.morph.noseWidth'), -0.4)
        self.assertTrue(self.e('S.equal(app, stored)'))
        self.assertEqual(self.e('#FakeDB.transactions'), n, 'nothing written')
        self.assertEqual(self.e('rows["vorp:1"].appearance'), self.e('json0'))

    def test_null_columns_keep_the_v3_json(self):
        self.rt.run("rows['vorp:1'].faceFeatures, rows['vorp:1'].overlays = nil, nil")
        self.check_kept()

    def test_truncated_columns_keep_the_v3_json(self):
        self.rt.run('''rows['vorp:1'].faceFeatures = '[{"hash":60334,"index":0.6'
                       rows['vorp:1'].overlays = '[{"compType":"blush"' ''')
        self.check_kept()

    def test_real_legacy_data_is_still_taken_back(self):
        self.rt.run(r'''
            rows['vorp:1'].faceFeatures = '[]'
            app, meta = WCAppearanceRepo.load('vorp:1')
        ''')
        self.assertTrue(self.e('meta.reconciled'))


# ---------------------------------------------------------------------------------------------
# 9  Migrations verify the recorded steps
# ---------------------------------------------------------------------------------------------
class MigrationVerifyTests(unittest.TestCase):
    def setUp(self):
        self.rt = Runtime().load_server_core()
        self.e = self.rt.eval
        self.rt.run('FakeDB.fireReady()')
        self.assertTrue(self.e('WCMigrations.ok'))

    def test_a_table_restored_from_a_pre_v3_dump_converges(self):
        self.rt.run('''
            FakeDB.schema.characters_appearence = { id = true, charid = true, isMale = true, components = true,
                                                    faceFeatures = true, overlays = true, name = true, age = true }
            FakeDB.schema.w_creators_outfits = nil
            ok2, applied2 = WCMigrations.run()
        ''')
        self.assertTrue(self.e('ok2'))
        self.assertEqual(sorted(self.e('applied2').values()), ['002_appearance_v3', '004_outfits'])
        for col in ('appearance', 'appearance_version', 'updated_at'):
            self.assertTrue(self.e('WCMigrations.columnExists("characters_appearence", "%s")' % col))
        self.assertTrue(self.e('WCMigrations.tableExists("w_creators_outfits")'))
        self.assertEqual(len(self.e('FakeDB.migrations')), 7, 'the ledger is not duplicated')
        self.assertTrue(self.e('WCMigrations.waitReady(10)'))

    def test_a_healthy_schema_is_left_alone(self):
        alters = self.e('FakeDB.count("ALTER TABLE")')
        self.rt.run('ok2, applied2 = WCMigrations.run()')
        self.assertTrue(self.e('ok2'))
        self.assertEqual(self.e('#applied2'), 0)
        self.assertEqual(self.e('FakeDB.count("ALTER TABLE")'), alters)
        self.assertEqual(self.e('FakeDB.count("CREATE TABLE IF NOT EXISTS `characters_appearence`")'), 1)

    def test_a_step_that_cannot_repair_stops_the_run(self):
        self.rt.run('''
            FakeDB.schema.w_creators_clothes.source = nil
            FakeDB.fail = 'ADD COLUMN `source`'
            ok2 = WCMigrations.run()
        ''')
        self.assertFalse(self.e('ok2'))
        self.assertFalse(self.e('WCMigrations.waitReady(10)'))


# ---------------------------------------------------------------------------------------------
# 10 rsg / qbr card balances
# ---------------------------------------------------------------------------------------------
class CardBalanceTests(unittest.TestCase):
    def setUp(self):
        self.rt = Runtime().load_server_core()
        self.e = self.rt.eval
        self.rt.run(r'''
            Bridge.Name = 'rsg'
            Bridge.GetLicense = function() return 'license:1' end
            FakeDB.on('SELECT citizenid, charinfo, job, money FROM', function() return {
                { citizenid = 'ABC', charinfo = json.encode({ firstname = 'Sara', lastname = 'Lee' }),
                  money = json.encode({ cash = 12.5, bank = 300, bloodmoney = 4 }) },
                { citizenid = 'DEF', charinfo = '{}', money = 'broken' },
            } end)
            states = {}
            GetResourceState = function(n) return states[n] or 'missing' end
            ledger = { ['player:ABC:cash'] = 77, ['player:ABC:bank'] = 88, ['player:ABC:gold'] = 9 }
            ledgerReadyFlag = true
            exports = setmetatable({}, { __index = function(_, res) return setmetatable({}, { __index = function(_, name)
                return function(self, arg)
                    if res == 'w_centralbank' and name == 'IsReady' then return ledgerReadyFlag end
                    if res == 'w_centralbank' and name == 'GetBalance' then return ledger[arg] end
                    return nil
                end
            end }) end })
            function list() local l = Bridge.GetCharacters(1); return l end
        ''')

    def test_stock_rsg_reads_players_money(self):
        l = self.e('list()')
        self.assertEqual((l[1].cash, l[1].bank, l[1].gold), (12.5, 300, 4))
        self.assertEqual((l[2].cash, l[2].bank, l[2].gold), (None, None, None))

    def test_the_central_ledger_wins(self):
        self.rt.run("states.w_core = 'started'; states.w_centralbank = 'started'")
        l = self.e('list()')
        self.assertEqual((l[1].cash, l[1].bank, l[1].gold), (77, 88, 9))
        self.assertIsNone(l[2].cash, 'an account the ledger does not know is unknown, not 0')

    def test_w_core_without_the_ledger_never_reads_the_stale_column(self):
        self.rt.run("states.w_core = 'started'; states.w_centralbank = 'started'; ledgerReadyFlag = false")
        l = self.e('list()')
        self.assertEqual((l[1].cash, l[1].bank, l[1].gold), (None, None, None))


# ---------------------------------------------------------------------------------------------
# 11 Barber growth plate
# ---------------------------------------------------------------------------------------------
class GrowthPlateTests(unittest.TestCase):
    def setUp(self):
        self.rt = services_server()
        self.e = self.rt.eval
        self.rt.run('Config.Grooming.enabled = true')  # growth ships off; the plate is checked with it on

    def open(self):
        self.rt.run('Clock.now = Clock.now + 11000; WCSessions.clear(1); o = WCBarberService.open(1, "valentine_barber")')
        self.assertTrue(self.e('o.ok'), self.e('o.code'))
        return self.e('o')

    def test_no_plate_while_grooming_is_off(self):
        self.rt.run('Config.Grooming.enabled = false')
        self.assertIsNone(self.open().data.growth)

    def test_the_last_stage_is_marked_fully_grown(self):
        o = self.open()
        self.assertFalse(o.data.growth.hair.fullyGrown)
        self.assertGreater(o.data.growth.hair.stages, 0)
        self.rt.run('''
            local last = Config.Grooming.stages.male.hair[#Config.Grooming.stages.male.hair]
            local grown
            for _, m in pairs(WCCatalog.forSex('male').hair.models) do
                for _, v in ipairs(m) do
                    if (WCCatalog.forSex('male').hair.hashes[v.hash].name or ''):upper():sub(1, #last) == last then grown = v.hash end
                end
            end
            assert(grown, 'no last-stage hair in the catalogue')
            local a = S.default('male'); a.hair.style = grown; setSaved(a)
        ''')
        o = self.open()
        self.assertTrue(o.data.growth.hair.fullyGrown)
        self.assertEqual(o.data.growth.hair.stage, o.data.growth.hair.stages)
        self.assertEqual(o.data.growth.hair.remainingMinutes, 0)


if __name__ == '__main__':
    unittest.main()
