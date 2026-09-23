"""Character selection must reach spawning when the optional logger is unavailable.

Run: python -m unittest discover -s tests -p 'test_*.py'
Requires lupa (Lua 5.4). These tests run the actual server Lua files with Cfx,
framework and database boundaries mocked; no live database/server is touched.
"""

from pathlib import Path
import unittest

from lupa.lua54 import LuaRuntime


RESOURCE = Path(__file__).resolve().parents[1]

STUBS = r"""
handlers, clientEvents, bucketChanges, loginCalls = {}, {}, {}, {}
dbCallbacks, dbRequests, logCalls, registrations = {}, {}, {}, {}
resourceStates, resourceFiles, resourceReadCounts, timers = {}, {}, {}, {}
buckets = { [7] = 7 }
source = 7
Config = {
    Framework = 'test',
    Services = { spawnSelector = true, lastLocation = true, characterDeletion = true, characterCreation = true },
    Characters = { defaultSlots = 3, setSurvivalMetadata = false, deletion = { enabled = true },
                   tables = { vorp = 'characters', rsg = 'players', qbr = 'players' } },
    Creator = { spawnEvent = nil },
    Spawn = {
        firstSpawn = { coords = { x = 1, y = 2, z = 3 }, heading = 4 },
        selector = { enabled = true },
        lastLocation = { enabled = true },
        points = { { id = 'valentine', enabled = true, order = 1, coords = { x = 10, y = 20, z = 30 }, heading = 40 } },
    },
    -- keys still read by the pre-v3 multichar/server.lua and server/server.lua loaded below
    Multicharacter = true, EnableDelete = true, CharacterSlots = 3,
}
function AddEventHandler(name, fn)
    handlers[name] = handlers[name] or {}
    table.insert(handlers[name], fn)
end
function RegisterNetEvent(name, fn)
    if fn then AddEventHandler(name, fn) end
end
function fire(name, ...)
    for _, fn in ipairs(handlers[name] or {}) do fn(...) end
end
TriggerEvent = fire
function TriggerClientEvent(name, player, ...)
    table.insert(clientEvents, { name = name, player = player, args = {...} })
end
threads={}
function CreateThread(fn)
 local co=coroutine.create(fn);threads[#threads+1]=co
 local ok,err=coroutine.resume(co);assert(ok,err)
end
function Wait() if coroutine.isyieldable() then coroutine.yield() end end
function SetTimeout(delay, fn) table.insert(timers, fn) end
function GetResourceState(name) return resourceStates[name] or 'missing' end
function GetCurrentResourceName() return 'w_creators' end
function IsDuplicityVersion() return true end
function LoadResourceFile(resource, path)
    local key = resource .. '/' .. path
    resourceReadCounts[key] = (resourceReadCounts[key] or 0) + 1
    return resourceFiles[key]
end
function SetPlayerRoutingBucket(player, bucket)
    buckets[player] = bucket
    table.insert(bucketChanges, { player = player, bucket = bucket })
end
function GetPlayerRoutingBucket(player) return buckets[player] or 0 end
function GetPlayerName(player) return player == 7 and 'test player' or nil end
function RegisterCommand() end
function print() end
exports = setmetatable({w_lib={CompatStatus=function() return {} end,FwName=function() return 'test' end}}, { __call = function() end })
lib = { callback = { register = function() end }, notify = function() end }
json = {
    decode = function(raw)
        assert(raw == '[]' or raw == '{}', 'Unexpected JSON fixture')
        return {}
    end,
    encode = function() return '{}' end,
}
fixtureDB = {
    query = { await = function() return {} end },
    Async = {
        fetchAll = function(query, params, callback)
            table.insert(dbRequests, { query = query, params = params })
            table.insert(dbCallbacks, callback)
        end,
    },
}
w={callback={register=function() end},print={error=function() end},framework={},logs={}}
w.database={ready=function() end,query=setmetatable({await=fixtureDB.query.await},{__call=function(_,sql,params,cb) return fixtureDB.Async.fetchAll(sql,params,cb) end})}
function w.logs.IsReady() return resourceStates.w_logs_v2=='started' and not badLoader end
function w.logs.Emit(event,payload)
 if throwEmit then error('logger transport unavailable') end
 if not w.logs.IsReady() then return false end
 table.insert(logCalls,{event=event,payload=payload});return true
end
function w.logs.RegisterScript(data) table.insert(registrations,{kind='script',data=data});return {ok=true} end
function w.logs.RegisterLogType(data) table.insert(registrations,{kind='type',data=data});return {ok=true} end
appearanceRows = { { isMale = true, faceFeatures = '[]', overlays = '[]', components = '{}' } }
function completeAppearanceQuery()
    assert(#dbCallbacks == 1, 'Expected one pending appearance query')
    table.remove(dbCallbacks, 1)(appearanceRows)
end
"""

