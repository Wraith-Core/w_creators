"""Review round 3 — server fixes (regressions for the triaged server findings).

0   rsg / qbr: a login over a logged-in character saves it on the server first and waits for the
    write (never an unsaved Logout); re-selecting the logged-in character never logs it in again
1   VORP registration accepts only a NEW character id (never the newest existing row), and a
    creation is never bound to a charid the player already had
2   every switch lapses (a pending creation / repair too) and a lapsed switch cannot be restarted
    at once (cooldown + security_violation)
3   clothingActions off: no submitted clothing state is persisted (wardrobe, outfits, creation)
7   runtime clothing states are forgotten when the character is cleared (switch)
11  SetSkin refuses out-of-range bodyScale / expressions / overlay opacity (never clamps)
12  a degraded repair tells the client the only sections it saves (no clothing stage)
14  a load that read a pre-save row never caches it over the entry a save wrote after its commit
15  a v3 SetSkin payload keeps every section / field it leaves out as saved
16  a stored overlay layer of the other sex (pre-v3 female beard shadow) survives the upgrade
17  rsg / qbr: a failed character listing is a DATABASE_ERROR, never "the row is gone"
18  a v3 row with an unreadable JSON is recovered without 'legacy' ownership grants
19  §6.1 documents the projection fingerprint / reconcile
32  a player who drops while select / create yields leaves nothing behind
"""
import json
import os
import sys
import unittest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from harness import RESOURCE  # noqa: E402
from test_server_characters_flow import server_runtime, identity  # noqa: E402
from test_server_characters_world import ENTITIES  # noqa: E402
from test_server_commerce_wardrobe import wardrobe  # noqa: E402
from test_server_services_barber import services_server  # noqa: E402
from test_server_core import server as core_server  # noqa: E402


# ---------------------------------------------------------------------------------------------
# 0  rsg / qbr: save before the logout
# ---------------------------------------------------------------------------------------------
RSG_SAVE = r'''
Bridge.Name = 'rsg'
calls = {}
playersRow = { job = json.encode({ name = 'sheriff' }), gang = json.encode({ name = 'none' }),
               metadata = json.encode({ hunger = 50 }), money = json.encode({ cash = 100 }) }
saveLatency, saveLands = 250, true
loggedIn = {
    PlayerData = { citizenid = 'CID1', job = { name = 'unemployed' }, gang = { name = 'none' },
                   metadata = { hunger = 42.5 }, money = { cash = 20 } },
    Functions = {},
}
loggedIn.Functions.Save = function()
    table.insert(calls, 'save')
    local snapshot = {
        job = json.encode(loggedIn.PlayerData.job), gang = json.encode(loggedIn.PlayerData.gang),
        metadata = json.encode(loggedIn.PlayerData.metadata), money = json.encode(loggedIn.PlayerData.money) }
    if saveLands then pendingWrite = { at = Clock.now + saveLatency, row = snapshot } end
end
current = loggedIn
FakeDB.on('FROM players WHERE citizenid', function()
    if pendingWrite and Clock.now >= pendingWrite.at then playersRow, pendingWrite = pendingWrite.row, nil end
    return { playersRow }
end)
fakeRsg = {
    Functions = { GetPlayer = function() return current end },
    Player = {
        Logout = function() table.insert(calls, 'logout') current = nil end,
        Login = function(src, cid, data)
            table.insert(calls, 'login')
            loginRow = playersRow
            return true
        end,
    },
}
w.framework = { getCore = function() return fakeRsg end }
'''


