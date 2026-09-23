-- =====================================================================
--  shared/grooming.lua  —  WCGrooming
--  Hair and beard growth on the v3 appearance (Config.Grooming). The growth state lives in
--  app.grooming = { hair = { stage, seconds }, beard = { stage, seconds } } (server-owned).
--  A stage is the index of the matching asset prefix in Config.Grooming.stages[sex][kind];
--  0 = none (bald / clean shaven); a style that matches no prefix counts as stage 1.
-- =====================================================================

WCGrooming = {}
local G = WCGrooming

local MAX_SECONDS = 864000

local function slot(kind) return kind == 'beard' and 'facial' or 'style' end
local function category(kind) return kind == 'beard' and 'mustache' or 'hair' end

local function stages(sex, kind)
    local cfg = Config.Grooming and Config.Grooming.stages
    local list = cfg and cfg[sex] and cfg[sex][kind]
    return type(list) == 'table' and #list > 0 and list or nil
end

local function itemName(app, kind)
    local hash = app.hair and app.hair[slot(kind)] or 0
    if not hash or hash == 0 then return nil end
    local cat = WCCatalog.forSex(app.sex)[category(kind)]
    local info = cat and cat.hashes[hash]
    return info and info.name or ''
end

local function stageFor(app, kind)
    local name = itemName(app, kind)
    if name == nil then return 0 end
    local upper = name:upper()
    for index, prefix in ipairs(stages(app.sex, kind) or {}) do
        if upper:sub(1, #prefix) == prefix then return index end
    end
    return 1
end

--- The current growth state { [kind] = { stage, seconds } } for the kinds configured for the sex.
function G.state(app)
    local saved = type(app.grooming) == 'table' and app.grooming or {}
    local out = {}
    for _, kind in ipairs({ 'hair', 'beard' }) do
        local list = stages(app.sex, kind)
        if list then
            local data = type(saved[kind]) == 'table' and saved[kind] or {}
            out[kind] = {
                stage = WCUtil.int(data.stage, 0, #list, stageFor(app, kind)),
                seconds = WCUtil.number(data.seconds, 0, MAX_SECONDS, 0),
            }
        end
    end
    return out
end

--- state() plus remainingMinutes until the next stage (0 at the last stage).
function G.info(app)
    local out = G.state(app)
    for kind, data in pairs(out) do
        local cap = #stages(app.sex, kind)
        local minutes = tonumber(Config.Grooming.minutesPerStage[kind]) or 0
        data.remainingMinutes = data.stage == cap and 0 or math.max(0, minutes - data.seconds / 60)
    end
    return out
end

local function colourOf(name)
    local upper = (name or ''):upper()
    return upper:match('_HAIR_%d+_(.+)$') or upper:match('_BEARD_%d+_(.+)$')
end

--- Add `seconds` of growth. Advancing a stage swaps the style for the next stage's asset in the
--  same colour. Writes app.grooming; returns true when a visible style changed.
function G.advance(app, seconds)
    local state = G.state(app)
    local changed = false
    for kind, data in pairs(state) do
        local list = stages(app.sex, kind)
        local interval = math.max(1, tonumber(Config.Grooming.minutesPerStage[kind]) or 1) * 60
        data.seconds = data.seconds + math.max(0, WCUtil.number(seconds, 0, MAX_SECONDS, 0))
        while data.seconds >= interval and data.stage < #list do
            data.seconds = data.seconds - interval
            data.stage = data.stage + 1
            local colour = colourOf(itemName(app, kind)) or 'BROWN'
            local hash = WCCatalog.resolve(app.sex, category(kind), WCUtil.u32(GetHashKey(list[data.stage] .. colour)))
            if hash and hash ~= app.hair[slot(kind)] then
                app.hair[slot(kind)] = hash
                changed = true
            end
        end
        if data.stage == #list then data.seconds = 0 end
    end
    app.grooming = state
    return changed
end

--- After a haircut: a kind whose style changed restarts from the new style's stage.
function G.cut(app, previous)
    local state = G.state(previous)
    for kind, data in pairs(state) do
        if app.hair[slot(kind)] ~= previous.hair[slot(kind)] then
            data.stage = stageFor(app, kind)
            data.seconds = 0
        end
    end
    app.grooming = state
end
