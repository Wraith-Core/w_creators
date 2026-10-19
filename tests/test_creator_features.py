"""The creator's theatre scene and the features added with it: the stage data (Config.Scene), its
ped-relative coloured lights, the interior wait, the ambient population kept out, the pair camera
and its glide, the profile turn, the save-time sex, the body build, the custom eye tint, the makeup
sheet styles and extra tints, the eyebrow texture sets, the eyebrows following the hair, stacked
scars, named styles and colour chips, the hide-clothes view, the mouth on the teeth view, the fuller
randomize's parts and the editor's draft resume / keep-draft cancel.

Run: python3 -m unittest discover -s tests -p 'test_creator_features.py'
"""
import unittest

from harness import Runtime
from test_client_characters_support import make_characters, settle
from test_client_infra_support import make_client
from test_editor_lua import EditorBase, lua_list
from test_server_characters_flow import identity, server_runtime
from test_server_characters_world import Base as WorldBase


class SceneDataTests(unittest.TestCase):
    def setUp(self):
        self.rt = Runtime().load_shared()
        self.e = self.rt.eval

    def test_the_scene_is_the_theatre_stage(self):
        e = self.e
        # the Jump On creator's places: the player's anchor and the two characters side by side, 2 m apart
        self.assertEqual([e('Config.Scene.anchor[%d]' % i) for i in (1, 2, 3, 4)], [2542.655, -1305.585, 48.014, 192.761])
        self.assertEqual([e('Config.Scene.peds.male[%d]' % i) for i in (1, 2, 3, 4)], [2547.0, -1310.0, 48.0, 358.732])
        self.assertEqual([e('Config.Scene.peds.female[%d]' % i) for i in (1, 2, 3, 4)], [2545.0, -1309.9, 48.0, 358.337])
        self.assertEqual(e('#Config.Scene.lights'), 5)
        self.assertEqual((e('Config.Scene.cameras.pair.distance'), e('Config.Scene.cameras.pair.fov')), (4.0, 45.0))
        self.assertEqual(e('Config.Scene.cameras.glideMs'), 1000)
        self.assertIsNone(e('Config.Scene.editingPed'))
        self.assertTrue(e('Config.Scene.hideOtherWhileEditing'))
        self.assertFalse(e('Config.Scene.ambient'))
        # the selection screen shares the stage
        self.assertEqual(e('Config.Scene.selectionPed[1]'), e('Config.Scene.peds.male[1]'))


