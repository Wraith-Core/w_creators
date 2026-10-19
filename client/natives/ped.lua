-- =====================================================================
--  client/natives/ped.lua  —  WCNative.ped
--  Ped morphology, variation refresh, placement and small ped state natives.
-- =====================================================================

WCNative.ped = {}
local H = WCNative._

--- _SET_CHAR_EXPRESSION (SetCharExpression)
-- hash: 0x5653AB26C82938CF · confidence: Verified (pre-v3 face features and body expressions)
-- params: ped (entity), expressionId (int, w.component.data.expressions), value (float -1.0..1.0)
-- returns: nothing · limitations: the value MUST be a float (an integer is read as raw bits);
--   does not refresh the ped - batch with WCNative.ped.refresh once per apply
-- tested models: mp_male, mp_female · MP safe: yes · OneSync tested here: no (see TESTING.md)
function WCNative.ped.setExpression(ped, expressionId, value)
    if not H.ped(ped) then return H.fail('setExpression', 'invalid ped %s', tostring(ped)) or false end
    local id = math.tointeger(tonumber(expressionId))
    if not id then return H.fail('setExpression', 'invalid expression %s', tostring(expressionId)) or false end
    local v = math.max(-1.0, math.min(1.0, H.float(value)))
    local ok = H.invoke(0x5653AB26C82938CF, ped, id, v)
    return ok
end

--- Pre-refresh (clears the pending metaped update request) — _0x704C908E9C405136
-- hash: 0x704C908E9C405136 · confidence: Verified (w_lib component/ped-texture refresh, pre-v3 refresh)
-- params: ped (entity) · returns: nothing
-- limitations: no visible effect on its own; always followed by updateVariation (WCNative.ped.refresh)
-- tested models: mp_male, mp_female · MP safe: yes · OneSync tested here: no
function WCNative.ped.preRefresh(ped)
    if not H.ped(ped) then return H.fail('preRefresh', 'invalid ped %s', tostring(ped)) or false end
    local ok = H.invoke(0x704C908E9C405136, ped)
    return ok
end

--- _UPDATE_PED_VARIATION
-- hash: 0xCC8CA3E88256E58F · confidence: Verified (w_lib, pre-v3 NativeUpdatePedVariation)
-- params: ped (entity), p1 (false), p2 (true), p3 (true), p4 (true), p5 (false)
-- returns: nothing · limitations: expensive; call once per batch (A11)
-- tested models: mp_male, mp_female, story NPCs (tailors) · MP safe: yes · OneSync tested here: no
function WCNative.ped.updateVariation(ped)
    if not H.ped(ped) then return H.fail('updateVariation', 'invalid ped %s', tostring(ped)) or false end
    local ok = H.invoke(0xCC8CA3E88256E58F, ped, false, true, true, true, false)
    return ok
end

--- The batch refresh: 0x704C908E9C405136 then 0xCC8CA3E88256E58F, once.
function WCNative.ped.refresh(ped)
    if not H.ped(ped) then return H.fail('refresh', 'invalid ped %s', tostring(ped)) or false end
    local a = WCNative.ped.preRefresh(ped)
    local b = WCNative.ped.updateVariation(ped)
    return a and b
end

--- SET_PED_SCALE (named native; wrapped for the float coercion)
-- hash: called by name (SetPedScale) · confidence: Verified (pre-v3 ApplyPedScale)
-- params: ped (entity), scale (float 0.9..1.1 here) · returns: nothing
-- limitations: an integer scale collapses every bone to the origin while the ped reports ready
-- tested models: mp_male, mp_female · MP safe: yes · OneSync tested here: no
function WCNative.ped.setScale(ped, scale)
    if not H.ped(ped) then return H.fail('setScale', 'invalid ped %s', tostring(ped)) or false end
    local ok = pcall(SetPedScale, ped, H.float(scale, 1.0))
    return ok
end

--- _PLACE_ENTITY_ON_GROUND_PROPERLY
-- hash: 0x9587913B9E772D29 · confidence: Verified (pre-v3 CreatorScene.position)
-- params: entity (ped or object), p1 (bool, true) · returns: nothing
-- limitations: collision must be loaded around the entity first
-- tested models: mp_male, mp_female · MP safe: yes · OneSync tested here: no
function WCNative.ped.placeOnGround(entity)
    if not H.entity(entity) then return H.fail('placeOnGround', 'invalid entity %s', tostring(entity)) or false end
    local ok = H.invoke(0x9587913B9E772D29, entity, true)
    return ok
end

