"""Server characters: WCCharacters, the characters:* callbacks, switching (ARCHITECTURE.md §9.1, §9.2, §16.1)."""
import os
import sys
import unittest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from harness import Runtime, manifest_scripts

# Server files loaded in manifest order: bridge, core, repository, sync, characters, scene,
# ownership (when implemented), spawn, respawn.
WANTED = ('server/bridge/', 'server/core/', 'server/appearance/', 'server/characters/', 'server/scene.lua',
          'server/spawn/', 'server/respawn/')

SETUP = r'''
S = AppearanceSchema
charids = {}
Bridge.Name = 'vorp'
Bridge.GetCharId = function(src) return charids[src] end
Bridge.GetLicense = function(src) return 'steam:' .. tostring(src) end
owned = {
    [1] = { { charid = 'vorp:1', name = 'John Smith', cash = 10, bank = 5, gold = 1, job = 'Rancher' },
            { charid = 'vorp:2', name = 'Jane Doe' } },
    [2] = { { charid = 'vorp:9', name = 'Other Guy' } },
}
Bridge.GetCharacters = function(src)
    local out = {}
    for i, r in ipairs(owned[src] or {}) do out[i] = { charid = r.charid, name = r.name, cash = r.cash, bank = r.bank, gold = r.gold, job = r.job } end
    return out
end
loginCalls, loginDelay = {}, 0
Bridge.LoginCharacter = function(src, charid)
    table.insert(loginCalls, { src = src, charid = charid })
    if loginDelay > 0 then SetTimeout(loginDelay, function() charids[src] = charid end)
    else charids[src] = charid end
    return true
end
order, registered, nextId = {}, {}, 100
AddEventHandler('w_creators:server:characterCreated', function(src) table.insert(order, 'characterCreated') end)
Bridge.RegisterCharacter = function(src, data)
    table.insert(order, 'register')
    table.insert(registered, data)
    nextId = nextId + 1
    local id = 'vorp:' .. nextId
    table.insert(owned[src], { charid = id, name = data.firstname .. ' ' .. data.lastname })
    charids[src] = id
    return id
end
Bridge.GetLastPosition = function(src) return lastPos end
Bridge.SetSurvival = function() end
-- this RedM build: the server reads 0 for a LIVING player's ped; death is the framework's flag
function GetEntityHealth(ped) return 0 end
dead = {}
rawset(exports, 'w_lib', setmetatable({
    FwGetCharacter = function(_, src) return { metadata = { isdead = dead[src] == true } } end,
}, { __index = function() return function() end end }))
Players[2] = { name = 'player two', coords = vector3(0, 0, 0), bucket = 0 }
rows = { ['vorp:1'] = { id = 11, charid = 'vorp:1', name = 'John Smith', age = 30, isMale = 1,
                        appearance = json.encode(S.default('male')), appearance_version = 3 },
         ['vorp:9'] = { id = 19, charid = 'vorp:9', appearance = json.encode(S.default('female')), appearance_version = 3 } }
FakeDB.on('SELECT %* FROM characters_appearence', function(sql, params) return rows[params[1]] end)
FakeDB.on('SELECT name, age, isMale FROM characters_appearence', function(sql, params) return rows[params[1]] end)
FakeDB.on('SELECT id FROM characters_appearence WHERE charid', function(sql, params)
    return rows[params[1]] and rows[params[1]].id end)
fwRows = {
    { charidentifier = 1, firstname = 'John', lastname = 'Smith', age = 30, gender = 'Male',
      coords = json.encode({ x = 1230.0, y = -1290.0, z = 76.0, heading = 12.0 }) },
    { charidentifier = 2, firstname = 'Jane', lastname = 'Doe', age = 25, gender = 'f', coords = '{broken' },
}
FakeDB.on('SELECT charidentifier, firstname, lastname, age, gender, coords FROM characters', function() return fwRows end)
keepFrameworkRow = false
FakeDB.on('DELETE FROM characters WHERE charidentifier', function(sql, params)
    if keepFrameworkRow then return {} end
    local charid = 'vorp:' .. tostring(params[1])
    for _, list in pairs(owned) do
        for i = #list, 1, -1 do if list[i].charid == charid then table.remove(list, i) end end
    end
    return {}
end)
logs = {}
CreatorLogs.Emit = function(event, payload) table.insert(logs, { event = event, payload = payload }) return true end
function countLogs(name) local n = 0 for _, l in ipairs(logs) do if l.event == name then n = n + 1 end end return n end
cb = function(name, src, ...) return Callbacks['w_creators:' .. name](src, ...) end
'''


