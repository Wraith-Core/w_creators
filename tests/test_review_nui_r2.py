"""Review round 2, area "nui" (client/editor/**, web/**): regression tests.

- store: the price preview (WCEditorTree.price) follows WCClothingStore.plan for a worn item the
  character does not own (a job uniform applied by SetClothes): a dye of it is a purchase of the item
  plus the dye; the item card is not 'owned' and shows the price; the colour controls are offered only
  where the store sells the item; the unowned saved item put back on is untouched (free). Every case
  is compared end to end with the real server plan (server open data -> editor -> Store.plan);
- surgery: equipping another owned item settles the clothing states as the clinic's commit does
  (WCOwnership.settleStates), so the preview never hides the new hat behind a saved 'off';
- wardrobe: the new outfit's name field is its Save action (one step: the typed name travels with
  the invoke), no separate Save row that stays disabled while a name is on screen;
- creator: the DOB picker's min / max are exactly the dates WCIdentity.validateDob accepts.

Run: python3 -m unittest discover -s tests -p 'test_review_nui_r2.py'
"""
import datetime
import unittest

from harness import RESOURCE, read
from test_editor_lua import EditorBase, lua_list
from test_server_commerce_store import commerce
from test_server_services_barber import services_server


# ---------------------------------------------------------------------------------------------
# Store: the preview follows the server plan for worn but unowned items
# ---------------------------------------------------------------------------------------------
SERVER = r'''
uniform = h('male', 'hats', 2)                   -- a job uniform (SetClothes: no ownership row)
boots = h('male', 'boots', 1)
base = S.default('male'); base.clothing.equipped.hats = uniform; base.clothing.equipped.boots = boots
base.clothing.tints.hats = UNIFORM_TINT
own('vorp:1', 'boots', boots, nil, 'legacy')
setSaved('vorp:1', base)
opened = openStore()
OPEN = json.encode(opened.data)
function planFor(workingJson)
    local plan, code = WCClothingStore.plan(saved('vorp:1'), json.decode(workingJson), WCOwnership.list('vorp:1'),
                                            WCLocations.byId('valentine_clothing'))
    return plan and plan.total or nil, code
end
'''

CLIENT = r'''
function openFromServer(openJson)
    local data = json.decode(openJson)
    return openEditor('store', 'male', { app = data.appearance, context = {
        owned = data.owned, prices = data.prices, tintPrice = data.tintPrice,
        storeProfile = data.storeProfile, pricingProfile = data.pricingProfile } })
end
function workingJson() return json.encode(WCEditor.session().working) end
'''


class UniformBase(EditorBase):
    """The server's open data of the Valentine store (a worn, unowned uniform hat; owned boots)
    opens the real editor; totals() compares WCEditorTree.price with WCClothingStore.plan."""

    UNIFORM_TINT = 'nil'

    def setUp(self):
        super().setUp()
        self.server = commerce()
        self.server.run('UNIFORM_TINT = ' + self.UNIFORM_TINT)
        self.server.run(SERVER)
        self.assertTrue(self.server.eval('opened.ok'), self.server.eval('opened.code'))
        self.rt.run(CLIENT)
        self.assertTrue(self.rt.g.openFromServer(self.server.eval('OPEN')))

    def act(self, control, value):
        r = self.action(op='set', control=control, value=value)
        self.assertTrue(r.ok, r.message)
        return r

    def totals(self):
        client = self.rt.eval('WCEditorTree.price(WCEditor.session()).total')
        self.server.g.WORKING = self.rt.eval('workingJson()')
        server_total, code = self.server.eval('planFor(WORKING)')
        return client, server_total, code