class SceneRuntimeTests(unittest.TestCase):
    def setUp(self):
        self.rt = make_client()
        self.e = self.rt.eval
        self.run = self.rt.run

    def light(self, i):
        return self.rt.py(self.e('CreatorScene.lights()[%d]' % i))

    def test_relative_lights_follow_the_spots(self):
        lights = self.rt.py(self.e('CreatorScene.lights()'))
        self.assertEqual(len(lights), 5)
        # key light 1 m in front of the man, 0.5 m up; warm fill over the pair; red rim on his right
        key, fill, rim = self.light(1), self.light(3), self.light(4)
        for got, want in zip((key[1], key[2], key[3]), (2547.022, -1309.000, 48.5)):
            self.assertAlmostEqual(got, want, places=2)
        self.assertEqual((key[4], key[5], key[6], key[7], key[8]), (4.0, 1500.0, 255, 255, 255))
        for got, want in zip((fill[1], fill[2], fill[3]), (2546.026, -1308.950, 50.5)):
            self.assertAlmostEqual(got, want, places=2)
        self.assertEqual((fill[6], fill[7], fill[8]), (255, 204, 153))
        for got, want in zip((rim[1], rim[2], rim[3]), (2547.322, -1309.007, 48.0)):
            self.assertAlmostEqual(got, want, places=2)
        # DrawLightWithRange: x, y, z, r, g, b, range, intensity
        self.run('clearLog(); CreatorScene.drawLights()')
        args = self.rt.py(self.e('Log[4].args'))
        self.assertEqual((args[4], args[5], args[6], args[7], args[8]), (255, 0, 0, 2.0, 1500.0))

    def test_moving_a_spot_moves_its_lights_and_absolute_lights_still_draw(self):
        x = self.light(1)[1]
        self.run('Config.Scene.peds.male[1] = Config.Scene.peds.male[1] + 10')
        self.assertAlmostEqual(self.light(1)[1], x + 10, places=3)
        self.run('Config.Scene.lights = { { 1.0, 2.0, 3.0, 10.0, 50.0 } }')
        self.assertEqual(self.light(1), {1: 1.0, 2: 2.0, 3: 3.0, 4: 10.0, 5: 50.0, 6: 255, 7: 255, 8: 255})

    def test_load_waits_for_the_interior_and_keeps_the_configured_clock(self):
        self.run('''InteriorCalls, ReadyAfter = 0, 3
            function GetInteriorAtCoords() InteriorCalls = InteriorCalls + 1 return 7 end
            function IsInteriorReady(id) if id == 7 and InteriorCalls >= ReadyAfter then return 1 end return false end
            clearLog(); arrived = CreatorScene.load()''')
        self.assertTrue(self.e('arrived'))
        self.assertGreaterEqual(self.e('InteriorCalls'), 3)
        clock = self.rt.py(self.e('Log[indexOf("NetworkClockTimeOverride")].args'))
        self.assertEqual((clock[1], clock[2]), (10, 0))
        self.assertEqual(self.e('count("SetTimecycleModifier")'), 0)   # the theatre: no timecycle
        self.run('CreatorScene.release(); Config.Scene.timecycle = "Online_Character_Editor"; clearLog(); CreatorScene.load()')
        self.assertEqual(self.e('Log[indexOf("SetTimecycleModifier")].args[1]'), 'Online_Character_Editor')

    def test_the_ambient_population_is_kept_out_while_the_room_shows(self):
        self.run('''local base = Citizen.InvokeNative
            Citizen.InvokeNative = function(hash, ...)
                if hash == 0x1B5C85C612E5256E then Log[#Log + 1] = { op = 'block', args = table.pack(...) } return 55 end
                return base(hash, ...)
            end''')
        self.assertFalse(self.e('CreatorScene.suppressAmbient()'))          # nothing loaded yet
        self.run('clearLog(); CreatorScene.load()')
        self.assertEqual(self.e('count("block")'), 1)                       # scenario peds blocked around it
        self.run('clearLog()')
        self.assertTrue(self.e('CreatorScene.suppressAmbient()'))
        self.assertEqual(self.e('#Log'), self.e('#WCNative.scene.DENSITY_THIS_FRAME'))
        self.assertEqual(self.e('Log[1].args[1]'), 0.0)
        self.run('clearLog(); CreatorScene.release()')
        self.assertEqual(self.e('Log[indexOf(string.format("native:0x%X", 0x31D16B74C6E29D66))].args[1]'), 55)
        # ambient = true leaves the town as it is
        self.run('Config.Scene.ambient = true; clearLog(); CreatorScene.load()')
        self.assertEqual(self.e('count("block")'), 0)
        self.assertFalse(self.e('CreatorScene.suppressAmbient()'))

    def test_the_cleanup_keeps_another_resources_ped_in_town(self):
        # the room is a real place now: a scripted ped of another resource near the stage stays; a
        # preview of an earlier run and an ambient passer-by go
        self.run('''Missions = {}
            function IsEntityAMissionEntity(e) if Missions[e] then return 1 end return false end
            local ax, ay, az = Config.Scene.anchor[1], Config.Scene.anchor[2], Config.Scene.anchor[3]
            preview = makePed("mp_female", ax, ay, az); Missions[preview] = true
            shopkeeper = makePed("s_m_m_tailor_01", ax + 1, ay, az); Missions[shopkeeper] = true
            walker = makePed("a_m_m_sdupperclass_01", ax - 1, ay, az)
            removed = CreatorScene.cleanup()''')
        self.assertEqual(self.e('removed'), 2)
        self.assertFalse(self.e('DoesEntityExist(preview)'))
        self.assertFalse(self.e('DoesEntityExist(walker)'))
        self.assertTrue(self.e('DoesEntityExist(shopkeeper)'))

    def test_still_stops_the_idle_where_the_ped_stands(self):
        self.run('p = makePed("mp_male", 1.0, 2.0, 3.0); clearLog(); CreatorScene.still(p)')
        self.assertEqual(self.rt.py(self.e('ops()')), {1: 'ClearPedTasksImmediately', 2: 'FreezeEntityPosition', 3: 'TaskStandStill'})
        self.assertEqual(self.e('Peds[p].coords.x'), 1.0)


class CameraTests(unittest.TestCase):
    def setUp(self):
        self.rt = make_client()
        self.e = self.rt.eval
        self.run = self.rt.run
        self.run('''a = makePed("mp_male", 2547.0, -1310.0, 48.0, 358.732)
            b = makePed("mp_female", 2545.0, -1309.9, 48.0, 358.337)''')

    def last(self, op):
        return self.rt.py(self.e('Log[(function() for i = #Log, 1, -1 do if Log[i].op == "%s" then return i end end end)()].args' % op))

    def test_the_pair_shot_frames_the_middle_of_both(self):
        self.run('clearLog(); ok = WCCamera.openPair({ a, b }, Config.Scene.cameras.pair)')
        self.assertTrue(self.e('ok'))
        cam, aim, fov = self.last('SetCamCoord'), self.last('PointCamAtCoord'), self.last('SetCamFov')
        for got, want in zip((cam[2], cam[3], cam[4]), (2546.102, -1305.951, 48.0)):
            self.assertAlmostEqual(got, want, places=2)
        for got, want in zip((aim[2], aim[3], aim[4]), (2546.0, -1309.95, 48.0)):
            self.assertAlmostEqual(got, want, places=2)
        self.assertEqual(fov[2], 45.0)
        self.assertEqual(self.e('WCCamera.current()'), 'pair')
        self.assertIsNone(self.e('WCCamera.ped()'))
        self.assertFalse(self.e('WCCamera.zoom(2)'))   # nothing to zoom on: the pair is not an actor

    def test_the_glide_applies_to_the_next_move_only(self):
        self.run('WCCamera.openPair({ a, b }); WCCamera.glide(1000); clearLog(); WCCamera.open(a, "fullBody")')
        self.assertEqual(self.last('SetCamActiveWithInterp')[3], 1000)
        self.run('clearLog(); WCCamera.focus("head")')
        self.assertEqual(self.last('SetCamActiveWithInterp')[3], self.e('WCCamera.INTERP_MS'))

    def test_profile_turns_the_actor_and_front_turns_it_back(self):
        self.run('WCCamera.open(a, "face"); h = GetEntityHeading(a)')
        self.run('WCCamera.pose("profile")')
        self.assertAlmostEqual(self.e('GetEntityHeading(a)'), (self.e('h') + 90.0) % 360)
        self.run('WCCamera.pose("profile")')                        # already turned: no second turn
        self.assertAlmostEqual(self.e('GetEntityHeading(a)'), (self.e('h') + 90.0) % 360)
        self.assertEqual(self.e('WCCamera.currentPose()'), 'profile')
        self.run('WCCamera.pose("front")')
        self.assertAlmostEqual(self.e('GetEntityHeading(a)'), self.e('h'))
        self.assertIsNone(self.e('WCCamera.currentPose()'))


