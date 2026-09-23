"""Client infrastructure: WCPreviewEnv enter/exit symmetry and resource-stop cleanup, WCCamera
presets / pick / close, CreatorScene preview peds, WCState locks and the locale / UI helpers."""
import unittest

from test_client_infra_support import make_client


def snapshot(rt, ped='MyPed'):
    return rt.py(rt.eval('''(function(p) local s = Peds[p]
        return { frozen = s.frozen == true, invincible = s.invincible == true, heading = s.heading,
                 x = s.coords.x, y = s.coords.y, z = s.coords.z } end)(%s)''' % ped))


class PreviewEnvTests(unittest.TestCase):
    def setUp(self):
        self.rt = make_client()
        self.e = self.rt.eval
        self.run = self.rt.run

    def test_enter_exit_symmetry(self):
        before = snapshot(self.rt)
        self.run('''clearLog(); entered = WCPreviewEnv.enter({ invincible = true, time = { 12, 30 }, weather = "sunny",
            coords = { 5.0, 6.0, 7.0, 180.0 } })''')
        self.assertTrue(self.e('entered'))
        self.assertTrue(self.e('WCPreviewEnv.active()'))
        during = snapshot(self.rt)
        self.assertTrue(during['frozen'] and during['invincible'])
        self.assertEqual((during['x'], during['y'], during['z'], during['heading']), (5.0, 6.0, 7.0, 180.0))
        self.assertEqual(self.e('count("TriggerEvent:hud:client:Hideui")'), 1)
        self.assertEqual(self.e('count("HidePedWeapons")'), 1)
        self.assertEqual(self.e('count("NetworkClockTimeOverride")'), 1)
        self.assertEqual(self.e('count("SetWeatherType")'), 1)
        # a second enter does nothing
        self.assertFalse(self.e('WCPreviewEnv.enter()'))
        # the control thread disables controls while active
        self.run('clearLog(); tick(0)')
        self.assertGreaterEqual(self.e('count("DisableAllControlActions")'), 1)

        self.run('clearLog(); left = WCPreviewEnv.exit()')
        self.assertTrue(self.e('left'))
        self.assertEqual(snapshot(self.rt), before)
        self.assertEqual(self.e('count("TriggerEvent:hud:client:showui")'), 1)
        self.assertEqual(self.e('count("NetworkClearClockTimeOverride")'), 1)
        self.assertEqual(self.e('count("ClearOverrideWeather")'), 1)
        self.assertFalse(self.e('WCPreviewEnv.active()'))
        # idempotent, and the thread has stopped
        self.run('clearLog()')
        self.assertFalse(self.e('WCPreviewEnv.exit()'))
        self.run('tick(0); tick(0)')
        self.assertEqual(self.e('#Log'), 0)

    def test_exit_only_undoes_what_enter_changed(self):
        self.run('''Peds[MyPed].frozen = true; clearLog()
            WCPreviewEnv.enter({ freeze = false, hud = false, holster = false, controls = false })''')
        self.run('clearLog(); WCPreviewEnv.exit()')
        self.assertEqual(self.e('count("FreezeEntityPosition")'), 0)
        self.assertEqual(self.e('count("TriggerEvent:hud:client:showui")'), 0)
        self.assertEqual(self.e('count("NetworkClearClockTimeOverride")'), 0)
        self.assertEqual(self.e('count("ClearOverrideWeather")'), 0)
        self.assertTrue(self.e('Peds[MyPed].frozen'))
        # no per-frame thread without controls or HUD
        self.run('WCPreviewEnv.enter({ hud = false, controls = false }); clearLog(); tick(0)')
        self.assertEqual(self.e('count("DisableAllControlActions")'), 0)
        self.run('WCPreviewEnv.exit()')

    def test_resource_stop_cleans_up(self):
        self.run('''WCPreviewEnv.enter({}); WCCamera.open(MyPed, "head"); SetEntityVisible(MyPed, false)
            clearLog(); fireEvent("onResourceStop", nil, "w_creators")''')
        self.assertFalse(self.e('WCPreviewEnv.active()'))
        self.assertFalse(self.e('WCCamera.isOpen()'))
        self.assertFalse(self.e('Peds[MyPed].frozen'))
        self.assertTrue(self.e('Peds[MyPed].visible'))
        self.assertEqual(self.e('count("SetNuiFocus")'), 1)
        self.assertEqual(self.e('next(Cams)'), None)
        self.assertGreaterEqual(self.e('count("TriggerEvent:hud:client:showui")'), 1)
        # another resource's stop does nothing
        self.run('WCPreviewEnv.enter({}); clearLog(); fireEvent("onResourceStop", nil, "other")')
        self.assertTrue(self.e('WCPreviewEnv.active()'))
        self.assertEqual(self.e('#Log'), 0)

    def test_radar_is_left_to_w_lib(self):
        # w_lib decides the radar (HUD wish, radar mode, custom minimap): never DisplayRadar(true) here
        self.run('WCPreviewEnv.enter({}); tick(0); clearLog(); WCPreviewEnv.exit(); tick(0)')
        self.assertEqual(self.e('count("setRadarVisible")'), 1)
        self.assertTrue(self.e('Log[indexOf("setRadarVisible")].args[1]'))
        self.assertEqual(self.e('count("DisplayRadar")'), 0)
        self.assertEqual(self.e('count("DisplayHud")'), 1)   # the game HUD was suppressed per frame
        self.run('WCPreviewEnv.enter({}); clearLog(); fireEvent("onResourceStop", nil, "w_creators")')
        self.assertEqual(self.e('count("DisplayRadar")'), 0)
        # an environment without HUD changes gives nothing back
        self.run('WCPreviewEnv.enter({ hud = false }); clearLog(); WCPreviewEnv.exit()')
        self.assertEqual(self.e('count("DisplayHud") + count("setRadarVisible")'), 0)

    def test_resource_stop_mid_transition_lifts_the_fade_and_the_curtain(self):
        self.run('''ResourceStates.w_loading = "started"; StartFade(300, "spawn"); ScreenFadedOut = true
            clearLog(); fireEvent("onResourceStop", nil, "w_creators")''')
        self.assertEqual(self.e('count("DoScreenFadeIn")'), 1)
        self.assertEqual(self.e('Log[indexOf("DoScreenFadeIn")].args[1]'), 0)
        self.assertEqual(self.e('count("w_loading:Hide")'), 1)
        self.assertFalse(self.e('WCurtain.held()'))

    def test_resource_stop_after_a_finished_transition_leaves_the_screen_alone(self):
        # another resource's fade (or a completed one of ours) is not touched
        self.run('''ResourceStates.w_loading = "started"; StartFade(300); EndFade(300); ScreenFadedOut = true
            clearLog(); fireEvent("onResourceStop", nil, "w_creators")''')
        self.assertEqual(self.e('count("DoScreenFadeIn") + count("w_loading:Hide")'), 0)

    def test_resource_stop_without_a_flow_leaves_the_player_alone(self):
        self.run('Peds[MyPed].frozen = true; clearLog(); fireEvent("onResourceStop", nil, "w_creators")')
        self.assertTrue(self.e('Peds[MyPed].frozen'))
        self.assertEqual(self.e('count("RenderScriptCams")'), 0)


