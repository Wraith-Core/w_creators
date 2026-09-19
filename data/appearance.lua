-- Stable appearance contract. Catalogues and component hashes belong to w_lib.
CreatorAppearance = {}
local A = CreatorAppearance
function A.decode(value)
    if type(value) == 'string' then local ok, data = pcall(json.decode, value); if ok then value = data end end
    return type(value) == 'table' and value or {}
end
function A.copy(value)
    if type(value) ~= 'table' then return value end
    local out = {}; for k, v in pairs(value) do out[k] = A.copy(v) end; return out
end
function A.number(v, lo, hi, fallback)
    v = tonumber(v)
    if not v or v ~= v or v == math.huge or v == -math.huge then return fallback or lo end
    return math.max(lo, math.min(hi, v))
end
function A.sex(value) return (value == true or value == 1 or value == 'male') and 'male' or 'female' end
local catalogs = {}
function A.catalog(sex)
    if catalogs[sex] then return catalogs[sex] end
    local out = {}
    for category, groups in pairs((GetLibraryPedComponentList() or {})[sex] or {}) do
        local entry = { models = {}, hashes = {} }
        for _, group in ipairs(groups) do
            if #(group.variations or {}) > 0 then
                local variants = {}; local model = #entry.models + 1
                for _, variant in ipairs(group.variations) do
                    local hash = tonumber(variant.hash)
                    if hash then
                        variants[#variants + 1] = { hash = hash & 0xffffffff, name = variant.hashname or '' }
                        entry.hashes[hash & 0xffffffff] = { model = model, variant = #variants, name = variant.hashname or '' }
                    end
                end
                entry.models[model] = variants
            end
        end
        out[category] = entry
    end
    if next(out) then catalogs[sex] = out end
    return out
end
function A.resolve(sex, category, value)
    local cat = A.catalog(sex)[category]
    if not cat then return nil end
    if type(value) == 'table' and not value.hash then
        local model = cat.models[tonumber(value[1]) or 0]
        return model and model[tonumber(value[2]) or 1] and model[tonumber(value[2]) or 1].hash
    end
    local hash = tonumber(type(value) == 'table' and value.hash or value)
    if hash and hash % 1 == 0 and cat.hashes[hash & 0xffffffff] then return hash & 0xffffffff end
end
A.essential = { heads = true, eyes = true, teeth = true, BODIES_UPPER = true, BODIES_LOWER = true }
function A.default(sex)
    local s = sex == 'male' and 'M' or 'F'
    local defaults = {
        heads = GetHashKey(('CLOTHING_ITEM_%s_HEAD_%03d_V_001'):format(s, sex == 'male' and 8 or 1)) & 0xffffffff,
        BODIES_UPPER = GetHashKey(('CLOTHING_ITEM_%s_BODIES_UPPER_001_V_001'):format(s)) & 0xffffffff,
        BODIES_LOWER = GetHashKey(('CLOTHING_ITEM_%s_BODIES_LOWER_001_V_001'):format(s)) & 0xffffffff,
        eyes = GetHashKey(('CLOTHING_ITEM_%s_EYES_001_TINT_014'):format(s)) & 0xffffffff,
        teeth = GetHashKey(('CLOTHING_ITEM_%s_TEETH_000'):format(s)) & 0xffffffff,
        hair = GetHashKey(('CLOTHING_ITEM_%s_HAIR_001_BLONDE'):format(s)) & 0xffffffff,
        mustache = 0,
    }
    for _, category in ipairs({'shirts_full','pants','boots'}) do
        local cat=A.catalog(sex)[category]
        if cat and cat.models[1] and cat.models[1][1] then defaults[category]=cat.models[1][1].hash end
    end
    return defaults
end
function A.normalize(raw)
    raw = A.decode(raw)
    local sex = A.sex(raw.isMale)
    local out = { isMale = sex == 'male', components = {}, faceFeatures = {}, overlays = {} }
    local defaults, source = A.default(sex), A.decode(raw.components)
    for category, value in pairs(source) do
        if A.catalog(sex)[category] then
            out.components[category] = A.resolve(sex, category, value) or (not A.essential[category] and 0 or nil)
        end
    end
    for category in pairs(A.essential) do out.components[category] = out.components[category] or defaults[category] end
    if out.components.hair == nil then out.components.hair = defaults.hair end
    if sex == 'male' then out.components.mustache = out.components.mustache or 0 end
    -- Old creators stored only the upper-body index. Pair its lower body by the actual asset name.
    if source.BODIES_LOWER == nil then
        local info = A.catalog(sex).BODIES_UPPER.hashes[out.components.BODIES_UPPER]
        if info and info.name ~= '' then
            out.components.BODIES_LOWER = A.resolve(sex, 'BODIES_LOWER', GetHashKey((info.name:gsub('UPPER', 'LOWER')))) or defaults.BODIES_LOWER
        end
    end
    out.components.__grooming = A.copy(A.decode(source.__grooming))
    out.components.__version = 2
    out.components.__scale = A.number(source.__scale, .9, 1.1, 1)
    out.components.__waist = math.floor(A.number(source.__waist, 1, 21, 11))
    out.components.__expressions = {}
    for name, value in pairs(A.decode(source.__expressions)) do
        if w.component.data.expressions[name] then out.components.__expressions[name] = A.number(value, -1, 1, 0) end
    end
    local validFeatures = {}
    for _,hash in pairs(w.component.data.expressions) do validFeatures[hash]=true end
    for _,field in ipairs(CreatorFeatureFields or {}) do if field.hash then validFeatures[field.hash]=true end end
    local seen = {}
    for _, feature in pairs(A.decode(raw.faceFeatures)) do
        local hash = type(feature) == 'table' and tonumber(feature.hash)
        if hash and validFeatures[hash] and not seen[hash] then
            seen[hash] = true
            out.faceFeatures[#out.faceFeatures + 1] = { hash = hash, index = A.number(feature.index, -1, 1, 0) }
        end
    end
    table.sort(out.faceFeatures, function(a,b) return a.hash < b.hash end)
    seen = {}
    for _, item in pairs(A.decode(raw.overlays)) do
        local definition = type(item) == 'table' and OverlayMap[item.compType]
        if definition and not seen[definition.layer] then
            seen[definition.layer] = true
            out.overlays[#out.overlays + 1] = { compType = item.compType,
                offsetModel = math.floor(A.number(item.offsetModel, 0, #definition.ids, 0)),
                offsetVariation = math.floor(A.number(item.offsetVariation, 1, 64, 1)), opacity = A.number(item.opacity, 0, 1, 1) }
        end
    end
    if raw.overlays == nil then
        out.overlays = {{compType='eyebrows',offsetModel=1,offsetVariation=1,opacity=.85}}
    end
    return out
end
function A.setChoice(app, category, model, variant)
    local sex = A.sex(app.isMale); local cat = A.catalog(sex)[category]
    if not cat then return false end
    model = math.floor(A.number(model, A.essential[category] and 1 or 0, #cat.models, 1))
    if model == 0 then app.components[category] = 0; return true end
    local variants = cat.models[model]
    variant = math.floor(A.number(variant, 1, #variants, 1))
    app.components[category] = variants[variant].hash
    local exclusive={coats='coats_closed',coats_closed='coats',ponchos='cloaks',cloaks='ponchos',pants='skirts',skirts='pants'}
    if exclusive[category] then app.components[exclusive[category]]=0 end
    if category == 'heads' or category == 'BODIES_UPPER' then
        local tone = variants[variant].name:match('_V_(%d+)')
        for _, other in ipairs({ 'heads', 'BODIES_UPPER', 'BODIES_LOWER' }) do
            local info = A.catalog(sex)[other].hashes[app.components[other]]
            if tone and info then
                local name = info.name:gsub('_V_%d+', '_V_' .. tone)
                if category == 'BODIES_UPPER' and other == 'BODIES_LOWER' then name = variants[variant].name:gsub('UPPER', 'LOWER') end
                app.components[other] = A.resolve(sex, other, GetHashKey(name)) or app.components[other]
            end
        end
    end
    return true
end
