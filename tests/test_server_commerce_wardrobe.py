"""Server commerce: the wardrobe (WCWardrobeService) and saved outfits (WCOutfits)."""
import unittest

from test_server_commerce_store import commerce

WARDROBE_SETUP = r'''
Players[1].coords = WARDROBE
function openWardrobe(src, id)
    WCSecurity.clear(src or 1)
    return call('w_creators:wardrobe:open', src or 1, id)
end
function wear(app, token, opId)
    WCSecurity.clear(1)
    return call('w_creators:wardrobe:commit', 1, token or wardrobeToken, opId or nextOp(), app)
end
function outfit(op, ...)
    if not keepRate then WCSecurity.clear(1) end
    return call('w_creators:outfits:' .. op, 1, ...)
end
hat = h('male', 'hats', 1)
'''


def wardrobe():
    rt = commerce()
    rt.run(WARDROBE_SETUP)
    return rt


class WardrobeOpenTests(unittest.TestCase):
    def setUp(self):
        self.rt = wardrobe()
        self.e = self.rt.eval

    def test_open_at_a_location(self):
        self.rt.run('own("vorp:1", "hats", hat); r = openWardrobe(1, "valentine_wardrobe")')
        self.assertTrue(self.e('r.ok'), self.e('r.code'))
        self.assertTrue(self.e('type(r.data.token) == "string"'))
        self.assertEqual(self.e('r.data.maxOutfits'), 10)
        self.assertTrue(self.e('r.data.outfitsEnabled'))
        self.assertEqual(self.e('#r.data.outfits'), 0)
        self.assertTrue(self.e('r.data.owned[tostring(hat)] ~= nil'))
        # the clothes the character wears are listed (marked worn) but never made owned
        boots = self.e('h("male", "boots", 1)')
        self.assertTrue(self.e('r.data.owned[tostring(%d)].worn' % boots))
        self.assertEqual(self.e('r.data.owned[tostring(%d)].source' % boots), 'worn')
        self.assertIsNone(self.e('r.data.owned[tostring(hat)].worn'))
        self.assertIsNone(self.e('ownedRow("vorp:1", %d)' % boots))

    def test_remote_only_when_allowed(self):
        self.rt.run('Players[1].coords = vector3(0, 0, 0); r = openWardrobe(1, nil)')
        self.assertTrue(self.e('r.ok'), self.e('r.code'))
        self.assertTrue(self.e('r.data.remote'))
        self.rt.run('WCSessions.clear(1); Config.Wardrobe.allowRemote = false; r = openWardrobe(1, nil)')
        self.assertFalse(self.e('r.ok'))
        self.assertEqual(self.e('r.code'), 'LOCATION_NOT_FOUND')
        self.rt.run('r = openWardrobe(1, "valentine_wardrobe")')
        self.assertEqual(self.e('r.code'), 'TOO_FAR')

    def test_disabled_services(self):
        self.rt.run('Config.Services.wardrobe = false; r = openWardrobe(1, nil)')
        self.assertEqual(self.e('r.code'), 'WARDROBE_DISABLED')
        self.rt.run('r = openWardrobe(1, "valentine_wardrobe")')
        self.assertEqual(self.e('r.code'), 'WARDROBE_DISABLED')
        self.rt.run('Config.Services.wardrobe = true; Config.Services.savedOutfits = false; r = openWardrobe(1, nil)')
        self.assertTrue(self.e('r.ok'))
        self.assertFalse(self.e('r.data.outfitsEnabled'))


