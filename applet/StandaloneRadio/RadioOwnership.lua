local Binding=require("applets.StandaloneBase.OwnershipBinding")
local M={}
function M.new(o)
    if not o or not o.player then return nil end
    local radio=o.player
    return Binding.new(o,{owner="radio",
        attach=function(gate) return radio:configureOwnership(gate) end,
        fence=function() return radio:ownershipFence() end,
        stopProducer=function(done)
            -- Direct stream producer is the closed Playback stream. HLS proxy
            -- sessions need an explicit qualified asynchronous shutdown driver.
            if radio.ownershipStation and radio.ownershipStation.hls then
                if not o.hlsStop then done(false);return end
                o.hlsStop(radio.generation,done)
            else
                local playback=o.getPlayback()
                done(playback~=nil and playback.stream==nil and radio.pendingStation==nil and not radio.reconnectTimer)
            end
        end,
        releaseHooks=function(done) done(radio:ownershipReleaseHooks()) end,
        grant=function() radio:ownershipGranted() end})
end
return M
