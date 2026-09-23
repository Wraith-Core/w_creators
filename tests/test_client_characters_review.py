"""Regression tests for the review of the character selector / creator / cutscene:
/characters refused during the first-spawn ride and the spawn selector, one reopen when the creator
hands back, a failed preview after a delete, the minimum boot wait after playerSpawned, cutscene
config overrides given as vectors, and the wagon of a finished ride removed when a new ride starts.

Run: cd /home/user/w_creators && python3 -m unittest discover -s tests -p 'test_client_characters_*.py'
"""
import unittest

from test_client_characters_support import make_characters, settle

TWO = ('CallbackResults = { ["w_creators:characters:list"] = '
       'listResult({ card("1", "male"), card("2", "female") }, 3) }')
REFUSED = 'noted("لا يمكنك تبديل الشخصية الآن")'
RETRY = 'تعذر عرض الشخصية. أعد المحاولة'

CREATED = '''
function createdEntities()
    local out = {}
    for _, e in ipairs(Log) do if e.op == "entity.create" then out[#out + 1] = e.args[1] end end
    return out
end
'''


class SwitchGuardTests(unittest.TestCase):
    def setUp(self):
        self.rt = make_characters(boot=False, setup=TWO)
        self.rt.run('Peds[MyPed].visible = true; WCState.setCharacter("9", "male")')

    def command(self):
        self.rt.run('Events.commands.characters.fn(0, {}, "characters")')
        settle(self.rt)

    def test_refused_during_the_first_spawn_ride(self):
        self.rt.run('Config.Creator.enableCutscene = true; clearLog(); fireEvent("W:CREATOR:FirstSpawn")')
        settle(self.rt, 0, 5, barrier=False)
        self.assertTrue(self.rt.eval('WCCutscene.active()'))
        self.assertFalse(self.rt.eval('(WCSelector.canSwitch())'))
        self.command()
        self.assertTrue(self.rt.eval(REFUSED))
        self.assertEqual(self.rt.eval('called("w_creators:scene:prepare")'), 0)
        self.assertFalse(self.rt.eval('WCSelector.active()'))
        self.assertTrue(self.rt.eval('WCCutscene.active()'))

    def test_refused_while_the_spawn_selector_is_open(self):
        self.rt.run('WCSpawnSelector = { active = function() return true end }')
        self.command()
        self.assertTrue(self.rt.eval(REFUSED))
        self.assertEqual(self.rt.eval('called("w_creators:scene:prepare")'), 0)
        self.assertFalse(self.rt.eval('WCSelector.active()'))
        self.assertEqual(self.rt.eval('WCState.character.charid'), '9')

    def test_refused_while_a_spawn_flow_runs(self):
        self.rt.run('WCSpawn = { busy = function() return true end }')
        self.command()
        self.assertTrue(self.rt.eval(REFUSED))
        self.assertEqual(self.rt.eval('called("w_creators:scene:prepare")'), 0)

    def test_allowed_once_those_flows_ended(self):
        self.rt.run('WCSpawnSelector = { active = function() return false end }; '
                    'WCSpawn = { busy = function() return false end }')
        self.assertTrue(self.rt.eval('(WCSelector.canSwitch())'))