LOGGER_SOURCE = r"""
loggerLoadCount = (loggerLoadCount or 0) + 1
SentinelBridge = {
    Emit = function(event, payload)
        if throwEmit then error('logger transport unavailable') end
        table.insert(logCalls, { event = event, payload = payload })
        return true
    end,
    RegisterScript = function(data)
        table.insert(registrations, { kind = 'script', data = data })
    end,
    RegisterLogType = function(data)
        table.insert(registrations, { kind = 'type', data = data })
    end,
}
"""


class CreatorHarness:
    def __init__(self, logger=False, throw_emit=False, bad_loader=False,
                 legacy_manifest=False, missing_adapter=False):
        self.lua = LuaRuntime(unpack_returned_tuples=True)
        self.lua.execute(STUBS)
        self.g = self.lua.globals()
        self.g.throwEmit = throw_emit
        self.g.badLoader = bad_loader
        if not missing_adapter:
            self.g.resourceFiles['w_creators/server/bridge/logging.lua'] = (
                RESOURCE / 'server/bridge/logging.lua'
            ).read_text(encoding='utf-8-sig')
        if logger or bad_loader:
            self.g.resourceStates['w_logs_v2'] = 'started'
            self.g.resourceFiles['w_logs_v2/bridge.lua'] = (
                "error('optional bridge failed to initialize')" if bad_loader else LOGGER_SOURCE
            )
        for filename in (
            'shared/util.lua', 'shared/result.lua', 'shared/debug.lua', 'shared/services.lua',
            'server/bridge/logging.lua', 'server/bridge/framework.lua',
            'server/scene.lua', 'server/server.lua', 'multichar/server.lua',
            'server/spawn/spawn.lua',
        ):
            if (legacy_manifest or missing_adapter) and filename == 'server/bridge/logging.lua':
                continue
            if filename == 'server/spawn/spawn.lua':
                # The spawn service replaces the pre-v3 spawnAt handler of server/server.lua
                # (that file is no longer in the manifest; it is loaded here for the selection flow).
                self.g.handlers['w_creators:server:spawnAt'] = None
            self.lua.execute((RESOURCE / filename).read_text(encoding='utf-8-sig'), name=filename)
        self.g.fire('w_creators:server:logsReady')
        self.lua.execute("""
            Bridge.GetCharacters = function(player)
                assert(player == 7)
                return { { charid = 'vorp:42' } }
            end
            Bridge.LoginCharacter = function(player, charid)
                table.insert(loginCalls, { player = player, charid = charid })
            end
            Bridge.GetLastPosition = function(player)
                return { x = 100, y = 200, z = 300, heading = 400 }
            end
        """)

    def fire(self, name, *args):
        self.g.fire(name, *args)

    def select(self, appearance=True):
        if not appearance:
            self.g.appearanceRows = self.lua.table()
        self.fire('w_creators:server:selectCharacter', 'vorp:42')
        self.g.completeAppearanceQuery()

    def events(self, name):
        return [event for _, event in self.g.clientEvents.items() if event.name == name]

    def logs(self, name):
        return [event for _, event in self.g.logCalls.items() if event.event == name]


