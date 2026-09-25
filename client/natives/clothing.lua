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

--- _GET_META_PED_TYPE
-- hash: 0xEC9A1261BF0CE510 · confidence: Verified (w_lib component module: the shop item natives'
--   metaped type argument) · params: ped (entity) · returns: the ped's metaped type (int) or nil
-- limitations: an existing ped only · tested models: mp_male, mp_female (w_lib) · MP safe: yes ·
-- OneSync tested here: no
function WCNative.clothing.metapedType(ped)
    if not H.ped(ped) then return H.fail('metapedType', 'invalid ped %s', tostring(ped)) end
    local ok, value = H.invoke(0xEC9A1261BF0CE510, ped, Citizen.ResultAsInteger())
    return ok and math.tointeger(tonumber(value)) or nil
end

--- The wearable states a shop item has (the clothing state checks: the body-part fix, the loadout
--  side, the tucks, a raisable bandana): the count, then each state by its index.
--  _GET_SHOP_ITEM_NUM_WEARABLE_STATES
-- hash: 0xFFCC2DB2D9953401 · confidence: Likely (rdr3 native reference)
-- params: shopItemHash (i32), metapedType (int: _GET_META_PED_TYPE of the wearer), p2 (bool, true)
-- returns: the number of states (int) · limitations: read-only game data
-- tested models: none here (needs an in-game check) · MP safe: yes · OneSync tested here: no
--  _GET_SHOP_ITEM_WEARABLE_STATE_BY_INDEX
-- hash: 0x6243635AF2F1B826 · confidence: Likely (rdr3 native reference)
-- params: shopItemHash (i32), index (int), metapedType (int), p3 (bool, true)
-- returns: the state's hash · limitations: index 0 .. count - 1
-- tested models: none here (needs an in-game check) · MP safe: yes · OneSync tested here: no
--  wearableStates(hash, pedOrType) returns { u32 state hash... } (the item's own states, 'base'
--  included when it has one), or nil when the game answered nothing (an unknown item, a failing
--  native): callers then let a garment's state through. The second argument is the wearer (a ped:
--  its metaped type is read) or a metaped type itself, the way w_lib's component module passes it:
--  the natives take the metaped type, not a male / female flag.
function WCNative.clothing.wearableStates(hash, pedOrType)
    local item = WCUtil.u32(hash)
    if not item or item == 0 then return H.fail('wearableStates', 'invalid item %s', tostring(hash)) end
    local metapedType
    if H.entity(pedOrType) then
        metapedType = WCNative.clothing.metapedType(pedOrType)
    else
        metapedType = math.tointeger(tonumber(pedOrType))
    end
    if not metapedType or metapedType < 0 then
        return H.fail('wearableStates', 'no metaped type for %s', tostring(pedOrType))
    end
    local signed = item >= 0x80000000 and item - 0x100000000 or item
    local ok, n = H.invoke(0xFFCC2DB2D9953401, signed, metapedType, true, Citizen.ResultAsInteger())
    n = ok and math.tointeger(tonumber(n)) or nil
    if not n or n < 0 or n > 64 then return nil end
    local out = {}
    for i = 0, n - 1 do
        local okState, state = H.invoke(0x6243635AF2F1B826, signed, i, metapedType, true, Citizen.ResultAsInteger())
        local u = okState and WCUtil.u32(state) or nil
        if u and u ~= 0 then out[#out + 1] = u end
    end
    return out
end