def fake_ownership(rt):
    rt.run(r'''
        if not (type(WCOwnership) == 'table' and type(WCOwnership.grantQueries) == 'function') then
            WCOwnership = WCOwnership or {}
            function WCOwnership.grantQueries(charid, items, source)
                local out = {}
                for _, it in ipairs(items) do
                    out[#out + 1] = { query = 'INSERT IGNORE INTO w_creators_clothes (charid, hash, category, source) VALUES (?, ?, ?, ?)',
                                      values = { charid, it.hash, it.category, source } }
                end
                return out
            end
        end
    ''')


def server_runtime():
    """A runtime with the server core, sync, characters, scene, spawn and respawn loaded."""
    rt = Runtime().load_shared()
    for path in manifest_scripts('server'):
        if path.startswith(WANTED):
            rt.load(path)
            if path == 'server/core/migrations.lua':
                rt.run('FakeDB.fireReady()')                # the migrations have run
        elif path == 'server/clothing/ownership.lua':
            try:
                rt.load(path)
            except Exception:  # an in-progress sibling module must not break these tests
                pass
    fake_ownership(rt)
    rt.run(SETUP)
    return rt


def identity(rt, first='John', last='Walker', dob='1990-05-01'):
    return rt.table({'firstname': first, 'lastname': last, 'dob': dob})


class Base(unittest.TestCase):
    def setUp(self):
        self.rt = server_runtime()
        self.e = self.rt.eval
        self.cb = self.e('cb')
        # the shipped config allows ONE character (owner 2026-11-06); the fixtures own two, so the flows run with 3
        self.shipped_slots = self.e('Config.Characters.defaultSlots')
        self.rt.run('Config.Characters.defaultSlots = 3')

    def call(self, name, src, *args):
        return self.cb(name, src, *args)

    def later(self, ms=6000):
        """Advance the clock past the rate-limit windows."""
        self.rt.run('Clock.now = Clock.now + %d' % ms)

    def select_and_load(self, src=1, charid='vorp:1'):
        r = self.call('characters:select', src, charid)
        self.assertTrue(r.ok, r.code)
        r2 = self.call('characters:loaded', src)
        self.assertTrue(r2.ok, r2.code)
        return r, r2


class ListTests(Base):
    def test_cards_come_from_framework_rows_with_fallbacks(self):
        r = self.call('characters:list', 1)
        self.assertTrue(r.ok, r.code)
        cards = r.data.characters
        self.assertEqual(len(cards), 2)
        john = cards[1]
        self.assertEqual((john.charid, john.name, john.firstname, john.lastname), ('vorp:1', 'John Smith', 'John', 'Smith'))
        self.assertEqual(john.age, 30)
        self.assertEqual(john.sex, 'male')
        self.assertEqual(john.lastLocation, 'رودز')                 # nearest enabled point to the stored coords
        self.assertEqual((john.job, john.cash, john.bank, john.gold), ('Rancher', 10, 5, 1))
        self.assertEqual(john.appearance.sex, 'male')
        jane = cards[2]
        self.assertEqual(jane.sex, 'female')                        # 'f' from the framework row
        self.assertIsNone(jane.lastLocation)                        # corrupt coords JSON never throws
        self.assertIsNone(jane.appearance)                          # no appearance row
        self.assertEqual(r.data.slots, 3)
        self.assertTrue(r.data.canCreate)
        self.assertTrue(r.data.deletion.enabled)
        self.assertEqual(r.data.deletion.holdTime, 5000)
        self.assertFalse(r.data.deletion.typed)

    def test_rsg_rows_and_appearance_row_fallback(self):
        self.rt.run(r'''
            Bridge.Name = 'rsg'
            owned[1] = { { charid = 'ABC123', name = 'ABC123' }, { charid = 'vorp:1', name = 'vorp:1' } }
            FakeDB.on('SELECT citizenid, charinfo, position FROM players', function() return {
                { citizenid = 'ABC123', charinfo = json.encode({ firstname = 'Sara', lastname = 'Lee', birthdate = '1995-02-03', gender = 1 }),
                  position = json.encode({ x = 2640.0, y = -1210.0, z = 52.0 }) },
                { citizenid = 'vorp:1', charinfo = 'not json', position = nil } } end)
        ''')
        cards = self.call('characters:list', 1).data.characters
        self.assertEqual((cards[1].name, cards[1].dob, cards[1].sex, cards[1].lastLocation),
                         ('Sara Lee', '1995-02-03', 'female', 'سانت دينيس'))
        self.assertIsInstance(cards[1].age, int)
        # no usable framework data: the characters_appearence row fills name / age / sex
        self.assertEqual((cards[2].firstname, cards[2].lastname, cards[2].age, cards[2].sex),
                         ('John', 'Smith', 30, 'male'))

    def test_slots_follow_ace_permissions(self):
        self.rt.run(r'''
            Config.Characters.slotPermissions = { ['w_creators.slots.vip'] = 5, ['w_creators.slots.x'] = 9 }
            function IsPlayerAceAllowed(src, ace) return ace == 'w_creators.slots.vip' end
        ''')
        self.assertEqual(self.call('characters:list', 1).data.slots, 5)
        self.assertEqual(self.e('WCCharacters.slots(1)'), 5)


