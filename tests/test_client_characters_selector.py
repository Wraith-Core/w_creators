"""WCSelector (client/characters/selector.lua): boot sequencing, the one-preview-ped rule, the card,
select → render → loaded ordering, busy guards, delete (hold time, typed confirmation), the retry
prompt, the /characters switch guard, the final exit and the resource-stop cleanup.

Run: cd /home/user/w_creators && python3 -m unittest discover -s tests -p 'test_client_characters_*.py'
"""
import unittest

from test_client_characters_support import make_characters, settle

TWO = ('CallbackResults = { ["w_creators:characters:list"] = '
       'listResult({ card("1", "male"), card("2", "female") }, 3) }')


class SelectorBootTests(unittest.TestCase):
    def test_restart_boot_opens_the_selection(self):
        rt = make_characters(setup=TWO)
        e = rt.eval
        self.assertTrue(e('WCSelector.active()'))
        self.assertEqual(e('called("w_creators:scene:prepare")'), 1)
        self.assertEqual(e('called("w_creators:characters:list")'), 1)
        self.assertLess(e('indexOf("callback:w_creators:scene:prepare")'),
                        e('indexOf("callback:w_creators:characters:list")'))
        self.assertEqual(e('#CreatorScene.peds()'), 1)
        self.assertEqual(e('liveGroups()'), 1)
        group = 'liveGroup()'
        self.assertEqual(e(group + '.title'), 'Name 1  (1/3)')
        self.assertEqual(e(group + '.prompts.DELETE.hold'), 5000)
        self.assertFalse(e(group + '.prompts.RETURN.hold'))
        card = 'lastNui("charCard")'
        self.assertTrue(e(card + '.show'))
        self.assertEqual(e(card + '.name'), 'Name 1')
        self.assertIsNone(e(card + '.appearance'))
        self.assertTrue(e('Peds[MyPed].frozen'))
        self.assertFalse(e('Peds[MyPed].visible'))
        self.assertTrue(e('Peds[MyPed].participantsOnly'))
        self.assertTrue(e('WCState.busy("selection")'))
        self.assertTrue(e('WCCamera.isOpen()'))
        self.assertGreater(e('count("TriggerEvent:hud:client:Hideui")'), 0)
        self.assertGreater(e('count("DoScreenFadeIn")'), 0)

    def test_first_login_waits_for_the_ped_and_playerSpawned(self):
        rt = make_characters(boot=False, setup=TWO)
        e = rt.eval
        settle(rt, 100, 5)
        self.assertFalse(e('WCSelector.active()'))
        rt.run('Peds[MyPed].coords = vector3(50.0, 50.0, 50.0)')
        settle(rt, 100, 5)
        self.assertFalse(e('WCSelector.active()'))  # no playerSpawned yet
        self.assertEqual(e('called("w_creators:scene:prepare")'), 0)
        rt.run('fireEvent("playerSpawned")')
        settle(rt, 600, 5)
        self.assertTrue(e('WCSelector.active()'))
        self.assertEqual(e('called("w_creators:characters:list")'), 1)

    def test_old_starting_command_is_gone(self):
        rt = make_characters(setup=TWO)
        self.assertIsNone(rt.eval('Events.commands.starting'))
        self.assertIsNotNone(rt.eval('Events.commands.characters'))

    def test_switch_command_absent_without_allowSwitch(self):
        rt = make_characters(setup=TWO + '; Config.Characters.allowSwitch = false')
        self.assertIsNone(rt.eval('Events.commands.characters'))

    def test_fade_guard_cancels_a_foreign_fade_while_visible(self):
        rt = make_characters(setup=TWO)
        rt.run('clearLog(); ScreenFadedOut = true')
        settle(rt, 250, 2)
        self.assertGreater(rt.eval('count("DoScreenFadeIn")'), 0)


