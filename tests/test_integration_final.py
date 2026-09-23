"""Final integration: the cross-module requests applied after wave B.

- the client has no os library: dates come from WCUtil.today (os on the server, the date the server
  publishes in GlobalState on the client); identity / editor / opening hours work without os;
- the server publishes its clock (WCSessions.publishClock);
- w_creators:dev:allowed (server/dev/tools.lua) gates the client dev commands;
- the 'service' lock is a documented client lock.
"""
import unittest

from harness import Runtime
from test_server_services_devtools import dev_server


def shared_without_os():
    rt = Runtime().load_shared()
    rt.run('SavedOs = os; os = nil; GlobalState = {}')
    return rt


class ClientDateTests(unittest.TestCase):
    def test_today_is_nil_without_os_and_without_a_published_date(self):
        rt = shared_without_os()
        self.assertIsNone(rt.eval('WCUtil.today()'))
        self.assertEqual(rt.eval('WCLocations.hour()'), 0)

    def test_today_reads_the_published_date_without_os(self):
        rt = shared_without_os()
        rt.run('GlobalState[WCUtil.TODAY_KEY] = { year = 1900, month = 6, day = 15, hour = 21 }')
        self.assertEqual(rt.eval('WCUtil.today().year'), 1900)
        self.assertEqual(rt.eval('WCLocations.hour()'), 21)

    def test_a_malformed_published_date_is_ignored(self):
        rt = shared_without_os()
        rt.run('GlobalState[WCUtil.TODAY_KEY] = { year = "x", month = 6, day = 15 }')
        self.assertIsNone(rt.eval('WCUtil.today()'))

    def test_today_uses_os_when_present(self):
        rt = Runtime().load_shared()
        self.assertEqual(rt.eval('WCUtil.today().year'), rt.eval('os.date("*t").year'))

    def test_dob_without_os_leaves_the_age_window_to_the_server(self):
        rt = shared_without_os()
        rt.run('ok, dob, age = WCIdentity.validateDob("1890-02-03")')
        self.assertTrue(rt.eval('ok'))
        self.assertEqual(rt.eval('dob'), '1890-02-03')
        self.assertIsNone(rt.eval('age'))
        # still a real date
        self.assertFalse(rt.eval('(WCIdentity.validateDob("1890-02-30"))'))

    def test_dob_without_os_uses_the_published_date(self):
        rt = shared_without_os()
        rt.run('GlobalState[WCUtil.TODAY_KEY] = { year = 1900, month = 1, day = 1 }')
        rt.run('ok, code = WCIdentity.validateDob("1890-02-03")')
        self.assertFalse(rt.eval('ok'))
        self.assertEqual(rt.eval('code'), 'INVALID_DOB')
        rt.run('ok, dob, age = WCIdentity.validateDob("1870-02-03")')
        self.assertTrue(rt.eval('ok'))
        self.assertEqual(rt.eval('age'), 29)


class ServerClockTests(unittest.TestCase):
    def test_the_server_publishes_its_hour_and_date(self):
        rt = Runtime().load_server_core()
        rt.run('GlobalState = {}')
        self.assertTrue(rt.eval('WCSessions.publishClock()'))
        now = rt.py(rt.eval('os.date("*t")'))
        self.assertEqual(rt.eval('GlobalState["w_creators:hour"]'), now['hour'])
        self.assertEqual(rt.eval('GlobalState[WCUtil.TODAY_KEY].year'), now['year'])
        # the client service prompts read the same key
        self.assertEqual(rt.eval('WCSessions.HOUR_KEY'), 'w_creators:hour')

    def test_publishing_without_global_state_does_not_throw(self):
        rt = Runtime().load_server_core()
        rt.run('GlobalState = nil')
        self.assertFalse(rt.eval('WCSessions.publishClock()'))


class DevAllowedTests(unittest.TestCase):
    def ask(self, rt, src, command):
        return rt.eval('Callbacks["w_creators:dev:allowed"](%d, %s)' % (src, command))

    def test_registered_and_disabled_in_production(self):
        rt = dev_server()
        r = self.ask(rt, 1, '"wc_inspect"')
        self.assertFalse(r.ok)
        self.assertEqual(r.code, 'SERVICE_DISABLED')

    def test_refused_without_the_ace(self):
        rt = dev_server(dev_tools=True)
        r = self.ask(rt, 1, '"wc_inspect"')
        self.assertFalse(r.ok)
        self.assertEqual(r.message, rt.eval('WCDevTools.DENIED'))

    def test_allowed_with_the_ace(self):
        rt = dev_server(dev_tools=True)
        rt.run('IsPlayerAceAllowed = function(_, ace) return ace == Config.Admin.devAce end')
        for command in ('wc_inspect', 'wc_apply', 'wc_remove', 'wc_restore'):
            self.assertTrue(self.ask(rt, 1, '"%s"' % command).ok, command)

    def test_unknown_commands_are_refused(self):
        rt = dev_server(dev_tools=True)
        rt.run('IsPlayerAceAllowed = function() return true end')
        for command in ('"wc_catalog_validate"', 'nil', '42', '"spawnprop"'):
            r = self.ask(rt, 1, command)
            self.assertFalse(r.ok, command)
            self.assertEqual(r.code, 'INVALID_PAYLOAD')

    def test_rate_limited(self):
        rt = dev_server(dev_tools=True)
        rt.run('IsPlayerAceAllowed = function() return true end')
        codes = [self.ask(rt, 7, '"wc_inspect"').code for _ in range(12)]
        self.assertIn('RATE_LIMITED', codes)


class ClientLockTests(unittest.TestCase):
    def test_service_is_a_documented_lock(self):
        rt = Runtime().load_shared()
        rt.load('client/core/state.lua')
        self.assertTrue(rt.eval('WCState.LOCKS.service'))


if __name__ == '__main__':
    unittest.main()
