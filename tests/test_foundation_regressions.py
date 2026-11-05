"""Regression tests for the foundation review findings (config defaults, catalogue sex rule, legacy
clothing preservation, degraded appearances, per-character lock ownership, session open race, spawn
service §11/§16.3, opening hours, numeric helpers, identity, natives gating, reference SQL)."""
import re
import unittest

from harness import REAL_CATALOG, RESOURCE, Runtime, read
from test_server_core import APP_SETUP, server

H = 'h = function(sex, c, m, v) return WCCatalog.forSex(sex)[c].models[m][v or 1].hash end\n'


def shared(catalog='fixture'):
    rt = Runtime(catalog=catalog).load_shared()
    rt.run(H + 'S = AppearanceSchema')
    return rt


class ConfigDefaultsTests(unittest.TestCase):
    def setUp(self):
        self.rt = shared()
        self.e = self.rt.eval

    def test_experimental_features_default_off(self):
        # clothingAnimations is on: its clips are the game's own, checked against the full RDR3 list
        for key, value in self.rt.py(self.e('Config.Experimental')).items():
            self.assertIs(value, key == 'clothingAnimations', key)

    def test_creator_offers_every_clothing_category_like_pre_v3(self):
        self.assertEqual(self.e('Config.Creator.startingClothing.categories'), '*')

    def test_barber_visit_keeps_the_pre_v3_flat_price(self):
        services = self.rt.py(self.e('Config.Barber.services'))
        cap = self.e('Config.Barber.prices.visitCap')
        self.assertEqual(cap, 10)
        # hair only, beard only, hair + beard: 10 each, as the pre-v3 GroomingConfig.price
        for changed in (['hair'], ['facialHair'], ['hair', 'facialHair']):
            self.assertEqual(min(sum(services[s]['price'] for s in changed), cap), 10)

    def test_spawn_camera_key(self):
        self.assertEqual(self.e('Config.Spawn.camera.dist'), 110.0)
        self.assertIsNone(self.e('Config.Spawn.selector.camDefaults'))

    def test_deletion_switch_is_honoured_by_the_service_gate(self):
        self.assertTrue(self.e('WCServices.enabled("characterDeletion")'))
        self.rt.run('Config.Characters.deletion.enabled = false')
        self.assertFalse(self.e('WCServices.enabled("characterDeletion")'))
        self.rt.run('Config.Characters.deletion.enabled = true; Config.Services.characterDeletion = false')
        self.assertFalse(self.e('WCServices.enabled("characterDeletion")'))

    def test_morph_labels_keep_the_pre_v3_keys(self):
        expected = {
            'jawWidth': 'الفكّ · عريض', 'jawDepth': 'الفكّ · غائر', 'eyesDistance': 'موضع العين · متباعد',
            'eyesHeight': 'موضع العين · أسفل', 'eyesAngle': 'محجر العين · ميلٌ للخارج',
            'eyesDepth': 'محجر العين · ضحل', 'cheekbonesWidth': 'عظام الوجنة · عريض',
            'cheekbonesDepth': 'عظام الوجنة · غائر', 'noseWidth': 'الأنف · عريض', 'noseHeight': 'الأنف · أسفل',
            'earlobes': 'الحجم', 'earsDepth': 'عمق الأذنين', 'headWidth': 'عرض الرأس',
        }
        for field, label in expected.items():
            self.assertEqual(self.e('WCMorph.byId.%s.label' % field), label, field)


