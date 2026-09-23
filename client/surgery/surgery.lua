-- =====================================================================
--  client/surgery/surgery.lua  —  WCSurgery: the cosmetic surgery clinic
--  (ARCHITECTURE.md §9.3, §13, §16.4, §17)
--  w_creators:surgery:open(clinicId) -> in place (or the clinic's `preview` seat: WCServiceSeat) ->
--  WCPreviewEnv -> WCEditor in 'surgery' mode (the "Confirm procedure" / procedure cost copy is the
--  editor's surgery mode) with the open data as context (price, allow, owned when the clinic allows
--  clothing) -> Save: w_creators:surgery:commit(token, opId, working) -> the committed appearance in
--  WCState, rendered on the player.
--  Cancel, death, a server-forced close, an editor closed elsewhere and resource stop restore the
--  snapshot (the character is never left half-modified), close the server session and undo the
--  preview: WCServiceFlow (client/services/locations.lua) runs the flow.
--
--  Opening a clinic:
--    * w_creators:client:openSurgery(clinicId): sent by the server export OpenCosmeticSurgery
--      (w_ambulancejob's station prompt -> its server -> exports.w_creators:OpenCosmeticSurgery), which
--      gives the player a one-use grant; clinics with prompt = false open only this way.
--    * WCSurgery.open(clinicId) / the client export OpenCosmeticSurgery(clinicId) (client/api.lua):
--      clinics with their own prompt (prompt = true). Without a grant the server refuses a
--      prompt-less clinic (SURGERY_NOT_ALLOWED) and the message is shown.
-- =====================================================================

WCSurgery = {}
local S = WCSurgery

local TITLE = 'عيادة التجميل'   -- "Cosmetic surgery"
local MAX_ID = 64

local function validId(id)
    return type(id) == 'string' and id ~= '' and #id <= MAX_ID
end

--- The editor context of a clinic visit: the open data as the server sent it (price, allow, owned
--  when the clinic allows clothing, sections), the location record instead of its id.
local function contextOf(data, loc)
    return {
        price = data.price,
        allow = data.allow,
        owned = data.owned,
        sections = data.sections,
        expiresIn = data.expiresIn,
        clinic = data.clinic,
        location = loc,
    }
end

--- The subtitle: the clinic's town, else its label when it differs from the title.
local function subtitleOf(loc)
    if not loc then return nil end
    if type(loc.town) == 'string' and loc.town ~= '' then return loc.town end
    if type(loc.label) == 'string' and loc.label ~= '' and loc.label ~= TITLE then return loc.label end
    return nil
end

local function options(flow, data, loc)
    if loc and loc.preview ~= nil and loc.preview ~= false then WCServiceSeat.take(flow, loc.preview) end
    return {
        title = TITLE,
        subtitle = subtitleOf(loc),
        -- the server's set of sections this clinic may change (Config.CosmeticSurgery.allow), unchanged
        sections = data.sections,
        context = contextOf(data, loc),
        camera = loc and loc.camera or 'face',
    }
end

--- Open a cosmetic surgery clinic. Yields (call it from a thread); returns true once the editor is
--  open, or false, code (the failure's message has been shown, except to a dead player).
--  A refusal because another flow holds the player is shown here: WCServiceFlow.run only logs it,
--  and on the server-opened paths (events, the OpenCosmeticSurgery export) nothing else would.
---@param clinicId string
---@return boolean ok, string|nil code
function S.open(clinicId)
    if not validId(clinicId) then
        WCServiceFlow.notify(WCResult.messageKey('INVALID_PAYLOAD'))
        return false, 'INVALID_PAYLOAD'
    end
    local why = WCServiceFlow.blocked()
    if why then
        if why ~= 'dead' then WCServiceFlow.notify(WCResult.messageKey('BUSY')) end
        return false, 'BUSY'
    end
    return WCServiceFlow.run({
        kind = 'surgery', mode = 'surgery', locationId = clinicId,
        open = 'w_creators:surgery:open', commit = 'w_creators:surgery:commit',
        fittingRoom = false, options = options,
    })
end

--- Is a clinic visit running (including the way back from the clinic's seat)?
function S.busy()
    local flow = WCServiceFlow.current()
    if flow ~= nil and flow.kind == 'surgery' then return true end
    return WCServiceSeat.kind() == 'surgery'
end

-- Server export OpenCosmeticSurgery (§13, §17): the server has issued a one-use grant for this
-- clinic; the open callback consumes it and re-validates service, clinic, proximity and price.
RegisterNetEvent('w_creators:client:openSurgery', function(clinicId)
    CreateThread(function() S.open(clinicId) end)
end)
