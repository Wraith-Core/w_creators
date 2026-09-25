"""w_core's character purge: WCCharacters.purge / exports.w_creators:PurgeCharacter
(server/characters/characters.lua, server/appearance/repository.lua, server/api.lua).

A deleted character's citizen id can be handed to another character, so the purge must leave
nothing: no row, no cached look, no owed 'legacy' grant, no pending flow or cleanup naming it.
"""
import os
import sys
import unittest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from harness import RESOURCE, read
from test_server_characters_flow import server_runtime

PURGE = r'''
-- the three tables, counted and deleted by charid
store = {
    characters_appearence = { ['12'] = 1, ['777'] = 1 },
    w_creators_clothes = { ['12'] = 5, ['777'] = 3 },
    w_creators_outfits = { ['12'] = 2 },
    w_creators_colorways = { ['12'] = 4 },
}
rows['12'] = { id = 12, charid = '12', name = 'Arthur Morgan', age = 36, isMale = 1,
               appearance = json.encode(S.default('male')), appearance_version = 3 }
rows['777'] = { id = 77, charid = '777', isMale = 1, appearance = json.encode(S.default('male')), appearance_version = 3 }
FakeDB.on('SELECT %(SELECT COUNT%(%*%) FROM characters_appearence', function(sql, params)
    return { appearance = store.characters_appearence[params[1]] or 0,
             clothes = store.w_creators_clothes[params[2]] or 0,
             outfits = store.w_creators_outfits[params[3]] or 0,
             colorways = store.w_creators_colorways[params[4]] or 0 }
end)
local realTx = w.database.transaction.await
w.database.transaction.await = function(queries)
    local done = realTx(queries)
    if done == true then
        for _, q in ipairs(queries) do
            local t = q.query:match('^DELETE FROM ([%w_]+) WHERE charid = %?$')
            if t and store[t] then store[t][q.values[1]] = nil end
            if t == 'characters_appearence' then rows[q.values[1]] = nil end
        end
    end
    return done
end
function deletesOf(charid)
    local n = 0
    for _, tx in ipairs(FakeDB.transactions) do
        for _, q in ipairs(tx) do
            if q.query:find('^DELETE FROM') and q.values[1] == charid then n = n + 1 end
        end
    end
    return n
end
function purge(id, ctx)
    local ok, detail = WCCharacters.purge(id, ctx or { by = 'staff', at = 1700000000, tombstone = 'deleted-12-1700000000' })
    return { ok = ok, detail = detail }
end
'''


class PurgeBase(unittest.TestCase):
    def setUp(self):
        self.rt = server_runtime()
        self.rt.run(PURGE)
        self.e = self.rt.eval
        self.cb = self.e('cb')

    def call(self, name, src, *args):
        return self.cb(name, src, *args)

    def later(self, ms=11000):
        self.rt.run('Clock.now = Clock.now + %d' % ms)

    def purge(self, charid="'12'"):
        return self.e('purge(%s)' % charid)


