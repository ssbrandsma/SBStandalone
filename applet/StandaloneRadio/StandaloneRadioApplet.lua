local ipairs, os, tostring = ipairs, os, tostring

local oo = require("loop.simple")
local table = require("table")

local Applet = require("jive.Applet")
local Framework = require("jive.ui.Framework")
local SimpleMenu = require("jive.ui.SimpleMenu")
local Timer = require("jive.ui.Timer")
local Window = require("jive.ui.Window")

local NowPlaying = require("applets.StandaloneRadio.NowPlaying")
local Stations = require("applets.StandaloneRadio.Stations")
local StreamPlayer = require("applets.StandaloneRadio.StreamPlayer")

local log = require("jive.utils.log").logger("StandaloneRadio")

local AUTOTEST_MARKER = "/tmp/standalone-radio-autotest"

module(..., Framework.constants)
oo.class(_M, Applet)


local function _logInfo(...)
	log:info("StandaloneRadio: ", ...)
end


function _ensureComponents(self)
	if self.streamPlayer then
		return true
	end

	if not Stations.validate(log) then
		log:error("StandaloneRadio: station configuration disabled")
		return false
	end

	local settings = self:getSettings() or {}
	self:setSettings(settings)
	self.lastStation = Stations.getById(settings.lastStationId)
	self.nowPlaying = NowPlaying.new(self, log)
	self.streamPlayer = StreamPlayer.new({
		log = log,
		lastStation = self.lastStation,
		callbacks = {
			onState = function(station, state, show)
				self.nowPlaying:update(station, state, show)
				self:_refreshMenu()
			end,
			onMetadata = function(title)
				self.nowPlaying:setMetadata(title)
			end,
			onSelected = function(station)
				self.lastStation = station
				settings.lastStationId = station.id
				self:storeSettings()
				self:_refreshMenu()
			end,
			onConnected = function(station)
				self.lastStation = station
				self:_refreshMenu()
			end,
		},
	})
	return true
end


function init(self)
	self:_ensureComponents()
end


-- The applet is deliberately retained so its global hardware listeners stay
-- active from boot until SqueezePlay exits.
function free(self)
	return false
end


function _statusText(self)
	if not self.lastStation then
		return self:string("STANDALONE_RADIO_STATUS_IDLE")
	end

	local prefix = self.streamPlayer and self.streamPlayer:isPlaying()
		and self:string("STANDALONE_RADIO_STATUS_PLAYING")
		or self:string("STANDALONE_RADIO_STATUS_STOPPED")
	return tostring(prefix):gsub("%%s", tostring(self:string(self.lastStation.nameToken)))
end


function _refreshMenu(self)
	if not self.menuWidget then
		return
	end

	local items = {
		{ text = self:_statusText(), style = "item", weight = 0 },
	}

	for _, station in ipairs(Stations.all()) do
		items[#items + 1] = {
			text = tostring(station.preset) .. ". " .. tostring(self:string(station.nameToken)),
			sound = "SELECT",
			weight = station.preset,
			callback = function()
				self.streamPlayer:start(station)
			end,
		}
	end

	items[#items + 1] = {
		text = self:string("STANDALONE_RADIO_STOP"),
		sound = "WINDOWHIDE",
		weight = 100,
		callback = function()
			self.streamPlayer:stop()
		end,
	}

	self.menuWidget:setItems(items)
	self.menuWidget:reLayout()
end


function menu(self)
	if not self:_ensureComponents() then
		return
	end

	local window = Window("text_list", self:string("STANDALONE_RADIO"))
	local menu = SimpleMenu("menu")
	menu:setComparator(SimpleMenu.itemComparatorWeightAlpha)
	window:addWidget(menu)

	self.menuWidget = menu
	self:enableStandaloneMode()
	self:_refreshMenu()
	window:addListener(EVENT_WINDOW_POP, function()
		self.menuWidget = nil
	end)
	self:tieAndShowWindow(window)
end


function scheduleStartupTest(self)
	if not self:_ensureComponents() then
		return
	end

	_logInfo("startup self-test scheduled")
	os.remove(AUTOTEST_MARKER)
	self._startupTimer = Timer(5000, function()
		_logInfo("startup self-test starting preset 1")
		self.streamPlayer:start(Stations.getByPreset(1))
	end, true)
	self._startupTimer:start()
end


function enableStandaloneMode(self)
	if not self:_ensureComponents() or self.listenerHandles then
		return
	end

	_logInfo("standalone mode controls enabled")
	self.listenerHandles = {}

	local function playPreset(_, event, station)
		_logInfo("preset action ", station.id)
		self.streamPlayer:start(station)
		return EVENT_CONSUME
	end

	for _, station in ipairs(Stations.all()) do
		table.insert(self.listenerHandles, Framework:addActionListener("play_preset_" .. station.preset, self,
			function(_, event)
				return playPreset(self, event, station)
			end, -100))
	end

	local function stopAction()
		self.streamPlayer:stop()
		return EVENT_CONSUME
	end
	table.insert(self.listenerHandles, Framework:addActionListener("pause", self, stopAction, -100))
	table.insert(self.listenerHandles, Framework:addActionListener("stop", self, stopAction, -100))
	table.insert(self.listenerHandles, Framework:addActionListener("play", self, function()
		self.streamPlayer:play()
		return EVENT_CONSUME
	end, -100))
end
