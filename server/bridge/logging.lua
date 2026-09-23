-- =====================================================================
--  server/bridge/logging.lua  —  CreatorLogs (ARCHITECTURE.md §3.3)
--  The optional logger (w_lib's w.logs → w_logs). Logging never blocks character selection, spawn,
--  isolation or any commit: a missing module, a throwing transport or a logger that starts later
--  are all tolerated. Every call is protected; Emit returns false when nothing was logged.
-- =====================================================================
CreatorLogs = {}

--- w.logs, or nil when the library has no logger (never throws).
local function logger()
    local ok, logs = pcall(function() return w.logs end)
    if ok and type(logs) == 'table' then return logs end
    return nil
end

local function ready()
    local logs = logger()
    if not logs or type(logs.IsReady) ~= 'function' then return false end
    local ok, value = pcall(logs.IsReady)
    return ok and value == true
end

--- Run register(proxy) once the logger is ready; the proxy turns a refused registration into an
--  error so the caller retries on the next logsReady. Returns true when everything registered.
function CreatorLogs.Register(register)
    if not ready() then return false end
    local logs = logger()
    local proxy = {}
    for _, name in ipairs({ 'RegisterScript', 'RegisterLogType' }) do
        proxy[name] = function(data)
            local fn = logs[name]
            if type(fn) ~= 'function' then error('log registration unavailable') end
            local result = fn(data)
            if type(result) ~= 'table' or result.ok ~= true then error('log registration unavailable') end
            return result
        end
    end
    local ok = pcall(register, proxy)
    return ok
end

function CreatorLogs.Emit(event, payload)
    local logs = logger()
    if not logs or type(logs.Emit) ~= 'function' then return false end
    local ok, result = pcall(logs.Emit, event, payload)
    return ok and result or false
end

CreateThread(function()
    local wasReady = false
    while true do
        local isReady = ready()
        if isReady and not wasReady then TriggerEvent('w_creators:server:logsReady') end
        wasReady = isReady
        Wait(1000)
    end
end)
