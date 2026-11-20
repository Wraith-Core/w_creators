"""w_medic's cosmetic surgery entry (sibling resource, loaded here over small fakes of w_core and
w_lib): the clinic ids match the w_creators surgery locations, the station prompt only asks its own
server, and the server validates, rate-limits and calls exports.w_creators:OpenCosmeticSurgery
(the one-use grant path), answering failures with its own dictionary key."""
import json
import re
import unittest

from harness import RESOURCE, Runtime, read

AMBULANCE = RESOURCE.parent / 'w_medic'

WCORE_STUBS = r'''
SrvCallbacks, CommandsAdded, Usables = {}, {}, {}
WPlayers = {}
WCore = {
    Functions = {
        GetPlayer = function(src) return WPlayers[tonumber(src) or -1] end,
        GetWPlayers = function() return {} end,
        CreateCallback = function(name, fn) SrvCallbacks[name] = fn end,
        CreateUseableItem = function(name, fn) Usables[name] = fn end,
        GetPlayerData = function() return {} end,
        Notify = function() end,
    },
    Commands = { Add = function(name) CommandsAdded[name] = true end },
}
local core = WCore
w.framework = { getCoreObject = function() return core end }
function player(src, meta) WPlayers[src] = { PlayerData = { source = src, metadata = meta or {}, job = { name = 'unemployed' } } } end
ResourceStates = { w_creators = 'started' }
function GetResourceState(name) return ResourceStates[name] or 'missing' end
function GetInvokingResource() return nil end
SurgeryCalls = {}
SurgeryAnswer = { ok = true, code = 'OK', data = { locationId = 'valentine_surgery' } }
rawset(exports, 'w_creators', { OpenCosmeticSurgery = function(_, data)
    SurgeryCalls[#SurgeryCalls + 1] = data
    if type(SurgeryAnswer) == 'function' then return SurgeryAnswer(data) end
    return SurgeryAnswer
end })
rawset(exports, 'w_lib', {
    FwName = function() return 'w_core' end,
    FwBackend = function() return 'wcore' end,
    FwGetPlayerData = function(_, src)
        if src == nil then return {} end
        local p = WPlayers[tonumber(src) or -1]
        return p and p.PlayerData or nil
    end,
    FwGetOnlinePlayers = function()
        local out = {}
        for k, v in pairs(WPlayers) do out[k] = v.PlayerData end
        return out
    end,
    FwGetLoadedPlayers = function()
        local out = {}
        for k in pairs(WPlayers) do out[#out + 1] = k end
        return out
    end,
    FwGetOfflinePlayer = function() return nil end,
    FwSetMetadata = function(_, src, key, value)
        local p = WPlayers[tonumber(src) or -1]
        if p and p.PlayerData then p.PlayerData.metadata = p.PlayerData.metadata or {}; p.PlayerData.metadata[key] = value; return true end
        return false
    end,
    FwSetJob = function() return true end,
    FwSetDuty = function() return true end,
    FwToggleDuty = function() end,
    FwAddCommand = function(_, name) CommandsAdded[name] = true; return true end,
    FwOnCharacterLoaded = function(_, fn)
        if IsDuplicityVersion() then AddEventHandler('WCore:Server:PlayerLoaded', fn) else RegisterNetEvent('WCore:Client:OnPlayerLoaded', fn) end
    end,
    FwOnCharacterUnloaded = function(_, fn)
        if IsDuplicityVersion() then AddEventHandler('WCore:Server:OnPlayerUnload', fn) else RegisterNetEvent('WCore:Client:OnPlayerUnload', fn) end
    end,
    FwOnJobUpdate = function(_, fn) RegisterNetEvent('WCore:Client:OnJobUpdate', fn) end,
    FwOnDutyChange = function(_, fn) RegisterNetEvent('WCore:Client:SetDuty', fn) end,
    FwReloadAppearance = function() end,
    FwGetSharedWeapon = function() return nil end,
    InvRegisterUsableItem = function(_, name, _, fn) Usables[name] = fn; return true end,
    InvRegisterShop = function() return true end,
    InvOpenInventory = function() return true end,
    InvHasItem = function() return false end,
    InvGetItemCount = function() return 0 end,
    InvAddItem = function() return true end,
    InvRemoveItem = function() return true end,
    EconName = function() return 'framework' end,
    EconIsReady = function() return false end,
    EconEnsureAccount = function() return false end,
    EconTransfer = function() return false end,
})
function request(src, clinicId) fireEvent('hospital:server:requestCosmeticSurgery', src, clinicId) end
function notes(src)
    local out = {}
    for _, n in ipairs(Notifications) do if n.src == src then out[#out + 1] = n.data.description end end
    return out
end
'''

