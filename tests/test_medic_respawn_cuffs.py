"""w_medic's RespawnedDead (2026-10-14): only a respawn after the full bleed-out drops the cuffs.

w_policejob asks exports.w_medic:RespawnedDead(src) before it lets a respawned man's client drop his
handcuffs. The death is the client's own word, so w_medic keeps the clock: when it first heard him
down (last stand, then dead once he bled out). These run the shipped server/main.lua.
"""
import unittest

from test_client_services_ambulance import WCORE_STUBS, ambulance_source
from test_review_ambulance_r1 import advance
from harness import Runtime

META_STUB = r'''
function player(src, meta)
    local p = { PlayerData = { source = src, metadata = meta or {}, job = { name = 'unemployed' } } }
    p.Functions = { SetMetaData = function(k, v) p.PlayerData.metadata[k] = v end, ClearInventory = function() end }
    WPlayers[src] = p
end
-- the state bag the jobs centre flag is written to (its boot loop runs as the clock advances)
function Player(src) local st = {}; function st:set(k, v) rawset(self, k, v) end; return { state = st } end
'''


def server_runtime():
    rt = Runtime()
    rt.run(WCORE_STUBS)
    rt.run(META_STUB)
    rt.run('Exported = {}; getmetatable(exports).__call = function(_, name, fn) Exported[name] = fn end')
    for rel in ('config.lua', 'server/main.lua'):
        rt.lua.execute(ambulance_source(rel), name='@w_medic/' + rel)
    rt.run('player(5)')
    # he lies at Valentine (the respawn point with the beds)
    rt.run('local c = Config.RespawnPoints[1].coords; GetEntityCoords = function() return vector3(c.x, c.y, c.z) end')
    return rt


class RespawnedDeadTests(unittest.TestCase):
    def setUp(self):
        self.rt = server_runtime()
        self.run, self.eval = self.rt.run, self.rt.eval
        self.bleed_ms = int(self.eval('Config.TimeTillRespawn')) * 1000

    def ev(self, name, *args):
        lua_args = ', '.join(['true' if a is True else 'false' if a is False else 'nil' if a is None else str(a)
                              for a in args])
        self.run('fireEvent("%s", 5%s)' % (name, (', ' + lua_args) if lua_args else ''))

    def respawned(self):
        return self.eval('Exported.RespawnedDead(5)')

    def test_an_honest_bleed_out_drops_the_cuffs(self):
        self.ev('hospital:server:SetLaststandStatus', True)
        advance(self.rt, self.bleed_ms)
        self.ev('hospital:server:SetLaststandStatus', False)   # the bleed-out: last stand over ...
        self.ev('hospital:server:SetDeathStatus', True)        # ... and dead, the same moment
        self.ev('hospital:server:RespawnAtHospital', 1)
        self.assertTrue(self.respawned())

    def test_dead_then_respawn_at_once_keeps_the_cuffs(self):
        self.ev('hospital:server:SetDeathStatus', True)
        self.ev('hospital:server:RespawnAtHospital', 1)
        self.assertFalse(self.respawned())

    def test_a_living_sender_keeps_the_cuffs(self):
        self.ev('hospital:server:RespawnAtHospital', 1)
        self.assertFalse(self.respawned())

    def test_a_revive_resets_the_clock(self):
        self.ev('hospital:server:SetLaststandStatus', True)
        advance(self.rt, self.bleed_ms)
        self.ev('hospital:server:SetDeathStatus', False)       # a doctor revived him
        self.ev('hospital:server:SetLaststandStatus', False)
        advance(self.rt, 10000)
        self.ev('hospital:server:SetDeathStatus', True)        # down again, and asks at once
        self.ev('hospital:server:RespawnAtHospital', 1)
        self.assertFalse(self.respawned())

    def test_standing_up_from_a_last_stand_resets_the_clock(self):
        self.ev('hospital:server:SetLaststandStatus', True)
        advance(self.rt, self.bleed_ms)
        self.ev('hospital:server:SetLaststandStatus', False)   # picked up (no death follows)
        advance(self.rt, 10000)
        self.ev('hospital:server:SetDeathStatus', True)
        self.ev('hospital:server:RespawnAtHospital', 1)
        self.assertFalse(self.respawned())

    def test_the_answer_expires(self):
        self.ev('hospital:server:SetLaststandStatus', True)
        advance(self.rt, self.bleed_ms)
        self.ev('hospital:server:SetLaststandStatus', False)
        self.ev('hospital:server:SetDeathStatus', True)
        self.ev('hospital:server:RespawnAtHospital', 1)
        advance(self.rt, 61000)
        self.assertFalse(self.respawned())

    def test_a_non_boolean_status_is_ignored(self):
        self.run('fireEvent("hospital:server:SetDeathStatus", 5, "yes")')
        self.assertIsNone(self.eval('WPlayers[5].PlayerData.metadata.isdead'))


if __name__ == '__main__':
    unittest.main()
