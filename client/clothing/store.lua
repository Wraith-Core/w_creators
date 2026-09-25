-- =====================================================================
--  client/clothing/store.lua  —  WCStore: the clothing store (ARCHITECTURE.md §9.3, §16.4, §17)
--  w_creators:store:open(locationId) -> the fitting room (w_creators:scene:prepare private bucket,
--  fade, the location's preview stand, collision wait) -> WCPreviewEnv -> WCEditor in 'store' mode
--  with the open data as context -> Save: w_creators:store:commit(token, opId, working) -> the
--  committed appearance in WCState, rendered on the player, fitting room left.
--  Cancel, death and a server-forced close (w_creators:client:sessionClosed) restore the snapshot,
--  close the server session and leave the fitting room (coordinates, bucket, HUD, freeze); a
--  resource stop leaves the fitting room without yielding (no render: the next start re-renders
--  the player). WCServiceFlow (client/services/locations.lua) runs the flow.
-- =====================================================================

WCStore = {}
local St = WCStore

local DEFAULT_TITLE = 'متجر الملابس'
local MAX_ID = 64

local function validId(id)
    return type(id) == 'string' and id ~= '' and #id <= MAX_ID
end

--- The editor's onResell hook: sell one owned item back (w_creators:store:resell). The server
--  answers the new ownership list, which the editor takes as its context.
local function resellOp(flow, hash)
    if flow.finished or type(flow.token) ~= 'string' then return WCResult.fail('SESSION_NOT_FOUND') end
    local result = WCServiceFlow.call('w_creators:store:resell', flow.token, hash)
    if result.ok then
        pcall(w.notify, { description = locale(St.SOLD), type = 'success' })
    end
    return result
end
St.SOLD = 'بيعت القطعة'

--- The editor options of a store visit (the open data is the editor context, unchanged).
local function options(flow, data, loc)
    return {
        title = loc and loc.label or DEFAULT_TITLE,
        subtitle = loc and loc.town or nil,
        sections = { clothing = true },
        context = {
            owned = data.owned,
            prices = data.prices,
            priceSpecs = data.priceSpecs,
            currencies = data.currencies,
            tintPrice = data.tintPrice,
            tintPrices = data.tintPrices,
            storeProfile = data.storeProfile,
            pricingProfile = data.pricingProfile,
            -- the saved outfits, to put on only (their contents are checked again at the commit)
            outfits = type(data.outfits) == 'table' and data.outfits or nil,
            outfitsEnabled = data.outfitsEnabled == true,
            maxOutfits = data.maxOutfits,
            resell = data.resell,
            location = loc,
        },
        camera = loc and loc.camera or 'fullBody',
        onResell = function(hash) return resellOp(flow, hash) end,
    }
end

--- What the store's commit carries besides the look: the payment currency and the outfit name.
local function commitExtra(extra)
    if type(extra) ~= 'table' then return nil end
    local out = { currency = extra.currency, outfitName = extra.outfitName }
    if out.currency == nil and out.outfitName == nil then return nil end
    return out
end

--- The working look an outfit card opens the store with (Config.Clothing.items): the saved look
--  with the card's pieces put on, only those the character owns or this store sells, through the
--  compatibility rules; each in the card's colour when the store may sell that colour. The store's
--  commit prices and checks it like any other look. nil when nothing of the card can be worn here.
function St.lookOf(data, look)
    if type(look) ~= 'table' or type(look.equipped) ~= 'table' or type(data) ~= 'table' then return nil end
    local app = type(data.appearance) == 'table' and WCUtil.copy(data.appearance) or nil
    if not app or type(app.clothing) ~= 'table' then return nil end
    local sex, owned = app.sex, type(data.owned) == 'table' and data.owned or {}
    local worn = {}
    for category, hash in pairs(look.equipped) do
        local h = type(category) == 'string' and WCCatalog.isClothing(category) and WCCatalog.resolve(sex, category, hash)
        if h and (owned[tostring(h)] or WCCatalog.available(data.storeProfile, sex, category, h)) then
            worn[category] = h
        end
    end
    worn = WCRules.normalize(worn)
    if next(worn) == nil then return nil end
    for category, hash in pairs(app.clothing.equipped) do
        if not WCRules.canRemove(category) and worn[category] == nil then worn[category] = hash end
    end
    local tints = {}
    for category in pairs(worn) do
        local tint = type(look.tints) == 'table' and look.tints[category] or nil
        if type(tint) == 'table' and WCCatalog.validTint(category, tint) then tints[category] = WCUtil.copy(tint) end
    end
    app.clothing.equipped, app.clothing.tints, app.clothing.outfit = worn, tints, nil
    return app
end

--- Open the clothing store of a location. Yields (call it from a thread); returns true once the
--  editor is open, or false, code (the failure's message has been shown, except to a dead player).
--  A refusal because another flow holds the player is shown here: WCServiceFlow.run only logs it,
--  and on the server-opened path (the OpenClothingStore export) nothing else would.
--  look (an outfit card, sent by the server): { equipped, tints } tried on when the editor opens.
---@param locationId string
---@param look? table
---@return boolean ok, string|nil code
function St.open(locationId, look)
    if not validId(locationId) then
        WCServiceFlow.notify(WCResult.messageKey('INVALID_PAYLOAD'))
        return false, 'INVALID_PAYLOAD'
    end
    local why = WCServiceFlow.blocked()
    if why then
        if why ~= 'dead' then WCServiceFlow.notify(WCResult.messageKey('BUSY')) end
        return false, 'BUSY'
    end
    local build = options
    if type(look) == 'table' then
        build = function(flow, data, loc)
            local opts = options(flow, data, loc)
            opts.working = St.lookOf(data, look)
            -- the ped must show the card's look before the editor diffs from it
            if opts.working then opts.render = true end
            return opts
        end
    end
    return WCServiceFlow.run({
        kind = 'store', mode = 'store', locationId = locationId,
        open = 'w_creators:store:open', commit = 'w_creators:store:commit',
        fittingRoom = true, options = build, commitExtra = commitExtra,
    })
end

--- Is a store visit running?
function St.busy()
    local flow = WCServiceFlow.current()
    return flow ~= nil and flow.kind == 'store'
end

-- Server export OpenClothingStore (§13) and an outfit card used at a store (its look): the open
-- callback re-validates everything, and the store's commit prices the look.
RegisterNetEvent('w_creators:client:openStore', function(locationId, look)
    CreateThread(function() St.open(locationId, type(look) == 'table' and look or nil) end)
end)
