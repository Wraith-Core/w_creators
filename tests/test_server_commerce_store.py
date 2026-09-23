"""Server commerce: clothing ownership (WCOwnership) and the clothing store (WCClothingStore).

The SETUP below is shared with the other test_server_commerce_* modules: a character 'vorp:1' for
player 1 standing at the Valentine clothing store with 100 cash, a simulated w_creators_clothes
table (transactions apply their grants) and a simulated w_creators_outfits table.
"""
import unittest

from harness import Runtime

COMMERCE_FILES = (
    'server/appearance/sync.lua',
    'server/clothing/ownership.lua',
    'server/clothing/store.lua',
    'server/clothing/states.lua',
    'server/wardrobe/outfits.lua',
    'server/wardrobe/wardrobe.lua',
)

SETUP = r'''
FakeDB.fireReady()                                              -- the migrations have run
S = AppearanceSchema
h = function(sex, c, m, v) return WCCatalog.forSex(sex)[c].models[m][v or 1].hash end
charids = { [1] = 'vorp:1', [2] = 'vorp:2' }
Bridge.GetCharId = function(src) return charids[src] end
STORE = vector3(-326.17, 773.757, 117.5)                        -- valentine_clothing
WARDROBE = vector3(-184.5, 625.02, 114.09)                      -- valentine_wardrobe
Players[1].coords = STORE
Players[2] = { name = 'player two', coords = STORE, bucket = 0 }
FakeUsers[1] = { money = 100 }
FakeUsers[2] = { money = 100 }

rows = {}
function setSaved(charid, app)
    rows[charid] = { id = charid == 'vorp:1' and 11 or 12, charid = charid, appearance = json.encode(app),
                     appearance_version = 3 }
    WCAppearanceRepo.invalidate(charid)
end
setSaved('vorp:1', S.default('male'))
setSaved('vorp:2', S.default('female'))
FakeDB.on('SELECT %* FROM characters_appearence', function(sql, params) return rows[params[1]] end)
FakeDB.on('SELECT id FROM characters_appearence WHERE charid', function(sql, params)
    return rows[params[1]] and rows[params[1]].id end)

-- w_creators_clothes
owned = {}
function own(charid, category, hash, tint, source)
    owned[charid] = owned[charid] or {}
    tint = tint or {}
    table.insert(owned[charid], { hash = hash, category = category, palette = tint.palette, tint0 = tint.tint0,
                                  tint1 = tint.tint1, tint2 = tint.tint2, source = source or 'store' })
end
function ownedRow(charid, hash)
    for _, r in ipairs(owned[charid] or {}) do
        if WCUtil.u32(r.hash) == WCUtil.u32(hash) then return r end
    end
    return nil
end
FakeDB.on('FROM w_creators_clothes WHERE charid', function(sql, params) return owned[params[1]] or {} end)

-- A committed transaction applies its clothes grants and appearance update.
local rawTransaction = w.database.transaction.await
w.database.transaction.await = function(queries)
    local done = rawTransaction(queries)
    if done ~= true then return done end
    for _, q in ipairs(queries) do
        local sql, v = q.query, q.values
        if sql:find('INTO w_creators_clothes', 1, true) then
            local row = ownedRow(v[1], v[2])
            if sql:find('INSERT IGNORE', 1, true) then
                if not row then own(v[1], v[3], v[2], nil, v[4]) end
            elseif sql:find('palette = NULL', 1, true) then
                if not row then own(v[1], v[3], v[2], nil, v[4])
                else row.palette, row.tint0, row.tint1, row.tint2 = nil, nil, nil, nil end
            else
                local tint = { palette = v[4], tint0 = v[5], tint1 = v[6], tint2 = v[7] }
                if not row then own(v[1], v[3], v[2], tint, v[8])
                else row.palette, row.tint0, row.tint1, row.tint2 = v[4], v[5], v[6], v[7] end
            end
        elseif sql:find('UPDATE characters_appearence SET appearance', 1, true) then
            rows[v[8]].appearance = v[1]
        end
    end
    return done
end

-- w_creators_outfits
outfitRows, nextOutfit = {}, 0
FakeDB.on('SELECT id, name, data FROM w_creators_outfits', function(sql, p)
    local out = {}
    for _, r in ipairs(outfitRows) do
        if r.charid == p[1] then out[#out + 1] = { id = r.id, name = r.name, data = r.data } end
    end
    return out
end)
FakeDB.on('INSERT INTO w_creators_outfits', function(sql, p)
    nextOutfit = nextOutfit + 1
    table.insert(outfitRows, { id = nextOutfit, charid = p[1], name = p[2], data = p[3] })
    return nextOutfit
end)
local function outfitRow(id, charid)
    for i, r in ipairs(outfitRows) do
        if r.id == id and r.charid == charid then return r, i end
    end
end
FakeDB.on('UPDATE w_creators_outfits SET data', function(sql, p)
    local r = outfitRow(p[2], p[3]); if r then r.data = p[1] return 1 end return 0 end)
FakeDB.on('UPDATE w_creators_outfits SET name', function(sql, p)
    local r = outfitRow(p[2], p[3]); if r then r.name = p[1] return 1 end return 0 end)
FakeDB.on('DELETE FROM w_creators_outfits', function(sql, p)
    local _, i = outfitRow(p[1], p[2]); if i then table.remove(outfitRows, i) return 1 end return 0 end)

changedEvents = {}
AddEventHandler('w_creators:server:appearanceChanged', function(src, charid, kind)
    table.insert(changedEvents, { src = src, charid = charid, kind = kind })
end)

function call(name, ...) return Callbacks[name](...) end
function saved(charid) return (WCAppearanceRepo.load(charid or 'vorp:1')) end
-- A working copy of the saved appearance (what the NUI edits).
function working(charid) return saved(charid) end
opSeq = 0
function nextOp() opSeq = opSeq + 1 return 'op' .. opSeq end
function openStore(src, id) WCSecurity.clear(src or 1) return call('w_creators:store:open', src or 1, id or 'valentine_clothing') end
function buy(app, src, token, opId)
    if not keepRate then WCSecurity.clear(src or 1) end
    return call('w_creators:store:commit', src or 1, token or storeToken, opId or nextOp(), app)
end
function countTx() return #FakeDB.transactions end
'''


