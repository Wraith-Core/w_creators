-- =====================================================================
--  client/clothing/states.lua  —  WCClothing, the clothing state controller
--  (ARCHITECTURE.md §3.2, §5.5, §13, §16.5, §17 "Clothing actions")
--
--  Runtime clothing states (hat on/off, bandana up/down, sleeves rolled, boots over/under the pants
--  ...) of the local character, and the quick-access "Clothing actions" panel (WCPanel).
--  A state never removes an owned or equipped item: 'off' only hides the component on the ped and
--  WCState.appearance.clothing.equipped is never touched here.
--
--  WCClothing.available(app?)          -> the applicable actions, Group › Item › action:
--        { { id, label, order, items = { { id, label, order, groups = { stateGroupIds },
--            actions = { { group, value, current, label, control } } } } } }  (labels: locale keys)
--  WCClothing.perform(groupId, target, opts?) -> Result { group, value, changed, states }
--        guards (character, service, editor/scene/service flows, dead, ragdoll, combat, mounted when
--        an animation would play) → per-action lock (WCState 'clothingAction') → optional animation
--        (Config.Experimental.clothingAnimations) up to its midpoint, interruptible → re-check (flow,
--        replaced appearance) → apply locally with the current WCState.appearance →
--        w_creators:clothing:setState → failure: the saved value is applied back; success: when our
--        appearance was re-rendered meanwhile, the new value is drawn again.
--        Refusals: BUSY (lock, editor / scene / flow / render; data.reason or data.interrupted),
--        STATE_NOT_APPLICABLE (dead, ragdoll, combat, mount, no ped; interrupted before the midpoint).
--        opts.notify = false: no notification on failure (the panel shows the message itself).
--  WCClothing.applyStates(ped, app)    -> ok, failedGroups (every applicable group, one refresh)
--  WCClothing.openPanel()              -> Result (WCPanel with the available() tree)
--  WCClothing.closePanel()             closes the panel opened by this module
--  WCClothing.isPanelOpen(), WCClothing.busy(), WCClothing.tree(app?) (the panel tree),
--  WCClothing.groupOfCategory(category) (visibility groups only), WCClothing.toggle(groupId),
--  WCClothing.removeCategory(category), WCClothing.restoreCategory(category)
--
--  Access: command /clothing, keybind 'wc_clothing_actions' (default key Config.Keys.clothingActions,
--  none when unset), exports OpenClothingActions, SetClothingState, ToggleHat, ToggleBandana,
--  ToggleSleeves, RemoveClothingCategory, RestoreClothingCategory (§13).
--  Controls: 'state.<groupId>.<value>' (§8.4).
-- =====================================================================

WCClothing = {}
local C = WCClothing

local LOCK = 'clothingAction'
local CALLBACK = 'w_creators:clothing:setState'
local TITLE = 'إجراءات الملابس'
local MSG_NONE = 'لا توجد إجراءات متاحة لملابسك الآن'
local KEYBIND = 'wc_clothing_actions'
local COMMAND = 'clothing'

local ANIM_LOAD_TIMEOUT = 2000   -- the animation dictionary must load by then (else: no animation)
local ANIM_STEP = 100            -- interruption checks while the animation runs up to its midpoint
local ANIM_FLAGS = 16 | 32       -- upper body + secondary: the player keeps walking
local WATCH_STEP = 250           -- the open panel's watcher (death, character cleared, changes)
local RENDER_WAIT = 5000         -- a render of the player that raced an action must finish by then