class CreatorHandBackTests(unittest.TestCase):
    def make(self, begin):
        return make_characters(setup='CallbackResults = { ["w_creators:characters:list"] = listResult({}, 2), '
                                     '["w_creators:characters:beginCreate"] = %s }' % begin)

    def assert_reopened_once(self, rt, code):
        rt.run('clearLog(); press("RETURN")')
        settle(rt)
        e = rt.eval
        self.assertTrue(e('WCSelector.active()'))
        self.assertFalse(e('WCCreator.active()'))
        self.assertEqual(e('called("w_creators:characters:beginCreate")'), 1)
        self.assertEqual(e('called("w_creators:scene:prepare")'), 1)
        self.assertEqual(e('called("w_creators:characters:list")'), 1)
        self.assertEqual(e('count("loadSphere")'), 1)
        self.assertEqual(e('#CreatorScene.peds()'), 1)
        self.assertEqual(e('liveGroups()'), 1)
        self.assertTrue(e('noted(WCResult.messageKey("%s"))' % code))
        self.assertFalse(e('WCSelector.busy()'))

    def test_busy_grant_reopens_the_selection_once(self):
        self.assert_reopened_once(self.make('WCResult.fail("BUSY")'), 'BUSY')

    def test_refused_grant_reopens_the_selection_once(self):
        self.assert_reopened_once(self.make('WCResult.fail("CHARACTER_SLOT_LIMIT")'), 'CHARACTER_SLOT_LIMIT')

    def test_creator_refusing_before_taking_the_room_reopens_the_selection(self):
        rt = self.make('WCResult.ok({ token = "t1" })')
        rt.run('WCEditor.isOpen = function() return true end; clearLog(); press("RETURN")')
        settle(rt)
        self.assertTrue(rt.eval('WCSelector.active()'))
        self.assertFalse(rt.eval('WCCreator.active()'))
        self.assertEqual(rt.eval('called("w_creators:characters:beginCreate")'), 0)
        self.assertEqual(rt.eval('called("w_creators:characters:list")'), 1)


class PreviewAfterDeleteTests(unittest.TestCase):
    def setUp(self):
        self.rt = make_characters(setup=(
            'CallbackResults = { ["w_creators:characters:list"] = listResult({ card("1", "male", "John Smith"), '
            'card("2", "female", "Jane Doe") }, 3, true, { enabled = true, holdTime = 3000, typed = false }) }'))
        self.e = self.rt.eval

    def test_failed_preview_after_delete_shows_the_retry_prompt(self):
        deleted_preview = self.e('CreatorScene.peds()[1]')
        self.rt.run('''CallbackResults["w_creators:characters:list"] = listResult({ card("2", "female", "Jane Doe") }, 3)
            CreatorScene.create = function() return nil, "RATE_LIMITED" end
            clearLog(); press("DELETE")''')
        settle(self.rt)
        e = self.e
        self.assertEqual(e('called("w_creators:characters:delete")'), 1)
        self.assertEqual(e('called("w_creators:characters:list")'), 1)
        # the deleted character's preview and card are gone; the retry prompt is up
        self.assertFalse(e('DoesEntityExist(%d)' % deleted_preview))
        self.assertEqual(e('#CreatorScene.peds()'), 0)
        self.assertFalse(e('lastNui("charCard").show'))
        self.assertEqual(e('liveGroup().title'), RETRY)
        self.assertTrue(e('WCSelector.active()'))
        self.assertFalse(e('WCSelector.busy()'))

    def test_failed_preview_while_browsing_keeps_the_current_slot(self):
        self.rt.run('CreatorScene.create = function() return nil, "RATE_LIMITED" end; clearLog(); press("RIGHT")')
        settle(self.rt)
        e = self.e
        self.assertEqual(e('liveGroup().title'), 'John Smith  (1/3)')
        self.assertEqual(e('#CreatorScene.peds()'), 1)
        self.assertTrue(e('noted("%s")' % RETRY))


class BootOrderTests(unittest.TestCase):
    def test_selection_opens_no_sooner_than_500_ms_after_playerSpawned(self):
        rt = make_characters(boot=False, setup=TWO)
        e = rt.eval
        rt.run('Peds[MyPed].coords = vector3(50.0, 50.0, 50.0)')
        settle(rt, 100, 5, barrier=False)
        # vorp_core's fade is already there: only the minimum wait holds the selection back
        rt.run('ScreenFadedOut = true; fireEvent("playerSpawned")')
        for _ in range(4):
            rt.run('tick(100)')
        self.assertEqual(e('called("w_creators:scene:prepare")'), 0)
        for _ in range(4):
            rt.run('tick(100)')
        self.assertEqual(e('called("w_creators:scene:prepare")'), 1)
        self.assertTrue(e('WCSelector.active()'))


