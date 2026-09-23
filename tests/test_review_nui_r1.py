"""Review round 1, area "nui" (client/editor/**, web/**): regression tests.

- wardrobe: non-persisting clothing states (the bandana) are not offered by the wardrobe tree, and
  their controls are not in the registry (the server drops them from a wardrobe commit, §5.5);
- wardrobe "Clothing actions": group › worn item › action with the quick panel's labels
  (WCClothing.available), no verb summary of the current state;
- feature pads: every T.PAIRS entry pairs two fields of the same WCMorph node (no dead pairs), so
  chest/arms, waist/hip and jaw depth/offset are pads instead of collapsed extras;
- store: a sold subcategory with nothing worn shows its category price;
- NUI wiring: Back at the creator's root counts a typed identity as unsaved, and the save modal
  shows the price breakdown (web/src; the helpers are unit-tested in web/tests/treeState.test.mjs).

Run: python3 -m unittest discover -s tests -p 'test_review_nui_r1.py'
"""
import re
import unittest

from harness import RESOURCE, read
from test_editor_lua import EditorBase, lua_list
from test_client_states_support import make_states_client

WARDROBE = r"""
function firstHash(category)
    local cat = WCCatalog.forSex('male')[category]
    local best
    for hash in pairs(cat and cat.hashes or {}) do
        if best == nil or tostring(hash) < tostring(best) then best = hash end
    end
    return best
end
function openWardrobe(extra)
    local app = AppearanceSchema.default('male')
    for category, hash in pairs(extra or {}) do app.clothing.equipped[category] = hash end
    app.clothing.equipped = WCRules.normalize(app.clothing.equipped)
    local owned = {}
    for _, h in pairs(app.clothing.equipped) do owned[tostring(h)] = { category = 'x' } end
    StateHooks = {}
    return openEditor('wardrobe', 'male', { app = app, context = { owned = owned, outfits = {} },
        onState = function(g, v) StateHooks[#StateHooks + 1] = g .. '=' .. v return nil end })
end
function controlsOf(node, acc)
    acc = acc or {}
    if node.control then acc[#acc + 1] = node.control end
    for _, c in ipairs(node.children or {}) do controlsOf(c, acc) end
    return acc
end
"""


class WardrobeStateTests(EditorBase):
    def setUp(self):
        super().setUp()
        self.rt.run(WARDROBE)

    def open_with_neckwear(self):
        neck = self.rt.eval("firstHash('neckwear')")
        self.assertIsNotNone(neck, 'the test catalogue has neckwear')
        self.assertTrue(self.rt.eval("openWardrobe({ neckwear = firstHash('neckwear') })"))
        self.assertTrue(self.rt.eval("WCClothingStates.applicable(WCEditor.session().working, 'bandana')"))

    def test_bandana_is_not_offered_in_the_wardrobe(self):
        self.open_with_neckwear()
        tree = self.payload().tree
        controls = lua_list(self.rt.g.controlsOf(tree))
        self.assertFalse([c for c in controls if c.startswith('state.bandana.')], controls)
        self.assertIsNone(self.registry()['state.bandana.up'])
        self.assertIsNone(self.registry()['state.bandana.down'])
        # persisting states stay offered
        self.assertIsNotNone(self.registry()['state.sleeves.rolled'])

    def test_bandana_invoke_is_refused_and_changes_nothing(self):
        self.open_with_neckwear()
        r = self.action(op='invoke', control='state.bandana.up')
        self.assertFalse(r.ok)
        self.assertIsNone(self.working('.clothing.states.bandana'))
        self.assertEqual(self.rt.eval('#StateHooks'), 0)
        self.assertFalse(self.payload().dirty)

    def test_persisting_state_still_previews_and_saves(self):
        self.open_with_neckwear()
        r = self.action(op='invoke', control='state.sleeves.rolled')
        self.assertTrue(r.ok, r.message)
        self.assertEqual(self.working('.clothing.states.sleeves'), 'rolled')
        self.assertEqual(self.rt.eval('StateHooks[1]'), 'sleeves=rolled')
        r = self.action(op='save')
        self.assertTrue(r.ok, r.message)
        self.assertEqual(self.rt.eval('Commits[1].app.clothing.states.sleeves'), 'rolled')
        self.assertIsNone(self.rt.eval('Commits[1].app.clothing.states.bandana'))

    def test_keep_filter_limits_the_registry(self):
        # T.clothingActions registers only the groups `keep` accepts
        self.open_with_neckwear()
        self.rt.run("""
            local reg = {}
            WCEditorTree.clothingActions(WCEditor.session().working, reg, function(g, v)
                return { apply = function(app) app.clothing.states[g] = v end }
            end, function(g) return g ~= 'sleeves' end)
            FilteredReg = reg
        """)
        self.assertIsNone(self.rt.eval("FilteredReg['state.sleeves.rolled']"))
        self.assertIsNotNone(self.rt.eval("FilteredReg['state.bandana.up']"))

    def test_actions_nest_under_the_worn_item_without_a_verb_summary(self):
        self.open_with_neckwear()
        actions = self.rt.g.findNode(self.payload().tree, 'actions')
        self.assertIsNotNone(actions)
        for g in lua_list(actions.children):
            self.assertTrue(g.id.startswith('states.'))
            for item in lua_list(g.children):
                self.assertEqual(item.kind, 'group')
                self.assertTrue(item.id.startswith(g.id + '.'), item.id)
                self.assertIsNone(item.summary)
                for act in lua_list(item.children):
                    self.assertEqual(act.kind, 'action')
                    self.assertTrue(act.control.startswith('state.'))
        shirt = self.rt.g.findNode(actions, 'states.upper.shirts_full')
        self.assertIsNotNone(shirt)
        self.assertEqual(shirt.label, 'القميص')
        self.assertEqual([a.control for a in lua_list(shirt.children)],
                         ['state.sleeves.rolled', 'state.collar.open'])


