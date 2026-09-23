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
}
