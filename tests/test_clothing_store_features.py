"""The clothing store / wardrobe additions (one resource): the game's blip sprites and the catalogue
book (the Jump On store places, data only), the fitting-room light, access rules, the per-hand
camera framings, "take off everything", the loadout / vest tuck / body-part states, the per-group
toggle commands and the bandana state bag, per-palette tint limits, per-model prices, paying with
gold, colourways (several owned colours of one garment), selling back, the outfits in the store and
"buy and save as outfit", and the optional inventory-item bridge.

Every price, colour, ownership and payment choice is decided on the server: these tests prove the
server never reads a price or a currency amount from the client and refuses every shortcut the
review found in other stores (a client price, an unowned outfit piece, reselling what was never
paid for).
"""
import json
import re
import unittest

from harness import RESOURCE, Runtime, read
from test_client_commerce_support import make_commerce, settle
from test_client_infra_support import make_client
from test_client_states_support import make_states_client
from test_editor_lua import CLIENT, lua_list
from test_server_commerce_store import commerce

LEATHER = "{ palette = 'metaped_tint_leather', tint0 = %d, tint1 = %d, tint2 = %d }"
HAT = "{ palette = 'metaped_tint_hat', tint0 = %d, tint1 = %d, tint2 = %d }"

# colourways, the price columns and the deletes on top of the commerce SETUP's simulated tables
COLOURS = r'''
colours = {}
function ownColour(charid, hash, tint)
    colours[charid] = colours[charid] or {}
    table.insert(colours[charid], { hash = hash, palette = tint.palette, tint0 = tint.tint0, tint1 = tint.tint1,
                                    tint2 = tint.tint2 })
end
FakeDB.on('FROM w_creators_colorways WHERE charid', function(sql, params) return colours[params[1]] or {} end)
local txWithGrants = w.database.transaction.await
w.database.transaction.await = function(queries)
    local done = txWithGrants(queries)
    if done ~= true then return done end
    for _, q in ipairs(queries) do
        local sql, v = q.query, q.values
        if sql:find('INTO w_creators_colorways', 1, true) then
            local seen = false
            for _, c in ipairs(colours[v[1]] or {}) do
                if WCUtil.u32(c.hash) == WCUtil.u32(v[2]) and c.palette == v[3] and c.tint0 == v[4]
                    and c.tint1 == v[5] and c.tint2 == v[6] then seen = true end
            end
            if not seen then ownColour(v[1], v[2], { palette = v[3], tint0 = v[4], tint1 = v[5], tint2 = v[6] }) end
        elseif sql:find('price_paid', 1, true) and sql:find('INTO w_creators_clothes', 1, true) then
            local row = ownedRow(v[1], v[2])
            if row then row.price_paid, row.currency = v[#v - 1], v[#v] end
        elseif sql:find('^DELETE FROM w_creators_clothes WHERE charid = %? AND hash') then
            for i = #(owned[v[1]] or {}), 1, -1 do
                if WCUtil.u32(owned[v[1]][i].hash) == WCUtil.u32(v[2]) then table.remove(owned[v[1]], i) end
            end
        elseif sql:find('^DELETE FROM w_creators_colorways WHERE charid = %? AND hash') then
            for i = #(colours[v[1]] or {}), 1, -1 do
                if WCUtil.u32(colours[v[1]][i].hash) == WCUtil.u32(v[2]) then table.remove(colours[v[1]], i) end
            end
        end
    end
    return done
end
function moneyTypes()
    local out = {}
    for _, c in ipairs(MoneyCalls) do out[#out + 1] = c.moneyType end
    return out
end
'''


def server():
    rt = commerce()
    rt.run(COLOURS)
    return rt


class ServerCase(unittest.TestCase):
    def setUp(self):
        self.rt = server()
        self.e = self.rt.eval
        self.run = self.rt.run

    def open_store(self):
        self.run('r = openStore(); storeToken = r.data.token; app = working(); hat = h("male", "hats", 1)')
        self.assertTrue(self.e('r.ok'), self.e('r.code'))

    def money(self):
        return self.e('FakeUsers[1].money')


# ---------------------------------------------------------------------------------------------
#  A  Presence: sprites, the catalogue book, access
# ---------------------------------------------------------------------------------------------
class PresenceTests(unittest.TestCase):
    def setUp(self):
        self.rt = Runtime().load_shared()
        self.e = self.rt.eval

    def test_blips_are_the_games_own_sprites(self):
        self.assertEqual(self.e('Config.LocationDefaults.clothing.blip.sprite'), 'blip_shop_tailor')
        self.assertEqual(self.e('Config.LocationDefaults.wardrobe.blip.sprite'), 'blip_shop_wardrobe')
        src = read(RESOURCE / 'client' / 'services' / 'locations.lua')
        self.assertIn("DEFAULT_SPRITE = 'blip_shop_tailor'", src)
        self.assertNotIn("= 'blip_shop_clothing'", read(RESOURCE / 'config' / 'locations.lua'))

    def test_every_store_has_its_book_kept_as_a_vector(self):
        books = {
            'valentine_clothing': (-326.17, 773.757, 117.5, -170.0),
            'saintdenis_clothing': (2554.619, -1167.834, 53.746, 0.0),
            'blackwater_clothing': (-761.98, -1292.61, 43.885, 180.0),
            'tumbleweed_clothing': (-5486.660, -2936.75, -0.346, -144.0),
        }
        for loc, (x, y, z, heading) in books.items():
            self.rt.run('B = WCLocations.byId(%r).book' % loc)
            # the config value itself (a vector4 in game: not copied into a plain table)
            self.assertTrue(self.e('B == Config.Locations[%d].book' % (list(books).index(loc) + 1)), loc)
            self.assertAlmostEqual(self.e('B.x'), x, places=3)
            self.assertAlmostEqual(self.e('B.y'), y, places=3)
            self.assertAlmostEqual(self.e('B.z'), z, places=3)
            self.assertAlmostEqual(self.e('B.w'), heading, places=3)
            # the book is where the prompt already was (the store's anchor)
            self.assertAlmostEqual(self.e('WCLocations.byId(%r).coords.x' % loc), x, places=3)
        self.assertTrue(self.e('Config.LocationDefaults.clothing.outfits'))

    def test_access_rules(self):
        self.rt.run('''
            L = { access = { jobs = { sheriff = 2, doctor = 0 }, ace = 'w_creators.tailor' } }
            J = { access = { jobs = { sheriff = 2 } } }
        ''')
        self.assertIsNone(self.e('WCLocations.access({})'))
        self.assertTrue(self.e('WCLocations.allows({}, nil, 0, nil)'))
        self.assertTrue(self.e('WCLocations.allows(L, "sheriff", 3, false)'))
        self.assertFalse(self.e('WCLocations.allows(L, "sheriff", 1, false)'))
        self.assertTrue(self.e('WCLocations.allows(L, "doctor", 0, false)'))
        self.assertTrue(self.e('WCLocations.allows(L, "farmer", 0, true)'))        # the ACE
        self.assertIsNone(self.e('WCLocations.allows(L, "farmer", 0, nil)'))       # client: unknown
        self.assertFalse(self.e('WCLocations.allows(J, "farmer", 0, nil)'))


class AccessServerTests(ServerCase):
    def restrict(self, rule):
        self.run('''
            for _, loc in ipairs(Config.Locations) do
                if loc.id == 'valentine_clothing' then loc.access = %s end
            end
            WCLocations.reload()
        ''' % rule)

    def test_an_access_rule_is_enforced_when_the_store_opens(self):
        self.restrict('{ jobs = { tailor = 1 } }')
        self.run('r = openStore()')
        self.assertEqual(self.e('r.code'), 'ACCESS_DENIED')
        # 1.0.6: the refusal names the job the place is for (its label when the core has one)
        self.assertEqual(self.e('r.detail.key'), self.e('WCResult.details.jobs'))
        self.assertEqual(self.e('r.detail.args[1]'), 'tailor')
        self.assertIsNone(self.e('WCSessions.current(1)'))
        # the job at its grade opens it
        self.run('''
            local User = getmetatable(w.framework:getUser(1)).__index
            User.getJob = function() return 'tailor' end
            User.getJobGrade = function() return 2 end
            r = openStore()
        ''')
        self.assertTrue(self.e('r.ok'), self.e('r.code'))

    def test_the_ace_permission_opens_it_and_the_client_can_ask(self):
        self.restrict("{ ace = 'w_creators.vip' }")
        self.run('r = openStore()')
        self.assertEqual(self.e('r.code'), 'ACCESS_DENIED')
        self.assertIsNone(self.e('r.detail'))                     # a permission rule is not advertised
        self.run('IsPlayerAceAllowed = function(src, ace) return ace == "w_creators.vip" and 1 or false end')
        self.run('WCSecurity.clear(1); a = call("w_creators:locations:access", 1)')
        self.assertTrue(self.e('a.ok'))
        self.assertTrue(self.e('a.data.valentine_clothing'))
        self.assertIsNone(self.e('a.data.saintdenis_clothing'))   # no rule: not listed
        self.run('r = openStore()')
        self.assertTrue(self.e('r.ok'), self.e('r.code'))


# ---------------------------------------------------------------------------------------------
#  B  Prices: per model, gold
# ---------------------------------------------------------------------------------------------
class ModelPriceTests(ServerCase):
    def test_a_model_price_a_multiplier_and_a_withheld_model(self):
        self.run('''
            Config.Clothing.modelPrices.male.hats = { [1] = 9, [2] = { multiplier = 2 }, [3] = -1 }
            p1 = WCCatalog.price('hats', h('male', 'hats', 1), 'standard', 'male')
            p2 = WCCatalog.price('hats', h('male', 'hats', 2), 'standard', 'male')
            p3 = WCCatalog.price('hats', h('male', 'hats', 3), 'standard', 'male')
            p4 = WCCatalog.price('boots', h('male', 'boots', 2), 'standard', 'male')
        ''')
        self.assertEqual(self.e('p1'), 9)
        self.assertEqual(self.e('p2'), 7)            # 3.5 × 2
        self.assertIsNone(self.e('p3'))
        self.assertEqual(self.e('p4'), 5)            # no entry: the category price
        self.assertFalse(self.e('WCCatalog.available("general", "male", "hats", h("male", "hats", 3))'))
        self.assertTrue(self.e('WCCatalog.available("general", "male", "hats", h("male", "hats", 1))'))
        # the pricing profile applies after the model's own price
        self.run('Config.Clothing.pricingProfiles.luxury = { multiplier = 1.5 }')
        self.assertEqual(self.e('WCCatalog.price("hats", h("male", "hats", 1), "luxury", "male")'), 13.5)

    def test_the_store_charges_the_models_price(self):
        self.run('Config.Clothing.modelPrices.male.hats = { [1] = 9 }')
        self.open_store()
        self.run('app.clothing.equipped.hats = hat; res = buy(app)')
        self.assertTrue(self.e('res.ok'), self.e('res.code'))
        self.assertEqual(self.e('res.data.charged'), 9)
        self.assertEqual(self.money(), 91)
        # what was paid is recorded with the item (a resale reads it)
        self.assertEqual(self.e('ownedRow("vorp:1", hat).price_paid'), 9)
        self.assertEqual(self.e('ownedRow("vorp:1", hat).currency'), 'cash')

    def test_a_withheld_model_cannot_be_bought(self):
        self.run('Config.Clothing.modelPrices.male.hats = { [1] = -1 }')
        self.open_store()
        self.run('app.clothing.equipped.hats = hat; res = buy(app)')
        self.assertEqual(self.e('res.code'), 'COMPONENT_NOT_AVAILABLE')
        self.assertEqual(self.money(), 100)

    def test_a_store_profile_withholds_restricted_models(self):
        self.run('''
            Config.Clothing.storeProfiles.general.restricted = { hats = { 1 } }
        ''')
        self.assertFalse(self.e('WCCatalog.available("general", "male", "hats", h("male", "hats", 1))'))
        self.assertTrue(self.e('WCCatalog.available("general", "male", "hats", h("male", "hats", 2))'))


