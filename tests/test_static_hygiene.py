"""Static hygiene (ARCHITECTURE.md §0): the rules every shipped file follows, checked on the source.

- no TODO / FIXME / TEMP / XXX markers (Lua, fxmanifest, web/src);
- no print( in client/ or shared/; server prints only on the startup / fatal paths and in the
  console dev tools listed in SERVER_PRINTS;
- no console.* in web/src;
- no Citizen.InvokeNative / N_0x outside client/natives/;
- no backtick hashes in Lua code;
- no hardcoded coordinates (vector3/vector4 literals, { x, y, z } world positions) or prices outside
  config/;
- every RegisterNUICallback name is sent by web/src and every nuiSend name is registered;
- every net event / callback a client uses has a server registration and vice versa, every event
  the server sends to clients has a client handler; the exceptions are external consumers or
  pre-v3 compatibility names, each listed with its reason in EXTERNAL.
"""
import re
import unittest

from harness import manifest_scripts
from lua_source import RESOURCE, code_only, lua_files, read, tokens

WEB_SRC = RESOURCE / 'web' / 'src'
WEB_EXT = ('.js', '.jsx', '.ts', '.tsx', '.css')

# Server print() calls that are allowed: (file, a snippet of the printed text, why)
SERVER_PRINTS = (
    ('server/bridge/framework.lua', 'Optional logging bootstrap failed', 'startup: the logging resource is optional'),
    ('server/bridge/framework.lua', 'no supported framework was detected', 'startup: fatal configuration error'),
    ('server/bridge/framework.lua', 'Framework detected', 'startup: the detected framework'),
    ('server/core/migrations.lua', 'database migration stopped', 'startup: fatal database error'),
    ('server/core/migrations.lua', 'database migrations applied', 'startup: the applied migrations'),
    ('server/appearance/repository.lua', 'wc_migrate_appearances', 'console command report (dev / admin tool)'),
)

# Event / callback names used on one side only, on purpose.
EXTERNAL = {
    # server -> other resources
    'w_creators:server:characterCreated': "consumed by w_lib's w_core bridge (framework-bridge/cores/w_core/server.lua)",
    # client -> other resources (local events)
    'w_creators:client:resurrected': 'fired for death systems (w_ambulancejob clears its downed state)',
    'hospital:client:Revive': "w_ambulancejob's revive, triggered by the spawn module for a downed player",
    'hud:client:showui': 'HUD resources (client/core/ui.lua SetCustomHudVisible)',
    'hud:client:Hideui': 'HUD resources (client/core/ui.lua SetCustomHudVisible)',
    'hud:client:showUiWithHoutStement': 'HUD resources (client/core/ui.lua SetPlayerHudVisible)',
    'hud:client:hideUiWithHoutStement': 'HUD resources (client/core/ui.lua SetPlayerHudVisible)',
    'vorp:showUi': 'vorp_core HUD (client/core/ui.lua)',
    'chat:clear': 'the chat resource (client/core/ui.lua)',
    # events other resources send to this one
    'w_lib:setLocale': 'raised by w_lib when the player changes the language',
    'w_logs:server:ready': 'raised by the optional logging resource',
    'W:CHARCREATION:starting': 'pre-v3 name other resources use to request the creator (server grant decides; ARCHITECTURE §13)',
    'PersonaCreatorHandler.applyCharacterAppearance': 'pre-v3 alias of w_creators:client:applyAppearance (ARCHITECTURE §13, §16.5)',
    'PersonaCreatorHandler.reloadCharacterAppearance': 'pre-v3 alias of w_creators:appearance:reload, rate-limited (§16.5)',
    'w_creators:server:isolate': 'pre-v3 name, mapped to the guarded scene:isolate (§16.2)',
    'PersonaCreatorHandler.setPlayerRoutingBucket': 'pre-v3 name, mapped to the guarded scene:isolate (§16.2)',
    'PersonaCreatorHandler.setRoutingBucket': 'pre-v3 name, mapped to the guarded scene:registerPed (§16.2)',
    'w_creators:server:rejoinWorld': 'pre-v3 name, mapped to the guarded scene:release (§16.2)',
    'w_creators:server:creationReady': 'pre-v3 name, same as characters:loaded (§16.1)',
}
# GlobalState keys (not events) that share the name shape.
STATE_KEYS = {'w_creators:hour', 'w_creators:today'}

