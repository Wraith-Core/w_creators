"""1.0.8 (owner 2026-11-02): the spawn rule and the home wardrobe.

  ServerSpawnRuleTests  WCSpawnServer.finish / the spawn:choose callback: a new character gets the selector; a
                        returning one (1.0.15) gets only «آخر مكان» (an invalid one -> the one fallback point);
                        a house OWNER (w_housing GetHomeSpawn, simulated) chooses «آخر مكان» / «بيتي»; «بيتي» on a
                        bed sends meta.bed; key holders / no w_housing / a broken answer = no home.
  HomeWardrobeTests     w_creators:wardrobe:open('home:<piece>') and every later write of that session ask
                        w_housing's CanUseWardrobe (simulated), whatever Config.Wardrobe.allowRemote says.
  ClientHomeTests       the selector shows «آخر مكان» and «بيتي»; a spawn with meta.bed lies the player in the
                        game's sleep scenario and gets him up with its own exit after Config.Spawn.home.wakeMs.

Run from the resource folder:  py -3 -I -m unittest discover -s tests -p "test_home_spawn.py" -v
"""
import unittest

from test_server_core import server
from test_server_commerce_wardrobe import wardrobe
from test_client_spawn_support import make_spawn_client, spin

HOUSING = r'''
HousingState = 'started'
HOME = nil            -- what w_housing's GetHomeSpawn answers (nil = he owns no house)
HomeAsked = {}
CanUse, CanUseWhy = true, nil
CanUseAsked = {}
local realState = GetResourceState
GetResourceState = function(name) if name == 'w_housing' then return HousingState end return realState(name) end
rawset(exports, 'w_housing', {
    GetHomeSpawn = function(_, who) HomeAsked[#HomeAsked + 1] = who; if HOME == 'throw' then error('boom') end return HOME end,
    CanUseWardrobe = function(_, src, piece) CanUseAsked[#CanUseAsked + 1] = { src = src, piece = piece } return CanUse, CanUseWhy end,
})
'''

BED_HOME = "{ x = 900.9, y = 258.7, z = 115.5, heading = 0.0, houseId = 'larned', bed = { x = 900.9, y = 258.7, z = 115.5, heading = 0.0 } }"
DOOR_HOME = "{ x = 900.3, y = 264.0, z = 115.0, heading = 180.0, houseId = 'larned' }"


