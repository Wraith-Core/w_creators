"""WCEditor / WCEditorTree / WCPanel (client/editor/*.lua): tree per mode, control registry validation,
undo, dirty state, busy rejection, render failure revert, prices, outfits, states and the panel.

Run: python3 -m unittest discover -s tests -p 'test_editor_*.py'
"""
import json
import unittest

from harness import RESOURCE, Runtime, read

CLIENT = r"""
NuiCallbacks, NuiMessages, NuiFocus = {}, {}, false
function RegisterNUICallback(name, fn) NuiCallbacks[name] = fn end
function SendNUIMessage(m) table.insert(NuiMessages, m) end
function SetNuiFocus(a) NuiFocus = a end
function SetNuiFocusKeepInput() end
function DoesEntityExist(e) return e == 42 end
LanguageHandlers = {}
function OnLanguageChange(fn) table.insert(LanguageHandlers, fn) end
CurrentLocale = 'ar'
function UiLocale() return CurrentLocale end
function UiDir() return CurrentLocale == 'ar' and 'rtl' or 'ltr' end
Rendered, ApplyFail, ApplyFailed = {}, false, nil
Appearance = {
    ApplyDiff = function(ped, before, after)
        table.insert(Rendered, { op = 'diff', after = after })
        if ApplyFail then return false, {}, 'INVALID_PED' end
        return true, ApplyFailed or {}
    end,
    RestoreCharacter = function(ped, app) table.insert(Rendered, { op = 'restore', app = app }) return true end,
}
CamCalls = {}
WCCamera = setmetatable({}, { __index = function(_, k)
    return function(...)
        table.insert(CamCalls, { name = k, args = { ... } })
        if k == 'pick' then return 'face' end
        return nil
    end
end })
function nui(name, data)
    local out
    NuiCallbacks[name](data, function(r) out = r end)
    return out
end
function lastPayload()
    for i = #NuiMessages, 1, -1 do
        if NuiMessages[i].type == 'editor' then return NuiMessages[i] end
    end
end
function findNode(node, id)
    if node.id == id then return node end
    for _, c in ipairs(node.children or {}) do
        local f = findNode(c, id)
        if f then return f end
    end
end
function countIds(node, pattern, acc)
    acc = acc or {}
    if node.id and tostring(node.id):find(pattern) then acc[#acc + 1] = node.id end
    for _, c in ipairs(node.children or {}) do countIds(c, pattern, acc) end
    return acc
end
Commits, Cancels = {}, 0
function openEditor(mode, sex, opts)
    opts = opts or {}
    opts.onCommit = opts.onCommit or function(app, extra)
        table.insert(Commits, { app = app, extra = extra })
        return WCResult.ok({ appearance = app })
    end
    opts.onCancel = opts.onCancel or function() Cancels = Cancels + 1 end
    local app = opts.app or AppearanceSchema.default(sex)
    opts.app = nil
    return WCEditor.open(42, mode, app, opts)
end
function sid() return WCEditor.session().id end
"""


def lua_list(tbl):
    if tbl is None:
        return []
    return [tbl[i] for i in range(1, len(tbl) + 1)]


class EditorBase(unittest.TestCase):
    def setUp(self):
        self.rt = Runtime()
        self.rt.load_shared()
        self.rt.run(CLIENT)
        self.rt.load('client/editor/tree.lua', 'client/editor/editor.lua', 'client/editor/panel.lua')

    def run_lua(self, code):
        return self.rt.run(code)

    def action(self, **data):
        data.setdefault('id', self.rt.eval('sid()'))
        return self.rt.g.nui('editor:action', self.rt.table(data))

    def payload(self):
        return self.rt.eval('lastPayload()')

    def registry(self):
        return self.rt.eval('WCEditor.session().registry')

    def working(self, expr):
        return self.rt.eval('WCEditor.session().working' + expr)


