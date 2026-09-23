"""Server core: WCMigrations, WCEconomy, WCSecurity, WCSessions, WCAppearanceRepo, spawn grant."""
import json
import unittest

from harness import Runtime

APP_SETUP = r'''
FakeDB.fireReady()                                              -- the migrations have run
S = AppearanceSchema
h = function(sex, c, m, v) return WCCatalog.forSex(sex)[c].models[m][v or 1].hash end
charids = { [1] = 'vorp:1' }
Bridge.GetCharId = function(src) return charids[src] end
Players[1].coords = vector3(-326.17, 773.757, 117.5)            -- valentine_clothing book
Players[2] = { name = 'player two', coords = vector3(0, 0, 0), bucket = 0 }
FakeUsers[1] = { money = 100 }
savedApp = S.default('male')
rows = { ['vorp:1'] = { id = 11, charid = 'vorp:1', appearance = json.encode(savedApp), appearance_version = 3 } }
FakeDB.on('SELECT %* FROM characters_appearence', function(sql, params) return rows[params[1]] end)
FakeDB.on('SELECT id FROM characters_appearence WHERE charid', function(sql, params)
    return rows[params[1]] and rows[params[1]].id end)
'''


def server():
    rt = Runtime().load_server_core()
    rt.run(APP_SETUP)
    return rt


class MigrationTests(unittest.TestCase):
    def setUp(self):
        self.rt = Runtime().load_server_core()
        self.e = self.rt.eval

    def test_runs_on_database_ready_and_is_idempotent(self):
        self.rt.run('FakeDB.fireReady()')
        self.assertTrue(self.e('WCMigrations.done and WCMigrations.ok'))
        self.assertEqual(list(self.e('FakeDB.migrations').values()),
                         ['001_base_tables', '002_appearance_v3', '003_clothes_meta', '004_outfits'])
        schema = self.rt.py(self.e('FakeDB.schema'))
        for col in ('charid', 'isMale', 'components', 'appearance', 'appearance_version', 'updated_at'):
            self.assertIn(col, schema['characters_appearence'])
        for col in ('hash', 'palette', 'tint2', 'source', 'acquired_at'):
            self.assertIn(col, schema['w_creators_clothes'])
        self.assertIn('data', schema['w_creators_outfits'])
        alters = self.e('FakeDB.count("ALTER TABLE")')
        self.assertEqual(alters, 5)
        self.rt.run('ok2, applied2 = WCMigrations.run()')
        self.assertTrue(self.e('ok2'))
        self.assertEqual(self.e('#applied2'), 0)
        self.assertEqual(self.e('FakeDB.count("ALTER TABLE")'), 5)
        self.assertEqual(self.e('FakeDB.count("CREATE TABLE IF NOT EXISTS `characters_appearence`")'), 1)

    def test_existing_columns_are_detected_through_information_schema(self):
        self.rt.run('''
            FakeDB.schema.characters_appearence = { id = true, charid = true, appearance = true, updated_at = true }
            FakeDB.schema.w_creators_clothes = { id = true, source = true }
            ok, applied = WCMigrations.run()
        ''')
        self.assertTrue(self.e('ok'))
        alters = [q.sql for q in self.e('FakeDB.queries').values() if 'ALTER TABLE' in q.sql]
        self.assertEqual(len(alters), 2)
        self.assertIn('appearance_version', alters[0])
        self.assertIn('acquired_at', alters[1])
        self.assertTrue(self.e('WCMigrations.columnExists("characters_appearence", "appearance_version")'))
        self.assertTrue(self.e('WCMigrations.tableExists("w_creators_outfits")'))
        self.assertFalse(self.e('WCMigrations.tableExists("nope")'))

    def test_failure_stops_and_resumes(self):
        self.rt.run('FakeDB.fail = "w_creators_outfits"; ok, applied = WCMigrations.run()')
        self.assertFalse(self.e('ok'))
        self.assertEqual(self.e('#applied'), 3)
        self.assertNotIn('004_outfits', list(self.e('FakeDB.migrations').values()))
        self.rt.run('FakeDB.fail = nil; ok2, applied2 = WCMigrations.run()')
        self.assertTrue(self.e('ok2'))
        self.assertEqual(list(self.e('applied2').values()), ['004_outfits'])