class SaveBeforeLogoutTests(unittest.TestCase):
    def setUp(self):
        self.rt = core_server()
        self.rt.run(RSG_SAVE)
        self.e = self.rt.eval

    def calls(self):
        return list(self.e('calls').values())

    def test_the_logged_in_character_is_saved_and_confirmed_before_the_logout(self):
        self.rt.run('ok1 = Bridge.LoginCharacter(1, "CID2")')
        self.assertTrue(self.e('ok1'))
        self.assertEqual(self.calls(), ['save', 'logout', 'login'])
        # the login read the row the save wrote: the job change was not rolled back
        self.assertEqual(json.loads(self.e('loginRow.job'))['name'], 'unemployed')
        self.assertEqual(json.loads(self.e('loginRow.money'))['cash'], 20)
        self.assertGreater(self.e('FakeDB.count("FROM players WHERE citizenid")'), 1, 'the write was awaited')

    def test_an_unconfirmed_save_refuses_the_login(self):
        self.rt.run('saveLands = false; ok1 = Bridge.LoginCharacter(1, "CID2")')
        self.assertFalse(self.e('ok1'))
        self.assertEqual(self.calls(), ['save'], 'no logout, no login: the character stays')

    def test_a_creation_mid_switch_saves_too(self):
        self.rt.run('''
            Bridge.GetCharacters = function() return {} end
            Bridge.RegisterCharacter(1, { firstname = 'John', lastname = 'Smith', age = 28, isMale = true })
        ''')
        self.assertEqual(self.calls()[:3], ['save', 'logout', 'login'])

    def test_no_logged_in_character_nothing_to_save(self):
        self.rt.run('current = nil; ok1 = Bridge.LoginCharacter(1, "CID2")')
        self.assertTrue(self.e('ok1'))
        self.assertEqual(self.calls(), ['login'])

    def test_w_core_does_not_compare_the_stale_money_column(self):
        self.rt.run('''
            local real = GetResourceState
            GetResourceState = function(name) if name == 'w_core' then return 'started' end return real(name) end
            rawset(exports, 'w_lib', { FwName = function() return 'w_core' end, FwBackend = function() return 'wcore' end })
            loggedIn.Functions.Save = function()
                table.insert(calls, 'save')
                pendingWrite = { at = Clock.now, row = { job = json.encode(loggedIn.PlayerData.job),
                    gang = json.encode(loggedIn.PlayerData.gang), metadata = json.encode(loggedIn.PlayerData.metadata),
                    money = playersRow.money } }
            end
            ok1 = Bridge.LoginCharacter(1, "CID2")
        ''')
        self.assertTrue(self.e('ok1'))


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

    def activate(self, src=1, charid='vorp:1'):
        self.assertTrue(self.call('characters:select', src, charid).ok)
        r = self.call('characters:loaded', src)
        self.assertTrue(r.ok, r.code)
        return r

    def in_world(self):
        self.activate()
        self.rt.run('WCSpawnServer.cancel(1); WCScene.toWorld(1); Players[1].coords = vector3(1230.0, -1290.0, 76.0)')
        self.later()

    def active(self):
        a = self.e('WCCharacters.active(1)')
        return a.charid if a else None

    def past_grace(self):
        self.later(self.e('WCScene.ROOM_GRACE_MS') + 1000)


class ReselectTests(Flow):
    def test_reselecting_the_logged_in_character_never_logs_in_again(self):
        self.activate()
        self.assertEqual(self.e('#loginCalls'), 1)
        self.later()
        self.assertTrue(self.call('characters:list', 1).ok)          # switch started
        self.later()
        self.assertTrue(self.call('characters:select', 1, 'vorp:1').ok)
        self.assertEqual(self.e('#loginCalls'), 1, 'no logout / login of the same character')
        self.assertTrue(self.call('characters:loaded', 1).ok)
        self.assertEqual(self.active(), 'vorp:1')

    def test_another_character_is_still_logged_in(self):
        self.rt.run("rows['vorp:2'] = { id = 12, charid = 'vorp:2', appearance = json.encode(S.default('female')), appearance_version = 3 }")
        self.activate()
        self.later()
        self.assertTrue(self.call('characters:select', 1, 'vorp:2').ok)
        self.assertEqual(self.e('#loginCalls'), 2)