class CameraTests(unittest.TestCase):
    def setUp(self):
        self.rt = make_client()
        self.e = self.rt.eval
        self.run = self.rt.run

    def test_presets_open_focus_and_interpolation(self):
        presets = ('fullBody', 'upperBody', 'lowerBody', 'head', 'face', 'eyes', 'hair', 'facialHair',
                   'hands', 'feet', 'accessories')
        for p in presets:
            self.assertIsNotNone(self.e('WCCamera.PRESETS.%s' % p), p)
        self.run('clearLog(); ok = WCCamera.open(MyPed)')
        self.assertTrue(self.e('ok'))
        self.assertEqual(self.e('WCCamera.current()'), 'fullBody')
        self.assertEqual(self.e('count("CreateCam")'), 2)
        self.assertEqual(self.e('count("SetCamActive")'), 1)
        self.run('clearLog(); WCCamera.focus("head")')
        self.assertEqual(self.e('count("SetCamActiveWithInterp")'), 1)
        self.assertEqual(self.e('count("CreateCam")'), 0)
        self.assertEqual(self.e('WCCamera.current()'), 'head')
        # same preset without force: nothing moves; unknown preset ignored; legacy alias accepted
        self.run('clearLog(); WCCamera.focus("head"); bad = WCCamera.focus("nowhere")')
        self.assertEqual(self.e('#Log'), 0)
        self.assertFalse(self.e('bad'))
        self.run('WCCamera.focus("boot")')
        self.assertEqual(self.e('WCCamera.current()'), 'feet')

    def test_rotate_keeps_the_view_and_zoom_is_clamped(self):
        self.run('WCCamera.open(MyPed, "upperBody"); clearLog(); WCCamera.rotate(45)')
        self.assertEqual(self.e('Peds[MyPed].heading'), 135.0)
        self.assertEqual(self.e('count("SetCamCoord")'), 0)
        self.run('clearLog(); for i = 1, 20 do WCCamera.zoom(10) end')
        fov = self.e('(function() local f; for _, e in ipairs(Log) do if e.op == "SetCamFov" then f = e.args[2] end end return f end)()')
        self.assertEqual(fov, self.e('WCCamera.FOV_MIN'))
        self.run('clearLog(); WCCamera.reset()')
        self.assertEqual(self.e('WCCamera.current()'), 'fullBody')
        self.assertEqual(self.e('Log[indexOf("SetCamFov")].args[2]'), self.e('WCCamera.PRESETS.fullBody.fov'))

    def test_rtl_mirrors_the_side(self):
        def cam_x():
            return self.e('(function() local x; for _, e in ipairs(Log) do if e.op == "SetCamCoord" then x = e.args[2] end end return x end)()')
        self.run('Peds[MyPed].heading = 0.0; LocaleKey = "en"; clearLog(); WCCamera.open(MyPed)')
        ltr = cam_x()
        self.run('WCCamera.close(); LocaleKey = "ar"; clearLog(); WCCamera.open(MyPed)')
        rtl = cam_x()
        self.assertAlmostEqual(ltr, -rtl, places=5)

    def test_pick_maps_parts_to_presets(self):
        self.run('WCCamera.open(MyPed)')
        for part, preset in (('eyes', 'eyes'), ('head', 'head'), ('body', 'upperBody'),
                             ('pant', 'lowerBody'), ('boot', 'feet')):
            self.run('PickPart = "%s"' % part)
            self.assertEqual(self.e('WCCamera.pick(0.5, 0.2, 1.7)'), preset)
            self.assertEqual(self.e('WCCamera.current()'), preset)
        self.run('PickPart = nil')
        self.assertIsNone(self.e('WCCamera.pick(0.1, 0.1)'))
        self.assertEqual(self.e('WCCamera.current()'), 'feet')

    def test_close_destroys_both_cameras(self):
        self.run('WCCamera.open(MyPed); WCCamera.focus("head"); WCCamera.focus("feet"); clearLog(); WCCamera.close()')
        self.assertEqual(self.e('count("DestroyCam")'), 2)
        self.assertEqual(self.e('next(Cams)'), None)
        self.assertEqual(self.e('Log[1].op'), 'RenderScriptCams')
        self.assertFalse(self.e('Log[1].args[1]'))
        self.assertEqual(self.e('count("ClearFocus")'), 1)
        self.assertFalse(self.e('WCCamera.isOpen()'))
        self.assertIsNone(self.e('WCCamera.current()'))
        self.assertFalse(self.e('WCCamera.focus("head")'))
        # closing again touches nothing
        self.run('clearLog(); WCCamera.close()')
        self.assertEqual(self.e('#Log'), 0)
        # reopening creates fresh cameras
        self.run('clearLog(); WCCamera.open(MyPed)')
        self.assertEqual(self.e('count("CreateCam")'), 2)

    def test_open_on_missing_ped_fails(self):
        self.assertFalse(self.e('WCCamera.open(424242)'))
        self.assertFalse(self.e('WCCamera.isOpen()'))


