"""WCCreator (client/creator/creator.lua): the server grant first, the gender scene, beginCreate(sex),
the creator editor (sections, identity, facial hair by sex), commit → render → loaded, cancel paths
that release the grant, the repair (appearance-only) path, the lost grant and the resource stop.

Run: cd /home/user/w_creators && python3 -m unittest discover -s tests -p 'test_client_characters_*.py'
"""
import datetime
import unittest

from test_client_characters_support import make_characters, settle

DOB = '%04d-05-01' % (datetime.date.today().year - 30)

BASE = ('CallbackResults = { ["w_creators:characters:list"] = listResult({}, 2), '
        '["w_creators:characters:beginCreate"] = WCResult.ok({ token = "tok-1" }) }')

SESSION = 'WCEditor.session()'


def facial_nodes(rt):
    return rt.eval('''(function()
        local payload = WCEditor.payload()
        local n = 0
        local function walk(node)
            if type(node) ~= "table" then return end
            if node.id == "facialHair" or (type(node.control) == "string" and node.control:find("^facial%.")) then n = n + 1 end
            for _, c in ipairs(node.children or {}) do walk(c) end
        end
        walk(payload.tree)
        return n
    end)()''')


class CreatorGrantTests(unittest.TestCase):
    def test_creator_refuses_to_open_without_a_grant(self):
        rt = make_characters(setup='CallbackResults = { ["w_creators:characters:list"] = listResult({}, 2), '
                                   '["w_creators:characters:beginCreate"] = WCResult.fail("CREATION_DISABLED") }')
        rt.run('clearLog(); press("RETURN")')
        settle(rt)
        e = rt.eval
        self.assertEqual(e('called("w_creators:characters:beginCreate")'), 1)
        self.assertFalse(e('WCCreator.active()'))
        self.assertTrue(e('WCSelector.active()'))
        self.assertTrue(e('noted(WCResult.messageKey("CREATION_DISABLED"))'))
        self.assertFalse(e('WCEditor.isOpen()'))
        # no gender peds were made: only the selection preview exists
        self.assertEqual(e('#CreatorScene.peds()'), 1)

    def test_legacy_event_asks_the_server_first(self):
        rt = make_characters(setup=BASE)
        rt.run('clearLog(); fireEvent("W:CHARCREATION:starting")')
        settle(rt)
        self.assertEqual(rt.eval('called("w_creators:characters:beginCreate")'), 1)
        self.assertTrue(rt.eval('WCCreator.active()'))
        self.assertFalse(rt.eval('WCSelector.active()'))

    def test_legacy_event_is_ignored_with_a_character_in_play(self):
        rt = make_characters(boot=False, setup=BASE)
        rt.run('WCState.setCharacter("7", "male"); clearLog(); fireEvent("W:CHARCREATION:starting")')
        settle(rt, 0, 5, barrier=False)
        self.assertEqual(rt.eval('called("w_creators:characters:beginCreate")'), 0)
        self.assertFalse(rt.eval('WCCreator.active()'))


