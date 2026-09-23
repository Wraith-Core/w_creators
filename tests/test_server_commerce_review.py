"""Server commerce: regressions for the review findings (store pricing scope, stale visibility
states, wardrobe ownership writes, expired sessions, exact outfit ids, malformed payloads,
invisible outfit names, degraded appearances, outfit logs, remote wardrobes turned off)."""
import unittest

from test_server_commerce_store import commerce
from test_server_commerce_wardrobe import wardrobe

HAT_TINT = "{ palette = 'metaped_tint_hat', tint0 = 1, tint1 = 2, tint2 = 3 }"


class StorePricingScopeTests(unittest.TestCase):
    """Only the categories the player changed are priced (finding 1)."""

    def setUp(self):
        self.rt = commerce()
        self.e = self.rt.eval
        self.rt.run('hat = h("male", "hats", 1); gloves = h("male", "gloves", 2)')

    def open(self):
        self.rt.run('r = openStore(); storeToken = r.data.token; app = working()')
        self.assertTrue(self.e('r.ok'), self.e('r.code'))

    def test_untouched_item_with_a_saved_tint_is_not_charged(self):
        # owned hat without a tint, worn with a tint set elsewhere (SetClothes)
        self.rt.run('''
            own('vorp:1', 'hats', hat)
            b = S.default('male'); b.clothing.equipped.hats = hat; b.clothing.tints.hats = %s
            setSaved('vorp:1', b)
        ''' % HAT_TINT)
        self.open()
        self.rt.run('app.clothing.equipped.gloves = gloves; res = buy(app)')
        self.assertTrue(self.e('res.ok'), self.e('res.code'))
        self.assertEqual(self.e('res.data.charged'), 4.25)
        self.assertEqual(self.e('#res.data.purchases'), 1)
        self.assertEqual(self.e('res.data.purchases[1].category'), 'gloves')
        self.assertIsNone(self.e('ownedRow("vorp:1", hat).palette'))          # never rewritten
        self.assertEqual(self.e('res.data.appearance.clothing.tints.hats.tint1'), 2)
        logs = [e for e in self.e('LogEmits').values() if e.event == 'clothing_purchased']
        self.assertEqual(len(logs), 1)

    def test_untouched_item_never_loses_its_paid_dye(self):
        # owned hat dyed, worn untinted
        self.rt.run('''
            own('vorp:1', 'hats', hat, { palette = 'metaped_tint_hat', tint0 = 9, tint1 = 9, tint2 = 9 })
            b = S.default('male'); b.clothing.equipped.hats = hat; setSaved('vorp:1', b)
        ''')
        self.open()
        self.rt.run('app.clothing.equipped.gloves = gloves; res = buy(app)')
        self.assertTrue(self.e('res.ok'), self.e('res.code'))
        self.assertEqual(self.e('res.data.charged'), 4.25)
        self.assertEqual(self.e('#res.data.purchases'), 1)
        self.assertEqual(self.e('ownedRow("vorp:1", hat).palette'), 'metaped_tint_hat')
        self.assertEqual(self.e('ownedRow("vorp:1", hat).tint0'), 9)

    def test_changing_the_tint_of_a_worn_item_is_still_charged(self):
        self.rt.run('''
            own('vorp:1', 'hats', hat)
            b = S.default('male'); b.clothing.equipped.hats = hat; b.clothing.tints.hats = %s
            setSaved('vorp:1', b)
        ''' % HAT_TINT)
        self.open()
        self.rt.run("app.clothing.tints.hats = { palette = 'metaped_tint_hat', tint0 = 5, tint1 = 5, tint2 = 5 }; "
                    "res = buy(app)")
        self.assertTrue(self.e('res.ok'), self.e('res.code'))
        self.assertEqual(self.e('res.data.charged'), 2.5)
        self.assertEqual(self.e('ownedRow("vorp:1", hat).tint0'), 5)
        # back to the item's original colour: free
        self.rt.run('storeToken = openStore().data.token; a = working(); a.clothing.tints.hats = nil; res = buy(a)')
        self.assertTrue(self.e('res.ok'), self.e('res.code'))
        self.assertEqual(self.e('res.data.charged'), 0)


