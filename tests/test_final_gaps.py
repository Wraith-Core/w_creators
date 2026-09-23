"""Regression tests for the final server/shared gaps behind the client fixes:

1. an owned dye outside the live tint config is re-worn in the store (and the wardrobe) for free,
   kept as stored by AppearanceSchema.mergeSections; a dye is reset only by an explicit
   original-colour choice (client finding 9);
2. the 8 overlay layers w_lib draws without a palette are not tintable (shared list, tint = false)
   and sanitize stores their colour as 1: a colour-only change is NO_CHANGES (client finding 20);
3. a repeated characters:loaded replays the last answer instead of NO_CHARACTER (client finding 6);
4. OpenSpawnSelector / an admin respawn answer BUSY while w_ambulancejob holds the player (dead,
   downed or in a hospital bed) (client finding 4);
5. GlobalState['w_creators:clinics'] publishes the usable clinics for w_ambulancejob.
"""
import os
import sys
import unittest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from harness import RESOURCE, Runtime  # noqa: E402
from test_server_commerce_store import commerce  # noqa: E402
from test_server_characters_flow import Base as CharsBase  # noqa: E402
from test_server_characters_world import Base as WorldBase  # noqa: E402
from test_server_services_barber import FILES as SERVICE_FILES, SETUP as SERVICE_SETUP, services_server  # noqa: E402

OWNED_DYE = "{ palette = 'metaped_tint_hat', tint0 = 4, tint1 = 5, tint2 = 6 }"