class ServerSpawnRuleTests(unittest.TestCase):
    def setUp(self):
        self.rt = server()
        self.e = self.rt.eval
        self.rt.run('last = { x = 5, y = 6, z = 7, heading = 8 }; Bridge.GetLastPosition = function() return last end')
        self.rt.run(HOUSING)
        self.choose = self.e('function(id) return Callbacks["w_creators:spawn:choose"](1, id) end')

    def selects(self):
        return self.rt.client_events('w_creators:client:selectSpawn')

    def spawns(self):
        return self.rt.client_events('w_creators:client:spawn')

    def finish(self, is_new=False, kind='nil'):
        return self.e('WCSpawnServer.finish(1, %s, %s)' % (kind, 'true' if is_new else 'false'))

    def test_the_shipped_config(self):
        self.assertFalse(self.e('Config.Spawn.lastLocation.direct'))   # off since the 2026-11-04 crash
        self.assertTrue(self.e('Config.Spawn.home.enabled'))
        self.assertEqual(self.e('Config.Spawn.home.resource'), 'w_housing')

    def test_a_new_character_chooses_in_the_selector(self):
        self.rt.run('HOME = %s' % BED_HOME)
        self.assertEqual(self.finish(is_new=True), 'selector')
        payload = self.selects()[-1].args[1]
        self.assertIsNone(payload.last)
        self.assertIsNone(payload.home)
        self.assertGreater(len(payload.points), 0)
        self.assertEqual(len(self.spawns()), 0)
        self.assertTrue(self.choose('valentine').ok)             # a new character picks any town

    # 1.0.15 (owner 2026-11-05): a returning character never picks a town
    def test_a_returning_character_sees_only_his_last_location(self):
        for kind in ('nil', '"login"', '"switch"'):
            self.rt.run('WCSpawnServer.cancel(1)')
            self.assertEqual(self.finish(kind=kind), 'selector')
            payload = self.selects()[-1].args[1]
            self.assertEqual(payload.last.x, 5)
            self.assertIsNone(payload.home)
            self.assertEqual(len(payload.points), 0)
        self.assertEqual(self.choose('valentine').code, 'INVALID_SPAWN')
        self.assertEqual(self.choose('__home').code, 'INVALID_SPAWN')
        self.assertTrue(self.e('SpawnPending[1]'))               # a refused choice keeps the grant
        r = self.choose('__last')
        self.assertTrue(r.ok, r.code)
        spawn = self.spawns()[-1]
        self.assertEqual((spawn.args[1].x, spawn.args[1].heading), (5, 8))
        self.assertEqual(spawn.args[2].kind, 'switch')
        self.assertIsNone(spawn.args[2].bed)
        self.assertIsNone(self.e('SpawnPending[1]'))

    def test_the_legacy_event_cannot_pick_a_town(self):
        self.finish()
        self.rt.run('fireEvent("w_creators:server:spawnAt", 1, "valentine")')
        self.assertEqual(self.spawns()[-1].args[1].x, 5)

    def test_direct_spawn_is_still_a_config_choice(self):
        self.rt.run('Config.Spawn.lastLocation.direct = true')
        self.assertEqual(self.finish(), 'direct')
        self.assertEqual(len(self.selects()), 0)
        self.assertEqual(self.spawns()[-1].args[1].x, 5)
        self.assertIsNone(self.e('SpawnPending[1]'))
        self.rt.run('HOME = %s' % BED_HOME)
        self.assertEqual(self.finish(), 'selector')              # a house owner still chooses

    def test_an_invalid_last_location_gets_the_one_fallback_point(self):
        first = self.e('WCSpawnServer.pointIds()[1]')
        for bad in ('nil', '{ x = 0, y = 0, z = 0 }', '{ x = 9000, y = 0, z = 0 }', '{ x = 0/0, y = 1, z = 1 }'):
            self.rt.run('last = %s; WCSpawnServer.cancel(1)' % bad)
            self.assertEqual(self.finish(), 'selector', bad)
            payload = self.selects()[-1].args[1]
            self.assertIsNone(payload.last)
            self.assertEqual(list(payload.points.values()), [first])
        self.assertEqual(self.choose('annesburg').code, 'INVALID_SPAWN')
        self.assertTrue(self.choose(first).ok)

    def test_a_house_owner_chooses_his_last_place_or_his_home(self):
        self.rt.run('HOME = %s' % BED_HOME)
        self.assertEqual(self.finish(), 'selector')
        payload = self.selects()[-1].args[1]
        self.assertEqual((payload.last.x, payload.home.x, payload.home.z), (5, 900.9, 115.5))
        self.assertEqual(len(payload.points), 0)                 # two choices only
        self.assertEqual(self.e('HomeAsked[1]'), 1)              # asked by the player's server id
        self.assertEqual(self.choose('valentine').code, 'INVALID_SPAWN')
        r = self.choose('__home')
        self.assertTrue(r.ok, r.code)
        spawn = self.spawns()[-1]
        self.assertEqual((spawn.args[1].x, spawn.args[1].y), (900.9, 258.7))
        self.assertEqual((spawn.args[2].kind, spawn.args[2].bed.x, spawn.args[2].bed.heading), ('login', 900.9, 0.0))
        self.assertEqual(self.choose('__home').code, 'SPAWN_NOT_PENDING')

    def test_the_owner_may_take_his_last_place(self):
        self.rt.run('HOME = %s' % DOOR_HOME)
        self.finish()
        r = self.choose('__last')
        self.assertTrue(r.ok, r.code)
        spawn = self.spawns()[-1]
        self.assertEqual(spawn.args[1].x, 5)
        self.assertIsNone(spawn.args[2].bed)

    def test_home_without_a_bed_is_inside_the_door(self):
        self.rt.run('HOME = %s' % DOOR_HOME)
        self.finish()
        self.assertTrue(self.choose('__home').ok)
        spawn = self.spawns()[-1]
        self.assertEqual((spawn.args[1].x, spawn.args[1].heading), (900.3, 180.0))
        self.assertIsNone(spawn.args[2].bed)

    def test_an_owner_without_a_valid_last_location_gets_only_his_home(self):
        self.rt.run('HOME = %s; last = nil' % BED_HOME)
        self.assertEqual(self.finish(), 'selector')
        payload = self.selects()[-1].args[1]
        self.assertIsNone(payload.last)
        self.assertEqual(payload.home.x, 900.9)
        self.assertEqual(len(payload.points), 0)
        self.assertEqual(self.choose('__last').code, 'INVALID_SPAWN')
        self.assertTrue(self.choose('__home').ok)

    def test_no_home_when_w_housing_says_none_is_stopped_or_breaks(self):
        def no_home():
            self.rt.run('WCSpawnServer.cancel(1)')
            self.assertEqual(self.finish(), 'selector')
            self.assertIsNone(self.selects()[-1].args[1].home)
        no_home()                                                # a key holder: w_housing answers nil
        self.rt.run('HOME = %s; HousingState = "stopped"' % BED_HOME)
        no_home()
        self.rt.run('HousingState = "started"; HOME = "throw"')
        no_home()
        self.rt.run('HOME = { x = 0/0, y = 1, z = 1 }')
        no_home()
        self.rt.run('WCSpawnServer.cancel(1); HOME = { x = 900.9, y = 258.7, z = 115.5, bed = { x = 1/0, y = 1, z = 1 } }')
        self.finish()
        self.assertTrue(self.choose('__home').ok)
        self.assertIsNone(self.spawns()[-1].args[2].bed)         # a broken bed: just the spot
        self.rt.run('Config.Spawn.home.enabled = false; HOME = %s' % BED_HOME)
        no_home()

    def test_a_house_sold_meanwhile_is_refused_and_the_grant_kept(self):
        self.rt.run('HOME = %s' % BED_HOME)
        self.finish()
        self.rt.run('HOME = nil')
        self.assertEqual(self.choose('__home').code, 'INVALID_SPAWN')
        self.assertTrue(self.e('SpawnPending[1]'))
        self.assertTrue(self.choose('__last').ok)

    def test_home_is_never_a_choice_without_a_grant(self):
        self.rt.run('HOME = %s' % BED_HOME)
        self.assertEqual(self.choose('__home').code, 'SPAWN_NOT_PENDING')


