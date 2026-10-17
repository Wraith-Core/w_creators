"""Review round 2, area "ambulance": a hospital bed stay (a living check-in / lie-in, or the dead
respawn) belongs to the character in it.

- Both IsDead exports (client: WCSpawn.DEATH_OWNER.isDead read by WCSelector.canSwitch; server:
  Chars.DEATH_OWNER read by Chars.canSwitch) answer true while the player is in a bed, so
  /characters is refused there (ARCHITECTURE.md section 9.1: "the hospital-bed heal timer").
- A character logging out (WCore:Client:OnPlayerUnload) drops the bed stay: the bed flags, the
  bed camera, the frozen / invincible ped, and the pending AI heal (a generation counter), so none
  of it reaches the next character (no god mode, no suppressed respawn prompt).
- The server tracks bed occupancy per player and frees it on LeaveBed, logout and drop.

The real w_medic files are loaded over the harness stubs (see test_review_ambulance_r1).
"""
import unittest

from harness import Runtime
from test_client_services_ambulance import WCORE_STUBS, ambulance_source
from test_review_ambulance_r1 import NATIVES, advance, BED

CAPTURE = r'''
Exported = {}
getmetatable(exports).__call = function(_, name, fn) Exported[name] = fn end
ServerEvents = {}
TriggerServerEvent = function(name, ...) ServerEvents[#ServerEvents + 1] = { name = name, args = { ... } } end
function serverEvents(name)
    local out = {}
    for _, e in ipairs(ServerEvents) do if e.name == name then out[#out + 1] = e end end
    return out
end
-- calls of a native on one ped with one value (SetEntityInvincible(ped, true) ...)
function calledOn(name, ped, value)
    local n = 0
    for _, c in ipairs(Natives) do
        if c[1] == name and c[2] == ped and (value == nil or c[3] == value) then n = n + 1 end
    end
    return n
end
function lastOn(name, ped)
    local v
    for _, c in ipairs(Natives) do if c[1] == name and c[2] == ped then v = c[3] end end
    return v
end
CamRendering = false
NativeReturns.CreateCam = 77
NativeReturns.DoesCamExist = function(c) return c == 77 end
NativeReturns.IsCamRendering = function() return CamRendering end
function shownGroups()
    local out = {}
    for _, g in ipairs(Groups) do if not g.deleted and g.shown then out[#out + 1] = g end end
    return out
end
function bedPromptShown()
    for _, g in ipairs(shownGroups()) do if g.title == locale('text.bed') then return true end end
    return false
end
'''


def client_runtime():
    rt = Runtime()
    rt.run(WCORE_STUBS)
    rt.run(NATIVES)
    rt.run(CAPTURE)
    for rel in ('config.lua', 'client/main.lua', 'client/laststand.lua', 'client/dead.lua'):
        rt.lua.execute(ambulance_source(rel), name='@w_medic/' + rel)
    return rt


def server_runtime():
    rt = Runtime()
    rt.run(WCORE_STUBS)
    rt.run('Exported = {}; getmetatable(exports).__call = function(_, name, fn) Exported[name] = fn end')
    for rel in ('config.lua', 'server/main.lua'):
        rt.lua.execute(ambulance_source(rel), name='@w_medic/' + rel)
    rt.run('player(5); player(6)')
    return rt


