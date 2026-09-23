"""Review round 2, client area: regressions for the confirmed client defects.

  * WCCutscene.stop() during the ride setup (fade, collision, wagon / driver streaming, seating) is
    final: the stale ride removes only its own entities, never re-seats or places the player, never
    turns the cinematic mode on and never leaves him invincible / participants-only
  * the renderer skips a stored tint the live config forbids (§5.4); the stored dye stays saved
  * a hair / beard growth stage draws only the hair slots (ApplyDiff) and keeps the runtime
    clothing states (the raised bandana) in WCState and on the ped
  * the wearable clothing states run on committed items (w_lib's helpers read the ped back)
  * the resurrect wrapper's doc block does not state the unconfirmed handle change as fact

Run: cd /home/user/w_creators && python3 -m unittest tests.test_review_client_r2
"""
import re
import unittest

from harness import RESOURCE, read
from test_client_characters_support import make_characters, settle
from test_client_infra_support import make_client

LAST_CINEMATIC = '''(function() local v
    for _, e in ipairs(Log) do if e.op == "SetCinematicModeActive" then v = e.args[1] end end
    return v end)()'''


class CutsceneStopDuringSetupTests(unittest.TestCase):
    """cutscene.lua play(): every yield of the setup is followed by a generation check."""

    def setUp(self):
        self.rt = make_characters(boot=False)
        self.e = self.rt.eval
        self.run = self.rt.run
        self.run('Config.Creator.enableCutscene = true')

    def start(self):
        self.run('clearLog(); fireEvent("W:CREATOR:FirstSpawn")')
        self.run('tick(0)')
        self.assertTrue(self.e('WCCutscene.active()'))

    def stop_and_settle(self):
        self.run('WCCutscene.stop()')
        # the respawn placed the player meanwhile
        self.run('Peds[MyPed].coords = vector3(500.0, 600.0, 70.0)')
        for _ in range(12):
            self.run('tick(250)')

    def assert_released(self):
        e = self.e
        self.assertFalse(e('WCCutscene.active()'))
        self.assertEqual(e('count("entity.create")'), e('count("entity.delete")'))  # nothing leaks
        self.assertIsNone(e('Peds[MyPed].vehicle'))                                 # never re-seated
        self.assertNotEqual(e(LAST_CINEMATIC), True)                                # no cinematic mode left on
        self.assertFalse(e('Peds[MyPed].invincible == true'))
        self.assertFalse(e('Peds[MyPed].participantsOnly == true'))
        self.assertAlmostEqual(e('Peds[MyPed].coords.x'), 500.0)                    # the respawn point stays
        # the arrival notice / arrival placement never happened
        self.assertEqual(e('count("TaskLeaveVehicle")'), 0)

    def test_stop_while_the_wagon_streams(self):
        self.run('''local real = w.entity.create
            w.entity.create = function(...) Wait(200) return real(...) end''')
        self.start()
        self.assertEqual(self.e('count("entity.create")'), 0)
        self.stop_and_settle()
        self.assert_released()
        self.assertEqual(self.e('count("SetPedIntoVehicle")'), 0)

    def test_stop_while_the_driver_streams(self):
        self.run('''local real, n = w.entity.create, 0
            w.entity.create = function(...) n = n + 1 if n == 2 then Wait(200) end return real(...) end''')
        self.start()
        self.assertEqual(self.e('count("entity.create")'), 1)  # the wagon, the driver is streaming
        self.stop_and_settle()
        self.assert_released()
        self.assertEqual(self.e('count("entity.create")'), 2)
        self.assertEqual(self.e('count("SetPedIntoVehicle")'), 0)

    def test_stop_during_the_fade(self):
        self.run('''IsScreenFadedOut = function() return false end
            StartFade = function() Wait(300) end''')
        self.start()
        self.stop_and_settle()
        self.assert_released()
        self.assertEqual(self.e('count("entity.create")'), 0)
        # the ride never started its music (only the stop's MC_MUSIC_STOP)
        self.assertEqual(self.e('''(function() local n = 0
            for _, e in ipairs(Log) do if e.op == "TriggerMusicEvent" and e.args[1] == "REHR_START" then n = n + 1 end end
            return n end)()'''), 0)

    def test_stop_while_seating(self):
        self.run('''SeatBlocked = true
            local real = IsPedInVehicle
            IsPedInVehicle = function(...) if SeatBlocked then return false end return real(...) end''')
        self.start()
        self.assertEqual(self.e('count("entity.create")'), 2)
        self.run('WCCutscene.stop(); SeatBlocked = false')
        # the vehicle is gone with the stop: the player is not in it any more
        self.run('Peds[MyPed].vehicle = nil; Peds[MyPed].coords = vector3(500.0, 600.0, 70.0)')
        for _ in range(12):
            self.run('tick(250)')
        self.assert_released()

    def test_a_new_ride_after_a_stale_one_owns_its_entities(self):
        self.run('''local real = w.entity.create
            SlowCreate = true
            w.entity.create = function(...) if SlowCreate then Wait(200) end return real(...) end''')
        self.start()
        self.run('WCCutscene.stop(); SlowCreate = false')
        self.run('fireEvent("W:CREATOR:FirstSpawn"); tick(0)')
        for _ in range(4):
            self.run('tick(250)')
        e = self.e
        # the new ride runs; the stale one removed only its own wagon
        self.assertTrue(e('WCCutscene.active()'))
        self.assertEqual(e('count("entity.create")'), 3)
        self.assertEqual(e('count("entity.delete")'), 1)
        self.assertIsNotNone(e('Peds[MyPed].vehicle'))
        self.assertTrue(e(LAST_CINEMATIC))

    def test_undisturbed_ride_is_unchanged(self):
        self.run('''local real = w.entity.create
            w.entity.create = function(...) Wait(200) return real(...) end''')
        self.start()
        settle(self.rt, 250, 4, barrier=False)
        e = self.e
        self.assertTrue(e('WCCutscene.active()'))
        self.assertEqual(e('count("entity.create")'), 2)
        self.assertIsNotNone(e('Peds[MyPed].vehicle'))
        self.assertTrue(e(LAST_CINEMATIC))
        self.run('WCCutscene.stop()')
        self.assertEqual(e('count("entity.delete")'), 2)
        self.assertFalse(e(LAST_CINEMATIC))


