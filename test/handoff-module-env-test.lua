-- Exercise actual imports and hooks in Jive's isolated Lua 5.1 module environment.
local file=assert(io.open('applet/StandaloneRadio/StreamPlayer.lua'))
local source=file:read('*a');file:close()
local prefix=assert(source:match('^(.-)module%(%...%)'))
local hooks=assert(source:match('(function StreamPlayer:_installHooks%b().-)function StreamPlayer:_begin'))
local stopped,handed=0,0
local playback={slimproto={send=function() return true end},_streamHttpHeaders=function() end,_streamDisconnect=function() end}
local selected={playback=playback}
local chooser={_doConnectPlayer=function() end}
local manager={loadApplet=function() return chooser end}
local dependencies={['jive.slim.Player']={getLocalPlayer=function() return selected end},
    string=string,math=math}
local environment={pairs=pairs,pcall=pcall,setmetatable=setmetatable,tonumber=tonumber,tostring=tostring,type=type,
    appletManager=manager,require=function(name) return dependencies[name] or {} end,
    module=function() setfenv(2,{}) end}
local chunk=assert(loadstring(prefix..'module(...)\nlocal StreamPlayer={}\n'..hooks..'\nreturn StreamPlayer'))
setfenv(chunk,environment)
local prototype=chunk('isolated.handoff.fixture')
local player=setmetatable({ownsPlayback=true,log={info=function() end,warn=function() error('Chooser hook unavailable in isolated module') end},
    stop=function(self) stopped=stopped+1;self.ownsPlayback=false end,
    callbacks={onHandoff=function() handed=handed+1 end}}, {__index=prototype})
player:_installHooks(playback)
playback.slimproto:send({opcode='HELO'})
assert(player.ownsPlayback and stopped==0)
chooser:_doConnectPlayer(selected,{getIpPort=function() return '192.168.1.100',9000 end})
assert(not player.ownsPlayback and stopped==1 and handed==1)
print('Isolated Lua 5.1 imports and managed chooser handoff passed')
