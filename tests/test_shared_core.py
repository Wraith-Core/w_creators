"""WCUtil, WCResult/WCCodes, WCDebug, WCServices, WCLocations and the config files."""
import re
import unittest

from harness import RESOURCE, REAL_CATALOG, Runtime, read


ARCH_CODES = re.findall(r'[A-Z_]{2,}', re.search(r'## 4\. Result contract.*?```(.*?)```',
                                                  read(RESOURCE / 'docs' / 'ARCHITECTURE.md'), re.S).group(1))


class UtilTests(unittest.TestCase):
    def setUp(self):
        self.rt = Runtime().load_shared()
        self.e = self.rt.eval

    def test_numbers(self):
        self.assertTrue(self.e('WCUtil.isFinite(1.5)'))
        for bad in ('0/0', '1/0', '-1/0', '"1"', 'nil'):
            self.assertFalse(self.e('WCUtil.isFinite(%s)' % bad), bad)
        self.assertEqual(self.e('WCUtil.number(0/0, 0, 1, 0.5)'), 0.5)
        self.assertEqual(self.e('WCUtil.number(1/0, 0, 1, 0.5)'), 0.5)
        self.assertEqual(self.e('WCUtil.number("2", 0, 1, 0.5)'), 1)
        self.assertEqual(self.e('WCUtil.number(-3, 0, 1)'), 0)
        self.assertEqual(self.e('WCUtil.int(3.9, 1, 5, 2)'), 3)
        self.assertEqual(self.e('math.type(WCUtil.int(3.0, 1, 5, 2))'), 'integer')
        self.assertEqual(self.e('WCUtil.int("x", 1, 5, 2)'), 2)

    def test_round2(self):
        self.assertEqual(self.e('WCUtil.round2(2.675)'), 2.68)
        self.assertEqual(self.e('WCUtil.round2(1.005)'), 1.01)
        self.assertEqual(self.e('WCUtil.round2(-1.555)'), -1.56)
        self.assertIsNone(self.e('WCUtil.round2(0/0)'))

    def test_u32(self):
        self.assertEqual(self.e('WCUtil.u32(-1)'), 0xffffffff)
        self.assertEqual(self.e('WCUtil.u32(4042989040.0)'), 4042989040)
        self.assertEqual(self.e('WCUtil.u32("123")'), 123)
        self.assertIsNone(self.e('WCUtil.u32(1.5)'))
        self.assertIsNone(self.e('WCUtil.u32(0/0)'))
        self.assertEqual(self.e("WCUtil.u32(GetHashKey('CLOTHING_ITEM_M_HEAD_001_V_001'))"), 4042989040)

    def test_decode_encode_never_throw(self):
        self.assertEqual(self.e('next(WCUtil.decode("{not json"))'), None)
        self.assertEqual(self.e('next(WCUtil.decode(42))'), None)
        self.assertEqual(self.e('WCUtil.decode(\'{"a":1}\').a'), 1)
        self.assertIsNone(self.e('(WCUtil.encode({a = 0/0}))'))
        self.assertEqual(self.e('WCUtil.jsonSize({a = 0/0})'), float('inf'))
        self.assertEqual(self.e('WCUtil.jsonSize({1,2})'), 5)

    def test_copy_equal_keys_trim(self):
        self.rt.run('t = {a = {b = {1, 2}}, c = "x"}; t2 = WCUtil.copy(t)')
        self.assertTrue(self.e('WCUtil.deepEqual(t, t2) and t.a ~= t2.a'))
        self.assertFalse(self.e('WCUtil.deepEqual(t, {a = {b = {1, 2}}})'))
        self.assertTrue(self.e('WCUtil.deepEqual(1, 1.0)'))
        self.assertEqual(list(self.e('WCUtil.sortedKeys({b=1, a=2, [2]=3, [1]=4})').values()), [1, 2, 'a', 'b'])
        self.assertEqual(self.e('WCUtil.trim("  a b  ")'), 'a b')

    def test_utf8(self):
        self.assertEqual(self.e('WCUtil.utf8len("مرحبا")'), 5)
        self.assertIsNone(self.e('WCUtil.utf8len("\\xff\\xfe")'))
        self.assertEqual(self.e('WCUtil.clampString("مرحبا بكم", 5)'), 'مرحبا')
        self.assertEqual(self.e('WCUtil.clampString("a\\xffb", 10)'), 'ab')

    def test_wait_until_uses_a_timeout(self):
        self.rt.run('n = 0; v = WCUtil.waitUntil(function() n = n + 1; return n >= 3 and "done" end, 1000)')
        self.assertEqual(self.e('v'), 'done')
        self.rt.run('t0 = GetGameTimer(); v2 = WCUtil.waitUntil(function() return false end, 50, 10)')
        self.assertIsNone(self.e('v2'))
        self.assertGreaterEqual(self.e('GetGameTimer() - t0'), 50)
        self.assertIsNone(self.e('WCUtil.waitUntil(function() error("boom") end, 20)'))


