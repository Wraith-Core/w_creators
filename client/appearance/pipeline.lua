-- =====================================================================
--  client/appearance/pipeline.lua  —  Appearance: the one render pipeline (ARCHITECTURE.md §3.2)
--  Every ped that shows a character (the player, a preview ped, a remote player) is rendered by
--  Appearance.RestoreCharacter from a v3 appearance (§5.1), in one fixed order:
--
--    validate ped + model → outfit preset 3 → commit + ready → strip clothes → BODIES_LOWER,
--    BODIES_UPPER → heads, eyes, teeth → hair → facial hair → waist type → scale → clothing
--    (Config.Clothing.applyOrder, tints, hidden visibility states skipped) → wearable clothing
--    states (inapplicable ones reset to base) → body commit + ready → morph (reset every channel,
--    then the values) → final refresh + ready → overlays (w.pedTexture, on the committed head).
--
--  The features are batched: nothing refreshes the ped per feature (audit A11). There are three
--  structural commits: the preset (it resets the drawable slots and must be committed before the
--  saved face and body go on), the body (the waist outfit must be committed before the morph, as
--  in w_lib's applySkin and the pre-v3 pipeline) and the final one. The overlays come last because
--  w.pedTexture builds the face texture on the head the ped carries at that moment.
--  Component hashes go through the w_lib wrappers (w.component.*); raw natives through WCNative.
-- =====================================================================

Appearance = {}
local A = Appearance

--- The facial hair category: 'mustache' in the catalogue is the beards_complete metaped category.
A.FACIAL_HAIR_CATEGORY = 0xF8016BCA

--- The waist type outfit hashes (body.weight is the 1-based index): AppearanceSchema.WAIST_TYPES.
A.WAIST_TYPES = AppearanceSchema.WAIST_TYPES

A.PRESET = 3                -- the MP base outfit preset the resource has always used
A.READY_TIMEOUT = 10000     -- ms to wait for the metaped to become ready to render
A.PED_WAIT_TIMEOUT = 15000  -- ms a second restore of the same ped waits for the first one
A.MODEL_TIMEOUT = 15000     -- ms to stream the player model

local BODY_ORDER = { 'BODIES_LOWER', 'BODIES_UPPER' }
local HEAD_ORDER = { 'heads', 'eyes', 'teeth' }

-- ---------------------------------------------------------------------
--  Small helpers
-- ---------------------------------------------------------------------
local function pedExists(ped)
    return type(ped) == 'number' and ped ~= 0 and DoesEntityExist(ped) == true
end

--- The w_lib category argument of a catalogue category.
local function categoryArg(category)
    if category == 'mustache' then return A.FACIAL_HAIR_CATEGORY end
    return category
end

local function modelOf(sex)
    return GetHashKey('mp_' .. tostring(sex))
end

local function sameModel(a, b)
    return WCUtil.u32(a) ~= nil and WCUtil.u32(a) == WCUtil.u32(b)
end

--- A v3 appearance: taken as it is when it already is one (the server sanitised it), otherwise
--  normalised (legacy row, JSON string).
local function v3(app)
    if type(app) == 'table' and tonumber(app.version) == AppearanceSchema.VERSION and type(app.sex) == 'string'
        and type(app.body) == 'table' and type(app.head) == 'table' then
        return app
    end
    if app == nil then return nil end
    return (AppearanceSchema.normalize(app))
end

local function tbl(v) return type(v) == 'table' and v or {} end

local function equippedOf(app) return tbl(tbl(app.clothing).equipped) end
local function tintsOf(app) return tbl(tbl(app.clothing).tints) end

--- Is a clothing category hidden by a visibility state of the appearance?
local function hiddenByState(app, category)
    for _, group in ipairs(WCClothingStates.groups) do
        if group.mechanism == 'visibility' and WCClothingStates.current(app, group.id) == 'off' then
            for _, c in ipairs(group.categories) do
                if c == category then return true end
            end
        end
    end
    return false
end

--- The clothing categories to render, in Config.Clothing.applyOrder (then any other equipped
--  clothing category, sorted, so nothing equipped is silently dropped).
local function clothingOrder(equipped)
    local out, seen = {}, {}
    local order = Config.Clothing and Config.Clothing.applyOrder or {}
    for _, category in ipairs(order) do
        if not seen[category] and WCCatalog.isClothing(category) then
            out[#out + 1] = category
            seen[category] = true
        end
    end
    local extra = {}
    for category in pairs(equipped) do
        if not seen[category] and WCCatalog.isClothing(category) then extra[#extra + 1] = category end
    end
    table.sort(extra)
    for _, category in ipairs(extra) do out[#out + 1] = category end
    return out
end

--- The visible clothing of an appearance: { [category] = { hash, tint } } (hidden states removed).
local function visibleClothing(app)
    local out = {}
    local equipped, tints = equippedOf(app), tintsOf(app)
    for category, hash in pairs(equipped) do
        if hash and hash ~= 0 and not hiddenByState(app, category) then
            out[category] = { hash = hash, tint = tints[category] }
        end
    end
    return out
end

-- ---------------------------------------------------------------------
--  Readiness
-- ---------------------------------------------------------------------

--- The minimum distance (m) between the head bone and the entity origin of a rendered skeleton.
A.MIN_HEAD_DISTANCE = 0.2

--- Is the ped rendered: the metaped reports ready AND the skeleton is not collapsed (a zero-scale
--  skeleton can report ready with every bone at the origin). The test is a distance, not a height,
--  so a ped that is lying, downed, hogtied or ragdolled (head level with its origin) is ready.
function A.IsReady(ped)
    if not pedExists(ped) then return false end
    if not WCNative.metaped.isReadyToRender(ped) then return false end
    local origin = GetEntityCoords(ped)
    local head = GetPedBoneCoords(ped, 21030, 0.0, 0.0, 0.0)
    if not origin or not head then return false end
    local dx, dy, dz = head.x - origin.x, head.y - origin.y, head.z - origin.z
    return (dx * dx + dy * dy + dz * dz) > A.MIN_HEAD_DISTANCE * A.MIN_HEAD_DISTANCE
end

--- Wait (condition wait with a timeout) until the ped is rendered. Returns true when ready.
function A.WaitReady(ped, timeoutMs)
    return WCUtil.waitUntil(function() return A.IsReady(ped) end, tonumber(timeoutMs) or A.READY_TIMEOUT, 0) == true
end

-- ---------------------------------------------------------------------
--  Single operations (no refresh: the caller batches, then Appearance.Refresh once)
-- ---------------------------------------------------------------------

--- Apply one component hash (with an optional tint) through w_lib.
--  A hash the engine does not know for this ped is reported, never thrown.
---@param ped integer
---@param category string catalogue category ('mustache' maps to beards_complete)
---@param hash integer
---@param tint? table { palette, tint0, tint1, tint2 }
---@return boolean ok, string|nil err
function A.ApplyComponent(ped, category, hash, tint)
    if not pedExists(ped) then return false, 'INVALID_PED' end
    hash = tonumber(hash)
    if not hash or hash == 0 then return false, 'INVALID_COMPONENT' end
    local okCat, catHash = pcall(w.component.getComponentCategory, ped, hash)
    if not okCat or not catHash or catHash == 0 then
        WCDebug.log('appearance', 'unknown component %s for %s', tostring(hash), tostring(category))
        return false, 'INVALID_COMPONENT'
    end
    local data = { hash = hash }
    if type(tint) == 'table' and type(tint.palette) == 'string' and tint.palette ~= '' then
        data.palette = tint.palette
        data.tint0 = math.tointeger(tonumber(tint.tint0)) or 0
        data.tint1 = math.tointeger(tonumber(tint.tint1)) or 0
        data.tint2 = math.tointeger(tonumber(tint.tint2)) or 0
    end
    local ok, err = pcall(w.component.apply, ped, categoryArg(category), data)
    if not ok then
        WCDebug.warn('appearance', 'could not apply %s to %s: %s', tostring(hash), tostring(category), tostring(err))
        return false, 'INVALID_COMPONENT'
    end
    return true
end

--- Remove a category from the ped through w_lib.
---@return boolean
function A.RemoveCategory(ped, category)
    if not pedExists(ped) then return false end
    local ok, err = pcall(w.component.remove, ped, categoryArg(category))
    if not ok then WCDebug.log('appearance', 'remove %s failed: %s', tostring(category), tostring(err)) end
    return ok
end

--- The one batched refresh, then wait until the ped is rendered.
---@return boolean ready
function A.Refresh(ped, timeoutMs)
    if not pedExists(ped) then return false end
    WCNative.ped.refresh(ped)
    return A.WaitReady(ped, timeoutMs)
end

--- The waist type (body weight): the outfit hash of WAIST_TYPES[weight]. The named metaped outfit
--  native is used so the waist joins the batch; w_lib's setWaistType (which refreshes on its own)
--  is the fallback when the named native is unavailable.
function A.SetWaist(ped, weight)
    local index = WCUtil.int(weight, 1, #A.WAIST_TYPES, 11)
    local hash = A.WAIST_TYPES[index]
    local named = EquipMetaPedOutfit
    if named then
        local ok = pcall(named, ped, hash)
        if ok then return true end
    end
    return (pcall(w.component.setWaistType, ped, hash))
end

--- The ped scale (height); always a float (an integer collapses every bone to the origin).
function A.SetHeight(ped, height)
    return WCNative.ped.setScale(ped, WCUtil.number(height, 0.9, 1.1, 1.0) + 0.0)
end

--- Morphology: every WCMorph channel back to 0.0, then the appearance's values (floats).
function A.ApplyMorph(ped, morph)
    for _, field in ipairs(WCMorph.fields) do
        WCNative.ped.setExpression(ped, field.expression, 0.0)
    end
    for id, value in pairs(tbl(morph)) do
        local field = WCMorph.byId[id]
        local n = tonumber(value)
        if field and n and n ~= 0 then
            WCNative.ped.setExpression(ped, field.expression, WCUtil.number(n, -1, 1, 0) + 0.0)
        end
    end
end

--- Apply one clothing state without animation (used by the restore and the state controller).
--    visibility: 'off' removes every category of the group from the ped; any other value
--                re-applies the equipped hash (+ tint). app.clothing.equipped is never changed.
--    wearable:   the w_lib wearable state (setWearableState) or the w_lib shirt helpers
--                (sleeveRoll / sleeveUnroll / collarOpen / collarClose).
--  Does not refresh: callers outside the pipeline follow with Appearance.Refresh(ped).
---@return boolean ok, string|nil err (STATE_NOT_SUPPORTED | INVALID_PAYLOAD | STATE_NOT_APPLICABLE | INVALID_PED)
function A.ApplyClothingState(ped, app, groupId, value)
    if not pedExists(ped) then return false, 'INVALID_PED' end
    local group = WCClothingStates.byId[groupId]
    if not group then return false, 'STATE_NOT_SUPPORTED' end
    if not WCClothingStates.isValid(groupId, value) then return false, 'INVALID_PAYLOAD' end
    if type(app) ~= 'table' then return false, 'STATE_NOT_APPLICABLE' end
    local category = WCClothingStates.category(app, groupId)
    if not category then return false, 'STATE_NOT_APPLICABLE' end
    local equipped, tints = equippedOf(app), tintsOf(app)
    local hash = equipped[category]

    if group.mechanism == 'visibility' then
        if value == 'off' then
            for _, c in ipairs(group.categories) do
                if equipped[c] and equipped[c] ~= 0 then A.RemoveCategory(ped, c) end
            end
            return true
        end
        return A.ApplyComponent(ped, category, hash, tints[category])
    end

    if group.mechanism == 'wearable' then
        if not WCClothingStates.applicable(app, groupId) then return false, 'STATE_NOT_APPLICABLE' end
        local ok, err
        if type(group.lib) == 'table' and group.lib[value] then
            local fn = w.component[group.lib[value]]
            if not fn then return false, 'STATE_NOT_SUPPORTED' end
            ok, err = pcall(fn, ped, hash)
        elseif type(group.wearable) == 'table' and group.wearable[value] then
            ok, err = pcall(w.component.setWearableState, ped, category, hash, group.wearable[value])
        else
            return false, 'STATE_NOT_SUPPORTED'
        end
        if not ok then
            WCDebug.warn('appearance', 'state %s=%s failed: %s', tostring(groupId), tostring(value), tostring(err))
            return false, 'STATE_NOT_SUPPORTED'
        end
        return true
    end
    return false, 'STATE_NOT_SUPPORTED'
end

--- Put an equipped wearable component whose group cannot act (its requirement is missing, e.g.
--  boots without pants) back to its base state: w_lib remembers the last non-base state per
--  category on the ped and re-applies it whenever the component goes back on.
local function resetWearable(ped, app, group)
    local category = WCClothingStates.category(app, group.id)
    if not category then return false end
    local hash = equippedOf(app)[category]
    local ok, err
    if type(group.lib) == 'table' then
        local fn = w.component[group.lib[group.default] or '']
        if not fn then return false end
        ok, err = pcall(fn, ped, hash)
    elseif type(group.wearable) == 'table' then
        ok, err = pcall(w.component.setWearableState, ped, category, hash, 'base')
    else
        return false
    end
    if not ok then WCDebug.log('appearance', 'state %s reset failed: %s', tostring(group.id), tostring(err)) end
    return ok
end

--- Every wearable state of the appearance: applicable groups get their value (defaults included:
--  w_lib re-applies a remembered non-base state when a component goes back on, so the stored value
--  is always set); equipped but inapplicable groups are reset to the base state.
local function applyWearableStates(ped, app, only)
    for _, group in ipairs(WCClothingStates.groups) do
        if group.mechanism == 'wearable' and (not only or only[group.id]) then
            if WCClothingStates.applicable(app, group.id) then
                A.ApplyClothingState(ped, app, group.id, WCClothingStates.current(app, group.id))
            else
                resetWearable(ped, app, group)
            end
        end
    end
end

--- The overlay layer (w.pedTexture) application, provided by client/appearance/overlays.lua.
local function applyOverlays(ped, app)
    if A.Overlays and A.Overlays.apply then return A.Overlays.apply(ped, app) end
    return false
end

-- ---------------------------------------------------------------------
--  Per-ped serialisation: two restores of one ped never interleave
-- ---------------------------------------------------------------------
local running = {}

local function acquire(ped)
    if running[ped] then
        WCUtil.waitUntil(function() return not running[ped] end, A.PED_WAIT_TIMEOUT, 0)
        if running[ped] then return false end
    end
    running[ped] = true
    return true
end

local function release(ped) running[ped] = nil end

--- Validate the ped and the model against the appearance's sex.
local function validate(ped, app)
    if not pedExists(ped) then return false, 'INVALID_PED' end
    if type(app) ~= 'table' or (app.sex ~= 'male' and app.sex ~= 'female') then return false, 'INVALID_PAYLOAD' end
    if not sameModel(GetEntityModel(ped), modelOf(app.sex)) then return false, 'MODEL_MISMATCH' end
    return true
end

-- ---------------------------------------------------------------------
--  The full render
-- ---------------------------------------------------------------------
local function render(ped, app, opts)
    local failed = {}
    local function put(category, hash, tint)
        if not hash or hash == 0 then return end
        local ok = A.ApplyComponent(ped, category, hash, tint)
        if not ok then failed[#failed + 1] = category end
    end

    -- 1. the preset establishes valid drawable slots; committed before anything else goes on
    WCNative.metaped.equipOutfitPreset(ped, A.PRESET)
    WCNative.ped.refresh(ped)
    -- a ped that did not render after the preset is not waited on again before the final refresh
    local stalled = not A.WaitReady(ped)
    if stalled then WCDebug.log('appearance', 'ped %s not ready after the preset', tostring(ped)) end
    if not pedExists(ped) then return false, 'INVALID_PED', failed end

    -- 2. a clean slate: every clothing category, the hair and the facial hair
    pcall(w.component.removeAllClothes, ped)
    A.RemoveCategory(ped, 'hair')
    A.RemoveCategory(ped, 'mustache')

    -- 3. body, head, eyes, teeth
    put(BODY_ORDER[1], app.body.lower)
    put(BODY_ORDER[2], app.body.upper)
    put(HEAD_ORDER[1], app.head.head)
    put(HEAD_ORDER[2], app.head.eyes)
    put(HEAD_ORDER[3], app.head.teeth)

    -- 4. hair and facial hair
    local hair = tbl(app.hair)
    put('hair', hair.style)
    if app.sex == 'male' then put('mustache', hair.facial) end

    -- 5. waist and height
    A.SetWaist(ped, app.body.weight)
    A.SetHeight(ped, app.body.height)

    -- 6. clothing in dependency order with tints; hidden visibility states stay off the ped
    local visible = visibleClothing(app)
    for _, category in ipairs(clothingOrder(equippedOf(app))) do
        local item = visible[category]
        if item then put(category, item.hash, item.tint) end
    end

    -- 7. wearable clothing states
    if not opts.skipStates then applyWearableStates(ped, app) end

    -- 8. the body commit: the waist outfit is committed before the morphology is set (as w_lib's
    --    applySkin and the pre-v3 pipeline do), so the outfit cannot overwrite the body morph
    if not pedExists(ped) then return false, 'INVALID_PED', failed end
    WCNative.ped.refresh(ped)
    if not stalled and not A.WaitReady(ped) then
        WCDebug.log('appearance', 'ped %s not ready after the body commit', tostring(ped))
    end
    if not pedExists(ped) then return false, 'INVALID_PED', failed end

    -- 9. morphology, then the final refresh
    A.ApplyMorph(ped, app.morph)
    if not A.Refresh(ped) then
        WCDebug.warn('appearance', 'ped %s did not become ready after the restore', tostring(ped))
        return false, 'NOT_READY', failed
    end

    -- 10. overlays on the committed head: w.pedTexture builds the face texture on the albedo of the
    --     head the ped carries now, and commits it itself (refreshNow)
    if not opts.skipOverlays and applyOverlays(ped, app) then A.WaitReady(ped) end
    return true, nil, failed
end

--- Render a v3 appearance on a ped (the one pipeline).
---@param ped integer
---@param app table v3 appearance (a legacy row or JSON is normalised)
---@param opts? table { skipStates = bool, skipOverlays = bool }
---@return boolean ok, string|nil err, table failedCategories
function A.RestoreCharacter(ped, app, opts)
    opts = type(opts) == 'table' and opts or {}
    app = v3(app)
    local ok, err = validate(ped, app)
    if not ok then return false, err, {} end
    if not acquire(ped) then return false, 'BUSY', {} end
    local done, result, code, failed = pcall(render, ped, app, opts)
    release(ped)
    if not done then
        WCDebug.warn('appearance', 'restore of ped %s failed: %s', tostring(ped), tostring(result))
        return false, 'INTERNAL_ERROR', {}
    end
    if #failed > 0 then
        WCDebug.log('appearance', 'ped %s: %d component(s) could not be applied', tostring(ped), #failed)
    end
    return result, code, failed
end

-- ---------------------------------------------------------------------
--  Incremental preview
-- ---------------------------------------------------------------------

local function needsFullRestore(before, after)
    if type(before) ~= 'table' or before.sex ~= after.sex then return true end
    local bb, ab, bh, ah = tbl(before.body), tbl(after.body), tbl(before.head), tbl(after.head)
    return bb.upper ~= ab.upper or bb.lower ~= ab.lower or bh.head ~= ah.head
end

local function sameTint(a, b)
    if a == nil and b == nil then return true end
    return WCUtil.deepEqual(a or {}, b or {})
end

local function diff(ped, before, after)
    local failed, changed = {}, false
    local function put(category, hash, tint)
        changed = true
        if not hash or hash == 0 then
            A.RemoveCategory(ped, category)
            return true
        end
        local ok = A.ApplyComponent(ped, category, hash, tint)
        if not ok then failed[#failed + 1] = category end
        return ok
    end

    -- eyes / teeth
    local bh, ah = tbl(before.head), tbl(after.head)
    if bh.eyes ~= ah.eyes then put('eyes', ah.eyes) end
    if bh.teeth ~= ah.teeth then put('teeth', ah.teeth) end

    -- hair / facial hair
    local bhair, ahair = tbl(before.hair), tbl(after.hair)
    if bhair.style ~= ahair.style then put('hair', ahair.style) end
    local bf = before.sex == 'male' and bhair.facial or 0
    local af = after.sex == 'male' and ahair.facial or 0
    if bf ~= af then put('mustache', af) end

    -- waist / height
    local bb, ab = tbl(before.body), tbl(after.body)
    local waistChanged = bb.weight ~= ab.weight
    if waistChanged then A.SetWaist(ped, ab.weight); changed = true end
    if bb.height ~= ab.height then A.SetHeight(ped, ab.height); changed = true end

    -- clothing: removals first, then additions/changes, both in dependency order
    local bv, av = visibleClothing(before), visibleClothing(after)
    local order = clothingOrder(equippedOf(after))
    local seen = {}
    for _, c in ipairs(order) do seen[c] = true end
    for category in pairs(bv) do
        if not seen[category] then order[#order + 1] = category; seen[category] = true end
    end
    local reapplied = {}
    for _, category in ipairs(order) do
        if bv[category] and not av[category] then
            put(category, 0)
            reapplied[category] = true
        end
    end
    for _, category in ipairs(order) do
        local b, a = bv[category], av[category]
        if a and (not b or b.hash ~= a.hash or not sameTint(b.tint, a.tint)) then
            put(category, a.hash, a.tint)
            reapplied[category] = true
        end
    end

    -- wearable states whose value changed, whose component went back on, or whose requirement
    -- (e.g. the pants of the boots) changed
    local only = {}
    for _, group in ipairs(WCClothingStates.groups) do
        if group.mechanism == 'wearable' then
            local touched = WCClothingStates.current(before, group.id) ~= WCClothingStates.current(after, group.id)
                or WCClothingStates.applicable(before, group.id) ~= WCClothingStates.applicable(after, group.id)
            for _, c in ipairs(group.categories) do
                if reapplied[c] then touched = true end
            end
            for _, c in ipairs(group.requires) do
                if reapplied[c] then touched = true end
            end
            if touched then only[group.id] = true end
        end
    end
    if next(only) then
        applyWearableStates(ped, after, only)
        changed = true
    end

    -- morphology: a new waist outfit is committed first and every channel is set again (the
    -- outfit can overwrite the body morph); otherwise only the channels whose value changed
    if waistChanged then
        if not pedExists(ped) then return false, failed, 'INVALID_PED' end
        if not A.Refresh(ped) then WCDebug.log('appearance', 'ped %s not ready after the waist commit', tostring(ped)) end
        A.ApplyMorph(ped, after.morph)
    else
        local bm, am = tbl(before.morph), tbl(after.morph)
        local ids = {}
        for id in pairs(bm) do ids[id] = true end
        for id in pairs(am) do ids[id] = true end
        for id in pairs(ids) do
            local b, a = tonumber(bm[id]) or 0, tonumber(am[id]) or 0
            local field = WCMorph.byId[id]
            if field and b ~= a then
                WCNative.ped.setExpression(ped, field.expression, WCUtil.number(a, -1, 1, 0) + 0.0)
                changed = true
            end
        end
    end

    if changed then
        if not pedExists(ped) then return false, failed, 'INVALID_PED' end
        if not A.Refresh(ped) then return false, failed, 'NOT_READY' end
    end

    -- overlays on the committed head: w.pedTexture rebuilds the whole head layer set and commits it
    if not WCUtil.deepEqual(tbl(before.overlays), tbl(after.overlays)) then
        if not pedExists(ped) then return false, failed, 'INVALID_PED' end
        if applyOverlays(ped, after) then A.WaitReady(ped) end
    end
    return true, failed
end

--- Incremental preview from `before` to `after` on a ped that currently shows `before`.
--  Falls back to RestoreCharacter when the sex, the body model or the head model changes.
---@return boolean ok, table failedCategories, string|nil err
function A.ApplyDiff(ped, before, after)
    after = v3(after)
    local ok, err = validate(ped, after)
    if not ok then return false, {}, err end
    before = type(before) == 'table' and v3(before) or nil
    if needsFullRestore(before, after) then
        local done, code, failed = A.RestoreCharacter(ped, after)
        return done, failed or {}, code
    end
    if not acquire(ped) then return false, {}, 'BUSY' end
    local done, result, failed, code = pcall(diff, ped, before, after)
    release(ped)
    if not done then
        WCDebug.warn('appearance', 'incremental apply on ped %s failed: %s', tostring(ped), tostring(result))
        return false, {}, 'INTERNAL_ERROR'
    end
    return result, failed or {}, code
end

-- ---------------------------------------------------------------------
--  The local player
-- ---------------------------------------------------------------------

--- Switch the player's model to mp_<sex> and wait until the new ped carries it.
--  Never touches a stale handle: the result is checked on the current PlayerPedId().
---@param sex string 'male' | 'female'
---@return boolean ok, string|nil err
function A.SetPlayerModel(sex)
    if sex ~= 'male' and sex ~= 'female' then return false, 'INVALID_PAYLOAD' end
    local model = modelOf(sex)
    if sameModel(GetEntityModel(PlayerPedId()), model) then return true end
    local loaded = pcall(w.requestModel, model, A.MODEL_TIMEOUT)
    if not loaded then return false, 'MODEL_TIMEOUT' end
    SetPlayerModel(PlayerId(), model, true)
    SetModelAsNoLongerNeeded(model)
    local ready = WCUtil.waitUntil(function()
        local ped = PlayerPedId()
        return pedExists(ped) and sameModel(GetEntityModel(ped), model)
    end, A.MODEL_TIMEOUT, 0)
    if not ready then return false, 'MODEL_TIMEOUT' end
    return true
end

local playerBusy = false

--- Render an appearance (default: the saved WCState.appearance) on the local player: sets the
--  model when needed, then RestoreCharacter on the current player ped. Serialised: a second call
--  waits for the first.
---@param app? table
---@param opts? table RestoreCharacter options
---@return boolean ok, string|nil err
function A.RestorePlayer(app, opts)
    app = v3(app or WCState.appearance)
    if type(app) ~= 'table' then return false, 'NO_CHARACTER' end
    if playerBusy then
        WCUtil.waitUntil(function() return not playerBusy end, A.PED_WAIT_TIMEOUT, 0)
        if playerBusy then return false, 'BUSY' end
    end
    playerBusy = true
    local done, ok, err = pcall(function()
        local switched, code = A.SetPlayerModel(app.sex)
        if not switched then return false, code end
        local restored, reason = A.RestoreCharacter(PlayerPedId(), app, opts)
        return restored, reason
    end)
    playerBusy = false
    if not done then
        WCDebug.warn('appearance', 'player restore failed: %s', tostring(ok))
        return false, 'INTERNAL_ERROR'
    end
    return ok, err
end

--- Is a RestorePlayer running (the spawn waits for it before fading in)?
function A.IsPlayerApplying()
    return playerBusy
end
