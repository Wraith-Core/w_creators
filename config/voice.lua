-- =====================================================================
--  config/voice.lua  —  the character's speaking voice (2026-10-19)
--  The voices themselves (tone 1 normal / 2 rough / 3 refined per sex) live in shared/appearance.lua
--  (AppearanceSchema.SPEECH_VOICES). This file is the greet / antagonize of client/voice/speak.lua.
-- =====================================================================

Config.Voice = {
    speak = {
        enabled = true,
        range = 30.0,           -- metres: the players who hear a line
        cooldownMs = 2500,      -- one line per player in this time (the server holds it too)
        replyDelayMs = 1400,    -- the person spoken to answers after this
        -- the game's own lock-on controls (the keys the player knows); the game's greet / antagonize on a
        -- focused person are muted while ours are shown
        greetControl = 'INPUT_INTERACT_LOCKON_POS',
        antagonizeControl = 'INPUT_INTERACT_LOCKON_NEG',
        -- 1.0.7: the letters w_lib's prompt frame draws beside the two rows (the controls' default keys)
        greetKey = 'R',
        antagonizeKey = 'F',
        -- lines every voice of AppearanceSchema.SPEECH_VOICES has (checked against the game's voice banks);
        -- male / female = the sex of the person spoken to
        lines = {
            greet = {
                male = { 'GREET_MALE', 'GREET_GENERAL_STRANGER', 'HOWS_IT_GOING' },
                female = { 'GREET_FEMALE', 'GREET_GENERAL_STRANGER', 'HOWS_IT_GOING' },
            },
            antagonize = {
                male = { 'GENERIC_INSULT_MED_MALE', 'GENERIC_INSULT_HIGH_MALE', 'GENERIC_MOCK' },
                female = { 'GENERIC_INSULT_MED_FEMALE', 'GENERIC_INSULT_HIGH_FEMALE', 'GENERIC_MOCK' },
            },
        },
        -- what a non-player answers, in its own voice
        replies = {
            greet = { 'HOWS_IT_GOING', 'GREET_GENERAL_STRANGER' },
            antagonize = { 'INSULT_RESPONSE', 'GENERIC_INSULT_MED_NEUTRAL' },
        },
    },
}
