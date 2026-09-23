"""WCClothing (client/clothing/states.lua): the available actions, perform() guards, the per-action
lock, the server round trip with revert on failure, the experimental animation (interrupted before
its midpoint → unchanged; reached → applied), applyStates, the category exports and ownership safety.

Run: python3 -m unittest discover -s tests -p 'test_client_states_*.py'
"""
import unittest

from test_client_states_support import make_states_client, lua_list


def controls(rt):
    out = []
    for g in lua_list(rt.eval('WCClothing.available()')):
        for item in lua_list(g['items']):
            for a in lua_list(item['actions']):
                out.append(a['control'])
    return out


class AvailableTests(unittest.TestCase):
    def setUp(self):
        self.rt = make_states_client()

    def test_only_equipped_items_and_the_inverse_of_the_current_state(self):
        got = controls(self.rt)
        # hat on → only "take off"; bandana down → "pull up"; shirt: sleeves down → roll, collar closed → open
        self.assertEqual(got, ['state.hat.off', 'state.bandana.up', 'state.sleeves.rolled', 'state.collar.open'])
        # not equipped: no coat, vest, gloves, mask, eyewear; boots without pants: not applicable
        for absent in ('coat', 'vest', 'gloves', 'mask', 'eyewear', 'boots', 'poncho'):
            self.assertFalse(any(c.startswith('state.%s.' % absent) for c in got), absent)

    def test_removed_hat_offers_only_wear(self):
        self.rt.run("WCState.appearance.clothing.states.hat = 'off'")
        got = controls(self.rt)
        self.assertIn('state.hat.on', got)
        self.assertNotIn('state.hat.off', got)

    def test_boots_need_pants(self):
        self.rt.run('WCState.appearance.clothing.equipped.pants = PANTS')
        self.assertIn('state.boots.under', controls(self.rt))

    def test_hierarchy_group_item_action(self):
        groups = lua_list(self.rt.eval('WCClothing.available()'))
        self.assertEqual([g['id'] for g in groups], ['head', 'neck', 'upper'])
        upper = groups[2]
        items = lua_list(upper['items'])
        self.assertEqual(len(items), 1)
        self.assertEqual(items[0]['id'], 'shirts_full')
        self.assertEqual(items[0]['label'], 'القميص')
        self.assertEqual([a['group'] for a in lua_list(items[0]['actions'])], ['sleeves', 'collar'])

    def test_cloak_named_after_the_equipped_piece(self):
        self.rt.run("WCState.appearance.clothing.equipped.cloaks = COAT")
        groups = lua_list(self.rt.eval('WCClothing.available()'))
        upper = [g for g in groups if g['id'] == 'upper'][0]
        cloak = [i for i in lua_list(upper['items']) if i['id'] == 'ponchos'][0]
        self.assertEqual(cloak['label'], 'العباءة')
        self.assertEqual(lua_list(cloak['actions'])[0]['label'], 'خلع العباءة')

    def test_nothing_without_a_character_or_with_the_service_off(self):
        self.rt.run('WCState.clear()')
        self.assertEqual(controls(self.rt), [])
        self.rt.run('giveCharacter(); Config.Services.clothingActions = false')
        self.assertEqual(controls(self.rt), [])


