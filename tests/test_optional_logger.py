"""The optional logger never blocks selection, spawn or isolation (v3 port of the pre-v3
test_optional_logging.py, which drove the deleted multichar/server.lua and server/server.lua).

Scenario map (pre-v3 test -> here):
  missing logger, selection completes          -> test_missing_logger_selection_reaches_the_spawn_selector
  spawn permission consumed, replay rejected   -> test_missing_logger_spawn_grant_is_one_shot
  missing logger, isolation / rejoin           -> test_missing_logger_does_not_interrupt_isolation_or_release
  foreign character rejected without logger    -> test_foreign_character_is_rejected_without_logger
  no saved appearance -> repair creator        -> test_no_saved_appearance_takes_the_repair_path_without_logger
  throwing logger does not block the selector  -> test_throwing_transport_does_not_block_selection_or_spawn
  failed optional bridge load                  -> test_throwing_readiness_probe_does_not_block_selection
  available logger keeps the selection log     -> test_available_logger_records_the_selection
  normal manifest registers once               -> test_log_types_register_once
  logger started later                         -> test_logger_started_later_is_picked_up
The two "legacy manifest / missing adapter" scenarios bootstrapped the adapter from disk at run time;
v3 always lists server/bridge/logging.lua in the manifest, so they have no v3 equivalent.
"""
import os
import sys
import unittest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from test_server_characters_flow import server_runtime  # noqa: E402

# The flow SETUP replaces CreatorLogs.Emit with a recorder; reload the real adapter so the
# w.logs boundary is what the tests exercise.
REAL_ADAPTER = r'''
LogEmits = {}
'''


class Base(unittest.TestCase):
    logger = 'missing'   # 'missing' | 'throwing' | 'probe_throws' | 'ready' | 'late'

    def setUp(self):
        rt = server_runtime()
        rt.load('server/bridge/logging.lua')
        rt.run(REAL_ADAPTER)
        if self.logger == 'missing':
            rt.run('w.logs = nil')
        elif self.logger == 'throwing':
            rt.run(r'''
                w.logs.IsReady = function() return true end
                w.logs.Emit = function() error('logger transport unavailable') end
            ''')
        elif self.logger == 'probe_throws':
            rt.run("w.logs.IsReady = function() error('optional bridge failed to initialize') end")
        elif self.logger == 'ready':
            rt.run('w.logs.IsReady = function() return true end; fireEvent("w_creators:server:logsReady")')
        self.rt = rt
        self.e = rt.eval
        self.cb = rt.eval('cb')

    def call(self, name, src, *args):
        return self.cb(name, src, *args)

    def names(self):
        return [e.name for _, e in self.rt.g.Events.client.items()]

    def select_to_selector(self, src=1, charid='vorp:1'):
        self.assertTrue(self.call('scene:prepare', src).ok)
        r = self.call('characters:select', src, charid)
        self.assertTrue(r.ok, r.code)
        self.assertIsNotNone(r.data.appearance)
        loaded = self.call('characters:loaded', src)
        self.assertTrue(loaded.ok, loaded.code)
        self.assertEqual(loaded.data.spawn, 'selector')
        sel = self.rt.client_events('w_creators:client:selectSpawn')
        self.assertEqual(len(sel), 1)
        self.assertEqual(sel[0].player, src)
        self.assertTrue(self.e('SpawnPending[%d]' % src))
        self.assertEqual(self.e('Players[%d].bucket' % src), src, 'isolation kept until a spawn is chosen')
        self.assertEqual(len(self.rt.client_events('w_creators:client:spawn')), 0)
        names = self.names()
        self.assertLess(names.index('w_creators:client:applyRemoteAppearance'),
                        names.index('w_creators:client:selectSpawn'))
        return r