class GoldTests(ServerCase):
    def setUp(self):
        super().setUp()
        self.run('''
            Config.Clothing.prices.hats = { cash = 3.5, gold = 0.2 }
            Config.Clothing.prices.masks = { gold = 1 }
            FakeUsers[1].money = 100
        ''')

    def test_the_store_lists_its_currencies_and_prices(self):
        self.open_store()
        self.assertEqual(list(self.e('r.data.currencies').values()), ['cash', 'gold'])
        self.assertEqual(self.e('r.data.priceSpecs.hats.gold'), 0.2)
        self.assertEqual(self.e('r.data.prices.hats'), 3.5)
        self.assertIsNone(self.e('r.data.prices.masks'))          # not sold for cash
        self.assertEqual(self.e('r.data.priceSpecs.masks.gold'), 1)

    def test_paying_with_gold_charges_gold(self):
        self.open_store()
        self.run('app.clothing.equipped.hats = hat; res = call("w_creators:store:commit", 1, storeToken, "g1", app, { currency = "gold" })')
        self.assertTrue(self.e('res.ok'), self.e('res.code'))
        self.assertEqual(self.e('res.data.charged'), 0.2)
        self.assertEqual(self.e('res.data.currency'), 'gold')
        self.assertEqual(list(self.e('moneyTypes()').values()), [1])     # the framework's gold
        self.assertEqual(self.e('ownedRow("vorp:1", hat).currency'), 'gold')

    def test_an_item_without_a_price_in_the_currency_is_refused_before_any_charge(self):
        self.open_store()
        self.run('app.clothing.equipped.masks = h("male", "masks", 1); res = buy(app)')      # cash
        self.assertEqual(self.e('res.code'), 'CURRENCY_NOT_ACCEPTED')
        self.assertEqual(self.e('#MoneyCalls'), 0)
        self.run('WCSecurity.clear(1); res = call("w_creators:store:commit", 1, storeToken, "g2", app, { currency = "gold" })')
        self.assertTrue(self.e('res.ok'), self.e('res.code'))
        self.assertEqual(self.e('res.data.charged'), 1)

    def test_an_unknown_currency_or_a_client_amount_is_never_taken(self):
        self.open_store()
        for extra in ('{ currency = "rol" }', '{ currency = 5 }', '"gold"'):
            self.run('WCSecurity.clear(1); app.clothing.equipped.hats = hat;'
                     ' res = call("w_creators:store:commit", 1, storeToken, "bad" .. tostring(math.random()), app, %s)' % extra)
            self.assertFalse(self.e('res.ok'), extra)
        self.assertEqual(self.e('#MoneyCalls'), 0)
        # a price in the extra table is ignored: the server's price is charged
        self.run('WCSecurity.clear(1); res = call("w_creators:store:commit", 1, storeToken, "g3", app,'
                 ' { currency = "gold", price = 0, total = 0, gold = 0 })')
        self.assertTrue(self.e('res.ok'), self.e('res.code'))
        self.assertEqual(self.e('res.data.charged'), 0.2)

    def test_the_colour_price_follows_the_currency(self):
        self.run('Config.Clothing.tints.price = { cash = 2.5, gold = 0.05 }')
        self.open_store()
        self.run('own("vorp:1", "hats", hat); app.clothing.equipped.hats = hat; app.clothing.tints.hats = ' + HAT % (1, 2, 3) +
                 '; res = call("w_creators:store:commit", 1, storeToken, "g4", app, { currency = "gold" })')
        self.assertTrue(self.e('res.ok'), self.e('res.code'))
        self.assertEqual(self.e('res.data.charged'), 0.05)


# ---------------------------------------------------------------------------------------------
#  C  Colours: colourways, limits
# ---------------------------------------------------------------------------------------------
class ColourwayTests(ServerCase):
    def test_the_ownership_list_carries_every_owned_colour(self):
        self.run('''
            hat = h('male', 'hats', 1)
            own('vorp:1', 'hats', hat, %s)
            ownColour('vorp:1', hat, %s)
            ownColour('vorp:1', hat, %s)
            list = WCOwnership.list('vorp:1')
            colors = WCOwnership.colorsOf(list, hat, 'hats')
        ''' % (HAT % (1, 1, 1), HAT % (1, 1, 1), HAT % (9, 9, 9)))
        self.assertEqual(self.e('#colors'), 2)                           # the last worn one first, no duplicate
        self.assertEqual(self.e('colors[1].tint0'), 1)
        self.assertTrue(self.e('WCOwnership.ownsColor(list, hat, %s, "hats")' % (HAT % (9, 9, 9))))
        self.assertTrue(self.e('WCOwnership.ownsColor(list, hat, nil, "hats")'))            # the original
        self.assertFalse(self.e('WCOwnership.ownsColor(list, hat, %s, "hats")' % (HAT % (5, 5, 5))))

    def test_an_owned_colour_is_free_and_a_new_one_is_charged_and_kept(self):
        self.open_store()
        self.run('''
            own('vorp:1', 'hats', hat, %s)
            ownColour('vorp:1', hat, %s)
            ownColour('vorp:1', hat, %s)
            app.clothing.equipped.hats = hat
            app.clothing.tints.hats = %s
            res = buy(app)
        ''' % (HAT % (1, 1, 1), HAT % (1, 1, 1), HAT % (9, 9, 9), HAT % (9, 9, 9)))
        self.assertTrue(self.e('res.ok'), self.e('res.code'))
        self.assertEqual(self.e('res.data.charged'), 0)                 # owned: free
        self.assertEqual(self.e('ownedRow("vorp:1", hat).tint0'), 9)    # now the colour it is worn in
        # a third colour costs the tint price and becomes owned too
        self.run('''
            storeToken = openStore().data.token
            a = working(); a.clothing.tints.hats = %s
            res = buy(a)
        ''' % (HAT % (4, 4, 4)))
        self.assertTrue(self.e('res.ok'), self.e('res.code'))
        self.assertEqual(self.e('res.data.charged'), 2.5)
        self.assertEqual(self.e('#colours["vorp:1"]'), 3)
        # and switching back to the first is free again
        self.run('''
            storeToken = openStore().data.token
            a = working(); a.clothing.tints.hats = %s
            res = buy(a)
        ''' % (HAT % (1, 1, 1)))
        self.assertTrue(self.e('res.ok'), self.e('res.code'))
        self.assertEqual(self.e('res.data.charged'), 0)

    def test_the_wardrobe_wears_an_owned_colour_and_never_dyes(self):
        self.run('''
            hat = h('male', 'hats', 1)
            own('vorp:1', 'hats', hat, %s)
            ownColour('vorp:1', hat, %s)
            ownColour('vorp:1', hat, %s)
            ownedList = WCOwnership.list('vorp:1')
            a = working(); a.clothing.equipped.hats = hat
            a.clothing.tints.hats = %s
            m1 = WCWardrobeService.plan(saved(), a, ownedList)
            a.clothing.tints.hats = %s
            m2 = WCWardrobeService.plan(saved(), a, ownedList)
            a.clothing.tints.hats = false
            m3 = WCWardrobeService.plan(saved(), a, ownedList)
        ''' % (HAT % (1, 1, 1), HAT % (1, 1, 1), HAT % (9, 9, 9), HAT % (9, 9, 9), HAT % (5, 5, 5)))
        self.assertEqual(self.e('m1.clothing.tints.hats.tint0'), 9)      # an owned colour
        self.assertEqual(self.e('m2.clothing.tints.hats.tint0'), 1)      # not owned: the last worn one
        self.assertIsNone(self.e('m3.clothing.tints.hats'))             # false: the original colour

    def test_outfits_keep_owned_colours_only(self):
        self.run('''
            hat = h('male', 'hats', 1)
            own('vorp:1', 'hats', hat, %s)
            ownColour('vorp:1', hat, %s)
            d1, c1 = WCOutfits.validateData('vorp:1', 'male', { hats = hat }, {}, {}, nil, { hats = %s })
            d2, c2 = WCOutfits.validateData('vorp:1', 'male', { hats = hat }, {}, {}, nil, { hats = %s })
            d3 = WCOutfits.validateData('vorp:1', 'male', { hats = hat }, {}, {}, nil, { hats = false })
            d4 = WCOutfits.validateData('vorp:1', 'male', { hats = hat }, {}, {})
        ''' % (HAT % (1, 1, 1), HAT % (1, 1, 1), HAT % (1, 1, 1), HAT % (7, 7, 7)))
        self.assertEqual(self.e('d1.tints.hats.tint0'), 1)
        self.assertIsNone(self.e('d2'))
        self.assertEqual(self.e('c2'), 'INVALID_TINT')
        self.assertFalse(self.e('d3.tints.hats'))
        self.assertIsNone(self.e('d4.tints'))                           # as before: no colours stored

    def test_tint_limits_per_palette(self):
        self.run("Config.Clothing.tints.limits = { metaped_tint_hat = { min = 2, max = 40, disabled = { 7 } } }")
        self.assertTrue(self.e('WCCatalog.validTint("hats", %s)' % (HAT % (2, 40, 8))))
        for bad in (HAT % (1, 5, 5), HAT % (5, 41, 5), HAT % (5, 5, 7)):
            self.assertFalse(self.e('WCCatalog.validTint("hats", %s)' % bad), bad)
        self.assertEqual(list(self.rt.lua.eval('function() return WCCatalog.tintLimits("metaped_tint_hat") end')())[:2], [2, 40])
        # the horse palette is offered everywhere the default list is, with its own label
        self.assertIn('metaped_tint_horse', list(self.e('WCCatalog.tintable("shirts_full")').values()))
        self.assertEqual(self.e('Config.Clothing.tints.labels.metaped_tint_horse'), 'الخيل')

    def test_the_boot_accessories_need_boots(self):
        self.assertEqual(list(self.e('Config.Clothing.rules.requires.boot_accessories').values()), ['boots'])
        self.run('norm = WCRules.normalize({ boot_accessories = 123 }); kept = WCRules.normalize({ boot_accessories = 123, boots = 7 })')
        self.assertIsNone(self.e('norm.boot_accessories'))
        self.assertEqual(self.e('kept.boot_accessories'), 123)


# ---------------------------------------------------------------------------------------------
#  D  Sell back, outfits in the store, "buy and save as outfit"
# ---------------------------------------------------------------------------------------------
class ResellTests(ServerCase):
    def setUp(self):
        super().setUp()
        self.open_store()
        self.run('''
            hat2 = h('male', 'hats', 2)
            own('vorp:1', 'hats', hat2, %s)
            ownColour('vorp:1', hat2, %s)
            ownedRow('vorp:1', hat2).price_paid = 6
            ownedRow('vorp:1', hat2).currency = 'cash'
            function sell(hash, src, token) WCSecurity.clear(src or 1)
                return call('w_creators:store:resell', src or 1, token or storeToken, hash) end
        ''' % (HAT % (3, 3, 3), HAT % (3, 3, 3)))

    def test_a_bought_item_is_sold_back_at_the_configured_share(self):
        self.run('res = sell(hat2)')
        self.assertTrue(self.e('res.ok'), self.e('res.code'))
        self.assertEqual(self.e('res.data.refunded'), 1.98)             # 6 × 0.33
        self.assertEqual(self.e('res.data.currency'), 'cash')
        self.assertEqual(self.money(), 101.98)
        self.assertIsNone(self.e('ownedRow("vorp:1", hat2)'))
        self.assertEqual(self.e('#colours["vorp:1"]'), 0)               # its colours go with it
        self.assertIsNone(self.e('res.data.owned[tostring(hat2)]'))     # the new list for the editor
        logs = [e for e in self.e('LogEmits').values() if e.event == 'clothing_sold']
        self.assertEqual(len(logs), 1)
        self.assertEqual(logs[0].payload.price, 1.98)
        # the rows were deleted before the refund (one transaction)
        tx = self.e('FakeDB.transactions[#FakeDB.transactions]')
        self.assertIn('DELETE FROM w_creators_clothes', tx[1].query)
        self.assertIn('DELETE FROM w_creators_colorways', tx[2].query)

    def test_what_was_never_paid_for_is_never_sold(self):
        for source in ('starter', 'legacy', 'admin', 'gift'):
            self.run('ownedRow("vorp:1", hat2).source = %r; res = sell(hat2)' % source)
            self.assertEqual(self.e('res.code'), 'NOT_RESELLABLE', source)
        self.run('ownedRow("vorp:1", hat2).source = "store"; ownedRow("vorp:1", hat2).price_paid = nil; res = sell(hat2)')
        self.assertEqual(self.e('res.code'), 'NOT_RESELLABLE')
        self.assertEqual(self.e('#MoneyCalls'), 0)
        self.assertIsNotNone(self.e('ownedRow("vorp:1", hat2)'))

    def test_a_worn_item_an_outfit_item_or_an_unowned_one_is_refused(self):
        self.run('''
            s = saved(); s.clothing.equipped.hats = hat2; setSaved('vorp:1', s)
            res = sell(hat2)
        ''')
        self.assertEqual(self.e('res.code'), 'ITEM_WORN')
        self.run('''
            setSaved('vorp:1', S.default('male'))
            table.insert(outfitRows, { id = 50, charid = 'vorp:1', name = 'Sunday', data = json.encode({ equipped = { hats = hat2 } }) })
            res = sell(hat2)
        ''')
        self.assertEqual(self.e('res.code'), 'ITEM_IN_OUTFIT')
        self.run('outfitRows = {}; res = sell(h("male", "hats", 3, 4))')
        self.assertEqual(self.e('res.code'), 'ITEM_NOT_OWNED')
        self.assertEqual(self.e('#MoneyCalls'), 0)

    def test_the_session_and_the_switch_decide(self):
        self.run('res = sell(hat2, 1, "nope")')
        self.assertEqual(self.e('res.code'), 'SESSION_NOT_FOUND')
        self.run('Config.Clothing.resell.enabled = false; res = sell(hat2)')
        self.assertEqual(self.e('res.code'), 'SERVICE_DISABLED')
        # a wardrobe sells only with resell.inWardrobe
        self.run('''
            Config.Clothing.resell.enabled = true
            WCSessions.clear(1); Players[1].coords = WARDROBE
            wtok = call('w_creators:wardrobe:open', 1, 'valentine_wardrobe').data.token
            res = sell(hat2, 1, wtok)
        ''')
        self.assertEqual(self.e('res.code'), 'SESSION_NOT_FOUND')
        self.run('Config.Clothing.resell.inWardrobe = true; res = sell(hat2, 1, wtok)')
        self.assertTrue(self.e('res.ok'), self.e('res.code'))

    def test_a_sale_is_never_easier_to_reach_than_a_purchase(self):
        # the commit's own gates: the access rule as it is now, the service, a remote wardrobe only
        # while remote wardrobes are allowed
        self.run('''
            for _, loc in ipairs(Config.Locations) do
                if loc.id == 'valentine_clothing' then loc.access = { jobs = { tailor = 0 } } end
            end
            WCLocations.reload()
            res = sell(hat2)
        ''')
        self.assertEqual(self.e('res.code'), 'ACCESS_DENIED')
        self.run('''
            for _, loc in ipairs(Config.Locations) do
                if loc.id == 'valentine_clothing' then loc.access = nil end
            end
            WCLocations.reload()
            Config.Services.clothingStores = false; res = sell(hat2); Config.Services.clothingStores = true
        ''')
        self.assertEqual(self.e('res.code'), 'STORE_DISABLED')
        self.run('''
            Config.Clothing.resell.inWardrobe = true; Config.Wardrobe.allowRemote = true
            WCSessions.clear(1)
            rtok = call('w_creators:wardrobe:open', 1, nil).data.token
            Config.Wardrobe.allowRemote = false
            res = sell(hat2, 1, rtok)
        ''')
        self.assertEqual(self.e('res.code'), 'LOCATION_NOT_FOUND')
        self.assertEqual(self.e('#MoneyCalls'), 0)
        self.assertIsNotNone(self.e('ownedRow("vorp:1", hat2)'))
        # remote wardrobes allowed (and selling there): the sale goes through
        self.run('Config.Wardrobe.allowRemote = true; res = sell(hat2, 1, rtok)')
        self.assertTrue(self.e('res.ok'), self.e('res.code'))

    def test_a_failed_refund_puts_the_rows_back(self):
        self.run('FakeUsers[1].failAdd = true; res = sell(hat2)')
        self.assertEqual(self.e('res.code'), 'INTERNAL_ERROR')
        self.assertIsNotNone(self.e('ownedRow("vorp:1", hat2)'))
        self.assertEqual(self.e('ownedRow("vorp:1", hat2).price_paid'), 6)
        self.assertEqual(self.e('#colours["vorp:1"]'), 1)


