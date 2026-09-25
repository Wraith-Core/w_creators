"""Appearance pipeline (client/appearance/pipeline.lua + overlays.lua): call order, the structural
commits only (no per-feature refresh), overlays on the committed head, readiness of a lying ped,
morphology reset and float values, clothing states, tints, failure handling,
incremental previews and the player model switch."""
import unittest

from test_client_infra_support import make_client

SETUP = r'''
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
function lastIndex(op)
    local found
    for i, e in ipairs(Log) do if e.op == op then found = i end end
    return found
end
app = AppearanceSchema.default('male')
app.hair.facial = h('male', 'mustache')
app.morph = { jawWidth = 1, noseSize = -0.5 }
app.body.height = 1
app.body.weight = 3
app.clothing.equipped.hats = h('male', 'hats')
app.clothing.equipped.coats = h('male', 'coats')
app.clothing.equipped.vests = h('male', 'vests')
app.clothing.tints.shirts_full = { palette = 'metaped_tint_generic_clean', tint0 = 5, tint1 = 6, tint2 = 7 }
'''


class PipelineTests(unittest.TestCase):
    def setUp(self):
        self.rt = make_client()
        self.rt.run(SETUP)
        self.e = self.rt.eval
        self.run = self.rt.run

    def restore(self, extra=''):
        self.run(extra + '\nclearLog(); ok, err, failed = Appearance.RestoreCharacter(MyPed, app)')
        return self.e('ok'), self.e('err')

    def test_call_order(self):
        ok, err = self.restore()
        self.assertTrue(ok, err)
        idx = lambda expr: self.e('(%s)' % expr)
        seq = [
            idx('indexOf("preset")'),
            idx('indexOf("updateVariation")'),
            idx('indexOf("component.removeAllClothes")'),
            idx('applied("BODIES_LOWER")'),
            idx('applied("BODIES_UPPER")'),
            idx('applied("heads")'),
            idx('applied("eyes")'),
            idx('applied("teeth")'),
            idx('applied("hair")'),
            idx('applied(Appearance.FACIAL_HAIR_CATEGORY)'),
            idx('indexOf("EquipMetaPedOutfit")'),
            idx('indexOf("SetPedScale")'),
            idx('applied("pants")'),
            idx('applied("shirts_full")'),
            idx('applied("boots")'),
            idx('applied("vests")'),
            idx('applied("coats")'),
            idx('applied("hats")'),
            idx('entries("updateVariation")[2].i'),   # the body commit (waist outfit, clothing)
            idx('indexOf("component.collarClose")'),  # the states act on committed items
            idx('indexOf("setExpression")'),
            idx('lastIndex("setExpression")'),
            idx('lastIndex("updateVariation")'),      # the final refresh
            idx('indexOf("pedTexture.overwriteBodyPart")'),
            idx('indexOf("pedTexture.refreshNow")'),
        ]
        self.assertTrue(all(i is not None for i in seq), seq)
        self.assertEqual(seq, sorted(seq))
        # the clothing follows Config.Clothing.applyOrder
        order = self.rt.py(self.e('Config.Clothing.applyOrder'))
        order = [order[k] for k in sorted(order)]
        self.assertLess(order.index('pants'), order.index('shirts_full'))
        self.assertLess(order.index('coats'), order.index('hats'))
        # the preset is 3 and the waist is WAIST_TYPES[weight]
        self.assertEqual(self.e('Log[indexOf("preset")].args[2]'), 3)
        self.assertEqual(self.e('Log[indexOf("EquipMetaPedOutfit")].args[2]'), self.e('Appearance.WAIST_TYPES[3]'))

    def test_only_structural_commits(self):
        self.restore()
        # the preset commit, the body commit (waist before morph) and the final refresh: never per feature
        self.assertEqual(self.e('count("updateVariation")'), 3)
        self.assertEqual(self.e('count("preRefresh")'), 3)
        commits = [self.e('entries("updateVariation")[%d].i' % k) for k in (1, 2, 3)]
        # the body commit comes after every component / waist / scale application ...
        for op in ('component.apply', 'EquipMetaPedOutfit', 'SetPedScale'):
            last = self.e('lastIndex("%s")' % op)
            if last is not None:
                self.assertLess(last, commits[1], op)
                self.assertGreater(last, commits[0], op)
        # ... and only the wearable states (w_lib reads the committed item back) and the morph sit
        # between the body commit and the final refresh
        between = self.rt.py(self.e('''(function(a, b) local out = {}
            for i = a + 1, b - 1 do out[#out + 1] = Log[i].op end return out end)(%d, %d)''' % (commits[1], commits[2]))).values()
        states = {'component.setWearableState', 'component.collarClose', 'component.sleeveUnroll'}
        self.assertEqual(set(between) - {'preRefresh'} - states, {'setExpression'})
        ops = [op for op in between if op != 'preRefresh']
        self.assertEqual(ops[-1], 'setExpression')
        self.assertTrue(set(ops[:ops.index('setExpression')]) <= states)
        # nothing refreshes through w_lib in between
        self.assertEqual(self.e('count("component.refreshPed")'), 0)
        self.assertEqual(self.e('count("component.setWaistType")'), 0)

    def test_overlays_follow_the_committed_head(self):
        # w.pedTexture reads the albedo of the head the ped carries: the head is committed first
        self.restore()
        last_refresh = self.e('lastIndex("updateVariation")')
        self.assertGreater(self.e('indexOf("pedTexture.overwriteBodyPart")'), last_refresh)
        self.assertLess(self.e('(applied("heads"))'), last_refresh)
        self.assertEqual(self.e('count("updateVariation")'), 3)  # refreshNow commits the texture itself

    def test_lying_ped_is_ready(self):
        # downed / hogtied / ragdolled: the head is level with the origin, but the skeleton is intact
        self.run('Peds[MyPed].boneHeight = 0.05; Peds[MyPed].boneX = 0.62')
        self.assertTrue(self.e('Appearance.IsReady(MyPed)'))
        self.run('Peds[MyPed].boneHeight = 0.05; Peds[MyPed].boneX = -0.62')
        self.assertTrue(self.e('Appearance.IsReady(MyPed)'))
        t0 = self.e('GetGameTimer()')
        ok, err = self.restore()
        self.assertTrue(ok, err)
        self.assertLess(self.e('GetGameTimer()') - t0, 1000)   # no readiness timeout was waited
        # collapsed: every bone at the origin, whatever the orientation
        self.run('Peds[MyPed].boneHeight = 0; Peds[MyPed].boneX = 0')
        self.assertFalse(self.e('Appearance.IsReady(MyPed)'))

    def test_morph_reset_then_values_as_floats(self):
        self.restore()
        n_fields = self.e('#WCMorph.fields')
        self.assertGreater(n_fields, 50)
        self.assertEqual(self.e('#entries("setExpression")'), n_fields + 2)
        self.assertTrue(self.e('''(function()
            local es = entries("setExpression")
            for i = 1, #WCMorph.fields do if es[i].args[3] ~= 0.0 then return false end end
            for _, e in ipairs(es) do if math.type(e.args[3]) ~= "float" then return false end end
            return true end)()'''))
        jaw = self.e('WCMorph.byId.jawWidth.expression')
        nose = self.e('WCMorph.byId.noseSize.expression')
        values = self.rt.py(self.e('''(function() local out = {}
            local es = entries("setExpression")
            for i = #WCMorph.fields + 1, #es do out[es[i].args[2]] = es[i].args[3] end return out end)()'''))
        self.assertEqual(values, {jaw: 1.0, nose: -0.5})
        # height reached the native as a float (the JSON integer 1)
        self.assertEqual(self.e('math.type(Log[indexOf("SetPedScale")].args[2])'), 'float')

    def test_overlays_go_through_ped_texture(self):
        self.restore('app.overlays.blush = { style = 2, color = 3, opacity = 0.5 }')
        args = self.e('Log[indexOf("pedTexture.overwriteBodyPart")].args')
        self.assertEqual(args[2], 'heads')
        overlay_set = self.rt.py(args[3])
        self.assertEqual(overlay_set['blush'], {'id': 1, 'opacity': 0.5, 'palette': 'metaped_tint_makeup', 'tint0': 2})
        self.assertEqual(overlay_set['eyebrow']['palette'], 'metaped_tint_hair')
        self.assertEqual(overlay_set['eyebrow']['id'], 12)
        self.assertTrue(args[4])
        # skipOverlays
        self.run('clearLog(); Appearance.RestoreCharacter(MyPed, app, { skipOverlays = true })')
        self.assertEqual(self.e('count("pedTexture.overwriteBodyPart")'), 0)

    def test_tints_reach_w_component(self):
        self.restore()
        data = self.rt.py(self.e('select(2, applied("shirts_full"))'))
        self.assertEqual(data['palette'], 'metaped_tint_generic_clean')
        self.assertEqual((data['tint0'], data['tint1'], data['tint2']), (5, 6, 7))
        self.assertNotIn('palette', self.rt.py(self.e('select(2, applied("pants"))')))

    def test_visibility_states_skip_and_wearable_states_apply(self):
        ok, err = self.restore('''
            app.clothing.equipped.neckwear = h('male', 'neckwear')
            app.clothing.states = { hat = 'off', coat = 'off', bandana = 'up', sleeves = 'rolled', boots = 'under' }
        ''')
        self.assertTrue(ok, err)
        self.assertIsNone(self.e('applied("hats")'))
        self.assertIsNone(self.e('applied("coats")'))
        self.assertIsNotNone(self.e('applied("vests")'))
        # equipped is unchanged by a hidden state
        self.assertTrue(self.e('app.clothing.equipped.hats ~= nil'))
        wearable = self.rt.py(self.e('''(function() local out = {}
            for _, e in ipairs(entries("component.setWearableState")) do out[e.args[2]] = e.args[4] end
            return out end)()'''))
        # the vest over the pants (vestTuck's default) is set too, like the collar below
        self.assertEqual(wearable, {'neckwear': 'mask_up', 'boots': 'under_pants', 'vests': 'base'})
        self.assertEqual(self.e('count("component.sleeveRoll")'), 1)
        self.assertEqual(self.e('count("component.collarClose")'), 1)   # the default is still set
        # the states come after the clothing and before the refresh
        self.assertLess(self.e('applied("hats") or lastIndex("component.apply")'),
                        self.e('indexOf("component.sleeveRoll")'))
        self.run('clearLog(); Appearance.RestoreCharacter(MyPed, app, { skipStates = true })')
        self.assertEqual(self.e('count("component.sleeveRoll") + count("component.setWearableState")'), 0)

    def test_boots_state_needs_pants(self):
        # without pants the boots cannot be tucked: w_lib's remembered 'under_pants' is reset to base
        self.restore('app.clothing.equipped.pants = nil; app.clothing.states = { boots = "under" }')
        calls = self.rt.py(self.e('''(function() local out = {}
            for _, e in ipairs(entries("component.setWearableState")) do out[#out + 1] = { e.args[2], e.args[4] } end
            return out end)()'''))
        # (the vest has its own tuck state, vestTuck, which needs the pants too: reset to base as well)
        self.assertEqual(list(calls.values()), [{1: 'boots', 2: 'base'}, {1: 'vests', 2: 'base'}])
        self.assertGreater(self.e('indexOf("component.setWearableState")'), self.e('(applied("boots"))'))
        # the reset reads the committed boots back: it follows the body commit
        self.assertGreater(self.e('indexOf("component.setWearableState")'), self.e('entries("updateVariation")[2].i'))
        self.assertLess(self.e('indexOf("component.setWearableState")'), self.e('lastIndex("updateVariation")'))
        # nothing is reset for the boots when they are not equipped either
        self.restore('app.clothing.equipped.boots = nil')
        boots = self.e('''(function() local n = 0
            for _, e in ipairs(entries("component.setWearableState")) do if e.args[2] == "boots" then n = n + 1 end end
            return n end)()''')
        self.assertEqual(boots, 0)

    def test_invalid_ped_and_model_mismatch_do_not_throw(self):
        self.run('clearLog(); ok, err = Appearance.RestoreCharacter(99999, app)')
        self.assertFalse(self.e('ok'))
        self.assertEqual(self.e('err'), 'INVALID_PED')
        self.run('clearLog(); ok, err = Appearance.RestoreCharacter(MyPed, AppearanceSchema.default("female"))')
        self.assertFalse(self.e('ok'))
        self.assertEqual(self.e('err'), 'MODEL_MISMATCH')
        self.assertEqual(self.e('#Log'), 0)
        self.run('ok, err = Appearance.RestoreCharacter(nil, app)')
        self.assertEqual(self.e('err'), 'INVALID_PED')
        self.run('ok, failed, err = Appearance.ApplyDiff(MyPed, app, AppearanceSchema.default("female"))')
        self.assertFalse(self.e('ok'))
        self.assertEqual(self.e('err'), 'MODEL_MISMATCH')

    def test_unknown_component_is_reported_not_thrown(self):
        ok, err = self.restore('BadHashes[app.clothing.equipped.vests] = true')
        self.assertTrue(ok, err)
        self.assertEqual(self.rt.py(self.e('failed')), {1: 'vests'})
        self.assertIsNone(self.e('applied("vests")'))
        self.assertIsNotNone(self.e('applied("coats")'))

    def test_ped_not_ready_fails_after_timeout(self):
        self.run('Peds[MyPed].ready = false; t0 = GetGameTimer()')
        ok, err = self.restore()
        self.assertFalse(ok)
        self.assertEqual(err, 'NOT_READY')
        # a stalled ped is waited on after the preset and at the end, not at the body commit too
        self.assertLessEqual(self.e('GetGameTimer() - t0'), 2 * self.e('Appearance.READY_TIMEOUT') + 100)
        self.run('Peds[MyPed].ready = true; Peds[MyPed].boneHeight = 0')  # collapsed skeleton
        self.assertFalse(self.e('Appearance.IsReady(MyPed)'))

    def test_female_has_no_facial_hair(self):
        self.run('''female = makePed('mp_female'); fapp = AppearanceSchema.default('female')
            fapp.hair.facial = h('male', 'mustache'); clearLog()
            ok = Appearance.RestoreCharacter(female, fapp)''')
        self.assertTrue(self.e('ok'))
        self.assertIsNone(self.e('applied(Appearance.FACIAL_HAIR_CATEGORY)'))

    def test_apply_clothing_state_errors(self):
        self.assertEqual(self.e('select(2, Appearance.ApplyClothingState(MyPed, app, "nope", "on"))'), 'STATE_NOT_SUPPORTED')
        self.assertEqual(self.e('select(2, Appearance.ApplyClothingState(MyPed, app, "hat", "sideways"))'), 'INVALID_PAYLOAD')
        self.assertEqual(self.e('select(2, Appearance.ApplyClothingState(MyPed, app, "gloves", "off"))'), 'STATE_NOT_APPLICABLE')
        self.run('clearLog(); ok = Appearance.ApplyClothingState(MyPed, app, "coat", "off")')
        self.assertTrue(self.e('ok'))
        self.assertEqual(self.e('Log[1].op'), 'component.remove')
        self.assertEqual(self.e('Log[1].args[2]'), 'coats')
        self.run('clearLog(); ok = Appearance.ApplyClothingState(MyPed, app, "hat", "on")')
        self.assertEqual(self.e('Log[1].args[2]'), 'hats')
        self.assertEqual(self.e('count("updateVariation")'), 0)  # the caller refreshes

    def test_legacy_input_is_normalised(self):
        self.run('clearLog(); ok, err = Appearance.RestoreCharacter(MyPed, AppearanceSchema.toLegacy(app))')
        self.assertTrue(self.e('ok'), self.e('err'))
        self.assertIsNotNone(self.e('applied("coats")'))