class NumericAndRulesTests(unittest.TestCase):
    def setUp(self):
        self.rt = shared()
        self.e = self.rt.eval

    def test_int_and_round2_reject_unrepresentable_values(self):
        self.assertIsNone(self.e('WCUtil.int(1e300, 1, nil, nil)'))
        self.assertEqual(self.e('WCUtil.int(1e300, 1, nil, 7)'), 7)
        self.assertEqual(self.e('math.type(WCUtil.int(1e300, 1, 100, nil))'), 'integer')
        self.assertIsNone(self.e('WCUtil.round2(1e307)'))
        self.assertIsNone(self.e('WCUtil.round2(-1e307)'))
        self.assertEqual(self.e('WCUtil.round2(10.005)'), 10.01)

    def test_style_label_and_outfit_id_with_huge_numbers(self):
        self.rt.run('ok, label = pcall(WCCatalog.styleLabel, "hats", 1e300)')
        self.assertTrue(self.e('ok'))
        self.rt.run('a = S.default("male"); a.clothing.outfit = 1e300; s = S.sanitize(a)')
        self.assertEqual(self.e('math.type(s.clothing.outfit)'), 'integer')
        self.assertLessEqual(self.e('s.clothing.outfit'), 2 ** 31 - 1)

    def test_equip_with_a_non_string_category_never_throws(self):
        for cat in ('nil', '0/0', '5', '{}'):
            self.rt.run('ok, eq, removed = pcall(WCRules.equip, { hats = 1 }, %s, nil)' % cat)
            self.assertTrue(self.e('ok'), cat)
            self.assertEqual(self.rt.py(self.e('eq')), {'hats': 1})
            self.rt.run('a = S.default("male"); ok, app, removed, code = pcall(S.equip, a, %s, 0)' % cat)
            self.assertTrue(self.e('ok'), cat)
            self.assertEqual(self.e('code'), 'INVALID_COMPONENT')
        self.rt.run('a = S.default("male"); _, _, code = S.equip(a, "heads", 0)')
        self.assertEqual(self.e('code'), 'INVALID_COMPONENT')


class CatalogSexRuleTests(unittest.TestCase):
    def test_taxonomy_sex_hint_is_enforced_by_the_server(self):
        rt = shared()
        e = rt.eval
        self.assertFalse(e('WCCatalog.offered("male", "skirts")'))    # no male skirts in the catalogue
        self.assertTrue(e('WCCatalog.offered("female", "skirts")'))
        self.assertFalse(e('WCCatalog.offered("male", "heads")'))     # body part, not clothing
        rt.run('''
            for _, g in ipairs(Config.Clothing.taxonomy) do
                for _, sub in ipairs(g.subs) do if sub.id == "hats" then sub.sex = "female" end end
            end
            WCCatalog.reset()
        ''')
        self.assertFalse(e('WCCatalog.offered("male", "hats")'))
        self.assertFalse(e('WCCatalog.available("general", "male", "hats", h("male", "hats", 1))'))
        self.assertTrue(e('WCCatalog.available("general", "female", "hats", h("female", "hats", 1))'))

    @unittest.skipUnless(REAL_CATALOG, 'w_lib catalogue not available')
    def test_dresses_follow_the_catalogue(self):
        rt = shared('real')
        e = rt.eval
        self.assertIsNotNone(e('WCCatalog.forSex("male").dresses'))
        # dresses carry no sex hint: the catalogue decides (males have a nightgown there)
        self.assertEqual(e('WCCatalog.offered("male", "dresses")'), e('WCCatalog.category("male", "dresses") ~= nil'))
        self.assertFalse(e('WCCatalog.offered("female", "dresses")'))
        self.assertTrue(e('WCCatalog.available("general", "male", "dresses", h("male", "dresses", 1))'))


LEGACY_MALE = r'''
comps = { heads = h("male", "heads", 2, 1), eyes = h("male", "eyes", 1, 1), teeth = h("male", "teeth", 1, 1),
          BODIES_UPPER = h("male", "BODIES_UPPER", 1, 1), pants = h("male", "pants", 1, 1),
          belt_buckles = h("male", "belt_buckles", 1, 1), gunbelt_accs = h("male", "gunbelt_accs", 2, 1),
          coats = h("male", "coats", 1, 1), coats_closed = h("male", "coats_closed", 1, 1),
          hats = 12345, __version = 2 }
legacyRow = { id = 11, charid = "vorp:1", isMale = 1, components = json.encode(comps), faceFeatures = "[]",
              overlays = "[]", appearance = nil, appearance_version = 2 }
'''
KEPT = ['belt_buckles', 'coats', 'coats_closed', 'gunbelt_accs', 'pants']


