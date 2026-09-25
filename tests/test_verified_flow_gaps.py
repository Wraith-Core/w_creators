"""Regression tests for the verified-flow gaps (character creation replay and sex lock, dead switch,
fitting isolation range, busy session close, uncertain commits, silent refusals, preview heading,
degraded barber/surgery, lingering isolation flag, non-persisting states, stale admin spawn grants,
admin selector hold on an aborted respawn)."""
import os
import sys
import unittest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from test_server_characters_flow import Base as CharsBase, identity  # noqa: E402
from test_client_characters_support import make_characters, settle  # noqa: E402
from test_server_characters_world import Base as WorldBase  # noqa: E402
from test_client_commerce_support import make_commerce, settle as settle_commerce  # noqa: E402
from test_server_services_barber import services_server  # noqa: E402


class CreationReplayTests(CharsBase):
    def test_begin_create_after_a_completed_creation_replays_the_same_token(self):
        r = self.call('characters:beginCreate', 1, 'male')
        token = r.data.token
        app = self.e('S.default("male")')
        created = self.call('characters:create', 1, token, identity(self.rt), app)
        self.assertTrue(created.ok, created.code)
        self.assertEqual(self.e('#registered'), 1)
        # the client never saw it finish: cancel → gender scene → accept again
        self.later()
        again = self.call('characters:beginCreate', 1, 'female')
        self.assertTrue(again.ok, again.code)
        self.assertEqual(again.data.token, token)
        self.assertEqual(again.data.sex, 'male')
        self.later()
        replay = self.call('characters:create', 1, token, identity(self.rt), app)
        self.assertTrue(replay.ok, replay.code)
        self.assertEqual(replay.data.charid, created.data.charid)
        self.assertEqual(self.e('#registered'), 1, 'no second framework character')
        self.assertTrue(self.call('characters:loaded', 1).ok)
        self.assertEqual(self.e('WCCharacters.active(1).charid'), created.data.charid)

    def test_completed_creation_on_the_last_slot_is_not_lost(self):
        self.rt.run('Config.Characters.defaultSlots = 3')
        token = self.call('characters:beginCreate', 1, 'male').data.token
        created = self.call('characters:create', 1, token, identity(self.rt), self.e('S.default("male")'))
        self.assertTrue(created.ok, created.code)
        self.later()
        again = self.call('characters:beginCreate', 1, 'male')
        self.assertTrue(again.ok, again.code)          # not CHARACTER_SLOT_LIMIT
        self.assertEqual(again.data.token, token)


class CreationSexLockTests(CharsBase):
    def test_provisioned_grant_keeps_and_reports_its_sex(self):
        token = self.call('characters:beginCreate', 1, 'male').data.token
        self.rt.run('FakeDB.transactionOk = false')
        r = self.call('characters:create', 1, token, identity(self.rt), self.e('S.default("male")'))
        self.assertEqual(r.code, 'DATABASE_ERROR')
        self.rt.run('FakeDB.transactionOk = true')
        self.later()
        again = self.call('characters:beginCreate', 1, 'female')
        self.assertTrue(again.ok, again.code)
        self.assertEqual(again.data.token, token)
        self.assertEqual(again.data.sex, 'male')
        # a design of the other sex is refused, never force-sanitised into a default look
        self.later()
        r = self.call('characters:create', 1, token, identity(self.rt), self.e('S.default("female")'))
        self.assertEqual(r.code, 'INVALID_PAYLOAD')
        self.later()
        r = self.call('characters:create', 1, token, identity(self.rt), self.e('S.default("male")'))
        self.assertTrue(r.ok, r.code)
        self.assertEqual(r.data.appearance.sex, 'male')
        self.assertEqual(self.e('#registered'), 1)

    def test_unprovisioned_grant_still_follows_the_picked_sex(self):
        token = self.call('characters:beginCreate', 1).data.token
        self.later()
        r = self.call('characters:beginCreate', 1, 'female')
        self.assertEqual(r.data.token, token)
        self.assertEqual(r.data.sex, 'female')