CLIENT_STUBS = r'''
function IsDuplicityVersion() return false end
Prompts = {}
w.prompt = { at = function(opts)
    local rec = { opts = opts, title = opts.title, labels = {}, removed = false }
    for _, row in ipairs(opts.prompts) do rec.labels[row.key] = row.label end
    function rec.setTitle(t) rec.title = t end
    function rec.setLabel(k, l) rec.labels[k] = l end
    function rec.remove() rec.removed = true end
    Prompts[#Prompts + 1] = rec
    return rec
end, atEntity = function() return { remove = function() end } end }
w.locale = function() end
w.getClosestPlayer = function() return nil end
ServerEvents = {}
function TriggerServerEvent(name, ...) ServerEvents[#ServerEvents + 1] = { name = name, args = { ... } } end
function RebuildStationBlips() end
function RelabelBedPrompt() end
function RelabelDeathPrompt() end
function PlayerPedId() return 1 end
function GetEntityCoords() return vector3(0, 0, 0) end
function surgeryPrompts()
    local out = {}
    for _, p in ipairs(Prompts) do if p.opts.prompts[1].label == Label then out[#out + 1] = p end end
    return out
end
'''


def ambulance_source(rel):
    """A w_medic file as plain Lua 5.4: its CitizenFX backtick hashes (the weapon table of
    config.lua) become GetHashKey calls, which the harness implements like the game."""
    return re.sub(r'`([^`]+)`', lambda m: 'GetHashKey("%s")' % m.group(1), read(AMBULANCE / rel))


def load_ambulance(rt, *paths):
    for rel in paths:
        rt.lua.execute(ambulance_source(rel), name='@w_medic/' + rel)


def ambulance_server():
    rt = Runtime()
    rt.run(WCORE_STUBS)
    load_ambulance(rt, 'config.lua', 'server/main.lua')
    return rt


def ambulance_client():
    rt = Runtime()
    rt.run(WCORE_STUBS)
    rt.run(CLIENT_STUBS)
    load_ambulance(rt, 'config.lua', 'client/job.lua')
    return rt


class ConfigTests(unittest.TestCase):
    def test_clinics_are_w_creators_surgery_locations_near_their_anchor(self):
        amb = ambulance_server()
        wc = Runtime()
        wc.load_shared()
        clinics = amb.py(amb.eval('Config.CosmeticSurgery.clinics'))
        self.assertTrue(amb.eval('Config.CosmeticSurgery.enabled'))
        self.assertEqual(amb.eval('Config.CosmeticSurgery.key'), amb.eval('Config.PromptKey'))
        self.assertGreaterEqual(len(clinics), 1)
        for i in range(1, len(clinics) + 1):
            cid = amb.eval('Config.CosmeticSurgery.clinics[%d].clinicId' % i)
            self.assertEqual(wc.eval('WCLocations.byId(%r).type' % cid), 'surgery', cid)
            x, y, z = (amb.eval('Config.CosmeticSurgery.clinics[%d].coords.%s' % (i, a)) for a in 'xyz')
            ax, ay, az = (wc.eval('WCLocations.anchor(WCLocations.byId(%r)).%s' % (cid, a)) for a in 'xyz')
            dist = ((x - ax) ** 2 + (y - ay) ** 2 + (z - az) ** 2) ** 0.5
            radius = wc.eval('WCLocations.byId(%r).interactionRadius' % cid)
            # the prompt distance must keep the player inside the server's proximity check
            self.assertLess(dist + amb.eval('Config.PromptDistance'), radius + 3, cid)

    def test_clinic_prompts_are_not_shadowed_by_station_prompts(self):
        # w_lib shows only the closest walk-up prompt and a tie goes to the one created first
        # (the station prompts): standing on a clinic prompt, no station prompt may be in range.
        amb = ambulance_server()
        reach = amb.eval('Config.PromptDistance')
        stations = amb.py(amb.eval('''(function()
            local out = {}
            for group, list in pairs(Config.Locations) do
                for i, v in pairs(list) do
                    local c = type(v) == 'table' and v.coords or v
                    if group ~= 'vehicle' and group ~= 'stations' then
                        out[#out + 1] = { name = group .. i, x = c.x, y = c.y, z = c.z }
                    end
                end
            end
            return out
        end)()'''))
        self.assertGreater(len(stations), 0)
        count = amb.eval('#Config.CosmeticSurgery.clinics')
        for i in range(1, count + 1):
            cid = amb.eval('Config.CosmeticSurgery.clinics[%d].clinicId' % i)
            x, y, z = (amb.eval('Config.CosmeticSurgery.clinics[%d].coords.%s' % (i, a)) for a in 'xyz')
            for st in (stations.values() if isinstance(stations, dict) else stations):
                st = dict(st)
                d = ((x - st['x']) ** 2 + (y - st['y']) ** 2 + (z - st['z']) ** 2) ** 0.5
                self.assertGreater(d, reach, '%s vs %s (%.2f m)' % (cid, st['name'], d))

    def test_locale_keys_exist_in_both_languages(self):
        for lang in ('ar', 'en'):
            data = json.loads(read(AMBULANCE / 'locales' / ('%s.json' % lang)))
            for group, key in (('text', 'surgery'), ('prompt', 'cosmetic_surgery'), ('error', 'surgery_unavailable')):
                self.assertTrue(data[group].get(key), '%s %s.%s' % (lang, group, key))

    def test_no_face_natives_in_the_ambulance_resource(self):
        for path in ('config.lua', 'client/job.lua', 'server/main.lua'):
            code = read(AMBULANCE / path)
            for forbidden in ('SetCharExpression', '0x5653AB26C82938CF', 'InvokeNative'):
                self.assertNotIn(forbidden, code, path)


