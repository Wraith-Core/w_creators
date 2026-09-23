-- =====================================================================
--  config/surgery.lua
--  Cosmetic surgery (the clinics are config/locations.lua entries of type 'surgery').
--  allow = the AppearanceSchema sections a procedure may change; everything else is kept
--  from the saved appearance on the server, whatever the client submits.
-- =====================================================================

Config.CosmeticSurgery = {
    enabled = true,
    price = 500.0,
    allow = {
        face = true,        -- base head, face morphology, teeth
        body = true,        -- body type, height, weight, body morphology
        eyes = true,        -- eye colour
        skin = true,        -- skin tone and skin overlays
        hair = false,
        facialHair = false,
        clothing = false,
    },
    -- How long a clinic session may stay open before the server expires it.
    sessionMinutes = 20,
}
