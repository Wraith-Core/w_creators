"""WCCutscene (client/creator/cutscene.lua): the optional first-spawn wagon scene (W:CREATOR:FirstSpawn),
the plain first spawn without it, the 250 ms arrival check, the fallback, the cleanup, and the static
rules of the three character files (no raw natives, no removed command, no blind 10 ms polling,
locale keys known).

Run: cd /home/user/w_creators && python3 -m unittest discover -s tests -p 'test_client_characters_*.py'
"""
import json
import re
import unittest

from harness import RESOURCE, read
from test_client_characters_support import make_characters, settle

FILES = ('client/characters/selector.lua', 'client/creator/creator.lua', 'client/creator/cutscene.lua')


def arrival(rt):
    return rt.eval('2539.83'), rt.eval('-1129.33'), rt.eval('50.03')


class CutsceneTests(unittest.TestCase):
    def setUp(self):
        # no boot selection (the player is already in the world)
        self.rt = make_characters(boot=False)
        self.e = self.rt.eval
        self.run = self.rt.run

    def fire(self):
        self.run('clearLog(); fireEvent("W:CREATOR:FirstSpawn")')
        settle(self.rt, 0, 5, barrier=False)

    def test_disabled_places_the_player_at_the_first_spawn(self):
        self.run('Config.Creator.enableCutscene = false')
        self.fire()
        self.assertAlmostEqual(self.e('Peds[MyPed].coords.x'), self.e('Config.Spawn.firstSpawn.coords.x'))
        self.assertEqual(self.e('count("entity.create")'), 0)
        self.assertFalse(self.e('WCCutscene.active()'))
        settle(self.rt, 5000, 2, barrier=False)
        self.assertGreater(self.e('#Notes'), 0)  # the story notices

    def test_ride_and_arrival(self):
        self.run('Config.Creator.enableCutscene = true')
        self.fire()
        e = self.e
        self.assertTrue(e('WCCutscene.active()'))
        self.assertEqual(e('count("entity.create")'), 2)  # wagon + driver
        self.assertEqual(e('count("TriggerMusicEvent")'), 1)
        self.assertIsNotNone(e('Peds[MyPed].vehicle'))
        self.assertTrue(e('Peds[MyPed].participantsOnly'))
        self.assertTrue(e('Peds[MyPed].invincible'))
        self.assertGreater(e('count("native:0x69D65E89FFD72313")'), 0)  # letterbox through WCNative
        self.assertGreater(e('count("setKeepTask") + count("native:0x971D38760FBC02EF")'), 0)
        # the arrival check runs every 250 ms: nothing happens far from Saint Denis
        self.run('clearLog()')
        settle(self.rt, 250, 4, barrier=False)
        self.assertEqual(e('count("TaskLeaveVehicle")'), 0)
        x, y, z = arrival(self.rt)
        self.run('Peds[MyPed].coords = vector3(%f, %f, %f)' % (x, y, z))
        settle(self.rt, 250, 2, barrier=False)
        self.assertEqual(e('count("TaskLeaveVehicle")'), 1)
        self.assertFalse(e('WCCutscene.active()'))
        self.assertFalse(e('Peds[MyPed].participantsOnly'))
        self.assertFalse(e('Peds[MyPed].invincible'))
        self.run('Peds[MyPed].vehicle = nil')  # the player got off
        settle(self.rt, 250, 2, barrier=False)
        self.assertTrue(e('noted("فقدت كل ملابسك، هناك متجر ملابس على الجانب الآخر من الشارع، ما رأيك أن تذهب إليه لتبديل ثيابك؟")'))
        settle(self.rt, 10000, 3, barrier=False)
        self.assertEqual(e('count("entity.delete")'), 2)

    def test_a_second_event_during_the_ride_is_ignored(self):
        self.run('Config.Creator.enableCutscene = true')
        self.fire()
        self.fire()
        self.assertEqual(self.e('count("entity.create")'), 0)

    def test_missing_driver_model_falls_back_to_the_arrival(self):
        self.run('Config.Creator.enableCutscene = true; InvalidModels = { [GetHashKey("CS_BivCoachDriver")] = true }')
        self.fire()
        x, _, _ = arrival(self.rt)
        self.assertAlmostEqual(self.e('Peds[MyPed].coords.x'), x, places=2)
        self.assertFalse(self.e('WCCutscene.active()'))
        self.assertEqual(self.e('count("entity.delete")'), 1)  # the wagon
        self.assertFalse(self.e('Peds[MyPed].invincible'))

    def test_config_overrides_the_scene(self):
        self.run('''Config.Creator.enableCutscene = true
            Config.Creator.cutscene = { start = { 10.0, 20.0, 30.0, 90.0 }, wagon = "CART01" }''')
        self.fire()
        self.assertAlmostEqual(self.e('Peds[MyPed].coords.x'), 10.0)

    def test_resource_stop_mid_ride_cleans_up(self):
        self.run('Config.Creator.enableCutscene = true')
        self.fire()
        self.run('clearLog(); fireEvent("onResourceStop", nil, "w_creators")')
        e = self.e
        self.assertFalse(e('WCCutscene.active()'))
        self.assertEqual(e('count("entity.delete")'), 2)
        self.assertFalse(e('Peds[MyPed].participantsOnly'))
        self.assertFalse(e('Peds[MyPed].invincible'))
        self.assertGreater(e('count("SetCinematicModeActive")'), 0)
        self.assertEqual(e('Log[indexOf("native:0x69D65E89FFD72313")].args[1]'), False)


