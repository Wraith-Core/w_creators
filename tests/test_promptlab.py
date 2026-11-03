"""The staff's /promptlab (2026-11-03): the gate (server ACE on open and on every report), the report format
(one JSON line per report in promptlab.jsonl, ONE masked console line for the final report, no fault words),
the cleaning of client data, the test list and the natives file (every hash the one checked against
alloc8or rdr3-nativedb-data)."""
import json
import re
import unittest

from harness import RESOURCE, Runtime, manifest, read

SERVER_STUBS = r'''
Files = {}
Traces = {}
LoadResourceFile = function(_, path) return Files[path] end
SaveResourceFile = function(_, path, content) Files[path] = content return true end
Citizen.Trace = function(line) Traces[#Traces + 1] = line end
IsPlayerAceAllowed = function(src, ace) return src == '1' and ace == 'w_creators.admin' end
GetPlayerIdentifierByType = function(src, kind) return kind .. ':abcdef' .. tostring(src) .. '9a7f' end
'''

FINAL = '''{ v = 1, reason = 'done', n = 23, last = 23, kb = true, results = {
    { id = '01', spec = 'L2', hide = 'type:12', answer = 'y', tries = 1,
      attempts = { { pf = 100, pa = 0, k = { ENTER = 1 }, mount = 1200 } } },
    { id = '13', spec = 'L8', hide = 'type:3,replay:loot', answer = 'n', tries = 2,
      attempts = { { pf = 10, pa = 10 }, { pf = 50, pa = 25, fire = { src = 'control', ms = 900, kb = true, ok = true },
                     loot = 950, ev = { same = true, ok = 1 }, err = { { n = 'taskLoot', e = 'error: attempt to call' } } } } },
    { id = '23', spec = 'L2', hide = 'sweep:1-20', answer = 'y', tries = 1,
      attempts = { { hits = { { n = 3, p = 2 }, { n = 12, p = 11 } } } } },
} }'''

# The natives of client/natives/promptlab.lua, each checked on 2026-11-03 in alloc8or rdr3-nativedb-data natives.json.
VERIFIED = {
    'blind': 0xF1622CE88A1946FB,             # HUD._UI_PROMPT_DISABLE_PROMPTS_THIS_FRAME()
    'disableType': 0xFC094EF26DD153FA,       # HUD._UI_PROMPT_DISABLE_PROMPT_TYPE_THIS_FRAME(int)
    'enableType': 0x06565032897BA861,        # HUD._UI_PROMPT_ENABLE_PROMPT_TYPE_THIS_FRAME(int)
    'modifyForPed': 0xA3DB37EDF9A74635,      # PLAYER._MODIFY_PLAYER_UI_PROMPT_FOR_PED(player, ped, int, int, BOOL)
    'isEnabledForPed': 0xEA8F168A76A0B9BC,   # PLAYER._GET_PLAYER_UI_PROMPT_FOR_PED_IS_ENABLED(player, ped, int, int)
    'controlPromptActive': 0x1BE19185B8AFE299,  # HUD.UI_PROMPT_IS_CONTROL_ACTION_ACTIVE(Hash)
    'setCarryingFlag': 0x18FF3110CF47115D,   # ENTITY._SET_ENTITY_CARRYING_FLAG(entity, int, BOOL)
    'getCarryingFlag': 0x808077647856DE62,   # ENTITY._GET_ENTITY_CARRYING_FLAG(entity, int)
    'taskLoot': 0x48FAE038401A2888,          # TASK.TASK_LOOT_ENTITY(ped, entity)
    'taskPickup': 0x502EC17B1BED4BFA,        # TASK.TASK_PICKUP_CARRIABLE_ENTITY(ped, entity)
    'taskMount': 0x92DB0739813C5186,         # TASK.TASK_MOUNT_ANIMAL(ped, mount, int, int, float, int, Any, Any)
    'taskHogtie': 0x27829AFD3E03AC1A,        # TASK.TASK_HOGTIE_TARGET_PED(ped, ped)
    'taskCutFree': 0x81D16C4FF3A77ADF,       # TASK._TASK_CUT_FREE_HOGTIED_TARGET_PED(ped, ped)
    'taskUsePoint': 0xCCDAE6324B6A821C,      # TASK.TASK_USE_SCENARIO_POINT(ped, int, char*, int, BOOL, BOOL, Hash, BOOL, float, BOOL)
    'taskNearestScenario': 0x322BFDEA666E2B0E,  # TASK._TASK_USE_NEAREST_SCENARIO_TO_COORD(ped, x, y, z, float, int, BOOL x4)
    'scenarioPoints': 0x345EC3B7EBDE1CB5,    # TASK.GET_SCENARIO_POINTS_IN_AREA(x, y, z, radius, Any*, int)
    'pointExists': 0x841475AC96E794D1,       # TASK.DOES_SCENARIO_POINT_EXIST(int)
    'pointCoords': 0xA8452DD321607029,       # TASK._GET_SCENARIO_POINT_COORDS(int, BOOL)
    'usingScenario': 0x57AB4A3080F85143,     # PED.IS_PED_USING_ANY_SCENARIO(ped)
    'carrying': 0xD806CD2A4F2C2996,          # PED._GET_FIRST_ENTITY_PED_IS_CARRYING(ped)
    'carryingSomething': 0xA911EE21EDF69DAF,  # PED.IS_PED_CARRYING_SOMETHING(ped)
    'carrier': 0x09B83E68DE004CD4,           # PED._GET_CARRIER_AS_PED(entity)
    'isCarriable': 0x0CCFE72B43C9CF96,       # TASK.GET_IS_CARRIABLE_ENTITY(entity)
    'fullyLooted': 0x8DE41E9902E85756,       # ENTITY._IS_ENTITY_FULLY_LOOTED(entity)
    'lootingPed': 0xEF2D9ED7CE684F08,        # ENTITY._FIND_ENTITY_LOOTING_PED(entity)
    'skinned': 0x88A5564B19C15391,           # PED._IS_ANIMAL_SKINNED(ped)
    'isAnimal': 0x9A100F1CF4546629,          # ENTITY.GET_IS_ANIMAL(entity)
    'isHorseModel': 0x772A1969F649E902,      # PED._IS_THIS_MODEL_A_HORSE(Hash)
    'hogtied': 0x3AA24CCC0D451379,           # PED.IS_PED_HOGTIED(ped)
    'keyboard': 0xA571D46727E2B718,          # PAD.IS_USING_KEYBOARD_AND_MOUSE(int)
    'eventCount': 0x5CE8DE5909565748,        # SCRIPT.GET_NUMBER_OF_EVENTS(int)
    'eventAt': 0xA85E614430EFF816,           # SCRIPT.GET_EVENT_AT_INDEX(int, int)
    'lootEventData': 0x57EC5FA4D4D6AFCA,     # SCRIPT.GET_EVENT_DATA(int, int, Any*, int)
}