class PurgeRowsTests(PurgeBase):
    def test_purge_deletes_every_row_and_reports_the_counts(self):
        self.rt.run('WCAppearanceRepo.load("12")')
        self.assertIsNotNone(self.e('WCAppearanceRepo.cache["12"]'))
        r = self.purge()
        self.assertTrue(r.ok, r.detail)
        self.assertEqual(self.rt.py(r.detail), {'characters_appearence': 1, 'w_creators_clothes': 5,
                                                'w_creators_outfits': 2, 'w_creators_colorways': 4})
        tx = self.e('FakeDB.transactions[#FakeDB.transactions]')
        self.assertEqual([q.query for q in tx.values()], [
            'DELETE FROM characters_appearence WHERE charid = ?',
            'DELETE FROM w_creators_clothes WHERE charid = ?',
            'DELETE FROM w_creators_colorways WHERE charid = ?',
            'DELETE FROM w_creators_outfits WHERE charid = ?'])
        self.assertEqual({q['values'][1] for q in tx.values()}, {'12'})
        self.assertIsNone(self.e('WCAppearanceRepo.cache["12"]'))
        self.assertIsNone(self.e('store.w_creators_clothes["12"]'))
        # another number is untouched
        self.assertEqual(self.e('store.w_creators_clothes["777"]'), 3)
        self.assertEqual(self.e('deletesOf("777")'), 0)

    def test_purge_is_idempotent(self):
        self.assertTrue(self.purge().ok)
        r = self.purge()
        self.assertTrue(r.ok, r.detail)
        self.assertEqual(self.rt.py(r.detail), {'characters_appearence': 0, 'w_creators_clothes': 0,
                                                'w_creators_outfits': 0, 'w_creators_colorways': 0})

    def test_an_integer_id_is_its_digits_and_a_malformed_id_is_refused_untouched(self):
        self.assertTrue(self.purge('12').ok)
        self.assertEqual(self.e('deletesOf("12")'), 4)   # + the owned colours (colourways)
        before = self.e('#FakeDB.transactions')
        for bad in ('nil', "''", "'7 77'", "'77\\n7'", "string.rep('1', 65)", '1.5', '{}'):
            r = self.purge(bad)
            self.assertFalse(r.ok, bad)
            self.assertEqual(r.detail, 'invalid_id', bad)
        self.assertEqual(self.e('#FakeDB.transactions'), before)

    def test_a_database_failure_is_reported_and_retried_safely(self):
        self.rt.run('FakeDB.transactionOk = false')
        r = self.purge()
        self.assertEqual((r.ok, r.detail), (False, 'database'))
        self.assertEqual(self.e('store.w_creators_clothes["12"]'), 5)
        self.assertIsNone(self.e('CreatorAppearanceLocks["12"]'))
        self.assertFalse(self.e('WCSecurity.locked("outfits:12")'))
        self.rt.run('FakeDB.transactionOk = true')
        self.assertTrue(self.purge().ok)
        self.assertIsNone(self.e('store.w_creators_clothes["12"]'))

    def test_a_count_failure_changes_nothing(self):
        self.rt.run('FakeDB.fail = "SELECT %(SELECT COUNT"')
        r = self.purge()
        self.assertEqual((r.ok, r.detail), (False, 'database'))
        self.assertEqual(self.e('#FakeDB.transactions'), 0)

    def test_the_export_is_registered(self):
        api = read(RESOURCE / 'server' / 'api.lua')
        self.assertIn("'PurgeCharacter'", api)
        self.assertIn('function Api.PurgeCharacter(citizenid, ctx)', api)
        # w_core's contract: the handler refuses any other caller first
        body = api.split('function Api.PurgeCharacter(citizenid, ctx)', 1)[1].lstrip()
        self.assertTrue(body.startswith("if GetInvokingResource() ~= 'w_core' then return false, 'forbidden' end"))


class PurgeInUseTests(PurgeBase):
    def test_a_character_in_play_is_refused_until_its_player_left(self):
        self.rt.run('charids[1] = "12"; WCCharacters.setActive(1, "12", "male")')
        r = self.purge()
        self.assertEqual((r.ok, r.detail), (False, 'online'))
        self.assertEqual(self.e('#FakeDB.transactions'), 0)
        self.assertIsNone(self.e('CreatorAppearanceLocks["12"]'))
        # kicked by w_core: the player is gone
        self.rt.run('Players[1] = nil')
        self.assertTrue(self.purge().ok)

    def test_a_selected_character_logged_in_is_refused(self):
        self.rt.run('owned[1][#owned[1] + 1] = { charid = "12", name = "Arthur Morgan" }')
        r = self.call('characters:select', 1, '12')
        self.assertTrue(r.ok, r.code)
        self.assertEqual(self.purge().detail, 'online')
        self.assertEqual(self.e('#FakeDB.transactions'), 0)

    def test_a_writer_holding_the_lock_past_the_wait_refuses_busy_untouched(self):
        self.rt.run('WCSessions.lockCharacter("12", "writer")')
        r = self.purge()
        self.assertEqual((r.ok, r.detail), (False, 'busy'))
        self.assertEqual(self.e('#FakeDB.transactions'), 0)
        self.assertEqual(self.e('CreatorAppearanceLocks["12"]'), 'writer')     # never taken from it
        self.rt.run('WCSessions.unlockCharacter("12", "writer")')
        self.assertTrue(self.purge().ok)

    def test_an_outfit_write_in_flight_refuses_busy_untouched(self):
        self.rt.run('WCSecurity.lock("outfits:12", 60000)')
        self.assertEqual(self.purge().detail, 'busy')
        self.assertEqual(self.e('#FakeDB.transactions'), 0)
        self.assertIsNone(self.e('CreatorAppearanceLocks["12"]'))              # released on refusal

    def test_the_purge_waits_for_a_write_in_flight_then_runs(self):
        self.rt.run('''
            WCSessions.lockCharacter("12", "writer")
            SetTimeout(1000, function() WCSessions.unlockCharacter("12", "writer") end)
            result = nil
            CreateThread(function() result = purge("12") end)
        ''')
        self.assertIsNone(self.e('result'))
        self.assertEqual(self.e('#FakeDB.transactions'), 0)
        self.rt.run('tick(1500)')
        self.assertTrue(self.e('result.ok'))
        self.assertEqual(self.e('deletesOf("12")'), 4)   # + the owned colours (colourways)
        self.assertIsNone(self.e('CreatorAppearanceLocks["12"]'))
        self.assertFalse(self.e('WCSecurity.locked("outfits:12")'))

    def test_a_write_after_the_purge_recreates_nothing(self):
        self.rt.run('WCAppearanceRepo.load("12")')
        self.assertTrue(self.purge().ok)
        before = self.e('#FakeDB.transactions')
        self.rt.run('sOk, sCode = WCAppearanceRepo.save("12", S.default("male"), { { query = "INSERT INTO w_creators_clothes x", values = { "12" } } })')
        self.assertFalse(self.e('sOk'))
        self.assertEqual(self.e('sCode'), 'CHARACTER_NOT_FOUND')
        self.assertEqual(self.e('#FakeDB.transactions'), before)