class LegacyClothingTests(unittest.TestCase):
    def test_from_legacy_keeps_combinations_the_new_rules_forbid(self):
        rt = shared()
        rt.run(LEGACY_MALE + 'app, meta = S.fromLegacy(legacyRow)')
        self.assertEqual(sorted(rt.py(rt.eval('app.clothing.equipped')).keys()), KEPT)
        self.assertEqual(list(rt.eval('meta.dropped').values()), ['hats'])   # not in the catalogue
        self.assertEqual(rt.eval('#meta.defaultsUsed'), 0)
        # the stored shape survives the round trips through the persisted paths
        rt.run('back = S.fromLegacy(S.toLegacy(app)); again = S.normalize(WCUtil.encode(app))')
        self.assertTrue(rt.eval('S.equal(app, back) and S.equal(app, again)'))
        self.assertEqual(rt.py(rt.eval('S.changedSections(app, back)')), {})
        # female pants + skirts (pre-v3 allowed on legacy rows) survive too
        rt.run('''
            f = S.fromLegacy({ isMale = 0, components = json.encode({ heads = h("female", "heads", 1, 1),
                eyes = h("female", "eyes", 1, 1), teeth = h("female", "teeth", 1, 1),
                BODIES_UPPER = h("female", "BODIES_UPPER", 1, 1), pants = h("female", "pants", 1, 1),
                skirts = h("female", "skirts", 1, 1) }) })
        ''')
        self.assertEqual(sorted(rt.py(rt.eval('f.clothing.equipped')).keys()), ['pants', 'skirts'])

    def test_repository_upgrade_grants_and_save_keep_every_legacy_item(self):
        rt = server()
        rt.run(LEGACY_MALE + 'rows["vorp:1"] = legacyRow; app, meta = WCAppearanceRepo.load("vorp:1")')
        self.assertTrue(rt.eval('meta.upgraded'))
        tx = rt.eval('FakeDB.transactions[1]')
        grants = sorted(q['values'][3] for q in tx.values() if 'INSERT IGNORE INTO w_creators_clothes' in q.query)
        self.assertEqual(grants, KEPT)
        self.assertTrue(any('left out: hats' in p.text for p in rt.eval('Printed').values()))
        # an automatic writer (no clothing edit) keeps the set in v3 and in the legacy projection
        rt.run('ok, saved = WCAppearanceRepo.save("vorp:1", app)')
        self.assertTrue(rt.eval('ok'))
        self.assertEqual(sorted(rt.py(rt.eval('saved.clothing.equipped')).keys()), KEPT)
        values = rt.eval('FakeDB.transactions[#FakeDB.transactions][1]')['values']
        import json
        self.assertEqual(sorted(json.loads(values[1])['clothing']['equipped'].keys()), KEPT)
        self.assertTrue(set(KEPT) <= set(json.loads(values[4]).keys()))

    def test_merge_applies_rules_only_when_the_clothing_is_edited(self):
        rt = shared()
        rt.run(LEGACY_MALE + '''
            saved = S.fromLegacy(legacyRow)
            sub = WCUtil.copy(saved); sub.hair.style = h("male", "hair", 2, 1)
            barber = S.mergeSections(saved, sub, { "hair" })
            same = S.mergeSections(saved, WCUtil.copy(saved), { "clothing" })
            edit = WCUtil.copy(saved); edit.clothing.equipped.hats = h("male", "hats", 1, 1)
            store = S.mergeSections(saved, edit, { "clothing" })
        ''')
        self.assertEqual(sorted(rt.py(rt.eval('barber.clothing.equipped')).keys()), KEPT)
        self.assertEqual(sorted(rt.py(rt.eval('same.clothing.equipped')).keys()), KEPT)
        self.assertEqual(sorted(rt.py(rt.eval('store.clothing.equipped')).keys()), ['coats', 'hats', 'pants'])


class SanitizeAuthorityTests(unittest.TestCase):
    def test_opts_sex_is_authoritative_and_grooming_can_be_dropped(self):
        rt = shared()
        rt.run('''
            f = S.default("female"); f.grooming = { hair = { stage = 2, seconds = 5 } }
            s, v = S.sanitize(f, { sex = "male", grooming = false })
            kept = S.sanitize(f)
        ''')
        self.assertEqual(rt.eval('s.sex'), 'male')
        self.assertTrue(any(x.field == 'sex' and x.reason == 'overridden' for x in rt.eval('v').values()))
        self.assertEqual(rt.py(rt.eval('s.grooming')), {})
        self.assertEqual(rt.eval('kept.sex'), 'female')
        self.assertEqual(rt.eval('kept.grooming.hair.stage'), 2)


