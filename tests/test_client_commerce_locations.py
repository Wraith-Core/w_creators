"""Service locations (client/services/locations.lua, WCServicePoints): which locations get a prompt,
a blip and an NPC, the prompt options, dispatching, canInteract, opening hours, relabelling and
cleanup on resource stop."""
import json
import re
import unittest

from harness import RESOURCE, read
from test_client_commerce_support import make_commerce


class LocationsTestCase(unittest.TestCase):
    def setUp(self):
        self.rt = make_commerce()
        self.run = self.rt.run
        self.eval = self.rt.eval

    def rebuild(self, setup=''):
        self.run(setup)
        self.run('WCLocations.reload(); Walkups = {}; BlipsMade = {}; N = WCServicePoints.build()')
        return self.eval('N')

    def point(self, loc_id):
        self.run('P = nil; for _, p in ipairs(WCServicePoints.points()) do if p.loc.id == %r then P = p end end' % loc_id)
        return self.eval('P')


class BuildTests(LocationsTestCase):
    def test_default_config_builds_every_prompted_location(self):
        self.assertEqual(self.eval('#WCServicePoints.points()'), 14)
        self.assertEqual(self.eval('#liveWalkups()'), 14)
        # surgery clinics have prompt = false (w_ambulancejob provides the interaction) and no blip
        for loc in ('valentine_surgery', 'saintdenis_surgery', 'armadillo_surgery'):
            self.assertIsNone(self.point(loc))

    def test_prompt_options(self):
        p = self.point('valentine_clothing')
        self.assertIsNotNone(p)
        self.run('O = P.prompt.opts')
        self.assertEqual(self.eval('O.distance'), 2.0)
        self.assertEqual(self.eval('O.prompts[1].key'), 'E')
        self.assertEqual(self.eval('O.prompts[1].label'), 'فتح')
        self.assertEqual(self.eval('O.prompts[1].hold'), False)
        self.assertEqual(self.eval('O.title'), 'متجر الملابس · فالنتاين')
        self.assertEqual(self.eval('O.coords.x'), -326.17)

    def test_interact_key_and_radius_come_from_the_config(self):
        self.rebuild('Config.Keys.interact = "G"; Config.Locations[1].interactionRadius = 3.5')
        self.point('valentine_clothing')
        self.assertEqual(self.eval('P.prompt.opts.prompts[1].key'), 'G')
        self.assertEqual(self.eval('P.prompt.opts.distance'), 3.5)

    def test_blips_and_npcs(self):
        self.point('valentine_clothing')
        # the game's own tailor sprite (blip_shop_clothing is not a sprite of the game: a plain dot)
        self.assertEqual(self.eval('BlipsMade[1].sprite'), 'blip_shop_tailor')
        self.assertEqual(self.eval('BlipsMade[1].name'), 'متجر الملابس')
        ped = self.eval('P.npc')
        self.assertIsNotNone(ped)
        self.assertTrue(self.eval('Peds[P.npc].frozen'))
        self.assertTrue(self.eval('Peds[P.npc].invincible'))
        self.assertFalse(self.eval('Peds[P.npc].damageable'))
        self.assertTrue(self.eval('Peds[P.npc].blocking'))
        self.assertEqual(self.eval('Peds[P.npc].model'), self.eval('GetHashKey("S_M_M_Tailor_01")'))
        self.point('tumbleweed_clothing')  # npc = false
        self.assertIsNone(self.eval('P.npc'))
        # 3 tailors, and the catalogue book on each of the 4 stores' counters
        self.assertEqual(self.eval('count("entity.create")'), 3 + 4)
        npcs = sum(1 for p in self.eval('WCServicePoints.points()').values() if p.npc)
        self.assertEqual(npcs, 3)

    def test_disabled_locations_and_services_are_skipped(self):
        n = self.rebuild('Config.Locations[1].enabled = false; Config.Services.barbers = false')
        self.assertEqual(n, 14 - 1 - 7)
        self.assertIsNone(self.point('valentine_clothing'))
        self.assertIsNone(self.point('valentine_barber'))
        self.assertIsNotNone(self.point('saintdenis_clothing'))
        self.assertFalse(any(b['name'] == 'الحلاق' for b in self.eval('BlipsMade').values()))

    def test_prompt_false_skips_the_whole_location(self):
        # §17: another resource owns a prompt = false location (no prompt, blip or NPC here)
        self.rebuild('Config.Locations[1].prompt = false')
        self.assertIsNone(self.point('valentine_clothing'))
        self.assertEqual(self.eval('#liveWalkups()'), 13)
        coords = [(b['coords']['x'], b['coords']['y']) for b in self.rt.py(self.eval('BlipsMade')).values()]
        self.assertNotIn((-326.17, self.eval('Config.Locations[1].coords.y')), coords)

    def test_a_prompt_false_location_with_blip_and_npc_gets_neither(self):
        self.rebuild('for _, l in ipairs(Config.Locations) do if l.id == "valentine_surgery" then'
                     ' l.blip = { sprite = "blip_shop_doctor" };'
                     ' l.npc = { model = "S_M_M_Tailor_01", coords = { x = 1.0, y = 2.0, z = 3.0, w = 0.0 } } end end;'
                     ' EntitiesBefore = count("entity.create")')
        self.assertIsNone(self.point('valentine_surgery'))
        self.assertFalse(any(b['sprite'] == 'blip_shop_doctor' for b in self.rt.py(self.eval('BlipsMade')).values()))
        # the rebuild made the 3 tailors and the 4 catalogue books again, and nothing for the clinic
        self.assertEqual(self.eval('count("entity.create") - EntitiesBefore'), 3 + 4)

    def test_a_surgery_clinic_with_a_prompt_dispatches_to_the_surgery_client(self):
        self.rebuild('for _, l in ipairs(Config.Locations) do if l.id == "valentine_surgery" then l.prompt = true end end')
        self.assertIsNotNone(self.point('valentine_surgery'))
        self.run('Opened = {}; WCSurgery = { open = function(id) Opened[#Opened + 1] = id end }')
        self.run('P.prompt.opts.prompts[1].onComplete()')
        self.assertEqual(self.eval('Opened[1]'), 'valentine_surgery')