# ---------------------------------------------------------------------------------------------
#  1  An owned dye re-worn in the store
# ---------------------------------------------------------------------------------------------
class StoreOwnedDyeTests(unittest.TestCase):
    def setUp(self):
        self.rt = commerce()
        self.e = self.rt.eval
        self.rt.run('''
            hat1, hat2 = h('male', 'hats', 1), h('male', 'hats', 2)
            base = S.default('male'); base.clothing.equipped.hats = hat1; setSaved('vorp:1', base)
            own('vorp:1', 'hats', hat1, nil, 'store')
            own('vorp:1', 'hats', hat2, %s, 'store')
            -- the owned dye's palette is no longer offered for hats
            Config.Clothing.tints.palettes.hats = { 'metaped_tint_generic_clean' }
        ''' % OWNED_DYE)

    def open(self):
        self.rt.run('r = openStore(); storeToken = r.data.token; a = working()')
        self.assertTrue(self.e('r.ok'), self.e('r.code'))

    def test_re_wearing_an_owned_dyed_item_keeps_the_dye_and_is_free(self):
        self.open()
        self.rt.run('a.clothing.equipped.hats = hat2; a.clothing.tints.hats = %s; res = buy(a)' % OWNED_DYE)
        self.assertTrue(self.e('res.ok'), self.e('res.code'))      # not INVALID_TINT
        self.assertEqual(self.e('res.data.charged'), 0)
        self.assertEqual(self.e('#res.data.purchases'), 0)
        self.assertEqual(self.e('FakeUsers[1].money'), 100)
        t = self.e('saved().clothing.tints.hats')
        self.assertEqual((t.palette, t.tint0, t.tint1, t.tint2), ('metaped_tint_hat', 4, 5, 6))
        self.assertEqual(self.e('saved().clothing.equipped.hats'), self.e('hat2'))
        self.assertEqual(self.e('ownedRow("vorp:1", hat2).tint2'), 6)      # the owned row is untouched

    def test_with_tints_disabled_too(self):
        self.rt.run('Config.Clothing.tints.enabled = false')
        self.open()
        self.rt.run('a.clothing.equipped.hats = hat2; a.clothing.tints.hats = %s; res = buy(a)' % OWNED_DYE)
        self.assertTrue(self.e('res.ok'), self.e('res.code'))
        self.assertEqual(self.e('res.data.charged'), 0)
        self.assertEqual(self.e('saved().clothing.tints.hats.tint0'), 4)

    def test_a_different_tint_still_follows_the_live_config(self):
        self.open()
        self.rt.run("a.clothing.equipped.hats = hat2; "
                    "a.clothing.tints.hats = { palette = 'metaped_tint_hat', tint0 = 4, tint1 = 5, tint2 = 7 }; "
                    "res = buy(a)")
        self.assertEqual(self.e('res.code'), 'INVALID_TINT')
        self.assertEqual(self.e('ownedRow("vorp:1", hat2).tint2'), 6)

    def test_the_dye_is_reset_only_by_an_explicit_original_colour(self):
        self.rt.run('b = S.default("male"); b.clothing.equipped.hats = hat2; b.clothing.tints.hats = %s; '
                    'setSaved("vorp:1", b)' % OWNED_DYE)
        # an unrelated purchase keeps the worn dye
        self.open()
        self.rt.run('a.clothing.equipped.gloves = h("male", "gloves", 1); res = buy(a)')
        self.assertTrue(self.e('res.ok'), self.e('res.code'))
        self.assertEqual(self.e('ownedRow("vorp:1", hat2).palette'), 'metaped_tint_hat')
        self.assertEqual(self.e('saved().clothing.tints.hats.tint1'), 5)
        # the explicit reset (false): free, the owned row and the saved look lose the dye
        self.open()
        self.rt.run('a.clothing.tints.hats = false; res = buy(a)')
        self.assertTrue(self.e('res.ok'), self.e('res.code'))
        self.assertEqual(self.e('res.data.charged'), 0)
        self.assertIsNone(self.e('ownedRow("vorp:1", hat2).palette'))
        self.assertIsNone(self.e('saved().clothing.tints.hats'))

    def test_plan_never_turns_a_submitted_dye_into_a_reset(self):
        self.rt.run('''
            savedApp = saved(); ownedList = WCOwnership.list('vorp:1')
            sub = WCUtil.copy(savedApp); sub.clothing.equipped.hats = hat2; sub.clothing.tints.hats = %s
            plan, code = WCClothingStore.plan(savedApp, sub, ownedList, WCLocations.byId('valentine_clothing'))
        ''' % OWNED_DYE)
        self.assertIsNotNone(self.e('plan'), self.e('code'))
        self.assertEqual(self.e('plan.total'), 0)
        self.assertEqual(self.e('#plan.grants'), 0)
        self.assertEqual(self.e('plan.merged.clothing.tints.hats.tint0'), 4)

    def test_merge_sections_keeps_a_vouched_stored_dye(self):
        self.rt.run('''
            savedApp = saved()
            draft = WCUtil.copy(savedApp); draft.clothing.equipped.hats = hat2; draft.clothing.tints.hats = %s
            plain = S.mergeSections(savedApp, draft, { clothing = true })
            kept = S.mergeSections(savedApp, draft, { clothing = true }, { storedTints = { hats = %s } })
            other = S.mergeSections(savedApp, draft, { clothing = true },
                { storedTints = { hats = { palette = 'metaped_tint_hat', tint0 = 1, tint1 = 1, tint2 = 1 } } })
        ''' % (OWNED_DYE, OWNED_DYE))
        self.assertIsNone(self.e('plain.clothing.tints.hats'))       # a new tint: the live config
        self.assertEqual(self.e('kept.clothing.tints.hats.tint2'), 6)
        self.assertIsNone(self.e('other.clothing.tints.hats'))       # only the vouched tint itself

    def test_the_wardrobe_keeps_the_owned_dye_of_an_item_put_on(self):
        self.rt.run('''
            ownedList = WCOwnership.list('vorp:1')
            a = working(); a.clothing.equipped.hats = hat2
            merged, code = WCWardrobeService.plan(saved(), a, ownedList)
        ''')
        self.assertIsNotNone(self.e('merged'), self.e('code'))
        self.assertEqual(self.e('merged.clothing.tints.hats.tint1'), 5)


