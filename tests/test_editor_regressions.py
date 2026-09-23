"""Regression tests of the editor review findings (client/editor/*.lua): concurrent opens while the
first render yields, a failed first payload, rules-dropped items, full-restore failures of untouched
categories, surgery sections, the barber price multiplier, the save opId and the panel open guard.

Run: python3 -m unittest discover -s tests -p 'test_editor_*.py'
"""
import unittest

from test_editor_lua import EditorBase, lua_list

LOCKS = """
    Locks = {}
    WCState = { busy = function(name, value)
        if value == nil then return Locks[name] == true end
        if value then if Locks[name] then return false end Locks[name] = true return true end
        Locks[name] = nil return true end }
"""


class OpenRaceTests(EditorBase):
    def test_second_open_while_the_first_render_yields_is_busy(self):
        self.rt.run(LOCKS)
        self.rt.run("""
            Appearance.RestoreCharacter = function(ped, app)
                coroutine.yield()
                table.insert(Rendered, { op = 'restore', app = app })
                return true, nil, {}
            end
            co1 = coroutine.create(function() return openEditor('store', 'male', { render = true }) end)
            co2 = coroutine.create(function() return openEditor('wardrobe', 'male', { render = true }) end)
            coroutine.resume(co1)
            R2 = table.pack(coroutine.resume(co2))
            R1 = table.pack(coroutine.resume(co1))
        """)
        self.assertTrue(self.rt.eval('R2[1]'))
        self.assertFalse(self.rt.eval('R2[2]'))
        self.assertEqual(self.rt.eval('R2[3]'), 'BUSY')
        self.assertTrue(self.rt.eval('R1[2]'))
        self.assertEqual(self.rt.eval('WCEditor.session().mode'), 'store')
        self.assertTrue(self.rt.eval('Locks.editor'))
        self.rt.run('WCEditor.close()')
        self.assertIsNone(self.rt.eval('WCEditor.session()'))
        self.assertIsNone(self.rt.eval('Locks.editor'))
        self.assertFalse(self.rt.eval('WCEditor.isOpen()'))

    def test_panel_refused_while_an_editor_is_opening(self):
        self.rt.run("""
            Appearance.RestoreCharacter = function() coroutine.yield() return true, nil, {} end
            co1 = coroutine.create(function() return openEditor('store', 'male', { render = true }) end)
            coroutine.resume(co1)
            P1 = table.pack(WCPanel.open({ build = function() return { id = 'root', kind = 'group', children = {} } end,
                                         onControl = function() return WCResult.ok() end }))
            coroutine.resume(co1)
        """)
        self.assertFalse(self.rt.eval('P1[1]'))
        self.assertEqual(self.rt.eval('P1[2]'), 'BUSY')

    def test_failed_initial_render_is_not_opened(self):
        self.rt.run(LOCKS)
        self.rt.run("Appearance.RestoreCharacter = function() return false, 'NOT_READY', {} end")
        ok = self.rt.eval("select(2, openEditor('store', 'male', { render = true }))")
        self.assertEqual(ok, 'INVALID_COMPONENT')
        self.assertIsNone(self.rt.eval('WCEditor.session()'))
        self.assertIsNone(self.rt.eval('Locks.editor'))
        self.assertFalse(self.rt.eval('NuiFocus'))
        # the next open works
        self.rt.run("Appearance.RestoreCharacter = function() return true, nil, {} end")
        self.assertTrue(self.rt.eval("openEditor('store', 'male', { render = true })"))

    def test_first_payload_failure_rolls_back(self):
        self.rt.run(LOCKS)
        self.rt.run("RealBuild = WCEditorTree.build; WCEditorTree.build = function() error('boom') end")
        code = self.rt.eval("select(2, openEditor('store', 'male'))")
        self.assertEqual(code, 'INTERNAL_ERROR')
        self.assertIsNone(self.rt.eval('WCEditor.session()'))
        self.assertIsNone(self.rt.eval('Locks.editor'))
        self.assertFalse(self.rt.eval('NuiFocus'))
        self.assertEqual(self.rt.eval('#NuiMessages'), 0)
        self.rt.run("WCEditorTree.build = RealBuild")
        self.assertTrue(self.rt.eval("openEditor('store', 'male')"))
        self.assertTrue(self.rt.eval('NuiFocus'))

    def test_panel_option_without_value_and_build_errors(self):
        self.rt.run("""
            PanelOk = table.pack(WCPanel.open({ build = function()
                return { id = 'root', kind = 'group', children = {
                    { id = 'c', kind = 'choice', control = 'c', options = { { label = 'x' }, { label = 'y', value = 2 } } } } }
            end, onControl = function() return WCResult.ok() end }))
        """)
        self.assertTrue(self.rt.eval('PanelOk[1]'))
        msg = self.rt.eval("NuiMessages[#NuiMessages]")
        self.assertEqual(msg.type, 'panel')
        opts = lua_list(msg.tree.children[1].options)
        self.assertEqual([o.value for o in opts], [2])
        self.rt.run('WCPanel.close()')
        # an option of the wrong type is skipped instead of breaking the open
        self.rt.run("""
            PanelBad = table.pack(WCPanel.open({ build = function()
                return { id = 'root', kind = 'group', children = { { id = 'c', kind = 'choice', control = 'c', options = { 'junk' } } } }
            end, onControl = function() return WCResult.ok() end }))
        """)
        self.assertTrue(self.rt.eval('PanelBad[1]'))
        self.assertTrue(self.rt.eval('NuiFocus'))


