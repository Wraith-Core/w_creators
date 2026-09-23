"""Wardrobe client (client/wardrobe/wardrobe.lua): open in place, outfit operations with the session
token, clothing states as preview only, commit, cancel, remote opens, the kept export."""
import unittest

from test_client_commerce_support import PLAYER_START, make_commerce, settle

LOC = 'valentine_wardrobe'


class WardrobeTestCase(unittest.TestCase):
    def setUp(self):
        self.rt = make_commerce()
        self.run = self.rt.run
        self.eval = self.rt.eval

    def open(self, data='wardrobeData()', loc=repr(LOC)):
        self.run('CallbackResults = { ["w_creators:wardrobe:open"] = %s }' % data)
        self.run('R = table.pack(WCWardrobe.open(%s))' % loc)
        return self.eval('R[1]'), self.eval('R[2]')

    def at(self):
        return tuple(self.rt.py(self.eval('playerAt()')).values())

    def args(self, name, nth=1):
        a = self.eval('callbacks(%r)[%d]' % (name, nth))
        return [a[i] for i in range(1, a['n'] + 1)]


class OpenTests(WardrobeTestCase):
    def test_open_stays_in_place_frozen(self):
        ok, _ = self.open()
        self.assertTrue(ok)
        self.assertEqual(self.args('w_creators:wardrobe:open')[1], LOC)
        self.assertEqual(self.eval('called("w_creators:scene:prepare")'), 0)
        self.assertEqual(self.eval('count("SetEntityCoords")'), 0)
        self.assertEqual(self.at(), PLAYER_START)
        self.assertTrue(self.eval('WCPreviewEnv.active()'))
        self.assertTrue(self.eval('Peds[MyPed].frozen'))
        s = 'WCEditor.session()'
        self.assertEqual(self.eval(s + '.mode'), 'wardrobe')
        self.assertTrue(self.eval(s + '.sections.clothing'))
        self.assertTrue(self.eval(s + '.sections.states'))
        self.assertEqual(self.eval(s + '.context.outfits[1].name'), 'Work')
        self.assertEqual(self.eval(s + '.context.maxOutfits'), 10)
        self.assertTrue(self.eval(s + '.context.outfitsEnabled'))
        self.assertEqual(self.eval(s + '.opts.title'), 'الخزانة')
        self.assertTrue(self.eval('WCWardrobe.busy()'))
        self.assertFalse(self.eval('WCStore.busy()'))

    def test_open_failure_shows_the_error(self):
        ok, code = self.open('fail("WARDROBE_DISABLED")')
        self.assertFalse(ok)
        self.assertEqual(code, 'WARDROBE_DISABLED')
        self.assertTrue(self.eval('noted(WCResult.messageKey("WARDROBE_DISABLED"))'))
        self.assertFalse(self.eval('WCPreviewEnv.active()'))
        self.assertIsNone(self.eval('WCServiceFlow.current()'))

    def test_remote_open_sends_nil(self):
        ok, _ = self.open('wardrobeData({ remote = true })', loc='nil')
        self.assertTrue(ok)
        self.assertEqual(self.eval('callbacks("w_creators:wardrobe:open")[1].n'), 2)
        self.assertIsNone(self.eval('callbacks("w_creators:wardrobe:open")[1][2]'))
        self.assertTrue(self.eval('WCEditor.session().context.remote'))

    def test_the_export_and_the_server_event_open_the_wardrobe(self):
        self.assertIsNotNone(self.eval('Exported.OpenWardrobe'))
        self.run('CallbackResults = { ["w_creators:wardrobe:open"] = wardrobeData() }')
        self.run('Exported.OpenWardrobe()')
        self.run('tick(0)')
        self.assertEqual(self.eval('called("w_creators:wardrobe:open")'), 1)
        self.assertTrue(self.eval('WCEditor.isOpen()'))
        self.run('cancel()')
        self.run('fireEvent("w_creators:client:openWardrobe", nil, "rhodes_wardrobe")')
        self.run('tick(0)')
        self.assertEqual(self.args('w_creators:wardrobe:open', 2)[1], 'rhodes_wardrobe')

    def test_a_store_visit_blocks_the_wardrobe(self):
        self.run('CallbackResults = { ["w_creators:store:open"] = storeData() }')
        self.run('WCStore.open("valentine_clothing")')
        ok, code = self.open()
        self.assertFalse(ok)
        self.assertEqual(code, 'BUSY')
        self.assertEqual(self.eval('called("w_creators:wardrobe:open")'), 0)