class ServerPopulationTests(WorldBase):
    def test_the_private_bucket_has_no_ambient_population(self):
        self.rt.run('PopulationCalls = {}; function SetRoutingBucketPopulationEnabled(b, on) '
                    'PopulationCalls[#PopulationCalls + 1] = { bucket = b, on = on } end')
        self.assertTrue(self.call('scene:prepare', 1).ok)
        self.assertEqual(self.e('#PopulationCalls'), 1)
        self.assertEqual(self.e('PopulationCalls[1].bucket'), 1)
        self.assertFalse(self.e('PopulationCalls[1].on'))


class GrantLockTests(unittest.TestCase):
    """beginCreate says when the grant's sex can no longer change, so the gender scene offers only it."""

    def setUp(self):
        self.rt = server_runtime()
        self.e = self.rt.eval
        self.cb = self.e('cb')

    def later(self):
        self.rt.run('Clock.now = Clock.now + 6000')   # past the rate-limit windows

    def test_the_server_says_when_the_sex_is_locked(self):
        r = self.cb('characters:beginCreate', 1)
        self.assertTrue(r.ok, r.code)
        self.assertIsNone(r.data.locked)
        token = r.data.token
        self.later()
        self.assertIsNone(self.cb('characters:beginCreate', 1, 'female').data.locked)   # only recorded
        # a half-finished creation: the framework character exists, the appearance write failed
        app = self.e('AppearanceSchema.default("female")')
        self.rt.run('FakeDB.transactionOk = false')
        self.assertEqual(self.cb('characters:create', 1, token, identity(self.rt), app).code, 'DATABASE_ERROR')
        self.later()
        r = self.cb('characters:beginCreate', 1, 'male')
        self.assertEqual((r.data.sex, r.data.locked), ('female', True))
        # a completed creation that was never loaded is replayed, locked too
        self.rt.run('FakeDB.transactionOk = true')
        self.later()
        self.assertTrue(self.cb('characters:create', 1, token, identity(self.rt), app).ok)
        self.later()
        r = self.cb('characters:beginCreate', 1)
        self.assertEqual((r.data.token, r.data.sex, r.data.locked), (token, 'female', True))

    def test_a_locked_grant_offers_only_its_sex_in_the_gender_scene(self):
        rt = make_characters(setup='CallbackResults = { ["w_creators:characters:list"] = listResult({}, 2), '
                                   '["w_creators:characters:beginCreate"] = WCResult.ok({ token = "tok-1", '
                                   'sex = "female", locked = true }) }')
        rt.run('press("RETURN")')
        settle(rt)
        rt.run('press("LEFT")')                       # the man: refused before anything is built
        settle(rt, 0, 3, barrier=False)
        self.assertEqual(rt.eval('WCCreator.stage()'), 'gender')
        self.assertTrue(rt.eval('noted(locale("جنس هذه الشخصية ثابت الآن ولا يمكن تغييره"))'))
        rt.run('press("RIGHT")')
        settle(rt, 0, 3, barrier=False)
        self.assertEqual(rt.eval('WCCreator.stage()'), 'editor')
        self.assertEqual(rt.eval('WCEditor.session().saved.sex'), 'female')


