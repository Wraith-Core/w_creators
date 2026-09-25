"""The long hair's bald crown (the owner's screenshot: bandana up, no hat, long hair without its top).

The long MP hair styles have *_TUCKED wearable states in the game's shop item data, and the game
moves an item to one through the shop-item triggers of other garments (a raised bandana tucks the
beard; the tucked long hair, drawn without its crown, is meant for under a hat). Nothing moved the
hair back: taking a garment off, the game knocking the hat off or lowering the bandana does not undo
a trigger, w_lib re-applies only clothing states (and its delayed re-apply sets
the raised bandana again, which fires the trigger again), and the w_creators paths never touched the
hair. Only a full render re-applied the hair from scratch, so the crown came and went.

These tests run the REAL w_lib component module (../w_lib/modules/component) and the REAL pipeline,
clothing state controller and sync on a fake metaped engine (tests/lua/metaped_engine.lua) that
models the triggers, and replay every sequence the owner can reach: /hat and the wheel, the bandana,
a relog with the bandana up, the store's diff, the creator's hide-clothes toggle, a remote player and
a hat the game knocks off by itself (no path of ours runs: the hat watch of WCClothing). Which
garment tucks the hair, and whether the game resolves a trigger on the state change or on the next
commit, are not known: both triggers and both timings are replayed.
Skipped when the w_lib checkout is not next to w_creators.
"""
import re
import unittest

from harness import TESTS, W_LIB, read
from test_client_states_support import make_states_client

COMPONENT = W_LIB / 'modules' / 'component'
W_LIB_FILES = ('table/shared.lua', 'timeout/shared.lua', 'waiter/shared.lua',
               'component/g_shared.lua', 'component/g_client.lua')
HAVE_W_LIB = all((W_LIB / 'modules' / f).exists() for f in W_LIB_FILES)


def joaat(s):
    h = 0
    for c in s.lower().encode():
        h = (h + c) & 0xFFFFFFFF
        h = (h + (h << 10)) & 0xFFFFFFFF
        h ^= h >> 6
    h = (h + (h << 3)) & 0xFFFFFFFF
    h ^= h >> 11
    h = (h + (h << 15)) & 0xFFFFFFFF
    return h - (1 << 32) if h >= 1 << 31 else h


def plain_lua(code):
    """CfxLua -> Lua 5.4: backtick hashes become their (signed) value, `x += y` becomes x = x + y."""
    code = re.sub(r'`([A-Za-z0-9_]+)`', lambda m: str(joaat(m.group(1))), code)
    return re.sub(r'^(\s*)([\w.\[\]"]+)\s*\+=\s*(.+)$', r'\1\2 = \2 + \3', code, flags=re.M)


# The CfxLua runtime pieces w_lib's modules use and the client stubs do not provide.
PRELUDE = r'''
w.require = function() end
w.createModule = w.createModule or function(name)
    if not rawget(w, name) then rawset(w, name, {}) end
    return rawget(w, name)
end
w.cache = w.cache or {}
CreateThreadNow = CreateThreadNow or CreateThread
dprint = dprint or function() end
eprint = eprint or function() end
function GetValue(value, default)
    if default == nil then return value end
    if default == false then return value or false end
    return value == nil and default or value
end
function math.toSigned(n) n = math.tointeger(n) if n and n >= 0x80000000 then return n - 0x100000000 end return n end
function GetHashFromString(value)
    if type(value) == 'string' then
        local number = tonumber(value)
        if number then return math.toSigned(number) end
        return joaat(value)
    end
    return value
end
table.clone = table.clone or function(t) local out = {} for k, v in pairs(t) do out[k] = v end return out end
table.type = table.type or function(t)
    if type(t) ~= 'table' then return nil end
    local n, c = #t, 0
    for _ in pairs(t) do c = c + 1 end
    if c == 0 then return 'empty' end
    if c == n then return 'array' end
    if n == 0 then return 'hash' end
    return 'mixed'
end
'''