class OutfitTests(WardrobeTestCase):
    def setUp(self):
        super().setUp()
        self.open()

    def outfit(self, op, oid='nil', value='nil'):
        self.run('O = WCEditor.session().opts.onOutfit(%r, %s, %s)' % (op, oid, value))

    def test_save_passes_the_token_and_the_working_clothes(self):
        self.run('CallbackResults["w_creators:outfits:save"] = okResult({ outfit = { id = 6 },'
                 ' outfits = { { id = 5, name = "Work" }, { id = 6, name = "Sunday" } } })')
        self.run('CLOTHES = { name = "Sunday", equipped = { hats = 123 }, states = { hat = "off" } }')
        self.outfit('save', value='CLOTHES')
        self.assertTrue(self.eval('O.ok'))
        a = self.args('w_creators:outfits:save')
        self.assertEqual(a[1:3], ['wtok', 'Sunday'])
        self.assertEqual(self.eval('callbacks("w_creators:outfits:save")[1][4].hats'), 123)
        self.assertEqual(self.eval('callbacks("w_creators:outfits:save")[1][5].hat'), 'off')
        self.assertEqual(self.eval('#WCEditor.session().context.outfits'), 2)

    def test_update_rename_delete_pass_the_token_and_the_id(self):
        self.run('CallbackResults["w_creators:outfits:update"] = okResult({ outfits = {} })')
        self.run('CallbackResults["w_creators:outfits:rename"] = okResult({ outfits = {} })')
        self.run('CallbackResults["w_creators:outfits:delete"] = okResult({ outfits = {} })')
        self.run('local s = WCEditor.session(); s.working.clothing.equipped = { boots = 77 }')
        self.outfit('update', '5', '{ equipped = WCEditor.working().clothing.equipped, states = {} }')
        self.assertEqual(self.args('w_creators:outfits:update')[1:3], ['wtok', 5])
        self.assertEqual(self.eval('callbacks("w_creators:outfits:update")[1][4].boots'), 77)
        self.outfit('rename', '5', '"Travel"')
        self.assertEqual(self.args('w_creators:outfits:rename')[1:4], ['wtok', 5, 'Travel'])
        self.outfit('delete', '5')
        self.assertEqual(self.args('w_creators:outfits:delete')[1:3], ['wtok', 5])
        self.assertEqual(self.eval('#WCEditor.session().context.outfits'), 0)

    def test_update_without_clothes_uses_the_working_appearance(self):
        self.run('CallbackResults["w_creators:outfits:update"] = okResult({ outfits = {} })')
        self.run('local s = WCEditor.session(); s.working.clothing.equipped = { boots = 88 }')
        self.outfit('update', '5')
        self.assertEqual(self.eval('callbacks("w_creators:outfits:update")[1][4].boots'), 88)

    def test_a_refusal_is_returned_and_keeps_the_list(self):
        self.run('CallbackResults["w_creators:outfits:rename"] = fail("INVALID_OUTFIT_NAME")')
        self.outfit('rename', '5', '"x"')
        self.assertFalse(self.eval('O.ok'))
        self.assertEqual(self.eval('O.code'), 'INVALID_OUTFIT_NAME')
        self.assertEqual(self.eval('#WCEditor.session().context.outfits'), 1)

    def test_equip_is_applied_locally(self):
        self.outfit('equip', '5')
        self.assertIsNone(self.eval('O'))
        self.assertEqual(self.eval('called("w_creators:outfits:save") + called("w_creators:outfits:update")'), 0)

    def test_unknown_ops_and_bad_values_are_refused(self):
        self.outfit('wear', '5')
        self.assertEqual(self.eval('O.code'), 'INVALID_PAYLOAD')
        self.outfit('save', value='"no table"')
        self.assertEqual(self.eval('O.code'), 'INVALID_OUTFIT_NAME')
        self.outfit('rename', '5', '{}')
        self.assertEqual(self.eval('O.code'), 'INVALID_OUTFIT_NAME')

    def test_a_lost_reply_is_an_internal_error(self):
        self.run('CallbackResults["w_creators:outfits:delete"] = function() return nil end')
        self.outfit('delete', '5')
        self.assertEqual(self.eval('O.code'), 'INTERNAL_ERROR')

    def test_delete_through_the_editor_tree(self):
        self.run('CallbackResults["w_creators:outfits:delete"] = okResult({ outfits = {} })')
        self.run('local s = WCEditor.session(); A = WCEditor.action({ id = s.id, op = "invoke", control = "outfit.5.delete" })')
        self.assertTrue(self.eval('A.ok'))
        self.assertEqual(self.args('w_creators:outfits:delete')[1:3], ['wtok', 5])
        self.assertEqual(self.eval('#WCEditor.session().context.outfits'), 0)

    def test_states_only_change_the_preview(self):
        self.run('S1 = WCEditor.session().opts.onState("hat", "off")')
        self.assertIsNone(self.eval('S1'))
        self.run('S2 = WCEditor.session().opts.onState("hat", "sideways")')
        self.assertEqual(self.eval('S2.code'), 'STATE_NOT_SUPPORTED')
        self.assertEqual(self.eval('called("w_creators:clothing:setState")'), 0)