# ---------------------------------------------------------------------------------------------
#  2  Untintable overlay layers
# ---------------------------------------------------------------------------------------------
UNTINTED = ('complex', 'disc', 'ageing', 'freckles', 'moles', 'spots', 'acne', 'scars')


class UntintedOverlayTests(unittest.TestCase):
    def setUp(self):
        self.rt = services_server()
        self.e = self.rt.eval

    def test_the_shared_list_marks_exactly_the_eight_layers(self):
        flagged = sorted(l.id for l in self.e('WCOverlays.layers').values() if l.tint is False)
        self.assertEqual(flagged, sorted(UNTINTED))
        self.assertFalse(self.e("WCOverlays.tintable('scars')"))
        self.assertTrue(self.e("WCOverlays.tintable('grime')"))
        # the client renderer reads the same list
        src = (RESOURCE / 'client' / 'appearance' / 'overlays.lua').read_text(encoding='utf-8')
        self.assertIn('O.UNTINTED = WCOverlays.UNTINTED', src)
        self.assertIn('return WCOverlays.tintable(layer)', src)

    def test_sanitize_stores_colour_1_for_them(self):
        self.rt.run('''
            a = S.default('male')
            a.overlays.ageing = { style = 3, color = 40, opacity = 0.5 }
            a.overlays.grime = { style = 2, color = 40, opacity = 0.5 }
            s = S.sanitize(a, { rules = false })
            b = WCUtil.copy(a); b.overlays.ageing.color = 7
            c = WCUtil.copy(a); c.overlays.grime.color = 7
        ''')
        self.assertEqual(self.e('s.overlays.ageing.color'), 1)
        self.assertEqual(self.e('s.overlays.grime.color'), 40)
        self.assertEqual(self.rt.py(self.e('S.changedSections(a, b)')), {})
        self.assertEqual(self.rt.py(self.e('S.changedSections(a, c)')), {'skin': True})

    def test_a_colour_only_surgery_change_is_no_changes(self):
        self.rt.run('''
            Players[1].coords = vector3(-284.49, 807.49, 119.38); FakeUsers[1].money = 1000
            base = S.default('male'); base.overlays.scars = { style = 2, color = 1, opacity = 1.0 }
            setSaved(base)
            Clock.now = Clock.now + 11000; WCSurgeryService.grant(1, 'valentine_surgery')
            o = WCSurgeryService.open(1, 'valentine_surgery')
            app = WCUtil.copy(o.data.appearance); app.overlays.scars.color = 33
            c = WCSurgeryService.commit(1, o.data.token, 'op', app)
        ''')
        self.assertTrue(self.e('o.ok'), self.e('o.code'))
        self.assertEqual(self.e('c.code'), 'NO_CHANGES')
        self.assertEqual(self.e('FakeUsers[1].money'), 1000)


# ---------------------------------------------------------------------------------------------
#  3  characters:loaded replay
# ---------------------------------------------------------------------------------------------
class LoadedReplayTests(CharsBase):
    def test_a_retry_after_a_lost_reply_gets_the_same_answer(self):
        self.assertTrue(self.call('characters:select', 1, 'vorp:1').ok)
        first = self.call('characters:loaded', 1)
        self.assertTrue(first.ok, first.code)
        spawns = len(self.rt.client_events('w_creators:client:selectSpawn'))
        again = self.call('characters:loaded', 1)
        self.assertTrue(again.ok, again.code)                  # not NO_CHARACTER
        self.assertEqual(again.data.spawn, first.data.spawn)
        self.assertEqual(len(self.rt.client_events('w_creators:client:selectSpawn')), spawns)
        self.assertEqual(self.e('WCCharacters.active(1).charid'), 'vorp:1')

    def test_the_replay_ends_with_the_activation(self):
        self.assertTrue(self.call('characters:select', 1, 'vorp:1').ok)
        self.assertTrue(self.call('characters:loaded', 1).ok)
        self.rt.run('WCCharacters.clear(1)')
        self.assertEqual(self.call('characters:loaded', 1).code, 'NO_CHARACTER')

    def test_the_replay_is_forgotten_on_drop(self):
        self.assertTrue(self.call('characters:select', 1, 'vorp:1').ok)
        self.assertTrue(self.call('characters:loaded', 1).ok)
        self.rt.run("fireEvent('playerDropped', 1); tick(0)")
        self.rt.run('WCCharacters.setActive(1, "vorp:1", "male")')    # the same character again
        self.assertEqual(self.call('characters:loaded', 1).code, 'NO_CHARACTER')


