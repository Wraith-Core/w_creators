"""Review round 1 — server fixes (regressions for the confirmed server defects).

1  selection isolation is bound to the character room (no private-bucket ghost)
2  a login spawn never resets a bucket another resource set; a released scene drops its login grant
3  a store commit never makes worn-but-unowned clothing (API uniforms) owned
4  a restarted server resolves an untracked logged-in player instead of refusing scene:prepare
5  the death-owner export is called with the CitizenFX proxy receiver
6  a refused / failed framework deletion never deletes the appearance, clothes and outfits
7  legacy columns written by an older release after the v3 write are taken back (rollback)
8  SetClothes (and surgery clothing) settle the saved clothing states
9  the 'legacy' grants of a failed lazy upgrade join the next save
10 a degraded (defaults-filled) character is repaired through the creator
11/12 selection cards are read once and never cached
13 a fully grown character is not rewritten every save interval
"""
import json
import os
import sys
import unittest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from test_server_characters_flow import server_runtime, identity  # noqa: E402
from test_server_characters_world import ENTITIES  # noqa: E402
from test_server_commerce_store import commerce  # noqa: E402
from test_server_services_barber import services_server  # noqa: E402
from test_server_core import server as core_server  # noqa: E402

# The real CitizenFX export proxy: every member is function(self, ...) and the receiver is dropped.
CFX_EXPORTS = r'''
ambulanceDead = {}
local real = { w_medic = { IsDead = function(playerId) return ambulanceDead[playerId or 0] == true end } }
exports = setmetatable({}, { __index = function(_, resource)
    return setmetatable({}, { __index = function(_, name)
        local fn = real[resource] and real[resource][name]
        return function(self, ...) return fn(...) end
    end })
end })
local baseState = GetResourceState
GetResourceState = function(name) if name == 'w_medic' then return 'started' end return baseState(name) end
'''


class Flow(unittest.TestCase):
    def setUp(self):
        self.rt = server_runtime()
        self.rt.run(ENTITIES)
        self.e = self.rt.eval
        self.cb = self.e('cb')

    def call(self, name, src, *args):
        return self.cb(name, src, *args)

    def later(self, ms=11000):
        self.rt.run('Clock.now = Clock.now + %d' % ms)

    def bucket(self, src=1):
        return self.e('Players[%d].bucket' % src)

    def violations(self):
        return self.e('countLogs("security_violation")')

    def activate(self, src=1, charid='vorp:1'):
        self.assertTrue(self.call('characters:select', src, charid).ok)
        r = self.call('characters:loaded', src)
        self.assertTrue(r.ok, r.code)
        return r

    def in_world(self, where='vector3(1230.0, -1290.0, 76.0)'):
        """An active character spawned in the world, standing away from the character room."""
        self.activate()
        self.rt.run('WCSpawnServer.cancel(1); WCScene.toWorld(1); Players[1].coords = %s' % where)
        self.later()


