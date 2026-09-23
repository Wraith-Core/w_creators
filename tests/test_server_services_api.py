"""Server services: the public server API (server/api.lua)."""
import unittest

from test_server_services_barber import services_server


class ApiReadTests(unittest.TestCase):
    def setUp(self):
        self.rt = services_server()
        self.e = self.rt.eval

    def test_get_appearance_shape_for_the_w_core_bridge(self):
        self.rt.run('''
            local app = WCUtil.copy(savedApp)
            app.morph.jawWidth = 0.25
            app.hair.facial = h("male", "mustache", 2)
            app.overlays.blush = { style = 2, color = 5, opacity = 0.5 }
            app.clothing.tints.shirts_full = { palette = "metaped_tint_generic_clean", tint0 = 1, tint1 = 2, tint2 = 3 }
            savedApp = app; setSaved(app)
            data = WCApi.GetAppearance(1)
        ''')
        self.assertIsNotNone(self.e('data'))
        self.assertEqual(self.e('data.appearance.version'), 3)
        skin = self.e('data.skin')
        self.assertEqual(skin.model, 'mp_male')
        self.assertEqual(skin.sex, 1)
        for key, path in (('headHash', 'head.head'), ('eyesHash', 'head.eyes'), ('teethHash', 'head.teeth'),
                          ('bodyUpperHash', 'body.upper'), ('bodyLowerHash', 'body.lower')):
            self.assertEqual(skin[key], self.e('savedApp.' + path), key)
        self.assertEqual(skin.bodyScale, 1.0)
        # the waist outfit hash w.component.applySkin equips (WAIST_TYPES[11]); no bodyType index
        self.assertEqual(skin.bodyWeight, 1745919061)
        self.assertIsNone(skin.bodyType)
        self.assertEqual(skin.hair.hash, self.e('savedApp.hair.style'))
        self.assertEqual(skin.beards_complete.hash, self.e('h("male", "mustache", 2)'))
        # standardizeSkin iterates expressions and overlays: both are always tables
        self.assertEqual(self.rt.py(skin.expressions), {'jawWidth': 0.25})
        overlays = self.rt.py(skin.overlays)
        self.assertEqual(overlays['eyebrow'], {'id': 12, 'opacity': 0.85, 'palette': 'metaped_tint_hair', 'tint0': 0})
        self.assertEqual(overlays['blush'], {'id': 1, 'opacity': 0.5, 'palette': 'metaped_tint_makeup', 'tint0': 4})
        clothes = self.rt.py(self.e('data.clothes'))
        self.assertEqual(set(clothes), set(self.rt.py(self.e('savedApp.clothing.equipped'))))
        self.assertEqual(clothes['shirts_full']['palette'], 'metaped_tint_generic_clean')
        self.assertEqual(clothes['pants'], {'hash': self.e('savedApp.clothing.equipped.pants')})
        for entry in clothes.values():
            self.assertIsInstance(entry['hash'], int)

    def test_no_character(self):
        self.assertIsNone(self.e('WCApi.GetAppearance(2)'))
        self.assertIsNone(self.e('WCApi.GetAppearance(99)'))
        self.assertIsNone(self.e('WCApi.GetCharacterAppearance(2)'))
        self.assertIsNone(self.e('WCApi.GetActiveCharacter(2)'))

    def test_active_character_and_appearance(self):
        active = self.e('WCApi.GetActiveCharacter(1)')
        self.assertEqual((active.charid, active.sex), ('vorp:1', 'male'))
        self.assertTrue(self.e('S.equal(WCApi.GetCharacterAppearance(1), savedApp)'))
        # a copy: changing it never touches the cache
        self.rt.run('local a = WCApi.GetCharacterAppearance(1); a.hair.style = 0')
        self.assertNotEqual(self.e('WCApi.GetCharacterAppearance(1).hair.style'), 0)

    def test_apply_character_appearance(self):
        r = self.e('WCApi.ApplyCharacterAppearance(1)')
        self.assertTrue(r.ok)
        own = self.rt.client_events('w_creators:client:applyAppearance')
        self.assertEqual(len(own), 1)
        self.assertEqual(own[0].player, 1)
        self.assertEqual(len(self.rt.client_events('w_creators:client:applyRemoteAppearance')), 1)
        self.assertEqual(self.e('WCApi.ApplyCharacterAppearance(2).code'), 'NO_CHARACTER')


