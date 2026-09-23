"""WCClothing (client/clothing/states.lua) regression tests from the module review:
  - our own appearance re-rendered (Appearance.Sync.applyOwn) during the server round trip: the ped
    ends in the state WCState records (success: the new value drawn again; failure: the saved value),
  - the saved appearance replaced or a render / flow starting while the animation runs: the change
    uses the current WCState.appearance or stops with the state unchanged,
  - Remove/RestoreClothingCategory act only on the category actually worn (poncho vs cloak, coat vs
    closed coat),
  - store / wardrobe / barber / surgery flows, the service seat and the cutscene refuse actions,
  - refusal codes: BUSY for flows and the lock, STATE_NOT_APPLICABLE for the ped's condition,
  - the keybind's Settings label comes from locales/en.json.

Run: python3 -m unittest discover -s tests -p 'test_client_states_*.py'
"""
import json
import unittest

from test_client_states_support import make_states_client, lua_list


def hat_ops(rt):
    return [e['op'] for e in lua_list(rt.eval('Log'))
            if e['op'] in ('component.apply', 'component.remove') and e['args'][2] == 'hats']


def controls(rt):
    return [a['control'] for g in lua_list(rt.eval('WCClothing.available()'))
            for i in lua_list(g['items']) for a in lua_list(i['actions'])]


RACE = r'''
AppearanceSchema.normalize = function(a) return WCUtil.copy(a) end  -- fixture hashes are not catalogue hashes
ServerApp = WCState.get()   -- the server's copy, taken before the change (hat on)
Answer = nil
CallbackResults['w_creators:clothing:setState'] = function()
    while not Answer do Wait(50) end
    return Answer
end
clearLog()
'''


class OwnAppearanceRaceTests(unittest.TestCase):
    def setUp(self):
        self.rt = make_states_client()
        self.rt.run(RACE)

    def race(self, answer):
        self.rt.run("performAsync('hat', 'off')")
        self.assertFalse(self.rt.eval('Done'))
        # a grooming tick / API SetClothes / reload arrives during the round trip
        self.rt.run('CreateThread(function() Appearance.Sync.applyOwn(ServerApp) end); tick(100)')
        self.rt.run('Answer = %s; for i = 1, 5 do tick(100) end' % answer)
        self.assertTrue(self.rt.eval('Done'))

    def test_success_draws_the_new_value_again(self):
        self.race('WCResult.ok({})')
        self.assertTrue(self.rt.eval('Result.ok'))
        self.assertEqual(self.rt.eval('WCState.appearance.clothing.states.hat'), 'off')
        ops = hat_ops(self.rt)
        self.assertIn('component.apply', ops)            # the render drew the server copy (hat on)
        self.assertEqual(ops[-1], 'component.remove')    # ... then our value again
        self.assertIn('state.hat.on', controls(self.rt))
        self.assertFalse(self.rt.eval("WCState.busy('clothingAction')"))

    def test_failure_ends_on_the_saved_value(self):
        self.race("WCResult.fail('RATE_LIMITED')")
        self.assertEqual(self.rt.eval('Result.code'), 'RATE_LIMITED')
        self.assertIsNone(self.rt.eval('WCState.appearance.clothing.states.hat'))
        self.assertEqual(hat_ops(self.rt)[-1], 'component.apply')   # the hat is visible
        self.assertIn('state.hat.off', controls(self.rt))

    def test_failure_ends_on_the_value_the_server_sent(self):
        # the server's copy (sent meanwhile) already has the hat off: that is the truth to draw
        self.rt.run("ServerApp.clothing.states.hat = 'off'")
        self.race("WCResult.fail('RATE_LIMITED')")
        self.assertEqual(self.rt.eval('WCState.appearance.clothing.states.hat'), 'off')
        self.assertEqual(hat_ops(self.rt)[-1], 'component.remove')

    def test_no_race_no_redraw(self):
        self.rt.run("Answer = WCResult.ok({}); performAsync('hat', 'off'); for i = 1, 3 do tick(100) end")
        self.assertTrue(self.rt.eval('Result.ok'))
        self.assertEqual(hat_ops(self.rt), ['component.remove'])


