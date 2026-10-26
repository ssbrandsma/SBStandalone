-- Exercise the actual playback hooks with a minimal Jive/decoder fixture.
local f = assert(io.open("applet/StandaloneRadio/StreamPlayer.lua"))
local source = f:read("*a"); f:close()
local hooks = assert(source:match("(function StreamPlayer:_installHooks%b().-)function StreamPlayer:_begin"))
local stop = assert(source:match("(function StreamPlayer:stop%b().-)function StreamPlayer:stopConnecting"))
StreamPlayer = {}
Stream = {icyMetaInterval=function() end}
UrlTransport = {}
assert((loadstring or load)(hooks .. stop))()
local sent, stops, handed, metadataStops, cancel = {}, 0, 0, 0, 0
local proto = {serverip="127.0.0.1", send=function(_, packet, force)
    sent[#sent+1] = {packet=packet, force=force}; return "sent"
end}
local playback = {slimproto=proto, _streamHttpHeaders=function() end,
    _streamDisconnect=function() end}
local gain, commands = 0, 0
playback._audg = function(_, data) gain=data.gainL end
for _, name in ipairs({'_strm','_cont','_aude'}) do
    playback[name]=function() commands=commands+1 end
end
local selected = {playback=playback, isConnected=function() return true end}
local external = {getIpPort=function() return '192.168.1.10',9000 end,
    isPasswordProtected=function() return false end, getVersion=function() return '7.9' end,
    isCompatible=function() return true end}
local loopback = {getIpPort=function() return '127.0.0.1',9000 end}
selected.getSlimServer=function() return external end
Player={getLocalPlayer=function() return selected end}
local connections=0
local chooser={_doConnectPlayer=function() connections=connections+1 end,
    selectServer=function() end}
local originalConnect, originalSelect = chooser._doConnectPlayer, chooser.selectServer
-- require and the managed applet can be different objects. Jive loadfile also
-- replaces methods when a freed applet is reopened, even with a surviving module.
local decoy={_doConnectPlayer=originalConnect, selectServer=originalSelect}
package.preload['applets.ChooseMusicSource.ChooseMusicSourceApplet']=function() return decoy end
appletManager={loadApplet=function(_,name)
    if name=='ChooseMusicSource' then return chooser end
    return 'another-applet'
end}
local station = {id="station"}
local player = setmetatable({ownsPlayback=true, generation=1,
    desiredStation=station, lastStation=station, playbackActive=true,
    pendingStation=station, currentMetadata="track",
    hlsMetadata={stop=function() metadataStops=metadataStops+1 end},
    playlistResolver={cancelPlaylist=function() cancel=cancel+1 end},
    callbacks={onHandoff=function() handed=handed+1 end},
    log={info=function() end},
    _cancelReconnect=function(self) self.reconnectTimer=nil end,
    _resetWatchdog=function() end, _resetAudioRecovery=function() end,
    _stopPlayback=function() stops=stops+1 end,
    _notifyState=function(_, _, state) assert(state=="STOPPED") end,
}, {__index=StreamPlayer})
player:_installHooks(playback)
player:_installHooks(playback) -- Hook installation must be idempotent.
assert(decoy._doConnectPlayer==originalConnect, 'Only the managed chooser must be patched')
for reopen=1,3 do
    chooser._doConnectPlayer=originalConnect
    chooser.selectServer=originalSelect
    assert(appletManager:loadApplet('ChooseMusicSource')==chooser)
    local wrapped=chooser._doConnectPlayer
    appletManager:loadApplet('ChooseMusicSource')
    assert(chooser._doConnectPlayer==wrapped, 'Cached loads must not stack hooks')
    assert(appletManager:loadApplet('Unrelated')=='another-applet')
    assert(player.ownsPlayback and stops==0, 'Opening a chooser is not a switch')
end
local tracedHeaders, tracedClose
player.streamTrace={headers=function(_,status,headers) tracedHeaders={status,headers} end,
    finish=function(_,reason,bytes) tracedClose={reason,bytes} end}
player._handleDisconnect=function() end
-- Keep the playback-state callbacks out of this header-only trace check.
player.intentionalStop=true
playback:_streamHttpHeaders("HTTP/1.1 200 OK\r\nContent-Type: audio/mpeg\r\n\r\n")
assert(tracedHeaders[1]==200 and tracedHeaders[2]["Content-Type"]=="audio/mpeg")
playback:_streamDisconnect("timeout",false)
assert(tracedClose[1]=="timeout" and tracedClose[2]=="unknown")
player.intentionalStop=false
assert(proto:send({opcode="HELO"}, true)=="sent")
assert(player.ownsPlayback and stops==0 and handed==0)
assert(proto:send({opcode="STAT"})=="sent")
proto:send({opcode="RESP"})
assert(#sent==2, "Standalone stream packets remain suppressed")
proto.serverip="192.168.1.10"
local helo = {opcode="HELO"}
assert(proto:send(helo, true)=="sent")
assert(sent[3].packet==helo and sent[3].force==true)
-- Failed reconnects and successful reconnects have identical ownership rules.
for elapsed=13,13*38,13 do
    proto:send({opcode='HELO',reconnect=true},true)
    proto:send({opcode='STAT'})
    playback:_audg({gainL=10})
    playback:_strm({command='s'})
    playback:_strm({command='q'})
    playback:_cont({})
    playback:_aude({})
    assert(player.ownsPlayback and player.playbackActive and stops==0 and handed==0)
    assert(player.generation==1 and player.desiredStation==station and commands==0 and gain==0)
end
playback:_audg({gainL=42},true) -- stock physical/controller setVolume path
assert(gain==42)
chooser:_doConnectPlayer(selected,loopback)
assert(player.ownsPlayback and stops==0)
chooser:_doConnectPlayer({playback={}},external) -- unrelated player
assert(player.ownsPlayback and stops==0)
chooser:_doConnectPlayer(selected,external)
assert(not player.ownsPlayback and not player.playbackActive)
assert(player.desiredStation==nil and player.pendingStation==nil)
assert(player.lastStation==station and player.generation==2)
assert(stops==1 and handed==1 and metadataStops==1 and cancel==1)
assert(proto:send({opcode="RESP"})=="sent", "External LMS packets must resume")
proto:send({opcode="HELO"}, true)
assert(stops==1 and handed==1, "Reconnect must not repeat the handoff")
playback:_audg({gainL=99})
playback:_strm({command='s'})
assert(gain==99 and commands==1, 'Normal LMS gain and playback resume after handoff')
-- Starting Standalone again reinstates isolation without stacking handlers.
player.ownsPlayback=true; player.playbackActive=true
playback:_audg({gainL=5})
assert(gain==99)
chooser:selectServer(external) -- already connected early-return path
assert(stops==2 and handed==2)
chooser:_doConnectPlayer(selected,external)
assert(stops==2 and handed==2)
-- Fully freed/recreated instance, not just overwritten class methods.
chooser={_doConnectPlayer=originalConnect,selectServer=originalSelect}
appletManager:loadApplet('ChooseMusicSource')
player.ownsPlayback=true;player.playbackActive=true
proto:send({opcode='HELO'},true)
assert(player.ownsPlayback and stops==2)
chooser:_doConnectPlayer(selected,external)
assert(stops==3 and handed==3 and not player.ownsPlayback)
print("server-handoff-tests-ok")
