"""The services board's server half (server/locations/store.lua, 2026-10-19): migration 007 copies
Config.Locations in once, the rows become the places (WCLocations.setList, clients, clinic points),
and w_creators:board:action edits them for staff only, with every spot near the staff member."""
import unittest

from harness import Runtime

# An in-memory w_creators_locations behind the fake database.
TABLE = r'''
Rows = {}
local function upsert(sql, p)
    local row = Rows[p[1]]
    if row and sql:find('INSERT IGNORE', 1, true) then return 0 end
    Rows[p[1]] = { id = p[1], type = p[2], data = p[3], position = p[4], updated_by = p[5] }
    return 1
end
FakeDB.on('INTO `w_creators_locations`', function(sql, p) return upsert(sql, p) end)
FakeDB.on('DELETE FROM `w_creators_locations`', function(_, p) Rows[p[1]] = nil return 1 end)
FakeDB.on('FROM `w_creators_locations` ORDER BY', function()
    local out = {}
    for _, row in pairs(Rows) do out[#out + 1] = row end
    table.sort(out, function(a, b)
        if a.position ~= b.position then return a.position < b.position end
        return a.id < b.id
    end)
    return out
end)
'''


class BoardStoreTests(unittest.TestCase):
    def setUp(self):
        self.rt = Runtime()
        self.rt.load_server_core()
        self.rt.load('server/locations/store.lua')
        self.e = self.rt.eval
        self.run = self.rt.run
        self.run('GlobalState = {}')
        self.run(TABLE)
        self.run('''Admins = { [1] = true }
            IsPlayerAceAllowed = function(src, ace) return Admins[src] == true and ace == Config.Admin.ace end
            Players[1].coords = vector3(-307.0, 814.0, 119.0)
            Players[2] = { name = 'guest', coords = vector3(0, 0, 0), bucket = 0 }''')
        self.run('FakeDB.fireReady(); tick(0)')

    def act(self, src, op, args=None):
        self.run('R = Callbacks["w_creators:board:action"](%d, %r, %s)' % (src, op, args or '{}'))
        return self.e('R')

    def test_the_config_places_are_copied_in_once_and_used(self):
        self.assertTrue(self.e('WCPlaces.loaded'))
        self.assertEqual(self.e('#WCPlaces.list()'), self.e('#Config.Locations'))
        self.assertEqual(self.e('Rows.valentine_barber.type'), 'barber')
        self.assertIsNotNone(self.e('WCLocations.byId("valentine_barber")'))
        # the clinics' interaction points for w_medic
        self.assertEqual(self.e('GlobalState["w_creators:clinicPoints"].valentine_surgery.x'), -284.49)
        sent = [c for c in self.rt.client_events('w_creators:client:locations')]
        self.assertEqual(sent[-1].player, -1)

    def test_only_staff_may_use_the_board(self):
        r = self.act(2, 'list')
        self.assertFalse(r.ok)
        self.assertEqual(r.error, 'forbidden')
        r = self.act(1, 'list')
        self.assertTrue(r.ok)
        types = {t['id']: t['count'] for t in self.rt.py(r.data.types).values()}
        self.assertEqual(types, {'clothing': 4, 'barber': 7, 'surgery': 3, 'wardrobe': 3})

    def test_create_puts_a_place_at_the_staff_members_feet(self):
        r = self.act(1, 'create', '{ type = "barber", label = "  حلاق الوادي  " }')
        self.assertTrue(r.ok)
        self.assertEqual(r.data.selected, 'barber_1')
        loc = 'WCLocations.byId("barber_1")'
        self.assertEqual(self.e(loc + '.label'), 'حلاق الوادي')
        self.assertEqual(self.e(loc + '.coords.x'), -307.0)
        self.assertEqual(self.e('Rows.barber_1.type'), 'barber')
        self.assertFalse(self.act(1, 'create', '{ type = "bank" }').ok)

    def test_save_edits_the_fields(self):
        r = self.act(1, 'save', '{ id = "valentine_barber", label = "حلاق", enabled = false, radius = 99, blip = false }')
        self.assertTrue(r.ok)
        self.assertFalse(self.e('WCLocations.byId("valentine_barber").enabled'))
        self.assertEqual(self.e('WCLocations.byId("valentine_barber").interactionRadius'), 10.0)
        self.assertFalse(self.e('WCLocations.byId("valentine_barber").blip'))
        r = self.act(1, 'save', '{ id = "valentine_clothing", storeProfile = "nope" }')
        self.assertEqual(r.error, 'invalid')
        r = self.act(1, 'save', '{ id = "valentine_clothing", storeProfile = "premium", npcModel = "S_M_M_Tailor_01" }')
        self.assertTrue(r.ok)
        self.assertEqual(self.e('WCLocations.byId("valentine_clothing").storeProfile'), 'premium')
        self.assertEqual(self.act(1, 'save', '{ id = "nowhere" }').error, 'not_found')

    def test_a_clinic_blip_turned_on_gets_the_doctor_sprite(self):
        self.assertTrue(self.act(1, 'save', '{ id = "valentine_surgery", blip = true }').ok)
        self.assertEqual(self.e('WCLocations.byId("valentine_surgery").blip.sprite'), 'blip_shop_doctor')

    def test_spots_must_be_near_the_staff_member(self):
        far = '{ id = "valentine_barber", what = "preview", value = { x = 0, y = 0, z = 0, h = 90 } }'
        self.assertEqual(self.act(1, 'spot', far).error, 'too_far')
        near = '{ id = "valentine_barber", what = "preview", value = { x = -306.5, y = 813.0, z = 119.0, h = 450 } }'
        self.assertTrue(self.act(1, 'spot', near).ok)
        self.assertEqual(self.e('WCLocations.byId("valentine_barber").preview.w'), 90.0)

    def test_the_npc_step_moves_the_interaction_point_too(self):
        args = ('{ id = "valentine_barber", what = "npc", at = { x = -306.0, y = 815.0, z = 119.0 },'
                ' value = { x = -305.0, y = 815.0, z = 118.5, h = 180 }, model = "s_m_m_barber_01" }')
        self.assertTrue(self.act(1, 'spot', args).ok)
        loc = 'WCLocations.byId("valentine_barber")'
        self.assertEqual(self.e(loc + '.coords.y'), 815.0)
        self.assertEqual(self.e(loc + '.npc.model'), 's_m_m_barber_01')
        self.assertEqual(self.e(loc + '.npc.coords.w'), 180.0)
        self.assertTrue(self.act(1, 'clear', '{ id = "valentine_barber", what = "npc" }').ok)
        self.assertFalse(self.e(loc + '.npc'))

    def test_a_chair_only_at_a_barber(self):
        chair = '{ x = -306.0, y = 814.0, z = 119.0, h = 10, kind = "world", model = -12345 }'
        self.assertEqual(self.act(1, 'spot', '{ id = "valentine_clothing", what = "chair", value = %s }' % chair).error,
                         'invalid')
        self.assertTrue(self.act(1, 'spot', '{ id = "valentine_barber", what = "chair", value = %s }' % chair).ok)
        loc = 'WCLocations.byId("valentine_barber")'
        self.assertEqual(self.e(loc + '.chair.kind'), 'world')
        self.assertEqual(self.e(loc + '.chair.model'), -12345)
        self.assertEqual(self.e(loc + '.chair.coords.w'), 10.0)
        nomodel = '{ x = -306.0, y = 814.0, z = 119.0, h = 10, kind = "prop" }'
        self.assertEqual(self.act(1, 'spot', '{ id = "valentine_barber", what = "chair", value = %s }' % nomodel).error,
                         'no_chair')

    def test_a_deleted_place_stays_deleted_after_a_restart(self):
        self.assertTrue(self.act(1, 'delete', '{ id = "valentine_surgery" }').ok)
        self.assertIsNone(self.e('WCLocations.byId("valentine_surgery")'))
        self.assertIsNone(self.e('GlobalState["w_creators:clinicPoints"].valentine_surgery'))
        # a restart: the ledger holds 007, so nothing is copied in again
        self.run('WCPlaces.loaded = false; WCPlaces.load()')
        self.assertIsNone(self.e('Rows.valentine_surgery'))
        self.assertIsNone(self.e('WCLocations.byId("valentine_surgery")'))

    def test_a_failed_write_changes_nothing(self):
        self.run('Before = WCLocations.byId("valentine_barber").label; FakeDB.fail = "ON DUPLICATE KEY"')
        r = self.act(1, 'save', '{ id = "valentine_barber", label = "x" }')
        self.assertEqual(r.error, 'database_error')
        self.assertTrue(self.e('WCLocations.byId("valentine_barber").label == Before'))


if __name__ == '__main__':
    unittest.main()