class SelectorNavigationTests(unittest.TestCase):
    def setUp(self):
        self.rt = make_characters(setup=TWO)
        self.e = self.rt.eval
        self.run = self.rt.run

    def test_next_creates_the_new_preview_before_destroying_the_old(self):
        first = self.e('CreatorScene.peds()[1]')
        self.run('clearLog(); press("RIGHT")')
        settle(self.rt)
        peds = self.rt.py(self.e('CreatorScene.peds()'))
        self.assertEqual(len(peds), 1)
        second = peds[1]
        self.assertNotEqual(first, second)
        self.assertFalse(self.e('DoesEntityExist(%d)' % first))
        self.assertEqual(self.e('GetEntityModel(%d) == GetHashKey("mp_female")' % second), True)
        self.assertLess(self.e('indexOf("entity.create")'), self.e('indexOf("entity.delete")'))
        self.assertEqual(self.e('lastNui("charCard").name'), 'Name 2')
        self.assertEqual(self.e('liveGroup().title'), 'Name 2  (2/3)')
        self.assertNotEqual(self.e('CreatorScene.peds()[1]'), self.e('MyPed'))

    def test_empty_slot_hides_the_card_and_the_delete_prompt(self):
        self.run('press("LEFT")')  # wraps to the third (empty) slot
        settle(self.rt)
        self.assertFalse(self.e('lastNui("charCard").show'))
        self.assertFalse(self.e('liveGroup().visible.DELETE'))
        self.assertEqual(self.e('#CreatorScene.peds()'), 1)

    def test_rapid_presses_are_ignored_while_an_action_runs(self):
        self.run('''
            local realCreate = CreatorScene.create
            CreatorScene.create = function(...) Wait(1000) return realCreate(...) end
            clearLog(); press("RIGHT")''')
        settle(self.rt, 0, 3)
        self.assertTrue(self.e('WCSelector.busy()'))
        self.run('press("RIGHT")')
        settle(self.rt, 0, 3, barrier=False)
        settle(self.rt, 1000, 3, barrier=False)
        self.assertEqual(self.e('count("entity.create")'), 1)
        self.assertEqual(self.e('liveGroup().title'), 'Name 2  (2/3)')


class SelectorSelectTests(unittest.TestCase):
    def setUp(self):
        self.rt = make_characters(setup=TWO)
        self.e = self.rt.eval
        self.run = self.rt.run

    def test_select_renders_then_loads(self):
        self.run('clearLog(); press("RETURN")')
        settle(self.rt)
        e = self.e
        self.assertEqual(e('called("w_creators:characters:select")'), 1)
        self.assertEqual(e('callArgs("w_creators:characters:select")[2]'), '1')
        self.assertEqual(e('called("w_creators:characters:loaded")'), 1)
        self.assertLess(e('indexOf("RestorePlayer")'), e('indexOf("callback:w_creators:characters:loaded")'))
        self.assertLess(e('indexOf("callback:w_creators:characters:select")'), e('indexOf("RestorePlayer")'))
        self.assertEqual(e('WCState.character.charid'), '1')
        self.assertEqual(e('WCState.appearance.sex'), 'male')
        self.assertFalse(e('WCSelector.active()'))
        self.assertFalse(e('WCState.busy("selection")'))
        self.assertEqual(e('#CreatorScene.peds()'), 0)
        self.assertFalse(e('WCCamera.isOpen()'))
        self.assertFalse(e('lastNui("charCard").show'))
        self.assertEqual(e('liveGroups()'), 0)
        self.assertTrue(e('Peds[MyPed].visible'))
        self.assertFalse(e('Peds[MyPed].frozen'))
        self.assertFalse(e('Peds[MyPed].participantsOnly'))
        # the room is released for the spawn, the bucket is kept (the spawn choice moves it)
        self.assertFalse(e('CreatorScene.isLoaded()'))
        self.assertEqual(e('called("w_creators:scene:release")'), 0)

    def test_render_failure_never_calls_loaded(self):
        self.run('RestoreFails = true; clearLog(); press("RETURN")')
        settle(self.rt)
        self.assertEqual(self.e('called("w_creators:characters:loaded")'), 0)
        self.assertTrue(self.e('WCSelector.active()'))
        self.assertIsNone(self.e('WCState.character'))
        self.assertTrue(self.e('noted("تعذر تطبيق التعديل")'))
        self.assertFalse(self.e('Peds[MyPed].visible'))
        # retry: the same character again
        self.run('RestoreFails = false; press("RETURN")')
        settle(self.rt)
        self.assertEqual(self.e('called("w_creators:characters:loaded")'), 1)

    def test_select_refused_keeps_the_screen(self):
        self.run('''CallbackResults["w_creators:characters:select"] = WCResult.fail("BUSY")
            clearLog(); press("RETURN")''')
        settle(self.rt)
        self.assertTrue(self.e('WCSelector.active()'))
        self.assertTrue(self.e('noted(WCResult.messageKey("BUSY"))'))
        self.assertEqual(self.e('count("RestorePlayer")'), 0)
        self.assertEqual(self.e('called("w_creators:characters:loaded")'), 0)
        self.assertFalse(self.e('WCSelector.busy()'))

    def test_double_select_is_ignored_while_busy(self):
        self.run('''CallbackResults["w_creators:characters:select"] = function(_, charid)
                Wait(1000)
                return WCResult.ok({ appearance = AppearanceSchema.default("male") })
            end
            clearLog(); press("RETURN")''')
        settle(self.rt, 0, 3)
        self.run('press("RETURN")')
        settle(self.rt, 0, 3, barrier=False)
        settle(self.rt, 1000, 5, barrier=False)
        self.assertEqual(self.e('called("w_creators:characters:select")'), 1)
        self.assertEqual(self.e('called("w_creators:characters:loaded")'), 1)

    def test_loaded_failure_reopens_the_selection(self):
        self.run('''CallbackResults["w_creators:characters:loaded"] = WCResult.fail("NO_CHARACTER")
            clearLog(); press("RETURN")''')
        settle(self.rt)
        self.assertTrue(self.e('WCSelector.active()'))
        self.assertIsNone(self.e('WCState.character'))
        self.assertEqual(self.e('called("w_creators:characters:list")'), 1)
        self.assertTrue(self.e('noted(WCResult.messageKey("NO_CHARACTER"))'))

    def test_final_exit_unloads_the_room_once_the_player_left(self):
        rt = make_characters(setup=TWO + '; IplInactive[Config.Scene.imaps[1]] = true')
        settle(rt, 500, 12)  # the room maps never report active: the load waits its 5 s timeout
        self.assertTrue(rt.eval('WCSelector.active()'))
        rt.run('clearLog(); press("RETURN")')
        settle(rt)
        settle(rt, 500, 2)
        self.assertEqual(rt.eval('count("RemoveIplByHash")'), 0)  # still in the room
        rt.run('Peds[MyPed].coords = vector3(-274.0, 785.0, 119.0)')
        settle(rt, 500, 2)
        self.assertEqual(rt.eval('count("RemoveIplByHash")'), 1)
        self.assertEqual(rt.eval('called("w_creators:scene:release")'), 1)

    def test_event_spawn_mode_fades_in_when_the_event_does_not(self):
        self.run('''CallbackResults["w_creators:characters:loaded"] = WCResult.ok({ spawn = "event" })
            ScreenFadedOut = true; clearLog(); press("RETURN")''')
        settle(self.rt)
        self.assertEqual(self.e('count("DoScreenFadeIn")'), 0)
        settle(self.rt, 16000, 3)
        self.assertGreater(self.e('count("DoScreenFadeIn")'), 0)


