"""client/natives: validation, batching, experimental gating, never throwing on bad entities."""
import unittest

from harness import Runtime

CLIENT_STUBS = r'''
invoked = {}
Citizen.InvokeNative = function(hash, ...)
    invoked[#invoked + 1] = { hash = hash, args = { ... } }
    if throwNative then error('native crashed') end
    return nativeResult
end
Citizen.ResultAsInteger = function() return 'int' end
Citizen.ResultAsLong = function() return 'long' end
DoesEntityExist = function(e) return e == 77 or e == 88 end
IsEntityAPed = function(e) return e == 77 end
GetEntityModel = function() return GetHashKey('mp_male') end
GetEntityHeading = function() return 12.5 end
scaled = {}
SetPedScale = function(ped, v) scaled[#scaled + 1] = v end
resurrected = {}
NetworkResurrectLocalPlayer = function(...) resurrected[#resurrected + 1] = { ... } end
'''

def s64(h):
    """A 64-bit hex literal as Lua 5.4 reads it (wraps to a signed integer)."""
    return h - (1 << 64) if h >= (1 << 63) else h


FILES = ['client/natives/%s.lua' % n for n in ('metaped', 'ped', 'clothing', 'camera', 'respawn', 'scene', 'ui')]


class NativeTests(unittest.TestCase):
    def setUp(self):
        self.rt = Runtime().load_shared()
        self.rt.run(CLIENT_STUBS)
        self.rt.load(*FILES)
        self.e = self.rt.eval

    def hashes(self):
        return [c.hash for c in self.e('invoked').values()]

    def assertHashes(self, expected):
        self.assertEqual(self.hashes(), [s64(h) for h in expected])

    def test_refresh_is_one_pre_refresh_then_one_update(self):
        self.assertTrue(self.e('WCNative.ped.refresh(77)'))
        self.assertHashes([0x704C908E9C405136, 0xCC8CA3E88256E58F])
        args = list(self.e('invoked[2].args').values())
        self.assertEqual(args, [77, False, True, True, True, False])

    def test_invalid_entities_never_throw_and_never_invoke(self):
        for call in ('WCNative.ped.refresh(0)', 'WCNative.ped.setExpression(nil, 1, 1)',
                     'WCNative.ped.setExpression(88, 1, 1)',  # exists but not a ped
                     'WCNative.clothing.applyShopItem(5, 1)', 'WCNative.clothing.removeTag("x", "hats")',
                     'WCNative.metaped.isReadyToRender(-1)', 'WCNative.metaped.equipOutfitPreset({}, 3)',
                     'WCNative.ped.giveWeapon(0, "WEAPON_REVOLVER_CATTLEMAN", 6)',
                     'WCNative.scene.startScenario(0, "X")', 'WCNative.ped.setScale(0, 1)',
                     'WCNative.metaped.numCategories(0)', 'WCNative.respawn.resurrect(nil, 0)',
                     'WCNative.scene.loadSphere(0/0, 1, 2, 3, 4)'):
            self.rt.run('ok, res = pcall(function() return %s end)' % call)
            self.assertTrue(self.e('ok'), call)
            self.assertFalse(self.e('res'), call)
        self.assertEqual(self.hashes(), [])
        self.assertTrue(self.e('WCNative.ped.placeOnGround(88)'))  # entities (not only peds) are accepted

    def test_a_crashing_native_is_contained(self):
        self.rt.run('throwNative = true')
        self.assertFalse(self.e('WCNative.ped.updateVariation(77)'))
        self.assertFalse(self.e('WCNative.metaped.isReadyToRender(77)'))

    def test_expression_value_is_a_clamped_float(self):
        self.rt.run('WCNative.ped.setExpression(77, 34006, 1); WCNative.ped.setExpression(77, "7010", -5)')
        a = self.e('invoked[1].args')
        self.assertEqual(self.e('math.type(invoked[1].args[3])'), 'float')
        self.assertEqual((a[2], a[3]), (34006, 1.0))
        self.assertEqual(self.e('invoked[2].args[3]'), -1.0)
        self.rt.run('WCNative.ped.setScale(77, 1)')
        self.assertEqual(self.e('math.type(scaled[1])'), 'float')

    def test_ready_to_render_accepts_bool_or_int(self):
        self.rt.run('nativeResult = 1')
        self.assertTrue(self.e('WCNative.metaped.isReadyToRender(77)'))
        self.rt.run('nativeResult = 0')
        self.assertFalse(self.e('WCNative.metaped.isReadyToRender(77)'))

    def test_shop_item_and_tag_use_u32(self):
        self.rt.run('WCNative.clothing.applyShopItem(77, -1); WCNative.clothing.removeTag(77, "hats")')
        self.assertEqual(self.e('invoked[1].hash'), s64(0xD3A7B003ED343FD9))
        self.assertEqual(self.e('invoked[1].args[2]'), 0xffffffff)
        self.assertEqual(self.e('invoked[2].args[2]'), self.e('WCUtil.u32(GetHashKey("hats"))'))

    def test_experimental_wrappers_are_gated(self):
        self.assertIsNone(self.e('WCNative.metaped.requestPed(123, 100)'))
        self.assertFalse(self.e('WCNative.clothing.setHatAccess(1, true)'))
        self.assertFalse(self.e('WCNative.metaped.setVariationPreset(77, 1)'))
        self.assertEqual(self.hashes(), [])

    def test_request_lifecycle_times_out_and_releases(self):
        self.rt.run('''
            Config.Experimental.metapedRequestPath = true
            Citizen.InvokeNative = function(hash, ...)
                invoked[#invoked + 1] = { hash = hash, args = { ... } }
                if hash == 0xF97C34C33487D569 then return 5 end
                if hash == 0xC0940AC858C1E126 then return true end
                if hash == 0x43E4DA469541A9C9 then return loadedNow end
                if hash == 0x0BCD4091C8EABA42 then return 77 end
            end
            loadedNow = false
            handle = WCNative.metaped.requestPed(123, 50)
        ''')
        self.assertIsNone(self.e('handle'))
        self.assertEqual(self.hashes()[-1], s64(0x3972F78A78B5D9DF))  # released on timeout
        self.rt.run('loadedNow = true; handle = WCNative.metaped.requestPed(123, 50)')
        self.assertEqual(self.e('handle'), 5)
        self.assertEqual(self.e('WCNative.metaped.createPed(handle, vector3(1, 2, 3), 90, true)'), 77)
        self.assertTrue(self.e('WCNative.metaped.release(handle)'))
        self.assertFalse(self.e('WCNative.metaped.release(handle)'))  # idempotent
        self.assertIsNone(self.e('WCNative.metaped.createPed(handle, vector3(1, 2, 3), 90, true)'))
        self.rt.run('h2 = WCNative.metaped.requestPed(123, 50); n = #invoked; fireEvent("onResourceStop", nil, "w_creators")')
        self.assertEqual(self.e('invoked[#invoked].hash'), s64(0x3972F78A78B5D9DF))

    def test_resurrect_and_ui(self):
        self.assertTrue(self.e('WCNative.respawn.resurrect(vector3(1, 2, 3), 90)'))
        args = list(self.e('resurrected[1]').values())
        self.assertEqual(args, [1.0, 2.0, 3.0, 90.0, True, False])
        self.rt.run('nativeResult = 99; WCNative.ui.blankObjective(); WCNative.ui.clearObjective()')
        self.assertHashes([0xFA925AC00EB830B9, 0xFA233F8FE190514C, 0xE9990552DEC71600,
                                         0xFA233F8FE190514C, 0xE9990552DEC71600])
        self.assertEqual(self.e('invoked[2].args[1]'), 99)
        self.assertEqual(self.e('invoked[4].args[1]'), 0)

    def test_scene_wrappers(self):
        self.rt.run('WCNative.scene.loadSphere(-561.4, -3782.6, 237.6, 50, 20); WCNative.scene.startScenario(77, "MP_LOBBY_SCENARIO_08", -1)')
        self.rt.run('WCNative.ped.giveWeapon(77, "WEAPON_REVOLVER_CATTLEMAN", 6, false, true); WCNative.camera.letterbox(true)')
        self.assertHashes([0x513F8AA5BF2F17CF, 0x524B54361229154F, 0x5E3BDDBCB83F3D84, 0x69D65E89FFD72313])
        self.assertEqual(self.e('invoked[2].args[6]'), 12.5)  # the ped heading by default
        self.assertEqual(self.e('invoked[3].args[2]'), self.e('GetHashKey("WEAPON_REVOLVER_CATTLEMAN")'))


if __name__ == '__main__':
    unittest.main()