--- _GET_PED_HEIGHT (GetPedHeight)
-- hash: 0x1D491CCF7211FB74 · confidence: Likely (rdr3 native reference; the MP character creators
--   read the character's height from it right after SET_PED_SCALE, so it follows the scale)
-- params: ped (entity) · returns: the standing height in metres (float), or nil
-- limitations: read-only; an answer outside 0.5..3.0 m (a ped not rendered yet) is reported as nil,
--   so the caller keeps its plain readout (the creator's height slider, WCEditorTree.heightDisplay)
-- tested models: none here (needs an in-game check) · MP safe: yes (read only) · OneSync tested here: no
function WCNative.ped.height(ped)
    if not H.ped(ped) then return H.fail('height', 'invalid ped %s', tostring(ped)) end
    local asFloat = Citizen.ResultAsFloat and Citizen.ResultAsFloat() or nil
    local ok, value = H.invoke(0x1D491CCF7211FB74, ped, asFloat)
    value = ok and tonumber(value) or nil
    if not value or value ~= value or value < 0.5 or value > 3.0 then return nil end
    return value + 0.0
end

--- SET_PED_KEEP_TASK
-- hash: 0x971D38760FBC02EF · confidence: Verified (pre-v3 first-spawn wagon driver)
-- params: ped (entity), toggle (bool) · returns: nothing
-- limitations: none known (the task must be given before the ped is released)
-- tested models: CS_BivCoachDriver · MP safe: yes · OneSync tested here: no
function WCNative.ped.setKeepTask(ped, toggle)
    if not H.ped(ped) then return H.fail('setKeepTask', 'invalid ped %s', tostring(ped)) or false end
    local ok = H.invoke(0x971D38760FBC02EF, ped, toggle == true)
    return ok
end

--- _GIVE_WEAPON_TO_PED_2 (GiveWeaponToPed)
-- hash: 0x5E3BDDBCB83F3D84 · confidence: Verified (pre-v3 ArmScenePed: holstered revolver)
-- params: ped (entity), weaponHash (u32/int), ammo (int), forceInHand (bool), forceInHolster (bool)
--   (the trailing attach/flags parameters are left at their zero defaults, as before)
-- returns: nothing · limitations: cosmetic use only (preview peds); never used on the player ped
-- tested models: mp_male, mp_female · MP safe: yes · OneSync tested here: no
function WCNative.ped.giveWeapon(ped, weapon, ammo, forceInHand, forceInHolster)
    if not H.ped(ped) then return H.fail('giveWeapon', 'invalid ped %s', tostring(ped)) or false end
    local hash = type(weapon) == 'string' and GetHashKey(weapon) or tonumber(weapon)
    if not hash then return H.fail('giveWeapon', 'invalid weapon %s', tostring(weapon)) or false end
    local ok = H.invoke(0x5E3BDDBCB83F3D84, ped, hash, math.tointeger(tonumber(ammo) or 0) or 0,
        forceInHand == true, forceInHolster == true)
    return ok
end

--- _SET_VOFX_PED_VOICE (SetVofxPedVoice)
-- hash: 0x2703EFB583F0949A · confidence: Likely (RedM's native table lists VOFX_PLAYER_MALE01..03 and
--   VOFX_PLAYER_FEMALE01..03; not used on this server before 2026-10-19)
-- params: ped (entity), voice (string name, hashed here: AppearanceSchema.vofxName)
-- returns: nothing · limitations: the vocal set only (pain, breath, effort), local to this client: every client sets
--   it on the peds it draws (the appearance render does, for remote players too); a new ped (SetPlayerModel) resets it
-- tested models: mp_male, mp_female (in-game check pending) · MP safe: yes · OneSync tested here: no
function WCNative.ped.setVoice(ped, voice)
    if not H.ped(ped) then return H.fail('setVoice', 'invalid ped %s', tostring(ped)) or false end
    if type(voice) ~= 'string' or voice == '' then return H.fail('setVoice', 'invalid voice %s', tostring(voice)) or false end
    local ok = H.invoke(0x2703EFB583F0949A, ped, GetHashKey(voice))
    return ok
end

--- PLAY_PAIN (PlayPain)
-- hash: 0xBC9AE166038A5CEC · confidence: Verified (w_hud client/thread.lua: PlayPain(ped, 9, 1, true, true))
-- params: ped (entity), painId (int 0..12), p2 (float 1.0), p3 (false), isNetwork (false: a local sample)
-- returns: nothing · limitations: plays in the ped's current vocal set; used as the voice sample in the creator
-- tested models: mp_male, mp_female (in-game check pending) · MP safe: yes · OneSync tested here: no
function WCNative.ped.playPain(ped, painId)
    if not H.ped(ped) then return H.fail('playPain', 'invalid ped %s', tostring(ped)) or false end
    local id = math.tointeger(tonumber(painId)) or 9
    local ok = H.invoke(0xBC9AE166038A5CEC, ped, math.max(0, math.min(12, id)), 1.0, false, false)
    return ok
end

--- SET_AMBIENT_VOICE_NAME (SetAmbientVoiceName)
-- hash: 0x6C8065A3B780185B · confidence: Likely (aaron1a12/wild sets it on mp_male / mp_female, which have no voice
--   group of their own in metapeds.ymt: without it the game speaks for them in JOHN's voice)
-- params: ped (entity), name (string: a full voice bank name, AppearanceSchema.speechVoice)
-- returns: nothing · limitations: local to this client (the appearance render sets it on every ped it draws);
--   a new ped (SetPlayerModel) resets it; the game's own player-only lines (antagonize) are not in these banks
-- tested models: mp_male, mp_female (in-game check pending) · MP safe: yes · OneSync tested here: no
function WCNative.ped.setSpeechVoice(ped, name)
    if not H.ped(ped) then return H.fail('setSpeechVoice', 'invalid ped %s', tostring(ped)) or false end
    if type(name) ~= 'string' or name == '' then return H.fail('setSpeechVoice', 'invalid voice %s', tostring(name)) or false end
    local ok = H.invoke(0x6C8065A3B780185B, ped, name)
    return ok
end

--- PLAY_PED_AMBIENT_SPEECH_NATIVE (PlayPedAmbientSpeechNative)
-- hash: 0x8E04FEDD28D42462 · confidence: Verified (w_store client/speech.lua: the same 0x40 params struct, the line
--   and the voice as var-string pointers)
-- params: ped (entity), line (string), voice (string | nil = the ped's own), paramsName (string, default
--   SPEECH_PARAMS_FORCE)
-- returns: true when the line started · limitations: played locally (syncOverNetwork 0): every client plays it on
--   the speaker's ped itself (server/voice/speak.lua relays); a voice that lacks the line returns false
-- tested models: mp_male, mp_female, ambient peds (in-game check pending) · MP safe: yes · OneSync tested here: no
function WCNative.ped.speak(ped, line, voice, paramsName)
    if not H.ped(ped) then return H.fail('speak', 'invalid ped %s', tostring(ped)) or false end
    if type(DataView) ~= 'table' or type(DataView.ArrayBuffer) ~= 'function' then return false end
    local linePtr = tonumber(WCNative.ui.varString(line))
    if not linePtr or linePtr == 0 then return false end
    local voicePtr = 0
    if voice then
        voicePtr = tonumber(WCNative.ui.varString(voice))
        if not voicePtr or voicePtr == 0 then return false end
    end
    local p = DataView.ArrayBuffer(0x40)
    p:SetInt64(0, linePtr)                                      -- const char* speechName
    p:SetInt64(8, voicePtr)                                     -- const char* voiceName (0 = the ped's own)
    p:SetInt32(16, 0)                                           -- variation (0 = any)
    p:SetInt32(24, GetHashKey(paramsName or 'SPEECH_PARAMS_FORCE'))
    p:SetInt32(32, 0)                                           -- listener ped
    p:SetInt32(40, 0)                                           -- syncOverNetwork: every client plays it itself
    p:SetInt32(48, 1)
    p:SetInt32(56, 1)
    local ok, started = H.invoke(0x8E04FEDD28D42462, ped, p:Buffer(), Citizen.ResultAsInteger())
    return ok ~= false and started ~= nil and started ~= 0 and started ~= false
end

--- _SET_PLAYER_GREET_DISABLED_FOR_PED (SetPlayerGreetDisabledForPed)
-- hash: 0x19173C3F15367B54 · confidence: Likely (rdr3 native db; the game's own player greet uses JOHN's lines)
-- params: ped (entity: the focused target), player (PlayerId()), duration (int ms)
-- returns: nothing · limitations: called each frame while a target is focused; our own greet prompt replaces it
-- tested models: ambient peds (in-game check pending) · MP safe: yes · OneSync tested here: no
function WCNative.ped.muteGreet(ped, duration)
    if not H.ped(ped) then return false end
    local ok = H.invoke(0x19173C3F15367B54, ped, PlayerId(), math.tointeger(tonumber(duration) or 500) or 500)
    return ok
end

--- _SET_PLAYER_ANTAGONIZE_DISABLED_FOR_PED (SetPlayerAntagonizeDisabledForPed)
-- hash: 0x5708EDD71B50C008 · confidence: Likely (rdr3 native db; the game's antagonize lines are player-only)
-- params: ped (entity: the focused target), player (PlayerId()), duration (int ms)
-- returns: nothing · limitations: called each frame while a target is focused; our own antagonize prompt replaces it
-- tested models: ambient peds (in-game check pending) · MP safe: yes · OneSync tested here: no
function WCNative.ped.muteAntagonize(ped, duration)
    if not H.ped(ped) then return false end
    local ok = H.invoke(0x5708EDD71B50C008, ped, PlayerId(), math.tointeger(tonumber(duration) or 500) or 500)
    return ok
end
