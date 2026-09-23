"""Barber client (client/barber/barber.lua over WCServiceFlow): open failures, the editor options and
context (multiplier / visitCap), commit, cancel, forced closes, death, resource stop, the optional
chair seat (WCServiceSeat) and the server-opened path (w_creators:client:openBarber in client/api.lua)."""
import unittest

from test_client_services_support import PLAYER_START, make_services, settle

LOC = 'valentine_barber'


class BarberTestCase(unittest.TestCase):
    setup = ''

    def setUp(self):
        self.rt = make_services(self.setup)
        self.run = self.rt.run
        self.eval = self.rt.eval

    def open(self, data='barberData()', commit=None):
        self.run('CallbackResults = { ["w_creators:barber:open"] = %s }' % data)
        if commit:
            self.run('CallbackResults["w_creators:barber:commit"] = %s' % commit)
        self.run('R = table.pack(WCBarber.open(%r))' % LOC)
        return self.eval('R[1]'), self.eval('R[2]')

    def at(self):
        return tuple(self.rt.py(self.eval('playerAt()')).values())

    def assert_left(self):
        """Nothing of the visit is left: flow, editor, environment, coordinates, freeze, isolation."""
        self.assertIsNone(self.eval('WCServiceFlow.current()'))
        self.assertFalse(self.eval('WCBarber.busy()'))
        self.assertFalse(self.eval('WCEditor.isOpen()'))
        self.assertFalse(self.eval('WCPreviewEnv.active()'))
        self.assertFalse(self.eval('WCServiceSeat.active()'))
        self.assertEqual(self.at(), PLAYER_START)
        self.assertFalse(self.eval('Peds[MyPed].frozen == true'))
        self.assertEqual(self.eval('called("w_creators:scene:prepare")'), 0)