class EconomyTests(unittest.TestCase):
    def setUp(self):
        self.rt = server()
        self.e = self.rt.eval

    def test_invalid_amounts(self):
        for bad in ('0/0', '1/0', '-1', '"5"', 'nil', '{}'):
            self.rt.run('r = WCEconomy.charge(1, %s, "test")' % bad)
            self.assertEqual(self.e('r.code'), 'INVALID_PRICE', bad)
        self.assertEqual(self.e('#MoneyCalls'), 0)
        self.assertEqual(self.e('FakeUsers[1].money'), 100)

    def test_zero_is_free_and_never_touches_the_framework(self):
        self.rt.run('r = WCEconomy.charge(1, 0, "free")')
        self.assertTrue(self.e('r.ok and r.data.charged == 0'))
        self.assertEqual(self.e('#MoneyCalls'), 0)
        self.rt.run('r = WCEconomy.charge(1, 0.001, "rounds to zero")')
        self.assertTrue(self.e('r.ok and r.data.charged == 0'))
        self.assertEqual(self.e('#MoneyCalls'), 0)

    def test_charge_rounds_and_checks_funds(self):
        self.rt.run('r = WCEconomy.charge(1, 10.005, "x")')
        self.assertTrue(self.e('r.ok'))
        self.assertEqual(self.e('r.data.charged'), 10.01)
        self.assertAlmostEqual(self.e('FakeUsers[1].money'), 89.99)
        call = self.e('MoneyCalls[1]')
        self.assertEqual((call.op, call.moneyType, call.remove), ('canBuy', 0, True))
        self.rt.run('r = WCEconomy.charge(1, 1000, "x")')
        self.assertEqual(self.e('r.code'), 'INSUFFICIENT_FUNDS')
        self.assertAlmostEqual(self.e('FakeUsers[1].money'), 89.99)
        self.rt.run('r = WCEconomy.charge(9, 1, "x")')
        self.assertEqual(self.e('r.code'), 'NO_CHARACTER')

    def test_refund(self):
        self.assertTrue(self.e('WCEconomy.refund(1, 5, "x")'))
        self.assertEqual(self.e('FakeUsers[1].money'), 105)
        self.assertTrue(self.e('WCEconomy.refund(1, 0, "x")'))
        self.assertFalse(self.e('WCEconomy.refund(1, -5, "x")'))
        self.rt.run('FakeUsers[1].failAdd = true')
        self.assertFalse(self.e('WCEconomy.refund(1, 5, "x")'))

    def test_with_charge(self):
        self.rt.run('calls = 0; r = WCEconomy.withCharge(1, 20, "ok", function() calls = calls + 1; return WCResult.ok({ id = 3 }) end)')
        self.assertTrue(self.e('r.ok and r.charged == 20 and r.data.id == 3 and calls == 1'))
        self.assertEqual(self.e('FakeUsers[1].money'), 80)
        # persist throws -> refunded
        self.rt.run('r = WCEconomy.withCharge(1, 30, "boom", function() error("db down") end)')
        self.assertEqual(self.e('r.code'), 'DATABASE_ERROR')
        self.assertTrue(self.e('r.data.refunded'))
        self.assertEqual(self.e('FakeUsers[1].money'), 80)
        # persist returns false / a failed Result -> refunded with that code
        self.rt.run('r = WCEconomy.withCharge(1, 30, "false", function() return false end)')
        self.assertEqual(self.e('r.code'), 'DATABASE_ERROR')
        self.rt.run('r = WCEconomy.withCharge(1, 30, "fail", function() return WCResult.fail("ITEM_NOT_OWNED") end)')
        self.assertEqual(self.e('r.code'), 'ITEM_NOT_OWNED')
        self.assertEqual(self.e('FakeUsers[1].money'), 80)
        # insufficient funds -> persist never runs
        self.rt.run('ran = false; r = WCEconomy.withCharge(1, 500, "x", function() ran = true end)')
        self.assertEqual(self.e('r.code'), 'INSUFFICIENT_FUNDS')
        self.assertFalse(self.e('ran'))
        # a failed refund is reported
        self.rt.run('FakeUsers[1].failAdd = true; r = WCEconomy.withCharge(1, 10, "x", function() error("x") end)')
        self.assertFalse(self.e('r.data.refunded'))
        self.assertEqual(self.e('FakeUsers[1].money'), 70)
        self.assertTrue(any(e.event == 'security_violation' and e.payload.kind == 'refund_failed'
                            for e in self.e('LogEmits').values()))
        canbuys = [c for c in self.e('MoneyCalls').values() if c.op == 'canBuy']
        self.assertEqual(len(canbuys), 6)  # one charge attempt per withCharge call