# ---------------------------------------------------------------------------------------------
# 1  Selection isolation bound to the character room
# ---------------------------------------------------------------------------------------------
class SelectionRoomTests(Flow):
    def test_prepare_release_prepare_away_from_the_room_is_refused(self):
        self.in_world()
        r = self.call('scene:prepare', 1)                      # the switch's free isolation (then the teleport)
        self.assertTrue(r.ok, r.code)
        self.assertEqual(self.bucket(), 1)
        self.assertTrue(self.call('scene:release', 1).data.released)
        self.assertEqual(self.bucket(), 0)
        for hours in (1, 2, 3):                                # the reported ghost toggle
            self.later(hours * 3600 * 1000)
            r = self.call('scene:prepare', 1)
            self.assertEqual(r.code, 'TOO_FAR')
            self.assertEqual(self.bucket(), 0)
        self.assertEqual(self.violations(), 3)
        # the legacy events reach the same guard
        self.later()
        for event in ('w_creators:server:isolate', 'PersonaCreatorHandler.setPlayerRoutingBucket'):
            self.rt.run('fireEvent("%s", 1)' % event)
            self.assertEqual(self.bucket(), 0, event)
        # inside the room the flow may isolate again
        self.later()
        self.rt.run('Players[1].coords = anchor')
        self.assertTrue(self.call('scene:prepare', 1).ok)
        self.assertEqual(self.bucket(), 1)

    def test_a_player_who_never_reaches_the_room_is_returned_after_the_grace(self):
        self.in_world()
        self.rt.run('Players[1].bucket = 0')
        self.assertTrue(self.call('scene:prepare', 1).ok)
        self.rt.run('Clock.now = Clock.now + WCScene.ROOM_GRACE_MS - 1000; WCScene.check()')
        self.assertEqual(self.bucket(), 1, 'still within the teleport grace')
        self.rt.run('Clock.now = Clock.now + 2000; WCScene.check()')
        self.assertEqual(self.bucket(), 0)
        self.assertEqual(self.violations(), 1)
        self.assertFalse(self.e('WCScene.isIsolated(1)'))

    def test_leaving_the_room_releases_at_the_next_check_and_the_thread_runs_it(self):
        self.in_world()
        self.assertTrue(self.call('scene:prepare', 1).ok)
        self.rt.run('Players[1].coords = anchor; WCScene.check()')             # arrived: seen in the room
        self.rt.run('Players[1].coords = vector3(2645.0, -1300.0, 50.0)')       # ...and rides off
        self.rt.run('tick(WCScene.FITTING_CHECK_MS)')                            # the periodic pass
        self.assertEqual(self.bucket(), 0)
        self.assertEqual(self.violations(), 1)

    def test_first_login_select_without_loaded_is_room_bound_too(self):
        self.rt.run('Config.Characters.allowSwitch = false')
        self.assertTrue(self.call('scene:prepare', 1).ok)                        # first login, no character
        self.rt.run('Players[1].coords = anchor; WCScene.check()')
        self.assertTrue(self.call('characters:select', 1, 'vorp:1').ok)          # framework logs in; never loaded
        self.later()
        self.assertTrue(self.call('scene:release', 1).ok)
        self.rt.run('Players[1].coords = vector3(1230.0, -1290.0, 76.0)')
        self.later(3 * 3600 * 1000)
        self.assertEqual(self.call('scene:prepare', 1).code, 'TOO_FAR')
        self.assertEqual(self.bucket(), 0)

    def test_the_legitimate_flow_is_untouched(self):
        # first login: isolate, teleport, select, load, spawn selector (ped held in the room), spawn
        self.assertTrue(self.call('scene:prepare', 1).ok)
        self.rt.run('Players[1].coords = anchor')
        self.activate()
        for _ in range(20):
            self.rt.run('tick(WCScene.FITTING_CHECK_MS)')
        self.assertEqual(self.bucket(), 1, 'the spawn selector keeps the room and the bucket')
        self.later()
        self.assertTrue(self.call('spawn:choose', 1, 'valentine').ok)
        self.assertEqual(self.bucket(), 0)
        # mid-game /characters from anywhere in the world: a new flow, a new free isolation
        self.rt.run('Players[1].coords = vector3(-300.0, 790.0, 118.0)')
        self.later()
        self.assertTrue(self.call('scene:prepare', 1).ok)
        self.assertEqual(self.bucket(), 1)
        self.assertEqual(self.violations(), 0)


# ---------------------------------------------------------------------------------------------
# 2  Login spawns and foreign buckets
# ---------------------------------------------------------------------------------------------
class LoginSpawnBucketTests(Flow):
    def test_released_scene_withdraws_the_login_grant(self):
        self.rt.run('Config.Characters.allowSwitch = false')
        self.assertTrue(self.call('scene:prepare', 1).ok)
        self.rt.run('Players[1].coords = anchor')
        self.activate()
        self.assertEqual(self.e('WCSpawnServer.pending(1)'), 'login')
        self.later()
        self.assertTrue(self.call('scene:release', 1).data.released)
        self.assertIsNone(self.e('WCSpawnServer.pending(1)'))
        self.later(3600 * 1000)
        self.rt.run('Players[1].bucket = 50')                                    # jailed later
        self.assertEqual(self.call('spawn:choose', 1, 'valentine').code, 'SPAWN_NOT_PENDING')
        self.rt.run('fireEvent("w_creators:server:spawnAt", 1, "valentine")')
        self.assertEqual(self.bucket(), 50)
        # the admin / death respawn is no longer blocked by a stale grant
        self.assertTrue(self.e('WCSpawnServer.respawn(1, "valentine", "death").ok'))

    def test_login_spawn_keeps_a_bucket_another_resource_set(self):
        self.assertTrue(self.call('scene:prepare', 1).ok)
        self.rt.run('Players[1].coords = anchor')
        self.activate()
        self.rt.run('Players[1].bucket = 50')          # a jail / instance resource moved him meanwhile
        self.later()
        r = self.call('spawn:choose', 1, 'valentine')
        self.assertTrue(r.ok, r.code)
        self.assertEqual(self.bucket(), 50)
        self.assertEqual(len(self.rt.client_events('w_creators:client:spawn')), 1)

    def test_login_spawn_leaves_the_private_bucket_for_the_world(self):
        # the bucket w_creators set, the player's own private bucket, or already 0: bucket 0
        self.assertTrue(self.call('scene:prepare', 1).ok)
        self.rt.run('Players[1].coords = anchor')
        self.activate()
        self.later()
        self.assertTrue(self.call('spawn:choose', 1, 'valentine').ok)
        self.assertEqual(self.bucket(), 0)
        self.rt.run('Players[1].bucket = 1; WCScene.forget(1)')
        self.assertTrue(self.e('WCScene.toWorld(1)'))
        self.assertEqual(self.bucket(), 0)