class StoreOutfitTests(ServerCase):
    def test_the_store_offers_the_saved_outfits_read_only(self):
        self.run('table.insert(outfitRows, { id = 3, charid = "vorp:1", name = "Work", data = json.encode({ equipped = {} }) })')
        self.open_store()
        self.assertTrue(self.e('r.data.outfitsEnabled'))
        self.assertEqual(self.e('r.data.outfits[1].name'), 'Work')
        self.assertEqual(self.e('r.data.maxOutfits'), self.e('WCOutfits.max()'))
        self.assertTrue(self.e('r.data.resell.enabled'))
        # a store with outfits = false lists none
        self.run('''
            for _, loc in ipairs(Config.Locations) do if loc.id == 'valentine_clothing' then loc.outfits = false end end
            WCLocations.reload(); WCSessions.clear(1)
            r2 = openStore()
        ''')
        self.assertFalse(self.e('r2.data.outfitsEnabled'))
        self.assertEqual(self.e('#r2.data.outfits'), 0)

    def test_buy_and_save_as_outfit_is_one_transaction(self):
        self.open_store()
        self.run('''
            app.clothing.equipped.hats = hat
            app.clothing.tints.hats = %s
            res = call('w_creators:store:commit', 1, storeToken, 'o1', app, { outfitName = '  Town  Best ' })
        ''' % (HAT % (2, 3, 4)))
        self.assertTrue(self.e('res.ok'), self.e('res.code'))
        self.assertEqual(self.e('res.data.outfit'), 'Town Best')
        self.assertEqual(self.e('res.data.charged'), 6)                  # 3.5 + a new colour 2.5
        queries = list(self.e('FakeDB.transactions[#FakeDB.transactions]').values())
        self.assertTrue(any('UPDATE characters_appearence' in q.query for q in queries))
        inserts = [q for q in queries if 'INSERT INTO w_creators_outfits' in q.query]
        self.assertEqual(len(inserts), 1)                                # the same transaction
        data = json.loads(inserts[0]['values'][3])
        self.assertEqual(data['tints']['hats']['tint2'], 4)             # the colour bought with it
        self.assertEqual(inserts[0]['values'][2], 'Town Best')

    def test_a_bad_name_a_full_list_or_no_outfits_refuse_before_any_charge(self):
        self.open_store()
        self.run('app.clothing.equipped.hats = hat')
        self.run('res = call("w_creators:store:commit", 1, storeToken, "o2", app, { outfitName = "\\226\\128\\174" })')
        self.assertEqual(self.e('res.code'), 'INVALID_OUTFIT_NAME')
        self.run('''
            Config.Wardrobe.maxSavedOutfits = 1
            table.insert(outfitRows, { id = 9, charid = 'vorp:1', name = 'Full', data = json.encode({ equipped = {} }) })
            WCSecurity.clear(1)
            res = call('w_creators:store:commit', 1, storeToken, 'o3', app, { outfitName = 'Another' })
        ''')
        self.assertEqual(self.e('res.code'), 'OUTFIT_LIMIT')
        self.run('Config.Services.savedOutfits = false; WCSecurity.clear(1);'
                 ' res = call("w_creators:store:commit", 1, storeToken, "o4", app, { outfitName = "Another" })')
        self.assertEqual(self.e('res.code'), 'OUTFITS_DISABLED')
        self.assertEqual(self.e('#MoneyCalls'), 0)
        self.assertEqual(self.money(), 100)
        self.assertFalse(self.e('WCSecurity.locked("outfits:vorp:1")'))


# ---------------------------------------------------------------------------------------------
#  E  The inventory-item bridge (off by default)
# ---------------------------------------------------------------------------------------------
class ItemBridgeTests(ServerCase):
    def setUp(self):
        super().setUp()
        self.rt.load('server/clothing/items.lua')
        self.run('''
            Given, Taken, Used = {}, {}, {}
            GiveOk, TakeOk = true, true
            w.framework.giveItem = function(_, src, item, n, meta) table.insert(Given, { item = item, meta = meta }) return GiveOk end
            w.framework.removeItem = function(_, src, item, n, meta) table.insert(Taken, { item = item }) return TakeOk end
            w.framework.registerUseItem = function(_, item, close, fn) Used[item] = fn return true end
            WCSessions.clear(1); Players[1].coords = WARDROBE
            wtok = call('w_creators:wardrobe:open', 1, 'valentine_wardrobe').data.token
            hat2 = h('male', 'hats', 2)
            own('vorp:1', 'hats', hat2, %s)
            ownColour('vorp:1', hat2, %s)
        ''' % (HAT % (3, 3, 3), HAT % (3, 3, 3)))

    def test_it_is_off_by_default(self):
        self.assertFalse(self.e('Config.Clothing.items.enabled'))
        self.run('res = call("w_creators:wardrobe:wrap", 1, wtok, hat2)')
        self.assertEqual(self.e('res.code'), 'ITEMS_DISABLED')
        self.assertFalse(self.e('WCClothingItems.registerItems()'))
        self.assertIsNotNone(self.e('ownedRow("vorp:1", hat2)'))

    def test_wrap_hands_the_garment_over_and_a_failed_hand_over_puts_it_back(self):
        self.run('Config.Clothing.items.enabled = true; res = call("w_creators:wardrobe:wrap", 1, wtok, hat2)')
        self.assertTrue(self.e('res.ok'), self.e('res.code'))
        self.assertIsNone(self.e('ownedRow("vorp:1", hat2)'))
        self.assertEqual(self.e('Given[1].item'), 'w_garment')
        self.assertEqual(self.e('Given[1].meta.category'), 'hats')
        self.assertEqual(self.e('Given[1].meta.tint.tint0'), 3)
        # a full satchel: the rows come back
        self.run('''
            own('vorp:1', 'hats', h('male', 'hats', 3))
            GiveOk = false; WCSecurity.clear(1)
            res = call('w_creators:wardrobe:wrap', 1, wtok, h('male', 'hats', 3))
        ''')
        self.assertEqual(self.e('res.code'), 'INVENTORY_FULL')
        self.assertIsNotNone(self.e('ownedRow("vorp:1", h("male", "hats", 3))'))

    def test_wrapping_keeps_the_wardrobe_commits_gates(self):
        # a remote wardrobe opened while remote wardrobes were allowed cannot wrap once they are not
        self.run('''
            Config.Clothing.items.enabled = true; Config.Wardrobe.allowRemote = true
            WCSessions.clear(1)
            rtok = call('w_creators:wardrobe:open', 1, nil).data.token
            Config.Wardrobe.allowRemote = false
            res = call('w_creators:wardrobe:wrap', 1, rtok, hat2)
        ''')
        self.assertEqual(self.e('res.code'), 'LOCATION_NOT_FOUND')
        self.assertEqual(self.e('#Given'), 0)
        self.assertIsNotNone(self.e('ownedRow("vorp:1", hat2)'))

    def test_a_worn_or_starting_item_never_leaves(self):
        self.run('''
            Config.Clothing.items.enabled = true
            ownedRow('vorp:1', hat2).source = 'starter'
            res = call('w_creators:wardrobe:wrap', 1, wtok, hat2)
        ''')
        self.assertEqual(self.e('res.code'), 'NOT_RESELLABLE')
        self.assertEqual(self.e('#Given'), 0)

    def test_using_a_garment_grants_it_as_a_gift_then_takes_the_item(self):
        self.run('''
            Config.Clothing.items.enabled = true
            WCClothingItems.registerItems()
            meta = { sex = 'male', category = 'hats', hash = h('male', 'hats', 3, 2), tint = %s }
            r1 = WCClothingItems.useGarment(1, { metadata = meta })
        ''' % (HAT % (8, 8, 8)))
        self.assertEqual(self.e('type(Used.w_garment)'), 'function')
        self.assertTrue(self.e('r1.ok'), self.e('r1.code'))
        self.assertEqual(self.e('ownedRow("vorp:1", h("male", "hats", 3, 2)).source'), 'gift')
        self.assertEqual(self.e('#Taken'), 1)
        # the other sex, or an item it owns already: nothing happens, the item is kept
        self.run('WCSecurity.clear(1); meta.sex = "female"; r2 = WCClothingItems.useGarment(1, { metadata = meta })')
        self.assertEqual(self.e('r2.code'), 'WRONG_SEX')
        self.run('WCSecurity.clear(1); meta.sex = "male"; r3 = WCClothingItems.useGarment(1, { metadata = meta })')
        self.assertFalse(self.e('r3.ok'))
        self.assertEqual(self.e('#Taken'), 1)
        # a failed take removes the grant again
        self.run('''
            WCSecurity.clear(1); TakeOk = false
            meta.hash = h('male', 'hats', 3, 3)
            r4 = WCClothingItems.useGarment(1, { metadata = meta })
        ''')
        self.assertFalse(self.e('r4.ok'))
        self.assertIsNone(self.e('ownedRow("vorp:1", h("male", "hats", 3, 3))'))

    def test_an_outfit_card_grants_nothing_and_opens_a_store_with_its_look(self):
        self.run('''
            Config.Clothing.items.enabled = true
            table.insert(outfitRows, { id = 4, charid = 'vorp:1', name = 'Card',
                data = json.encode({ equipped = { hats = hat2 }, tints = { hats = %s } }) })
            res = call('w_creators:outfits:share', 1, wtok, 4)
        ''' % (HAT % (3, 3, 3)))
        self.assertTrue(self.e('res.ok'), self.e('res.code'))
        self.assertEqual(self.e('Given[1].item'), 'w_outfit_card')
        self.assertEqual(self.e('Given[1].meta.items[1].category'), 'hats')
        # away from a store: told to use it at one
        self.run('WCSecurity.clear(1); card = { metadata = Given[1].meta }; u1 = WCClothingItems.useCard(1, card)')
        self.assertEqual(self.e('u1.code'), 'TOO_FAR')
        self.assertEqual(self.e('u1.message'), self.e('WCClothingItems.MSG_NEED_STORE'))
        self.run('WCSecurity.clear(1); Players[1].coords = STORE; u2 = WCClothingItems.useCard(1, card)')
        self.assertTrue(self.e('u2.ok'), self.e('u2.code'))
        opened = self.rt.client_events('w_creators:client:openStore')
        self.assertEqual(opened[-1].args[1], 'valentine_clothing')
        self.assertEqual(opened[-1].args[2].equipped.hats, self.e('hat2'))


# ---------------------------------------------------------------------------------------------
#  F  States: the bandana state bag
# ---------------------------------------------------------------------------------------------
class BandanaBagTests(ServerCase):
    def test_a_raised_bandana_is_published_and_forgotten(self):
        self.run('''
            Bags = {}
            function Player(src)
                Bags[src] = Bags[src] or {}
                local bag = Bags[src]
                return { state = setmetatable({ set = function(self, k, v, rep) bag[k] = { v = v, rep = rep } end },
                                              { __index = function(_, k) return bag[k] and bag[k].v end }) }
            end
            s = saved(); s.clothing.equipped.neckwear = h('male', 'neckwear', 1); setSaved('vorp:1', s)
            res = call('w_creators:clothing:setState', 1, 'bandana', 'up')
        ''')
        self.assertTrue(self.e('res.ok'), self.e('res.code'))
        self.assertTrue(self.e('Bags[1].wcBandanaUp.v'))
        self.assertTrue(self.e('Bags[1].wcBandanaUp.rep'))              # replicated
        self.assertTrue(self.e('WCClothingActions.bandanaUp(1)'))
        self.run('WCClothingActions.forget(1)')
        self.assertFalse(self.e('Bags[1].wcBandanaUp.v'))
        self.assertFalse(self.e('WCClothingActions.bandanaUp(1)'))