DEATH_OWNER_STARTED = r'''
ambulanceDead = {}
-- the CitizenFX export proxy shape: every member is function(self, ...) (the receiver is dropped)
rawset(exports, 'w_ambulancejob', { IsDead = function(self, src) return ambulanceDead[src or 0] == true end })
local baseState = GetResourceState
GetResourceState = function(name) if name == 'w_ambulancejob' then return 'started' end return baseState(name) end
'''


class DeadSwitchServerTests(CharsBase):
    def test_switch_refused_while_the_death_system_holds_a_living_player(self):
        self.select_and_load(1, 'vorp:1')
        self.rt.run(DEATH_OWNER_STARTED)
        self.rt.run('ambulanceDead[1] = true')           # hospital bed heal timer: ped alive
        self.assertEqual(self.e('dead[1]'), None)
        self.assertEqual(self.call('scene:prepare', 1).code, 'BUSY')
        self.assertEqual(self.call('characters:beginCreate', 1).code, 'BUSY')
        self.assertEqual(self.e('WCCharacters.active(1).charid'), 'vorp:1')
        self.rt.run('ambulanceDead[1] = false')
        self.later(11000)
        self.assertTrue(self.call('scene:prepare', 1).ok)

    def test_a_throwing_or_stopped_death_system_does_not_block(self):
        self.select_and_load(1, 'vorp:1')
        self.rt.run("rawset(exports, 'w_ambulancejob', { IsDead = function() error('boom') end })"
                    "; GetResourceState = function() return 'started' end")
        self.assertTrue(self.call('scene:prepare', 1).ok)


class DeadSwitchClientTests(unittest.TestCase):
    def test_client_refuses_before_the_fade(self):
        rt = make_characters(boot=False, setup='CallbackResults = { ["w_creators:characters:list"] = '
                                               'listResult({ card("1", "male") }, 3) }')
        rt.run('Peds[MyPed].visible = true; WCState.setCharacter("9", "male")')
        rt.run(DEATH_OWNER_STARTED)
        rt.run("WCSpawn = { busy = function() return false end, DEATH_OWNER = { resource = 'w_ambulancejob', "
               "revive = 'hospital:client:Revive', isDead = 'IsDead' } }; "
               "WCSpawnSelector = { active = function() return false end }")
        self.assertTrue(rt.eval('(WCSelector.canSwitch())'))
        rt.run('ambulanceDead[0] = true')
        self.assertFalse(rt.eval('(WCSelector.canSwitch())'))

    def test_spawn_declares_the_death_owner_export(self):
        from harness import RESOURCE
        src = (RESOURCE / 'client' / 'spawn' / 'spawn.lua').read_text(encoding='utf-8')
        self.assertIn("isDead = 'IsDead'", src)
        amb = RESOURCE.parent / 'w_ambulancejob' / 'client' / 'main.lua'
        if amb.exists():
            self.assertIn("exports('IsDead'", amb.read_text(encoding='utf-8'))


STORE = 'vector3(-326.17, 773.757, 117.5)'


class StoreBase(WorldBase):
    def open_store(self):
        self.activate()
        self.rt.run('WCSpawnServer.cancel(1); WCScene.toWorld(1); Players[1].coords = %s' % STORE)
        self.later()
        self.rt.run('s = WCSessions.open(1, "store", { locationId = "valentine_clothing" })')
        self.assertTrue(self.e('s.ok'))


