"""Shared client stubs for the client infrastructure tests (test_client_infra_*.py).

make_client() returns a harness Runtime with the shared layer, the native wrappers and the client
infrastructure (core, appearance, camera, scene) loaded on top of a recording fake of the RedM
client natives and of w_lib's w.component / w.pedTexture / w.entity / w.raycast.

Everything observable is appended to the Lua list `Log` as {op = name, args = {...}}:
  natives through Citizen.InvokeNative are named by NATIVE_NAMES (preset, preRefresh,
  updateVariation, setExpression), w_lib calls are 'component.<fn>' / 'pedTexture.<fn>',
  and plain named natives are logged by their own name.
This module has no tests of its own.
"""
from harness import Runtime, manifest_scripts

CLIENT_STUBS = r'''
Log = {}
local function rec(op, ...) Log[#Log + 1] = { op = op, args = table.pack(...) } end
function ops(prefix)
    local out = {}
    for _, e in ipairs(Log) do
        if not prefix or e.op:sub(1, #prefix) == prefix then out[#out + 1] = e.op end
    end
    return out
end
function count(op)
    local n = 0
    for _, e in ipairs(Log) do if e.op == op then n = n + 1 end end
    return n
end
function indexOf(op, from)
    for i = from or 1, #Log do if Log[i].op == op then return i end end
    return nil
end
function clearLog() Log = {} end

-- entities -------------------------------------------------------------------------------
Peds = {}
NextHandle = 500
function makePed(model, x, y, z, heading, extra)
    NextHandle = NextHandle + 1
    local p = { model = GetHashKey(model or 'mp_male'), coords = vector3(x or 0.0, y or 0.0, z or 0.0),
                heading = heading or 0.0, networked = true, ready = true, boneHeight = 0.6 }
    for k, v in pairs(extra or {}) do p[k] = v end
    Peds[NextHandle] = p
    return NextHandle
end
MyPed = makePed('mp_male', 0.0, 0.0, 0.0, 90.0)
function PlayerPedId() return MyPed end
function PlayerId() return 0 end
MyServerId = 1
function GetPlayerServerId(player) if player == 0 then return MyServerId end return player end
RemotePlayers = {}   -- [serverId] = ped handle (in scope)
function GetPlayerFromServerId(sid) if RemotePlayers[sid] then return sid end if sid == MyServerId then return 0 end return -1 end
function GetPlayerPed(player) if player == 0 then return MyPed end return RemotePlayers[player] or 0 end
-- BOOL natives answer 1 (not true) on the RedM runtime: the stubs do the same so a strict == true
-- comparison against a native fails here before it fails in the game.
function DoesEntityExist(e) if type(e) == 'number' and Peds[e] ~= nil then return 1 end return false end
function IsEntityAPed(e) return Peds[e] ~= nil end
function IsPedAPlayer(e) if e == MyPed then return true end for _, p in pairs(RemotePlayers) do if p == e then return true end end return false end
function GetEntityModel(e) return Peds[e] and Peds[e].model or 0 end
function GetEntityCoords(e) return Peds[e] and Peds[e].coords or vector3(0, 0, 0) end
function GetEntityHeading(e) return Peds[e] and Peds[e].heading or 0.0 end
function SetEntityHeading(e, h) rec('SetEntityHeading', e, h) if Peds[e] then Peds[e].heading = h end end
function SetEntityCoords(e, x, y, z) rec('SetEntityCoords', e, x, y, z) if Peds[e] then Peds[e].coords = vector3(x, y, z) end end
function GetPedBoneCoords(e) local p = Peds[e]; if not p then return vector3(0, 0, 0) end
    return vector3(p.coords.x + (p.boneX or 0.0), p.coords.y, p.coords.z + p.boneHeight) end
function NetworkGetEntityIsNetworked(e) return Peds[e] ~= nil and Peds[e].networked end
function NetworkGetNetworkIdFromEntity(e) return Peds[e] and 77 or 0 end
function FreezeEntityPosition(e, b) rec('FreezeEntityPosition', e, b) if Peds[e] then Peds[e].frozen = b end end
function SetEntityVisible(e, b) rec('SetEntityVisible', e, b) if Peds[e] then Peds[e].visible = b end end
function SetEntityInvincible(e, b) rec('SetEntityInvincible', e, b) if Peds[e] then Peds[e].invincible = b end end
for _, name in ipairs({ 'ClearPedTasksImmediately', 'ClearPedTasks', 'SetEntityCollision', 'RequestCollisionAtCoord',
    'TaskStandStill', 'ResetEntityAlpha', 'SetBlockingOfNonTemporaryEvents', 'SetPedCanBeTargetted',
    'SetEntityAsMissionEntity', 'DisplayRadar', 'DisplayHud', 'DisableAllControlActions', 'SetNuiFocus',
    'SetNuiFocusKeepInput', 'NetworkClockTimeOverride', 'NetworkClearClockTimeOverride', 'HidePedWeapons',
    'SetWeatherType', 'ClearOverrideWeather', 'ClearWeatherTypePersist', 'ClearFocus', 'SetFocusPosAndVel',
    'ClearTimecycleModifier', 'SetTimecycleModifier', 'EquipMetaPedOutfit', 'SetPlayerModel',
    'SetModelAsNoLongerNeeded', 'DoScreenFadeOut', 'DoScreenFadeIn', 'ShutdownLoadingScreen', 'DrawLightWithRange',
    'RequestIplByHash', 'StartPlayerTeleport', 'RemoveIplByHash' }) do
    _ENV[name] = function(...) rec(name, ...) end
end
function HasCollisionLoadedAroundEntity() return 1 end
IplInactive = {}      -- [hash] = true: the map is not active until requested
function IsIplActiveByHash(hash) return not IplInactive[hash] end
function IsPlayerTeleportActive() return false end
ScreenFadedOut = false
function IsScreenFadedOut() return ScreenFadedOut end
ResourceStates = {}
function GetResourceState(name) return ResourceStates[name] or 'missing' end
exports = exports or {}
exports.w_loading = {
    Show = function(_, key) rec('w_loading:Show', key) end,
    Hide = function(_) rec('w_loading:Hide') end,
}
function IsScreenFadingOut() return false end
function IsScreenFadingIn() return false end
function NetworkIsSessionStarted() return true end
function GetGamePool() local out = {} for h in pairs(Peds) do out[#out + 1] = h end table.sort(out) return out end
local triggerEvent = TriggerEvent
function TriggerEvent(name, ...) rec('TriggerEvent:' .. name, ...) triggerEvent(name, ...) end
function TriggerServerEvent(name, ...) rec('TriggerServerEvent:' .. name, ...) end
function SetPedScale(ped, value)
    assert(math.type(value) == 'float', 'native scale requires float')
    rec('SetPedScale', ped, value)
end
function SetPlayerModel(player, model) rec('SetPlayerModel', player, model)
    local old = MyPed
    MyPed = makePed('mp_male'); Peds[MyPed].model = model; Peds[old] = nil end

-- cameras --------------------------------------------------------------------------------
Cams = {}
NextCam = 0
function CreateCam() NextCam = NextCam + 1; Cams[NextCam] = true; rec('CreateCam', NextCam) return NextCam end
function DoesCamExist(c) if Cams[c] == true then return 1 end return false end
function DestroyCam(c) rec('DestroyCam', c) Cams[c] = nil end
function RenderScriptCams(b) rec('RenderScriptCams', b) end
for _, name in ipairs({ 'SetCamCoord', 'PointCamAtCoord', 'SetCamFov', 'SetCamActiveWithInterp', 'SetCamActive' }) do
    _ENV[name] = function(...) rec(name, ...) end
end

-- raw natives through the wrappers -------------------------------------------------------
NATIVE_NAMES = {
    [0x77FF8D35EEC6BBC4] = 'preset', [0x704C908E9C405136] = 'preRefresh',
    [0xCC8CA3E88256E58F] = 'updateVariation', [0x5653AB26C82938CF] = 'setExpression',
    [0x9587913B9E772D29] = 'placeOnGround', [0x5E3BDDBCB83F3D84] = 'giveWeapon',
    [0x524B54361229154F] = 'startScenario', [0x513F8AA5BF2F17CF] = 'loadSphere',
    [0x2703EFB583F0949A] = 'setVoice', [0xBC9AE166038A5CEC] = 'playPain',
}
Citizen.InvokeNative = function(hash, ...)
    if hash == 0xA0BC8FAED8CFEB3C then local p = Peds[(...)] return p ~= nil and p.ready end
    rec(NATIVE_NAMES[hash] or string.format('native:0x%X', hash), ...)
end
Citizen.ResultAsInteger = function() return nil end

-- w_lib ------------------------------------------------------------------------------------
BadHashes = {}
w.component.getComponentCategory = function(ped, hash)
    if BadHashes[hash] then return nil end
    return 12345, true
end
local function comp(name) return function(...) rec('component.' .. name, ...) end end
for _, name in ipairs({ 'apply', 'remove', 'removeAllClothes', 'setWearableState', 'sleeveRoll',
    'sleeveUnroll', 'collarOpen', 'collarClose', 'setWaistType', 'refreshPed', 'waitPedLoaded' }) do
    w.component[name] = comp(name)
end
w.pedTexture = {
    overwriteBodyPart = function(...) rec('pedTexture.overwriteBodyPart', ...) end,
    refreshNow = function(...) rec('pedTexture.refreshNow', ...) end,
}
w.entity = {
    create = function(model, pos, networked) local ped = makePed(model, pos.x, pos.y, pos.z, pos.w)
        rec('entity.create', ped) return ped end,
    delete = function(ped) rec('entity.delete', ped) Peds[ped] = nil end,
}
w.requestModel = function(model) rec('requestModel', model) return true end
w.setRadarVisible = function(b) rec('setRadarVisible', b) end
w.getLocaleKey = function() return LocaleKey or 'ar' end
w.locale = function(key) rec('w.locale', key) end
w.raycast = { pedPartFromScreen = function(ped, x, y, aspect) return PickPart end }
w.callback.await = function(name, ...) rec('callback:' .. name, ...)
    local r = CallbackResults and CallbackResults[name]
    if type(r) == 'function' then return r(...) end
    return r or { ok = true, code = 'OK' } end
'''


def client_scripts_until(last):
    """Client scripts in manifest order up to and including `last`."""
    out = []
    for path in manifest_scripts('client'):
        out.append(path)
        if path == last:
            break
    return out


def make_client(catalog='fixture'):
    rt = Runtime(catalog=catalog)
    rt.load_shared()
    rt.run(CLIENT_STUBS)
    rt.load(*client_scripts_until('client/scene/environment.lua'))
    return rt