EVENT_NAME = re.compile(r'^(?:[A-Za-z_][\w\-]*:[\w:\-]+|PersonaCreatorHandler\.\w+)$')


def web_files():
    return sorted(p for p in WEB_SRC.rglob('*') if p.suffix in WEB_EXT)


def web_code(text):
    """JS/CSS without comments (strings kept)."""
    text = re.sub(r'/\*.*?\*/', lambda m: re.sub(r'[^\n]', ' ', m.group(0)), text, flags=re.S)
    return re.sub(r'(^|[^:\'"\\])//[^\n]*', r'\1', text)


def lines_of(path, code):
    rel = path.relative_to(RESOURCE).as_posix()   # SERVER_PRINTS is written with '/'
    for i, line in enumerate(code.split('\n'), 1):
        yield rel, i, line


def call_before(blanked, start):
    """The function called with the literal at `start` as its first argument, '=NAME' for an
    assignment, or '' (e.g. a table value)."""
    before = blanked[max(0, start - 160):start].split('\n')[-1]
    m = re.search(r'([\w.:]+)\s*\(\s*(?:[\w.]+\s*,\s*)?$', before)
    if m:
        return m.group(1)
    m = re.search(r'([\w.\[\]]+)\s*=\s*$', before)
    return '=' + m.group(1) if m else ''


def event_uses():
    """{side: {name: [(call, file:line)]}} for every event-shaped literal of the manifest's Lua."""
    out = {'client': {}, 'server': {}, 'shared': {}}
    for side in out:
        for rel in manifest_scripts(side):
            src = read(RESOURCE / rel)
            blanked = code_only(src)
            for kind, value, line, start in tokens(src):
                if kind == 'string' and EVENT_NAME.match(value):
                    out[side].setdefault(value, []).append((call_before(blanked, start), '%s:%d' % (rel, line)))
    return out


def names(uses, *calls):
    return {n for n, lst in uses.items() if any(c in calls for c, _ in lst)}


class MarkerTests(unittest.TestCase):
    def test_no_work_markers(self):
        marker = re.compile(r'\b(TODO|FIXME|TEMP|XXX)\b')
        found = []
        paths = list(lua_files()) + [RESOURCE / 'fxmanifest.lua'] + web_files()
        for path in paths:
            for rel, i, line in lines_of(path, read(path)):
                if marker.search(line):
                    found.append('%s:%d' % (rel, i))
        self.assertEqual(found, [])


class OutputTests(unittest.TestCase):
    def test_no_print_on_client_or_shared(self):
        found = []
        for path in lua_files(('client', 'shared', 'config')):
            for rel, i, line in lines_of(path, code_only(read(path))):
                if re.search(r'(?<![\w.:])print\s*\(', line):
                    found.append('%s:%d' % (rel, i))
        self.assertEqual(found, [])

    def test_server_prints_are_startup_fatal_or_dev_tools(self):
        found = []
        for path in lua_files(('server',)):
            src = read(path)
            code = code_only(src)
            raw = src.split('\n')
            for rel, i, line in lines_of(path, code):
                if not re.search(r'(?<![\w.:])print\s*\(', line):
                    continue
                allowed = [s for f, s, _ in SERVER_PRINTS if f == rel and s in raw[i - 1]]
                if not allowed:
                    found.append('%s:%d %s' % (rel, i, raw[i - 1].strip()))
        self.assertEqual(found, [])

    def test_every_allowed_server_print_still_exists(self):
        for rel, snippet, _ in SERVER_PRINTS:
            self.assertIn(snippet, read(RESOURCE / rel), rel)

    def test_no_console_in_web_src(self):
        found = []
        for path in web_files():
            for rel, i, line in lines_of(path, web_code(read(path))):
                if re.search(r'\bconsole\s*\.\s*\w+\s*\(', line):
                    found.append('%s:%d' % (rel, i))
        self.assertEqual(found, [])