PIPELINE_SETUP = r'''
cat = function(sex, c) return WCCatalog.forSex(sex)[c] end
h = function(sex, c, m, v) return cat(sex, c).models[m or 1][v or 1].hash end
function entries(op)
    local out = {}
    for i, e in ipairs(Log) do if e.op == op then out[#out + 1] = { i = i, args = e.args } end end
    return out
end
function applied(category)
    for i, e in ipairs(Log) do
        if e.op == 'component.apply' and e.args[2] == category then return i, e.args[3] end
    end
    return nil
end
function fire(name, ...) fireEvent(name, nil, ...) end
app = AppearanceSchema.default('male')
app.clothing.equipped.hats = h('male', 'hats')
app.clothing.tints.shirts_full = { palette = 'metaped_tint_generic_clean', tint0 = 5, tint1 = 6, tint2 = 7 }
app.clothing.tints.hats = { palette = 'metaped_tint_hat', tint0 = 1, tint1 = 2, tint2 = 3 }
'''


class ForbiddenTintTests(unittest.TestCase):
    """pipeline.lua: a stored tint the live config forbids is not drawn (ARCHITECTURE.md §5.4)."""

    def setUp(self):
        self.rt = make_client()
        self.rt.run(PIPELINE_SETUP)
        self.e = self.rt.eval
        self.run = self.rt.run

    def drawn(self, category):
        return self.rt.py(self.e('select(2, applied("%s"))' % category))

    def restore(self):
        self.run('clearLog(); ok = Appearance.RestoreCharacter(MyPed, app)')
        self.assertTrue(self.e('ok'))

    def test_allowed_tints_are_drawn(self):
        self.restore()
        self.assertEqual(self.drawn('shirts_full')['palette'], 'metaped_tint_generic_clean')
        self.assertEqual(self.drawn('hats')['palette'], 'metaped_tint_hat')

    def test_disabled_tints_are_not_drawn_but_stay_stored(self):
        self.run('Config.Clothing.tints.enabled = false')
        self.restore()
        self.assertNotIn('palette', self.drawn('shirts_full'))
        self.assertNotIn('palette', self.drawn('hats'))
        self.assertEqual(self.e('app.clothing.tints.shirts_full.palette'), 'metaped_tint_generic_clean')
        # a stored (persisted) read keeps the dye: it is drawn again once the config allows it
        self.run('stored = AppearanceSchema.sanitize(app, { rules = false })')
        self.assertEqual(self.e('stored.clothing.tints.shirts_full.tint0'), 5)
        self.run('Config.Clothing.tints.enabled = true')
        self.restore()
        self.assertEqual(self.drawn('shirts_full')['tint0'], 5)

    def test_a_narrowed_palette_list_skips_only_that_category(self):
        self.run('Config.Clothing.tints.palettes.hats = { "metaped_tint_hat_clean" }')
        self.restore()
        self.assertNotIn('palette', self.drawn('hats'))
        self.assertEqual(self.drawn('shirts_full')['palette'], 'metaped_tint_generic_clean')

    def test_visibility_state_reapply_skips_a_forbidden_tint(self):
        self.run('Config.Clothing.tints.enabled = false; clearLog(); ok = Appearance.ApplyClothingState(MyPed, app, "hat", "on")')
        self.assertTrue(self.e('ok'))
        self.assertNotIn('palette', self.drawn('hats'))

    def test_diff_skips_a_forbidden_tint(self):
        self.run('''Config.Clothing.tints.enabled = false
            before = WCUtil.copy(app); after = WCUtil.copy(app)
            after.clothing.equipped.shirts_full = h('male', 'shirts_full', 2)
            clearLog(); ok = Appearance.ApplyDiff(MyPed, before, after)''')
        self.assertTrue(self.e('ok'))
        self.assertNotIn('palette', self.drawn('shirts_full'))
        # a tint change the config hides draws nothing
        self.run('''before = WCUtil.copy(app); after = WCUtil.copy(app)
            after.clothing.tints.hats = { palette = 'metaped_tint_hat', tint0 = 9, tint1 = 9, tint2 = 9 }
            clearLog(); ok = Appearance.ApplyDiff(MyPed, before, after)''')
        self.assertEqual(self.e('count("component.apply")'), 0)