# ---------------------------------------------------------------------------------------------
#  Migrations and the purge
# ---------------------------------------------------------------------------------------------
class SchemaTests(unittest.TestCase):
    def test_the_colourways_backfill_is_idempotent(self):
        src = read(RESOURCE / 'server' / 'core' / 'migrations.lua')
        backfill = re.search(r"INSERT IGNORE INTO w_creators_colorways .*?tint2 IS NOT NULL", src, re.S)
        self.assertIsNotNone(backfill)
        self.assertIn('FROM w_creators_clothes', backfill.group(0))
        self.assertIn('UNIQUE KEY `char_colorway` (`charid`, `hash`, `palette`, `tint0`, `tint1`, `tint2`)', src)
        rt = Runtime().load_server_core()
        rt.run('FakeDB.fireReady(); ok2, applied2 = WCMigrations.run()')
        self.assertTrue(rt.eval('WCMigrations.ok'))
        self.assertEqual(rt.eval('#applied2'), 0)                         # a second run changes nothing

    def test_the_new_table_joins_w_cores_citizen_registry(self):
        wcore = RESOURCE.parent / 'w_core' / 'server' / 'citizen.lua'
        if not wcore.exists():
            self.skipTest('w_core is not next to w_creators')
        self.assertIn("{ 'w_creators_colorways', 'charid', 'data' }", read(wcore))


# ---------------------------------------------------------------------------------------------
#  Client: the editor tree of the store and the wardrobe
# ---------------------------------------------------------------------------------------------
class TreeCase(unittest.TestCase):
    def setUp(self):
        self.rt = Runtime()
        self.rt.load_shared()
        self.rt.run(CLIENT)
        self.rt.load('client/editor/tree.lua', 'client/editor/editor.lua', 'client/editor/panel.lua')
        self.e = self.rt.eval
        self.run = self.rt.run
        self.run('h = function(sex, c, m, v) return WCCatalog.forSex(sex)[c].models[m][v or 1].hash end')

    last = None

    def action(self, **data):
        data.setdefault('id', self.e('sid()'))
        r = self.rt.g.nui('editor:action', self.rt.table(data))
        # the answer carries the rebuilt tree (NuiMessages only has the one sent on open)
        if r is not None and r.payload is not None:
            self.last = r.payload
        return r

    def payload(self):
        return self.last if self.last is not None else self.e('lastPayload()')

    def node(self, node_id):
        return self.rt.g.findNode(self.payload().tree, node_id)

    def store(self, context='{}', sex='male', app=None):
        self.run('openEditor("store", %r, { %s context = %s })' % (sex, ('app = %s,' % app) if app else '', context))

    def count(self, expr):
        return self.e('(function() local n = 0 for _ in pairs(%s) do n = n + 1 end return n end)()' % expr)


class StoreTreeTests(TreeCase):
    def test_take_off_everything(self):
        self.store('{ storeProfile = "general", owned = {} }')
        root = [c.id for c in lua_list(self.payload().tree.children)]
        self.assertEqual(root[-1], 'clothing.undress')
        before = self.count('WCEditor.session().working.clothing.equipped')
        self.assertGreater(before, 0)
        r = self.action(op='invoke', control='clothing.undress')
        self.assertTrue(r.ok, r.code)
        self.assertEqual(self.count('WCEditor.session().working.clothing.equipped'), 0)
        self.assertTrue(self.e('WCEditor.session().working.body.upper ~= 0'))    # the body stays
        self.assertTrue(self.action(op='undo').ok)
        self.assertEqual(self.count('WCEditor.session().working.clothing.equipped'), before)

    def test_the_payment_choice_and_prices_in_gold(self):
        self.run('Config.Clothing.prices.hats = { cash = 3.5, gold = 0.2 }')
        self.store('{ storeProfile = "general", owned = {}, currencies = { "cash", "gold" } }')
        self.assertIsNotNone(self.node('store.currency'))
        self.assertTrue(self.action(op='set', control='clothing.hats.style', value=1).ok)
        self.assertEqual(self.payload().price.currency, 'cash')
        self.assertEqual(self.payload().price.total, 3.5)
        self.assertTrue(self.action(op='set', control='store.currency', value=2).ok)
        p = self.payload().price
        self.assertEqual((p.currency, p.total), ('gold', 0.2))
        self.assertEqual(self.node('item.hats').summary, '0.20 ذهب')
        # the currency is the session's, sent with the commit; the look did not change for it
        self.assertEqual(self.e('#WCEditor.session().history'), 1)
        self.assertTrue(self.action(op='save').ok)
        self.assertEqual(self.e('Commits[1].extra.currency'), 'gold')

    def test_an_item_without_a_price_in_the_currency_blocks_the_save(self):
        self.run('Config.Clothing.prices.masks = { gold = 1 }')
        self.store('{ storeProfile = "general", owned = {}, currencies = { "cash", "gold" } }')
        self.assertTrue(self.action(op='set', control='clothing.masks.style', value=1).ok)
        p = self.payload()
        self.assertFalse(p.canSave)
        self.assertIn('القناع', p.saveBlocked)
        self.assertTrue(self.action(op='set', control='store.currency', value=2).ok)
        self.assertTrue(self.payload().canSave)
        self.assertIsNone(self.payload().saveBlocked)

    def test_the_payment_choice_hides_with_one_currency(self):
        self.store('{ storeProfile = "general", owned = {}, currencies = { "cash" } }')
        self.assertIsNone(self.node('store.currency'))
        # a cash purchase sends no currency: the server's default, as before gold existed
        self.assertTrue(self.action(op='set', control='clothing.hats.style', value=1).ok)
        self.assertTrue(self.action(op='save').ok)
        self.assertIsNone(self.e('Commits[1].extra.currency'))

    def test_a_store_that_takes_only_gold_prices_and_pays_in_gold(self):
        # one currency: no choice is shown, so that currency is the default (not cash)
        self.run('Config.Clothing.prices.hats = { gold = 0.2 }')
        self.store('{ storeProfile = "general", owned = {}, currencies = { "gold" } }')
        self.assertIsNone(self.node('store.currency'))
        self.assertTrue(self.action(op='set', control='clothing.hats.style', value=1).ok)
        p = self.payload()
        self.assertEqual((p.price.currency, p.price.total), ('gold', 0.2))
        self.assertTrue(p.canSave, p.saveBlocked)
        self.assertTrue(self.action(op='save').ok)
        self.assertEqual(self.e('Commits[1].extra.currency'), 'gold')

    def test_a_model_price_shows_on_the_item(self):
        self.run('Config.Clothing.modelPrices.male.hats = { [1] = 9 }')
        self.store('{ storeProfile = "general", owned = {}, prices = { hats = 3.5 } }')
        self.assertTrue(self.action(op='set', control='clothing.hats.style', value=1).ok)
        self.assertEqual(self.node('item.hats').summary, '$9.00')
        self.assertEqual(self.payload().price.total, 9)
        self.assertTrue(self.action(op='set', control='clothing.hats.style', value=2).ok)
        self.assertEqual(self.node('item.hats').summary, '$3.50')

    def test_owned_colours_are_offered_and_free(self):
        self.run('''
            HAT = h('male', 'hats', 1)
            OWNED = { [tostring(HAT)] = { category = 'hats', palette = 'metaped_tint_hat', tint0 = 1, tint1 = 1, tint2 = 1,
                      colors = { { palette = 'metaped_tint_hat', tint0 = 9, tint1 = 9, tint2 = 9 } } } }
        ''')
        self.store('{ storeProfile = "general", owned = OWNED, tintPrice = 2.5 }')
        self.assertTrue(self.action(op='set', control='clothing.hats.style', value=1).ok)
        owned = self.node('clothing.hats.owned')
        self.assertIsNotNone(owned)
        self.assertEqual(len(lua_list(owned.options)), 3)       # original + two owned
        self.assertTrue(self.action(op='set', control='clothing.hats.owned', value=2).ok)
        self.assertEqual(self.e('WCEditor.session().working.clothing.tints.hats.tint0'), 9)
        self.assertEqual(self.payload().price.total, 0)          # owned: free
        self.assertTrue(self.action(op='set', control='clothing.hats.tint0', value=40).ok)
        self.assertEqual(self.payload().price.total, 2.5)        # a new colour
        self.assertEqual(self.node('clothing.hats.owned').value, 3)   # shown as the colour being tried

    def test_tint_sliders_follow_the_palette_limits_and_carry_its_strip(self):
        self.run("Config.Clothing.tints.limits = { metaped_tint_hat = { min = 3, max = 60, disabled = { 5, 6 } } }")
        self.store('{ storeProfile = "general", owned = {} }')
        self.assertTrue(self.action(op='set', control='clothing.hats.style', value=1).ok)
        self.assertTrue(self.action(op='set', control='clothing.hats.palette', value=1).ok)
        t0 = self.node('clothing.hats.tint0')
        self.assertEqual((t0.min, t0.max), (3, 60))
        self.assertEqual(list(lua_list(t0.skip)), [5, 6])
        self.assertEqual(t0.track, 'tex/palettes/metaped_tint_hat.png')
        self.assertEqual(self.e('WCEditor.session().working.clothing.tints.hats.tint0'), 3)   # moved inside
        self.assertFalse(self.action(op='set', control='clothing.hats.tint1', value=6).ok)
        self.run('Config.Clothing.tints.swatches = false')
        self.assertTrue(self.action(op='set', control='clothing.hats.tint1', value=7).ok)
        self.assertIsNone(self.node('clothing.hats.tint0').track)

    def test_sell_back_on_a_bought_item(self):
        self.run('''
            HAT = h('male', 'hats', 2)
            OWNED = { [tostring(HAT)] = { category = 'hats', source = 'store', pricePaid = 6, currency = 'cash' } }
            Sold = {}
            onResell = function(hash) table.insert(Sold, hash)
                return WCResult.ok({ owned = {}, refunded = 1.98, currency = 'cash' }) end
        ''')
        self.run('openEditor("store", "male", { onResell = onResell, context = { storeProfile = "general", owned = OWNED,'
                 ' resell = { enabled = true, percent = 0.33 } } })')
        self.assertIsNone(self.node('clothing.hats.resell'))     # nothing selected yet
        self.assertTrue(self.action(op='set', control='clothing.hats.style', value=2).ok)
        node = self.node('clothing.hats.resell')
        self.assertIsNotNone(node)
        self.assertTrue(node.danger)
        self.assertEqual(node.summary, '$1.98')
        r = self.action(op='invoke', control='clothing.hats.resell')
        self.assertTrue(r.ok, r.code)
        self.assertEqual(self.e('Sold[1]'), self.e('HAT'))
        # sold: the new ownership list is the editor's, the saved item is back in its place
        self.assertIsNone(self.e('WCEditor.session().working.clothing.equipped.hats'))
        self.assertIsNone(self.e('next(WCEditor.session().context.owned)'))
        # never on a starting piece or an item without a recorded price
        self.run('WCEditor.session().context.owned = { [tostring(HAT)] = { category = "hats", source = "starter",'
                 ' pricePaid = 6, currency = "cash" } }')
        self.assertIsNone(self.e('WCEditorTree.resellNode({}, WCEditor.session(), "hats", HAT)'))
        self.run('WCEditor.session().context.owned = { [tostring(HAT)] = { category = "hats", source = "store" } }')
        self.assertIsNone(self.e('WCEditorTree.resellNode({}, WCEditor.session(), "hats", HAT)'))
        self.run('WCEditor.session().context.owned[tostring(HAT)].pricePaid = 6;'
                 ' WCEditor.session().context.owned[tostring(HAT)].currency = "cash"')
        self.assertIsNotNone(self.e('WCEditorTree.resellNode({}, WCEditor.session(), "hats", HAT)'))

    def test_the_outfits_and_the_tailors_suggestions(self):
        self.run('''
            HAT = h('male', 'hats', 1)
            OWNED = { [tostring(HAT)] = { category = 'hats' } }
            OUTFITS = { { id = 7, name = 'Work', data = { equipped = { hats = HAT, boots = 12345 } } } }
            -- a suggestion of the config (first), then the starting outfits
            Config.Clothing.suggestions.male = { { id = 'town', label = 'اقتراحات الخيّاط',
                items = { { category = 'hats', model = 2, variant = 1 }, { category = 'masks', model = 2, variant = 1 } } } }
        ''')
        self.store('{ storeProfile = "general", owned = OWNED, outfits = OUTFITS, outfitsEnabled = true, maxOutfits = 3 }')
        group = self.node('tax.outfits')
        self.assertIsNotNone(group)
        self.assertIsNotNone(self.node('outfits'))
        self.assertIsNone(self.node('outfit.7.delete'))          # a store puts outfits on only
        self.assertIsNone(self.node('outfit.new'))
        self.assertTrue(self.action(op='invoke', control='outfit.7.equip').ok)
        self.assertEqual(self.e('WCEditor.session().working.clothing.equipped.hats'), self.e('HAT'))
        self.assertIsNone(self.e('WCEditor.session().working.clothing.equipped.boots'))   # not owned
        # the starting outfits as suggestions (the store's items, priced as usual)
        sugg = self.node('suggestions')
        self.assertIsNotNone(sugg)
        children = lua_list(sugg.children)
        self.assertGreater(len(children), 1)
        self.assertTrue(self.action(op='invoke', control=children[0].control).ok)
        self.assertEqual(self.e('WCEditor.session().working.clothing.equipped.hats'), self.e('h("male", "hats", 2)'))
        self.assertEqual(self.payload().price.total, 3.5 + 10)          # a hat and a mask, as priced
        self.assertTrue(self.e('WCEditor.session().working.body.upper ~= 0'))
        # the save confirmation offers "save this look as an outfit"
        self.assertIsNotNone(self.payload().saveOutfit)
        self.assertTrue(self.action(op='save', outfitName='  Sunday ').ok)
        self.assertEqual(self.e('Commits[1].extra.outfitName'), 'Sunday')

    def test_no_outfit_field_at_the_limit(self):
        self.run('OUTFITS = { { id = 1, name = "A", data = { equipped = {} } } }')
        self.store('{ storeProfile = "general", owned = {}, outfits = OUTFITS, outfitsEnabled = true, maxOutfits = 1 }')
        self.assertIsNone(self.payload().saveOutfit)
        self.assertTrue(self.action(op='set', control='clothing.hats.style', value=1).ok)
        self.assertTrue(self.action(op='save', outfitName='Late').ok)
        self.assertIsNone(self.e('Commits[1].extra.outfitName'))


