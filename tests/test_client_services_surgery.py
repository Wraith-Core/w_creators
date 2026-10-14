"""Cosmetic surgery client (client/surgery/surgery.lua over WCServiceFlow): the server-granted open
path (w_creators:client:openSurgery), the client export OpenCosmeticSurgery (client/api.lua), the
editor options and context, commit, cancel, forced closes, death and resource stop (the character is
never left half-modified)."""
import unittest

from test_client_services_support import PLAYER_START, make_services, settle

CLINIC = 'valentine_surgery'


class SurgeryTestCase(unittest.TestCase):
    def setUp(self):
        self.rt = make_services()
        self.run = self.rt.run
        self.eval = self.rt.eval

    def open(self, data='surgeryData()', commit=None):
        self.run('CallbackResults = { ["w_creators:surgery:open"] = %s }' % data)
        if commit:
            self.run('CallbackResults["w_creators:surgery:commit"] = %s' % commit)
        self.run('R = table.pack(WCSurgery.open(%r))' % CLINIC)
        return self.eval('R[1]'), self.eval('R[2]')

    def at(self):
        return tuple(self.rt.py(self.eval('playerAt()')).values())

    def assert_left(self):
        self.assertIsNone(self.eval('WCServiceFlow.current()'))
        self.assertFalse(self.eval('WCSurgery.busy()'))
        self.assertFalse(self.eval('WCEditor.isOpen()'))
        self.assertFalse(self.eval('WCPreviewEnv.active()'))
        self.assertEqual(self.at(), PLAYER_START)
        self.assertFalse(self.eval('Peds[MyPed].frozen == true'))
        self.assertEqual(self.eval('called("w_creators:scene:prepare")'), 0)

    def reshape(self):
        """A real procedure on the working appearance (a face morph)."""
        self.run('local s = WCEditor.session(); s.working.morph.noseWidth = 0.5; s.revision = s.revision + 1')


class OpenPathTests(SurgeryTestCase):
    def test_the_server_grant_event_requests_the_open_callback(self):
        self.run('CallbackResults = { ["w_creators:surgery:open"] = surgeryData() }')
        self.run('fireEvent("w_creators:client:openSurgery", nil, %r)' % CLINIC)
        settle(self.rt)
        self.assertEqual(self.eval('called("w_creators:surgery:open")'), 1)
        self.assertEqual(self.eval('callbacks("w_creators:surgery:open")[1][2]'), CLINIC)
        self.assertTrue(self.eval('WCSurgery.busy()'))
        self.assertEqual(self.eval('WCEditor.session().mode'), 'surgery')

    def test_the_grant_event_refused_by_the_server_shows_the_message(self):
        self.run('CallbackResults = { ["w_creators:surgery:open"] = fail("SURGERY_NOT_ALLOWED") }')
        self.run('fireEvent("w_creators:client:openSurgery", nil, %r)' % CLINIC)
        settle(self.rt)
        self.assertTrue(self.eval('noted(WCResult.messageKey("SURGERY_NOT_ALLOWED"))'))
        self.assert_left()

    def test_the_grant_event_refused_by_another_flow_tells_the_player(self):
        # w_medic saw the export succeed: the client refusal is the only feedback
        for lock in ('clothingAction', 'respawn'):
            self.run('Notes = {}; WCState.busy(%r, true)' % lock)
            self.run('fireEvent("w_creators:client:openSurgery", nil, %r)' % CLINIC)
            settle(self.rt)
            self.assertEqual(self.eval('called("w_creators:surgery:open")'), 0, lock)
            self.assertTrue(self.eval('noted(WCResult.messageKey("BUSY"))'), lock)
            self.run('WCState.busy(%r, false)' % lock)
        self.assert_left()

    def test_the_grant_event_while_the_seat_is_left_tells_the_player(self):
        self.run('WCServiceSeat.kind = function() return "barber" end')
        self.run('fireEvent("w_creators:client:openSurgery", nil, %r)' % CLINIC)
        settle(self.rt)
        self.assertEqual(self.eval('called("w_creators:surgery:open")'), 0)
        self.assertTrue(self.eval('noted(WCResult.messageKey("BUSY"))'))

    def test_the_client_export_refused_by_another_flow_tells_the_player(self):
        self.run('WCState.busy("clothingAction", true)')
        self.assertTrue(self.eval('Exported.OpenCosmeticSurgery(%r)' % CLINIC))
        settle(self.rt)
        self.assertEqual(self.eval('called("w_creators:surgery:open")'), 0)
        self.assertTrue(self.eval('noted(WCResult.messageKey("BUSY"))'))

    def test_a_dead_player_is_refused_silently(self):
        self.run('Peds[MyPed].dead = true')
        self.run('R = table.pack(WCSurgery.open(%r))' % CLINIC)
        self.assertFalse(self.eval('R[1]'))
        self.assertEqual(self.eval('R[2]'), 'BUSY')
        self.assertEqual(self.eval('#Notes'), 0)

    def test_the_client_export_opens_directly(self):
        self.run('CallbackResults = { ["w_creators:surgery:open"] = surgeryData() }')
        self.assertTrue(self.eval('Exported.OpenCosmeticSurgery(%r)' % CLINIC))
        settle(self.rt)
        self.assertEqual(self.eval('callbacks("w_creators:surgery:open")[1][2]'), CLINIC)
        self.assertTrue(self.eval('WCEditor.isOpen()'))

    def test_the_client_export_refuses_garbage(self):
        for bad in ('nil', '""', '{}', 'string.rep("x", 65)'):
            self.assertFalse(self.eval('Exported.OpenCosmeticSurgery(%s)' % bad))
        settle(self.rt)
        self.assertEqual(self.eval('called("w_creators:surgery:open")'), 0)

    def test_open_failure_leaves_nothing(self):
        ok, code = self.open('fail("TOO_FAR")')
        self.assertFalse(ok)
        self.assertEqual(code, 'TOO_FAR')
        self.assertTrue(self.eval('noted(WCResult.messageKey("TOO_FAR"))'))
        self.assertEqual(self.eval('called("w_creators:session:close")'), 0)
        self.assertEqual(self.eval('#RestoreCalls'), 0)
        self.assert_left()

    def test_a_malformed_open_answer_closes_its_session(self):
        ok, code = self.open('okResult({ token = "gtok" })')
        self.assertFalse(ok)
        self.assertEqual(code, 'INTERNAL_ERROR')
        self.assertEqual(self.eval('callbacks("w_creators:session:close")[1][2]'), 'gtok')
        self.assert_left()

    def test_editor_refusal_closes_the_session(self):
        self.run('WCEditor.open = function() return false, "INVALID_COMPONENT" end')
        ok, code = self.open()
        self.assertFalse(ok)
        self.assertEqual(code, 'INVALID_COMPONENT')
        self.assertEqual(self.eval('callbacks("w_creators:session:close")[1][2]'), 'gtok')
        self.assert_left()

    def test_blocked_while_another_service_runs(self):
        self.run('CallbackResults = { ["w_creators:barber:open"] = barberData() }')
        self.run('WCBarber.open("valentine_barber")')
        ok, code = self.open()
        self.assertFalse(ok)
        self.assertEqual(code, 'BUSY')
        self.assertEqual(self.eval('called("w_creators:surgery:open")'), 0)


