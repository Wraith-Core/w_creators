"""Client dev tools (client/dev/tools.lua): nothing is registered unless Config.Admin.devTools /
Config.Admin.spawnProp; every command asks the server for permission first (a refusal or a missing
callback does nothing); the commands refuse during flows; W:ADMIN:SpawnObject places a valid model
on the ground."""
import unittest

from test_client_services_support import make_services, settle

DEV_STUBS = r'''
DevRows = { { 0x9925C067, 111 }, { 0x05E47CA6, 0 } }
WCNative.metaped.numCategories = function(ped) return #DevRows end
WCNative.metaped.categoryAt = function(ped, i) return WCUtil.u32(DevRows[i + 1][1]) end
w.component.getCategoryNameFromHash = function(h) if WCUtil.u32(h) == 0x9925C067 then return "hats" end return "unknown" end
w.component.getComponentEquiped = function(ped, h)
    for _, r in ipairs(DevRows) do if WCUtil.u32(r[1]) == WCUtil.u32(h) then return r[2] ~= 0 and r[2] or false end end
    return false
end
w.component.getWearableState = function() return "base" end
Applied = {}
Appearance.ApplyComponent = function(ped, category, hash) Applied[#Applied + 1] = { category = category, hash = hash }
    return ApplyOk ~= false end
Removed = {}
Appearance.RemoveCategory = function(ped, category) Removed[#Removed + 1] = category return true end
Refreshes = 0
Appearance.Refresh = function() Refreshes = Refreshes + 1 return true end
function IsModelValid(h) return ValidModels ~= nil and ValidModels[h] == true end
GroundFound, GroundZ = true, 40.0
function GetGroundZAndNormalFor_3dCoord(x, y, z) return GroundFound, GroundZ, vector3(0, 0, 1) end
Created = {}
w.entity.create = function(model, pos, heading, networked)
    NextHandle = NextHandle + 1
    Peds[NextHandle] = { model = model, coords = pos }
    Created[#Created + 1] = { model = model, pos = pos, heading = heading, networked = networked, handle = NextHandle }
    return NextHandle
end
w.entity.delete = function(e) Peds[e] = nil end
function allow(ok) CallbackResults = CallbackResults or {}
    CallbackResults["w_creators:dev:allowed"] = ok and okResult() or fail("SERVICE_DISABLED") end
function command(name, ...) Events.commands[name].fn(0, { ... }) end
'''


class DisabledTests(unittest.TestCase):
    def test_nothing_registered_by_default(self):
        rt = make_services()
        for name in ('wc_inspect', 'wc_apply', 'wc_remove', 'wc_restore'):
            self.assertIsNone(rt.eval('Events.commands[%r]' % name), name)
        self.assertIsNone(rt.eval('Events.handlers["W:ADMIN:SpawnObject"]'))

    def test_spawn_prop_alone_registers_only_the_handler(self):
        rt = make_services('Config.Admin.spawnProp = true')
        self.assertIsNone(rt.eval('Events.commands.wc_inspect'))
        self.assertEqual(rt.eval('#Events.handlers["W:ADMIN:SpawnObject"]'), 1)

    def test_dev_tools_alone_registers_only_the_commands(self):
        rt = make_services('Config.Admin.devTools = true')
        for name in ('wc_inspect', 'wc_apply', 'wc_remove', 'wc_restore'):
            self.assertIsNotNone(rt.eval('Events.commands[%r]' % name), name)
        self.assertIsNone(rt.eval('Events.handlers["W:ADMIN:SpawnObject"]'))