# ---------------------------------------------------------------------------------------------
# 4  Restart: an untracked logged-in player
# ---------------------------------------------------------------------------------------------
class RestartRecoveryTests(Flow):
    def test_prepare_adopts_an_unadopted_player_without_a_violation(self):
        self.rt.run('charids[1] = "vorp:1"')              # logged in, the adoption pass has not reached him
        r = self.call('scene:prepare', 1)
        self.assertTrue(r.ok, r.code)
        self.assertEqual(r.data.reason, 'selection')
        self.assertTrue(self.e('WCCharacters.isSwitching(1)'))
        self.assertEqual(self.violations(), 0)
        self.assertTrue(self.call('characters:list', 1).ok)

    def test_a_character_without_an_appearance_row_gets_the_repair_flow(self):
        self.rt.run('charids[1] = "vorp:2"')              # no characters_appearence row
        for _ in range(3):
            r = self.call('scene:prepare', 1)
            self.assertTrue(r.ok, r.code)
            self.later()
        self.assertEqual(self.violations(), 0)
        self.assertTrue(self.e('WCCharacters.inFlow(1)'))
        r = self.call('characters:select', 1, 'vorp:2')
        self.assertTrue(r.ok, r.code)
        self.assertTrue(r.data.needsAppearance)

    def test_a_dead_player_is_still_refused(self):
        self.rt.run('charids[1] = "vorp:1"; dead[1] = true')
        self.assertEqual(self.call('scene:prepare', 1).code, 'BUSY')
        self.assertEqual(self.bucket(), 0)


# ---------------------------------------------------------------------------------------------
# 5  Death owner export through the CitizenFX proxy
# ---------------------------------------------------------------------------------------------
class DeathOwnerProxyTests(Flow):
    def test_the_player_id_reaches_the_export(self):
        self.activate()
        self.rt.run(CFX_EXPORTS)
        self.rt.run('ambulanceDead[1] = true')           # last stand / heal timer: the ped is alive
        self.assertTrue(self.e('exports.w_medic:IsDead(1)'))
        self.later()
        self.assertEqual(self.call('scene:prepare', 1).code, 'BUSY')
        self.assertEqual(self.e('WCCharacters.active(1).charid'), 'vorp:1')
        self.rt.run('ambulanceDead[1] = false')
        self.later()
        self.assertTrue(self.call('scene:prepare', 1).ok)


# ---------------------------------------------------------------------------------------------
# 6  Deletion on a refusing / asynchronous core
# ---------------------------------------------------------------------------------------------
RSG = r'''
Bridge.Name = 'rsg'
rsgAnswer, rsgRemoves = false, true
fakeRsg = {
    Functions = { GetPlayer = function() return nil end },
    Player = {
        DeleteCharacter = function(src, cid)
            if rsgRemoves and rsgAnswer ~= false then
                for _, list in pairs(owned) do
                    for i = #list, 1, -1 do if list[i].charid == cid then table.remove(list, i) end end
                end
            end
            return rsgAnswer
        end,
    },
}
w.framework = { getCore = function() return fakeRsg end }
function appearanceDeletes()
    local n = 0
    for _, tx in ipairs(FakeDB.transactions) do
        for _, q in ipairs(tx) do if q.query:find('DELETE FROM characters_appearence', 1, true) then n = n + 1 end end
    end
    return n
end
'''