class OptionsTests(SurgeryTestCase):
    def test_editor_options(self):
        ok, _ = self.open()
        self.assertTrue(ok)
        s = 'WCEditor.session()'
        self.assertEqual(self.eval(s + '.mode'), 'surgery')
        self.assertEqual(self.eval(s + '.opts.title'), 'عيادة التجميل')
        self.assertEqual(self.eval(s + '.opts.subtitle'), 'فالنتاين')
        self.assertEqual(self.eval(s + '.camera'), 'face')
        self.assertEqual(self.rt.py(self.eval(s + '.sections')),
                         {'face': True, 'body': True, 'eyes': True, 'skin': True})
        self.assertEqual(self.eval(s + '.context.price'), 500)
        self.assertTrue(self.eval(s + '.context.allow.face'))
        self.assertEqual(self.eval(s + '.context.location.id'), CLINIC)
        self.assertIsNone(self.eval(s + '.context.owned'))
        # the editor's surgery copy: "Confirm procedure" and the procedure cost
        payload = self.eval('WCEditor.payload(%s)' % s)
        self.assertEqual(payload.saveLabel, 'تأكيد العملية')

    def test_owned_clothing_reaches_the_context(self):
        self.open('surgeryData({ owned = { ["123"] = { category = "hats" } },'
                  ' allow = { face = true, clothing = true }, sections = { face = true, clothing = true } })')
        self.assertEqual(self.eval('WCEditor.session().context.owned["123"].category'), 'hats')
        self.assertTrue(self.eval('WCEditor.session().sections.clothing'))

    def test_the_procedure_cost_is_previewed(self):
        self.open()
        self.reshape()
        price = self.rt.py(self.eval('WCEditorTree.price(WCEditor.session())'))
        self.assertEqual(price['total'], 500)