# ---------------------------------------------------------------------------------------------
# 1 / 13  VORP registration: only a new id
# ---------------------------------------------------------------------------------------------
VORP_REGISTER = r'''
Bridge.Name = 'vorp'
used, added = {}, {}
vorpRows = { { charidentifier = 5 }, { charidentifier = 7 } }
insertLatency, insertLands, addThrows = 250, true, false
local user = {
    addCharacter = function(d)
        if addThrows then error('vorp down') end
        table.insert(added, d)
        if insertLands then pendingInsert = { at = Clock.now + insertLatency, id = 8 } end
    end,
    setUsedCharacter = function(id) table.insert(used, id) end,
}
w.framework = { getCore = function() return { getUser = function() return user end } end }
Bridge.GetLicense = function() return 'steam:1' end
FakeDB.on('SELECT charidentifier FROM characters WHERE identifier', function()
    if pendingInsert and Clock.now >= pendingInsert.at then
        table.insert(vorpRows, { charidentifier = pendingInsert.id }) pendingInsert = nil
    end
    local out = {}
    for i, r in ipairs(vorpRows) do out[i] = { charidentifier = r.charidentifier } end
    return out
end)
'''


class VorpRegisterTests(unittest.TestCase):
    def setUp(self):
        self.rt = core_server()
        self.rt.run(VORP_REGISTER)
        self.e = self.rt.eval

    def register(self):
        self.rt.run("id1 = Bridge.RegisterCharacter(1, { firstname = 'John', lastname = 'Smith', age = 28, isMale = true })")
        return self.e('id1')

    def test_a_slow_insert_answers_the_new_id(self):
        self.assertEqual(self.register(), 'vorp:8')
        self.assertEqual(list(self.e('used').values()), [8])

    def test_no_new_row_is_a_failure_never_the_newest_existing_one(self):
        self.rt.run('insertLands = false')
        self.assertIsNone(self.register())
        self.assertEqual(self.e('#used'), 0)

    def test_a_throwing_add_character_fails(self):
        self.rt.run('addThrows = true')
        self.assertIsNone(self.register())
        self.assertEqual(self.e('#used'), 0)

    def test_an_unreadable_listing_before_the_add_fails(self):
        self.rt.run('FakeDB.fail = "SELECT charidentifier FROM characters WHERE identifier"')
        self.assertIsNone(self.register())
        self.assertEqual(self.e('#added'), 0, 'nothing registered blindly')


class ExistingCharidTests(Flow):
    def test_a_registration_answering_an_existing_character_is_refused(self):
        self.rt.run('''
            Bridge.RegisterCharacter = function(src, data) table.insert(registered, data) charids[src] = 'vorp:1' return 'vorp:1' end
            Config.Creator.startingClothing.categories = '*'
        ''')
        r = self.call('characters:beginCreate', 1)
        self.assertTrue(r.ok, r.code)
        tx = self.e('#FakeDB.transactions')
        c = self.call('characters:create', 1, r.data.token, identity(self.rt), self.e('S.default("male")'))
        self.assertEqual(c.code, 'INTERNAL_ERROR')
        self.assertEqual(self.e('#FakeDB.transactions'), tx, 'no appearance row / grants for vorp:1')
        self.assertEqual(self.e('countLogs("character_create_failed")'), 1)