def commerce():
    rt = Runtime().load_server_core()
    rt.load(*COMMERCE_FILES)
    rt.run(SETUP)
    return rt


class OwnershipTests(unittest.TestCase):
    def setUp(self):
        self.rt = commerce()
        self.e = self.rt.eval

    def test_list_normalises_hashes_and_tints(self):
        self.rt.run('''
            hat = h('male', 'hats', 1)
            own('vorp:1', 'hats', hat - 0x100000000, { palette = 'metaped_tint_hat', tint0 = 3, tint1 = 4, tint2 = 5 })
            own('vorp:1', 'boots', h('male', 'boots', 1), { palette = 'metaped_tint_leather', tint0 = 999, tint1 = 1, tint2 = 1 })
            list = WCOwnership.list('vorp:1')
        ''')
        self.assertTrue(self.e('list[tostring(hat)] ~= nil'))
        self.assertEqual(self.e('list[tostring(hat)].tint1'), 4)
        self.assertTrue(self.e('WCOwnership.owns("vorp:1", hat)'))
        self.assertFalse(self.e('WCOwnership.owns("vorp:1", h("male", "hats", 2))'))
        self.assertEqual(self.e('WCOwnership.tintOf(list, hat, "hats").palette'), 'metaped_tint_hat')
        # an out-of-range stored tint is not a valid tint: the original colour
        self.assertIsNone(self.e('WCOwnership.tintOf(list, h("male", "boots", 1), "boots")'))

    def test_list_database_failure(self):
        self.rt.run('FakeDB.fail = "FROM w_creators_clothes"; l, code = WCOwnership.list("vorp:1")')
        self.assertIsNone(self.e('l'))
        self.assertEqual(self.e('code'), 'DATABASE_ERROR')

    def test_grant_queries(self):
        self.rt.run('''
            q = WCOwnership.grantQueries('vorp:1', {
                { category = 'hats', hash = -5 },
                { category = 'boots', hash = 7, tint = { palette = 'metaped_tint_leather', tint0 = 1, tint1 = 2, tint2 = 3 } },
                { category = 'gloves', hash = 9, tint = false },
                { category = 'x' },
            }, 'bogus')
        ''')
        self.assertEqual(self.e('#q'), 3)
        self.assertIn('INSERT IGNORE', self.e('q[1].query'))
        self.assertEqual(self.e('q[1].values[2]'), 0xfffffffb)
        self.assertEqual(self.e('q[1].values[4]'), 'admin')
        self.assertIn('ON DUPLICATE KEY UPDATE', self.e('q[2].query'))
        self.assertEqual(self.e('#q[2].values'), 8)
        self.assertIn('palette = NULL', self.e('q[3].query'))
        self.assertEqual(self.e('#q[3].values'), 4)

    def test_resolve_equipped(self):
        self.rt.run('r, code, cat = WCOwnership.resolveEquipped("male", { hats = h("male", "hats", 1), boots = 0 })')
        self.assertEqual(self.rt.py(self.e('r')), {'hats': self.e('h("male", "hats", 1)')})
        for bad in ('{ hats = 12345 }', '{ heads = h("male", "heads", 1) }', '{ skirts = h("female", "skirts", 1) }',
                    '{ hats = h("female", "hats", 1) }', '{ hats = {} }', '{ [1] = h("male", "hats", 1) }'):
            self.rt.run('r, code = WCOwnership.resolveEquipped("male", %s)' % bad)
            self.assertEqual(self.e('code'), 'INVALID_COMPONENT', bad)


