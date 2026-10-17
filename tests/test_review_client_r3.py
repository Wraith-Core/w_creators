"""Review round 3, client / NUI area: regressions for the confirmed client findings.

  * the in-world spawn selector re-displays its prompt group when another group displaced it, has
    a cancel key for the in-world kind, and is refused while the death system holds the player
    (the character selector and the creator re-display their groups too)          (finding 4)
  * a world respawn ends a w_medic hospital bed stay before the revive / move (5)
  * an uncertain characters:loaded answer is settled by the spawn hand-off, not a reopen (6)
  * the preview environment only gives back the HUD / radar it hid                 (8)
  * an owned dye the live config no longer offers is kept when the item is put on (9)
  * the owner's own applyAppearance / reload keeps the runtime clothing states    (10)
  * the Color control of the blend-type-1 skin layers is gone (never priced), not drawn (20)
  * the Outfits group: StartingOutfits in the free creator, saved outfits beside the item groups (21)
  * a closed location keeps its prompt, disabled, with a "Closed · opens at" title (25)
  * a stage list without 'identity' / 'review' gets them back                     (26)
  * the taxonomy `order` is honoured by every tree, with a stable tie-break        (27)
  * one Arabic spelling per town                                                   (29)
  * the remote scope watcher renders in parallel threads, skips identical re-broadcasts and draws
    small changes incrementally                                                    (30, 31)

Run: cd /home/user/w_creators && python3 -m unittest discover -s tests -p 'test_review_client_r3.py'
"""
import json
import re
import unittest

from harness import RESOURCE, read as read_path
from test_client_characters_selector import TWO
from test_client_characters_support import make_characters, settle
from test_client_commerce_support import make_commerce
from test_client_infra_support import make_client
from test_client_spawn_support import make_spawn_client, count, spin
from test_editor_lua import EditorBase, lua_list

def read(path):
    return read_path(RESOURCE / path)


AMBULANCE_MAIN = RESOURCE.parent / 'w_medic' / 'client' / 'main.lua'


def ids(tbl):
    return [n.id for n in lua_list(tbl)]


# ---------------------------------------------------------------------------------------------
#  Finding 4: the spawn selector's prompt group, cancel key and death-owner refusal
# ---------------------------------------------------------------------------------------------
SELECT = "{ points = { 'saintdenis', 'valentine' }, kind = %r }"


class SpawnSelectorPromptTests(unittest.TestCase):
    def setUp(self):
        self.rt = make_spawn_client()
        self.e = self.rt.eval
        self.run = self.rt.run
        self.run('clearLog()')

    def open(self, kind='admin'):
        self.run("fireEvent('w_creators:client:selectSpawn', nil, %s)" % (SELECT % kind))
        self.run('G = PromptGroups[#PromptGroups]; G.displays = 0'
                 '; local d = G.display; G.display = function() G.displays = G.displays + 1; d() end'
                 '; G.isVisible = function() return G.visible end')

    def test_a_displaced_group_is_displayed_again_and_still_answers(self):
        self.open()
        self.assertTrue(self.e('WCSpawnSelector.active()'))
        # a walk-up prompt (the hospital desk) displayed over ours: w_lib hid our group
        self.run('G.visible = false')
        spin(self.rt, 600)
        self.assertTrue(self.e('G.visible'))
        self.assertGreaterEqual(self.e('G.displays'), 1)
        # the selector can be used again
        self.run("Pressed[Config.Spawn.selector.keys.next] = true")
        spin(self.rt, 600)
        self.assertEqual(self.e('WCSpawnSelector.index()'), 2)

    def test_a_visible_group_is_not_redisplayed(self):
        self.open()
        spin(self.rt, 1000)
        self.assertEqual(self.e('G.displays'), 0)

    def test_the_in_world_selector_can_be_cancelled(self):
        self.open('admin')
        keys = [p.key for p in lua_list(self.e('G.prompts'))]
        self.assertIn('BACK', keys)
        self.run("Pressed['BACK'] = true")
        spin(self.rt, 600)
        self.assertFalse(self.e('WCSpawnSelector.active()'))
        self.assertFalse(self.e('WCSpawnSelector.holding()'))
        self.assertFalse(self.e('Peds[MyPed].frozen'))
        self.assertTrue(self.e('Peds[MyPed].visible'))
        self.assertFalse(self.e('Peds[MyPed].invincible'))
        self.assertEqual(count(self.rt, 'TriggerServerEvent:w_creators:server:spawnCancel'), 1)
        self.assertEqual(len(self.e("callbacks('w_creators:spawn:choose')")), 0)

    def test_a_login_selector_has_no_cancel(self):
        self.open('login')
        keys = [p.key for p in lua_list(self.e('G.prompts'))]
        self.assertNotIn('BACK', keys)
        self.assertFalse(self.e('WCSpawnSelector.cancel()'))
        self.run("Pressed['BACK'] = true")
        spin(self.rt, 600)
        self.assertTrue(self.e('WCSpawnSelector.active()'))
        self.assertEqual(count(self.rt, 'TriggerServerEvent:w_creators:server:spawnCancel'), 0)

    def test_refused_while_the_death_system_holds_the_player(self):
        self.run("ResourceStates['w_medic'] = 'started'"
                 "; exports.w_medic = { IsDead = function() return true end }")
        self.run("fireEvent('w_creators:client:selectSpawn', nil, %s)" % (SELECT % 'admin'))
        self.assertFalse(self.e('WCSpawnSelector.active()'))
        self.assertFalse(self.e('WCSpawnSelector.holding()'))
        self.assertFalse(self.e('Peds[MyPed].frozen == true'))
        self.assertEqual(self.e('#PromptGroups'), 0)
        self.assertEqual(count(self.rt, 'TriggerServerEvent:w_creators:server:spawnCancel'), 1)
        self.assertEqual(count(self.rt, 'CreateCam'), 0)

    def test_a_login_selector_ignores_the_death_owner(self):
        self.run("ResourceStates['w_medic'] = 'started'"
                 "; exports.w_medic = { IsDead = function() return true end }")
        self.open('login')
        self.assertTrue(self.e('WCSpawnSelector.active()'))