-- Action labels per group and value; a per-category table wins for groups acting on several
-- categories (poncho / cloak). Fallback: Config.ClothingStates.valueLabels[value].
local ACTION_LABELS = {
    hat     = { on = 'ارتداء القبعة', off = 'خلع القبعة' },
    eyewear = { on = 'ارتداء النظّارة', off = 'خلع النظّارة' },
    mask    = { on = 'ارتداء القناع', off = 'خلع القناع' },
    bandana = { up = 'رفع الوشاح', down = 'إنزال الوشاح' },
    sleeves = { rolled = 'تشمير الأكمام', down = 'إنزال الأكمام' },
    collar  = { open = 'فتح الياقة', closed = 'إغلاق الياقة' },
    coat    = { on = 'ارتداء المعطف', off = 'خلع المعطف' },
    vest    = { on = 'ارتداء الصديري', off = 'خلع الصديري' },
    poncho  = { on = 'ارتداء البونشو', off = 'خلع البونشو' },
    gloves  = { on = 'ارتداء القفازات', off = 'خلع القفازات' },
    boots   = { under = 'إدخال الحذاء تحت البنطال', over = 'إخراج الحذاء فوق البنطال' },
}
local CATEGORY_LABELS = {
    cloaks = { on = 'ارتداء العباءة', off = 'خلع العباءة' },
}

-- Which clip of Config.ClothingStates.animations[group] ('up' | 'down') a target value plays when
-- the animation has no clip named after the value itself.
local VALUE_CLIP = { off = 'up', up = 'up', rolled = 'up', open = 'up', under = 'up',
                     on = 'down', down = 'down', closed = 'down', over = 'down' }
local GROUP_CLIP = { mask = { on = 'up', off = 'down' } } -- a mask goes on from the neck (neck_2_face)

local st = {
    performing = nil, -- { group, target, ped, dict, clip } while an action runs
    panel = false,    -- the open WCPanel is ours
    watchId = 0,      -- the panel watcher generation
}

-- ---------------------------------------------------------------------
--  Helpers
-- ---------------------------------------------------------------------

local function L(key, ...)
    if type(locale) == 'function' then return locale(key, ...) end
    return key
end

local function fail(code, data) return WCResult.fail(code, data) end

local function notify(result)
    if type(result) ~= 'table' then return end
    local key = result.message or WCResult.messageKey(result.code or 'INTERNAL_ERROR')
    pcall(w.notify, { description = L(key), type = 'error' })
end

local function notifyKey(key, kind)
    pcall(w.notify, { description = L(key), type = kind or 'inform' })
end

-- A named native that may be missing on a build: a missing or failing call answers false.
local function call(name, ...)
    local fn = _ENV[name]
    if type(fn) ~= 'function' then return false end
    local ok, value = pcall(fn, ...)
    return ok and (value == true or value == 1)
end

local function pedExists(ped)
    return type(ped) == 'number' and ped ~= 0 and DoesEntityExist(ped) == true
end

local function enabled()
    local cfg = Config.ClothingStates or {}
    return cfg.enabled ~= false and WCServices.enabled('clothingActions')
end

local function animationsOn()
    return Config.Experimental ~= nil and Config.Experimental.clothingAnimations == true
end

local function statesOf(app)
    if type(app) ~= 'table' then return nil end
    if type(app.clothing) ~= 'table' then app.clothing = {} end
    if type(app.clothing.states) ~= 'table' then app.clothing.states = {} end
    return app.clothing.states
end

-- A global module's boolean query, false when the module or the function is missing.
local function query(module, fn)
    local m = _ENV[module]
    if type(m) ~= 'table' or type(m[fn]) ~= 'function' then return false end
    local ok, value = pcall(m[fn])
    return ok and value == true
end

-- ---------------------------------------------------------------------
--  Guards
-- ---------------------------------------------------------------------

--- Is the player's appearance being rendered (a restore, or our own appearance from the server)?
local function rendering()
    local A = Appearance
    if type(A) ~= 'table' then return false end
    if type(A.IsPlayerApplying) == 'function' and A.IsPlayerApplying() == true then return true end
    return type(A.Sync) == 'table' and type(A.Sync.applyingOwn) == 'function' and A.Sync.applyingOwn() == true
end

