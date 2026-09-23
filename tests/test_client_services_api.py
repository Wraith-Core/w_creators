"""Public client API (client/api.lua): the read exports return copies, GetEquippedCategory,
RefreshAppearance (server reload, local fallback, never over an editor), IsInCharacterScene, the
OpenCosmeticSurgery export and the /reloadappearance command."""
import unittest

from test_client_services_support import make_services, settle


class ApiTestCase(unittest.TestCase):
    def setUp(self):
        self.rt = make_services()
        self.run = self.rt.run
        self.eval = self.rt.eval


class ReadTests(ApiTestCase):
    def test_every_export_is_registered(self):
        for name in ('OpenCosmeticSurgery', 'GetAppearance', 'GetCurrentOutfit', 'GetEquippedCategory',
                     'RefreshAppearance', 'IsInCharacterScene'):
            self.assertEqual(self.eval('type(Exported[%r])' % name), 'function', name)

    def test_get_appearance_is_a_copy(self):
        self.run('A = Exported.GetAppearance(); A.body.height = 1.09')
        self.assertEqual(self.eval('A.version'), 3)
        self.assertEqual(self.eval('WCState.appearance.body.height'), 1.0)

    def test_get_appearance_without_a_character(self):
        self.run('WCState.clear()')
        self.assertIsNone(self.eval('Exported.GetAppearance()'))
        self.assertIsNone(self.eval('Exported.GetCurrentOutfit()'))
        self.assertIsNone(self.eval('Exported.GetEquippedCategory("hats")'))

    def test_current_outfit(self):
        self.run('local a = WCState.appearance.clothing; a.equipped.hats = 123; a.tints.hats = { palette = "p", tint0 = 1,'
                 ' tint1 = 2, tint2 = 3 }; a.states.hat = "off"; a.outfit = 7')
        self.run('O = Exported.GetCurrentOutfit(); O.equipped.hats = 999')
        self.assertEqual(self.eval('O.outfit'), 7)
        self.assertEqual(self.eval('O.tints.hats.tint1'), 2)
        self.assertEqual(self.eval('O.states.hat'), 'off')
        self.assertEqual(self.eval('WCState.appearance.clothing.equipped.hats'), 123)

    def test_equipped_category(self):
        self.run('local a = WCState.appearance.clothing; a.equipped.hats = -5; a.tints.hats = { palette = "p", tint0 = 4,'
                 ' tint1 = 0, tint2 = 0 }')
        self.run('H, T = Exported.GetEquippedCategory("hats")')
        self.assertEqual(self.eval('H'), 0xFFFFFFFB)
        self.assertEqual(self.eval('T.tint0'), 4)
        self.run('T.tint0 = 99')
        self.assertEqual(self.eval('WCState.appearance.clothing.tints.hats.tint0'), 4)
        self.run('WCState.appearance.clothing.equipped.boots = nil')
        self.assertIsNone(self.eval('Exported.GetEquippedCategory("boots")'))
        self.assertEqual(self.eval('Exported.GetEquippedCategory("heads")'),
                         self.eval('WCUtil.u32(WCState.appearance.head.head)'))
        self.assertEqual(self.eval('Exported.GetEquippedCategory("BODIES_UPPER")'),
                         self.eval('WCUtil.u32(WCState.appearance.body.upper)'))
        for bad in ('nil', '5', '""', 'string.rep("a", 65)'):
            self.assertIsNone(self.eval('Exported.GetEquippedCategory(%s)' % bad))

    def test_a_removed_beard_is_not_equipped(self):
        self.run('WCState.appearance.hair.facial = 0')
        self.assertIsNone(self.eval('Exported.GetEquippedCategory("mustache")'))


class SceneTests(ApiTestCase):
    def test_not_in_the_scene_by_default(self):
        self.assertFalse(self.eval('Exported.IsInCharacterScene()'))

    def test_selection_lock(self):
        self.run('WCState.busy("selection", true)')
        self.assertTrue(self.eval('Exported.IsInCharacterScene()'))

    def test_scene_room_loaded(self):
        self.run('CreatorScene.isLoaded = function() return true end')
        self.assertTrue(self.eval('Exported.IsInCharacterScene()'))

    def test_login_spawn_selection_counts_and_admin_does_not(self):
        self.run('WCSpawnSelector = { active = function() return true end, kind = function() return Kind end }')
        self.run('Kind = "login"')
        self.assertTrue(self.eval('Exported.IsInCharacterScene()'))
        self.run('Kind = "admin"')
        self.assertFalse(self.eval('Exported.IsInCharacterScene()'))

    def test_creator_and_selector_modules(self):
        self.run('WCCreator = { active = function() return true end }')
        self.assertTrue(self.eval('Exported.IsInCharacterScene()'))
        self.run('WCCreator = { active = function() error("broken") end }')
        self.assertFalse(self.eval('Exported.IsInCharacterScene()'))
        self.run('WCSelector = { active = function() return true end }')
        self.assertTrue(self.eval('Exported.IsInCharacterScene()'))

    def test_barber_visit_is_not_the_character_scene(self):
        self.run('CallbackResults = { ["w_creators:barber:open"] = barberData() }')
        self.run('WCBarber.open("valentine_barber")')
        self.assertTrue(self.eval('WCEditor.isOpen()'))
        self.assertFalse(self.eval('Exported.IsInCharacterScene()'))