class SelectTests(Base):
    def test_spoofed_charid_is_denied_and_logged(self):
        r = self.call('characters:select', 1, 'vorp:9')           # player two's character
        self.assertEqual(r.code, 'NOT_CHARACTER_OWNER')
        self.assertEqual(self.e('#loginCalls'), 0)
        self.assertEqual(self.e('countLogs("character_access_denied")'), 1)
        self.assertEqual(self.e('logs[1].payload.operation'), 'select')
        self.assertEqual(self.call('characters:select', 1, 42).code, 'INVALID_PAYLOAD')
        self.assertEqual(self.call('characters:select', 1, 'x' * 65).code, 'INVALID_PAYLOAD')

    def test_select_waits_for_the_framework_then_loaded_activates(self):
        # 1.0.8: the selector for a returning character is now the config choice lastLocation.direct = false
        self.rt.run('Config.Spawn.lastLocation.direct = false')
        self.rt.run('loginDelay = 300; lastPos = { x = 1230.0, y = -1290.0, z = 76.0 }')
        self.rt.run('CreateThread(function() r1 = cb("characters:select", 1, "vorp:1") end)')
        self.assertIsNone(self.e('r1'))                             # waiting for GetCharId == charid
        self.rt.run('tick(500); tick(200)')
        self.assertTrue(self.e('r1.ok'))
        self.assertEqual(self.e('r1.data.appearance.sex'), 'male')
        self.assertIsNone(self.e('WCCharacters.active(1)'))         # not before `loaded`
        self.assertEqual(self.e('countLogs("character_selected")'), 1)
        r = self.call('characters:loaded', 1)
        self.assertTrue(r.ok, r.code)
        self.assertEqual(r.data.spawn, 'selector')
        self.assertEqual(self.e('WCCharacters.active(1).charid'), 'vorp:1')
        self.assertEqual(self.e('WCCharacters.active(1).sex'), 'male')
        sel = self.rt.client_events('w_creators:client:selectSpawn')
        self.assertEqual(sel[0].args[1].kind, 'login')
        self.assertEqual(sel[0].args[1].last.label, 'رودز')
        remote = self.rt.client_events('w_creators:client:applyRemoteAppearance')
        self.assertEqual((remote[0].player, remote[0].args[1]), (-1, 1))
        # a repeated call replays the answer (a lost reply), without a second spawn hand-off
        again = self.call('characters:loaded', 1)
        self.assertTrue(again.ok, again.code)
        self.assertEqual(again.data.spawn, 'selector')
        self.assertEqual(len(self.rt.client_events('w_creators:client:selectSpawn')), len(sel))

    def test_login_timeout_is_a_failure_not_a_blind_wait(self):
        self.rt.run('Bridge.LoginCharacter = function(src, charid) table.insert(loginCalls, charid) return true end')
        start = self.e('Clock.now')
        r = self.call('characters:select', 1, 'vorp:1')
        self.assertEqual(r.code, 'INTERNAL_ERROR')
        self.assertGreaterEqual(self.e('Clock.now') - start, 10000)
        self.assertEqual(self.call('characters:loaded', 1).code, 'NO_CHARACTER')

    def test_rapid_double_select_logs_in_once(self):
        self.rt.run('loginDelay = 300')
        self.rt.run('CreateThread(function() r1 = cb("characters:select", 1, "vorp:1") end)')
        r2 = self.call('characters:select', 1, 'vorp:1')
        self.assertEqual(r2.code, 'BUSY')
        self.rt.run('tick(500); tick(200)')
        self.assertTrue(self.e('r1.ok'))
        r3 = self.call('characters:select', 1, 'vorp:1')           # the replay of a completed select
        self.assertTrue(r3.ok)
        self.assertEqual(self.e('#loginCalls'), 1)

    def test_missing_appearance_row_opens_the_repair_path(self):
        r = self.call('characters:select', 1, 'vorp:2')
        self.assertTrue(r.ok, r.code)
        self.assertTrue(r.data.needsAppearance)
        self.assertEqual(r.data.sex, 'female')
        self.assertTrue(self.e('WCCharacters.inFlow(1)'))
        app = self.e('S.default("female")')
        c = self.call('characters:create', 1, r.data.token, None, app)
        self.assertTrue(c.ok, c.code)
        self.assertEqual(c.data.charid, 'vorp:2')
        self.assertEqual(self.e('order[1]'), None)                  # no framework registration for a repair
        tx = self.e('FakeDB.transactions[#FakeDB.transactions]')
        self.assertIn('INSERT INTO characters_appearence', tx[1].query)
        self.assertEqual(tx[1]['values'][1], 'vorp:2')
        self.assertEqual(tx[1]['values'][3], 'Jane Doe')
        loaded = self.call('characters:loaded', 1)
        self.assertTrue(loaded.ok)
        self.assertEqual(self.rt.client_events('w_creators:client:selectSpawn')[0].args[1].kind, 'login')

    def test_database_error_is_not_a_repair(self):
        self.rt.run('FakeDB.fail = "SELECT %* FROM characters_appearence"')
        r = self.call('characters:select', 1, 'vorp:1')
        self.assertEqual(r.code, 'DATABASE_ERROR')