class CreatorGenderSceneTests(unittest.TestCase):
    def setUp(self):
        self.rt = make_characters(setup=BASE)
        self.e = self.rt.eval
        self.run = self.rt.run
        self.run('clearLog(); press("RETURN")')
        settle(self.rt)

    def test_gender_scene_as_before(self):
        e = self.e
        self.assertEqual(e('WCCreator.stage()'), 'gender')
        peds = self.rt.py(e('CreatorScene.peds()'))
        self.assertEqual(len(peds), 2)
        models = sorted(e('GetEntityModel(%d)' % p) for p in peds.values())
        self.assertEqual(models, sorted([e('GetHashKey("mp_male")'), e('GetHashKey("mp_female")')]))
        self.assertEqual(e('count("giveWeapon")'), 2)       # holstered revolvers
        self.assertEqual(e('count("startScenario")'), 2)    # scenario idles
        group = 'liveGroup()'
        for key in ('LEFT', 'RIGHT', 'RETURN', 'BACK'):
            self.assertIsNotNone(e('%s.prompts.%s' % (group, key)), key)
        self.assertTrue(e('WCCamera.isOpen()'))
        self.assertEqual(e('GetEntityModel(WCCamera.ped()) == GetHashKey("mp_male")'), True)
        self.run('clearLog()')
        settle(self.rt, 0, 2, barrier=False)
        self.assertGreater(e('count("DrawLightWithRange")'), 0)  # the lights loop
        self.assertNotIn(e('MyPed'), list(peds.values()))

    def test_switching_gender_moves_the_camera(self):
        self.run('press("RIGHT")')
        settle(self.rt, 0, 3, barrier=False)
        self.assertEqual(self.e('GetEntityModel(WCCamera.ped()) == GetHashKey("mp_female")'), True)
        self.assertGreater(self.e('count("PlaySoundFrontend")'), 0)

    def test_back_releases_the_grant_and_returns_to_the_selection(self):
        self.run('clearLog(); press("BACK")')
        settle(self.rt)
        e = self.e
        self.assertEqual(e('called("w_creators:characters:cancelCreate")'), 1)
        self.assertEqual(e('callArgs("w_creators:characters:cancelCreate")[2]'), 'tok-1')
        self.assertFalse(e('WCCreator.active()'))
        self.assertTrue(e('WCSelector.active()'))
        self.assertEqual(e('#CreatorScene.peds()'), 1)  # only the selection preview
        self.assertEqual(e('liveGroups()'), 1)

    def test_female_accept_locks_the_sex_and_never_offers_facial_hair(self):
        self.run('press("RIGHT")')
        settle(self.rt, 0, 3, barrier=False)
        self.run('clearLog(); press("RETURN")')
        settle(self.rt)
        e = self.e
        self.assertEqual(e('callArgs("w_creators:characters:beginCreate")[2]'), 'female')
        self.assertEqual(e('WCCreator.stage()'), 'editor')
        self.assertEqual(e(SESSION + '.mode'), 'creator')
        self.assertEqual(e(SESSION + '.saved.sex'), 'female')
        self.assertIsNone(e(SESSION + '.sections.facialHair'))
        self.assertTrue(e(SESSION + '.sections.makeup'))
        self.assertEqual(facial_nodes(self.rt), 0)
        self.assertEqual(e(SESSION + '.opts.identity.sex'), 'female')
        self.assertIsNotNone(e('lastNui("editor").identity'))
        self.assertTrue(e(SESSION + '.context.startingClothing == Config.Creator.startingClothing'))
        self.assertTrue(e(SESSION + '.context.presets == Config.StartingOutfits.female'))
        # the gender prompts are gone: the only live group is the editor's own hint group
        self.assertEqual(e('liveGroups()'), 1)
        self.assertIsNone(e('liveGroup().prompts.BACK'))
        # the male ped is hidden, out of the wide shots
        male = e('(function() for _, p in ipairs(CreatorScene.peds()) do if GetEntityModel(p) == GetHashKey("mp_male") then return p end end end)()')
        self.assertFalse(e('Peds[%d].visible' % male))

    def test_male_creator_offers_facial_hair(self):
        self.run('press("RETURN")')
        settle(self.rt)
        self.assertTrue(self.e(SESSION + '.sections.facialHair'))
        self.assertGreater(facial_nodes(self.rt), 0)

    def test_beginCreate_refused_on_accept_keeps_the_scene(self):
        self.run('''CallbackResults["w_creators:characters:beginCreate"] = WCResult.fail("RATE_LIMITED")
            press("RETURN")''')
        settle(self.rt)
        self.assertEqual(self.e('WCCreator.stage()'), 'gender')
        self.assertTrue(self.e('noted(WCResult.messageKey("RATE_LIMITED"))'))
        self.assertFalse(self.e('WCEditor.isOpen()'))