class SecurityTests(unittest.TestCase):
    def setUp(self):
        self.rt = server()
        self.e = self.rt.eval

    def test_rate_window(self):
        results = [self.e('WCSecurity.rate(1, "k", 3, 1000)') for _ in range(4)]
        self.assertEqual(results, [True, True, True, False])
        self.assertTrue(self.e('WCSecurity.rate(2, "k", 3, 1000)'))
        self.rt.run('Clock.now = Clock.now + 1001')
        self.assertTrue(self.e('WCSecurity.rate(1, "k", 3, 1000)'))
        self.rt.run('fireEvent("playerDropped", 1)')
        self.assertTrue(self.e('WCSecurity.rate(1, "k", 1, 1000)'))

    def test_payload_lock_near(self):
        self.assertTrue(self.e('WCSecurity.payload({a = 1}, 100)'))
        self.assertFalse(self.e('WCSecurity.payload({a = string.rep("x", 200)}, 100)'))
        self.assertFalse(self.e('WCSecurity.payload({a = 0/0}, 100)'))
        self.assertTrue(self.e('WCSecurity.lock("x")'))
        self.assertFalse(self.e('WCSecurity.lock("x")'))
        self.rt.run('WCSecurity.unlock("x")')
        self.assertTrue(self.e('WCSecurity.lock("x", 100)'))
        self.rt.run('Clock.now = Clock.now + 101')
        self.assertTrue(self.e('WCSecurity.lock("x")'))  # abandoned lock expired
        self.assertTrue(self.e('WCSecurity.near(1, vector3(-326, 774, 117.5), 2)'))
        self.assertFalse(self.e('WCSecurity.near(1, vector3(-300, 774, 117.5), 2)'))
        self.assertFalse(self.e('WCSecurity.near(99, vector3(0, 0, 0), 2)'))
        self.assertFalse(self.e('WCSecurity.near(1, {x = 0/0, y = 0, z = 0}, 2)'))
        self.rt.run('WCSecurity.violation(1, "bad_hash", {hash = 5})')
        self.assertEqual(self.e('LogEmits[#LogEmits].event'), 'security_violation')


