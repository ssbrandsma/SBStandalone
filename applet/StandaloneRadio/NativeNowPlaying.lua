local pcall, setmetatable, tostring = pcall, setmetatable, tostring

module(...)

local Navigation = {}
Navigation.__index = Navigation
local RETRY_DELAYS = { 50, 250, 500 }

function new(options)
	return setmetatable({
		appletManager = options.appletManager,
		framework = options.framework,
		timerFactory = options.timerFactory,
		transition = options.transition,
		log = options.log,
		getGeneration = options.getGeneration,
	}, Navigation)
end

function Navigation:_cancelTimer()
	local timer = self.timer
	self.timer = nil
	if timer and timer.stop then timer:stop() end
end

function Navigation:_current(generation)
	return self.generation == generation
		and (not self.getGeneration or self.getGeneration() == generation)
end

function Navigation:_schedule(generation, attempt)
	if not self:_current(generation) then return end
	local delay = RETRY_DELAYS[attempt]
	if not delay then
		if self.log then self.log:warn("StandaloneRadio: native Now Playing unavailable") end
		return
	end
	self:_cancelTimer()
	self.timer = self.timerFactory(delay, function()
		self.timer = nil
		self:_open(generation, attempt)
	end, true)
	self.timer:start()
end

function Navigation:_open(generation, attempt)
	if not self:_current(generation) then return end
	local manager = self.appletManager
	if not manager or not manager:hasService("goNowPlaying") then
		self:_schedule(generation, attempt + 1)
		return
	end

	local player = manager:callService("getCurrentPlayer")
	if not player then
		self:_schedule(generation, attempt + 1)
		return
	end

	-- Avoid even a moveToTop call when the stock window is already current.
	-- If it is elsewhere in the stack, the stock service safely reuses it.
	local okApplet, nativeApplet = pcall(function()
		return manager:getAppletInstance("NowPlaying")
	end)
	if okApplet and nativeApplet and nativeApplet.window
		and self.framework:isCurrentWindow(nativeApplet.window) then
		return
	end

	local ok, result = pcall(function()
		return manager:callService("goNowPlaying", self.transition)
	end)
	if not ok or result == false then
		if self.log then
			self.log:warn("StandaloneRadio: native Now Playing navigation failed: ",
				tostring(ok and "no current player" or result))
		end
		self:_schedule(generation, attempt + 1)
	end
end

function Navigation:request(generation)
	if not generation then return false end
	self.generation = generation
	self:_schedule(generation, 1)
	return true
end

function Navigation:shutdown()
	self.generation = nil
	self:_cancelTimer()
end