class FittingRangeTests(StoreBase):
    def test_fitting_isolation_refused_away_from_the_store(self):
        self.open_store()
        self.rt.run('Players[1].coords = vector3(2000, 2000, 50)')
        r = self.call('scene:prepare', 1)
        self.assertFalse(r.ok)
        self.assertEqual(self.bucket(), 0)
        for event in ('w_creators:server:isolate', 'PersonaCreatorHandler.setPlayerRoutingBucket'):
            self.rt.run('fireEvent("%s", 1)' % event)
            self.assertEqual(self.bucket(), 0, event)

    def test_fitting_isolation_ends_when_the_player_walks_away(self):
        self.open_store()
        self.assertTrue(self.call('scene:prepare', 1).ok)
        self.assertEqual(self.bucket(), 1)
        self.rt.run('tick(WCScene.FITTING_CHECK_MS)')
        self.assertEqual(self.bucket(), 1, 'still at the store: kept')
        self.rt.run('Players[1].coords = vector3(2000, 2000, 50); tick(WCScene.FITTING_CHECK_MS)')
        self.assertEqual(self.bucket(), 0)
        self.assertFalse(self.e('WCScene.isIsolated(1)'))


class SessionCloseTests(StoreBase):
    def test_close_during_a_busy_commit_is_done_when_the_commit_fails(self):
        self.open_store()
        self.rt.run('''r = WCSessions.commit(1, s.data.token, "op-1", function(sess)
            closeAnswer = Callbacks["w_creators:session:close"](1, s.data.token)
            return WCResult.fail("DATABASE_ERROR")
        end)''')
        self.assertEqual(self.e('r.code'), 'DATABASE_ERROR')
        self.assertTrue(self.e('closeAnswer.ok'))
        self.assertIsNone(self.e('WCSessions.current(1)'))
        # the cached answer still serves a retry of that opId
        self.assertEqual(self.e('WCSessions.commit(1, s.data.token, "op-1", function() return WCResult.ok() end).code'),
                         'DATABASE_ERROR')

    def test_busy_commit_without_a_close_keeps_the_session(self):
        self.open_store()
        self.rt.run('r = WCSessions.commit(1, s.data.token, "op-1", function() return WCResult.fail("DATABASE_ERROR") end)')
        self.assertIsNotNone(self.e('WCSessions.current(1)'))

    def test_an_unused_session_is_replaced_by_a_new_open(self):
        self.open_store()
        old = self.e('s.data.token')
        self.later(1000)
        self.assertEqual(self.e('WCSessions.open(1, "store", { locationId = "valentine_clothing" }).code'), 'BUSY')
        self.later(self.e('WCSessions.REPLACE_UNUSED_MS'))
        self.rt.run('s2 = WCSessions.open(1, "store", { locationId = "valentine_clothing" })')
        self.assertTrue(self.e('s2.ok'), self.e('s2.code'))
        self.assertNotEqual(self.e('s2.data.token'), old)
        closed = [ev for ev in self.rt.client_events('w_creators:client:sessionClosed')]
        self.assertEqual(closed[-1].args[1], old)
        # a session the client used (it knows the token) is not replaced
        self.rt.run('WCSessions.get(1, s2.data.token)')
        self.later(self.e('WCSessions.REPLACE_UNUSED_MS'))
        self.assertEqual(self.e('WCSessions.open(1, "store", { locationId = "valentine_clothing" }).code'), 'BUSY')


class SessionResultServerTests(StoreBase):
    def test_result_is_read_only(self):
        self.open_store()
        # nothing recorded: never executes a commit
        self.assertEqual(self.call('session:result', 1, self.e('s.data.token'), 'op-9').code, 'SESSION_NOT_FOUND')
        self.assertIsNotNone(self.e('WCSessions.current(1)'))
        self.rt.run('WCSessions.commit(1, s.data.token, "op-1", function() return WCResult.ok({ appearance = { x = 1 } }) end)')
        r = self.call('session:result', 1, self.e('s.data.token'), 'op-1')
        self.assertTrue(r.ok)
        self.assertEqual(r.data.appearance.x, 1)


