"""Server services: the restricted development tools (server/dev/tools.lua)."""
import unittest

from harness import Runtime, REAL_CATALOG
from test_server_services_barber import FILES, SETUP


def dev_server(dev_tools=False, spawn_prop=False, catalog='fixture'):
    rt = Runtime(catalog=catalog).load_server_core()
    rt.run('Config.Admin.devTools = %s; Config.Admin.spawnProp = %s' % (str(dev_tools).lower(), str(spawn_prop).lower()))
    rt.load(*FILES)
    rt.load('server/dev/tools.lua')
    rt.run(SETUP)
    return rt


def lines(rt, level):
    return [p.text for p in rt.eval('Printed').values() if p.level == level]


class DevToolsTests(unittest.TestCase):
    def test_nothing_is_registered_in_production(self):
        rt = dev_server()
        self.assertIsNone(rt.eval('Events.commands.wc_catalog_validate'))
        self.assertIsNone(rt.eval('Events.commands.spawnprop'))
        # the appearance migration command is the repository's (always available, console only)
        self.assertIsNotNone(rt.eval('Events.commands.wc_migrate_appearances'))

    def test_default_configuration_has_no_errors(self):
        rt = dev_server()
        rt.run('report = WCDevTools.validate()')
        errors = list(rt.py(rt.eval('report.errors')).values())
        self.assertEqual(errors, [])
        checked = rt.py(rt.eval('report.checked'))
        for name in ('taxonomy', 'prices', 'tints', 'locations', 'services', 'spawn', 'outfits', 'grooming'):
            self.assertTrue(checked.get(name), name)

    @unittest.skipUnless(REAL_CATALOG, 'w_lib catalogue not available')
    def test_default_configuration_against_the_real_catalogue(self):
        rt = dev_server(catalog='real')
        rt.run('report = WCDevTools.validate()')
        self.assertEqual(list(rt.py(rt.eval('report.errors')).values()), [])

    def test_broken_configuration_is_reported(self):
        rt = dev_server()
        rt.run('''
            Config.Clothing.prices.hats = -1
            table.insert(Config.Clothing.taxonomy[1].subs, { id = 'hats2', category = 'hats', label = 'x' })
            Config.Clothing.pricingProfiles.bad = { multiplier = 0/0 }
            table.insert(Config.Locations, { id = 'valentine_barber', type = 'barber', coords = vector3(1, 2, 3) })
            table.insert(Config.Locations, { id = 'nowhere_shop', type = 'clothing', coords = vector3(1, 2, 3), storeProfile = 'nope' })
            WCLocations.reload()
            Config.CosmeticSurgery.price = 'free'
            table.insert(Config.Spawn.points, { id = 'valentine', coords = vector3(1, 2, 3) })
            table.insert(Config.Spawn.points, { id = 'moon', coords = vector3(0, 0, 99999) })
            Config.Grooming.stages.male.hair[1] = 'CLOTHING_ITEM_M_NOTHING_'
            report = WCDevTools.validate()
        ''')
        errors = '\n'.join(rt.py(rt.eval('report.errors')).values())
        warnings = '\n'.join(rt.py(rt.eval('report.warnings')).values())
        self.assertIn('hats has an invalid price', errors)
        self.assertIn('category hats appears twice', errors)
        self.assertIn('pricing profile bad', errors)
        self.assertIn('duplicate id valentine_barber', errors)
        self.assertIn('nowhere_shop uses an unknown store profile', errors)
        self.assertIn('surgery: invalid price', errors)
        self.assertIn('duplicate point id valentine', errors)
        self.assertIn('moon is outside', warnings)
        self.assertIn('CLOTHING_ITEM_M_NOTHING_ matches no catalogue item', warnings)

    def test_catalog_validate_command(self):
        rt = dev_server(dev_tools=True)
        cmd = rt.eval('Events.commands.wc_catalog_validate')
        self.assertIsNotNone(cmd)
        rt.run('Events.commands.wc_catalog_validate.fn(0, {})')
        self.assertTrue(any('wc_catalog_validate' in t for t in lines(rt, 'info')))
        # a player without the dev ACE is refused and reported
        before = len(lines(rt, 'info'))
        rt.run('LogEmits = {}; Events.commands.wc_catalog_validate.fn(1, {})')
        self.assertEqual(len(lines(rt, 'info')), before)
        self.assertEqual(rt.eval('LogEmits[1].event'), 'security_violation')
        # with the ACE
        rt.run('IsPlayerAceAllowed = function(src, ace) return ace == Config.Admin.devAce end')
        rt.run('Events.commands.wc_catalog_validate.fn(1, {})')
        self.assertEqual(len(lines(rt, 'info')), before + 1)
        self.assertEqual(rt.eval('Notifications[1].src'), 1)

    def test_spawnprop_only_when_enabled(self):
        rt = dev_server(spawn_prop=True)
        cmd = rt.eval('Events.commands.spawnprop')
        self.assertIsNotNone(cmd)
        self.assertTrue(cmd.restricted)
        rt.run('Events.commands.spawnprop.fn(1, { "p_chair01x" })')
        events = rt.client_events('W:ADMIN:SpawnObject')
        self.assertEqual((len(events), events[0].player, events[0].args[1]), (1, 1, 'p_chair01x'))
        rt.run('Events.commands.spawnprop.fn(0, { "p_chair01x" })')  # the console has no ped
        self.assertEqual(len(rt.client_events('W:ADMIN:SpawnObject')), 1)


if __name__ == '__main__':
    unittest.main()