class AppearanceFieldTests(unittest.TestCase):
    def setUp(self):
        self.rt = Runtime().load_shared()
        self.e = self.rt.eval
        self.run = self.rt.run

    def sanitize(self, code):
        self.run('app = AppearanceSchema.default("male"); %s; out, violations = AppearanceSchema.sanitize(app)' % code)
        return [v['field'] for v in self.rt.py(self.e('violations')).values()]

    def test_an_appearance_without_the_new_fields_is_unchanged(self):
        self.run('a = AppearanceSchema.default("female"); b = AppearanceSchema.sanitize(a)')
        self.assertTrue(self.e('WCUtil.deepEqual(a, b)'))
        self.assertIsNone(self.e('b.body.build'))
        self.assertIsNone(self.e('b.head.eyesTint'))

    def test_build_and_eye_tint_are_validated(self):
        self.assertEqual(self.sanitize('app.body.build = 3; app.head.eyesTint = { tint0 = 1, tint1 = 2, tint2 = 127 }'), [])
        self.assertEqual(self.e('out.body.build'), 3)
        self.assertEqual(self.e('out.head.eyesTint.tint2'), 127)
        bad = self.sanitize('app.body.build = 9; app.head.eyesTint = { tint0 = 500, tint1 = 0, tint2 = 0 }')
        self.assertIn('body.build', bad)
        self.assertIn('eyes.tint', bad)
        self.assertIsNone(self.e('out.body.build'))
        self.assertIsNone(self.e('out.head.eyesTint'))

    def test_overlay_extras_only_where_the_layer_has_them(self):
        bad = self.sanitize('''app.overlays.foundation = { style = 1, color = 3, opacity = 1, color2 = 9 }
            app.overlays.blush = { style = 1, color = 3, opacity = 1, color2 = 9, matchHair = true }
            app.overlays.eyebrows.matchHair = true
            app.overlays.shadows = { style = 6, color = 1, opacity = 1, color2 = 2, color3 = 64 }
            app.overlays.scars = { style = 1, color = 1, opacity = 1, extra = { { style = 2 }, { style = 3, opacity = 0.5 },
                { style = 4 }, { style = 5 } } }
            app.overlays.moles = { style = 1, color = 1, opacity = 1, extra = { { style = 2 } } }''')
        self.assertEqual(self.e('out.overlays.foundation.color2'), 9)
        self.assertIsNone(self.e('out.overlays.blush.color2'))
        self.assertIsNone(self.e('out.overlays.blush.matchHair'))
        self.assertTrue(self.e('out.overlays.eyebrows.matchHair'))
        self.assertEqual((self.e('out.overlays.shadows.color2'), self.e('out.overlays.shadows.color3')), (2, 64))
        self.assertEqual(self.e('#out.overlays.scars.extra'), 3)                 # at most `extra` more
        self.assertEqual(self.e('out.overlays.scars.extra[2].opacity'), 0.5)
        self.assertIsNone(self.e('out.overlays.moles.extra'))
        for field in ('overlay.blush.color2', 'overlay.blush.matchHair', 'overlay.scars.extra', 'overlay.moles.extra'):
            self.assertIn(field, bad)

    def test_the_legacy_projection_carries_build_and_eye_tint(self):
        self.run('''a = AppearanceSchema.default("male"); a.body.build = 4
            a.head.eyesTint = { tint0 = 5, tint1 = 6, tint2 = 7 }
            b = AppearanceSchema.fromLegacy(AppearanceSchema.toLegacy(a))''')
        self.assertEqual(self.e('b.body.build'), 4)
        self.assertEqual(self.e('b.head.eyesTint.tint1'), 6)

    def test_sections_see_build_and_eye_tint(self):
        self.run('''a = AppearanceSchema.default("male"); b = WCUtil.copy(a); b.body.build = 2
            c = WCUtil.copy(a); c.head.eyesTint = { tint0 = 1, tint1 = 1, tint2 = 1 }''')
        self.assertTrue(self.e('AppearanceSchema.changedSections(a, b).body'))
        self.assertTrue(self.e('AppearanceSchema.changedSections(a, c).eyes'))
        self.assertIsNone(self.e('AppearanceSchema.changedSections(a, c).body'))
        self.assertEqual(self.e('AppearanceSchema.mergeSections(a, c, { "eyes" }).head.eyesTint.tint0'), 1)
        self.assertIsNone(self.e('AppearanceSchema.mergeSections(a, c, { "hair" }).head.eyesTint'))

    # 2026-10-19: the voice (1..3), the sex's vocal set
    def test_voice_is_validated(self):
        self.assertEqual(self.sanitize('app.voice = 2'), [])
        self.assertEqual(self.e('out.voice'), 2)
        self.assertIn('voice', self.sanitize('app.voice = 7'))
        self.assertIsNone(self.e('out.voice'))
        self.assertIn('voice', self.sanitize('app.voice = 1.5'))

    def test_voice_name_follows_the_sex(self):
        self.assertEqual(self.e('AppearanceSchema.vofxName("female", 3)'), 'VOFX_PLAYER_FEMALE03')
        self.assertEqual(self.e('AppearanceSchema.vofxName("male", nil)'), 'VOFX_PLAYER_MALE01')
        self.assertEqual(self.e('AppearanceSchema.vofxName("female", nil)'), 'VOFX_PLAYER_FEMALE01')
        self.assertEqual(self.e('AppearanceSchema.vofxName("female", 9)'), 'VOFX_PLAYER_FEMALE01')

    def test_the_legacy_projection_carries_the_voice(self):
        self.run('a = AppearanceSchema.default("female"); a.voice = 3; b = AppearanceSchema.fromLegacy(AppearanceSchema.toLegacy(a))')
        self.assertEqual(self.e('b.voice'), 3)

    def test_the_surgeon_changes_the_voice_and_others_keep_it(self):
        self.run('a = AppearanceSchema.default("male"); a.voice = 2; c = WCUtil.copy(a); c.voice = 3')
        self.assertEqual(self.e('AppearanceSchema.mergeSections(a, c, { "body" }).voice'), 3)   # surgery: body
        self.assertEqual(self.e('AppearanceSchema.mergeSections(a, c, { "hair" }).voice'), 2)   # barber
        self.run('d = WCUtil.copy(a); d.voice = nil')                                             # SetSkin, no voice
        self.assertEqual(self.e('AppearanceSchema.mergeSections(a, d, { "body" }).voice'), 2)
        self.assertTrue(self.e('AppearanceSchema.changedSections(a, c).body'))
        self.assertIsNone(self.e('AppearanceSchema.changedSections(a, WCUtil.copy(a)).body'))

    def test_speaking_voice_follows_the_sex_and_tone(self):
        self.assertEqual(self.e('AppearanceSchema.speechVoice("female", nil)'), '0537_A_F_M_CIV_WHITE_06')
        self.assertEqual(self.e('AppearanceSchema.speechVoice("female", 2)'), '0859_A_F_M_CIV_POOR_WHITE_AGGRESSIVE_01')
        self.assertEqual(self.e('AppearanceSchema.speechVoice("male", 3)'), '0294_A_M_M_NBXUPPERCLASS_01_WHITE_02')
        self.assertEqual(self.e('AppearanceSchema.speechVoice("male", 7)'), '0583_A_M_M_CIV_WHITE_07')

    def test_eyebrow_styles_keep_their_texture_set(self):
        # style 1 is mp_u_faov_eyebrow_m_012 on either sex; style 6 is the f set's 004
        self.assertEqual(self.rt.py(self.e('{ WCOverlays.texture("eyebrows", 1) }')), {1: 12, 3: 'm'})
        self.assertEqual(self.rt.py(self.e('{ WCOverlays.texture("eyebrows", 6) }')), {1: 4, 3: 'f'})
        seen = set()
        for style in range(1, 25):
            t = self.rt.py(self.e('{ WCOverlays.texture("eyebrows", %d) }' % style))
            seen.add((t[3], t[1]))
        self.assertEqual(seen, {('m', i) for i in range(16)} | {('f', i) for i in range(8)})

    def test_makeup_styles_are_the_cells_of_one_sheet(self):
        e = self.e
        self.assertEqual((e('WCOverlays.byId.eyeliners.styles'), e('WCOverlays.byId.shadows.styles'),
                          e('WCOverlays.byId.lipsticks.styles')), (16, 6, 7))
        self.assertEqual(self.rt.py(e('{ WCOverlays.texture("eyeliners", 1) }')), {1: 0, 2: 0})   # the old single style
        self.assertEqual(self.rt.py(e('{ WCOverlays.texture("eyeliners", 9) }')), {1: 0, 2: 13})
        self.assertEqual(self.rt.py(e('{ WCOverlays.texture("lipsticks", 7) }')), {1: 0, 2: 7})
        self.assertIsNone(e('WCOverlays.texture("shadows", 7)'))
        self.assertEqual((e('WCOverlays.byId.foundation.tints'), e('WCOverlays.byId.shadows.tints'),
                          e('WCOverlays.byId.blush.tints')), (2, 3, 1))