class StoreStateTests(unittest.TestCase):
    """A saved visibility state never hides a newly bought item (finding 2)."""

    def setUp(self):
        self.rt = commerce()
        self.e = self.rt.eval

    def test_state_of_a_swapped_item_is_reset(self):
        self.rt.run('''
            b = S.default('male'); b.clothing.equipped.hats = h('male', 'hats', 2)
            b.clothing.states = { hat = 'off', sleeves = 'rolled' }
            setSaved('vorp:1', b)
            storeToken = openStore().data.token
            app = working(); app.clothing.equipped.hats = h('male', 'hats', 1)
            res = buy(app)
        ''')
        self.assertTrue(self.e('res.ok'), self.e('res.code'))
        self.assertEqual(self.e('res.data.charged'), 3.5)
        self.assertEqual(self.rt.py(self.e('res.data.appearance.clothing.states')), {'sleeves': 'rolled'})
        self.assertEqual(self.rt.py(self.e('saved().clothing.states')), {'sleeves': 'rolled'})
        logs = [e for e in self.e('LogEmits').values() if e.event == 'appearance_changed']
        self.assertEqual(list(logs[-1].payload.sections.values()), ['clothing', 'states'])

    def test_state_of_a_removed_item_is_dropped(self):
        self.rt.run('''
            b = S.default('male'); b.clothing.equipped.hats = h('male', 'hats', 2); b.clothing.states = { hat = 'off' }
            setSaved('vorp:1', b)
            storeToken = openStore().data.token
            app = working(); app.clothing.equipped.hats = nil; app.clothing.equipped.gloves = h('male', 'gloves', 2)
            res = buy(app)
        ''')
        self.assertTrue(self.e('res.ok'), self.e('res.code'))
        self.assertIsNone(self.e('res.data.appearance.clothing.states.hat'))


class StorePayloadAndOpenTests(unittest.TestCase):
    def setUp(self):
        self.rt = commerce()
        self.e = self.rt.eval

    def test_missing_equipped_map_is_not_remove_everything(self):
        self.rt.run('storeToken = openStore().data.token; tx = countTx(); res = buy({ clothing = {} })')
        self.assertEqual(self.e('res.code'), 'INVALID_PAYLOAD')
        self.assertEqual(self.e('countTx()'), self.e('tx'))
        self.assertTrue(self.e('saved().clothing.equipped.boots ~= nil'))
        self.rt.run('res = buy({ clothing = { tints = {} } })')
        self.assertEqual(self.e('res.code'), 'INVALID_PAYLOAD')

    def test_degraded_appearance_is_refused_at_open(self):
        self.rt.run('bad = S.default("male"); bad.head.head = 1; setSaved("vorp:1", bad); r = openStore()')
        self.assertEqual(self.e('r.code'), 'INTERNAL_ERROR')
        self.assertIsNone(self.e('WCSessions.current(1)'))


class WardrobeReviewTests(unittest.TestCase):
    def setUp(self):
        self.rt = wardrobe()
        self.e = self.rt.eval

    def open(self, where='"valentine_wardrobe"'):
        self.rt.run('r = openWardrobe(1, %s); wardrobeToken = r.data and r.data.token; app = working()' % where)
        self.assertTrue(self.e('r.ok'), self.e('r.code'))

    def test_remote_open_never_writes_ownership(self):
        # finding 3: a worn but unowned item (e.g. a job uniform) must not become owned
        self.rt.run('''
            gloves = h('male', 'gloves', 3)
            b = S.default('male'); b.clothing.equipped.gloves = gloves; setSaved('vorp:1', b)
            Players[1].coords = vector3(2000, -2000, 50)
            tx = countTx()
        ''')
        self.open('nil')
        self.assertEqual(self.e('countTx()'), self.e('tx'))
        self.assertIsNone(self.e('ownedRow("vorp:1", gloves)'))
        self.assertTrue(self.e('r.data.owned[tostring(gloves)].worn'))
        # the worn item stays wearable; the commit writes no ownership either
        self.rt.run('own("vorp:1", "hats", hat); app.clothing.equipped.hats = hat; res = wear(app)')
        self.assertTrue(self.e('res.ok'), self.e('res.code'))
        self.assertEqual(self.e('res.data.appearance.clothing.equipped.gloves'), self.e('gloves'))
        self.assertIsNone(self.e('ownedRow("vorp:1", gloves)'))
        # once taken off, it cannot be put back on
        self.rt.run('''
            r = openWardrobe(1, nil); wardrobeToken = r.data.token
            a = working(); a.clothing.equipped.gloves = nil; res = wear(a)
            r = openWardrobe(1, nil); wardrobeToken = r.data.token
            a = working(); a.clothing.equipped.gloves = gloves; res = wear(a)
        ''')
        self.assertEqual(self.e('res.code'), 'ITEM_NOT_OWNED')

    def test_states_of_items_not_worn_are_dropped(self):
        # finding 2: a state is kept only while its item is worn
        self.rt.run('own("vorp:1", "hats", hat)')
        self.open()
        self.rt.run('''
            app.clothing.equipped.hats = hat
            app.clothing.states = { gloves = 'off', coat = 'off', hat = 'off', sleeves = 'rolled', boots = 'under' }
            res = wear(app)
        ''')
        self.assertTrue(self.e('res.ok'), self.e('res.code'))
        self.assertEqual(self.rt.py(self.e('res.data.appearance.clothing.states')),
                         {'hat': 'off', 'sleeves': 'rolled', 'boots': 'under'})
        # removing the hat drops its saved state even when the client keeps sending it
        self.rt.run('''
            r = openWardrobe(1, 'valentine_wardrobe'); wardrobeToken = r.data.token
            a = working(); a.clothing.equipped.hats = nil; res = wear(a)
        ''')
        self.assertTrue(self.e('res.ok'), self.e('res.code'))
        self.assertIsNone(self.e('res.data.appearance.clothing.states.hat'))
        self.assertIsNone(self.e('saved().clothing.states.hat'))

    def test_states_only_submission_of_an_inapplicable_group_is_no_change(self):
        self.open()
        self.rt.run('app.clothing.states = { gloves = "off" }; res = wear(app)')
        self.assertEqual(self.e('res.code'), 'NO_CHANGES')

    def test_missing_equipped_map_is_invalid(self):
        self.open()
        self.rt.run('tx = countTx(); res = wear({ clothing = {} })')
        self.assertEqual(self.e('res.code'), 'INVALID_PAYLOAD')
        self.assertEqual(self.e('countTx()'), self.e('tx'))
        self.rt.run('res = wear({ clothing = { states = { sleeves = "rolled" } } })')
        self.assertEqual(self.e('res.code'), 'INVALID_PAYLOAD')

    def test_outfit_marker_must_be_an_exact_id(self):
        self.rt.run('''
            own('vorp:1', 'hats', hat)
            table.insert(outfitRows, { id = 1, charid = 'vorp:1', name = 'a', data = '{}' })
        ''')
        for bad in ('-7', '0', '1.5', '0.5', '"1x"'):
            self.open()
            self.rt.run('app.clothing.equipped.hats = hat; app.clothing.outfit = %s; res = wear(app)' % bad)
            self.assertTrue(self.e('res.ok'), bad)
            self.assertIsNone(self.e('res.data.appearance.clothing.outfit'), bad)
            self.rt.run('b = saved(); b.clothing.equipped.hats = nil; setSaved("vorp:1", b)')

    def test_degraded_appearance_is_refused_at_open(self):
        self.rt.run('bad = S.default("male"); bad.head.head = 1; setSaved("vorp:1", bad); '
                    'tx = countTx(); r = openWardrobe(1, "valentine_wardrobe")')
        self.assertEqual(self.e('r.code'), 'INTERNAL_ERROR')
        self.assertIsNone(self.e('WCSessions.current(1)'))
        self.assertEqual(self.e('countTx()'), self.e('tx'))