class TreeTests(EditorBase):
    def test_female_creator_has_no_facial_hair(self):
        ok = self.rt.eval("openEditor('creator', 'female', { identity = {} })")
        self.assertTrue(ok)
        tree = self.payload().tree
        self.assertIsNone(self.rt.g.findNode(tree, 'facialHair'))
        self.assertEqual(len(lua_list(self.rt.g.countIds(tree, '^facial'))), 0)
        self.assertEqual(len(lua_list(self.rt.g.countIds(tree, 'beardstabble'))), 0)
        reg = self.registry()
        self.assertIsNone(reg['facial.style'])
        self.assertIsNone(reg['overlay.beardstabble.style'])
        stages = [s.id for s in lua_list(self.payload().stages)]
        self.assertNotIn('facialHair', stages)
        self.assertEqual(stages, ['identity', 'body', 'face', 'skin', 'hair', 'makeup', 'clothing', 'review'])
        # direct control attempt is rejected
        r = self.action(op='set', control='facial.style', value=1)
        self.assertFalse(r.ok)
        self.assertEqual(r.code, 'INVALID_PAYLOAD')

    def test_male_creator_has_facial_hair_nested(self):
        self.rt.eval("openEditor('creator', 'male', { identity = {} })")
        tree = self.payload().tree
        facial = self.rt.g.findNode(tree, 'facialHair')
        self.assertIsNotNone(facial)
        beard = self.rt.g.findNode(facial, 'facial.beard')
        self.assertIsNotNone(self.rt.g.findNode(beard, 'facial.style'))
        self.assertIsNotNone(self.registry()['facial.style'])

    def test_every_option_is_nested(self):
        self.rt.eval("openEditor('creator', 'male', { identity = {} })")
        tree = self.payload().tree
        for child in lua_list(tree.children):
            self.assertIn(child.kind, ('group', 'identity', 'review'), child.id)

    def test_morph_pads_and_display_scale(self):
        self.rt.eval("openEditor('creator', 'male', { identity = {} })")
        nose = self.rt.g.findNode(self.payload().tree, 'face.nose')
        kinds = [c.kind for c in lua_list(nose.children)]
        self.assertIn('pad', kinds)
        pad = [c for c in lua_list(nose.children) if c.kind == 'pad'][0]
        self.assertEqual(pad.x.control, 'morph.noseWidth')
        self.assertEqual(pad.y.control, 'morph.noseHeight')
        self.assertEqual(pad.display.scale, 100)
        r = self.action(op='setMany', values={'morph.noseWidth': 0.5, 'morph.noseHeight': -2})
        self.assertTrue(r.ok, r.message)
        self.assertEqual(self.working('.morph.noseWidth'), 0.5)
        self.assertEqual(self.working('.morph.noseHeight'), -1)
        self.assertEqual(self.rt.eval('#WCEditor.session().history'), 1)

    def test_hair_colour_uses_named_options(self):
        self.rt.eval("openEditor('creator', 'male', { identity = {} })")
        colour = self.rt.g.findNode(self.payload().tree, 'hair.color')
        labels = [o.label for o in lua_list(colour.options)]
        known = set(json.loads(read(RESOURCE / 'locales' / 'en.json')))
        self.assertTrue(any(label in known for label in labels), labels)

    def test_surgery_only_allowed_sections(self):
        self.rt.eval("openEditor('surgery', 'male', { sections = { 'body' }, context = { price = 500 } })")
        reg = self.registry()
        self.assertIsNotNone(reg['body.type'])
        self.assertIsNotNone(reg['morph.shoulders'])
        self.assertIsNone(reg['face.head'])
        self.assertIsNone(reg['morph.noseWidth'])
        self.assertIsNone(reg['skin.tone'])
        stages = [s.id for s in lua_list(self.payload().stages)]
        self.assertEqual(stages, ['body', 'review'])
        r = self.action(op='set', control='face.head', value=2)
        self.assertEqual(r.code, 'INVALID_PAYLOAD')

    def test_barber_tree_and_price_cap(self):
        self.rt.run("Config.Barber.prices.visitCap = 12")
        self.rt.eval("openEditor('barber', 'male', { sections = { 'hair', 'facialHair', 'eyebrows' },"
                     " context = { growth = { hair = { stage = 1, remainingMinutes = 30 }, beard = { stage = 2, remainingMinutes = 5 } },"
                     " services = { hair = { enabled = true, price = 10 }, facialHair = { enabled = true, price = 10 },"
                     " details = { enabled = true, price = 5 } } } })")
        tree = self.payload().tree
        ids = [c.id for c in lua_list(tree.children)]
        self.assertEqual(ids, ['hair', 'facialHair', 'details', 'growth'])
        self.assertEqual(self.payload().price.total, 0)
        r = self.action(op='set', control='hair.style', value=2)
        self.assertTrue(r.ok, r.message)
        self.assertEqual(r.payload.price.total, 10)
        r = self.action(op='set', control='facial.style', value=1)
        self.assertTrue(r.ok, r.message)
        self.assertEqual(r.payload.price.total, 12)

    def test_barber_female_never_offers_facial_hair(self):
        self.rt.eval("openEditor('barber', 'female', { sections = { 'hair', 'facialHair' } })")
        self.assertIsNone(self.rt.g.findNode(self.payload().tree, 'facialHair'))
        self.assertIsNone(self.registry()['facial.style'])


