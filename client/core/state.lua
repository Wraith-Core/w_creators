-- =====================================================================
--  client/core/state.lua  —  WCState (ARCHITECTURE.md §3.2)
--  The local client's character state: the active character, its saved v3 appearance, and the
--  named client locks that keep two flows (editor, selection, spawn, respawn, clothing action,
--  service visit) from running at the same time.
-- =====================================================================

WCState = {
    character = nil,  -- { charid, sex } or nil
    appearance = nil, -- the saved v3 appearance of the local character (never the editor's working copy)
}

--- The named client locks. Any string is accepted; these are the ones the contract names.
WCState.LOCKS = {
    editor = true, selection = true, spawn = true, respawn = true, clothingAction = true,
    service = true, -- a store / wardrobe / barber / surgery visit (WCServiceFlow.LOCK)
}

local locks = {}

--- Store the saved appearance of the local character (a copy: callers keep their own table).
--  The character's sex follows the appearance.
---@param app table|nil
function WCState.set(app)
    if type(app) ~= 'table' then
        WCState.appearance = nil
        return
    end
    WCState.appearance = WCUtil.copy(app)
    if WCState.character and type(app.sex) == 'string' then
        WCState.character.sex = app.sex
    end
end

--- The saved appearance (a copy), or nil.
function WCState.get()
    if not WCState.appearance then return nil end
    return WCUtil.copy(WCState.appearance)
end

--- Set (or clear with nil) the active character { charid, sex }.
function WCState.setCharacter(charid, sex)
    if charid == nil then
        WCState.character = nil
        return
    end
    WCState.character = { charid = charid, sex = sex }
end

--- Forget the character and its appearance (character switch, logout).
function WCState.clear()
    WCState.character = nil
    WCState.appearance = nil
end

--- A named client lock.
--    busy(name)         -> boolean: is it held?
--    busy(name, true)   -> boolean: acquired (false when it was already held)
--    busy(name, false)  -> true: released
---@param name string
---@param value? boolean
---@return boolean
function WCState.busy(name, value)
    if type(name) ~= 'string' then return false end
    if value == nil then return locks[name] == true end
    if value then
        if locks[name] then return false end
        locks[name] = true
        return true
    end
    locks[name] = nil
    return true
end

--- Is any appearance editor open (the editor lock, or an open WCEditor session)?
function WCState.inEditor()
    if locks.editor then return true end
    local editor = WCEditor
    if type(editor) == 'table' and type(editor.session) == 'function' then
        local ok, session = pcall(editor.session)
        if ok and session then return true end
    end
    return false
end
