"""Server services: cosmetic surgery (server/surgery/surgery.lua)."""
import unittest

from test_server_services_barber import services_server

CLINIC = 'Players[1].coords = vector3(-284.49, 807.49, 119.38)'  # valentine_surgery


class SurgeryTests(unittest.TestCase):
    def setUp(self):
        self.rt = services_server()
        self.e = self.rt.eval
        self.rt.run(CLINIC + '; FakeUsers[1].money = 1000')

    def open(self, clinic='valentine_surgery'):
        self.rt.run('Clock.now = Clock.now + 11000; WCSurgeryService.grant(1, "%s"); o = WCSurgeryService.open(1, "%s");'
                    ' token = o.ok and o.data.token' % (clinic, clinic))
        return self.e('o')

    def commit(self, edit, op='op'):
        self.rt.run('app = WCUtil.copy(o.data.appearance); %s; c = WCSurgeryService.commit(1, token, "%s", app)' % (edit, op))
        return self.e('c')

    def set_location(self, field, value):
        self.rt.run('''
            for _, loc in ipairs(Config.Locations) do if loc.id == 'valentine_surgery' then loc.%s = %s end end
            WCLocations.reload()
        ''' % (field, value))

    def test_open_payload(self):
        o = self.open()
        self.assertTrue(o.ok, o.code)
        self.assertEqual(o.data.price, 500)
        self.assertEqual(o.data.clinic, 'valentine_surgery')
        self.assertEqual(self.rt.py(self.e('o.data.sections')), {'face': True, 'body': True, 'eyes': True, 'skin': True})
        allow = self.rt.py(self.e('o.data.allow'))
        self.assertEqual(allow, {'face': True, 'body': True, 'eyes': True, 'skin': True, 'hair': False,
                                 'facialHair': False, 'clothing': False})
        self.assertEqual(self.e('o.data.expiresIn'), 20 * 60)

    def test_disabled_globally(self):
        self.rt.run('Config.CosmeticSurgery.enabled = false')
        self.assertEqual(self.open().code, 'SURGERY_DISABLED')
        self.rt.run('Config.CosmeticSurgery.enabled = true; Config.Services.surgery = false')
        self.assertEqual(self.open().code, 'SURGERY_DISABLED')
        self.rt.run('Config.Services.surgery = true; Config.CosmeticSurgery.allow = {}')
        self.assertEqual(self.open().code, 'SURGERY_DISABLED')
        self.assertIsNone(self.e('WCSessions.current(1)'))

    def test_clinic_disabled_or_unknown(self):
        self.set_location('enabled', 'false')
        self.assertEqual(self.open().code, 'LOCATION_DISABLED')
        self.assertEqual(self.open('nowhere').code, 'LOCATION_NOT_FOUND')
        self.assertEqual(self.open('valentine_barber').code, 'LOCATION_NOT_FOUND')
        self.set_location('enabled', 'true')
        self.rt.run('Players[1].coords = vector3(0, 0, 0)')
        self.assertEqual(self.open().code, 'TOO_FAR')
        self.assertEqual(self.e('WCSurgeryService.open(1, {}).code'), 'INVALID_PAYLOAD')

    def test_success_changes_only_allowed_sections(self):
        self.open()
        c = self.commit('''
            app.morph.jawWidth = 0.5
            app.hair.style = h("male", "hair", 3)
            app.clothing.equipped.hats = h("male", "hats", 1)
        ''')
        self.assertTrue(c.ok, c.code)
        self.assertEqual(c.data.charged, 500)
        self.assertEqual(list(self.rt.py(c.data.sections).values()), ['face'])
        self.rt.run('saved = lastSaved()')
        self.assertEqual(self.e('saved.morph.jawWidth'), 0.5)
        self.assertEqual(self.e('saved.hair.style'), self.e('savedApp.hair.style'))
        self.assertIsNone(self.e('saved.clothing.equipped.hats'))
        self.assertEqual(self.e('FakeUsers[1].money'), 500)
        log = self.e('logsOf("surgery_completed")[1]')
        self.assertEqual((log.charid, log.price, log.clinic), ('vorp:1', 500, 'valentine_surgery'))
        self.assertEqual(list(self.rt.py(log.sections).values()), ['face'])
        self.assertEqual(self.e('serverEvents[1].kind'), 'surgery')
        self.assertEqual(len(self.rt.client_events('w_creators:client:applyRemoteAppearance')), 1)
        self.assertIsNone(self.e('WCSessions.current(1)'))

    def test_skin_tone_and_body(self):
        self.open()
        c = self.commit('S.setSkinTone(app, 3); app.body.height = 1.05')
        self.assertTrue(c.ok, c.code)
        self.assertEqual(self.e('S.skinTone(lastSaved())'), 3)
        self.assertAlmostEqual(self.e('lastSaved().body.height'), 1.05)

    def test_insufficient_funds(self):
        self.rt.run('FakeUsers[1].money = 100')
        self.open()
        c = self.commit('app.morph.jawWidth = 0.5')
        self.assertEqual(c.code, 'INSUFFICIENT_FUNDS')
        self.assertEqual(len(self.e('FakeDB.transactions')), 0)
        self.assertEqual(self.e('FakeUsers[1].money'), 100)
        self.assertIsNotNone(self.e('WCSessions.current(1)'))

    def test_disallowed_only_changes(self):
        self.open()
        c = self.commit('app.hair.style = h("male", "hair", 3); app.clothing.equipped.hats = h("male", "hats", 1)')
        self.assertEqual(c.code, 'SURGERY_NOT_ALLOWED')
        self.assertEqual(self.e('#MoneyCalls'), 0)
        self.assertEqual(len(self.e('FakeDB.transactions')), 0)

    def test_no_changes(self):
        self.open()
        c = self.commit('')
        self.assertEqual(c.code, 'NO_CHANGES')
        self.assertEqual(self.e('#MoneyCalls'), 0)
        # runtime clothing states are not a procedure either
        c = self.commit('app.clothing.states = { hat = "off" }', 'states')
        self.assertEqual(c.code, 'NO_CHANGES')

    def test_database_failure_refunds(self):
        self.rt.run('FakeDB.transactionOk = false')
        self.open()
        c = self.commit('app.morph.noseWidth = -0.4')
        self.assertEqual(c.code, 'DATABASE_ERROR')
        self.assertTrue(c.data.refunded)
        self.assertEqual(self.e('FakeUsers[1].money'), 1000)
        self.assertEqual(len(self.rt.client_events('w_creators:client:applyRemoteAppearance')), 0)
        self.assertEqual(self.e('#logsOf("surgery_completed")'), 0)

    def test_price_ignores_payload_and_uses_the_clinic(self):
        self.open()
        c = self.commit('app.morph.jawWidth = 0.5; app.price = 1; app.charged = 0')
        self.assertEqual(c.data.charged, 500)
        self.set_location('price', '250')
        self.rt.run('Config.Clothing.pricingProfiles.clinic = { multiplier = 1.2 }')
        self.set_location('pricingProfile', '"clinic"')
        o = self.open()
        self.assertEqual(o.data.price, 300)
        c = self.commit('app.morph.jawWidth = -0.5', 'second')
        self.assertEqual(c.data.charged, 300)
        self.assertEqual(self.e('FakeUsers[1].money'), 1000 - 500 - 300)

    def test_facial_hair_allowed_for_males_only(self):
        self.rt.run('Config.CosmeticSurgery.allow.facialHair = true')
        o = self.open()
        self.assertTrue(self.e('o.data.sections.facialHair'))
        self.rt.run('WCSessions.clear(1); savedApp = S.default("female"); setSaved(savedApp)')
        o = self.open()
        self.assertIsNone(self.e('o.data.sections.facialHair'))
        self.assertFalse(o.data.allow.facialHair)

    def test_hair_allowed_restarts_growth(self):
        self.rt.run('''
            Config.CosmeticSurgery.allow.hair = true
            local app = WCUtil.copy(savedApp); app.grooming = { hair = { stage = 1, seconds = 2000 } }
            savedApp = app; setSaved(app)
        ''')
        self.open()
        c = self.commit('app.hair.style = h("male", "hair", 3)')
        self.assertTrue(c.ok, c.code)
        self.assertEqual(self.e('lastSaved().grooming.hair.seconds'), 0)

    def own(self):
        """Clothing allowed; the ownership module over a fake w_creators_clothes table."""
        self.rt.load('server/clothing/ownership.lua')
        self.rt.run('''
            Config.CosmeticSurgery.allow.clothing = true
            ownedRows = {}
            FakeDB.on('FROM w_creators_clothes WHERE charid', function() return ownedRows end)
            function own(category, hash, tint)
                local row = { hash = hash, category = category }
                if tint then row.palette, row.tint0, row.tint1, row.tint2 = tint.palette, tint.tint0, tint.tint1, tint.tint2 end
                ownedRows[#ownedRows + 1] = row
            end
        ''')

    def test_clothing_needs_ownership(self):
        self.own()
        self.open()
        c = self.commit('app.clothing.equipped.hats = h("male", "hats", 1)')
        self.assertEqual(c.code, 'ITEM_NOT_OWNED')
        self.assertEqual(c.data.category, 'hats')
        self.assertEqual(self.e('#MoneyCalls'), 0)
        self.assertEqual(len(self.e('FakeDB.transactions')), 0)
        # owned: allowed, with the owned tint whatever the payload says
        self.rt.run('own("hats", h("male", "hats", 1), { palette = "metaped_tint_generic_clean", tint0 = 4, tint1 = 5, tint2 = 6 })')
        c = self.commit('''
            app.clothing.equipped.hats = h("male", "hats", 1)
            app.clothing.tints.hats = { palette = "metaped_tint_generic_clean", tint0 = 1, tint1 = 1, tint2 = 1 }
            app.clothing.outfit = 7
        ''', 'owned')
        self.assertTrue(c.ok, c.code)
        self.assertEqual(self.e('lastSaved().clothing.equipped.hats'), self.e('h("male", "hats", 1)'))
        self.assertEqual(self.e('lastSaved().clothing.tints.hats.tint0'), 4)
        self.assertIsNone(self.e('lastSaved().clothing.outfit'))

    def test_clothing_tint_of_a_worn_item_cannot_be_changed(self):
        self.own()
        self.open()
        c = self.commit('app.clothing.tints.shirts_full = { palette = "metaped_tint_generic_clean", tint0 = 9, tint1 = 9, tint2 = 9 }')
        self.assertEqual(c.code, 'SURGERY_NOT_ALLOWED')  # recolouring is the store's service
        self.assertEqual(self.e('#MoneyCalls'), 0)

    def test_clothing_ownership_database_failure(self):
        self.own()
        self.rt.run("FakeDB.fail = 'FROM w_creators_clothes'")
        self.open()
        c = self.commit('app.morph.jawWidth = 0.5')
        self.assertEqual(c.code, 'DATABASE_ERROR')
        self.assertEqual(self.e('#MoneyCalls'), 0)

    def test_direct_open_without_the_export_grant_is_refused(self):
        self.rt.run('Clock.now = Clock.now + 11000; o = WCSurgeryService.open(1, "valentine_surgery")')
        self.assertEqual(self.e('o.code'), 'SURGERY_NOT_ALLOWED')
        self.assertIsNone(self.e('WCSessions.current(1)'))
        self.assertEqual(self.e('Callbacks["w_creators:surgery:open"](1, "valentine_surgery").code'), 'SURGERY_NOT_ALLOWED')

    def test_disconnect_or_stop_before_commit_writes_nothing(self):
        self.open()
        self.rt.run('fireEvent("playerDropped", 1)')
        c = self.commit('app.morph.jawWidth = 0.5')
        self.assertEqual(c.code, 'SESSION_NOT_FOUND')
        self.open()
        self.rt.run('fireEvent("onResourceStop", nil, "w_creators")')
        c = self.commit('app.morph.jawWidth = 0.5', 'after-stop')
        self.assertEqual(c.code, 'SESSION_NOT_FOUND')
        self.assertEqual(len(self.e('FakeDB.transactions')), 0)
        self.assertEqual(self.e('#MoneyCalls'), 0)

    def test_replayed_op_is_not_charged_twice(self):
        self.open()
        c1 = self.commit('app.morph.jawWidth = 0.5', 'same')
        self.assertTrue(c1.ok)
        self.rt.run('c1 = c; c2 = WCSurgeryService.commit(1, token, "same", app)')
        self.assertTrue(self.e('c1 == c2'))
        self.assertEqual(self.e('FakeUsers[1].money'), 500)
        self.assertEqual(len(self.e('FakeDB.transactions')), 1)


if __name__ == '__main__':
    unittest.main()
