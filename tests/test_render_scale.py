"""Regression for the live RedM zero-size preview (Lua integer vs float).

The ped scale and the morphology values must reach the natives as floats: an integer is read as
raw bits and collapses every bone to the origin while the ped still reports ready. The render
pipeline (client/appearance/pipeline.lua) and the scene readiness check
(client/scene/scene.lua) are loaded with the recording client stubs.

Run with Python and lupa.lua54. Live male/female checks are recorded in _checks.
"""
import unittest

from test_client_infra_support import make_client

FLOAT_NATIVES = r'''
scales = {}; expressions = {}
function SetPedScale(ped, value)
    assert(math.type(value) == 'float', 'native scale requires float')
    scales[#scales + 1] = value
end
local invoke = Citizen.InvokeNative
Citizen.InvokeNative = function(hash, ped, id, value, ...)
    if hash == 0x5653AB26C82938CF then
        assert(math.type(value) == 'float', 'native expression requires float')
        expressions[#expressions + 1] = value
        return
    end
    return invoke(hash, ped, id, value, ...)
end
arms = WCMorph.byId.arms.expression
'''


class RenderScaleTests(unittest.TestCase):
    def setUp(self):
        self.rt = make_client()
        self.rt.run(FLOAT_NATIVES)
        self.lua = self.rt

    def test_json_integer_height_reaches_native_as_float(self):
        self.lua.run('Appearance.SetHeight(MyPed, 1); assert(scales[1] == 1.0 and math.type(scales[1]) == "float")')

    def test_string_and_default_heights_reach_native_as_float(self):
        self.lua.run('''
            Appearance.SetHeight(MyPed, "1"); Appearance.SetHeight(MyPed, nil); Appearance.SetHeight(MyPed, 0/0)
            assert(#scales == 3)
            for _, v in ipairs(scales) do assert(v == 1.0) end
        ''')

    def test_fractional_height_is_preserved_and_clamped(self):
        self.lua.run('''
            Appearance.SetHeight(MyPed, .9); Appearance.SetHeight(MyPed, 1.1); Appearance.SetHeight(MyPed, 5)
            assert(scales[1] == .9 and scales[2] == 1.1 and scales[3] == 1.1)
        ''')

    def test_integer_expression_endpoints_reach_native_as_float(self):
        self.lua.run('''
            for _, v in ipairs({ -1, 1 }) do
                expressions = {}
                Appearance.ApplyMorph(MyPed, { arms = v })
                assert(#expressions == #WCMorph.fields + 1)
                assert(expressions[#expressions] == v)
            end
        ''')

    def test_full_restore_sends_floats(self):
        self.lua.run('''
            local app = AppearanceSchema.default("male")
            app.body.height = 1
            app.morph = { arms = 1, calves = -1 }
            assert(Appearance.RestoreCharacter(MyPed, app))
            assert(#scales == 1 and scales[1] == 1.0)
            assert(#expressions == #WCMorph.fields + 2)
        ''')


class SceneReadinessTests(unittest.TestCase):
    def setUp(self):
        self.lua = make_client()
        self.lua.run('ped = makePed("mp_male", 0.0, 0.0, 238.6)')

    def ready(self):
        return self.lua.eval('CreatorScene.ready(ped, 100)')

    def test_numeric_zero_is_not_ready(self):
        self.lua.run('Peds[ped].ready = 0; Peds[ped].boneHeight = .63')
        self.assertFalse(self.ready())

    def test_collapsed_skeleton_is_not_ready(self):
        self.lua.run('Peds[ped].ready = 1; Peds[ped].boneHeight = 0')
        self.assertFalse(self.ready())

    def test_renderable_male_and_female_are_ready(self):
        self.lua.run('Peds[ped].ready = 1; Peds[ped].boneHeight = .63')
        self.assertTrue(self.ready())
        self.lua.run('Peds[ped].ready = true; Peds[ped].boneHeight = .53')
        self.assertTrue(self.ready())

    def test_missing_ped_is_not_ready(self):
        self.assertFalse(self.lua.eval('CreatorScene.ready(424242, 100)'))


if __name__ == '__main__':
    unittest.main()