class StoreWardrobeTests(EditorBase):
    def test_store_hides_unavailable_items(self):
        self.rt.run("Config.Clothing.prices.masks = -1")
        self.rt.eval("openEditor('store', 'male', { context = { storeProfile = 'general', owned = {} } })")
        tree = self.payload().tree
        self.assertIsNone(self.rt.g.findNode(tree, 'item.masks'))
        self.assertIsNotNone(self.rt.g.findNode(tree, 'item.hats'))
        self.assertIsNone(self.registry()['clothing.masks.style'])

    def test_store_profile_filters_categories_and_models(self):
        self.rt.run("Config.Clothing.storeProfiles.test = { include = { 'hats' }, models = { hats = { min = 1, max = 1 } } }")
        self.rt.eval("openEditor('store', 'male', { context = { storeProfile = 'test', owned = {} },"
                     " app = (function() local a = AppearanceSchema.default('male'); a.clothing.equipped = {} return a end)() })")
        tree = self.payload().tree
        self.assertIsNone(self.rt.g.findNode(tree, 'item.boots'))
        style = self.rt.g.findNode(tree, 'clothing.hats.style')
        values = [o.value for o in lua_list(style.options)]
        self.assertEqual(values, [0, 1])
        r = self.action(op='set', control='clothing.hats.style', value=2)
        self.assertEqual(r.code, 'INVALID_PAYLOAD')

    def test_store_price_and_badges(self):
        self.rt.eval("openEditor('store', 'male', { context = { storeProfile = 'general', owned = {}, prices = { hats = 3.5 } } })")
        r = self.action(op='set', control='clothing.hats.style', value=1)
        self.assertTrue(r.ok, r.message)
        self.assertEqual(r.payload.price.total, 3.5)
        node = self.rt.g.findNode(r.payload.tree, 'item.hats')
        self.assertEqual(node.summary, '$3.50')
        card = self.rt.g.findNode(node, 'clothing.hats.card')
        self.assertEqual(card.kind, 'itemcard')
        self.assertFalse(card.item.owned)
        self.assertTrue(r.payload.dirty)
        self.assertTrue(r.payload.canSave)

    def test_store_tint_controls_only_for_tintable(self):
        self.rt.eval("openEditor('store', 'male', { context = { storeProfile = 'general', owned = {} } })")
        self.action(op='set', control='clothing.hats.style', value=1)
        self.assertIsNotNone(self.registry()['clothing.hats.palette'])
        self.assertIsNone(self.registry()['clothing.hats.tint0'])  # disabled until a palette is chosen
        r = self.action(op='set', control='clothing.hats.palette', value=1)
        self.assertTrue(r.ok, r.message)
        r = self.action(op='set', control='clothing.hats.tint0', value=999)
        self.assertTrue(r.ok, r.message)
        self.assertEqual(self.working('.clothing.tints.hats.tint0'), 254)

    def test_wardrobe_shows_only_owned_hashes(self):
        cat = self.rt.eval("WCCatalog.forSex('male').shirts_full")
        m2 = cat.models[2]
        owned_hash = m2[1].hash
        self.rt.run("WardrobeOwned = { [tostring(%d)] = { category = 'shirts_full' } }" % owned_hash)
        self.rt.eval("openEditor('wardrobe', 'male', { context = { owned = WardrobeOwned, outfits = {}, maxOutfits = 3 },"
                     " app = (function() local a = AppearanceSchema.default('male'); a.clothing.equipped = {} return a end)() })")
        tree = self.payload().tree
        items = self.rt.g.findNode(tree, 'items')
        subs = lua_list(self.rt.g.countIds(items, '^item%.'))
        self.assertEqual(subs, ['item.shirts_full'])
        style = self.rt.g.findNode(tree, 'clothing.shirts_full.style')
        self.assertEqual([o.value for o in lua_list(style.options)], [0, 2])
        r = self.action(op='set', control='clothing.shirts_full.style', value=1)
        self.assertEqual(r.code, 'INVALID_PAYLOAD')
        r = self.action(op='set', control='clothing.shirts_full.style', value=2)
        self.assertTrue(r.ok, r.message)
        variant = self.rt.g.findNode(r.payload.tree, 'clothing.shirts_full.variant')
        self.assertEqual([o.value for o in lua_list(variant.options)], [1])
        self.assertIsNone(self.registry()['clothing.shirts_full.palette'])
        self.assertIsNone(r.payload.price)

    def test_wardrobe_outfits_and_states(self):
        self.rt.run("""
            OutfitCalls = {}
            WardrobeApp = AppearanceSchema.default('male')
            local owned = {}
            for _, h in pairs(WardrobeApp.clothing.equipped) do owned[tostring(h)] = { category = 'x' } end
            WardrobeOwned = owned
        """)
        self.rt.eval("""openEditor('wardrobe', 'male', { app = WardrobeApp,
            context = { owned = WardrobeOwned, maxOutfits = 2, outfits = { { id = 7, name = 'Work', data = { equipped = {} } } } },
            onOutfit = function(op, id, value)
                table.insert(OutfitCalls, { op = op, id = id, value = value })
                if op == 'rename' then
                    return WCResult.ok({ outfits = { { id = 7, name = value, data = { equipped = {} } } } })
                end
                return WCResult.ok({})
            end })""")
        tree = self.payload().tree
        outfit = self.rt.g.findNode(tree, 'outfit.7')
        self.assertEqual([c.id for c in lua_list(outfit.children)],
                         ['outfit.7.equip', 'outfit.7.update', 'outfit.7.rename', 'outfit.7.delete'])
        r = self.action(op='invoke', control='outfit.7.rename', value='  Formal  ')
        self.assertTrue(r.ok, r.message)
        self.assertEqual(self.rt.eval('OutfitCalls[1].value'), 'Formal')
        self.assertEqual(self.rt.g.findNode(r.payload.tree, 'outfit.7').label, 'Formal')
        # save needs a name first
        self.assertIsNone(self.registry()['outfit.new.save'])
        r = self.action(op='invoke', control='outfit.new.name', value='Travel')
        self.assertTrue(r.ok)
        r = self.action(op='invoke', control='outfit.new.save')
        self.assertTrue(r.ok, r.message)
        self.assertEqual(self.rt.eval('OutfitCalls[2].op'), 'save')
        self.assertEqual(self.rt.eval('OutfitCalls[2].value.name'), 'Travel')
        # clothing actions: shirt sleeves roll
        actions = self.rt.g.findNode(r.payload.tree, 'actions')
        self.assertIsNotNone(actions)
        self.assertIsNotNone(self.registry()['state.sleeves.rolled'])
        r = self.action(op='invoke', control='state.sleeves.rolled')
        self.assertTrue(r.ok, r.message)
        self.assertEqual(self.working('.clothing.states.sleeves'), 'rolled')
        # equip the outfit locally (empty outfit)
        r = self.action(op='invoke', control='outfit.7.equip')
        self.assertTrue(r.ok, r.message)
        self.assertEqual(self.working('.clothing.outfit'), 7)