class NativeTests(unittest.TestCase):
    def test_raw_invokes_only_in_client_natives(self):
        found = []
        for path in lua_files():
            if path.relative_to(RESOURCE).as_posix().startswith('client/natives/'):
                continue
            for rel, i, line in lines_of(path, code_only(read(path))):
                if re.search(r'\bInvokeNative\b|\bN_0x[0-9a-fA-F]+', line):
                    found.append('%s:%d' % (rel, i))
        self.assertEqual(found, [])

    def test_no_backtick_hashes(self):
        found = []
        for path in lua_files():
            for rel, i, line in lines_of(path, code_only(read(path))):
                if '`' in line:
                    found.append('%s:%d' % (rel, i))
        self.assertEqual(found, [])


class HardcodedValueTests(unittest.TestCase):
    COORD_TABLE = re.compile(r'\{\s*-?\d{2,5}\.\d+\s*,\s*-?\d{2,5}\.\d+\s*,\s*-?\d{1,4}\.\d+')
    COORD_VALUES = re.compile(r'-?\d{3,5}\.\d+\s*,\s*-?\d{3,5}\.\d+\s*,\s*-?\d{1,4}\.\d+')
    VECTOR = re.compile(r'\bvector[34]\s*\(\s*-?\d')
    PRICE = re.compile(r'(?i)\b\w*(price|cost|fee)\w*\s*(=|or)\s*[1-9]\d*(\.\d+)?\b')

    def test_no_coordinates_outside_config(self):
        found = []
        for path in lua_files(('shared', 'client', 'server')):
            for rel, i, line in lines_of(path, code_only(read(path))):
                if self.VECTOR.search(line) or self.COORD_TABLE.search(line) or self.COORD_VALUES.search(line):
                    found.append('%s:%d %s' % (rel, i, line.strip()))
        self.assertEqual(found, [])

    def test_no_prices_outside_config(self):
        found = []
        for path in lua_files(('shared', 'client', 'server')):
            for rel, i, line in lines_of(path, code_only(read(path))):
                if self.PRICE.search(line):
                    found.append('%s:%d %s' % (rel, i, line.strip()))
        self.assertEqual(found, [])

    def test_the_checks_see_a_coordinate_and_a_price(self):
        self.assertTrue(self.VECTOR.search('local p = vector3(-274.09, 785.36, 119.29)'))
        self.assertTrue(self.COORD_TABLE.search('start = { 2520.09, -358.05, 41.61, 268.8 }'))
        self.assertTrue(self.COORD_VALUES.search('x, y, z = -274.09, 785.36, 119.29'))
        self.assertTrue(self.PRICE.search('local hatPrice = 12'))
        self.assertFalse(self.PRICE.search('local cost = 0'))


class ManifestTests(unittest.TestCase):
    def test_every_lua_file_is_loaded_and_no_legacy_file_is_left(self):
        listed = set()
        for side in ('shared', 'client', 'server'):
            listed |= set(manifest_scripts(side))
        # pathlib renders Windows separators, the manifest writes '/': compare like with like, or the
        # whole tree reads as "not loaded" on a Windows dev box
        on_disk = {str(p.relative_to(RESOURCE)).replace('\\', '/') for p in lua_files()}
        on_disk |= {p.name for p in RESOURCE.glob('*.lua')} - {'fxmanifest.lua'}
        self.assertEqual(sorted(on_disk - listed), [], 'Lua files the manifest does not load')
        for legacy in ('config.lua', 'data', 'bridge', 'modules', 'creator', 'multichar', 'spawnselect',
                       'store', 'sql/characters_appearence.sql'):
            self.assertFalse((RESOURCE / legacy).exists(), legacy)
        self.assertTrue((RESOURCE / 'sql' / 'install.sql').exists())

    def test_no_stub_files(self):
        found = [str(p.relative_to(RESOURCE)) for p in lua_files()
                 if 'implemented in a later phase' in read(p)]
        self.assertEqual(found, [])


