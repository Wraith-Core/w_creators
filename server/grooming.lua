-- Count only time observed online in the main world. Offline time never advances growth.
local ticks={}
CreateThread(function()
    while true do
        Wait(30000)
        local now=GetGameTimer()
        for _,id in ipairs(GetPlayers()) do
            local src=tonumber(id)
            local charid=Bridge.GetCharId(src)
            local session=CreatorShopSessions[src]
            if session and session.expires<os.time() and not session.busy then CreatorShopSessions[src]=nil;session=nil end
            local active=GroomingConfig.enabled and charid and GetPlayerRoutingBucket(src)==0 and not session and not SpawnPending[src]
            local old=ticks[src]
            ticks[src]=active and {charid=tostring(charid),time=now} or nil
            if active and old and old.charid==tostring(charid) and not CreatorAppearanceLocks[tostring(charid)] then
                local elapsed=math.max(0,math.min(60,(now-old.time)/1000))
                local key=tostring(charid);CreatorAppearanceLocks[key]=true
                local ok,err=pcall(function()
                    local app,row=ReadCreatorAppearance(charid)
                    if not app then return end
                    local changed=CreatorGrooming.advance(app,elapsed)
                    SaveCreatorAppearance(charid,app,row)
                    if changed then
                        BroadcastAppearance(src,app)
                        TriggerClientEvent('w_creators:client:grooming',src,app)
                    end
                end)
                CreatorAppearanceLocks[key]=nil
                if not ok then w.print.error('grooming save failed: %s',err) end
            end
        end
    end
end)
AddEventHandler('playerDropped',function() ticks[source]=nil end)