class WardrobeTreeTests(TreeCase):
    def test_the_colour_of_an_owned_item(self):
        self.run('''
            app = AppearanceSchema.default('male')
            HAT = h('male', 'hats', 1)
            OWNED = { [tostring(HAT)] = { category = 'hats', palette = 'metaped_tint_hat', tint0 = 1, tint1 = 1, tint2 = 1,
                      colors = { { palette = 'metaped_tint_hat', tint0 = 9, tint1 = 9, tint2 = 9 } } } }
            for _, hash in pairs(app.clothing.equipped) do OWNED[tostring(hash)] = OWNED[tostring(hash)] or { category = 'x' } end
            openEditor('wardrobe', 'male', { app = app, context = { owned = OWNED, outfits = {}, maxOutfits = 3 } })
        ''')
        self.assertTrue(self.action(op='set', control='clothing.hats.style', value=1).ok)
        self.assertEqual(self.e('WCEditor.session().working.clothing.tints.hats.tint0'), 1)   # the last worn one
        choice = self.node('clothing.hats.colorway')
        self.assertEqual(len(lua_list(choice.options)), 3)
        self.assertTrue(self.action(op='set', control='clothing.hats.colorway', value=2).ok)
        self.assertEqual(self.e('WCEditor.session().working.clothing.tints.hats.tint0'), 9)
        self.assertTrue(self.action(op='set', control='clothing.hats.colorway', value=0).ok)
        self.assertFalse(self.e('WCEditor.session().working.clothing.tints.hats'))   # false: the original
        # a new outfit keeps each item's colour
        self.run('Saved = nil; WCEditor.session().opts.onOutfit = function(op, id, v) Saved = v return WCResult.ok({}) end')
        self.assertTrue(self.action(op='invoke', control='outfit.new.name', value='Blue').ok)
        self.assertFalse(self.e('Saved.tints.hats'))
        self.assertIsNotNone(self.e('Saved.tints'))

    def test_undress_is_offered_and_wrapping_needs_the_bridge(self):
        self.run('''
            app = AppearanceSchema.default('male')
            HAT = h('male', 'hats', 2)
            OWNED = { [tostring(HAT)] = { category = 'hats', source = 'store' } }
            for _, hash in pairs(app.clothing.equipped) do OWNED[tostring(hash)] = OWNED[tostring(hash)] or { category = 'x' } end
            Items = {}
            openEditor('wardrobe', 'male', { app = app, onItem = function(op, hash) table.insert(Items, { op, hash })
                return WCResult.ok({ owned = {} }) end, context = { owned = OWNED, outfits = {}, maxOutfits = 3 } })
        ''')
        self.assertIsNotNone(self.node('clothing.undress'))
        self.assertTrue(self.action(op='set', control='clothing.hats.style', value=2).ok)
        self.assertIsNone(self.node('clothing.hats.wrap'))       # the bridge is off
        self.run('Config.Clothing.items.enabled = true')
        self.assertTrue(self.action(op='set', control='clothing.hats.style', value=2).ok)
        self.assertIsNotNone(self.node('clothing.hats.wrap'))
        self.assertIsNotNone(self.node('outfit.new'))
        r = self.action(op='invoke', control='clothing.hats.wrap')
        self.assertTrue(r.ok, r.code)
        self.assertEqual(self.e('Items[1][1]'), 'wrap')
        self.assertIsNone(self.e('WCEditor.session().working.clothing.equipped.hats'))


# ---------------------------------------------------------------------------------------------
#  Client: the flow (catalogue, light, commit extras), the camera, the states
# ---------------------------------------------------------------------------------------------
class FlowTests(unittest.TestCase):
    def setUp(self):
        self.rt = make_commerce()
        self.run = self.rt.run
        self.e = self.rt.eval

    def open(self):
        self.run('CallbackResults = { ["w_creators:store:open"] = storeData() }')
        self.run('R = table.pack(WCStore.open("valentine_clothing"))')
        return self.e('R[1]')

    def test_the_catalogue_is_read_before_the_fitting_room_and_closed_after(self):
        self.run('''
            Scenes = {}
            local nextScene = 500
            WCNative.scene.createAnimScene = function(dict, flags, playlist)
                nextScene = nextScene + 1
                Scenes[nextScene] = { dict = dict, playlist = playlist, entities = {} }
                Log[#Log + 1] = { op = 'scene:' .. playlist, args = table.pack(nextScene) }
                return nextScene
            end
            WCNative.scene.setAnimSceneOrigin = function(s, x, y, z, h) Scenes[s].origin = { x, y, z, h } return true end
            WCNative.scene.setAnimSceneEntity = function(s, name, e) Scenes[s].entities[name] = e return true end
            WCNative.scene.loadAnimScene = function() return true end
            WCNative.scene.isAnimSceneLoaded = function() return true end
            WCNative.scene.startAnimScene = function(s) Scenes[s].started = true return true end
            WCNative.scene.isAnimSceneFinished = function() return false end
            WCNative.scene.deleteAnimScene = function(s) Scenes[s].deleted = true
                Log[#Log + 1] = { op = 'scene:delete', args = table.pack(s) } return true end
        ''')
        self.assertTrue(self.open())
        enter = [s for s in self.e('Scenes').values() if s.playlist == 'PBL_ENTER']
        self.assertEqual(len(enter), 1)
        self.assertEqual(enter[0].dict, 'script@ambient@shop@CATALOG_PLAYER')
        self.assertEqual(enter[0].entities.player, self.e('MyPed'))
        # the origin: the book's position lowered to the floor, facing the book's heading
        self.assertAlmostEqual(enter[0].origin[3], 117.5 - 1.065, places=3)
        self.assertAlmostEqual(enter[0].origin[4], -170.0, places=3)
        self.assertTrue(enter[0].deleted)                          # freed before the move
        self.assertLess(self.e('indexOf("scene:PBL_ENTER")'), self.e('indexOf("callback:w_creators:scene:prepare")'))
        self.assertLess(self.e('indexOf("scene:delete")'), self.e('indexOf("SetEntityCoords")'))
        # back at the counter: the exit playlist
        self.run('cancel()')
        settle(self.rt, 500, 12)
        exits = [s for s in self.e('Scenes').values() if s.playlist == 'PBL_EXIT_INDEX']
        self.assertEqual(len(exits), 1)
        self.assertTrue(exits[0].deleted)

    def test_a_flow_stopped_during_the_reading_never_reaches_the_fitting_room(self):
        # the reading yields for seconds: a player who dies meanwhile (or whose session the server
        # closed) is neither isolated (scene:prepare would start a character switch without a
        # session) nor faded and moved
        for stop in ('Peds[MyPed].dead = true', 'WCServiceFlow.current().abortReason = "sessionClosed"'):
            self.rt = make_commerce()
            self.run, self.e = self.rt.run, self.rt.eval
            self.run('''
                Scenes = {}
                WCNative.scene.createAnimScene = function(dict, flags, playlist)
                    Scenes[#Scenes + 1] = { playlist = playlist } return #Scenes end
                WCNative.scene.setAnimSceneOrigin = function() return true end
                WCNative.scene.setAnimSceneEntity = function() return true end
                WCNative.scene.loadAnimScene = function() return true end
                WCNative.scene.isAnimSceneLoaded = function() return true end
                WCNative.scene.startAnimScene = function() return true end
                WCNative.scene.isAnimSceneFinished = function() %s return true end
                WCNative.scene.deleteAnimScene = function(s) Scenes[s].deleted = true return true end
            ''' % stop)
            self.assertFalse(self.open(), stop)
            self.assertIsNone(self.e('indexOf("callback:w_creators:scene:prepare")'), stop)
            self.assertIsNone(self.e('indexOf("SetEntityCoords")'), stop)
            self.assertTrue(self.e('Scenes[1].deleted'), stop)
            self.assertFalse(self.e('WCCatalogue.active()'), stop)
            self.assertIsNone(self.e('WCServiceFlow.current()'), stop)

    def test_a_store_without_a_book_or_with_the_feature_off_reads_nothing(self):
        self.run('Config.Clothing.catalogue.enabled = false; Made = 0;'
                 ' WCNative.scene.createAnimScene = function() Made = Made + 1 return nil end')
        self.assertTrue(self.open())
        self.assertEqual(self.e('Made'), 0)

    def test_the_fitting_room_light_follows_the_player(self):
        self.run('''
            Lights = {}
            GetOffsetFromEntityInWorldCoords = function(e, x, y, z) local c = Peds[e].coords
                return vector3(c.x + x, c.y + y, c.z + z) end
            DrawLightWithRange = function(...) Lights[#Lights + 1] = table.pack(...) end
        ''')
        self.assertTrue(self.open())
        settle(self.rt, 50, 3)
        self.assertGreater(self.e('#Lights'), 0)
        light = self.e('Lights[#Lights]')
        self.assertEqual((light[4], light[5], light[6]), (255, 255, 255))
        self.assertAlmostEqual(light[7], 15.0)
        self.assertAlmostEqual(light[8], 10.0)
        self.assertTrue(self.e('WCPreviewEnv.changes().light ~= nil'))

    def test_the_commit_carries_the_currency_and_the_outfit_name(self):
        self.run('CallbackResults = { ["w_creators:store:open"] = storeData({ outfits = {}, outfitsEnabled = true,'
                 ' maxOutfits = 3, currencies = { "cash", "gold" } }),'
                 ' ["w_creators:store:commit"] = function(delay, token, opId, app) return okResult({ appearance = app }) end }')
        self.run('R = table.pack(WCStore.open("valentine_clothing"))')
        self.assertTrue(self.e('R[1]'))
        self.run('''
            local s = WCEditor.session()
            WCEditor.action({ id = s.id, op = 'set', control = 'store.currency', value = 2 })
            makeDirty()
            RES = WCEditor.action({ id = s.id, op = 'save', outfitName = 'Sunday' })
        ''')
        self.assertTrue(self.e('RES.ok'), self.e('RES.code'))
        # (false, token, opId, look, extra): the extra table after the look
        args = self.e('callbacks("w_creators:store:commit")[1]')
        self.assertEqual(args[5].currency, 'gold')
        self.assertEqual(args[5].outfitName, 'Sunday')

    def test_an_outfit_card_opens_the_store_with_its_look(self):
        self.run('''
            HAT = WCCatalog.forSex('male').hats.models[2][1].hash
            CallbackResults = { ['w_creators:store:open'] = storeData() }
            fireEvent('w_creators:client:openStore', nil, 'valentine_clothing', { equipped = { hats = HAT }, tints = {} })
        ''')
        settle(self.rt)
        self.assertEqual(self.e('WCEditor.session().working.clothing.equipped.hats'), self.e('HAT'))
        self.assertIsNone(self.e('WCEditor.session().saved.clothing.equipped.hats'))   # not saved: bought on commit
        # the ped was dressed in the card's look before the editor diffs from it
        self.assertEqual(self.e('RenderCalls[#RenderCalls].clothing.equipped.hats'), self.e('HAT'))


class CameraTests(unittest.TestCase):
    def setUp(self):
        self.rt = make_client()
        self.run = self.rt.run
        self.e = self.rt.eval

    def test_the_hand_framings_aim_at_the_hand_bone(self):
        self.run('''
            Bones = { SKEL_L_Hand = 10, SKEL_R_Hand = 11 }
            GetEntityBoneIndexByName = function(e, name) return Bones[name] or -1 end
            GetWorldPositionOfEntityBone = function(e, i)
                local c = Peds[e].coords
                return vector3(c.x + (i == 10 and -0.3 or 0.3), c.y, c.z + 0.1)
            end
            WCCamera.open(MyPed, 'handLeft')
        ''')
        self.assertEqual(self.e('WCCamera.current()'), 'handLeft')
        aims = [e for e in self.e('Log').values() if e.op == 'PointCamAtCoord']
        target = aims[-1].args
        c = self.e('Peds[MyPed].coords')
        self.assertAlmostEqual(target[2], c.x - 0.3, places=3)
        self.assertTrue(self.e('WCCamera.focus("handRight")'))
        target = [e for e in self.e('Log').values() if e.op == 'PointCamAtCoord'][-1].args
        self.assertAlmostEqual(target[2], c.x + 0.3, places=3)
        # the skeleton not readable: the two-hands framing instead
        self.run('GetEntityBoneIndexByName = function() return -1 end; WCCamera.focus("handLeft", true)')
        self.assertEqual(self.e('WCCamera.current()'), 'handLeft')
        self.assertIn('handLeft', read(RESOURCE / 'client' / 'editor' / 'tree.lua'))

    def test_the_arms_items_use_the_hand_that_wears_them(self):
        rt = Runtime().load_shared()
        cams = {s.id: s.camera for g in lua_list(rt.eval('Config.Clothing.taxonomy')) for s in lua_list(g.subs)}
        self.assertEqual(cams['jewelry_rings_left'], 'handLeft')
        self.assertEqual(cams['jewelry_bracelets'], 'handLeft')
        self.assertEqual(cams['jewelry_rings_right'], 'handRight')
        self.assertEqual(cams['gloves'], 'handRight')