FAULT = re.compile(r'(?i)error|warn|fail|exception|traceback|blocked|mismatch|attempt to')


class PromptLabServerTests(unittest.TestCase):
    def setUp(self):
        self.rt = Runtime()
        self.rt.load_server_core()
        self.rt.run(SERVER_STUBS)
        self.rt.load('server/lab/promptlab.lua')
        self.e = self.rt.eval

    def call(self, name, src, *args):
        self.rt.g.R = None
        lua_args = ', '.join(args)
        self.rt.run('R = Callbacks["%s"](%d%s)' % (name, src, (', ' + lua_args) if lua_args else ''))
        return self.rt.py(self.e('R'))

    def lines(self):
        content = self.e('Files["promptlab.jsonl"]')
        return [json.loads(line) for line in (content or '').splitlines()]

    def traces(self):
        return list(self.rt.py(self.e('Traces')).values()) if self.e('#Traces') else []

    # -- the gate ---------------------------------------------------------------------------
    def test_a_normal_player_gets_nothing_and_nothing_is_written(self):
        self.assertEqual(self.call('w_creators:promptlab:open', 2), {'ok': False})
        res = self.call('w_creators:promptlab:report', 2, "'final'", FINAL)
        self.assertFalse(res['ok'])
        self.assertEqual(self.lines(), [])
        self.assertEqual(self.traces(), [])

    def test_the_console_is_not_a_player(self):
        self.assertFalse(self.e('WCPromptLab.isStaff(0)'))
        self.assertFalse(self.e('WCPromptLab.isStaff(nil)'))

    def test_staff_open_gives_a_code(self):
        res = self.call('w_creators:promptlab:open', 1)
        self.assertTrue(res['ok'])
        self.assertRegex(res['code'], r'^PL-[0-9A-F]{4}$')
        self.assertEqual(self.lines()[0]['k'], 'open')

    def test_the_gate_reads_the_admin_ace_of_the_config(self):
        self.assertIn("ace       = 'w_creators.admin'", read(RESOURCE / 'config' / 'main.lua'))
        self.rt.run("Config.Admin.ace = 'something.else'")
        self.assertEqual(self.call('w_creators:promptlab:open', 1), {'ok': False})

    # -- the report -------------------------------------------------------------------------
    def test_a_result_is_one_json_line_and_no_console_line(self):
        code = self.call('w_creators:promptlab:open', 1)['code']
        res = self.call('w_creators:promptlab:report', 1, "'result'", "{ id = '01', answer = 'y', tries = 1 }")
        self.assertEqual(res['code'], code)
        last = self.lines()[-1]
        self.assertEqual((last['k'], last['code'], last['src'], last['data']['id'], last['data']['answer']),
                         ('result', code, 1, '01', 'y'))
        self.assertRegex(last['at'], r'^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ$')
        self.assertEqual(self.traces(), [])

    def test_the_final_report_prints_one_masked_line_without_fault_words(self):
        code = self.call('w_creators:promptlab:open', 1)['code']
        res = self.call('w_creators:promptlab:report', 1, "'final'", FINAL)
        self.assertTrue(res['ok'])
        traces = self.traces()
        self.assertEqual(len(traces), 1)
        line = traces[0]
        self.assertTrue(line.startswith('[w_creators] PROMPTLAB %s src=1 lic=..9a7f ' % code), line)
        self.assertTrue(line.endswith('\n'))
        self.assertEqual(line.count('\n'), 1)
        self.assertIn('kb=1 n=23 last=23 end=done', line)
        self.assertIn(' 01:y/M.P0 ', line)
        self.assertIn(' 13:n/Fc.L.E=.P50.X1 ', line)
        self.assertIn(' 23:y/#3+12 ', line)
        self.assertIn('(full: promptlab.jsonl)', line)
        self.assertIsNone(FAULT.search(line), line)
        self.assertNotIn('license', line)
        self.assertTrue(all(32 <= ord(c) <= 126 for c in line.rstrip('\n')))
        final = self.lines()[-1]
        self.assertEqual(final['k'], 'final')
        # the file keeps the full detail, the native error message included
        self.assertIn('taskLoot', json.dumps(final))

    def test_a_wrong_kind_or_an_oversized_payload_is_refused(self):
        self.call('w_creators:promptlab:open', 1)
        self.assertEqual(self.call('w_creators:promptlab:report', 1, "'other'", '{}')['error'], 'kind')
        big = "{ s = string.rep('x', 60000) }"
        self.assertEqual(self.call('w_creators:promptlab:report', 1, "'result'", big)['error'], 'payload')

    def test_the_rate_limit_holds(self):
        self.call('w_creators:promptlab:open', 1)
        for _ in range(40):
            self.call('w_creators:promptlab:report', 1, "'result'", "{ id = '01' }")
        self.assertEqual(self.call('w_creators:promptlab:report', 1, "'result'", "{ id = '01' }")['error'], 'rate')

    def test_clean_keeps_plain_data_only(self):
        out = self.rt.py(self.e('''WCPromptLab.clean({ ok = true, n = 1.5, s = 'abc\\n\\216\\167', bad_key_ = 1,
            ['no-good'] = 1, f = function() end, nan = 0/0, deep = { a = { b = { c = { d = { e = { g = { h = { i = { f = 1 } } } } } } } } },
            list = { 1, 'x', function() end, 3 } })'''))
        self.assertEqual(out['ok'], True)
        self.assertEqual(out['n'], 1.5)
        self.assertEqual(out['s'], 'abc???')
        self.assertNotIn('no-good', out)
        self.assertNotIn('f', out)
        self.assertNotIn('nan', out)
        self.assertEqual(list(out['list'].values()), [1, 'x', 3])
        self.assertNotIn('f', json.dumps(out['deep']).replace('"deep"', ''))

    def test_the_file_keeps_its_newest_lines(self):
        self.rt.run("Files['promptlab.jsonl'] = string.rep(string.rep('a', 99) .. '\\n', 11000)")
        self.call('w_creators:promptlab:open', 1)
        content = self.e('Files["promptlab.jsonl"]')
        self.assertLess(len(content), 1048576)
        self.assertEqual(json.loads(content.splitlines()[-1])['k'], 'open')


class PromptLabClientTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        rt = Runtime().load_shared()
        rt.run('PlayerId = function() return 0 end')
        rt.load('client/natives/metaped.lua', 'client/natives/promptlab.lua', 'client/lab/promptlab.lua')
        cls.rt = rt
        cls.tests = [rt.py(t) for t in rt.eval('WCPromptLab.TESTS').values()]

    def test_the_tests_are_numbered_in_order(self):
        self.assertEqual([t['id'] for t in self.tests], ['%02d' % i for i in range(1, len(self.tests) + 1)])
        self.assertGreaterEqual(len(self.tests), 20)

    def test_every_test_is_complete(self):
        en = json.loads(read(RESOURCE / 'locales' / 'en.json'))
        ar = json.loads(read(RESOURCE / 'locales' / 'ar.json'))
        targets = {'none', 'horse', 'body', 'carcass', 'carriable', 'living', 'hogtied', 'carrying', 'chair'}
        watches = {'mount', 'loot', 'lootEvent', 'carry', 'drop', 'sit', 'melee', 'focus', 'hogtie', 'skin'}
        for t in self.tests:
            for field in ('say', 'doing', 'ask'):
                self.assertIn(t[field], en, t['id'])
                self.assertIn(t[field], ar, t['id'])
            self.assertIn(t['target'], targets, t['id'])
            self.assertTrue(t['spec'].startswith(('L', 'B-')), t['id'])
            for name in (t.get('watch') or {}).values():
                self.assertIn(name, watches, t['id'])
            for c in list((t.get('controls') or {}).values()):
                self.assertTrue(c.startswith('INPUT_'), t['id'])
            if t.get('hide'):
                self.assertIn(t['hide']['kind'], ('type', 'blind', 'ped', 'carry', 'sweep'), t['id'])
            rp = t.get('replay')
            if rp:
                self.assertIn(rp['key'], ('E', 'R', 'F'), t['id'])   # the game's own keys (owner, 2026-11-03)
                self.assertIn(rp['task'], ('loot', 'pickup', 'mount', 'hogtie', 'cutfree', 'sit'), t['id'])
                self.assertIn(rp['label'], en, t['id'])
                self.assertTrue(all(c.startswith('INPUT_') for c in rp['controls'].values()), t['id'])

    def test_the_spec_lab_items_are_covered(self):
        specs = {t['spec'] for t in self.tests}
        for item in ('L1', 'L2', 'L3', 'L4', 'L5', 'L6', 'L7', 'L8', 'L9'):
            self.assertIn(item, specs)
        # L1: the same per-ped switch once with false and once with true
        l1 = [t['hide'] for t in self.tests if t['spec'] == 'L1']
        self.assertEqual(sorted(h['value'] for h in l1), [False, True])
        self.assertEqual(len({(h['type'], h['mode']) for h in l1}), 1)

    def test_hide_codes(self):
        e = self.rt.eval
        self.assertEqual(e("WCPromptLab.hideCode(WCPromptLab.TESTS[1])"), 'type:12')
        self.assertEqual(e("WCPromptLab.hideCode(WCPromptLab.TESTS[2])"), 'blind+enable:12')
        self.assertEqual(e("WCPromptLab.hideCode(WCPromptLab.TESTS[3])"), 'type:12,replay:mount')
        self.assertEqual(e("WCPromptLab.hideCode(WCPromptLab.TESTS[4])"), 'ped:35/1/false')

    def test_nothing_runs_until_the_command(self):
        src = read(RESOURCE / 'client' / 'lab' / 'promptlab.lua')
        top = re.sub(r'(?s)RegisterCommand\(.*', '', src)
        self.assertNotRegex(top, r'(?m)^CreateThread')
        self.assertIn("pcall(w.callback.await, OPEN_CB, false)", src)
        self.assertIn("res.ok ~= true then return end", src)


