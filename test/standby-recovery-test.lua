-- Real StreamPlayer recovery methods, controlled firmware/timer boundaries.
local path=standby_source_path or "applet/StandaloneRadio/StreamPlayer.lua"
local f=assert(io.open(path));local source=f:read("*a");f:close()
local function method(name)
 local first=assert(source:find("function StreamPlayer:"..name.."(",1,true),name)
 local last=source:find("\nfunction StreamPlayer:",first+1,true)
 return source:sub(first,last and last-1 or #source)
end
local power="on";local wake,resume,stops,begins=0,0,0,0;local timers={}
jiveMain={getSoftPowerState=function() if power=="error" then error("power unavailable") end;return power end}
Framework={wakeup=function() wake=wake+1 end}
decode={status=function() return {audioState=2,decodeFull=4096,bytesReceivedL=200} end,resumeAudio=function() resume=resume+1 end}
Timer=function(delay,callback,once)
 local t={callback=callback,stopped=false,start=function() end,stop=function(self) self.stopped=true end}
 timers[#timers+1]=t;return t
end
StreamPlayer={}
local code='local StreamPlayer=StreamPlayer;local jiveMain=jiveMain;local Framework=Framework;local decode=decode;local Timer=Timer;local DECODE_UNDERRUN=2;local WATCHDOG_STALL_POLLS=2;local reconnectDelays={2000};local localPlayback=function() return {stream=true} end;'
for _,name in ipairs({'_isStandby','_standbyFence','_isCurrent','_powerKeepaliveTick','_audioRecoveryTick','_watchdogTick','_cancelReconnect','_scheduleReconnect','stop'}) do code=code..method(name).."\n" end
assert(load(code))()
local station={id="valid-station"}
local function player()
 return setmetatable({generation=1,stationGeneration=1,retryIndex=1,desiredStation=station,lastStation=station,
 ownsPlayback=true,playbackActive=true,watchdogBytes=200,watchdogStalls=1,
 log={info=function() end,warn=function() end},callbacks={},
 _resetWatchdog=function(self) self.watchdogStalls=0 end,_resetAudioRecovery=function() end,
 _notifyState=function() end,_stopPlayback=function() stops=stops+1 end,
 _begin=function() begins=begins+1 end}, {__index=StreamPlayer})
end

-- Normal playback still maintains power and can recover a real network stall.
local p=player();p:_powerKeepaliveTick();assert(wake==1)
p:_watchdogTick();assert(p.reconnectTimer and #timers==1)
local pending=p.reconnectTimer;power="off";pending.callback();assert(begins==0)
-- Sleep cancels all old intent; repeated clocks/timers cannot emit sound.
local before=p.generation
for _=1,20 do p:_audioRecoveryTick();p:_watchdogTick();p:_powerKeepaliveTick() end
assert(stops==1 and resume==0 and wake==1 and begins==0)
assert(not p.desiredStation and not p.pendingStation and not p.playbackActive and not p.reconnectTimer)
assert(p.generation>before and p.lastStation==station)
-- Late DNS/probe completion must fail its generation/power predicate.
assert(not p:_isCurrent(before,station))
local generation=p.generation;p:_audioRecoveryTick();assert(p.generation==generation)
-- Waking the screen is not an implicit Play.
power="on";p:_watchdogTick();p:_powerKeepaliveTick();assert(begins==0 and wake==1)
-- Standby must not stop another app's decoder after Radio handed it off.
power="off";local foreign=player();foreign.ownsPlayback=false;foreign:_watchdogTick();assert(stops==1)
-- A failed firmware power-state read is conservative.
power="error";local broken=player();broken:_audioRecoveryTick();assert(stops==2 and resume==0)
print("Standby cancels recovery/queued reconnects, rejects late callbacks and never wakes audio")
