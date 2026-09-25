"""WCClothing panel (client/clothing/states.lua): the WCPanel tree (root › group › item › action, every
action under its parent group, only applicable actions, rebuilt after each action), the panel:action
round trip, the watcher (death, character cleared), resource-stop cleanup, the /clothing command and
the keybind.

Run: python3 -m unittest discover -s tests -p 'test_client_states_*.py'
"""
import unittest

from test_client_states_support import make_states_client, lua_list


class PanelTreeTests(unittest.TestCase):
    def setUp(self):
        self.rt = make_states_client()

    def open(self):
        r = self.rt.eval('WCClothing.openPanel()')
        self.assertTrue(r['ok'])
        return self.rt.eval("lastMessage('panel')")

    def test_every_action_sits_under_its_item_and_group(self):
        msg = self.open()
        self.assertTrue(self.rt.eval('WCClothing.isPanelOpen()'))
        paths = lua_list(self.rt.eval("actionPaths(lastMessage('panel').tree)"))
        self.assertEqual(len(paths), 5)   # hat, bandana, sleeves, collar, the shirt itself
        for path in paths:
            chain = lua_list(path)
            # root › taxonomy group › item › action
            self.assertEqual(len(chain), 4)
            self.assertEqual([n['kind'] for n in chain], ['group', 'group', 'group', 'action'])
            action = chain[3]
            item = chain[2]
            group = chain[1]
            self.assertTrue(action['control'].startswith('state.'))
            self.assertTrue(item['id'].startswith(group['id'] + '.'))
        self.assertEqual(msg['session']['title'], 'إجراءات الملابس')

    def test_shirt_actions_nest_under_upper_body_shirt(self):
        self.open()
        tree = self.rt.eval("lastMessage('panel').tree")
        upper = [c for c in lua_list(tree['children']) if c['id'] == 'clothing.upper'][0]
        shirt = lua_list(upper['children'])[0]
        self.assertEqual(shirt['id'], 'clothing.upper.shirts_full')
        self.assertEqual([c['control'] for c in lua_list(shirt['children'])],
                         ['state.sleeves.rolled', 'state.collar.open', 'state.shirt.off'])

    def test_action_rebuilds_the_tree_with_the_inverse(self):
        msg = self.open()
        sid = msg['session']['id']
        r = self.rt.eval("nui('panel:action', { id = '%s', control = 'state.hat.off' })" % sid)
        self.assertTrue(r['ok'])
        got = lua_list(self.rt.eval('controlsOf(%s)' % "nui('panel:action', { id = '%s', control = 'state.bandana.up' }).payload.tree" % sid))
        self.assertIn('state.hat.on', got)
        self.assertNotIn('state.hat.off', got)
        self.assertIn('state.bandana.down', got)
        self.assertNotIn('state.bandana.up', got)
        # a control that is no longer offered is refused by the panel registry
        r = self.rt.eval("nui('panel:action', { id = '%s', control = 'state.hat.off' })" % sid)
        self.assertFalse(r['ok'])
        self.assertEqual(r['code'], 'INVALID_PAYLOAD')

    def test_failed_action_returns_the_message_without_a_notification(self):
        msg = self.open()
        self.rt.run("CallbackResults['w_creators:clothing:setState'] = WCResult.fail('RATE_LIMITED')")
        r = self.rt.eval("nui('panel:action', { id = '%s', control = 'state.hat.off' })" % msg['session']['id'])
        self.assertFalse(r['ok'])
        self.assertEqual(r['code'], 'RATE_LIMITED')
        self.assertEqual(r['message'], self.rt.eval("WCResult.messageKey('RATE_LIMITED')"))
        self.assertEqual(len(lua_list(self.rt.eval('Notified'))), 0)
        self.assertIn('state.hat.off', lua_list(self.rt.eval('controlsOf(WCPanel.payload().tree)')))

    def test_export_action_refreshes_the_open_panel(self):
        self.open()
        n = len(lua_list(self.rt.eval('NuiMessages')))
        self.rt.eval('Exported.ToggleHat()')
        self.assertGreater(len(lua_list(self.rt.eval('NuiMessages'))), n)
        self.assertIn('state.hat.on', lua_list(self.rt.eval("controlsOf(lastMessage('panel').tree)")))

    def test_nothing_to_do_does_not_open(self):
        self.rt.run('WCState.appearance.clothing.equipped = {}')
        r = self.rt.eval('WCClothing.openPanel()')
        self.assertFalse(r['ok'])
        self.assertFalse(self.rt.eval('WCPanel.isOpen()'))
        self.assertEqual(len(lua_list(self.rt.eval('Notified'))), 1)

    def test_refused_while_dead_or_in_an_editor(self):
        self.rt.run('Peds[MyPed].dead = true')
        self.assertEqual(self.rt.eval('WCClothing.openPanel()')['code'], 'STATE_NOT_APPLICABLE')
        self.rt.run("Peds[MyPed].dead = nil; WCState.busy('editor', true)")
        self.assertEqual(self.rt.eval('WCClothing.openPanel()')['code'], 'BUSY')
        self.rt.run("WCState.busy('editor', false); Config.Services.clothingActions = false")
        self.assertEqual(self.rt.eval('WCClothing.openPanel()')['code'], 'ACTIONS_DISABLED')
        self.assertFalse(self.rt.eval('WCPanel.isOpen()'))


