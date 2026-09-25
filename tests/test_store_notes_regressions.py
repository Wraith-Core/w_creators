"""Regressions of the clothing-store notes (after the store camera fix):

1. client/editor/editor.lua: a camera request made while the editor is busy (a live preview or a
   set still rendering) was refused and lost, so the owner in head › mask saw the whole body under
   a header that said "full body". It is now parked (latest wins) and applied, then answered, the
   moment the operation ends: the camera and its label always follow the selected category.
2. client/scene/environment.lua: the fitting room hid the w_hud HUD only while the radar was shown
   (in a store it often is not), and with the show flag alone, which w_hud's tick sets back for a
   player in play. The HUD is now hidden (show flag + stement gate) for the whole store / wardrobe /
   barber / surgery visit and given back on every way out.
"""
import unittest

from test_client_commerce_support import make_commerce, settle
from test_client_services_support import make_services
from test_editor_lua import EditorBase, lua_list

CAMERA = r"""
-- a render that takes a while, as on a real ped: the operation keeps the editor busy meanwhile
Appearance.ApplyDiff = function(ped, before, after)
    Wait(200)
    table.insert(Rendered, { op = 'diff', after = after })
    return true, {}
end
CamAnswers = {}
function camReq(tag, data)
    data.id = data.id or sid()
    NuiCallbacks['editor:camera'](data, function(r) CamAnswers[tag] = r end)
end
function camCalls(name)
    local out = {}
    for _, c in ipairs(CamCalls) do if c.name == name then out[#out + 1] = c.args[1] end end
    return out
end
function busyOp(data)
    data.id = sid()
    CreateThread(function() OpAnswer = nui('editor:action', data) end)
end
"""

STORE = "openEditor('store', 'male', { context = { storeProfile = 'general', owned = {} } })"