class WardrobeLabelTests(unittest.TestCase):
    """With the real clothing state module loaded (as in the game), the wardrobe branch uses the quick
    panel's grouping and action labels."""

    def setUp(self):
        self.rt = make_states_client()

    def build(self, keep=True):
        code = "WCEditorTree.clothingActions(WCState.appearance, nil, nil, %s)" % (
            "function(g) return WCClothingStates.byId[g].persist == true end" if keep else 'nil')
        return lua_list(self.rt.eval(code))

    def by_id(self, nodes):
        return {n.id: n for n in nodes}

    def test_specific_action_labels_and_item_level(self):
        self.rt.run("WCState.appearance.clothing.states.sleeves = 'rolled'")
        groups = self.by_id(self.build())
        upper = groups['states.upper']
        shirt = self.by_id(lua_list(upper.children))['states.upper.shirts_full']
        self.assertEqual(shirt.label, 'القميص')
        self.assertIsNone(shirt.summary)
        labels = {a.control: a.label for a in lua_list(shirt.children)}
        # the inverse action with its own verb, never the current state
        self.assertEqual(labels, {'state.sleeves.down': 'إنزال الأكمام', 'state.collar.open': 'فتح الياقة'})
        head = groups['states.head']
        hat = lua_list(head.children)[0]
        self.assertEqual([a.label for a in lua_list(hat.children)], ['خلع القبعة'])

    def test_cloak_is_named_after_the_worn_piece(self):
        self.rt.run("WCState.appearance.clothing.equipped.cloaks = COAT")
        upper = self.by_id(self.build())['states.upper']
        items = self.by_id(lua_list(upper.children))
        cloak = items['states.upper.ponchos']
        self.assertEqual(cloak.label, 'العباءة')
        self.assertEqual([a.label for a in lua_list(cloak.children)], ['خلع العباءة'])

    def test_bandana_only_without_the_persist_filter(self):
        with_filter = self.by_id(self.build())
        self.assertNotIn('states.neck', with_filter)
        without = self.by_id(self.build(keep=False))
        self.assertIn('states.neck', without)
        neck = lua_list(without['states.neck'].children)[0]
        self.assertEqual([a.control for a in lua_list(neck.children)], ['state.bandana.up'])

    def test_every_label_is_a_dictionary_key(self):
        import json
        en = json.loads(read(RESOURCE / 'locales' / 'en.json'))
        self.rt.run("WCState.appearance.clothing.equipped.cloaks = COAT; "
                    "WCState.appearance.clothing.equipped.pants = PANTS")

        def walk(node, out):
            out.append(node.label)
            for c in lua_list(node.children):
                walk(c, out)
            return out

        labels = []
        for g in self.build(keep=False):
            walk(g, labels)
        self.assertTrue(labels)
        self.assertEqual([l for l in labels if l not in en], [])