class CreateTests(Base):
    def begin(self, src=1):
        r = self.call('characters:beginCreate', src)
        self.assertTrue(r.ok, r.code)
        return r.data.token

    def test_create_without_grant_or_after_cancel_is_rejected(self):
        app = self.e('S.default("male")')
        self.assertEqual(self.call('characters:create', 1, 'forged', identity(self.rt), app).code, 'CREATION_NOT_GRANTED')
        token = self.begin()
        self.assertEqual(self.call('characters:beginCreate', 1).data.token, token)   # one grant per player
        self.assertTrue(self.call('characters:cancelCreate', 1, token).ok)
        self.later()
        self.assertEqual(self.call('characters:create', 1, token, identity(self.rt), app).code, 'CREATION_NOT_GRANTED')
        self.assertEqual(self.e('#registered'), 0)

    def test_grant_expires_after_thirty_minutes(self):
        token = self.begin()
        self.rt.run('Clock.now = Clock.now + 30 * 60 * 1000 + 1')
        app = self.e('S.default("male")')
        self.assertEqual(self.call('characters:create', 1, token, identity(self.rt), app).code, 'CREATION_NOT_GRANTED')

    def test_one_character_per_person_shipped(self):
        self.assertEqual(self.shipped_slots, 1)
        self.assertEqual(self.e('next(Config.Characters.slotPermissions)'), None)
        self.rt.run('Config.Characters.defaultSlots = 1')
        self.assertEqual(self.call('characters:beginCreate', 1).code, 'CHARACTER_SLOT_LIMIT')
        self.assertFalse(self.call('characters:list', 1).data.canCreate)

    def test_slot_limit(self):
        self.rt.run('Config.Characters.defaultSlots = 2')
        self.assertEqual(self.call('characters:beginCreate', 1).code, 'CHARACTER_SLOT_LIMIT')
        self.assertFalse(self.call('characters:list', 1).data.canCreate)
        self.rt.run('Config.Characters.defaultSlots = 3')
        self.later()
        token = self.begin()
        self.rt.run('table.insert(owned[1], { charid = "vorp:3", name = "Late Row" })')   # filled meanwhile
        r = self.call('characters:create', 1, token, identity(self.rt), self.e('S.default("male")'))
        self.assertEqual(r.code, 'CHARACTER_SLOT_LIMIT')
        self.assertEqual(self.e('#registered'), 0)

    def test_creation_disabled(self):
        self.rt.run('Config.Services.characterCreation = false')
        self.assertEqual(self.call('characters:beginCreate', 1).code, 'CREATION_DISABLED')

    def test_invalid_names_and_dob_are_rejected(self):
        token = self.begin()
        app = self.e('S.default("male")')
        cases = [(('J', 'Walker', '1990-05-01'), 'INVALID_NAME'), (('John3', 'Walker', '1990-05-01'), 'INVALID_NAME'),
                 (('John', '<b>x</b>', '1990-05-01'), 'INVALID_NAME'), (('John', 'Walker', '1990-02-30'), 'INVALID_DOB'),
                 (('John', 'Walker', '2020-01-01'), 'INVALID_DOB'), (('John', 'Walker', 'yesterday'), 'INVALID_DOB')]
        for (first, last, dob), code in cases:
            self.later()
            r = self.call('characters:create', 1, token, identity(self.rt, first, last, dob), app)
            self.assertEqual(r.code, code, (first, last, dob))
        self.later()
        self.assertEqual(self.call('characters:create', 1, token, None, app).code, 'INVALID_PAYLOAD')
        self.assertEqual(self.e('#registered'), 0)

    def test_create_fires_character_created_before_registration_and_writes_one_transaction(self):
        self.rt.run('Config.Creator.startingClothing.categories = { "shirts_full", "boots" }')
        token = self.begin()
        app = self.e('S.default("male")')
        r = self.call('characters:create', 1, token, identity(self.rt), app)
        self.assertTrue(r.ok, r.code)
        self.assertEqual(list(self.e('order').values()), ['characterCreated', 'register'])
        self.assertEqual(self.e('registered[1].firstname'), 'John')
        self.assertEqual(self.e('registered[1].dob'), '1990-05-01')
        self.assertTrue(self.e('registered[1].isMale'))
        charid = r.data.charid
        self.assertEqual(charid, 'vorp:101')
        # pants were not a starting category: dropped from the new appearance
        self.assertIsNone(r.data.appearance.clothing.equipped.pants)
        self.assertIsNotNone(r.data.appearance.clothing.equipped.shirts_full)
        txs = self.e('FakeDB.transactions')
        self.assertEqual(len(txs), 1)
        tx = txs[1]
        self.assertIn('INSERT INTO characters_appearence', tx[1].query)
        grants = [tx[i] for i in range(2, len(tx) + 1)]
        self.assertEqual(len(grants), 2)
        for q in grants:
            self.assertIn('w_creators_clothes', q.query)
            self.assertIn('starter', q.query + ' ' + ' '.join(str(v) for v in q['values'].values()))
            self.assertEqual(q['values'][1], charid)
        self.assertEqual(self.e('countLogs("character_created")'), 1)
        # a repeated create answers the same result without a second registration
        again = self.call('characters:create', 1, token, identity(self.rt), app)
        self.assertTrue(again.ok)
        self.assertEqual(again.data.charid, charid)
        self.assertEqual(self.e('#registered'), 1)
        loaded = self.call('characters:loaded', 1)
        self.assertTrue(loaded.ok, loaded.code)
        sel = self.rt.client_events('w_creators:client:selectSpawn')[0].args[1]
        self.assertEqual(sel.kind, 'initial')
        self.assertIsNone(sel.last)
        self.assertEqual(self.e('WCCharacters.active(1).charid'), charid)

    def test_failed_appearance_insert_retries_without_a_second_framework_character(self):
        token = self.begin()
        app = self.e('S.default("male")')
        self.rt.run('FakeDB.transactionOk = false')
        r = self.call('characters:create', 1, token, identity(self.rt), app)
        self.assertEqual(r.code, 'DATABASE_ERROR')
        self.assertEqual(self.e('#registered'), 1)
        self.rt.run('FakeDB.transactionOk = true')
        self.later()
        r = self.call('characters:create', 1, token, identity(self.rt), app)
        self.assertTrue(r.ok, r.code)
        self.assertEqual(r.data.charid, 'vorp:101')
        self.assertEqual(self.e('#registered'), 1)
        self.assertEqual(list(self.e('order').values()), ['characterCreated', 'register'])

    def test_presets_mode_accepts_only_a_configured_preset(self):
        self.rt.run(r'''
            Config.Creator.startingClothing.mode = 'presets'
            presetApp = S.default('male')
            presetApp.clothing.equipped = {
                shirts_full = WCCatalog.resolve('male', 'shirts_full', { model = 1, variant = 1 }),
                pants = WCCatalog.resolve('male', 'pants', { model = 1, variant = 1 }),
                boots = WCCatalog.resolve('male', 'boots', { model = 1, variant = 1 }) }
            otherApp = S.default('male')
            otherApp.clothing.equipped.hats = WCCatalog.resolve('male', 'hats', { model = 1, variant = 1 })
        ''')
        token = self.begin()
        self.assertEqual(self.call('characters:create', 1, token, identity(self.rt), self.e('otherApp')).code,
                         'INVALID_COMPONENT')
        self.later()
        r = self.call('characters:create', 1, token, identity(self.rt), self.e('presetApp'))
        self.assertTrue(r.ok, r.code)

    def test_sex_is_the_granted_one_and_grooming_is_server_owned(self):
        self.rt.run('femaleApp = S.default("female"); femaleApp.grooming = { hair = { stage = 5, seconds = 99 } }')
        r = self.call('characters:beginCreate', 1, 'male')
        r = self.call('characters:create', 1, r.data.token, identity(self.rt), self.e('femaleApp'))
        self.assertTrue(r.ok, r.code)
        self.assertEqual(r.data.appearance.sex, 'male')
        self.assertIsNone(r.data.appearance.grooming.hair)
        self.assertFalse(self.e('registered[1].isMale == false'))

    def test_oversized_payload(self):
        token = self.begin()
        self.rt.run('big = S.default("male"); big.junk = string.rep("x", 70000)')
        self.assertEqual(self.call('characters:create', 1, token, identity(self.rt), self.e('big')).code,
                         'INVALID_PAYLOAD')