class OverlayPayloadTests(unittest.TestCase):
    def setUp(self):
        self.rt = make_client()
        self.e = self.rt.eval
        self.run = self.rt.run

    def payload(self, layer, o):
        self.run('lib, pay = Appearance.Overlays.payload("%s", %s, "male")' % (layer, o))
        return self.rt.py(self.e('pay'))

    def test_texture_set_sheet_cell_and_extra_tints(self):
        self.assertEqual(self.payload('eyebrows', '{ style = 6, color = 3, opacity = 1 }'),
                         {'id': 4, 'sexe': 'f', 'opacity': 1.0, 'palette': 'metaped_tint_hair', 'tint0': 2})
        self.assertEqual(self.payload('eyeliners', '{ style = 2, color = 1, opacity = 0.5 }')['sheetGrid'], 1)
        p = self.payload('shadows', '{ style = 1, color = 2, opacity = 1, color2 = 5, color3 = 9 }')
        self.assertEqual((p['tint0'], p['tint1'], p['tint2']), (1, 4, 8))
        self.assertNotIn('tint1', self.payload('blush', '{ style = 1, color = 2, opacity = 1, color2 = 5 }'))

    def test_stacked_scars_are_one_texture_layer_each(self):
        p = self.payload('scars', '{ style = 1, color = 1, opacity = 1, extra = { { style = 3, opacity = 0.4 }, { style = 7 } } }')
        self.assertEqual(len(p), 3)
        self.assertEqual((p[1]['id'], p[2]['id'], p[3]['id']), (0, 2, 6))
        self.assertEqual(p[2]['opacity'], 0.4)

    def test_eyebrows_that_follow_the_hair_take_its_tints(self):
        self.run('''w.component.getCategoryTint = function(ped, category, inTable)
                return { palette = 1, tint0 = 10, tint1 = 20, tint2 = 30 } end
            ped = makePed("mp_male"); app = AppearanceSchema.default("male")
            app.overlays.eyebrows.matchHair = true
            Appearance.Overlays.apply(ped, app)
            brows = Appearance.Overlays.applied(ped).eyebrow''')
        self.assertEqual((self.e('brows.tint0'), self.e('brows.tint1'), self.e('brows.tint2')), (10, 20, 30))
        self.assertEqual(self.e('brows.palette'), 'metaped_tint_hair')
        # bald: the colour chosen in the panel is drawn
        self.run('app.hair.style = 0; Appearance.Overlays.apply(ped, app); brows = Appearance.Overlays.applied(ped).eyebrow')
        self.assertEqual(self.e('brows.tint0'), 0)


class PipelineTests(unittest.TestCase):
    def setUp(self):
        self.rt = make_client()
        self.e = self.rt.eval
        self.run = self.rt.run
        self.run('ped = makePed("mp_male"); app = AppearanceSchema.default("male")')

    def outfits(self):
        return [self.e('Log[%d].args[2]' % i) for i in range(1, int(self.e('#Log')) + 1)
                if self.e('Log[%d].op' % i) == 'EquipMetaPedOutfit']

    def test_the_build_is_equipped_before_the_waist(self):
        self.run('app.body.build = 2; clearLog(); Appearance.RestoreCharacter(ped, app)')
        self.assertEqual(self.outfits(), [self.e('AppearanceSchema.BODY_BUILDS[2]'), self.e('AppearanceSchema.WAIST_TYPES[11]')])
        self.run('app.body.build = nil; clearLog(); Appearance.RestoreCharacter(ped, app)')
        self.assertEqual(self.outfits(), [self.e('AppearanceSchema.WAIST_TYPES[11]')])   # no build: as before

    def test_a_build_change_starts_from_the_preset(self):
        self.run('b = WCUtil.copy(app); b.body.build = 5; clearLog(); Appearance.ApplyDiff(ped, app, b)')
        self.assertGreater(self.e('count("preset")'), 0)

    def test_the_eye_tint_goes_with_the_eyes(self):
        self.run('''b = WCUtil.copy(app); b.head.eyesTint = { tint0 = 3, tint1 = 4, tint2 = 5 }
            clearLog(); Appearance.ApplyDiff(ped, app, b)''')
        data = self.rt.py(self.e('Log[indexOf("component.apply")].args[3]'))
        self.assertEqual((data['palette'], data['tint0'], data['tint2']), ('metaped_tint_eye', 3, 5))