class SkinToneLeakTests(unittest.TestCase):
    DROP_V6 = r'''
        local cat = w.component.getFullPedComponentList()
        for _, category in ipairs({ "BODIES_UPPER", "BODIES_LOWER" }) do
            for _, group in ipairs(cat.male[category]) do
                local kept = {}
                for _, v in ipairs(group.variations) do
                    if not v.hashname:find("_003_V_006$") then kept[#kept + 1] = v end
                end
                group.variations = kept
            end
        end
    '''

    def test_body_model_without_the_saved_tone_keeps_the_saved_body(self):
        rt = Runtime()
        rt.run(self.DROP_V6)
        rt.load_shared()
        rt.run(H + '''
            S = AppearanceSchema
            nameOf = function(c, hash) return WCCatalog.forSex("male")[c].hashes[hash].name end
            saved = S.default("male"); S.setSkinTone(saved, 6)
            for _, v in ipairs({ 1, 3 }) do
                local sub = WCUtil.copy(saved)
                sub.body.upper = h("male", "BODIES_UPPER", 3, v); sub.body.lower = h("male", "BODIES_LOWER", 3, v)
                _G["m" .. v] = S.mergeSections(saved, sub, { "body" })
            end
            sub = WCUtil.copy(saved); S.setSkinTone(sub, 1); S.setBodyType(sub, 3)
            withSkin = S.mergeSections(saved, sub, { "body", "skin" })
        ''')
        for v in (1, 3):
            self.assertEqual(rt.eval('nameOf("BODIES_UPPER", m%d.body.upper)' % v), 'CLOTHING_ITEM_M_BODIES_UPPER_001_V_006')
            self.assertEqual(rt.eval('nameOf("BODIES_LOWER", m%d.body.lower)' % v), 'CLOTHING_ITEM_M_BODIES_LOWER_001_V_006')
            self.assertEqual(rt.py(rt.eval('S.changedSections(saved, m%d)' % v)), {})
        # with the skin section allowed the body model and its tone are taken
        self.assertEqual(rt.eval('nameOf("BODIES_UPPER", withSkin.body.upper)'), 'CLOTHING_ITEM_M_BODIES_UPPER_003_V_001')
        self.assertEqual(rt.eval('S.skinTone(withSkin)'), 1)
        # sanitize reports a body that cannot adopt the head's tone
        rt.run('bad = WCUtil.copy(saved); bad.body.upper = h("male", "BODIES_UPPER", 3, 1); _, v = S.sanitize(bad)')
        self.assertTrue(any(x.reason == 'tone_unavailable' for x in rt.eval('v').values()))

    @unittest.skipUnless(REAL_CATALOG, 'w_lib catalogue not available')
    def test_real_catalogue_body_type_five(self):
        rt = shared('real')
        rt.run('''
            saved = S.default("male"); S.setSkinTone(saved, 6)
            sub = WCUtil.copy(saved); sub.body.upper = h("male", "BODIES_UPPER", 5, 3)
            m = S.mergeSections(saved, sub, { "body" })
        ''')
        self.assertTrue(rt.eval('m.body.upper == saved.body.upper'))
        self.assertEqual(rt.eval('S.skinTone(m)'), 6)