class CharacterScreensReassertTests(unittest.TestCase):
    """The character selector and the creator's gender screen display their group again."""

    def test_the_character_selector_group_comes_back(self):
        rt = make_characters(setup=TWO)
        rt.run('G = liveGroup(); G.displays = 0; local d = G.display'
               '; G.display = function() G.displays = G.displays + 1; d() end'
               '; G.isVisible = function() return G.shown ~= false end; G.shown = false'
               '; local d2 = G.display; G.display = function() G.shown = true; d2() end')
        settle(rt, 300, 5)
        self.assertTrue(rt.eval('G.shown'))
        self.assertGreaterEqual(rt.eval('G.displays'), 1)

    def test_sources_reassert_through_isVisible(self):
        for path in ('client/characters/selector.lua', 'client/creator/creator.lua'):
            src = read(path)
            self.assertRegex(src, r'pcall\(group\.isVisible\)', path)
            self.assertRegex(src, r'reassertPrompts\(group\)\s*\n\s*local ok, done = pcall\(group\.isCompleted, key\)', path)


# ---------------------------------------------------------------------------------------------
#  Finding 5: a world respawn ends the hospital bed stay first
# ---------------------------------------------------------------------------------------------
class BedStayRespawnTests(unittest.TestCase):
    def setUp(self):
        self.rt = make_spawn_client()
        self.run = self.rt.run
        self.e = self.rt.eval
        self.run('''
            WCRespawn.reset(); clearLog()
            InBed, Ended, ReviveEvents = true, 0, 0
            ResourceStates['w_medic'] = 'started'
            exports.w_medic = {
                InHospitalBed = function() return InBed end,
                EndBedStay = function() Log[#Log + 1] = { op = 'EndBedStay', args = table.pack() }; Ended = Ended + 1; local was = InBed; InBed = false; return was end,
                IsDead = function() return InBed end,
            }
            AddEventHandler('hospital:client:Revive', function() ReviveEvents = ReviveEvents + 1; Log[#Log + 1] = { op = 'Revive', args = table.pack(InBed) } end)
        ''')

    def respawn(self, kind):
        self.run("fireEvent('w_creators:client:respawn', nil, { x = 5.0, y = 6.0, z = 7.0, heading = 10.0 }, "
                 "{ kind = %r, point = 'valentine' })" % kind)
        spin(self.rt, 4000, 100)

    def test_admin_respawn_of_a_patient_ends_the_stay_before_the_move(self):
        self.respawn('admin')
        self.assertEqual(self.e('Ended'), 1)
        self.assertLess(self.e("indexOf('EndBedStay')"), self.e("indexOf('SetEntityCoords', indexOf('EndBedStay'))"))
        pos = self.e('GetEntityCoords(MyPed)')
        self.assertEqual((pos.x, pos.y), (5.0, 6.0))

    def test_death_respawn_ends_the_stay_before_the_revive(self):
        self.respawn('death')
        self.assertEqual(self.e('Ended'), 1)
        self.assertEqual(self.e('ReviveEvents'), 1)
        self.assertLess(self.e("indexOf('EndBedStay')"), self.e("indexOf('Revive')"))
        # the revive no longer sees a patient in bed (it would re-pose him in the bed animation)
        self.assertFalse(self.e("Log[indexOf('Revive')].args[1]"))

    def test_no_bed_no_call(self):
        self.run('InBed = false')
        self.respawn('admin')
        self.assertEqual(self.e('Ended'), 0)

    def test_stopped_death_system_is_not_called(self):
        self.run("ResourceStates['w_medic'] = 'stopped'")
        self.respawn('admin')
        self.assertEqual(self.e('Ended'), 0)

    def test_w_medic_exports_the_bed_end(self):
        if not AMBULANCE_MAIN.exists():
            self.skipTest('w_medic not checked out')
        src = AMBULANCE_MAIN.read_text(encoding='utf-8')
        m = re.search(r"exports\('EndBedStay', function\(\)(.*?)\nend\)", src, re.S)
        self.assertIsNotNone(m)
        self.assertIn('ResetBedState()', m.group(1))
        # ResetBedState is a local defined before the export (same chunk)
        self.assertLess(src.index('local function ResetBedState()'), m.start())