class DeleteTests(Flow):
    def setUp(self):
        super().setUp()
        self.rt.run(RSG)

    def test_a_refusing_core_keeps_every_w_creators_row(self):
        r = self.call('characters:delete', 1, 'vorp:1')           # w_core: open loan / economy not ready
        self.assertEqual(r.code, 'DATABASE_ERROR')
        self.assertEqual(self.e('appearanceDeletes()'), 0)
        self.assertEqual(self.e('#owned[1]'), 2)

    def test_an_accepted_but_rolled_back_deletion_keeps_them_until_the_row_is_gone(self):
        self.rt.run('rsgAnswer, rsgRemoves = nil, false')          # upstream rsg: nil, then a rollback
        self.assertEqual(self.call('characters:delete', 1, 'vorp:1').code, 'DATABASE_ERROR')
        self.assertEqual(self.e('appearanceDeletes()'), 0)
        # the row disappears later (a slow asynchronous core): the retry finishes the cleanup only
        self.rt.run('table.remove(owned[1], 1)')
        self.later()
        self.assertTrue(self.call('characters:delete', 1, 'vorp:1').ok)
        self.assertEqual(self.e('appearanceDeletes()'), 1)
        self.assertEqual(self.e('countLogs("character_access_denied")'), 0)

    def test_an_accepting_core_deletes_after_the_row_is_gone(self):
        self.rt.run('rsgAnswer = true')
        self.assertTrue(self.call('characters:delete', 1, 'vorp:1').ok)
        self.assertEqual(self.e('appearanceDeletes()'), 1)

    def test_bridge_delete_character_respects_an_explicit_false(self):
        self.rt.run('ok1, stage1 = Bridge.DeleteCharacter(1, "vorp:1")')
        self.assertEqual((self.e('ok1'), self.e('stage1')), (False, 'framework'))
        self.assertEqual(self.e('appearanceDeletes()'), 0)


# ---------------------------------------------------------------------------------------------
# 10 Degraded characters are repaired explicitly
# ---------------------------------------------------------------------------------------------
class DegradedRepairTests(Flow):
    def setUp(self):
        super().setUp()
        self.rt.run(r'''
            broken = S.default('male')
            broken.head.head = 12345                                   -- unknown to the catalogue
            broken.clothing.equipped.hats = WCCatalog.forSex('male').hats.models[1][1].hash
            rows['vorp:2'] = { id = 12, charid = 'vorp:2', isMale = 1, appearance = json.encode(broken), appearance_version = 3 }
        ''')

    def test_select_offers_the_repair_and_create_saves_it(self):
        r = self.call('characters:select', 1, 'vorp:2')
        self.assertTrue(r.ok, r.code)
        self.assertTrue(r.data.needsAppearance)
        self.assertEqual(r.data.sex, 'male')
        self.assertEqual(list(r.data.degraded.values()), ['face'])
        self.assertEqual(r.data.appearance.sex, 'male')
        token = r.data.token
        self.rt.run('fixed = S.default("male"); fixed.clothing.equipped = {}')
        self.later()
        r = self.call('characters:create', 1, token, None, self.e('fixed'))
        self.assertTrue(r.ok, r.code)
        self.assertEqual(r.data.charid, 'vorp:2')
        self.assertEqual(r.data.appearance.head.head, self.e('fixed.head.head'))
        # the clothing is kept as saved (the creator's starting clothing never replaces it)
        self.assertEqual(r.data.appearance.clothing.equipped.hats, self.e('broken.clothing.equipped.hats'))
        tx = self.e('FakeDB.transactions[#FakeDB.transactions]')
        self.assertIn('UPDATE characters_appearence SET appearance', tx[1].query)
        self.assertEqual(self.e('#FakeDB.transactions'), 1, 'saved in place, no second row')
        self.assertIsNone(self.e('WCAppearanceRepo.degraded("vorp:2")'))
        r = self.call('characters:loaded', 1)
        self.assertTrue(r.ok, r.code)
        self.assertEqual(self.e('WCCharacters.active(1).charid'), 'vorp:2')

    def test_a_healthy_character_is_selected_as_before(self):
        r = self.call('characters:select', 1, 'vorp:1')
        self.assertTrue(r.ok, r.code)
        self.assertIsNone(r.data.needsAppearance)