class PanelCleanupTests(unittest.TestCase):
    def setUp(self):
        self.rt = make_states_client()
        self.assertTrue(self.rt.eval('WCClothing.openPanel()')['ok'])

    def assertClosed(self):
        self.assertFalse(self.rt.eval('WCPanel.isOpen()'))
        self.assertFalse(self.rt.eval('WCClothing.isPanelOpen()'))
        self.assertEqual(self.rt.eval("NuiMessages[#NuiMessages].type"), 'panelClose')
        focus = [e for e in lua_list(self.rt.eval('Log')) if e['op'] == 'SetNuiFocus']
        self.assertFalse(focus[-1]['args'][1])

    def test_closed_on_death(self):
        self.rt.run('Peds[MyPed].dead = true; tick(250)')
        self.assertClosed()

    def test_closed_when_the_character_is_cleared(self):
        self.rt.run('WCState.clear(); tick(250)')
        self.assertClosed()

    def test_closed_when_the_character_scene_starts(self):
        self.rt.run("WCState.busy('selection', true); tick(250)")
        self.assertClosed()

    def test_refreshed_when_the_saved_appearance_changes(self):
        n = len(lua_list(self.rt.eval('NuiMessages')))
        self.rt.run("WCState.appearance.clothing.states.hat = 'off'; tick(250)")
        self.assertTrue(self.rt.eval('WCPanel.isOpen()'))
        self.assertEqual(len(lua_list(self.rt.eval('NuiMessages'))), n + 1)
        self.assertIn('state.hat.on', lua_list(self.rt.eval("controlsOf(lastMessage('panel').tree)")))

    def test_closed_on_resource_stop(self):
        self.rt.run("fireEvent('onResourceStop', nil, 'w_creators')")
        self.assertClosed()

    def test_other_resource_stop_is_ignored(self):
        self.rt.run("fireEvent('onResourceStop', nil, 'w_hud')")
        self.assertTrue(self.rt.eval('WCPanel.isOpen()'))

    def test_editor_opening_closes_our_panel_and_the_watcher_stops(self):
        self.rt.run('WCPanel.close(); tick(250)')
        self.assertFalse(self.rt.eval('WCClothing.isPanelOpen()'))
        # a panel of another module is never closed by our watcher
        self.rt.run("WCPanel.open({ build = function() return { children = {} } end, onControl = function() end });"
                    "Peds[MyPed].dead = true; tick(500)")
        self.assertTrue(self.rt.eval('WCPanel.isOpen()'))


class AccessTests(unittest.TestCase):
    def test_command_and_keybind(self):
        rt = make_states_client('Config.Keys.clothingActions = "K"')
        self.assertIn('clothing', rt.eval('Events.commands').keys())
        bind = rt.eval('Keybinds.wc_clothing_actions')
        self.assertEqual(bind['defaultKey'], 'K')
        self.assertEqual(bind['description'], 'إجراءات الملابس')
        self.assertIsNone(bind['descriptionEn'])   # no locales/en.json entry: w_lib derives it from the name
        rt.run('Events.commands.clothing.fn(0, {})')
        self.assertTrue(rt.eval('WCClothing.isPanelOpen()'))
        rt.run('WCClothing.closePanel()')
        rt.run('Keybinds.wc_clothing_actions:onPressed()')
        self.assertTrue(rt.eval('WCClothing.isPanelOpen()'))

    def test_keybind_without_a_configured_key_is_unbound(self):
        rt = make_states_client()
        self.assertEqual(rt.eval('Keybinds.wc_clothing_actions.defaultKey'), '')

    def test_command_refusal_is_notified(self):
        rt = make_states_client()
        rt.run('Peds[MyPed].dead = true; Events.commands.clothing.fn(0, {})')
        self.assertFalse(rt.eval('WCPanel.isOpen()'))
        notes = lua_list(rt.eval('Notified'))
        self.assertEqual(notes[-1]['description'], rt.eval("WCResult.messageKey('STATE_NOT_APPLICABLE')"))

    def test_nothing_registered_when_the_service_is_off(self):
        rt = make_states_client('Config.Services.clothingActions = false')
        self.assertNotIn('clothing', rt.eval('Events.commands').keys())
        self.assertIsNone(rt.eval('Keybinds.wc_clothing_actions'))
        # the exports still exist and answer ACTIONS_DISABLED
        self.assertEqual(rt.eval('Exported.ToggleHat()')['code'], 'ACTIONS_DISABLED')


if __name__ == '__main__':
    unittest.main()
