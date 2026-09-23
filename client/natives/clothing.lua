-- =====================================================================
--  client/natives/clothing.lua  —  WCNative.clothing
--  Shop item application / removal at the metaped level. The production path goes through the
--  w_lib wrappers (w.component.apply / remove); these wrappers are the documented raw fallbacks.
-- =====================================================================

WCNative.clothing = {}
local H = WCNative._

--- _APPLY_SHOP_ITEM_TO_PED
-- hash: 0xD3A7B003ED343FD9 · confidence: Verified (w_lib/jo_libs production use)
-- params: ped (entity), shopItemHash (u32), immediately (bool), isMultiplayer (bool), p4 (bool)
-- returns: nothing · limitations: ped must be a metaped and ready; category derived from the hash;
--   needs WCNative.ped.refresh afterwards
-- tested models: mp_male, mp_female (community) · MP safe: yes · OneSync tested here: no (see TESTING.md)
function WCNative.clothing.applyShopItem(ped, hash, immediately, isMultiplayer, p4)
    if not H.ped(ped) then return H.fail('applyShopItem', 'invalid ped %s', tostring(ped)) or false end
    local item = WCUtil.u32(hash)
    if not item or item == 0 then return H.fail('applyShopItem', 'invalid item %s', tostring(hash)) or false end
    local ok = H.invoke(0xD3A7B003ED343FD9, ped, item, immediately ~= false, isMultiplayer ~= false, p4 == true)
    return ok
end

--- _REMOVE_TAG_FROM_META_PED
-- hash: 0xD710A5007C2AC539 · confidence: Likely (documented, used by w_lib-style removal)
-- params: ped (entity), categoryHash (u32; e.g. GetHashKey('hats')), p2 (int, 0)
-- returns: nothing · limitations: needs WCNative.ped.refresh afterwards
-- tested models: mp_male, mp_female (community) · MP safe: yes · OneSync tested here: no
function WCNative.clothing.removeTag(ped, category, p2)
    if not H.ped(ped) then return H.fail('removeTag', 'invalid ped %s', tostring(ped)) or false end
    local hash = type(category) == 'string' and WCUtil.u32(GetHashKey(category)) or WCUtil.u32(category)
    if not hash then return H.fail('removeTag', 'invalid category %s', tostring(category)) or false end
    local ok = H.invoke(0xD710A5007C2AC539, ped, hash, math.tointeger(tonumber(p2) or 0) or 0)
    return ok
end

--- _SET_PLAYER_HAT_ACCESS
-- hash: 0xA0C683284DF027C7 · confidence: Experimental (Config.Experimental.hatAccess, default off)
-- params: player (Player id), hatAccess (bool), p2 (bool)
-- returns: nothing · limitations: not used for equip/remove; the production hat state removes and
--   re-applies the equipped hash
-- tested models: none here · MP safe: unknown · OneSync tested here: no
function WCNative.clothing.setHatAccess(player, access, p2)
    if not (Config.Experimental and Config.Experimental.hatAccess) then
        return H.fail('setHatAccess', 'disabled (Config.Experimental.hatAccess)') or false
    end
    local id = math.tointeger(tonumber(player))
    if not id or id < 0 then return H.fail('setHatAccess', 'invalid player %s', tostring(player)) or false end
    local ok = H.invoke(0xA0C683284DF027C7, id, access == true, p2 == true)
    return ok
end