class UncertainCommitClientTests(unittest.TestCase):
    LOC = 'valentine_clothing'

    def setUp(self):
        self.rt = make_commerce()
        self.run = self.rt.run
        self.e = self.rt.eval
        self.run('CallbackResults = { ["w_creators:store:open"] = storeData(),'
                 ' ["w_creators:store:commit"] = function(_, token, opId) CommitOp = opId return fail("INTERNAL_ERROR") end }')
        self.run('R = table.pack(WCStore.open(%r))' % self.LOC)
        self.assertTrue(self.e('R[1]'))
        self.run('makeDirty(1.07); A = save()')
        self.assertEqual(self.e('A.code'), 'INTERNAL_ERROR')

    def cancel(self):
        self.run('CreateThread(function() cancel() end)')
        settle_commerce(self.rt)

    def test_a_committed_answer_is_taken_after_a_cancel(self):
        self.run('''CallbackResults["w_creators:session:result"] = function(_, token, opId)
            ResultAsk = { token = token, opId = opId }
            local app = AppearanceSchema.default("male"); app.body.height = 1.07
            return okResult({ appearance = app }) end''')
        self.cancel()
        self.assertEqual(self.e('ResultAsk.token'), 'stok')
        self.assertEqual(self.e('ResultAsk.opId'), self.e('CommitOp'))
        self.assertEqual(self.e('WCState.appearance.body.height'), 1.07)
        self.assertEqual(self.e('RestoreCalls[#RestoreCalls].body.height'), 1.07)
        # asked only after the session close, so nothing can commit any more
        self.assertLess(self.e('indexOf("callback:w_creators:session:close")'),
                        self.e('indexOf("callback:w_creators:session:result")'))
        self.assertIsNone(self.e('WCServiceFlow.current()'))

    def test_no_recorded_commit_keeps_the_saved_look(self):
        self.run('CallbackResults["w_creators:session:result"] = fail("SESSION_NOT_FOUND")')
        self.cancel()
        self.assertEqual(self.e('WCState.appearance.body.height'), 1.0)
        self.assertEqual(self.e('called("w_creators:appearance:reload")'), 0)

    def test_a_still_unknown_answer_reloads_the_saved_look(self):
        self.run('CallbackResults["w_creators:session:result"] = fail("BUSY")')
        self.run('''CallbackResults["w_creators:appearance:reload"] = (function()
            local app = AppearanceSchema.default("male"); app.body.height = 1.03
            return okResult({ appearance = app }) end)()''')
        self.cancel()
        self.assertEqual(self.e('called("w_creators:session:result")'), self.e('WCServiceFlow.RECONCILE_TRIES'))
        self.assertEqual(self.e('called("w_creators:appearance:reload")'), 1)
        self.assertEqual(self.e('WCState.appearance.body.height'), 1.03)


class SilentRefusalTests(unittest.TestCase):
    def setUp(self):
        self.rt = make_commerce()
        self.run = self.rt.run
        self.e = self.rt.eval

    def check(self, call):
        self.run('Notes = {}; R = table.pack(%s("bad id with spaces" .. string.rep("x", 80)))' % call)
        self.assertEqual(self.e('R[2]'), 'INVALID_PAYLOAD')
        self.assertTrue(self.e('noted(WCResult.messageKey("INVALID_PAYLOAD"))'))
        self.run('Notes = {}; WCState.busy("clothingAction", true); R = table.pack(%s("valentine_clothing"))' % call)
        self.assertEqual(self.e('R[2]'), 'BUSY')
        self.assertTrue(self.e('noted(WCResult.messageKey("BUSY"))'))
        self.run('WCState.busy("clothingAction", false); Notes = {}; Peds[MyPed].dead = true;'
                 ' R = table.pack(%s("valentine_clothing"))' % call)
        self.assertEqual(self.e('R[2]'), 'BUSY')
        self.assertEqual(self.e('#Notes'), 0, 'a dead player gets no BUSY message')

    def test_store_open_shows_its_refusals(self):
        self.check('WCStore.open')

    def test_wardrobe_open_shows_its_refusals(self):
        self.check('WCWardrobe.open')