# ---------------------------------------------------------------------------------------------
# 11/12 Selection cards
# ---------------------------------------------------------------------------------------------
class CardTests(Flow):
    def test_cards_are_read_once_and_not_cached(self):
        self.rt.run("rows['vorp:2'] = { id = 12, charid = 'vorp:2', name = 'Jane Doe', age = 25, isMale = 0, "
                    "appearance = json.encode(S.default('female')), appearance_version = 3 }")
        r = self.call('characters:list', 1)
        self.assertTrue(r.ok, r.code)
        self.assertEqual(len(r.data.characters), 2)
        self.assertEqual(self.e('FakeDB.count("SELECT name, age, isMale")'), 0)
        self.assertEqual(self.e('FakeDB.count("SELECT %* FROM characters_appearence")'), 2)
        self.assertIsNone(self.e('WCAppearanceRepo.cache["vorp:1"]'))
        self.assertIsNone(self.e('WCAppearanceRepo.cache["vorp:2"]'))
        # the stored fallbacks still come from that one read
        self.rt.run('fwRows = {}')
        self.later()
        r = self.call('characters:list', 1)
        cards = {c.charid: c for c in r.data.characters.values()}
        self.assertEqual(cards['vorp:2'].age, 25)
        self.assertEqual(cards['vorp:2'].sex, 'female')
        # a selected character is cached for play; dropping at the selection leaves nothing behind
        self.later()
        self.activate()
        self.assertIsNotNone(self.e('WCAppearanceRepo.cache["vorp:1"]'))
        self.rt.run('fireEvent("playerDropped", 1); tick(0)')
        self.assertIsNone(self.e('WCAppearanceRepo.cache["vorp:2"]'))

    def test_a_selected_but_never_loaded_character_leaves_the_cache(self):
        self.rt.run("rows['vorp:2'] = { id = 12, charid = 'vorp:2', isMale = 0, "
                    "appearance = json.encode(S.default('female')), appearance_version = 3 }")
        self.assertTrue(self.call('characters:select', 1, 'vorp:1').ok)
        self.assertIsNotNone(self.e('WCAppearanceRepo.cache["vorp:1"]'))
        self.later()
        self.assertTrue(self.call('characters:select', 1, 'vorp:2').ok)          # changed his mind
        self.assertIsNone(self.e('WCAppearanceRepo.cache["vorp:1"]'))
        self.rt.run('fireEvent("playerDropped", 1); tick(0)')                   # quits at the selection
        self.assertIsNone(self.e('WCAppearanceRepo.cache["vorp:2"]'))


# ---------------------------------------------------------------------------------------------
# 3  Store commits and worn-but-unowned clothing
# ---------------------------------------------------------------------------------------------
class StoreUniformTests(unittest.TestCase):
    def setUp(self):
        self.rt = commerce()
        self.e = self.rt.eval
        self.rt.run(r'''
            uniform = h('male', 'hats', 2)                   -- applied by a job resource (SetClothes)
            boots = h('male', 'boots', 1)
            base = S.default('male'); base.clothing.equipped.hats = uniform; base.clothing.equipped.boots = boots
            own('vorp:1', 'boots', boots, nil, 'legacy')
            setSaved('vorp:1', base)
            r = openStore(); storeToken = r.data.token
        ''')
        self.assertTrue(self.e('r.ok'))

    def test_a_free_commit_does_not_grant_the_uniform(self):
        self.rt.run('a = working(); a.clothing.equipped.boots = nil; res = buy(a)')
        self.assertTrue(self.e('res.ok'), self.e('res.code'))
        self.assertEqual(self.e('res.data.charged'), 0)
        self.assertIsNone(self.e('ownedRow("vorp:1", uniform)'))
        grants = [q.query for tx in self.e('FakeDB.transactions').values() for q in tx.values()
                  if 'w_creators_clothes' in q.query]
        self.assertEqual(grants, [])

    def test_dyeing_an_unowned_worn_item_is_a_purchase(self):
        self.rt.run('''
            a = working()
            a.clothing.tints.hats = { palette = 'metaped_tint_hat', tint0 = 1, tint1 = 2, tint2 = 3 }
            res = buy(a)
        ''')
        self.assertTrue(self.e('res.ok'), self.e('res.code'))
        self.assertEqual(self.e('res.data.charged'), 6.0)                 # the item + the dye
        self.assertEqual(self.e('ownedRow("vorp:1", uniform).source'), 'store')

    def test_dyeing_an_unowned_item_the_store_does_not_sell_is_refused(self):
        self.rt.run('''
            local available = WCCatalog.available
            WCCatalog.available = function(p, sex, c, hash)
                if WCUtil.u32(hash) == WCUtil.u32(uniform) then return false end
                return available(p, sex, c, hash)
            end
            a = working()
            a.clothing.tints.hats = { palette = 'metaped_tint_hat', tint0 = 1, tint1 = 2, tint2 = 3 }
            res = buy(a)
        ''')
        self.assertEqual(self.e('res.code'), 'COMPONENT_NOT_AVAILABLE')
        self.assertIsNone(self.e('ownedRow("vorp:1", uniform)'))