class DispatchTests(LocationsTestCase):
    def test_each_type_dispatches_to_its_entry_point(self):
        self.run('Opened = {}')
        for mod in ('WCStore', 'WCWardrobe', 'WCBarber'):
            self.run('%s = %s or {}; %s.open = function(id) Opened[#Opened + 1] = "%s:" .. id end' % (mod, mod, mod, mod))
        for loc in ('valentine_clothing', 'rhodes_wardrobe', 'valentine_barber'):
            self.point(loc)
            self.run('P.prompt.opts.prompts[1].onComplete()')
        self.assertEqual(list(self.eval('Opened').values()),
                         ['WCStore:valentine_clothing', 'WCWardrobe:rhodes_wardrobe', 'WCBarber:valentine_barber'])

    def test_a_missing_entry_point_is_not_an_error(self):
        self.run('WCBarber = nil')
        self.point('valentine_barber')
        self.assertFalse(self.eval('WCServicePoints.dispatch(P.loc)'))

    def test_the_prompt_opens_the_store(self):
        self.run('CallbackResults = { ["w_creators:store:open"] = storeData() }')
        self.point('valentine_clothing')
        self.run('P.prompt.opts.prompts[1].onComplete()')
        self.assertEqual(self.eval('callbacks("w_creators:store:open")[1][2]'), 'valentine_clothing')
        self.assertTrue(self.eval('WCEditor.isOpen()'))

    def test_can_interact_blocks(self):
        self.point('valentine_clothing')
        ci = 'P.prompt.opts.canInteract()'
        self.assertTrue(self.eval(ci))
        self.run('Peds[MyPed].dead = true')
        self.assertFalse(self.eval(ci))
        self.run('Peds[MyPed].dead = false')
        for lock in ('selection', 'spawn', 'respawn', 'clothingAction', 'editor', 'service'):
            self.run('WCState.busy(%r, true)' % lock)
            self.assertFalse(self.eval(ci), lock)
            self.run('WCState.busy(%r, false)' % lock)
        self.assertTrue(self.eval(ci))
        self.run('WCBarber = { busy = function() return true end }')
        self.assertFalse(self.eval(ci))
        self.run('WCBarber = nil; WCPanel.isOpen = function() return true end')
        self.assertFalse(self.eval(ci))
        self.run('WCPanel.isOpen = function() return false end; CreatorScene.isLoaded = function() return true end')
        self.assertFalse(self.eval(ci))
        self.run('CreatorScene.isLoaded = function() return false end')
        self.assertTrue(self.eval(ci))
        self.run('CallbackResults = { ["w_creators:wardrobe:open"] = wardrobeData() }; WCWardrobe.open("rhodes_wardrobe")')
        self.assertFalse(self.eval(ci))
        self.run('cancel()')
        self.assertTrue(self.eval(ci))

    def test_a_blocked_prompt_does_not_dispatch(self):
        self.run('Opened = {}; WCStore.open = function(id) Opened[#Opened + 1] = id end')
        self.point('valentine_clothing')
        self.run('Peds[MyPed].dead = true; P.prompt.opts.prompts[1].onComplete()')
        self.assertEqual(self.eval('#Opened'), 0)