# ---------------------------------------------------------------------------------------------
#  Finding 6: an uncertain characters:loaded answer
# ---------------------------------------------------------------------------------------------
class UncertainLoadedTests(unittest.TestCase):
    def make(self, answer):
        rt = make_characters(setup=TWO + '''
            SpawnCount = 0
            WCSpawn = { count = function() return SpawnCount end, busy = function() return false end }
            LoadedCalls = 0
            CallbackResults["w_creators:characters:loaded"] = function()
                LoadedCalls = LoadedCalls + 1
                %s
            end''' % answer)
        rt.run('WCSelector.LOADED_HANDOFF_TIMEOUT = 3000')
        return rt

    def select(self, rt):
        rt.run('clearLog(); press("RETURN")')
        settle(rt, 500, 20)

    def test_a_timeout_after_the_spawn_hand_off_is_a_load(self):
        rt = self.make('SpawnCount = SpawnCount + 1; return WCResult.fail("INTERNAL_ERROR")')
        self.select(rt)
        self.assertEqual(rt.eval('LoadedCalls'), 1)
        self.assertEqual(rt.eval('called("w_creators:characters:list")'), 0)   # never reopened
        self.assertEqual(rt.eval('WCState.character.charid'), '1')
        self.assertFalse(rt.eval('WCSelector.active()'))

    def test_a_retry_after_a_real_load_answers_no_character(self):
        rt = self.make('if LoadedCalls == 1 then return WCResult.fail("INTERNAL_ERROR") end'
                       ' return WCResult.fail("NO_CHARACTER")')
        self.select(rt)
        self.assertEqual(rt.eval('LoadedCalls'), 2)
        self.assertEqual(rt.eval('called("w_creators:characters:list")'), 0)
        self.assertEqual(rt.eval('WCState.character.charid'), '1')

    def test_a_successful_retry_is_used(self):
        rt = self.make('if LoadedCalls == 1 then return WCResult.fail("INTERNAL_ERROR") end'
                       ' return WCResult.ok({ spawn = "direct" })')
        self.select(rt)
        self.assertEqual(rt.eval('LoadedCalls'), 2)
        self.assertEqual(rt.eval('called("w_creators:characters:list")'), 0)

    def test_two_uncertain_answers_without_a_hand_off_reopen(self):
        rt = self.make('return WCResult.fail("INTERNAL_ERROR")')
        self.select(rt)
        self.assertEqual(rt.eval('LoadedCalls'), 2)
        self.assertTrue(rt.eval('WCSelector.active()'))
        self.assertIsNone(rt.eval('WCState.character'))

    def test_a_certain_refusal_is_not_retried(self):
        rt = self.make('return WCResult.fail("NO_CHARACTER")')
        self.select(rt)
        self.assertEqual(rt.eval('LoadedCalls'), 1)
        self.assertTrue(rt.eval('WCSelector.active()'))

    def test_the_creator_uses_the_same_settlement(self):
        src = read('client/creator/creator.lua')
        self.assertIn('WCSelector.awaitLoaded()', src)