class CommitTests(WardrobeTestCase):
    def test_commit_success_updates_the_state_and_unfreezes(self):
        self.open()
        self.run('CallbackResults["w_creators:wardrobe:commit"] = function(_, token, opId, app)'
                 ' Committed = { token = token, opId = opId } return okResult({ appearance = app }) end')
        self.run('makeDirty(1.04); A = save()')
        self.assertTrue(self.eval('A.ok'))
        self.assertEqual(self.eval('Committed.token'), 'wtok')
        settle(self.rt)
        self.assertEqual(self.eval('WCState.appearance.body.height'), 1.04)
        self.assertEqual(self.eval('RestoreCalls[1].body.height'), 1.04)
        self.assertFalse(self.eval('WCPreviewEnv.active()'))
        self.assertFalse(self.eval('Peds[MyPed].frozen'))
        self.assertIsNone(self.eval('WCServiceFlow.current()'))
        self.assertEqual(self.eval('called("w_creators:session:close")'), 0)
        self.assertEqual(self.eval('called("w_creators:scene:release")'), 0)
        self.assertEqual(self.at(), PLAYER_START)

    def test_cancel_closes_the_session(self):
        self.open()
        self.run('cancel()')
        self.assertEqual(self.args('w_creators:session:close')[1], 'wtok')
        self.assertFalse(self.eval('WCPreviewEnv.active()'))
        self.assertIsNone(self.eval('WCServiceFlow.current()'))

    def test_resource_stop_unfreezes_and_closes_the_session(self):
        self.open()
        self.run('fireEvent("onResourceStop", nil, "w_creators")')
        self.assertEqual(self.args('w_creators:session:close')[1], 'wtok')
        self.assertEqual(self.eval('called("w_creators:scene:release")'), 0)
        self.assertFalse(self.eval('Peds[MyPed].frozen'))
        self.assertFalse(self.eval('WCEditor.isOpen()'))


if __name__ == '__main__':
    unittest.main()