class HoursTests(LocationsTestCase):
    HOURS = 'Config.Locations[1].hours = { open = 6, close = 22 }; '

    def tearDown(self):
        self.run('GlobalState = nil')

    def open_now(self):
        """The prompt shows (no flow blocks it) and its action is enabled."""
        return self.eval('P.prompt.opts.canInteract() and P.prompt.enabled.E ~= false and WCServicePoints.canInteract(P.loc)')

    def test_the_prompt_follows_the_hour_the_server_publishes(self):
        self.rebuild(self.HOURS + 'GlobalState = { [WCServicePoints.HOUR_KEY] = 3 }')
        self.point('valentine_clothing')
        self.assertIsNotNone(self.eval('P.prompt'))  # built while closed: shown, action disabled
        self.assertFalse(self.open_now())
        self.assertTrue(self.eval('P.prompt.opts.canInteract()'))
        self.assertFalse(self.eval('P.prompt.enabled.E'))
        self.run('GlobalState[WCServicePoints.HOUR_KEY] = 10')
        self.assertTrue(self.open_now())
        self.run('GlobalState[WCServicePoints.HOUR_KEY] = 23')
        self.assertFalse(self.open_now())
        self.point('saintdenis_clothing')  # no hours: always open
        self.assertTrue(self.open_now())

    def test_neither_the_os_clock_nor_the_game_clock_is_read(self):
        self.rebuild(self.HOURS + 'GlobalState = {}; GameHour = 2;'
                     ' WCLocations.hour = function() error("the client has no os library") end')
        self.point('valentine_clothing')
        # no published hour: the prompt shows and the server's store:open decides
        self.assertTrue(self.eval('P.prompt.opts.canInteract()'))
        self.run('GlobalState = nil')
        self.assertTrue(self.eval('P.prompt.opts.canInteract()'))
        self.run('GlobalState = { [WCServicePoints.HOUR_KEY] = "bad" }')
        self.assertTrue(self.eval('P.prompt.opts.canInteract()'))

    def test_the_client_runs_without_the_os_library(self):
        self.run('SavedOs = os; os = nil')
        try:
            n = self.rebuild(self.HOURS + 'GlobalState = { [WCServicePoints.HOUR_KEY] = 23 }')
            self.assertEqual(n, 14)
            self.point('valentine_clothing')
            self.assertFalse(self.open_now())
            self.run('CallbackResults = { ["w_creators:wardrobe:open"] = wardrobeData(),'
                     ' ["w_creators:wardrobe:commit"] = function(_, t, o, app) return okResult({ appearance = app }) end }')
            self.point('rhodes_wardrobe')
            self.run('P.prompt.opts.prompts[1].onComplete()')
            self.assertTrue(self.eval('WCEditor.isOpen()'))
            self.run('makeDirty(); save()')
            self.run('tick(300); tick(300)')
            self.assertEqual(self.eval('callbacks("w_creators:wardrobe:commit")[1][2]'), 'wtok')
            self.assertIsNone(self.eval('WCServiceFlow.current()'))
            self.run('CallbackResults["w_creators:store:open"] = storeData(); WCStore.open("valentine_clothing"); cancel()')
            self.run('tick(300); tick(300)')
            self.assertIsNone(self.eval('WCServiceFlow.current()'))
            self.assertEqual(self.eval('called("w_creators:session:close")'), 1)
        finally:
            self.run('os = SavedOs')

    def test_locations_without_hours_are_always_open(self):
        self.rebuild('GlobalState = { [WCServicePoints.HOUR_KEY] = 3 }')
        self.point('valentine_clothing')
        self.assertTrue(self.eval('P.prompt.opts.canInteract()'))


