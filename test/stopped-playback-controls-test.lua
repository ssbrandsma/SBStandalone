-- Exercise the registered controls with the real stop/pause/play and handoff hooks.
local function read(path)
    local file=assert(io.open(path,"r"));local source=file:read("*a");file:close();return source
end
local appletSource=read("applet/StandaloneRadio/StandaloneRadioApplet.lua")
local source=read("applet/StandaloneRadio/StreamPlayer.lua")
local hooks=assert(source:match("(function StreamPlayer:_installHooks%b().-)function StreamPlayer:_begin"))
local stop=assert(source:match("(function StreamPlayer:stop%b().-)function StreamPlayer:stopConnecting"))
local transport=assert(source:match("(function StreamPlayer:pause%b().-)function StreamPlayer:getCurrentStation"))
StreamPlayer={}
assert(loadstring(hooks..stop..transport))()

EVENT_CONSUME,EVENT_UNUSED,EVENT_IR_PRESS="consume","unused","ir"
local actions,calls={}, {start=0,stop=0,resume=0}
Framework={addActionListener=function(_,name,owner,callback) actions[name]=callback;return name end,
    addListener=function() return "ir" end}
jiveMain={state="on",getSoftPowerState=function(self) return self.state end,
    setSoftPowerState=function(self,state) self.state=state end}
hasServerMigration=true
ServerMigration={LOCAL_UUID="base"}
local base={id="base",getIpPort=function() return "127.0.0.1",9000 end}
local external={id="external",getIpPort=function() return "192.168.1.10",9000 end}
local server=base
local playback={_strm=function() calls.native=(calls.native or 0)+1 end,
    _streamHttpHeaders=function() end,_streamDisconnect=function() end,
    slimproto={send=function() end}}
local localPlayer={playback=playback,isLocal=function() return true end,
    getSlimServer=function() return server end}
local selected=localPlayer
local chooser={_doConnectPlayer=function(_,player,target) server=target end}
Player={getLocalPlayer=function() return localPlayer end}
appletManager={callService=function() return selected end,
    loadApplet=function(_,name) if name=="ChooseMusicSource" then return chooser end end}
decode={pauseAudio=function() calls.pause=(calls.pause or 0)+1 end,
    resumeAudio=function() calls.resume=calls.resume+1 end}
_logInfo=function() end
local station={id="remembered"}
local stream=setmetatable({generation=0,stationGeneration=0,lastStation=station,
    ownsPlayback=false,state="STOPPED",callbacks={},log={info=function() end,warn=function() end},
    _cancelReconnect=function() end,_resetWatchdog=function() end,_resetAudioRecovery=function() end,
    _stopPlayback=function() calls.stop=calls.stop+1 end,
    _notifyState=function(self,_,state) self.state=state end,
    start=function(self,value)
        assert(value==station);calls.start=calls.start+1
        self.ownsPlayback=true;self.resumeAfterStop=false
        self.desiredStation=value;self.playbackActive=true
        return true
    end}, {__index=StreamPlayer})
local applet={streamPlayer=stream,lastStation=station,_ensureComponents=function() return true end,
    _playStation=function(_,value) stream:start(value) end}
local registration=assert(appletSource:find("function enableStandaloneMode(self)",1,true))
assert(loadstring(appletSource:sub(registration)))()
enableStandaloneMode(applet)
stream:_installHooks(playback)

-- A remembered station alone must not steal an awake local Base player's controls.
assert(actions.play()==EVENT_UNUSED and calls.start==0)
assert(actions.stop()==EVENT_UNUSED and not stream.resumeAfterStop)
for _,action in ipairs({"stop","pause"}) do
    stream:start(station)
    assert(actions[action]()==EVENT_CONSUME and not stream.ownsPlayback,
        action.." must stop the live Radio stream")
    local starts=calls.start
    assert(actions.play()==EVENT_CONSUME and calls.start==starts+1 and stream.ownsPlayback,
        "Awake "..action.." -> Play must restart the remembered live station")
end

-- Podcast Pause remains an in-place decoder resume, never a restart from zero.
station.episode=true;stream.paused=false
local starts=calls.start
assert(actions.pause()==EVENT_CONSUME and stream.ownsPlayback and stream.paused)
assert(actions.play()==EVENT_CONSUME and calls.resume==1 and calls.start==starts and not stream.paused)
station.episode=nil

-- Every selected-player and server guard still applies after a Radio stop.
actions.stop()
for _,other in ipairs({{isLocal=function() return false end},
    {isLocal=function() return true end,getSlimServer=function() return external end},
    {isLocal=function() return true end,getSlimServer=function() return nil end}}) do
    selected=other
    assert(actions.play()==EVENT_UNUSED and calls.start==starts)
end
selected=nil
assert(actions.play()==EVENT_UNUSED)
selected=localPlayer;hasServerMigration=false
assert(actions.play()==EVENT_UNUSED)
hasServerMigration=true

-- An explicit handoff after Stop revokes resume, even though Radio is no longer owner.
chooser:_doConnectPlayer(localPlayer,external)
assert(not stream.resumeAfterStop and actions.play()==EVENT_UNUSED)
chooser:_doConnectPlayer(localPlayer,base)
assert(actions.play()==EVENT_UNUSED,"Returning to Base must not revive a stale stopped-owner permission")

-- Another native stream can start on the same Base; its Play must pass through.
stream:start(station);actions.stop()
playback:_strm({command="t"})
assert(stream.resumeAfterStop,"Keepalive traffic is not a new playback owner")
playback:_strm({command="s"})
assert(not stream.resumeAfterStop and actions.play()==EVENT_UNUSED and calls.native==2)

-- A terminal error is distinct from an explicit Stop.
stream:start(station);stream:stop("FAILED")
assert(not stream.resumeAfterStop and actions.play()==EVENT_UNUSED)

-- Waking the clock first still allows Play after a Radio-owned power-off stop.
stream:start(station);actions.stop();jiveMain.state="on"
starts=calls.start
assert(actions.play()==EVENT_CONSUME and calls.start==starts+1)
print("Awake Stop/Pause -> Play, podcast resume, source handoff and native-owner guards passed")