CLIENT_FLOW_STUBS = r'''
Pressed, Sent, Notes, Texts, Invoked, Visible, Labels, JustPressed = {}, {}, {}, {}, {}, {}, {}, {}
NativeResults, Mounted, Shown, OpenReply, Warns = {}, false, false, { ok = true, code = 'PL-1234' }, {}
Citizen.ResultAsInteger = function() return 'int' end
Citizen.ResultAsVector = function() return 'vec' end
Citizen.InvokeNative = function(hash, ...)
    Invoked[#Invoked + 1] = { hash = hash, args = { ... } }
    local r = NativeResults[hash]
    if type(r) == 'function' then return r(...) end
    return r
end
PlayerPedId = function() return 1 end
PlayerId = function() return 0 end
GetEntityCoords = function(e) if e == 1 then return vector3(0, 0, 0) end return vector3(1, 0, 0) end
GetGamePool = function() return { 1, 50 } end
IsPedDeadOrDying = function() return false end
IsPedOnMount = function() return Mounted end
IsPedInAnyVehicle = function() return false end
IsPedHuman = function() return false end
IsPedAPlayer = function(e) return e == 1 end
DoesEntityExist = function(e) return e == 1 or e == 50 end
IsEntityAPed = function() return true end
GetEntityModel = function() return 777 end
GetEntityPlayerIsFreeAimingAt = function() return false, 0 end
GetPlayerTargetEntity = function() return false, 0 end
IsPlayerFreeFocusing = function() return false end
IsPedInMeleeCombat = function() return false end
IsControlJustPressed = function(_, h) return JustPressed[h] == true end
IsDisabledControlJustPressed = function(_, h) return JustPressed[h] == true end
DisableControlAction = function() end
Entity = function() return { state = {} } end
exports = { w_lib = {
    CreateGroup = function() return 9 end,
    AddPrompt = function() return true end,
    SetPromptVisible = function(_, _, key, v) Visible[key] = v return true end,
    SetPromptLabel = function(_, _, key, l) Labels[key] = l return true end,
    SetTitle = function(_, _, t) Title = t return true end,
    Display = function() Shown = true return true end,
    Hide = function() Shown = false return true end,
    IsVisible = function() return Shown end,
    IsCompleted = function(_, _, key) if Pressed[key] then Pressed[key] = nil return true end return false end,
    DeleteGroup = function() Deleted = true return true end,
    WalkupClaim = function() return true end,
    WalkupRelease = function() Released = true end,
} }
w.notify = function(t) Notes[#Notes + 1] = t end
w.showTextUI = function(t) Texts[#Texts + 1] = t end
w.hideTextUI = function() TextHidden = true end
w.callback.await = function(name, _, ...)
    Sent[#Sent + 1] = { name = name, args = { ... } }
    if name == 'w_creators:promptlab:open' then return OpenReply end
    return { ok = true, code = 'PL-1234' }
end
-- the horse: _IS_THIS_MODEL_A_HORSE answers 1; the per-ped switch: `value` = enabled (true enables)
NativeResults[0x772A1969F649E902] = 1
Enabled = true
NativeResults[0xEA8F168A76A0B9BC] = function() return Enabled and 1 or 0 end
NativeResults[0xA3DB37EDF9A74635] = function(_, _, _, _, value) Enabled = value end
'''