class ApiWriteTests(unittest.TestCase):
    def setUp(self):
        self.rt = services_server()
        self.e = self.rt.eval

    def test_set_clothes_rejects_unknown_hashes(self):
        for clothes in ('{ hats = 12345 }', '{ hats = h("male", "boots", 1) }', '{ skirts = h("female", "skirts", 1) }',
                        '{ unknown_category = h("male", "hats", 1) }', '{ heads = h("male", "heads", 2) }',
                        '{ hats = { hash = 777 } }'):
            r = self.e('WCApi.SetClothes(1, %s, false)' % clothes)
            self.assertEqual(r.code, 'INVALID_COMPONENT', clothes)
        self.assertEqual(len(self.e('FakeDB.transactions')), 0)
        self.assertEqual(self.e('WCApi.SetClothes(1, "hats", false).code'), 'INVALID_PAYLOAD')
        self.assertEqual(self.e('WCApi.SetClothes(2, {}, false).code'), 'NO_CHARACTER')

    def test_set_clothes_merge_overwrite_and_remove(self):
        r = self.e('WCApi.SetClothes(1, { hats = h("male", "hats", 1) }, false)')
        self.assertTrue(r.ok, r.code)
        self.rt.run('saved = lastSaved()')
        self.assertEqual(self.e('saved.clothing.equipped.hats'), self.e('h("male", "hats", 1)'))
        self.assertEqual(self.e('saved.clothing.equipped.pants'), self.e('savedApp.clothing.equipped.pants'))
        own = self.rt.client_events('w_creators:client:applyAppearance')
        self.assertEqual((len(own), own[0].player), (1, 1))
        self.assertEqual(len(self.rt.client_events('w_creators:client:applyRemoteAppearance')), 1)
        self.assertEqual(self.e('serverEvents[1].kind'), 'api')

        r = self.e('WCApi.SetClothes(1, { hats = 0, boots = { hash = h("male", "boots", 2) } }, false)')
        self.assertTrue(r.ok, r.code)
        self.assertIsNone(self.e('lastSaved().clothing.equipped.hats'))
        self.assertEqual(self.e('lastSaved().clothing.equipped.boots'), self.e('h("male", "boots", 2)'))

        r = self.e('WCApi.SetClothes(1, { gloves = h("male", "gloves", 1) }, true)')
        self.assertTrue(r.ok, r.code)
        self.assertEqual(self.rt.py(self.e('lastSaved().clothing.equipped')), {'gloves': self.e('h("male", "gloves", 1)')})

    def test_set_clothes_tints_and_rules(self):
        r = self.e('WCApi.SetClothes(1, { boots = { hash = h("male", "boots", 1), palette = "metaped_tint_leather", tint0 = 3, tint1 = 4, tint2 = 5 } }, false)')
        self.assertTrue(r.ok, r.code)
        self.assertEqual(self.e('lastSaved().clothing.tints.boots.tint1'), 4)
        r = self.e('WCApi.SetClothes(1, { boots = { hash = h("male", "boots", 1), palette = "no_such_palette" } }, false)')
        self.assertEqual(r.code, 'INVALID_TINT')
        # the palette may be given as its hash
        r = self.e('WCApi.SetClothes(1, { boots = { hash = h("male", "boots", 1), palette = GetHashKey("metaped_tint_horse_leather"), tint0 = 1 } }, false)')
        self.assertTrue(r.ok, r.code)
        self.assertEqual(self.e('lastSaved().clothing.tints.boots.palette'), 'metaped_tint_horse_leather')
        # two conflicting requests: the rules keep one, the call is refused
        r = self.e('WCApi.SetClothes(1, { coats = h("male", "coats", 1), coats_closed = h("male", "coats_closed", 1) }, false)')
        self.assertEqual(r.code, 'CONFLICTING_ITEMS')
        # a new item replaces a conflicting saved one
        self.assertTrue(self.e('WCApi.SetClothes(1, { coats = h("male", "coats", 1) }, false).ok'))
        r = self.e('WCApi.SetClothes(1, { coats_closed = h("male", "coats_closed", 1) }, false)')
        self.assertTrue(r.ok, r.code)
        self.rt.run('saved = lastSaved()')
        self.assertIsNone(self.e('saved.clothing.equipped.coats'))
        self.assertIsNotNone(self.e('saved.clothing.equipped.coats_closed'))

    def test_set_clothes_busy_while_a_session_or_lock(self):
        self.rt.run('CreatorAppearanceLocks["vorp:1"] = "commit"')
        self.assertEqual(self.e('WCApi.SetClothes(1, { hats = h("male", "hats", 1) }, false).code'), 'BUSY')
        self.rt.run('CreatorAppearanceLocks["vorp:1"] = nil; o = WCBarberService.open(1, "valentine_barber")')
        self.assertTrue(self.e('o.ok'))
        self.assertEqual(self.e('WCApi.SetClothes(1, { hats = h("male", "hats", 1) }, false).code'), 'BUSY')
        self.assertIsNone(self.e('CreatorAppearanceLocks["vorp:1"]'))

    def test_set_clothes_unchanged_writes_nothing(self):
        r = self.e('WCApi.SetClothes(1, { pants = savedApp.clothing.equipped.pants }, false)')
        self.assertTrue(r.ok)
        self.assertFalse(r.data.changed)
        self.assertEqual(len(self.e('FakeDB.transactions')), 0)

    def test_set_skin_from_a_standard_skin(self):
        r = self.e('''WCApi.SetSkin(1, { model = "mp_male", expressions = { jawWidth = 50, noseSize = -0.25 },
                                         bodyScale = 1.05, hair = { hash = h("male", "hair", 3) },
                                         overlays = { eyebrow = { id = 6, tint0 = 2, opacity = 1.0 } } }, false)''')
        self.assertTrue(r.ok, r.code)
        self.rt.run('saved = lastSaved()')
        self.assertEqual(self.e('saved.morph.jawWidth'), 0.5)
        self.assertEqual(self.e('saved.morph.noseSize'), -0.25)
        self.assertAlmostEqual(self.e('saved.body.height'), 1.05)
        self.assertEqual(self.e('saved.hair.style'), self.e('h("male", "hair", 3)'))
        self.assertEqual((self.e('saved.overlays.eyebrows.style'), self.e('saved.overlays.eyebrows.color')), (2, 3))
        self.assertEqual(self.rt.py(self.e('saved.clothing.equipped')), self.rt.py(self.e('savedApp.clothing.equipped')))
        # overwrite replaces the morphology
        r = self.e('WCApi.SetSkin(1, { expressions = { chinWidth = 0.1 } }, true)')
        self.assertTrue(r.ok, r.code)
        self.assertEqual(self.rt.py(self.e('lastSaved().morph')), {'chinWidth': 0.1})

    def test_set_skin_validates_everything(self):
        cases = {
            '{ headHash = 1234 }': 'INVALID_COMPONENT',
            '{ eyesHash = h("female", "eyes", 1) }': 'INVALID_COMPONENT',
            '{ hair = { hash = h("male", "hats", 1) } }': 'INVALID_COMPONENT',
            '{ model = "mp_female" }': 'INVALID_PAYLOAD',
            '{ expressions = { notAnExpression = 0.5 } }': 'INVALID_PAYLOAD',
            '{ expressions = { jawWidth = "x" } }': 'INVALID_PAYLOAD',
            '{ overlays = { eyebrow = { id = 99 } } }': 'INVALID_COMPONENT',
            '{ overlays = { nope = { id = 1 } } }': 'INVALID_COMPONENT',
            '{ bodyScale = "tall" }': 'INVALID_PAYLOAD',
        }
        for skin, code in cases.items():
            self.assertEqual(self.e('WCApi.SetSkin(1, %s, false).code' % skin), code, skin)
        self.assertEqual(len(self.e('FakeDB.transactions')), 0)
        # a female character has no facial hair
        self.rt.run('savedApp = S.default("female"); setSaved(savedApp)')
        self.assertEqual(self.e('WCApi.SetSkin(1, { beards_complete = h("male", "mustache", 1) }, false).code'), 'INVALID_COMPONENT')

    def test_set_skin_never_touches_clothing(self):
        r = self.e('WCApi.SetSkin(1, { version = 3, sex = "male", body = savedApp.body, head = savedApp.head, morph = { chest = 0.3 }, hair = savedApp.hair, overlays = {}, clothing = { equipped = {} } }, false)')
        self.assertTrue(r.ok, r.code)
        self.assertEqual(self.e('lastSaved().morph.chest'), 0.3)
        self.assertEqual(self.rt.py(self.e('lastSaved().clothing.equipped')), self.rt.py(self.e('savedApp.clothing.equipped')))