class RepositoryGuardTests(unittest.TestCase):
    def test_degraded_appearance_is_flagged_on_cache_hits_and_never_overwritten_implicitly(self):
        rt = server()
        rt.run(LEGACY_MALE + '''
            legacyRow.components = json.encode((function() local c = WCUtil.copy(comps); c.heads = 999 return c end)())
            rows["vorp:1"] = legacyRow
            app, meta = WCAppearanceRepo.load("vorp:1")
            app2, meta2 = WCAppearanceRepo.load("vorp:1")
            ok, code = WCAppearanceRepo.save("vorp:1", app2)
        ''')
        self.assertTrue(rt.eval('meta.degraded'))
        self.assertTrue(rt.eval('meta2.cached and meta2.degraded'))
        self.assertEqual(list(rt.eval('meta2.defaultsUsed').values()), ['face'])
        self.assertFalse(rt.eval('ok'))
        self.assertEqual(rt.eval('code'), 'INTERNAL_ERROR')
        self.assertEqual(rt.eval('#FakeDB.transactions'), 0)
        # still refused after the cache was dropped (e.g. the drop-save of a disconnect)
        rt.run('fireEvent("playerDropped", 1); ok, code = WCAppearanceRepo.save("vorp:1", app2)')
        self.assertFalse(rt.eval('ok'))
        self.assertEqual(list(rt.eval('WCAppearanceRepo.degraded("vorp:1")').values()), ['face'])
        # an explicit repair may replace it
        rt.run('ok = WCAppearanceRepo.save("vorp:1", app2, nil, { replaceDegraded = true }); _, meta3 = WCAppearanceRepo.load("vorp:1")')
        self.assertTrue(rt.eval('ok'))
        self.assertFalse(rt.eval('meta3.degraded'))
        self.assertIsNone(rt.eval('WCAppearanceRepo.degraded("vorp:1")'))

    def test_unavailable_catalogue_is_a_load_error_not_a_defaults_case(self):
        rt = server()
        rt.run('''
            rows["vorp:1"].appearance = json.encode((function() local a = WCUtil.copy(savedApp)
                a.clothing.equipped.hats = h("male", "hats", 1, 1) return a end)())
            realList = w.component.getFullPedComponentList
            w.component.getFullPedComponentList = function() return nil end
            WCCatalog.reset()
            a, m = WCAppearanceRepo.load("vorp:1")
            ok, code = WCAppearanceRepo.save("vorp:1", savedApp)
        ''')
        self.assertIsNone(rt.eval('a'))
        self.assertEqual(rt.eval('m.error'), 'INTERNAL_ERROR')
        self.assertIsNone(rt.eval('WCAppearanceRepo.cache["vorp:1"]'))
        self.assertEqual(rt.eval('code'), 'INTERNAL_ERROR')
        self.assertEqual(rt.eval('#FakeDB.transactions'), 0)
        rt.run('w.component.getFullPedComponentList = realList; WCCatalog.reset(); a, m = WCAppearanceRepo.load("vorp:1")')
        self.assertIsNotNone(rt.eval('a.clothing.equipped.hats'))
        self.assertFalse(rt.eval('m.degraded'))

    def test_repository_waits_for_the_migrations(self):
        rt = Runtime().load_server_core()
        rt.run(APP_SETUP.replace('FakeDB.fireReady()', ''))
        rt.run('a, m = WCAppearanceRepo.load("vorp:1"); ok, code = WCAppearanceRepo.save("vorp:1", savedApp)')
        self.assertIsNone(rt.eval('a'))
        self.assertEqual(rt.eval('m.error'), 'DATABASE_ERROR')
        self.assertEqual(rt.eval('code'), 'DATABASE_ERROR')
        self.assertEqual(rt.eval('FakeDB.count("SELECT %* FROM characters_appearence")'), 0)
        rt.run('FakeDB.fireReady(); a, m = WCAppearanceRepo.load("vorp:1")')
        self.assertTrue(rt.eval('S.equal(a, savedApp)'))

    def test_failed_migrations_block_appearance_io(self):
        rt = Runtime().load_server_core()
        rt.run(APP_SETUP.replace('FakeDB.fireReady()', 'FakeDB.fail = "ALTER TABLE"; FakeDB.fireReady(); FakeDB.fail = nil'))
        self.assertFalse(rt.eval('WCMigrations.ok'))
        rt.run('a, m = WCAppearanceRepo.load("vorp:1")')
        self.assertEqual(rt.eval('m.error'), 'DATABASE_ERROR')