class BedGatesTheSwitchClientTests(unittest.TestCase):
    def setUp(self):
        self.rt = client_runtime()
        self.run, self.eval = self.rt.run, self.rt.eval
        self.heal_ms = self.eval('Config.AIHealTimer') * 1000

    def check_in(self, bed=3):
        self.run('spawnEvent("hospital:client:SendToBed", %d, %s, true)' % (bed, BED))
        advance(self.rt, 3000)

    def test_a_living_check_in_answers_busy_until_the_bed_is_left(self):
        self.assertFalse(self.eval('Exported.IsDead()'))
        self.check_in()
        self.assertFalse(self.eval('isDead or InLaststand'))
        self.assertTrue(self.eval('isInHospitalBed'))
        self.assertTrue(self.eval('Exported.IsDead()'))
        self.assertTrue(self.eval('Exported.InHospitalBed()'))
        advance(self.rt, self.heal_ms + 1000)          # the AI heal: may leave now, still in bed
        self.assertTrue(self.eval('Exported.IsDead()'))
        self.assertTrue(self.eval('bedPromptShown()'))
        self.run('for _, g in ipairs(shownGroups()) do fireEvent("w_lib:promptCompleted", nil, g.id, "J") end')
        advance(self.rt, 5000)
        self.assertFalse(self.eval('isInHospitalBed'))
        self.assertFalse(self.eval('Exported.IsDead()'))
        self.assertEqual(self.eval('#serverEvents("hospital:server:LeaveBed")'), 1)
        self.assertEqual(self.eval('serverEvents("hospital:server:LeaveBed")[1].args[1]'), 3)

    def test_logout_in_bed_drops_the_stay_and_the_pending_heal(self):
        self.check_in()
        self.run('CamRendering = true')
        self.run('spawnEvent("WCore:Client:OnPlayerUnload")')
        advance(self.rt, 200)
        self.assertFalse(self.eval('isInHospitalBed'))
        self.assertFalse(self.eval('Exported.IsDead()'))
        self.assertEqual(self.eval('#serverEvents("hospital:server:LeaveBed")'), 1)
        self.assertEqual(self.eval('lastOn("FreezeEntityPosition", 1)'), False)
        self.assertEqual(self.eval('lastOn("SetEntityInvincible", 1)'), False)
        self.assertEqual(self.eval('called("DestroyCam")'), 1)
        self.assertEqual(self.eval('called("RenderScriptCams")'), 2)   # on (bed), off (reset)
        # the next character is in the world when the old heal timer would have fired
        self.run('NativeReturns.PlayerPedId = 2; Natives = {}')
        advance(self.rt, self.heal_ms + 2000)
        self.assertEqual(self.eval('calledOn("SetEntityInvincible", 2, true)'), 0)
        self.assertEqual(self.eval('calledOn("TaskPlayAnim", 2)'), 0)
        self.assertFalse(self.eval('isInHospitalBed'))
        self.assertFalse(self.eval('bedPromptShown()'))
        self.assertEqual(self.eval('#serverEvents("hospital:server:LeaveBed")'), 1)

    def test_the_next_character_dying_gets_the_respawn_prompt(self):
        self.check_in()
        self.run('spawnEvent("WCore:Client:OnPlayerUnload")')
        advance(self.rt, 200)
        self.run('NativeReturns.PlayerPedId = 2')
        advance(self.rt, self.heal_ms + 2000)
        self.run('isDead = true; deathTime = 0; PedDead = true')
        advance(self.rt, 1000)
        self.assertFalse(self.eval('bedPromptShown()'))
        self.assertTrue(self.eval('deathGroup().shown and deathGroup().enabled.J'))
        self.run('fireEvent("w_lib:promptCompleted", nil, deathGroup().id, "J")')
        self.assertEqual(self.eval('RespawnRequests'), 1)

    def test_a_selection_camera_is_left_alone(self):
        self.check_in()
        self.run('CamRendering = false')               # another script's camera is on screen
        self.run('spawnEvent("WCore:Client:OnPlayerUnload")')
        advance(self.rt, 200)
        self.assertEqual(self.eval('called("DestroyCam")'), 1)
        self.assertEqual(self.eval('called("RenderScriptCams")'), 1)   # only the bed's own

    def test_logout_during_the_get_up_does_not_free_the_bed_twice(self):
        self.check_in()
        advance(self.rt, self.heal_ms + 1000)
        self.run('for _, g in ipairs(shownGroups()) do fireEvent("w_lib:promptCompleted", nil, g.id, "J") end')
        advance(self.rt, 1000)                         # in the 4 s get-up animation
        self.run('spawnEvent("WCore:Client:OnPlayerUnload")')
        advance(self.rt, 5000)
        events = self.eval('#serverEvents("hospital:server:LeaveBed")')
        self.assertEqual(events, 1)
        self.assertEqual(self.eval('serverEvents("hospital:server:LeaveBed")[1].args[1]'), 3)
        self.assertFalse(self.eval('isInHospitalBed'))

    def test_logout_while_being_put_in_bed_stops_the_placement(self):
        self.run('NativeReturns.IsScreenFadedOut = false')
        self.run('spawnEvent("hospital:client:SendToBed", 3, %s, true)' % BED)
        advance(self.rt, 300)                          # still fading out
        self.run('spawnEvent("WCore:Client:OnPlayerUnload")')
        self.run('NativeReturns.IsScreenFadedOut = true')
        advance(self.rt, self.heal_ms + 3000)
        self.assertEqual(self.eval('called("CreateCam")'), 0)
        self.assertEqual(self.eval('calledOn("SetEntityInvincible", 1, true)'), 0)
        self.assertFalse(self.eval('isInHospitalBed'))
        self.assertFalse(self.eval('bedPromptShown()'))

    def test_the_dead_respawn_heals_in_bed_as_before(self):
        self.run('isDead = true; deathTime = 0; PedDead = true')
        self.check_in()
        self.assertTrue(self.eval('Exported.IsDead()'))
        advance(self.rt, self.heal_ms + 3000)
        self.assertFalse(self.eval('isDead'))
        self.assertTrue(self.eval('isInHospitalBed'))
        self.assertTrue(self.eval('bedPromptShown()'))
        self.assertTrue(self.eval('Exported.IsDead()'))  # still in the bed