# ---------------------------------------------------------------------------------------------
# 8  SetClothes / surgery settle the clothing states
# ---------------------------------------------------------------------------------------------
class StatesSettleTests(unittest.TestCase):
    def setUp(self):
        self.rt = services_server()
        self.e = self.rt.eval
        self.rt.run(r'''
            hatX, hatY = h('male', 'hats', 1), h('male', 'hats', 2)
            base = S.default('male'); base.clothing.equipped.hats = hatX; base.clothing.states = { hat = 'off' }
            setSaved(base)
        ''')
        self.assertEqual(self.e('WCAppearanceRepo.load("vorp:1").clothing.states.hat'), 'off')

    def test_removed_then_new_item_starts_visible(self):
        self.assertTrue(self.e('WCApi.SetClothes(1, { hats = 0 }).ok'))
        self.assertIsNone(self.e('lastSaved().clothing.states.hat'))
        self.rt.run('Clock.now = Clock.now + 11000')
        self.assertTrue(self.e('WCApi.SetClothes(1, { hats = hatY }).ok'))
        self.assertEqual(self.e('lastSaved().clothing.equipped.hats'), self.e('hatY'))
        self.assertIsNone(self.e('lastSaved().clothing.states.hat'))

    def test_a_direct_swap_drops_the_state_and_an_untouched_item_keeps_it(self):
        self.assertTrue(self.e('WCApi.SetClothes(1, { boots = h("male", "boots", 1) }).ok'))
        self.assertEqual(self.e('lastSaved().clothing.states.hat'), 'off')
        self.rt.run('Clock.now = Clock.now + 11000')
        self.assertTrue(self.e('WCApi.SetClothes(1, { hats = hatY }).ok'))
        self.assertIsNone(self.e('lastSaved().clothing.states.hat'))

    def test_surgery_with_clothing_settles_the_states(self):
        self.rt.run(r'''
            Config.CosmeticSurgery.allow.clothing = true
            saved = WCAppearanceRepo.load('vorp:1')
            sub = WCUtil.copy(saved); sub.clothing.equipped.hats = hatY
            owned = { [WCOwnership.key(hatY)] = { category = 'hats' } }
            plan, code = WCSurgeryService.plan(saved, sub, { price = 10 }, owned)
        ''')
        self.assertIsNotNone(self.e('plan'), self.e('code'))
        self.assertIsNone(self.e('plan.merged.clothing.states.hat'))


# ---------------------------------------------------------------------------------------------
# 13 Grooming at the last stage
# ---------------------------------------------------------------------------------------------
class GroomingSteadyStateTests(unittest.TestCase):
    def test_a_fully_grown_character_is_not_rewritten(self):
        rt = services_server()
        rt.run(r'''
            Config.Grooming.enabled = true -- growth ships off; this covers the feature
            Config.Grooming.saveIntervalSeconds = 300
            Config.Grooming.minutesPerStage.hair = 1; Config.Grooming.minutesPerStage.beard = 1
            function step(seconds) Clock.now = Clock.now + seconds * 1000; WCGroomingServer.tick() end
            function saves()
                local n = 0
                for _, tx in ipairs(FakeDB.transactions) do
                    if tx[1] and tx[1].query:find('UPDATE characters_appearence SET appearance', 1, true) then n = n + 1 end
                end
                return n
            end
            step(0)
            for _ = 1, 12 do step(30) end                               -- 6 min: every kind at its last stage
        ''')
        grown = rt.eval('lastSaved()')
        self.assertIsNotNone(grown)
        rt.run('before = saves(); snapshot = json.encode(lastSaved())')
        rt.run('for _ = 1, 120 do step(30) end')                         # one hour online
        self.assertEqual(rt.eval('saves()'), rt.eval('before'))
        self.assertEqual(rt.eval('json.encode(lastSaved())'), rt.eval('snapshot'))
        self.assertLess(rt.eval('WCGroomingServer.pending(1).seconds'), 300)


# ---------------------------------------------------------------------------------------------
# 7 / 9  Repository: rollback reconciliation, owed legacy grants
# ---------------------------------------------------------------------------------------------
STORE_ROW = r'''
-- the fake row follows the writes (the UPDATE of a save, the JSON-only UPDATE of load paths)
local rawTx = w.database.transaction.await
w.database.transaction.await = function(queries)
    local done = rawTx(queries)
    if done ~= true then return done end
    for _, q in ipairs(queries) do
        local v = q.query:find('UPDATE characters_appearence SET appearance', 1, true) and q.values
        if v then
            local row = rows['vorp:1']
            row.appearance, row.appearance_version = v[1], v[2]
            if q.query:find('components = ?', 1, true) then
                row.isMale, row.components, row.faceFeatures, row.overlays = v[3], v[4], v[5], v[6]
            end
        end
    end
    return done
end
hat, boots = h('male', 'hats', 1), h('male', 'boots', 1)
'''