class ResultTests(unittest.TestCase):
    def setUp(self):
        self.rt = Runtime().load_shared()
        self.e = self.rt.eval

    def test_every_contract_code_has_a_locale_key(self):
        self.assertIn('INVALID_PAYLOAD', ARCH_CODES)
        for code in ARCH_CODES:
            self.assertEqual(self.e('WCCodes.%s' % code), code)
            key = self.e('WCResult.messageKey("%s")' % code)
            self.assertTrue(key and not re.match(r'^[A-Z_]+$', key), code)
        codes = set(self.rt.py(self.e('WCCodes')).keys())
        self.assertEqual(codes, set(ARCH_CODES))

    def test_shapes(self):
        self.rt.run('ok = WCResult.ok({x = 1}); bad = WCResult.fail("BUSY"); weird = WCResult.fail("NOPE")')
        self.assertTrue(self.e('ok.ok and ok.code == "OK" and ok.data.x == 1'))
        self.assertTrue(self.e('not bad.ok and bad.code == "BUSY" and bad.message == WCResult.messageKey("BUSY")'))
        self.assertEqual(self.e('weird.code'), 'INTERNAL_ERROR')
        self.assertTrue(self.e('WCResult.is(ok) and WCResult.is(bad) and not WCResult.is({}) and not WCResult.is(1)'))


class DebugServicesTests(unittest.TestCase):
    def setUp(self):
        self.rt = Runtime().load_shared()
        self.e = self.rt.eval

    def test_debug_is_silent_unless_enabled(self):
        self.rt.run('Printed = {}; WCDebug.log("x", "hidden %d", 1)')
        self.assertEqual(self.e('#Printed'), 0)
        self.rt.run('Config.Debug.enabled = true; Config.Debug.domains = {sessions = true}')
        self.rt.run('WCDebug.log("x", "hidden"); WCDebug.log("sessions", "shown %s", "a")')
        self.assertEqual(self.e('#Printed'), 1)
        self.assertIn('shown a', self.e('Printed[1].text'))
        self.rt.run('WCDebug.warn("y", "bad %d")')  # bad format args never throw
        self.assertEqual(self.e('#Printed'), 2)

    def test_services(self):
        names = self.rt.py(self.e('WCServices.names'))
        self.assertEqual(len(names), 11)
        for name in names.values():
            self.assertTrue(self.e('WCServices.enabled("%s")' % name), name)
        self.assertFalse(self.e('WCServices.enabled("unknown")'))
        self.rt.run('Config.Services.barbers = false')
        self.assertFalse(self.e('WCServices.enabled("barbers")'))
        self.assertEqual(self.e('WCServices.code("barbers")'), 'BARBER_DISABLED')
        self.assertEqual(self.e('WCServices.code("spawnSelector")'), 'SERVICE_DISABLED')
        self.rt.run('Config.CosmeticSurgery.enabled = false')
        self.assertFalse(self.e('WCServices.enabled("surgery")'))