class SessionTests(unittest.TestCase):
    def setUp(self):
        self.rt = server()
        self.e = self.rt.eval
        self.rt.run('closed = {}; WCSessions.onClose(function(s, reason) closed[#closed + 1] = reason end)')

    def open(self, kind='store', loc='valentine_clothing', src=1, extra=''):
        self.rt.run('r = WCSessions.open(%d, "%s", { locationId = %s %s })' % (src, kind, 'nil' if loc is None else '"%s"' % loc, extra))
        return self.e('r')

    def test_open_success_and_single_session(self):
        r = self.open()
        self.assertTrue(r.ok)
        self.assertEqual(r.data.session.charid, 'vorp:1')
        self.assertEqual(r.data.session.location.id, 'valentine_clothing')
        self.assertTrue(self.e('S.equal(r.data.session.snapshot, savedApp)'))
        self.rt.run('token = r.data.token')
        self.assertEqual(self.open().code, 'BUSY')
        self.assertTrue(self.e('WCSessions.close(1, token)'))
        self.assertEqual(list(self.e('closed').values()), ['close'])
        self.assertTrue(self.open().ok)

    def test_open_refusals(self):
        self.assertEqual(self.open(kind='bank').code, 'INVALID_PAYLOAD')
        self.assertEqual(self.open(loc='nowhere').code, 'LOCATION_NOT_FOUND')
        self.assertEqual(self.open(loc='valentine_barber').code, 'LOCATION_NOT_FOUND')
        self.assertEqual(self.open(loc=None).code, 'LOCATION_NOT_FOUND')
        self.assertEqual(self.open(kind='barber', loc='valentine_barber').code, 'TOO_FAR')
        self.assertEqual(self.open(src=2).code, 'NO_CHARACTER')
        self.rt.run('Clock.now = Clock.now + 20000')
        self.rt.run('Config.Locations[1].enabled = false; WCLocations.reload()')
        self.assertEqual(self.open().code, 'LOCATION_DISABLED')
        self.rt.run('Config.Locations[1].enabled = true; WCLocations.reload(); Config.Services.clothingStores = false')
        self.assertEqual(self.open().code, 'STORE_DISABLED')
        self.rt.run('Clock.now = Clock.now + 20000; Config.Services.clothingStores = true; CreatorAppearanceLocks["vorp:1"] = true')
        self.assertEqual(self.open().code, 'BUSY')
        self.rt.run('CreatorAppearanceLocks["vorp:1"] = nil; rows["vorp:1"] = nil; WCAppearanceRepo.invalidate("vorp:1")')
        self.assertEqual(self.open().code, 'CHARACTER_NOT_FOUND')

    def test_rate_limit(self):
        codes = [self.open(loc='nowhere').code for _ in range(6)]
        self.assertEqual(codes[-1], 'RATE_LIMITED')

    def test_remote_wardrobe_only_when_allowed(self):
        self.rt.run('r = WCSessions.open(1, "wardrobe", { remote = true })')
        self.assertTrue(self.e('r.ok and r.data.session.remote and r.data.session.location == nil'))
        self.rt.run('WCSessions.clear(1); Config.Wardrobe.allowRemote = false; r = WCSessions.open(1, "wardrobe", { remote = true })')
        self.assertEqual(self.e('r.code'), 'LOCATION_NOT_FOUND')
        self.rt.run('r = WCSessions.open(1, "store", { remote = true })')
        self.assertEqual(self.e('r.code'), 'LOCATION_NOT_FOUND')

    def test_get_expiry_and_token(self):
        self.open()
        self.rt.run('token = r.data.token')
        self.assertEqual(self.e('select(2, WCSessions.get(1, "forged"))'), 'SESSION_NOT_FOUND')
        self.assertIsNotNone(self.e('WCSessions.get(1, token)'))
        self.rt.run('r.data.session.expires = os.time() - 1')
        self.assertEqual(self.e('select(2, WCSessions.get(1, token))'), 'SESSION_EXPIRED')
        self.assertIsNone(self.e('WCSessions.current(1)'))
        self.assertEqual(list(self.e('closed').values()), ['expired'])

    def test_expiry_thread(self):
        self.open()
        self.rt.run('r.data.session.expires = os.time() - 1; tick(30000)')
        self.assertIsNone(self.e('WCSessions.current(1)'))

    def test_character_change_invalidates(self):
        self.open()
        self.rt.run('token = r.data.token; charids[1] = "vorp:2"')
        self.assertEqual(self.e('select(2, WCSessions.get(1, token))'), 'NO_CHARACTER')

    def test_commit_success_replay_and_close(self):
        self.open()
        self.rt.run('''
            token = r.data.token; runs = 0
            fn = function(s) runs = runs + 1; assert(CreatorAppearanceLocks[s.charid]); return WCResult.ok({ n = runs }) end
            c1 = WCSessions.commit(1, token, "op-1", fn)
            c2 = WCSessions.commit(1, token, "op-1", fn)
        ''')
        self.assertTrue(self.e('c1.ok and c1.data.n == 1'))
        self.assertTrue(self.e('c1 == c2 and runs == 1'))
        self.assertIsNone(self.e('WCSessions.current(1)'))
        self.assertIsNone(self.e('CreatorAppearanceLocks["vorp:1"]'))
        self.assertEqual(list(self.e('closed').values()), ['commit'])
        self.assertEqual(self.e('WCSessions.commit(1, token, "op-2", fn).code'), 'SESSION_NOT_FOUND')
        self.assertEqual(self.e('WCSessions.commit(1, "other", "op-1", fn).code'), 'SESSION_NOT_FOUND')

    def test_commit_busy_errors_and_distance(self):
        self.open()
        self.rt.run('''
            token = r.data.token
            nested = nil
            c = WCSessions.commit(1, token, "a", function(s) nested = WCSessions.commit(1, token, "b", function() return 1 end); return WCResult.fail("INSUFFICIENT_FUNDS") end)
        ''')
        self.assertEqual(self.e('nested.code'), 'BUSY')
        self.assertEqual(self.e('c.code'), 'INSUFFICIENT_FUNDS')
        self.assertIsNotNone(self.e('WCSessions.current(1)'))  # a failed commit keeps the session
        self.rt.run('e = WCSessions.commit(1, token, "c", function() error("boom") end)')
        self.assertEqual(self.e('e.code'), 'INTERNAL_ERROR')
        self.assertIsNone(self.e('CreatorAppearanceLocks["vorp:1"]'))
        self.assertEqual(self.e('WCSessions.commit(1, token, {}, function() end).code'), 'INVALID_PAYLOAD')
        self.assertEqual(self.e('WCSessions.commit(1, token, string.rep("x", 65), function() end).code'), 'INVALID_PAYLOAD')
        # the fitting stand (preview) counts as in range; far away does not
        self.rt.run('Players[1].coords = vector3(-329.31, 775.11, 120.63)')
        self.assertTrue(self.e('WCSessions.commit(1, token, "d", function() return true end).ok'))
        self.open()
        self.rt.run('token = r.data.token; Players[1].coords = vector3(0, 0, 0)')
        self.assertEqual(self.e('WCSessions.commit(1, token, "e", function() return true end).code'), 'TOO_FAR')

    def test_disconnect_and_resource_stop_cleanup(self):
        self.open()
        self.rt.run('fireEvent("playerDropped", 1)')
        self.assertIsNone(self.e('WCSessions.current(1)'))
        self.assertEqual(list(self.e('closed').values()), ['dropped'])
        self.open()
        self.rt.run('fireEvent("onResourceStop", nil, "other"); fireEvent("onResourceStop", nil, "w_creators")')
        self.assertIsNone(self.e('WCSessions.current(1)'))
        self.assertEqual(list(self.e('closed').values()), ['dropped', 'stopped'])

    def test_surgery_session_lifetime_and_disabled(self):
        self.rt.run('Players[1].coords = vector3(-284.49, 807.49, 119.38)')
        r = self.open(kind='surgery', loc='valentine_surgery')
        self.assertTrue(r.ok)
        self.assertEqual(self.e('r.data.session.expires - r.data.session.opened'), 20 * 60)
        self.rt.run('WCSessions.clear(1); Config.CosmeticSurgery.enabled = false')
        self.assertEqual(self.open(kind='surgery', loc='valentine_surgery').code, 'SURGERY_DISABLED')

    def test_uses_wccharacters_when_present(self):
        self.rt.run('WCCharacters = { active = function(src) return src == 2 and { charid = "vorp:1", sex = "male" } or nil end }')
        self.rt.run('Players[2].coords = Players[1].coords')
        self.assertEqual(self.open(src=1).code, 'NO_CHARACTER')
        self.assertTrue(self.open(src=2).ok)


