"""Reusable Lua test harness for w_creators (Python + lupa, Lua 5.4).

Usage (from any tests/test_*.py; the tests directory is on sys.path under unittest discovery):

    from harness import Runtime, RESOURCE, manifest

    rt = Runtime()                    # stubs + fixture catalogue (tests/fixtures/catalog.lua)
    rt = Runtime(catalog='real')      # the real w_lib catalogue (skip the test if not REAL_CATALOG)
    rt.load_shared()                  # config/*.lua + shared/*.lua in fxmanifest order
    rt.load_server_core()             # + server bridge/core/appearance repository/spawn (manifest order)
    rt.load('server/core/economy.lua')
    rt.eval('WCUtil.u32(-1)')         # evaluate a Lua expression
    rt.run('x = 1')                   # execute Lua statements
    rt.g.FakeDB / rt.g.FakeUsers / rt.g.Events / rt.g.Clock / rt.g.tick(ms)

Stubs (tests/lua/stubs.lua): fake clock + coroutine threads (Wait yields inside CreateThread,
tick(ms) resumes), joaat/GetHashKey (signed int32 like RedM), vector3/vector4, events
(AddEventHandler/RegisterNetEvent/fireEvent/TriggerClientEvent recorded in Events.client),
players (Players[src] = {name, coords, bucket}), locale(), w.print/notify/callback/logs, a fake
w.database (FakeDB: scripted handlers, recorded queries, schema simulator, transaction toggles)
and fake framework users (FakeUsers[src] = {money=..., failRemove, failAdd}).
The JSON codec (tests/lua/json.lua) behaves like the CitizenFX rxi json.lua.
"""

from pathlib import Path

from lupa.lua54 import LuaRuntime

TESTS = Path(__file__).resolve().parent
RESOURCE = TESTS.parent
W_LIB = RESOURCE.parent / 'w_lib'
REAL_CATALOG_PATH = W_LIB / 'modules' / 'component' / 'data' / 'playerComponents.lua'
REAL_CATALOG = REAL_CATALOG_PATH.exists()


def read(path):
    return Path(path).read_text(encoding='utf-8-sig')


_MANIFEST_READER = r"""
local code = ...
local out = { files = {}, lists = {} }
local env = setmetatable({}, { __index = function(_, name)
    return function(value)
        if type(value) == 'table' then
            out.lists[name] = out.lists[name] or {}
            for _, item in ipairs(value) do table.insert(out.lists[name], item) end
        else
            out[name] = value
        end
        return function() end
    end
end })
local chunk = assert(load(code, '@fxmanifest.lua', 't', env))
chunk()
return out
"""


def manifest():
    """The parsed fxmanifest.lua: {'shared_scripts': [...], 'client_scripts': [...], ...}."""
    lua = LuaRuntime(unpack_returned_tuples=True)
    result = lua.execute(_MANIFEST_READER, read(RESOURCE / 'fxmanifest.lua'))
    lists = {}
    for name, items in result['lists'].items():
        lists[name] = [items[i] for i in range(1, len(items) + 1)]
    scalars = {k: v for k, v in result.items() if k not in ('lists', 'files')}
    lists.update(scalars)
    return lists


def manifest_scripts(side):
    """Resource-local Lua scripts of a side ('shared', 'client', 'server'), in load order."""
    return [p for p in manifest().get(side + '_scripts', []) if not p.startswith('@')]


class Runtime:
    def __init__(self, catalog='fixture'):
        self.lua = LuaRuntime(unpack_returned_tuples=True)
        self.g = self.lua.globals()
        self.g.json = self.lua.execute(read(TESTS / 'lua' / 'json.lua'))
        self.lua.execute(read(TESTS / 'lua' / 'stubs.lua'))
        data = self.lua.execute(read(TESTS / 'fixtures' / 'component_data.lua'))
        if catalog == 'real':
            if not REAL_CATALOG:
                raise RuntimeError('w_lib catalogue not available at %s' % REAL_CATALOG_PATH)
            cat = self.lua.execute(read(REAL_CATALOG_PATH))
        else:
            cat = self.lua.execute(read(TESTS / 'fixtures' / 'catalog.lua'))
        self.g.setComponentData(cat, data)

    # -- loading ---------------------------------------------------------------------------
    def load(self, *paths):
        for path in paths:
            self.lua.execute(read(RESOURCE / path), name='@w_creators/' + path)
        return self

    def load_shared(self):
        return self.load(*manifest_scripts('shared'))

    def load_server_core(self):
        """Shared scripts, then the server scripts up to and including the appearance repository
        and the spawn service (bridge, core, repository, spawn)."""
        self.load_shared()
        wanted = ('server/bridge/', 'server/core/', 'server/appearance/repository.lua', 'server/spawn/spawn.lua')
        return self.load(*[p for p in manifest_scripts('server') if p.startswith(wanted)])

    # -- evaluation ------------------------------------------------------------------------
    def run(self, code):
        return self.lua.execute(code)

    def eval(self, expr):
        return self.lua.eval(expr)

    def table(self, value):
        """Python dict/list -> Lua table (recursive)."""
        return self.lua.table_from(value, recursive=True)

    def py(self, value):
        """Lua table -> Python (dict; arrays become dicts keyed 1..n)."""
        if hasattr(value, 'items'):
            return {k: self.py(v) for k, v in value.items()}
        return value

    def client_events(self, name):
        return [e for _, e in self.g.Events.client.items() if e.name == name]
