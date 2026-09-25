"""WCCatalog (index, resolve, taxonomy, prices, store profiles, tints) and WCRules."""
import unittest

from harness import REAL_CATALOG, Runtime

# Real hashes present in tests/fixtures/catalog.lua
M_HAT = 'WCCatalog.forSex("male").hats.models[1][1].hash'
F_HAT = 'WCCatalog.forSex("female").hats.models[1][1].hash'


class CatalogTests(unittest.TestCase):
    def setUp(self):
        self.rt = Runtime().load_shared()
        self.e = self.rt.eval

    def test_index_shape_and_u32(self):
        cat = self.e('WCCatalog.forSex("male").heads')
        first = cat.models[1][1]
        self.assertEqual(first.name, 'CLOTHING_ITEM_M_HEAD_001_V_001')
        self.assertEqual(first.hash, 4042989040)
        info = cat.hashes[4042989040]
        self.assertEqual((info.model, info.variant), (1, 1))
        # cached per sex: the same table is returned
        self.assertTrue(self.e('WCCatalog.forSex("male") == WCCatalog.forSex("male")'))
        self.assertEqual(self.e('next(WCCatalog.forSex("other"))'), None)
        for h in self.rt.py(self.e('WCCatalog.forSex("male").hats.hashes')).keys():
            self.assertTrue(0 <= h <= 0xffffffff)

    def test_resolve_forms(self):
        h = self.e(M_HAT)
        signed = h - 0x100000000 if h >= 0x80000000 else h
        self.assertEqual(self.e('WCCatalog.resolve("male", "hats", %d)' % signed), h)
        self.assertEqual(self.e('WCCatalog.resolve("male", "hats", "%d")' % h), h)
        self.assertEqual(self.e('WCCatalog.resolve("male", "hats", {hash = %d})' % h), h)
        self.assertEqual(self.e('WCCatalog.resolve("male", "hats", {1, 1})'), h)
        self.assertEqual(self.e('WCCatalog.resolve("male", "hats", {model = 1, variant = 1})'), h)
        self.assertIsNone(self.e('WCCatalog.resolve("male", "hats", {99, 1})'))
        self.assertIsNone(self.e('WCCatalog.resolve("male", "hats", 12345)'))
        self.assertIsNone(self.e('WCCatalog.resolve("male", "boots", %d)' % h))   # wrong category
        self.assertIsNone(self.e('WCCatalog.resolve("male", "nope", %d)' % h))
        self.assertIsNone(self.e('WCCatalog.resolve("male", "hats", 0/0)'))

    def test_cross_sex_hash_is_rejected(self):
        f = self.e(F_HAT)
        self.assertIsNone(self.e('WCCatalog.resolve("male", "hats", %d)' % f))
        self.assertIsNone(self.e('WCCatalog.item("male", %d)' % f))
        item = self.e('WCCatalog.item("female", %d)' % f)
        self.assertEqual((item.category, item.model, item.variant), ('hats', 1, 1))

    def test_clothing_and_groups(self):
        self.assertTrue(self.e('WCCatalog.isClothing("hats")'))
        self.assertTrue(self.e('WCCatalog.isClothing("jewelry_rings_left")'))
        for part in ('heads', 'eyes', 'teeth', 'BODIES_UPPER', 'BODIES_LOWER', 'hair', 'mustache', 'x'):
            self.assertFalse(self.e('WCCatalog.isClothing("%s")' % part), part)
        g = self.e('WCCatalog.groupOf("coats_closed")')
        self.assertEqual((g.group, g.sub), ('upper', 'coats_closed'))
        self.assertIsNone(self.e('WCCatalog.groupOf("heads")'))
        self.assertTrue(self.e('WCCatalog.ESSENTIAL.heads and WCCatalog.ESSENTIAL.BODIES_LOWER'))
        self.assertEqual(self.e('WCCatalog.styleLabel("hats", 3)'), 'القبعة 03')

    def test_prices_and_profiles(self):
        h = self.e(M_HAT)
        self.assertEqual(self.e('WCCatalog.price("hats", %d)' % h), 3.5)
        self.assertEqual(self.e('WCCatalog.price("hats", %d, "standard")' % h), 3.5)
        self.assertIsNone(self.e('WCCatalog.price("hats", %d, "nope")' % h))
        self.assertIsNone(self.e('WCCatalog.price("hats", 1234)'))
        self.assertIsNone(self.e('WCCatalog.price("heads", nil)'))
        self.rt.run('Config.Clothing.pricingProfiles.cheap = {multiplier = 0.333}')
        self.assertEqual(self.e('WCCatalog.price("hats", %d, "cheap")' % h), 1.17)
        self.rt.run('Config.Clothing.prices.masks = -1')
        mask = self.e('WCCatalog.forSex("male").masks.models[1][1].hash')
        self.assertIsNone(self.e('WCCatalog.price("masks", %d)' % mask))
        self.assertFalse(self.e('WCCatalog.available("general", "male", "masks", %d)' % mask))
        self.assertTrue(self.e('WCCatalog.available("general", "male", "hats", %d)' % h))
        self.assertFalse(self.e('WCCatalog.available("general", "female", "hats", %d)' % h))
        self.assertFalse(self.e('WCCatalog.available("missing", "male", "hats", %d)' % h))
        boots = self.e('WCCatalog.forSex("male").boots.models[1][1].hash')
        self.assertTrue(self.e('WCCatalog.available("premium", "male", "boots", %d)' % boots))
        gunbelt = self.e('WCCatalog.forSex("male").gunbelts.models[1][1].hash')
        self.assertFalse(self.e('WCCatalog.available("premium", "male", "gunbelts", %d)' % gunbelt))
        self.rt.run('Config.Clothing.storeProfiles.premium.models.hats = {min = 2, max = 3}')
        self.assertFalse(self.e('WCCatalog.available("premium", "male", "hats", %d)' % h))

    def test_tints(self):
        self.assertEqual(self.e('WCCatalog.tintable("hats")[1]'), 'metaped_tint_hat')
        # the default list (metaped_tint_horse joined it: offered everywhere, as the game allows)
        self.assertEqual(self.e('#WCCatalog.tintable("shirts_full")'), 6)
        self.assertIsNone(self.e('WCCatalog.tintable("jewelry_rings_left")'))
        self.assertIsNone(self.e('WCCatalog.tintable("heads")'))
        ok = '{palette = "metaped_tint_leather", tint0 = 1, tint1 = 254, tint2 = 0}'
        self.assertTrue(self.e('WCCatalog.validTint("boots", %s)' % ok))
        self.assertFalse(self.e('WCCatalog.validTint("hats", %s)' % ok))
        for bad in ('{palette = "metaped_tint_leather", tint0 = 255, tint1 = 0, tint2 = 0}',
                    '{palette = "metaped_tint_leather", tint0 = 1.5, tint1 = 0, tint2 = 0}',
                    '{palette = "metaped_tint_leather", tint0 = 0/0, tint1 = 0, tint2 = 0}',
                    '{palette = "nope", tint0 = 0, tint1 = 0, tint2 = 0}', '"x"'):
            self.assertFalse(self.e('WCCatalog.validTint("boots", %s)' % bad), bad)
        self.rt.run('Config.Clothing.tints.enabled = false')
        self.assertIsNone(self.e('WCCatalog.tintable("boots")'))

    def test_color_key(self):
        self.assertEqual(self.e('WCCatalog.colorKey("CLOTHING_ITEM_M_HAIR_001_DArk_blonde")'), 'أشقر داكن')
        self.assertEqual(self.e('WCCatalog.colorKey("CLOTHING_ITEM_M_BEARD_004_jet_black")'), 'أسود فاحم')
        self.assertIsNone(self.e('WCCatalog.colorKey("CLOTHING_ITEM_M_HAT_001")'))
        self.assertIsNone(self.e('WCCatalog.colorKey(nil)'))