class RepositoryTests(unittest.TestCase):
    def setUp(self):
        self.rt = server()
        self.e = self.rt.eval

    def legacy_row(self, complete=True):
        self.rt.run('''
            comps = { heads = h("male", "heads", 2, 1), eyes = h("male", "eyes", 1, 2), teeth = h("male", "teeth", 1, 1),
                      BODIES_UPPER = h("male", "BODIES_UPPER", 1, 1), hats = h("male", "hats", 1, 1),
                      boots = h("male", "boots", 2, 1), __version = 2 }
            if not %s then comps.heads = 12345 end
            rows["vorp:1"] = { id = 11, charid = "vorp:1", isMale = 1, components = json.encode(comps),
                               faceFeatures = "[]", overlays = "[]", appearance = nil, appearance_version = 2 }
        ''' % ('true' if complete else 'false'))

    def test_lazy_upgrade_writes_back_with_legacy_grants(self):
        self.legacy_row()
        self.rt.run('app, meta = WCAppearanceRepo.load("vorp:1")')
        self.assertTrue(self.e('meta.upgraded'))
        self.assertEqual(self.e('meta.version'), 2)
        tx = self.e('FakeDB.transactions[1]')
        self.assertIn('UPDATE characters_appearence SET appearance = ?', tx[1].query)
        stored = json.loads(tx[1]['values'][1])
        self.assertEqual(stored['version'], 3)
        grants = [q for q in tx.values() if 'INSERT IGNORE INTO w_creators_clothes' in q.query]
        self.assertEqual(sorted(q['values'][3] for q in grants), ['boots', 'hats'])
        self.assertTrue(all("'legacy'" in q.query for q in grants))
        # cached: no second read
        reads = self.e('FakeDB.count("SELECT %* FROM characters_appearence")')
        self.rt.run('app2, meta2 = WCAppearanceRepo.load("vorp:1")')
        self.assertEqual(self.e('FakeDB.count("SELECT %* FROM characters_appearence")'), reads)
        self.assertTrue(self.e('meta2.cached and S.equal(app, app2)'))
        self.rt.run('app2.hair.style = 0')
        self.assertFalse(self.e('S.equal(WCAppearanceRepo.load("vorp:1"), app2)'))  # copies, not the cache

    def test_no_write_back_when_defaults_were_needed(self):
        self.legacy_row(complete=False)
        self.rt.run('app, meta = WCAppearanceRepo.load("vorp:1")')
        self.assertFalse(self.e('meta.upgraded'))
        self.assertEqual(list(self.e('meta.defaultsUsed').values()), ['face'])
        self.assertEqual(self.e('#FakeDB.transactions'), 0)
        self.assertEqual(self.e('app.version'), 3)
        self.assertTrue(any('not upgraded' in p.text for p in self.e('Printed').values()))

    def test_failed_upgrade_write_still_returns_the_appearance(self):
        self.legacy_row()
        self.rt.run('FakeDB.transactionOk = false; app, meta = WCAppearanceRepo.load("vorp:1")')
        self.assertFalse(self.e('meta.upgraded'))
        self.assertEqual(self.e('app.version'), 3)

    def test_v3_row_is_read_without_writing(self):
        self.rt.run('app, meta = WCAppearanceRepo.load("vorp:1")')
        self.assertTrue(self.e('S.equal(app, savedApp)'))
        self.assertEqual(self.e('meta.version'), 3)
        self.assertEqual(self.e('#FakeDB.transactions'), 0)

    def test_corrupt_v3_falls_back_to_the_legacy_columns(self):
        self.legacy_row()
        self.rt.run('rows["vorp:1"].appearance = "{broken"; rows["vorp:1"].appearance_version = 3')
        self.rt.run('app, meta = WCAppearanceRepo.load("vorp:1")')
        self.assertEqual(self.e('meta.version'), 2)
        self.assertTrue(self.e('meta.upgraded'))

    def test_missing_and_database_error(self):
        self.rt.run('a, m = WCAppearanceRepo.load("vorp:404")')
        self.assertIsNone(self.e('a'))
        self.assertTrue(self.e('m.missing'))
        self.rt.run('FakeDB.fail = "SELECT %*"; a, m = WCAppearanceRepo.load("vorp:1")')
        self.assertEqual(self.e('m.error'), 'DATABASE_ERROR')

    def test_save_writes_v3_and_projection_in_one_transaction(self):
        self.rt.run('WCAppearanceRepo.load("vorp:1")')
        self.rt.run('''
            new = WCUtil.copy(savedApp); new.clothing.equipped.hats = h("male", "hats", 1, 1)
            ok, saved = WCAppearanceRepo.save("vorp:1", new, { { query = "INSERT INTO w_creators_clothes x", values = { 1 } } })
        ''')
        self.assertTrue(self.e('ok'))
        tx = self.e('FakeDB.transactions[#FakeDB.transactions]')
        self.assertEqual(len(tx), 2)
        self.assertIn('isMale = ?, components = ?, faceFeatures = ?, overlays = ?', tx[1].query)
        values = tx[1]['values']
        self.assertEqual(json.loads(values[1])['clothing']['equipped']['hats'], self.e('h("male", "hats", 1, 1)'))
        self.assertEqual(values[2], 3)
        self.assertEqual(values[3], 1)
        self.assertEqual(json.loads(values[4])['__version'], 2)
        self.assertEqual((values[7], values[8]), (11, 'vorp:1'))
        self.assertTrue(self.e('S.equal(WCAppearanceRepo.load("vorp:1"), saved)'))

    def test_save_failure_and_unknown_character(self):
        self.rt.run('FakeDB.transactionOk = false; ok, code = WCAppearanceRepo.save("vorp:1", savedApp)')
        self.assertFalse(self.e('ok'))
        self.assertEqual(self.e('code'), 'DATABASE_ERROR')
        self.assertIsNone(self.e('WCAppearanceRepo.cache["vorp:1"]'))
        self.rt.run('ok, code = WCAppearanceRepo.save("vorp:404", savedApp)')
        self.assertEqual(self.e('code'), 'CHARACTER_NOT_FOUND')

    def test_create_and_delete(self):
        self.rt.run('ok = WCAppearanceRepo.create("vorp:7", { firstname = "Sadie", lastname = "Adler", age = 29 }, savedApp, { { query = "Q", values = {} } })')
        self.assertTrue(self.e('ok'))
        tx = self.e('FakeDB.transactions[1]')
        self.assertIn('INSERT INTO characters_appearence', tx[1].query)
        self.assertEqual(tx[1]['values'][3], 'Sadie Adler')
        self.assertEqual(tx[2].query, 'Q')
        self.rt.run('WCAppearanceRepo.load("vorp:1"); okd = WCAppearanceRepo.delete("vorp:1")')
        self.assertTrue(self.e('okd'))
        tx = self.e('FakeDB.transactions[#FakeDB.transactions]')
        self.assertEqual([q.query for q in tx.values()], [
            'DELETE FROM characters_appearence WHERE charid = ?',
            'DELETE FROM w_creators_clothes WHERE charid = ?',
            'DELETE FROM w_creators_outfits WHERE charid = ?'])
        self.assertIsNone(self.e('WCAppearanceRepo.cache["vorp:1"]'))

    def test_migrate_all_in_batches(self):
        self.legacy_row()
        self.rt.run('''
            rows["vorp:2"] = WCUtil.copy(rows["vorp:1"]); rows["vorp:2"].id = 12; rows["vorp:2"].charid = "vorp:2"
            FakeDB.on("SELECT id, charid FROM characters_appearence", function(sql, params)
                local out = {}
                for _, r in pairs(rows) do
                    if r.id > params[1] and (r.appearance == nil or r.appearance_version < 3) then out[#out + 1] = { id = r.id, charid = r.charid } end
                end
                table.sort(out, function(a, b) return a.id < b.id end)
                while #out > params[3] do table.remove(out) end
                return out
            end)
            scanned, upgraded = WCAppearanceRepo.migrateAll(1)
        ''')
        self.assertEqual((self.e('scanned'), self.e('upgraded')), (2, 2))
        self.assertTrue(self.e('Events.commands.wc_migrate_appearances.restricted'))