class OpenTests(BarberTestCase):
    def test_open_failure_shows_the_message_and_leaves_nothing(self):
        ok, code = self.open('fail("BARBER_DISABLED")')
        self.assertFalse(ok)
        self.assertEqual(code, 'BARBER_DISABLED')
        self.assertTrue(self.eval('noted(WCResult.messageKey("BARBER_DISABLED"))'))
        self.assertEqual(self.eval('called("w_creators:session:close")'), 0)
        self.assertEqual(self.eval('#RestoreCalls'), 0)
        self.assert_left()

    def test_a_lost_reply_is_an_internal_error(self):
        ok, code = self.open('function() return nil end')
        self.assertFalse(ok)
        self.assertEqual(code, 'INTERNAL_ERROR')
        self.assertTrue(self.eval('noted(WCResult.messageKey("INTERNAL_ERROR"))'))
        self.assert_left()

    def test_invalid_location_ids_never_reach_the_server(self):
        for bad in ('nil', '""', '42', 'string.rep("a", 65)'):
            self.run('R = table.pack(WCBarber.open(%s))' % bad)
            self.assertFalse(self.eval('R[1]'))
            self.assertEqual(self.eval('R[2]'), 'INVALID_PAYLOAD')
        self.assertEqual(self.eval('called("w_creators:barber:open")'), 0)

    def test_editor_refusal_closes_the_session_and_undoes_the_preview(self):
        self.run('WCEditor.open = function() return false, "INVALID_COMPONENT" end')
        ok, code = self.open()
        self.assertFalse(ok)
        self.assertEqual(code, 'INVALID_COMPONENT')
        self.assertTrue(self.eval('noted(WCResult.messageKey("INVALID_COMPONENT"))'))
        self.assertEqual(self.eval('callbacks("w_creators:session:close")[1][2]'), 'btok')
        self.assert_left()

    def test_a_throwing_editor_is_cleaned_up(self):
        self.run('WCEditor.open = function() error("boom") end')
        ok, code = self.open()
        self.assertFalse(ok)
        self.assertEqual(code, 'INTERNAL_ERROR')
        self.assertEqual(self.eval('called("w_creators:session:close")'), 1)
        self.assert_left()

    def test_editor_options_pass_the_open_data(self):
        ok, _ = self.open()
        self.assertTrue(ok)
        s = 'WCEditor.session()'
        self.assertEqual(self.eval(s + '.mode'), 'barber')
        self.assertEqual(self.eval(s + '.opts.title'), 'الحلاق')
        self.assertEqual(self.eval(s + '.opts.subtitle'), 'فالنتاين')
        self.assertEqual(self.eval(s + '.camera'), 'hair')
        self.assertEqual(self.rt.py(self.eval(s + '.sections')), {'hair': True, 'facialHair': True, 'eyebrows': True})
        ctx = s + '.context'
        self.assertEqual(self.eval(ctx + '.multiplier'), 1.5)
        self.assertEqual(self.eval(ctx + '.visitCap'), 15)
        self.assertEqual(self.eval(ctx + '.services.hair.price'), 15)
        self.assertEqual(self.eval(ctx + '.growth.hair.stage'), 1)
        self.assertEqual(self.eval(ctx + '.location.id'), LOC)
        self.assertEqual(self.eval(ctx + '.locationId'), LOC)
        self.assertTrue(self.eval('WCPreviewEnv.active()'))
        self.assertTrue(self.eval('Peds[MyPed].frozen == true'))
        self.assertTrue(self.eval('WCBarber.busy()'))
        self.assertEqual(self.at(), PLAYER_START)  # no seat configured: in place

    def test_price_preview_uses_the_context_cap(self):
        self.open()
        self.run('local s = WCEditor.session(); s.working.hair.style = 0; s.working.hair.facial = 0;'
                 ' s.revision = s.revision + 1')
        price = self.rt.py(self.eval('WCEditorTree.price(WCEditor.session())'))
        self.assertEqual(price['total'], 15)

    def test_a_second_open_is_busy(self):
        self.open()
        self.run('R2 = table.pack(WCBarber.open(%r))' % LOC)
        self.assertFalse(self.eval('R2[1]'))
        self.assertEqual(self.eval('R2[2]'), 'BUSY')
        self.assertEqual(self.eval('called("w_creators:barber:open")'), 1)

    def test_blocked_while_dead(self):
        self.run('Peds[MyPed].dead = true')
        ok, code = self.open()
        self.assertFalse(ok)
        self.assertEqual(code, 'BUSY')
        self.assertEqual(self.eval('called("w_creators:barber:open")'), 0)