class WearableStatesOnCommittedItemsTests(unittest.TestCase):
    """pipeline.lua: w_lib's state helpers read the ped's current item: it is committed first."""

    def setUp(self):
        self.rt = make_client()
        self.rt.run(PIPELINE_SETUP)
        self.e = self.rt.eval
        self.run = self.rt.run

    def commits(self):
        return [v['i'] for v in self.rt.py(self.e('entries("updateVariation")')).values()]

    def test_full_render_states_follow_the_body_commit(self):
        self.run('''app.clothing.equipped.neckwear = h('male', 'neckwear')
            app.clothing.states = { bandana = 'up', sleeves = 'rolled' }
            clearLog(); ok = Appearance.RestoreCharacter(MyPed, app)''')
        self.assertTrue(self.e('ok'))
        commits = self.commits()
        self.assertEqual(len(commits), 3)  # still three structural commits
        for op in ('component.setWearableState', 'component.sleeveRoll', 'component.collarClose'):
            first = self.e('indexOf("%s")' % op)
            self.assertIsNotNone(first, op)
            self.assertGreater(first, commits[1], op)   # after the body commit (items committed)
            self.assertLess(first, commits[2], op)      # committed by the final refresh
        # the morph follows the states (committed together by the final refresh)
        self.assertGreater(self.e('indexOf("setExpression")'), self.e('indexOf("component.sleeveRoll")'))

    def test_new_shirt_preview_is_committed_before_its_states(self):
        self.run('''before = WCUtil.copy(app); after = WCUtil.copy(app)
            after.clothing.equipped.shirts_full = h('male', 'shirts_full', 2)
            after.clothing.tints.shirts_full = nil
            clearLog(); ok = Appearance.ApplyDiff(MyPed, before, after)''')
        self.assertTrue(self.e('ok'))
        commits = self.commits()
        self.assertEqual(len(commits), 2)
        shirt = self.e('(applied("shirts_full"))')
        self.assertLess(shirt, commits[0])
        for op in ('component.sleeveUnroll', 'component.collarClose'):
            self.assertGreater(self.e('indexOf("%s")' % op), commits[0], op)
            self.assertLess(self.e('indexOf("%s")' % op), commits[1], op)

    def test_state_value_change_alone_needs_no_extra_commit(self):
        self.run('''before = WCUtil.copy(app); after = WCUtil.copy(app)
            after.clothing.states.sleeves = 'rolled'
            clearLog(); ok = Appearance.ApplyDiff(MyPed, before, after)''')
        self.assertTrue(self.e('ok'))
        self.assertEqual(len(self.commits()), 1)
        self.assertLess(self.e('indexOf("component.sleeveRoll")'), self.commits()[0])

    def test_new_item_of_a_group_without_state_item_needs_no_extra_commit(self):
        # a hat change touches no wearable group
        self.run('''before = WCUtil.copy(app); after = WCUtil.copy(app)
            after.clothing.equipped.hats = h('male', 'hats', 2)
            clearLog(); ok = Appearance.ApplyDiff(MyPed, before, after)''')
        self.assertTrue(self.e('ok'))
        self.assertEqual(len(self.commits()), 1)


