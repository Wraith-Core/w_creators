-- =====================================================================
--  multichar/server.lua
--  The character selection screen's logic: the listing, the selection (logging in + applying the appearance
--  + the spawn), and the deletion. It only runs when Config.Multicharacter = true.
-- =====================================================================

if not Config.Multicharacter then return end

--- Making sure the character really belongs to this player (protection against tampering).
local function ownsCharacter(source, charid)
    for _, c in ipairs(Bridge.GetCharacters(source)) do
        if c.charid == charid then return true end
    end
    return false
end

--- Reading one character's appearance to build the preview ped in the selection screen.
--  The decoding is protected with a pcall: one corrupt row must not bring the whole screen down.
local function readAppearance(charid)
    -- The query itself is protected as well: a missing characters_appearence table or a failed query
    -- used to throw outside the callback so the client's wait hung with no message.
    local ok, rows = pcall(w.database.query.await,
        'SELECT isMale, faceFeatures, overlays, components FROM characters_appearence WHERE charid = ? ORDER BY id DESC LIMIT 1',
        { charid })
    if not ok then
        print(('^1[w_creators] reading the appearance failed (%s): %s^0'):format(tostring(charid), tostring(rows)))
        return nil
    end
    local row = rows and rows[1]
    if not row then return nil end

    local function decode(raw)
        if type(raw) ~= 'string' or raw == '' then return nil end
        local ok, value = pcall(json.decode, raw)
        if ok then return value end
        return nil
    end

    return {
        isMale = row.isMale,
        faceFeatures = decode(row.faceFeatures),
        overlays = decode(row.overlays),
        -- components is passed as a raw JSON string because SetSkin decodes it itself
        components = row.components,
    }
end

-- Listing the player's characters + the number of slots + each character's appearance (for the preview ped)
w.callback.register('w_creators:getCharacters', function(source)
    -- The client waits for this call with await and no timeout: were it to throw, no answer would ever arrive
    -- and the selection screen would stay black with no message. So we guarantee an answer in every case.
    local ok, characters = pcall(Bridge.GetCharacters, source)
    if not ok or type(characters) ~= 'table' then
        print(('^1[w_creators] could not list the characters: %s^0'):format(tostring(characters)))
        characters = {}
    end

    for i = 1, #characters do
        characters[i].appearance = readAppearance(characters[i].charid)
    end
    return {
        characters = characters,
        slots = Config.CharacterSlots,
        canDelete = Config.EnableDelete,
    }
end)

-- Picking an existing character: logging in then applying the appearance then the spawn
RegisterNetEvent('w_creators:server:selectCharacter', function(charid)
    local _source = source
    if not ownsCharacter(_source, charid) then
        print(('^1[w_creators] the player %s tried to pick a character he does not own.^0'):format(_source))
        CreatorLogs.Emit('character_access_denied', {
            playerSource = _source, charid = tostring(charid),
            operation = 'select',
            reason = 'حدث selectCharacter بهوية لا يملكها اللاعب',
        })
        return
    end

    Bridge.LoginCharacter(_source, charid)
    Wait(300)

    w.database.query('SELECT * FROM characters_appearence WHERE charid = @charid ORDER BY id DESC LIMIT 1', {
        ['@charid'] = charid
    }, function(result)
        CreatorLogs.Emit('character_selected', {
            playerSource = _source, charid = tostring(charid),
            appearanceFound = result[1] ~= nil, framework = Bridge.Name,
            reason = 'اختيار من شاشة الشخصيات',
        })
        if not result[1] then
            -- No saved look (a creation whose save failed): back into the creator for this
            -- character; the creator saves the appearance and spawns him from there.
            TriggerClientEvent('W:CHARCREATION:starting', _source, { appearanceOnly = true })
            return
        end

        local appearance = {
            isMale = result[1].isMale,
            faceFeatures = json.decode(result[1].faceFeatures),
            overlays = json.decode(result[1].overlays),
            components = result[1].components
        }
        TriggerClientEvent('PersonaCreatorHandler.applyCharacterAppearance', _source, appearance)
        -- and the other players see it too, not its owner alone
        BroadcastAppearance(_source, appearance)
        Bridge.FinishCharacter(_source, false)
    end)
end)

-- Deleting a character
RegisterNetEvent('w_creators:server:deleteCharacter', function(charid)
    local _source = source
    if not Config.EnableDelete then return end
    if not ownsCharacter(_source, charid) then
        CreatorLogs.Emit('character_access_denied', {
            playerSource = _source, charid = tostring(charid),
            operation = 'delete',
            reason = 'حدث deleteCharacter بهوية لا يملكها اللاعب',
        })
        return
    end
    Bridge.DeleteCharacter(_source, charid)
    Bridge.Notify(_source, 'تم حذف الشخصية.', 'success')
end)