# ---------------------------------------------------------------------------------------------
# 2  Every switch lapses; no immediate restart
# ---------------------------------------------------------------------------------------------
class LapseTests(Flow):
    def test_a_pending_creation_is_finished_when_the_switch_lapses(self):
        self.in_world()
        r = self.call('characters:beginCreate', 1, 'male')
        self.assertTrue(r.ok, r.code)
        self.later()
        c = self.call('characters:create', 1, r.data.token, identity(self.rt), self.e('S.default("male")'))
        self.assertTrue(c.ok, c.code)
        self.assertIsNone(self.active())
        self.past_grace()
        self.rt.run('WCCharacters.checkSwitches()')
        self.assertEqual(self.active(), c.data.charid)
        self.assertIsNotNone(self.e('WCSync.get(1)'))
        self.assertFalse(self.e('WCCharacters.isSwitching(1)'))
        self.assertEqual(self.e('countLogs("security_violation")') >= 1, True)

    def test_an_open_creation_grant_is_cancelled_and_the_old_character_restored(self):
        self.in_world()
        self.assertTrue(self.call('characters:beginCreate', 1, 'male').ok)
        self.past_grace()
        self.rt.run('WCCharacters.checkSwitches()')
        self.assertEqual(self.active(), 'vorp:1')
        self.assertFalse(self.e('WCCharacters.inFlow(1)'))

    def test_a_provisioned_creation_logs_the_old_character_in_again(self):
        self.in_world()
        r = self.call('characters:beginCreate', 1, 'male')
        self.later()
        self.rt.run('FakeDB.transactionOk = false')                  # the appearance write fails
        c = self.call('characters:create', 1, r.data.token, identity(self.rt), self.e('S.default("male")'))
        self.assertFalse(c.ok)
        self.rt.run('FakeDB.transactionOk = true')
        self.assertEqual(self.e('charids[1]'), 'vorp:101')
        self.past_grace()
        self.rt.run('WCCharacters.checkSwitches(); tick(1000)')
        self.assertEqual(self.e('charids[1]'), 'vorp:1')
        self.assertEqual(self.active(), 'vorp:1')

    def test_a_lapsed_switch_cannot_be_restarted_at_once(self):
        self.in_world()
        self.assertTrue(self.call('characters:list', 1).ok)
        self.past_grace()
        self.rt.run('WCCharacters.checkSwitches()')
        self.assertEqual(self.active(), 'vorp:1')
        forgets = len(self.rt.client_events('w_creators:client:forgetRemote'))
        self.later()
        self.assertEqual(self.call('characters:list', 1).code, 'BUSY')
        self.assertEqual(self.active(), 'vorp:1')
        self.assertEqual(len(self.rt.client_events('w_creators:client:forgetRemote')), forgets)
        self.later(self.e('WCCharacters.SWITCH_LAPSE_COOLDOWN_MS'))
        self.assertTrue(self.call('characters:list', 1).ok)


# ---------------------------------------------------------------------------------------------
# 3 / 22  clothingActions off: no state persisted
# ---------------------------------------------------------------------------------------------
class StatesOffTests(unittest.TestCase):
    def setUp(self):
        self.rt = wardrobe()
        self.e = self.rt.eval
        self.rt.run('''
            own('vorp:1', 'hats', hat)
            base = saved(); base.clothing.equipped.hats = hat; setSaved('vorp:1', base)
            Config.Services.clothingActions = false
            r = openWardrobe(1, 'valentine_wardrobe'); wardrobeToken = r.data.token
        ''')
        self.assertTrue(self.e('r.ok'), self.e('r.code'))

    def test_the_wardrobe_commit_keeps_the_saved_states(self):
        self.assertEqual(self.e('WCClothingActions.setState(1, "hat", "off").code'), 'ACTIONS_DISABLED')
        self.assertEqual(self.e('saved().clothing.equipped.hats'), self.e('hat'))
        self.rt.run('a = working(); a.clothing.states = { hat = "off" }; res = wear(a)')
        self.assertEqual(self.e('res.code'), 'NO_CHANGES')
        self.assertIsNone(self.e('saved().clothing.states.hat'))
        # a real change commits, and still no state
        self.rt.run('a = working(); a.clothing.equipped.hats = nil; a.clothing.states = { hat = "off" }; res = wear(a)')
        self.assertTrue(self.e('res.ok'), self.e('res.code'))
        self.assertIsNone(self.e('saved().clothing.states.hat'))

    def test_an_outfit_stores_no_state(self):
        self.rt.run('eq = working().clothing.equipped; o = outfit("save", wardrobeToken, "x", eq, { hat = "off" })')
        self.assertTrue(self.e('o.ok'), self.e('o.code'))
        data = self.e('WCOutfits.validateData("vorp:1", "male", eq, { hat = "off" }, eq)')
        self.assertEqual(self.rt.py(data.states), {})

    def test_on_again_the_state_persists(self):
        self.rt.run('Config.Services.clothingActions = true; a = working(); a.clothing.states = { hat = "off" }; res = wear(a)')
        self.assertTrue(self.e('res.ok'), self.e('res.code'))
        self.assertEqual(self.e('saved().clothing.states.hat'), 'off')


