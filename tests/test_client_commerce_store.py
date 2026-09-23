"""Clothing store client (client/clothing/store.lua over WCServiceFlow in client/services/locations.lua):
open failures, the fitting room, commit, cancel, forced closes, death, resource stop, opId retries."""
import unittest

from test_client_commerce_support import PLAYER_START, make_commerce, settle

LOC = 'valentine_clothing'


class StoreTestCase(unittest.TestCase):
    def setUp(self):
        self.rt = make_commerce()
        self.run = self.rt.run
        self.eval = self.rt.eval

    def open(self, data='storeData()', commit=None):
        self.run('CallbackResults = { ["w_creators:store:open"] = %s }' % data)
        if commit:
            self.run('CallbackResults["w_creators:store:commit"] = %s' % commit)
        self.run('R = table.pack(WCStore.open(%r))' % LOC)
        return self.eval('R[1]'), self.eval('R[2]')

    def at(self):
        return tuple(self.rt.py(self.eval('playerAt()')).values())

    def assert_left(self, released=True):
        """Nothing of the visit is left: flow, editor, environment, coords, bucket, freeze, focus."""
        self.assertIsNone(self.eval('WCServiceFlow.current()'))
        self.assertFalse(self.eval('WCEditor.isOpen()'))
        self.assertFalse(self.eval('WCPreviewEnv.active()'))
        self.assertEqual(self.at(), PLAYER_START)
        self.assertFalse(self.eval('Peds[MyPed].frozen == true'))
        if released:
            self.assertEqual(self.eval('called("w_creators:scene:release")'), 1)