class SessionConcurrencyTests(unittest.TestCase):
    def setUp(self):
        self.rt = server()
        self.e = self.rt.eval

    def test_drop_during_commit_keeps_the_lock_until_that_commit_ends(self):
        self.rt.run('''
            r = WCSessions.open(1, "store", { locationId = "valentine_clothing" })
            token = r.data.token
            CreateThread(function()
                c = WCSessions.commit(1, token, "op1", function() Wait(500) return WCResult.ok() end)
            end)
        ''')
        self.assertIsNotNone(self.e('CreatorAppearanceLocks["vorp:1"]'))
        self.rt.run('fireEvent("playerDropped", 1)')
        self.assertIsNone(self.e('WCSessions.current(1)'))
        self.assertIsNotNone(self.e('CreatorAppearanceLocks["vorp:1"]'))      # still held by the running commit
        self.assertFalse(self.e('WCSessions.lockCharacter("vorp:1", "grooming")'))
        self.rt.run('tick(500)')
        self.assertTrue(self.e('c.ok'))
        self.assertIsNone(self.e('CreatorAppearanceLocks["vorp:1"]'))         # released by its owner

    def test_a_writer_only_releases_its_own_lock(self):
        self.rt.run('''
            r = WCSessions.open(1, "store", { locationId = "valentine_clothing" })
            token = r.data.token
            CreateThread(function()
                c = WCSessions.commit(1, token, "op1", function() Wait(500) return WCResult.ok() end)
            end)
            CreatorAppearanceLocks["vorp:1"] = "another-writer"
            tick(500)
        ''')
        self.assertEqual(self.e('CreatorAppearanceLocks["vorp:1"]'), 'another-writer')
        self.assertFalse(self.e('WCSessions.unlockCharacter("vorp:1", "someone-else")'))
        self.assertTrue(self.e('WCSessions.unlockCharacter("vorp:1", "another-writer")'))
        self.assertTrue(self.e('WCSessions.lockCharacter("vorp:1", "g")'))
        self.assertFalse(self.e('WCSessions.lockCharacter("vorp:1", "h")'))

    def test_two_opens_in_the_load_window_yield_one_session(self):
        self.rt.run('''
            closed = 0; WCSessions.onClose(function() closed = closed + 1 end)
            FakeDB.on("SELECT %* FROM characters_appearence", function(sql, params) Wait(100) return rows[params[1]] end)
            CreateThread(function() r1 = WCSessions.open(1, "store", { locationId = "valentine_clothing" }) end)
            CreateThread(function() r2 = WCSessions.open(1, "store", { locationId = "valentine_clothing" }) end)
            tick(100)
        ''')
        self.assertTrue(self.e('r1.ok'))
        self.assertEqual(self.e('r2.code'), 'BUSY')
        self.assertTrue(self.e('WCSessions.current(1).token == r1.data.token'))
        self.assertEqual(self.e('closed'), 0)

    def test_database_failure_is_reported_as_such(self):
        self.rt.run('FakeDB.fail = "SELECT %*"; r = WCSessions.open(1, "store", { locationId = "valentine_clothing" })')
        self.assertEqual(self.e('r.code'), 'DATABASE_ERROR')


class LocationHoursTests(unittest.TestCase):
    def test_hours_rule(self):
        rt = shared()
        f = rt.eval('function(o, c, h) return WCLocations.isOpen({ hours = { open = o, close = c } }, h) end')
        self.assertEqual([f(6, 22, h) for h in (5, 6, 21, 22)], [False, True, True, False])
        self.assertEqual([f(20, 4, h) for h in (23, 3, 4, 12)], [True, True, False, False])
        self.assertTrue(all(f(0, 24, h) for h in range(24)))
        self.assertTrue(rt.eval('WCLocations.isOpen({}, 3)'))

    def test_closed_location_is_not_usable_and_refused(self):
        rt = server()
        rt.run('''
            local hr = WCLocations.hour()
            Config.Locations[1].hours = { open = (hr + 1) % 24, close = (hr + 2) % 24 }
            Config.Locations[2].hours = { open = "x" }
            WCLocations.reload()
            r = WCSessions.open(1, "store", { locationId = "valentine_clothing" })
        ''')
        self.assertFalse(rt.eval('WCLocations.isUsable(WCLocations.byId("valentine_clothing"))'))
        # 1.0.6: closed by its hours is its own refusal, and it names them
        self.assertEqual(rt.eval('r.code'), 'LOCATION_CLOSED_HOURS')
        self.assertEqual(rt.eval('r.detail.key'), rt.eval('WCResult.details.hours'))
        self.assertEqual(rt.eval('r.detail.args[1]'), '%02d:00' % ((rt.eval('WCLocations.hour()') + 1) % 24))
        self.assertIsNone(rt.eval('WCLocations.all()[2].hours'))
        self.assertTrue(any('invalid hours' in p.text for p in rt.eval('Printed').values()))
        rt.run('Config.Locations[1].hours = nil; WCLocations.reload(); Clock.now = Clock.now + 20000')
        self.assertTrue(rt.eval('WCSessions.open(1, "store", { locationId = "valentine_clothing" }).ok'))