class CreatorEditorTests(unittest.TestCase):
    def setUp(self):
        self.rt = make_characters(setup=BASE)
        self.e = self.rt.eval
        self.run = self.rt.run
        self.run('press("RETURN")')
        settle(self.rt)
        self.run('press("RETURN")')  # accept male
        settle(self.rt)
        self.assertEqual(self.e('WCCreator.stage()'), 'editor')

    def save(self):
        self.run('''saveResult = WCEditor.action({ id = WCEditor.session().id, op = "save", opId = "op-1",
            identity = { firstname = "John", lastname = "Smith", dob = "%s" } })''' % DOB)
        settle(self.rt, 0, 5, barrier=False)

    def test_commit_creates_renders_then_loads(self):
        self.run('''CallbackResults["w_creators:characters:create"] = function(_, token, identity, app)
            return WCResult.ok({ appearance = app, charid = "42" }) end
            clearLog()''')
        self.save()
        e = self.e
        self.assertTrue(e('saveResult.ok'))
        self.assertTrue(e('saveResult.closed'))
        args = e('callArgs("w_creators:characters:create")')
        self.assertEqual(args[2], 'tok-1')
        self.assertEqual(args[3]['firstname'], 'John')
        self.assertEqual(args[3]['dob'], DOB)
        self.assertEqual(args[4]['sex'], 'male')
        self.assertLess(e('indexOf("callback:w_creators:characters:create")'), e('indexOf("RestorePlayer")'))
        self.assertLess(e('indexOf("RestorePlayer")'), e('indexOf("callback:w_creators:characters:loaded")'))
        self.assertEqual(e('WCState.character.charid'), '42')
        self.assertFalse(e('WCCreator.active()'))
        self.assertFalse(e('WCEditor.isOpen()'))
        self.assertEqual(e('#CreatorScene.peds()'), 0)
        self.assertEqual(e('liveGroups()'), 0)
        self.assertFalse(e('WCCamera.isOpen()'))
        self.assertFalse(e('WCState.busy("selection")'))
        self.assertFalse(e('WCState.busy("editor")'))
        self.assertTrue(e('Peds[MyPed].visible'))
        self.assertFalse(e('Peds[MyPed].frozen'))
        self.assertFalse(e('CreatorScene.isLoaded()'))
        self.assertEqual(e('called("w_creators:characters:cancelCreate")'), 0)

    def test_render_failure_keeps_the_editor_and_never_loads(self):
        self.run('''CallbackResults["w_creators:characters:create"] = function(_, token, identity, app)
            return WCResult.ok({ appearance = app, charid = "42" }) end
            RestoreFails = true; clearLog()''')
        self.save()
        self.assertFalse(self.e('saveResult.ok'))
        self.assertEqual(self.e('saveResult.code'), 'INTERNAL_ERROR')
        self.assertEqual(self.e('called("w_creators:characters:loaded")'), 0)
        self.assertTrue(self.e('WCEditor.isOpen()'))
        self.assertEqual(self.e('WCCreator.stage()'), 'editor')
        # the retry reuses the same token (the server replays the same create)
        self.run('RestoreFails = false')
        self.save()
        self.assertTrue(self.e('saveResult.ok'))
        self.assertEqual(self.e('callArgs("w_creators:characters:create", 2)[2]'), 'tok-1')
        self.assertEqual(self.e('called("w_creators:characters:loaded")'), 1)

    def test_lost_grant_closes_the_editor_and_returns_to_the_selection(self):
        self.run('''CallbackResults["w_creators:characters:create"] = WCResult.fail("CREATION_NOT_GRANTED")
            clearLog()''')
        self.save()
        settle(self.rt)
        e = self.e
        self.assertFalse(e('saveResult.ok'))
        self.assertFalse(e('WCEditor.isOpen()'))
        self.assertFalse(e('WCCreator.active()'))
        self.assertTrue(e('WCSelector.active()'))
        self.assertTrue(e('noted(WCResult.messageKey("CREATION_NOT_GRANTED"))'))

    def test_invalid_identity_never_reaches_the_server(self):
        self.run('''clearLog(); r = WCEditor.action({ id = WCEditor.session().id, op = "save",
            identity = { firstname = "J", lastname = "", dob = "x" } })''')
        self.assertFalse(self.e('r.ok'))
        self.assertEqual(self.e('called("w_creators:characters:create")'), 0)

    def test_cancel_returns_to_the_gender_scene_and_keeps_the_grant(self):
        self.run('clearLog(); r = WCEditor.action({ id = WCEditor.session().id, op = "cancel" })')
        settle(self.rt)
        e = self.e
        self.assertTrue(e('r.ok'))
        self.assertFalse(e('WCEditor.isOpen()'))
        self.assertEqual(e('WCCreator.stage()'), 'gender')
        self.assertEqual(e('called("w_creators:characters:cancelCreate")'), 0)
        self.assertEqual(e('#CreatorScene.peds()'), 2)
        self.assertEqual(e('liveGroups()'), 1)
        self.assertTrue(e('WCCamera.isOpen()'))
        # back from there releases the grant
        self.run('press("BACK")')
        settle(self.rt)
        self.assertEqual(e('called("w_creators:characters:cancelCreate")'), 1)

    def test_resource_stop_in_the_editor_cleans_up(self):
        self.run('clearLog(); NuiMessages = {}')
        self.run('fireEvent("onResourceStop", nil, "w_creators")')
        e = self.e
        self.assertFalse(e('WCCreator.active()'))
        self.assertFalse(e('WCEditor.isOpen()'))
        self.assertIsNotNone(e('lastNui("editorClose")'))
        self.assertEqual(e('#CreatorScene.peds()'), 0)
        self.assertEqual(e('liveGroups()'), 0)
        self.assertFalse(e('WCCamera.isOpen()'))
        self.assertFalse(e('CreatorScene.isLoaded()'))
        self.assertTrue(e('Peds[MyPed].visible'))
        self.assertFalse(e('Peds[MyPed].frozen'))
        self.assertFalse(e('WCState.busy("selection")'))
        self.assertFalse(e('WCState.busy("editor")'))
        self.assertGreater(e('count("SetNuiFocus")'), 0)
        self.assertGreater(e('count("NetworkClearClockTimeOverride")'), 0)