class OpenTests(StoreTestCase):
    def test_open_failure_shows_the_error_and_leaves_nothing(self):
        ok, code = self.open('fail("TOO_FAR")')
        self.assertFalse(ok)
        self.assertEqual(code, 'TOO_FAR')
        self.assertTrue(self.eval('noted(WCResult.messageKey("TOO_FAR"))'))
        self.assertEqual(self.eval('called("w_creators:scene:prepare")'), 0)
        self.assertEqual(self.eval('called("w_creators:session:close")'), 0)
        self.assert_left(released=False)
        self.assertEqual(self.eval('#RestoreCalls'), 0)

    def test_a_lost_reply_is_an_internal_error(self):
        self.run('CallbackResults = { ["w_creators:store:open"] = function() return nil end }')
        self.run('R = table.pack(WCStore.open(%r))' % LOC)
        self.assertFalse(self.eval('R[1]'))
        self.assertEqual(self.eval('R[2]'), 'INTERNAL_ERROR')
        self.assertTrue(self.eval('noted(WCResult.messageKey("INTERNAL_ERROR"))'))
        self.assertIsNone(self.eval('WCServiceFlow.current()'))

    def test_isolation_refused_closes_the_session_and_never_moves_the_player(self):
        self.run('CallbackResults = { ["w_creators:store:open"] = storeData(),'
                 ' ["w_creators:scene:prepare"] = fail("SESSION_NOT_FOUND") }')
        self.run('R = table.pack(WCStore.open(%r))' % LOC)
        self.assertFalse(self.eval('R[1]'))
        self.assertEqual(self.eval('R[2]'), 'SESSION_NOT_FOUND')
        self.assertTrue(self.eval('noted(WCResult.messageKey("SESSION_NOT_FOUND"))'))
        self.assertEqual(self.eval('callbacks("w_creators:session:close")[1][2]'), 'stok')
        self.assertEqual(self.eval('count("SetEntityCoords")'), 0)
        self.assert_left(released=False)

    def test_editor_refusal_closes_the_session_and_leaves_the_fitting_room(self):
        self.run('WCEditor.open = function() return false, "INVALID_COMPONENT" end')
        ok, code = self.open()
        self.assertFalse(ok)
        self.assertEqual(code, 'INVALID_COMPONENT')
        self.assertTrue(self.eval('noted(WCResult.messageKey("INVALID_COMPONENT"))'))
        self.assertEqual(self.eval('called("w_creators:session:close")'), 1)
        self.assert_left()

    def test_a_malformed_open_answer_is_refused_and_its_session_closed(self):
        ok, code = self.open('okResult({ token = "stok" })')
        self.assertFalse(ok)
        self.assertEqual(code, 'INTERNAL_ERROR')
        self.assertEqual(self.eval('callbacks("w_creators:session:close")[1][2]'), 'stok')
        self.assert_left(released=False)

    def test_open_enters_the_fitting_room_and_the_editor(self):
        ok, code = self.open()
        self.assertTrue(ok)
        self.assertIsNone(code)
        self.assertEqual(self.eval('callbacks("w_creators:store:open")[1][2]'), LOC)
        self.assertEqual(self.eval('called("w_creators:scene:prepare")'), 1)
        self.assertEqual(self.at(), (10.0, 20.0, 30.0))
        self.assertEqual(self.eval('Peds[MyPed].heading'), 90.0)
        self.assertTrue(self.eval('WCPreviewEnv.active()'))
        self.assertTrue(self.eval('Peds[MyPed].frozen'))
        # isolation comes before the move; the fade is lifted before the editor shows
        self.assertLess(self.eval('indexOf("callback:w_creators:scene:prepare")'), self.eval('indexOf("SetEntityCoords")'))
        self.assertLess(self.eval('indexOf("SetEntityCoords")'), self.eval('indexOf("DoScreenFadeIn")'))
        s = 'WCEditor.session()'
        self.assertEqual(self.eval(s + '.mode'), 'store')
        self.assertEqual(self.eval(s + '.opts.title'), 'متجر الملابس')
        self.assertEqual(self.eval(s + '.opts.subtitle'), 'فالنتاين')
        self.assertTrue(self.eval(s + '.sections.clothing'))
        self.assertIsNone(self.eval(s + '.sections.states'))
        self.assertEqual(self.eval(s + '.context.prices.hats'), 5)
        self.assertEqual(self.eval(s + '.context.tintPrice'), 2.5)
        self.assertEqual(self.eval(s + '.context.storeProfile'), 'general')
        self.assertEqual(self.eval(s + '.context.location.id'), LOC)
        self.assertEqual(self.eval(s + '.camera'), 'fullBody')
        self.assertTrue(self.eval('WCStore.busy()'))

    def test_a_second_open_is_busy(self):
        self.open()
        self.run('R2 = table.pack(WCStore.open(%r))' % LOC)
        self.assertFalse(self.eval('R2[1]'))
        self.assertEqual(self.eval('R2[2]'), 'BUSY')
        self.assertEqual(self.eval('called("w_creators:store:open")'), 1)

    def test_dead_players_cannot_open(self):
        self.run('Peds[MyPed].dead = true')
        ok, code = self.open()
        self.assertFalse(ok)
        self.assertEqual(code, 'BUSY')
        self.assertEqual(self.eval('called("w_creators:store:open")'), 0)

    def test_invalid_ids_are_refused_locally(self):
        for bad in ('nil', '""', '5', '{}', 'string.rep("a", 65)'):
            self.run('R = table.pack(WCStore.open(%s))' % bad)
            self.assertEqual(self.eval('R[2]'), 'INVALID_PAYLOAD', bad)
        self.assertEqual(self.eval('called("w_creators:store:open")'), 0)

    def test_no_preview_stand_keeps_the_player_in_place(self):
        ok, _ = self.open('storeData({ preview = false })')
        self.assertTrue(ok)
        self.assertEqual(self.eval('called("w_creators:scene:prepare")'), 0)
        self.assertEqual(self.at(), PLAYER_START)
        self.run('cancel()')
        self.assert_left(released=False)

    def test_server_open_event_opens_the_store(self):
        self.run('CallbackResults = { ["w_creators:store:open"] = storeData() }')
        self.run('fireEvent("w_creators:client:openStore", nil, "saintdenis_clothing")')
        self.run('tick(0)')
        self.assertEqual(self.eval('callbacks("w_creators:store:open")[1][2]'), 'saintdenis_clothing')
        self.assertEqual(self.eval('WCEditor.session().opts.subtitle'), 'سانت دينيس')