class WardrobeCommitTests(unittest.TestCase):
    def setUp(self):
        self.rt = wardrobe()
        self.e = self.rt.eval
        self.rt.run('''
            own('vorp:1', 'hats', hat, { palette = 'metaped_tint_hat', tint0 = 7, tint1 = 8, tint2 = 9 })
            r = openWardrobe(1, 'valentine_wardrobe'); wardrobeToken = r.data.token; app = working()
        ''')
        self.assertTrue(self.e('r.ok'))

    def test_wear_an_owned_item_with_its_owned_tint(self):
        self.rt.run('''
            app.clothing.equipped.hats = hat
            app.clothing.tints.hats = { palette = 'metaped_tint_hat', tint0 = 1, tint1 = 1, tint2 = 1 }
            res = wear(app)
        ''')
        self.assertTrue(self.e('res.ok'), self.e('res.code'))
        self.assertEqual(self.e('res.data.appearance.clothing.equipped.hats'), self.e('hat'))
        self.assertEqual(self.e('res.data.appearance.clothing.tints.hats.tint0'), 7)   # forced from ownership
        self.assertEqual(self.e('#MoneyCalls'), 0)
        self.assertEqual(self.e('saved().clothing.equipped.hats'), self.e('hat'))
        self.assertEqual(self.e('changedEvents[1].kind'), 'wardrobe')
        self.assertEqual(len(self.rt.client_events('w_creators:client:applyRemoteAppearance')), 1)
        self.assertIsNone(self.e('WCSessions.current(1)'))

    def test_unowned_item_is_rejected(self):
        self.rt.run('app.clothing.equipped.masks = h("male", "masks", 1); tx = countTx(); res = wear(app)')
        self.assertEqual(self.e('res.code'), 'ITEM_NOT_OWNED')
        self.assertEqual(self.e('countTx()'), self.e('tx'))
        self.rt.run('a = working(); a.clothing.equipped.hats = 99; res = wear(a)')
        self.assertEqual(self.e('res.code'), 'INVALID_COMPONENT')

    def test_states_are_saved_and_invalid_states_dropped(self):
        self.rt.run('''
            app.clothing.equipped.hats = hat
            app.clothing.states = { hat = 'off', sleeves = 'rolled', bandana = 'up', bogus = 'x', coat = 'maybe' }
            res = wear(app)
        ''')
        self.assertTrue(self.e('res.ok'))
        states = self.rt.py(self.e('res.data.appearance.clothing.states'))
        self.assertEqual(states, {'hat': 'off', 'sleeves': 'rolled'})

    def test_no_changes(self):
        self.rt.run('res = wear(app)')
        self.assertEqual(self.e('res.code'), 'NO_CHANGES')

    def test_outfit_id_must_belong_to_the_character(self):
        self.rt.run('''
            table.insert(outfitRows, { id = 50, charid = 'vorp:2', name = 'x', data = '{}' })
            table.insert(outfitRows, { id = 51, charid = 'vorp:1', name = 'y', data = '{}' })
            app.clothing.equipped.hats = hat; app.clothing.outfit = 50
            res = wear(app)
        ''')
        self.assertTrue(self.e('res.ok'))
        self.assertIsNone(self.e('res.data.appearance.clothing.outfit'))
        self.rt.run('''
            r = openWardrobe(1, 'valentine_wardrobe'); wardrobeToken = r.data.token
            a = working(); a.clothing.equipped.hats = nil; a.clothing.outfit = 51; res = wear(a)
        ''')
        self.assertTrue(self.e('res.ok'))
        self.assertEqual(self.e('res.data.appearance.clothing.outfit'), 51)

    def test_disabled_after_open(self):
        self.rt.run('Config.Services.wardrobe = false; app.clothing.equipped.hats = hat; res = wear(app)')
        self.assertEqual(self.e('res.code'), 'WARDROBE_DISABLED')

    def test_store_token_is_not_a_wardrobe(self):
        self.rt.run('''
            WCSessions.clear(1)
            Players[1].coords = STORE
            storeToken = openStore().data.token
            app.clothing.equipped.hats = hat
            res = wear(app, storeToken)
        ''')
        self.assertEqual(self.e('res.code'), 'SESSION_NOT_FOUND')


