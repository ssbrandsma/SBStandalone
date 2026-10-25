"""Prove the reconnect regression fails on 0.9.14 and passes in the worktree."""
from pathlib import Path
import os
import subprocess
from lupa.lua51 import LuaRuntime, LuaError

root = Path(__file__).resolve().parents[1]
os.chdir(root)
fixture = (root / 'test/server-handoff-test.lua').read_text()
baseline = subprocess.check_output(['git', 'show', '22c2dbcfdb514ca5a6a6dc75ec7b767d3a4d4c3a:applet/StandaloneRadio/StreamPlayer.lua']).decode()
lua = LuaRuntime()
lua.globals().baseline = baseline
lua.execute('''
local original = io.open
io.open = function(path, ...)
    if path == 'applet/StandaloneRadio/StreamPlayer.lua' then
        return {read=function() return baseline end, close=function() end}
    end
    return original(path, ...)
end
''')
try:
    lua.execute(fixture)
except LuaError as error:
    assert 'assertion failed' in str(error), error
    print('Confirmed: pre-fix HELO handoff fails the reconnect regression')
else:
    raise AssertionError('Expected the pre-fix HELO implementation to fail')
LuaRuntime().execute(fixture)
print('Fixed worktree passes the same reconnect and volume fixture')