class TaxonomyCoverageTests(unittest.TestCase):
    def check(self, rt):
        tax = rt.py(rt.eval('Config.Clothing.taxonomy'))
        seen = []
        for group in tax.values():
            for sub in group['subs'].values():
                seen.append(sub['category'])
                self.assertIn('camera', sub)
                self.assertIn('order', sub)
        self.assertEqual(len(seen), len(set(seen)), 'a category appears twice')
        catalog = set()
        for sex in ('male', 'female'):
            for category in rt.py(rt.eval('WCCatalog.forSex("%s")' % sex)).keys():
                if rt.eval('WCCatalog.isClothing("%s")' % category):
                    catalog.add(category)
        self.assertTrue(catalog <= set(seen), catalog - set(seen))
        arts = {sub['art'] for g in tax.values() for sub in g['subs'].values() if 'art' in sub}
        self.assertEqual(arts, {'hat', 'shirt', 'coat', 'ccoat', 'vest', 'boots', 'gloves', 'mask', 'gunbelt'})
        return seen, catalog

    def test_fixture_catalog_covered(self):
        self.check(Runtime().load_shared())

    @unittest.skipUnless(REAL_CATALOG, 'w_lib catalogue not available')
    def test_real_catalog_covered_exactly_once(self):
        seen, catalog = self.check(Runtime(catalog='real').load_shared())
        self.assertEqual(set(seen), catalog)
        self.assertEqual(len(seen), 35)