class HomeWardrobeTests(unittest.TestCase):
    def setUp(self):
        self.rt = wardrobe()
        self.e = self.rt.eval
        self.rt.run(HOUSING)
        self.rt.run('Players[1].coords = vector3(0, 0, 0)')     # far from every wardrobe location

    def test_open_asks_w_housing_whatever_remote_says(self):
        for remote in ('true', 'false'):
            self.rt.run('WCSessions.clear(1); Config.Wardrobe.allowRemote = %s; r = openWardrobe(1, "home:7")' % remote)
            self.assertTrue(self.e('r.ok'), self.e('r.code'))
            self.assertTrue(self.e('r.data.remote'))
        self.assertEqual((self.e('CanUseAsked[1].src'), self.e('CanUseAsked[1].piece')), (1, 7))

    def test_refusals(self):
        self.rt.run('CanUse, CanUseWhy = false, "distance"; r = openWardrobe(1, "home:7")')
        self.assertEqual(self.e('r.code'), 'TOO_FAR')
        self.rt.run('CanUse, CanUseWhy = false, "no_key"; r = openWardrobe(1, "home:7")')
        self.assertEqual(self.e('r.code'), 'ACCESS_DENIED')
        self.rt.run('CanUse = true; HousingState = "missing"; r = openWardrobe(1, "home:7")')
        self.assertEqual(self.e('r.code'), 'ACCESS_DENIED')
        # not a piece id: an ordinary (unknown) location
        self.rt.run('HousingState = "started"; r = openWardrobe(1, "home:x")')
        self.assertEqual(self.e('r.code'), 'LOCATION_NOT_FOUND')

    def test_every_write_asks_again(self):
        self.rt.run('''
            Config.Wardrobe.allowRemote = false
            own("vorp:1", "hats", hat)
            r = openWardrobe(1, "home:7"); wardrobeToken = r.data.token
            app = working(); app.clothing.equipped.hats = hat
        ''')
        self.assertTrue(self.e('r.ok'), self.e('r.code'))
        # he walked away / lost his key: the commit and the outfits are refused
        self.rt.run('CanUse, CanUseWhy = false, "distance"; res = wear(app)')
        self.assertEqual(self.e('res.code'), 'LOCATION_NOT_FOUND')
        self.rt.run('eq = { hats = hat }; res = outfit("save", wardrobeToken, "home", eq, {})')
        self.assertEqual(self.e('res.code'), 'LOCATION_NOT_FOUND')
        # still his and still there: the commit goes through
        self.rt.run('CanUse = true; res = wear(app)')
        self.assertTrue(self.e('res.ok'), self.e('res.code'))

    def test_an_ordinary_remote_session_is_unchanged(self):
        self.rt.run('Config.Wardrobe.allowRemote = false; r = openWardrobe(1, nil)')
        self.assertEqual(self.e('r.code'), 'LOCATION_NOT_FOUND')
        self.assertEqual(self.e('#CanUseAsked'), 0)


