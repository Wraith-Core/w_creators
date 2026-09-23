"""Global-symbol audit: every global a script reads is defined on its side.

All Lua files of a resource share one environment per side, so a global read that no file of that
side defines is nil at runtime: a typo, a module of the other side (a client file calling a server
module), or a helper that was removed. The audit parses every script fxmanifest loads, per side
(shared + client, shared + server), with luaparser, tracking local scopes:

- defined = globals assigned (at top level or inside a function) and the roots of global function
  names (`function Foo()`, `function Foo.bar()`);
- a read = a global Name used as a value, the root of an index or a call.

A read passes when the name is defined on that side, is a Lua / CitizenFX / w_lib runtime global
(RUNTIME), is a native (a CamelCase name, not defined anywhere in the resource, used as a function:
called, or passed to pcall / xpcall / type), or is whitelisted in EXTERNAL with its reason. Roots of
dotted function names must also be assigned somewhere on the side (`function Foo.bar()` needs
`Foo = {}`).

Needs luaparser (pip install luaparser); skipped with a message without it.
"""
import re
import unittest

from harness import RESOURCE, manifest_scripts, read
from lua_source import code_only

try:
    from luaparser import ast as lua_ast
    from luaparser import astnodes as N
except ImportError:  # pragma: no cover - reported as a skip
    lua_ast = None

LUA_STD = {
    '_G', '_ENV', '_VERSION', 'assert', 'collectgarbage', 'error', 'getmetatable', 'ipairs', 'load', 'next',
    'pairs', 'pcall', 'print', 'rawequal', 'rawget', 'rawlen', 'rawset', 'select', 'setmetatable',
    'tonumber', 'tostring', 'type', 'xpcall', 'coroutine', 'math', 'string', 'table', 'utf8', 'os',
    'debug', 'require',
}
# Not in the RedM client runtime (the CitizenFX client sandbox has no os / io library): a client or
# shared script that reads them fails in game (shared code reads os through rawget(_G, 'os')).
CLIENT_UNAVAILABLE = {'os', 'io'}
# CitizenFX / RedM runtime and w_lib globals that are not CamelCase functions.
RUNTIME = {
    'Citizen', 'json', 'vector2', 'vector3', 'vector4', 'quat', 'exports', 'source', 'GlobalState',
    'LocalPlayer', 'Entity', 'Player', 'promise', 'msgpack', 'w', 'locale', 'lib', 'cache', 'joaat',
}
# Globals provided by another resource and read here: name -> (side or 'both', reason). Empty:
# the database goes through w.database (@oxmysql/lib/MySQL.lua's MySQL global is not read).
EXTERNAL = {}
# Natives read as a value (not called directly): name -> reason.
NATIVE_VALUES = {
    'EquipMetaPedOutfit': 'client/appearance/pipeline.lua SetWaist: availability check, then pcall',
    'RemoveIplByHash': 'client/scene/scene.lua unload: availability check, then pcall',
    'RemoveImap': 'client/scene/scene.lua unload: the fallback of RemoveIplByHash',
}

CAMEL = re.compile(r'^[A-Z][A-Za-z0-9_]*$')
FUNCTION_ARG_CALLS = {'pcall', 'xpcall', 'type'}