class RollbackTests(unittest.TestCase):
    def setUp(self):
        self.rt = core_server()
        self.rt.load('server/clothing/ownership.lua')
        self.rt.run(STORE_ROW)
        self.e = self.rt.eval
        self.rt.run(r'''
            v3 = S.default('male')
            v3.clothing.equipped.boots = boots
            v3.clothing.tints.boots = { palette = 'metaped_tint_leather', tint0 = 1, tint1 = 2, tint2 = 3 }
            v3.clothing.outfit = 4
            assert(WCAppearanceRepo.save('vorp:1', v3))
            WCAppearanceRepo.invalidate('vorp:1')
        ''')

    def writes(self):
        return self.e('#FakeDB.transactions')

    def test_an_untouched_v3_row_is_trusted(self):
        n = self.writes()
        self.rt.run('app, meta = WCAppearanceRepo.load("vorp:1")')
        self.assertFalse(self.e('meta.reconciled'))
        self.assertEqual(self.writes(), n)
        self.assertEqual(self.e('app.clothing.outfit'), 4)

    def test_changes_written_by_an_older_release_are_taken_back(self):
        # the pre-v3 barber / store: UPDATE characters_appearence SET components = ? (JSON re-encoded)
        self.rt.run(r'''
            comps = json.decode(rows['vorp:1'].components)
            newHair = WCCatalog.forSex('male').hair.models[2][1].hash
            comps.hair, comps.hats = newHair, hat
            rows['vorp:1'].components = json.encode(comps)
            app, meta = WCAppearanceRepo.load('vorp:1')
        ''')
        self.assertTrue(self.e('meta.reconciled'))
        self.assertEqual(self.e('app.hair.style'), self.e('newHair'))
        self.assertEqual(self.e('app.clothing.equipped.hats'), self.e('hat'))
        self.assertEqual(self.e('app.clothing.tints.boots.tint1'), 2, 'the tint of an item still worn is kept')
        self.assertIsNone(self.e('app.clothing.outfit'), 'the worn set changed: no longer the outfit')
        stored = json.loads(self.e('rows["vorp:1"].appearance'))
        self.assertEqual(stored['hair']['style'], self.e('newHair'))
        # written back: the next load trusts the JSON again, and a v3 save keeps the new look
        n = self.writes()
        self.rt.run('WCAppearanceRepo.invalidate("vorp:1"); app2, meta2 = WCAppearanceRepo.load("vorp:1")')
        self.assertFalse(self.e('meta2.reconciled'))
        self.assertEqual(self.writes(), n)
        self.assertTrue(self.e('WCAppearanceRepo.save("vorp:1", app2)'))
        self.assertEqual(json.loads(self.e('rows["vorp:1"].components'))['hair'], self.e('newHair'))

    def test_a_rebuild_that_needs_defaults_keeps_the_v3_json(self):
        self.rt.run(r'''
            comps = json.decode(rows['vorp:1'].components)
            comps.heads = 12345
            rows['vorp:1'].components = json.encode(comps)
            app, meta = WCAppearanceRepo.load('vorp:1')
        ''')
        self.assertFalse(self.e('meta.reconciled'))
        self.assertFalse(self.e('meta.degraded'))
        self.assertEqual(self.e('app.clothing.outfit'), 4)

    def test_a_lazily_upgraded_row_is_not_mistaken_for_a_rollback(self):
        # §6.2 writes only the JSON: the legacy columns keep their pre-v3 text (e.g. an item no longer
        # in the catalogue) and never match toLegacy(v3) — the fingerprint is the row's own.
        self.rt.run(r'''
            rows['vorp:1'] = { id = 11, charid = 'vorp:1', isMale = 1, faceFeatures = '[]', overlays = '[]',
                               components = json.encode({ heads = h('male', 'heads', 2, 1), eyes = h('male', 'eyes', 1, 2),
                                   teeth = h('male', 'teeth', 1, 1), BODIES_UPPER = h('male', 'BODIES_UPPER', 1, 1),
                                   coats = 99999, __version = 2 }),
                               appearance = nil, appearance_version = 2 }
            WCAppearanceRepo.invalidate('vorp:1')
            a1, m1 = WCAppearanceRepo.load('vorp:1')
            WCAppearanceRepo.invalidate('vorp:1')
            a2, m2 = WCAppearanceRepo.load('vorp:1')
        ''')
        self.assertTrue(self.e('m1.upgraded'))
        self.assertEqual(self.e('m2.version'), 3)
        self.assertFalse(self.e('m2.reconciled'))

    def test_the_fingerprint_never_reaches_the_appearance(self):
        self.rt.run('app = WCAppearanceRepo.load("vorp:1")')
        self.assertIsNone(self.e('app.projection'))
        self.assertIn('projection', json.loads(self.e('rows["vorp:1"].appearance')))