class MissingLoggerTests(Base):
    logger = 'missing'

    def test_emit_and_register_are_safe_without_the_module(self):
        self.assertFalse(self.e('CreatorLogs.Emit("character_selected", {})'))
        self.assertFalse(self.e('CreatorLogs.Register(function() end)'))

    def test_missing_logger_selection_reaches_the_spawn_selector(self):
        self.select_to_selector()
        self.assertEqual(self.e('#loginCalls'), 1)

    def test_missing_logger_spawn_grant_is_one_shot(self):
        self.select_to_selector()
        r = self.call('spawn:choose', 1, 'valentine')
        self.assertTrue(r.ok, r.code)
        self.assertIsNone(self.e('SpawnPending[1]'))
        self.assertEqual(self.e('Players[1].bucket'), 0)
        self.assertEqual(len(self.rt.client_events('w_creators:client:spawn')), 1)
        self.rt.run('Clock.now = Clock.now + 11000')
        self.assertEqual(self.call('spawn:choose', 1, 'valentine').code, 'SPAWN_NOT_PENDING')
        self.assertEqual(len(self.rt.client_events('w_creators:client:spawn')), 1)

    def test_missing_logger_does_not_interrupt_isolation_or_release(self):
        self.assertTrue(self.call('scene:prepare', 1).ok)
        self.assertEqual(self.e('Players[1].bucket'), 1)
        self.assertTrue(self.call('scene:release', 1).data.released)
        self.assertEqual(self.e('Players[1].bucket'), 0)

    def test_foreign_character_is_rejected_without_logger(self):
        r = self.call('characters:select', 1, 'vorp:9')
        self.assertEqual(r.code, 'NOT_CHARACTER_OWNER')
        self.assertEqual(self.e('#loginCalls'), 0)
        self.assertEqual(self.names(), [])
        self.assertIsNone(self.e('SpawnPending[1]'))

    def test_no_saved_appearance_takes_the_repair_path_without_logger(self):
        r = self.call('characters:select', 1, 'vorp:2')
        self.assertTrue(r.ok, r.code)
        self.assertTrue(r.data.needsAppearance)
        self.assertEqual(len(self.rt.client_events('w_creators:client:selectSpawn')), 0)


class ThrowingLoggerTests(Base):
    logger = 'throwing'

    def test_throwing_transport_does_not_block_selection_or_spawn(self):
        self.select_to_selector()
        self.assertTrue(self.call('spawn:choose', 1, 'valentine').ok)
        self.assertEqual(self.e('Players[1].bucket'), 0)


class ThrowingProbeTests(Base):
    logger = 'probe_throws'

    def test_throwing_readiness_probe_does_not_block_selection(self):
        self.rt.run('fireEvent("w_creators:server:logsReady")')
        self.select_to_selector()
        self.assertEqual(self.e('#LogTypes'), 0)


class ReadyLoggerTests(Base):
    logger = 'ready'

    def test_available_logger_records_the_selection(self):
        self.select_to_selector()
        selected = [e for _, e in self.rt.g.LogEmits.items() if e.event == 'character_selected']
        self.assertEqual(len(selected), 1)
        self.assertEqual(selected[0].payload.charid, 'vorp:1')
        self.assertTrue(selected[0].payload.appearanceFound)

    def test_log_types_register_once(self):
        count = self.e('#LogTypes')
        self.assertGreater(count, 0)
        self.rt.run('fireEvent("w_creators:server:logsReady")')
        self.assertEqual(self.e('#LogTypes'), count)


class LateLoggerTests(Base):
    logger = 'late'

    def test_logger_started_later_is_picked_up(self):
        self.assertEqual(self.e('#LogTypes'), 0)
        self.rt.run('w.logs.IsReady = function() return true end; tick(1500)')
        self.assertGreater(self.e('#LogTypes'), 0, 'the readiness watcher fires logsReady')
        self.select_to_selector()
        self.assertEqual(len([e for _, e in self.rt.g.LogEmits.items() if e.event == 'character_selected']), 1)


if __name__ == '__main__':
    unittest.main()