class FittingHeadingTests(unittest.TestCase):
    def visit(self, end):
        rt = make_commerce()
        rt.run('Peds[MyPed].heading = 33.0')
        rt.run('CallbackResults = { ["w_creators:store:open"] = storeData(), '
               '["w_creators:store:commit"] = function(_, t, o, app) return okResult({ appearance = app }) end }')
        rt.run('R = table.pack(WCStore.open("valentine_clothing"))')
        self.assertTrue(rt.eval('R[1]'))
        self.assertEqual(rt.eval('Peds[MyPed].heading'), 90.0)     # on the fitting stand
        rt.run(end)
        settle_commerce(rt)
        self.assertIsNone(rt.eval('WCServiceFlow.current()'))
        self.assertEqual(rt.eval('Peds[MyPed].heading'), 33.0)

    def test_cancel_restores_the_shop_floor_heading(self):
        self.visit('cancel()')

    def test_commit_restores_the_shop_floor_heading(self):
        self.visit('makeDirty(1.05); save()')

    def test_death_restores_the_shop_floor_heading(self):
        self.visit('Peds[MyPed].dead = true')


DEGRADE = 'bad = S.default("male"); bad.head.head = 1; setSaved(bad)'


class DegradedServiceTests(unittest.TestCase):
    def setUp(self):
        self.rt = services_server()
        self.e = self.rt.eval
        self.rt.run('MoneyCalls = MoneyCalls or {}')

    def test_barber_open_refuses_a_degraded_appearance(self):
        self.rt.run(DEGRADE)
        self.rt.run('Clock.now = Clock.now + 11000; o = WCBarberService.open(1, "valentine_barber")')
        self.assertEqual(self.e('o.code'), 'INTERNAL_ERROR')
        self.assertIsNone(self.e('WCSessions.current(1)'))

    def test_barber_commit_refuses_before_charging(self):
        self.rt.run('Clock.now = Clock.now + 11000; o = WCBarberService.open(1, "valentine_barber"); token = o.data.token')
        self.assertTrue(self.e('o.ok'))
        self.rt.run(DEGRADE)
        self.rt.run('before = #MoneyCalls; app = WCUtil.copy(o.data.appearance); '
                    'app.hair.style = h("male", "hair", 3); c = WCBarberService.commit(1, token, "op", app)')
        self.assertEqual(self.e('c.code'), 'INTERNAL_ERROR')
        self.assertEqual(self.e('#MoneyCalls - before'), 0)
        self.assertEqual(self.e('FakeUsers[1].money'), 100)

    def surgery_open(self):
        self.rt.run('Players[1].coords = vector3(-284.49, 807.49, 119.38); FakeUsers[1].money = 1000;'
                    'Clock.now = Clock.now + 11000; WCSurgeryService.grant(1, "valentine_surgery");'
                    'o = WCSurgeryService.open(1, "valentine_surgery"); token = o.ok and o.data.token')

    def test_surgery_open_refuses_a_degraded_appearance_and_keeps_the_grant(self):
        self.rt.run(DEGRADE)
        self.surgery_open()
        self.assertEqual(self.e('o.code'), 'INTERNAL_ERROR')
        self.assertIsNone(self.e('WCSessions.current(1)'))
        self.assertTrue(self.e('WCSurgeryService.granted(1, "valentine_surgery")'))

    def test_surgery_commit_refuses_before_charging(self):
        self.surgery_open()
        self.assertTrue(self.e('o.ok'), self.e('o.code'))
        self.rt.run(DEGRADE)
        self.rt.run('before = #MoneyCalls; app = WCUtil.copy(o.data.appearance); app.morph.jawWidth = 0.5;'
                    'c = WCSurgeryService.commit(1, token, "op", app)')
        self.assertEqual(self.e('c.code'), 'INTERNAL_ERROR')
        self.assertEqual(self.e('#MoneyCalls - before'), 0)
        self.assertEqual(self.e('FakeUsers[1].money'), 1000)


