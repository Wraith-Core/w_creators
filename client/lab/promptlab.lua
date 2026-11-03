-- =====================================================================
--  client/lab/promptlab.lua  —  /promptlab: the staff's guided lab for the game's own prompts (2026-11-03)
--  Settles the open questions of ops/local/plans/game-prompts-arabic-spec.md (§9 lab list L1-L9) before any
--  phase is built: which per-frame number hides which English prompt, the true/false of
--  _MODIFY_PLAYER_UI_PROMPT_FOR_PED, whether a hidden prompt's key still acts, and whether the game's task natives
--  replay the action on our key (replayed actions keep the GAME's keys E / R / F: owner, 2026-11-03).
--  Staff only: the server checks Config.Admin.ace (the /servicesadmin permission) before the lab opens and on every
--  report; a normal player who types the command gets nothing. Nothing runs until the command opens it.
--  Flow per test: READY (the instruction at the top, J starts, Z skips) -> RUN (the setting is applied, the lab
--  measures on its own) -> ASK (one yes / no question: J yes, G no, Z again). Every answer goes to the server at
--  once (server/lab/promptlab.lua: a JSON line in promptlab.jsonl); the end sends the whole report (one console
--  line PROMPTLAB) and shows a code + a short summary to screenshot. BACKSPACE held = end now.
--  Every persistent change (the per-ped prompt switch, the carrying flag) is put back at the end of its test, at
--  the end of the lab and when the resource stops. Raw natives: client/natives/promptlab.lua (WCNative.lab).
-- =====================================================================

local N = WCNative.lab
local OPEN_CB = 'w_creators:promptlab:open'
local REPORT_CB = 'w_creators:promptlab:report'

local READY_MS = 400            -- a key press is not taken for this long after a phase changes
local PED_REASSERT_MS = 500     -- the per-ped switch is applied again this often while a test runs
local DONE_MS = 120000          -- the summary stays this long (or until J)
local CARD_MS = 250             -- how often the card checks it is still on screen
local LOOT_COMPLETE = GetHashKey('EVENT_LOOT_COMPLETE')
local REACH = 2.5               -- LOOT_HUMAN_PROMPT_TABLE radius (lootconfigdata.meta)
local HORSE_REACH = 4.0

-- ---------------------------------------------------------------------
--  The tests (spec §10 lab list). say / doing / ask are locale keys (the Arabic text).
--  target: what must be near when J starts it. hide: what the lab switches off.
--  replay: our card's row; on its key (or the game control) the lab runs the game's task.
--  watch: what the lab measures on its own. controls: game controls whose presses are counted.
-- ---------------------------------------------------------------------
local TESTS = {
    { id = '01', spec = 'L2', target = 'horse', hide = { kind = 'type', n = 12 }, sec = 12,
      watch = { 'mount' }, controls = { 'INPUT_ENTER' },
      say = 'قف بجانب حصان ليس لك (حصان عند عمود الربط مثلًا) حتى يظهر زر الركوب Mount، ثم اضغط J.',
      doing = 'انظر إلى زر الركوب: هل اختفى؟ بعدها جرّب الركوب بزر E.',
      ask = 'هل اختفى زر الركوب (Mount)؟' },
    { id = '02', spec = 'L3', target = 'horse', hide = { kind = 'blind', enable = 12 }, sec = 12,
      watch = { 'mount' }, controls = { 'INPUT_ENTER' },
      say = 'انزل عن الحصان إن كنت ركبته وقف بجانبه، ثم اضغط J.',
      doing = 'أزرار اللعبة كلها مخفية الآن، ويُفترض أن يبقى زر الركوب وحده. انظر إليه.',
      ask = 'هل بقي زر الركوب (Mount) ظاهرًا؟' },
    { id = '03', spec = 'B-mount', target = 'horse', hide = { kind = 'type', n = 12 }, sec = 15,
      replay = { task = 'mount', key = 'E', label = 'ركوب', controls = { 'INPUT_ENTER' }, afterMs = 6000 },
      watch = { 'mount' }, controls = { 'INPUT_ENTER' },
      say = 'ابقَ بجانب الحصان وأنت على الأرض، ثم اضغط J. ستظهر بطاقتنا بزر E للركوب.',
      doing = 'اضغط E من بطاقتنا لتركب الحصان.',
      ask = 'هل ركبت الحصان بحركة اللعبة العادية بعد ضغط E؟' },
    { id = '04', spec = 'L1', target = 'horse', hide = { kind = 'ped', type = 35, mode = 1, value = false }, sec = 15,
      watch = { 'focus' }, controls = { 'INPUT_INTERACT_LOCKON_TARGET_INFO' },
      say = 'انزل عن الحصان وقف بجانبه، ثم اضغط J.',
      doing = 'صوّب على الحصان بزر الفأرة الأيمن وانظر إلى زر المعلومات Show Info.',
      ask = 'هل اختفى زر المعلومات (Show Info) عن هذا الحصان؟' },
    { id = '05', spec = 'L1', target = 'horse', hide = { kind = 'ped', type = 35, mode = 1, value = true }, sec = 15,
      watch = { 'focus' }, controls = { 'INPUT_INTERACT_LOCKON_TARGET_INFO' },
      say = 'ابقَ عند الحصان نفسه، ثم اضغط J.',
      doing = 'صوّب على الحصان بزر الفأرة الأيمن وانظر إلى زر المعلومات Show Info.',
      ask = 'هل اختفى زر المعلومات (Show Info) عن هذا الحصان؟' },
    { id = '06', spec = 'L2', target = 'none', hide = { kind = 'type', n = 7 }, sec = 15,
      watch = { 'focus' }, controls = { 'INPUT_INTERACT_LOCKON_TARGET_INFO' },
      say = 'ابقَ قريبًا من الحصان، ثم اضغط J.',
      doing = 'صوّب على الحصان بزر الفأرة الأيمن وانظر إلى أزرار التصويب.',
      ask = 'هل اختفت كل أزرار التصويب الإنجليزية؟' },
    { id = '07', spec = 'L9', target = 'none', yieldCard = true, sec = 15,
      watch = { 'focus', 'melee' }, controls = { 'INPUT_MELEE_ATTACK' },
      say = 'اذهب إلى شخص من أهل البلد (ليس لاعبًا)، ثم اضغط J.',
      doing = 'صوّب على الشخص بزر الفأرة الأيمن حتى تظهر بطاقة «حديث»، ثم اضغط F.',
      ask = 'هل ضربت الشخص بالزر F؟' },
    { id = '08', spec = 'L9', target = 'none', yieldCard = true, sec = 15,
      watch = { 'focus' }, controls = { 'INPUT_EMOTE_DANCE' },
      say = 'ابقَ عند الشخص نفسه، ثم اضغط J.',
      doing = 'صوّب على الشخص بزر الفأرة الأيمن، ثم اضغط 1.',
      ask = 'هل عملت الحركة (الإيموت) بالزر 1؟' },
    { id = '09', spec = 'B-hogtie', target = 'living', hide = { kind = 'blind' }, sec = 12,
      replay = { task = 'hogtie', key = 'F', label = 'تقييد', controls = { 'INPUT_HOGTIE' }, afterMs = 6000 },
      watch = { 'hogtie' }, controls = { 'INPUT_HOGTIE' },
      say = 'قف ملاصقًا لشخص من أهل البلد (ليس لاعبًا)، ثم اضغط J. ستظهر بطاقتنا بزر F.',
      doing = 'اضغط F من بطاقتنا لتقييد الشخص.',
      ask = 'هل قيّدت الشخص بحركة اللعبة بعد ضغط F؟' },
    { id = '10', spec = 'B-cutfree', target = 'hogtied', hide = { kind = 'blind' }, sec = 12,
      replay = { task = 'cutfree', key = 'F', label = 'فك الحبل', controls = { 'INPUT_CUT_FREE' }, afterMs = 6000 },
      watch = { 'hogtie' }, controls = { 'INPUT_CUT_FREE' },
      say = 'قف عند شخص مقيّد (من التجربة السابقة أو قيّده بالحبل)، ثم اضغط J.',
      doing = 'اضغط F من بطاقتنا لفك الحبل.',
      ask = 'هل فككت الحبل بحركة اللعبة بعد ضغط F؟' },
    { id = '11', spec = 'L4', target = 'body', sec = 6,
      watch = { 'loot' }, controls = { 'INPUT_LOOT' },
      say = 'قف عند جثة شخص (ليس لاعبًا) لم تُفتَّش بعد حتى يظهر زر التفتيش Loot، ثم اضغط J.',
      doing = 'لا شيء مخفي الآن. انظر إلى زر التفتيش ولا تضغطه.',
      ask = 'هل كان زر التفتيش (Loot) ظاهرًا طوال الوقت؟' },
    { id = '12', spec = 'L2', target = 'body', hide = { kind = 'type', n = 3 }, sec = 12,
      watch = { 'loot', 'lootEvent' }, controls = { 'INPUT_LOOT' },
      say = 'ابقَ عند الجثة نفسها، ثم اضغط J.',
      doing = 'انظر إلى زر التفتيش: هل اختفى؟ بعدها جرّب التفتيش بزر E.',
      ask = 'هل اختفى زر التفتيش (Loot)؟' },
    { id = '13', spec = 'L8', target = 'body', hide = { kind = 'type', n = 3 }, sec = 15,
      replay = { task = 'loot', key = 'E', label = 'تفتيش', controls = { 'INPUT_LOOT', 'INPUT_LOOT2' }, afterMs = 8000 },
      watch = { 'loot', 'lootEvent' }, controls = { 'INPUT_LOOT' },
      say = 'قف عند جثة لم تُفتَّش بعد، ثم اضغط J. ستظهر بطاقتنا بزر E.',
      doing = 'اضغط E من بطاقتنا لتفتيش الجثة.',
      ask = 'هل فتّشت الجثة بحركة اللعبة نفسها بعد ضغط E؟' },
    { id = '14', spec = 'L2', target = 'carcass', hide = { kind = 'type', n = 3 }, sec = 12,
      watch = { 'loot', 'lootEvent', 'skin' }, controls = { 'INPUT_LOOT' },
      say = 'قف عند حيوان ميت لم يُسلخ بعد حتى يظهر زر السلخ Skin، ثم اضغط J.',
      doing = 'انظر إلى زر السلخ: هل اختفى؟ ولا تضغط E الآن.',
      ask = 'هل اختفى زر السلخ (Skin)؟' },
    { id = '15', spec = 'L6', target = 'carcass', hide = { kind = 'type', n = 3 }, sec = 15,
      replay = { task = 'loot', key = 'E', label = 'سلخ', controls = { 'INPUT_LOOT', 'INPUT_LOOT2' }, afterMs = 12000 },
      watch = { 'loot', 'lootEvent', 'skin' }, controls = { 'INPUT_LOOT' },
      say = 'ابقَ عند الحيوان نفسه، ثم اضغط J. ستظهر بطاقتنا بزر E.',
      doing = 'اضغط E من بطاقتنا لسلخ الحيوان، وانتظر حتى تنتهي الحركة.',
      ask = 'هل سلخت الحيوان ووصلتك رسالة الصيد بالغنائم؟' },
    { id = '16', spec = 'L5', target = 'carriable', hide = { kind = 'carry', flag = 37 }, sec = 12,
      watch = { 'carry' }, controls = { 'INPUT_PICKUP_CARRIABLE' },
      say = 'قف عند حيوان ميت يظهر عنده زر الحمل Pick Up، ثم اضغط J.',
      doing = 'انظر إلى زر الحمل: هل اختفى؟ بعدها جرّب الحمل بزر R.',
      ask = 'هل اختفى زر الحمل (Pick Up)؟' },
    { id = '17', spec = 'L2', target = 'carriable', hide = { kind = 'type', n = 5 }, sec = 12,
      watch = { 'carry' }, controls = { 'INPUT_PICKUP_CARRIABLE' },
      say = 'ضع الحيوان على الأرض إن كنت تحمله وقف عنده، ثم اضغط J.',
      doing = 'انظر إلى زر الحمل: هل اختفى؟ بعدها جرّب الحمل بزر R.',
      ask = 'هل اختفى زر الحمل (Pick Up)؟' },
    { id = '18', spec = 'L7', target = 'carriable', hide = { kind = 'type', n = 5 }, sec = 12,
      replay = { task = 'pickup', key = 'R', label = 'حمل', controls = { 'INPUT_PICKUP_CARRIABLE', 'INPUT_PICKUP_CARRIABLE2' },
                 afterMs = 5000 },
      watch = { 'carry' }, controls = { 'INPUT_PICKUP_CARRIABLE' },
      say = 'ضع الحيوان على الأرض إن كنت تحمله وقف عنده، ثم اضغط J. ستظهر بطاقتنا بزر R.',
      doing = 'اضغط R من بطاقتنا لحمل الحيوان.',
      ask = 'هل حملت الحيوان بحركة اللعبة بعد ضغط R؟' },
    { id = '19', spec = 'L2', target = 'carrying', hide = { kind = 'type', n = 5 }, sec = 12,
      watch = { 'drop' }, controls = { 'INPUT_DROP' },
      say = 'احمل الحيوان (أو أي جثة)، ثم اضغط J.',
      doing = 'انظر إلى زر الإنزال Drop: هل اختفى؟ بعدها جرّب الإنزال بزر R.',
      ask = 'هل اختفى زر الإنزال (Drop)؟' },
    { id = '20', spec = 'L2', target = 'chair', hide = { kind = 'type', n = 8 }, sec = 12,
      watch = { 'sit' }, controls = { 'INPUT_DYNAMIC_SCENARIO', 'INPUT_CONTEXT_Y' },
      say = 'قف بجانب كرسي أو مقعد حتى يظهر زر الجلوس Sit، ثم اضغط J.',
      doing = 'انظر إلى زر الجلوس: هل اختفى؟ بعدها جرّب الجلوس بزر E.',
      ask = 'هل اختفى زر الجلوس (Sit)؟' },
    { id = '21', spec = 'B-sit', target = 'chair', hide = { kind = 'type', n = 8 }, sec = 12,
      replay = { task = 'sit', key = 'E', label = 'جلوس', controls = { 'INPUT_DYNAMIC_SCENARIO', 'INPUT_CONTEXT_Y' },
                 afterMs = 5000 },
      watch = { 'sit' }, controls = { 'INPUT_DYNAMIC_SCENARIO', 'INPUT_CONTEXT_Y' },
      say = 'قم من الكرسي إن كنت جالسًا وقف بجانبه، ثم اضغط J. ستظهر بطاقتنا بزر E.',
      doing = 'اضغط E من بطاقتنا لتجلس.',
      ask = 'هل جلست على الكرسي بعد ضغط E؟' },
    { id = '22', spec = 'L2', target = 'none', hide = { kind = 'type', n = 2 }, sec = 12,
      say = 'قف أمام درج أو خزانة حتى يظهر زر الفتح Open، ثم اضغط J.',
      doing = 'انظر إلى زر الفتح: هل اختفى؟',
      ask = 'هل اختفى زر الفتح (Open)؟' },
    { id = '23', spec = 'L2', target = 'none', hide = { kind = 'sweep', from = 1, to = 20, stepMs = 2000 },
      say = 'قف في أي مكان يظهر فيه زر من أزرار اللعبة (حصان، جثة، كرسي)، ثم اضغط J.',
      doing = 'تمر الأرقام من 1 إلى 20. اضغط J كلما اختفى زر اللعبة.',
      ask = 'هل اختفى زر اللعبة عند رقم واحد على الأقل؟' },
}

WCPromptLab = { TESTS = TESTS }

-- ---------------------------------------------------------------------
--  Small helpers
-- ---------------------------------------------------------------------
local KEYS = { 'E', 'R', 'F', 'J', 'G', 'Z', 'BACKSPACE' }
local HASH = {}
local function control(name)
    local h = HASH[name]
    if not h then h = GetHashKey(name); HASH[name] = h end
    return h
end
local function short(name) return (tostring(name):gsub('^INPUT_', '')) end
local function yes(v) return v == true or v == 1 end
local function same(a, b) return a ~= nil and b ~= nil and (a & 0xFFFFFFFF) == (b & 0xFFFFFFFF) end

local function lib(name, ...)
    local ok, result = pcall(exports.w_lib[name], exports.w_lib, ...)
    return ok and result or nil
end

local function notify(key, kind, ...)
    pcall(w.notify, { description = locale(key, ...), type = kind or 'inform' })
end

local function text(value)
    pcall(function() w.showTextUI(value, { position = 'top-center' }) end)
end

local function hideText()
    pcall(function() w.hideTextUI() end)
end

--- "type:12" / "blind+enable:12" / "ped:35/1/false" / "carry:37" / "sweep:1-20" / "none" (+ ",replay:<task>")
local function hideCode(t)
    local h = t.hide
    local out = 'none'
    if h and h.kind == 'type' then out = 'type:' .. h.n
    elseif h and h.kind == 'blind' then out = h.enable and ('blind+enable:' .. h.enable) or 'blind'
    elseif h and h.kind == 'ped' then out = ('ped:%d/%d/%s'):format(h.type, h.mode, tostring(h.value))
    elseif h and h.kind == 'carry' then out = 'carry:' .. h.flag
    elseif h and h.kind == 'sweep' then out = ('sweep:%d-%d'):format(h.from, h.to) end
    if t.replay then out = out .. ',replay:' .. t.replay.task end
    return out
end
WCPromptLab.hideCode = hideCode

-- ---------------------------------------------------------------------
--  State
-- ---------------------------------------------------------------------
local S = nil          -- the running lab: { idx, phase, run, results, touched, code, ... }
local groupId = nil
local finish           -- defined with the reports below (the frames call it)

local function newState(code, first)
    return {
        idx = first, phase = 'ready', run = nil, results = {}, attempts = {}, touched = {}, flags = {},
        code = code, startedAt = GetGameTimer(), inputAfter = 0, cardAt = 0, claimAt = 0, doneUntil = 0,
    }
end

-- ---------------------------------------------------------------------
--  The card (one w_lib group, its rows shown per phase)
-- ---------------------------------------------------------------------
local function ensureGroup()
    if groupId then return groupId end
    groupId = lib('CreateGroup', locale('مختبر الأزرار'), 'bottom-right')
    if not groupId then return nil end
    for _, key in ipairs(KEYS) do
        lib('AddPrompt', groupId, key, ' ', key == 'BACKSPACE' and 1500 or false)
        lib('SetPromptVisible', groupId, key, false)
    end
    return groupId
end

local function rows(title, map)
    if not ensureGroup() then return end
    lib('SetTitle', groupId, title)
    for _, key in ipairs(KEYS) do
        local label = map[key]
        if label then
            lib('SetPromptLabel', groupId, key, label)
            lib('SetPromptVisible', groupId, key, true)
        else
            lib('SetPromptVisible', groupId, key, false)
        end
    end
end

--- Keep the card on screen (another resource's Display hides it) and claim the walk-up slot so cards of
--  the other resources stand aside while the lab runs.
local function keepCard(now)
    if not groupId then return end
    if now >= S.claimAt then
        S.claimAt = now + 100
        lib('WalkupClaim', 0.0)
    end
    if now >= S.cardAt then
        S.cardAt = now + CARD_MS
        if lib('IsVisible', groupId) ~= true then lib('Display', groupId) end
    end
end

local function pressed(now, key)
    return groupId ~= nil and now >= S.inputAfter and lib('IsCompleted', groupId, key) == true
end

local function phase(name)
    S.phase = name
    S.inputAfter = GetGameTimer() + READY_MS
    S.cardAt = 0
end

local function test() return TESTS[S.idx] end

local function title()
    return locale('مختبر الأزرار · %s من %s', S.idx, #TESTS)
end

local function showReady()
    local t = test()
    rows(title(), { J = locale('ابدأ التجربة'), Z = locale('تخطَّ'), BACKSPACE = locale('إنهاء المختبر') })
    text(locale('تجربة %s من %s', S.idx, #TESTS) .. '\n' .. locale(t.say))
    phase('ready')
end

-- ---------------------------------------------------------------------
--  Targets
-- ---------------------------------------------------------------------
local function peds()
    local ok, list = pcall(GetGamePool, 'CPed')
    return ok and type(list) == 'table' and list or {}
end

local function stablesTagged(e)
    local ok, tag = pcall(function() return Entity(e).state['w_stables'] end)
    return ok and tag ~= nil
end

local function isHorse(p)
    local ok, model = pcall(GetEntityModel, p)
    return ok and N.isHorseModel(model)
end

local function dead(p) return yes(IsPedDeadOrDying(p, true)) end
local function npcHuman(p) return yes(IsPedHuman(p)) and not yes(IsPedAPlayer(p)) end

local function nearest(radius, pick)
    local me = PlayerPedId()
    local at = GetEntityCoords(me)
    local best, bestD
    for _, p in ipairs(peds()) do
        if p ~= me and yes(DoesEntityExist(p)) then
            local d = #(GetEntityCoords(p) - at)
            if d <= radius and (not bestD or d < bestD) and pick(p) then best, bestD = p, d end
        end
    end
    return best, bestD
end

local function aimedOrTarget()
    local pid = PlayerId()
    local ok, found, e = pcall(GetEntityPlayerIsFreeAimingAt, pid)
    if ok and yes(found) and e and e ~= 0 then return e end
    ok, found, e = pcall(GetPlayerTargetEntity, pid)
    if ok and yes(found) and e and e ~= 0 then return e end
    return nil
end

local PICK = {
    horse = function(p) return isHorse(p) and not dead(p) and not stablesTagged(p) end,
    body = function(p) return npcHuman(p) and dead(p) and not N.fullyLooted(p) and N.lootingPed(p) == 0 end,
    carcass = function(p) return N.isAnimal(p) and not isHorse(p) and dead(p) and not N.skinned(p) end,
    carriable = function(p)
        return dead(p) and (npcHuman(p) or (N.isAnimal(p) and not isHorse(p))) and N.isCarriable(p) and N.carrier(p) == 0
    end,
    living = function(p) return npcHuman(p) and not dead(p) and not N.hogtied(p) and not yes(IsPedOnMount(p)) end,
    hogtied = function(p) return npcHuman(p) and N.hogtied(p) end,
}

local MISSING = {
    horse = 'لا يوجد حصان قريب يصلح للتجربة (حصان الإسطبل لا يصلح).',
    body = 'لا توجد جثة قريبة لم تُفتَّش.',
    carcass = 'لا يوجد حيوان ميت قريب لم يُسلخ.',
    carriable = 'لا يوجد شيء قريب يمكن حمله.',
    living = 'لا يوجد شخص قريب يصلح للتجربة.',
    hogtied = 'لا يوجد شخص مقيّد قريب.',
    carrying = 'أنت لا تحمل شيئًا.',
}

--- The nearest scenario point within 1.5 m (chairs, benches). Never blocks the test: without a point the
--  replay asks the game for the nearest scenario instead. info.hd = slot 0 held the count.
local function chairInfo()
    local at = GetEntityCoords(PlayerPedId())
    local pts = N.scenarioPoints(at.x, at.y, at.z, 1.5, 8)
    local info = { c = pts and pts.count or -1, s0 = pts and pts.slots[1] or nil }
    if not pts or pts.count <= 0 then return info end
    local header = pts.slots[1] == pts.count
    info.hd = header or nil
    local first = header and 2 or 1
    local bestD
    for i = first, math.min(#pts.slots, first + pts.count - 1) do
        local point = pts.slots[i]
        if N.pointExists(point) then
            local c = N.pointCoords(point)
            local d = c and #(vector3(c.x, c.y, c.z) - at) or 99.0
            if not bestD or d < bestD then info.point, bestD = point, d end
        end
    end
    return info
end

--- target entity (0 for none / chair) + info, or nil + the reason key
local function findTarget(kind)
    if kind == 'none' then return 0, {} end
    if kind == 'chair' then return 0, chairInfo() end
    if kind == 'carrying' then
        local c = N.carrying(PlayerPedId())
        if c ~= 0 then return c, {} end
        return nil, MISSING.carrying
    end
    local pick = PICK[kind]
    if kind == 'horse' then
        local aimed = aimedOrTarget()
        if aimed and yes(IsEntityAPed(aimed)) and pick(aimed) then return aimed, {} end
    end
    local e, d = nearest(kind == 'horse' and HORSE_REACH or REACH, pick)
    if not e then return nil, MISSING[kind] end
    return e, { td = math.floor((d or 0) * 10 + 0.5) }
end

local function canStart()
    local me = PlayerPedId()
    if yes(IsPedDeadOrDying(me, true)) then return 'لا تبدأ التجربة وأنت ميت.' end
    if yes(IsPedOnMount(me)) then return 'انزل عن الحصان أولًا.' end
    if yes(IsPedInAnyVehicle(me, false)) then return 'انزل من العربة أولًا.' end
    return nil
end

-- ---------------------------------------------------------------------
--  RUN
-- ---------------------------------------------------------------------
local function since(now) return now - S.run.startAt end

local function startHide(t, run)
    local h, e = t.hide, run.target
    if not h then return end
    if h.kind == 'ped' and e ~= 0 then
        local entry = { ped = e, type = h.type, mode = h.mode, value = h.value,
                        r0 = N.isEnabledForPed(e, h.type, h.mode), restored = false }
        S.touched[#S.touched + 1] = entry
        run.ped = entry
        N.modifyForPed(e, h.type, h.mode, h.value)
        run.reassertAt = GetGameTimer() + PED_REASSERT_MS
        run.auto.rb = { r0 = entry.r0 }
    elseif h.kind == 'carry' and e ~= 0 then
        local entry = { carry = e, flag = h.flag, before = N.getCarryingFlag(e, h.flag), restored = false }
        S.touched[#S.touched + 1] = entry
        run.carry = entry
        N.setCarryingFlag(e, h.flag, true)
        run.auto.cf = { b = entry.before, a = N.getCarryingFlag(e, h.flag) }
    elseif h.kind == 'sweep' then
        run.sweepN, run.sweepAt, run.auto.hits = h.from, GetGameTimer() + h.stepMs, {}
    end
end

local function frameHide(t, run, now)
    local h = t.hide
    if not h then return end
    if h.kind == 'type' then
        N.disableType(h.n)
    elseif h.kind == 'blind' then
        N.blind()
        if h.enable then N.enableType(h.enable) end
    elseif h.kind == 'sweep' then
        N.disableType(run.sweepN)
    elseif h.kind == 'ped' and run.ped and now >= run.reassertAt then
        run.reassertAt = now + PED_REASSERT_MS
        N.modifyForPed(run.ped.ped, h.type, h.mode, h.value)
        if run.auto.rb.r1 == nil then
            run.auto.rb.r1 = N.isEnabledForPed(run.ped.ped, h.type, h.mode)
            if run.auto.rb.r1 ~= nil and run.ped.r0 ~= nil and run.auto.rb.r1 ~= run.ped.r0 then S.flags.rbMoved = true end
        end
    end
end

--- Put a per-ped switch / a carrying flag back. The readback decides for the per-ped switch: it is reversed
--  when it moved off its first value; the owner's "it hid" (`force`) counts only while no readback of this lab
--  has ever moved (a readback that works is trusted over the eye).
local function restoreEntry(entry, force)
    if entry.restored then return end
    if entry.carry then
        if yes(DoesEntityExist(entry.carry)) then N.setCarryingFlag(entry.carry, entry.flag, entry.before == true) end
        entry.restored = true
        return entry.before == true
    end
    if not yes(DoesEntityExist(entry.ped)) then entry.restored = true return nil end
    local now = N.isEnabledForPed(entry.ped, entry.type, entry.mode)
    local moved = now ~= nil and entry.r0 ~= nil and now ~= entry.r0
    if moved then S.flags.rbMoved = true end
    if moved or (force and not S.flags.rbMoved) then
        N.modifyForPed(entry.ped, entry.type, entry.mode, not entry.value)
        entry.restored = true
        return N.isEnabledForPed(entry.ped, entry.type, entry.mode)
    end
    return nil
end

local function scanLootEvents(run, me)
    local n = N.eventCount(0)
    for i = 0, n - 1 do
        if same(N.eventAt(0, i), LOOT_COMPLETE) then
            local looter, ped, success = N.lootEventData(0, i)
            if looter == me and not run.auto.ev then
                run.auto.ev = { same = ped == run.target, ok = success, ms = since(GetGameTimer()) }
            end
        end
    end
end

local WATCH = {
    mount = function(run, me, now) if not run.auto.mount and yes(IsPedOnMount(me)) then run.auto.mount = since(now) end end,
    loot = function(run, me, now)
        if not run.auto.loot and run.target ~= 0 and N.lootingPed(run.target) == me then run.auto.loot = since(now) end
    end,
    lootEvent = function(run, me) scanLootEvents(run, me) end,
    carry = function(run, me, now)
        local c = N.carrying(me)
        if c ~= 0 then
            run.auto.carry = run.auto.carry or since(now)
            if c == run.target then run.auto.carryT = true end
        end
    end,
    drop = function(run, me, now)
        if not run.auto.drop and N.carrying(me) == 0 and not N.carryingSomething(me) then run.auto.drop = since(now) end
    end,
    sit = function(run, me, now) if not run.auto.sat and N.usingScenario(me) then run.auto.sat = since(now) end end,
    melee = function(run, me, now)
        if not run.auto.melee and yes(IsPedInMeleeCombat(me)) then run.auto.melee = since(now) end
    end,
    focus = function(run)
        local pid = PlayerId()
        if not yes(IsPlayerFreeFocusing(pid)) then return end
        run.auto.focus = (run.auto.focus or 0) + 1
        local ok, found, e = pcall(GetPlayerTargetEntity, pid)
        if ok and yes(found) and e and e ~= 0 and yes(IsEntityAPed(e)) and yes(IsPedHuman(e)) then
            run.auto.focusH = (run.auto.focusH or 0) + 1
        end
    end,
    hogtie = function() end, -- read at the start and the end
    skin = function() end,   -- read at the start and the end
}

local function has(list, name)
    for _, v in ipairs(list or {}) do if v == name then return true end end
    return false
end

local function snapshot(t, run, key)
    if run.target == 0 or not yes(DoesEntityExist(run.target)) then return end
    if has(t.watch, 'hogtie') then run.auto['hog' .. key] = N.hogtied(run.target) end
    if has(t.watch, 'skin') then run.auto['skin' .. key] = N.skinned(run.target) end
end

local function fire(t, run, src, now)
    local me, rp, e = PlayerPedId(), t.replay, run.target
    local ok = false
    if rp.task == 'loot' then ok = N.taskLoot(me, e)
    elseif rp.task == 'pickup' then ok = N.taskPickup(me, e)
    elseif rp.task == 'mount' then ok = N.taskMount(me, e)
    elseif rp.task == 'hogtie' then ok = N.taskHogtie(me, e)
    elseif rp.task == 'cutfree' then ok = N.taskCutFree(me, e)
    elseif rp.task == 'sit' then
        local point = run.info.point
        if point then
            ok, run.auto.used = N.taskUsePoint(me, point), 'point'
        else
            local at = GetEntityCoords(me)
            ok, run.auto.used = N.taskNearestScenario(me, at.x, at.y, at.z, 1.5), 'nearest'
        end
    end
    run.fired = true
    run.auto.fire = { src = src, ms = since(now), kb = N.keyboard(), ok = ok == true }
    run.endAt = math.max(run.endAt, now + (rp.afterMs or 6000))
    if groupId then lib('SetPromptVisible', groupId, rp.key, false) end
end

local function beginRun(target, info)
    local t = test()
    local now = GetGameTimer()
    local run = { target = target, info = info or {}, startAt = now, endAt = now + (t.sec or 12) * 1000,
                  auto = { pf = 0, pa = 0, k = {} }, fired = false, shownSec = -1 }
    if target ~= 0 then
        local ok, model = pcall(GetEntityModel, target)
        run.auto.tm = ok and model or nil
    end
    run.auto.td = run.info.td
    if t.target == 'chair' then run.auto.pts = { c = run.info.c, s0 = run.info.s0, hd = run.info.hd, pt = run.info.point ~= nil } end
    S.run = run
    snapshot(t, run, '0')
    startHide(t, run)
    local map = {}
    if t.replay then map[t.replay.key] = locale(t.replay.label) end
    if t.hide and t.hide.kind == 'sweep' then
        map.J = locale('اختفى الزر الآن')
    elseif not t.yieldCard then
        map.J = locale('انتهيت')
    end
    map.BACKSPACE = locale('إنهاء المختبر')
    rows(title(), map)
    if t.yieldCard and groupId then lib('Hide', groupId) end
    local hint = t.yieldCard and locale('تنتهي التجربة وحدها بعد ثوانٍ.') or ''
    text(locale(t.doing) .. (hint ~= '' and ('\n' .. hint) or ''))
    phase('run')
end

local function endRun()
    local t, run = test(), S.run
    local now = GetGameTimer()
    snapshot(t, run, '1')
    run.auto.ms = since(now)
    if run.ped then
        run.auto.rb.r2 = restoreEntry(run.ped, false)
    elseif run.carry then
        restoreEntry(run.carry, false)
        run.auto.cf.r = N.getCarryingFlag(run.carry.carry, run.carry.flag)
    end
    local errs = N.takeErrors()
    if #errs > 0 then run.auto.err = errs end
    S.attempts[#S.attempts + 1] = run.auto
    while #S.attempts > 4 do table.remove(S.attempts, 1) end
    rows(title(), { J = locale('نعم'), G = locale('لا'), Z = locale('أعد التجربة'), BACKSPACE = locale('إنهاء المختبر') })
    text(locale(t.ask))
    phase('ask')
end

local function runFrame(now)
    local t, run = test(), S.run
    local me = PlayerPedId()
    if not t.yieldCard then keepCard(now) end
    -- 1. the game's own prompt state, read before any hide in this frame (L4)
    local first = t.controls and t.controls[1]
    if first then
        run.auto.pf = run.auto.pf + 1
        if N.controlPromptActive(control(first)) then run.auto.pa = run.auto.pa + 1 end
    end
    -- 2. the setting under test
    frameHide(t, run, now)
    -- 3. our replay: the game control is ours while the card shows it (no double action)
    local rp = t.replay
    if rp and not run.fired then
        for _, c in ipairs(rp.controls) do DisableControlAction(0, control(c), true) end
    end
    -- 4. the presses of the game controls
    local seen = {}
    for _, list in ipairs({ t.controls or {}, rp and rp.controls or {} }) do
        for _, c in ipairs(list) do
            if not seen[c] then
                seen[c] = true
                local h = control(c)
                if yes(IsControlJustPressed(0, h)) or yes(IsDisabledControlJustPressed(0, h)) then
                    run.auto.k[short(c)] = (run.auto.k[short(c)] or 0) + 1
                    if rp and not run.fired and has(rp.controls, c) then fire(t, run, 'control', now) end
                end
            end
        end
    end
    if rp and not run.fired and pressed(now, rp.key) then fire(t, run, 'card', now) end
    -- 5. what happened, measured
    for _, name in ipairs(t.watch or {}) do
        local fn = WATCH[name]
        if fn then fn(run, me, now) end
    end
    -- 6. the sweep's next number / the owner's marks
    local h = t.hide
    if h and h.kind == 'sweep' then
        if pressed(now, 'J') then
            run.auto.hits[#run.auto.hits + 1] = { n = run.sweepN, p = run.sweepPrev, ms = since(now) }
        end
        if now >= run.sweepAt then
            run.sweepPrev, run.sweepN, run.sweepAt = run.sweepN, run.sweepN + 1, now + h.stepMs
            if run.sweepN > h.to then return endRun() end
        end
        if run.shownSec ~= run.sweepN then
            run.shownSec = run.sweepN
            lib('SetTitle', groupId, locale('الرقم %s', run.sweepN))
        end
    else
        local left = math.max(0, math.ceil((run.endAt - now) / 1000))
        if left ~= run.shownSec then
            run.shownSec = left
            if groupId and not t.yieldCard then lib('SetTitle', groupId, locale('جارية · %s ث', left)) end
        end
        if not t.yieldCard and pressed(now, 'J') then return endRun() end
        if now >= run.endAt then return endRun() end
    end
    if pressed(now, 'BACKSPACE') then return finish('stopped') end
end

-- ---------------------------------------------------------------------
--  ASK / reports / the end
-- ---------------------------------------------------------------------
local function send(kind, payload)
    local ok, res = pcall(w.callback.await, REPORT_CB, false, kind, payload)
    return ok and type(res) == 'table' and res or nil
end

local function result(t, answer)
    local r = { id = t.id, spec = t.spec, hide = hideCode(t), answer = answer, tries = #S.attempts,
                at = GetGameTimer() - S.startedAt }
    if #S.attempts > 0 then r.attempts = S.attempts end
    return r
end

local function nextTest()
    S.attempts, S.run = {}, nil
    S.idx = S.idx + 1
    if S.idx > #TESTS then return 'end' end
    showReady()
end

local function answer(value)
    local t = test()
    if value == 'y' and S.run and S.run.ped then
        local r3 = restoreEntry(S.run.ped, true)
        if r3 ~= nil and S.attempts[#S.attempts] then S.attempts[#S.attempts].rb.r3 = r3 end
    end
    local r = result(t, value)
    S.results[#S.results + 1] = r
    CreateThread(function() send('result', r) end)
    if nextTest() == 'end' then finish('done') end
end

local function askFrame(now)
    keepCard(now)
    DisableControlAction(0, control('INPUT_INTERACT_ANIMAL'), true) -- G must not pat a horse here
    if pressed(now, 'J') then return answer('y') end
    if pressed(now, 'G') then return answer('n') end
    if pressed(now, 'Z') then return showReady() end
    if pressed(now, 'BACKSPACE') then return finish('stopped') end
end

local function readyFrame(now)
    keepCard(now)
    if pressed(now, 'BACKSPACE') then return finish('stopped') end
    if pressed(now, 'Z') then
        local r = result(test(), 's')
        S.results[#S.results + 1] = r
        CreateThread(function() send('result', r) end)
        if nextTest() == 'end' then finish('done') end
        return
    end
    if not pressed(now, 'J') then return end
    local why = canStart()
    if why then return notify(why, 'error') end
    local target, info = findTarget(test().target)
    if not target then return notify(info, 'error') end
    beginRun(target, info)
end

local function restoreAll()
    for _, entry in ipairs(S and S.touched or {}) do pcall(restoreEntry, entry, false) end
end

local function closeLab()
    if groupId then
        lib('Hide', groupId)
        lib('DeleteGroup', groupId)
        groupId = nil
    end
    lib('WalkupRelease')
    hideText()
    S = nil
end

local function summary()
    local words = { y = locale('نعم'), n = locale('لا'), s = locale('تُركت') }
    local parts = {}
    for _, r in ipairs(S.results) do
        parts[#parts + 1] = r.id .. ' ' .. (words[r.answer] or r.answer)
    end
    local lines = {}
    for i = 1, #parts, 6 do lines[#lines + 1] = table.concat(parts, ' · ', i, math.min(i + 5, #parts)) end
    return table.concat(lines, '\n')
end

finish = function(reason)
    if not S or S.phase == 'done' then return end
    if S.phase == 'run' and S.run then endRun() end
    -- a test that ran but got no answer keeps its measurements (answer 'x')
    if #S.attempts > 0 and test() then S.results[#S.results + 1] = result(test(), 'x') end
    restoreAll()
    S.phase = 'done'
    S.inputAfter, S.doneUntil = math.huge, math.huge -- nothing closes the lab while the report travels
    if groupId then lib('Hide', groupId) end
    local report = { v = 1, reason = reason, n = #TESTS, last = S.idx, kb = N.keyboard(),
                     ms = GetGameTimer() - S.startedAt, results = S.results, err = N.takeErrors(), flags = S.flags }
    local res = send('final', report)
    if not S then return end
    local code = res and res.ok and res.code or S.code
    rows(locale('مختبر الأزرار'), { J = locale('إغلاق') })
    text(locale('انتهى المختبر. صوّر هذه الشاشة وأرسلها.') .. '\n' .. locale('الرمز: %s', tostring(code)) .. '\n' .. summary())
    if res and res.ok then notify('أُرسلت النتائج إلى السيرفر.', 'success') else notify('تعذّر إرسال النتائج، صوّر الشاشة.', 'error') end
    S.doneUntil = GetGameTimer() + DONE_MS
    S.inputAfter = GetGameTimer() + 1500
end

local function doneFrame(now)
    keepCard(now)
    if pressed(now, 'J') or now >= S.doneUntil then closeLab() end
end

local FRAMES = { ready = readyFrame, run = runFrame, ask = askFrame, done = doneFrame }

local function loop()
    while S do
        local fn = FRAMES[S.phase]
        local ok, err = pcall(fn, GetGameTimer())
        if not ok and S then
            S.flags.loopErr = tostring(err):sub(1, 120)
            WCDebug.warn('promptlab', 'lab frame failed: %s', tostring(err))
            Wait(250)
        end
        Wait(0)
    end
end

RegisterCommand('promptlab', function(_, args)
    if S then
        if S.phase == 'done' then return closeLab() end
        return CreateThread(function() finish('stopped') end)
    end
    CreateThread(function()
        local ok, res = pcall(w.callback.await, OPEN_CB, false)
        if not ok or type(res) ~= 'table' or res.ok ~= true then return end -- not staff: nothing at all
        local first = math.tointeger(tonumber(args and args[1])) or 1
        S = newState(res.code, math.max(1, math.min(#TESTS, first)))
        if not ensureGroup() then S = nil return end
        notify('بدأ مختبر الأزرار. اتبع التعليمات أعلى الشاشة.', 'success')
        showReady()
        loop()
    end)
end, false)

AddEventHandler('onResourceStop', function(name)
    if name ~= GetCurrentResourceName() or not S then return end
    restoreAll()
    closeLab()
end)
