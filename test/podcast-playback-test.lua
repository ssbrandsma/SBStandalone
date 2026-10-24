-- Native syntax requires Jive's bitwise operators; this suite uses Lua 5.4.
local f=assert(io.open("applet/StandaloneRadio/StreamPlayer.lua"));local source=f:read("*a");f:close()
StreamPlayer={}
local function method(name,nextName)
 local begin=assert(source:find("function StreamPlayer:"..name.."(",1,true))
 local finish=assert(source:find("function StreamPlayer:"..nextName.."(",begin+1,true))
 return source:sub(begin,finish-1)
end
local calls={};local states={};local decoderStatus={audioState=0,decodeState=0,decodeFull=100,elapsed=4000}
decode={status=function() return decoderStatus end,pauseAudio=function() calls.pause=(calls.pause or 0)+1 end,
 resumeAudio=function() calls.resume=(calls.resume or 0)+1 end}
local function timer() return {start=function() end,stop=function() end} end
assert(load('local DECODE_UNDERRUN=2;local WATCHDOG_STALL_POLLS=2;local reconnectDelays={2000};local Timer=...;local UrlTransport={isHttps=function() return false end};local localPlayback=function() return {stream=true} end;local decode=decode;local StreamPlayer=StreamPlayer;'
 ..method('_audioRecoveryTick','_watchdogTick')..method('_watchdogTick','_cancelReconnect')
 ..method('_installHooks','_begin')..method('_scheduleReconnect','_handleDisconnect')..method('_handleDisconnect','_finishRedirectProbe')
 ..method('stop','stopConnecting')..method('pause','play')..method('play','getCurrentStation'))) (timer)
local player=setmetatable({generation=1,stationGeneration=1,retryIndex=1,_isCurrent=function() return true end,ownsPlayback=true,playbackActive=true,
 log={info=function() end,warn=function() end},callbacks={onPosition=function(value) calls.position=value end},
 _resetWatchdog=function() end,_resetAudioRecovery=function() end,_cancelReconnect=function(self) self.reconnectTimer=nil end,
 _stopPlayback=function() calls.stop=(calls.stop or 0)+1 end,_notifyState=function(self,station,state) states[#states+1]=state end}, {__index=StreamPlayer})
local ep={id="episode",episode=true,url="https://example.org/a.mp3"}
player.desiredStation=ep;player.lastStation=ep
player:pause();assert(player.paused and calls.pause==1 and states[#states]=="PAUSED")
player:_audioRecoveryTick();assert(not calls.position)
player:play();assert(not player.paused and calls.resume==1 and states[#states]=="PLAYING")
player:_audioRecoveryTick();assert(calls.position==4000 and ep.position_ms==4000)
player:_handleDisconnect(0,false);assert(player.episodeEOF and player.playbackActive and not calls.stop)
player:_watchdogTick();assert(not player.reconnectTimer,"network EOF must not restart finite audio")
player:_handleDisconnect(2,false);assert(not player.playbackActive and states[#states]=="FAILED" and not player.ownsPlayback)
player.playbackActive=true;player.ownsPlayback=true;player:_scheduleReconnect(ep,player.generation)
assert(not player.reconnectTimer and states[#states]=="FAILED")
player.playbackActive=true;player.ownsPlayback=true;decoderStatus.decodeState=4
player:_audioRecoveryTick();assert(states[#states]=="FAILED")
-- Run the real native callback adapter: network FIN and decoder completion
-- must not discard buffered audio; only output completion stops the episode.
local playback={_streamHttpHeaders=function() end,_streamDisconnect=function() end,slimproto={send=function() return true end}}
player.desiredStation=ep;player.lastStation=ep;player.playbackActive=true;player.ownsPlayback=true
player:_installHooks(playback)
local stops=calls.stop
playback:_streamDisconnect(0,false);assert(calls.stop==stops and player.episodeEOF)
playback.slimproto:send({opcode="STAT",event="STMd"});assert(calls.stop==stops)
playback.slimproto:send({opcode="STAT",event="STMu"});assert(calls.stop==stops+1 and states[#states]=="STOPPED")
playback.slimproto:send({opcode="STAT",event="STMu"});assert(calls.stop==stops+1)
-- Live-radio disconnections retain their existing reconnect policy.
player.desiredStation={id="live",url="http://example.org/live"};player.lastStation=player.desiredStation
player:_handleDisconnect(2,false);assert(player.reconnectTimer and states[#states]=="RECONNECTING")
print("Finite episode pause/resume, decoder position, FIN/draining, terminal errors, no restart loop and live-radio reconnect regression passed")