# The skeleton of the store camera tests: bone positions in the ped's own frame (right, ahead, up
# from its origin), and GetPedBoneCoords moving a bone along the ped's axes (BoneAxes = -1 flips
# the ahead axis: a bone whose own axes point backwards).
BONE_STUBS = r'''
BoneLocal = { [57278] = { 0.0, 0.03, 0.66 }, [21030] = { 0.0, 0.03, 0.66 },
              [7966] = { 0.24, 0.05, -0.12 }, [37709] = { -0.24, 0.05, -0.12 } }
BoneAxes = 1
function GetPedBoneCoords(e, bone, ox, oy, oz)
    local p = Peds[e]; if not p then return vector3(0, 0, 0) end
    local b = BoneLocal[bone] or { 0, 0, 0 }
    local h = math.rad(p.heading)
    local rx, ry, fx, fy = math.cos(h), math.sin(h), -math.sin(h), math.cos(h)
    local r, f, u = b[1] + (ox or 0), b[2] + BoneAxes * (oy or 0), b[3] + (oz or 0)
    return vector3(p.coords.x + rx * r + fx * f, p.coords.y + ry * r + fy * f, p.coords.z + u)
end
function lastOf(op)
    for i = #Log, 1, -1 do if Log[i].op == op then return Log[i].args end end
end
'''

# The store camera's wall probe (WCNative.camera.firstWall): Walls are lines y = <y> across the room
# (optionally only from minX / up to maxX); the probe answers the first one its line crosses, the
# way GET_SHAPE_TEST_RESULT answers (retval, hit 1/0, end coords, normal, entity).
WALL_STUBS = r'''
Walls, Probes = {}, {}
local invoke = Citizen.InvokeNative
Citizen.InvokeNative = function(hash, ...)
    if hash ~= 0x377906D8A31E5586 then return invoke(hash, ...) end
    local x1, y1, z1, x2, y2, z2, flags, ignore, options = ...
    Probes[#Probes + 1] = { x1, y1, z1, x2, y2, z2, flags = flags, ignore = ignore, options = options }
    return #Probes
end
function GetShapeTestResult(handle)
    local p, best = Probes[handle], nil
    for _, wall in ipairs(Walls) do
        if (p[2] - wall.y) * (p[5] - wall.y) < 0 then
            local t = (wall.y - p[2]) / (p[5] - p[2])
            local x = p[1] + (p[4] - p[1]) * t
            if x >= (wall.minX or -math.huge) and x <= (wall.maxX or math.huge) and (not best or t < best) then best = t end
        end
    end
    if not best then return 2, 0, vector3(0, 0, 0), vector3(0, 0, 0), 0 end
    return 2, 1, vector3(p[1] + (p[4] - p[1]) * best, p[2] + (p[5] - p[2]) * best, p[3] + (p[6] - p[3]) * best),
        vector3(0, -1, 0), 0
end
'''


def geometry(rt, heading):
    """Where the last camera stands relative to the ped facing `heading`: (ahead, right, up,
    flat distance, fov, ped in the horizontal view)."""
    import math
    cam, aim = rt.eval('lastOf("SetCamCoord")'), rt.eval('lastOf("PointCamAtCoord")')
    fov = rt.eval('lastOf("SetCamFov")')[2]
    p = rt.eval('Peds[MyPed].coords')
    h = math.radians(heading)
    rx, ry, fx, fy = math.cos(h), math.sin(h), -math.sin(h), math.cos(h)
    dx, dy, dz = cam[2] - p.x, cam[3] - p.y, cam[4] - p.z
    ax, ay, bx, by = aim[2] - cam[2], aim[3] - cam[3], p.x - cam[2], p.y - cam[3]
    off = math.degrees(abs(math.atan2(ax * by - ay * bx, ax * bx + ay * by)))
    half = math.degrees(math.atan(math.tan(math.radians(fov / 2)) * 16 / 9))
    return dx * fx + dy * fy, dx * rx + dy * ry, dz, math.hypot(dx, dy), fov, off <= half


class StoreCameraTests(unittest.TestCase):
    """The clothing store / wardrobe camera: in front of the player on every category, from the
    fitting stand's heading (never a heading he only had for a moment), with the Jump On store's
    framings (their numbers, laid out on ours)."""

    def setUp(self):
        self.rt = make_client()
        self.rt.run(BONE_STUBS)
        self.run = self.rt.run
        self.e = self.rt.eval

    def views(self):
        rt = Runtime().load_shared()
        out = ['fullBody']
        for g in lua_list(rt.eval('Config.Clothing.taxonomy')):
            out.append(g.camera)
            out += [s.camera for s in lua_list(g.subs)]
        return sorted(set(out))

    def stands(self, kind):
        out = []
        for loc in lua_list(self.e('WCLocations.byType("%s")' % kind)):
            if loc.preview is not None:
                out.append((loc.id, loc.preview.x, loc.preview.y, loc.preview.z, loc.preview.w))
            else:
                out.append((loc.id, loc.coords.x, loc.coords.y, loc.coords.z, 137.0))
        return out

    def open_on(self, x, y, z, stand, live, lang='ar'):
        # the body origin is about a metre above the floor the stand gives
        self.run('LocaleKey = "%s"; WCCamera.close(); Peds[MyPed].coords = vector3(%r, %r, %r);'
                 ' Peds[MyPed].heading = %r' % (lang, x, y, z + 1.0, live))
        self.run('WCCamera.anchor(MyPed, { heading = %r, set = "shop", hold = 1500 })' % stand)
        self.assertTrue(self.e('WCCamera.open(MyPed, "fullBody")'))

    def test_every_category_view_stands_in_front_of_the_player_in_every_store(self):
        views = self.views()
        self.assertIn('handLeft', views)
        stores = self.stands('clothing')
        self.assertEqual(len(stores), 4)
        for lang in ('ar', 'en'):
            for loc, x, y, z, h in stores:
                # opened while the player still had the opposite heading (the old failure)
                self.open_on(x, y, z, h, (h + 180.0) % 360.0, lang)
                self.assertAlmostEqual(self.e('Peds[MyPed].heading'), h % 360.0, places=3, msg=loc)
                self.assertEqual(self.e('WCCamera.currentSet()'), 'shop')
                for view in views:
                    self.run('clearLog(); WCCamera.focus("%s", true)' % view)
                    ahead, right, up, dist, fov, seen = geometry(self.rt, h)
                    what = '%s %s %s' % (loc, view, lang)
                    self.assertGreater(ahead, 0.25, what)             # in front, never behind or beside
                    self.assertTrue(0.5 <= dist <= 3.2, (what, dist))  # neither in his face nor across the room
                    self.assertTrue(-0.85 <= up <= 1.6, (what, up))   # above the floor, below the ceiling
                    self.assertTrue(seen, what)                       # the player is in the picture

    def test_the_wardrobes_frame_the_way_the_player_faces(self):
        wardrobes = self.stands('wardrobe')
        self.assertEqual(len(wardrobes), 3)
        for loc, x, y, z, h in wardrobes:
            self.open_on(x, y, z, h, h)
            for view in self.views():
                self.run('clearLog(); WCCamera.focus("%s", true)' % view)
                ahead, right, up, dist, fov, seen = geometry(self.rt, h)
                self.assertGreater(ahead, 0.25, (loc, view))
                self.assertTrue(seen, (loc, view))

    def test_the_store_framings_are_the_jump_on_numbers(self):
        # (ahead, right, up) of the camera, the target's right / up, the fov; right mirrored in RTL
        want = {
            'fullBody': (2.0, 0.5, 0.3, 0.5, 0.0, 60.0),
            'upperBody': (1.5, 0.3, 0.5, 0.3, 0.3, 45.0),
            'lowerBody': (2.0, 0.3, 0.0, 0.3, -0.4, 40.0),
            'feet': (1.5, 1.0, 0.0, 0.3, -0.6, 30.0),
        }
        import math
        for lang, sign in (('en', 1), ('ar', -1)):
            self.open_on(0.0, 0.0, 0.0, 0.0, 0.0, lang)
            for view, (ahead, right, up, tRight, tUp, fov) in want.items():
                self.run('clearLog(); WCCamera.focus("%s", true)' % view)
                cam, aim = self.e('lastOf("SetCamCoord")'), self.e('lastOf("PointCamAtCoord")')
                p = self.e('Peds[MyPed].coords')
                # heading 0: ahead is +y, right is +x
                self.assertAlmostEqual(cam[3] - p.y, ahead, places=3, msg=view)
                self.assertAlmostEqual(cam[2] - p.x, sign * right, places=3, msg=view)
                self.assertAlmostEqual(cam[4] - p.z, up, places=3, msg=view)
                self.assertAlmostEqual(aim[2] - p.x, sign * tRight, places=3, msg=view)
                self.assertAlmostEqual(aim[4] - p.z, tUp, places=3, msg=view)
                self.assertAlmostEqual(self.e('lastOf("SetCamFov")')[2], fov, places=3, msg=view)
            # the head: the head bone moved by (0.1, 1.0, 0.5), aimed at it moved by (0.0, 0.1, 0.0)
            self.run('clearLog(); WCCamera.focus("face", true)')
            cam, aim = self.e('lastOf("SetCamCoord")'), self.e('lastOf("PointCamAtCoord")')
            p = self.e('Peds[MyPed].coords')
            self.assertAlmostEqual(cam[2] - p.x, 0.1, places=3)
            self.assertAlmostEqual(cam[3] - p.y, 0.03 + 1.0, places=3)
            self.assertAlmostEqual(cam[4] - p.z, 0.66 + 0.5, places=3)
            self.assertAlmostEqual(aim[3] - p.y, 0.03 + 0.1, places=3)
            self.assertEqual(self.e('lastOf("SetCamFov")')[2], 30.0)
            self.assertFalse(math.isnan(cam[2]))

    def test_a_store_camera_a_wall_hides_is_kept_in_front_of_it(self):
        # The Valentine hotel room in Arabic, the Tumbleweed booth: the store's framing stood inside
        # or behind a wall and, aimed at the player, showed the wall. Heading 0: ahead is +y, right +x.
        import math
        self.run(WALL_STUBS)
        margin, least = self.e('WCCamera.WALL_MARGIN'), self.e('WCCamera.WALL_MIN')
        self.assertEqual((margin, least), (0.15, 0.45))

        def shot(view):
            self.run('clearLog(); WCCamera.focus("%s", true)' % view)
            return self.e('lastOf("SetCamCoord")'), self.e('lastOf("PointCamAtCoord")')

        def walled(view, wall, seen=True, lang='ar'):
            """The camera of `view` with no wall, then with a wall across the room at y = wall."""
            self.run('Walls = {}')
            self.open_on(0.0, 0.0, 0.0, 0.0, 0.0, lang)
            p = self.e('Peds[MyPed].coords')
            cam0, aim0 = shot(view)
            self.run('Walls = { { y = %r } }; Probes = {}' % wall)  # both sides walled in
            cam, aim = shot(view)
            x0, y0, x, y = cam0[2] - p.x, cam0[3] - p.y, cam[2] - p.x, cam[3] - p.y
            self.assertGreater(y0, wall, view)                          # the framing stood behind it
            want = max(wall / y0 * math.hypot(x0, y0) - margin, least)  # the wall's distance on its line
            self.assertAlmostEqual(math.hypot(x, y), want, places=3, msg=view)
            if want > least:
                self.assertLess(y, wall, view)                          # in front of the wall
            self.assertAlmostEqual(x * y0, y * x0, places=4, msg=view)  # on its line to the player
            self.assertAlmostEqual(cam[4], cam0[4], places=4, msg=view)  # at the same height
            for i in (2, 3, 4):
                self.assertAlmostEqual(aim[i], aim0[i], places=4, msg=view)  # aimed at the same point
            # the probe runs from the player at the camera's height, on the map only, past the player
            probe = self.e('Probes[1]')
            self.assertEqual((probe[1], probe[2], probe[3]), (p.x, p.y, cam0[4]))
            self.assertEqual((probe.flags, probe.ignore, probe.options), (1, self.e('MyPed'), 7))
            if seen:
                self.assertTrue(geometry(self.rt, 0.0)[5], view)        # the player is in the picture

        walled('fullBody', 1.2)  # the mirrored and the unmirrored side both walled in
        walled('feet', 0.9)
        walled('face', 0.8)      # a bone framing (frameBone)
        walled('fullBody', 0.3, seen=False)  # a wall right in front: never nearer than WALL_MIN
        # one hand on its named bone (the store's bone framing falls back to it)
        self.run('''
            BoneAxes = -1
            GetEntityBoneIndexByName = function(e, name) return name == 'SKEL_L_Hand' and 10 or -1 end
            GetWorldPositionOfEntityBone = function(e, i) local c = Peds[e].coords return vector3(c.x - 0.3, c.y, c.z + 0.1) end
        ''')
        walled('handLeft', 0.6, seen=False)  # the hand, not the body, is the picture here
        self.assertAlmostEqual(self.e('lastOf("PointCamAtCoord")')[2], -0.3, places=3)
        self.run('BoneAxes = 1')

        # walled in on the mirrored side only: Jump On's own (unmirrored) framing, at its full distance
        self.open_on(0.0, 0.0, 0.0, 0.0, 0.0, 'ar')
        self.run('Walls = { { y = 1.2, maxX = -0.05 } }')
        cam, aim = shot('fullBody')
        self.assertEqual([round(v, 3) for v in (cam[2], cam[3], aim[2])], [0.5, 2.0, 0.5])
        # in English that side is the framing itself: unchanged
        self.open_on(0.0, 0.0, 0.0, 0.0, 0.0, 'en')
        cam, aim = shot('fullBody')
        self.assertEqual([round(v, 3) for v in (cam[2], cam[3], aim[2])], [0.5, 2.0, 0.5])

        # only the store and the wardrobe: the other editors never probe and keep their framings
        self.run('WCCamera.close(); Walls = { { y = 1.2 } }; Probes = {}; LocaleKey = "en";'
                 ' Peds[MyPed].heading = 0.0; clearLog(); WCCamera.open(MyPed)')
        self.assertIsNone(self.e('WCCamera.currentSet()'))
        self.assertEqual(self.e('#Probes'), 0)
        self.assertAlmostEqual(self.e('lastOf("SetCamCoord")')[3] - self.e('Peds[MyPed].coords').y,
                               self.e('WCCamera.PRESETS.fullBody.distance'), places=3)

    def test_a_turned_player_is_framed_from_where_the_camera_opened(self):
        # the player's own turn never swings the camera, the bone framings included
        self.open_on(0.0, 0.0, 0.0, 0.0, 0.0)
        self.run('clearLog(); WCCamera.focus("head", true)')
        before = self.e('lastOf("SetCamCoord")')
        self.run('WCCamera.rotate(120); clearLog(); WCCamera.focus("head", true)')
        after = self.e('lastOf("SetCamCoord")')
        for i in (2, 3, 4):
            self.assertAlmostEqual(before[i], after[i], places=3)

    def test_a_bone_framing_that_would_stand_behind_the_player_is_never_shown(self):
        # a bone whose own axes point backwards: the store's numbers would put the camera behind
        # him, so the default framing of that view is used instead
        self.run('BoneAxes = -1')
        self.open_on(0.0, 0.0, 0.0, 0.0, 0.0)
        for view in ('head', 'face', 'handRight', 'handLeft'):
            self.run('clearLog(); WCCamera.focus("%s", true)' % view)
            ahead, right, up, dist, fov, seen = geometry(self.rt, 0.0)
            self.assertGreater(ahead, 0.25, view)
            self.assertEqual(self.e('WCCamera.current()'), view)
        # an unreadable skeleton (every bone at the origin) likewise
        self.run('BoneAxes = 1; GetPedBoneCoords = function(e) return Peds[e].coords end')
        self.run('clearLog(); WCCamera.focus("head", true)')
        self.assertGreater(geometry(self.rt, 0.0)[0], 0.25)

    def test_the_player_is_held_on_the_stand_heading_but_never_against_his_own_turn(self):
        self.open_on(0.0, 0.0, 0.0, 90.0, 270.0)
        self.assertAlmostEqual(self.e('Peds[MyPed].heading'), 90.0)
        # a task the move ended turns him back a moment later: turned to the stand again
        self.run('Peds[MyPed].heading = 270.0; tick(16)')
        self.assertAlmostEqual(self.e('Peds[MyPed].heading'), 90.0)
        # his own turn is kept
        self.run('WCCamera.rotate(45); tick(16); tick(16)')
        self.assertAlmostEqual(self.e('Peds[MyPed].heading'), 135.0)
        self.run('WCCamera.pose("profile"); tick(16)')
        self.assertAlmostEqual(self.e('Peds[MyPed].heading'), 225.0)
        self.run('WCCamera.pose("front"); tick(16)')
        self.assertAlmostEqual(self.e('Peds[MyPed].heading'), 135.0)
        # the hold ends after its time, and with the camera
        self.run('tick(2000); Peds[MyPed].heading = 10.0; tick(16)')
        self.assertAlmostEqual(self.e('Peds[MyPed].heading'), 10.0)
        self.open_on(0.0, 0.0, 0.0, 90.0, 90.0)
        self.run('WCCamera.close(); Peds[MyPed].heading = 10.0; tick(16)')
        self.assertAlmostEqual(self.e('Peds[MyPed].heading'), 10.0)

    def test_the_other_editors_keep_the_default_framings(self):
        # no anchor: the selector, the creator, the barber and the clinic are unchanged
        self.run('Peds[MyPed].heading = 0.0; LocaleKey = "en"; clearLog(); WCCamera.open(MyPed)')
        self.assertIsNone(self.e('WCCamera.currentSet()'))
        cam = self.e('lastOf("SetCamCoord")')
        p = self.e('Peds[MyPed].coords')
        self.assertAlmostEqual(cam[3] - p.y, self.e('WCCamera.PRESETS.fullBody.distance'), places=3)
        # an anchor is for one open: the next plain open is plain again
        self.open_on(0.0, 0.0, 0.0, 0.0, 0.0)
        self.assertEqual(self.e('WCCamera.currentSet()'), 'shop')
        self.run('WCCamera.close(); WCCamera.open(MyPed)')
        self.assertIsNone(self.e('WCCamera.currentSet()'))
        # an anchor of another ped is ignored
        self.run('WCCamera.close(); OTHER = makePed("mp_male", 5, 5, 5, 0);'
                 ' WCCamera.anchor(OTHER, { heading = 45, set = "shop" }); WCCamera.open(MyPed)')
        self.assertIsNone(self.e('WCCamera.currentSet()'))

    def tailor_clearance(self, npc):
        """The closest the last camera's line of sight (lens to aim point) comes to the tailor's
        body (a vertical segment from his floor up 1.8 m), in metres."""
        import math
        cam, aim = self.e('lastOf("SetCamCoord")'), self.e('lastOf("PointCamAtCoord")')
        best = float('inf')
        for i in range(101):
            t = i / 100.0
            px, py, pz = (cam[k] + (aim[k] - cam[k]) * t for k in (2, 3, 4))
            dz = max(0.0, npc.z - pz, pz - (npc.z + 1.8))
            best = min(best, math.sqrt((px - npc.x) ** 2 + (py - npc.y) ** 2 + dz ** 2))
        return best

    def test_the_tailor_never_stands_between_the_camera_and_the_player(self):
        # Screenshot 40 (Valentine, head > mask): the move to the fitting room was lost and the
        # player stayed at the counter, facing the book; the camera opened in front of him, i.e.
        # across the counter BEHIND the tailor, whose back filled the screen with his head above
        # the frame. Reproduced here with the default framing on the reader at the counter...
        import math
        shops = [loc for loc in lua_list(self.e('WCLocations.byType("clothing")')) if loc.npc]
        self.assertEqual(len(shops), 3)
        for loc in shops:
            book, npc = loc.book, loc.npc.coords
            ahead = (-math.sin(math.radians(book.w)), math.cos(math.radians(book.w)))
            # the reader stands 0.6 m behind the book, on the floor under it, facing the book's heading
            rx, ry = book.x - ahead[0] * 0.6, book.y - ahead[1] * 0.6
            self.run('LocaleKey = "ar"; WCCamera.close(); Peds[MyPed].coords = vector3(%r, %r, %r);'
                     ' Peds[MyPed].heading = %r; clearLog(); WCCamera.open(MyPed, "fullBody")'
                     % (rx, ry, book.z - 1.065 + 1.0, book.w % 360.0))
            if loc.id == 'valentine_clothing':
                self.assertLess(self.tailor_clearance(npc), 0.35, loc.id)
            # ...and never again from the fitting stand: every view of the store has a clear line
            p = loc.preview
            self.open_on(p.x, p.y, p.z, p.w, p.w)
            for view in self.views():
                self.run('clearLog(); WCCamera.focus("%s", true)' % view)
                self.assertGreater(self.tailor_clearance(npc), 1.0, (loc.id, view))


