-- tests/lua/metaped_engine.lua
-- A fake RedM metaped engine for the bald-crown regression (tests/test_hair_crown.py). Loaded on top
-- of the client stubs (test_client_infra_support) so the REAL w_lib component module and the REAL
-- appearance pipeline run against it. It models only what the regression needs, from the evidence:
--   * a shop item has its own wearable states (the game's shop item data, femga rdr3_discoveries
--     peds_customization/wearable_states.lua: the long MP hair styles such as
--     CLOTHING_ITEM_M_HAIR_023 have BASE / BASE_TUCKED / POMADE / POMADE_TUCKED, the short ones
--     BASE / POMADE);
--   * the shop item system switches OTHER items' states through triggers when a garment is added or
--     changes state (Cfx "Ped Modification and MetaData Overview": add / remove triggers);
--   * RemoveTagFromMetaPed and a state revert do not undo a triggered state (VORP resets the boots
--     by hand after the pants come off; w_lib re-applies the beard when the bandana goes down);
--   * a freshly applied shop item starts in BASE; an outfit preset clears the components.
-- The triggers are declared per test (Engine.onState / Engine.onAdd), so the bandana and the hat
-- hypotheses are each checked. When a trigger resolves is not known either: on the state change
-- (the default) or on the next commit (Engine.deferred = true: UPDATE_PED_VARIATION resolves the
-- pending ones), so the fix is checked under both timings.

Engine = { peds = {}, items = {}, tagCategory = {}, calls = {}, triggers = { state = {}, add = {} },
           deferred = false, pending = {} }
local E = Engine

local function u32(h)
    h = math.tointeger(tonumber(h))
    if not h then return nil end
    if h < 0 then h = h + 0x100000000 end
    return h
end
E.u32 = u32
local function s32(h) if h and h >= 0x80000000 then return h - 0x100000000 end return h end
local function J(name) return u32(joaat(name)) end
E.J = J