class CommitTests(StoreTestCase):
    COMMIT = ('function(_, token, opId, app) Committed = { token = token, opId = opId, app = app }'
              ' local out = WCUtil.copy(app) out.body.height = 1.07'
              ' return okResult({ appearance = out, charged = 5, purchases = {} }) end')

    def test_commit_success_updates_the_state_and_leaves_the_fitting_room(self):
        self.open(commit=self.COMMIT)
        self.run('makeDirty(1.05)')
        self.run('A = save()')
        self.assertTrue(self.eval('A.ok'))
        self.assertTrue(self.eval('A.closed'))
        self.assertEqual(self.eval('Committed.token'), 'stok')
        self.assertEqual(self.eval('Committed.app.body.height'), 1.05)
        self.assertEqual(self.eval('type(Committed.opId)'), 'string')
        settle(self.rt)
        self.assertEqual(self.eval('WCState.appearance.body.height'), 1.07)
        self.assertEqual(self.eval('#RestoreCalls'), 1)
        self.assertEqual(self.eval('RestoreCalls[1].body.height'), 1.07)
        self.assertEqual(self.eval('called("w_creators:session:close")'), 0)
        self.assert_left()
        # the committed look is rendered before the player leaves the fitting room
        self.assertLess(self.eval('indexOf("RestorePlayer")'), self.eval('indexOf("callback:w_creators:scene:release")'))

    def test_a_refused_commit_keeps_the_editor_open(self):
        self.open(commit='function() return fail("INSUFFICIENT_FUNDS") end')
        self.run('makeDirty()')
        self.run('A = save()')
        self.assertFalse(self.eval('A.ok'))
        self.assertEqual(self.eval('A.code'), 'INSUFFICIENT_FUNDS')
        settle(self.rt)
        self.assertTrue(self.eval('WCEditor.isOpen()'))
        self.assertTrue(self.eval('WCPreviewEnv.active()'))
        self.assertIsNotNone(self.eval('WCServiceFlow.current()'))
        self.assertEqual(self.eval('WCState.appearance.body.height'), 1.0)

    def test_the_opid_is_reused_when_the_save_is_retried_after_a_lost_reply(self):
        self.open(commit='function(_, token, opId) OpIds[#OpIds + 1] = opId return Answers[#OpIds] end')
        self.run('OpIds = {}; Answers = { fail("INTERNAL_ERROR"), fail("BUSY"), okResult({ appearance = WCEditor.working() }) }')
        self.run('makeDirty()')
        self.run('save(); save(); A = save()')
        self.assertTrue(self.eval('A.ok'))
        self.assertEqual(self.eval('#OpIds'), 3)
        self.assertEqual(self.eval('OpIds[1]'), self.eval('OpIds[2]'))
        self.assertEqual(self.eval('OpIds[2]'), self.eval('OpIds[3]'))

    def test_a_definite_refusal_or_a_new_look_gets_a_new_opid(self):
        self.open(commit='function(_, token, opId) OpIds[#OpIds + 1] = opId return Answers[#OpIds] end')
        self.run('OpIds = {}; Answers = { fail("INTERNAL_ERROR"), fail("INSUFFICIENT_FUNDS"), fail("INTERNAL_ERROR"), fail("INTERNAL_ERROR") }')
        self.run('makeDirty(1.05); save(); save()')
        self.assertEqual(self.eval('OpIds[1]'), self.eval('OpIds[2]'))
        self.run('save()')  # after a definite answer: a new attempt
        self.assertNotEqual(self.eval('OpIds[2]'), self.eval('OpIds[3]'))
        self.run('makeDirty(1.06); save()')  # a different look: a new attempt
        self.assertNotEqual(self.eval('OpIds[3]'), self.eval('OpIds[4]'))

    def test_a_commit_without_an_editor_opid_reuses_its_own_on_retry(self):
        self.open(commit='function(_, token, opId) OpIds[#OpIds + 1] = opId return fail("INTERNAL_ERROR") end')
        self.run('OpIds = {}')
        self.run('local s = WCEditor.session(); local app = WCEditor.working()'
                 ' s.opts.onCommit(app, {}); s.opts.onCommit(app, {})')
        self.assertEqual(self.eval('OpIds[1]'), self.eval('OpIds[2]'))
        self.run('local s = WCEditor.session(); local app = WCEditor.working(); app.body.height = 1.09'
                 ' s.opts.onCommit(app, {})')
        self.assertNotEqual(self.eval('OpIds[2]'), self.eval('OpIds[3]'))

    def test_a_lost_session_on_commit_closes_the_editor(self):
        self.open(commit='function() return fail("SESSION_NOT_FOUND") end')
        self.run('makeDirty()')
        self.run('A = save()')
        self.assertFalse(self.eval('A.ok'))
        settle(self.rt)
        self.assertTrue(self.eval('noted(WCResult.messageKey("SESSION_NOT_FOUND"))'))
        self.assertEqual(self.eval('called("w_creators:session:close")'), 0)
        self.assert_left()