class RulesTests(EditorBase):
    def test_item_dropped_by_the_rules_is_a_conflict(self):
        self.rt.eval("openEditor('store', 'male', { context = { storeProfile = 'general', owned = {} },"
                     " app = (function() local a = AppearanceSchema.default('male'); a.clothing.equipped.belts = nil;"
                     " a.clothing.equipped.belt_buckles = nil return a end)() })")
        if self.registry()['clothing.belt_buckles.style'] is None:
            self.skipTest('belt buckles not offered by the test catalogue')
        r = self.action(op='set', control='clothing.belt_buckles.style', value=1)
        self.assertFalse(r.ok)
        self.assertEqual(r.code, 'CONFLICTING_ITEMS')
        self.assertTrue(r.message)
        self.assertIsNone(self.working('.clothing.equipped.belt_buckles'))
        self.assertIsNone(self.working('.clothing.tints.belt_buckles'))
        self.assertEqual(self.rt.eval('#WCEditor.session().history'), 0)
        self.assertFalse(r.payload.dirty)

    def test_full_restore_failure_of_an_untouched_category_is_accepted(self):
        self.rt.eval("openEditor('surgery', 'male', { sections = { 'face', 'skin' }, context = { price = 500 } })")
        # a saved item that never applies: reported by every full restore
        self.rt.run("ApplyFailed = { 'boots' }")
        r = self.action(op='set', control='face.head', value=2)
        self.assertTrue(r.ok, r.message)
        self.assertTrue(r.payload.dirty)
        # a failure in a category the edit changed still reverts
        self.rt.run("ApplyFailed = { 'heads' }")
        before = self.working('.head.head')
        r = self.action(op='set', control='face.head', value=3)
        self.assertEqual(r.code, 'INVALID_COMPONENT')
        self.assertEqual(self.working('.head.head'), before)

    def test_touched_categories(self):
        t = self.rt.eval("""(function()
            local a = AppearanceSchema.default('male')
            local b = WCUtil.copy(a)
            b.head.head = (a.head.head or 0) + 1
            b.clothing.equipped.hats = 123
            local touched = WCEditor.touchedCategories(a, b)
            local other = WCUtil.copy(a); other.sex = 'female'
            return { heads = touched.heads, hats = touched.hats, boots = touched.boots,
                     all = WCEditor.touchedCategories(a, other) == nil }
        end)()""")
        self.assertTrue(t.heads)
        self.assertTrue(t.hats)
        self.assertIsNone(t.boots)
        self.assertTrue(t.all)


class SurgeryTests(EditorBase):
    def test_hair_and_facial_hair_sections(self):
        self.rt.eval("openEditor('surgery', 'male', { sections = { hair = true, facialHair = true }, context = { price = 500 } })")
        stages = [s.id for s in lua_list(self.payload().stages)]
        self.assertEqual(stages, ['hair', 'facialHair', 'review'])
        self.assertIsNotNone(self.registry()['hair.style'])
        self.assertIsNotNone(self.registry()['facial.style'])
        self.assertIsNone(self.registry()['morph.noseWidth'])
        r = self.action(op='set', control='hair.style', value=2)
        self.assertTrue(r.ok, r.message)
        self.assertEqual(r.payload.price.total, 500)

    def test_female_surgery_never_offers_facial_hair(self):
        self.rt.eval("openEditor('surgery', 'female', { sections = { 'hair', 'facialHair' } })")
        stages = [s.id for s in lua_list(self.payload().stages)]
        self.assertEqual(stages, ['hair', 'review'])

    def test_clothing_section_offers_only_worn_or_owned_items(self):
        self.rt.eval("openEditor('surgery', 'male', { sections = { 'clothing' }, context = { owned = {} } })")
        tree = self.payload().tree
        self.assertIsNotNone(self.rt.g.findNode(tree, 'clothing'))
        saved = self.rt.eval('WCEditor.session().saved.clothing.equipped')
        for category in ('hats', 'boots', 'shirts_full'):
            style = self.registry()['clothing.%s.style' % category]
            if style is None:
                continue
            node = self.rt.g.findNode(tree, 'clothing.%s.style' % category)
            models = [o.value for o in lua_list(node.options) if o.value != 0]
            self.assertLessEqual(len(models), 1 if saved[category] else 0, category)

    def test_no_sections_no_tree(self):
        self.rt.eval("openEditor('surgery', 'male', { sections = {} })")
        self.assertEqual(len(lua_list(self.payload().tree.children)), 0)