class OperationTests(EditorBase):
    def open_creator(self):
        self.rt.eval("openEditor('creator', 'male', { identity = {} })")

    def test_unknown_control_rejected(self):
        self.open_creator()
        for control in ('body.nope', 'morph.notAField', '', 'clothing.hats.style.extra'):
            r = self.action(op='set', control=control, value=1)
            self.assertFalse(r.ok, control)
            self.assertEqual(r.code, 'INVALID_PAYLOAD')
            self.assertTrue(r.message)
        r = self.action(op='invoke', control='body.height', value=1)
        self.assertEqual(r.code, 'INVALID_PAYLOAD')
        r = self.action(op='explode')
        self.assertEqual(r.code, 'INVALID_PAYLOAD')

    def test_value_clamping(self):
        self.open_creator()
        self.assertTrue(self.action(op='set', control='body.height', value=5).ok)
        self.assertEqual(self.working('.body.height'), 1.1)
        self.assertTrue(self.action(op='set', control='body.weight', value=-40).ok)
        self.assertEqual(self.working('.body.weight'), 1)
        self.assertTrue(self.action(op='set', control='morph.shoulderBlades', value=-3).ok)
        self.assertEqual(self.working('.morph.shoulderBlades'), -1)
        self.assertTrue(self.action(op='set', control='overlay.blush.style', value=99).ok)
        self.assertEqual(self.working('.overlays.blush.style'), 4)
        self.assertTrue(self.action(op='set', control='overlay.blush.opacity', value=7).ok)
        self.assertEqual(self.working('.overlays.blush.opacity'), 1)

    def test_nan_and_garbage_rejected(self):
        self.open_creator()
        r = self.rt.eval("nui('editor:action', { id = sid(), op = 'set', control = 'body.height', value = 0/0 })")
        self.assertEqual(r.code, 'INVALID_PAYLOAD')
        r = self.rt.eval("nui('editor:action', { id = sid(), op = 'set', control = 'body.height', value = math.huge })")
        self.assertEqual(r.code, 'INVALID_PAYLOAD')
        r = self.action(op='set', control='body.type', value='abc')
        self.assertEqual(r.code, 'INVALID_PAYLOAD')
        r = self.action(op='set', control='body.type', value=1.5)
        self.assertEqual(r.code, 'INVALID_PAYLOAD')
        self.assertEqual(self.rt.eval('#WCEditor.session().history'), 0)
        self.assertFalse(self.payload().dirty)

    def test_undo_and_dirty(self):
        self.open_creator()
        self.assertFalse(self.payload().dirty)
        r = self.action(op='set', control='body.height', value=0.95)
        self.assertTrue(r.payload.dirty)
        self.assertTrue(r.payload.canUndo)
        r = self.action(op='set', control='body.height', value=1.05)
        r = self.action(op='undo')
        self.assertTrue(r.ok)
        self.assertEqual(self.working('.body.height'), 0.95)
        r = self.action(op='undo')
        self.assertFalse(r.payload.dirty)
        self.assertFalse(r.payload.canUndo)
        r = self.action(op='undo')
        self.assertTrue(r.ok)
        self.action(op='set', control='body.height', value=0.95)
        r = self.action(op='reset')
        self.assertFalse(r.payload.dirty)
        self.assertTrue(r.payload.canUndo)

    def test_history_is_capped(self):
        self.open_creator()
        for i in range(40):
            self.action(op='set', control='body.weight', value=1 + (i % 20))
        self.assertEqual(self.rt.eval('#WCEditor.session().history'), 30)

    def test_invalid_component_reverts(self):
        self.open_creator()
        before = self.rt.eval('WCEditor.session().working.hair.style')
        self.rt.run('ApplyFail = true')
        r = self.action(op='set', control='hair.style', value=3)
        self.assertFalse(r.ok)
        self.assertEqual(r.code, 'INVALID_COMPONENT')
        self.assertEqual(self.working('.hair.style'), before)
        self.assertEqual(self.rt.eval('Rendered[#Rendered].op'), 'restore')
        self.assertFalse(r.payload.dirty)
        self.assertEqual(self.rt.eval('#WCEditor.session().history'), 0)

    def test_failed_category_reverts(self):
        self.open_creator()
        self.rt.run("ApplyFailed = { 'hair' }")
        before = self.rt.eval('WCEditor.session().working.hair.style')
        r = self.action(op='set', control='hair.style', value=3)
        self.assertEqual(r.code, 'INVALID_COMPONENT')
        self.assertEqual(self.working('.hair.style'), before)

    def test_editor_lock_is_released_only_when_owned(self):
        self.rt.run("""
            Locks = {}
            WCState = { busy = function(name, value)
                if value == nil then return Locks[name] == true end
                if value then if Locks[name] then return false end Locks[name] = true return true end
                Locks[name] = nil return true end }
        """)
        self.open_creator()
        self.assertTrue(self.rt.eval("Locks.editor"))
        self.rt.run('WCEditor.close()')
        self.assertIsNone(self.rt.eval("Locks.editor"))
        self.rt.run("Locks.editor = true")
        self.open_creator()
        self.rt.run('WCEditor.close()')
        self.assertTrue(self.rt.eval("Locks.editor"))

    def test_busy_rejection(self):
        self.rt.run("""
            SlowResult = nil
            openEditor('store', 'male', { context = { storeProfile = 'general', owned = {} },
                onCommit = function(app) Wait(500) return WCResult.ok({ appearance = app }) end })
            nui('editor:action', { id = sid(), op = 'set', control = 'clothing.hats.style', value = 1 })
            CreateThread(function() SlowResult = nui('editor:action', { id = sid(), op = 'save', opId = 'op-1' }) end)
        """)
        self.assertIsNone(self.rt.g.SlowResult)
        r = self.action(op='set', control='clothing.hats.variant', value=1)
        self.assertFalse(r.ok)
        self.assertEqual(r.code, 'BUSY')
        r = self.rt.g.nui('editor:camera', self.rt.table({'id': self.rt.eval('sid()'), 'preset': 'head'}))
        self.assertFalse(r.ok)
        self.rt.g.tick(600)
        self.assertTrue(self.rt.g.SlowResult.ok)
        self.assertTrue(self.rt.g.SlowResult.closed)
        self.assertIsNone(self.rt.eval('WCEditor.session()'))

    def test_save_and_cancel(self):
        self.open_creator()
        r = self.action(op='save', identity={'firstname': 'J', 'lastname': 'Marston', 'dob': '1990-01-01'})
        self.assertEqual(r.code, 'INVALID_NAME')
        self.assertIsNotNone(self.rt.eval('WCEditor.session()'))
        r = self.action(op='save', opId='abc-1', identity={'firstname': 'John', 'lastname': 'Marston', 'dob': '1990-01-01'})
        self.assertTrue(r.ok, r.message)
        self.assertTrue(r.closed)
        self.assertEqual(self.rt.eval('Commits[1].extra.identity.firstname'), 'John')
        self.assertEqual(self.rt.eval('Commits[1].extra.opId'), 'abc-1')
        self.assertEqual(self.rt.eval("NuiMessages[#NuiMessages].type"), 'editorClose')
        self.assertFalse(self.rt.g.NuiFocus)
        # cancel restores the saved appearance
        self.rt.eval("openEditor('barber', 'male', {})")
        self.action(op='set', control='hair.style', value=2)
        r = self.action(op='cancel')
        self.assertTrue(r.closed)
        self.assertEqual(self.rt.g.Cancels, 1)
        self.assertEqual(self.rt.eval('Rendered[#Rendered].op'), 'restore')

    def test_commit_failure_keeps_session_and_translates(self):
        self.rt.eval("openEditor('store', 'male', { context = { storeProfile = 'general', owned = {} },"
                     " onCommit = function() return WCResult.fail('INSUFFICIENT_FUNDS') end })")
        r = self.action(op='save')
        self.assertEqual(r.code, 'NO_CHANGES')
        self.action(op='set', control='clothing.hats.style', value=1)
        r = self.action(op='save')
        self.assertFalse(r.ok)
        self.assertEqual(r.code, 'INSUFFICIENT_FUNDS')
        self.assertEqual(r.message, self.rt.eval("WCResult.messageKey('INSUFFICIENT_FUNDS')"))
        self.assertIsNotNone(r.payload)

    def test_random_is_creator_only_and_moderate(self):
        self.open_creator()
        r = self.action(op='random')
        self.assertTrue(r.ok, r.message)
        morph = self.rt.eval('WCEditor.session().working.morph')
        for _, v in morph.items():
            self.assertLessEqual(abs(v), 0.25)
        self.assertEqual(self.working('.hair.facial'), 0)
        self.rt.run('WCEditor.close()')
        self.rt.eval("openEditor('barber', 'male', {})")
        self.assertEqual(self.action(op='random').code, 'INVALID_PAYLOAD')

    def test_stale_session_and_second_open(self):
        self.open_creator()
        ok, code = self.rt.eval("openEditor('barber', 'male', {})")
        self.assertFalse(ok)
        self.assertEqual(code, 'BUSY')
        r = self.rt.g.nui('editor:action', self.rt.table({'id': 999, 'op': 'undo'}))
        self.assertEqual(r.code, 'SESSION_NOT_FOUND')

    def test_camera_validation(self):
        self.open_creator()
        sid = self.rt.eval('sid()')
        r = self.rt.g.nui('editor:camera', self.rt.table({'id': sid, 'preset': 'nope'}))
        self.assertFalse(r.ok)
        r = self.rt.g.nui('editor:camera', self.rt.table({'id': sid, 'preset': 'eyes'}))
        self.assertTrue(r.ok)
        self.assertEqual(r.camera, 'eyes')
        r = self.rt.g.nui('editor:camera', self.rt.table({'id': sid, 'pick': {'x': 0.5, 'y': 0.2, 'aspect': 1.7}}))
        self.assertEqual(r.camera, 'face')
        r = self.rt.g.nui('editor:camera', self.rt.table({'id': sid, 'rotate': 1e9}))
        self.assertTrue(r.ok)
        rotate = [c for c in lua_list(self.rt.g.CamCalls) if c.name == 'rotate'][-1]
        self.assertEqual(rotate.args[1], 180)

    def test_language_change_resends_payload(self):
        self.open_creator()
        count = len(lua_list(self.rt.g.NuiMessages))
        self.rt.run("CurrentLocale = 'en'; for _, fn in ipairs(LanguageHandlers) do fn('en') end")
        messages = lua_list(self.rt.g.NuiMessages)
        self.assertEqual(len(messages), count + 1)
        self.assertEqual(messages[-1].session.locale, 'en')
        self.assertEqual(messages[-1].session.dir, 'ltr')
        self.assertTrue(messages[-1].strings.back)

    def test_identity_payload(self):
        self.rt.run("Config.Characters.identity.referenceYear = 1899")
        self.open_creator()
        fields = lua_list(self.payload().identity.fields)
        self.assertEqual([f.key for f in fields], ['firstname', 'lastname', 'dob', 'sex'])
        dob = fields[2]
        self.assertEqual(dob.type, 'date')
        self.assertEqual(dob.min, '1809-01-01')
        self.assertEqual(dob.max, '1881-12-31')

    def test_identity_payload_without_os(self):
        # the client runtime has no os library: without a reference year the window comes from the
        # date the server publishes, and without one the field has no min / max (the server checks)
        self.rt.run("os = nil; GlobalState = {}")
        self.open_creator()
        dob = lua_list(self.payload().identity.fields)[2]
        self.assertIsNone(dob.min)
        self.assertIsNone(dob.max)
        self.rt.run("GlobalState[WCUtil.TODAY_KEY] = { year = 1900, month = 1, day = 1 }; WCEditor.refresh()")
        dob = lua_list(self.payload().identity.fields)[2]
        self.assertEqual(dob.min, '1810-01-01')
        self.assertEqual(dob.max, '1882-12-31')

    def test_locked_identity_is_read_only_and_never_submitted(self):
        self.rt.eval("openEditor('creator', 'male', { identity = { locked = true, firstname = 'John', "
                     "lastname = 'Marston', dob = '1873-05-01' } })")
        identity = self.payload().identity
        self.assertTrue(identity.locked)
        fields = lua_list(identity.fields)
        self.assertEqual([f.type for f in fields], ['info'] * 4)
        self.assertEqual(fields[0].value, 'John')
        r = self.action(op='save', opId='lock-1', identity={'firstname': '', 'lastname': '', 'dob': 'x'})
        self.assertTrue(r.ok)
        self.assertIsNone(self.rt.eval('Commits[1].extra.identity'))

    def test_chrome_strings_are_locale_keys(self):
        known = set(json.loads(read(RESOURCE / 'locales' / 'en.json')))
        strings = self.rt.eval('WCEditor.STRINGS')
        for key, value in strings.items():
            self.assertIn(value, known, key)