class CancelTests(StoreTestCase):
    def test_cancel_restores_the_snapshot_and_closes_the_session(self):
        self.open()
        self.run('makeDirty(1.08)')
        self.run('clearLog(); RenderCalls = {}')
        self.run('A = cancel()')
        self.assertTrue(self.eval('A.ok'))
        self.assertEqual(self.eval('#RenderCalls'), 1)
        self.assertEqual(self.eval('RenderCalls[1].body.height'), 1.0)
        self.assertEqual(self.eval('callbacks("w_creators:session:close")[1][2]'), 'stok')
        self.assertEqual(self.eval('WCState.appearance.body.height'), 1.0)
        self.assertLess(self.eval('indexOf("RestoreCharacter")'), self.eval('indexOf("callback:w_creators:session:close")'))
        self.assert_left()
        self.assertTrue(self.eval('indexOf("TriggerEvent:hud:client:showui") ~= nil'))

    def test_death_cancels_through_the_editor(self):
        self.open()
        self.run('makeDirty(1.08); RenderCalls = {}')
        self.run('Peds[MyPed].dead = true')
        settle(self.rt)
        self.assertEqual(self.eval('RenderCalls[1].body.height'), 1.0)
        self.assertEqual(self.eval('called("w_creators:session:close")'), 1)
        self.assert_left()

    def test_an_editor_closed_elsewhere_ends_the_visit(self):
        self.open()
        self.run('WCEditor.close()')
        settle(self.rt)
        self.assertEqual(self.eval('#RestoreCalls'), 1)
        self.assertEqual(self.eval('called("w_creators:session:close")'), 1)
        self.assert_left()

    def test_a_forced_server_close_restores_and_leaves(self):
        self.open()
        self.run('makeDirty(1.08); RenderCalls = {}')
        self.run('fireEvent("w_creators:client:sessionClosed", nil, "other", "expired")')
        self.assertTrue(self.eval('WCEditor.isOpen()'))  # another token is ignored
        self.run('fireEvent("w_creators:client:sessionClosed", nil, "stok", "expired")')
        self.assertEqual(self.eval('RenderCalls[1].body.height'), 1.0)
        self.assertTrue(self.eval('noted(WCResult.messageKey("SESSION_EXPIRED"))'))
        self.assertEqual(self.eval('called("w_creators:session:close")'), 0)  # the server closed it
        self.assert_left()

    def test_a_forced_close_during_a_commit_waits_for_the_editor(self):
        self.open()
        self.run('WCEditor.session().busy = true')
        self.run('fireEvent("w_creators:client:sessionClosed", nil, "stok", "character")')
        self.assertTrue(self.eval('WCEditor.isOpen()'))
        self.run('WCEditor.session().busy = false')
        settle(self.rt)
        self.assert_left()

    def test_a_forced_close_while_opening_stops_the_open(self):
        self.run('CallbackResults = { ["w_creators:store:open"] = storeData(),'
                 ' ["w_creators:scene:prepare"] = function()'
                 ' fireEvent("w_creators:client:sessionClosed", nil, "stok", "expired") return okResult({}) end }')
        self.run('R = table.pack(WCStore.open(%r))' % LOC)
        self.assertFalse(self.eval('R[1]'))
        self.assertEqual(self.eval('R[2]'), 'SESSION_NOT_FOUND')
        self.assertFalse(self.eval('WCEditor.isOpen()'))
        self.assert_left()


class ServiceLockTests(StoreTestCase):
    def test_the_service_lock_is_held_from_the_open_until_back_on_the_shop_floor(self):
        self.run('Seen = {}')
        self.run('CallbackResults = { ["w_creators:store:open"] = function()'
                 ' Seen.open = WCState.busy("service") return storeData() end,'
                 ' ["w_creators:scene:prepare"] = function() Seen.prepare = WCState.busy("service") return okResult({}) end,'
                 ' ["w_creators:scene:release"] = function() Seen.release = WCState.busy("service");'
                 ' Seen.env = WCPreviewEnv.active(); Seen.frozen = Peds[MyPed].frozen == true;'
                 ' Seen.at = playerAt() return okResult({}) end }')
        self.run('WCStore.open(%r)' % LOC)
        self.assertTrue(self.eval('Seen.open'))
        self.assertTrue(self.eval('Seen.prepare'))
        self.assertTrue(self.eval('WCState.busy("service")'))
        self.run('cancel()')
        settle(self.rt)
        # the leave phase: still locked, still in the preview environment, already moved back
        self.assertTrue(self.eval('Seen.release'))
        self.assertTrue(self.eval('Seen.env'))
        self.assertTrue(self.eval('Seen.frozen'))
        self.assertEqual(tuple(self.rt.py(self.eval('Seen.at')).values()), PLAYER_START)
        self.assertFalse(self.eval('WCState.busy("service")'))
        self.assert_left()

    def test_an_open_failure_releases_the_lock(self):
        self.open('fail("TOO_FAR")')
        self.assertFalse(self.eval('WCState.busy("service")'))
        self.open('okResult({ token = "stok" })')
        self.assertFalse(self.eval('WCState.busy("service")'))
        self.run('CallbackResults = { ["w_creators:store:open"] = function() error("boom") end }')
        self.run('WCServiceFlow.run({ kind = "store", mode = "store", open = "w_creators:store:open",'
                 ' commit = "w_creators:store:commit", options = function() error("boom") end })')
        self.assertFalse(self.eval('WCState.busy("service")'))

    def test_a_service_lock_held_elsewhere_refuses_and_is_left_alone(self):
        self.run('WCState.busy("service", true)')
        ok, code = self.open()
        self.assertFalse(ok)
        self.assertEqual(code, 'BUSY')
        self.assertEqual(self.eval('called("w_creators:store:open")'), 0)
        self.assertTrue(self.eval('WCState.busy("service")'))


