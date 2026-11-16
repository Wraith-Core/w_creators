-- =====================================================================
--  client/voice/speak.lua  —  greet / antagonize in the character's own voice (2026-10-19)
--  The game's player greet and antagonize speak with JOHN's lines (mp_male / mp_female have no voice). While a
--  person is focused (free focus), the game's two are muted for that person and ours take their place, on the same
--  game controls (Config.Voice.speak). A press goes to the server (server/voice/speak.lua), which picks the line and
--  the voice and tells the players near; each plays it on the speaker's ped (WCNative.ped.speak, the voice written
--  in), and the person answers in its own voice.
--  1.0.7 (2026-11-02): the two rows are drawn by w_lib's prompt frame (the game's font has no Arabic: the native
--  prompts showed boxes), and nothing is shown or muted while the player or the person is in a melee or a grapple:
--  our rows sat in the person's prompt group on the same keys and the player could not let go of a grabbed person.
-- =====================================================================

--  1.0.9 (2026-11-03, owner): the game's own prompts (Emote, Melee, the "Stranger" name) were drawn under ours.
--  They are switched off for the frame while our card shows, and our card carries those two as well: melee on F
--  and emote on 1 stay the game's own keys (shown, the game still acts on them). Antagonize moves off F (it was
--  the melee key too) to its own key, read through w_lib's key listener.

--  2026-11-16 (owner: "F does not hit, and hide the emote, there is no emote here"): the blind switch takes the
--  game's prompts WITH their actions (client/natives/promptlab.lua, T1), so the focus melee on F never struck.
--  While the melee key is down, and a short while after it (meleeGraceMs), the game's prompts are left alone and
--  our card steps aside, so the game's own melee takes the key. The emote row is gone.

local SPEAK = (Config.Voice or {}).speak or {}
local CONTROLS = {
    greet = GetHashKey(SPEAK.greetControl or 'INPUT_INTERACT_LOCKON_POS'),
    melee = GetHashKey(SPEAK.meleeControl or 'INPUT_MELEE_ATTACK'),
}
-- the letters on the card: greet = the game's control key; antagonize = our own key; melee = the game's key
local KEYS = { greet = SPEAK.greetKey or 'R', antagonize = SPEAK.antagonizeKey or 'G',
    melee = SPEAK.meleeKey or 'F' }
local MELEE_GRACE = tonumber(SPEAK.meleeGraceMs) or 1500
local groupId, shown = nil, false
local readyAt, meleeUntil = 0, 0

local function lib(name, ...)
    local ok, result = pcall(exports.w_lib[name], exports.w_lib, ...)
    return ok and result or nil
end

local function ensureGroup()
    if groupId then return groupId end
    groupId = lib('CreateGroup', locale('حديث'), 'bottom-right')
    if not groupId then return nil end
    lib('AddPrompt', groupId, KEYS.greet, locale('تحية'), false)
    lib('AddPrompt', groupId, KEYS.antagonize, locale('استفزاز'), false)
    lib('AddPrompt', groupId, KEYS.melee, locale('ضرب'), false)
    return groupId
end

local function show(on)
    if on == shown then return end
    local id = ensureGroup()
    if not id then return end
    lib(on and 'Display' or 'Hide', id)
    shown = on
end

local function setLive(live)
    if not groupId then return end
    lib('SetPromptEnabled', groupId, KEYS.greet, live)
    lib('SetPromptEnabled', groupId, KEYS.antagonize, live)
end

local function yes(v) return v == true or v == 1 end

--- A fight or a hold: the game's own melee and grapple prompts and keys must stay untouched.
local function inMelee(ped, target)
    return yes(IsPedInMeleeCombat(ped)) or yes(IsPedInMeleeCombat(target)) or yes(IsPedRagdoll(target))
        or yes(IsPedInCombat(ped, target))
end