class SpawnServiceTests(unittest.TestCase):
    def setUp(self):
        self.rt = server()
        self.e = self.rt.eval
        self.rt.run('last = { x = 5, y = 6, z = 7, heading = 8 }; Bridge.GetLastPosition = function() return last end')
        self.choose = self.e('function(id) return Callbacks["w_creators:spawn:choose"](1, id) end')

    def spawns(self):
        return self.rt.client_events('w_creators:client:spawn')

    def test_select_payload_has_points_kind_and_last_label(self):
        # 1.0.8: the selector for a returning character is now the config choice lastLocation.direct = false
        self.rt.run('Config.Spawn.lastLocation.direct = false')
        self.rt.run('Config.Spawn.points[2].enabled = false; Config.Spawn.points[1].order = 99; Bridge.FinishCharacter(1, false)')
        payload = self.rt.client_events('w_creators:client:selectSpawn')[0].args[1]
        self.assertEqual(list(payload.points.values()), [])        # 1.0.15: a returning character, no towns
        self.assertEqual(payload.kind, 'login')
        self.assertEqual(payload.last.x, 5)
        self.assertEqual(payload.last.label, 'فالنتاين')
        self.rt.run('WCSpawnServer.cancel(1); Bridge.FinishCharacter(1, true)')
        payload = self.rt.client_events('w_creators:client:selectSpawn')[1].args[1]
        self.assertEqual(payload.kind, 'initial')
        self.assertIsNone(payload.last)
        self.assertEqual(list(payload.points.values()),
                         ['rhodes', 'blackwater', 'strawberry', 'armadillo', 'tumbleweed', 'vanhorn', 'annesburg', 'valentine'])

    def test_choose_callback(self):
        # 1.0.8: the selector for a returning character is now the config choice lastLocation.direct = false
        self.rt.run('Config.Spawn.lastLocation.direct = false')
        self.assertEqual(self.choose('rhodes').code, 'SPAWN_NOT_PENDING')
        self.rt.run('Bridge.FinishCharacter(1, true, "switch")')        # 1.0.15: towns = a new character
        self.assertEqual(self.choose('nowhere').code, 'INVALID_SPAWN')
        self.assertEqual(self.choose(42).code, 'INVALID_PAYLOAD')
        self.assertTrue(self.e('SpawnPending[1]'))                     # a refused choice keeps the grant
        r = self.choose('rhodes')
        self.assertTrue(r.ok)
        self.assertAlmostEqual(r.data.pos.x, 1233.28)
        spawn = self.spawns()
        self.assertEqual(len(spawn), 1)
        self.assertAlmostEqual(spawn[0].args[1].x, 1233.28)
        self.assertEqual(spawn[0].args[2].kind, 'switch')
        self.assertIsNone(self.e('SpawnPending[1]'))
        self.assertEqual(self.choose('rhodes').code, 'SPAWN_NOT_PENDING')

    def test_invalid_last_positions_fall_back_to_the_first_enabled_point(self):
        # 1.0.8: the selector for a returning character is now the config choice lastLocation.direct = false
        self.rt.run('Config.Spawn.lastLocation.direct = false')
        self.rt.run('Config.Spawn.points[1].enabled = false')     # valentine off -> saintdenis (order 2)
        bad = ('{ x = 1/0, y = 1, z = 1 }', '{ x = 0/0, y = 1, z = 1 }', '{ x = "1e999", y = 1, z = 1 }',
               '{ x = 9000, y = 0, z = 0 }', '{ x = 0, y = 0, z = 5000 }',
               '{ x = 2542.655, y = -1305.585, z = 48.014 }',            # the creator scene
               '{ x = 2550, y = -1300, z = 48 }', '{ x = 0, y = 0, z = 0 }', 'nil', '"garbage"')  # 9 m from it
        for i, value in enumerate(bad):
            self.rt.run('last = %s; Clock.now = Clock.now + 6000; Bridge.FinishCharacter(1, false)' % value)
            payload = self.rt.client_events('w_creators:client:selectSpawn')[i].args[1]
            self.assertIsNone(payload.last, value)
            self.assertEqual(list(payload.points.values()), ['saintdenis'], value)   # 1.0.15: the one fallback
            self.assertEqual(self.choose('rhodes').code, 'INVALID_SPAWN', value)
            r = self.choose('saintdenis')
            self.assertTrue(r.ok, value)
            self.assertAlmostEqual(r.data.pos.x, 2645.11, msg=value)
            self.assertAlmostEqual(self.e('Bridge.GetSpawnCoords(1).x'), 2645.11, msg=value)
        self.rt.run('last = { x = 5, y = 6, z = 7 }; Clock.now = Clock.now + 6000; Bridge.FinishCharacter(1, false)')
        self.assertEqual(self.choose('__last').data.pos.x, 5)

    def test_last_needs_the_service_and_direct_spawn_carries_meta(self):
        self.rt.run('Config.Services.lastLocation = false; Bridge.FinishCharacter(1, false)')
        self.assertEqual(self.choose('__last').code, 'INVALID_SPAWN')
        self.rt.run('Config.Services.spawnSelector = false; Bridge.FinishCharacter(1, true)')
        spawn = self.spawns()[-1]
        self.assertAlmostEqual(spawn.args[1].x, -274.09)
        self.assertEqual(spawn.args[2].kind, 'initial')

    def test_legacy_event_resolves_the_same_way(self):
        self.rt.run('last = { x = 1/0, y = 0, z = 0 }; Bridge.FinishCharacter(1, false)')
        self.rt.run('fireEvent("w_creators:server:spawnAt", 1, "__last")')
        spawn = self.spawns()[-1]
        self.assertAlmostEqual(spawn.args[1].x, -274.09)
        self.assertEqual(spawn.args[2].kind, 'login')


