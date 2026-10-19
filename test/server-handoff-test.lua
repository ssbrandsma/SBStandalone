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
assert(proto:send({opcode="HELO"}, true)=="sent")
assert(player.ownsPlayback and stops==0 and handed==0)
assert(proto:send({opcode="STAT"})=="sent")
proto:send({opcode="RESP"})
assert(#sent==2, "Standalone stream packets remain suppressed")
proto.serverip="192.168.1.10"
local helo = {opcode="HELO"}
assert(proto:send(helo, true)=="sent")
assert(sent[3].packet==helo and sent[3].force==true)
assert(not player.ownsPlayback and not player.playbackActive)
assert(player.desiredStation==nil and player.pendingStation==nil)
assert(player.lastStation==station and player.generation==2)
assert(stops==1 and handed==1 and metadataStops==1 and cancel==1)
assert(proto:send({opcode="RESP"})=="sent", "External LMS packets must resume")
proto:send({opcode="HELO"}, true)
assert(stops==1 and handed==1, "Reconnect must not repeat the handoff")
print("server-handoff-tests-ok")