class OptionalLoggingTests(unittest.TestCase):
    def assert_selector_reached(self, harness):
        events = harness.events('w_creators:client:selectSpawn')
        self.assertEqual(len(events), 1)
        self.assertEqual(events[0].player, 7)
        self.assertEqual(events[0].args[1]['last'].x, 100)
        self.assertTrue(harness.g.SpawnPending[7])
        self.assertEqual(harness.g.buckets[7], 7, 'Keep isolation until a spawn is chosen')
        self.assertEqual(len(harness.events('w_creators:client:spawn')), 0)

    def test_missing_logger_selection_completes_after_appearance_callback(self):
        h = CreatorHarness()
        h.fire('w_creators:server:selectCharacter', 'vorp:42')
        self.assertIsNone(h.g.SpawnPending[7])
        self.assertEqual(len(h.events('w_creators:client:selectSpawn')), 0)
        self.assertEqual(len(h.g.loginCalls), 1)
        self.assertEqual(h.g.dbRequests[1].params['@charid'], 'vorp:42')

        h.g.completeAppearanceQuery()
        self.assert_selector_reached(h)
        self.assertEqual(len(h.events('PersonaCreatorHandler.applyCharacterAppearance')), 1)
        self.assertEqual(len(h.events('w_creators:client:applyRemoteAppearance')), 1)
        names = [event.name for _, event in h.g.clientEvents.items()]
        self.assertLess(names.index('PersonaCreatorHandler.applyCharacterAppearance'),
                        names.index('w_creators:client:selectSpawn'))

    def test_cached_legacy_manifest_bootstraps_adapter_before_character_selection(self):
        h = CreatorHarness(legacy_manifest=True)
        h.fire('w_creators:server:isolate')
        h.select()
        self.assert_selector_reached(h)
        self.assertEqual(h.g.resourceReadCounts['w_creators/server/bridge/logging.lua'], 1)
        self.assertEqual(len(h.g.handlers['w_creators:server:logsReady']), 1)

    def test_incomplete_update_without_adapter_still_allows_character_selection(self):
        h = CreatorHarness(missing_adapter=True)
        h.fire('w_creators:server:isolate')
        h.select()
        self.assert_selector_reached(h)
        self.assertEqual(h.g.resourceReadCounts['w_creators/server/bridge/logging.lua'], 1)
        h.fire('w_creators:server:spawnAt', 'valentine')
        self.assertIsNone(h.g.SpawnPending[7])
        self.assertEqual(h.g.buckets[7], 0)
        self.assertEqual(len(h.events('w_creators:client:spawn')), 1)

    def test_normal_manifest_does_not_load_adapter_or_register_handlers_twice(self):
        h = CreatorHarness(logger=True)
        self.assertIsNone(h.g.resourceReadCounts['w_creators/server/bridge/logging.lua'])
        self.assertEqual(len(h.g.handlers['w_creators:server:logsReady']), 1)
        initial_registrations = len(h.g.registrations)
        h.fire('w_creators:server:logsReady')
        self.assertEqual(len(h.g.registrations), initial_registrations)
        self.assertEqual(sum(row.kind == 'script' for _, row in h.g.registrations.items()), 1)
        h.select()
        self.assert_selector_reached(h)
        self.assertEqual(len(h.logs('character_selected')), 1)

    def test_no_saved_appearance_opens_repair_creator(self):
        h = CreatorHarness()
        h.select(appearance=False)
        self.assertEqual(len(h.events('W:CHARCREATION:starting')), 1)
        self.assertEqual(len(h.events('w_creators:client:selectSpawn')), 0)
        self.assertEqual(len(h.events('PersonaCreatorHandler.applyCharacterAppearance')), 0)

    def test_missing_logger_does_not_interrupt_isolation_or_rejoin(self):
        h = CreatorHarness()
        h.fire('w_creators:server:isolate')
        self.assertEqual(h.g.buckets[7], 7)
        h.fire('w_creators:server:rejoinWorld')
        self.assertEqual(h.g.buckets[7], 0)
        self.assertEqual(len(h.g.bucketChanges), 2)

    def test_foreign_character_is_rejected_even_without_logger(self):
        h = CreatorHarness()
        h.fire('w_creators:server:selectCharacter', 'vorp:99')
        self.assertEqual(len(h.g.loginCalls), 0)
        self.assertEqual(len(h.g.dbRequests), 0)
        self.assertEqual(len(h.g.clientEvents), 0)
        self.assertIsNone(h.g.SpawnPending[7])

    def test_spawn_permission_is_consumed_and_replay_still_rejected(self):
        h = CreatorHarness()
        h.select()
        h.fire('w_creators:server:spawnAt', 'valentine')
        self.assertIsNone(h.g.SpawnPending[7])
        self.assertEqual(h.g.buckets[7], 0)
        spawn = h.events('w_creators:client:spawn')
        self.assertEqual(len(spawn), 1)
        self.assertEqual(spawn[0].args[1].x, 10)
        h.fire('w_creators:server:spawnAt', 'valentine')
        self.assertEqual(len(h.events('w_creators:client:spawn')), 1)
        self.assertEqual(len(h.g.bucketChanges), 1)

    def test_throwing_logger_does_not_block_spawn_selector(self):
        h = CreatorHarness(logger=True, throw_emit=True)
        h.select()
        self.assert_selector_reached(h)

    def test_available_logger_preserves_selection_event_and_registration(self):
        h = CreatorHarness(logger=True)
        h.select()
        self.assert_selector_reached(h)
        logs = h.logs('character_selected')
        self.assertEqual(len(logs), 1)
        self.assertEqual(logs[0].payload.charid, 'vorp:42')
        self.assertTrue(logs[0].payload.appearanceFound)
        self.assertTrue(any(row.kind == 'script' for _, row in h.g.registrations.items()))

    def test_failed_optional_bridge_load_does_not_block_character_selection(self):
        h = CreatorHarness(bad_loader=True)
        h.select()
        self.assert_selector_reached(h)

    def test_logger_started_later_is_loaded_without_restarting_creator(self):
        h = CreatorHarness()
        h.g.resourceStates['w_logs_v2'] = 'started'
        h.g.resourceFiles['w_logs_v2/bridge.lua'] = LOGGER_SOURCE
        h.fire('w_creators:server:logsReady')
        h.select()
        self.assert_selector_reached(h)
        self.assertEqual(len(h.logs('character_selected')), 1)
        self.assertTrue(any(row.kind == 'script' for _, row in h.g.registrations.items()))


if __name__ == '__main__':
    unittest.main()