class IdentityTatweelTests(unittest.TestCase):
    def test_tatweel_is_not_a_boundary_letter(self):
        rt = shared()
        name = rt.eval('function(s) return WCIdentity.validateName(s) end')
        for raw in ('ـــ', 'ـمحمد', 'محمدـ'):
            self.assertEqual(name(raw), (False, 'INVALID_NAME'), raw)
        self.assertEqual(name('مـحمد'), (True, 'مـحمد'))


class NativeGatingTests(unittest.TestCase):
    def test_category_discovery_needs_dev_tools(self):
        rt = Runtime().load_shared()
        rt.run('''
            invoked = {}
            Citizen.InvokeNative = function(hash, ...) invoked[#invoked + 1] = hash return 4 end
            Citizen.ResultAsInteger = function() return 'int' end
            DoesEntityExist = function(e) return e == 77 end
            IsEntityAPed = function(e) return e == 77 end
        ''')
        rt.load(*['client/natives/%s.lua' % n for n in ('metaped', 'ped', 'clothing', 'camera', 'respawn', 'scene', 'ui')])
        self.assertIsNone(rt.eval('WCNative.metaped.numCategories(77)'))
        self.assertIsNone(rt.eval('WCNative.metaped.categoryAt(77, 0)'))
        self.assertEqual(rt.eval('#invoked'), 0)
        rt.run('Config.Admin.devTools = true')
        self.assertEqual(rt.eval('WCNative.metaped.numCategories(77)'), 4)
        self.assertEqual(rt.eval('WCNative.metaped.categoryAt(77, 0)'), 4)


class InstallSqlTests(unittest.TestCase):
    def test_install_sql_matches_the_migrations(self):
        rt = Runtime().load_server_core()
        rt.run('FakeDB.fireReady()')
        self.assertTrue(rt.eval('WCMigrations.ok'))
        sql = read(RESOURCE / 'sql' / 'install.sql')
        schema = rt.py(rt.eval('FakeDB.schema'))
        self.assertEqual(set(schema), {'characters_appearence', 'w_creators_clothes', 'w_creators_outfits',
                                       'w_creators_colorways', 'w_creators_migrations',
                                       'w_creators_locations'})
        for table, cols in schema.items():
            block = re.search(r'CREATE TABLE IF NOT EXISTS `%s` \((.*?)\) ENGINE' % table, sql, re.S)
            self.assertIsNotNone(block, table)
            for col in cols:
                self.assertIn('`%s`' % col, block.group(1), '%s.%s' % (table, col))
        # The ledger is never pre-filled (a pre-v3 database importing the file must still migrate):
        # tests/test_review_shared_r1.py covers that.
        self.assertNotIn('INSERT', sql.upper())


if __name__ == '__main__':
    unittest.main()