class CommitCancelTests(SurgeryTestCase):
    def test_commit_success_updates_the_state(self):
        self.run('Committed = AppearanceSchema.default("male"); Committed.morph.noseWidth = 0.5')
        self.open(commit='okResult({ appearance = Committed, charged = 500, sections = { "face" } })')
        self.reshape()
        self.run('SR = save()')
        self.assertTrue(self.eval('SR.ok'))
        args = self.eval('callbacks("w_creators:surgery:commit")[1]')
        self.assertEqual(args[2], 'gtok')
        self.assertEqual(args[4].morph.noseWidth, 0.5)
        settle(self.rt)
        self.assertEqual(self.eval('WCState.appearance.morph.noseWidth'), 0.5)
        self.assertEqual(self.eval('lastRestore().morph.noseWidth'), 0.5)
        self.assertEqual(self.eval('called("w_creators:session:close")'), 0)
        self.assert_left()

    def test_an_uncertain_commit_retries_with_the_same_op_id(self):
        self.open(commit='fail("INTERNAL_ERROR")')
        self.reshape()
        self.run('save()')
        self.run('CallbackResults["w_creators:surgery:commit"] = okResult({ appearance = WCEditor.working() })')
        self.run('save()')
        first = self.eval('callbacks("w_creators:surgery:commit")[1][3]')
        second = self.eval('callbacks("w_creators:surgery:commit")[2][3]')
        self.assertEqual(first, second)
        settle(self.rt)
        self.assert_left()

    def test_a_refused_procedure_keeps_the_editor_and_the_saved_state(self):
        self.open(commit='fail("SURGERY_NOT_ALLOWED")')
        self.reshape()
        self.run('SR = save()')
        self.assertFalse(self.eval('SR.ok'))
        self.assertTrue(self.eval('WCEditor.isOpen()'))
        self.assertIsNone(self.eval('WCState.appearance.morph.noseWidth'))

    def test_cancel_restores_the_snapshot_and_closes_the_session(self):
        self.open()
        self.reshape()
        self.run('cancel()')
        settle(self.rt)
        self.assertIsNone(self.eval('lastRender().morph.noseWidth'))
        self.assertEqual(self.eval('callbacks("w_creators:session:close")[1][2]'), 'gtok')
        self.assertIsNone(self.eval('WCState.appearance.morph.noseWidth'))
        self.assert_left()

    def test_a_server_close_restores_the_snapshot(self):
        self.open()
        self.reshape()
        self.run('fireEvent("w_creators:client:sessionClosed", nil, "gtok", "character")')
        settle(self.rt)
        self.assertIsNone(self.eval('lastRender().morph.noseWidth'))
        self.assertEqual(self.eval('called("w_creators:session:close")'), 0)
        self.assert_left()

    def test_a_lost_session_on_commit_ends_the_visit(self):
        self.open(commit='fail("SESSION_EXPIRED")')
        self.reshape()
        self.run('save()')
        settle(self.rt)
        self.assertTrue(self.eval('noted(WCResult.messageKey("SESSION_EXPIRED"))'))
        self.assertIsNone(self.eval('lastRender().morph.noseWidth'))
        self.assertEqual(self.eval('called("w_creators:session:close")'), 0)
        self.assert_left()

    def test_death_restores_the_snapshot(self):
        self.open()
        self.reshape()
        self.run('Peds[MyPed].dead = true')
        settle(self.rt)
        self.assertIsNone(self.eval('lastRender().morph.noseWidth'))
        self.assertEqual(self.eval('called("w_creators:session:close")'), 1)
        self.assertIsNone(self.eval('WCServiceFlow.current()'))
        self.assertFalse(self.eval('WCEditor.isOpen()'))

    def test_resource_stop_undoes_the_visit_without_saving_the_procedure(self):
        # WCServiceFlow's stop never renders (an appearance render yields); the uncommitted
        # session is closed, so the server drops the procedure and the next start re-renders.
        self.open()
        self.reshape()
        self.run('RenderCalls = {}')
        self.run('stopResource()')
        self.assertFalse(self.eval('WCEditor.isOpen()'))
        self.assertFalse(self.eval('WCPreviewEnv.active()'))
        self.assertEqual(self.eval('#RenderCalls'), 0)
        self.assertEqual(self.eval('called("w_creators:session:close")'), 1)
        self.assertEqual(self.eval('called("w_creators:surgery:commit")'), 0)
        self.assertFalse(self.eval('Peds[MyPed].frozen == true'))



class ClinicSeatTests(SurgeryTestCase):
    def setUp(self):
        super().setUp()
        self.run('setPreview("valentine_surgery", 5.0, 6.0, 7.0, 90.0)')

    def test_a_clinic_seat_is_taken_and_left(self):
        ok, _ = self.open()
        self.assertTrue(ok)
        self.assertEqual(self.at(), (5.0, 6.0, 7.0))
        self.assertEqual(self.eval('WCServiceSeat.kind()'), 'surgery')
        self.run('cancel()')
        settle(self.rt)
        self.assert_left()
        self.assertIsNone(self.eval('WCServiceSeat.kind()'))


if __name__ == '__main__':
    unittest.main()
