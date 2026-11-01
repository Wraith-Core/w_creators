"""Server services: the barber (server/barber/barber.lua)."""
import unittest

from harness import Runtime

SETUP = r'''
FakeDB.fireReady()                                              -- the migrations have run
S = AppearanceSchema
h = function(sex, c, m, v) return WCCatalog.forSex(sex)[c].models[m][v or 1].hash end
charids = { [1] = 'vorp:1' }
Bridge.GetCharId = function(src) return charids[src] end
Players[1].coords = vector3(-307.51, 813.96, 118.99)            -- valentine_barber
Players[2] = { name = 'player two', coords = vector3(0, 0, 0), bucket = 0 }
FakeUsers[1] = { money = 100 }
savedApp = S.default('male')
rows = { ['vorp:1'] = { id = 11, charid = 'vorp:1', appearance = json.encode(savedApp), appearance_version = 3 } }
FakeDB.on('SELECT %* FROM characters_appearence', function(sql, params) return rows[params[1]] end)
FakeDB.on('SELECT id FROM characters_appearence WHERE charid', function(sql, params)
    return rows[params[1]] and rows[params[1]].id end)
serverEvents = {}
AddEventHandler('w_creators:server:appearanceChanged', function(src, charid, kind)
    serverEvents[#serverEvents + 1] = { src = src, charid = charid, kind = kind }
end)
function setSaved(app)
    rows['vorp:1'].appearance = json.encode(app)
    WCAppearanceRepo.invalidate('vorp:1')
end
function lastSaved()
    local entry = WCAppearanceRepo.cache['vorp:1']
    return entry and entry.app
end
function logsOf(event)
    local out = {}
    for _, e in ipairs(LogEmits) do if e.event == event then out[#out + 1] = e.payload end end
    return out
end
'''

FILES = ('server/clothing/ownership.lua', 'server/barber/barber.lua', 'server/barber/grooming.lua',
         'server/surgery/surgery.lua', 'server/api.lua')


def services_server():
    """Server core + the services of this module, a male character 'vorp:1' on player 1."""
    rt = Runtime().load_server_core()
    rt.load(*FILES)
    rt.run(SETUP)
    return rt