class AnimationRaceTests(unittest.TestCase):
    def setUp(self):
        self.rt = make_states_client('Config.Experimental.clothingAnimations = true')

    def test_replaced_appearance_is_the_one_applied(self):
        self.rt.run("WCState.appearance.clothing.states.hat = 'off'; clearLog(); performAsync('hat', 'on'); tick(100)")
        self.rt.run("local a = WCState.get(); a.clothing.equipped.hats = 9999; WCState.set(a)")
        self.rt.run('for i = 1, 8 do tick(100) end')
        self.assertTrue(self.rt.eval('Result.ok'))
        applied = [e['args'][3]['hash'] for e in lua_list(self.rt.eval('Log'))
                   if e['op'] == 'component.apply' and e['args'][2] == 'hats']
        self.assertEqual(applied, [9999])
        self.assertEqual(self.rt.eval('WCState.appearance.clothing.states.hat'), 'on')

    def test_replaced_appearance_without_the_piece_stops_unchanged(self):
        self.rt.run("clearLog(); performAsync('hat', 'off'); tick(100)")
        self.rt.run("local a = WCState.get(); a.clothing.equipped.hats = nil; WCState.set(a)")
        self.rt.run('for i = 1, 8 do tick(100) end')
        self.assertFalse(self.rt.eval('Result.ok'))
        self.assertEqual(self.rt.eval('Result.code'), 'STATE_NOT_APPLICABLE')
        self.assertEqual(self.rt.eval('Result.data.interrupted'), 'appearance')
        self.assertNotIn('component.remove', lua_list(self.rt.eval('ops()')))
        self.assertEqual(lua_list(self.rt.eval('setStateCalls()')), [])
        self.assertIn('StopAnimTask', lua_list(self.rt.eval('ops()')))

    def test_replaced_appearance_already_at_the_target_is_a_no_op(self):
        self.rt.run("clearLog(); performAsync('hat', 'off'); tick(100)")
        # the new copy already has the target: nothing to do, ok without a change
        self.rt.run("local a = WCState.get(); a.clothing.states.hat = 'off'; WCState.set(a)")
        self.rt.run('for i = 1, 8 do tick(100) end')
        self.assertTrue(self.rt.eval('Result.ok'))
        self.assertFalse(self.rt.eval('Result.data.changed'))
        self.assertEqual(lua_list(self.rt.eval('setStateCalls()')), [])

    def test_render_started_mid_animation_interrupts(self):
        self.rt.run("clearLog(); performAsync('hat', 'off'); tick(100)")
        # checked every 100 ms: stopped at once, long before the 600 ms midpoint
        self.rt.run('Appearance.IsPlayerApplying = function() return true end; tick(100)')
        self.assertTrue(self.rt.eval('Done'))
        self.assertIn('StopAnimTask', lua_list(self.rt.eval('ops()')))
        self.assertEqual(self.rt.eval('Result.code'), 'BUSY')
        self.assertEqual(self.rt.eval('Result.data.interrupted'), 'render')
        self.assertNotIn('component.remove', lua_list(self.rt.eval('ops()')))
        self.assertEqual(lua_list(self.rt.eval('setStateCalls()')), [])
        self.assertFalse(self.rt.eval("WCState.busy('clothingAction')"))

    def test_service_flow_started_mid_animation_interrupts(self):
        self.rt.run("clearLog(); performAsync('hat', 'off'); tick(100)")
        self.rt.run("WCServiceFlow = { busy = function() return true end }; tick(100)")
        self.assertTrue(self.rt.eval('Done'))
        self.assertEqual(self.rt.eval('Result.code'), 'BUSY')
        self.assertEqual(self.rt.eval('Result.data.interrupted'), 'flow')
        self.assertNotIn('component.remove', lua_list(self.rt.eval('ops()')))

    def test_ped_interruption_is_not_applicable(self):
        self.rt.run("clearLog(); performAsync('hat', 'off'); tick(100); Peds[MyPed].combat = true; tick(100)")
        self.assertEqual(self.rt.eval('Result.code'), 'STATE_NOT_APPLICABLE')
        self.assertEqual(self.rt.eval('Result.data.interrupted'), 'combat')


class CategoryTests(unittest.TestCase):
    def setUp(self):
        self.rt = make_states_client()

    def removed(self):
        return [e['args'][2] for e in lua_list(self.rt.eval('Log')) if e['op'] == 'component.remove']

    def test_remove_cloak_does_not_hide_a_poncho(self):
        self.rt.run('WCState.appearance.clothing.equipped.ponchos = 8888; clearLog()')
        r = self.rt.eval("Exported.RemoveClothingCategory('cloaks')")
        self.assertEqual(r['code'], 'STATE_NOT_APPLICABLE')
        self.assertEqual(self.removed(), [])
        self.assertIsNone(self.rt.eval('WCState.appearance.clothing.states.poncho'))
        self.assertEqual(len(lua_list(self.rt.eval('Notified'))), 1)
        r = self.rt.eval("Exported.RemoveClothingCategory('ponchos')")
        self.assertTrue(r['ok'])
        self.assertEqual(self.removed(), ['ponchos'])
        self.assertEqual(self.rt.eval("Exported.RestoreClothingCategory('cloaks')")['code'], 'STATE_NOT_APPLICABLE')
        self.assertTrue(self.rt.eval("Exported.RestoreClothingCategory('ponchos')")['ok'])

    def test_coat_and_closed_coat(self):
        self.rt.run('WCState.appearance.clothing.equipped.coats_closed = COAT; clearLog()')
        self.assertEqual(self.rt.eval("Exported.RemoveClothingCategory('coats')")['code'], 'STATE_NOT_APPLICABLE')
        self.assertEqual(self.removed(), [])
        self.assertTrue(self.rt.eval("Exported.RemoveClothingCategory('coats_closed')")['ok'])
        self.assertEqual(self.removed(), ['coats_closed'])

    def test_no_character_still_answers_no_character(self):
        self.rt.run('WCState.clear()')
        self.assertEqual(self.rt.eval("Exported.RemoveClothingCategory('hats')")['code'], 'NO_CHARACTER')


