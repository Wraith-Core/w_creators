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
--  ToggleSleeves, RemoveClothingCategory, RestoreClothingCategory, GetClothingActions (§13).
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
    shirt   = { on = 'ارتداء القميص', off = 'خلع القميص' },
    pants   = { on = 'ارتداء البنطال', off = 'خلع البنطال' },
    loadout = { left = 'نقل العتاد إلى الكتف الأيسر', right = 'نقل العتاد إلى الكتف الأيمن' },
    vestTuck = { under = 'إدخال الصديري تحت البنطال', over = 'إخراج الصديري فوق البنطال' },
    bodyUpper = { auto = 'الجزء العلوي: تلقائي' },
    bodyLower = { auto = 'الجزء السفلي: تلقائي' },
}
local CATEGORY_LABELS = {
    cloaks = { on = 'ارتداء العباءة', off = 'خلع العباءة' },
}
-- A woman's vest is a corset: the same state, her garment's name
local FEMALE_LABELS = {
    vestTuck = { under = 'إدخال المشدّ تحت البنطال', over = 'إخراج المشدّ فوق البنطال' },
}
-- A body state the game names (the body-part fix): the label carries the game's own name
local BODY_STATE_LABELS = { bodyUpper = 'الجزء العلوي: %s', bodyLower = 'الجزء السفلي: %s' }

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
    -- BOOL natives answer 1 (not true) on this runtime: never compare them with == true
    return type(ped) == 'number' and ped ~= 0 and not not DoesEntityExist(ped)
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
    local bySex = app.sex == 'female' and FEMALE_LABELS[groupId]
    if bySex and bySex[value] then return bySex[value] end
    local byGroup = ACTION_LABELS[groupId]
    if byGroup and byGroup[value] then return byGroup[value] end
    if BODY_STATE_LABELS[groupId] then
        -- already translated (the game's state name is not a dictionary key); locale() passes it on
        return L(BODY_STATE_LABELS[groupId], value)
    end
    local values = Config.ClothingStates and Config.ClothingStates.valueLabels or {}
    return values[value] or value
end

-- ---------------------------------------------------------------------
--  What the worn item supports: the game's own wearable states of the item
-- ---------------------------------------------------------------------

local itemStateCache = {} -- ['<u32>:<sex>'] = { [u32 state] = true } | false (the game told nothing)
local stateHashes = {}    -- [state name] = u32 | false

local function stateHash(name)
    local h = stateHashes[name]
    if h == nil then
        h = WCUtil.u32(GetHashKey(name)) or false
        stateHashes[name] = h
    end
    return h or nil
end

--- The wearable states the game lists for an item worn by a sex, as a set of u32 hashes, or nil
--  when the game answers nothing (the native is missing or the item unknown). Cached per item.
function C.itemStates(hash, sex)
    local u = WCUtil.u32(hash)
    if not u or u == 0 then return nil end
    local key = ('%d:%s'):format(u, tostring(sex))
    local cached = itemStateCache[key]
    if cached == nil then
        -- the natives take the wearer's metaped type: the player's own ped wears this appearance
        -- (the /clothing panel, the store and the wardrobe dress the player ped)
        local ok, list = pcall(WCNative.clothing.wearableStates, u, PlayerPedId())
        -- no answer at all (no ped yet, a failing native) is not remembered: asked again next time
        if not ok or type(list) ~= 'table' then return nil end
        cached = false
        if #list > 0 then
            cached = {}
            for _, s in ipairs(list) do cached[s] = true end
        end
        itemStateCache[key] = cached
    end
    return cached or nil
end

--- The item a state group acts on in an appearance (the equipped garment, or the body item).
local function wornItem(app, groupId)
    local def = WCClothingStates.byId[groupId]
    local category = def and WCClothingStates.category(app, groupId)
    if not category then return nil end
    if def.mechanism == 'bodyWearable' then
        local body = type(app.body) == 'table' and app.body or {}
        return def.body == 'lower' and body.lower or body.upper
    end
    return app.clothing.equipped[category]
end

--- Does the worn item have the game state a value needs? A garment the game gives no list for is
--  let through (the server and the pipeline decide); a garment whose list lacks the state is not
--  (a neckerchief that cannot be raised over the face). A body state is offered only when the game
--  lists it: the body-part fix never guesses among dozens of names.
function C.supports(app, groupId, value)
    local def = WCClothingStates.byId[groupId]
    if not def or type(app) ~= 'table' then return true end
    if def.mechanism == 'bodyWearable' then
        if value == 'auto' then return true end
        local states = C.itemStates(wornItem(app, groupId), app.sex)
        return states ~= nil and states[stateHash(value)] == true
    end
    local name = def.mechanism == 'wearable' and type(def.wearable) == 'table' and def.wearable[value] or nil
    if type(name) ~= 'string' or name == 'base' then return true end
    local states = C.itemStates(wornItem(app, groupId), app.sex)
    if not states then return true end
    return states[stateHash(name)] == true
end

--- The applicable actions of an appearance (default: the saved one), as a hierarchy:
--  taxonomy group › item (the taxonomy subcategory the state group belongs to) › actions.
--  Only equipped items appear, and only the values that differ from the current state. Labels are
--  locale keys.
---@param app? table
function C.available(app)
    app = app or WCState.appearance
    if type(app) ~= 'table' then return {} end
    -- the body-part groups too: C.supports narrows them to the worn body item's own states
    local ok, actions = pcall(WCClothingStates.actions, app, true)
    if not ok or type(actions) ~= 'table' then return {} end
    local groups, subs = taxonomyIndex()
    local out, groupAt, itemAt = {}, {}, {}
    local function place(a)
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
    for _, found in ipairs(actions) do
        -- only the values the worn item really has (the game's own states of the item)
        local targets = {}
        for _, value in ipairs(found.targets or {}) do
            if C.supports(app, found.group, value) then targets[#targets + 1] = value end
        end
        if #targets > 0 then
            place({ group = found.group, parent = found.parent, label = found.label, current = found.current,
                    targets = targets })
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

--- The same list as C.available, flattened to one row per state group and made safe to send
--  across an export boundary (plain strings and numbers, no nested functions or metatables).
--
--  ★ The flattening lives HERE, not in the caller: which action represents a garment, and what that
--    garment is called, is clothing knowledge. A radial menu that knows nothing about coats should
--    not have to decide it. Rows come out in C.available's deterministic order.
--
--  status: 'disabled'     the service or Config.ClothingStates is off      -> hide the menu entirely
--          'no_character' no appearance loaded yet                          -> hide the menu entirely
--          'ok' / 'empty' a real answer; 'empty' means nothing is actionable right now
---@return table { status, rows = { { group, value, label, item, itemId, icon, control } } }
function C.actionList()
    if not enabled() then return { status = 'disabled', rows = {} } end
    if type(WCState.appearance) ~= 'table' then return { status = 'no_character', rows = {} } end
    local ok, tree = pcall(C.available)
    if not ok or type(tree) ~= 'table' then
        WCDebug.warn('clothing', 'the action list could not be built: %s', tostring(tree))
        return { status = 'error', rows = {} }
    end
    local rows = {}
    for _, group in ipairs(tree) do
        for _, item in ipairs(group.items or {}) do
            for _, action in ipairs(item.actions or {}) do
                rows[#rows + 1] = {
                    group   = tostring(action.group or ''),
                    value   = tostring(action.value or ''),
                    -- C.available answers locale keys: translated here to the player's language, since
                    -- the caller (the wheel) shows them as they are
                    label   = tostring(L(action.label or '')),
                    item    = tostring(L(item.label or '')),  -- the garment it acts on
                    itemId  = tostring(item.id or ''),
                    icon    = tostring(action.group or ''),   -- art id; the caller resolves it
                    control = tostring(action.control or ''),
                    current = tostring(action.current or ''),   -- the state the garment is in now
                }
            end
        end
    end
    return { status = (#rows > 0) and 'ok' or 'empty', rows = rows }
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
    if type(anim) ~= 'table' then return nil end
    local entry = type(anim.clips) == 'table' and anim.clips[target] or nil
    local dict, clip, at = anim.dict, nil, nil
    if type(entry) == 'table' then
        -- { dict?, clip, at? }: a clip may live in another dictionary than the group's
        dict, clip, at = type(entry.dict) == 'string' and entry.dict or anim.dict, entry.clip, tonumber(entry.at)
    elseif type(entry) == 'string' then
        clip = entry
    else
        local direction = (GROUP_CLIP[groupId] and GROUP_CLIP[groupId][target]) or VALUE_CLIP[target]
        clip = direction and anim[direction]
    end
    if type(dict) ~= 'string' or type(clip) ~= 'string' then return nil end
    local duration = WCUtil.int(anim.duration, 100, 10000, 1000)
    local midpoint = WCUtil.int(anim.midpoint, 0, duration, duration // 2)
    -- no fixed duration: the clip's own length is read once it is loaded (startAnimation)
    local auto = anim.duration == nil
    return { dict = dict, clip = clip, duration = duration, midpoint = midpoint, auto = auto,
             at = math.max(.05, math.min(.95, at or .5)), maxMs = WCUtil.int(anim.maxMs, 300, 10000, 3000),
             onMount = anim.onMount == true }
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
    if anim.auto then
        -- the game's own length of the clip, cut at maxMs; 0 = the dictionary has no such clip
        local okD, seconds = pcall(GetAnimDuration, anim.dict, anim.clip)
        seconds = okD and tonumber(seconds) or 0
        if seconds <= 0 then
            WCDebug.log('clothing', 'animation %s/%s: the game has no such clip', anim.dict, anim.clip)
            return false
        end
        anim.duration = math.floor(math.min(seconds * 1000, anim.maxMs))
        anim.midpoint = math.floor(anim.duration * anim.at)
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
        local why = blocked(ped, anim.onMount and anim.riding) or flowActive()
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
    Appearance.Refresh(ped)            -- the garment is committed: w_lib's helpers read it back
    -- `app` does not hold the new value yet (the server confirms it later): a copy does
    local copy = WCUtil.copy(app)
    copy.clothing = type(copy.clothing) == 'table' and copy.clothing or {}
    copy.clothing.states = type(copy.clothing.states) == 'table' and copy.clothing.states or {}
    copy.clothing.states[groupId] = value
    -- ★ a garment going back on (the shirt, the trousers): the states that act on it (sleeves, collar,
    --   boots) are drawn again from their saved value. A full render while it was off reset them to
    --   base (resetWearable), which also overwrote w_lib's remembered state, so nothing else redraws
    --   them.
    if value ~= 'off' then
        local any = false
        for _, def in ipairs(WCClothingStates.groups) do
            if def.hiddenBy == groupId and WCClothingStates.applicable(copy, def.id) then
                any = Appearance.ApplyClothingState(ped, copy, def.id, WCClothingStates.current(copy, def.id)) or any
            end
        end
        if any then Appearance.Refresh(ped) end
    end
    -- ★ the hair's own state, on the committed change: taking the hat off, or raising / lowering the
    --   bandana, can leave a long hair tucked with no crown (Appearance.SettleHair)
    if Appearance.SettleHair(ped, copy) then Appearance.Refresh(ped) end
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
    -- the worn item must have the state (a neckerchief that cannot be raised, a body item without
    -- the chosen state): the game says so, nothing is played or sent
    if not C.supports(app, groupId, target) then return fail('STATE_NOT_APPLICABLE', { reason = 'item' }) end
    local flow = flowActive()
    if flow then
        WCDebug.log('clothing', 'refused %s=%s: %s', groupId, target, flow)
        return refusal(flow)
    end
    local anim = animationFor(groupId, target)
    -- ★ riding (a mount or a vehicle) never refuses the change: a clip made for riding too (onMount:
    --   the bandana, the mask, the hat) plays, any other change happens without its clip
    local riding = mounted(PlayerPedId())
    if anim and not anim.onMount and riding then anim = nil end
    -- a rider's clip may go on while he rides; getting on a horse or into a wagon mid-clip still stops it
    if anim then anim.riding = riding end
    local why = blocked(PlayerPedId(), anim == nil or anim.onMount)
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
    -- a state drawn here (a raised bandana) can tuck a long hair: without a hat, its crown goes
    if Appearance.SettleHair(ped, app) then Appearance.Refresh(ped) end
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
export('GetClothingActions', function() return C.actionList() end)
export('ToggleHat', function() return C.toggle('hat') end)
export('ToggleBandana', function() return C.toggle('bandana') end)
export('ToggleSleeves', function() return C.toggle('sleeves') end)
export('RemoveClothingCategory', function(category) return C.removeCategory(category) end)
export('RestoreClothingCategory', function(category) return C.restoreCategory(category) end)

--- Is the local character's bandana raised over the face? (Other resources: a masked player.)
function C.bandanaUp()
    local app = WCState.appearance
    if type(app) ~= 'table' or not WCClothingStates.byId.bandana then return false end
    return WCClothingStates.applicable(app, 'bandana') and WCClothingStates.current(app, 'bandana') == 'up'
end
export('IsBandanaUp', function() return C.bandanaUp() end)

-- ---------------------------------------------------------------------
--  One command per state group (Config.ClothingStates.commands): /hat, /gloves, ... flip their
--  group through C.toggle, so the guards, the animation and the server check all apply.
-- ---------------------------------------------------------------------
local COMMAND_HELP = 'تبديل: %s'
C.commands = {} -- [command] = groupId, the ones registered

--- Is a command of this name already registered by another resource?
local function registeredElsewhere(name)
    if type(GetRegisteredCommands) ~= 'function' then return false end
    local ok, list = pcall(GetRegisteredCommands)
    if not ok or type(list) ~= 'table' then return false end
    local me = GetCurrentResourceName()
    for _, entry in ipairs(list) do
        if type(entry) == 'table' and type(entry.name) == 'string' and entry.name:lower() == name:lower()
            and entry.resource ~= me then
            return true
        end
    end
    return false
end

local function suggest()
    for name, groupId in pairs(C.commands) do
        local def = WCClothingStates.byId[groupId]
        pcall(TriggerEvent, 'chat:addSuggestion', '/' .. name, L(COMMAND_HELP, L(def and def.label or groupId)))
    end
end

--- Register the configured commands once. A name given twice, one another resource registered, an
--  unknown group or a malformed name is skipped with a warning. Returns the number registered.
function C.registerCommands()
    local cfg = Config.ClothingStates and Config.ClothingStates.commands
    if type(cfg) ~= 'table' then return 0 end
    local taken = { [COMMAND] = true }
    for name in pairs(C.commands) do taken[name:lower()] = true end
    local groupIds = {}
    for groupId in pairs(cfg) do groupIds[#groupIds + 1] = tostring(groupId) end
    table.sort(groupIds) -- the same winner every start when two groups name one command
    local count = 0
    for _, groupId in ipairs(groupIds) do
        local name = cfg[groupId]
        if not WCClothingStates.byId[groupId] then
            WCDebug.warn('clothing', 'command for unknown state group %s skipped', groupId)
        elseif type(name) ~= 'string' or not name:match('^[%w_]+$') or #name > 32 then
            WCDebug.warn('clothing', 'command name of %s is not valid: skipped', groupId)
        elseif taken[name:lower()] then
            WCDebug.warn('clothing', 'command /%s is given twice (%s): skipped', name, groupId)
        elseif registeredElsewhere(name) then
            WCDebug.warn('clothing', 'command /%s belongs to another resource: skipped', name)
        else
            taken[name:lower()] = true
            C.commands[name] = groupId
            RegisterCommand(name, function() C.toggle(groupId) end, false)
            count = count + 1
        end
    end
    suggest()
    return count
end

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
    C.registerCommands()
    OnLanguageChange(function() suggest() end)
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
--  A hat that leaves the head outside this controller
-- ---------------------------------------------------------------------
-- ★ The game can take the hat off the player's head by itself: a punch, a fall from the horse or a
--   shot knocks it off, and no path of this resource or of w_lib runs then. A long hair the game
--   tucked while the hat was on keeps that state, drawn without its crown, until the next clothing
--   change runs the hair rule. So the hat on the head is watched (a category check, once a second)
--   and the hair rule runs once when the hat goes. It is w_lib's own check on the ped
--   (w.component.restoreHairState), not Appearance.SettleHair: the saved appearance still says the
--   hat is on. A flow or an action of this resource owns the ped then and settles the hair itself,
--   so the check waits for it to end.
local HAT_WATCH_STEP = 1000

local function hatOnHead(ped)
    -- the export may hand the function back as a callable funcref (type 'table'): presence only
    if not w.component.isCategoryEquiped then return false end
    local ok, on = pcall(w.component.isCategoryEquiped, ped, 'hats')
    return ok and on == true
end

CreateThread(function()
    local watched, hadHat = nil, false
    while not st.stopped do
        Wait(HAT_WATCH_STEP)
        local ped = PlayerPedId()
        if type(WCState.appearance) ~= 'table' or not pedExists(ped) then
            watched, hadHat = nil, false
        elseif ped ~= watched then
            watched, hadHat = ped, hatOnHead(ped)
        elseif not (C.busy() or isDown(ped) or flowActive()) then
            local hat = hatOnHead(ped)
            if hadHat and not hat and w.component.restoreHairState then
                local ok, changed = pcall(w.component.restoreHairState, ped)
                -- committed the way w_lib commits a wearable state (its refresh marks the metaped
                -- components updated first, as the game's scripts do): no other w_lib pass follows
                -- here to commit it, unlike the clothing actions
                if ok and changed == true then
                    if not (w.component.refreshPed and pcall(w.component.refreshPed, ped)) then
                        Appearance.Refresh(ped)
                    end
                end
            end
            hadHat = hat
        end
    end
end)

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