--- 2026-11-12: another script's card on this person comes first. w_lib shows one prompt card at a time, so ours
--- pushed w_policejob's law card off the screen on the lock-on (and its G is the cuff key). w_policejob sets
--- LocalPlayer.state['w:personCard'] (this client only) while its card is up; a cuffed or carried player is that
--- card's person too, before its flag arrives.
local function anotherCard(target)
    if LocalPlayer.state['w:personCard'] == true then return true end
    if not IsPedAPlayer(target) then return false end
    local index = NetworkGetPlayerIndexFromPed(target)
    if not index or index == -1 then return false end
    local state = Player(GetPlayerServerId(index)).state
    return state.isHandcuffed == true or state.isEscorted == true
end

local function focusedPerson()
    local player = PlayerId()
    if not IsPlayerFreeFocusing(player) then return nil end
    local ok, target = GetPlayerTargetEntity(player)
    local ped = PlayerPedId()
    if not ok or not target or target == 0 or target == ped then return nil end
    if not IsEntityAPed(target) or not IsPedHuman(target) or IsPedDeadOrDying(target, true) then return nil end
    if inMelee(ped, target) then return nil end
    if anotherCard(target) then return nil end
    return target
end

local function pressed(control)
    return IsControlJustPressed(0, control) or IsDisabledControlJustPressed(0, control)
end

local function held(control)
    return IsControlPressed(0, control) or IsDisabledControlPressed(0, control)
end

CreateThread(function()
    if SPEAK.enabled == false then return end
    while true do
        local target = focusedPerson()
        local now = GetGameTimer()
        -- checked before the blind switch: the game's melee prompt must be live in the very frame F goes down
        if target and held(CONTROLS.melee) then meleeUntil = now + MELEE_GRACE end
        if target and now < meleeUntil then
            WCNative.ped.muteGreet(target, 1000)
            WCNative.ped.muteAntagonize(target, 1000)
            show(false) -- the game's own melee has the key: no blind switch, our card steps aside
            Wait(0)
        elseif target then
            WCNative.ped.muteGreet(target, 1000)
            WCNative.ped.muteAntagonize(target, 1000)
            WCNative.ui.hidePromptsThisFrame() -- 1.0.9: the game's prompts under ours
            show(true)
            local live = now >= readyAt
            setLive(live)
            if live then
                local kind = (pressed(CONTROLS.greet) and 'greet')
                    or (groupId and lib('IsCompleted', groupId, KEYS.antagonize) == true and 'antagonize') or nil
                if kind then
                    readyAt = now + (tonumber(SPEAK.cooldownMs) or 2500)
                    local net = NetworkGetEntityIsNetworked(target) and NetworkGetNetworkIdFromEntity(target) or 0
                    TriggerServerEvent('w_creators:server:voiceSpeak', kind, net, not IsPedMale(target))
                end
            end
            Wait(0)
        else
            show(false)
            Wait(250)
        end
    end
end)

RegisterNetEvent('w_creators:client:voiceSaid', function(src, line, voice, targetNet, reply)
    local index = GetPlayerFromServerId(tonumber(src) or -1)
    if not index or index == -1 then return end
    local ped = GetPlayerPed(index)
    if not ped or ped == 0 or not DoesEntityExist(ped) then return end
    WCNative.ped.speak(ped, line, voice)
    targetNet = tonumber(targetNet) or 0
    if type(reply) ~= 'string' or targetNet == 0 or not NetworkDoesNetworkIdExist(targetNet) then return end
    local target = NetToPed(targetNet)
    if not target or target == 0 or not DoesEntityExist(target) or IsPedAPlayer(target) then return end
    SetTimeout(tonumber(SPEAK.replyDelayMs) or 1400, function()
        if DoesEntityExist(target) and not IsPedDeadOrDying(target, true) then WCNative.ped.speak(target, reply, nil) end
    end)
end)

AddEventHandler('onResourceStop', function(name)
    if name == GetCurrentResourceName() and groupId then
        lib('Hide', groupId)
        lib('DeleteGroup', groupId)
        groupId, shown = nil, false
    end
end)
