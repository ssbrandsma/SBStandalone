"""Exercise a supplied stock Jive _audg implementation behind our actual hooks.

Usage: python test/jive-volume-contract.py PATH/TO/jive/audio/Playback.lua
Source is read only; this does not modify or contact a Radio.
"""
from pathlib import Path
import sys
from lupa.lua51 import LuaRuntime

root = Path(__file__).resolve().parents[1]
stock = Path(sys.argv[1]).read_text()
gain = stock[stock.index('function _audg('):stock.index('function translateServerGain(')]
source = (root / 'applet/StandaloneRadio/StreamPlayer.lua').read_text()
hooks = source[source.index('function StreamPlayer:_installHooks('):source.index('function StreamPlayer:_begin(')]
lua = LuaRuntime()
lua.globals().stock_gain = gain
lua.globals().hooks = hooks
lua.execute('''
local output, timers = 0, 0
local decode = {audioGain=function(_,left,right) output=left end}
local Player = {getLocalPlayer=function() return {getDigitalVolumeControl=function() return 1 end} end}
local log = {debug=function() end}
local stock = assert(loadstring('local decode,Player,log=...; '..stock_gain..' return _audg'))(decode,Player,log)
StreamPlayer={}
assert(loadstring(hooks))()
local proto={send=function() return true end}
local playback={slimproto=proto,_streamHttpHeaders=function() end,_streamDisconnect=function() end,
    _audg=stock,translateServerGain=function(_,gain) return gain,50 end,
    isSequenceNumberInSync=function() return true end,
    _stopPauseAndStopTimers=function() timers=timers+1 end}
local player=setmetatable({ownsPlayback=true,log={info=function() end,warn=function() end}}, {__index=StreamPlayer})
player:_installHooks(playback)
playback:_audg({gainL=5,gainR=5})
assert(output==0 and timers==0)
playback:_audg({gainL=42,gainR=42},true)
assert(output==42 and timers==0)
player.ownsPlayback=false
playback:_audg({gainL=99,gainR=99})
assert(output==99 and timers==1)
''')
print('Stock Jive gain contract passed:', sys.argv[1])