class Collector:
    """Walks one side's scripts: global definitions and reads (name, file, line, how)."""

    def __init__(self):
        self.defs = {}       # name -> [(file, line)]
        self.assigned = set()  # names given a value by an assignment or `function Name()`
        self.roots = {}      # name -> [(file, line)]  roots of dotted function names
        self.reads = []      # (name, file, line, how) how: call | fnarg | value

    # -- scopes -------------------------------------------------------------------------------
    def local(self, name):
        return any(name in s for s in self.scopes)

    def declare(self, name_node):
        if isinstance(name_node, N.Name):
            self.scopes[-1].add(name_node.id)

    def line(self, node):
        try:
            if node.line:
                return node.line
        except Exception:
            pass
        token = getattr(node, '_first_token', None)
        return getattr(token, 'line', 0) or 0

    # -- entry ----------------------------------------------------------------------------------
    def file(self, rel, src):
        self.rel = rel
        self.code = code_only(src)
        self.scopes = [set()]
        self.visit(lua_ast.parse(src))

    def define(self, node):
        self.defs.setdefault(node.id, []).append((self.rel, self.line(node)))

    def read(self, node, how):
        if not self.local(node.id):
            line = self.line(node)
            if not line:
                # luaparser keeps no position on some Name nodes: the first use in the code
                m = re.search(r'(?<![\w.:])%s\b' % re.escape(node.id), self.code)
                line = self.code.count('\n', 0, m.start()) + 1 if m else 0
            self.reads.append((node.id, self.rel, line, how))

    def function_name(self, name):
        if isinstance(name, N.Name):
            if not self.local(name.id):
                self.define(name)
                self.assigned.add(name.id)
            return
        root = name
        while isinstance(root, (N.Index, N.Invoke)):
            root = root.value if isinstance(root, N.Index) else root.source
        if isinstance(root, N.Name) and not self.local(root.id):
            self.roots.setdefault(root.id, []).append((self.rel, self.line(root)))
            self.define(root)

    def function_body(self, args, body, method=False):
        self.scopes.append(set(['self']) if method else set())
        for a in args:
            self.declare(a)
        self.visit(body)
        self.scopes.pop()

    # -- visitor --------------------------------------------------------------------------------
    def visit(self, node):
        if node is None:
            return
        if isinstance(node, list):
            for n in node:
                self.visit(n)
            return
        if not isinstance(node, N.Node):
            return
        kind = type(node).__name__
        method = getattr(self, 'v_' + kind, None)
        if method:
            method(node)
            return
        for key, value in node.__dict__.items():
            if key.startswith('_') or key in ('comments', 'wrapped'):
                continue
            if isinstance(value, (N.Node, list)):
                self.visit(value)

    def v_Chunk(self, node):
        self.visit(node.body)

    def v_Block(self, node):
        self.scopes.append(set())
        self.visit(node.body)
        self.scopes.pop()

    def v_LocalAssign(self, node):
        self.visit(node.values)
        for t in node.targets:
            self.declare(t)

    def v_LocalFunction(self, node):
        self.declare(node.name)
        self.function_body(node.args, node.body)

    def v_Function(self, node):
        self.function_name(node.name)
        self.function_body(node.args, node.body)

    def v_Method(self, node):
        self.function_name(node.source)
        self.function_body(node.args, node.body, method=True)

    def v_AnonymousFunction(self, node):
        self.function_body(node.args, node.body)

    def v_Assign(self, node):
        self.visit(node.values)
        for t in node.targets:
            if isinstance(t, N.Name):
                if not self.local(t.id):
                    self.define(t)
                    self.assigned.add(t.id)
            else:
                self.visit(t)

    def v_Fornum(self, node):
        self.visit([node.start, node.stop])
        if isinstance(node.step, N.Node):
            self.visit(node.step)
        self.scopes.append(set())
        self.declare(node.target)
        self.visit(node.body)
        self.scopes.pop()

    def v_Forin(self, node):
        self.visit(node.iter)
        self.scopes.append(set())
        for t in node.targets:
            self.declare(t)
        self.visit(node.body)
        self.scopes.pop()

    def v_Repeat(self, node):
        # the until condition sees the body's locals
        self.scopes.append(set())
        self.visit(node.body.body if isinstance(node.body, N.Block) else node.body)
        self.visit(node.test)
        self.scopes.pop()

    def v_Call(self, node):
        func = node.func
        if isinstance(func, N.Name):
            self.read(func, 'call')
            if func.id in FUNCTION_ARG_CALLS and node.args and isinstance(node.args[0], N.Name):
                self.read(node.args[0], 'fnarg')
                self.visit(node.args[1:])
                return
        else:
            self.visit(func)
        self.visit(node.args)

    def v_Invoke(self, node):
        self.visit(node.source)
        self.visit(node.args)

    def v_Index(self, node):
        self.visit(node.value)
        if node.notation != N.IndexNotation.DOT:
            self.visit(node.idx)

    def v_Field(self, node):
        if getattr(node, 'between_brackets', False):
            self.visit(node.key)
        self.visit(node.value)

    def v_Label(self, node):
        pass

    def v_Goto(self, node):
        pass

    def v_Name(self, node):
        self.read(node, 'value')