class OwedLegacyGrantTests(unittest.TestCase):
    def test_a_failed_upgrade_write_hands_its_grants_to_the_next_save(self):
        rt = core_server()
        e = rt.eval
        rt.run(r'''
            comps = { heads = h("male", "heads", 2, 1), eyes = h("male", "eyes", 1, 2), teeth = h("male", "teeth", 1, 1),
                      BODIES_UPPER = h("male", "BODIES_UPPER", 1, 1), hats = h("male", "hats", 1, 1),
                      boots = h("male", "boots", 2, 1), __version = 2 }
            rows["vorp:1"] = { id = 11, charid = "vorp:1", isMale = 1, components = json.encode(comps),
                               faceFeatures = "[]", overlays = "[]", appearance = nil, appearance_version = 2 }
            FakeDB.transactionOk = false
            app, meta = WCAppearanceRepo.load("vorp:1")
            FakeDB.transactionOk = true
            app.clothing.equipped.hats = nil                           -- the first save takes the hat off
            ok1 = WCAppearanceRepo.save("vorp:1", app)
            tx1 = FakeDB.transactions[#FakeDB.transactions]
            ok2 = WCAppearanceRepo.save("vorp:1", app)
            tx2 = FakeDB.transactions[#FakeDB.transactions]
        ''')
        self.assertFalse(e('meta.upgraded'))
        self.assertTrue(e('ok1'))
        grants = sorted(q['values'][3] for q in e('tx1').values() if "'legacy'" in q.query)
        self.assertEqual(grants, ['boots', 'hats'], 'the loaded pre-v3 outfit, not the saved one')
        self.assertTrue(e('ok2'))
        self.assertEqual(len(e('tx2')), 1, 'granted once')

    def test_a_failed_save_keeps_them_owed(self):
        rt = core_server()
        e = rt.eval
        rt.run(r'''
            comps = { heads = h("male", "heads", 2, 1), eyes = h("male", "eyes", 1, 2), teeth = h("male", "teeth", 1, 1),
                      BODIES_UPPER = h("male", "BODIES_UPPER", 1, 1), hats = h("male", "hats", 1, 1), __version = 2 }
            rows["vorp:1"] = { id = 11, charid = "vorp:1", isMale = 1, components = json.encode(comps),
                               faceFeatures = "[]", overlays = "[]", appearance = nil, appearance_version = 2 }
            FakeDB.transactionOk = false
            app = WCAppearanceRepo.load("vorp:1")
            okA = WCAppearanceRepo.save("vorp:1", app)
            FakeDB.transactionOk = true
            okB = WCAppearanceRepo.save("vorp:1", app)                -- straight after the failed save
            txB = FakeDB.transactions[#FakeDB.transactions]
        ''')
        self.assertFalse(e('okA'))
        self.assertTrue(e('okB'))
        self.assertEqual([q['values'][3] for q in e('txB').values() if "'legacy'" in q.query], ['hats'])


# ---------------------------------------------------------------------------------------------
# (client round 1 dependency) w_creators:session:abandon closes only an unused session
# ---------------------------------------------------------------------------------------------
class SessionAbandonTests(unittest.TestCase):
    def test_only_an_unused_idle_session_is_abandoned(self):
        rt = core_server()
        e = rt.eval
        rt.run('closed = {}; WCSessions.onClose(function(s, reason) closed[#closed + 1] = reason end)')
        rt.run('r = WCSessions.open(1, "store", { locationId = "valentine_clothing" }); token = r.data.token')
        self.assertTrue(e('r.ok'))
        r = e('Callbacks["w_creators:session:abandon"](1)')
        self.assertTrue(r.ok)
        self.assertTrue(r.data.closed)
        self.assertIsNone(e('WCSessions.current(1)'))
        self.assertEqual(list(e('closed').values()), ['abandoned'])
        # a session whose token the client used is never closed this way
        rt.run('Clock.now = Clock.now + 11000; r = WCSessions.open(1, "store", { locationId = "valentine_clothing" })')
        rt.run('WCSessions.get(1, r.data.token)')
        r = e('Callbacks["w_creators:session:abandon"](1)')
        self.assertFalse(r.data.closed)
        self.assertIsNotNone(e('WCSessions.current(1)'))
        self.assertFalse(e('Callbacks["w_creators:session:abandon"](2).data.closed'))


if __name__ == '__main__':
    unittest.main()