class ApiReviewRegressionTests(unittest.TestCase):
    def setUp(self):
        self.rt = services_server()
        self.e = self.rt.eval

    def test_body_weight_is_the_waist_outfit_hash(self):
        # WAIST_TYPES[5] (negative) and its unsigned form, WAIST_TYPES[11], an index
        for value, weight in (('-844699484', 5), ('(-844699484) & 0xffffffff', 5), ('1745919061', 11), ('7', 7)):
            r = self.e('WCApi.SetSkin(1, { model = "mp_male", bodyWeight = %s }, false)' % value)
            self.assertTrue(r.ok, value)
            self.assertEqual(self.e('lastSaved().body.weight'), weight, value)
        self.assertEqual(self.e('WCApi.GetAppearance(1).skin.bodyWeight'), 927185840)  # WAIST_TYPES[7]
        writes = len(self.e('FakeDB.transactions'))
        for value in ('12345678', '0', '22', '1.5', '"heavy"'):
            self.assertEqual(self.e('WCApi.SetSkin(1, { bodyWeight = %s }, false).code' % value), 'INVALID_PAYLOAD', value)
        self.assertEqual(len(self.e('FakeDB.transactions')), writes)
        self.assertEqual(self.e('lastSaved().body.weight'), 7)

    def test_get_appearance_skin_round_trips_through_set_skin(self):
        self.rt.run('app = WCUtil.copy(savedApp); app.body.weight = 3; setSaved(app)')
        r = self.e('WCApi.SetSkin(1, WCApi.GetAppearance(1).skin, true)')
        self.assertTrue(r.ok, r.code)
        self.assertFalse(r.data.changed)
        self.assertEqual(len(self.e('FakeDB.transactions')), 0)

    def test_v3_skin_is_validated_not_repaired(self):
        cases = {
            'a.hair.style = 12345': 'INVALID_COMPONENT',
            'a.hair.facial = h("female", "hair", 1)': 'INVALID_COMPONENT',
            'a.head.head = 1': 'INVALID_COMPONENT',
            'a.body.upper = h("female", "BODIES_UPPER", 1)': 'INVALID_COMPONENT',
            'a.overlays.blush = { style = 999, color = 1, opacity = 1 }': 'INVALID_COMPONENT',
            'a.overlays.blush = { style = 1, color = 99, opacity = 1 }': 'INVALID_COMPONENT',
            'a.overlays.blush = { style = 1, color = 1, opacity = 5 }': 'INVALID_COMPONENT',
            'a.overlays.nope = { style = 1 }': 'INVALID_COMPONENT',
            'a.morph.jawWidth = 5': 'INVALID_PAYLOAD',
            'a.morph.notAMorph = 0.5': 'INVALID_PAYLOAD',
            'a.body.weight = 40': 'INVALID_PAYLOAD',
            'a.body.height = 3': 'INVALID_PAYLOAD',
            'a.hair = "long"': 'INVALID_PAYLOAD',
        }
        before = self.e('lastSaved() and lastSaved().hair.style or savedApp.hair.style')
        for edit, code in cases.items():
            self.rt.run('a = WCApi.GetCharacterAppearance(1); %s; r = WCApi.SetSkin(1, a, false)' % edit)
            self.assertEqual(self.e('r.code'), code, edit)
        self.assertEqual(len(self.e('FakeDB.transactions')), 0)
        self.assertEqual(self.e('WCApi.GetCharacterAppearance(1).hair.style'), before)
        # a valid v3 change still goes through; 0 = bald is valid
        self.rt.run('a = WCApi.GetCharacterAppearance(1); a.hair.style = 0; a.morph.jawWidth = 0.4; r = WCApi.SetSkin(1, a, false)')
        self.assertTrue(self.e('r.ok'), self.e('r.code'))
        self.assertEqual(self.e('lastSaved().hair.style'), 0)

    def test_standard_overlay_out_of_range_is_refused(self):
        for overlay in ('{ style = 999 }', '{ style = 1, color = 99 }', '{ id = 6, tint0 = 1.5 }'):
            self.assertEqual(self.e('WCApi.SetSkin(1, { overlays = { eyebrow = %s } }, false).code' % overlay),
                             'INVALID_COMPONENT', overlay)
        self.assertEqual(len(self.e('FakeDB.transactions')), 0)

    def test_set_skin_folds_the_pending_growth(self):
        self.rt.run('''
            Config.Grooming.saveIntervalSeconds = 3600
            WCGroomingServer.tick(); for _ = 1, 9 do Clock.now = Clock.now + 30000; WCGroomingServer.tick() end
        ''')
        self.assertEqual(self.e('WCGroomingServer.pending(1).seconds'), 270)
        r = self.e('WCApi.SetSkin(1, { hair = { hash = h("male", "hair", 3) } }, false)')
        self.assertTrue(r.ok, r.code)
        self.assertEqual(self.e('lastSaved().grooming.hair.seconds'), 0)   # cut: restarts
        self.assertEqual(self.e('lastSaved().grooming.beard.seconds'), 270)  # not cut: kept
        self.assertEqual(self.e('WCGroomingServer.pending(1).seconds'), 0)
        # a refused write keeps the counter
        self.rt.run('Clock.now = Clock.now + 30000; WCGroomingServer.tick()')
        self.assertEqual(self.e('WCApi.SetSkin(1, { headHash = 1 }, false).code'), 'INVALID_COMPONENT')
        self.assertEqual(self.e('WCGroomingServer.pending(1).seconds'), 30)

    def test_spawn_selector_never_replaces_a_grant_or_leaves_an_instance(self):
        self.rt.run('WCSpawnServer.grant(1, "login")')
        self.assertEqual(self.e('WCApi.OpenSpawnSelector(1).code'), 'BUSY')
        self.assertEqual(self.e('WCSpawnServer.pending(1)'), 'login')
        self.rt.run('WCSpawnServer.cancel(1); Players[1].bucket = 55')
        self.assertEqual(self.e('WCApi.OpenSpawnSelector(1).code'), 'BUSY')
        self.assertIsNone(self.e('WCSpawnServer.pending(1)'))
        self.assertEqual(self.e('Players[1].bucket'), 55)
        self.assertEqual(len(self.rt.client_events('w_creators:client:selectSpawn')), 0)
        self.rt.run('Players[1].bucket = 0')
        self.assertTrue(self.e('WCApi.OpenSpawnSelector(1).ok'))

    def test_admin_spawn_choice_moves_the_player_without_a_fresh_login(self):
        self.assertTrue(self.e('WCApi.OpenSpawnSelector(1).ok'))
        # another resource instances the player between the grant and the choice
        self.rt.run('Players[1].bucket = 55')
        r = self.e('Callbacks["w_creators:spawn:choose"](1, "rhodes")')
        self.assertTrue(r.ok, r.code)
        self.assertEqual(r.data.kind, 'admin')
        self.assertEqual(len(self.rt.client_events('w_creators:client:spawn')), 0,
                         'client:spawn is a fresh login for w_core')
        respawn = self.rt.client_events('w_creators:client:respawn')
        self.assertEqual(len(respawn), 1)
        self.assertEqual((respawn[0].args[2].kind, respawn[0].args[2].point), ('admin', 'rhodes'))
        self.assertEqual(self.e('Players[1].bucket'), 55, 'the other resource keeps its bucket')
        self.assertIsNone(self.e('WCSpawnServer.pending(1)'))

    def test_prompt_less_clinic_opens_only_through_the_export(self):
        self.rt.run('Players[1].coords = vector3(-284.49, 807.49, 119.38)')
        self.assertEqual(self.e('WCSurgeryService.open(1, "valentine_surgery").code'), 'SURGERY_NOT_ALLOWED')
        self.assertIsNone(self.e('WCSessions.current(1)'))
        self.assertTrue(self.e('WCApi.OpenCosmeticSurgery({ source = 1, clinicId = "valentine_surgery" }).ok'))
        # the grant is for that clinic only
        self.rt.run('Clock.now = Clock.now + 11000')
        self.rt.run('o = WCSurgeryService.open(1, "valentine_surgery")')
        self.assertTrue(self.e('o.ok'), self.e('o.code'))
        # one-shot: consumed by the open
        self.rt.run('WCSessions.close(1, o.data.token); Clock.now = Clock.now + 11000')
        self.assertEqual(self.e('WCSurgeryService.open(1, "valentine_surgery").code'), 'SURGERY_NOT_ALLOWED')
        # expires
        self.rt.run('WCSurgeryService.grant(1, "valentine_surgery"); Clock.now = Clock.now + 61000')
        self.assertEqual(self.e('WCSurgeryService.open(1, "valentine_surgery").code'), 'SURGERY_NOT_ALLOWED')
        self.rt.run('WCSurgeryService.grant(1, "saintdenis_surgery"); Clock.now = Clock.now + 11000')
        self.assertEqual(self.e('WCSurgeryService.open(1, "valentine_surgery").code'), 'SURGERY_NOT_ALLOWED')
        # a clinic with its own prompt needs no grant
        self.rt.run('''
            for _, loc in ipairs(Config.Locations) do if loc.id == 'valentine_surgery' then loc.prompt = true end end
            WCLocations.reload(); Clock.now = Clock.now + 11000
        ''')
        self.assertTrue(self.e('WCSurgeryService.open(1, "valentine_surgery").ok'))