class ParkedCameraTests(EditorBase):
    def setUp(self):
        super().setUp()
        self.rt.run(CAMERA)
        self.e = self.rt.eval

    def calls(self, name):
        return lua_list(self.e('camCalls(%r)' % name))

    def preview(self):
        self.rt.run("busyOp({ op = 'preview', values = { ['clothing.hats.style'] = 1 } })")
        self.assertTrue(self.e('WCEditor.session().busy'))

    def test_a_category_opened_during_a_preview_moves_the_camera_once_it_ends(self):
        self.assertTrue(self.e(STORE))
        self.preview()
        self.rt.run("camReq('mask', { preset = 'head' })")
        # parked: nothing moved and nothing answered yet (the header keeps its label until the view is real)
        self.assertIsNone(self.e('CamAnswers.mask'))
        self.assertEqual(self.calls('focus'), [])
        self.rt.run('tick(250)')
        self.assertTrue(self.e('OpAnswer.ok'))
        self.assertFalse(self.e('WCEditor.session().busy'))
        self.assertEqual(self.calls('focus'), ['head'])
        self.assertTrue(self.e('CamAnswers.mask.ok'))
        # the answer names the view the camera took, and the session agrees
        self.assertEqual(self.e('CamAnswers.mask.camera'), 'head')
        self.assertEqual(self.e('WCEditor.session().camera'), 'head')

    def test_the_latest_view_wins(self):
        self.assertTrue(self.e(STORE))
        self.preview()
        self.rt.run("camReq('a', { preset = 'head' }); camReq('b', { preset = 'feet' })")
        # the replaced request is answered at once, and not ok: the NUI keeps what it shows
        self.assertFalse(self.e('CamAnswers.a.ok'))
        self.assertIsNone(self.e('CamAnswers.b'))
        self.rt.run('tick(250)')
        self.assertEqual(self.calls('focus'), ['feet'])
        self.assertEqual(self.e('CamAnswers.b.camera'), 'feet')

    def test_turns_add_up_after_the_view_and_a_new_view_drops_them(self):
        self.assertTrue(self.e(STORE))
        self.preview()
        self.rt.run("camReq('t0', { rotate = 90 }); camReq('v', { preset = 'upperBody' })")
        self.assertFalse(self.e('CamAnswers.t0.ok'))     # the new view would undo it
        self.rt.run("camReq('t1', { rotate = 30 }); camReq('t2', { rotate = 40 }); camReq('z', { zoom = 1 })")
        self.assertFalse(self.e('CamAnswers.t1.ok'))     # folded into the next turn
        self.rt.run('tick(250)')
        self.assertEqual(self.calls('focus'), ['upperBody'])
        self.assertEqual(self.calls('rotate'), [70])
        self.assertEqual(self.calls('zoom'), [1])
        for tag in ('v', 't2', 'z'):
            self.assertTrue(self.e('CamAnswers.%s.ok' % tag), tag)
        # applied in order: the view, then the turn on it
        order = [c.name for c in lua_list(self.rt.g.CamCalls) if c.name in ('focus', 'rotate', 'zoom')]
        self.assertEqual(order, ['focus', 'rotate', 'zoom'])

    def test_the_hide_toggle_keeps_its_own_slot_and_lands_before_the_answer(self):
        self.assertTrue(self.e("openEditor('creator', 'male', { identity = {} })"))
        self.rt.run("busyOp({ op = 'set', control = 'body.weight', value = 5 })")
        self.rt.run("camReq('hide', { hide = true }); camReq('view', { preset = 'face' })")
        self.assertIsNone(self.e('CamAnswers.hide'))
        self.assertIsNone(self.e('CamAnswers.view'))
        settle_ticks = 'tick(250); tick(250); tick(250)'
        self.rt.run(settle_ticks)
        self.assertTrue(self.e('CamAnswers.hide.ok'))
        self.assertTrue(self.e('CamAnswers.hide.hidden'))
        self.assertEqual(self.e('CamAnswers.view.camera'), 'face')
        # the operation's own answer was built after the parked toggle: its payload shows it
        self.assertTrue(self.e('OpAnswer.ok'))
        self.assertTrue(self.e('OpAnswer.payload.hidden'))

    def test_what_cannot_be_parked_is_refused_at_once(self):
        self.assertTrue(self.e(STORE))
        self.preview()
        self.rt.run("camReq('other', { id = 999, preset = 'head' }); camReq('nan', { rotate = 'x' })"
                    "; camReq('none', {})")
        for tag in ('other', 'nan', 'none'):
            self.assertFalse(self.e('CamAnswers.%s.ok' % tag), tag)
        self.rt.run('tick(250)')
        self.assertEqual(self.calls('focus') + self.calls('rotate'), [])

    def test_a_request_still_parked_when_the_session_closes_is_answered(self):
        self.assertTrue(self.e(STORE))
        self.preview()
        self.rt.run("camReq('late', { preset = 'head' }); WCEditor.close()")
        self.assertFalse(self.e('CamAnswers.late.ok'))
        self.rt.run('tick(250)')
        self.assertEqual(self.calls('focus'), [])

    def test_a_free_editor_answers_at_once_as_before(self):
        self.assertTrue(self.e(STORE))
        self.rt.run("camReq('now', { preset = 'feet' })")
        self.assertEqual(self.e('CamAnswers.now.camera'), 'feet')


# A stand-in for w_hud's two flags: `show` (hud:client:showui / Hideui) and the stement gate
# (hud:client:show/hideUiWithHoutStement), the one that holds for a player in play.
W_HUD = r"""
HudShow, HudStement = true, false
AddEventHandler('hud:client:showui', function() HudShow = true end)
AddEventHandler('hud:client:Hideui', function() HudShow = false end)
AddEventHandler('hud:client:showUiWithHoutStement', function() HudStement = false end)
AddEventHandler('hud:client:hideUiWithHoutStement', function() HudStement = true end)
function hudHidden() return HudShow == false and HudStement == true end
function hudBack() return HudShow == true and HudStement == false end
-- the store's case: the radar is off (an interior, a w_map minimap); BOOL natives answer 1
function IsRadarHidden() return 1 end
"""

STORE_LOC = 'valentine_clothing'