class SelectorDeleteTests(unittest.TestCase):
    def make(self, typed):
        rt = make_characters(setup=(
            'CallbackResults = { ["w_creators:characters:list"] = listResult({ card("1", "male", "John Smith"), '
            'card("2", "female") }, 3, true, { enabled = true, holdTime = 3000, typed = %s }) }'
            % ('true' if typed else 'false')))
        return rt

    def test_hold_time_comes_from_the_server(self):
        rt = self.make(False)
        self.assertEqual(rt.eval('liveGroup().prompts.DELETE.hold'), 3000)

    def test_confirmed_delete_reloads_the_list(self):
        rt = self.make(False)
        rt.run('clearLog(); press("DELETE")')
        settle(rt)
        self.assertEqual(rt.eval('Dialogs[1].kind'), 'alert')
        self.assertEqual(rt.eval('called("w_creators:characters:delete")'), 1)
        args = rt.eval('callArgs("w_creators:characters:delete")')
        self.assertEqual(args[2], '1')
        self.assertIsNone(args[3])
        self.assertEqual(rt.eval('called("w_creators:characters:list")'), 1)
        self.assertTrue(rt.eval('noted("تم حذف الشخصية.")'))

    def test_cancelled_delete_does_nothing(self):
        rt = self.make(False)
        rt.run('AlertAnswer = "cancel"; clearLog(); press("DELETE")')
        settle(rt)
        self.assertEqual(rt.eval('called("w_creators:characters:delete")'), 0)
        self.assertFalse(rt.eval('WCSelector.busy()'))

    def test_typed_confirmation_passes_the_typed_text(self):
        rt = self.make(True)
        rt.run('InputAnswer = { "John Smith" }; clearLog(); press("DELETE")')
        settle(rt)
        self.assertEqual(rt.eval('Dialogs[2].kind'), 'input')
        self.assertEqual(rt.eval('Dialogs[2].rows[1].placeholder'), 'John Smith')
        args = rt.eval('callArgs("w_creators:characters:delete")')
        self.assertEqual(args[2], '1')
        self.assertEqual(args[3], 'John Smith')

    def test_typed_confirmation_cancelled_or_empty_does_not_delete(self):
        rt = self.make(True)
        rt.run('InputAnswer = nil; press("DELETE")')
        settle(rt)
        rt.run('InputAnswer = { "   " }; press("DELETE")')
        settle(rt)
        self.assertEqual(rt.eval('called("w_creators:characters:delete")'), 0)

    def test_refused_delete_shows_the_reason(self):
        rt = self.make(True)
        rt.run('''InputAnswer = { "wrong" }
            CallbackResults["w_creators:characters:delete"] = WCResult.fail("DELETE_CONFIRMATION_REQUIRED")
            clearLog(); press("DELETE")''')
        settle(rt)
        self.assertTrue(rt.eval('noted(WCResult.messageKey("DELETE_CONFIRMATION_REQUIRED"))'))
        self.assertEqual(rt.eval('called("w_creators:characters:list")'), 0)
        self.assertTrue(rt.eval('WCSelector.active()'))