class StoreOpenTests(unittest.TestCase):
    def setUp(self):
        self.rt = commerce()
        self.e = self.rt.eval

    def test_open_returns_the_store_data(self):
        self.rt.run('own("vorp:1", "hats", h("male", "hats", 2)); r = openStore()')
        self.assertTrue(self.e('r.ok'), self.e('r.code'))
        d = 'r.data'
        self.assertTrue(self.e('type(%s.token) == "string"' % d))
        self.assertEqual(self.e('%s.appearance.sex' % d), 'male')
        self.assertTrue(self.e('%s.owned[tostring(h("male", "hats", 2))] ~= nil' % d))
        self.assertEqual(self.e('%s.prices.hats' % d), 3.5)
        self.assertEqual(self.e('%s.prices.boots' % d), 5)
        self.assertIsNone(self.e('%s.prices.skirts' % d))                # not offered to males
        self.assertEqual(self.e('%s.tintPrice' % d), 2.5)
        self.assertEqual(self.e('%s.storeProfile' % d), 'general')
        self.assertEqual(self.e('%s.pricingProfile' % d), 'standard')
        self.assertAlmostEqual(self.e('%s.preview.x' % d), -329.31)
        self.assertAlmostEqual(self.e('%s.preview.w' % d), 294.79)
        self.assertGreater(self.e('%s.expiresIn' % d), 0)

    def test_prices_follow_the_pricing_profile(self):
        self.rt.run('''
            Config.Clothing.pricingProfiles.luxury = { multiplier = 1.5 }
            for _, loc in ipairs(Config.Locations) do
                if loc.id == 'valentine_clothing' then loc.pricingProfile = 'luxury' end
            end
            WCLocations.reload()
            r = openStore()
        ''')
        self.assertEqual(self.e('r.data.prices.hats'), 5.25)
        self.assertEqual(self.e('r.data.pricingProfile'), 'luxury')

    def test_open_refusals(self):
        self.rt.run('Config.Services.clothingStores = false; r = openStore()')
        self.assertEqual(self.e('r.code'), 'STORE_DISABLED')
        self.rt.run('''
            Config.Services.clothingStores = true
            for _, loc in ipairs(Config.Locations) do
                if loc.id == 'valentine_clothing' then loc.enabled = false end
            end
            WCLocations.reload()
            r = openStore()
        ''')
        self.assertEqual(self.e('r.code'), 'LOCATION_DISABLED')
        self.rt.run('r = openStore(1, "saintdenis_clothing")')
        self.assertEqual(self.e('r.code'), 'TOO_FAR')
        self.rt.run('r = openStore(1, "nowhere")')
        self.assertEqual(self.e('r.code'), 'LOCATION_NOT_FOUND')
        self.rt.run('r = openStore(1, "valentine_wardrobe")')
        self.assertEqual(self.e('r.code'), 'LOCATION_NOT_FOUND')
        self.rt.run('WCSecurity.clear(1); r = call("w_creators:store:open", 1, nil)')
        self.assertEqual(self.e('r.code'), 'LOCATION_NOT_FOUND')
        self.rt.run('WCSecurity.clear(1); r = call("w_creators:store:open", 1, { "x" })')
        self.assertEqual(self.e('r.code'), 'INVALID_PAYLOAD')
        self.rt.run('charids[1] = nil; r = openStore(1, "blackwater_clothing")')
        self.assertEqual(self.e('r.code'), 'NO_CHARACTER')

    def test_open_database_failure_closes_the_session(self):
        self.rt.run('FakeDB.fail = "FROM w_creators_clothes"; r = openStore()')
        self.assertEqual(self.e('r.code'), 'DATABASE_ERROR')
        self.assertIsNone(self.e('WCSessions.current(1)'))


