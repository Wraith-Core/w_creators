-- =====================================================================
--  client/editor/panel.lua  —  WCPanel (ARCHITECTURE.md §3.2, §8.1)
--  A lightweight node-tree panel without scene or camera (clothing actions). It shares the
--  editor's look and validation model: the registry is derived from the tree the spec builds.
--
--  WCPanel.open(spec) -> true | false, code
--    spec = { title (locale key), build() -> Node (labels as locale keys or text),
--             onControl(control, value) -> Result, onClose() }
--  NUI: { type = 'panel', session = { id, title, locale, dir }, strings, tree } / { type = 'panelClose' }
--  NUI callbacks: panel:action { id, control, value? }, panel:close { id }
--    -> { ok, code?, message? (translated), payload?, closed? }
-- =====================================================================

WCPanel = {}
local P = WCPanel

local current = nil
local sequence = 0
local MAX_CONTROL = 96
local TEXT_FIELDS = { 'label', 'hint', 'reason', 'actionLabel', 'badgeLabel', 'summary', 'placeholder', 'confirmBody' }

local function L(key, ...)
    if type(locale) == 'function' then return locale(key, ...) end
    return key
end

local function send(message)
    if type(SendNUIMessage) == 'function' then SendNUIMessage(message) end
end

local function focus(on)
    if type(SetNuiFocus) == 'function' then SetNuiFocus(on, on) end
    if type(SetNuiFocusKeepInput) == 'function' then SetNuiFocusKeepInput(false) end
end

local function fail(code)
    local r = WCResult.fail(code)
    return { ok = false, code = r.code, message = L(r.message) }
end