class NuiCallbackTests(unittest.TestCase):
    def test_registered_callbacks_match_the_nui(self):
        registered = set()
        for path in lua_files(('client',)):
            src = code_only(read(path), keep_strings=True)
            registered |= set(re.findall(r"""RegisterNUICallback\(\s*['"]([^'"]+)['"]""", src))
        sent = set()
        for path in web_files():
            code = web_code(read(path))
            sent |= set(re.findall(r"""nuiSend\(\s*['"`]([^'"`]+)['"`]""", code))
            sent |= set(re.findall(r"""\bsend\(\s*['"`]([\w:]+)['"`]""", code))
        self.assertTrue(registered)
        self.assertEqual(sorted(registered - sent), [], 'registered but never sent by web/src')
        self.assertEqual(sorted(sent - registered), [], 'sent by web/src but not registered')


class EventCatalogueTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.uses = event_uses()

    def client_handled(self):
        return names(self.uses['client'], 'RegisterNetEvent', 'AddEventHandler')

    def server_handled(self):
        return names(self.uses['server'], 'RegisterNetEvent', 'AddEventHandler')

    def test_client_sent_events_have_a_server_handler(self):
        sent = names(self.uses['client'], 'TriggerServerEvent')
        self.assertEqual(sorted(sent - self.server_handled() - set(EXTERNAL)), [])

    def test_client_callbacks_are_registered_on_the_server(self):
        registered = names(self.uses['server'], 'w.callback.register')
        used = set()
        for name, lst in self.uses['client'].items():
            if not name.startswith('w_creators:') or name in STATE_KEYS:
                continue
            domain = name.split(':')[1]
            if domain in ('client', 'server'):
                continue
            used.add(name)
        self.assertEqual(sorted(used - registered), [], 'callbacks the client calls that no server file registers')
        self.assertEqual(sorted(registered - used), [], 'server callbacks no client uses')

    def test_server_net_events_have_a_client_sender(self):
        client_literals = set(self.uses['client'])
        handled = {n for n, lst in self.uses['server'].items() if any(c == 'RegisterNetEvent' for c, _ in lst)}
        orphans = sorted(n for n in handled if n not in client_literals and n not in EXTERNAL)
        self.assertEqual(orphans, [])

    def test_server_to_client_events_have_a_client_handler(self):
        sent = names(self.uses['server'], 'TriggerClientEvent')
        # server/api.lua keeps the open events in a table (OPEN_EVENTS)
        sent |= {n for n, lst in self.uses['server'].items() if n.startswith('w_creators:client:')}
        missing = sorted(n for n in sent if n not in self.client_handled() and n not in EXTERNAL)
        self.assertEqual(missing, [])

    def test_client_handlers_have_a_sender(self):
        senders = set(self.uses['server']) | names(self.uses['client'], 'TriggerEvent')
        orphans = sorted(n for n in self.client_handled() if n not in senders and n not in EXTERNAL
                         and n not in ('playerSpawned',))
        self.assertEqual(orphans, [])

    def test_local_events_have_a_handler_or_an_external_consumer(self):
        fired = names(self.uses['client'], 'TriggerEvent')
        missing = sorted(n for n in fired if n not in self.client_handled() and n not in EXTERNAL)
        self.assertEqual(missing, [])
        fired = names(self.uses['server'], 'TriggerEvent')
        missing = sorted(n for n in fired if n not in self.server_handled() and n not in EXTERNAL)
        self.assertEqual(missing, [])

    def test_every_external_entry_is_still_used(self):
        every = set(self.uses['client']) | set(self.uses['server'])
        self.assertEqual(sorted(n for n in EXTERNAL if n not in every), [])


if __name__ == '__main__':
    unittest.main()