TWO_CARDS = ('CallbackResults = { ["w_creators:characters:list"] = '
             'listResult({ card("1", "male"), card("2", "female") }, 3) }')


class LingeringIsolationTests(unittest.TestCase):
    def test_final_exit_still_releases_after_a_long_idle_in_the_room(self):
        rt = make_characters(setup=TWO_CARDS)
        rt.run('clearLog(); press("RETURN")')
        settle(rt)
        self.assertTrue(rt.eval('CreatorScene.isIsolated()'))
        settle(rt, 60000, 12, barrier=False)          # more than ten minutes still in the room
        self.assertTrue(rt.eval('CreatorScene.isIsolated()'))
        rt.run('Peds[MyPed].coords = vector3(-274.0, 785.0, 119.0)')
        settle(rt, 500, 3, barrier=False)
        self.assertFalse(rt.eval('CreatorScene.isIsolated()'))
        self.assertEqual(rt.eval('called("w_creators:scene:release")'), 1)
        self.assertNotEqual(rt.eval('WCServiceFlow and WCServiceFlow.blocked() or "none"'), 'scene')

    def test_spawn_arrival_clears_the_isolation_flag(self):
        from test_client_spawn_support import make_spawn_client
        rt = make_spawn_client()
        rt.run('CallbackResults = CallbackResults or {}; '
               'CallbackResults["w_creators:scene:prepare"] = WCResult.ok({ bucket = 1, reason = "selection" })')
        rt.run('CreateThread(function() Iso = table.pack(CreatorScene.isolate()) end)')
        rt.run('tick(0)')
        self.assertTrue(rt.eval('CreatorScene.isIsolated()'))
        rt.run('fireEvent("w_creators:client:spawn", nil, vector4(-274.0, 785.0, 119.0, 0.0), { kind = "login" })')
        self.assertFalse(rt.eval('CreatorScene.isIsolated()'))

    def test_event_spawn_mode_clears_the_isolation_flag(self):
        rt = make_characters(setup=TWO_CARDS)
        rt.run('CallbackResults["w_creators:characters:loaded"] = WCResult.ok({ spawn = "event" }); '
               'clearLog(); press("RETURN")')
        settle(rt)
        self.assertFalse(rt.eval('CreatorScene.isIsolated()'))


class RuntimeStateTests(unittest.TestCase):
    def setUp(self):
        self.rt = make_commerce()
        self.run = self.rt.run
        self.e = self.rt.eval
        self.run('''
            local cat = WCCatalog.forSex("male").neckwear
            local model = next(cat.models)
            Neck = cat.models[model][1].hash
            local app = AppearanceSchema.default("male")
            app.clothing.equipped.neckwear = Neck
            WCState.set(app)
            WCState.appearance.clothing.states.bandana = "up"      -- raised with /clothing
            local saved = AppearanceSchema.default("male")
            saved.clothing.equipped.neckwear = Neck                 -- the stored look: no runtime state
            StoredApp = saved
            StateDraws = {}
            local real = Appearance.ApplyClothingState
            Appearance.ApplyClothingState = function(ped, app, group, value)
                StateDraws[#StateDraws + 1] = { group = group, value = value }
                return true
            end
        ''')
        self.run('CallbackResults = { ["w_creators:wardrobe:open"] = wardrobeData({ appearance = StoredApp }) }')
        self.run('R = table.pack(WCWardrobe.open("valentine_wardrobe"))')
        self.assertTrue(self.e('R[1]'), self.e('R[2]'))

    def last_draw(self):
        return self.e('StateDraws[#StateDraws] and (StateDraws[#StateDraws].group .. "=" .. StateDraws[#StateDraws].value)')

    def test_cancel_draws_the_raised_bandana_again(self):
        self.run('StateDraws = {}; cancel()')
        settle_commerce(self.rt)
        self.assertIsNone(self.e('WCServiceFlow.current()'))
        self.assertEqual(self.last_draw(), 'bandana=up')
        self.assertEqual(self.e('WCState.appearance.clothing.states.bandana'), 'up')

    def test_death_draws_the_raised_bandana_again(self):
        self.run('StateDraws = {}; Peds[MyPed].dead = true')
        settle_commerce(self.rt)
        self.assertIsNone(self.e('WCServiceFlow.current()'))
        self.assertEqual(self.last_draw(), 'bandana=up')