EDITOR_EXTRA = r"""
AnimCalls = {}
function RequestAnimDict() end
function HasAnimDictLoaded() return 1 end
function IsEntityPlayingAnim() return false end
function TaskPlayAnim(ped, dict, clip, ...) AnimCalls[#AnimCalls + 1] = clip end
function lastCam(name)
    for i = #CamCalls, 1, -1 do if CamCalls[i].name == name then return CamCalls[i].args[1] end end
end
"""


class EditorFeatureTests(EditorBase):
    def setUp(self):
        super().setUp()
        self.rt.run(EDITOR_EXTRA)
        self.e = self.rt.eval

    def action(self, **data):
        data.setdefault('id', self.e('sid()'))
        return self.rt.g.nui('editor:action', self.rt.table(data))

    def camera(self, **data):
        data.setdefault('id', self.e('sid()'))
        return self.rt.g.nui('editor:camera', self.rt.table(data))

    def test_hide_clothes_is_a_view_of_the_look(self):
        self.e("openEditor('creator', 'male', { identity = {} })")
        equipped = len(self.rt.py(self.e('WCEditor.session().working.clothing.equipped')))
        self.assertGreater(equipped, 0)
        r = self.camera(hide=True)
        self.assertTrue(r.ok)
        self.assertTrue(r.hidden)
        shown = self.e('Rendered[#Rendered].after')
        self.assertEqual(len(self.rt.py(shown.clothing.equipped)), 0)
        self.assertEqual(shown.hair.style, 0)
        # the look itself keeps every piece; the next payload reports the view
        self.assertEqual(len(self.rt.py(self.e('WCEditor.session().working.clothing.equipped'))), equipped)
        self.assertTrue(self.action(op='set', control='body.weight', value=5).payload.hidden)
        self.assertEqual(len(self.rt.py(self.e('Rendered[#Rendered].after.clothing.equipped'))), 0)
        # the save puts the clothes back on before the commit
        self.action(op='save', identity=self.rt.table({'firstname': 'John', 'lastname': 'Smith', 'dob': '1990-05-01'}))
        self.assertGreater(len(self.rt.py(self.e('Rendered[#Rendered].after.clothing.equipped'))), 0)

    def test_a_clothing_change_shows_the_clothes_again(self):
        self.e("openEditor('creator', 'male', { identity = {} })")
        self.camera(hide=True)
        r = self.action(op='invoke', control='clothing.boots.remove')
        self.assertTrue(r.ok, r.message)
        self.assertIsNone(r.payload.hidden)
        self.assertGreater(len(self.rt.py(self.e('Rendered[#Rendered].after.clothing.equipped'))), 0)

    def test_hide_is_creator_only(self):
        self.e("openEditor('barber', 'male', {})")
        self.assertFalse(self.camera(hide=True).ok)
        self.assertIsNone(self.e('lastPayload().canHide'))

    def test_depth_controls_turn_the_character_to_its_profile(self):
        self.e("openEditor('creator', 'male', { identity = {} })")
        self.action(op='set', control='morph.jawDepth', value=0.5)
        self.assertEqual(self.e('lastCam("pose")'), 'profile')
        self.action(op='set', control='morph.jawWidth', value=0.5)
        self.assertEqual(self.e('lastCam("pose")'), 'front')
        self.rt.run('CamCalls = {}')
        self.action(op='set', control='body.weight', value=3)       # not a morph: the character stays put
        self.assertIsNone(self.e('lastCam("pose")'))
        self.action(op='preview', values=self.rt.table({'morph.earsAngle': 0.2}))
        self.assertEqual(self.e('lastCam("pose")'), 'profile')
        self.camera(preset='face')                                   # a new view faces forward again
        self.assertEqual(self.e('lastCam("pose")'), 'front')

    def test_the_teeth_view_opens_the_mouth(self):
        self.e("openEditor('creator', 'male', { identity = {} })")
        self.camera(preset='teeth')
        self.rt.run('tick(0); tick(100); tick(100)')
        clips = self.rt.py(self.e('AnimCalls'))
        self.assertEqual(clips[1], 'Face_Dentistry_In')
        self.assertIn('Face_Dentistry_Loop', clips.values())
        self.camera(preset='face')
        self.rt.run('tick(0); tick(100)')
        self.assertEqual(self.e('AnimCalls[#AnimCalls]'), 'Face_Dentistry_Out')

    def test_a_draft_is_resumed_and_reset_still_means_the_start(self):
        self.e("""(function()
            local draft = AppearanceSchema.default('male'); draft.body.weight = 5
            return openEditor('creator', 'male', { identity = {}, working = draft })
        end)()""")
        self.assertEqual(self.e('WCEditor.session().working.body.weight'), 5)
        self.assertEqual(self.e('WCEditor.session().saved.body.weight'), 11)
        self.assertTrue(self.e('WCEditor.dirty()'))
        self.assertTrue(self.action(op='reset').ok)
        self.assertEqual(self.e('WCEditor.session().working.body.weight'), 11)

    def test_a_keep_draft_cancel_hands_back_the_look_and_the_typed_name(self):
        self.e("""openEditor('creator', 'male', { identity = {}, keepDraft = true, keepCamera = true,
            backLabel = 'تغيير الجنس', onCancel = function(w, id) Draft = { w = w, id = id } end })""")
        payload = self.e('lastPayload()')
        self.assertEqual(payload.backLabel, 'تغيير الجنس')
        self.assertTrue(payload.backDirect)
        self.action(op='set', control='body.weight', value=5)
        self.rt.run('Rendered = {}; CamCalls = {}')
        r = self.action(op='cancel', identity=self.rt.table({'firstname': 'Ann', 'lastname': 'Lee', 'dob': ''}))
        self.assertTrue(r.ok)
        self.assertEqual(self.e('Draft.w.body.weight'), 5)
        self.assertEqual(self.e('Draft.id.firstname'), 'Ann')
        # the ped keeps the draft (no restore of the saved look) and the camera is left to the creator
        self.assertEqual(self.e('#Rendered'), 0)
        self.assertIsNone(self.e('lastCam("close")'))