class ServerTests(unittest.TestCase):
    def setUp(self):
        self.rt = ambulance_server()
        self.run = self.rt.run
        self.eval = self.rt.eval
        self.run('player(7)')

    def test_a_valid_request_calls_the_export(self):
        self.run('request(7, "saintdenis_surgery")')
        self.assertEqual(self.eval('#SurgeryCalls'), 1)
        self.assertEqual(self.eval('SurgeryCalls[1].source'), 7)
        self.assertEqual(self.eval('SurgeryCalls[1].clinicId'), 'saintdenis_surgery')
        self.assertEqual(self.eval('#notes(7)'), 0)

    def test_unknown_clinics_are_ignored(self):
        for bad in ('"valentine_barber"', 'nil', '{}', '12'):
            self.run('Clock.now = Clock.now + 10000')
            self.run('request(7, %s)' % bad)
        self.assertEqual(self.eval('#SurgeryCalls'), 0)

    def test_disabled_config_refuses(self):
        self.run('Config.CosmeticSurgery.enabled = false')
        self.run('request(7, "valentine_surgery")')
        self.assertEqual(self.eval('#SurgeryCalls'), 0)

    def test_requests_are_rate_limited_per_player(self):
        self.run('player(8)')
        self.run('request(7, "valentine_surgery")')
        self.run('request(7, "valentine_surgery")')
        self.run('request(8, "valentine_surgery")')
        self.assertEqual(self.eval('#SurgeryCalls'), 2)
        self.run('Clock.now = Clock.now + 3000')
        self.run('request(7, "valentine_surgery")')
        self.assertEqual(self.eval('#SurgeryCalls'), 3)

    def test_a_refused_export_notifies_the_ambulance_key(self):
        self.run('SurgeryAnswer = { ok = false, code = "TOO_FAR", message = "أنت بعيد جدًا عن المكان" }')
        self.run('request(7, "valentine_surgery")')
        self.assertEqual(self.rt.py(self.eval('notes(7)')), {1: 'error.surgery_unavailable'})

    def test_a_throwing_export_or_a_stopped_w_creators_notifies(self):
        self.run('SurgeryAnswer = function() error("boom") end')
        self.run('request(7, "valentine_surgery")')
        self.run('Clock.now = Clock.now + 5000; ResourceStates.w_creators = "stopped"')
        self.run('request(7, "valentine_surgery")')
        self.assertEqual(self.eval('#SurgeryCalls'), 1)
        self.assertEqual(self.eval('#notes(7)'), 2)

    def test_dead_players_and_unknown_players_are_refused(self):
        self.run('player(9, { isdead = true })')
        self.run('request(9, "valentine_surgery")')
        self.run('request(99, "valentine_surgery")')
        self.assertEqual(self.eval('#SurgeryCalls'), 0)
        self.assertEqual(self.eval('#notes(9)'), 1)

    def test_drop_forgets_the_rate_limit(self):
        self.run('request(7, "valentine_surgery")')
        self.run('fireEvent("playerDropped", 7)')
        self.run('request(7, "valentine_surgery")')
        self.assertEqual(self.eval('#SurgeryCalls'), 2)


