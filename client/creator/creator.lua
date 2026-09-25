-- =====================================================================
--  client/creator/creator.lua  —  WCCreator: the character creator (ARCHITECTURE.md §9.2, §17)
--
--  Server grant first (characters:beginCreate, no sex yet) → the gender scene: the man and the
--  woman stand side by side on the stage (Config.Scene.peds), the camera frames the pair, and the
--  w_lib prompts offer LEFT (the man) / RIGHT (the woman) / BACK (the character list). Picking a
--  side opens WCEditor in 'creator' mode on that character at once, where it stands (the other one
--  is hidden while editing); the camera glides from the pair to it. The editor's root Back
--  ("change the sex") returns to the pair and keeps what was built: each gender has its own draft
--  look, and the typed name is shared, so switching back and forth loses nothing. The server
--  learns the sex only when the character is saved (beginCreate(sex) right before
--  characters:create); then render on the player ped → characters:loaded → spawn
--  (WCSelector.finish).
--
--  Repair path: characters:select answered {needsAppearance, token, sex?} for a character without
--  a saved appearance → the creator in appearance-only mode (no identity; create(token, nil, app)).
--  With a known sex the editor opens directly and its Back returns to the character list.
--
--  BACK in the gender scene → characters:cancelCreate + the selection screen (after a confirmation
--  when a draft holds work). Everything the creator takes (prompts, peds, cameras, the lights loop,
--  NUI, the player's frozen/hidden state, the 'selection' lock) is released on success, failure,
--  a lost grant and resource stop; the room itself (focus, timecycle, clock override, maps,
--  bucket) through CreatorScene.
--
--  Public: WCCreator.start(opts) -> true | false, code; WCCreator.active(); WCCreator.stage();
--          net event W:CHARCREATION:starting (compatibility: server-granted only).
-- =====================================================================

WCCreator = {}
local C = WCCreator

local SEXES = { 'male', 'female' }
local MSG_RETRY = 'تعذر عرض الشخصية. أعد المحاولة'
local MSG_SEX_LOCKED = 'جنس هذه الشخصية ثابت الآن ولا يمكن تغييره'
local LEAVE_TITLE, LEAVE_BODY = 'تعديلات غير محفوظة', 'سيتم إلغاء التعديلات غير المحفوظة.'
local BACK_LABEL = 'تغيير الجنس'
local TITLE = 'بناء الشخصية'
local SOUND_SET = 'RDRO_Character_Creator_Sounds'

-- Codes after which the creation grant is gone: back to the selection screen.
local GRANT_LOST = { CREATION_NOT_GRANTED = true, CREATION_DISABLED = true, CHARACTER_SLOT_LIMIT = true }

local st = {
    active = false,
    stage = nil,      -- 'starting' | 'gender' | 'opening' | 'editor' | 'saving'
    token = nil,      -- the server creation grant
    repair = nil,     -- { token, sex?, charid, appearance?, identity? } for the appearance-only path
    created = nil,    -- { data, working } once characters:create answered ok (render / loaded pending)
    sex = 'male',     -- the gender picked last
    peds = {},        -- [sex] = preview ped
    drafts = {},      -- [sex] = the look built for that gender, kept while the player switches
    identityDraft = {}, -- { firstname, lastname, dob } typed in the editor (one name for both)
    grantSex = nil,   -- the sex the server grant holds (set at the save, before characters:create)
    lockedSex = nil,  -- the server locked the grant to this sex (a half-finished creation)
    prompts = nil,
    busy = false,     -- a gender-scene action runs
    ownsLock = false,
    generation = 0,   -- bumped on every start / teardown: stale threads stop
}

-- ---------------------------------------------------------------------
--  Helpers
-- ---------------------------------------------------------------------

local function validSex(sex)
    return (sex == 'male' or sex == 'female') and sex or nil
end

local function notify(key, kind)
    if type(key) ~= 'string' then return end
    pcall(w.notify, { description = locale(key), type = kind or 'error' })
end

local function messageOf(result)
    if type(result) == 'table' then
        if type(result.message) == 'string' then return result.message end
        if type(result.code) == 'string' then return WCResult.messageKey(result.code) end
    end
    return WCResult.messageKey('INTERNAL_ERROR')
end

local function await(name, ...)
    local ok, result = pcall(w.callback.await, name, false, ...)
    if not ok then
        WCDebug.warn('creator', '%s failed: %s', name, tostring(result))
        return WCResult.fail('INTERNAL_ERROR')
    end
    if not WCResult.is(result) then return WCResult.fail('INTERNAL_ERROR') end
    return result
end

local function pedExists(ped)
    -- BOOL natives answer 1 (not true) on this runtime: never compare them with == true
    return type(ped) == 'number' and ped ~= 0 and not not DoesEntityExist(ped)
end

local function takeLock()
    if st.ownsLock then return end
    st.ownsLock = WCState.busy('selection', true) == true
end

local function releaseLock()
    if st.ownsLock then WCState.busy('selection', false) end
    st.ownsLock = false
end

local function hidePlayer()
    if type(WCSelector) == 'table' and WCSelector.hidePlayer then return WCSelector.hidePlayer() end
    local ped = PlayerPedId()
    FreezeEntityPosition(ped, true)
    SetEntityInvincible(ped, true)
    SetEntityVisible(ped, false)
    NetworkSetEntityOnlyExistsForParticipants(ped, true)
end

local function restorePlayer()
    if type(WCSelector) == 'table' and WCSelector.restorePlayer then return WCSelector.restorePlayer() end
    local ped = PlayerPedId()
    SetEntityVisible(ped, true)
    NetworkSetEntityOnlyExistsForParticipants(ped, false)
    SetEntityInvincible(ped, false)
    FreezeEntityPosition(ped, false)
end

local function sceneCfg() return Config.Scene or {} end

local function sceneCoords(sex)
    local peds = sceneCfg().peds or {}
    return peds[sex]
end

--- The look a new character of this sex starts from (the editor's Reset goes back to it).
local function baseLook(sex)
    local app = AppearanceSchema.default(sex)
    if Config.Creator and Config.Creator.eyebrowsFollowHair and type(app.overlays.eyebrows) == 'table' then
        app.overlays.eyebrows.matchHair = true
    end
    return app
end

--- Did the player build anything that leaving would throw away?
local function hasDrafts()
    for sex, app in pairs(st.drafts) do
        if not WCUtil.deepEqual(AppearanceSchema.normalize(app), AppearanceSchema.normalize(baseLook(sex))) then
            return true
        end
    end
    for _, key in ipairs({ 'firstname', 'lastname', 'dob' }) do
        local v = st.identityDraft[key]
        if type(v) == 'string' and WCUtil.trim(v) ~= '' then return true end
    end
    return false
end

-- ---------------------------------------------------------------------
--  The gender prompts (w_lib NUI prompts: Arabic-capable)
-- ---------------------------------------------------------------------

local function promptCfg() return Config.Characters.genderPrompt or {} end

local function destroyPrompts()
    local group = st.prompts
    st.prompts = nil
    if group then
        pcall(group.hide)
        pcall(group.delete)
    end
end

--- LEFT = the man, RIGHT = the woman, BACK = the character list. Picking is accepting: there is
--  no confirm prompt (Config genderPrompt.accept is kept for old configs and not shown).
local function buildPrompts()
    destroyPrompts()
    local P = promptCfg()
    local group = w.prompt.createGroup(locale(P.title), P.position)
    group.addPrompt(P.prev.key, locale(P.prev.label), false)
    group.addPrompt(P.next.key, locale(P.next.label), false)
    group.addPrompt(P.back.key, locale(P.back.label), false)
    group.display()
    st.prompts = group
end

local function relabelPrompts()
    local group = st.prompts
    if not group then return end
    local P = promptCfg()
    pcall(function()
        group.setTitle(locale(P.title))
        group.setLabel(P.prev.key, locale(P.prev.label))
        group.setLabel(P.next.key, locale(P.next.label))
        group.setLabel(P.back.key, locale(P.back.label))
    end)
end

-- Another group displayed over ours (a w_lib walk-up prompt, a death prompt re-displayed by its
-- owner) hides it, and w_lib only reports completions of the visible group: ours is displayed
-- again (checked every PROMPT_REASSERT_MS), or the screen could never be left.
local PROMPT_REASSERT_MS = 250
local function reassertPrompts(group)
    local now = GetGameTimer()
    if st.promptCheckAt and now < st.promptCheckAt then return end
    st.promptCheckAt = now + PROMPT_REASSERT_MS
    local ok, visible = pcall(group.isVisible)
    if ok and visible == false then pcall(group.display) end
end

local function isCompleted(key)
    local group = st.prompts
    if not group or key == nil then return false end
    reassertPrompts(group)
    local ok, done = pcall(group.isCompleted, key)
    return ok and done == true
end

-- ---------------------------------------------------------------------
--  Teardown
-- ---------------------------------------------------------------------

local function destroyPeds()
    for sex, ped in pairs(st.peds) do
        CreatorScene.destroy(ped)
        st.peds[sex] = nil
    end
    st.peds = {}
end

--- Release everything the creator took. The room (maps, bucket) stays for the next owner:
--  the selection screen (back / failure) or the spawn (WCSelector.finish).
local function teardown()
    st.generation = st.generation + 1
    st.active, st.stage, st.busy = false, nil, false
    destroyPrompts()
    local session = WCEditor.session()
    if session and session.mode == 'creator' then WCEditor.close() end
    destroyPeds()
    WCCamera.close()
    pcall(WCNative.ui.blankObjective)
    releaseLock()
    st.token, st.repair, st.created = nil, nil, nil
    st.drafts, st.identityDraft, st.grantSex, st.lockedSex = {}, {}, nil, nil
end

local function backToSelection(errorKey)
    if type(WCSelector) == 'table' and WCSelector.back then
        local ok = WCSelector.back(errorKey)
        if ok then return end
        WCDebug.warn('creator', 'the selection screen could not be reopened')
        return
    end
    TriggerEvent('w_creators:client:backToSelection', errorKey)
end

--- Renew the server's creation grant while the editor is open.
--  ⚠️ The grant lives GRANT_TTL_MS (30 minutes) on the server and used to be issued once and never
--     renewed, while the editor makes NO server call between beginCreate and create. Anyone who
--     spent longer than that on a character had the save refused with CREATION_NOT_GRANTED and lost
--     all of it. One cheap ping keeps the grant alive for as long as the creator is genuinely up.
local KEEPALIVE_MS = 60000

local function startKeepAlive(gen)
    CreateThread(function()
        while st.active and gen == st.generation do
            Wait(KEEPALIVE_MS)
            if not st.active or gen ~= st.generation then return end
            local token = st.token
            if token then
                local result = await('w_creators:characters:keepAlive', token)
                if not result.ok and result.code ~= 'RATE_LIMITED' then
                    -- not fatal on its own: the save still decides. Worth a line, because a grant that
                    -- cannot be renewed is a save that is going to be refused.
                    WCDebug.warn('creator', 'the creation grant could not be renewed: %s', tostring(result.code))
                end
            end
        end
    end)
end

--- Give up the creation: release the grant and go back to the selection screen.
local function abort(errorKey)
    local token = st.token
    teardown()
    if token then await('w_creators:characters:cancelCreate', token) end
    backToSelection(errorKey)
end
C.abort = abort

-- ---------------------------------------------------------------------
--  The scene loop: lights, controls, HUD every frame while the creator is up
-- ---------------------------------------------------------------------

local pick

--- BACK in the gender scene: work the player built in either draft is confirmed before it is
--  thrown away (the same "unsaved changes" copy the editor uses).
local function confirmLeave()
    if not hasDrafts() then return true end
    local ok, answer = pcall(w.alertDialog, {
        header = locale(LEAVE_TITLE),
        content = locale(LEAVE_BODY),
        centered = true,
        cancel = true,
    })
    return ok and answer == 'confirm'
end

local function pickAsync(sex)
    st.busy = true
    CreateThread(function()
        local ok, err = pcall(pick, sex)
        if not ok then
            if type(err) ~= 'table' then WCDebug.warn('creator', 'opening the editor failed: %s', tostring(err)) end
            abort(type(err) == 'table' and err.key or MSG_RETRY)
        end
        st.busy = false
    end)
end

local function genderInput()
    local P = promptCfg()
    if isCompleted(P.back.key) then
        st.busy = true
        CreateThread(function()
            if not confirmLeave() then
                st.busy = false
                return
            end
            destroyPrompts()
            abort(nil)
        end)
    elseif isCompleted(P.next.key) then
        pickAsync('female')
    elseif isCompleted(P.prev.key) then
        pickAsync('male')
    end
end

local function startLoop()
    local gen = st.generation
    CreateThread(function()
        while st.active and gen == st.generation do
            DisableAllControlActions(0)
            SuppressGameHud()
            CreatorScene.drawLights()
            CreatorScene.suppressAmbient()
            if st.stage == 'editor' or st.stage == 'saving' then
                -- no stale objective text over the editor (the pre-v3 state loop did the same)
                WCNative.ui.clearObjective()
            elseif st.stage == 'gender' and not st.busy then
                genderInput()
            end
            Wait(0)
        end
    end)
end

-- ---------------------------------------------------------------------
--  The gender scene
-- ---------------------------------------------------------------------

--- Place (or create) the preview ped of a sex in its gender-scene spot, wearing its draft (or the
--  starting look).
local function stagePed(sex)
    local app = st.drafts[sex] or baseLook(sex)
    local ped = st.peds[sex]
    if pedExists(ped) then
        local placed, code = CreatorScene.position(ped, sceneCoords(sex))
        if not placed then error('position ' .. sex .. ': ' .. tostring(code), 0) end
        local rendered, err = Appearance.RestoreCharacter(ped, app)
        if not rendered then error('render ' .. sex .. ': ' .. tostring(err), 0) end
        CreatorScene.ready(ped)
        SetEntityCollision(ped, true, true)
        CreatorScene.show(ped)
    else
        local created, err = CreatorScene.create(nil, sceneCoords(sex), app)
        if not created then error('preview ' .. sex .. ': ' .. tostring(err), 0) end
        ped = created
        st.peds[sex] = ped
    end
    CreatorScene.arm(ped, sex)
    CreatorScene.idle(ped, sex)
    return ped
end

--- The camera on both characters (Config.Scene.cameras.pair), gliding from wherever it is.
local function pairShot()
    local cams = sceneCfg().cameras or {}
    WCCamera.glide(cams.glideMs)
    if WCCamera.openPair(st.peds, cams.pair) then return true end
    return WCCamera.open(st.peds.male or st.peds.female, 'selection')
end

local function showGenderScene()
    for _, sex in ipairs(SEXES) do stagePed(sex) end
    if not pairShot() then error('camera', 0) end
    buildPrompts()
    st.stage = 'gender'
end

--- Back to the pair after editing: both characters stand in their spots wearing their drafts
--  (never re-rendered: the edited one already shows its draft), idling again.
local function returnToGenderScene()
    local moved = sceneCfg().editingPed ~= nil
    for _, sex in ipairs(SEXES) do
        local ped = st.peds[sex]
        if pedExists(ped) then
            if moved then
                local placed, code = CreatorScene.position(ped, sceneCoords(sex))
                if not placed then error('position ' .. sex .. ': ' .. tostring(code), 0) end
            else
                -- the player may have turned the character in the editor: it faces the stalls again
                local _, _, _, heading = CreatorScene.coords(sceneCoords(sex))
                if heading then SetEntityHeading(ped, heading) end
            end
            SetEntityCollision(ped, true, true)
            CreatorScene.show(ped)
            CreatorScene.arm(ped, sex)
            CreatorScene.idle(ped, sex)
        else
            stagePed(sex)
        end
    end
    if not pairShot() then error('camera', 0) end
    PlaySoundFrontend('BACK', SOUND_SET, true, 0)
    buildPrompts()
    st.stage = 'gender'
end

--- Back from the editor to the gender scene (the editor already closed itself).
local function backToGender()
    if not st.active then return end
    if st.repair and validSex(st.repair.sex) then
        -- the server knows the sex of a repaired character: nothing to choose, back to the list
        abort(nil)
        return
    end
    local ok, err = pcall(returnToGenderScene)
    if not ok then
        WCDebug.warn('creator', 'the gender scene could not be restored: %s', tostring(err))
        abort(MSG_RETRY)
    end
end

-- ---------------------------------------------------------------------
--  The editor
-- ---------------------------------------------------------------------

local openEditor, finishCreated

--- The sex is decided at the save: the grant takes it now (beginCreate(sex) on the same token),
--  once per sex. nil = go on; a Result = the save is refused with it.
local function settleSex(working)
    if st.repair then return nil end
    local sex = type(working) == 'table' and validSex(working.sex) or nil
    if not sex or st.grantSex == sex then return nil end
    local result = await('w_creators:characters:beginCreate', sex)
    if not result.ok then
        if GRANT_LOST[result.code] then
            local key = messageOf(result)
            CreateThread(function() abort(key) end)
        end
        -- never saved against a grant that may still hold the other sex: the server would clean
        -- this design as that sex. The player saves again.
        return result
    end
    local data = type(result.data) == 'table' and result.data or {}
    if type(data.token) == 'string' then st.token = data.token end
    local granted = validSex(data.sex)
    if granted and data.locked == true then st.lockedSex = granted end
    if granted and granted ~= sex then
        -- a half-finished creation locked the sex server-side: this design cannot be that character
        st.lockedSex = granted
        local refused = WCResult.fail('INVALID_PAYLOAD')
        refused.message = MSG_SEX_LOCKED
        return refused
    end
    st.grantSex = granted or sex
    return nil
end

--- Save: characters:create → render on the player → loaded (only after the render succeeded).
local function commit(working, extra)
    if not st.active or st.stage ~= 'editor' then return WCResult.fail('BUSY') end
    st.stage = 'saving'
    local identity = (not st.repair) and type(extra) == 'table' and extra.identity or nil
    local refused = settleSex(working)
    if refused then
        st.stage = 'editor'
        return refused
    end
    local result = await('w_creators:characters:create', st.token, identity, working)

    -- ★ The grant expired while the player was working (the heartbeat could not keep it, the resource
    --   restarted, the player idled for hours). The finished appearance is right here in `working`,
    --   so ask for a fresh grant and save it ONCE rather than throwing the whole character away —
    --   which is what abort() below does, and what the player reported losing. Only for a plain
    --   expiry: CREATION_DISABLED and CHARACTER_SLOT_LIMIT are real refusals and must stand.
    if not result.ok and result.code == 'CREATION_NOT_GRANTED' and not st.repair then
        local again = await('w_creators:characters:beginCreate', working and working.sex or st.sex)
        local token = again.ok and type(again.data) == 'table' and again.data.token or nil
        local sex = again.ok and type(again.data) == 'table' and validSex(again.data.sex) or nil
        -- a server that locked the sex to something else is not the same creation: do not overwrite it
        if token and (not sex or not working or not working.sex or sex == working.sex) then
            WCDebug.warn('creator', 'the creation grant had expired; retrying the save with a fresh one')
            st.token = token
            st.grantSex = sex or (working and validSex(working.sex)) or nil
            result = await('w_creators:characters:create', token, identity, working)
        end
    end

    if not result.ok then
        st.stage = 'editor'
        if GRANT_LOST[result.code] then
            -- the grant is gone for good (disabled, no slot): the editor cannot succeed any more
            local key = messageOf(result)
            CreateThread(function() abort(key) end)
        end
        return result
    end

    local data = type(result.data) == 'table' and result.data or {}
    -- the character exists now: a cancel retries this finish instead of starting a new creation
    st.created = { data = data, working = working }
    if not finishCreated(data, working) then
        st.stage = 'editor'
        return WCResult.fail('INTERNAL_ERROR')
    end
    return result
end

--- Render the created character on the player, then characters:loaded → spawn. false when the
--  render failed (the player stays hidden; the creation is kept for a retry).
finishCreated = function(data, working)
    local app = AppearanceSchema.normalize(data.appearance or working)
    StartFade(300, 'creator')
    local rendered, err = Appearance.SetPlayerModel(app.sex)
    if rendered then rendered, err = Appearance.RestorePlayer(app) end
    if not rendered then
        -- the character exists; a retry of the same token replays the same create answer
        WCDebug.warn('creator', 'the created appearance could not be rendered: %s', tostring(err))
        hidePlayer()
        EndFade(300)
        return false
    end

    local charid = data.charid ~= nil and tostring(data.charid) or (st.repair and st.repair.charid) or nil
    WCState.setCharacter(charid, app.sex)
    WCState.set(app)
    teardown()
    restorePlayer()

    -- an uncertain answer (a timed-out reply) is settled by the spawn hand-off (WCSelector.awaitLoaded)
    local loaded = (type(WCSelector) == 'table' and type(WCSelector.awaitLoaded) == 'function')
        and WCSelector.awaitLoaded() or await('w_creators:characters:loaded')
    if not loaded.ok then
        WCState.clear()
        local key = messageOf(loaded)
        CreateThread(function() backToSelection(key) end)
        return true
    end
    if type(WCSelector) == 'table' and WCSelector.finish then
        WCSelector.finish(type(loaded.data) == 'table' and loaded.data.spawn or nil)
    else
        CreatorScene.release({ keepBucket = true })
    end
    return true
end

--- Cancel in the editor (its root Back). After a create the server already answered ok (only the
--  render failed), the character exists: the finish is retried, never a new creation from the
--  gender scene. Otherwise the look built so far is this gender's draft and the typed name is
--  kept for either gender.
local function onEditorCancel(sex, draft, identity)
    local created = st.created
    if st.active and created then
        st.stage = 'saving'
        local ok, done = pcall(finishCreated, created.data, created.working)
        if ok and done then return end
        if not ok then WCDebug.warn('creator', 'finishing the created character failed: %s', tostring(done)) end
        if not st.active then return end
        st.stage = 'editor'
    end
    if validSex(sex) and type(draft) == 'table' and draft.sex == sex then st.drafts[sex] = draft end
    if type(identity) == 'table' then st.identityDraft = identity end
    backToGender()
end

--- The editor's identity: an editable one for a new character (with what was typed before); for
--  the repair path the card's framework identity, locked (read-only), or nil when the card had no name.
local function editorIdentity(sex)
    if not st.repair then
        local d = st.identityDraft
        return { sex = sex, locked = false, firstname = d.firstname, lastname = d.lastname, dob = d.dob }
    end
    local id = type(st.repair.identity) == 'table' and st.repair.identity or nil
    if not id or (type(id.firstname) ~= 'string' and type(id.lastname) ~= 'string') then return nil end
    return { sex = sex, locked = true, firstname = id.firstname, lastname = id.lastname, dob = id.dob }
end

openEditor = function(sex)
    local scene = sceneCfg()
    local ped = st.peds[sex]
    if not pedExists(ped) then ped = stagePed(sex) end
    -- the other character would stand half in the full-body shot: hidden while this one is edited
    if scene.hideOtherWhileEditing ~= false then
        for other, p in pairs(st.peds) do
            if other ~= sex and pedExists(p) then
                SetEntityVisible(p, false)
                SetEntityCollision(p, false, false)
            end
        end
    end
    -- edited where it stands (Config.Scene.editingPed = nil); a configured editing spot moves it
    -- there behind a short fade, as the single-spot room did
    local moved = scene.editingPed ~= nil
    if moved then
        StartFade(250, 'creator')
        local placed, code = CreatorScene.position(ped, scene.editingPed)
        if not placed then error('editing position: ' .. tostring(code), 0) end
    else
        CreatorScene.still(ped)
    end
    CreatorScene.show(ped)

    local base, working, render = baseLook(sex), st.drafts[sex], false
    if st.repair and type(st.repair.appearance) == 'table' then
        local existing = AppearanceSchema.normalize(st.repair.appearance)
        if type(existing) == 'table' and existing.sex == sex then base, working, render = existing, nil, true end
    end
    -- a new character (or a repair that still has to choose its sex): the gender choice is one Back
    -- away and nothing built is lost on the way; a repair of a known sex goes back to the list
    local toGender = not (st.repair and validSex(st.repair.sex))
    WCCamera.glide((scene.cameras or {}).glideMs)
    local opened, reason = WCEditor.open(ped, 'creator', base, {
        title = TITLE,
        sections = AppearanceSchema.SECTIONS,
        -- the repair path keeps the framework identity: shown read-only when the card had one
        -- (identity.locked), never submitted: create(token, nil, app)
        identity = editorIdentity(sex),
        context = {
            startingClothing = Config.Creator.startingClothing,
            presets = (Config.StartingOutfits and Config.StartingOutfits[sex]) or {},
        },
        render = render,
        working = working,
        keepDraft = toGender or nil,
        keepCamera = toGender or nil,
        backLabel = toGender and BACK_LABEL or nil,
        onCommit = commit,
        onCancel = function(draft, identity) CreateThread(function() onEditorCancel(sex, draft, identity) end) end,
    })
    if not opened then error({ key = WCResult.messageKey(reason or 'INTERNAL_ERROR') }, 0) end
    st.stage = 'editor'
    if moved then EndFade(300) end
end

--- LEFT / RIGHT: open the editor on that character at once (no server call: the grant from
--  C.start stays valid, and the server takes the sex at the save).
pick = function(sex)
    if st.lockedSex and st.lockedSex ~= sex then
        notify(MSG_SEX_LOCKED)
        return
    end
    PlaySoundFrontend(sex == 'female' and 'gender_right' or 'gender_left', SOUND_SET, true, 0)
    destroyPrompts()
    st.sex = sex
    st.stage = 'opening'
    openEditor(sex)
end

-- ---------------------------------------------------------------------
--  Start
-- ---------------------------------------------------------------------

--- The room: isolated (the selection usually did it already), loaded, cleaned, the player hidden.
local function prepareRoom()
    if not CreatorScene.isIsolated() then
        local ok, code = CreatorScene.isolate()
        if not ok then error({ key = WCResult.messageKey(code or 'INTERNAL_ERROR') }, 0) end
    end
    if not CreatorScene.isLoaded() then CreatorScene.load() end
    CreatorScene.cleanup()
    hidePlayer()
    SetCustomHudVisible(false)
    WCCamera.close()
end

--- Start the creator. opts.repair = { token, sex?, charid, appearance?, identity? } for the appearance-only
--  path (the token comes from characters:select). Returns true | false, code.
function C.start(opts)
    opts = type(opts) == 'table' and opts or {}
    if st.active then return false, 'BUSY' end
    if WCEditor.isOpen() then return false, 'BUSY' end
    st.active, st.stage, st.busy = true, 'starting', false
    st.generation = st.generation + 1
    st.repair = type(opts.repair) == 'table' and type(opts.repair.token) == 'string' and opts.repair or nil
    st.token = st.repair and st.repair.token or nil
    st.created = nil
    st.sex = (st.repair and validSex(st.repair.sex)) or 'male'
    st.peds = {}
    st.drafts, st.identityDraft, st.grantSex, st.lockedSex = {}, {}, nil, nil
    takeLock()
    startKeepAlive(st.generation)
    StartFade(500, 'creator')

    if not st.repair then
        local result = await('w_creators:characters:beginCreate')
        if not result.ok or type(result.data) ~= 'table' or type(result.data.token) ~= 'string' then
            -- no grant: back to the selection with the server's reason
            local key = result.ok and WCResult.messageKey('INTERNAL_ERROR') or messageOf(result)
            teardown()
            backToSelection(key)
            return false, result.ok and 'INTERNAL_ERROR' or result.code
        end
        st.token = result.data.token
        -- a replayed grant may already carry a sex (a creation that completed or half-completed)
        st.grantSex = validSex(result.data.sex)
        -- and when the server says that sex is locked, only it can be picked: the other gender is
        -- refused in the gender scene, before anything is built for it
        if result.data.locked == true then st.lockedSex = st.grantSex end
    end

    local ok, err = pcall(function()
        prepareRoom()
        startLoop()
        if st.repair and validSex(st.repair.sex) then
            openEditor(st.repair.sex)
        else
            showGenderScene()
        end
        EndFade(500)
    end)
    if not ok then
        local key = type(err) == 'table' and err.key or MSG_RETRY
        if type(err) ~= 'table' then WCDebug.warn('creator', 'the creator scene failed: %s', tostring(err)) end
        abort(key)
        return false, 'INTERNAL_ERROR'
    end
    return true
end

--- Is the creator up?
function C.active() return st.active end

--- The creator stage ('starting' | 'gender' | 'opening' | 'editor' | 'saving') or nil.
function C.stage() return st.stage end

--- The draft look of a gender (a copy) or nil: what the player built for it so far.
function C.draft(sex) return st.drafts[sex] and WCUtil.copy(st.drafts[sex]) or nil end

-- ---------------------------------------------------------------------
--  Events and cleanup
-- ---------------------------------------------------------------------

--- Compatibility: other resources opened the creator with this event. It is honoured only as a
--  request: the server grant (beginCreate) decides, and a player with a character in play is
--  refused here (a character switch goes through /characters).
RegisterNetEvent('W:CHARCREATION:starting', function()
    CreateThread(function()
        if st.active then return end
        local selecting = type(WCSelector) == 'table' and WCSelector.active()
        if WCState.character and not selecting then
            WCDebug.warn('creator', 'W:CHARCREATION:starting ignored: a character is in play')
            return
        end
        if selecting then
            if WCSelector.busy() then return end
            WCSelector.leave()
        end
        C.start({})
    end)
end)

OnLanguageChange(function()
    if st.active then relabelPrompts() end
end)

AddEventHandler('onResourceStop', function(resource)
    if resource ~= GetCurrentResourceName() then return end
    if not st.active and not st.ownsLock and next(st.peds) == nil then return end
    st.generation = st.generation + 1
    st.active, st.stage = false, nil
    pcall(destroyPrompts)
    local okSession, session = pcall(WCEditor.session)
    if okSession and session and session.mode == 'creator' then pcall(WCEditor.close) end
    for _, ped in pairs(st.peds) do pcall(CreatorScene.destroy, ped) end
    st.peds = {}
    pcall(WCCamera.close)
    pcall(WCNative.ui.blankObjective)
    pcall(CreatorScene.release, { keepBucket = true })
    pcall(SetNuiFocus, false, false)
    pcall(restorePlayer)
    pcall(SetCustomHudVisible, true)
    releaseLock()
end)