--- Copy a node tree translating its text fields and collect the registry of its controls.
local function prepare(node, registry, depth)
    if type(node) ~= 'table' or depth > 12 then return nil end
    local out = {}
    for k, v in pairs(node) do
        if type(v) ~= 'table' then out[k] = v end
    end
    for _, field in ipairs(TEXT_FIELDS) do
        if type(node[field]) == 'string' then out[field] = L(node[field]) end
    end
    if type(node.options) == 'table' then
        out.options = {}
        local values = {}
        for _, o in ipairs(node.options) do
            -- an option without a value cannot be selected: it is not offered
            if type(o) == 'table' and o.value ~= nil then
                out.options[#out.options + 1] = { value = o.value,
                    label = type(o.label) == 'string' and L(o.label) or o.label, badge = o.badge }
                values[o.value] = true
            end
        end
        out._values = values
    end
    if type(node.range) == 'table' then out.range = { min = node.range.min, max = node.range.max, none = node.range.none } end
    if type(node.display) == 'table' then out.display = { scale = node.display.scale, decimals = node.display.decimals } end
    for _, axis in ipairs({ 'x', 'y' }) do
        local a = node[axis]
        if type(a) == 'table' and type(a.control) == 'string' then
            out[axis] = { control = a.control, value = a.value, label = type(a.label) == 'string' and L(a.label) or a.label }
            if not node.disabled then
                registry[a.control] = { kind = 'slider', min = tonumber(node.min) or -1, max = tonumber(node.max) or 1 }
            end
        end
    end
    if type(node.item) == 'table' then
        local item = node.item
        out.item = { name = type(item.name) == 'string' and L(item.name) or item.name, price = item.price,
                     owned = item.owned, equipped = item.equipped, variants = item.variants }
    end
    if type(node.items) == 'table' then
        out.items = {}
        for i, item in ipairs(node.items) do
            out.items[i] = { label = type(item.label) == 'string' and L(item.label) or item.label, value = item.value }
        end
    end
    if type(node.children) == 'table' then
        out.children = {}
        for _, child in ipairs(node.children) do
            local c = prepare(child, registry, depth + 1)
            if c then out.children[#out.children + 1] = c end
        end
    end
    if type(out.control) == 'string' and not out.disabled then
        local entry = { kind = out.kind }
        if out.kind == 'choice' then
            entry.values = out._values
            if out.range then
                entry.range = { min = out.range.none and 0 or (tonumber(out.range.min) or 0),
                                max = tonumber(out.range.max) or 0 }
            end
        elseif out.kind == 'slider' then
            entry.min, entry.max = tonumber(out.min) or 0, tonumber(out.max) or 1
            entry.integer = (tonumber(out.step) or 0) >= 1
        elseif out.kind == 'text' then
            entry.maxLength = tonumber(out.maxLength) or 64
        end
        registry[out.control] = entry
    end
    out._values = nil
    return out
end

local function build(s)
    local ok, tree = pcall(s.spec.build)
    if not ok then
        WCDebug.warn('panel', 'build failed: %s', tostring(tree))
        tree = nil
    end
    local registry = {}
    local prepared, root = pcall(prepare, type(tree) == 'table' and tree or {}, registry, 0)
    if not prepared or type(root) ~= 'table' then
        WCDebug.warn('panel', 'invalid panel tree: %s', tostring(root))
        registry, root = {}, {}
    end
    root.id, root.kind = root.id or 'root', 'group'
    root.children = root.children or {}
    if not root.label then root.label = L(s.spec.title or '') end
    s.registry = registry
    return root
end

--- The NUI payload of the open panel.
function P.payload(s)
    s = s or current
    if not s then return nil end
    return {
        type = 'panel',
        session = { id = s.id, title = L(s.spec.title or ''), locale = WCEditor.uiLocale(), dir = WCEditor.uiDir() },
        strings = WCEditor.strings(),
        tree = build(s),
    }
end

local function push(s)
    if s and current == s then send(P.payload(s)) end
end

--- Open a panel. Refused while the editor or another panel is open.
function P.open(spec)
    if current then return false, 'BUSY' end
    if type(spec) ~= 'table' or type(spec.build) ~= 'function' or type(spec.onControl) ~= 'function' then
        return false, 'INVALID_PAYLOAD'
    end
    if (WCEditor.isOpen and WCEditor.isOpen()) or WCEditor.session() then return false, 'BUSY' end
    sequence = sequence + 1
    local s = { id = 'panel-' .. sequence, spec = spec, registry = {}, busy = false }
    -- the first payload is built before anything is committed: no NUI focus without a rendered panel
    local ok, payload = pcall(P.payload, s)
    if not ok or type(payload) ~= 'table' then
        WCDebug.warn('panel', 'open failed: %s', tostring(payload))
        return false, 'INTERNAL_ERROR'
    end
    current = s
    focus(true)
    send(payload)
    return true
end

function P.isOpen() return current ~= nil end

function P.refresh() push(current) end

local function closeSession(s, notify)
    if current ~= s then return end
    current = nil
    s.closed = true
    send({ type = 'panelClose' })
    focus(false)
    if notify and type(s.spec.onClose) == 'function' then
        local ok, err = pcall(s.spec.onClose)
        if not ok then WCDebug.warn('panel', 'onClose failed: %s', tostring(err)) end
    end
end

--- Close the open panel (its onClose runs).
function P.close()
    if current then closeSession(current, true) end
end

local function validate(s, control, value)
    if type(control) ~= 'string' or #control == 0 or #control > MAX_CONTROL then return nil, 'INVALID_PAYLOAD' end
    local entry = s.registry[control]
    if not entry then return nil, 'INVALID_PAYLOAD' end
    if entry.kind == 'choice' or entry.kind == 'slider' then
        local n = type(value) == 'string' and tonumber(value) or value
        if type(n) ~= 'number' or not WCUtil.isFinite(n) then return nil, 'INVALID_PAYLOAD' end
        if entry.kind == 'choice' then
            if n % 1 ~= 0 then return nil, 'INVALID_PAYLOAD' end
            n = math.tointeger(n)
            if entry.range then n = math.max(entry.range.min, math.min(entry.range.max, n))
            elseif not (entry.values and entry.values[n]) then return nil, 'INVALID_PAYLOAD' end
            return n
        end
        n = math.max(entry.min, math.min(entry.max, n))
        if entry.integer then n = math.tointeger(math.floor(n + 0.5)) end
        return n
    elseif entry.kind == 'text' then
        if type(value) ~= 'string' then return nil, 'INVALID_PAYLOAD' end
        return WCUtil.trim(WCUtil.clampString(value, entry.maxLength) or '')
    elseif entry.kind == 'action' then
        return true
    end
    return nil, 'INVALID_PAYLOAD'
end

--- Handle one panel:action request.
function P.action(data)
    local s = current
    if type(data) ~= 'table' then return fail('INVALID_PAYLOAD') end
    if not s or data.id ~= s.id then
        local r = fail('SESSION_NOT_FOUND')
        r.closed = s == nil or nil
        return r
    end
    if s.busy then return fail('BUSY') end
    local value, code = validate(s, data.control, data.value)
    if value == nil then
        local r = fail(code)
        r.payload = P.payload(s)
        return r
    end
    local entry = s.registry[data.control]
    s.busy = true
    local ok, result = pcall(s.spec.onControl, data.control, entry.kind ~= 'action' and value or nil)
    s.busy = false
    if not ok then
        WCDebug.warn('panel', 'control %s failed: %s', tostring(data.control), tostring(result))
        result = WCResult.fail('INTERNAL_ERROR')
    elseif not WCResult.is(result) then
        result = WCResult.fail('INTERNAL_ERROR')
    end
    local out = { ok = result.ok == true }
    if not out.ok then
        out.code = result.code
        out.message = WCResult.text(result, L)
    end
    if current == s then out.payload = P.payload(s) else out.closed = true end
    return out
end

--- Handle panel:close.
function P.closeAction(data)
    local s = current
    if type(data) ~= 'table' or not s or data.id ~= s.id then return { ok = true, closed = true } end
    if s.busy then return fail('BUSY') end
    closeSession(s, true)
    return { ok = true, closed = true }
end

if type(RegisterNUICallback) == 'function' then
    RegisterNUICallback('panel:action', function(data, cb) cb(P.action(data)) end)
    RegisterNUICallback('panel:close', function(data, cb) cb(P.closeAction(data)) end)
end

if type(OnLanguageChange) == 'function' then
    OnLanguageChange(function() push(current) end)
end
