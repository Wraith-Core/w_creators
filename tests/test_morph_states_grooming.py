"""WCMorph, WCOverlays, WCClothingStates and WCGrooming."""
import unittest

from harness import Runtime


class MorphOverlayTests(unittest.TestCase):
    def setUp(self):
        self.rt = Runtime().load_shared()
        self.e = self.rt.eval

    def test_every_w_lib_expression_is_placed_once(self):
        expressions = self.rt.py(self.e('w.component.data.expressions'))
        fields = self.rt.py(self.e('WCMorph.fields'))
        ids = [f['id'] for f in fields.values()]
        self.assertEqual(len(ids), len(set(ids)))
        self.assertEqual(set(ids), set(expressions))
        for f in fields.values():
            self.assertEqual(f['expression'], expressions[f['id']])
            self.assertEqual((f['min'], f['max']), (-1, 1))
            self.assertTrue(f['label'])
        self.assertEqual(self.e('WCMorph.byExpression[34006].id'), 'headWidth')
        self.assertEqual(self.e('WCMorph.sectionOf("jawWidth")'), 'face')
        self.assertEqual(self.e('WCMorph.sectionOf("calves")'), 'body')
        self.assertIsNone(self.e('WCMorph.sectionOf("nope")'))
        warnings = [p.text for p in self.e('Printed').values() if p.level == 'warn']
        self.assertEqual(warnings, [])

    def test_hierarchy(self):
        groups = self.e('WCMorph.groups')
        self.assertEqual([groups[1].id, groups[2].id], ['face', 'body'])
        face = [c.id for c in groups[1].children.values()]
        self.assertEqual(face[0], 'face.base')
        self.assertIn('face.mouth', face)
        mouth = [c for c in groups[1].children.values() if c.id == 'face.mouth'][0]
        self.assertEqual([c.id for c in mouth.children.values()], ['face.mouth.left', 'face.mouth.right'])
        build = groups[2].children[1]
        # body.shape: the body build outfit (skinny ... brawny), next to the body model
        self.assertEqual(list(build.extras.values()), ['body.type', 'body.shape', 'body.height', 'body.weight'])

    def test_overlays(self):
        layers = self.rt.py(self.e('WCOverlays.layers'))
        self.assertEqual(len(layers), 18)
        sections = {}
        for layer in layers.values():
            sections.setdefault(layer['section'], []).append(layer['id'])
        self.assertEqual(sections['skin'], ['complex', 'disc', 'ageing', 'freckles', 'moles', 'spots', 'acne', 'scars', 'grime'])
        self.assertEqual(sections['makeup'], ['foundation', 'blush', 'lipsticks', 'eyeliners', 'shadows', 'paintedmasks'])
        self.assertEqual(sections['eyebrows'], ['eyebrows'])
        self.assertEqual(sections['hair'], ['hairov'])
        self.assertEqual(sections['facialHair'], ['beardstabble'])
        self.assertEqual(self.e('WCOverlays.byId.eyebrows.ids[1]'), 12)
        self.assertEqual(self.e('WCOverlays.byId.eyebrows.palette'), 'metaped_tint_hair')
        self.assertEqual(self.e('WCOverlays.byId.blush.palette'), 'metaped_tint_makeup')
        self.assertEqual(self.e('WCOverlays.byId.scars.library'), 'scar')
        self.assertTrue(self.e('WCOverlays.allowed("beardstabble", "male")'))
        self.assertFalse(self.e('WCOverlays.allowed("beardstabble", "female")'))