class FeaturePadTests(EditorBase):
    def test_every_pair_sits_in_one_morph_node(self):
        pairs = lua_list(self.rt.eval('WCEditorTree.PAIRS'))
        node_of = {}
        for name, field in self.rt.eval('WCMorph.byId').items():
            node_of[name] = field.group
        self.assertTrue(node_of, 'WCMorph has fields in the test runtime')
        dead = []
        for pair in pairs:
            a, b = pair[1], pair[2]
            if a in node_of and b in node_of and node_of[a] != node_of[b]:
                dead.append((a, node_of[a], b, node_of[b]))
        self.assertEqual(dead, [])

    def test_body_and_jaw_pads(self):
        self.rt.eval("openEditor('creator', 'male', { identity = {} })")
        tree = self.payload().tree

        def kids(node_id):
            return [(c.kind, c.id) for c in lua_list(self.rt.g.findNode(tree, node_id).children)]

        self.assertEqual(kids('body.upper'), [('pad', 'pad.shoulders.shoulderThickness'), ('pad', 'pad.chest.arms'),
                                              ('slider', 'morph.shoulderBlades')])
        self.assertEqual(kids('body.torso'), [('pad', 'pad.waist.hip')])
        self.assertEqual(kids('face.jaw'), [('pad', 'pad.jawWidth.jawHeight'), ('pad', 'pad.jawDepth.jawY')])
        # the pads still write both fields
        r = self.action(op='setMany', values={'morph.chest': 0.5, 'morph.arms': -0.25})
        self.assertTrue(r.ok, r.message)
        self.assertEqual(self.working('.morph.chest'), 0.5)
        self.assertEqual(self.working('.morph.arms'), -0.25)


class StorePriceTests(EditorBase):
    def open_store(self, prices):
        self.rt.eval("openEditor('store', 'male', { context = { storeProfile = 'general', owned = {}, prices = %s } })"
                     % prices)
        return self.payload().tree

    def test_unworn_category_shows_its_price(self):
        tree = self.open_store('{ hats = 3.5, masks = 2 }')
        self.assertIsNone(self.rt.eval("WCEditor.session().working.clothing.equipped.hats"))
        self.assertEqual(self.rt.g.findNode(tree, 'item.hats').summary, '$3.50')
        self.assertEqual(self.rt.g.findNode(tree, 'item.masks').summary, '$2.00')
        self.assertIsNone(self.rt.g.findNode(tree, 'item.hats').badge)

    def test_worn_saved_item_keeps_its_badge(self):
        tree = self.open_store('{ hats = 3.5 }')
        worn = [c for c in ('shirts_full', 'pants', 'boots')
                if self.rt.eval("WCEditor.session().working.clothing.equipped.%s" % c)]
        self.assertTrue(worn)
        node = self.rt.g.findNode(tree, 'item.' + worn[0])
        self.assertEqual(node.badge, 'equipped')
        # worn but not owned (owned = {}): any change buys it, so its price shows (round 2,
        # tests/test_review_nui_r2.py); the row still reads 'equipped' (badge first)
        self.assertEqual(node.summary, '$5.00')

    def test_trying_on_keeps_the_price(self):
        self.open_store('{ hats = 3.5 }')
        r = self.action(op='set', control='clothing.hats.style', value=1)
        self.assertTrue(r.ok, r.message)
        self.assertEqual(self.rt.g.findNode(r.payload.tree, 'item.hats').summary, '$3.50')

    def test_creator_and_wardrobe_rows_get_no_price(self):
        self.rt.eval("openEditor('creator', 'male', { identity = {} })")
        for node in lua_list(self.rt.g.countIds(self.payload().tree, '^item%.')):
            summary = self.rt.g.findNode(self.payload().tree, node).summary
            self.assertFalse(summary and summary.startswith('$'), node)


class NuiWiringTests(unittest.TestCase):
    def setUp(self):
        self.editor = read(RESOURCE / 'web' / 'src' / 'Editor.jsx')

    def test_back_counts_a_typed_identity_as_unsaved(self):
        back = self.editor[self.editor.index('const back = () =>'):]
        back = back[:back.index('};')]
        self.assertRegex(back, r'identityDirty\(payload\.identity,\s*identity\)')
        self.assertRegex(back, r'backAction\(\{confirm, pathLength: validPath\.length, dirty(, search)?\}\)')

    def test_save_modal_renders_the_price_lines(self):
        self.assertRegex(self.editor, r'priceLines\(price\)')
        self.assertIn('className="price-lines"', self.editor)
        self.assertRegex(self.editor, r'modal\.lines\.map')
        css = read(RESOURCE / 'web' / 'src' / 'styles.css')
        self.assertIn('.price-lines', css)
        self.assertTrue(re.search(r'export function priceLines', read(RESOURCE / 'web' / 'src' / 'treeState.js')))


if __name__ == '__main__':
    unittest.main()