class OutfitReviewTests(unittest.TestCase):
    def setUp(self):
        self.rt = wardrobe()
        self.e = self.rt.eval
        self.rt.run('''
            own('vorp:1', 'hats', hat)
            r = openWardrobe(1, 'valentine_wardrobe'); wardrobeToken = r.data.token
            eq = working().clothing.equipped
            eq.hats = hat
        ''')
        self.assertTrue(self.e('r.ok'))

    def test_malformed_ids_never_target_another_outfit(self):
        # finding 5: -7 / 0 used to become 1, 2.9 used to become 2
        self.rt.run('a = outfit("save", wardrobeToken, "one", eq, {}); b = outfit("save", wardrobeToken, "two", eq, {})')
        self.assertTrue(self.e('a.ok and b.ok'))
        for bad in ('-7', '0', '2.9', '1.0000001', '1e12', '2147483648', '0/0', '1/0', '"1abc"', '" 1"', '{}', 'true'):
            for op in ('outfit("delete", wardrobeToken, %s)', 'outfit("rename", wardrobeToken, %s, "x")',
                       'outfit("update", wardrobeToken, %s, eq, {})'):
                self.rt.run('res = ' + op % bad)
                self.assertEqual(self.e('res.code'), 'OUTFIT_NOT_FOUND', op % bad)
        self.assertEqual(self.e('#outfitRows'), 2)
        self.assertEqual(self.e('outfitRows[1].name'), 'one')
        # an exact id (number, integral float or digit string) still works
        self.rt.run('res = outfit("rename", wardrobeToken, 2.0, "zwei")')
        self.assertTrue(self.e('res.ok'), self.e('res.code'))
        self.rt.run('res = outfit("delete", wardrobeToken, "1")')
        self.assertTrue(self.e('res.ok'), self.e('res.code'))
        self.assertEqual(self.e('#outfitRows'), 1)
        self.assertEqual(self.e('outfitRows[1].name'), 'zwei')
        self.assertIsNone(self.e('WCOutfits.get("vorp:1", 2.5)'))
        self.assertEqual(self.e('WCOutfits.get("vorp:1", 2).name'), 'zwei')

    def test_invisible_and_blank_names_are_rejected(self):
        # finding 7
        for name in (r'"\u{200B}"', r'"\u{00A0}"', r'"\u{200F}"', r'"\u{061C}"', r'"\u{00AD}"', r'"\u{2060}"',
                     r'"\u{200C}\u{200D}"', r'"a\u{200B}b"', r'"\u{3000}\u{00A0} "', r'"\u{3164}"',
                     r'"\u{E0041}"', r'"\u{206A}"'):
            self.assertIsNone(self.e('WCOutfits.validateName(%s)' % name), name)
            self.rt.run('res = outfit("save", wardrobeToken, %s, eq, {})' % name)
            self.assertEqual(self.e('res.code'), 'INVALID_OUTFIT_NAME', name)
        # other spaces become one ordinary space
        self.assertEqual(self.e(r'WCOutfits.validateName("\u{00A0}a\u{00A0}\u{2003}b\u{3000}")'), 'a b')
        self.assertEqual(self.e('WCOutfits.validateName("ملابس العمل")'), 'ملابس العمل')
        self.assertEqual(self.e('#outfitRows'), 0)

    def test_states_of_items_the_outfit_does_not_wear_are_dropped(self):
        self.rt.run('res = outfit("save", wardrobeToken, "x", eq, { gloves = "off", hat = "off", coat = "off" })')
        self.assertTrue(self.e('res.ok'), self.e('res.code'))
        self.assertEqual(self.rt.py(self.e('res.data.outfit.data.states')), {'hat': 'off'})
        self.rt.run('d = WCOutfits.validateData("vorp:1", "male", { boots = eq.boots }, { hat = "off", boots = "under" }, '
                    '{ boots = eq.boots }, {})')
        self.assertEqual(self.rt.py(self.e('d.states')), {})    # boots 'under' needs pants the outfit lacks

    def test_outfit_saved_is_logged(self):
        # finding 9
        self.rt.run('''
            res = outfit('save', wardrobeToken, 'one', eq, {}); id = res.data.outfit.id
            outfit('update', wardrobeToken, id, eq, { hat = 'off' })
            outfit('rename', wardrobeToken, id, 'two')
            outfit('delete', wardrobeToken, id)
        ''')
        logs = [e.payload for e in self.e('LogEmits').values() if e.event == 'outfit_saved']
        self.assertEqual([(p.charid, p.outfitId, p.name, p.playerSource) for p in logs],
                         [('vorp:1', 1, 'one', 1), ('vorp:1', 1, 'one', 1), ('vorp:1', 1, 'two', 1)])

    def test_remote_session_after_remote_wardrobes_are_turned_off(self):
        # finding 10
        self.rt.run('''
            WCSessions.clear(1)
            Players[1].coords = vector3(2000, -2000, 50)
            r = openWardrobe(1, nil); wardrobeToken = r.data.token
            ok1 = outfit('save', wardrobeToken, 'one', eq, {})
            Config.Wardrobe.allowRemote = false
            res = outfit('save', wardrobeToken, 'two', eq, {})
            del = outfit('delete', wardrobeToken, ok1.data.outfit.id)
        ''')
        self.assertTrue(self.e('ok1.ok'), self.e('ok1.code'))
        self.assertEqual(self.e('res.code'), 'LOCATION_NOT_FOUND')
        self.assertEqual(self.e('del.code'), 'LOCATION_NOT_FOUND')
        self.assertEqual(self.e('#outfitRows'), 1)