class StoreUniformPriceTests(UniformBase):
    def test_dyeing_the_unowned_uniform_is_priced_like_the_server(self):
        self.act('clothing.hats.palette', 1)
        self.act('clothing.hats.tint0', 10)
        client, server_total, code = self.totals()
        self.assertIsNotNone(server_total, code)
        self.assertEqual(client, server_total)
        self.assertEqual(client, 6.0)                                   # the hat 3.5 + the dye 2.5
        price = self.rt.eval('WCEditor.payload().price')
        self.assertEqual(len(lua_list(price.lines)), 2, 'the item and the dye are both on screen')

    def test_the_uniform_card_is_equipped_not_owned_and_shows_its_price(self):
        hats = self.rt.g.findNode(self.payload().tree, 'item.hats')
        self.assertEqual(hats.badge, 'equipped')
        self.assertEqual(hats.summary, '$3.50')
        card = self.rt.g.findNode(hats, 'clothing.hats.card').item
        self.assertFalse(card.owned)
        self.assertTrue(card.equipped)
        self.assertEqual(card.price, 3.5)
        # an owned worn item: owned, no price
        boots = self.rt.g.findNode(self.payload().tree, 'item.boots')
        card = self.rt.g.findNode(boots, 'clothing.boots.card').item
        self.assertTrue(card.owned)
        self.assertIsNone(card.price)
        self.assertIsNone(boots.summary)

    def test_dyeing_an_owned_worn_item_costs_the_dye_only(self):
        self.act('clothing.boots.palette', 1)
        client, server_total, code = self.totals()
        self.assertIsNotNone(server_total, code)
        self.assertEqual((client, server_total), (2.5, 2.5))

    def test_untouched_and_the_uniform_put_back_on_are_free(self):
        self.assertEqual(self.totals()[0], 0)
        # another hat is bought (both sides agree), then the uniform again is the saved item: free
        self.act('clothing.hats.style', 1)
        client, server_total, code = self.totals()
        self.assertIsNotNone(server_total, code)
        self.assertEqual(client, server_total)
        self.act('clothing.hats.style', 2)
        self.assertEqual(self.totals()[:2], (0, 0))                        # nothing changed at all
        self.assertFalse(self.rt.eval('WCEditor.payload().dirty'))

    def test_a_uniform_the_store_does_not_sell_offers_no_colour(self):
        self.rt.run('''
            local available = WCCatalog.available
            Uniform = WCEditor.session().saved.clothing.equipped.hats
            WCCatalog.available = function(p, sex, c, hash)
                if WCUtil.u32(hash) == WCUtil.u32(Uniform) then return false end
                return available(p, sex, c, hash)
            end
            WCEditor.refresh()
        ''')
        self.assertIsNone(self.registry()['clothing.hats.palette'])
        self.assertIsNone(self.rt.g.findNode(self.rt.eval('WCEditor.payload()').tree, 'clothing.hats.color'))
        # the uniform itself is still shown (worn), and an owned item stays dyeable
        self.assertIsNotNone(self.registry()['clothing.hats.style'])
        self.assertIsNotNone(self.registry()['clothing.boots.palette'])

    def test_is_purchase_is_the_server_rule(self):
        self.rt.run('''
            S0 = WCEditor.session()
            U = S0.saved.clothing.equipped.hats
            P = WCCatalog.tintable('hats')[1]
        ''')
        dye = '{ palette = P, tint0 = 1, tint1 = 0, tint2 = 0 }'
        self.assertFalse(self.rt.eval("WCEditorTree.isPurchase(S0, 'hats', U, nil)"))
        self.assertTrue(self.rt.eval("WCEditorTree.isPurchase(S0, 'hats', U, %s)" % dye))
        self.assertFalse(self.rt.eval("WCEditorTree.isPurchase(S0, 'boots', S0.saved.clothing.equipped.boots, %s)" % dye))
        self.assertFalse(self.rt.eval("WCEditorTree.isPurchase(S0, 'hats', 0)"))


class DyedUniformTests(UniformBase):
    """A uniform saved with a dye: the saved dye is its own colour (WCOwnership.wornTint)."""

    UNIFORM_TINT = "{ palette = WCCatalog.tintable('hats')[1], tint0 = 4, tint1 = 5, tint2 = 6 }"

    def test_put_back_on_it_keeps_its_saved_dye_and_is_free(self):
        self.act('clothing.hats.style', 1)
        self.assertIsNone(self.working('.clothing.tints.hats'))
        self.act('clothing.hats.style', 2)
        self.assertEqual(self.working('.clothing.tints.hats.tint0'), 4)
        self.assertEqual(self.totals()[:2], (0, 0))

    def test_back_to_the_original_colour_is_a_purchase_of_the_item(self):
        self.act('clothing.hats.palette', 0)
        client, server_total, code = self.totals()
        self.assertIsNotNone(server_total, code)
        self.assertEqual((client, server_total), (3.5, 3.5))


# ---------------------------------------------------------------------------------------------
# Surgery: the clothing states of a swapped item are settled like the clinic's commit
# ---------------------------------------------------------------------------------------------
SURGERY = r'''
H = function(m) return WCCatalog.forSex('male').hats.models[m][1].hash end
surgeryApp = AppearanceSchema.default('male')
surgeryApp.clothing.equipped.hats = H(1)
surgeryApp.clothing.states = { hat = 'off' }
surgeryOwned = { [tostring(WCUtil.u32(H(1)))] = { category = 'hats' }, [tostring(WCUtil.u32(H(2)))] = { category = 'hats' } }
function openSurgery()
    return openEditor('surgery', 'male', { app = surgeryApp, sections = { 'face', 'clothing' },
        context = { price = 500, owned = surgeryOwned } })
end
'''