class StoreCommitTests(unittest.TestCase):
    def setUp(self):
        self.rt = commerce()
        self.e = self.rt.eval
        self.rt.run('r = openStore(); storeToken = r.data.token; app = working(); hat = h("male", "hats", 1)')
        self.assertTrue(self.e('r.ok'))
        self.tx0 = self.e('countTx()')

    def money(self):
        return self.e('FakeUsers[1].money')

    def assertRefused(self, code):
        self.assertFalse(self.e('res.ok'))
        self.assertEqual(self.e('res.code'), code)
        self.assertEqual(self.money(), 100)
        self.assertEqual(self.e('#MoneyCalls'), 0)
        self.assertEqual(self.e('countTx()'), self.tx0)
        self.assertTrue(self.e('WCSessions.current(1) ~= nil'), 'a refused commit keeps the session open')

    def test_buy_a_hat(self):
        self.rt.run('app.clothing.equipped.hats = hat; res = buy(app)')
        self.assertTrue(self.e('res.ok'), self.e('res.code'))
        self.assertEqual(self.e('res.data.charged'), 3.5)
        self.assertEqual(self.e('res.charged'), 3.5)
        self.assertEqual(self.money(), 96.5)
        self.assertEqual(self.e('res.data.appearance.clothing.equipped.hats'), self.e('hat'))
        self.assertEqual(self.e('#res.data.purchases'), 1)
        self.assertEqual(self.e('res.data.purchases[1].category'), 'hats')
        self.assertEqual(self.e('res.data.purchases[1].hash'), self.e('hat'))
        # one transaction: appearance + purchase grant + the clothes the player arrived in
        self.assertEqual(self.e('countTx()'), self.tx0 + 1)
        self.assertEqual(self.e('ownedRow("vorp:1", hat).source'), 'store')
        self.assertEqual(self.e('ownedRow("vorp:1", h("male", "boots", 1)).source'), 'legacy')
        self.assertEqual(self.e('saved().clothing.equipped.hats'), self.e('hat'))
        self.assertEqual(self.e('json.decode(rows["vorp:1"].appearance).clothing.equipped.hats'), self.e('hat'))
        # broadcast, logs, event; the session is closed
        self.assertEqual(len(self.rt.client_events('w_creators:client:applyRemoteAppearance')), 1)
        logs = [e for e in self.e('LogEmits').values() if e.event == 'clothing_purchased']
        self.assertEqual(len(logs), 1)
        self.assertEqual(logs[0].payload.price, 3.5)
        self.assertEqual(logs[0].payload.store, 'valentine_clothing')
        self.assertEqual(self.e('#changedEvents'), 1)
        self.assertEqual(self.e('changedEvents[1].kind'), 'store')
        self.assertEqual(self.e('changedEvents[1].charid'), 'vorp:1')
        self.assertIsNone(self.e('WCSessions.current(1)'))

    def test_client_price_fields_are_ignored(self):
        self.rt.run('''
            app.clothing.equipped.hats = hat
            app.price = 0; app.total = 0; app.charged = 0
            app.clothing.prices = { hats = 0 }; app.clothing.price = 0
            app.prices = { hats = -100 }
            res = buy(app)
        ''')
        self.assertTrue(self.e('res.ok'))
        self.assertEqual(self.e('res.data.charged'), 3.5)
        self.assertEqual(self.money(), 96.5)

    def test_other_sections_are_never_taken_from_the_payload(self):
        self.rt.run('''
            app.clothing.equipped.hats = hat
            app.head.head = h('male', 'heads', 2)
            app.body.height = 1.1
            app.sex = 'female'
            app.clothing.states = { hat = 'off' }
            res = buy(app)
        ''')
        self.assertTrue(self.e('res.ok'))
        self.assertEqual(self.e('res.data.appearance.sex'), 'male')
        self.assertEqual(self.e('res.data.appearance.head.head'), self.e('S.default("male").head.head'))
        self.assertEqual(self.e('res.data.appearance.body.height'), self.e('S.default("male").body.height'))
        self.assertIsNone(self.e('res.data.appearance.clothing.states.hat'))

    def test_fake_and_cross_sex_hashes_are_rejected(self):
        for value in ('12345', 'h("female", "hats", 1)', 'h("male", "boots", 1)', '"garbage"'):
            self.rt.run('a = working(); a.clothing.equipped.hats = %s; res = buy(a)' % value)
            self.assertRefused('INVALID_COMPONENT')
        self.rt.run('a = working(); a.clothing.equipped.skirts = h("female", "skirts", 1); res = buy(a)')
        self.assertRefused('INVALID_COMPONENT')
        self.rt.run('a = working(); a.clothing.equipped.heads = h("male", "heads", 2); res = buy(a)')
        self.assertRefused('INVALID_COMPONENT')

    def test_unavailable_in_the_store_profile(self):
        self.rt.run('''
            Config.Clothing.storeProfiles.hatsOnly = { include = { 'hats' }, models = { hats = { min = 2, max = 3 } } }
            for _, loc in ipairs(Config.Locations) do
                if loc.id == 'valentine_clothing' then loc.storeProfile = 'hatsOnly' end
            end
            WCLocations.reload()
            WCSessions.clear(1)
            storeToken = openStore().data.token
            a = working(); a.clothing.equipped.masks = h('male', 'masks', 1); res = buy(a)
        ''')
        self.assertRefused('COMPONENT_NOT_AVAILABLE')
        self.rt.run('a = working(); a.clothing.equipped.hats = h("male", "hats", 1); res = buy(a)')
        self.assertRefused('COMPONENT_NOT_AVAILABLE')     # model 1 is outside the profile's range
        self.rt.run('a = working(); a.clothing.equipped.hats = h("male", "hats", 2); res = buy(a)')
        self.assertTrue(self.e('res.ok'))

    def test_not_for_sale_is_not_available(self):
        self.rt.run('Config.Clothing.prices.masks = -1; a = working(); a.clothing.equipped.masks = h("male", "masks", 1); res = buy(a)')
        self.assertRefused('COMPONENT_NOT_AVAILABLE')

    def test_owned_item_is_free(self):
        self.rt.run('own("vorp:1", "hats", hat); app.clothing.equipped.hats = hat; res = buy(app)')
        self.assertTrue(self.e('res.ok'))
        self.assertEqual(self.e('res.data.charged'), 0)
        self.assertEqual(self.e('#MoneyCalls'), 0)
        self.assertEqual(self.e('#res.data.purchases'), 0)
        self.assertEqual(self.money(), 100)

    def test_removal_is_free(self):
        self.rt.run('app.clothing.equipped.boots = nil; res = buy(app)')
        self.assertTrue(self.e('res.ok'))
        self.assertEqual(self.e('res.data.charged'), 0)
        self.assertIsNone(self.e('res.data.appearance.clothing.equipped.boots'))

    def test_invalid_tints_are_rejected(self):
        bad = (
            '{ palette = "metaped_tint_nope", tint0 = 1, tint1 = 1, tint2 = 1 }',
            '{ palette = "metaped_tint_leather", tint0 = 1, tint1 = 1, tint2 = 1 }',   # not a hat palette
            '{ palette = "metaped_tint_hat", tint0 = 255, tint1 = 1, tint2 = 1 }',
            '{ palette = "metaped_tint_hat", tint0 = -1, tint1 = 1, tint2 = 1 }',
            '{ palette = "metaped_tint_hat", tint0 = 1.5, tint1 = 1, tint2 = 1 }',
            '{ palette = "metaped_tint_hat", tint0 = "1", tint1 = 1, tint2 = 1 }',
            '{ palette = "metaped_tint_hat", tint0 = 1, tint1 = 1 }',
            '"red"',
        )
        for tint in bad:
            self.rt.run('a = working(); a.clothing.equipped.hats = hat; a.clothing.tints.hats = %s; res = buy(a)' % tint)
            self.assertRefused('INVALID_TINT')
        # NaN / inf cannot even be encoded: the payload is refused
        self.rt.run('a = working(); a.clothing.equipped.hats = hat; '
                    'a.clothing.tints.hats = { palette = "metaped_tint_hat", tint0 = 0/0, tint1 = 1, tint2 = 1 }; res = buy(a)')
        self.assertRefused('INVALID_PAYLOAD')
        # ... and the plan itself refuses NaN / inf as a tint
        for v in ('0/0', '1/0', '-1/0'):
            self.rt.run('a = working(); a.clothing.equipped.hats = hat; '
                        'a.clothing.tints.hats = { palette = "metaped_tint_hat", tint0 = %s, tint1 = 1, tint2 = 1 }; '
                        'p, code = WCClothingStore.plan(saved(), a, {}, WCLocations.byId("valentine_clothing"))' % v)
            self.assertEqual(self.e('code'), 'INVALID_TINT', v)

    def test_dye_price_is_charged(self):
        self.rt.run('''
            own('vorp:1', 'hats', hat)
            app.clothing.equipped.hats = hat
            app.clothing.tints.hats = { palette = 'metaped_tint_hat', tint0 = 10, tint1 = 20, tint2 = 30 }
            res = buy(app)
        ''')
        self.assertTrue(self.e('res.ok'), self.e('res.code'))
        self.assertEqual(self.e('res.data.charged'), 2.5)
        self.assertTrue(self.e('res.data.purchases[1].dyed'))
        self.assertEqual(self.e('ownedRow("vorp:1", hat).palette'), 'metaped_tint_hat')
        self.assertEqual(self.e('ownedRow("vorp:1", hat).tint1'), 20)
        self.assertEqual(self.e('res.data.appearance.clothing.tints.hats.tint2'), 30)

    def test_new_item_with_a_tint_pays_both(self):
        self.rt.run('''
            app.clothing.equipped.hats = hat
            app.clothing.tints.hats = { palette = 'metaped_tint_hat', tint0 = 1, tint1 = 2, tint2 = 3 }
            app.clothing.equipped.gloves = h('male', 'gloves', 2)
            res = buy(app)
        ''')
        self.assertTrue(self.e('res.ok'))
        self.assertEqual(self.e('res.data.charged'), 10.25)   # 3.5 + 2.5 + 4.25
        self.assertEqual(self.money(), 89.75)
        logs = [e for e in self.e('LogEmits').values() if e.event == 'clothing_purchased']
        self.assertEqual(len(logs), 2)

    def test_same_tint_as_owned_is_free(self):
        self.rt.run('''
            tint = { palette = 'metaped_tint_hat', tint0 = 1, tint1 = 2, tint2 = 3 }
            own('vorp:1', 'hats', hat, tint)
            app.clothing.equipped.hats = hat
            app.clothing.tints.hats = tint
            res = buy(app)
        ''')
        self.assertTrue(self.e('res.ok'))
        self.assertEqual(self.e('res.data.charged'), 0)

    def test_duplicate_op_id_replays_without_a_second_charge(self):
        self.rt.run('app.clothing.equipped.hats = hat; res = buy(app, 1, storeToken, "same"); res2 = buy(app, 1, storeToken, "same")')
        self.assertTrue(self.e('res.ok and res2.ok'))
        self.assertEqual(self.e('res2.data.charged'), 3.5)
        self.assertEqual(self.money(), 96.5)
        self.assertEqual(self.e('countTx()'), self.tx0 + 1)
        self.assertEqual(len(self.rt.client_events('w_creators:client:applyRemoteAppearance')), 1)

    def test_concurrent_commit_is_busy(self):
        self.rt.run('''
            app.clothing.equipped.hats = hat
            local tx = w.database.transaction.await
            w.database.transaction.await = function(q)
                if not inner then inner = buy(app, 1, storeToken, 'second') end
                return tx(q)
            end
            res = buy(app, 1, storeToken, 'first')
        ''')
        self.assertTrue(self.e('res.ok'))
        self.assertEqual(self.e('inner.code'), 'BUSY')
        self.assertEqual(self.money(), 96.5)

    def test_insufficient_funds_writes_nothing(self):
        self.rt.run('FakeUsers[1].money = 1; app.clothing.equipped.hats = hat; res = buy(app)')
        self.assertEqual(self.e('res.code'), 'INSUFFICIENT_FUNDS')
        self.assertEqual(self.e('FakeUsers[1].money'), 1)
        self.assertEqual(self.e('countTx()'), self.tx0)
        self.assertIsNone(self.e('saved().clothing.equipped.hats'))
        self.assertIsNone(self.e('ownedRow("vorp:1", hat)'))

    def test_database_failure_refunds(self):
        self.rt.run('FakeDB.transactionOk = false; app.clothing.equipped.hats = hat; res = buy(app)')
        self.assertEqual(self.e('res.code'), 'DATABASE_ERROR')
        self.assertTrue(self.e('res.data.refunded'))
        self.assertEqual(self.money(), 100)
        self.assertIsNone(self.e('saved().clothing.equipped.hats'))
        self.assertIsNone(self.e('ownedRow("vorp:1", hat)'))
        self.assertEqual(len(self.rt.client_events('w_creators:client:applyRemoteAppearance')), 0)
        self.assertEqual(self.e('#changedEvents'), 0)
        # a thrown transaction error is refunded too
        self.rt.run('FakeDB.transactionOk = true; FakeDB.transactionError = "deadlock"; res = buy(app)')
        self.assertEqual(self.e('res.code'), 'DATABASE_ERROR')
        self.assertEqual(self.money(), 100)

    def test_service_and_location_disabled_after_open(self):
        self.rt.run('Config.Services.clothingStores = false; app.clothing.equipped.hats = hat; res = buy(app)')
        self.assertRefused('STORE_DISABLED')
        self.rt.run('''
            Config.Services.clothingStores = true
            for _, loc in ipairs(Config.Locations) do
                if loc.id == 'valentine_clothing' then loc.enabled = false end
            end
            WCLocations.reload()
            res = buy(app)
        ''')
        self.assertRefused('LOCATION_DISABLED')

    def test_too_far(self):
        self.rt.run('Players[1].coords = vector3(0, 0, 0); app.clothing.equipped.hats = hat; res = buy(app)')
        self.assertRefused('TOO_FAR')

    def test_no_changes_is_not_charged(self):
        self.rt.run('res = buy(app)')
        self.assertRefused('NO_CHANGES')

    def test_conflicting_items(self):
        self.rt.run('''
            app.clothing.equipped.coats = h('male', 'coats', 1)
            app.clothing.equipped.coats_closed = h('male', 'coats_closed', 1)
            res = buy(app)
        ''')
        self.assertRefused('CONFLICTING_ITEMS')
        self.rt.run('a = working(); a.clothing.equipped.belt_buckles = h("male", "belt_buckles", 1); res = buy(a)')
        self.assertRefused('CONFLICTING_ITEMS')

    def test_invalid_payloads(self):
        for payload in ('nil', '"app"', '{}', '{ clothing = "x" }', '{ clothing = { equipped = 5 } }',
                        '{ clothing = { equipped = {}, tints = 5 } }'):
            self.rt.run('res = buy(%s)' % payload)
            self.assertRefused('INVALID_PAYLOAD')
        self.rt.run('res = call("w_creators:store:commit", 1, storeToken, nil, app)')
        self.assertRefused('INVALID_PAYLOAD')
        self.rt.run('big = working(); big.junk = string.rep("x", 70000); res = buy(big)')
        self.assertRefused('INVALID_PAYLOAD')

    def test_wrong_token_and_wrong_session_kind(self):
        self.rt.run('app.clothing.equipped.hats = hat; res = buy(app, 1, "nope")')
        self.assertRefused('SESSION_NOT_FOUND')
        self.rt.run('res = buy(app, 2, storeToken)')
        self.assertEqual(self.e('res.code'), 'SESSION_NOT_FOUND')
        self.rt.run('''
            WCSessions.clear(1)
            Players[1].coords = WARDROBE
            wardrobeToken = call('w_creators:wardrobe:open', 1, 'valentine_wardrobe').data.token
            res = buy(app, 1, wardrobeToken)
        ''')
        self.assertEqual(self.e('res.code'), 'SESSION_NOT_FOUND')
        self.assertEqual(self.money(), 100)

    def test_degraded_appearance_is_never_charged(self):
        self.rt.run('bad = S.default("male"); bad.head.head = 1; setSaved("vorp:1", bad); '
                    'app.clothing.equipped.hats = hat; res = buy(app)')
        self.assertRefused('INTERNAL_ERROR')

    def test_rate_limit(self):
        self.rt.run('keepRate = true; for i = 1, 6 do buy("x") end; res = buy(app)')
        self.assertEqual(self.e('res.code'), 'RATE_LIMITED')


if __name__ == '__main__':
    unittest.main()