class ClientTests(unittest.TestCase):
    def setUp(self):
        self.rt = ambulance_client()
        self.run = self.rt.run
        self.eval = self.rt.eval
        self.run('Label = locale("prompt.cosmetic_surgery")')
        self.run('createAmbuPrompts()')

    def test_one_prompt_per_clinic(self):
        prompts = self.eval('#surgeryPrompts()')
        self.assertEqual(prompts, self.eval('#Config.CosmeticSurgery.clinics'))
        self.assertEqual(self.eval('surgeryPrompts()[1].title'), 'text.surgery')
        self.assertEqual(self.eval('surgeryPrompts()[1].opts.prompts[1].key'), self.eval('Config.PromptKey'))

    def test_the_prompt_asks_its_own_server(self):
        self.run('surgeryPrompts()[2].opts.prompts[1].onComplete()')
        self.assertEqual(self.eval('ServerEvents[1].name'), 'hospital:server:requestCosmeticSurgery')
        self.assertEqual(self.eval('ServerEvents[1].args[1]'), self.eval('Config.CosmeticSurgery.clinics[2].clinicId'))

    def test_can_interact_needs_an_upright_player_and_w_creators(self):
        can = 'surgeryPrompts()[1].opts.canInteract()'
        self.assertTrue(self.eval(can))
        self.run('isDead = true')
        self.assertFalse(self.eval(can))
        self.run('isDead = false; InLaststand = true')
        self.assertFalse(self.eval(can))
        self.run('InLaststand = false; ResourceStates.w_creators = "stopped"')
        self.assertFalse(self.eval(can))

    def test_relabel_on_language_change(self):
        self.run('locale = function(key) return "EN:" .. key end')
        self.run('fireEvent("w_lib:setLocale", nil, "en")')
        self.run('Label = "prompt.cosmetic_surgery"')
        for i in range(1, self.eval('#Prompts') + 1):
            if self.eval('Prompts[%d].opts.prompts[1].onComplete ~= nil and Prompts[%d].labels.R' % (i, i)) == \
                    'EN:prompt.cosmetic_surgery':
                self.assertEqual(self.eval('Prompts[%d].title' % i), 'EN:text.surgery')
                break
        else:
            self.fail('no relabelled surgery prompt')

    def test_disabled_config_builds_no_surgery_prompt(self):
        rt = ambulance_client()
        rt.run('Config.CosmeticSurgery.enabled = false; Label = locale("prompt.cosmetic_surgery")')
        rt.run('createAmbuPrompts()')
        self.assertEqual(rt.eval('#surgeryPrompts()'), 0)
        self.assertGreater(rt.eval('#Prompts'), 0)

    def test_prompts_removed_on_stop(self):
        self.run('fireEvent("onResourceStop", nil, "w_creators")')
        self.assertTrue(all(self.eval('Prompts[%d].removed' % i) for i in range(1, self.eval('#Prompts') + 1)))



class ResurrectedListenerTests(unittest.TestCase):
    """w_medic clears its downed state when w_creators resurrects the player for another
    reason (w_creators:client:resurrected), and ignores its own 'hospital' resurrects."""

    def setUp(self):
        src = ambulance_source('client/main.lua')
        start = src.index("AddEventHandler('w_creators:client:resurrected'")
        end = src.index('\nend)', start) + len('\nend)')
        self.rt = rt = Runtime()
        rt.run('''isDead = true; InLaststand = false; deathTime = 30; emsNotified = true
            Sent = {}; Invincible = true; Laststand = {}
            function TriggerServerEvent(name, value) Sent[#Sent + 1] = { name, value } end
            function PlayerPedId() return 1 end
            function SetEntityInvincible(_, v) Invincible = v end
            function SetLaststand(v) InLaststand = v; Laststand[#Laststand + 1] = v end''')
        rt.run(src[start:end])

    def test_another_resurrect_clears_the_downed_state(self):
        self.rt.run('fireEvent("w_creators:client:resurrected", nil, "admin")')
        e = self.rt.eval
        self.assertFalse(e('isDead'))
        self.assertEqual(e('deathTime'), 0)
        self.assertFalse(e('emsNotified'))
        self.assertFalse(e('Invincible'))
        self.assertEqual(e('#Sent'), 2)
        self.assertEqual(e('Sent[1][1]'), 'hospital:server:SetDeathStatus')
        self.assertFalse(e('Sent[1][2]'))

    def test_last_stand_is_ended(self):
        self.rt.run('isDead = false; InLaststand = true; fireEvent("w_creators:client:resurrected", nil, "respawn")')
        self.assertFalse(self.rt.eval('InLaststand'))
        self.assertEqual(self.rt.eval('#Laststand'), 1)

    def test_own_hospital_resurrects_and_living_players_are_ignored(self):
        self.rt.run('fireEvent("w_creators:client:resurrected", nil, "hospital")')
        self.assertTrue(self.rt.eval('isDead'))
        self.rt.run('isDead = false; fireEvent("w_creators:client:resurrected", nil, "admin")')
        self.assertEqual(self.rt.eval('#Sent'), 0)


if __name__ == '__main__':
    unittest.main()