WORLD = r'''
LONG_HAIR = joaat('CLOTHING_ITEM_M_HAIR_023_JET_BLACK')     -- long, centre parted: has BASE_TUCKED
SHORT_HAIR = joaat('CLOTHING_ITEM_M_HAIR_001_JET_BLACK')    -- short: BASE / POMADE only
BEARD = joaat('CLOTHING_ITEM_M_BEARD_009_JET_BLACK')
HAIR_STATES = { 'BASE', 'BASE_TUCKED', 'POMADE', 'POMADE_TUCKED' }
local A = AppearanceSchema.default('male')
Engine.item(A.body.upper, 'BODIES_UPPER'); Engine.item(A.body.lower, 'BODIES_LOWER')
Engine.item(A.head.head, 'heads'); Engine.item(A.head.eyes, 'eyes'); Engine.item(A.head.teeth, 'teeth')
Engine.item(LONG_HAIR, 'hair', HAIR_STATES)
Engine.item(SHORT_HAIR, 'hair', { 'BASE', 'POMADE' })
Engine.item(BEARD, 'beards_complete', { 'BASE', 'MASK_A', 'TUCKED' })
Engine.item(HAT, 'hats'); Engine.item(SHIRT, 'shirts_full', { 'BASE', 'CLOSED_COLLAR_ROLLED_SLEEVE' })
Engine.item(NECK, 'neckwear', { 'BASE', 'MASK_UP', 'MASK_UP_XL' })
Engine.item(BOOTS, 'boots', { 'BASE', 'UNDER_PANTS' }); Engine.item(PANTS, 'pants'); Engine.item(COAT, 'coats')
WCState.appearance.hair.style = LONG_HAIR
WCState.appearance.hair.facial = BEARD
function hairOf(ped) return Engine.stateName(ped or PlayerPedId(), 'hair', HAIR_STATES) end
function hatOn(ped) return Engine.has(ped or PlayerPedId(), 'hats') end
function bandanaTrigger()
    Engine.onState('neckwear', 'MASK_UP', { { category = 'hair', state = 'BASE_TUCKED' },
                                            { category = 'beards_complete', state = 'TUCKED' } })
end
function hatTrigger() Engine.onAdd('hats', { { category = 'hair', state = 'BASE_TUCKED' } }) end
'''


