-- =====================================================================
--  client/voice/speak.lua  —  greet / antagonize in the character's own voice (2026-10-19)
--  The game's player greet and antagonize speak with JOHN's lines (mp_male / mp_female have no voice). While a
--  person is focused (free focus), the game's two are muted for that person and ours take their place in the
--  person's prompt group, on the same game controls (Config.Voice.speak). A press goes to the server
--  (server/voice/speak.lua), which picks the line and the voice and tells the players near; each plays it on the
--  speaker's ped (WCNative.ped.speak, the voice written in), and the person answers in its own voice.
-- =====================================================================

local SPEAK = (Config.Voice or {}).speak or {}
local prompts, promptTarget = nil, 0
local readyAt = 0

local function removePrompts()
    if prompts then
        for _, prompt in pairs(prompts) do UiPromptDelete(prompt) end
    end
    prompts, promptTarget = nil, 0
end

local function makePrompt(control, text, group)
    local prompt = UiPromptRegisterBegin()
    UiPromptSetControlAction(prompt, GetHashKey(control))
    UiPromptSetText(prompt, WCNative.ui.varString(text))
    UiPromptSetStandardMode(prompt, true)
    UiPromptSetGroup(prompt, group, 0)
    UiPromptRegisterEnd(prompt)
    return prompt
end

local function buildPrompts(target)
    removePrompts()
    local group = UiPromptGetGroupIdForTargetEntity(target)
    prompts = {
        greet = makePrompt(SPEAK.greetControl or 'INPUT_INTERACT_LOCKON_POS', locale('تحية'), group),
        antagonize = makePrompt(SPEAK.antagonizeControl or 'INPUT_INTERACT_LOCKON_NEG', locale('استفزاز'), group),
    }
    promptTarget = target
end

local function completed(prompt)
    local r = UiPromptHasStandardModeCompleted(prompt, 0)
    return r == true or r == 1
end

local function focusedPerson()
    local player = PlayerId()
    if not IsPlayerFreeFocusing(player) then return nil end
    local ok, target = GetPlayerTargetEntity(player)
    if not ok or not target or target == 0 or target == PlayerPedId() then return nil end
    if not IsEntityAPed(target) or not IsPedHuman(target) or IsPedDeadOrDying(target, true) then return nil end
    return target
end

CreateThread(function()
    if SPEAK.enabled == false then return end
    while true do
        local target = focusedPerson()
        if target then
            WCNative.ped.muteGreet(target, 1000)
            WCNative.ped.muteAntagonize(target, 1000)
            if promptTarget ~= target then buildPrompts(target) end
            local now = GetGameTimer()
            local live = now >= readyAt
            for _, prompt in pairs(prompts) do UiPromptSetEnabled(prompt, live) end
            if live then
                local kind = (completed(prompts.greet) and 'greet') or (completed(prompts.antagonize) and 'antagonize') or nil
                if kind then
                    readyAt = now + (tonumber(SPEAK.cooldownMs) or 2500)
                    local net = NetworkGetEntityIsNetworked(target) and NetworkGetNetworkIdFromEntity(target) or 0
                    TriggerServerEvent('w_creators:server:voiceSpeak', kind, net, not IsPedMale(target))
                end
            end
            Wait(0)
        else
            if prompts then removePrompts() end
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
    if name == GetCurrentResourceName() then removePrompts() end
end)