# ---------------------------------------------------------------------------------------------
# 7  runtime states forgotten on a clear
# ---------------------------------------------------------------------------------------------
class RuntimeClearTests(unittest.TestCase):
    def test_a_switch_forgets_the_raised_bandana(self):
        rt = services_server()
        rt.load('server/clothing/states.lua')
        rt.run('''
            base = S.default('male'); base.clothing.equipped.neckwear = h('male', 'neckwear', 1)
            setSaved(base)
            r = WCClothingActions.setState(1, 'bandana', 'up')
        ''')
        self.assertTrue(rt.eval('r.ok'), rt.eval('r.code'))
        self.assertEqual(rt.eval('WCClothingActions.states(1, nil, "vorp:1").bandana'), 'up')
        rt.run('TriggerEvent("w_creators:server:characterCleared", 1, "vorp:1", "switch")')
        self.assertIsNone(rt.eval('WCClothingActions.states(1, nil, "vorp:1").bandana'))
        self.assertIsNone(rt.eval('WCSync.withRuntimeStates(1, base, "vorp:1").clothing.states.bandana'))


# ---------------------------------------------------------------------------------------------
# 11 / 15 / 16  SetSkin
# ---------------------------------------------------------------------------------------------
class SetSkinTests(unittest.TestCase):
    def setUp(self):
        self.rt = services_server()
        self.e = self.rt.eval

    def skin(self, lua):
        self.rt.run('Clock.now = Clock.now + 11000; r = WCApi.SetSkin(1, %s, false)' % lua)
        return self.e('r')

    def test_out_of_range_values_are_refused(self):
        for lua, code in (('{ bodyScale = 1.5 }', 'INVALID_PAYLOAD'), ('{ bodyScale = 0.2 }', 'INVALID_PAYLOAD'),
                          ('{ expressions = { jawWidth = 250 } }', 'INVALID_PAYLOAD'),
                          ('{ overlays = { blush = { id = 1, opacity = 250 } } }', 'INVALID_COMPONENT')):
            r = self.skin(lua)
            self.assertFalse(r.ok, lua)
            self.assertEqual(r.code, code, lua)

    def test_in_range_values_still_pass(self):
        r = self.skin('{ bodyScale = 1.05, expressions = { jawWidth = 50 }, overlays = { blush = { id = 1, opacity = 50 } } }')
        self.assertTrue(r.ok, r.code)
        self.assertAlmostEqual(r.data.appearance.body.height, 1.05)
        self.assertAlmostEqual(r.data.appearance.morph.jawWidth, 0.5)
        self.assertAlmostEqual(r.data.appearance.overlays.blush.opacity, 0.5)

    def test_a_partial_v3_payload_keeps_what_it_leaves_out(self):
        self.rt.run('''
            local app = WCUtil.copy(savedApp)
            app.morph.jawWidth = 0.3; app.body.height = 1.08; app.body.weight = 4
            app.overlays.blush = { style = 2, color = 5, opacity = 0.5 }
            savedApp = app; setSaved(app)
            WCAppearanceRepo.invalidate('vorp:1')
            hs = h('male', 'hair', 2)
        ''')
        r = self.skin('{ version = 3, sex = "male", hair = { style = hs, facial = 0 } }')
        self.assertTrue(r.ok, r.code)
        app = r.data.appearance
        self.assertEqual(app.hair.style, self.e('hs'))
        self.assertAlmostEqual(app.morph.jawWidth, 0.3)
        self.assertAlmostEqual(app.body.height, 1.08)
        self.assertEqual(app.body.weight, 4)
        self.assertEqual(app.overlays.blush.style, 2)
        self.assertIsNotNone(app.overlays.eyebrows)

    def test_a_female_beard_shadow_is_kept_as_stored_but_never_added(self):
        self.rt.run('''
            fem = S.default('female'); fem.overlays.beardstabble = { style = 1, color = 2, opacity = 0.4 }
            kept = S.sanitize(fem, { rules = false })
            edited = S.sanitize(fem)
            base = S.default('female')
            merged = S.mergeSections(base, fem, { 'facialHair', 'hair' })
            mergedKeep = S.mergeSections(kept, S.default('female'), { 'facialHair', 'hair' })
        ''')
        self.assertIsNotNone(self.e('kept.overlays.beardstabble'))
        self.assertIsNone(self.e('edited.overlays.beardstabble'))
        self.assertIsNone(self.e('merged.overlays.beardstabble'), 'a submission never adds it')
        self.assertIsNotNone(self.e('mergedKeep.overlays.beardstabble'), 'the stored one stays')


