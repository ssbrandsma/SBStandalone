if not module then
	function module(name)
		local target = package.loaded[name] or {}
		package.loaded[name] = target
		local info, index = debug.getinfo(2, "f"), 1
		while true do
			local upname = debug.getupvalue(info.func, index)
			if not upname then break end
			if upname == "_ENV" then
				setmetatable(target, { __index = _G })
				debug.setupvalue(info.func, index, target)
				break
			end
			index = index + 1
		end
	end
end

assert(loadfile("./applet/StandaloneRadio/NativeNowPlaying.lua"))(
	"applets.StandaloneRadio.NativeNowPlaying")
local navigation = package.loaded["applets.StandaloneRadio.NativeNowPlaying"]

local generation = 0
local calls, timers = 0, {}
local nativeWindow = {}
local nativeApplet = { window=nativeWindow }
local serviceAvailable, playerAvailable, current = true, true, false
local manager = {}
function manager:hasService(name) return name == "goNowPlaying" and serviceAvailable end
function manager:callService(name)
	if name == "getCurrentPlayer" then return playerAvailable and {} or nil end
	if name == "goNowPlaying" then calls = calls + 1; return nil end
end
function manager:getAppletInstance(name) return name == "NowPlaying" and nativeApplet or nil end
local framework = {}
function framework:isCurrentWindow(window) return current and window == nativeWindow end
local function timerFactory(delay, callback)
	local timer = { delay=delay, callback=callback, stopped=false }
	function timer:start() end
	function timer:stop() self.stopped=true end
	timers[#timers + 1] = timer
	return timer
end
local nav = navigation.new({
	appletManager=manager, framework=framework, timerFactory=timerFactory,
	transition="push-left", getGeneration=function() return generation end,
})

-- Rapid preset input coalesces: even if an obsolete callback runs, generation
-- checks prevent it from navigating.
generation = 1; nav:request(1); local stale = timers[#timers]
generation = 2; nav:request(2); local latest = timers[#timers]
assert(stale.stopped)
stale.callback(); assert(calls == 0)
latest.callback(); assert(calls == 1)

-- The stock window already current is left untouched; elsewhere in the stack
-- the stock service is responsible for moving its single instance to the top.
current = true; generation = 3; nav:request(3); timers[#timers].callback(); assert(calls == 1)
current = false; generation = 4; nav:request(4); timers[#timers].callback(); assert(calls == 2)

-- Missing service/player retries are bounded and become obsolete on a new
-- explicit selection. No playback callback invokes this controller.
serviceAvailable = false; generation = 5; nav:request(5); timers[#timers].callback()
local retry = timers[#timers]; assert(retry.delay == 250)
generation = 6; serviceAvailable = true; playerAvailable = false; nav:request(6)
retry.callback(); assert(calls == 2)
timers[#timers].callback(); local playerRetry = timers[#timers]; assert(playerRetry.delay == 250)
playerAvailable = true; playerRetry.callback(); assert(calls == 3)

generation = 7; nav:request(7); local pending = timers[#timers]
nav:shutdown(); assert(pending.stopped)
pending.callback(); assert(calls == 3)

print("Native Now Playing navigation tests passed")

