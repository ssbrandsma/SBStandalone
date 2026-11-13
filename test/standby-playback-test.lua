-- Exercise native LocalPlayer power-off and the real recovery callbacks.
local file=assert(io.open("applet/StandaloneRadio/StreamPlayer.lua"))
local source=file:read("*a");file:close()
local function method(name,nextName)
    local first=assert(source:find("function StreamPlayer:"..name.."(",1,true))
    local last=assert(source:find("function StreamPlayer:"..nextName.."(",first+1,true))
    return source:sub(first,last-1)
end
local calls={resume=0,stop=0,power=0,begin=0,wake=0}
local timers={}
local Timer=function(_,callback)
    local timer={callback=callback,start=function() end,stop=function(self) self.stopped=true end}
    timers[#timers+1]=timer;return timer
end
local playback={stream={},_streamHttpHeaders=function() end,_streamDisconnect=function() end,
    slimproto={send=function() end},sentOutputUnderrunEvent=true,decodeThreshold=2048}
local localPlayer={playback=playback,setPower=function(_,on,sequence,serverRequest)
    calls.power=calls.power+1;calls.on=on;calls.sequence=sequence;calls.serverRequest=serverRequest
end}
local Player={getLocalPlayer=function() return localPlayer end}
local decode={status=function() return {audioState=2,decodeFull=10000,bytesReceived=100} end,
    resumeAudio=function() calls.resume=calls.resume+1 end}
local Framework={wakeup=function() calls.wake=calls.wake+1 end}
local prototype={}
local code=method('_isStandby','_notifyState')..method('_powerKeepaliveTick','_startWatchdog')
    ..method('_audioRecoveryTick','_watchdogTick')..method('_watchdogTick','_cancelReconnect')
    ..method('_cancelReconnect','_stopPlayback')..method('_scheduleReconnect','_handleDisconnect')
    ..method('_handleDisconnect','_finishRedirectProbe')..method('_installHooks','_begin')
    ..method('stop','stopConnecting')..method('play','getCurrentStation')
    ..method('ownershipReleaseHooks','ownershipGranted')
assert((loadstring or load)('local StreamPlayer,Player,decode,Framework,Timer,localPlayback=...;'
    ..'local DECODE_UNDERRUN=2;local WATCHDOG_STALL_POLLS=2;local reconnectDelays={2000};'
    ..'local UrlTransport={isHttps=function() return false end};'..code))(
        prototype,Player,decode,Framework,Timer,function() return playback end)
local station={id="last-radio",url="http://example.org/live"}
local player=setmetatable({generation=1,stationGeneration=1,retryIndex=1,
    ownsPlayback=true,playbackActive=true,desiredStation=station,lastStation=station,
    log={info=function() end,warn=function() end},
    _resetWatchdog=function() end,_resetAudioRecovery=function(self) self.audioUnderrunRecovered=false end,
    _stopPlayback=function() calls.stop=calls.stop+1;playback.stream=nil end,
    _notifyState=function(self,_,state) self.state=state end,
    _begin=function() calls.begin=calls.begin+1 end,
    start=function(_,value) assert(value==station);calls.begin=calls.begin+1;return true end,
}, {__index=prototype})
player:_installHooks(playback)
local wrappedPower=localPlayer.setPower
player:_installHooks(playback)
assert(localPlayer.setPower==wrappedPower,"Power hooks must not stack")
player:_scheduleReconnect(station,player.generation)
local retry=assert(player.reconnectTimer)
local generation=player.generation
player.pendingStation=station
player.playlistResolver={cancelPlaylist=function()
    assert(not player:_isCurrent(generation,station),
        "Cancellation callbacks must already belong to an invalidated generation")
end}
localPlayer:setPower(false,7,true)
assert(not player.ownsPlayback and not player.playbackActive and player.desiredStation==nil,
    "Power-off must stop radio intent, not merely pause the native decoder")
assert(player.lastStation==station and player.state=="STOPPED" and calls.stop==1)
assert(retry.stopped and not player.reconnectTimer and not player.pendingStation)
assert(calls.power==1 and calls.on==false and calls.sequence==7 and calls.serverRequest==true,
    "Preserve native power arguments and server-request semantics")
-- Simulate many minutes of standby and callbacks already queued at power-off.
for tick=1,600 do
    player:_audioRecoveryTick();player:_watchdogTick();player:_powerKeepaliveTick()
end
retry.callback()
player:_handleDisconnect(2,false)
playback:_streamHttpHeaders("HTTP/1.1 200 OK\r\nContent-Type: audio/mpeg\r\n\r\n")
assert(calls.resume==0 and calls.begin==0 and calls.wake==0 and #timers==1,
    "Standby recovery, stale retry/disconnect/headers must never restart audio")
localPlayer:setPower(true)
assert(calls.begin==0,"Power on alone must not restart radio")
assert(player:play() and calls.begin==1,"Explicit Play must still resume the last station")
localPlayer:setPower(false)
assert(calls.stop==1,"Non-owner power changes must retain stock behavior")
print("Standby power-off cancels radio recovery and stale callbacks; explicit Play resumes saved station")

-- Opt-in ownership must release the power hook together with decoder hooks.
-- A queued retired wrapper may still forward native power, but cannot stop Radio.
local function registry()
    local r={records={}}
    function r:record(target,key,original)
        self.records[#self.records+1]={target=target,key=key,original=original,wrapper=target[key]}
        return true
    end
    function r:restore()
        for _,v in ipairs(self.records) do assert(v.target[v.key]==v.wrapper) end
        for _,v in ipairs(self.records) do v.target[v.key]=v.original end
        return true
    end
    return r
end
package.preload['applets.StandaloneBase.OwnershipHooks']=function() return {new=registry} end
playback={_streamHttpHeaders=function() end,_streamDisconnect=function() end,
    slimproto={send=function() end}}
local nativePower=function(_,on,sequence,serverRequest)
    calls.power=calls.power+1;calls.on=on;calls.sequence=sequence;calls.serverRequest=serverRequest
end
localPlayer={playback=playback,setPower=nativePower}
local gate={epoch=1,allowed=true,canStart=function(self) return self.allowed end}
player.ownership=gate;player.ownershipHooks=registry();player.hookedPlayback=nil
player.ownsPlayback=true;player.desiredStation=station
player:_installHooks(playback)
local ownedPower=localPlayer.setPower
player:_installHooks(playback)
assert(localPlayer.setPower==ownedPower,'Owned power hook must not stack')
local stopped=calls.stop
localPlayer:setPower(false,9,true)
assert(calls.stop==stopped+1 and calls.sequence==9 and calls.serverRequest==true)
assert(player:ownershipReleaseHooks())
assert(localPlayer.setPower==nativePower and player.hookedPlayback==nil,
    'Ownership release must restore the original local-player power method')
player.ownsPlayback=true;gate.epoch=2
stopped=calls.stop
ownedPower(localPlayer,false,10,true)
assert(calls.stop==stopped and calls.sequence==10,'Retired power hook may only forward native behavior')
player:_installHooks(playback)
assert(localPlayer.setPower~=nativePower,'New ownership may reinstall the released power hook')
gate.allowed=false
stopped=calls.stop
localPlayer:setPower(false,11,true)
assert(calls.stop==stopped and calls.sequence==11,'Revoked power hook must leave playback alone')
assert(player:ownershipReleaseHooks() and localPlayer.setPower==nativePower)
print('Ownership power hook restoration, reinstallation and retired callback isolation passed')