class ClientHomeTests(unittest.TestCase):
    def setUp(self):
        self.rt = make_spawn_client()
        self.rt.run('clearLog()')
        self.rt.run('''
            Scenario = nil; Cleared = 0
            TaskStartScenarioAtPosition = function(ped, hash, x, y, z, h, d, sitting, teleport)
                Log[#Log + 1] = { op = "TaskStartScenarioAtPosition", args = table.pack(ped, hash, x, y, z, h, d, sitting, teleport) }
                Scenario = hash
            end
            IsPedUsingAnyScenario = function() return Scenario ~= nil end
            ClearPedTasks = function() Cleared = Cleared + 1; Scenario = nil end
        ''')

    def test_the_selector_shows_last_place_and_home(self):
        pts = self.rt.eval("WCSpawnSelector.resolve({ points = {}, kind = 'login', "
                           "last = { x = 100.0, y = 200.0, z = 50.0, heading = 1.0, label = 'فالنتاين' }, "
                           "home = { x = 900.0, y = 258.0, z = 115.0, heading = 90.0 } })")
        ids = [pts[i].id for i in range(1, len(pts) + 1)]
        self.assertEqual(ids, ['__last', '__home'])
        self.assertEqual(pts[1].label, 'آخر مكان')
        self.assertEqual((pts[2].label, pts[2].region, pts[2].coords.x, pts[2].heading), ('بيتي', 'البيت الذي تملكه', 900.0, 90.0))
        # without a home the last location keeps its old name; with no last: home first, then the towns
        pts = self.rt.eval("WCSpawnSelector.resolve({ points = { 'valentine', '__home' }, home = { x = 1.0, y = 2.0, z = 3.0 } })")
        self.assertEqual([pts[i].id for i in range(1, len(pts) + 1)], ['__home', 'valentine'])
        pts = self.rt.eval("WCSpawnSelector.resolve({ points = {}, last = { x = 1.0, y = 2.0, z = 3.0 } })")
        self.assertEqual(pts[1].label, self.rt.eval('Config.Spawn.selector.labels.lastPosition'))

    def test_the_two_choices_do_not_follow_preselect(self):
        # 1.0.8 (pre-ship review): with lastLocation.preselect = false the owner still gets exactly «آخر مكان», «بيتي»
        self.rt.run('Config.Spawn.lastLocation.preselect = false')
        pts = self.rt.eval("WCSpawnSelector.resolve({ points = {}, kind = 'login', "
                           "last = { x = 100.0, y = 200.0, z = 50.0, heading = 1.0 }, home = { x = 900.0, y = 258.0, z = 115.0 } })")
        self.assertEqual([pts[i].id for i in range(1, len(pts) + 1)], ['__last', '__home'])
        self.assertEqual((pts[1].label, pts[2].label), ('آخر مكان', 'بيتي'))
        # the selector opened with them: the first is «آخر مكان», one step on is «بيتي»
        self.rt.run("fireEvent('w_creators:client:selectSpawn', nil, { points = {}, kind = 'login', "
                    "last = { x = 1.0, y = 2.0, z = 3.0 }, home = { x = 900.0, y = 258.0, z = 115.0 } })")
        self.rt.run('WCSpawnSelector.move(1)')
        self.assertTrue(self.rt.eval('WCSpawnSelector.confirm()'))
        args = self.rt.eval("callbacks('w_creators:spawn:choose')[1]")
        self.assertEqual(args[2], '__home')
        # without a house, preselect = false still puts the last location after the towns (unchanged)
        pts = self.rt.eval("WCSpawnSelector.resolve({ points = { 'valentine' }, last = { x = 1.0, y = 2.0, z = 3.0 } })")
        self.assertEqual([pts[i].id for i in range(1, len(pts) + 1)], ['valentine', '__last'])

    def test_home_is_chosen_by_its_id(self):
        self.rt.run("fireEvent('w_creators:client:selectSpawn', nil, { points = {}, kind = 'login', "
                    "last = { x = 1.0, y = 2.0, z = 3.0 }, home = { x = 900.0, y = 258.0, z = 115.0 } })")
        self.rt.run('WCSpawnSelector.move(1)')
        self.assertTrue(self.rt.eval('WCSpawnSelector.confirm()'))
        args = self.rt.eval("callbacks('w_creators:spawn:choose')[1]")
        self.assertEqual((args.n, args[2]), (2, '__home'))

    def test_waking_up_in_bed(self):
        self.rt.run('Ground = { true, 115.0 }')
        self.rt.run("fireEvent('w_creators:client:spawn', nil, { x = 900.9, y = 258.7, z = 115.5, heading = 0.0 }, "
                    "{ kind = 'login', bed = { x = 900.9, y = 258.7, z = 115.5, heading = 270.0 } })")
        spin(self.rt, 500)
        self.assertEqual(self.rt.eval("count('TaskStartScenarioAtPosition')"), 1)
        a = self.rt.eval("Log[indexOf('TaskStartScenarioAtPosition')].args")
        self.assertEqual(a[2], self.rt.eval("GetHashKey('PROP_HUMAN_SLEEP_BED_PILLOW')"))
        self.assertEqual((a[3], a[4], a[5], a[6]), (900.9, 258.7, 115.5, 270.0))
        self.assertEqual((a[7], a[8], a[9]), (-1, False, True))   # warped into the bed
        self.assertEqual(self.rt.eval('Cleared'), 0)
        spin(self.rt, 2600)                                       # Config.Spawn.home.wakeMs = 2500
        self.assertEqual(self.rt.eval('Cleared'), 1)              # the scenario's own exit

    def test_no_bed_no_scenario_and_a_bed_left_early_is_not_cleared(self):
        self.rt.run("fireEvent('w_creators:client:spawn', nil, { x = 10.0, y = 20.0, z = 100.0 }, { kind = 'login' })")
        spin(self.rt, 3500)
        self.assertEqual(self.rt.eval("count('TaskStartScenarioAtPosition')"), 0)
        self.assertEqual(self.rt.eval('Cleared'), 0)
        self.rt.run("fireEvent('w_creators:client:spawn', nil, { x = 10.0, y = 20.0, z = 100.0 }, "
                    "{ kind = 'login', bed = { x = 10.0, y = 20.0, z = 100.5, heading = 0.0 } })")
        spin(self.rt, 500)
        self.rt.run('Scenario = nil')                              # he moved the stick and got up himself
        spin(self.rt, 2600)
        self.assertEqual(self.rt.eval('Cleared'), 0)


if __name__ == '__main__':
    unittest.main(verbosity=2)