class SceneTests(unittest.TestCase):
    def setUp(self):
        self.rt = make_client()
        self.e = self.rt.eval
        self.run = self.rt.run
        self.run('app = AppearanceSchema.default("female")')

    def test_create_registers_positions_renders_and_shows(self):
        self.run('clearLog(); ped, err = CreatorScene.create(nil, Config.Scene.selectionPed, app)')
        self.assertIsNotNone(self.e('ped'), self.e('err'))
        self.assertEqual(self.e('GetEntityModel(ped) == GetHashKey("mp_female")'), True)
        order = [self.e('indexOf("%s")' % op) for op in
                 ('entity.create', 'SetEntityVisible', 'callback:w_creators:scene:registerPed', 'placeOnGround',
                  'preset', 'updateVariation')]
        order.append(self.e('(function() for i, e in ipairs(Log) do if e.op == "SetEntityVisible" and e.args[2] then return i end end end)()'))
        self.assertFalse(self.e('Log[indexOf("SetEntityVisible")].args[2]'))  # hidden until rendered
        self.assertTrue(all(order), order)
        self.assertEqual(order, sorted(order))
        self.assertTrue(self.e('Peds[ped].visible'))
        self.assertEqual(self.rt.py(self.e('CreatorScene.peds()')), {1: self.e('ped')})

    def test_create_failure_deletes_the_ped(self):
        self.run('''CallbackResults = { ["w_creators:scene:registerPed"] = { ok = false, code = "TOO_FAR" } }
            clearLog(); ped, err = CreatorScene.create("mp_female", Config.Scene.selectionPed, app)''')
        self.assertIsNone(self.e('ped'))
        self.assertEqual(self.e('err'), 'TOO_FAR')
        self.assertEqual(self.e('count("entity.delete")'), 1)
        self.assertEqual(self.rt.py(self.e('CreatorScene.peds()')), {})
        # model mismatch between the model and the appearance
        self.run('CallbackResults = nil; ped, err = CreatorScene.create("mp_male", Config.Scene.selectionPed, app)')
        self.assertIsNone(self.e('ped'))
        self.assertEqual(self.e('err'), 'MODEL_MISMATCH')
        self.assertEqual(self.e('select(2, CreatorScene.create(nil, "bad", app))'), 'INVALID_PAYLOAD')

    def test_cleanup_destroy_and_never_the_player(self):
        self.run('''a = CreatorScene.create(nil, Config.Scene.selectionPed, app)
            stray = makePed("mp_male", Config.Scene.anchor[1], Config.Scene.anchor[2], Config.Scene.anchor[3])
            far = makePed("mp_male", 9000.0, 0.0, 0.0)
            Peds[MyPed].coords = vector3(Config.Scene.anchor[1], Config.Scene.anchor[2], Config.Scene.anchor[3])
            removed = CreatorScene.cleanup()''')
        self.assertEqual(self.e('removed'), 2)
        self.assertFalse(self.e('DoesEntityExist(a)'))
        self.assertFalse(self.e('DoesEntityExist(stray)'))
        self.assertTrue(self.e('DoesEntityExist(far)'))
        self.assertTrue(self.e('DoesEntityExist(MyPed)'))
        self.assertFalse(self.e('CreatorScene.destroy(MyPed)'))

    def test_isolate_and_release(self):
        self.run('CallbackResults = { ["w_creators:scene:prepare"] = { ok = false, code = "BUSY" } }')
        self.assertEqual(self.e('select(2, CreatorScene.isolate())'), 'BUSY')
        self.assertFalse(self.e('CreatorScene.isIsolated()'))
        self.run('CallbackResults = nil; ok = CreatorScene.isolate(); CreatorScene.load(); clearLog(); CreatorScene.release()')
        self.assertTrue(self.e('ok'))
        self.assertEqual(self.e('count("callback:w_creators:scene:release")'), 1)
        self.assertEqual(self.e('count("NetworkClearClockTimeOverride")'), 1)
        self.assertFalse(self.e('CreatorScene.isLoaded()'))
        self.run('clearLog(); CreatorScene.release()')
        self.assertEqual(self.e('#Log'), 0)

    def test_load_moves_the_player_into_the_room(self):
        self.run('clearLog(); arrived = CreatorScene.load()')
        self.assertTrue(self.e('arrived'))
        self.assertEqual(self.e('count("loadSphere")'), 1)
        self.assertEqual(self.e('Peds[MyPed].coords.x'), self.e('Config.Scene.anchor[1]'))
        self.run('clearLog(); CreatorScene.drawLights()')
        self.assertEqual(self.e('count("DrawLightWithRange")'), self.e('#Config.Scene.lights'))

    def test_load_retries_at_an_interval(self):
        # neither the managed teleport nor the direct move lands: one attempt per TELEPORT_RETRY ms
        self.run('''SetEntityCoords = function(...) Log[#Log + 1] = { op = "SetEntityCoords", args = { ... } } end
            clearLog(); t0 = GetGameTimer(); arrived = CreatorScene.load()''')
        self.assertFalse(self.e('arrived'))
        attempts = self.e('count("StartPlayerTeleport")')
        expected = self.e('CreatorScene.TELEPORT_TIMEOUT // CreatorScene.TELEPORT_RETRY')
        self.assertGreaterEqual(attempts, expected - 2)
        self.assertLessEqual(attempts, expected + 2)

    def test_room_maps_are_unloaded_on_the_final_exit_and_on_stop(self):
        maps = self.rt.py(self.e('Config.Scene.imaps'))
        self.run('IplInactive[Config.Scene.imaps[1]] = true; clearLog(); CreatorScene.load()')
        self.assertEqual(self.e('count("RequestIplByHash")'), 1)
        self.run('IplInactive = {}; clearLog(); CreatorScene.release()')
        self.assertEqual(self.e('count("RemoveIplByHash")'), 0)   # a plain release keeps the room
        self.run('clearLog(); CreatorScene.release({ unload = true })')
        self.assertEqual(self.e('count("RemoveIplByHash")'), 1)   # only the map load() requested
        self.assertEqual(self.e('Log[indexOf("RemoveIplByHash")].args[1]'), maps[1])
        self.run('clearLog(); CreatorScene.release({ unload = true })')
        self.assertEqual(self.e('count("RemoveIplByHash")'), 0)
        # resource stop: kept while the player stands in the floating room, removed once out of it
        self.run('''IplInactive[Config.Scene.imaps[2]] = true; CreatorScene.load(); IplInactive = {}
            clearLog(); fireEvent("onResourceStop", nil, "w_creators")''')
        self.assertEqual(self.e('count("RemoveIplByHash")'), 0)
        self.run('''Peds[MyPed].coords = vector3(0.0, 0.0, 0.0)
            clearLog(); fireEvent("onResourceStop", nil, "w_creators")''')
        self.assertEqual(self.e('count("RemoveIplByHash")'), 1)
        self.assertEqual(self.e('Log[indexOf("RemoveIplByHash")].args[1]'), maps[2])

    def test_arm_and_idle(self):
        self.run('p = makePed("mp_male"); clearLog(); CreatorScene.arm(p, "male"); CreatorScene.idle(p, true)')
        self.assertEqual(self.e('Log[indexOf("giveWeapon")].args[2]'), self.e('GetHashKey("WEAPON_REVOLVER_CATTLEMAN")'))
        self.assertFalse(self.e('Log[indexOf("giveWeapon")].args[4]'))  # never forced into the hand
        self.assertTrue(self.e('Log[indexOf("giveWeapon")].args[5]'))
        self.assertEqual(self.e('count("startScenario")'), 1)
        self.assertTrue(self.e('Peds[p].frozen'))

    def test_resource_stop_deletes_previews(self):
        self.run('a = CreatorScene.create(nil, Config.Scene.selectionPed, app); fireEvent("onResourceStop", nil, "w_creators")')
        self.assertFalse(self.e('DoesEntityExist(a)'))


