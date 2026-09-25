-- =====================================================================
--  client/wardrobe/wardrobe.lua  —  WCWardrobe: wearing owned clothing and saved outfits
--  (ARCHITECTURE.md §5.6, §9.3, §13, §16.4, §17)
--  w_creators:wardrobe:open(locationId | nil = remote) -> frozen in place (WCPreviewEnv, no
--  teleport) -> WCEditor in 'wardrobe' mode (clothing + states) with the open data as context ->
--  Save: w_creators:wardrobe:commit(token, opId, working).
--  Outfits: the editor's onOutfit hook calls w_creators:outfits:save|update|rename|delete with the
--  session token and the editor's working equipped items / states; 'equip' is applied locally (the
--  result is saved by the wardrobe commit). Clothing states only change the working preview; they
--  are committed with the wardrobe commit.
--  Cancel, death, a server-forced close and resource stop are handled by WCServiceFlow
--  (client/services/locations.lua).
-- =====================================================================

WCWardrobe = {}
local Wd = WCWardrobe

local DEFAULT_TITLE = 'الخزانة'
local MAX_ID = 64

local OUTFIT_CALLS = {
    save = 'w_creators:outfits:save',
    update = 'w_creators:outfits:update',
    rename = 'w_creators:outfits:rename',
    delete = 'w_creators:outfits:delete',
    share = 'w_creators:outfits:share',
}

--- The clothes an outfit operation sends: those the editor passed, else its working appearance.
--  tints: each item's colour (a tint, or false for its original colour; colourways).
local function clothesOf(value)
    local v = type(value) == 'table' and value or {}
    local working = WCEditor.working() or {}
    local clothing = type(working.clothing) == 'table' and working.clothing or {}
    local equipped = type(v.equipped) == 'table' and v.equipped or clothing.equipped or {}
    local states = type(v.states) == 'table' and v.states or clothing.states or {}
    local tints = type(v.tints) == 'table' and v.tints or nil
    return equipped, states, tints
end

--- The editor's onOutfit hook (§3.2, §5.6). 'equip' is a veto hook: nil lets the editor apply the
--  owned outfit to the working appearance. The others answer the server's Result; its outfit list
--  replaces the context's.
local function outfitOp(flow, context, op, id, value)
    if op == 'equip' then return nil end
    local name = OUTFIT_CALLS[op]
    if not name then return WCResult.fail('INVALID_PAYLOAD') end
    if flow.finished or type(flow.token) ~= 'string' then return WCResult.fail('SESSION_NOT_FOUND') end
    local result
    if op == 'save' then
        if type(value) ~= 'table' or type(value.name) ~= 'string' then return WCResult.fail('INVALID_OUTFIT_NAME') end
        local equipped, states, tints = clothesOf(value)
        result = WCServiceFlow.call(name, flow.token, value.name, equipped, states, tints)
    elseif op == 'update' then
        local equipped, states, tints = clothesOf(value)
        result = WCServiceFlow.call(name, flow.token, id, equipped, states, tints)
    elseif op == 'rename' then
        if type(value) ~= 'string' then return WCResult.fail('INVALID_OUTFIT_NAME') end
        result = WCServiceFlow.call(name, flow.token, id, value)
    else
        result = WCServiceFlow.call(name, flow.token, id)
    end
    if result.ok and type(result.data) == 'table' and type(result.data.outfits) == 'table' then
        context.outfits = result.data.outfits
    end
    return result
end

--- The editor's onState hook: a valid state only changes the working preview (nil lets the editor
--  apply it); it is saved by the wardrobe commit.
local function stateOp(groupId, value)
    if not WCClothingStates.isValid(groupId, value) then return WCResult.fail('STATE_NOT_SUPPORTED') end
    return nil
end

--- The editor's onResell hook (Config.Clothing.resell.inWardrobe): sell an owned item back.
local function resellOp(flow, hash)
    if flow.finished or type(flow.token) ~= 'string' then return WCResult.fail('SESSION_NOT_FOUND') end
    return WCServiceFlow.call('w_creators:store:resell', flow.token, hash)
end

--- The editor's onItem hook (Config.Clothing.items): wrap an owned item into an inventory item.
local function itemOp(flow, op, hash)
    if op ~= 'wrap' then return WCResult.fail('INVALID_PAYLOAD') end
    if flow.finished or type(flow.token) ~= 'string' then return WCResult.fail('SESSION_NOT_FOUND') end
    return WCServiceFlow.call('w_creators:wardrobe:wrap', flow.token, hash)
end

local function options(flow, data, loc)
    local context = {
        owned = data.owned,
        outfits = type(data.outfits) == 'table' and data.outfits or {},
        maxOutfits = data.maxOutfits,
        outfitsEnabled = data.outfitsEnabled,
        remote = data.remote,
        resell = data.resell,
        location = loc,
    }
    return {
        title = loc and loc.label or DEFAULT_TITLE,
        subtitle = loc and loc.town or nil,
        sections = { clothing = true, states = true },
        context = context,
        camera = loc and loc.camera or 'fullBody',
        onOutfit = function(op, id, value) return outfitOp(flow, context, op, id, value) end,
        onState = function(groupId, value) return stateOp(groupId, value) end,
        onResell = function(hash) return resellOp(flow, hash) end,
        onItem = function(op, hash) return itemOp(flow, op, hash) end,
    }
end

--- Open a wardrobe: a location id, or nil for a remote wardrobe (job resources, housing; the
--  server decides with Config.Wardrobe.allowRemote). Yields; returns true once the editor is open,
--  or false, code (the failure's message has been shown, except to a dead player). A refusal
--  because another flow holds the player is shown here: WCServiceFlow.run only logs it, and on the
--  remote paths (the OpenWardrobe exports) nothing else would.
---@param locationId string|nil
---@return boolean ok, string|nil code
function Wd.open(locationId)
    if locationId ~= nil and (type(locationId) ~= 'string' or locationId == '' or #locationId > MAX_ID) then
        WCServiceFlow.notify(WCResult.messageKey('INVALID_PAYLOAD'))
        return false, 'INVALID_PAYLOAD'
    end
    local why = WCServiceFlow.blocked()
    if why then
        if why ~= 'dead' then WCServiceFlow.notify(WCResult.messageKey('BUSY')) end
        return false, 'BUSY'
    end
    return WCServiceFlow.run({
        kind = 'wardrobe', mode = 'wardrobe', locationId = locationId,
        open = 'w_creators:wardrobe:open', commit = 'w_creators:wardrobe:commit',
        fittingRoom = false, options = options,
    })
end

--- Is a wardrobe visit running?
function Wd.busy()
    local flow = WCServiceFlow.current()
    return flow ~= nil and flow.kind == 'wardrobe'
end

-- Server export OpenWardrobe (§13): the open callback re-validates everything.
RegisterNetEvent('w_creators:client:openWardrobe', function(locationId)
    CreateThread(function() Wd.open(locationId) end)
end)

-- The client export used by job resources (kept, §13). The flow waits on the server, so it runs
-- in its own thread rather than inside the caller's export call.
exports('OpenWardrobe', function(locationId)
    CreateThread(function() Wd.open(locationId) end)
    return true
end)