class ClothingStateTests(unittest.TestCase):
    def setUp(self):
        self.rt = Runtime().load_shared()
        self.e = self.rt.eval
        self.rt.run('''
            h = function(sex, c, m) return WCCatalog.forSex(sex)[c].models[m or 1][1].hash end
            app = AppearanceSchema.default("male")
            app.clothing.equipped.hats = h("male", "hats")
            app.clothing.equipped.neckwear = h("male", "neckwear")
        ''')

    def test_groups(self):
        groups = [g.id for g in self.e('WCClothingStates.groups').values()]
        # + the loadout side, the vest tuck and the two body-part states (the clothing store's
        #   wearable additions), after the original thirteen
        self.assertEqual(groups, ['hat', 'eyewear', 'mask', 'bandana', 'sleeves', 'collar', 'coat', 'vest',
                                  'poncho', 'gloves', 'boots', 'shirt', 'pants', 'loadout', 'vestTuck',
                                  'bodyUpper', 'bodyLower'])
        for g in self.e('WCClothingStates.groups').values():
            self.assertIn(g.verified, ('likely', 'experimental'))
            self.assertIn(g.persist, (True, False))
        self.assertTrue(self.e('WCClothingStates.isValid("bandana", "up")'))
        self.assertFalse(self.e('WCClothingStates.isValid("bandana", "rolled")'))
        self.assertFalse(self.e('WCClothingStates.isValid("nope", "on")'))

    def test_actions_only_for_equipped_and_different_targets(self):
        actions = self.rt.py(self.e('WCClothingStates.actions(app)'))
        by = {a['group']: a for a in actions.values()}
        self.assertEqual(list(by), ['hat', 'bandana', 'sleeves', 'collar', 'boots', 'shirt', 'pants'])
        self.assertEqual(by['hat']['current'], 'on')
        self.assertEqual(list(by['hat']['targets'].values()), ['off'])
        self.assertEqual(list(by['boots']['targets'].values()), ['under'])
        self.rt.run('app.clothing.states.hat = "off"; app.clothing.equipped.pants = nil')
        by = {a['group']: a for a in self.rt.py(self.e('WCClothingStates.actions(app)')).values()}
        self.assertEqual(list(by['hat']['targets'].values()), ['on'])
        self.assertNotIn('boots', by)  # boots under pants needs pants
        self.assertTrue(self.e('app.clothing.equipped.hats ~= nil'))  # a state never unequips
        self.assertEqual(self.e('WCClothingStates.category(app, "coat")'), None)
        self.rt.run('app.clothing.equipped.coats_closed = h("male", "coats_closed")')
        self.assertEqual(self.e('WCClothingStates.category(app, "coat")'), 'coats_closed')
        self.rt.run('Config.Services.clothingActions = false')
        self.assertEqual(self.e('#WCClothingStates.actions(app)'), 0)


class GroomingTests(unittest.TestCase):
    def setUp(self):
        self.rt = Runtime().load_shared()
        self.e = self.rt.eval
        self.rt.run('''
            G = WCGrooming
            name = function(c, hash) return WCCatalog.forSex("male")[c].hashes[hash].name end
            byName = function(n) return WCUtil.u32(GetHashKey(n)) end
            app = AppearanceSchema.default("male")
            app.hair.style = byName("CLOTHING_ITEM_M_HAIR_001_DArk_blonde")
            app.hair.facial = byName("CLOTHING_ITEM_M_BEARD_001_Brown")
            app = AppearanceSchema.sanitize(app)
        ''')

    def test_state_and_info(self):
        state = self.rt.py(self.e('G.state(app)'))
        self.assertEqual(state, {'hair': {'stage': 1, 'seconds': 0}, 'beard': {'stage': 1, 'seconds': 0}})
        info = self.rt.py(self.e('G.info(app)'))
        self.assertEqual(info['hair']['remainingMinutes'], 120)
        self.rt.run('f = AppearanceSchema.default("female")')
        self.assertEqual(list(self.rt.py(self.e('G.state(f)')).keys()), ['hair'])

    def test_advance_keeps_colour_and_caps(self):
        self.assertFalse(self.e('G.advance(app, 60)'))
        self.assertEqual(self.e('app.grooming.hair.seconds'), 60)
        self.assertTrue(self.e('G.advance(app, 3600)'))  # beard 60 min -> stage 2
        self.assertEqual(name := self.e('name("mustache", app.hair.facial)'), 'CLOTHING_ITEM_M_BEARD_004_Brown')
        self.assertEqual(self.e('app.grooming.beard.stage'), 2)
        self.assertTrue(self.e('G.advance(app, 7200 * 3)'))
        self.assertEqual(self.e('name("hair", app.hair.style)'), 'CLOTHING_ITEM_M_HAIR_008_DArk_blonde')
        self.assertEqual(self.e('app.grooming.hair.stage'), 3)
        self.assertEqual(self.e('app.grooming.hair.seconds'), 0)
        self.assertFalse(self.e('G.advance(app, 7200)'))
        self.assertFalse(self.e('G.advance(app, 0/0)'))
        self.assertTrue(name)

    def test_cut_resets_changed_kind_only(self):
        self.rt.run('G.advance(app, 1800); before = WCUtil.copy(app)')
        self.rt.run('app.hair.style = byName("CLOTHING_ITEM_M_HAIR_006_Brown"); G.cut(app, before)')
        self.assertEqual(self.rt.py(self.e('app.grooming.hair')), {'stage': 2, 'seconds': 0})
        self.assertEqual(self.e('app.grooming.beard.seconds'), 1800)
        self.rt.run('app.hair.style = 0; G.cut(app, before)')
        self.assertEqual(self.e('app.grooming.hair.stage'), 0)


if __name__ == '__main__':
    unittest.main()