class LocationTests(unittest.TestCase):
    def setUp(self):
        self.rt = Runtime().load_shared()
        self.e = self.rt.eval

    def test_config_locations(self):
        self.assertEqual(self.e('#WCLocations.byType("clothing")'), 4)
        self.assertEqual(self.e('#WCLocations.byType("barber")'), 7)
        self.assertEqual(self.e('#WCLocations.byType("wardrobe")'), 3)
        self.assertEqual(self.e('#WCLocations.byType("surgery")'), 3)
        loc = self.e('WCLocations.byId("valentine_clothing")')
        self.assertEqual(loc.storeProfile, 'general')
        self.assertEqual(loc.pricingProfile, 'standard')
        self.assertEqual(loc.npc.model, 'S_M_M_Tailor_01')
        self.assertAlmostEqual(loc.preview.w, 294.79)
        self.assertEqual(loc.interactionRadius, 2.0)
        self.assertFalse(self.e('WCLocations.byId("tumbleweed_clothing").npc'))
        surgery = self.e('WCLocations.byId("saintdenis_surgery")')
        self.assertFalse(surgery.prompt)
        self.assertFalse(surgery.blip)
        self.assertAlmostEqual(surgery.coords.x, 2387.306)
        self.assertAlmostEqual(self.e('WCLocations.byId("rhodes_wardrobe").coords.x'), 1223.55)
        for loc in self.e('WCLocations.all()').values():
            self.assertTrue(loc.enabled, loc.id)

    def test_usable_active_and_validation(self):
        self.rt.run('''
            table.insert(Config.Locations, { id = 'valentine_clothing', type = 'clothing', coords = vector3(1, 2, 3) })
            table.insert(Config.Locations, { id = 'nowhere', type = 'barber' })
            table.insert(Config.Locations, { id = 'odd', type = 'bank', coords = vector3(1, 2, 3) })
            Config.Locations[1].enabled = false
            WCLocations.reload()
            WCLocations.all()
        ''')
        warnings = [p.text for p in self.e('Printed').values() if p.level == 'warn']
        self.assertTrue(any('duplicate' in t for t in warnings))
        self.assertTrue(any('nowhere' in t for t in warnings))
        self.assertTrue(any('odd' in t for t in warnings))
        self.assertIsNone(self.e('WCLocations.byId("nowhere")'))
        self.assertEqual(self.e('#WCLocations.active("clothing")'), 3)
        self.assertFalse(self.e('WCLocations.isUsable(WCLocations.byId("valentine_clothing"))'))
        self.rt.run('Config.Services.clothingStores = false')
        self.assertEqual(self.e('#WCLocations.active("clothing")'), 0)
        self.assertEqual(self.e('#WCLocations.byType("clothing")'), 4)
        self.assertAlmostEqual(self.e('WCLocations.anchor(WCLocations.byId("blackwater_clothing")).x'), -761.98)


class ConfigTests(unittest.TestCase):
    def setUp(self):
        self.rt = Runtime().load_shared()
        self.e = self.rt.eval

    def test_ported_values(self):
        self.assertEqual(self.e('Config.Clothing.prices.hats'), 3.5)
        self.assertEqual(self.e('Config.Clothing.prices.holsters_left'), 3.12)
        self.assertEqual(self.e('Config.Clothing.tints.price'), 2.5)
        self.assertEqual(self.e('Config.Characters.defaultSlots'), 3)
        self.assertEqual(self.e('Config.Characters.deletion.holdTime'), 5000)
        self.assertEqual(self.e('Config.Characters.selection.keys.delete'), 'DELETE')
        self.assertEqual(self.e('Config.Scene.imaps[2]'), -1699673416)
        self.assertEqual(self.e('Config.Scene.cleanupRadius'), 25.0)
        self.assertEqual(self.e('#Config.Spawn.points'), 9)
        self.assertEqual(self.e('Config.Spawn.points[9].id'), 'annesburg')
        self.assertEqual(self.e('Config.Spawn.points[9].order'), 9)
        self.assertAlmostEqual(self.e('Config.Spawn.firstSpawn.coords.x'), -274.09)
        self.assertEqual(self.e('Config.Spawn.selector.transition'), 350)
        self.assertEqual(self.e('Config.Grooming.minutesPerStage.beard'), 60)
        self.assertEqual(self.e('Config.Grooming.saveIntervalSeconds'), 300)
        self.assertEqual(self.e('Config.CosmeticSurgery.price'), 500.0)
        self.assertFalse(self.e('Config.CosmeticSurgery.allow.clothing'))
        self.assertEqual(self.e('Config.Wardrobe.maxSavedOutfits'), 10)
        self.assertEqual(self.e('Config.Barber.services.hair.price'), 10)
        self.assertFalse(self.e('Config.Experimental.metapedRequestPath'))
        self.assertFalse(self.e('Config.Admin.spawnProp'))
        self.assertEqual(self.e('Config.Respawn.pollMs'), 250)

    def test_every_palette_exists_in_w_lib(self):
        palettes = set(self.rt.py(self.e('w.component.data.palettes')).values())
        tints = self.rt.py(self.e('Config.Clothing.tints'))
        names = list(tints['default'].values())
        for lst in tints['palettes'].values():
            if lst:
                names.extend(lst.values())
        for name in names:
            self.assertIn(name, palettes)

    @unittest.skipUnless(REAL_CATALOG, 'w_lib catalogue not available')
    def test_starting_outfits_resolve_in_the_real_catalog(self):
        rt = Runtime(catalog='real').load_shared()
        for sex in ('male', 'female'):
            for preset in rt.py(rt.eval('Config.StartingOutfits.%s' % sex)).values():
                for item in preset['items'].values():
                    h = rt.eval('WCCatalog.resolve("%s", "%s", {%d, %d})' % (sex, item['category'], item['model'], item['variant']))
                    self.assertIsNotNone(h, (sex, preset['id'], item))


if __name__ == '__main__':
    unittest.main()