class DeleteTests(Base):
    def test_spoofed_delete_is_denied_and_logged(self):
        r = self.call('characters:delete', 1, 'vorp:9')
        self.assertEqual(r.code, 'NOT_CHARACTER_OWNER')
        self.assertEqual(self.e('countLogs("character_access_denied")'), 1)
        self.assertEqual(self.e('logs[1].payload.operation'), 'delete')
        self.assertEqual(self.e('#FakeDB.transactions'), 0)

    def test_delete_removes_appearance_clothes_and_outfits(self):
        r = self.call('characters:delete', 1, 'vorp:1')
        self.assertTrue(r.ok, r.code)
        tx = self.e('FakeDB.transactions[1]')
        sqls = [tx[i].query for i in range(1, len(tx) + 1)]
        self.assertTrue(any('characters_appearence' in s for s in sqls))
        self.assertTrue(any('w_creators_clothes' in s for s in sqls))
        self.assertTrue(any('w_creators_outfits' in s for s in sqls))
        self.assertTrue(any('DELETE FROM characters WHERE charidentifier' in q.sql
                            for q in self.e('FakeDB.queries').values()))

    def test_typed_confirmation(self):
        self.rt.run('Config.Characters.deletion.typedConfirmation = true')
        self.assertTrue(self.call('characters:list', 1).data.deletion.typed)
        self.assertEqual(self.call('characters:delete', 1, 'vorp:1').code, 'DELETE_CONFIRMATION_REQUIRED')
        self.assertEqual(self.call('characters:delete', 1, 'vorp:1', 'John Smyth').code, 'DELETE_CONFIRMATION_REQUIRED')
        self.later(11000)
        self.assertEqual(self.e('#FakeDB.transactions'), 0)
        self.assertTrue(self.call('characters:delete', 1, 'vorp:1', '  john   smith ').ok)

    def test_delete_disabled_and_not_while_playing(self):
        self.rt.run('Config.Characters.deletion.enabled = false')
        self.assertEqual(self.call('characters:delete', 1, 'vorp:1').code, 'DELETE_DISABLED')
        self.rt.run('Config.Characters.deletion.enabled = true')
        self.select_and_load(1, 'vorp:1')
        self.later(11000)
        self.assertEqual(self.call('characters:delete', 1, 'vorp:2').code, 'BUSY')