class PromptLabFlowTests(unittest.TestCase):
    """The whole lab in a fake client: the command, the card keys, the frames, the reports."""

    def setUp(self):
        rt = Runtime().load_shared()
        rt.run(CLIENT_FLOW_STUBS)
        rt.load('client/natives/metaped.lua', 'client/natives/promptlab.lua', 'client/lab/promptlab.lua')
        rt.run("WCDebug.warn = function(_, fmt, ...) Warns[#Warns + 1] = string.format(fmt, ...) end")
        self.rt, self.e = rt, rt.eval

    def press(self, key):
        self.rt.g.tick(500)
        self.rt.run("Pressed['%s'] = true" % key)
        self.rt.g.tick(1)

    def command(self, *args):
        self.rt.run("Events.commands.promptlab.fn(0, { %s })" % ', '.join("'%s'" % a for a in args))
        self.rt.g.tick(1)

    def sent(self, kind):
        out = []
        for s in self.rt.py(self.e('Sent')).values():
            if s['name'] == 'w_creators:promptlab:report' and s['args'][1] == kind:
                out.append(s['args'][2])
        return out

    def test_a_normal_player_sees_nothing(self):
        self.rt.run("OpenReply = { ok = false }")
        self.command()
        self.assertEqual(self.e('#Texts'), 0)
        self.assertEqual(self.e('#Notes'), 0)
        self.assertFalse(self.e('Shown'))

    def test_a_full_run_answers_skips_and_reports(self):
        self.command()
        self.assertTrue(self.e('Shown'))
        self.press('J')                                          # test 01 starts at the horse
        self.rt.run("JustPressed[GetHashKey('INPUT_ENTER')] = true; Mounted = true")
        self.rt.g.tick(1)
        self.rt.run("JustPressed = {}; Mounted = false")
        self.rt.g.tick(13000)                                    # the run ends by itself
        self.assertEqual(self.e("Labels.J"), 'نعم')
        self.press('J')                                          # yes
        for _ in range(22):
            self.press('Z')                                      # skip 02..23
        self.rt.g.tick(1500)                                     # the summary ignores keys for 1.5 s
        self.press('J')                                          # close the summary
        self.assertEqual(list(self.rt.py(self.e('Warns')).values()) if self.e('#Warns') else [], [])
        results = self.sent('result')
        self.assertEqual([r['answer'] for r in results], ['y'] + ['s'] * 22)
        first = results[0]
        self.assertEqual((first['id'], first['hide'], first['tries']), ('01', 'type:12', 1))
        attempt = first['attempts'][1]
        self.assertGreaterEqual(attempt['k']['ENTER'], 1)              # the fake clock runs two frames per tick
        self.assertIn('mount', attempt)
        self.assertGreater(attempt['pf'], 0)
        final = self.sent('final')
        self.assertEqual(len(final), 1)
        self.assertEqual((final[0]['reason'], final[0]['n'], len(final[0]['results'])), ('done', 23, 23))
        self.assertTrue(any('PL-1234' in t for t in self.rt.py(self.e('Texts')).values()))
        self.assertTrue(self.e('Deleted') and self.e('Released') and self.e('TextHidden'))
        disabled12 = [c for c in self.rt.py(self.e('Invoked')).values()
                      if c['hash'] == s64(0xFC094EF26DD153FA) and c['args'][1] == 12]
        self.assertGreater(len(disabled12), 0)

    def test_the_per_ped_switch_is_put_back(self):
        self.command('4')                                         # start at test 04 (false), then 05 (true)
        self.press('J')
        self.rt.g.tick(600)
        self.rt.g.tick(16000)
        self.assertTrue(self.e('Enabled'))                        # false switched it off, the lab put it back
        self.press('G')                                           # "no" (whatever he saw)
        self.press('J')
        self.rt.g.tick(600)
        self.rt.g.tick(16000)
        self.press('J')                                           # "yes": the readback said nothing moved
        self.assertTrue(self.e('Enabled'))                        # a working readback is trusted: left on
        r4, r5 = self.sent('result')[:2]
        self.assertEqual(r4['attempts'][1]['rb'], {'r0': True, 'r1': False, 'r2': True})
        self.assertEqual(r5['hide'], 'ped:35/1/true')
        self.press('J')                                           # test 06 starts ...
        self.press('BACKSPACE')                                   # ... and held BACKSPACE ends the lab
        final = self.sent('final')[0]
        self.assertEqual(final['reason'], 'stopped')
        self.assertEqual([r['id'] for r in final['results'].values()], ['04', '05', '06'])
        self.assertEqual(final['results'][3]['answer'], 'x')          # ran, not answered: kept

    def test_the_resource_stop_puts_everything_back(self):
        self.command('4')
        self.press('J')
        self.rt.g.tick(600)
        self.assertFalse(self.e('Enabled'))
        self.rt.run("for _, fn in ipairs(Events.handlers.onResourceStop) do fn('w_creators') end")
        self.assertTrue(self.e('Enabled'))
        self.assertTrue(self.e('Deleted'))