class PanelTests(EditorBase):
    def test_panel_validates_controls(self):
        self.rt.run("""
            PanelCalls, PanelClosed = {}, 0
            PanelOk = WCPanel.open({ title = 'إجراءات الملابس',
                build = function()
                    return { id = 'root', kind = 'group', label = 'إجراءات الملابس', children = {
                        { id = 'g', kind = 'group', label = 'الرأس', children = {
                            { id = 'state.hat.off', kind = 'action', label = 'خلع', control = 'state.hat.off' } } } } }
                end,
                onControl = function(control, value) table.insert(PanelCalls, control) return WCResult.ok() end,
                onClose = function() PanelClosed = PanelClosed + 1 end })
        """)
        self.assertTrue(self.rt.g.PanelOk)
        msg = self.rt.eval('NuiMessages[#NuiMessages]')
        self.assertEqual(msg.type, 'panel')
        pid = msg.session.id
        r = self.rt.g.nui('panel:action', self.rt.table({'id': pid, 'control': 'state.hat.on'}))
        self.assertEqual(r.code, 'INVALID_PAYLOAD')
        r = self.rt.g.nui('panel:action', self.rt.table({'id': pid, 'control': 'state.hat.off'}))
        self.assertTrue(r.ok)
        self.assertEqual(self.rt.eval('PanelCalls[1]'), 'state.hat.off')
        self.assertEqual(r.payload.type, 'panel')
        ok, code = self.rt.eval('WCPanel.open({ build = function() return {} end, onControl = function() end })')
        self.assertFalse(ok)
        self.assertEqual(code, 'BUSY')
        r = self.rt.g.nui('panel:close', self.rt.table({'id': pid}))
        self.assertTrue(r.closed)
        self.assertEqual(self.rt.g.PanelClosed, 1)
        self.assertEqual(self.rt.eval('NuiMessages[#NuiMessages].type'), 'panelClose')
        r = self.rt.g.nui('panel:action', self.rt.table({'id': pid, 'control': 'state.hat.off'}))
        self.assertFalse(r.ok)
        self.assertTrue(r.closed)

    def test_editor_takes_over_an_open_panel(self):
        self.rt.run("""
            PanelClosed = 0
            WCPanel.open({ build = function() return { children = {} } end,
                onControl = function() return WCResult.ok() end, onClose = function() PanelClosed = PanelClosed + 1 end })
        """)
        self.assertTrue(self.rt.eval("openEditor('creator', 'male', {})"))
        self.assertFalse(self.rt.eval('WCPanel.isOpen()'))
        self.assertEqual(self.rt.g.PanelClosed, 1)
        ok, code = self.rt.eval('WCPanel.open({ build = function() return {} end, onControl = function() end })')
        self.assertFalse(ok)

    def test_clothing_actions_helper(self):
        self.rt.run("App = AppearanceSchema.default('male')")
        nodes = lua_list(self.rt.eval('WCEditorTree.clothingActions(App)'))
        self.assertTrue(nodes)
        for node in nodes:
            self.assertEqual(node.kind, 'group')
            for state in lua_list(node.children):
                for act in lua_list(state.children):
                    self.assertTrue(act.control.startswith('state.'))


class LocaleKeyTests(unittest.TestCase):
    def test_editor_keys_are_translated(self):
        import re
        arabic = re.compile(r"'([^'\n]*[؀-ۿ][^'\n]*)'|\"([^\"\n]*[؀-ۿ][^\"\n]*)\"")
        known = set(json.loads(read(RESOURCE / 'locales' / 'en.json')))
        missing = []
        for name in ('editor.lua', 'tree.lua', 'panel.lua'):
            code = re.sub(r'--[^\n]*', '', read(RESOURCE / 'client' / 'editor' / name))
            for m in arabic.finditer(code):
                key = m.group(1) or m.group(2)
                if key not in known:
                    missing.append('%s: %s' % (name, key))
        self.assertEqual(missing, [])

    def test_no_debug_output(self):
        for name in ('editor.lua', 'tree.lua', 'panel.lua'):
            code = read(RESOURCE / 'client' / 'editor' / name)
            self.assertNotRegex(code, r'\bprint\(|InvokeNative|N_0x|\bTODO\b|\bFIXME\b')


if __name__ == '__main__':
    unittest.main()