class SwitchTests(Base):
    def test_switch_forgets_the_remote_appearance_and_clears_active(self):
        self.select_and_load(1, 'vorp:1')
        self.rt.run('SpawnPending[1] = nil')
        r = self.call('characters:list', 1)
        self.assertTrue(r.ok, r.code)
        self.assertIsNone(self.e('WCCharacters.active(1)'))
        self.assertTrue(self.e('WCCharacters.isSwitching(1)'))
        forget = self.rt.client_events('w_creators:client:forgetRemote')
        self.assertEqual((forget[0].player, forget[0].args[1]), (-1, 1))
        self.assertIsNone(self.e('WCSync.get(1)'))
        self.later()
        self.select_and_load(1, 'vorp:1')
        self.assertEqual(self.rt.client_events('w_creators:client:selectSpawn')[-1].args[1].kind, 'switch')
        self.assertFalse(self.e('WCCharacters.isSwitching(1)'))

    def test_switch_refused_while_dead_in_a_session_or_disabled(self):
        self.select_and_load(1, 'vorp:1')
        self.rt.run('dead[1] = true')
        self.assertEqual(self.call('characters:list', 1).code, 'BUSY')
        self.assertEqual(self.call('characters:select', 1, 'vorp:2').code, 'BUSY')
        self.assertEqual(self.call('characters:beginCreate', 1).code, 'BUSY')
        self.assertEqual(self.e('WCCharacters.active(1).charid'), 'vorp:1')
        self.rt.run('dead[1] = nil; Players[1].coords = vector3(-326.17, 773.757, 117.5)')
        self.later(11000)
        self.assertTrue(self.e('WCSessions.open(1, "store", { locationId = "valentine_clothing" }).ok'))
        self.assertEqual(self.call('characters:list', 1).code, 'BUSY')
        self.rt.run('WCSessions.clear(1, "close")')
        self.rt.run('Config.Characters.allowSwitch = false')
        self.later(11000)
        self.assertEqual(self.call('characters:list', 1).code, 'SERVICE_DISABLED')
        self.assertEqual(self.e('WCCharacters.active(1).charid'), 'vorp:1')
        self.assertEqual(len(self.rt.client_events('w_creators:client:forgetRemote')), 0)

    def test_drop_clears_state_after_the_tick(self):
        self.select_and_load(1, 'vorp:1')
        self.rt.run('fireEvent("playerDropped", 1)')
        self.assertEqual(self.e('WCCharacters.active(1).charid'), 'vorp:1')   # readable by later drop handlers
        self.rt.run('tick(0)')
        self.assertIsNone(self.e('WCCharacters.active(1)'))
        self.assertIsNone(self.e('WCSync.get(1)'))

    def test_sessions_use_the_active_character(self):
        self.assertIsNone(self.e('WCSessions.activeCharacter(1)'))
        self.select_and_load(1, 'vorp:1')
        self.assertEqual(self.e('WCSessions.activeCharacter(1).charid'), 'vorp:1')