class ApplyDiffTests(unittest.TestCase):
    def setUp(self):
        self.rt = make_client()
        self.rt.run(SETUP)
        self.rt.run('before = WCUtil.copy(app); after = WCUtil.copy(app)')
        self.e = self.rt.eval
        self.run = self.rt.run

    def diff(self, change):
        self.run(change + '\nclearLog(); ok, failed, err = Appearance.ApplyDiff(MyPed, before, after)')
        return self.e('ok')

    def test_falls_back_to_full_restore(self):
        for change in ('after.head.head = h("male", "heads", 2)',
                       'after.body.upper = h("male", "BODIES_UPPER", 2)',
                       'after.body.lower = h("male", "BODIES_LOWER", 2)'):
            self.run('after = WCUtil.copy(app)')
            self.assertTrue(self.diff(change), change)
            self.assertEqual(self.e('count("preset")'), 1, change)
        # sex change on the matching ped, and no `before`
        self.run('female = makePed("mp_female"); clearLog(); ok = Appearance.ApplyDiff(female, app, AppearanceSchema.default("female"))')
        self.assertTrue(self.e('ok'))
        self.assertEqual(self.e('count("preset")'), 1)
        self.run('clearLog(); ok = Appearance.ApplyDiff(MyPed, nil, app)')
        self.assertEqual(self.e('count("preset")'), 1)

    def test_minimal_ops(self):
        self.assertTrue(self.diff('after.hair.style = h("male", "hair", 2); after.morph.jawWidth = 0.25'))
        self.assertEqual(self.e('count("preset")'), 0)
        self.assertEqual(self.e('count("component.removeAllClothes")'), 0)
        self.assertEqual(self.e('count("component.apply")'), 1)
        self.assertEqual(self.e('Log[indexOf("component.apply")].args[2]'), 'hair')
        self.assertEqual(self.e('count("setExpression")'), 1)
        self.assertEqual(self.e('Log[indexOf("setExpression")].args[3]'), 0.25)
        self.assertEqual(self.e('count("updateVariation")'), 1)
        self.assertEqual(self.e('count("pedTexture.overwriteBodyPart")'), 0)

    def test_no_change_no_refresh(self):
        self.assertTrue(self.diff(''))
        self.assertEqual(self.e('#Log'), 0)

    def test_clothing_removal_state_and_tint_changes(self):
        self.assertTrue(self.diff('''after.clothing.equipped.vests = nil
            after.clothing.states.hat = 'off'
            after.clothing.tints.pants = { palette = 'metaped_tint_generic_clean', tint0 = 1, tint1 = 2, tint2 = 3 }
            after.clothing.states.sleeves = 'rolled' '''))
        removed = self.rt.py(self.e('''(function() local out = {}
            for _, e in ipairs(entries("component.remove")) do out[#out + 1] = e.args[2] end return out end)()'''))
        self.assertEqual(sorted(removed.values()), ['hats', 'vests'])
        self.assertEqual(self.e('count("component.apply")'), 1)
        self.assertEqual(self.e('Log[indexOf("component.apply")].args[2]'), 'pants')
        self.assertEqual(self.e('count("component.sleeveRoll")'), 1)
        # the re-dyed pants are the boots' requirement: they are committed before the boots state
        # (w_lib's setWearableState re-tints the pants it reads back), then the final refresh
        self.assertEqual(self.e('count("updateVariation")'), 2)
        self.assertLess(self.e('indexOf("component.apply")'), self.e('indexOf("updateVariation")'))
        self.assertGreater(self.e('indexOf("component.setWearableState")'), self.e('indexOf("updateVariation")'))

    def test_facial_hair_removal_and_failures(self):
        self.assertTrue(self.diff('after.hair.facial = 0'))
        self.assertEqual(self.e('Log[indexOf("component.remove")].args[2]'), self.e('Appearance.FACIAL_HAIR_CATEGORY'))
        self.run('before = WCUtil.copy(after); after = WCUtil.copy(after)')
        ok = self.diff('after.clothing.equipped.gloves = h("male", "gloves"); BadHashes[after.clothing.equipped.gloves] = true')
        self.assertTrue(ok)
        self.assertEqual(self.rt.py(self.e('failed')), {1: 'gloves'})

    def test_overlay_and_body_numbers(self):
        self.assertTrue(self.diff('after.overlays.blush = { style = 1, color = 1, opacity = 1 }; after.body.weight = 5; after.body.height = 1.05'))
        self.assertEqual(self.e('count("pedTexture.overwriteBodyPart")'), 1)
        self.assertEqual(self.e('Log[indexOf("EquipMetaPedOutfit")].args[2]'), self.e('Appearance.WAIST_TYPES[5]'))
        self.assertEqual(self.e('Log[indexOf("SetPedScale")].args[2]'), 1.05)
        # the overlays go on after the last commit
        self.assertGreater(self.e('indexOf("pedTexture.overwriteBodyPart")'), self.e('lastIndex("updateVariation")'))

    def test_waist_change_commits_then_sets_the_whole_morph(self):
        self.assertTrue(self.diff('after.body.weight = 7'))
        self.assertEqual(self.e('count("updateVariation")'), 2)
        waist = self.e('indexOf("EquipMetaPedOutfit")')
        commit = self.e('indexOf("updateVariation")')
        self.assertLess(waist, commit)
        # every channel is set again after the waist commit (reset + the values), then committed
        self.assertEqual(self.e('#entries("setExpression")'), self.e('#WCMorph.fields') + 2)
        self.assertGreater(self.e('indexOf("setExpression")'), commit)
        self.assertLess(self.e('lastIndex("setExpression")'), self.e('lastIndex("updateVariation")'))

    def test_only_overlays_changed_needs_no_refresh(self):
        self.assertTrue(self.diff('after.overlays.blush = { style = 1, color = 1, opacity = 1 }'))
        self.assertEqual(self.e('count("updateVariation")'), 0)
        self.assertEqual(self.e('count("pedTexture.overwriteBodyPart")'), 1)
        self.assertEqual(self.e('count("pedTexture.refreshNow")'), 1)

    def test_removing_the_pants_resets_tucked_boots(self):
        self.run('before.clothing.states.boots = "under"; after.clothing.states.boots = "under"')
        self.assertTrue(self.diff('after.clothing.equipped.pants = nil'))
        calls = self.rt.py(self.e('''(function() local out = {}
            for _, e in ipairs(entries("component.setWearableState")) do out[#out + 1] = { e.args[2], e.args[4] } end
            return out end)()'''))
        # (the vest's tuck state also needs the pants: it goes back to base with them)
        self.assertEqual(list(calls.values()), [{1: 'boots', 2: 'base'}, {1: 'vests', 2: 'base'}])
        # the pants back on: the stored 'under' is applied again
        self.run('before = WCUtil.copy(after); after = WCUtil.copy(app); after.clothing.states.boots = "under"')
        self.assertTrue(self.diff(''))
        self.assertEqual(self.e('Log[indexOf("component.setWearableState")].args[4]'), 'under_pants')