class GrowthStageTests(unittest.TestCase):
    """sync.lua: w_creators:client:grooming draws only the hair slots and keeps runtime states."""

    def setUp(self):
        self.rt = make_client()
        self.rt.run(PIPELINE_SETUP)
        self.e = self.rt.eval
        self.run = self.rt.run
        self.run('''app.clothing.equipped.neckwear = h('male', 'neckwear')
            app.hair.facial = h('male', 'mustache', 1)
            fire("w_creators:client:applyAppearance", app)
            WCState.appearance.clothing.states.bandana = 'up'
            grown = WCUtil.copy(app)
            grown.hair.facial = h('male', 'mustache', 2)
            grown.clothing.states.bandana = nil''')

    def test_growth_draws_only_the_facial_hair_and_keeps_the_bandana(self):
        self.run('clearLog(); fire("w_creators:client:grooming", grown)')
        e = self.e
        self.assertEqual(e('count("preset")'), 0)
        self.assertEqual(e('count("component.removeAllClothes")'), 0)
        self.assertEqual(e('count("component.setWearableState")'), 0)
        self.assertEqual(e('count("component.apply")'), 1)
        self.assertEqual(e('Log[indexOf("component.apply")].args[2]'), e('Appearance.FACIAL_HAIR_CATEGORY'))
        self.assertEqual(e('count("updateVariation")'), 1)
        self.assertEqual(e('WCState.appearance.clothing.states.bandana'), 'up')
        self.assertEqual(e('WCState.appearance.hair.facial'), e('grown.hair.facial'))
        self.assertFalse(e('Appearance.Sync.applyingOwn()'))

    def test_growth_over_an_open_editor_is_stored_with_the_states(self):
        self.run('WCState.busy("editor", true); clearLog(); fire("w_creators:client:grooming", grown)')
        self.assertEqual(self.e('#Log'), 0)
        self.assertEqual(self.e('WCState.appearance.clothing.states.bandana'), 'up')
        self.assertEqual(self.e('WCState.appearance.hair.facial'), self.e('grown.hair.facial'))

    def test_persisting_states_come_from_the_server_look(self):
        # a persisted state (hat off) is the server's: it is not overwritten from memory
        self.run('''WCState.appearance.clothing.states.hat = 'off'
            grown.clothing.states.hat = nil
            clearLog(); fire("w_creators:client:grooming", grown)''')
        self.assertIsNone(self.e('WCState.appearance.clothing.states.hat'))
        self.assertEqual(self.e('WCState.appearance.clothing.states.bandana'), 'up')

    def test_without_a_previous_look_the_full_render_runs(self):
        self.run('WCState.set(nil); clearLog(); fire("w_creators:client:grooming", grown)')
        self.assertEqual(self.e('count("preset")'), 1)
        self.assertTrue(self.e('AppearanceSchema.equal(WCState.appearance, grown)'))

    def test_a_failed_diff_falls_back_to_the_full_render(self):
        self.run('''BadHashes[grown.hair.facial] = nil
            local real = Appearance.ApplyDiff
            Appearance.ApplyDiff = function() return false, {}, 'BUSY' end
            clearLog(); fire("w_creators:client:grooming", grown)
            Appearance.ApplyDiff = real''')
        self.assertEqual(self.e('count("preset")'), 1)
        self.assertEqual(self.e('WCState.appearance.clothing.states.bandana'), 'up')

    def test_apply_appearance_still_renders_in_full(self):
        self.run('clearLog(); fire("w_creators:client:applyAppearance", grown)')
        self.assertEqual(self.e('count("preset")'), 1)


class ResurrectDocTests(unittest.TestCase):
    def test_handle_change_is_not_stated_as_fact(self):
        code = read(RESOURCE / 'client' / 'natives' / 'respawn.lua')
        block = '\n'.join(line for line in code.splitlines() if line.startswith('--'))
        self.assertNotIn('the player ped handle changes;', block)
        self.assertIsNotNone(re.search(r'handle may change \(unconfirmed', block))
        self.assertIn('re-read PlayerPedId()', block)


if __name__ == '__main__':
    unittest.main()