class ReviewRegressionTests(Base):
    """Regressions of the review findings (grant/active races, deletion of a logged-in character,
    unverified deletions)."""

    def test_begin_create_holds_the_lock_so_no_grant_survives_into_play(self):
        self.rt.run(r'''
            loginDelay = 300
            local base, calls = Bridge.GetCharacters, 0
            Bridge.GetCharacters = function(src)
                calls = calls + 1
                if calls == 1 then Wait(100) end
                return base(src)
            end
            results = {}
            CreateThread(function() results.begin = cb('characters:beginCreate', 1) end)
            CreateThread(function() results.select = cb('characters:select', 1, 'vorp:1') end)
            tick(50) tick(100) tick(400)
        ''')
        self.assertTrue(self.e('results.begin.ok'))
        self.assertEqual(self.e('results.select.code'), 'BUSY')             # refused while beginCreate yields
        self.assertIsNone(self.e('WCCharacters.active(1)'))

    def test_activation_drops_the_grant_and_create_refuses_an_active_player(self):
        token = self.call('characters:beginCreate', 1).data.token
        self.rt.run('WCCharacters.setActive(1, "vorp:1", "male")')
        self.assertFalse(self.e('WCCharacters.inFlow(1)'))
        self.rt.run('Config.Characters.allowSwitch = false; dead[1] = true')
        r = self.call('characters:create', 1, token, identity(self.rt), self.e('S.default("male")'))
        self.assertEqual(r.code, 'CREATION_NOT_GRANTED')
        self.assertEqual(self.e('#registered'), 0)
        self.assertEqual(self.e('WCScene.isolate(1).code'), 'SESSION_NOT_FOUND')

    def test_in_flow_is_false_for_an_active_player_even_with_a_stale_grant(self):
        self.select_and_load(1, 'vorp:1')
        self.assertFalse(self.e('WCCharacters.inFlow(1)'))

    def test_the_character_the_framework_still_has_logged_in_cannot_be_deleted(self):
        self.select_and_load(1, 'vorp:1')
        self.rt.run('SpawnPending[1] = nil')
        self.later(11000)
        self.assertTrue(self.call('characters:list', 1).ok)                 # switch: active cleared
        self.assertEqual(self.e('charids[1]'), 'vorp:1')                    # the framework keeps it
        self.assertEqual(self.call('characters:delete', 1, 'vorp:1').code, 'BUSY')
        self.assertEqual(self.e('#FakeDB.transactions'), 0)
        self.assertTrue(self.call('characters:delete', 1, 'vorp:2').ok)     # another character is fine

    def test_repair_character_cannot_be_deleted_while_logged_in(self):
        self.rt.run('rows["vorp:2"] = nil')
        r = self.call('characters:select', 1, 'vorp:2')
        self.assertTrue(r.data.needsAppearance)
        self.assertEqual(self.call('characters:delete', 1, 'vorp:2').code, 'BUSY')

    def test_delete_reports_a_framework_row_that_survived(self):
        self.rt.run('keepFrameworkRow = true')
        self.assertEqual(self.call('characters:delete', 1, 'vorp:1').code, 'DATABASE_ERROR')

    def test_delete_reports_a_failed_appearance_transaction(self):
        self.rt.run('FakeDB.transactionOk = false')
        self.assertEqual(self.call('characters:delete', 1, 'vorp:1').code, 'DATABASE_ERROR')
        self.later(11000)
        self.rt.run('FakeDB.transactionOk = true')
        before = self.e('#FakeDB.transactions')
        self.assertTrue(self.call('characters:delete', 1, 'vorp:1').ok)       # the retry finishes the cleanup
        self.assertEqual(self.e('#FakeDB.transactions'), before + 1)
        self.assertEqual(self.e('countLogs("character_access_denied")'), 0)
        self.later(11000)
        self.assertEqual(self.call('characters:delete', 1, 'vorp:1').code, 'NOT_CHARACTER_OWNER')  # cleanup done once

    def test_a_failed_appearance_cleanup_is_retried_when_the_player_drops(self):
        self.rt.run('FakeDB.transactionOk = false')
        self.assertEqual(self.call('characters:delete', 1, 'vorp:1').code, 'DATABASE_ERROR')
        self.rt.run('FakeDB.transactionOk = true')
        before = self.e('#FakeDB.transactions')
        self.rt.run('fireEvent("playerDropped", 1); tick(0)')
        self.assertEqual(self.e('#FakeDB.transactions'), before + 1)


class OptionalLoggingTests(Base):
    """The optional logger never blocks selection -> spawn (ported from the pre-v3 test_optional_logging)."""

    def test_throwing_logger_does_not_block_selection_or_spawn(self):
        self.rt.run("CreatorLogs.Emit = function() error('logger transport unavailable') end")
        self.assertTrue(self.call('scene:prepare', 1).ok)
        self.select_and_load(1, 'vorp:1')
        self.assertTrue(self.e('SpawnPending[1]'))
        self.assertEqual(self.e('Players[1].bucket'), 1, 'isolation kept until a spawn is chosen')
        r = self.call('spawn:choose', 1, 'valentine')
        self.assertTrue(r.ok, r.code)
        self.assertEqual(self.e('Players[1].bucket'), 0)
        self.assertEqual(len(self.rt.client_events('w_creators:client:spawn')), 1)

    def test_locale_key_of_the_admin_feedback_is_translated(self):
        import json
        from harness import RESOURCE
        data = json.loads((RESOURCE / 'locales' / 'en.json').read_text(encoding='utf-8'))
        self.assertIn('تمت إعادة إظهار اللاعب', data)

if __name__ == '__main__':
    unittest.main()