# ---------------------------------------------------------------------------------------------
#  Finding 8: the preview environment gives back only what it hid
# ---------------------------------------------------------------------------------------------
class EnvironmentHudTests(unittest.TestCase):
    def setUp(self):
        self.rt = make_client()
        self.e = self.rt.eval
        self.run = self.rt.run

    def cycle(self):
        self.run('clearLog(); WCPreviewEnv.enter(); tick(0); WCPreviewEnv.exit()')

    def test_a_hidden_radar_stays_hidden_after_the_visit(self):
        self.run('function IsRadarHidden() return true end')
        self.cycle()
        self.assertEqual(count(self.rt, 'setRadarVisible'), 0)
        # the game HUD was muted per frame all the same
        self.assertGreater(count(self.rt, 'DisplayRadar'), 0)
        # the w_hud HUD no longer follows the radar (store notes): hidden for the visit, given back
        self.assertEqual(count(self.rt, 'TriggerEvent:hud:client:Hideui'), 1)
        self.assertEqual(count(self.rt, 'TriggerEvent:hud:client:showui'), 1)

    def test_a_shown_hud_is_hidden_and_given_back(self):
        self.run('function IsRadarHidden() return false end')
        self.cycle()
        self.assertEqual(count(self.rt, 'TriggerEvent:hud:client:Hideui'), 1)
        self.assertEqual(count(self.rt, 'TriggerEvent:hud:client:showui'), 1)
        self.assertEqual([e.args[1] for e in lua_list(self.e(
            '(function() local o = {} for _, e in ipairs(Log) do if e.op == "setRadarVisible" then o[#o + 1] = e end end return o end)()'))],
            [False, True])

    def test_without_the_native_the_previous_behaviour_stays(self):
        self.run('IsRadarHidden = nil')
        self.cycle()
        self.assertEqual(count(self.rt, 'TriggerEvent:hud:client:showui'), 1)


# ---------------------------------------------------------------------------------------------
#  Finding 9: an owned dye outside the live palette list
# ---------------------------------------------------------------------------------------------
class OwnedStoredDyeTests(EditorBase):
    SETUP = r"""
        H = function(m, v) return WCCatalog.forSex('male').hats.models[m][v or 1].hash end
        savedApp = AppearanceSchema.default('male')
        savedApp.clothing.equipped.hats = H(1)
        savedApp.clothing.tints.hats = { palette = 'metaped_tint_hat', tint0 = 1, tint1 = 2, tint2 = 3 }
        owned = { [tostring(WCUtil.u32(H(1)))] = { category = 'hats', palette = 'metaped_tint_hat', tint0 = 1, tint1 = 2, tint2 = 3 },
                  [tostring(WCUtil.u32(H(2)))] = { category = 'hats', palette = 'metaped_tint_hat', tint0 = 4, tint1 = 5, tint2 = 6 } }
        Config.Clothing.tints.palettes.hats = { 'metaped_tint_generic_clean' }
    """

    def setUp(self):
        super().setUp()
        self.rt.run(self.SETUP)
        self.assertTrue(self.rt.eval("openEditor('store', 'male', { app = savedApp, context = { owned = owned, storeProfile = 'general' } })"))

    def test_another_owned_dyed_item_is_put_on_with_its_dye(self):
        r = self.action(op='set', control='clothing.hats.style', value=2)
        self.assertTrue(r.ok, r.code)
        t = self.working('.clothing.tints.hats')
        self.assertEqual((t.palette, t.tint0, t.tint1, t.tint2), ('metaped_tint_hat', 4, 5, 6))
        self.assertEqual(self.rt.eval('WCEditorTree.price(WCEditor.session()).total'), 0)

    def test_the_worn_dyed_item_taken_off_and_put_back_is_untouched(self):
        self.assertTrue(self.action(op='invoke', control='clothing.hats.remove').ok)
        self.assertTrue(self.action(op='set', control='clothing.hats.style', value=1).ok)
        t = self.working('.clothing.tints.hats')
        self.assertEqual((t.palette, t.tint0), ('metaped_tint_hat', 1))
        self.assertEqual(self.rt.eval('WCEditorTree.price(WCEditor.session()).total'), 0)

    def test_a_new_tint_still_follows_the_live_config(self):
        self.assertFalse(self.rt.eval("WCEditorTree.ownedTint == nil"))
        self.assertTrue(self.rt.eval("WCCatalog.validStoredTint('hats', { palette = 'metaped_tint_hat', tint0 = 1, tint1 = 1, tint2 = 1 })"))
        self.assertFalse(self.rt.eval("WCCatalog.validTint('hats', { palette = 'metaped_tint_hat', tint0 = 1, tint1 = 1, tint2 = 1 })"))


