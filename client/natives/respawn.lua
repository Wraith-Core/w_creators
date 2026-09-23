-- =====================================================================
--  client/natives/respawn.lua  —  WCNative.respawn
--  The single resurrect primitive used by the respawn service (ARCHITECTURE.md §12).
-- =====================================================================

WCNative.respawn = {}
local H = WCNative._

--- NETWORK_RESURRECT_LOCAL_PLAYER
-- hash: called by name (NetworkResurrectLocalPlayer) · confidence: Verified (w_ambulancejob client/main.lua, production)
-- params: x, y, z (float), heading (float), unk (bool, true), changetime (bool, false)
-- returns: nothing · limitations: the player ped handle may change (unconfirmed, see TESTING.md;
--   w_ambulancejob keeps using the handle it read before the call); callers re-read PlayerPedId()
--   afterwards and restore the appearance (Appearance.RestorePlayer). Never touches weapons/inventory.
-- tested models: mp_male, mp_female · MP safe: yes · OneSync tested here: no (see TESTING.md)
--
-- _NETWORK_RESURRECT_LOCAL_PLAYER_2 (the struct-parameter variant named in the research notes)
-- confidence: Experimental · NOT wrapped and NOT used: its parameter is a native struct whose
-- layout is unverified; the plain variant above is what production resources rely on.
function WCNative.respawn.resurrect(coords, heading)
    local x, y, z = WCUtil.xyz(coords)
    if not x then return H.fail('resurrect', 'invalid coords') or false end
    local ok, err = pcall(NetworkResurrectLocalPlayer, H.float(x), H.float(y), H.float(z), H.float(heading), true, false)
    if not ok then return H.fail('resurrect', 'failed: %s', tostring(err)) or false end
    return true
end
