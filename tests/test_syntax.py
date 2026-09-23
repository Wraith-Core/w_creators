"""Every Lua file of the v3 layout compiles under plain Lua 5.4, the manifest lists only existing
files, and the ground rules of ARCHITECTURE.md §0 hold for the v3 directories.

Run: python3 -m unittest discover -s tests -p 'test_*.py'
"""
import re
import unittest

from lupa.lua54 import LuaRuntime

from harness import RESOURCE, manifest, read

V3_DIRS = ('config', 'shared', 'client', 'server')


def v3_lua_files():
    for d in V3_DIRS:
        yield from sorted((RESOURCE / d).rglob('*.lua'))


class SyntaxTests(unittest.TestCase):
    def test_every_v3_lua_file_compiles(self):
        # Plain Lua 5.4 rejects backtick hashes and compound assignment operators, so compiling
        # is also the check for those CitizenFX-only extensions.
        lua = LuaRuntime(unpack_returned_tuples=True)
        compile_ = lua.eval('function(code, name) local f, err = load(code, name, "t") return f ~= nil, err end')
        files = list(v3_lua_files())
        self.assertGreater(len(files), 60)
        for path in files:
            ok, err = compile_(read(path), '@' + str(path.relative_to(RESOURCE)))
            self.assertTrue(ok, '%s: %s' % (path.relative_to(RESOURCE), err))

    def test_manifest_lists_existing_files_in_contract_order(self):
        m = manifest()
        shared = m['shared_scripts']
        self.assertEqual(shared[0], '@w_lib/init.lua')
        self.assertEqual(shared[1], 'config/main.lua')
        self.assertEqual(m['server_scripts'][0], '@oxmysql/lib/MySQL.lua')
        self.assertEqual(m['ui_page'], 'web/build/index.html')
        self.assertIn('locales/*.json', m['files'])
        self.assertEqual(m['w_lib'], ['locale', 'component', 'callback'])
        for side in ('shared_scripts', 'client_scripts', 'server_scripts'):
            for p in m[side]:
                if p.startswith('@'):
                    continue
                self.assertTrue((RESOURCE / p).exists(), p)
        client = m['client_scripts']
        self.assertTrue(all(p.startswith('client/natives/') for p in client[:7]))
        self.assertEqual(client[-1], 'client/api.lua')
        self.assertEqual(m['server_scripts'][-1], 'server/api.lua')
        order = [p for p in shared if p.startswith('shared/')]
        self.assertEqual(order, ['shared/%s.lua' % n for n in (
            'util', 'result', 'debug', 'services', 'locations', 'morphology', 'overlays', 'catalog',
            'rules', 'appearance', 'grooming', 'clothing_states', 'identity')])

    def test_raw_natives_only_in_client_natives(self):
        for path in v3_lua_files():
            rel = path.relative_to(RESOURCE).as_posix()
            if rel.startswith('client/natives/'):
                continue
            code = re.sub(r'--[^\n]*', '', read(path))
            self.assertNotRegex(code, r'InvokeNative|N_0x', rel)

    def test_no_debug_markers(self):
        for path in v3_lua_files():
            code = read(path)
            self.assertNotRegex(code, r'\b(TODO|FIXME|TEMP)\b', path.relative_to(RESOURCE))

    def test_every_native_wrapper_is_documented(self):
        for path in sorted((RESOURCE / 'client' / 'natives').glob('*.lua')):
            code = read(path)
            for m in re.finditer(r'H\.invoke\((0x[0-9A-Fa-f]+)', code):
                self.assertRegex(code, r'-- hash: %s' % m.group(1), '%s: %s undocumented' % (path.name, m.group(1)))
            for block in re.findall(r'-- hash: [^\n]+', code):
                self.assertIn('confidence:', block)
            self.assertEqual(code.count('-- hash:'), code.count('OneSync tested here: no'), path.name)
            # every §10 doc block (from `-- hash:` to its OneSync line) carries every field
            blocks = re.findall(r'-- hash: .*?OneSync tested here: no[^\n]*', code, re.S)
            self.assertEqual(len(blocks), code.count('-- hash:'), path.name)
            for block in blocks:
                for field in ('confidence:', 'params:', 'returns:', 'limitations:', 'tested models:', 'MP safe:'):
                    self.assertIn(field, block, '%s: %s lacks %s' % (path.name, block.splitlines()[0], field))


if __name__ == '__main__':
    unittest.main()
