"""Shared runtime for the character selector / creator / cutscene tests (test_client_characters_*.py).

make_characters() returns a harness Runtime with the client infrastructure (test_client_infra_support),
the real editor (tree, editor, panel) and client/characters/selector.lua, client/creator/creator.lua,
client/creator/cutscene.lua loaded on top of these extra fakes:

  NuiMessages            every SendNUIMessage payload
  PromptGroups           every w.prompt.createGroup group ({title, prompts[key] = {label, hold},
                         visible[key], displayed, deleted}); press(key) makes the next
                         isCompleted(key) of any live group answer true once
  Dialogs / AlertAnswer / InputAnswer   w.alertDialog / w.inputDialog
  Notes                  every client w.notify payload
  Log / count / indexOf  from test_client_infra_support (plain natives, callbacks, entities)

The boot thread of the selector runs when the file loads: by default the player ped is placed away
from the origin, so the boot takes the "resource restart" path (no playerSpawned wait) and opens the
selection at once. boot=False keeps the ped at the origin so the boot thread waits.
This module has no tests of its own.
"""
from test_client_infra_support import make_client

EXTRA_STUBS = r'''
local function record(op, ...) Log[#Log + 1] = { op = op, args = table.pack(...) } end
Citizen.ResultAsLong = Citizen.ResultAsLong or function() return nil end

NuiMessages, NuiCallbacks = {}, {}
function SendNUIMessage(m) NuiMessages[#NuiMessages + 1] = m end
function RegisterNUICallback(name, fn) NuiCallbacks[name] = fn end
function lastNui(kind)
    for i = #NuiMessages, 1, -1 do
        if NuiMessages[i].type == kind then return NuiMessages[i] end
    end
end

PromptGroups, Pressed = {}, {}
function press(key) Pressed[key] = true end
w.prompt = { createGroup = function(title, position)
    local g = { title = title, position = position, prompts = {}, visible = {}, displayed = false, deleted = false }
    function g.addPrompt(key, label, hold) g.prompts[key] = { label = label, hold = hold } end
    function g.setLabel(key, label) if g.prompts[key] then g.prompts[key].label = label end end
    function g.setVisible(key, visible) g.visible[key] = visible end
    function g.setTitle(t) g.title = t end
    function g.display() g.displayed = true end
    function g.hide() g.displayed = false end
    function g.delete() g.deleted = true end
    function g.isCompleted(key)
        if g.deleted or not g.prompts[key] or not Pressed[key] then return false end
        Pressed[key] = nil
        return true
    end
    PromptGroups[#PromptGroups + 1] = g
    return g
end }
function liveGroups()
    local n = 0
    for _, g in ipairs(PromptGroups) do if not g.deleted then n = n + 1 end end
    return n
end
function liveGroup()
    for i = #PromptGroups, 1, -1 do if not PromptGroups[i].deleted then return PromptGroups[i] end end
end

Dialogs, AlertAnswer, InputAnswer = {}, 'confirm', nil
w.alertDialog = function(data) Dialogs[#Dialogs + 1] = { kind = 'alert', data = data } return AlertAnswer end
w.inputDialog = function(heading, rows, options)
    Dialogs[#Dialogs + 1] = { kind = 'input', heading = heading, rows = rows, options = options }
    return InputAnswer
end

Notes = {}
w.notify = function(data) Notes[#Notes + 1] = data end
function noted(key)
    for _, n in ipairs(Notes) do if n.description == key then return true end end
    return false
end

function IsEntityDead(e) return Peds[e] ~= nil and Peds[e].dead == true end
function NetworkSetEntityOnlyExistsForParticipants(e, b)
    record('NetworkSetEntityOnlyExistsForParticipants', e, b)
    if Peds[e] then Peds[e].participantsOnly = b end
end
function PlaySoundFrontend(...) record('PlaySoundFrontend', ...) end
function SetEntityCollision(e, a, b) record('SetEntityCollision', e, a, b) end

-- cutscene natives
Vehicles = {}
function IsModelValid(hash) return InvalidModels == nil or not InvalidModels[hash] end
for _, name in ipairs({ 'TriggerMusicEvent', 'SetCinematicModeActive', 'SetVehicleOnGroundProperly',
    'TaskVehicleDriveToCoord', 'TaskLeaveVehicle', 'RemovePedFromGroup', 'SetPedAsGroupMember',
    'SetRelationshipBetweenGroups', 'SetEntityNoCollisionEntity', 'SetEntityCanBeDamaged' }) do
    _ENV[name] = function(...) record(name, ...) end
end
function GetPedGroupIndex() return 7 end
function GetPedRelationshipGroupHash() return 99 end
function SetPedIntoVehicle(ped, vehicle, seat)
    record('SetPedIntoVehicle', ped, vehicle, seat)
    if Peds[ped] then Peds[ped].vehicle = vehicle end
end
function IsPedInVehicle(ped, vehicle) return Peds[ped] ~= nil and Peds[ped].vehicle == vehicle end
function IsPedInAnyVehicle(ped) return Peds[ped] ~= nil and Peds[ped].vehicle ~= nil end

-- a recording player restore (tests replace it to fail)
RestoreCalls = {}
local realRestorePlayer = Appearance.RestorePlayer
Appearance.RestorePlayer = function(app, opts)
    record('RestorePlayer', app)
    RestoreCalls[#RestoreCalls + 1] = app
    if RestoreFails then return false, 'NOT_READY' end
    return realRestorePlayer(app, opts)
end
function called(name)
    local n = 0
    for _, e in ipairs(Log) do if e.op == 'callback:' .. name then n = n + 1 end end
    return n
end
function callArgs(name, nth)
    local n = 0
    for _, e in ipairs(Log) do
        if e.op == 'callback:' .. name then
            n = n + 1
            if n == (nth or 1) then return e.args end
        end
    end
end
'''