@unittest.skipUnless(HAVE_W_LIB, 'needs the w_lib checkout next to w_creators')
class HairCrownTests(unittest.TestCase):
    def build(self, trigger='bandana', deferred=False):
        rt = make_states_client()
        rt.run(PRELUDE)
        rt.run(read(TESTS / 'lua' / 'metaped_engine.lua'))
        keep = rt.eval('w.component.getFullPedComponentList')
        for rel in W_LIB_FILES:
            rt.lua.execute(plain_lua(read(W_LIB / 'modules' / rel)), name='@w_lib/modules/' + rel)
        rt.g.w.component.getFullPedComponentList = keep
        # the shop tint list is a 1 MB data file w.file loads in game: no dye data here
        rt.run('w.component.getShopItemTint = function() return nil end')
        rt.run(WORLD)
        rt.run({'bandana': 'bandanaTrigger()', 'hat': 'hatTrigger()'}[trigger])
        if deferred:
            rt.run('Engine.deferred = true')   # the trigger resolves on the next commit
        self.rt = rt
        return rt

    def settle(self, ms=2000):
        self.rt.run('tick(%d)' % ms)   # w_lib's delayed re-apply and every waiting thread run

    def perform(self, group, value):
        self.rt.run("performAsync('%s', '%s', { notify = false })" % (group, value))
        for _ in range(60):
            self.rt.run('tick(50)')
            if self.rt.eval('Done'):
                break
        result = self.rt.eval('Result')
        self.assertTrue(result and result['ok'], '%s=%s refused' % (group, value))

    def relog(self, **states):
        for key, value in states.items():
            self.rt.run("WCState.appearance.clothing.states.%s = %s" % (key, 'nil' if value is None else repr(value)))
        self.rt.run('Appearance.RestorePlayer(WCState.appearance)')

    def assertCrown(self, where):
        self.settle()
        hair = self.rt.eval('hairOf()')
        if not self.rt.eval('hatOn()'):
            self.assertEqual(hair, 'BASE', '%s: the long hair is left %s without a hat (bald crown)' % (where, hair))
        return hair

    # -- the owner's sequences ------------------------------------------------------------------
    def test_bandana_up_and_down_without_a_hat_keeps_the_crown(self):
        self.build('bandana')
        self.relog(hat='off')
        self.assertCrown('relog without a hat')
        self.perform('bandana', 'up')
        self.assertCrown('bandana up (the screenshot)')
        self.perform('bandana', 'down')
        self.assertCrown('bandana down')

    def test_hat_off_after_the_bandana_tucked_the_hair_under_it(self):
        self.build('bandana')
        self.relog(hat='on')
        self.perform('bandana', 'up')
        # under the hat the game's tucked hair is left alone: the crown is hidden
        self.assertEqual(self.assertCrown('bandana up under the hat'), 'BASE_TUCKED')
        self.perform('hat', 'off')        # /hat, the wheel (SetClothingState) and the keybind
        self.assertCrown('hat off while the bandana is up')

    def test_hat_that_tucks_the_hair_comes_off_with_the_crown(self):
        self.build('hat')
        self.relog(hat='on')
        self.assertEqual(self.assertCrown('relog with the hat on'), 'BASE_TUCKED')
        self.perform('hat', 'off')
        self.assertCrown('/hat off')
        self.perform('hat', 'on')
        self.perform('hat', 'off')
        self.assertCrown('/hat on then off again')

    def test_relog_with_the_bandana_still_up(self):
        # the raised bandana is a runtime state the server re-sends: the full render raises it again
        self.build('bandana')
        self.relog(hat='off', bandana='up')
        self.assertCrown('relog / respawn with the bandana up')

    def test_the_render_hands_the_ped_back_with_the_crown(self):
        # checked right when RestoreCharacter returns (the spawn fades in then), not after w_lib's
        # delayed re-apply
        self.build('bandana')
        self.rt.run("WCState.appearance.clothing.states = { hat = 'off', bandana = 'up' }")
        self.rt.run('R_OK, R_ERR = Appearance.RestoreCharacter(PlayerPedId(), WCState.appearance)')
        self.assertTrue(self.rt.eval('R_OK'), self.rt.eval('R_ERR'))
        self.assertTrue(self.rt.eval("Engine.stateName(PlayerPedId(), 'neckwear', { 'MASK_UP' }) == 'MASK_UP'"))
        self.assertEqual(self.rt.eval('hairOf()'), 'BASE')

    def test_store_and_creator_previews(self):
        self.build('hat')
        self.rt.run('''
            local ped = PlayerPedId()
            ON = WCUtil.copy(WCState.appearance); ON.clothing.states = { hat = 'on' }
            Appearance.RestoreCharacter(ped, ON)
            OFF = WCUtil.copy(ON); OFF.clothing.equipped.hats = nil
            Appearance.ApplyDiff(ped, ON, OFF)
        ''')
        self.assertCrown('the store takes the hat off (ApplyDiff)')
        self.build('bandana')
        self.rt.run('''
            local ped = PlayerPedId()
            WORKING = WCUtil.copy(WCState.appearance); WORKING.clothing.states = { hat = 'off', bandana = 'up' }
            Appearance.RestoreCharacter(ped, WORKING)
            HIDDEN = WCEditor.view({ hidden = true }, WORKING)
            Appearance.ApplyDiff(ped, WORKING, HIDDEN)
            Appearance.ApplyDiff(ped, HIDDEN, WORKING)
        ''')
        self.assertCrown("the creator's hide clothes, then show them again")

    def test_remote_player_bandana(self):
        self.build('bandana')
        rt = self.rt
        rt.run('''
            REMOTE = makePed('mp_male')
            RemotePlayers[9] = REMOTE
            RAPP = WCUtil.copy(WCState.appearance); RAPP.clothing.states = { hat = 'off' }
            Appearance.Sync.set(9, RAPP)
            Appearance.Sync.check(9)
        ''')
        self.settle()
        rt.run("Appearance.Sync.state(9, 'bandana', 'up')")
        self.settle()
        self.assertFalse(rt.eval('hatOn(REMOTE)'))
        self.assertEqual(rt.eval('hairOf(REMOTE)'), 'BASE')

    # -- the rule itself ------------------------------------------------------------------------
    def test_w_lib_delayed_reapply_fires_the_trigger_again_and_restores_the_hair(self):
        # the root in w_lib: reapplyComponentStats sets the remembered bandana state again after
        # every component change, which tucks the hair again; the same pass now puts it back
        self.build('bandana')
        self.relog(hat='off')
        self.settle()
        self.rt.run("Appearance.SettleHair = function() return false end")   # w_lib alone
        self.rt.run('Engine.calls = {}')
        self.perform('bandana', 'up')
        self.settle()
        calls = [self.rt.eval('Engine.calls[%d]' % i) for i in range(1, self.rt.eval('#Engine.calls') + 1)]
        self.assertGreaterEqual(sum(1 for c in calls if c == 'trigger hair BASE_TUCKED'), 2, calls)
        self.assertEqual(self.rt.eval('hairOf()'), 'BASE')

    def test_a_chosen_pomade_is_what_comes_back(self):
        self.build('bandana')
        self.relog(hat='off')
        self.settle()
        self.rt.run("w.component.setWearableState(PlayerPedId(), 'hair', LONG_HAIR, 'pomade')")
        self.settle()
        self.perform('bandana', 'up')
        self.settle()
        self.assertEqual(self.rt.eval('hairOf()'), 'POMADE')

    def test_short_hair_is_never_touched(self):
        self.build('bandana')
        self.rt.run('WCState.appearance.hair.style = SHORT_HAIR')
        self.relog(hat='off')
        self.settle()
        self.rt.run('Engine.calls = {}')
        self.perform('bandana', 'up')
        self.settle()
        short = str(self.rt.eval('Engine.u32(SHORT_HAIR)'))
        calls = [self.rt.eval('Engine.calls[%d]' % i) for i in range(1, self.rt.eval('#Engine.calls') + 1)]
        self.assertFalse([c for c in calls if c.startswith('state ' + short)], calls)
        self.assertEqual(self.rt.eval('Engine.stateName(PlayerPedId(), "hair", { "BASE", "POMADE" })'), 'BASE')

    # w_lib's delayed re-apply: the check before its commit, and the re-check after it
    CALL = '\n      reapplyHairState(ped)\n'
    RECHECK = '\n      if reapplyHairState(ped, true) then refreshPed(ped) end\n'

    def reload_w_lib_without(self, *calls):
        source = plain_lua(read(COMPONENT / 'g_client.lua'))
        for call in calls:
            self.assertEqual(source.count(call), 1, "w_lib's delayed re-apply no longer has %r" % call)
            source = source.replace(call, '\n')
        self.rt.lua.execute(source, name='@w_lib/modules/component/g_client.lua')
        self.rt.run('w.component.getShopItemTint = function() return nil end')

    def test_without_the_fix_the_crown_goes(self):
        # the regression guard: with the hair rule taken out of every place, the owner's sequence
        # leaves the long hair tucked without a hat, as in the screenshot
        self.build('bandana')
        self.reload_w_lib_without(self.CALL, self.RECHECK)
        self.rt.run('w.component.restoreHairState = nil')
        self.rt.run('Appearance.SettleHair = function() return false end')
        self.relog(hat='off')
        self.settle()
        self.perform('bandana', 'up')
        self.perform('bandana', 'down')
        self.settle()
        self.assertEqual(self.rt.eval('hairOf()'), 'BASE_TUCKED')

    # -- a trigger that resolves on the commit (UPDATE_PED_VARIATION), not on the state change ---
    def test_deferred_trigger_bandana_up_and_down_keeps_the_crown(self):
        self.build('bandana', deferred=True)
        self.relog(hat='off')
        self.assertCrown('relog without a hat (deferred trigger)')
        self.perform('bandana', 'up')
        self.assertCrown('bandana up (deferred trigger)')
        self.perform('bandana', 'down')
        self.assertCrown('bandana down (deferred trigger)')

    def test_deferred_trigger_hat_off_after_the_bandana(self):
        self.build('bandana', deferred=True)
        self.relog(hat='on')
        self.perform('bandana', 'up')
        self.assertEqual(self.assertCrown('bandana up under the hat (deferred trigger)'), 'BASE_TUCKED')
        self.perform('hat', 'off')
        self.assertCrown('hat off while the bandana is up (deferred trigger)')

    def test_deferred_trigger_needs_the_recheck_after_the_commit(self):
        # the guard of the re-check: w_lib's delayed pass sets the raised bandana again and, with a
        # deferred trigger, its own commit tucks the hair after the check before it
        self.build('bandana', deferred=True)
        self.reload_w_lib_without(self.RECHECK)
        self.relog(hat='off')
        self.settle()
        self.perform('bandana', 'up')
        self.settle()
        self.assertEqual(self.rt.eval('hairOf()'), 'BASE_TUCKED')

    # -- a hat the game takes off by itself -----------------------------------------------------
    def knock_off_hat(self):
        # the game's knock-off (a punch, a fall, a shot): the hat tag goes, no w_lib or w_creators
        # path runs, and the saved appearance still says the hat is on
        self.rt.run("RemoveTagFromMetaPed(PlayerPedId(), 'hats')")

    def test_hat_knocked_off_by_the_game_gets_the_crown_back(self):
        self.build('hat')
        self.relog(hat='on')
        self.assertEqual(self.assertCrown('relog with the hat on'), 'BASE_TUCKED')
        self.knock_off_hat()
        self.assertCrown('the hat knocked off by the game')
        self.assertEqual(self.rt.eval("WCClothingStates.current(WCState.appearance, 'hat')"), 'on')

    def test_hat_knocked_off_under_a_raised_bandana(self):
        self.build('bandana')
        self.relog(hat='on')
        self.perform('bandana', 'up')
        self.assertEqual(self.assertCrown('bandana up under the hat'), 'BASE_TUCKED')
        self.knock_off_hat()
        self.assertCrown('the hat knocked off while the bandana is up (the screenshot)')

    def test_hat_knocked_off_is_left_bald_without_the_watch(self):
        # the guard of the hat watch: nothing else runs when the game takes the hat
        self.build('hat')
        self.relog(hat='on')
        self.settle()
        self.rt.run('w.component.restoreHairState = nil')
        self.knock_off_hat()
        self.settle()
        self.assertFalse(self.rt.eval('hatOn()'))
        self.assertEqual(self.rt.eval('hairOf()'), 'BASE_TUCKED')

    def test_the_hat_watch_waits_for_a_flow(self):
        # a flow of this resource (the editor, a store visit, a render) owns the ped and settles the
        # hair itself: the watch acts only once it has ended
        self.build('hat')
        self.relog(hat='on')
        self.settle()
        self.rt.run("WCClothing_busy = WCClothing.busy; WCClothing.busy = function() return true end")
        self.knock_off_hat()
        self.settle()
        self.assertEqual(self.rt.eval('hairOf()'), 'BASE_TUCKED')
        self.rt.run('WCClothing.busy = WCClothing_busy')
        self.assertCrown('once the flow has ended')


if __name__ == '__main__':
    unittest.main()