class StaleSpawnGrantTests(unittest.TestCase):
    def setUp(self):
        self.rt = services_server()
        self.e = self.rt.eval

    def test_admin_respawn_withdraws_a_pending_in_world_grant(self):
        self.assertTrue(self.e('WCApi.OpenSpawnSelector(1).ok'))
        self.assertEqual(self.e('WCSpawnServer.pending(1)'), 'admin')
        r = self.e('WCApi.RespawnPlayer(1, "rhodes")')
        self.assertTrue(r.ok, r.code)
        self.assertIsNone(self.e('WCSpawnServer.pending(1)'))
        self.assertEqual(self.e('Callbacks["w_creators:spawn:choose"](1, "valentine").code'), 'SPAWN_NOT_PENDING')
        self.assertTrue(self.e('WCApi.OpenSpawnSelector(1).ok'))
        r = self.e('WCApi.RespawnPlayer(1, nil, "death")')
        self.assertTrue(r.ok, r.code)
        self.assertIsNone(self.e('WCSpawnServer.pending(1)'))

    def test_admin_respawn_refused_during_a_login_spawn_choice(self):
        self.rt.run('WCSpawnServer.grant(1, "login")')
        self.assertEqual(self.e('WCApi.RespawnPlayer(1, "rhodes").code'), 'BUSY')
        self.assertEqual(self.e('WCSpawnServer.pending(1)'), 'login')
        self.assertEqual(len(self.rt.client_events('w_creators:client:respawn')), 0)


class RespawnSelectorHoldTests(unittest.TestCase):
    def setUp(self):
        from test_client_spawn_support import make_spawn_client
        from test_client_spawn_flow import open_selector
        self.rt = make_spawn_client()
        self.rt.run('WCRespawn.reset(); clearLog()')
        open_selector(self.rt, kind='admin')
        self.assertTrue(self.rt.eval('WCSpawnSelector.holding()'))
        self.assertFalse(self.rt.eval('Peds[MyPed].visible'))

    def respawn(self):
        self.rt.run("fireEvent('w_creators:client:respawn', nil, { x = 5.0, y = 6.0, z = 7.0, heading = 10.0 }, "
                    "{ kind = 'admin', point = 'valentine' })")

    def assert_given_back(self):
        e = self.rt.eval
        self.assertFalse(e('WCSpawnSelector.holding()'))
        self.assertFalse(e('WCSpawnSelector.active()'))
        self.assertTrue(e('Peds[MyPed].visible'))
        self.assertFalse(e('Peds[MyPed].frozen'))
        self.assertFalse(e('Peds[MyPed].invincible'))

    def test_an_aborted_respawn_gives_the_held_player_back(self):
        from test_client_spawn_support import spin
        self.rt.run('''FakeFlow = { kind = 'store', committed = false, finished = false }
            WCServiceFlow = { current = function() return FakeFlow end, abort = function() return false end }''')
        self.respawn()
        spin(self.rt, 16000, 500)
        self.assertFalse(self.rt.eval('WCSpawn.busy()'))
        self.assert_given_back()

    def test_a_respawn_that_throws_before_closing_the_selector_gives_the_player_back(self):
        from test_client_spawn_support import spin
        self.rt.run('RealStartFade = StartFade; StartFade = function() error("boom") end')
        self.respawn()
        spin(self.rt, 1000)
        self.rt.run('StartFade = RealStartFade')
        c = self.rt.eval('Peds[MyPed].coords')
        self.assertNotEqual((c.x, c.y), (5.0, 6.0), 'the respawn failed before placing the player')
        self.assertFalse(self.rt.eval('WCSpawn.busy()'))
        self.assert_given_back()