class CreatorRepairTests(unittest.TestCase):
    def make(self, sex):
        # a character without a saved appearance; the framework may not know its sex either
        setup = ('local c = card("5", "female", "Jane Doe", { appearance = false }); c.sex = %s\n'
                 'CallbackResults = { ["w_creators:characters:list"] = listResult({ c }, 2), '
                 '["w_creators:characters:select"] = WCResult.ok({ needsAppearance = true, token = "rep-1", '
                 'sex = %s }) }' % (('"%s"' % sex, '"%s"' % sex) if sex else ('nil', 'nil')))
        rt = make_characters(setup=setup)
        rt.run('clearLog(); press("RETURN")')
        settle(rt)
        return rt

    def test_repair_with_a_known_sex_opens_the_editor_without_identity(self):
        rt = self.make('female')
        e = rt.eval
        self.assertEqual(e('called("w_creators:characters:beginCreate")'), 0)
        self.assertEqual(e('WCCreator.stage()'), 'editor')
        self.assertEqual(e(SESSION + '.saved.sex'), 'female')
        self.assertIsNone(e(SESSION + '.opts.identity'))
        self.assertIsNone(e(SESSION + '.sections.facialHair'))
        rt.run('''CallbackResults["w_creators:characters:create"] = function(_, token, identity, app)
            return WCResult.ok({ appearance = app, charid = "5" }) end
            clearLog(); r = WCEditor.action({ id = WCEditor.session().id, op = "save", opId = "x" })''')
        settle(rt, 0, 5, barrier=False)
        self.assertTrue(e('r.ok'))
        args = e('callArgs("w_creators:characters:create")')
        self.assertEqual(args[2], 'rep-1')
        self.assertIsNone(args[3])
        self.assertEqual(e('called("w_creators:characters:loaded")'), 1)
        self.assertEqual(e('WCState.character.charid'), '5')

    def test_repair_cancel_releases_the_grant(self):
        rt = self.make('female')
        rt.run('clearLog(); r = WCEditor.action({ id = WCEditor.session().id, op = "cancel" })')
        settle(rt)
        self.assertEqual(rt.eval('callArgs("w_creators:characters:cancelCreate")[2]'), 'rep-1')
        self.assertTrue(rt.eval('WCSelector.active()'))

    def test_repair_without_a_sex_runs_the_gender_scene(self):
        rt = self.make(None)
        self.assertEqual(rt.eval('WCCreator.stage()'), 'gender')
        rt.run('press("RETURN")')
        settle(rt)
        self.assertEqual(rt.eval('called("w_creators:characters:beginCreate")'), 0)
        self.assertEqual(rt.eval('WCCreator.stage()'), 'editor')


class CreatorStopTests(unittest.TestCase):
    def test_resource_stop_in_the_gender_scene(self):
        rt = make_characters(setup=BASE)
        rt.run('press("RETURN")')
        settle(rt)
        rt.run('fireEvent("onResourceStop", nil, "w_creators")')
        e = rt.eval
        self.assertEqual(e('#CreatorScene.peds()'), 0)
        self.assertEqual(e('liveGroups()'), 0)
        self.assertFalse(e('WCCamera.isOpen()'))
        self.assertTrue(e('Peds[MyPed].visible'))
        self.assertFalse(e('WCState.busy("selection")'))


if __name__ == '__main__':
    unittest.main()
