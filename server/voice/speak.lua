-- =====================================================================
--  server/voice/speak.lua  —  a greet / antagonize in the character's own voice (2026-10-19)
--  client/voice/speak.lua sends the press: the kind and the person spoken to. The server picks the line
--  (Config.Voice.speak.lines), takes the voice from the speaker's saved look (WCSync.get -> never from the
--  client) and tells every player within range, who plays it on the speaker's ped; a non-player answers.
-- =====================================================================

local SPEAK = (Config.Voice or {}).speak or {}
local RATE_KEY = 'voice:speak'

local function pick(list)
    if type(list) ~= 'table' or #list == 0 then return nil end
    return list[math.random(#list)]
end

RegisterNetEvent('w_creators:server:voiceSpeak', function(kind, targetNet, targetFemale)
    local src = source
    if SPEAK.enabled == false or (kind ~= 'greet' and kind ~= 'antagonize') then return end
    if not WCSecurity.rate(src, RATE_KEY, 1, SPEAK.cooldownMs or 2500) then return end
    local app = WCSync.get(src)
    if type(app) ~= 'table' then return end
    local line = pick(((SPEAK.lines or {})[kind] or {})[targetFemale == true and 'female' or 'male'])
    if not line then return end
    local voice = AppearanceSchema.speechVoice(app.sex, app.voice)
    local reply = pick((SPEAK.replies or {})[kind])
    local ped = GetPlayerPed(src)
    if not ped or ped == 0 then return end
    local at, range = GetEntityCoords(ped), tonumber(SPEAK.range) or 30.0
    targetNet = math.tointeger(tonumber(targetNet)) or 0
    for _, id in ipairs(GetPlayers()) do
        local other = tonumber(id)
        local otherPed = other and GetPlayerPed(other)
        if otherPed and otherPed ~= 0 and #(GetEntityCoords(otherPed) - at) <= range then
            TriggerClientEvent('w_creators:client:voiceSaid', other, src, line, voice, targetNet, reply)
        end
    end
end)