class StaticRulesTests(unittest.TestCase):
    def source(self, path):
        return re.sub(r'--[^\n]*', '', read(RESOURCE / path))

    def test_no_raw_natives_or_backtick_hashes(self):
        for path in FILES:
            code = self.source(path)
            self.assertNotIn('InvokeNative', code, path)
            self.assertIsNone(re.search(r'\bN_0x', code), path)
            self.assertNotIn('`', code, path)
            self.assertIsNone(re.search(r'\bprint\(', code), path)

    def test_no_starting_command_and_no_fast_polling(self):
        for path in FILES:
            code = self.source(path)
            self.assertNotIn("RegisterCommand('starting'", code)
            self.assertNotIn('RegisterCommand("starting"', code)
            self.assertIsNone(re.search(r'Wait\(10\)', code), path)
            self.assertNotIn('TODO', code)
            self.assertNotIn('FIXME', code)

    def test_callbacks_use_the_catalogue_names(self):
        names = set()
        for path in FILES:
            names |= set(re.findall(r"await\('([^']+)'", read(RESOURCE / path)))
        allowed = {'w_creators:characters:list', 'w_creators:characters:select', 'w_creators:characters:loaded',
                   'w_creators:characters:beginCreate', 'w_creators:characters:create',
                   'w_creators:characters:cancelCreate', 'w_creators:characters:delete'}
        self.assertEqual(names - allowed, set())
        self.assertTrue({'w_creators:characters:list', 'w_creators:characters:select',
                         'w_creators:characters:loaded', 'w_creators:characters:create'} <= names)

    def test_locale_keys_are_known(self):
        keys = set(json.loads(read(RESOURCE / 'locales' / 'en.json')))
        for path in sorted((RESOURCE / 'locales' / 'pending').glob('*.json')):
            keys |= set(json.loads(read(path)))
        arabic = re.compile(r"'([^'\n]*[؀-ۿ][^'\n]*)'")
        missing = []
        for path in FILES:
            for m in arabic.finditer(self.source(path)):
                if m.group(1) not in keys:
                    missing.append('%s: %s' % (path, m.group(1)))
        self.assertEqual(missing, [])

    def test_legacy_files_are_gone(self):
        for path in ('multichar/client.lua', 'creator/client.lua', 'creator/spawn.lua'):
            self.assertFalse((RESOURCE / path).exists(), path)


if __name__ == '__main__':
    unittest.main()