class StateLocaleUiTests(unittest.TestCase):
    def setUp(self):
        self.rt = make_client()
        self.e = self.rt.eval
        self.run = self.rt.run

    def test_state_set_get_copy_and_locks(self):
        self.run('WCState.setCharacter(4, "male"); a = AppearanceSchema.default("female"); WCState.set(a); a.sex = "x"')
        self.assertEqual(self.e('WCState.appearance.sex'), 'female')
        self.assertEqual(self.e('WCState.character.sex'), 'female')
        self.run('g = WCState.get(); g.sex = "y"')
        self.assertEqual(self.e('WCState.appearance.sex'), 'female')
        self.assertTrue(self.e('WCState.busy("spawn", true)'))
        self.assertFalse(self.e('WCState.busy("spawn", true)'))
        self.assertTrue(self.e('WCState.busy("spawn")'))
        self.assertTrue(self.e('WCState.busy("spawn", false)'))
        self.assertFalse(self.e('WCState.busy("spawn")'))
        self.assertFalse(self.e('WCState.inEditor()'))
        self.run('WCEditor = { session = function() return nil end }')
        self.assertFalse(self.e('WCState.inEditor()'))
        self.run('WCState.clear()')
        self.assertIsNone(self.e('WCState.character'))
        self.assertIsNone(self.e('WCState.get()'))

    def test_locale_helpers(self):
        self.run('LocaleKey = "ar-SA"')
        self.assertEqual(self.e('UiLocale()'), 'ar')
        self.assertEqual(self.e('UiDir()'), 'rtl')
        self.run('LocaleKey = "fr"')
        self.assertEqual(self.e('UiLocale()'), 'en')
        self.assertEqual(self.e('UiDir()'), 'ltr')
        self.run('''locale = function(k) return "T:" .. k end
            src = { title = "a", label = "b", value = "c", children = { { label = "d", xLabel = { "e", 3 } } } }
            out = TranslateTree(src)''')
        self.assertEqual(self.e('out.title'), 'T:a')
        self.assertEqual(self.e('out.label'), 'T:b')
        self.assertEqual(self.e('out.value'), 'c')
        self.assertEqual(self.e('out.children[1].label'), 'T:d')
        self.assertEqual(self.e('out.children[1].xLabel[1]'), 'T:e')
        self.assertEqual(self.e('out.children[1].xLabel[2]'), 3)
        self.assertEqual(self.e('src.title'), 'a')

    def test_language_change_reloads_and_refreshes(self):
        self.run('''seen = {}; OnLanguageChange(function(k) seen[#seen + 1] = k end)
            OnLanguageChange(function() error("boom") end)
            OnLanguageChange(function(k) seen[#seen + 1] = "second:" .. k end)
            clearLog(); fireEvent("w_lib:setLocale", nil, "ar_AR")''')
        self.assertEqual(self.e('Log[indexOf("w.locale")].args[1]'), 'ar')
        self.assertEqual(self.rt.py(self.e('seen')), {1: 'ar', 2: 'second:ar'})
        self.run('fireEvent("w_lib:setLocale", nil, "de")')
        self.assertEqual(self.e('seen[3]'), 'en')

    def test_fades_and_hud(self):
        self.run('clearLog(); StartFade(300, "spawn"); EndFade(300)')
        self.assertEqual(self.rt.py(self.e('ops()')),
                         {1: 'DoScreenFadeOut', 2: 'ShutdownLoadingScreen', 3: 'DoScreenFadeIn'})
        self.run('clearLog(); SetWorldUiVisible(false)')
        names = list(self.rt.py(self.e('ops("TriggerEvent:")')).values())
        self.assertIn('TriggerEvent:hud:client:Hideui', names)
        self.assertIn('TriggerEvent:hud:client:hideUiWithHoutStement', names)
        self.assertIn('TriggerEvent:chat:clear', names)
        self.run('clearLog(); SuppressGameHud()')
        self.assertEqual(self.rt.py(self.e('ops()')), {1: 'DisplayRadar', 2: 'DisplayHud'})


if __name__ == '__main__':
    unittest.main()