class ServiceFlowGuardTests(unittest.TestCase):
    CASES = (
        "WCServiceFlow = { busy = function() return true end }",
        "WCBarber = { busy = function() return true end }",
        "WCSurgery = { busy = function() return true end }",
        "WCServiceSeat = { active = function() return true end }",
        "WCCutscene = { active = function() return true end }",
        "WCState.busy('service', true)",
    )

    def test_every_service_flow_refuses_with_busy(self):
        for setup in self.CASES:
            rt = make_states_client()
            rt.run(setup)
            r = rt.eval("WCClothing.perform('hat', 'off')")
            self.assertEqual(r['code'], 'BUSY', setup)
            self.assertNotIn('component.remove', lua_list(rt.eval('ops()')), setup)
            self.assertEqual(lua_list(rt.eval('setStateCalls()')), [], setup)
            self.assertEqual(rt.eval("WCClothing.openPanel()")['code'], 'BUSY', setup)

    def test_watcher_closes_the_panel_when_a_service_flow_starts(self):
        rt = make_states_client()
        self.assertTrue(rt.eval('WCClothing.openPanel()')['ok'])
        rt.run("WCServiceFlow = { busy = function() return true end }; tick(250)")
        self.assertFalse(rt.eval('WCClothing.isPanelOpen()'))
        self.assertFalse(rt.eval('WCPanel.isOpen()'))


class RefusalCodeTests(unittest.TestCase):
    def setUp(self):
        self.rt = make_states_client()

    def test_ped_condition_is_not_applicable_with_its_reason(self):
        for flag in ('combat', 'ragdoll', 'dead'):
            rt = make_states_client()
            rt.run('Peds[MyPed].%s = true' % flag)
            r = rt.eval("WCClothing.perform('hat', 'off')")
            self.assertEqual(r['code'], 'STATE_NOT_APPLICABLE')
            self.assertEqual(r['data']['reason'], flag)
            self.assertEqual(lua_list(rt.eval('Notified'))[-1]['description'],
                             rt.eval("WCResult.messageKey('STATE_NOT_APPLICABLE')"))

    def test_lock_and_editor_stay_busy(self):
        self.rt.run("WCState.busy('clothingAction', true)")
        self.assertEqual(self.rt.eval("WCClothing.perform('hat', 'off')")['code'], 'BUSY')
        self.rt.run("WCState.busy('clothingAction', false); WCState.busy('editor', true)")
        r = self.rt.eval("WCClothing.perform('hat', 'off')")
        self.assertEqual(r['code'], 'BUSY')
        self.assertEqual(r['data']['reason'], 'editor')

    def test_nothing_available_is_notified_once(self):
        self.rt.run('WCState.appearance.clothing.equipped = {}')
        self.rt.run('Events.commands.clothing.fn(0, {})')
        self.assertEqual(len(lua_list(self.rt.eval('Notified'))), 1)


class KeybindLabelTests(unittest.TestCase):
    def test_settings_label_comes_from_the_english_locale(self):
        en = json.dumps({'إجراءات الملابس': 'Clothing actions'}, ensure_ascii=False)
        rt = make_states_client(
            "function LoadResourceFile(res, path) if res == 'w_creators' and path == 'locales/en.json' "
            "then return %s end end" % json.dumps(en, ensure_ascii=False))
        bind = rt.eval('Keybinds.wc_clothing_actions')
        self.assertEqual(bind['descriptionEn'], 'Clothing actions')
        self.assertEqual(bind['description'], 'إجراءات الملابس')

    def test_broken_locale_file_is_ignored(self):
        rt = make_states_client("function LoadResourceFile() return '{not json' end")
        self.assertIsNone(rt.eval('Keybinds.wc_clothing_actions.descriptionEn'))
        self.assertIsNotNone(rt.eval('Keybinds.wc_clothing_actions'))


if __name__ == '__main__':
    unittest.main()