class LegacyFemaleOverlayTests(unittest.TestCase):
    def test_the_upgrade_keeps_the_female_beard_shadow(self):
        rt = core_server()
        rt.run(r'''
            fem = S.default('female'); fem.overlays.beardstabble = { style = 1, color = 2, opacity = 0.4 }
            legacy = S.toLegacy(fem)
            up, meta = S.fromLegacy({ isMale = 0, components = legacy.components, faceFeatures = legacy.faceFeatures,
                                      overlays = legacy.overlays })
        ''')
        self.assertIsNotNone(rt.eval('up.overlays.beardstabble'))


# ---------------------------------------------------------------------------------------------
# 12  degraded repair sections
# ---------------------------------------------------------------------------------------------
class DegradedSectionsTests(Flow):
    def test_select_hands_out_the_repair_sections(self):
        self.rt.run(r'''
            broken = S.default('male'); broken.head.head = 12345
            rows['vorp:2'] = { id = 12, charid = 'vorp:2', isMale = 1, appearance = json.encode(broken), appearance_version = 3 }
        ''')
        r = self.call('characters:select', 1, 'vorp:2')
        self.assertTrue(r.ok, r.code)
        sections = list(r.data.repairSections.values())
        self.assertNotIn('clothing', sections)
        self.assertIn('face', sections)


# ---------------------------------------------------------------------------------------------
# 14 / 18  repository
# ---------------------------------------------------------------------------------------------
class RepositoryTests(unittest.TestCase):
    def setUp(self):
        self.rt = core_server()
        self.e = self.rt.eval

    def test_a_pre_save_read_never_replaces_the_saved_entry(self):
        self.rt.run(r'''
            WCAppearanceRepo.invalidate('vorp:1')
            local old = json.decode(rows['vorp:1'].appearance)
            staleRow = WCUtil.copy(rows['vorp:1'])
            -- the concurrent load: its SELECT answers the pre-save row and, while it yields, the save commits
            local base = FakeDB.handlers
            FakeDB.on('SELECT %* FROM characters_appearence', function(sql, params)
                if interleave then
                    interleave = false
                    local app = WCUtil.copy(savedApp); app.clothing.equipped.hats = h('male', 'hats', 1, 1)
                    saveOk = WCAppearanceRepo.save('vorp:1', app)
                    return staleRow
                end
                return rows[params[1]]
            end)
            interleave = true
            loaded = WCAppearanceRepo.load('vorp:1')
        ''')
        self.assertTrue(self.e('saveOk'))
        self.assertIsNone(self.e('loaded.clothing.equipped.hats'), 'the load still answers what it read')
        self.assertIsNotNone(self.e('WCAppearanceRepo.cache["vorp:1"].app.clothing.equipped.hats'),
                             'the cache keeps what the save committed')

    def test_a_corrupt_v3_row_is_recovered_without_legacy_grants(self):
        self.rt.run(r'''
            local app = WCUtil.copy(savedApp); app.clothing.equipped.hats = h('male', 'hats', 1, 1)
            local legacy = S.toLegacy(app)
            rows['vorp:1'].components = legacy.components
            rows['vorp:1'].faceFeatures = legacy.faceFeatures
            rows['vorp:1'].overlays = legacy.overlays
            rows['vorp:1'].isMale = 1
            rows['vorp:1'].appearance = '{broken'; rows['vorp:1'].appearance_version = 3
            WCAppearanceRepo.invalidate('vorp:1')
            app2, meta = WCAppearanceRepo.load('vorp:1')
        ''')
        self.assertTrue(self.e('meta.recovered'))
        self.assertIsNotNone(self.e('app2.clothing.equipped.hats'))
        tx = self.e('FakeDB.transactions[#FakeDB.transactions]')
        self.assertEqual(len(tx), 1, 'the JSON only, no legacy grant')
        self.assertNotIn('w_creators_clothes', tx[1].query)