class StoreFittingFlowTests(unittest.TestCase):
    """The fitting-room move: the player is let go of the reading and his tasks are cleared a
    moment BEFORE he is moved and turned, and the camera frames from the stand's heading even when
    the game turns him back after the move."""

    def setUp(self):
        self.rt = make_commerce()
        self.run = self.rt.run
        self.e = self.rt.eval
        self.run(BONE_STUBS)
        self.run('''
            local clear, move = ClearPedTasksImmediately, SetEntityCoords
            Moves, Clears = {}, {}
            SetEntityCoords = function(e, x, y, z, ...)
                Moves[#Moves + 1] = { at = Clock.now, x = x, y = y, z = z }
                return move(e, x, y, z, ...)
            end
            -- the game: tasks cleared after the move turn him back to his old heading a moment later
            ClearPedTasksImmediately = function(ped, ...)
                Clears[#Clears + 1] = Clock.now
                if TurnBack and #Moves > 0 and Peds[ped] then
                    local h = TurnBack
                    TurnBack = nil
                    CreateThread(function() Wait(50) Peds[ped].heading = h end)
                end
                return clear(ped, ...)
            end
        ''')

    def test_the_store_frames_from_the_stand_heading_after_the_game_turned_the_player_back(self):
        self.run('TurnBack = 270.0; CallbackResults = { ["w_creators:store:open"] = storeData() }')
        self.run('R = table.pack(WCStore.open("valentine_clothing"))')
        self.assertTrue(self.e('R[1]'))
        settle(self.rt, 300, 3)
        # let go first (tasks cleared), a moment, then the move to the stand
        self.assertGreaterEqual(self.e('#Clears'), 1)
        stand = self.e('Moves[1]')
        self.assertEqual((stand.x, stand.y, stand.z), (10.0, 20.0, 30.0))
        self.assertGreaterEqual(self.e('WCServiceFlow.RELEASE_MS'), 100)
        self.assertGreaterEqual(stand.at - self.e('Clears[1]'), self.e('WCServiceFlow.RELEASE_MS'))
        self.assertIsNotNone(self.e('indexOf("placeOnGround")'))
        # the camera: the store framings, in front of the stand's heading; the player faces it
        self.assertEqual(self.e('WCCamera.currentSet()'), 'shop')
        self.assertAlmostEqual(self.e('Peds[MyPed].heading'), 90.0)
        self.run('clearLog(); WCCamera.focus("fullBody", true)')
        self.assertGreater(geometry(self.rt, 90.0)[0], 0.25)

    def test_an_editor_that_did_not_open_leaves_no_anchor_for_the_next_camera(self):
        # the store anchored the camera on its stand, then its editor refused to open: the next
        # open of the player (the barber's chair) must be framed as its own, not from the stand
        self.run('''
            local open = WCEditor.open
            WCEditor.open = function() return false, 'BUSY' end
            CallbackResults = { ["w_creators:store:open"] = storeData() }
            R = table.pack(WCStore.open("valentine_clothing"))
            WCEditor.open = open
        ''')
        self.assertFalse(self.e('R[1]'))
        self.run('Peds[MyPed].heading = 200.0; WCCamera.open(MyPed, "hair")')
        self.assertIsNone(self.e('WCCamera.currentSet()'))
        self.assertAlmostEqual(self.e('Peds[MyPed].heading'), 200.0)

    def test_a_player_the_move_did_not_keep_on_the_stand_is_put_back_on_it(self):
        # the move lost to the game (he is still downstairs at the counter when the camera opens)
        self.run('''
            local enter = WCPreviewEnv.enter
            WCPreviewEnv.enter = function(opts)
                Peds[MyPed].coords = vector3(100.0, 200.0, 50.0)
                return enter(opts)
            end
            CallbackResults = { ["w_creators:store:open"] = storeData() }
            R = table.pack(WCStore.open("valentine_clothing"))
        ''')
        self.assertTrue(self.e('R[1]'))
        c = self.e('Peds[MyPed].coords')
        self.assertEqual((c.x, c.y, c.z), (10.0, 20.0, 30.0))

    def test_the_wardrobe_uses_the_store_framings_where_the_player_stands(self):
        self.run('Peds[MyPed].heading = 33.0; CallbackResults = { ["w_creators:wardrobe:open"] = wardrobeData() }')
        self.run('R = table.pack(WCWardrobe.open("valentine_wardrobe"))')
        self.assertTrue(self.e('R[1]'))
        self.assertEqual(self.e('WCCamera.currentSet()'), 'shop')
        self.assertEqual(self.e('#Moves'), 0)                        # never moved
        self.run('clearLog(); WCCamera.focus("upperBody", true)')
        self.assertGreater(geometry(self.rt, 33.0)[0], 0.25)

    def test_the_way_back_sets_the_player_down_on_the_shop_floor(self):
        self.run('CallbackResults = { ["w_creators:store:open"] = storeData() }')
        self.run('R = table.pack(WCStore.open("valentine_clothing"))')
        self.assertTrue(self.e('R[1]'))
        self.run('clearLog(); cancel()')
        settle(self.rt, 300, 6)
        back = self.e('Moves[#Moves]')
        self.assertEqual((back.x, back.y, back.z), (100.0, 200.0, 50.0))
        self.assertIsNotNone(self.e('indexOf("placeOnGround")'))
        self.assertIsNone(self.e('WCCamera.currentSet()'))

    def test_a_move_the_reading_undoes_is_made_again_before_the_screen_fades_in(self):
        # The fault of screenshot 40: the catalogue scene holds the reader at the counter, and a
        # move made while it still does is undone, so he never reached the fitting room (the camera
        # in front of him then stood behind the tailor). Here the scene lets him go only LATE ms
        # after it is told to (later than the release wait), so the first move is undone as well:
        # he must still be on the stand, facing its heading, when the screen fades back in.
        self.run('''
            Scenes, SceneHold, Late = {}, nil, 250
            local nextScene = 700
            WCNative.scene.createAnimScene = function(dict, flags, playlist)
                nextScene = nextScene + 1
                Scenes[nextScene] = { playlist = playlist }
                return nextScene
            end
            WCNative.scene.setAnimSceneOrigin = function() return true end
            WCNative.scene.setAnimSceneEntity = function(s, name, e)
                -- the scene plays the reader where he stands, facing the book
                if e == MyPed and Scenes[s].playlist == 'PBL_ENTER' then
                    local c = Peds[MyPed].coords
                    SceneHold = { scene = s, x = c.x, y = c.y, z = c.z, h = 190.0, till = math.huge }
                end
                return true
            end
            local function letGo(s)
                if SceneHold and SceneHold.scene == s then SceneHold.till = math.min(SceneHold.till, Clock.now + Late) end
                return true
            end
            WCNative.scene.removeAnimSceneEntity = function(s) return letGo(s) end
            WCNative.scene.deleteAnimScene = function(s) Scenes[s].deleted = true return letGo(s) end
            WCNative.scene.loadAnimScene = function() return true end
            WCNative.scene.isAnimSceneLoaded = function() return true end
            WCNative.scene.startAnimScene = function() return true end
            WCNative.scene.isAnimSceneFinished = function() return false end
            -- the game: every frame the scene holds him, he is where it plays him
            CreateThread(function()
                while true do
                    if SceneHold then
                        if Clock.now <= SceneHold.till then
                            Peds[MyPed].coords = vector3(SceneHold.x, SceneHold.y, SceneHold.z)
                            Peds[MyPed].heading = SceneHold.h
                        else
                            SceneHold = nil
                        end
                    end
                    Wait(0)
                end
            end)
            FadeIns = {}
            local fadeIn = DoScreenFadeIn
            DoScreenFadeIn = function(...)
                local c = Peds[MyPed].coords
                FadeIns[#FadeIns + 1] = { x = c.x, y = c.y, z = c.z, h = Peds[MyPed].heading, at = Clock.now,
                                          cam = WCCamera.isOpen(), set = WCCamera.currentSet() }
                return fadeIn(...)
            end
            CallbackResults = { ["w_creators:store:open"] = storeData() }
            CreateThread(function() R = table.pack(WCStore.open("valentine_clothing")) end)
        ''')
        for _ in range(400):
            self.run('tick(16)')
            if self.e('R ~= nil'):
                break
        self.assertTrue(self.e('R[1]'))
        self.assertTrue(self.e('Scenes[701].deleted'))
        # the move was undone at least once, and made again under the fade
        self.assertGreaterEqual(self.e('#Moves'), 2)
        self.assertEqual(self.e('#FadeIns'), 1)
        seen = self.e('FadeIns[1]')
        self.assertEqual((seen.x, seen.y, seen.z), (10.0, 20.0, 30.0))
        self.assertAlmostEqual(seen.h, 90.0)
        # the screen comes back on the store's camera, never on the game's own camera behind him
        self.assertTrue(seen.cam)
        self.assertEqual(seen.set, 'shop')
        # the camera frames him on the stand, in front of him
        self.assertEqual(self.e('WCCamera.currentSet()'), 'shop')
        c = self.e('Peds[MyPed].coords')
        self.assertEqual((c.x, c.y, c.z), (10.0, 20.0, 30.0))
        self.run('clearLog(); WCCamera.focus("fullBody", true)')
        self.assertGreater(geometry(self.rt, 90.0)[0], 0.25)