class TreeFeatureTests(EditorBase):
    def node(self, control):
        # the control node (a group can share the id of the control it hosts: face.teeth), in the
        # tree of the latest answer
        payload = self.last if self.last is not None else self.e('lastPayload()')
        self.rt.run('function findControl(node, id) if node.control == id then return node end '
                    'for _, c in ipairs(node.children or {}) do local f = findControl(c, id) if f then return f end end end')
        return self.rt.g.findControl(payload.tree, control)

    def setUp(self):
        super().setUp()
        self.e = self.rt.eval
        self.last = None

    def action(self, **data):
        data.setdefault('id', self.e('sid()'))
        r = self.rt.g.nui('editor:action', self.rt.table(data))
        if r.payload is not None:
            self.last = r.payload
        return r

    def test_skin_tones_lightest_first_with_colour_chips(self):
        self.e("openEditor('creator', 'male', { identity = {} })")
        options = lua_list(self.node('skin.tone').options)
        order = [v for v in self.rt.py(self.e('Config.Swatches.skinOrder')).values()]
        values = [o.value for o in options]
        self.assertEqual(values, [t for t in order if t in values])
        for o in options:
            self.assertRegex(o.swatch, r'^#[0-9a-f]{6}$')

    def test_the_body_build_choice(self):
        self.e("openEditor('creator', 'male', { identity = {} })")
        self.assertEqual([o.value for o in lua_list(self.node('body.shape').options)], [0, 1, 2, 3, 4, 5])
        self.assertTrue(self.action(op='set', control='body.shape', value=3).ok)
        self.assertEqual(self.e('WCEditor.session().working.body.build'), 3)
        self.assertTrue(self.action(op='set', control='body.shape', value=0).ok)
        self.assertIsNone(self.e('WCEditor.session().working.body.build'))

    def test_the_custom_eye_tint(self):
        self.e("openEditor('creator', 'male', { identity = {} })")
        self.assertTrue(self.node('eyes.tint.tint0').disabled)
        self.assertTrue(self.action(op='set', control='eyes.tint', value=1).ok)
        self.assertTrue(self.action(op='set', control='eyes.tint.tint1', value=300).ok)
        self.assertEqual(self.e('WCEditor.session().working.head.eyesTint.tint1'), 127)   # the palette's range
        self.assertTrue(self.action(op='set', control='eyes.tint', value=0).ok)
        self.assertIsNone(self.e('WCEditor.session().working.head.eyesTint'))

    def test_makeup_styles_are_named_and_carry_their_extra_tints(self):
        self.e("openEditor('creator', 'female', { identity = {} })")
        options = lua_list(self.node('overlay.eyeliners.style').options)
        self.assertEqual(len(options), 17)
        self.assertEqual(options[1].label, 'كحل بسيط')
        self.assertIsNotNone(self.node('overlay.shadows.color3'))
        self.assertIsNotNone(self.node('overlay.lipsticks.color2'))
        self.assertIsNone(self.node('overlay.lipsticks.color3'))
        self.assertIsNone(self.node('overlay.blush.color2'))
        self.action(op='set', control='overlay.lipsticks.style', value=3)
        self.assertTrue(self.action(op='set', control='overlay.lipsticks.color2', value=9).ok)
        self.assertEqual(self.e('WCEditor.session().working.overlays.lipsticks.color2'), 9)
        # a new style keeps the layer's colours
        self.action(op='set', control='overlay.lipsticks.style', value=5)
        self.assertEqual(self.e('WCEditor.session().working.overlays.lipsticks.color2'), 9)

    def test_eyebrows_can_follow_the_hair(self):
        self.e("openEditor('creator', 'male', { identity = {} })")
        self.assertFalse(self.node('overlay.eyebrows.color').disabled)
        self.assertTrue(self.action(op='set', control='overlay.eyebrows.match', value=1).ok)
        self.assertTrue(self.e('WCEditor.session().working.overlays.eyebrows.matchHair'))
        self.assertTrue(self.node('overlay.eyebrows.color').disabled)          # the hair decides the colour
        self.assertTrue(self.action(op='set', control='overlay.eyebrows.match', value=0).ok)
        self.assertIsNone(self.e('WCEditor.session().working.overlays.eyebrows.matchHair'))

    def test_scars_stack(self):
        self.e("openEditor('creator', 'male', { identity = {} })")
        self.assertTrue(self.node('overlay.scars.extra1.style').disabled)      # no first scar yet
        self.action(op='set', control='overlay.scars.style', value=2)
        self.assertTrue(self.node('overlay.scars.extra2.style').disabled)      # one at a time
        self.assertTrue(self.action(op='set', control='overlay.scars.extra1.style', value=5).ok)
        self.assertTrue(self.action(op='set', control='overlay.scars.extra2.style', value=7).ok)
        self.assertEqual(self.e('#WCEditor.session().working.overlays.scars.extra'), 2)
        self.assertTrue(self.action(op='set', control='overlay.scars.extra1.style', value=0).ok)
        self.assertEqual(self.e('WCEditor.session().working.overlays.scars.extra[1].style'), 7)

    def test_styles_carry_the_games_names(self):
        self.e("openEditor('creator', 'male', { identity = {} })")
        teeth = lua_list(self.node('face.teeth').options)
        self.assertEqual(teeth[0].label, 'الأسنان المتينة')
        hair = lua_list(self.node('hair.style').options)
        self.assertEqual(hair[1].label, 'مفروق يسارًا بعناية')          # CLOTHING_ITEM_M_HAIR_001
        colours = lua_list(self.node('hair.color').options)
        self.assertTrue(all(o.swatch for o in colours))
        brows = lua_list(self.node('overlay.eyebrows.style').options)
        self.assertEqual(brows[1].label, 'حاجبان حادّان')                # m_012 (sharp)

    def test_the_height_reads_in_metres_or_feet_measured_on_the_ped(self):
        # the game measures the ped at the scale it wears (1.89 m at 1.05): 1.8 m at scale 1.0
        self.rt.run('WCNative = { ped = { height = function(ped) return Measured end } }; Measured = 1.89')
        self.e("openEditor('creator', 'male', { identity = {}, app = (function() local a = AppearanceSchema.default('male'); a.body.height = 1.05; return a end)() })")
        display = self.node('body.height').display
        self.assertAlmostEqual(display.scale, 1.8, places=6)
        self.assertEqual((display.decimals, display.format), (2, '%s م'))
        # the review lists the same height
        self.rt.run('''function findKind(node, kind) if node.kind == kind then return node end
            for _, c in ipairs(node.children or {}) do local f = findKind(c, kind) if f then return f end end end''')
        items = lua_list(self.rt.eval('findKind(WCEditorTree.build(WCEditor.session()), "review").items'))
        self.assertEqual({i.label: i.value for i in items}['الطول'], '1.89 م')
        self.rt.run('Config.Creator.heightUnit = "ft"')
        display = self.rt.eval('WCEditorTree.heightDisplay(WCEditor.session())')
        self.assertAlmostEqual(display.scale, 1.8 * 3.28084, places=4)
        self.assertEqual(display.format, '%s قدم')
        # no measure (an implausible answer, no ped yet) or the unit off: the plain ×100 scale, as before
        for setup in ('Config.Creator.heightUnit = "m"; Measured = nil', 'Measured = 5.0',
                      'Measured = 1.89; Config.Creator.heightUnit = false'):
            self.rt.run(setup)
            display = self.rt.eval('WCEditorTree.heightDisplay(WCEditor.session())')
            self.assertEqual((display.scale, display.decimals, display.format), (100, 1, None), setup)