# ---------------------------------------------------------------------------------------------
#  Finding 10: runtime states on the owner's own re-render
# ---------------------------------------------------------------------------------------------
class OwnRuntimeStatesTests(unittest.TestCase):
    def setUp(self):
        self.rt = make_client()
        self.run = self.rt.run
        self.e = self.rt.eval
        self.run('''
            h = function(sex, c) return WCCatalog.forSex(sex)[c].models[1][1].hash end
            function fire(name, ...) fireEvent(name, nil, ...) end
            app = AppearanceSchema.default('male')
            app.clothing.equipped.neckwear = h('male', 'neckwear')
            withUp = WCUtil.copy(app); withUp.clothing.states = { bandana = 'up' }
        ''')

    def test_apply_appearance_keeps_the_runtime_state_it_carries(self):
        self.run('fire("w_creators:client:applyAppearance", withUp)')
        self.assertEqual(self.e('WCState.appearance.clothing.states.bandana'), 'up')

    def test_a_reload_of_the_saved_look_keeps_the_shown_runtime_state(self):
        self.run('fire("w_creators:client:applyAppearance", withUp)')
        self.run('Appearance.Sync.applyOwn(app, { keepRuntime = true })')
        self.assertEqual(self.e('WCState.appearance.clothing.states.bandana'), 'up')

    def test_a_plain_saved_look_without_keepRuntime_drops_it(self):
        self.run('fire("w_creators:client:applyAppearance", withUp)')
        self.run('fire("w_creators:client:applyAppearance", app)')
        self.assertIsNone(self.e('WCState.appearance.clothing.states.bandana'))

    def test_a_state_whose_item_is_gone_is_not_kept(self):
        self.run('fire("w_creators:client:applyAppearance", withUp)')
        self.run('bare = AppearanceSchema.default("male"); Appearance.Sync.applyOwn(bare, { keepRuntime = true })')
        self.assertIsNone(self.e('WCState.appearance.clothing.states.bandana'))

    def test_the_api_reload_keeps_runtime_states(self):
        src = read('client/api.lua')
        self.assertEqual(src.count('applyOwn(data.appearance, { keepRuntime = true })'), 1)
        self.assertEqual(src.count('applyOwn(saved, { keepRuntime = true })'), 1)


# ---------------------------------------------------------------------------------------------
#  Finding 20: blend-type-1 overlay layers have no Color
# ---------------------------------------------------------------------------------------------
UNTINTED = ('complex', 'disc', 'ageing', 'freckles', 'moles', 'spots', 'acne', 'scars')


class OverlayTintTests(EditorBase):
    def setUp(self):
        super().setUp()
        self.rt.load('client/appearance/overlays.lua')

    def test_creator_offers_no_color_for_the_untinted_layers(self):
        self.assertTrue(self.rt.eval("openEditor('creator', 'male', { identity = {} })"))
        tree = self.payload().tree
        reg = self.registry()
        for layer in UNTINTED:
            self.assertIsNotNone(self.rt.g.findNode(tree, 'overlay.%s.style' % layer), layer)
            self.assertIsNone(self.rt.g.findNode(tree, 'overlay.%s.color' % layer), layer)
            self.assertIsNone(reg['overlay.%s.color' % layer], layer)
        for layer in ('grime', 'blush', 'eyebrows'):
            self.assertIsNotNone(self.rt.g.findNode(tree, 'overlay.%s.color' % layer), layer)
        r = self.action(op='set', control='overlay.ageing.color', value=40)
        self.assertFalse(r.ok)

    def test_surgery_cannot_charge_a_colour_only_change(self):
        self.rt.run('''surgeryApp = AppearanceSchema.default('male')
            surgeryApp.overlays.ageing = { style = 3, color = 1, opacity = 1.0 }''')
        self.assertTrue(self.rt.eval("openEditor('surgery', 'male', { app = surgeryApp, context = { prices = {} } })"))
        self.assertIsNone(self.rt.g.findNode(self.payload().tree, 'overlay.ageing.color'))
        self.assertFalse(self.action(op='set', control='overlay.ageing.color', value=40).ok)
        self.assertFalse(self.rt.eval('WCEditor.session().working.overlays.ageing.color ~= 1'))

    def test_the_render_payload_carries_no_palette_for_them(self):
        lib, payload = self.rt.eval("Appearance.Overlays.payload('ageing', { style = 1, color = 40, opacity = 1.0 }, 'male')")
        self.assertEqual(lib, 'ageing')
        self.assertIsNone(payload['palette'])
        self.assertIsNone(payload['tint0'])
        _, payload = self.rt.eval("Appearance.Overlays.payload('grime', { style = 1, color = 3, opacity = 1.0 }, 'male')")
        self.assertEqual(payload['tint0'], 2)
        self.assertIsNotNone(payload['palette'])

    def test_a_shared_tint_flag_wins(self):
        self.assertFalse(self.rt.eval("Appearance.Overlays.tintable({ library = 'grime', tint = false })"))
        self.assertTrue(self.rt.eval("Appearance.Overlays.tintable({ library = 'ageing', tint = true })"))
        self.assertFalse(self.rt.eval("Appearance.Overlays.tintable('scars')"))


