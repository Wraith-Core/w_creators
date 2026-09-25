"""Regenerates web/tests/fixtures/payloads.json from the Lua tree builder (client/editor/*.lua) with the
test catalogue (tests/fixtures/catalog.lua). Run from anywhere: python3 web/tests/fixtures/generate_payloads.py"""
import json
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
RESOURCE = HERE.parents[2]
sys.path.insert(0, str(RESOURCE / 'tests'))
from harness import Runtime
import test_editor_lua as t

def rt_new():
    rt = Runtime(); rt.load_shared(); rt.run(t.CLIENT)
    rt.load('client/editor/editor.lua', 'client/editor/tree.lua', 'client/editor/panel.lua')
    return rt

out = {}
def grab(name, setup, actions=()):
    rt = rt_new()
    rt.run(setup)
    rt.run("_LAST = lastPayload()")
    for a in actions:
        rt.run("local r = nui('editor:action', " + a + ") assert(r.ok, r.message) _LAST = r.payload")
    out[name] = json.loads(rt.eval("json.encode(_LAST)"))

grab('creatorMale', "openEditor('creator', 'male', { identity = { firstname = 'John' } })")
grab('creatorFemale', "openEditor('creator', 'female', { identity = {} })")
grab('surgery', "openEditor('surgery', 'female', { sections = { 'face', 'body', 'eyes', 'skin' }, context = { price = 500 } })",
     ["{ id = sid(), op = 'set', control = 'body.height', value = 1.05 }"])
grab('surgeryHair', "openEditor('surgery', 'male', { sections = { 'hair', 'facialHair' }, context = { price = 500 } })")
grab('barber', "openEditor('barber', 'male', { sections = { 'hair', 'facialHair', 'eyebrows', 'makeup' }, context = { growth = { hair = { stage = 1, remainingMinutes = 30 }, beard = { stage = 2, remainingMinutes = 5 } } } })")
grab('store', "openEditor('store', 'male', { context = { storeProfile = 'general', owned = {}, prices = { hats = 3.5 } } })",
     ["{ id = sid(), op = 'set', control = 'clothing.hats.style', value = 1 }"])
grab('storeExtras', """
    Config.Clothing.prices.hats = { cash = 3.5, gold = 0.2 }
    local hat = WCCatalog.forSex('male').hats.models[2][1].hash
    local owned = { [tostring(hat)] = { category = 'hats', source = 'store', pricePaid = 6, currency = 'cash',
        palette = 'metaped_tint_hat', tint0 = 1, tint1 = 2, tint2 = 3,
        colors = { { palette = 'metaped_tint_hat', tint0 = 9, tint1 = 9, tint2 = 9 } } } }
    openEditor('store', 'male', { onResell = function() return WCResult.ok({}) end, context = {
        storeProfile = 'general', owned = owned, currencies = { 'cash', 'gold' }, tintPrice = 2.5,
        outfits = { { id = 3, name = 'Work', data = { equipped = { hats = hat } } } }, outfitsEnabled = true,
        maxOutfits = 3, resell = { enabled = true, percent = 0.33 } } })""",
     ["{ id = sid(), op = 'set', control = 'clothing.hats.style', value = 2 }",
      "{ id = sid(), op = 'set', control = 'store.currency', value = 2 }",
      "{ id = sid(), op = 'set', control = 'clothing.boots.style', value = 2 }"])
grab('wardrobe', """
    local app = AppearanceSchema.default('male')
    local owned = {}
    for _, h in pairs(app.clothing.equipped) do owned[tostring(h)] = { category = 'x' } end
    openEditor('wardrobe', 'male', { app = app, context = { owned = owned, maxOutfits = 3,
        outfits = { { id = 7, name = 'Work', data = { equipped = {} } } } } })""")
rt = rt_new()
rt.run("""WCPanel.open({ title = 'إجراءات الملابس', build = function()
    return { id = 'root', kind = 'group', label = 'إجراءات الملابس', children = WCEditorTree.clothingActions(AppearanceSchema.default('male')) }
end, onControl = function() return WCResult.ok() end })""")
out['panel'] = json.loads(rt.eval("json.encode(NuiMessages[#NuiMessages])"))
out['charCard'] = {'type': 'charCard', 'show': True, 'name': 'John Marston', 'age': 34, 'dob': '1865-04-12',
                   'gender': 'ذكر', 'lastLocation': 'فالنتاين', 'job': 'Rancher', 'cash': 120.5, 'bank': 900, 'gold': 2,
                   'locale': 'ar', 'dir': 'rtl',
                   'strings': {'name': 'الاسم', 'age': 'العمر', 'dob': 'تاريخ الميلاد', 'gender': 'الجنس',
                               'lastLocation': 'آخر موقع', 'job': 'المهنة', 'cash': 'النقد', 'bank': 'البنك', 'gold': 'الذهب'}}
(HERE / 'payloads.json').write_text(json.dumps(out, ensure_ascii=False, indent=1) + '\n', encoding='utf-8')