class PurgeMemoryTests(PurgeBase):
    def test_owed_legacy_grants_never_reach_the_next_holder_of_the_number(self):
        self.rt.run('''
            h = function(sex, c, m, v) return WCCatalog.forSex(sex)[c].models[m][v or 1].hash end
            local comps = { heads = h("male", "heads", 2, 1), eyes = h("male", "eyes", 1, 2), teeth = h("male", "teeth", 1, 1),
                            BODIES_UPPER = h("male", "BODIES_UPPER", 1, 1), hats = h("male", "hats", 1, 1),
                            boots = h("male", "boots", 2, 1), __version = 2 }
            rows["12"] = { id = 12, charid = "12", isMale = 1, components = json.encode(comps),
                           faceFeatures = "[]", overlays = "[]", appearance = nil, appearance_version = 2 }
            FakeDB.transactionOk = false
            app, meta = WCAppearanceRepo.load("12")      -- the lazy upgrade fails: its grants are owed
            FakeDB.transactionOk = true
            WCAppearanceRepo.invalidate("12")
        ''')
        self.assertFalse(self.e('meta.upgraded'))
        self.assertTrue(self.purge().ok)
        # the number is given to another character (a reassign moved its rows under it)
        self.rt.run('''
            rows["12"] = { id = 99, charid = "12", isMale = 1, appearance = json.encode(S.default("male")), appearance_version = 3 }
            WCAppearanceRepo.load("12")
            sOk = WCAppearanceRepo.save("12", S.default("male"))
        ''')
        self.assertTrue(self.e('sOk'))
        tx = self.e('FakeDB.transactions[#FakeDB.transactions]')
        self.assertEqual(len(tx), 1)                                        # the UPDATE alone
        self.assertNotIn('w_creators_clothes', tx[1].query)

    def test_stale_flow_references_are_dropped(self):
        # a failed appearance cleanup left 'owed' for the player's character vorp:1
        self.rt.run('FakeDB.transactionOk = false')
        self.assertEqual(self.call('characters:delete', 1, 'vorp:1').code, 'DATABASE_ERROR')
        self.rt.run('FakeDB.transactionOk = true')
        r = self.purge("'vorp:1'")
        self.assertTrue(r.ok, r.detail)
        self.assertEqual(self.rt.py(r.detail).get('memory'), 1)
        # nothing is attempted against the number when the player leaves
        before = self.e('#FakeDB.transactions')
        self.rt.run('fireEvent("playerDropped", 1); tick(0)')
        self.assertEqual(self.e('#FakeDB.transactions'), before)

    def test_a_switch_away_from_a_purged_character_is_forgotten(self):
        self.rt.run('owned[1][#owned[1] + 1] = { charid = "12", name = "Arthur Morgan" }')
        self.assertTrue(self.call('characters:select', 1, '12').ok)
        self.assertTrue(self.call('characters:loaded', 1).ok)
        self.rt.run('SpawnPending[1] = nil')
        self.assertTrue(self.call('characters:list', 1).ok)                 # the switch starts
        self.assertTrue(self.e('WCCharacters.isSwitching(1)'))
        self.assertTrue(self.call('characters:select', 1, 'vorp:1').ok)     # now logged into vorp:1
        r = self.purge()
        self.assertTrue(r.ok, r.detail)
        self.assertFalse(self.e('WCCharacters.isSwitching(1)'))
        self.assertTrue(self.call('characters:loaded', 1).ok)               # the flow goes on
        self.assertEqual(self.e('WCCharacters.active(1).charid'), 'vorp:1')