class RefreshTests(ApiTestCase):
    def test_reload_from_the_server_renders_the_saved_appearance(self):
        self.run('Server = AppearanceSchema.default("male"); Server.body.height = 1.04')
        self.run('CallbackResults = { ["w_creators:appearance:reload"] = okResult({ appearance = Server }) }')
        self.assertTrue(self.eval('Exported.RefreshAppearance()'))
        settle(self.rt)
        self.assertEqual(self.eval('called("w_creators:appearance:reload")'), 1)
        self.assertEqual(self.eval('WCState.appearance.body.height'), 1.04)
        self.assertEqual(self.eval('lastRestore().body.height'), 1.04)

    def test_a_refused_reload_renders_the_local_copy(self):
        self.run('CallbackResults = { ["w_creators:appearance:reload"] = fail("RATE_LIMITED") }')
        self.assertTrue(self.eval('Exported.RefreshAppearance()'))
        settle(self.rt)
        self.assertEqual(self.eval('#RestoreCalls'), 1)
        self.assertEqual(self.eval('lastRestore().body.height'), 1.0)

    def test_a_throwing_reload_renders_the_local_copy(self):
        self.run('CallbackResults = { ["w_creators:appearance:reload"] = function() error("down") end }')
        self.assertTrue(self.eval('Exported.RefreshAppearance()'))
        settle(self.rt)
        self.assertEqual(self.eval('#RestoreCalls'), 1)

    def test_no_refresh_over_an_editor(self):
        self.run('CallbackResults = { ["w_creators:barber:open"] = barberData() }')
        self.run('WCBarber.open("valentine_barber")')
        self.run('R = table.pack(WCClientApi.refresh())')
        self.assertFalse(self.eval('R[1]'))
        self.assertEqual(self.eval('R[2]'), 'BUSY')
        self.assertEqual(self.eval('called("w_creators:appearance:reload")'), 0)

    def test_no_refresh_without_a_character_or_in_the_scene(self):
        self.run('WCState.busy("selection", true)')
        self.assertFalse(self.eval('Exported.RefreshAppearance()'))
        self.run('WCState.busy("selection", false); WCState.clear()')
        self.assertFalse(self.eval('Exported.RefreshAppearance()'))
        self.assertEqual(self.eval('called("w_creators:appearance:reload")'), 0)

    def test_one_refresh_at_a_time(self):
        self.run('CallbackResults = { ["w_creators:appearance:reload"] = function() Wait(500) return okResult({'
                 ' appearance = AppearanceSchema.default("male") }) end }')
        self.assertTrue(self.eval('Exported.RefreshAppearance()'))
        self.assertFalse(self.eval('Exported.RefreshAppearance()'))
        settle(self.rt)
        self.assertTrue(self.eval('Exported.RefreshAppearance()'))

    def test_reloadappearance_command(self):
        self.assertIsNotNone(self.eval('Events.commands.reloadappearance'))
        self.run('Events.commands.reloadappearance.fn(0, {})')
        settle(self.rt)
        self.assertEqual(self.eval('called("w_creators:appearance:reload")'), 1)
        self.run('WCState.clear(); Events.commands.reloadappearance.fn(0, {})')
        self.assertTrue(self.eval('noted(WCResult.messageKey("NO_CHARACTER"))'))



class LocaleTests(unittest.TestCase):
    def test_every_arabic_key_of_the_module_is_translated(self):
        import json
        import re
        from harness import RESOURCE, read
        keys = set(json.loads(read(RESOURCE / 'locales' / 'en.json')))
        arabic = re.compile(r"'([^'\n]*[؀-ۿ][^'\n]*)'|\"([^\"\n]*[؀-ۿ][^\"\n]*)\"")
        missing = []
        for rel in ('client/barber/barber.lua', 'client/surgery/surgery.lua', 'client/api.lua',
                    'client/dev/tools.lua'):
            code = re.sub(r'--[^\n]*', '', read(RESOURCE / rel))
            for m in arabic.finditer(code):
                key = m.group(1) or m.group(2)
                if key not in keys:
                    missing.append('%s: %s' % (rel, key))
        self.assertEqual(missing, [])

    def test_no_raw_natives_prints_or_backticks(self):
        import re
        from harness import RESOURCE, read
        for rel in ('client/barber/barber.lua', 'client/surgery/surgery.lua', 'client/api.lua',
                    'client/dev/tools.lua'):
            raw = read(RESOURCE / rel)
            code = re.sub(r'--[^\n]*', '', raw).replace('w.print', '')
            for forbidden in ('InvokeNative', 'N_0x', '`', 'print('):
                self.assertFalse(forbidden in code, '%s: %s' % (rel, forbidden))
            for marker in ('TODO', 'FIXME', 'TEMP'):
                self.assertFalse(marker in raw, '%s: %s' % (rel, marker))


if __name__ == '__main__':
    unittest.main()