class PerformTests(unittest.TestCase):
    def setUp(self):
        self.rt = make_states_client()

    def equipped(self):
        return dict(self.rt.eval('WCState.appearance.clothing.equipped').items())

    def test_success_applies_locally_then_persists(self):
        before = self.equipped()
        r = self.rt.eval("WCClothing.perform('hat', 'off')")
        self.assertTrue(r['ok'])
        ops = lua_list(self.rt.eval('ops()'))
        self.assertLess(ops.index('component.remove'), ops.index('callback:w_creators:clothing:setState'))
        self.assertIn('updateVariation', ops)  # one refresh after the local change
        calls = lua_list(self.rt.eval('setStateCalls()'))
        self.assertEqual([lua_list(c) for c in calls], [['hat', 'off']])
        self.assertEqual(self.rt.eval('WCState.appearance.clothing.states.hat'), 'off')
        self.assertEqual(self.equipped(), before)  # ownership / equipped untouched
        self.assertFalse(self.rt.eval("WCState.busy('clothingAction')"))

    def test_server_failure_reverts_and_notifies(self):
        self.rt.run("CallbackResults['w_creators:clothing:setState'] = WCResult.fail('ACTIONS_DISABLED')")
        before = self.equipped()
        r = self.rt.eval("WCClothing.perform('hat', 'off')")
        self.assertFalse(r['ok'])
        self.assertEqual(r['code'], 'ACTIONS_DISABLED')
        ops = lua_list(self.rt.eval('ops()'))
        # removed, server refused, re-applied (the equipped hash) → the previous visible state
        i_remove = ops.index('component.remove')
        i_call = ops.index('callback:w_creators:clothing:setState')
        i_apply = ops.index('component.apply')
        self.assertTrue(i_remove < i_call < i_apply)
        applied = [e for e in lua_list(self.rt.eval('Log')) if e['op'] == 'component.apply'][0]
        self.assertEqual(applied['args'][3]['hash'], self.rt.eval('HAT'))
        self.assertIsNone(self.rt.eval('WCState.appearance.clothing.states.hat'))
        self.assertEqual(self.equipped(), before)
        notes = lua_list(self.rt.eval('Notified'))
        self.assertEqual(len(notes), 1)
        self.assertEqual(notes[0]['description'], self.rt.eval("WCResult.messageKey('ACTIONS_DISABLED')"))
        self.assertFalse(self.rt.eval("WCState.busy('clothingAction')"))

    def test_callback_error_is_internal_error_and_reverts(self):
        self.rt.run("CallbackResults['w_creators:clothing:setState'] = function() error('timeout') end")
        r = self.rt.eval("WCClothing.perform('sleeves', 'rolled')")
        self.assertEqual(r['code'], 'INTERNAL_ERROR')
        ops = lua_list(self.rt.eval('ops()'))
        self.assertEqual(ops.count('component.sleeveRoll'), 1)
        self.assertEqual(ops.count('component.sleeveUnroll'), 1)
        self.assertLess(ops.index('component.sleeveRoll'), ops.index('component.sleeveUnroll'))
        self.assertIsNone(self.rt.eval('WCState.appearance.clothing.states.sleeves'))

    def test_panel_path_does_not_notify(self):
        self.rt.run("CallbackResults['w_creators:clothing:setState'] = WCResult.fail('RATE_LIMITED')")
        r = self.rt.eval("WCClothing.perform('hat', 'off', { notify = false })")
        self.assertEqual(r['code'], 'RATE_LIMITED')
        self.assertEqual(len(lua_list(self.rt.eval('Notified'))), 0)

    def assertRefused(self, code='BUSY'):
        r = self.rt.eval("WCClothing.perform('hat', 'off')")
        self.assertFalse(r['ok'])
        self.assertEqual(r['code'], code)
        self.assertEqual(lua_list(self.rt.eval('setStateCalls()')), [])
        self.assertNotIn('component.remove', lua_list(self.rt.eval('ops()')))
        self.assertIsNone(self.rt.eval('WCState.appearance.clothing.states.hat'))

    def test_refused_while_dead(self):
        self.rt.run('Peds[MyPed].dead = true')
        self.assertRefused('STATE_NOT_APPLICABLE')

    def test_refused_while_dying_ragdoll_or_in_combat(self):
        for flag in ('dying', 'ragdoll', 'combat', 'melee'):
            self.rt.run('Peds[MyPed].%s = true' % flag)
            self.assertRefused('STATE_NOT_APPLICABLE')
            self.rt.run('Peds[MyPed].%s = nil; clearLog()' % flag)

    def test_refused_in_editor_scene_and_flows(self):
        for setup, undo in (("WCState.busy('editor', true)", "WCState.busy('editor', false)"),
                            ("WCState.busy('selection', true)", "WCState.busy('selection', false)"),
                            ("WCState.busy('respawn', true)", "WCState.busy('respawn', false)"),
                            ("CreatorScene.isLoaded = function() return true end",
                             "CreatorScene.isLoaded = function() return false end")):
            self.rt.run(setup)
            self.assertRefused()
            self.rt.run(undo + '; clearLog()')

    def test_per_action_lock(self):
        self.rt.run("WCState.busy('clothingAction', true)")
        self.assertRefused()

    def test_mounted_allowed_without_animation(self):
        self.rt.run('Peds[MyPed].mounted = true')
        r = self.rt.eval("WCClothing.perform('hat', 'off')")
        self.assertTrue(r['ok'])

    def test_mounted_refused_when_an_animation_would_play(self):
        self.rt.run('Config.Experimental.clothingAnimations = true; Peds[MyPed].mounted = true')
        self.assertRefused('STATE_NOT_APPLICABLE')
        # a group without a configured animation is still allowed on a mount
        r = self.rt.eval("WCClothing.perform('collar', 'open')")
        self.assertTrue(r['ok'])

    def test_invalid_inputs(self):
        self.assertEqual(self.rt.eval("WCClothing.perform('hat', 'sideways')")['code'], 'STATE_NOT_SUPPORTED')
        self.assertEqual(self.rt.eval("WCClothing.perform('wings', 'on')")['code'], 'STATE_NOT_SUPPORTED')
        self.assertEqual(self.rt.eval("WCClothing.perform(nil, 'on')")['code'], 'INVALID_PAYLOAD')
        self.assertEqual(self.rt.eval("WCClothing.perform('coat', 'off')")['code'], 'STATE_NOT_APPLICABLE')
        self.rt.run('Config.Services.clothingActions = false')
        self.assertEqual(self.rt.eval("WCClothing.perform('hat', 'off')")['code'], 'ACTIONS_DISABLED')
        self.rt.run('Config.Services.clothingActions = true; WCState.clear()')
        self.assertEqual(self.rt.eval("WCClothing.perform('hat', 'off')")['code'], 'NO_CHARACTER')
        self.assertEqual(lua_list(self.rt.eval('setStateCalls()')), [])

    def test_same_value_is_a_no_op(self):
        r = self.rt.eval("WCClothing.perform('hat', 'on')")
        self.assertTrue(r['ok'])
        self.assertFalse(r['data']['changed'])
        self.assertEqual(lua_list(self.rt.eval('setStateCalls()')), [])

    def test_non_persisting_state_updates_memory(self):
        r = self.rt.eval("WCClothing.perform('bandana', 'up')")
        self.assertTrue(r['ok'])
        self.assertIn('component.setWearableState', lua_list(self.rt.eval('ops()')))
        self.assertEqual(self.rt.eval('WCState.appearance.clothing.states.bandana'), 'up')