# ---------------------------------------------------------------------------------------------
#  Findings 21, 26, 27: the creator / wardrobe trees
# ---------------------------------------------------------------------------------------------
class TaxonomyTreeTests(EditorBase):
    def creator(self, opts="{ identity = {} }"):
        self.assertTrue(self.rt.eval("openEditor('creator', 'male', %s)" % opts))
        return self.payload()

    def test_free_creator_lists_the_starting_outfits_as_the_eighth_group(self):
        clothing = self.rt.g.findNode(self.creator().tree, 'clothing')
        groups = ids(clothing.children)
        self.assertEqual(len(groups), 8)
        self.assertEqual(groups[-1], 'tax.outfits')
        preset = self.rt.g.findNode(clothing, 'starter.preset')
        # 'none' then every Config.StartingOutfits preset of the sex (worker, traveler and the game's
        # matching sets), in config order
        count = int(self.rt.eval('#Config.StartingOutfits.male'))
        self.assertGreaterEqual(count, 2)
        self.assertEqual([o.value for o in lua_list(preset.options)], list(range(count + 1)))
        r = self.action(op='set', control='starter.preset', value=2)
        self.assertTrue(r.ok, r.code)
        self.assertEqual(self.rt.eval("WCEditor.session().working.clothing.equipped.hats"),
                         self.rt.eval("WCCatalog.forSex('male').hats.models[1][1].hash"))

    def test_free_creator_presets_keep_to_the_allowed_categories(self):
        self.rt.run("Config.Creator.startingClothing.categories = { 'shirts_full', 'pants' }")
        self.creator()
        self.assertTrue(self.action(op='set', control='starter.preset', value=2).ok)
        equipped = self.rt.eval('WCEditor.session().working.clothing.equipped')
        self.assertEqual(sorted(k for k in equipped.keys()), ['pants', 'shirts_full'])
        self.rt.run("Config.Creator.startingClothing.categories = '*'")

    def test_presets_mode_is_unchanged(self):
        self.rt.run("Config.Creator.startingClothing.mode = 'presets'")
        clothing = self.rt.g.findNode(self.creator().tree, 'clothing')
        self.assertEqual(ids(clothing.children), ['starter.preset'])
        self.rt.run("Config.Creator.startingClothing.mode = 'free'")

    def test_wardrobe_outfits_sit_beside_the_item_groups(self):
        self.rt.eval("openEditor('wardrobe', 'male', { context = { owned = {}, outfits = {}, maxOutfits = 3 } })")
        tree = self.payload().tree
        self.assertNotIn('outfits', ids(tree.children))
        items = self.rt.g.findNode(tree, 'items')
        # the last group is Outfits; after it only the "take off every garment" action row
        groups = [c.id for c in lua_list(items.children) if c.kind == 'group']
        self.assertEqual(groups[-1], 'outfits')
        self.assertEqual(ids(items.children)[-1], 'clothing.undress')
        self.assertEqual(items.label, 'الملابس')

    def test_a_stage_list_without_identity_and_review_gets_them(self):
        self.rt.run("SavedStages = Config.Creator.stages; Config.Creator.stages = { 'body', 'face', 'clothing' }")
        try:
            stages = [s.id for s in lua_list(self.creator().stages)]
            self.assertEqual(stages[0], 'identity')
            self.assertEqual(stages[-1], 'review')
            self.assertEqual(stages[1:-1], ['body', 'face', 'clothing'])
            # the repair creator (no identity to type) gets no identity stage
            self.rt.run('WCEditor.close()')
            self.rt.eval("openEditor('creator', 'male', {})")
            self.assertNotIn('identity', [s.id for s in lua_list(self.payload().stages)])
        finally:
            self.rt.run('Config.Creator.stages = SavedStages')

    def test_the_taxonomy_order_is_honoured_with_a_stable_tie_break(self):
        self.rt.run("for _, g in ipairs(Config.Clothing.taxonomy) do if g.id == 'accessories' then g.order = 0 end end")
        try:
            clothing = self.rt.g.findNode(self.creator().tree, 'clothing')
            self.assertEqual(ids(clothing.children)[0], 'tax.accessories')
            self.rt.run('WCEditor.close()')
            self.rt.eval("openEditor('store', 'male', { context = { storeProfile = 'general' } })")
            self.assertEqual(ids(self.payload().tree.children)[0], 'tax.accessories')
        finally:
            self.rt.run("for _, g in ipairs(Config.Clothing.taxonomy) do if g.id == 'accessories' then g.order = 7 end end")
        out = self.rt.eval("WCEditorTree.ordered({ { id = 'a', order = 2 }, { id = 'b', order = 1 }, { id = 'c', order = 2 }, { id = 'd' }, 'x' })")
        self.assertEqual([e.id for e in lua_list(out)], ['b', 'a', 'c', 'd'])

    def test_clothing_actions_follow_the_taxonomy_order(self):
        self.rt.run('''actApp = AppearanceSchema.default('male')
            actApp.clothing.equipped.hats = WCCatalog.forSex('male').hats.models[1][1].hash
            actApp.clothing.equipped.neckwear = WCCatalog.forSex('male').neckwear.models[1][1].hash''')
        before = ids(self.rt.eval('WCEditorTree.clothingActions(actApp)'))
        self.assertEqual(before[:2], ['states.head', 'states.neck'])
        self.rt.run("for _, g in ipairs(Config.Clothing.taxonomy) do if g.id == 'neck' then g.order = 0 end end")
        try:
            after = ids(self.rt.eval('WCEditorTree.clothingActions(actApp)'))
            self.assertEqual(after[:2], ['states.neck', 'states.head'])
        finally:
            self.rt.run("for _, g in ipairs(Config.Clothing.taxonomy) do if g.id == 'neck' then g.order = 2 end end")

    def test_the_quick_panel_sort_is_stable(self):
        src = read('client/clothing/states.lua')
        self.assertIn('return x.index < y.index', src)