# ---------------------------------------------------------------------------------------------
#  4  The spawn selector / admin respawn while the death system holds the player
# ---------------------------------------------------------------------------------------------
AMBULANCE = r'''
ambulance = { dead = {}, bed = {} }
-- the CitizenFX export proxy shape: every member is function(self, ...) (the receiver is dropped)
rawset(exports, 'w_ambulancejob', {
    IsDead = function(self, src) return ambulance.dead[src] == true or ambulance.bed[src] == true end,
    InHospitalBed = function(self, src) return ambulance.bed[src] == true end,
})
ambulanceState = 'started'
local baseState = GetResourceState
GetResourceState = function(name) if name == 'w_ambulancejob' then return ambulanceState end return baseState(name) end
'''


class DeathOwnerSpawnTests(unittest.TestCase):
    def setUp(self):
        self.rt = services_server()
        self.e = self.rt.eval
        self.rt.run(AMBULANCE)

    def test_open_spawn_selector_is_busy_while_dead_or_in_bed(self):
        self.rt.run('ambulance.dead[1] = true')
        self.assertEqual(self.e('WCApi.OpenSpawnSelector(1).code'), 'BUSY')
        self.assertIsNone(self.e('WCSpawnServer.pending(1)'))
        self.assertEqual(len(self.rt.client_events('w_creators:client:selectSpawn')), 0)
        self.rt.run('ambulance.dead[1] = false; ambulance.bed[1] = true')
        self.assertEqual(self.e('WCApi.OpenSpawnSelector(1).code'), 'BUSY')
        # only the bed export (an IsDead that does not count beds) still refuses
        self.rt.run("exports.w_ambulancejob.IsDead = function() return false end")
        self.assertEqual(self.e('WCApi.OpenSpawnSelector(1).code'), 'BUSY')
        self.rt.run('ambulance.bed[1] = false')
        self.assertTrue(self.e('WCApi.OpenSpawnSelector(1).ok'))

    def test_a_stopped_missing_or_throwing_death_system_never_blocks(self):
        self.rt.run("ambulance.dead[1] = true; ambulanceState = 'stopped'")
        self.assertTrue(self.e('WCApi.OpenSpawnSelector(1).ok'))
        self.rt.run("WCSpawnServer.cancel(1); ambulanceState = 'started'"
                    "; rawset(exports, 'w_ambulancejob', { IsDead = function() error('boom') end })")
        self.assertTrue(self.e('WCApi.OpenSpawnSelector(1).ok'))

    def test_an_admin_respawn_is_busy_but_a_death_respawn_is_not(self):
        self.rt.run('ambulance.dead[1] = true')
        self.assertEqual(self.e('WCApi.RespawnPlayer(1, "rhodes").code'), 'BUSY')
        self.assertEqual(self.e('WCSpawnServer.respawn(1, "rhodes", "admin").code'), 'BUSY')
        self.assertEqual(len(self.rt.client_events('w_creators:client:respawn')), 0)
        self.assertTrue(self.e('WCApi.RespawnPlayer(1, "rhodes", "death").ok'))
        self.rt.run('ambulance.dead[1] = false')
        self.assertTrue(self.e('WCApi.RespawnPlayer(1, "rhodes").ok'))