class AnimationTests(unittest.TestCase):
    def setUp(self):
        self.rt = make_states_client('Config.Experimental.clothingAnimations = true')

    def test_interrupted_before_midpoint_leaves_state_unchanged(self):
        self.rt.run("performAsync('hat', 'off')")
        self.assertFalse(self.rt.eval('Done'))
        ops = lua_list(self.rt.eval('ops()'))
        self.assertIn('playAnim', ops)
        play = [e for e in lua_list(self.rt.eval('Log')) if e['op'] == 'playAnim'][0]
        self.assertEqual(play['args'][3], 'hat_off')
        self.assertTrue(self.rt.eval("WCState.busy('clothingAction')"))
        self.rt.run('tick(100)')
        self.rt.run('Peds[MyPed].ragdoll = true')
        self.rt.run('tick(100)')
        self.assertTrue(self.rt.eval('Done'))
        self.assertFalse(self.rt.eval('Result.ok'))
        self.assertEqual(self.rt.eval('Result.data.interrupted'), 'ragdoll')
        ops = lua_list(self.rt.eval('ops()'))
        self.assertIn('StopAnimTask', ops)
        self.assertNotIn('component.remove', ops)
        self.assertEqual(lua_list(self.rt.eval('setStateCalls()')), [])
        self.assertIsNone(self.rt.eval('WCState.appearance.clothing.states.hat'))
        self.assertFalse(self.rt.eval("WCState.busy('clothingAction')"))

    def test_interrupted_by_death_or_getting_into_a_vehicle(self):
        for flag in ('dead', 'enteringVehicle'):
            self.rt.run("clearLog(); Peds[MyPed].dead = nil; Peds[MyPed].enteringVehicle = nil; performAsync('hat', 'off')")
            self.rt.run('tick(100); Peds[MyPed].%s = true; tick(100)' % flag)
            self.assertTrue(self.rt.eval('Done'))
            self.assertFalse(self.rt.eval('Result.ok'))
            self.assertNotIn('component.remove', lua_list(self.rt.eval('ops()')))

    def test_reaching_the_midpoint_applies_fully(self):
        self.rt.run("performAsync('hat', 'off')")
        self.rt.run('for i = 1, 5 do tick(100) end')   # hat: 1200 ms, midpoint 600 ms
        self.assertFalse(self.rt.eval('Done'))
        self.assertNotIn('component.remove', lua_list(self.rt.eval('ops()')))
        self.rt.run('tick(100)')
        self.assertTrue(self.rt.eval('Done'))
        self.assertTrue(self.rt.eval('Result.ok'))
        ops = lua_list(self.rt.eval('ops()'))
        self.assertIn('component.remove', ops)
        self.assertNotIn('StopAnimTask', ops)
        self.assertEqual(self.rt.eval('WCState.appearance.clothing.states.hat'), 'off')

    def test_missing_dictionary_changes_the_state_without_animation(self):
        self.rt.run("AnimMissing = true")
        r = self.rt.eval("WCClothing.perform('hat', 'off')")
        self.assertTrue(r['ok'])
        ops = lua_list(self.rt.eval('ops()'))
        self.assertNotIn('playAnim', ops)
        self.assertIn('component.remove', ops)

    def test_mask_goes_on_from_the_neck(self):
        self.rt.run("WCState.appearance.clothing.equipped.masks = 7777; WCState.appearance.clothing.states.mask = 'off'")
        self.rt.run("performAsync('mask', 'on')")
        play = [e for e in lua_list(self.rt.eval('Log')) if e['op'] == 'playAnim'][0]
        self.assertEqual(play['args'][3], 'neck_2_face')

    def test_resource_stop_mid_animation_releases_everything(self):
        self.rt.run("performAsync('hat', 'off'); tick(100)")
        self.rt.run("fireEvent('onResourceStop', nil, 'w_creators')")
        self.assertIn('StopAnimTask', lua_list(self.rt.eval('ops()')))
        self.assertFalse(self.rt.eval("WCState.busy('clothingAction')"))
        self.rt.run('tick(100)')
        self.assertTrue(self.rt.eval('Done'))
        self.assertFalse(self.rt.eval('Result.ok'))
        self.assertNotIn('component.remove', lua_list(self.rt.eval('ops()')))