def s64(h):
    return h - (1 << 64) if h >= (1 << 63) else h


class PromptLabStaticTests(unittest.TestCase):
    def test_every_native_is_the_verified_hash_and_documented(self):
        code = read(RESOURCE / 'client' / 'natives' / 'promptlab.lua')
        used = {m.group(1): int(m.group(2), 16) for m in re.finditer(r"call\('(\w+)', (0x[0-9A-Fa-f]{16})", code)}
        self.assertEqual(used, VERIFIED)
        for h in used.values():
            self.assertIn('-- hash: 0x%016X' % h, code)

    def test_the_lab_is_three_manifest_lines(self):
        m = manifest()
        client, server = m['client_scripts'], m['server_scripts']
        self.assertIn('client/natives/promptlab.lua', client)
        self.assertLess(client.index('client/natives/promptlab.lua'), client.index('client/core/locale.lua'))
        self.assertEqual(client[-2:], ['client/lab/promptlab.lua', 'client/api.lua'])
        self.assertEqual(server[-2:], ['server/lab/promptlab.lua', 'server/api.lua'])
        self.assertEqual(sum('promptlab' in p for p in client + server), 3)

    def test_the_report_file_is_not_tracked(self):
        self.assertIn('/promptlab.jsonl', read(RESOURCE / '.gitignore'))


if __name__ == '__main__':
    unittest.main()