class BedOccupancyServerTests(unittest.TestCase):
    def setUp(self):
        self.rt = server_runtime()
        self.run, self.eval = self.rt.run, self.rt.eval

    def place(self, src, where):
        # the stubs' ped of a player (1000 + src) stands where Players[src].coords says; the
        # ambulance stubs answer the origin for every entity, so read the positions again
        self.run('local pos = (function() ' + where + ' end)() or vector3(0, 0, 0); '
                 'Players[%d] = Players[%d] or { name = "p%d", bucket = 0 }; Players[%d].coords = pos; '
                 'GetEntityCoords = function(e) local p = Players[(tonumber(e) or 0) - 1000]; '
                 'return p and p.coords or vector3(0, 0, 0) end' % (src, src, src, src))

    def send_to_bed(self, src, bed):
        # the server now refuses a check-in from away from the bed (w_medic atHospital):
        # stand the player at the bed first, as the real check-in does
        self.place(src, 'local b = Config.Locations["beds"][%d]; if b then local c = b.coords; '
                        'return vector3(c.x, c.y, c.z) end' % bed)
        self.run('fireEvent("hospital:server:SendToBed", %d, %d, true)' % (src, bed))

    def set_bed(self):
        return [(e.args[1], e.args[2]) for e in self.rt.client_events('hospital:client:SetBed')]

    def test_send_to_bed_counts_until_leave_bed(self):
        self.assertFalse(self.eval('Exported.IsDead(5)'))
        self.send_to_bed(5, 2)
        self.assertTrue(self.eval('Exported.IsDead(5)'))
        self.assertTrue(self.eval('Exported.InHospitalBed(5)'))
        self.assertFalse(self.eval('Exported.IsDead(6)'))
        self.run('fireEvent("hospital:server:LeaveBed", 5, 2)')
        self.assertFalse(self.eval('Exported.IsDead(5)'))
        self.assertEqual(self.set_bed(), [(2, True), (2, False)])

    def test_respawn_at_hospital_counts(self):
        # w_medic wakes a dead man at the nearest Config.RespawnPoints; only Valentine has beds
        valentine = 'local c = Config.RespawnPoints[1].coords; return vector3(c.x, c.y, c.z)'
        self.place(5, valentine)
        self.place(6, valentine)
        self.run('fireEvent("hospital:server:RespawnAtHospital", 5, 2)')
        self.assertTrue(self.eval('Exported.IsDead(5)'))
        self.run('fireEvent("hospital:server:RespawnAtHospital", 6, nil)')   # no bed near: bed 1
        self.assertTrue(self.eval('Exported.IsDead(6)'))
        self.assertEqual(self.set_bed(), [(2, True), (1, True)])

    def test_logout_and_drop_free_the_bed(self):
        self.send_to_bed(5, 2)
        self.send_to_bed(6, 1)
        self.run('fireEvent("WCore:Server:OnPlayerUnload", nil, 5)')
        self.run('fireEvent("playerDropped", 6)')
        self.assertFalse(self.eval('Exported.IsDead(5)'))
        self.assertFalse(self.eval('Exported.IsDead(6)'))
        self.assertEqual(self.set_bed(), [(2, True), (1, True), (2, False), (1, False)])

    def test_a_late_leave_bed_does_not_free_a_bed_someone_else_took(self):
        self.send_to_bed(5, 2)
        self.run('fireEvent("WCore:Server:OnPlayerUnload", nil, 5)')
        self.send_to_bed(6, 2)
        self.run('fireEvent("hospital:server:LeaveBed", 5, 2)')   # the logout's client event
        self.assertEqual(self.set_bed(), [(2, True), (2, False), (2, True)])
        self.assertTrue(self.eval('Exported.IsDead(6)'))

    def test_an_unknown_bed_is_ignored(self):
        self.run('fireEvent("hospital:server:SendToBed", 5, 999, true)')
        self.run('fireEvent("hospital:server:LeaveBed", 5, "x")')
        self.assertEqual(self.set_bed(), [])
        self.assertFalse(self.eval('Exported.IsDead(5)'))

    def test_a_check_in_from_away_is_refused(self):
        # player 5 stands at the origin, far from every bed and desk
        self.place(5, 'return vector3(0, 0, 0)')
        self.run('fireEvent("hospital:server:SendToBed", 5, 2, true)')
        self.assertEqual(self.set_bed(), [])
        self.assertFalse(self.eval('Exported.IsDead(5)'))

    def test_a_second_check_in_from_a_bed_is_refused(self):
        # w_medic: a patient already in a bed is not checked in again (a second bill, a spam)
        self.send_to_bed(5, 2)
        self.send_to_bed(5, 1)
        self.assertEqual(self.set_bed(), [(2, True)])
        self.run('fireEvent("hospital:server:LeaveBed", 5, 2)')
        self.assertEqual(self.set_bed()[-1], (2, False))
        self.assertFalse(self.eval('Exported.IsDead(5)'))


if __name__ == '__main__':
    unittest.main()