class FittingRoomHudTests(unittest.TestCase):
    def setUp(self):
        self.rt = make_commerce(W_HUD)
        self.run = self.rt.run
        self.e = self.rt.eval

    def open_store(self):
        self.run('CallbackResults = { ["w_creators:store:open"] = storeData(),'
                 ' ["w_creators:store:commit"] = function(token, opId, app) return okResult({ appearance = app }) end }')
        self.run('R = table.pack(WCStore.open(%r))' % STORE_LOC)
        self.assertTrue(self.e('R[1]'), self.e('R[2]'))
        self.assertTrue(self.e('WCPreviewEnv.active()'))

    def assert_hidden_then_back(self, leave):
        self.open_store()
        # hidden for the whole visit although the radar was off, with the gate that holds in play
        self.assertTrue(self.e('hudHidden()'))
        self.run('tick(0); tick(100)')
        self.assertTrue(self.e('hudHidden()'))
        # the radar the player did not have is not touched
        self.assertEqual(self.e('count("setRadarVisible")'), 0)
        self.run(leave)
        settle(self.rt)
        self.assertFalse(self.e('WCPreviewEnv.active()'))
        self.assertTrue(self.e('hudBack()'))

    def test_cancel_gives_the_hud_back(self):
        self.assert_hidden_then_back('cancel()')

    def test_commit_gives_the_hud_back(self):
        self.assert_hidden_then_back('makeDirty(1.05); save()')

    def test_death_gives_the_hud_back(self):
        self.assert_hidden_then_back('Peds[MyPed].dead = true')

    def test_a_forced_server_close_gives_the_hud_back(self):
        self.assert_hidden_then_back('fireEvent("w_creators:client:sessionClosed", nil, "stok", "expired")')

    def test_an_editor_closed_elsewhere_gives_the_hud_back(self):
        self.assert_hidden_then_back('WCEditor.close()')

    def test_resource_stop_gives_the_hud_back(self):
        self.assert_hidden_then_back('fireEvent("onResourceStop", nil, "w_creators")')

    def test_a_w_hud_restart_mid_visit_is_hidden_again(self):
        self.open_store()
        self.run('HudShow, HudStement = true, false')          # w_hud came back with its defaults
        self.run('fireEvent("onClientResourceStart", nil, "other")')
        self.assertTrue(self.e('hudBack()'))
        self.run('fireEvent("onClientResourceStart", nil, "w_hud")')
        self.assertTrue(self.e('hudHidden()'))
        self.run('cancel()')
        settle(self.rt)
        self.assertTrue(self.e('hudBack()'))
        # after the visit a w_hud restart is none of this resource's business
        self.run('HudShow, HudStement = true, false; fireEvent("onClientResourceStart", nil, "w_hud")')
        self.assertTrue(self.e('hudBack()'))

    def test_a_shown_radar_is_still_hidden_and_given_back(self):
        self.run('function IsRadarHidden() return false end')
        self.open_store()
        self.assertTrue(self.e('hudHidden()'))
        self.run('clearLog(); cancel()')
        settle(self.rt)
        self.assertTrue(self.e('hudBack()'))
        self.assertEqual(self.e('count("setRadarVisible")'), 1)
        self.assertTrue(self.e('Log[indexOf("setRadarVisible")].args[1]'))


class ServiceHudTests(unittest.TestCase):
    """The wardrobe, the barber and the clinic go through the same environment."""

    def setUp(self):
        self.rt = make_services(W_HUD)
        self.run = self.rt.run
        self.e = self.rt.eval

    def visit(self, callback, data, opener, loc):
        self.run('CallbackResults = { [%r] = %s }' % (callback, data))
        self.run('R = table.pack(%s(%r))' % (opener, loc))
        self.assertTrue(self.e('R[1]'), self.e('R[2]'))
        self.assertTrue(self.e('hudHidden()'))
        self.run('cancel()')
        settle(self.rt)
        self.assertFalse(self.e('WCPreviewEnv.active()'))
        self.assertTrue(self.e('hudBack()'))

    def test_wardrobe(self):
        self.visit('w_creators:wardrobe:open', 'wardrobeData()', 'WCWardrobe.open', 'valentine_wardrobe')

    def test_barber(self):
        self.visit('w_creators:barber:open', 'barberData()', 'WCBarber.open', 'valentine_barber')

    def test_surgery(self):
        self.visit('w_creators:surgery:open', 'surgeryData()', 'WCSurgery.open', 'valentine_surgery')


if __name__ == '__main__':
    unittest.main()
