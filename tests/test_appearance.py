"""AppearanceSchema: defaults, validation, legacy v1/v2 conversion, v3 round trips, skin tone,
section merging and change detection."""
import json
import unittest

from harness import REAL_CATALOG, Runtime

SETUP = r'''
S = AppearanceSchema
cat = function(sex, c) return WCCatalog.forSex(sex)[c] end
h = function(sex, c, m, v) return cat(sex, c).models[m][v or 1].hash end
signed = function(x) if x >= 0x80000000 then return x - 0x100000000 end return x end
nameOf = function(sex, c, hash) local i = cat(sex, c).hashes[hash]; return i and i.name end
'''


class AppearanceTests(unittest.TestCase):
    def setUp(self):
        self.rt = Runtime().load_shared()
        self.rt.run(SETUP)
        self.e = self.rt.eval
        self.run = self.rt.run

    # -- defaults / sanitize -----------------------------------------------------------------
    def test_default_is_complete_and_stable(self):
        for sex in ('male', 'female'):
            self.run('d = S.default("%s"); s, v, du = S.sanitize(d)' % sex)
            self.assertTrue(self.e('S.equal(d, s)'), sex)
            self.assertEqual(self.e('#v'), 0, sex)
            self.assertEqual(self.e('#du'), 0, sex)
            self.assertEqual(self.e('d.version'), 3)
            self.assertEqual(self.e('nameOf(d.sex, "heads", d.head.head)'),
                             'CLOTHING_ITEM_M_HEAD_008_V_001' if sex == 'male' else 'CLOTHING_ITEM_F_HEAD_001_V_001')
            self.assertEqual(self.e('nameOf(d.sex, "eyes", d.head.eyes)')[-8:], 'TINT_014')
            self.assertEqual(self.e('d.overlays.eyebrows.opacity'), 0.85)
            self.assertTrue(self.e('d.clothing.equipped.shirts_full and d.clothing.equipped.pants and d.clothing.equipped.boots'))

    def test_missing_essentials_use_defaults_and_report_sections(self):
        self.run('a, v, du = S.sanitize({version = 3, sex = "male"})')
        self.assertEqual(sorted(self.rt.py(self.e('du')).values()), ['body', 'eyes', 'face'])
        self.assertTrue(self.e('a.head.head == S.default("male").head.head'))
        self.run('b, v2, du2 = S.sanitize({version = 3, sex = "martian"})')
        self.assertEqual(self.e('b.sex'), 'male')

    def test_nan_inf_and_ranges(self):
        self.run('''
            a = S.default("male")
            a.body.height = 0/0; a.body.weight = 1/0
            a.morph = { jawWidth = 1/0, noseSize = 0/0, chinWidth = 5, lipsUnknown = 0.5, arms = -0.25, calves = 0 }
            a.overlays = { blush = { style = 99, color = 0/0, opacity = 1/0 }, freckles = { style = 0 },
                           nothing = { style = 1 } }
            s, v = S.sanitize(a)
        ''')
        self.assertEqual(self.e('s.body.height'), 1.0)
        self.assertEqual(self.e('math.type(s.body.height)'), 'float')
        self.assertEqual(self.e('s.body.weight'), 11)
        self.assertEqual(self.rt.py(self.e('s.morph')), {'chinWidth': 1.0, 'arms': -0.25})
        self.assertEqual(self.rt.py(self.e('s.overlays.blush')), {'style': 4, 'color': 1, 'opacity': 1.0})
        self.assertIsNone(self.e('s.overlays.freckles'))
        self.assertIsNone(self.e('s.overlays.nothing'))
        self.assertGreater(self.e('#v'), 0)

    def test_unknown_and_cross_sex_hashes(self):
        self.run('''
            a = S.default("male")
            a.clothing.equipped.hats = 12345
            a.clothing.equipped.masks = h("female", "masks", 1)
            a.clothing.equipped.heads = h("male", "heads", 2)
            a.clothing.equipped.boots = h("male", "hats", 1)
            a.hair.style = h("female", "hair", 1)
            s = S.sanitize(a)
            f = S.default("female")
            f.hair.facial = h("male", "mustache", 1)
            f.overlays.beardstabble = { style = 1, color = 1, opacity = 1 }
            fs = S.sanitize(f)
        ''')
        eq = self.rt.py(self.e('s.clothing.equipped'))
        self.assertNotIn('hats', eq)
        self.assertNotIn('masks', eq)
        self.assertNotIn('heads', eq)
        self.assertNotIn('boots', eq)
        self.assertEqual(self.e('s.hair.style'), 0)
        self.assertEqual(self.e('fs.hair.facial'), 0)
        self.assertIsNone(self.e('fs.overlays.beardstabble'))

    def test_rules_tints_states_in_sanitize(self):
        self.run('''
            a = S.default("male")
            a.clothing.equipped.coats = h("male", "coats", 1)
            a.clothing.equipped.coats_closed = h("male", "coats_closed", 1)
            a.clothing.equipped.gunbelt_accs = h("male", "gunbelt_accs", 1)
            a.clothing.tints.boots = { palette = "metaped_tint_leather", tint0 = 3, tint1 = 4, tint2 = 5 }
            a.clothing.tints.hats = { palette = "metaped_tint_hat", tint0 = 1, tint1 = 1, tint2 = 1 }
            a.clothing.tints.shirts_full = { palette = "metaped_tint_leather", tint0 = 999, tint1 = 1, tint2 = 1 }
            a.clothing.states = { hat = "off", bandana = "up", sleeves = "rolled", coat = "sideways", bogus = "on" }
            a.clothing.outfit = "7"
            s = S.sanitize(a)
        ''')
        eq = self.rt.py(self.e('s.clothing.equipped'))
        self.assertIn('coats', eq)
        self.assertNotIn('coats_closed', eq)
        self.assertNotIn('gunbelt_accs', eq)
        self.assertEqual(self.rt.py(self.e('s.clothing.tints')), {'boots': {'palette': 'metaped_tint_leather', 'tint0': 3, 'tint1': 4, 'tint2': 5}})
        # bandana does not persist; coat value invalid; bogus unknown
        self.assertEqual(self.rt.py(self.e('s.clothing.states')), {'hat': 'off', 'sleeves': 'rolled'})
        self.assertEqual(self.e('s.clothing.outfit'), 7)

    # -- legacy ------------------------------------------------------------------------------
    def test_v2_legacy_row(self):
        self.run('''
            comps = {
                heads = signed(h("male", "heads", 2, 3)), eyes = h("male", "eyes", 1, 5), teeth = h("male", "teeth", 1, 2),
                BODIES_UPPER = h("male", "BODIES_UPPER", 2, 3), BODIES_LOWER = h("male", "BODIES_LOWER", 2, 3),
                hair = h("male", "hair", 3, 2), mustache = signed(h("male", "mustache", 2, 1)),
                hats = h("male", "hats", 2, 1), coats = h("male", "coats", 1, 1), masks = 0,
                __version = 2, __scale = 1.05, __waist = 4,
                __expressions = { arms = 0.5, jawY = -0.2, headWidth = 0.1 },
                __grooming = { hair = { stage = 2, seconds = 30 } },
            }
            row = { isMale = 1, components = json.encode(comps),
                    faceFeatures = json.encode({ { hash = 34006, index = 0.4 }, { hash = 60334, index = -0.3 },
                                                 { hash = 999999, index = 1 } }),
                    overlays = json.encode({ { compType = "blush", offsetModel = 2, offsetVariation = 7, opacity = 0.5 },
                                             { compType = "scars", offsetModel = 0, offsetVariation = 1, opacity = 1 },
                                             { compType = "nope", offsetModel = 1 } }) }
            a, meta = S.fromLegacy(row)
        ''')
        self.assertEqual(self.e('meta.version'), 2)
        self.assertEqual(self.e('#meta.defaultsUsed'), 0)
        self.assertEqual(self.e('a.sex'), 'male')
        self.assertTrue(self.e('a.head.head == h("male", "heads", 2, 3) and a.hair.facial == h("male", "mustache", 2, 1)'))
        self.assertTrue(self.e('a.body.upper == h("male", "BODIES_UPPER", 2, 3)'))
        self.assertEqual(self.e('a.body.height'), 1.05)
        self.assertEqual(self.e('a.body.weight'), 4)
        # faceFeatures win over __expressions (headWidth = 34006)
        self.assertEqual(self.rt.py(self.e('a.morph')), {'arms': 0.5, 'jawY': -0.2, 'headWidth': 0.4, 'jawWidth': -0.3})
        self.assertEqual(self.rt.py(self.e('a.overlays')), {'blush': {'style': 2, 'color': 7, 'opacity': 0.5}})
        self.assertEqual(set(self.rt.py(self.e('a.clothing.equipped')).keys()), {'hats', 'coats'})
        self.assertEqual(self.rt.py(self.e('a.grooming')), {'hair': {'stage': 2, 'seconds': 30}})

    def test_v1_legacy_model_variant_arrays(self):
        self.run('''
            row = { isMale = true, components = { heads = {3, 4}, eyes = {1, 5}, teeth = {1, 1},
                                                  BODIES_UPPER = {2, 4}, hair = {2, 3}, hats = {2, 1}, boots = {0, 1} },
                    faceFeatures = {}, overlays = {} }
            a, meta = S.fromLegacy(row)
        ''')
        self.assertEqual(self.e('meta.version'), 1)
        self.assertEqual(self.e('#meta.defaultsUsed'), 0)
        self.assertTrue(self.e('a.head.head == h("male", "heads", 3, 4)'))
        self.assertTrue(self.e('a.body.upper == h("male", "BODIES_UPPER", 2, 4)'))
        # the lower body is paired by name with the upper body (same model and tone)
        self.assertEqual(self.e('nameOf("male", "BODIES_LOWER", a.body.lower)'), 'CLOTHING_ITEM_M_BODIES_LOWER_002_V_004')
        self.assertTrue(self.e('a.clothing.equipped.hats == h("male", "hats", 2, 1)'))
        self.assertIsNone(self.e('a.clothing.equipped.boots'))
        self.assertEqual(self.rt.py(self.e('a.overlays')), {})

    def test_legacy_without_overlays_gets_default_eyebrows(self):
        self.run('a = S.fromLegacy({ isMale = 0, components = "{}" })')
        self.assertEqual(self.e('a.sex'), 'female')
        self.assertEqual(self.e('a.overlays.eyebrows.style'), 1)

    def test_legacy_mismatched_tone_is_repaired_from_the_head(self):
        self.run('a = S.fromLegacy({ isMale = 1, components = { heads = {3, 2}, eyes = {1, 1}, teeth = {1, 1}, BODIES_UPPER = {2, 4} } })')
        self.assertEqual(self.e('nameOf("male", "BODIES_UPPER", a.body.upper)'), 'CLOTHING_ITEM_M_BODIES_UPPER_002_V_002')
        self.assertEqual(self.e('nameOf("male", "BODIES_LOWER", a.body.lower)'), 'CLOTHING_ITEM_M_BODIES_LOWER_002_V_002')

    def test_corrupt_rows_report_defaults(self):
        self.run('a, meta = S.fromLegacy({ isMale = 1, components = "{not json", faceFeatures = "[", overlays = "x" })')
        self.assertEqual(sorted(self.rt.py(self.e('meta.defaultsUsed')).values()), ['body', 'eyes', 'face'])
        self.run('b, meta2 = S.normalize("{broken")')
        self.assertEqual(self.e('b.version'), 3)
        self.assertGreater(self.e('#meta2.defaultsUsed'), 0)
        for raw in ('nil', '42', 'true', '{version = 3, body = "x", head = 7, clothing = {equipped = "z"}}',
                    '{isMale = 1, components = {heads = {"a", "b"}}}', 'function() end'):
            self.run('ok, n = pcall(S.normalize, %s)' % raw)
            self.assertTrue(self.e('ok and n.version == 3'), raw)
        self.run('c, meta3 = S.fromLegacy({ isMale = 1, components = json.encode({heads = 1, BODIES_UPPER = h("male", "BODIES_UPPER", 1, 1)}) })')
        self.assertEqual(sorted(self.rt.py(self.e('meta3.defaultsUsed')).values()), ['eyes', 'face'])

    def test_v3_round_trips(self):
        self.run('''
            a = S.default("male")
            S.setHead(a, 3); S.setSkinTone(a, 4)
            a.morph = { headWidth = 0.25, arms = -0.5, mouthConerLeftWidth = 0.75, earlobes = 0.1 }
            a.hair.facial = h("male", "mustache", 3, 2)
            a.overlays.freckles = { style = 3, color = 9, opacity = 0.4 }
            a.overlays.beardstabble = { style = 1, color = 2, opacity = 1 }
            a.clothing.equipped.hats = h("male", "hats", 2, 1)
            a.grooming = { hair = { stage = 1, seconds = 10 }, beard = { stage = 2, seconds = 0 } }
            a.body.height = 0.95
            a = S.sanitize(a)
            viaJson = S.normalize(json.encode(a))
            legacy = S.toLegacy(a)
            back, meta = S.fromLegacy(legacy)
        ''')
        self.assertTrue(self.e('S.equal(a, viaJson)'))
        self.assertTrue(self.e('S.equal(a, back)'), self.e('json.encode(back)'))
        self.assertEqual(self.e('meta.version'), 2)
        self.assertEqual(self.e('legacy.isMale'), 1)
        comps = json.loads(self.e('legacy.components'))
        self.assertEqual(comps['__version'], 2)
        self.assertEqual(comps['__scale'], 0.95)
        self.assertIn('arms', comps['__expressions'])
        self.assertIn('mouthConerLeftWidth', comps['__expressions'])
        features = json.loads(self.e('legacy.faceFeatures'))
        self.assertEqual(sorted(f['hash'] for f in features), [34006, 60720])
        overlays = json.loads(self.e('legacy.overlays'))
        self.assertEqual([o['compType'] for o in overlays], ['freckles', 'eyebrows', 'beardstabble'])

    def test_female_round_trip(self):
        self.run('''
            f = S.default("female")
            S.equip(f, "skirts", h("female", "skirts", 2, 1))
            f.overlays.lipsticks = { style = 1, color = 30, opacity = 0.7 }
            f = S.sanitize(f)
            back = S.fromLegacy(S.toLegacy(f))
        ''')
        self.assertIsNone(self.e('f.clothing.equipped.pants'))  # skirts conflict with pants
        self.assertTrue(self.e('S.equal(f, back)'))
        self.assertEqual(self.e('S.toLegacy(f).isMale'), 0)
        self.assertNotIn('mustache', json.loads(self.e('S.toLegacy(f).components')))

    # -- skin tone ---------------------------------------------------------------------------
    def test_skin_tone_helpers(self):
        self.run('a = S.default("male"); ok = S.setSkinTone(a, 3)')
        self.assertTrue(self.e('ok'))
        self.assertEqual(self.e('S.skinTone(a)'), 3)
        self.assertTrue(self.e('nameOf("male", "BODIES_UPPER", a.body.upper):sub(-5) == "V_003"'))
        self.assertTrue(self.e('nameOf("male", "BODIES_LOWER", a.body.lower):sub(-5) == "V_003"'))
        self.run('S.setHead(a, 2)')
        self.assertEqual(self.e('nameOf("male", "heads", a.head.head)'), 'CLOTHING_ITEM_M_HEAD_002_V_003')
        self.run('S.setBodyType(a, 3)')
        self.assertEqual(self.e('nameOf("male", "BODIES_UPPER", a.body.upper)'), 'CLOTHING_ITEM_M_BODIES_UPPER_003_V_003')
        self.assertEqual(self.e('nameOf("male", "BODIES_LOWER", a.body.lower)'), 'CLOTHING_ITEM_M_BODIES_LOWER_003_V_003')
        self.assertFalse(self.e('S.setSkinTone(a, 0/0)'))
        # a mismatched body tone is repaired by adopting the head's
        self.run('a.body.upper = h("male", "BODIES_UPPER", 3, 1); s = S.sanitize(a)')
        self.assertEqual(self.e('nameOf("male", "BODIES_UPPER", s.body.upper)'), 'CLOTHING_ITEM_M_BODIES_UPPER_003_V_003')

    # -- sections ----------------------------------------------------------------------------
    def test_merge_sections_isolates_permissions(self):
        self.run('''
            saved = S.default("male")
            sub = WCUtil.copy(saved)
            S.setHead(sub, 4); S.setSkinTone(sub, 5)
            sub.morph = { jawWidth = 0.5, arms = 0.3 }
            sub.head.eyes = h("male", "eyes", 1, 9)
            sub.hair.style = h("male", "hair", 5, 1)
            sub.clothing.equipped = { hats = h("male", "hats", 1, 1) }
            sub.overlays.blush = { style = 1, color = 1, opacity = 1 }
            sub.overlays.scars = { style = 2, color = 1, opacity = 1 }
            sub.grooming = { hair = { stage = 3, seconds = 1 } }
            sub.sex = "female"
            surgery = S.mergeSections(saved, sub, { face = true, eyes = true })
        ''')
        # face + eyes taken; the tone stays the saved one; nothing else changes
        self.assertEqual(self.e('nameOf("male", "heads", surgery.head.head)'), 'CLOTHING_ITEM_M_HEAD_004_V_001')
        self.assertEqual(self.rt.py(self.e('surgery.morph')), {'jawWidth': 0.5})
        self.assertTrue(self.e('surgery.head.eyes == h("male", "eyes", 1, 9)'))
        self.assertTrue(self.e('surgery.hair.style == saved.hair.style'))
        self.assertTrue(self.e('WCUtil.deepEqual(surgery.clothing, saved.clothing)'))
        self.assertIsNone(self.e('surgery.overlays.blush'))
        self.assertIsNone(self.e('surgery.overlays.scars'))
        self.assertEqual(self.e('surgery.sex'), 'male')
        self.assertTrue(self.e('WCUtil.deepEqual(surgery.grooming, saved.grooming)'))
        changed = set(self.rt.py(self.e('S.changedSections(saved, surgery)')).keys())
        self.assertEqual(changed, {'face', 'eyes'})

        self.run('skin = S.mergeSections(saved, sub, { skin = true })')
        self.assertEqual(self.e('S.skinTone(skin)'), 5)
        self.assertEqual(self.e('nameOf("male", "heads", skin.head.head)'), 'CLOTHING_ITEM_M_HEAD_008_V_005')
        self.assertIsNotNone(self.e('skin.overlays.scars'))
        self.assertEqual(set(self.rt.py(self.e('S.changedSections(saved, skin)')).keys()), {'skin'})

        self.run('store = S.mergeSections(saved, sub, { "clothing" })')
        self.assertEqual(set(self.rt.py(self.e('S.changedSections(saved, store)')).keys()), {'clothing'})
        self.run('barber = S.mergeSections(saved, sub, { hair = true, makeup = true, body = false })')
        self.assertEqual(set(self.rt.py(self.e('S.changedSections(saved, barber)')).keys()), {'hair', 'makeup'})
        self.run('none = S.mergeSections(saved, "garbage", { face = true })')
        self.assertTrue(self.e('S.equal(none, saved)'))

    def test_merge_invalid_submitted_essential_keeps_saved(self):
        self.run('''
            saved = S.default("male"); S.setHead(saved, 5)
            sub = WCUtil.copy(saved); sub.head.head = h("female", "heads", 1); sub.body.upper = 7
            m = S.mergeSections(saved, sub, { face = true, body = true })
        ''')
        self.assertTrue(self.e('m.head.head == saved.head.head and m.body.upper == saved.body.upper'))

    def test_changed_sections(self):
        self.run('a = S.default("male"); b = WCUtil.copy(a)')
        self.assertEqual(self.rt.py(self.e('S.changedSections(a, b)')), {})
        self.run('b.clothing.states = { hat = "off" }; b.overlays.lipsticks = { style = 1, color = 2, opacity = 1 }')
        self.assertEqual(set(self.rt.py(self.e('S.changedSections(a, b)')).keys()), {'states', 'makeup'})
        self.run('c = S.default("female")')
        changed = set(self.rt.py(self.e('S.changedSections(a, c)')).keys())
        self.assertEqual(changed, set(self.rt.py(self.e('S.SECTIONS')).values()) - {'identity'})

    def test_equip(self):
        self.run('a = S.default("male"); a.clothing.tints.coats = nil')
        self.run('_, removed, err = S.equip(a, "coats", h("male", "coats", 1))')
        self.assertIsNone(self.e('err'))
        self.run('a.clothing.tints.coats = { palette = "metaped_tint_leather", tint0 = 1, tint1 = 1, tint2 = 1 }')
        self.run('_, removed, err = S.equip(a, "coats_closed", h("male", "coats_closed", 1))')
        self.assertEqual(list(self.e('removed').values()), ['coats'])
        self.assertIsNone(self.e('a.clothing.equipped.coats'))
        self.assertIsNone(self.e('a.clothing.tints.coats'))
        self.run('_, _, err2 = S.equip(a, "hats", h("female", "hats", 1))')
        self.assertEqual(self.e('err2'), 'INVALID_COMPONENT')
        self.run('_, _, err3 = S.equip(a, "heads", h("male", "heads", 1))')
        self.assertEqual(self.e('err3'), 'INVALID_COMPONENT')
        self.run('S.equip(a, "coats_closed", 0)')
        self.assertIsNone(self.e('a.clothing.equipped.coats_closed'))