def collect(files):
    c = Collector()
    for rel in files:
        c.file(rel, read(RESOURCE / rel))
    return c


def side_files(side):
    return manifest_scripts('shared') + manifest_scripts(side)


def audit():
    """{side: sorted list of 'name  (file:line, how)'} of the undefined global reads."""
    sides = {side: collect(side_files(side)) for side in ('client', 'server')}
    project = set()
    for c in sides.values():
        project |= set(c.defs)
    problems = {}
    for side, c in sides.items():
        other = 'server' if side == 'client' else 'client'
        defined = set(c.defs)
        callable_names = {n for n, _, _, how in c.reads if how in ('call', 'fnarg')}
        bad = set()
        for name, rel, line, how in c.reads:
            if side == 'client' and name in CLIENT_UNAVAILABLE:
                bad.add('%s  (%s:%d, %s, not available in the client runtime)' % (name, rel, line, how))
                continue
            if name in defined or name in LUA_STD or name in RUNTIME:
                continue
            ext = EXTERNAL.get(name)
            if ext and ext[0] in (side, 'both'):
                continue
            is_native = CAMEL.match(name) and name not in project and not name.startswith('WC') \
                and name in callable_names
            if is_native or (name in NATIVE_VALUES and name not in project):
                continue
            where = 'defined only on the %s side' % other if name in sides[other].defs else 'undefined'
            bad.add('%s  (%s:%d, %s, %s)' % (name, rel, line, how, where))
        for root, places in c.roots.items():
            if root not in c.assigned and root not in LUA_STD and root not in RUNTIME:
                bad.add('%s  (%s:%d, function-name root never assigned)' % (root, places[0][0], places[0][1]))
        problems[side] = sorted(bad)
    return problems, sides


@unittest.skipIf(lua_ast is None, 'luaparser is not installed (pip install luaparser)')
class GlobalSymbolTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.problems, cls.sides = audit()

    def test_client_reads_only_defined_globals(self):
        self.assertEqual(self.problems['client'], [])

    def test_server_reads_only_defined_globals(self):
        self.assertEqual(self.problems['server'], [])

    def test_the_audit_sees_the_modules(self):
        client, server = self.sides['client'], self.sides['server']
        for name in ('WCEditor', 'WCState', 'WCSelector', 'WCSpawn', 'Appearance', 'Config', 'WCUtil'):
            self.assertIn(name, client.defs, name)
        for name in ('WCSessions', 'Bridge', 'WCCharacters', 'Config', 'WCUtil'):
            self.assertIn(name, server.defs, name)
        self.assertNotIn('WCSessions', client.defs)
        self.assertNotIn('WCEditor', server.defs)

    def test_the_audit_catches_an_undefined_read(self):
        c = Collector()
        c.file('probe.lua', 'local a = 1\nfunction F() return a + WCNope + b.c end\nGetEntityCoords(1)')
        names = {n for n, _, _, _ in c.reads}
        self.assertIn('WCNope', names)
        self.assertIn('b', names)
        self.assertNotIn('a', names)
        self.assertIn('F', c.defs)

    def test_external_entries_are_used(self):
        every = set()
        for c in self.sides.values():
            every |= {n for n, _, _, _ in c.reads}
        self.assertEqual(sorted(n for n in list(EXTERNAL) + list(NATIVE_VALUES) if n not in every), [])


if __name__ == '__main__':
    unittest.main()