class BarberTests(unittest.TestCase):
    def setUp(self):
        self.rt = services_server()
        self.e = self.rt.eval

    def open(self, loc='valentine_barber'):
        self.rt.run('Clock.now = Clock.now + 11000; o = WCBarberService.open(1, "%s"); token = o.ok and o.data.token' % loc)
        return self.e('o')

    def commit(self, edit, op='op'):
        self.rt.run('app = WCUtil.copy(o.data.appearance); %s; c = WCBarberService.commit(1, token, "%s", app)' % (edit, op))
        return self.e('c')

    def test_open_payload(self):
        self.rt.run('Config.Grooming.enabled = true')  # growth ships off; the plate is checked with it on
        o = self.open()
        self.assertTrue(o.ok, o.code)
        self.assertTrue(self.e('S.equal(o.data.appearance, savedApp)'))
        self.assertEqual(self.rt.py(self.e('o.data.sections')), {'hair': True, 'facialHair': True, 'eyebrows': True})
        services = self.rt.py(self.e('o.data.services'))
        self.assertEqual(services['hair'], {'enabled': True, 'price': 10})
        self.assertEqual(services['facialHair'], {'enabled': True, 'price': 10})
        self.assertEqual(services['details'], {'enabled': True, 'price': 5, 'eyebrows': True, 'makeup': False})
        self.assertIn('hair', self.rt.py(self.e('o.data.growth')))
        self.assertEqual(o.data.location, 'valentine_barber')

    def test_price_by_changed_services(self):
        self.rt.run('Config.Barber.prices.visitCap = nil')
        self.open()
        c = self.commit('app.hair.style = h("male", "hair", 3)', 'hair')
        self.assertTrue(c.ok, c.code)
        self.assertEqual(c.data.charged, 10)
        self.assertEqual(list(self.rt.py(c.data.sections).values()), ['hair'])
        self.assertEqual(self.e('FakeUsers[1].money'), 90)

        self.open()
        c = self.commit('app.hair.style = h("male", "hair", 4); app.hair.facial = h("male", "mustache", 2)', 'both')
        self.assertEqual(c.data.charged, 20)
        self.open()
        c = self.commit('app.overlays.eyebrows.style = 5', 'brows')
        self.assertEqual(c.data.charged, 5)
        self.open()
        c = self.commit('app.overlays.eyebrows.color = 9; app.hair.facial = h("male", "mustache", 3)', 'brows+beard')
        self.assertEqual(c.data.charged, 15)
        self.assertEqual(self.e('FakeUsers[1].money'), 100 - 10 - 20 - 5 - 15)

    def test_visit_cap_and_pricing_profile(self):
        self.open()
        c = self.commit('app.hair.style = h("male", "hair", 3); app.hair.facial = h("male", "mustache", 2)')
        self.assertEqual(c.data.charged, 10)  # capped at visitCap (the pre-v3 flat price)
        self.rt.run('''
            Config.Clothing.pricingProfiles.premium = { multiplier = 1.5 }
            for _, loc in ipairs(Config.Locations) do if loc.id == 'valentine_barber' then loc.pricingProfile = 'premium' end end
            WCLocations.reload()
        ''')
        o = self.open()
        self.assertEqual(o.data.services.hair.price, 15)
        c = self.commit('app.hair.style = h("male", "hair", 4)', 'premium')
        self.assertEqual(c.data.charged, 15)

    def client_total(self, sections):
        """The editor's preview (client/editor/tree.lua): the open() prices of the changed services,
        their sum capped at the open() visitCap."""
        services = self.rt.py(self.e('o.data.services'))
        total = sum(services[k]['price'] for k in sections)
        cap = self.e('o.data.visitCap')
        return min(total, cap) if cap is not None else total

    def test_open_payload_carries_the_multiplied_cap(self):
        o = self.open()
        self.assertEqual((o.data.multiplier, o.data.visitCap), (1, 10))
        self.assertEqual(self.client_total(['hair', 'facialHair']), 10)
        self.rt.run('WCSessions.clear(1)')
        self.rt.run('''
            Config.Clothing.pricingProfiles.premium = { multiplier = 1.5 }
            for _, loc in ipairs(Config.Locations) do if loc.id == 'valentine_barber' then loc.pricingProfile = 'premium' end end
            WCLocations.reload()
        ''')
        o = self.open()
        self.assertEqual((o.data.multiplier, o.data.visitCap), (1.5, 15))
        preview = self.client_total(['hair', 'facialHair'])
        c = self.commit('app.hair.style = h("male", "hair", 3); app.hair.facial = h("male", "mustache", 2)')
        self.assertTrue(c.ok, c.code)
        self.assertEqual(c.data.charged, preview)
        self.assertEqual(c.data.charged, 15)
        # no cap configured -> none sent
        self.rt.run('Config.Barber.prices.visitCap = nil')
        self.assertIsNone(self.open().data.visitCap)

    def test_missing_or_invalid_service_price_is_refused_not_free(self):
        self.rt.run('loc = WCLocations.byId("valentine_barber")')
        for price in ('"abc"', 'nil', '-1', '0/0'):
            self.rt.run('Config.Barber.services.hair.price = %s' % price)
            self.assertEqual(self.e('select(2, WCBarberService.price(loc, { hair = true }))'), 'INVALID_PRICE', price)
            self.assertEqual(self.open().code, 'INVALID_PRICE', price)
            self.assertIsNone(self.e('WCSessions.current(1)'))
        self.rt.run('Config.Barber.services.hair.price = 0')  # an explicit 0 is a free service
        self.assertEqual(self.e('(WCBarberService.price(loc, { hair = true }))'), 0)
        # a disabled service's price is never needed
        self.rt.run('Config.Barber.services.hair = { enabled = false }')
        self.assertTrue(self.open().ok)

    def test_price_ignores_the_payload(self):
        self.open()
        c = self.commit('app.hair.style = h("male", "hair", 3); app.price = 0; app.charged = 0; app.total = -5')
        self.assertTrue(c.ok)
        self.assertEqual(c.data.charged, 10)

    def test_face_body_and_skin_are_never_changed(self):
        self.open()
        c = self.commit('''
            app.hair.style = h("male", "hair", 3)
            app.morph.jawWidth = 0.8; app.morph.chest = -0.5
            app.head.head = h("male", "heads", 2); app.head.eyes = h("male", "eyes", 1, 3)
            app.body.height = 1.1
            app.overlays.freckles = { style = 2, color = 1, opacity = 1 }
            app.clothing.equipped.hats = h("male", "hats", 1)
        ''')
        self.assertTrue(c.ok, c.code)
        self.rt.run('saved = lastSaved()')
        self.assertEqual(self.e('saved.hair.style'), self.e('h("male", "hair", 3)'))
        self.assertIsNone(self.e('next(saved.morph)'))
        self.assertEqual(self.e('saved.head.head'), self.e('savedApp.head.head'))
        self.assertEqual(self.e('saved.head.eyes'), self.e('savedApp.head.eyes'))
        self.assertEqual(self.e('saved.body.height'), 1.0)
        self.assertIsNone(self.e('saved.overlays.freckles'))
        self.assertIsNone(self.e('saved.clothing.equipped.hats'))

    def test_no_changes_is_free(self):
        self.open()
        c = self.commit('')
        self.assertEqual(c.code, 'NO_CHANGES')
        self.assertEqual(self.e('#MoneyCalls'), 0)
        self.assertEqual(len(self.e('FakeDB.transactions')), 0)
        self.assertIsNotNone(self.e('WCSessions.current(1)'))

    def test_female_facial_hair_is_ignored(self):
        self.rt.run('savedApp = S.default("female"); setSaved(savedApp)')
        o = self.open()
        self.assertTrue(o.ok, o.code)
        self.assertFalse(o.data.services.facialHair.enabled)
        self.assertIsNone(self.e('o.data.sections.facialHair'))
        c = self.commit('app.hair.facial = h("male", "mustache", 2); app.overlays.beardstabble = { style = 1, color = 3, opacity = 1 }')
        self.assertEqual(c.code, 'NO_CHANGES')
        self.assertEqual(self.e('#MoneyCalls'), 0)
        c = self.commit('app.hair.style = h("female", "hair", 2); app.hair.facial = h("male", "mustache", 2)', 'hair')
        self.assertTrue(c.ok, c.code)
        self.assertEqual(c.data.charged, 10)
        self.assertEqual(self.e('lastSaved().hair.facial'), 0)

    def test_location_allowed_services(self):
        self.rt.run('''
            for _, loc in ipairs(Config.Locations) do if loc.id == 'valentine_barber' then loc.allowedServices = { hair = true } end end
            WCLocations.reload()
        ''')
        o = self.open()
        self.assertEqual(self.rt.py(self.e('o.data.sections')), {'hair': True})
        c = self.commit('app.hair.facial = h("male", "mustache", 2); app.overlays.eyebrows.style = 7')
        self.assertEqual(c.code, 'NO_CHANGES')

    def test_details_off_ignores_eyebrows(self):
        self.rt.run('Config.Barber.services.details.enabled = false')
        o = self.open()
        self.assertIsNone(self.e('o.data.sections.eyebrows'))
        self.assertFalse(o.data.services.details.enabled)
        c = self.commit('app.overlays.eyebrows.style = 7')
        self.assertEqual(c.code, 'NO_CHANGES')
        c = self.commit('app.overlays.eyebrows.style = 7; app.hair.style = h("male", "hair", 3)', 'hair')
        self.assertTrue(c.ok, c.code)
        self.assertEqual(c.data.charged, 10)
        self.assertEqual(self.e('lastSaved().overlays.eyebrows.style'), 1)

    def test_makeup_only_when_flagged(self):
        o = self.open()
        self.assertIsNone(self.e('o.data.sections.makeup'))
        c = self.commit('app.overlays.blush = { style = 2, color = 4, opacity = 0.5 }')
        self.assertEqual(c.code, 'NO_CHANGES')
        self.rt.run('Config.Barber.services.details.makeup = true')
        self.rt.run('WCSessions.clear(1)')
        o = self.open()
        self.assertTrue(self.e('o.data.sections.makeup'))
        c = self.commit('app.overlays.blush = { style = 2, color = 4, opacity = 0.5 }', 'makeup')
        self.assertTrue(c.ok, c.code)
        self.assertEqual(c.data.charged, 5)

    def test_disabled_service_and_location(self):
        self.rt.run('Config.Services.barbers = false')
        self.assertEqual(self.open().code, 'BARBER_DISABLED')
        self.rt.run('Config.Services.barbers = true')
        self.rt.run('''
            for _, loc in ipairs(Config.Locations) do if loc.id == 'valentine_barber' then loc.enabled = false end end
            WCLocations.reload()
        ''')
        self.assertEqual(self.open().code, 'LOCATION_DISABLED')
        self.assertEqual(self.open('nowhere').code, 'LOCATION_NOT_FOUND')
        self.assertEqual(self.open('valentine_surgery').code, 'LOCATION_NOT_FOUND')
        self.rt.run('''
            for _, loc in ipairs(Config.Locations) do if loc.id == 'valentine_barber' then loc.enabled = true end end
            WCLocations.reload()
            Config.Barber.services.hair.enabled = false
            Config.Barber.services.facialHair.enabled = false
            Config.Barber.services.details.enabled = false
        ''')
        self.assertEqual(self.open().code, 'BARBER_DISABLED')
        self.assertIsNone(self.e('WCSessions.current(1)'))
        self.assertEqual(self.e('WCBarberService.open(1, 42).code'), 'INVALID_PAYLOAD')

    def test_service_disabled_while_the_session_is_open(self):
        self.open()
        self.rt.run('Config.Services.barbers = false')
        c = self.commit('app.hair.style = h("male", "hair", 3)')
        self.assertEqual(c.code, 'BARBER_DISABLED')
        self.assertEqual(self.e('#MoneyCalls'), 0)

    def test_insufficient_funds_writes_nothing(self):
        self.rt.run('FakeUsers[1].money = 5')
        self.open()
        c = self.commit('app.hair.style = h("male", "hair", 3)')
        self.assertEqual(c.code, 'INSUFFICIENT_FUNDS')
        self.assertEqual(len(self.e('FakeDB.transactions')), 0)
        self.assertEqual(self.e('FakeUsers[1].money'), 5)

    def test_database_failure_refunds(self):
        self.rt.run('FakeDB.transactionOk = false')
        self.open()
        c = self.commit('app.hair.style = h("male", "hair", 3)')
        self.assertEqual(c.code, 'DATABASE_ERROR')
        self.assertTrue(c.data.refunded)
        self.assertEqual(self.e('FakeUsers[1].money'), 100)

    def test_success_broadcasts_logs_and_restarts_growth(self):
        self.rt.run('''
            local app = WCUtil.copy(savedApp)
            app.grooming = { hair = { stage = 1, seconds = 3000 } }
            savedApp = app
            setSaved(app)
        ''')
        self.open()
        c = self.commit('app.hair.style = h("male", "hair", 3); app.grooming = { hair = { stage = 3, seconds = 1 } }')
        self.assertTrue(c.ok, c.code)
        self.assertEqual(self.e('lastSaved().grooming.hair.seconds'), 0)
        remote = self.rt.client_events('w_creators:client:applyRemoteAppearance')
        self.assertEqual(len(remote), 1)
        self.assertEqual(remote[0].args[1], 1)
        haircut = self.e('logsOf("haircut")[1]')
        self.assertEqual((haircut.charid, haircut.price, haircut.barber), ('vorp:1', 10, 'valentine_barber'))
        self.assertEqual(self.e('serverEvents[1].kind'), 'barber')
        self.assertIsNone(self.e('WCSessions.current(1)'))
        self.assertIsNone(self.e('CreatorAppearanceLocks["vorp:1"]'))

    def test_session_and_payload_checks(self):
        self.open()
        self.assertEqual(self.e('WCBarberService.commit(1, "forged", "x", {}).code'), 'SESSION_NOT_FOUND')
        self.assertEqual(self.e('WCBarberService.commit(1, token, "x", "app").code'), 'INVALID_PAYLOAD')
        self.rt.run('Players[1].coords = vector3(0, 0, 0)')
        c = self.commit('app.hair.style = h("male", "hair", 3)')
        self.assertEqual(c.code, 'TOO_FAR')

    def test_unknown_style_is_refused_not_shaved(self):
        self.open()
        c = self.commit('app.hair.style = 12345')
        self.assertEqual(c.code, 'INVALID_COMPONENT')
        c = self.commit('app.hair.facial = h("female", "hair", 1)', 'beard')
        self.assertEqual(c.code, 'INVALID_COMPONENT')
        c = self.commit('app.hair = "long"', 'shape')
        self.assertEqual(c.code, 'INVALID_PAYLOAD')
        self.assertEqual(self.e('#MoneyCalls'), 0)
        c = self.commit('app.hair.style = 0', 'bald')  # 0 = bald is a valid choice
        self.assertTrue(c.ok, c.code)
        self.assertEqual(self.e('lastSaved().hair.style'), 0)

    def test_callbacks_are_registered(self):
        self.assertIsNotNone(self.e('Callbacks["w_creators:barber:open"]'))
        self.assertIsNotNone(self.e('Callbacks["w_creators:barber:commit"]'))


if __name__ == '__main__':
    unittest.main()