STATES = r'''
StateLists = {}
WCNative.clothing.wearableStates = function(hash, wearer) return StateLists[WCUtil.u32(hash)] end
function stateHash(n) return WCUtil.u32(GetHashKey(n)) end
'''


class StateTests(unittest.TestCase):
    def setUp(self):
        self.rt = make_states_client()
        self.rt.run(STATES)
        self.e = self.rt.eval
        self.run = self.rt.run

    def controls(self, app='WCState.appearance'):
        out = []
        for g in lua_list(self.e('WCClothing.available(%s)' % app)):
            for item in lua_list(g['items']):
                out += [a.control for a in lua_list(item.actions)]
        return out

    def test_the_loadout_and_the_vest_tuck(self):
        self.run('''
            local a = WCState.appearance
            a.clothing.equipped.loadouts = 7777
            a.clothing.equipped.vests = 7778
            a.clothing.equipped.pants = PANTS
        ''')
        got = self.controls()
        self.assertIn('state.loadout.left', got)
        self.assertIn('state.vestTuck.under', got)
        self.assertEqual(self.e('Config.ClothingStates.groups[14].wearable.left'), 'base_right')
        # a woman's vest is a corset
        self.run('WCState.appearance.sex = "female"')
        labels = [a.label for g in lua_list(self.e('WCClothing.available()')) for i in lua_list(g['items'])
                  for a in lua_list(i.actions) if a.group == 'vestTuck']
        self.assertIn('إدخال المشدّ تحت البنطال', labels)

    def test_a_state_the_item_does_not_have_is_neither_offered_nor_performed(self):
        # the worn neckerchief (NECK) has no raised state in the game's list
        self.run('StateLists[NECK] = { stateHash("base") }')
        self.assertNotIn('state.bandana.up', self.controls())
        r = self.e('WCClothing.perform("bandana", "up", { notify = false })')
        self.assertEqual(r.code, 'STATE_NOT_APPLICABLE')
        self.assertEqual(self.e('#setStateCalls()'), 0)
        # one that has it (and one the game says nothing about) is offered
        self.run('NECK2 = 3334; StateLists[NECK2] = { stateHash("base"), stateHash("mask_up") };'
                 ' WCState.appearance.clothing.equipped.neckwear = NECK2')
        self.assertIn('state.bandana.up', self.controls())
        self.run('WCState.appearance.clothing.equipped.neckwear = 3335')
        self.assertIn('state.bandana.up', self.controls())

    def test_body_states_only_from_the_games_own_list(self):
        self.run('''
            BODY = WCState.appearance.body.upper
            StateLists[BODY] = { stateHash('base'), stateHash('base_tucked') }
        ''')
        got = self.controls()
        self.assertIn('state.bodyUpper.base_tucked', got)
        self.assertNotIn('state.bodyUpper.base', got)
        # the lower body: the game gave no list, so nothing is guessed
        self.assertFalse(any(c.startswith('state.bodyLower') for c in got))
        self.assertTrue(self.e('WCClothingStates.isValid("bodyUpper", "open_collar_rolled_sleeve")'))
        self.assertFalse(self.e('WCClothingStates.isValid("bodyUpper", "not_a_state")'))

    def test_the_toggle_commands(self):
        cmds = self.e('WCClothing.commands')
        self.assertEqual(cmds.hat, 'hat')
        self.assertEqual(cmds.tuck, 'vestTuck')
        self.assertEqual(cmds.glasses, 'eyewear')
        # a duplicate name, an unknown group and a taken name are skipped
        self.run('''
            Config.ClothingStates.commands = { hat = 'cap', mask = 'cap', nope = 'x' }
            GetRegisteredCommands = function() return { { name = 'cap2', resource = 'other' } } end
            Config.ClothingStates.commands.gloves = 'cap2'
            n = WCClothing.registerCommands()
        ''')
        self.assertEqual(self.e('n'), 1)
        self.assertEqual(self.e('WCClothing.commands.cap'), 'hat')      # the first in sorted order wins
        self.assertIsNone(self.e('WCClothing.commands.cap2'))


class WearableStatesNativeTests(unittest.TestCase):
    """The shop item wearable-state natives take the wearer's metaped type (an int read from the
    ped, as w_lib's component module passes it), never a male / female boolean."""

    def setUp(self):
        from test_natives import CLIENT_STUBS, FILES
        self.rt = Runtime().load_shared()
        self.rt.run(CLIENT_STUBS)
        self.rt.load(*FILES)
        self.e = self.rt.eval

    def test_the_metaped_type_of_the_wearer_is_passed(self):
        self.rt.run('nativeResult = 2; list = WCNative.clothing.wearableStates(0xFFFFFFF0, 77)')
        calls = list(self.e('invoked').values())
        hashes = [c.hash & 0xFFFFFFFFFFFFFFFF for c in calls]
        self.assertEqual(hashes[0], 0xEC9A1261BF0CE510)                  # _GET_META_PED_TYPE of ped 77
        self.assertEqual(list(calls[0].args.values())[0], 77)
        self.assertEqual(hashes[1], 0xFFCC2DB2D9953401)
        count_args = list(calls[1].args.values())
        self.assertEqual(count_args[0], 0xFFFFFFF0 - 0x100000000)       # the item as a signed int
        self.assertEqual(count_args[1], 2)                               # the metaped type, an int
        self.assertNotIsInstance(count_args[1], bool)
        self.assertEqual(hashes[2:], [0x6243635AF2F1B826] * 2)
        self.assertEqual(list(calls[2].args.values())[2], 2)
        self.assertEqual(self.e('#list'), 2)
        # a metaped type given as such is used as it is
        self.rt.run('invoked = {}; nativeResult = 0; WCNative.clothing.wearableStates(123, 1)')
        self.assertEqual(list(self.e('invoked[1].args').values())[1], 1)

    def test_no_wearer_no_call(self):
        self.rt.run('invoked = {}; r = WCNative.clothing.wearableStates(123, nil)')
        self.assertIsNone(self.e('r'))
        self.assertEqual(self.e('#invoked'), 0)



class DevStatesTests(unittest.TestCase):
    """wc_states: the wearable-state explorer (Config.Admin.devTools and the dev ACE)."""

    def setUp(self):
        from test_client_services_devtools import DEV_STUBS
        from test_client_services_support import make_services
        self.rt = make_services('Config.Admin.devTools = true')
        self.rt.run(DEV_STUBS)
        self.rt.run(r"""
            Lists = {}
            WCNative.clothing.wearableStates = function(hash) return Lists[WCUtil.u32(hash)] end
            SetStates = {}
            w.component.setWearableState = function(ped, category, hash, state)
                SetStates[#SetStates + 1] = { category = category, hash = hash, state = state } end
            BOOTS = WCState.appearance.clothing.equipped.boots
            Lists[BOOTS] = { WCUtil.u32(GetHashKey('base')), WCUtil.u32(GetHashKey('under_pants')), 0x1234 }
        """)
        self.e = self.rt.eval

    def test_it_is_registered_only_with_the_dev_tools_and_asks_the_server(self):
        self.assertIsNotNone(self.e('Events.commands.wc_states'))
        self.rt.run('allow(false); command("wc_states", "boots", "2")')
        self.assertEqual(self.e('#SetStates'), 0)
        self.assertIn('wc_states = true', read(RESOURCE / 'server' / 'dev' / 'tools.lua'))

    def test_it_lists_and_sets_the_games_own_states(self):
        self.rt.run('allow(true); items = WCDevClient.wearableStates(PlayerPedId())')
        boots = [i for i in lua_list(self.e('items')) if i.category == 'boots'][0]
        names = [s.name for s in lua_list(boots.states)]
        self.assertEqual(names[:2], ['base', 'under_pants'])
        self.assertIsNone(names[2])                                   # a state w_lib has no name for
        self.rt.run('command("wc_states", "boots", "2")')
        self.assertEqual(self.e('SetStates[1].state'), 'under_pants')
        self.assertEqual(self.e('SetStates[1].category'), 'boots')
        self.rt.run('command("wc_states", "boots", "9")')
        self.assertEqual(self.e('#SetStates'), 1)                    # no such state: nothing set



class ClientAccessTests(unittest.TestCase):
    def test_the_prompt_hides_where_the_server_refuses(self):
        rt = make_commerce()
        rt.run("""
            for _, l in ipairs(Config.Locations) do
                if l.id == 'valentine_clothing' then l.access = { jobs = { tailor = 0 } } end
            end
            WCLocations.reload()
            LOC, FREE = WCLocations.byId('valentine_clothing'), WCLocations.byId('saintdenis_clothing')
        """)
        # before the server answered: shown (the open is checked on the server anyway)
        self.assertTrue(rt.eval('WCServicePoints.accessible(LOC)'))
        rt.run('CallbackResults = { ["w_creators:locations:access"] = okResult({ valentine_clothing = false }) }')
        self.assertTrue(rt.eval('WCServicePoints.refreshAccess()'))
        self.assertFalse(rt.eval('WCServicePoints.accessible(LOC)'))
        self.assertFalse(rt.eval('WCServicePoints.canInteract(LOC)'))
        self.assertTrue(rt.eval('WCServicePoints.accessible(FREE)'))
        rt.run('CallbackResults = { ["w_creators:locations:access"] = okResult({ valentine_clothing = true }) }')
        rt.run('WCServicePoints.refreshAccess()')
        self.assertTrue(rt.eval('WCServicePoints.accessible(LOC)'))


class ValidatorTests(unittest.TestCase):
    """wc_validate knows the new price shapes: {cash, gold}, model prices and tint limits."""

    def setUp(self):
        self.rt = Runtime().load_server_core()
        self.rt.load('server/dev/tools.lua')

    def errors(self, setup):
        self.rt.run(setup + '\nREPORT = WCDevTools.validate()')
        return list(self.rt.eval('REPORT.errors').values())

    def test_the_default_config_is_clean_and_gold_prices_are_accepted(self):
        self.assertEqual(self.errors(''), [])
        self.assertEqual(self.errors("""
            Config.Clothing.prices.hats = { cash = 3.5, gold = 0.2 }
            Config.Clothing.tints.price = { gold = 0.1 }
            Config.Clothing.modelPrices.male.hats = { [2] = -1, [3] = { multiplier = 2 }, [4] = { gold = 1 } }
        """), [])

    def test_bad_shapes_are_reported(self):
        errs = self.errors("""
            Config.Clothing.prices.hats = { silver = 3 }
            Config.Clothing.tints.price = { cash = -1 }
            Config.Clothing.modelPrices.female.hats = { [2] = 'free' }
        """)
        self.assertTrue(any('prices: hats' in e for e in errs), errs)
        self.assertTrue(any('tints: invalid price' in e for e in errs), errs)
        self.assertTrue(any('model prices (female): hats' in e for e in errs), errs)


if __name__ == '__main__':
    unittest.main()
