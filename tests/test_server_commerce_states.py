"""Server commerce: runtime clothing states (w_creators:clothing:setState, WCClothingActions)."""
import unittest

from test_server_commerce_store import commerce

STATES_SETUP = r'''
Players[1].coords = vector3(0, 0, 0)
base = S.default('male')
base.clothing.equipped.hats = h('male', 'hats', 1)
base.clothing.equipped.neckwear = h('male', 'neckwear', 1)
setSaved('vorp:1', base)
function setState(group, value, src)
    if not keepRate then WCSecurity.clear(src or 1) end
    return call('w_creators:clothing:setState', src or 1, group, value)
end
'''


class ClothingStateTests(unittest.TestCase):
    def setUp(self):
        self.rt = commerce()
        self.rt.run(STATES_SETUP)
        self.e = self.rt.eval

    def test_persisting_state(self):
        self.rt.run('tx = countTx(); res = setState("hat", "off")')
        self.assertTrue(self.e('res.ok'), self.e('res.code'))
        self.assertEqual(self.e('res.data.states.hat'), 'off')
        self.assertEqual(self.e('countTx()'), self.e('tx') + 1)
        self.assertEqual(self.e('saved().clothing.states.hat'), 'off')
        self.assertEqual(self.e('json.decode(rows["vorp:1"].appearance).clothing.states.hat'), 'off')
        # the equipped item is never removed
        self.assertEqual(self.e('saved().clothing.equipped.hats'), self.e('h("male", "hats", 1)'))
        events = self.rt.client_events('w_creators:client:remoteClothingState')
        self.assertEqual(len(events), 1)
        self.assertEqual((events[0].args[1], events[0].args[2], events[0].args[3]), (1, 'hat', 'off'))
        self.assertEqual(self.e('changedEvents[1].kind'), 'clothingState')
        # the same value again: no write
        self.rt.run('tx = countTx(); res = setState("hat", "off")')
        self.assertTrue(self.e('res.ok'))
        self.assertEqual(self.e('countTx()'), self.e('tx'))

    def test_runtime_state_is_not_persisted(self):
        self.rt.run('tx = countTx(); res = setState("bandana", "up")')
        self.assertTrue(self.e('res.ok'), self.e('res.code'))
        self.assertEqual(self.e('countTx()'), self.e('tx'))
        self.assertEqual(self.e('res.data.states.bandana'), 'up')
        self.assertIsNone(self.e('saved().clothing.states.bandana'))
        self.rt.run('res = setState("hat", "off")')
        self.assertEqual(self.rt.py(self.e('res.data.states')), {'hat': 'off', 'bandana': 'up'})
        # a new appearance (store / wardrobe) resets the runtime states
        self.rt.run('TriggerEvent("w_creators:server:appearanceChanged", 1, "vorp:1", "wardrobe"); res = setState("hat", "on")')
        self.assertEqual(self.rt.py(self.e('res.data.states')), {'hat': 'on'})

    def test_invalid_group_or_value(self):
        for args in ('"nope", "on"', '"hat", "sideways"', '"hat", nil', 'nil, "on"', '{}, "on"', '"hat", 1',
                     'string.rep("h", 100), "on"'):
            self.rt.run('res = setState(%s)' % args)
            self.assertEqual(self.e('res.code'), 'STATE_NOT_SUPPORTED', args)
        self.assertEqual(len(self.rt.client_events('w_creators:client:remoteClothingState')), 0)

    def test_not_equipped_is_not_applicable(self):
        for group, value in (('gloves', 'off'), ('coat', 'off'), ('sleeves', 'rolled')):
            self.rt.run('res = setState("%s", "%s")' % (group, value))
            if group == 'sleeves':
                self.assertTrue(self.e('res.ok'))          # the default outfit has a shirt
            else:
                self.assertEqual(self.e('res.code'), 'STATE_NOT_APPLICABLE', group)
        # boots 'under' requires pants
        self.rt.run('b = saved(); b.clothing.equipped.pants = nil; setSaved("vorp:1", b); res = setState("boots", "under")')
        self.assertEqual(self.e('res.code'), 'STATE_NOT_APPLICABLE')
        self.assertEqual(len([e for e in self.rt.client_events('w_creators:client:remoteClothingState')
                              if e.args[2] != 'sleeves']), 0)

    def test_rate_limit(self):
        self.rt.run('''
            keepRate = true
            ok = 0
            for i = 1, 12 do if setState('hat', i % 2 == 0 and 'on' or 'off').ok then ok = ok + 1 end end
            res = setState('hat', 'on')
        ''')
        self.assertEqual(self.e('ok'), 12)
        self.assertEqual(self.e('res.code'), 'RATE_LIMITED')
        self.rt.run('tick(10001); res = setState("hat", "on")')
        self.assertTrue(self.e('res.ok'))

    def test_disabled_service(self):
        self.rt.run('Config.Services.clothingActions = false; res = setState("hat", "off")')
        self.assertEqual(self.e('res.code'), 'ACTIONS_DISABLED')
        self.rt.run('Config.Services.clothingActions = true; Config.ClothingStates.enabled = false; res = setState("hat", "off")')
        self.assertEqual(self.e('res.code'), 'ACTIONS_DISABLED')

    def test_busy_and_no_character(self):
        self.rt.run('Players[1].coords = WARDROBE; opened = call("w_creators:wardrobe:open", 1, "valentine_wardrobe"); res = setState("hat", "off")')
        self.assertTrue(self.e('opened.ok'))
        self.assertEqual(self.e('res.code'), 'BUSY')
        self.rt.run('WCSessions.clear(1); CreatorAppearanceLocks["vorp:1"] = "other"; res = setState("hat", "off")')
        self.assertEqual(self.e('res.code'), 'BUSY')
        self.rt.run('CreatorAppearanceLocks["vorp:1"] = nil; charids[1] = nil; res = setState("hat", "off")')
        self.assertEqual(self.e('res.code'), 'NO_CHARACTER')

    def test_database_failure_is_reported(self):
        self.rt.run('FakeDB.transactionOk = false; res = setState("hat", "off")')
        self.assertEqual(self.e('res.code'), 'DATABASE_ERROR')
        self.assertIsNone(self.e('CreatorAppearanceLocks["vorp:1"]'))
        self.assertEqual(len(self.rt.client_events('w_creators:client:remoteClothingState')), 0)


if __name__ == '__main__':
    unittest.main()
