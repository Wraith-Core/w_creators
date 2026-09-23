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

--- The editor options of a store visit (the open data is the editor context, unchanged).
local function options(_, data, loc)
    return {
        title = loc and loc.label or DEFAULT_TITLE,
        subtitle = loc and loc.town or nil,
        sections = { clothing = true },
        context = {
            owned = data.owned,
            prices = data.prices,
            tintPrice = data.tintPrice,
            storeProfile = data.storeProfile,
            pricingProfile = data.pricingProfile,
            location = loc,
        },
        camera = loc and loc.camera or 'fullBody',
    }
end

--- Open the clothing store of a location. Yields (call it from a thread); returns true once the
--  editor is open, or false, code (the failure's message has been shown).
---@param locationId string
---@return boolean ok, string|nil code
function St.open(locationId)
    if not validId(locationId) then return false, 'INVALID_PAYLOAD' end
    return WCServiceFlow.run({
        kind = 'store', mode = 'store', locationId = locationId,
        open = 'w_creators:store:open', commit = 'w_creators:store:commit',
        fittingRoom = true, options = options,
    })
end

--- Is a store visit running?
function St.busy()
    local flow = WCServiceFlow.current()
    return flow ~= nil and flow.kind == 'store'
end

-- Server export OpenClothingStore (§13): the open callback re-validates everything.
RegisterNetEvent('w_creators:client:openStore', function(locationId)
    CreateThread(function() St.open(locationId) end)
end)