class CutsceneReviewTests(unittest.TestCase):
    def setUp(self):
        self.rt = make_characters(boot=False)
        self.rt.run(CREATED)
        self.e = self.rt.eval

    def handles(self):
        table = self.rt.py(self.e('createdEntities()')) or {}
        if isinstance(table, dict):
            return [table[k] for k in sorted(table)]
        return list(table)

    def fire(self):
        self.rt.run('fireEvent("W:CREATOR:FirstSpawn")')
        settle(self.rt, 0, 5, barrier=False)

    def test_vector_overrides_are_used(self):
        # CitizenFX: type(vector4(...)) == "vector4"; the test stubs build plain tables
        self.rt.run('''
            local rawtype = type
            local vmt = getmetatable(vector4(0, 0, 0, 0))
            type = function(v)
                if rawtype(v) == "table" and getmetatable(v) == vmt then
                    return v.w ~= nil and "vector4" or "vector3"
                end
                return rawtype(v)
            end
            Config.Creator.enableCutscene = true
            Config.Creator.cutscene = { start = vector4(10.0, 20.0, 30.0, 90.0),
                                        arrival = vector3(11.0, 21.0, 31.0), speed = "12" }''')
        self.rt.run('clearLog()')
        self.fire()
        e = self.e
        self.assertAlmostEqual(e('Peds[MyPed].coords.x'), 10.0)
        self.assertAlmostEqual(e('Peds[MyPed].coords.y'), 20.0)
        drive = 'Log[indexOf("TaskVehicleDriveToCoord")].args'
        self.assertAlmostEqual(e(drive + '[3]'), 11.0)
        self.assertAlmostEqual(e(drive + '[6]'), 12.0)

    def test_invalid_overrides_fall_back_to_the_defaults(self):
        self.rt.run('''Config.Creator.enableCutscene = true
            Config.Creator.cutscene = { start = "nowhere", wagon = 5, speed = "fast", bogus = 1 }
            clearLog()''')
        self.fire()
        e = self.e
        self.assertAlmostEqual(e('Peds[MyPed].coords.x'), 2520.09, places=2)
        self.assertEqual(e('GetEntityModel(createdEntities()[1]) == GetHashKey("STAGECOACH001X")'), True)
        self.assertAlmostEqual(e('Log[indexOf("TaskVehicleDriveToCoord")].args[6]'), 10.0)
        self.assertTrue(e('WCCutscene.active()'))

    def test_a_new_ride_during_the_departure_removes_the_old_wagon(self):
        self.rt.run('Config.Creator.enableCutscene = true; clearLog()')
        self.fire()
        first = self.handles()
        self.assertEqual(len(first), 2)
        self.rt.run('Peds[MyPed].coords = vector3(2539.83, -1129.33, 50.03)')
        settle(self.rt, 250, 2, barrier=False)
        self.rt.run('Peds[MyPed].vehicle = nil')
        settle(self.rt, 250, 2, barrier=False)
        self.assertFalse(self.e('WCCutscene.active()'))
        # the departure delay runs: a second first-spawn event starts a new ride
        self.fire()
        created = self.handles()
        self.assertEqual(len(created), 4)
        for handle in first:
            self.assertFalse(self.e('DoesEntityExist(%d)' % handle), handle)
        settle(self.rt, 10000, 3, barrier=False)
        for handle in first:
            self.assertFalse(self.e('DoesEntityExist(%d)' % handle), handle)
        # the new ride keeps its own wagon and driver
        for handle in created[2:]:
            self.assertTrue(self.e('DoesEntityExist(%d)' % handle), handle)
        self.assertTrue(self.e('WCCutscene.active()'))

    def test_departure_removes_the_wagon_even_after_a_stop(self):
        self.rt.run('Config.Creator.enableCutscene = true; clearLog()')
        self.fire()
        first = self.handles()
        self.rt.run('Peds[MyPed].coords = vector3(2539.83, -1129.33, 50.03)')
        settle(self.rt, 250, 2, barrier=False)
        self.rt.run('Peds[MyPed].vehicle = nil')
        settle(self.rt, 10000, 3, barrier=False)
        for handle in first:
            self.assertFalse(self.e('DoesEntityExist(%d)' % handle), handle)


if __name__ == '__main__':
    unittest.main()