class HeightNativeTests(unittest.TestCase):
    def test_the_ped_height_is_read_by_hash_and_bounded(self):
        rt = Runtime().load_shared()
        rt.run('''invoked = {}
            Citizen.InvokeNative = function(hash, ...) invoked[#invoked + 1] = hash return Answer end
            DoesEntityExist = function(e) return e == 77 and 1 or false end
            IsEntityAPed = function(e) return e == 77 end''')
        rt.load('client/natives/metaped.lua', 'client/natives/ped.lua')
        rt.run('Answer = 1.83')
        self.assertAlmostEqual(rt.eval('WCNative.ped.height(77)'), 1.83)
        self.assertEqual(rt.eval('invoked[1]'), 0x1D491CCF7211FB74)
        for answer in ('0.0', '12.0', '0/0', 'nil'):
            rt.run('Answer = %s' % answer)
            self.assertIsNone(rt.eval('WCNative.ped.height(77)'), answer)
        rt.run('invoked = {}')
        self.assertIsNone(rt.eval('WCNative.ped.height(0)'))           # no ped: never invoked
        self.assertEqual(rt.eval('#invoked'), 0)


class ApiBuildTests(unittest.TestCase):
    def test_the_bridge_skin_carries_the_build_both_ways(self):
        rt = Runtime().load_server_core()
        rt.load('server/api.lua')
        rt.run('app = AppearanceSchema.default("male"); app.body.build = 2; skin = WCApi.standardSkin(app)')
        self.assertEqual(rt.eval('skin.bodyType'), rt.eval('AppearanceSchema.BODY_BUILDS[2]'))
        rt.run('app.body.build = nil; skin = WCApi.standardSkin(app)')
        self.assertIsNone(rt.eval('skin.bodyType'))


if __name__ == '__main__':
    unittest.main()
