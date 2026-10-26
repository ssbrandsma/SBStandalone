-- Starting physical radio audio must select its actual LocalPlayer for LMS UI.
local file=assert(io.open('applet/StandaloneRadio/StreamPlayer.lua'))
local source=file:read('*a');file:close()
local localPlayback=assert(source:match('(local function localPlayback%b().-)function new'))
local begin=assert(source:match('(function StreamPlayer:_begin%b().-)function StreamPlayer:start'))
local actual={playback={}}
local orphan={id='00:04:20:2a:56:81'}
local current,localPlayer,selections=orphan,actual,0
local Player={getLocalPlayer=function() return localPlayer end,
    getCurrentPlayer=function() return current end,
    setCurrentPlayer=function(_,player) current=player;selections=selections+1 end}
local prototype={}
assert(loadstring('local Player,StreamPlayer=...; '..localPlayback..begin))(Player,prototype)
local instance=setmetatable({generation=0,stationGeneration=0,callbacks={onSelected=function() end},
    log={info=function() end,warn=function() end},
    _cancelReconnect=function() end,_resetWatchdog=function() end,_resetAudioRecovery=function() end,
    _installHooks=function(_,playback) assert(playback==actual.playback) end,
    _notifyState=function() end,_resolveStreamRedirect=function() end}, {__index=prototype})
assert(instance:_begin({id='npo-radio-2'},false))
assert(current==actual and selections==1)
assert(instance:_begin({id='another-station'},false))
assert(current==actual and selections==1,'Do not reselect the same player')
current=orphan
assert(instance:_begin({id='npo-radio-2'},true))
assert(current==orphan and selections==1,'A background recovery is not a player-selection action')
localPlayer=nil
assert(instance:_begin({id='npo-radio-2'},false)==false)
assert(current==orphan and selections==1,'No player selection on unavailable local decoder')
print('Explicit station start selects local player; background recovery preserves selection')