CREATOR_BASE = ('CallbackResults = { ["w_creators:characters:list"] = listResult({}, 2), '
                '["w_creators:characters:beginCreate"] = WCResult.ok({ token = "tok-1" }) }')


class CreatorClientReplayTests(unittest.TestCase):
    def open_editor(self, setup=CREATOR_BASE):
        rt = make_characters(setup=setup)
        rt.run('press("RETURN")')
        settle(rt)
        rt.run('press("LEFT")')  # picking the man opens his editor at once
        settle(rt)
        self.assertEqual(rt.eval('WCCreator.stage()'), 'editor')
        return rt

    def test_cancel_after_a_created_but_unrendered_character_retries_the_finish(self):
        rt = self.open_editor()
        rt.run('''CallbackResults["w_creators:characters:create"] = function(_, token, identity, app)
            return WCResult.ok({ appearance = app, charid = "42" }) end
            RestoreFails = true; clearLog()
            saveResult = WCEditor.action({ id = WCEditor.session().id, op = "save", opId = "op-1",
                identity = { firstname = "John", lastname = "Smith", dob = "1990-05-01" } })''')
        settle(rt, 0, 5, barrier=False)
        self.assertEqual(rt.eval('saveResult.code'), 'INTERNAL_ERROR')
        rt.run('RestoreFails = false; clearLog(); r = WCEditor.action({ id = WCEditor.session().id, op = "cancel" })')
        settle(rt)
        e = rt.eval
        self.assertEqual(e('called("w_creators:characters:beginCreate")'), 0, 'no new creation')
        self.assertEqual(e('called("w_creators:characters:loaded")'), 1)
        self.assertEqual(e('WCState.character.charid'), '42')
        self.assertFalse(e('WCCreator.active()'))

    def test_the_servers_locked_sex_wins_over_the_design(self):
        # the server's sex decides: a grant locked to the man (a half-finished creation) never saves a
        # woman's design as a man; the sex is asked for at the save, and the man stays pickable
        rt = make_characters(setup=CREATOR_BASE)
        rt.run('press("RETURN")')
        settle(rt)
        rt.run('CallbackResults["w_creators:characters:beginCreate"] = WCResult.ok({ token = "tok-1", sex = "male" })')
        rt.run('press("RIGHT")')
        settle(rt, 0, 3, barrier=False)
        self.assertEqual(rt.eval('WCCreator.stage()'), 'editor')
        rt.run('''r = WCEditor.action({ id = WCEditor.session().id, op = "save", opId = "x",
            identity = { firstname = "Jane", lastname = "Smith", dob = "1990-05-01" } })''')
        settle(rt, 0, 5, barrier=False)
        self.assertFalse(rt.eval('r.ok'))
        self.assertEqual(rt.eval('callArgs("w_creators:characters:beginCreate", 2)[2]'), 'female')
        self.assertEqual(rt.eval('called("w_creators:characters:create")'), 0)
        rt.run('WCEditor.action({ id = WCEditor.session().id, op = "cancel" })')
        settle(rt, 0, 3, barrier=False)
        rt.run('press("LEFT")')
        settle(rt, 0, 3, barrier=False)
        self.assertEqual(rt.eval('WCCreator.stage()'), 'editor')
        self.assertEqual(rt.eval('WCEditor.session().saved.sex'), 'male')


if __name__ == '__main__':
    unittest.main()