class OutfitTests(unittest.TestCase):
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

    def test_save_update_rename_delete(self):
        self.rt.run('res = outfit("save", wardrobeToken, "  Sunday   best ", eq, { hat = "off", bandana = "up" })')
        self.assertTrue(self.e('res.ok'), self.e('res.code'))
        self.assertEqual(self.e('res.data.outfit.name'), 'Sunday best')
        self.assertEqual(self.e('#res.data.outfits'), 1)
        self.assertEqual(self.e('res.data.outfit.data.equipped.hats'), self.e('hat'))
        self.assertEqual(self.rt.py(self.e('res.data.outfit.data.states')), {'hat': 'off'})
        self.rt.run('id = res.data.outfit.id; e2 = { boots = eq.boots }; res = outfit("update", wardrobeToken, id, e2, {})')
        self.assertTrue(self.e('res.ok'))
        self.assertIsNone(self.e('res.data.outfit.data.equipped.hats'))
        self.rt.run('res = outfit("rename", wardrobeToken, id, "عمل")')
        self.assertTrue(self.e('res.ok'))
        self.assertEqual(self.e('res.data.outfit.name'), 'عمل')
        self.rt.run('res = outfit("delete", wardrobeToken, id)')
        self.assertTrue(self.e('res.ok'))
        self.assertEqual(self.e('#res.data.outfits'), 0)
        self.assertEqual(self.e('#outfitRows'), 0)

    def test_limit(self):
        self.rt.run('''
            Config.Wardrobe.maxSavedOutfits = 2
            a = outfit('save', wardrobeToken, 'one', eq, {})
            b = outfit('save', wardrobeToken, 'two', eq, {})
            c = outfit('save', wardrobeToken, 'three', eq, {})
        ''')
        self.assertTrue(self.e('a.ok and b.ok'))
        self.assertEqual(self.e('c.code'), 'OUTFIT_LIMIT')
        self.assertEqual(self.e('#outfitRows'), 2)

    def test_other_characters_outfit_is_not_found(self):
        self.rt.run('table.insert(outfitRows, { id = 77, charid = "vorp:2", name = "theirs", data = "{}" })')
        for op in ('outfit("update", wardrobeToken, 77, eq, {})', 'outfit("rename", wardrobeToken, 77, "mine")',
                   'outfit("delete", wardrobeToken, 77)', 'outfit("delete", wardrobeToken, "77abc")',
                   'outfit("delete", wardrobeToken, -1)'):
            self.rt.run('res = %s' % op)
            self.assertEqual(self.e('res.code'), 'OUTFIT_NOT_FOUND', op)
        self.assertEqual(self.e('outfitRows[1].name'), 'theirs')
        self.assertEqual(self.e('#outfitRows'), 1)

    def test_invalid_names(self):
        for name in ('""', '"    "', 'string.rep("a", 25)', '"bad\\nname"', '"tab\\tname"', '"\\226\\128\\174evil"',
                     '"\\255\\254"', 'nil', '42', '{}', '"a\\0b"'):
            self.rt.run('res = outfit("save", wardrobeToken, %s, eq, {})' % name)
            self.assertEqual(self.e('res.code'), 'INVALID_OUTFIT_NAME', name)
        self.rt.run('res = outfit("save", wardrobeToken, string.rep("ب", 24), eq, {})')
        self.assertTrue(self.e('res.ok'))
        self.rt.run('res = outfit("rename", wardrobeToken, res.data.outfit.id, "\\r")')
        self.assertEqual(self.e('res.code'), 'INVALID_OUTFIT_NAME')

    def test_contents_are_validated(self):
        self.rt.run('bad = { masks = h("male", "masks", 1) }; res = outfit("save", wardrobeToken, "x", bad, {})')
        self.assertEqual(self.e('res.code'), 'ITEM_NOT_OWNED')
        self.rt.run('bad = { hats = h("female", "hats", 1) }; res = outfit("save", wardrobeToken, "x", bad, {})')
        self.assertEqual(self.e('res.code'), 'INVALID_COMPONENT')
        self.rt.run('res = outfit("save", wardrobeToken, "x", eq, { hat = "sideways" })')
        self.assertEqual(self.e('res.code'), 'STATE_NOT_SUPPORTED')
        self.rt.run('res = outfit("save", wardrobeToken, "x", "eq", {})')
        self.assertEqual(self.e('res.code'), 'INVALID_PAYLOAD')
        self.rt.run('''
            own('vorp:1', 'coats', h('male', 'coats', 1)); own('vorp:1', 'coats_closed', h('male', 'coats_closed', 1))
            bad = { coats = h('male', 'coats', 1), coats_closed = h('male', 'coats_closed', 1) }
            res = outfit('save', wardrobeToken, 'x', bad, {})
        ''')
        self.assertEqual(self.e('res.code'), 'CONFLICTING_ITEMS')
        self.assertEqual(self.e('#outfitRows'), 0)

    def test_requires_a_wardrobe_session_and_the_service(self):
        self.rt.run('res = outfit("save", "nope", "x", eq, {})')
        self.assertEqual(self.e('res.code'), 'SESSION_NOT_FOUND')
        self.rt.run('Config.Services.savedOutfits = false; res = outfit("save", wardrobeToken, "x", eq, {})')
        self.assertEqual(self.e('res.code'), 'OUTFITS_DISABLED')
        self.rt.run('''
            Config.Services.savedOutfits = true
            WCSessions.clear(1)
            Players[1].coords = STORE
            storeToken = openStore().data.token
            res = outfit('save', storeToken, 'x', eq, {})
        ''')
        self.assertEqual(self.e('res.code'), 'SESSION_NOT_FOUND')
        self.assertEqual(self.e('#outfitRows'), 0)

    def test_too_far_from_the_wardrobe(self):
        self.rt.run('Players[1].coords = vector3(0, 0, 0); res = outfit("save", wardrobeToken, "x", eq, {})')
        self.assertEqual(self.e('res.code'), 'TOO_FAR')

    def test_database_failure(self):
        self.rt.run('FakeDB.fail = "INSERT INTO w_creators_outfits"; res = outfit("save", wardrobeToken, "x", eq, {})')
        self.assertEqual(self.e('res.code'), 'DATABASE_ERROR')
        self.assertFalse(self.e('WCSecurity.locked("outfits:vorp:1")'))

    def test_rate_limit(self):
        self.rt.run('keepRate = true; for i = 1, 10 do outfit("delete", wardrobeToken, 999) end; '
                    'res = outfit("save", wardrobeToken, "x", eq, {})')
        self.assertEqual(self.e('res.code'), 'RATE_LIMITED')


