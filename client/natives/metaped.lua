-- =====================================================================
--  client/natives/metaped.lua  —  WCNative.metaped (+ the WCNative shared validation helpers)
--  client/natives/*.lua are the ONLY files allowed to call Citizen.InvokeNative / N_0x...
--  (ARCHITECTURE.md §0.4, §10). Every wrapper validates its entity/model, never throws on an
--  invalid entity (it returns false/nil and reports through WCDebug) and carries the §10 doc block.
--  Inventory with confidence levels: docs/NATIVES.md.
-- =====================================================================

WCNative = WCNative or {}
WCNative.metaped = {}

-- ---------------------------------------------------------------------
--  Shared helpers (used by every client/natives file; loaded first)
-- ---------------------------------------------------------------------
local H = {}
WCNative._ = H

--- Report a refused/failed native call (debug domain 'natives').
function H.fail(name, fmt, ...)
    WCDebug.log('natives', '%s: ' .. tostring(fmt), name, ...)
    return nil
end

--- A number handle of an existing entity.
function H.entity(entity)
    -- BOOL natives answer 1 (not true) on this runtime: never compare them with == true
    return type(entity) == 'number' and entity ~= 0 and not not DoesEntityExist(entity)
end

--- An existing ped.
function H.ped(ped)
    if not H.entity(ped) then return false end
    if not IsEntityAPed then return true end
    local isPed = IsEntityAPed(ped)
    return isPed == true or isPed == 1
end

local MP = {}
--- An existing multiplayer ped (mp_male / mp_female).
function H.mpPed(ped)
    if not H.ped(ped) then return false end
    if not MP.male then MP.male, MP.female = GetHashKey('mp_male'), GetHashKey('mp_female') end
    local model = GetEntityModel(ped)
    return model == MP.male or model == MP.female
end

--- Invoke a native safely: ok, result... (never throws).
function H.invoke(hash, ...)
    return pcall(Citizen.InvokeNative, hash, ...)
end

--- A native BOOL result as a Lua boolean (RedM returns true/false or 1/0).
function H.bool(v)
    return v == true or v == 1
end

--- A number coerced to float (RedM float params need float bits: integer 1 is not 1.0).
function H.float(v, fallback)
    v = tonumber(v)
    if not v or v ~= v or v == math.huge or v == -math.huge then v = fallback or 0.0 end
    return v + 0.0
end

-- ---------------------------------------------------------------------
--  Readiness
-- ---------------------------------------------------------------------

--- _IS_PED_READY_TO_RENDER
-- hash: 0xA0BC8FAED8CFEB3C · confidence: Verified (w_lib component module, pre-v3 CreatorScene.ready)
-- params: ped (entity)
-- returns: boolean · limitations: true can be reported while the skeleton is still collapsed
--   (zero scale); callers also check a bone height (see Appearance pipeline)
-- tested models: mp_male, mp_female · MP safe: yes · OneSync tested here: no (see TESTING.md)
function WCNative.metaped.isReadyToRender(ped)
    if not H.ped(ped) then return H.fail('isReadyToRender', 'invalid ped %s', tostring(ped)) or false end
    local ok, ready = H.invoke(0xA0BC8FAED8CFEB3C, ped)
    return ok and H.bool(ready)
end

-- ---------------------------------------------------------------------
--  Outfit presets
-- ---------------------------------------------------------------------

--- _EQUIP_META_PED_OUTFIT_PRESET (EquipMetaPedOutfitPreset)
-- hash: 0x77FF8D35EEC6BBC4 · confidence: Verified (pre-v3 SetSkin, vorp_character DefaultPedSetup)
-- params: ped (entity), presetId (int), p2 (bool, false)
-- returns: nothing · limitations: must run BEFORE the saved face/body are applied (it resets
--   drawable slots); preset 3 is the MP base outfit used by the resource
-- tested models: mp_male, mp_female · MP safe: yes · OneSync tested here: no
function WCNative.metaped.equipOutfitPreset(ped, presetId, p2)
    if not H.ped(ped) then return H.fail('equipOutfitPreset', 'invalid ped %s', tostring(ped)) or false end
    local ok = H.invoke(0x77FF8D35EEC6BBC4, ped, math.tointeger(tonumber(presetId) or 0) or 0, p2 == true)
    return ok
end

--- _SET_PED_VARIATION_PRESET (name per research notes, unconfirmed)
-- hash: 0xFFA1594703ED27CA · confidence: Experimental (Config.Experimental.variationPreset, default off)
-- params: ped (entity), presetHash (u32), p2 (int, 0)
-- returns: nothing · limitations: semantics not verified on current builds; not on the production
--   path (the render pipeline uses equipOutfitPreset + explicit components)
-- tested models: none here · MP safe: unknown · OneSync tested here: no
function WCNative.metaped.setVariationPreset(ped, presetHash, p2)
    if not (Config.Experimental and Config.Experimental.variationPreset) then
        return H.fail('setVariationPreset', 'disabled (Config.Experimental.variationPreset)') or false
    end
    if not H.ped(ped) then return H.fail('setVariationPreset', 'invalid ped %s', tostring(ped)) or false end
    local ok = H.invoke(0xFFA1594703ED27CA, ped, WCUtil.u32(presetHash) or 0, math.tointeger(tonumber(p2) or 0) or 0)
    return ok
end

-- ---------------------------------------------------------------------
--  MetaPed asset request lifecycle (Experimental, not on the production path)
--  Players and preview peds are mp_male / mp_female created by model (the verified path). These
--  wrappers exist for research behind Config.Experimental.metapedRequestPath: every request is
--  tracked, waited on with a timeout and always released (on timeout, on release() and on
--  resource stop).
-- ---------------------------------------------------------------------
local requests = {} -- [handle] = true

local function experimentalRequests()
    return Config.Experimental and Config.Experimental.metapedRequestPath == true
end

--- _REQUEST_META_PED_ASSET (name per research notes, unconfirmed)
-- hash: 0xF97C34C33487D569 · confidence: Experimental
-- params: assetHash (u32), p1 (int, 0) · returns: request handle (int, 0/-1 = refused)
-- limitations: handle must be released with 0x3972F78A78B5D9DF
-- tested models: none here · MP safe: unknown · OneSync tested here: no
local function requestAsset(assetHash)
    local ok, handle = H.invoke(0xF97C34C33487D569, assetHash, 0, Citizen.ResultAsInteger())
    if not ok then return nil end
    handle = tonumber(handle)
    if not handle or handle <= 0 then return nil end
    return handle
end

--- _HAS_META_PED_ASSET_LOADED (name per research notes, unconfirmed)
-- hash: 0x43E4DA469541A9C9 · confidence: Experimental
-- params: handle (int) · returns: boolean
-- limitations: only handles tracked by requestPed are queried (anything else returns false)
-- tested models: none here · MP safe: unknown · OneSync tested here: no
function WCNative.metaped.isRequestLoaded(handle)
    if not requests[handle] then return false end
    local ok, loaded = H.invoke(0x43E4DA469541A9C9, handle)
    return ok and H.bool(loaded)
end

--- _IS_META_PED_ASSET_REQUEST_VALID (name per research notes, unconfirmed)
-- hash: 0xC0940AC858C1E126 · confidence: Experimental
-- params: handle (int) · returns: boolean
-- limitations: only handles tracked by requestPed are queried (anything else returns false)
-- tested models: none here · MP safe: unknown · OneSync tested here: no
function WCNative.metaped.isRequestValid(handle)
    if not requests[handle] then return false end
    local ok, valid = H.invoke(0xC0940AC858C1E126, handle)
    return ok and H.bool(valid)
end

--- _RELEASE_META_PED_ASSET_REQUEST (name per research notes, unconfirmed)
-- hash: 0x3972F78A78B5D9DF · confidence: Experimental
-- params: handle (int) · returns: nothing · limitations: idempotent here (tracked handles only)
-- tested models: none here · MP safe: unknown · OneSync tested here: no
function WCNative.metaped.release(handle)
    if not requests[handle] then return false end
    requests[handle] = nil
    local ok = H.invoke(0x3972F78A78B5D9DF, handle)
    return ok
end

--- Request a MetaPed asset and wait (with a timeout) until it is loaded.
--  Returns the request handle, or nil (disabled, refused, invalid or timed out; always released).
function WCNative.metaped.requestPed(assetHash, timeoutMs)
    if not experimentalRequests() then
        return H.fail('requestPed', 'disabled (Config.Experimental.metapedRequestPath)')
    end
    assetHash = WCUtil.u32(assetHash)
    if not assetHash or assetHash == 0 then return H.fail('requestPed', 'invalid asset %s', tostring(assetHash)) end
    local handle = requestAsset(assetHash)
    if not handle then return H.fail('requestPed', 'request refused for %s', tostring(assetHash)) end
    requests[handle] = true
    local loaded = WCUtil.waitUntil(function()
        if not WCNative.metaped.isRequestValid(handle) then return 'invalid' end
        return WCNative.metaped.isRequestLoaded(handle) and 'loaded' or nil
    end, tonumber(timeoutMs) or 5000, 0)
    if loaded ~= 'loaded' then
        WCNative.metaped.release(handle)
        return H.fail('requestPed', 'request %s %s', tostring(assetHash), loaded or 'timed out')
    end
    return handle
end

--- _CREATE_PED_FROM_META_PED_ASSET (name per research notes, unconfirmed)
-- hash: 0x0BCD4091C8EABA42 · confidence: Experimental
-- params: handle (int), x, y, z, heading (float), isNetwork (bool), bScriptHostPed (bool), p7 (bool)
-- returns: ped (entity) or nil · limitations: the request must be loaded; the caller still owns the
--   handle and must release() it
-- tested models: none here · MP safe: unknown · OneSync tested here: no
function WCNative.metaped.createPed(handle, coords, heading, networked)
    if not requests[handle] or not WCNative.metaped.isRequestLoaded(handle) then
        return H.fail('createPed', 'request %s is not loaded', tostring(handle))
    end
    local x, y, z = WCUtil.xyz(coords)
    if not x then return H.fail('createPed', 'invalid coords') end
    local ok, ped = H.invoke(0x0BCD4091C8EABA42, handle, H.float(x), H.float(y), H.float(z), H.float(heading),
        networked == true, false, false, Citizen.ResultAsInteger())
    if not ok or not H.entity(ped) then return H.fail('createPed', 'creation failed') end
    return ped
end

-- ---------------------------------------------------------------------
--  Category discovery (dev tooling only: Config.Admin.devTools, default off)
-- ---------------------------------------------------------------------
local function devTools()
    return Config.Admin and Config.Admin.devTools == true
end

--- _GET_NUM_META_PED_COMPONENT_CATEGORIES (name per research notes, unconfirmed)
-- hash: 0xCCB97B51893C662F · confidence: Experimental (dev tools only: Config.Admin.devTools, default off)
-- params: ped (entity) · returns: int, or nil when dev tools are off / the ped is invalid
-- limitations: read-only; the name and layout are unconfirmed on the current build
-- tested models: none here · MP safe: n/a (read-only) · OneSync tested here: no
function WCNative.metaped.numCategories(ped)
    if not devTools() then return H.fail('numCategories', 'disabled (Config.Admin.devTools)') end
    if not H.ped(ped) then return H.fail('numCategories', 'invalid ped %s', tostring(ped)) end
    local ok, n = H.invoke(0xCCB97B51893C662F, ped, Citizen.ResultAsInteger())
    return ok and tonumber(n) or nil
end

--- _GET_META_PED_COMPONENT_CATEGORY_AT_INDEX (name per research notes, unconfirmed)
-- hash: 0xA622E66EEE92A08D · confidence: Experimental (dev tools only: Config.Admin.devTools, default off)
-- params: ped (entity), index (int) · returns: category hash (u32), or nil when dev tools are off
-- limitations: read-only; index range is 0..numCategories-1; the name and layout are unconfirmed
-- tested models: none here · MP safe: n/a (read-only) · OneSync tested here: no
function WCNative.metaped.categoryAt(ped, index)
    if not devTools() then return H.fail('categoryAt', 'disabled (Config.Admin.devTools)') end
    if not H.ped(ped) then return H.fail('categoryAt', 'invalid ped %s', tostring(ped)) end
    local ok, hash = H.invoke(0xA622E66EEE92A08D, ped, math.tointeger(tonumber(index) or 0) or 0,
        Citizen.ResultAsInteger())
    return ok and WCUtil.u32(hash) or nil
end

AddEventHandler('onResourceStop', function(resource)
    if resource ~= GetCurrentResourceName() then return end
    for handle in pairs(requests) do WCNative.metaped.release(handle) end
end)