class CommandTests(unittest.TestCase):
    def setUp(self):
        self.rt = make_services('Config.Admin.devTools = true')
        self.rt.run(DEV_STUBS)
        self.run = self.rt.run
        self.eval = self.rt.eval

    def test_refused_without_permission(self):
        self.run('allow(false)')
        self.run('command("wc_apply", "123")')
        self.assertEqual(self.eval('#Applied'), 0)
        self.assertEqual(self.eval('callbacks("w_creators:dev:allowed")[1][2]'), 'wc_apply')
        self.assertTrue(self.eval('noted(WCResult.messageKey("SERVICE_DISABLED"))'))

    def test_a_missing_callback_is_a_refusal(self):
        self.run('CallbackResults = { ["w_creators:dev:allowed"] = function() return nil end }')
        self.run('command("wc_restore")')
        self.assertEqual(self.eval('count("RestorePlayer")'), 0)
        self.assertTrue(self.eval('noted("هذا الأمر مخصص للمطورين")'))

    def test_apply_with_permission(self):
        self.run('allow(true)')
        self.run('command("wc_apply", "0x10")')
        self.assertEqual(self.eval('#Applied'), 1)
        self.assertEqual(self.eval('Applied[1].hash'), 16)
        self.assertEqual(self.eval('Refreshes'), 1)
        self.assertTrue(self.eval('noted("تم")'))

    def test_apply_uses_the_catalogue_category(self):
        self.run('allow(true)')
        self.run('H = WCState.appearance.clothing.equipped.boots')
        self.run('command("wc_apply", tostring(H))')
        self.assertEqual(self.eval('Applied[1].category'), 'boots')

    def test_apply_refuses_garbage(self):
        self.run('allow(true)')
        self.run('command("wc_apply", "not a hash!")')
        self.run('command("wc_apply")')
        self.assertEqual(self.eval('#Applied'), 0)
        self.assertTrue(self.eval('noted(WCResult.messageKey("INVALID_PAYLOAD"))'))

    def test_apply_failure_is_reported(self):
        self.run('allow(true); ApplyOk = false')
        self.run('command("wc_apply", "0x10")')
        self.assertEqual(self.eval('Refreshes'), 0)
        self.assertTrue(self.eval('noted(WCResult.messageKey("INVALID_COMPONENT"))'))

    def test_remove_and_restore(self):
        self.run('allow(true)')
        self.run('command("wc_remove", "hats")')
        self.assertEqual(self.eval('Removed[1]'), 'hats')
        self.run('command("wc_remove", "../x")')
        self.assertEqual(self.eval('#Removed'), 1)
        self.run('command("wc_restore")')
        self.assertEqual(self.eval('count("RestorePlayer")'), 1)

    def test_inspect_prints_the_categories(self):
        self.run('allow(true)')
        self.run('WCState.appearance.clothing.equipped.hats = 111')
        self.run('command("wc_inspect")')
        rows = self.rt.py(self.eval('WCDevClient.inspect(PlayerPedId())'))
        self.assertEqual(rows[1]['name'], 'hats')
        self.assertEqual(rows[1]['equipped'], 111)
        self.assertIsNone(rows[2].get('equipped'))
        text = '\n'.join(self.rt.py(self.eval('Printed'))[i]['text'] for i in range(1, self.eval('#Printed') + 1))
        self.assertIn('wc_inspect: 2 metaped categories', text)
        self.assertIn('hats', text)
        self.assertIn('(saved: hats)', text)

    def test_inspect_without_the_natives(self):
        self.run('allow(true); WCNative.metaped.numCategories = function() return nil end')
        self.run('command("wc_inspect")')
        self.assertTrue(self.eval('noted(WCResult.messageKey("SERVICE_DISABLED"))'))

    def test_refused_during_a_service_visit(self):
        self.run('allow(true)')
        self.run('CallbackResults["w_creators:barber:open"] = barberData()')
        self.run('WCBarber.open("valentine_barber")')
        self.run('command("wc_restore")')
        self.assertEqual(self.eval('called("w_creators:dev:allowed")'), 0)
        self.assertEqual(self.eval('count("RestorePlayer")'), 0)
        self.assertTrue(self.eval('noted(WCResult.messageKey("BUSY"))'))

    def test_refused_when_a_flow_starts_during_the_permission_check(self):
        self.run('CallbackResults = { ["w_creators:dev:allowed"] = function() WCState.busy("spawn", true)'
                 ' return okResult() end }')
        self.run('command("wc_restore")')
        self.assertEqual(self.eval('count("RestorePlayer")'), 0)


class SpawnObjectTests(unittest.TestCase):
    def setUp(self):
        self.rt = make_services('Config.Admin.spawnProp = true')
        self.rt.run(DEV_STUBS)
        self.run = self.rt.run
        self.eval = self.rt.eval

    def test_a_valid_model_is_placed_on_the_ground(self):
        self.run('ValidModels = { [GetHashKey("p_chair01x")] = true }')
        self.run('fireEvent("W:ADMIN:SpawnObject", nil, "p_chair01x")')
        settle(self.rt)
        self.assertEqual(self.eval('#Created'), 1)
        self.assertEqual(self.eval('Created[1].model'), self.eval('GetHashKey("p_chair01x")'))
        self.assertAlmostEqual(self.eval('Created[1].pos.z'), 40.02)
        self.assertEqual(self.eval('Created[1].heading'), 0.0)
        self.assertTrue(self.eval('Created[1].networked'))

    def test_a_numeric_model_and_no_ground(self):
        self.run('ValidModels = { [-5] = true }; GroundFound = false')
        self.run('fireEvent("W:ADMIN:SpawnObject", nil, "-5")')
        settle(self.rt)
        self.assertEqual(self.eval('#Created'), 1)
        self.assertAlmostEqual(self.eval('Created[1].pos.z'), self.eval('Peds[MyPed].coords.z') + 0.02)

    def test_invalid_models_are_ignored(self):
        self.run('ValidModels = {}')
        for bad in ('"nope"', '{}', 'nil', '"bad model!"'):
            self.run('fireEvent("W:ADMIN:SpawnObject", nil, %s)' % bad)
        settle(self.rt)
        self.assertEqual(self.eval('#Created'), 0)

    def test_props_are_deleted_on_stop(self):
        self.run('ValidModels = { [GetHashKey("p_chair01x")] = true }')
        self.run('fireEvent("W:ADMIN:SpawnObject", nil, "p_chair01x")')
        settle(self.rt)
        handle = self.eval('Created[1].handle')
        self.run('stopResource()')
        self.assertIsNone(self.eval('Peds[%d]' % handle))


if __name__ == '__main__':
    unittest.main()