class LifecycleTests(LocationsTestCase):
    def test_language_change_relabels_prompts_and_blips(self):
        self.run('locale = function(k) return "EN:" .. k end')
        self.run('fireEvent("w_lib:setLocale", nil, "en")')
        self.point('valentine_clothing')
        self.assertEqual(self.eval('P.prompt.title'), 'EN:متجر الملابس · EN:فالنتاين')
        self.assertEqual(self.eval('P.prompt.labels.E'), 'EN:فتح')
        self.assertEqual(self.eval('BlipsMade[1].name'), 'EN:متجر الملابس')

    def test_resource_stop_removes_everything(self):
        self.run('NPCS = {}; for _, p in ipairs(WCServicePoints.points()) do if p.npc then NPCS[#NPCS + 1] = p.npc end end')
        self.run('fireEvent("onResourceStop", nil, "w_creators")')
        self.assertEqual(self.eval('#liveWalkups()'), 0)
        self.assertTrue(all(b['removed'] for b in self.eval('BlipsMade').values()))
        self.assertEqual(self.eval('#WCServicePoints.points()'), 0)
        for ped in self.eval('NPCS').values():
            self.assertFalse(self.eval('DoesEntityExist(%d)' % ped))

    def test_rebuilding_does_not_duplicate(self):
        self.rebuild()
        self.run('WCServicePoints.build()')
        self.assertEqual(self.eval('#liveWalkups()'), 14)


class SourceRulesTests(unittest.TestCase):
    FILES = ('client/services/locations.lua', 'client/clothing/store.lua', 'client/wardrobe/wardrobe.lua')

    def test_locale_keys_are_translated(self):
        keys = set(json.loads(read(RESOURCE / 'locales' / 'en.json')))
        pattern = re.compile(r"'([^'\n]*[؀-ۿ][^'\n]*)'")
        for name in self.FILES:
            code = re.sub(r'--[^\n]*', '', read(RESOURCE / name))
            for m in pattern.finditer(code):
                self.assertIn(m.group(1), keys, name)

    def test_no_raw_natives_prints_or_legacy_store(self):
        for name in self.FILES:
            code = read(RESOURCE / name)
            self.assertNotIn('InvokeNative', code, name)
            self.assertNotRegex(code, r'\bN_0x', name)
            self.assertNotRegex(code, r'(?m)^\s*print\(', name)
            self.assertNotIn('`', code, name)
        self.assertFalse((RESOURCE / 'store' / 'client.lua').exists())


if __name__ == '__main__':
    unittest.main()