class SurgeryStatesTests(EditorBase):
    def setUp(self):
        super().setUp()
        self.rt.run(SURGERY)
        self.assertTrue(self.rt.eval('openSurgery()'))
        self.assertEqual(self.working('.clothing.states.hat'), 'off')

    def test_a_swapped_hat_is_shown_visible_and_the_saved_one_keeps_its_state(self):
        r = self.action(op='set', control='clothing.hats.style', value=2)
        self.assertTrue(r.ok, r.message)
        self.assertEqual(self.working('.clothing.equipped.hats'), self.rt.eval('H(2)'))
        self.assertIsNone(self.working('.clothing.states.hat'))
        r = self.action(op='set', control='clothing.hats.style', value=1)
        self.assertTrue(r.ok, r.message)
        self.assertEqual(self.working('.clothing.states.hat'), 'off')
        self.assertFalse(self.payload().dirty)

    def test_the_preview_matches_the_clinic_commit(self):
        self.assertTrue(self.action(op='set', control='clothing.hats.style', value=2).ok)
        working = self.rt.eval('json.encode(WCEditor.session().working)')
        server = services_server()
        server.g.WORKING = working
        server.run(r'''
            Config.CosmeticSurgery.allow.clothing = true
            local hat = function(m) return WCCatalog.forSex('male').hats.models[m][1].hash end
            local base = S.default('male'); base.clothing.equipped.hats = hat(1); base.clothing.states = { hat = 'off' }
            setSaved(base)
            local owned = { [WCOwnership.key(hat(1))] = { category = 'hats' }, [WCOwnership.key(hat(2))] = { category = 'hats' } }
            plan, code = WCSurgeryService.plan(WCAppearanceRepo.load('vorp:1'), json.decode(WORKING), { price = 10 }, owned)
        ''')
        self.assertIsNotNone(server.eval('plan'), server.eval('code'))
        self.assertEqual(server.eval('json.encode(plan.merged.clothing.states)'),
                         self.rt.eval('json.encode(WCEditor.session().working.clothing.states)'))


# ---------------------------------------------------------------------------------------------
# Wardrobe: the new outfit is named and saved in one step
# ---------------------------------------------------------------------------------------------
WARDROBE = r'''
OutfitCalls = {}
OutfitAnswer = function() return WCResult.ok({}) end
function openWardrobe(max, outfits)
    local app = AppearanceSchema.default('male')
    local owned = {}
    for _, h in pairs(app.clothing.equipped) do owned[tostring(h)] = { category = 'x' } end
    return openEditor('wardrobe', 'male', { app = app,
        context = { owned = owned, maxOutfits = max or 3, outfits = outfits or {} },
        onOutfit = function(op, id, value)
            OutfitCalls[#OutfitCalls + 1] = { op = op, id = id, value = value }
            return OutfitAnswer(op, id, value)
        end })
end
'''


class OutfitSaveTests(EditorBase):
    def setUp(self):
        super().setUp()
        self.rt.run(WARDROBE)

    def new_group(self):
        return self.rt.g.findNode(self.payload().tree, 'outfit.new')

    def test_the_name_field_is_the_save_action(self):
        self.assertTrue(self.rt.eval('openWardrobe()'))
        group = self.new_group()
        kids = lua_list(group.children)
        self.assertEqual([(k.kind, k.id) for k in kids], [('text', 'outfit.new.name')])
        field = kids[0]
        self.assertEqual(field.actionLabel, 'حفظ')                       # Save, not Apply
        self.assertTrue(field.required)
        self.assertTrue(field.clear)
        self.assertIsNone(field.reason, 'no "type the name first" while the field is the action')
        self.assertIsNone(field.disabled)
        r = self.action(op='invoke', control='outfit.new.name', value='  Work  ')
        self.assertTrue(r.ok, r.message)
        self.assertEqual(self.rt.eval('#OutfitCalls'), 1)
        self.assertEqual(self.rt.eval('OutfitCalls[1].op'), 'save')
        self.assertEqual(self.rt.eval('OutfitCalls[1].value.name'), 'Work')
        self.assertIsNotNone(self.rt.eval('OutfitCalls[1].value.equipped'))
        self.assertEqual(lua_list(self.new_group().children)[0].value, '')

    def test_an_empty_name_is_refused_without_a_server_call(self):
        self.assertTrue(self.rt.eval('openWardrobe()'))
        r = self.action(op='invoke', control='outfit.new.name', value='   ')
        self.assertFalse(r.ok)
        self.assertEqual(r.code, 'INVALID_OUTFIT_NAME')
        self.assertEqual(self.rt.eval('#OutfitCalls'), 0)

    def test_a_refused_save_keeps_the_typed_name(self):
        self.rt.run("OutfitAnswer = function() return WCResult.fail('INVALID_OUTFIT_NAME') end")
        self.assertTrue(self.rt.eval('openWardrobe()'))
        r = self.action(op='invoke', control='outfit.new.name', value='Bad')
        self.assertFalse(r.ok)
        group = self.rt.g.findNode(self.rt.eval('WCEditor.payload()').tree, 'outfit.new')
        self.assertEqual(lua_list(group.children)[0].value, 'Bad')

    def test_a_full_wardrobe_disables_the_field_with_its_reason(self):
        self.assertTrue(self.rt.eval("openWardrobe(1, { { id = 7, name = 'Work', data = { equipped = {} } } })"))
        field = lua_list(self.new_group().children)[0]
        self.assertTrue(field.disabled)
        self.assertEqual(field.reason, 'وصلت إلى الحد الأقصى من الأطقم')
        self.assertIsNone(self.registry()['outfit.new.name'])

    def test_the_nui_sends_the_typed_value_and_blocks_an_empty_one(self):
        src = read(RESOURCE / 'web' / 'src' / 'TreeView.jsx')
        text_node = src[src.index('export function TextNode'):src.index('function Plate')]
        self.assertIn('onInvoke(node.control,draft)', text_node)
        self.assertIn('textBlocked(node,draft)', text_node)
        self.assertIn('node.clear', text_node)
        state = read(RESOURCE / 'web' / 'src' / 'treeState.js')
        self.assertIn('export function textBlocked', state)