class CommitCancelTests(BarberTestCase):
    def test_commit_success_updates_the_state_and_renders_the_result(self):
        self.run('Committed = AppearanceSchema.default("male"); Committed.hair.style = 0')
        self.open(commit='okResult({ appearance = Committed, charged = 15, sections = { "hair" } })')
        self.run('makeDirty(1.02)')
        self.run('SR = save()')
        self.assertTrue(self.eval('SR.ok'))
        args = self.eval('callbacks("w_creators:barber:commit")[1]')
        self.assertEqual(args[2], 'btok')
        self.assertIsInstance(args[3], str)
        settle(self.rt)
        self.assertEqual(self.eval('WCState.appearance.hair.style'), 0)
        self.assertEqual(self.eval('lastRestore().hair.style'), 0)
        self.assertEqual(self.eval('called("w_creators:session:close")'), 0)
        self.assert_left()

    def test_a_refused_commit_keeps_the_editor_open(self):
        self.open(commit='fail("INSUFFICIENT_FUNDS")')
        self.run('makeDirty(1.02)')
        self.run('SR = save()')
        self.assertFalse(self.eval('SR.ok'))
        self.assertEqual(self.eval('SR.code'), 'INSUFFICIENT_FUNDS')
        self.assertTrue(self.eval('WCEditor.isOpen()'))
        self.assertIsNone(self.eval('WCState.appearance.body.height ~= 1.0 and WCState.appearance.body.height or nil'))
        self.run('cancel()')
        settle(self.rt)
        self.assertEqual(self.eval('called("w_creators:session:close")'), 1)
        self.assert_left()

    def test_cancel_restores_the_snapshot_and_closes_the_session(self):
        self.open()
        self.run('makeDirty(1.07)')
        self.run('cancel()')
        settle(self.rt)
        self.assertEqual(self.eval('lastRender().body.height'), 1.0)
        self.assertEqual(self.eval('callbacks("w_creators:session:close")[1][2]'), 'btok')
        self.assertEqual(self.eval('called("w_creators:barber:commit")'), 0)
        self.assert_left()

    def test_a_forced_server_close_restores_and_does_not_close_again(self):
        self.open()
        self.run('makeDirty(1.07)')
        self.run('fireEvent("w_creators:client:sessionClosed", nil, "btok", "expired")')
        settle(self.rt)
        self.assertTrue(self.eval('noted(WCResult.messageKey("SESSION_EXPIRED"))'))
        self.assertEqual(self.eval('lastRender().body.height'), 1.0)
        self.assertEqual(self.eval('called("w_creators:session:close")'), 0)
        self.assert_left()

    def test_a_close_for_another_token_is_ignored(self):
        self.open()
        self.run('fireEvent("w_creators:client:sessionClosed", nil, "other", "expired")')
        settle(self.rt)
        self.assertTrue(self.eval('WCEditor.isOpen()'))

    def test_death_cancels_the_visit(self):
        self.open()
        self.run('makeDirty(1.07)')
        self.run('Peds[MyPed].dead = true')
        settle(self.rt)
        self.assertEqual(self.eval('lastRender().body.height'), 1.0)
        self.assertEqual(self.eval('called("w_creators:session:close")'), 1)
        self.assertIsNone(self.eval('WCServiceFlow.current()'))
        self.assertFalse(self.eval('WCEditor.isOpen()'))
        self.assertFalse(self.eval('WCPreviewEnv.active()'))

    def test_resource_stop_closes_everything(self):
        self.open()
        self.run('makeDirty(1.07); RenderCalls = {}')
        self.run('stopResource()')
        self.assertFalse(self.eval('WCEditor.isOpen()'))
        self.assertFalse(self.eval('WCPreviewEnv.active()'))
        self.assertIsNone(self.eval('WCServiceFlow.current()'))
        self.assertEqual(self.eval('called("w_creators:session:close")'), 1)
        self.assertEqual(self.eval('called("w_creators:barber:commit")'), 0)
        # no render on stop (it would yield): the server drops the uncommitted session
        self.assertEqual(self.eval('#RenderCalls'), 0)
        self.assertFalse(self.eval('Peds[MyPed].frozen == true'))


