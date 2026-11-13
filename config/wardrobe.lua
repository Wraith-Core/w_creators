-- =====================================================================
--  config/wardrobe.lua
--  The wardrobe: wearing owned clothing and saved outfits (w_creators_outfits).
-- =====================================================================

Config.Wardrobe = {
    maxSavedOutfits = 10,
    outfitNameMax = 24,  -- characters (UTF-8 aware)
    -- exports.w_creators:OpenWardrobe() with no location id (job resources, housing). The
    -- wardrobe service toggle still applies.
    allowRemote = true,
    -- 2026-11-13 (owner): the character's starting clothes are one of his outfits, free and always there:
    -- saved with the new character, and for one made before the first time his wardrobe opens. It cannot
    -- be updated or deleted (renaming is fine) and does not count against maxSavedOutfits.
    starterOutfit = { enabled = true, name = 'ملابس البداية' },
}