# ---------------------------------------------------------------------------------------------
# Creator: the DOB picker offers exactly the dates the age check accepts
# ---------------------------------------------------------------------------------------------
class DobBoundsTests(EditorBase):
    TODAYS = [(2026, 9, 23), (1900, 1, 1), (1899, 12, 31), (2028, 2, 29), (2027, 2, 28), (2024, 3, 1),
              (1895, 6, 30)]

    def setUp(self):
        super().setUp()
        self.rt.run("os = nil; GlobalState = {}; Config.Characters.identity.referenceYear = nil")
        self.min_age = self.rt.eval('Config.Characters.identity.minAge') or 18
        self.max_age = self.rt.eval('Config.Characters.identity.maxAge') or 90

    def set_today(self, y, m, d):
        self.rt.run("GlobalState[WCUtil.TODAY_KEY] = { year = %d, month = %d, day = %d }" % (y, m, d))

    def valid(self, date):
        return self.rt.eval("(WCIdentity.validateDob('%s'))" % date.strftime('%Y-%m-%d')) is True

    def test_bounds_are_the_exact_validation_window(self):
        one = datetime.timedelta(days=1)
        for today in self.TODAYS:
            with self.subTest(today=today):
                self.set_today(*today)
                lo, hi = self.rt.eval('WCEditor.dobBounds(nil, %d, %d)' % (self.min_age, self.max_age))
                lo_d = datetime.date.fromisoformat(lo)
                hi_d = datetime.date.fromisoformat(hi)
                self.assertTrue(self.valid(lo_d), lo)
                self.assertTrue(self.valid(hi_d), hi)
                self.assertFalse(self.valid(lo_d - one), lo_d - one)
                self.assertFalse(self.valid(hi_d + one), hi_d + one)

    def test_the_reported_dates(self):
        self.set_today(2026, 9, 23)
        self.rt.eval("openEditor('creator', 'male', { identity = {} })")
        dob = lua_list(self.payload().identity.fields)[2]
        self.assertEqual((dob.min, dob.max), ('1935-09-24', '2008-09-23'))
        # 2008-12-01 (age 17) is no longer offered; 1935-10-01 (age 90, valid) now is
        self.assertFalse(self.valid(datetime.date(2008, 12, 1)))
        self.assertTrue(self.valid(datetime.date(1935, 10, 1)))
        self.assertTrue(dob.min <= '1935-10-01' <= dob.max)
        self.assertFalse(dob.min <= '2008-12-01' <= dob.max)

    def test_a_reference_year_keeps_whole_year_bounds(self):
        # the age is then referenceYear - year: whole years are exact
        self.assertEqual(lua_list(self.rt.eval('{ WCEditor.dobBounds(1899, 18, 90) }')),
                         ['1809-01-01', '1881-12-31'])

    def test_unknown_date_has_no_bounds(self):
        self.assertEqual(lua_list(self.rt.eval('{ WCEditor.dobBounds(nil, 18, 90) }')), [])


if __name__ == '__main__':
    unittest.main()