# ---------------------------------------------------------------------------------------------
#  Finding 25: a closed location
# ---------------------------------------------------------------------------------------------
class ClosedLocationTests(unittest.TestCase):
    def setUp(self):
        self.rt = make_commerce()
        self.run = self.rt.run
        self.e = self.rt.eval
        self.run('Config.Locations[1].hours = { open = 6, close = 22 }; GlobalState = { [WCServicePoints.HOUR_KEY] = 23 }')
        self.run('WCLocations.reload(); Walkups = {}; BlipsMade = {}; WCServicePoints.build()')
        self.run("P = nil; for _, p in ipairs(WCServicePoints.points()) do if p.loc.id == 'valentine_clothing' then P = p end end")

    def tearDown(self):
        self.run('GlobalState = nil')

    def test_the_prompt_stays_disabled_with_a_closed_title(self):
        self.assertTrue(self.e('P.prompt.opts.canInteract()'))
        self.assertFalse(self.e('P.prompt.enabled.J'))
        self.assertEqual(self.e('P.prompt.title'), 'متجر الملابس · فالنتاين · مغلق · يفتح الساعة 06:00')
        # the action itself still refuses
        self.run('Opened = {}; WCStore.open = function(id) Opened[#Opened + 1] = id end; P.prompt.opts.prompts[1].onComplete()')
        self.assertEqual(self.e('#Opened'), 0)

    def test_it_opens_again_with_the_hour(self):
        self.run('GlobalState[WCServicePoints.HOUR_KEY] = 8; P.prompt.opts.canInteract()')
        self.assertTrue(self.e('P.prompt.enabled.J'))
        self.assertEqual(self.e('P.prompt.title'), 'متجر الملابس · فالنتاين')

    def test_the_closed_title_is_translated(self):
        en = json.loads(read('locales/en.json'))
        ar = json.loads(read('locales/ar.json'))
        self.assertEqual(en['مغلق · يفتح الساعة %s'], 'Closed · opens at %s')
        self.assertIn('مغلق · يفتح الساعة %s', ar)
        self.assertIn('إلغاء', en)
        self.assertIn('إلغاء', ar)


# ---------------------------------------------------------------------------------------------
#  Finding 29: one Arabic spelling per town
# ---------------------------------------------------------------------------------------------
class TownSpellingTests(unittest.TestCase):
    def test_barber_towns_use_the_spawn_spelling(self):
        towns = set(re.findall(r"town = '([^']+)'", read('config/locations.lua')))
        labels = set(re.findall(r"label = '([^']+)'", read('config/spawn.lua')))
        en = json.loads(read('locales/en.json'))
        by_english = {}
        for key in towns | labels:
            if key in en:
                by_english.setdefault(en[key], set()).add(key)
        doubles = {k: v for k, v in by_english.items() if len(v) > 1}
        self.assertEqual(doubles, {})
        for orphan in ('ستروبري', 'أنيسبرغ'):
            self.assertNotIn(orphan, en)
            self.assertNotIn(orphan, json.loads(read('locales/ar.json')))