class RulesTests(unittest.TestCase):
    def setUp(self):
        self.rt = Runtime().load_shared()
        self.e = self.rt.eval

    def test_conflicts_are_symmetric(self):
        self.assertEqual(list(self.e('WCRules.conflicts.dresses').values()), ['pants', 'skirts'])
        self.assertIn('dresses', list(self.e('WCRules.conflicts.pants').values()))
        self.assertIn('coats', list(self.e('WCRules.conflicts.coats_closed').values()))
        self.assertEqual(list(self.e('WCRules.requires.gunbelt_accs').values()), ['gunbelts'])

    def test_equip_replaces_conflicts_and_dependants(self):
        self.rt.run('eq, removed = WCRules.equip({coats = 1, belts = 2, belt_buckles = 3}, "coats_closed", 9)')
        self.assertEqual(self.rt.py(self.e('eq')), {'coats_closed': 9, 'belts': 2, 'belt_buckles': 3})
        self.assertEqual(list(self.e('removed').values()), ['coats'])
        self.rt.run('eq2, removed2 = WCRules.equip(eq, "belts", 0)')
        self.assertEqual(self.rt.py(self.e('eq2')), {'coats_closed': 9})
        self.assertEqual(list(self.e('removed2').values()), ['belt_buckles', 'belts'])
        self.rt.run('eq3, removed3 = WCRules.equip({}, "gunbelt_accs", 5)')
        self.assertEqual(self.rt.py(self.e('eq3')), {})
        self.assertEqual(list(self.e('removed3').values()), ['gunbelt_accs'])
        self.rt.run('eq4 = WCRules.equip({pants = 1, skirts = 2}, "dresses", 3)')
        self.assertEqual(self.rt.py(self.e('eq4')), {'dresses': 3})

    def test_normalize_is_deterministic(self):
        self.rt.run('n, v = WCRules.normalize({coats = 1, coats_closed = 2, gunbelt_accs = 3, pants = 4, skirts = 5})')
        self.assertEqual(self.rt.py(self.e('n')), {'coats': 1, 'pants': 4})
        reasons = sorted((x['category'], x['reason']) for x in self.rt.py(self.e('v')).values())
        self.assertEqual(reasons, [('coats_closed', 'conflict'), ('gunbelt_accs', 'requires'), ('skirts', 'conflict')])

    def test_can_remove(self):
        self.assertFalse(self.e('WCRules.canRemove("heads")'))
        self.assertTrue(self.e('WCRules.canRemove("hats")'))


if __name__ == '__main__':
    unittest.main()