--- Declare a shop item: its category and its wearable states (names).
function E.item(hash, category, states)
    local list = {}
    for _, s in ipairs(states or { 'BASE' }) do list[#list + 1] = J(s) end
    E.items[u32(hash)] = { category = J(category), states = list }
end

function E.ped(p)
    local e = E.peds[p]
    if not e then e = { order = {}, comps = {} } E.peds[p] = e end
    return e
end

local function put(p, cat, comp)
    local e = E.ped(p)
    if not e.comps[cat] then e.order[#e.order + 1] = cat end
    e.comps[cat] = comp
end

local function drop(p, cat)
    local e = E.ped(p)
    if not e.comps[cat] then return end
    e.comps[cat] = nil
    for i, c in ipairs(e.order) do if c == cat then table.remove(e.order, i) break end end
end

local function has(list, v) for _, x in ipairs(list) do if x == v then return true end end return false end

-- a trigger moves the target category's item to `state` when that item has the state
local function resolve(p, list)
    for _, t in ipairs(list or {}) do
        local comp = E.ped(p).comps[J(t.category)]
        local item = comp and comp.item and E.items[comp.item]
        if item and has(item.states, J(t.state)) then
            comp.state = J(t.state)
            E.calls[#E.calls + 1] = 'trigger ' .. t.category .. ' ' .. t.state
        end
    end
end

-- a trigger fires now, or waits for the next commit when the engine defers them
local function fire(p, list)
    if not list or #list == 0 then return end
    if not E.deferred then return resolve(p, list) end
    local queue = E.pending[p] or {}
    for _, t in ipairs(list) do queue[#queue + 1] = t end
    E.pending[p] = queue
end

--- category reaching state -> targets { { category, state } } (e.g. the raised bandana)
function E.onState(category, state, targets) E.triggers.state[J(category) .. ':' .. J(state)] = targets end
--- category added to the ped -> targets (e.g. a hat)
function E.onAdd(category, targets) E.triggers.add[J(category)] = targets end

--- The state name of a category's item on a ped (nil when the category is not on the ped).
function E.stateName(p, category, names)
    local comp = E.ped(p).comps[J(category)]
    if not comp then return nil end
    for _, n in ipairs(names) do if J(n) == comp.state then return n end end
    return tostring(comp.state)
end
function E.has(p, category) return E.ped(p).comps[J(category)] ~= nil end

-- natives ---------------------------------------------------------------------------------------
local N = {}
N[0x77FF8D35EEC6BBC4] = function(p) E.peds[p] = { order = {}, comps = {} } E.pending[p] = nil end -- outfit preset
N[0xD3A7B003ED343FD9] = function(p, hash)                                                  -- apply shop item
    local item = E.items[u32(hash)]
    if not item then return end
    put(p, item.category, { item = u32(hash), state = J('BASE') })
    fire(p, E.triggers.add[item.category])
end
N[0xD710A5007C2AC539] = function(p, cat) drop(p, u32(cat)) end                               -- remove tag: no undo
N[0x66B957AAC2EAAEAB] = function(p, hash, state)                                           -- wearable state
    local h = u32(hash)
    for cat, comp in pairs(E.ped(p).comps) do
        if comp.item == h then
            comp.state = u32(state)
            E.calls[#E.calls + 1] = 'state ' .. tostring(h) .. ' ' .. tostring(u32(state))
            fire(p, E.triggers.state[cat .. ':' .. u32(state)])
        end
    end
end
N[0xBC6DF00D7A4A6819] = function(p, drawable)                                              -- metatag (hats, masks)
    local cat = E.tagCategory[u32(drawable)]
    if not cat then return end
    put(p, cat, { tag = true, drawable = u32(drawable), state = 0 })
    fire(p, E.triggers.add[cat])
end
N[0x63342C50EC115CE8] = function(hash)                                                     -- base layers
    local item = E.items[u32(hash)]
    if not item then return 0, 0, 0, 0, 0, 0, 0, 0 end
    local drawable = (u32(hash) ~ 0x5A5A) & 0x7fffffff
    E.tagCategory[drawable] = item.category
    return drawable, drawable + 1, drawable + 2, drawable + 3, 0, 0, 0, 0
end
N[0x5FF9A878C3D115B8] = function(hash)                                                     -- item category
    local item = E.items[u32(hash)]
    return item and s32(item.category) or nil
end
N[0x90403E8107B60E81] = function(p) return #E.ped(p).order end                              -- component count
N[0x9B90842304C938A7] = function(p, index)                                                 -- category at index
    local cat = E.ped(p).order[(index or 0) + 1]
    return cat and s32(cat) or 0
end
N[0xFB4891BD7578CDC1] = function(p, cat) return E.ped(p).comps[u32(cat)] and 1 or 0 end    -- BOOL answers 1
N[0xE7998FEC53A33BBE] = function() return 0, 0, 0, 0 end                                     -- asset tint
N[0xA0BC8FAED8CFEB3C] = function(p) return Peds[p] ~= nil and 1 or 0 end                   -- ready to render
N[0x772A1969F649E902] = function() return 0 end                                              -- is a horse
N[0xEC9A1261BF0CE510] = function() return 0 end                                              -- metaped type
N[0xFFCC2DB2D9953401] = function(hash)                                                     -- number of states
    local item = E.items[u32(hash)]
    return item and #item.states or 0
end
N[0x6243635AF2F1B826] = function(hash, i)                                                  -- state by index
    local item = E.items[u32(hash)]
    return item and s32(item.states[(i or 0) + 1]) or 0
end
N[0xCC8CA3E88256E58F] = function(p)                                                        -- update variation
    local queue = E.pending[p]
    E.pending[p] = nil
    if queue then resolve(p, queue) end
end
for _, h in ipairs({ 0x4EFC1F8FF1AD94DE, 0xAAB86462966168CE, 0x704C908E9C405136, 0x5653AB26C82938CF }) do
    N[h] = function() end
end

local previous = Citizen.InvokeNative
Citizen.InvokeNative = function(hash, ...)
    local fn = N[hash]
    if fn then return fn(...) end
    return previous(hash, ...)
end
InvokeNative = function(...) return Citizen.InvokeNative(...) end
Citizen.PointerValueInt = function() return 0 end
Citizen.ResultAsInteger = function() return nil end

function GetShopPedComponentAtIndex(p, index)
    local cat = E.ped(p).order[(index or 0) + 1]
    local comp = cat and E.ped(p).comps[cat]
    if not comp then return 0, 0, 0 end
    return comp.item and s32(comp.item) or 0, 0, comp.state and s32(comp.state) or 0
end
function GetMetaPedAssetGuids(p, index)
    local cat = E.ped(p).order[(index or 0) + 1]
    local comp = cat and E.ped(p).comps[cat]
    if not comp then return 0, 0, 0, 0, 0 end
    local d = comp.drawable or comp.item or 0
    return 0, d, d + 1, d + 2, d + 3
end
function RemoveTagFromMetaPed(p, cat) return N[0xD710A5007C2AC539](p, GetHashFromString(cat)) end
function EquipMetaPedOutfitPreset(p) N[0x77FF8D35EEC6BBC4](p) end
function IsPedMale() return true end
function GetMetaPedType() return 0 end
function SetCharExpression() end

-- entity state bags (w_lib keeps the wearable states of a networked ped there) -------------------
Bags = {}
function Entity(e)
    local bag = Bags[e]
    if not bag then
        bag = setmetatable({}, { __index = { set = function(self, k, v) rawset(self, k, v) end } })
        Bags[e] = bag
    end
    return { state = bag }
end