# ---------------------------------------------------------------------------------------------
# 17  a failed rsg listing
# ---------------------------------------------------------------------------------------------
class RsgListingTests(unittest.TestCase):
    def test_a_failed_query_is_not_an_empty_listing(self):
        rt = core_server()
        rt.run('''
            Bridge.Name = 'rsg'
            Bridge.GetLicense = function() return 'license:1' end
            FakeDB.fail = 'SELECT citizenid, charinfo, job, money FROM'
            list = Bridge.GetCharacters(1)
            reg = Bridge.RegisterCharacter(1, { firstname = 'A', lastname = 'B', isMale = true })
        ''')
        self.assertIsNone(rt.eval('list'))
        self.assertIsNone(rt.eval('reg'))

    def test_the_delete_confirmation_answers_database_error(self):
        rt = server_runtime()
        rt.run('''
            Bridge.GetCharacters = function(src) if listFails then return nil end
                local out = {} for i, r in ipairs(owned[src] or {}) do out[i] = { charid = r.charid, name = r.name } end return out end
            Bridge.DeleteFrameworkCharacter = function() listFails = true return true end
        ''')
        r = rt.eval('cb')('characters:delete', 1, 'vorp:2')
        self.assertEqual(r.code, 'DATABASE_ERROR')
        self.assertEqual(rt.eval('FakeDB.count("DELETE FROM characters_appearence")'), 0,
                         'the w_creators data of a character that may still exist is kept')


# ---------------------------------------------------------------------------------------------
# 19  §6.1
# ---------------------------------------------------------------------------------------------
class DocsTests(unittest.TestCase):
    def test_the_projection_fingerprint_is_documented(self):
        text = (RESOURCE / 'docs' / 'ARCHITECTURE.md').read_text(encoding='utf-8')
        section = text[text.index('### 6.1 Storage'):text.index('### 6.3 Identity')]
        self.assertNotIn('never read when `appearance_version >= 3`', section)
        for needle in ('fingerprint', 'rebuilt', 'NULL', 'meta.recovered'):
            self.assertIn(needle, section)


# ---------------------------------------------------------------------------------------------
# 32  a drop while select / create yields
# ---------------------------------------------------------------------------------------------
class DropMidCallTests(Flow):
    def test_a_drop_during_the_select_load_leaves_nothing(self):
        self.rt.run('''
            FakeDB.on('SELECT %* FROM characters_appearence', function(sql, params)
                fireEvent('playerDropped', 1); Players[1] = nil
                return rows[params[1]]
            end)
        ''')
        r = self.call('characters:select', 1, 'vorp:1')
        self.assertEqual(r.code, 'NO_CHARACTER')
        self.rt.run('tick(0)')
        self.assertIsNone(self.e('WCAppearanceRepo.cache["vorp:1"]'))
        self.assertFalse(self.e('WCCharacters.inFlow(1) and WCCharacters.isSwitching(1)'))

    def test_a_drop_during_the_creation_write_leaves_no_pending(self):
        r = self.call('characters:beginCreate', 1, 'male')
        self.later()
        self.rt.run('''
            local real = w.database.transaction.await
            w.database.transaction.await = function(q)
                fireEvent('playerDropped', 1); Players[1] = nil
                return real(q)
            end
        ''')
        c = self.call('characters:create', 1, r.data.token, identity(self.rt), self.e('S.default("male")'))
        self.assertEqual(c.code, 'NO_CHARACTER')
        self.rt.run('Players[1] = { name = "back", coords = vector3(0, 0, 0), bucket = 0 }')
        self.assertEqual(self.call('characters:loaded', 1).code, 'NO_CHARACTER')


if __name__ == '__main__':
    unittest.main()