class PlayerTests(unittest.TestCase):
    def setUp(self):
        self.rt = make_client()
        self.rt.run(SETUP)
        self.e = self.rt.eval

    def test_restore_player_switches_model_on_the_new_ped(self):
        self.rt.run('''old = MyPed; clearLog()
            ok, err = Appearance.RestorePlayer(AppearanceSchema.default("female"))''')
        self.assertTrue(self.e('ok'), self.e('err'))
        self.assertNotEqual(self.e('old'), self.e('MyPed'))
        self.assertEqual(self.e('count("SetPlayerModel")'), 1)
        self.assertEqual(self.e('Log[indexOf("preset")].args[1]'), self.e('MyPed'))

    def test_restore_player_defaults_to_the_saved_appearance(self):
        self.assertEqual(self.e('select(2, Appearance.RestorePlayer())'), 'NO_CHARACTER')
        self.rt.run('WCState.set(app); clearLog(); ok = Appearance.RestorePlayer()')
        self.assertTrue(self.e('ok'))
        self.assertEqual(self.e('count("SetPlayerModel")'), 0)
        self.assertIsNotNone(self.e('applied("coats")'))
        self.assertEqual(self.e('select(2, Appearance.SetPlayerModel("martian"))'), 'INVALID_PAYLOAD')


if __name__ == '__main__':
    unittest.main()
