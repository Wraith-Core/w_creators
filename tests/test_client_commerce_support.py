"""Shared runtime for the service locations / clothing store / wardrobe client tests
(test_client_commerce_*.py).

make_commerce() returns a harness Runtime with the client infrastructure (test_client_infra_support),
the real editor (tree, editor, panel) and client/services/locations.lua, client/clothing/store.lua and
client/wardrobe/wardrobe.lua loaded on top of these extra fakes:

  Walkups            every w.prompt.at record ({opts, removed, title, labels})
  BlipsMade          every w.blip.create call ({coords, name, sprite, removed, handle})
  Notes / noted(key) every client w.notify payload
  Exported           exports(name, fn)
  RestoreCalls       every Appearance.RestorePlayer(app) (recorded; RestoreFails makes it fail)
  RenderCalls        every Appearance.RestoreCharacter(ped, app) (the real pipeline still runs)
  CallbackResults    [name] = Result | function(delay, ...) -> Result  (from test_client_infra_support)
  callbacks(name)    the argument lists of every w.callback.await(name, ...)

The player starts at PLAYER_START with the default male appearance as the active character.
This module has no tests of its own.
"""
from test_client_infra_support import make_client

PLAYER_START = (100.0, 200.0, 50.0)

EXTRA_STUBS = r'''
local function record(op, ...) Log[#Log + 1] = { op = op, args = table.pack(...) } end
Citizen.ResultAsLong = Citizen.ResultAsLong or function() return nil end

NuiMessages, NuiCallbacks = {}, {}
function SendNUIMessage(m) NuiMessages[#NuiMessages + 1] = m end
function RegisterNUICallback(name, fn) NuiCallbacks[name] = fn end

Walkups = {}
w.prompt = {
    at = function(opts)
        local rec = { opts = opts, removed = false, title = opts.title, labels = {} }
        for _, row in ipairs(opts.prompts or {}) do rec.labels[row.key] = row.label end
        function rec.remove() rec.removed = true end
        function rec.setTitle(t) rec.title = t end
        function rec.setLabel(key, label) rec.labels[key] = label end
        rec.enabled = {}
        function rec.setEnabled(key, on) rec.enabled[key] = on end
        Walkups[#Walkups + 1] = rec
        return rec
    end,
}
function liveWalkups()
    local out = {}
    for _, r in ipairs(Walkups) do if not r.removed then out[#out + 1] = r end end
    return out
end

BlipsMade, NextBlip = {}, 9000
w.blip = {
    create = function(coords, name, sprite)
        NextBlip = NextBlip + 1
        BlipsMade[#BlipsMade + 1] = { coords = coords, name = name, sprite = sprite, removed = false, handle = NextBlip }
        return NextBlip
    end,
    setName = function(handle, name)
        for _, b in ipairs(BlipsMade) do if b.handle == handle then b.name = name end end
        return true
    end,
    remove = function(handle)
        for _, b in ipairs(BlipsMade) do if b.handle == handle then b.removed = true end end
        return true
    end,
}

Notes = {}
w.notify = function(data) Notes[#Notes + 1] = data end
function noted(key)
    for _, n in ipairs(Notes) do if n.description == key then return true end end
    return false
end

Exported = {}
getmetatable(exports).__call = function(_, name, fn) Exported[name] = fn end

function IsEntityDead(e) return Peds[e] ~= nil and Peds[e].dead == true end
function SetEntityCanBeDamaged(e, b) record('SetEntityCanBeDamaged', e, b) if Peds[e] then Peds[e].damageable = b end end
function SetBlockingOfNonTemporaryEvents(e, b) record('SetBlockingOfNonTemporaryEvents', e, b) if Peds[e] then Peds[e].blocking = b end end
function GetClockHours() return GameHour or 12 end

RestoreCalls = {}
Appearance.RestorePlayer = function(app, opts)
    record('RestorePlayer', app)
    RestoreCalls[#RestoreCalls + 1] = app
    if RestoreFails then return false, 'NOT_READY' end
    return true
end
RenderCalls = {}
local realRestoreCharacter = Appearance.RestoreCharacter
Appearance.RestoreCharacter = function(ped, app, opts)
    record('RestoreCharacter', ped, app)
    RenderCalls[#RenderCalls + 1] = app
    return realRestoreCharacter(ped, app, opts)
end

function callbacks(name)
    local out = {}
    for _, e in ipairs(Log) do if e.op == 'callback:' .. name then out[#out + 1] = e.args end end
    return out
end
function called(name) return #callbacks(name) end

WCState.setCharacter('c1', 'male')
WCState.set(AppearanceSchema.default('male'))

-- server answers
function storeData(extra)
    local d = { token = 'stok', appearance = AppearanceSchema.default('male'), owned = {},
                prices = { hats = 5, boots = 8 }, tintPrice = 2.5, storeProfile = 'general',
                pricingProfile = 'standard', preview = { x = 10.0, y = 20.0, z = 30.0, w = 90.0, heading = 90.0 },
                expiresIn = 600 }
    for k, v in pairs(extra or {}) do d[k] = v end
    return { ok = true, code = 'OK', data = d }
end
function wardrobeData(extra)
    local d = { token = 'wtok', appearance = AppearanceSchema.default('male'), owned = {},
                outfits = { { id = 5, name = 'Work', data = { equipped = {}, states = {} } } },
                maxOutfits = 10, outfitsEnabled = true, remote = false, expiresIn = 600 }
    for k, v in pairs(extra or {}) do d[k] = v end
    return { ok = true, code = 'OK', data = d }
end
function fail(code, data) return WCResult.fail(code, data) end
function okResult(data) return WCResult.ok(data) end

--- Make the open editor dirty (a real change of the working appearance).
function makeDirty(height)
    local s = WCEditor.session()
    s.working.body.height = height or 1.05
    s.revision = s.revision + 1
end
function save() local s = WCEditor.session() return WCEditor.action({ id = s.id, op = 'save' }) end
function cancel() local s = WCEditor.session() return WCEditor.action({ id = s.id, op = 'cancel' }) end
function playerAt() local c = Peds[MyPed].coords return { c.x, c.y, c.z } end
'''

DOMAINS = (
    'client/editor/tree.lua', 'client/editor/editor.lua', 'client/editor/panel.lua',
    'client/services/locations.lua', 'client/clothing/store.lua', 'client/wardrobe/wardrobe.lua',
)


def make_commerce(setup=''):
    """The runtime with the service modules loaded. `setup` runs before they load."""
    rt = make_client()
    rt.run(EXTRA_STUBS)
    rt.run('Peds[MyPed].coords = vector3(%r, %r, %r)' % PLAYER_START)
    if setup:
        rt.run(setup)
    rt.load(*DOMAINS)
    rt.run('tick(0)')
    return rt


def settle(rt, ms=300, rounds=10):
    """Advance the fake clock and resume the waiting threads a few times."""
    for _ in range(rounds):
        rt.run('tick(%d)' % ms)