class DeathOwnerAdminCommandTests(WorldBase):
    def test_wc_respawn_is_refused_while_in_a_bed(self):
        self.activate()
        self.assertTrue(self.call('spawn:choose', 1, 'valentine').ok)
        self.rt.run(AMBULANCE + '; ambulance.bed[1] = true')
        self.assertEqual(self.e('WCRespawnServer.admin(0, "1").code'), 'BUSY')
        self.assertEqual(len(self.rt.client_events('w_creators:client:respawn')), 0)

    def test_the_ambulance_server_exports_exist(self):
        amb = RESOURCE.parent / 'w_ambulancejob' / 'server' / 'main.lua'
        if not amb.exists():
            self.skipTest('w_ambulancejob not available')
        src = amb.read_text(encoding='utf-8')
        self.assertIn("exports('IsDead'", src)
        self.assertIn("exports('InHospitalBed'", src)


# ---------------------------------------------------------------------------------------------
#  5  GlobalState['w_creators:clinics']
# ---------------------------------------------------------------------------------------------
KEY = 'w_creators:clinics'
CLINICS = ['armadillo_surgery', 'saintdenis_surgery', 'valentine_surgery']


def clinics_server():
    rt = Runtime().load_server_core()
    rt.run('GlobalState = {}; realDate = os.date; fixedHour = 12'
           '; os.date = function(f, ...) if f == "*t" then local t = realDate("*t"); t.hour = fixedHour; return t end'
           ' return realDate(f, ...) end')
    rt.load(*SERVICE_FILES)
    rt.run(SERVICE_SETUP)
    return rt


class ClinicPublicationTests(unittest.TestCase):
    def setUp(self):
        self.rt = clinics_server()
        self.e = self.rt.eval

    def published(self):
        value = self.e('GlobalState["%s"]' % KEY)
        return sorted(k for k, v in value.items() if v is True)

    def location(self, field, value):
        self.rt.run('''
            for _, loc in ipairs(Config.Locations) do if loc.id == 'valentine_surgery' then loc.%s = %s end end
            WCLocations.reload()
        ''' % (field, value))

    def test_published_at_start_with_the_shape_the_ambulance_job_reads(self):
        self.assertEqual(self.published(), CLINICS)
        self.assertEqual(self.e('WCSurgeryService.CLINICS_KEY'), KEY)
        job = RESOURCE.parent / 'w_ambulancejob' / 'client' / 'job.lua'
        if job.exists():
            src = job.read_text(encoding='utf-8')
            self.assertIn("CLINICS_KEY = '%s'" % KEY, src)
            self.assertIn('published[clinicId] == true', src)

    def test_the_clock_tick_republishes_hours_location_and_service_changes(self):
        self.location('hours', '{ open = 6, close = 22 }')
        self.rt.run('fixedHour = 23; WCSessions.publishClock()')
        self.assertEqual(self.published(), ['armadillo_surgery', 'saintdenis_surgery'])
        self.rt.run('fixedHour = 8; WCSessions.publishClock()')
        self.assertEqual(self.published(), CLINICS)
        self.location('enabled', 'false')
        self.rt.run('WCSessions.publishClock()')
        self.assertEqual(self.published(), ['armadillo_surgery', 'saintdenis_surgery'])
        self.rt.run('Config.Services.surgery = false; WCSessions.publishClock()')
        self.assertEqual(self.published(), [])
        self.rt.run('Config.Services.surgery = true; Config.CosmeticSurgery.enabled = false; WCSessions.publishClock()')
        self.assertEqual(self.published(), [])

    def test_an_unchanged_set_is_not_rewritten(self):
        self.rt.run('first = GlobalState["%s"]; WCSessions.publishClock()' % KEY)
        self.assertTrue(self.e('rawequal(first, GlobalState["%s"])' % KEY))

    def test_the_sixty_second_thread_runs_it(self):
        self.location('enabled', 'false')
        self.rt.run('tick(WCSessions.CLOCK_INTERVAL)')
        self.assertEqual(self.published(), ['armadillo_surgery', 'saintdenis_surgery'])


if __name__ == '__main__':
    unittest.main()