CARDS = r'''
function card(charid, sex, name, extra)
    local c = { charid = charid, name = name or ('Name ' .. charid), firstname = 'Name', lastname = charid,
                dob = '1870-01-01', age = 29, sex = sex, lastLocation = nil, job = 'unemployed', cash = 10,
                bank = 20, gold = 1, appearance = AppearanceSchema.default(sex) }
    for k, v in pairs(extra or {}) do c[k] = v end
    return c
end
function listResult(cards, slots, canCreate, deletion)
    return { ok = true, code = 'OK', data = { characters = cards, slots = slots or 3,
        canCreate = canCreate ~= false, deletion = deletion or { enabled = true, holdTime = 5000, typed = false } } }
end
'''

EDITOR_AND_DOMAINS = (
    'client/editor/tree.lua', 'client/editor/editor.lua', 'client/editor/panel.lua',
    'client/characters/selector.lua', 'client/creator/creator.lua', 'client/creator/cutscene.lua',
)


def make_characters(boot=True, setup=''):
    """The runtime with the selector / creator / cutscene loaded. `setup` runs before they load
    (e.g. CallbackResults for the boot selection)."""
    rt = make_client()
    rt.run(EXTRA_STUBS)
    rt.run(CARDS)
    if boot:
        rt.run('Peds[MyPed].coords = vector3(100.0, 100.0, 100.0)')
    if setup:
        rt.run(setup)
    rt.load(*EDITOR_AND_DOMAINS)
    rt.run('tick(0)')
    return rt


def settle(rt, ms=0, rounds=20, barrier=True):
    """Advance the fake clock and resume the threads a few times (actions run in their own threads).
    barrier=True first moves the clock past the selection's input barrier (500 ms after the prompts
    appear), so a pending press() is handled."""
    if barrier:
        rt.run('tick(600)')
    for _ in range(rounds):
        rt.run('tick(%d)' % ms)