class SelectorFailureTests(unittest.TestCase):
    def test_list_failure_shows_the_retry_prompt(self):
        rt = make_characters(setup='CallbackResults = { ["w_creators:characters:list"] = WCResult.fail("DATABASE_ERROR") }')
        e = rt.eval
        self.assertTrue(e('WCSelector.active()'))
        self.assertEqual(e('liveGroup().title'), 'تعذر عرض الشخصية. أعد المحاولة')
        self.assertTrue(e('noted(WCResult.messageKey("DATABASE_ERROR"))'))
        self.assertFalse(e('Peds[MyPed].visible'))
        self.assertEqual(e('#CreatorScene.peds()'), 0)
        rt.run(TWO + '; press("RETURN")')
        settle(rt)
        self.assertEqual(e('liveGroup().title'), 'Name 1  (1/3)')
        self.assertEqual(e('#CreatorScene.peds()'), 1)

    def test_empty_slot_hands_over_to_the_creator(self):
        rt = make_characters(setup='CallbackResults = { ["w_creators:characters:list"] = listResult({}, 2), '
                                   '["w_creators:characters:beginCreate"] = WCResult.ok({ token = "t1" }) }')
        rt.run('clearLog(); press("RETURN")')
        settle(rt)
        self.assertFalse(rt.eval('WCSelector.active()'))
        self.assertTrue(rt.eval('WCCreator.active()'))
        self.assertEqual(rt.eval('called("w_creators:characters:beginCreate")'), 1)


class SelectorSwitchTests(unittest.TestCase):
    def setUp(self):
        # no boot selection: the player is in the world with a character
        self.rt = make_characters(boot=False, setup=TWO)
        self.rt.run('Peds[MyPed].visible = true; WCState.setCharacter("9", "male")')

    def command(self):
        self.rt.run('Events.commands.characters.fn(0, {}, "characters")')
        settle(self.rt)

    def test_refused_while_dead(self):
        self.rt.run('Peds[MyPed].dead = true')
        self.command()
        self.assertTrue(self.rt.eval('noted("لا يمكنك تبديل الشخصية الآن")'))
        self.assertEqual(self.rt.eval('called("w_creators:scene:prepare")'), 0)

    def test_refused_in_an_editor(self):
        self.rt.run('WCState.busy("editor", true)')
        self.command()
        self.assertTrue(self.rt.eval('noted("لا يمكنك تبديل الشخصية الآن")'))
        self.assertEqual(self.rt.eval('called("w_creators:scene:prepare")'), 0)

    def test_server_refusal_leaves_the_player_in_the_world(self):
        self.rt.run('CallbackResults["w_creators:scene:prepare"] = WCResult.fail("SERVICE_DISABLED"); clearLog()')
        self.command()
        e = self.rt.eval
        self.assertTrue(e('noted(WCResult.messageKey("SERVICE_DISABLED"))'))
        self.assertFalse(e('WCSelector.active()'))
        self.assertEqual(e('called("w_creators:characters:list")'), 0)
        self.assertEqual(e('count("loadSphere")'), 0)
        self.assertTrue(e('Peds[MyPed].visible'))
        self.assertEqual(e('WCState.character.charid'), '9')
        self.assertFalse(e('WCState.busy("selection")'))

    def test_allowed_switch_opens_the_selection(self):
        self.command()
        self.assertTrue(self.rt.eval('WCSelector.active()'))
        self.assertIsNone(self.rt.eval('WCState.character'))
        self.assertEqual(self.rt.eval('called("w_creators:characters:list")'), 1)


class SelectorStopTests(unittest.TestCase):
    def test_resource_stop_cleans_up(self):
        rt = make_characters(setup=TWO)
        ped = rt.eval('CreatorScene.peds()[1]')
        rt.run('fireEvent("onResourceStop", nil, "w_creators")')
        e = rt.eval
        self.assertFalse(e('DoesEntityExist(%d)' % ped))
        self.assertEqual(e('liveGroups()'), 0)
        self.assertFalse(e('WCCamera.isOpen()'))
        self.assertFalse(e('lastNui("charCard").show'))
        self.assertTrue(e('Peds[MyPed].visible'))
        self.assertFalse(e('Peds[MyPed].frozen'))
        self.assertFalse(e('Peds[MyPed].participantsOnly'))
        self.assertFalse(e('WCState.busy("selection")'))
        self.assertFalse(e('WCSelector.active()'))


if __name__ == '__main__':
    unittest.main()