class ResourceStopTests(StoreTestCase):
    def test_resource_stop_mid_store_restores_coords_and_releases_the_bucket(self):
        self.open()
        self.run('makeDirty(1.08); RenderCalls = {}')
        self.run('fireEvent("onResourceStop", nil, "w_creators")')
        self.assertEqual(self.at(), PLAYER_START)
        self.assertEqual(self.eval('called("w_creators:scene:release")'), 1)
        self.assertEqual(self.eval('callbacks("w_creators:session:close")[1][2]'), 'stok')
        self.assertIsNone(self.eval('WCServiceFlow.current()'))
        self.assertFalse(self.eval('WCEditor.isOpen()'))
        self.assertFalse(self.eval('WCPreviewEnv.active()'))
        self.assertFalse(self.eval('Peds[MyPed].frozen'))
        self.assertFalse(self.eval('WCState.busy("service")'))
        # no appearance render: it would yield and stop half-way on the stock metaped preset
        self.assertEqual(self.eval('#RenderCalls'), 0)
        self.assertEqual(self.eval('#RestoreCalls'), 0)
        # nothing waited for an answer: the calls were sent with a response function
        self.assertEqual(self.eval('type(callbacks("w_creators:scene:release")[1][1])'), 'function')

    def test_resource_stop_never_yields_and_always_removes_the_locations(self):
        self.open()
        self.run('makeDirty(1.08); RenderCalls = {}')
        self.assertGreater(self.eval('#liveWalkups()'), 0)
        self.run('WaitCalls = 0; RealWait = Wait; Wait = function() WaitCalls = WaitCalls + 1;'
                 ' error("yield in onResourceStop") end; Citizen.Wait = Wait')
        try:
            self.run('CreateThread(function() fireEvent("onResourceStop", nil, "w_creators") end)')
            self.assertEqual(self.eval('WaitCalls'), 0)
        finally:
            self.run('Wait = RealWait; Citizen.Wait = RealWait')
        self.assertEqual(self.eval('#liveWalkups()'), 0)
        self.assertEqual(self.eval('#WCServicePoints.points()'), 0)
        self.assertEqual(self.at(), PLAYER_START)
        self.assertFalse(self.eval('Peds[MyPed].frozen'))
        self.assertIsNone(self.eval('WCServiceFlow.current()'))
        self.assertEqual(self.eval('#RenderCalls'), 0)

    def test_resource_stop_while_leaving_never_yields(self):
        self.run('CallbackResults = { ["w_creators:store:open"] = storeData() }')
        self.run('CallbackResults["w_creators:scene:release"] = function()'
                 ' WaitCalls = 0; RealWait = Wait; Wait = function() WaitCalls = WaitCalls + 1;'
                 ' error("yield in onResourceStop") end; Citizen.Wait = Wait;'
                 ' fireEvent("onResourceStop", nil, "w_creators");'
                 ' Wait = RealWait; Citizen.Wait = RealWait; return okResult({}) end')
        self.run('WCStore.open(%r)' % LOC)
        self.run('cancel()')
        settle(self.rt)
        self.assertEqual(self.eval('WaitCalls'), 0)
        self.assertEqual(self.eval('#liveWalkups()'), 0)
        self.assert_left()

    def test_resource_stop_after_the_commit_does_not_close_the_session(self):
        self.open(commit='function(_, t, o, app) return okResult({ appearance = app }) end')
        self.run('makeDirty(); save()')
        self.run('fireEvent("onResourceStop", nil, "w_creators")')
        self.assertEqual(self.eval('called("w_creators:session:close")'), 0)
        self.assertEqual(self.at(), PLAYER_START)
        self.assertEqual(self.eval('called("w_creators:scene:release")'), 1)

    def test_another_resource_stopping_changes_nothing(self):
        self.open()
        self.run('fireEvent("onResourceStop", nil, "other")')
        self.assertTrue(self.eval('WCEditor.isOpen()'))
        self.assertEqual(self.at(), (10.0, 20.0, 30.0))


if __name__ == '__main__':
    unittest.main()