class BarberPriceTests(EditorBase):
    def open_barber(self, services, extra=''):
        self.rt.run("Config.Barber.prices.visitCap = 10")
        self.rt.eval("openEditor('barber', 'male', { sections = { 'hair', 'facialHair' }, context = { services = "
                     + services + extra + " } })")

    def test_cap_is_scaled_by_the_location_multiplier(self):
        # multiplier 1.5: hair 15 + beard 15 -> base 20 capped at 10 -> 10 * 1.5 = 15 (server rule)
        self.open_barber("{ hair = { enabled = true, price = 15 }, facialHair = { enabled = true, price = 15 } }")
        r = self.action(op='set', control='hair.style', value=2)
        self.assertEqual(r.payload.price.total, 15)
        r = self.action(op='set', control='facial.style', value=1)
        self.assertEqual(r.payload.price.total, 15)

    def test_context_cap_wins(self):
        self.open_barber("{ hair = { enabled = true, price = 15 }, facialHair = { enabled = true, price = 15 } }",
                         ", visitCap = 12")
        self.action(op='set', control='hair.style', value=2)
        r = self.action(op='set', control='facial.style', value=1)
        self.assertEqual(r.payload.price.total, 12)

    def test_under_the_cap_is_the_sum(self):
        self.rt.run("Config.Barber.services.hair.price = 4; Config.Barber.services.facialHair.price = 4")
        self.open_barber("{ hair = { enabled = true, price = 6 }, facialHair = { enabled = true, price = 6 } }")
        self.action(op='set', control='hair.style', value=2)
        r = self.action(op='set', control='facial.style', value=1)
        self.assertEqual(r.payload.price.total, 12)


class SaveOpIdTests(EditorBase):
    def open_store(self, results):
        self.rt.run("SaveResults = " + results + "; SaveOps = {}")
        self.rt.eval("""openEditor('store', 'male', { context = { storeProfile = 'general', owned = {} },
            onCommit = function(app, extra)
                table.insert(SaveOps, extra.opId)
                local r = table.remove(SaveResults, 1)
                if r == 'throw' then error('lost') end
                return r
            end })""")
        self.assertTrue(self.action(op='set', control='clothing.hats.style', value=1).ok)

    def test_retry_after_a_lost_reply_reuses_the_opid(self):
        self.open_store("{ WCResult.fail('INTERNAL_ERROR'), 'throw', WCResult.ok() }")
        r1 = self.action(op='save', opId='nui-1')
        self.assertEqual(r1.code, 'INTERNAL_ERROR')
        r2 = self.action(op='save', opId='nui-2')
        self.assertEqual(r2.code, 'INTERNAL_ERROR')
        r3 = self.action(op='save', opId='nui-3')
        self.assertTrue(r3.ok)
        self.assertEqual(lua_list(self.rt.eval('SaveOps')), ['nui-1', 'nui-1', 'nui-1'])

    def test_definite_failure_or_a_change_starts_a_new_opid(self):
        self.open_store("{ WCResult.fail('INSUFFICIENT_FUNDS'), WCResult.fail('INTERNAL_ERROR'), WCResult.ok() }")
        self.assertEqual(self.action(op='save', opId='a').code, 'INSUFFICIENT_FUNDS')
        self.assertEqual(self.action(op='save', opId='b').code, 'INTERNAL_ERROR')
        # the working appearance changes (and back again): a new attempt
        self.assertTrue(self.action(op='set', control='clothing.hats.style', value=0).ok)
        self.assertTrue(self.action(op='set', control='clothing.hats.style', value=1).ok)
        self.assertTrue(self.action(op='save', opId='c').ok)
        self.assertEqual(lua_list(self.rt.eval('SaveOps')), ['a', 'b', 'c'])


if __name__ == '__main__':
    unittest.main()