class ApiOpenTests(unittest.TestCase):
    def setUp(self):
        self.rt = services_server()
        self.e = self.rt.eval

    def test_open_cosmetic_surgery(self):
        self.rt.run('Players[1].coords = vector3(-284.49, 807.49, 119.38)')
        r = self.e('WCApi.OpenCosmeticSurgery({ source = 1, clinicId = "valentine_surgery" })')
        self.assertTrue(r.ok, r.code)
        events = self.rt.client_events('w_creators:client:openSurgery')
        self.assertEqual((len(events), events[0].player, events[0].args[1]), (1, 1, 'valentine_surgery'))
        self.assertTrue(self.e('WCApi.OpenCosmeticSurgery(1, "valentine_surgery").ok'))
        self.assertEqual(self.e('WCApi.OpenCosmeticSurgery({ source = 1, clinicId = "nowhere" }).code'), 'LOCATION_NOT_FOUND')
        self.assertEqual(self.e('WCApi.OpenCosmeticSurgery({ source = 1, clinicId = "valentine_barber" }).code'), 'LOCATION_NOT_FOUND')
        self.assertEqual(self.e('WCApi.OpenCosmeticSurgery({ source = 1, clinicId = "saintdenis_surgery" }).code'), 'TOO_FAR')
        self.assertEqual(self.e('WCApi.OpenCosmeticSurgery({ source = 2, clinicId = "valentine_surgery" }).code'), 'NO_CHARACTER')
        self.assertEqual(self.e('WCApi.OpenCosmeticSurgery({ source = 42, clinicId = "valentine_surgery" }).code'), 'INVALID_PAYLOAD')
        self.rt.run('Config.CosmeticSurgery.enabled = false')
        self.assertEqual(self.e('WCApi.OpenCosmeticSurgery({ source = 1, clinicId = "valentine_surgery" }).code'), 'SURGERY_DISABLED')
        self.rt.run('''
            Config.CosmeticSurgery.enabled = true
            for _, loc in ipairs(Config.Locations) do if loc.id == 'valentine_surgery' then loc.enabled = false end end
            WCLocations.reload()
        ''')
        self.assertEqual(self.e('WCApi.OpenCosmeticSurgery({ source = 1, clinicId = "valentine_surgery" }).code'), 'LOCATION_DISABLED')
        self.assertEqual(len(self.rt.client_events('w_creators:client:openSurgery')), 2)

    def test_open_store_barber_wardrobe(self):
        self.rt.run('Players[1].coords = vector3(-326.17, 773.757, 117.5)')  # valentine_clothing
        self.assertTrue(self.e('WCApi.OpenClothingStore(1, "valentine_clothing").ok'))
        self.assertEqual(len(self.rt.client_events('w_creators:client:openStore')), 1)
        self.assertEqual(self.e('WCApi.OpenBarber(1, "valentine_barber").code'), 'TOO_FAR')
        self.rt.run('Config.Services.clothingStores = false')
        self.assertEqual(self.e('WCApi.OpenClothingStore(1, "valentine_clothing").code'), 'STORE_DISABLED')
        self.rt.run('Players[1].coords = vector3(-307.51, 813.96, 118.99)')
        self.assertTrue(self.e('WCApi.OpenBarber(1, "valentine_barber").ok'))
        self.assertEqual(len(self.rt.client_events('w_creators:client:openBarber')), 1)
        # a remote wardrobe only when allowed
        self.rt.run('Config.Wardrobe.allowRemote = false')
        self.assertEqual(self.e('WCApi.OpenWardrobe(1).code'), 'LOCATION_NOT_FOUND')
        self.rt.run('Config.Wardrobe.allowRemote = true')
        self.assertTrue(self.e('WCApi.OpenWardrobe(1).ok'))
        events = self.rt.client_events('w_creators:client:openWardrobe')
        self.assertEqual(len(events), 1)
        self.assertIsNone(events[0].args[1])
        self.rt.run('Config.Services.wardrobe = false')
        self.assertEqual(self.e('WCApi.OpenWardrobe(1).code'), 'WARDROBE_DISABLED')

    def test_open_refused_while_a_session_is_open(self):
        self.rt.run('Players[1].coords = vector3(-307.51, 813.96, 118.99); o = WCBarberService.open(1, "valentine_barber")')
        self.assertTrue(self.e('o.ok'))
        self.assertEqual(self.e('WCApi.OpenBarber(1, "valentine_barber").code'), 'BUSY')

    def test_spawn_selector_and_respawn_delegate_to_the_spawn_service(self):
        r = self.e('WCApi.OpenSpawnSelector(1)')
        self.assertTrue(r.ok, r.code)
        self.assertTrue(self.e('SpawnPending[1]'))
        self.assertEqual(self.e('WCSpawnServer.pending(1)'), 'admin')
        events = self.rt.client_events('w_creators:client:selectSpawn')
        self.assertEqual(len(events), 1)
        payload = events[0].args[1]
        self.assertEqual(payload.kind, 'admin')
        self.assertEqual(payload.points[1], 'valentine')
        self.assertEqual(self.e('WCApi.OpenSpawnSelector(2).code'), 'NO_CHARACTER')
        self.rt.run('Config.Services.spawnSelector = false')
        self.assertEqual(self.e('WCApi.OpenSpawnSelector(1).code'), 'SERVICE_DISABLED')

        r = self.e('WCApi.RespawnPlayer(1, "rhodes")')
        self.assertTrue(r.ok, r.code)
        self.assertEqual((r.data.kind, r.data.point), ('admin', 'rhodes'))
        respawn = self.rt.client_events('w_creators:client:respawn')
        self.assertEqual(len(respawn), 1)
        self.assertEqual(self.e('WCApi.RespawnPlayer(1, "atlantis").code'), 'INVALID_SPAWN')
        self.assertEqual(self.e('WCApi.RespawnPlayer(1, 12).code'), 'INVALID_SPAWN')
        self.assertEqual(self.e('WCApi.RespawnPlayer(1, nil, "death").data.kind'), 'death')


if __name__ == '__main__':
    unittest.main()