class ClothingStateSessionTests(unittest.TestCase):
    """An expired or abandoned session does not block clothing actions (finding 4)."""

    def setUp(self):
        self.rt = commerce()
        self.e = self.rt.eval
        self.rt.run('''
            base = S.default('male'); base.clothing.equipped.hats = h('male', 'hats', 1); setSaved('vorp:1', base)
            Players[1].coords = WARDROBE
            opened = call('w_creators:wardrobe:open', 1, 'valentine_wardrobe')
            WCSecurity.clear(1)
        ''')
        self.assertTrue(self.e('opened.ok'), self.e('opened.code'))

    def test_expired_session_does_not_block(self):
        self.rt.run('res = call("w_creators:clothing:setState", 1, "hat", "off")')
        self.assertEqual(self.e('res.code'), 'BUSY')
        self.rt.run('WCSessions.current(1).expires = os.time() - 5; res = call("w_creators:clothing:setState", 1, "hat", "off")')
        self.assertTrue(self.e('res.ok'), self.e('res.code'))
        self.assertEqual(self.e('saved().clothing.states.hat'), 'off')

    def test_expired_session_with_a_commit_running_still_blocks(self):
        self.rt.run('s = WCSessions.current(1); s.expires = os.time() - 5; s.busy = true; '
                    'res = call("w_creators:clothing:setState", 1, "hat", "off")')
        self.assertEqual(self.e('res.code'), 'BUSY')


if __name__ == '__main__':
    unittest.main()