class SeatTests(BarberTestCase):
    setup = 'setPreview("valentine_barber", 11.0, 22.0, 33.0, 180.0)'

    def test_the_seat_is_taken_and_left_on_cancel(self):
        ok, _ = self.open()
        self.assertTrue(ok)
        self.assertEqual(self.at(), (11.0, 22.0, 33.0))
        self.assertEqual(self.eval('Peds[MyPed].heading'), 180.0)
        self.assertTrue(self.eval('WCServiceSeat.active()'))
        self.assertEqual(self.eval('count("DoScreenFadeOut")'), 1)
        self.run('cancel()')
        settle(self.rt)
        self.assert_left()
        self.assertEqual(self.eval('count("DoScreenFadeIn") >= 2'), True)

    def test_the_seat_is_left_after_a_commit(self):
        self.open(commit='okResult({ appearance = AppearanceSchema.default("male"), charged = 0, sections = {} })')
        self.run('makeDirty(1.02)')
        self.run('save()')
        settle(self.rt)
        self.assert_left()

    def test_the_seat_is_left_when_the_editor_refuses(self):
        self.run('WCEditor.open = function() return false, "BUSY" end')
        ok, _ = self.open()
        self.assertFalse(ok)
        settle(self.rt)
        self.assert_left()

    def test_resource_stop_puts_the_player_back_at_once(self):
        self.open()
        self.run('stopResource()')
        self.assertEqual(self.at(), PLAYER_START)
        self.assertFalse(self.eval('WCServiceSeat.active()'))
        self.assertFalse(self.eval('Peds[MyPed].frozen == true'))

    def test_no_service_opens_while_the_player_is_put_back(self):
        self.open()
        self.run('CollisionReady = false; HasCollisionLoadedAroundEntity = function() return CollisionReady end')
        self.run('cancel()')
        self.run('tick(200)')
        self.assertIsNone(self.eval('WCServiceFlow.current()'))
        self.assertTrue(self.eval('WCServiceSeat.active()'))
        self.assertTrue(self.eval('WCBarber.busy()'))
        self.assertFalse(self.eval('WCSurgery.busy()'))
        self.assertEqual(self.eval('WCServiceFlow.blocked()'), 'session')
        self.run('CollisionReady = true')
        settle(self.rt)
        self.assertIsNone(self.eval('WCServiceFlow.blocked()'))
        self.assert_left()

    def test_resource_stop_while_the_player_is_put_back(self):
        self.open()
        self.run('CollisionReady = false; HasCollisionLoadedAroundEntity = function() return CollisionReady end')
        self.run('cancel()')
        self.run('tick(200)')
        self.run('Peds[MyPed].coords = vector3(11.0, 22.0, 33.0)')
        self.run('stopResource()')
        self.assertEqual(self.at(), PLAYER_START)
        self.assertFalse(self.eval('WCServiceSeat.active()'))

    def test_a_dead_player_is_not_moved_back(self):
        self.open()
        self.run('Peds[MyPed].dead = true')
        settle(self.rt)
        self.assertEqual(self.at(), (11.0, 22.0, 33.0))
        self.assertFalse(self.eval('WCServiceSeat.active()'))
        self.assertIsNone(self.eval('WCServiceFlow.current()'))


class ServerOpenedTests(BarberTestCase):
    def test_open_barber_event_requests_the_open_callback(self):
        self.run('CallbackResults = { ["w_creators:barber:open"] = barberData() }')
        self.run('fireEvent("w_creators:client:openBarber", nil, %r)' % LOC)
        settle(self.rt)
        self.assertEqual(self.eval('callbacks("w_creators:barber:open")[1][2]'), LOC)
        self.assertTrue(self.eval('WCEditor.isOpen()'))

    def test_open_barber_event_refused_by_another_flow_tells_the_player(self):
        # the server export already answered ok: the client refusal is the only feedback
        self.run('WCState.busy("clothingAction", true)')
        self.run('fireEvent("w_creators:client:openBarber", nil, %r)' % LOC)
        settle(self.rt)
        self.assertEqual(self.eval('called("w_creators:barber:open")'), 0)
        self.assertTrue(self.eval('noted(WCResult.messageKey("BUSY"))'))
        self.assertFalse(self.eval('WCEditor.isOpen()'))
        self.run('WCState.busy("clothingAction", false)')
        self.assertIsNone(self.eval('WCServiceFlow.current()'))

    def test_a_dead_player_is_refused_silently(self):
        self.run('Peds[MyPed].dead = true')
        self.run('fireEvent("w_creators:client:openBarber", nil, %r)' % LOC)
        settle(self.rt)
        self.assertEqual(self.eval('called("w_creators:barber:open")'), 0)
        self.assertEqual(self.eval('#Notes'), 0)

    def test_open_barber_event_with_garbage_does_nothing(self):
        self.run('fireEvent("w_creators:client:openBarber", nil, { x = 1 })')
        settle(self.rt)
        self.assertEqual(self.eval('called("w_creators:barber:open")'), 0)


if __name__ == '__main__':
    unittest.main()