# ---------------------------------------------------------------------------------------------
#  Findings 30, 31: the remote scope watcher
# ---------------------------------------------------------------------------------------------
WATCH_SETUP = r'''
app = AppearanceSchema.default('male')
function fire(name, ...) fireEvent(name, nil, ...) end
Remotes = {}
for i = 1, 8 do
    local ped = makePed('mp_male', 10.0 + i, 0.0, 0.0)
    Peds[ped].ready = false
    RemotePlayers[20 + i] = ped
    Remotes[i] = ped
    Appearance.Sync.set(20 + i, WCUtil.copy(app))
end
'''


class ParallelWatcherTests(unittest.TestCase):
    def setUp(self):
        self.rt = make_client()
        self.run = self.rt.run
        self.e = self.rt.eval
        self.run(WATCH_SETUP)

    def test_a_crowd_is_rendered_in_parallel_threads(self):
        self.run('clearLog(); Appearance.Sync.tick(); tick(0)')
        # the tick returned at once; MAX_CONCURRENT renders started together (each waits for its ped)
        self.assertEqual(self.e('count("preset")'), self.e('Appearance.Sync.MAX_CONCURRENT'))
        self.assertEqual(self.e('Appearance.Sync.running()'), self.e('Appearance.Sync.MAX_CONCURRENT'))
        self.run('for _, p in ipairs(Remotes) do Peds[p].ready = true end')
        for _ in range(8):
            self.run('tick(1000)')
        self.assertEqual(self.e('count("preset")'), 8)
        self.assertEqual(self.e('Appearance.Sync.running()'), 0)
        # every player rendered once: no further passes render again
        self.run('tick(1000); tick(1000)')
        self.assertEqual(self.e('count("preset")'), 8)

    def test_the_tick_itself_never_blocks(self):
        self.assertIn('CreateThread(function()', read('client/appearance/sync.lua').split('function Sync.tick()')[1][:1500])


class IncrementalRemoteTests(unittest.TestCase):
    def setUp(self):
        self.rt = make_client()
        self.run = self.rt.run
        self.e = self.rt.eval
        self.run('''
            app = AppearanceSchema.default('male')
            remote = makePed('mp_male', 10.0, 0.0, 0.0)
            RemotePlayers[5] = remote
            function fire(name, ...) fireEvent(name, nil, ...) end
            fire("w_creators:client:applyRemoteAppearance", 5, app)
        ''')
        self.assertEqual(self.e('count("preset")'), 1)

    def test_an_identical_rebroadcast_renders_nothing(self):
        self.run('clearLog(); fire("w_creators:client:applyRemoteAppearance", 5, WCUtil.copy(app)); tick(1000); tick(1000)')
        self.assertEqual(self.e('#Log'), 0)

    def test_a_hat_only_change_is_drawn_incrementally(self):
        self.run('''hatted = WCUtil.copy(app)
            hatted.clothing.equipped.hats = WCCatalog.forSex('male').hats.models[1][1].hash
            clearLog(); fire("w_creators:client:applyRemoteAppearance", 5, hatted)''')
        self.assertEqual(self.e('count("preset")'), 0)
        self.assertEqual(self.e('count("component.removeAllClothes")'), 0)
        self.assertEqual(self.e('count("component.apply")'), 1)
        self.assertEqual(self.e('Appearance.Sync.get(5).clothing.equipped.hats'), self.e('hatted.clothing.equipped.hats'))
        # applied once: the watcher does not render it again
        self.run('clearLog(); tick(1000); tick(1000)')
        self.assertEqual(self.e('#Log'), 0)

    def test_a_new_ped_is_rendered_in_full(self):
        self.run('''hatted = WCUtil.copy(app)
            hatted.clothing.equipped.hats = WCCatalog.forSex('male').hats.models[1][1].hash
            respawned = makePed('mp_male'); RemotePlayers[5] = respawned
            clearLog(); fire("w_creators:client:applyRemoteAppearance", 5, hatted)''')
        self.assertEqual(self.e('count("preset")'), 1)

    def test_a_sex_change_falls_back_to_the_full_render(self):
        self.run('''fem = makePed('mp_female'); RemotePlayers[5] = fem
            clearLog(); fire("w_creators:client:applyRemoteAppearance", 5, AppearanceSchema.default('female'))''')
        self.assertEqual(self.e('count("preset")'), 1)


if __name__ == '__main__':
    unittest.main()