RSG_SELF_DELETE = r'''
Bridge.Name = 'rsg'
purgeAnswers = {}
fakeRsg = {
    Functions = { GetPlayer = function() return nil end },
    Player = {
        -- w_core's deletion purges every resource, w_creators included, before it answers
        DeleteCharacter = function(src, cid)
            local ok, detail = exportedPurge(cid, { by = 'player', at = 1, tombstone = 'deleted-' .. cid .. '-1' })
            purgeAnswers[#purgeAnswers + 1] = { ok = ok, detail = detail }
            if not ok then return false, detail end
            for _, list in pairs(owned) do
                for i = #list, 1, -1 do if list[i].charid == cid then table.remove(list, i) end end
            end
            return true
        end,
    },
}
w.framework = { getCore = function() return fakeRsg end }
exportedPurge = WCCharacters.purge
owned[1][#owned[1] + 1] = { charid = '12', name = 'Arthur Morgan' }
'''


class SelfDeleteTests(PurgeBase):
    def setUp(self):
        super().setUp()
        self.rt.run(RSG_SELF_DELETE)

    def test_the_selector_delete_succeeds_when_w_core_purged_everything(self):
        r = self.call('characters:delete', 1, '12')
        self.assertTrue(r.ok, r.code)
        self.assertTrue(self.e('purgeAnswers[1].ok'))
        self.assertEqual(self.e('purgeAnswers[1].detail.w_creators_clothes'), 5)
        # w_core's purge removed the rows; the delete adds no second transaction
        self.assertEqual(self.e('#FakeDB.transactions'), 1)
        self.assertEqual(self.e('deletesOf("12")'), 4)   # + the owned colours (colourways)

    def test_a_purge_refused_as_busy_is_a_retry(self):
        self.rt.run('WCSessions.lockCharacter("12", "writer")')
        self.assertEqual(self.call('characters:delete', 1, '12').code, 'BUSY')
        self.assertEqual(self.e('store.w_creators_clothes["12"]'), 5)
        self.rt.run('WCSessions.unlockCharacter("12", "writer")')
        self.later()
        self.assertTrue(self.call('characters:delete', 1, '12').ok)

    def test_an_older_w_core_refusal_is_still_the_players_message(self):
        self.rt.run('fakeRsg.Player.DeleteCharacter = function() return false, "assets" end')
        self.assertEqual(self.call('characters:delete', 1, '12').code, 'DELETE_HOLDS_ASSETS')
        self.rt.run('fakeRsg.Player.DeleteCharacter = function() return false, "something_new" end')
        self.later()
        self.assertEqual(self.call('characters:delete', 1, '12').code, 'DATABASE_ERROR')
        self.assertEqual(self.e('#FakeDB.transactions'), 0)

    def test_a_core_that_does_not_purge_still_gets_the_rows_deleted(self):
        self.rt.run('''
            fakeRsg.Player.DeleteCharacter = function(src, cid)
                for _, list in pairs(owned) do
                    for i = #list, 1, -1 do if list[i].charid == cid then table.remove(list, i) end end
                end
                return true
            end
        ''')
        self.assertTrue(self.call('characters:delete', 1, '12').ok)
        self.assertEqual(self.e('deletesOf("12")'), 4)   # + the owned colours (colourways)


if __name__ == '__main__':
    unittest.main()