--- A flow of this resource owns the player or its appearance (editor, panel of another module,
--  character scene, selection, creator, spawn, respawn, a store / wardrobe / barber / surgery visit
--  including its opening and closing steps, the barber / clinic seat, the arrival cutscene, a render
--  of the player).
local function flowActive()
    if WCState.inEditor() or query('WCEditor', 'isOpen') then return 'editor' end
    if WCState.busy('selection') or WCState.busy('spawn') or WCState.busy('respawn') then return 'flow' end
    if WCState.busy('service') or query('WCServiceFlow', 'busy') or query('WCBarber', 'busy')
        or query('WCSurgery', 'busy') then
        return 'flow'
    end
    if query('CreatorScene', 'isLoaded') or query('CreatorScene', 'isIsolated') then return 'scene' end
    if query('WCPreviewEnv', 'active') or query('WCSelector', 'active') or query('WCCreator', 'active') then
        return 'scene'
    end
    if query('WCServiceSeat', 'active') or query('WCCutscene', 'active') then return 'scene' end
    if query('WCSpawnSelector', 'active') then return 'spawn' end
    if rendering() then return 'render' end
    return nil
end

-- The refusal code of a reason: a flow of this resource or the lock → BUSY ("another operation is in
-- progress"); the ped's condition (dead, ragdoll, combat, mount, no ped) → STATE_NOT_APPLICABLE
-- ("this state cannot be applied now").
local FLOW_REASONS = { editor = true, flow = true, scene = true, spawn = true, render = true, stopped = true }
local function refusal(why, key)
    local code = FLOW_REASONS[why] and 'BUSY' or 'STATE_NOT_APPLICABLE'
    return WCResult.fail(code, { [key or 'reason'] = why })
end

local function isDown(ped)
    return call('IsEntityDead', ped) or call('IsPedDeadOrDying', ped, true)
end

local function inCombat(ped)
    return call('IsPedInCombat', ped, 0) or call('IsPedInMeleeCombat', ped)
end

local function mounted(ped)
    return call('IsPedOnMount', ped) or call('IsPedInAnyVehicle', ped, false)
        or call('IsPedGettingIntoAVehicle', ped)
end

--- Why the ped cannot change clothing now (nil = it can). `mountOk`: riding is allowed (no animation).
local function blocked(ped, mountOk)
    if not pedExists(ped) then return 'ped' end
    if isDown(ped) then return 'dead' end
    if call('IsPedRagdoll', ped) then return 'ragdoll' end
    if inCombat(ped) then return 'combat' end
    if not mountOk and mounted(ped) then return 'mount' end
    return nil
end

-- ---------------------------------------------------------------------
--  Actions (Group › Item › action)
-- ---------------------------------------------------------------------

local function taxonomyIndex()
    local groups, subs = {}, {}
    for gi, g in ipairs((Config.Clothing and Config.Clothing.taxonomy) or {}) do
        groups[g.id] = { label = g.label, order = g.order or gi, index = gi }
        for si, sub in ipairs(g.subs or {}) do
            subs[sub.id] = { label = sub.label, order = sub.order or si, index = si, group = g.id }
            if sub.category then subs[sub.category] = subs[sub.category] or subs[sub.id] end
        end
    end
    return groups, subs
end

local function actionLabel(app, groupId, value)
    local category = WCClothingStates.category(app, groupId)
    local byCategory = category and CATEGORY_LABELS[category]
    if byCategory and byCategory[value] then return byCategory[value] end
    local byGroup = ACTION_LABELS[groupId]
    if byGroup and byGroup[value] then return byGroup[value] end
    local values = Config.ClothingStates and Config.ClothingStates.valueLabels or {}
    return values[value] or value
end

--- The applicable actions of an appearance (default: the saved one), as a hierarchy:
--  taxonomy group › item (the taxonomy subcategory the state group belongs to) › actions.
--  Only equipped items appear, and only the values that differ from the current state. Labels are
--  locale keys.
---@param app? table
function C.available(app)
    app = app or WCState.appearance
    if type(app) ~= 'table' then return {} end
    local ok, actions = pcall(WCClothingStates.actions, app)
    if not ok or type(actions) ~= 'table' then return {} end
    local groups, subs = taxonomyIndex()
    local out, groupAt, itemAt = {}, {}, {}
    for _, a in ipairs(actions) do
        local parent = type(a.parent) == 'table' and a.parent or {}
        local groupId = type(parent[1]) == 'string' and parent[1] or 'other'
        local itemId = type(parent[2]) == 'string' and parent[2] or a.group
        local g = groupAt[groupId]
        if not g then
            local info = groups[groupId] or {}
            g = { id = groupId, label = info.label or TITLE, order = info.order or 99, index = info.index or (1000 + #out), items = {} }
            groupAt[groupId] = g
            out[#out + 1] = g
        end
        local key = groupId .. '/' .. itemId
        local item = itemAt[key]
        if not item then
            local info = subs[itemId] or {}
            item = { id = itemId, label = info.label or a.label, order = info.order or 99, index = info.index or (1000 + #g.items),
                     actions = {}, groups = {} }
            itemAt[key] = item
            g.items[#g.items + 1] = item
        end
        item.groups[#item.groups + 1] = a.group
        if #item.groups == 1 then
            -- one state group: the item is named after the equipped piece (a cloak, a closed coat)
            local category = WCClothingStates.category(app, a.group)
            local info = category and subs[category]
            item.label = (info and info.label) or a.label or item.label
        else
            item.label = (subs[itemId] and subs[itemId].label) or item.label
        end
        for _, value in ipairs(a.targets or {}) do
            item.actions[#item.actions + 1] = {
                group = a.group, value = value, current = a.current,
                label = actionLabel(app, a.group, value),
                control = 'state.' .. a.group .. '.' .. value,
            }
        end
    end
    -- by `order`, then by the config position (table.sort is not stable): the same deterministic
    -- order as the editor's taxonomy (WCEditorTree.ordered)
    local function byOrder(list)
        table.sort(list, function(x, y)
            if x.order ~= y.order then return x.order < y.order end
            return x.index < y.index
        end)
    end
    byOrder(out)
    for _, g in ipairs(out) do byOrder(g.items) end
    return out
end

--- The visibility group acting on a clothing category (nil for other categories).
---@param category string
---@return string|nil
function C.groupOfCategory(category)
    if type(category) ~= 'string' then return nil end
    for _, group in ipairs(WCClothingStates.groups) do
        if group.mechanism == 'visibility' then
            for _, c in ipairs(group.categories or {}) do
                if c == category then return group.id end
            end
        end
    end
    return nil
end

-- ---------------------------------------------------------------------
--  Animation (experimental, Config.Experimental.clothingAnimations)
-- ---------------------------------------------------------------------

--- The animation a change plays, or nil: { dict, clip, duration, midpoint }.
local function animationFor(groupId, target)
    if not animationsOn() then return nil end
    local anims = Config.ClothingStates and Config.ClothingStates.animations or {}
    local anim = anims[groupId]
    if type(anim) ~= 'table' or type(anim.dict) ~= 'string' then return nil end
    local clip = type(anim.clips) == 'table' and anim.clips[target] or nil
    if type(clip) ~= 'string' then
        local direction = (GROUP_CLIP[groupId] and GROUP_CLIP[groupId][target]) or VALUE_CLIP[target]
        clip = direction and anim[direction]
    end
    if type(clip) ~= 'string' then return nil end
    local duration = WCUtil.int(anim.duration, 100, 10000, 1000)
    local midpoint = WCUtil.int(anim.midpoint, 0, duration, duration // 2)
    return { dict = anim.dict, clip = clip, duration = duration, midpoint = midpoint }
end

local function stopAnimation(ped, anim)
    if not anim or not anim.playing then return end
    anim.playing = false
    if pedExists(ped) and type(StopAnimTask) == 'function' then
        pcall(StopAnimTask, ped, anim.dict, anim.clip, 1.0)
    end
end

--- Load and start the animation. false when it cannot play (the change goes on without it).
local function startAnimation(ped, anim)
    if type(w.requestAnimDict) ~= 'function' or type(w.playAnim) ~= 'function' then return false end
    local loaded, err = pcall(w.requestAnimDict, anim.dict, ANIM_LOAD_TIMEOUT)
    if not loaded then
        WCDebug.log('clothing', 'animation %s not loaded: %s', anim.dict, tostring(err))
        return false
    end
    local played, perr = pcall(w.playAnim, ped, anim.dict, anim.clip, 4.0, -4.0, anim.duration, ANIM_FLAGS)
    if not played then
        WCDebug.log('clothing', 'animation %s/%s failed: %s', anim.dict, anim.clip, tostring(perr))
        return false
    end
    anim.playing = true
    return true
end

--- Run the animation up to its midpoint. true = reached (the state changes), false = interrupted
--  (death, ragdoll, combat, getting on a mount / into a vehicle, a new ped, the resource stopping,
--  a flow or a render of the player starting).
local function runToMidpoint(ped, anim)
    local deadline = GetGameTimer() + anim.midpoint
    while GetGameTimer() < deadline do
        Wait(ANIM_STEP)
        if st.stopped then return false, 'stopped' end
        if PlayerPedId() ~= ped then return false, 'ped' end
        local why = blocked(ped, false) or flowActive()
        if why then return false, why end
    end
    return true
end

-- ---------------------------------------------------------------------
--  Perform
-- ---------------------------------------------------------------------

local function applyLocal(ped, app, groupId, value)
    local ok, err = Appearance.ApplyClothingState(ped, app, groupId, value)
    if not ok then return false, err end
    Appearance.Refresh(ped)
    return true
end

local PIPELINE_CODES = { STATE_NOT_SUPPORTED = true, STATE_NOT_APPLICABLE = true, INVALID_PAYLOAD = true }

--- The saved appearance was replaced (Appearance.Sync.applyOwn: a grooming tick, an API SetClothes /
--  SetSkin, a reload) or a render of the player ran while the action waited: wait for the render to
--  finish. true when the ped may no longer show the action's value.
local function settle(app)
    local raced = WCState.appearance ~= app or rendering()
    if not raced then return false end
    if not WCUtil.waitUntil(function() return not rendering() end, RENDER_WAIT, ANIM_STEP) then
        WCDebug.warn('clothing', 'a render of the player did not finish in %d ms', RENDER_WAIT)
    end
    return true
end

--- Draw one group's value on the current ped with the current saved appearance.
local function redraw(groupId, value)
    local app, ped = WCState.appearance, PlayerPedId()
    if type(app) ~= 'table' or not pedExists(ped) or not WCClothingStates.applicable(app, groupId) then return end
    local ok, err = applyLocal(ped, app, groupId, value)
    if not ok then WCDebug.warn('clothing', 'redraw %s=%s failed: %s', groupId, tostring(value), tostring(err)) end
end

local function run(groupId, target, previous, app, anim)
    local ped = PlayerPedId()
    if anim then
        st.performing.dict, st.performing.clip, st.performing.anim = anim.dict, anim.clip, anim
        if startAnimation(ped, anim) then
            local reached, why = runToMidpoint(ped, anim)
            if not reached then
                -- interrupted before the midpoint: nothing changed, the state stays as it was
                stopAnimation(ped, anim)
                WCDebug.log('clothing', '%s -> %s interrupted (%s)', groupId, target, tostring(why))
                return refusal(why, 'interrupted')
            end
        end
    end

    -- the world may have moved while the animation (or the dictionary load) waited: a flow or a
    -- render took the player, or the saved appearance was replaced
    local flow = flowActive()
    if flow then
        stopAnimation(ped, anim)
        return refusal(flow, 'interrupted')
    end
    local cur = WCState.appearance
    if type(cur) ~= 'table' then
        stopAnimation(ped, anim)
        return fail('NO_CHARACTER')
    end
    if cur ~= app then
        if not WCClothingStates.applicable(cur, groupId) then
            stopAnimation(ped, anim)
            return fail('STATE_NOT_APPLICABLE', { interrupted = 'appearance' })
        end
        local now = WCClothingStates.current(cur, groupId)
        if now == target then
            return WCResult.ok({ group = groupId, value = target, changed = false,
                                 states = WCUtil.copy(statesOf(cur) or {}) })
        end
        if now ~= previous then
            stopAnimation(ped, anim)
            return fail('STATE_NOT_APPLICABLE', { interrupted = 'appearance' })
        end
        app = cur
    end

    -- the change itself: locally first (visible at once), then the server
    local applied, err = applyLocal(ped, app, groupId, target)
    if not applied then
        stopAnimation(ped, anim)
        return fail(PIPELINE_CODES[err] and err or 'INTERNAL_ERROR')
    end

    local called, result = pcall(w.callback.await, CALLBACK, false, groupId, target)
    if not called or not WCResult.is(result) then
        WCDebug.warn('clothing', 'setState %s=%s: %s', groupId, target, tostring(result))
        result = fail('INTERNAL_ERROR')
    end
    -- our own appearance may have been replaced and re-rendered during the round trip
    local raced = settle(app)
    if not result.ok then
        -- the server refused: the ped goes back to the saved value (the previous one, or the value
        -- of an appearance the server sent meanwhile) on the current ped and appearance
        local base = type(WCState.appearance) == 'table' and WCState.appearance or nil
        redraw(groupId, base and WCClothingStates.current(base, groupId) or previous)
        return result
    end

    local states = statesOf(WCState.appearance)
    if states then states[groupId] = target end
    -- a render of an appearance without the new value drew over our change: draw it again
    if raced then redraw(groupId, target) end
    WCDebug.log('clothing', '%s = %s', groupId, target)
    return WCResult.ok({ group = groupId, value = target, changed = true,
                         states = states and WCUtil.copy(states) or {} })
end

local function perform(groupId, target)
    if type(groupId) ~= 'string' or type(target) ~= 'string' then return fail('INVALID_PAYLOAD') end
    local group = WCClothingStates.byId[groupId]
    if not group or not WCClothingStates.isValid(groupId, target) then return fail('STATE_NOT_SUPPORTED') end
    if not enabled() then return fail('ACTIONS_DISABLED') end
    if st.stopped then return fail('BUSY') end
    local app = WCState.appearance
    if type(app) ~= 'table' then return fail('NO_CHARACTER') end
    if not WCClothingStates.applicable(app, groupId) then return fail('STATE_NOT_APPLICABLE') end
    local previous = WCClothingStates.current(app, groupId)
    if previous == target then
        return WCResult.ok({ group = groupId, value = target, changed = false,
                             states = WCUtil.copy(statesOf(app) or {}) })
    end
    local flow = flowActive()
    if flow then
        WCDebug.log('clothing', 'refused %s=%s: %s', groupId, target, flow)
        return refusal(flow)
    end
    local anim = animationFor(groupId, target)
    -- riding (a mount or a vehicle) is allowed only when no animation has to play
    local why = blocked(PlayerPedId(), anim == nil)
    if why then
        WCDebug.log('clothing', 'refused %s=%s: %s', groupId, target, why)
        return refusal(why)
    end
    if not WCState.busy(LOCK, true) then return fail('BUSY') end
    st.performing = { group = groupId, target = target, ped = PlayerPedId() }
    local done, result = pcall(run, groupId, target, previous, app, anim)
    local performing = st.performing
    st.performing = nil
    WCState.busy(LOCK, false)
    if not done then
        WCDebug.warn('clothing', 'action %s=%s failed: %s', groupId, target, tostring(result))
        if performing and performing.anim then stopAnimation(performing.ped, performing.anim) end
        result = fail('INTERNAL_ERROR')
    end
    return result
end

--- Change one clothing state of the local character. Result.
---@param groupId string
---@param target string
---@param opts? table { notify = false (no notification on failure), fromPanel = true }
function C.perform(groupId, target, opts)
    opts = type(opts) == 'table' and opts or {}
    local result = perform(groupId, target)
    if not result.ok and opts.notify ~= false then notify(result) end
    -- an action from elsewhere (export, keybind) while the panel is open: show the new state
    if st.panel and not opts.fromPanel then pcall(WCPanel.refresh) end
    return result
end

--- Is an action running?
function C.busy()
    return st.performing ~= nil
end

--- Apply every applicable state of an appearance to a ped (the pipeline's ApplyClothingState per
--  group, then one refresh). Returns ok, failedGroups.
---@param ped integer
---@param app table
function C.applyStates(ped, app)
    if not pedExists(ped) or type(app) ~= 'table' then return false, {} end
    local failed = {}
    local any = false
    for _, group in ipairs(WCClothingStates.groups) do
        if WCClothingStates.applicable(app, group.id) then
            local ok, err = Appearance.ApplyClothingState(ped, app, group.id, WCClothingStates.current(app, group.id))
            if ok then any = true else failed[#failed + 1] = group.id end
            if not ok then WCDebug.log('clothing', 'state %s not applied: %s', group.id, tostring(err)) end
        end
    end
    if any then Appearance.Refresh(ped) end
    return #failed == 0, failed
end

-- ---------------------------------------------------------------------
--  Panel
-- ---------------------------------------------------------------------

--- The WCPanel tree: root › taxonomy group › item › action (every action under its item).
function C.tree(app)
    local root = { id = 'clothing', kind = 'group', label = TITLE, children = {} }
    for _, g in ipairs(C.available(app)) do
        local groupNode = { id = 'clothing.' .. g.id, kind = 'group', label = g.label, children = {} }
        for _, item in ipairs(g.items) do
            local itemNode = { id = 'clothing.' .. g.id .. '.' .. item.id, kind = 'group', label = item.label,
                               children = {} }
            for _, a in ipairs(item.actions) do
                itemNode.children[#itemNode.children + 1] = { id = a.control, kind = 'action', label = a.label,
                                                               control = a.control }
            end
            if #itemNode.children > 0 then groupNode.children[#groupNode.children + 1] = itemNode end
        end
        if #groupNode.children > 0 then root.children[#root.children + 1] = groupNode end
    end
    return root
end

local function parseControl(control)
    if type(control) ~= 'string' then return nil end
    local groupId, value = control:match('^state%.([%w_]+)%.([%w_]+)$')
    return groupId, value
end

local function onControl(control)
    local groupId, value = parseControl(control)
    if not groupId then return fail('INVALID_PAYLOAD') end
    return C.perform(groupId, value, { notify = false, fromPanel = true })
end

-- A cheap fingerprint of what the panel shows: rebuilt when the saved appearance changes.
local function fingerprint()
    local app = WCState.appearance
    if type(app) ~= 'table' or type(app.clothing) ~= 'table' then return '' end
    return (WCUtil.encode({ app.sex, app.clothing.equipped, app.clothing.states }) or '')
end

local function watch()
    st.watchId = st.watchId + 1
    local id = st.watchId
    CreateThread(function()
        local last = fingerprint()
        while st.panel and st.watchId == id do
            Wait(WATCH_STEP)
            if not st.panel or st.watchId ~= id then break end
            if not WCPanel.isOpen() then
                st.panel = false
                break
            end
            local ped = PlayerPedId()
            local flow = not C.busy() and flowActive() or nil
            if type(WCState.appearance) ~= 'table' or not enabled() or (pedExists(ped) and isDown(ped))
                or (flow ~= nil and flow ~= 'render') then
                C.closePanel()
                break
            end
            local now = fingerprint()
            if now ~= last and not C.busy() then
                last = now
                pcall(WCPanel.refresh)
            end
        end
    end)
end

--- Open the clothing actions panel. Result.
function C.openPanel()
    if not enabled() then return fail('ACTIONS_DISABLED') end
    if type(WCState.appearance) ~= 'table' then return fail('NO_CHARACTER') end
    if st.panel and WCPanel.isOpen() then return WCResult.ok() end
    local flow = flowActive()
    if flow then return refusal(flow) end
    local ped = PlayerPedId()
    if not pedExists(ped) then return refusal('ped') end
    if isDown(ped) then return refusal('dead') end
    if #C.available() == 0 then
        notifyKey(MSG_NONE)
        return fail('STATE_NOT_APPLICABLE', { reason = 'none' })
    end
    local ok, code = WCPanel.open({
        title = TITLE,
        build = function() return C.tree() end,
        onControl = onControl,
        onClose = function()
            st.panel = false
            st.watchId = st.watchId + 1
        end,
    })
    if not ok then return fail(code or 'INTERNAL_ERROR') end
    st.panel = true
    watch()
    return WCResult.ok()
end

--- Close the panel opened by this module (a panel of another module stays).
function C.closePanel()
    if not st.panel then return end
    st.panel = false
    st.watchId = st.watchId + 1
    if WCPanel.isOpen() then pcall(WCPanel.close) end
end

function C.isPanelOpen()
    return st.panel and WCPanel.isOpen()
end

-- ---------------------------------------------------------------------
--  Toggles and category helpers (exports, §13)
-- ---------------------------------------------------------------------

--- The next value of a group: the first of its values that differs from the current one.
local function toggleTarget(groupId)
    local group = WCClothingStates.byId[groupId]
    if not group then return nil end
    local current = WCClothingStates.current(WCState.appearance, groupId)
    for _, value in ipairs(group.values) do
        if value ~= current then return value end
    end
    return nil
end

function C.toggle(groupId)
    local target = toggleTarget(groupId)
    if not target then
        local r = fail('STATE_NOT_SUPPORTED')
        notify(r)
        return r
    end
    return C.perform(groupId, target)
end

--- A category's visibility group, only when that category is the piece worn: a group covers
--  categories that are never worn together (ponchos / cloaks, coats / coats_closed), so removing
--  'cloaks' must not hide a poncho.
local function categoryState(category, value)
    local groupId = C.groupOfCategory(category)
    if not groupId then
        local r = fail('STATE_NOT_SUPPORTED')
        notify(r)
        return r
    end
    local app = WCState.appearance
    if type(app) == 'table' and WCClothingStates.category(app, groupId) ~= category then
        local r = fail('STATE_NOT_APPLICABLE', { reason = 'category' })
        notify(r)
        return r
    end
    return C.perform(groupId, value)
end

function C.removeCategory(category) return categoryState(category, 'off') end
function C.restoreCategory(category) return categoryState(category, 'on') end

-- ---------------------------------------------------------------------
--  Access: exports, command, keybind
-- ---------------------------------------------------------------------

local function export(name, fn)
    local ok, err = pcall(exports, name, fn)
    if not ok then WCDebug.warn('clothing', 'export %s failed: %s', name, tostring(err)) end
end

export('OpenClothingActions', function() return C.openPanel() end)
export('SetClothingState', function(groupId, value) return C.perform(groupId, value) end)
export('ToggleHat', function() return C.toggle('hat') end)
export('ToggleBandana', function() return C.toggle('bandana') end)
export('ToggleSleeves', function() return C.toggle('sleeves') end)
export('RemoveClothingCategory', function(category) return C.removeCategory(category) end)
export('RestoreClothingCategory', function(category) return C.restoreCategory(category) end)

local function openFromInput()
    if C.isPanelOpen() then return end
    local result = C.openPanel()
    -- "nothing available" was already notified by openPanel
    local none = type(result.data) == 'table' and result.data.reason == 'none'
    if not result.ok and not none then notify(result) end
end

--- The English text of a locale key, read from locales/en.json (nil when missing). RedM's
--  Settings > Key Bindings page draws Latin only, so w.addKeybind shows this for an Arabic label.
local function englishOf(key)
    local ok, text = pcall(function()
        local raw = LoadResourceFile(GetCurrentResourceName(), 'locales/en.json')
        if type(raw) ~= 'string' or raw == '' then return nil end
        local decoded = json.decode(raw)
        return type(decoded) == 'table' and decoded[key] or nil
    end)
    if ok and type(text) == 'string' and text ~= '' then return text end
    return nil
end

if WCServices.enabled('clothingActions') then
    RegisterCommand(COMMAND, function() openFromInput() end, false)
    if type(w.addKeybind) == 'function' then
        local key = Config.Keys and Config.Keys.clothingActions
        local ok, err = pcall(w.addKeybind, {
            name = KEYBIND,
            description = L(TITLE),
            descriptionEn = englishOf(TITLE),
            defaultKey = type(key) == 'string' and key or '',
            onPressed = function() openFromInput() end,
        })
        if not ok then WCDebug.warn('clothing', 'keybind failed: %s', tostring(err)) end
    end
end

-- ---------------------------------------------------------------------
--  Cleanup
-- ---------------------------------------------------------------------

AddEventHandler('onResourceStop', function(resource)
    if resource ~= GetCurrentResourceName() then return end
    st.stopped = true
    local performing = st.performing
    if performing and performing.anim then pcall(stopAnimation, performing.ped, performing.anim) end
    if performing then WCState.busy(LOCK, false) end
    st.performing = nil
    pcall(C.closePanel)
end)
