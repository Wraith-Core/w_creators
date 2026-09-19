"""Regression for the live RedM zero-size preview (Lua integer vs float).

Run with Python and lupa.lua54. Live male/female checks are recorded in _checks.
"""
import unittest
from pathlib import Path
from lupa.lua54 import LuaRuntime, LuaError

ROOT = Path(__file__).resolve().parents[1]


class RenderScaleTests(unittest.TestCase):
    def setUp(self):
        self.lua = LuaRuntime(unpack_returned_tuples=True)
        self.lua.execute('''
            scales = {}; expressions = {}
            function SetPedScale(ped, value)
                assert(math.type(value) == 'float', 'native scale requires float')
                scales[#scales+1] = value
            end
            function SetCharExpression(ped, hash, value)
                assert(math.type(value) == 'float', 'native expression requires float')
                expressions[#expressions+1] = value
            end
            w = {component={data={expressions={arms=46032}}}}
        ''')
        self.lua.execute((ROOT/'modules/appearance.lua').read_text(encoding='utf-8-sig'))

    def test_json_integer_height_reaches_native_as_float(self):
        self.lua.execute('ApplyPedScale(7, 1); assert(scales[1] == 1.0)')

    def test_string_and_default_heights_reach_native_as_float(self):
        self.lua.execute('''
            ApplyPedScale(7, "1"); ApplyPedScale(7, nil); ApplyPedScale(7, 0)
            assert(#scales == 3)
            for _,v in ipairs(scales) do assert(v == 1.0) end
        ''')

    def test_fractional_height_is_preserved(self):
        self.lua.execute('''
            ApplyPedScale(7, .9); ApplyPedScale(7, 1.1)
            assert(scales[1] == .9 and scales[2] == 1.1)
        ''')

    def test_integer_expression_endpoints_reach_native_as_float(self):
        self.lua.execute('''
            for _,v in ipairs({-1,0,1}) do ApplyBodyExpressions(7,{arms=v}) end
            assert(expressions[1] == -1 and expressions[2] == 0 and expressions[3] == 1)
        ''')


class SceneReadinessTests(unittest.TestCase):
    def setUp(self):
        self.lua = LuaRuntime(unpack_returned_tuples=True)
        self.lua.execute('''
            function DoesEntityExist() return true end
            function GetEntityCoords() return {x=0,y=0,z=238.6} end
            function GetPedBoneCoords() return {x=0,y=0,z=238.6+headHeight} end
            Citizen={InvokeNative=function() return ready end}
            w={waitFor=function(check, message, timeout)
                for i=1,3 do if check() then return true end end
                error(message)
            end}
        ''')
        self.lua.execute((ROOT/'modules/scene.lua').read_text(encoding='utf-8-sig'))

    def test_numeric_zero_is_not_ready(self):
        self.lua.execute('ready=0; headHeight=.63')
        with self.assertRaises(LuaError): self.lua.execute('CreatorScene.ready(7)')

    def test_collapsed_skeleton_is_not_ready(self):
        self.lua.execute('ready=1; headHeight=0')
        with self.assertRaises(LuaError): self.lua.execute('CreatorScene.ready(7)')

    def test_renderable_male_and_female_are_ready(self):
        self.lua.execute('''
            ready=1; headHeight=.63; CreatorScene.ready(7)
            ready=true; headHeight=.53; CreatorScene.ready(7)
        ''')


if __name__ == '__main__': unittest.main()
