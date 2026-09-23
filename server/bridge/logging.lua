-- Logging readiness never blocks character selection or spawn.
CreatorLogs = {}
function CreatorLogs.Register(register)
    local ok,ready=pcall(w.logs.IsReady)
    if not ok or not ready then return false end
    local proxy = {}
    for _, name in ipairs({'RegisterScript', 'RegisterLogType'}) do
        proxy[name] = function(data)
            local result = w.logs[name](data)
            if type(result) ~= 'table' or result.ok ~= true then error('log registration unavailable') end
            return result
        end
    end
    return pcall(register, proxy)
end
function CreatorLogs.Emit(event, payload)
    local ok,result=pcall(w.logs.Emit,event,payload)
    return ok and result or false
end
CreateThread(function()
    local wasReady = false
    while true do
        local ok,ready = pcall(w.logs.IsReady)
        ready=ok and ready or false
        if ready and not wasReady then TriggerEvent('w_creators:server:logsReady') end
        wasReady = ready
        Wait(1000)
    end
end)