class StarterOutfitTests(unittest.TestCase):
    """2026-11-13 (owner): the clothes a character was created in are one of his outfits, free and fixed."""

    def setUp(self):
        self.rt = wardrobe()
        self.e = self.rt.eval
        self.rt.run('''
            boots = h('male', 'boots', 1)
            own('vorp:1', 'boots', boots, nil, 'starter')
            own('vorp:1', 'hats', hat)
            eq = { hats = hat, boots = boots }
            r = openWardrobe(1, 'valentine_wardrobe'); wardrobeToken = r.data.token
        ''')
        self.assertTrue(self.e('r.ok'), self.e('r.code'))

    def starter_id(self):
        return self.e('(function() for _, o in ipairs(r.data.outfits) do if o.data.starter then return o.id end end end)()')

    def test_an_older_character_gets_it_once_from_his_starting_clothes(self):
        self.assertEqual(self.e('#r.data.outfits'), 1)
        self.assertEqual(self.e('r.data.outfits[1].name'), 'ملابس البداية')
        self.assertTrue(self.e('r.data.outfits[1].data.starter'))
        self.assertEqual(self.e('r.data.outfits[1].data.equipped.boots'), self.e('boots'))
        self.assertIsNone(self.e('r.data.outfits[1].data.equipped.hats'))  # a bought hat is not a starting piece
        self.rt.run('WCSessions.clear(1); r = openWardrobe(1, "valentine_wardrobe")')
        self.assertEqual(self.e('#r.data.outfits'), 1)
        self.assertEqual(self.e('#outfitRows'), 1)

    def test_it_is_worn_and_renamed_never_updated_or_deleted(self):
        sid = self.starter_id()
        self.assertIsNotNone(sid)
        self.rt.run('res = outfit("update", wardrobeToken, %d, eq, {})' % sid)
        self.assertEqual(self.e('res.code'), 'OUTFIT_LOCKED')
        self.rt.run('res = outfit("delete", wardrobeToken, %d)' % sid)
        self.assertEqual(self.e('res.code'), 'OUTFIT_LOCKED')
        self.assertEqual(self.e('#outfitRows'), 1)
        self.rt.run('res = outfit("rename", wardrobeToken, %d, "أول لبس")' % sid)
        self.assertTrue(self.e('res.ok'), self.e('res.code'))
        self.assertTrue(self.e('res.data.outfit.data.starter'))

    def test_it_does_not_count_against_the_limit(self):
        self.rt.run('''
            Config.Wardrobe.maxSavedOutfits = 1
            a = outfit('save', wardrobeToken, 'one', eq, {})
            b = outfit('save', wardrobeToken, 'two', eq, {})
        ''')
        self.assertTrue(self.e('a.ok'), self.e('a.code'))
        self.assertEqual(self.e('b.code'), 'OUTFIT_LIMIT')

    def test_a_saved_outfit_can_never_claim_to_be_the_starting_one(self):
        self.rt.run('''
            bad = outfit('save', wardrobeToken, 'fake', { boots = boots, starter = true }, {})
            res = outfit('save', wardrobeToken, 'mine', { boots = boots }, {})
            forged = json.decode(outfitRows[#outfitRows].data).starter
        ''')
        self.assertFalse(self.e('bad.ok'))
        self.assertTrue(self.e('res.ok'), self.e('res.code'))
        self.assertEqual(self.e('outfitRows[#outfitRows].name'), 'mine')
        self.assertIsNone(self.e('forged'))

    def test_off_in_the_config(self):
        self.rt.run('''
            outfitRows = {}; Config.Wardrobe.starterOutfit.enabled = false
            WCSessions.clear(1); r = openWardrobe(1, 'valentine_wardrobe')
        ''')
        self.assertEqual(self.e('#r.data.outfits'), 0)

    def test_a_new_character_gets_it_in_the_creation_transaction(self):
        self.rt.run('''
            app = { clothing = { equipped = { boots = boots, hats = hat },
                                 tints = { hats = { palette = 'metaped_tint_hat', tint0 = 7, tint1 = 8, tint2 = 9 } } } }
            q = WCOutfits.starterQuery('vorp:9', app)
            d = json.decode(q.values[3])
        ''')
        self.assertIn('INSERT INTO w_creators_outfits', self.e('q.query'))
        self.assertEqual(self.e('q.values[2]'), 'ملابس البداية')
        self.assertTrue(self.e('d.starter'))
        self.assertEqual(self.e('d.equipped.boots'), self.e('boots'))
        self.assertFalse(self.e('d.tints.boots'))
        self.assertEqual(self.e('d.tints.hats.tint1'), 8)
        self.assertIsNone(self.e('WCOutfits.starterQuery("vorp:9", { clothing = { equipped = {} } })'))


if __name__ == '__main__':
    unittest.main()