class BridgeTests(unittest.TestCase):
    def test_log_types_are_registered(self):
        rt = server()
        rt.run('w.logs.IsReady = function() return true end; fireEvent("w_creators:server:logsReady")')
        keys = set(rt.py(rt.eval('LogTypes')).values())
        for key in ('character_created', 'appearance_changed', 'surgery_completed', 'clothing_purchased',
                    'outfit_saved', 'character_spawned', 'security_violation', 'haircut'):
            self.assertIn(key, keys)

    def test_delete_character_uses_the_repository_transaction(self):
        rt = server()
        rt.run('Bridge.GetCharacters = function() return {} end; Bridge.DeleteCharacter(1, "qbr-cid")')
        tx = rt.eval('FakeDB.transactions[1]')
        self.assertEqual(len(tx), 3)
        self.assertEqual(tx[2]['values'][1], 'qbr-cid')


class SpawnTests(unittest.TestCase):
    def setUp(self):
        self.rt = server()
        self.e = self.rt.eval
        self.rt.run('Bridge.GetLastPosition = function() return { x = 5, y = 6, z = 7, heading = 8 } end')

    def test_disabled_points_and_one_shot_grant(self):
        self.assertIsNotNone(self.e('Bridge.FindSpawnPoint("rhodes")'))
        self.rt.run('Config.Spawn.points[3].enabled = false')
        self.assertIsNone(self.e('Bridge.FindSpawnPoint("rhodes")'))
        self.rt.run('Bridge.FinishCharacter(1, false)')
        sel = self.rt.client_events('w_creators:client:selectSpawn')
        self.assertEqual(sel[0].args[1].last.x, 5)
        self.rt.run('fireEvent("w_creators:server:spawnAt", 1, "rhodes")')
        spawn = self.rt.client_events('w_creators:client:spawn')
        self.assertAlmostEqual(spawn[0].args[1].x, -274.09)  # disabled point -> first spawn
        self.rt.run('fireEvent("w_creators:server:spawnAt", 1, "valentine")')
        self.assertEqual(len(self.rt.client_events('w_creators:client:spawn')), 1)

    def test_selector_and_last_location_toggles(self):
        self.rt.run('Config.Services.lastLocation = false; Bridge.FinishCharacter(1, false)')
        self.assertIsNone(self.rt.client_events('w_creators:client:selectSpawn')[0].args[1].last)
        self.rt.run('Config.Services.spawnSelector = false; Bridge.FinishCharacter(1, false)')
        spawn = self.rt.client_events('w_creators:client:spawn')
        self.assertAlmostEqual(spawn[0].args[1].x, -274.09)
        self.rt.run('Config.Services.lastLocation = true; Bridge.FinishCharacter(1, false)')
        self.assertEqual(self.rt.client_events('w_creators:client:spawn')[1].args[1].x, 5)
        self.rt.run('Config.Creator.spawnEvent = "fw:spawn"; Bridge.FinishCharacter(1, true)')
        self.assertEqual(len(self.rt.client_events('fw:spawn')), 1)


if __name__ == '__main__':
    unittest.main()