@unittest.skipUnless(REAL_CATALOG, 'w_lib catalogue not available')
class RealCatalogAppearanceTests(unittest.TestCase):
    def setUp(self):
        self.rt = Runtime(catalog='real').load_shared()
        self.rt.run(SETUP)
        self.e = self.rt.eval

    def test_defaults_and_round_trips_on_the_real_catalog(self):
        for sex in ('male', 'female'):
            self.rt.run('''
                d = S.default("%s")
                s, v, du = S.sanitize(d)
                -- dress every clothing category with its last model/variant, then round-trip
                a = WCUtil.copy(d)
                for category, entry in pairs(WCCatalog.forSex(a.sex)) do
                    if WCCatalog.isClothing(category) and #entry.models > 0 then
                        local variants = entry.models[#entry.models]
                        S.equip(a, category, variants[#variants].hash)
                    end
                end
                a = S.sanitize(a)
                back, meta = S.fromLegacy(S.toLegacy(a))
                viaJson = S.normalize(json.encode(a))
            ''' % sex)
            self.assertTrue(self.e('S.equal(d, s) and #v == 0 and #du == 0'), sex)
            self.assertGreater(self.e('(function() local n = 0 for _ in pairs(a.clothing.equipped) do n = n + 1 end return n end)()'), 20)
            self.assertTrue(self.e('S.equal(a, back)'), sex)
            self.assertTrue(self.e('S.equal(a, viaJson)'), sex)
            self.assertEqual(self.e('#meta.defaultsUsed'), 0)


if __name__ == '__main__':
    unittest.main()