class HelperTests(unittest.TestCase):
    def setUp(self):
        self.rt = make_states_client()

    def test_apply_states_delegates_to_the_pipeline_with_one_refresh(self):
        self.rt.run("WCState.appearance.clothing.states.hat = 'off'; WCState.appearance.clothing.states.sleeves = 'rolled'")
        ok, failed = self.rt.eval('WCClothing.applyStates(PlayerPedId(), WCState.appearance)')
        self.assertTrue(ok)
        ops = lua_list(self.rt.eval('ops()'))
        self.assertIn('component.remove', ops)          # hat off
        self.assertIn('component.sleeveRoll', ops)      # sleeves rolled
        self.assertIn('component.collarClose', ops)     # collar default
        self.assertEqual(ops.count('updateVariation'), 1)
        self.assertEqual(lua_list(self.rt.eval('setStateCalls()')), [])

    def test_category_exports_map_to_visibility_groups(self):
        self.assertEqual(self.rt.eval("WCClothing.groupOfCategory('hats')"), 'hat')
        self.assertEqual(self.rt.eval("WCClothing.groupOfCategory('coats_closed')"), 'coat')
        self.assertEqual(self.rt.eval("WCClothing.groupOfCategory('cloaks')"), 'poncho')
        self.assertIsNone(self.rt.eval("WCClothing.groupOfCategory('shirts_full')"))  # wearable: not a visibility group
        r = self.rt.eval("Exported.RemoveClothingCategory('hats')")
        self.assertTrue(r['ok'])
        self.assertEqual(self.rt.eval('WCState.appearance.clothing.states.hat'), 'off')
        r = self.rt.eval("Exported.RestoreClothingCategory('hats')")
        self.assertTrue(r['ok'])
        self.assertEqual(self.rt.eval('WCState.appearance.clothing.states.hat'), 'on')
        r = self.rt.eval("Exported.RemoveClothingCategory('shirts_full')")
        self.assertEqual(r['code'], 'STATE_NOT_SUPPORTED')

    def test_toggle_exports(self):
        self.assertTrue(self.rt.eval('Exported.ToggleHat()')['ok'])
        self.assertEqual(self.rt.eval('WCState.appearance.clothing.states.hat'), 'off')
        self.assertTrue(self.rt.eval('Exported.ToggleHat()')['ok'])
        self.assertEqual(self.rt.eval('WCState.appearance.clothing.states.hat'), 'on')
        self.assertTrue(self.rt.eval('Exported.ToggleBandana()')['ok'])
        self.assertEqual(self.rt.eval('WCState.appearance.clothing.states.bandana'), 'up')
        self.assertTrue(self.rt.eval('Exported.ToggleSleeves()')['ok'])
        self.assertEqual(self.rt.eval('WCState.appearance.clothing.states.sleeves'), 'rolled')
        self.assertTrue(self.rt.eval("Exported.SetClothingState('collar', 'open')")['ok'])
        self.assertEqual(self.rt.eval('WCState.appearance.clothing.states.collar'), 'open')

    def test_every_export_is_registered(self):
        names = set(self.rt.eval('Exported').keys())
        self.assertTrue({'OpenClothingActions', 'SetClothingState', 'ToggleHat', 'ToggleBandana', 'ToggleSleeves',
                         'RemoveClothingCategory', 'RestoreClothingCategory'} <= names)

    def test_no_ownership_mutation_across_every_action(self):
        before = dict(self.rt.eval('WCState.appearance.clothing.equipped').items())
        self.rt.run("Exported.ToggleHat(); Exported.ToggleBandana(); Exported.ToggleSleeves();"
                    "Exported.SetClothingState('collar', 'open'); Exported.RemoveClothingCategory('hats')")
        self.rt.run("CallbackResults['w_creators:clothing:setState'] = WCResult.fail('BUSY'); Exported.ToggleHat()")
        self.assertEqual(dict(self.rt.eval('WCState.appearance.clothing.equipped').items()), before)
        callbacks = {op for op in lua_list(self.rt.eval('ops("callback:")'))}
        self.assertEqual(callbacks, {'callback:w_creators:clothing:setState'})


if __name__ == '__main__':
    unittest.main()
