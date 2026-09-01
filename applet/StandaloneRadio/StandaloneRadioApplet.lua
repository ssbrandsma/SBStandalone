local ipairs, os, tostring = ipairs, os, tostring

local oo = require("loop.simple")
local table = require("table")

local Applet = require("jive.Applet")
local Framework = require("jive.ui.Framework")
local Label = require("jive.ui.Label")
local Popup = require("jive.ui.Popup")
local SimpleMenu = require("jive.ui.SimpleMenu")
local Timer = require("jive.ui.Timer")
local Window = require("jive.ui.Window")

local NowPlaying = require("applets.StandaloneRadio.NowPlaying")
local PresetStore = require("applets.StandaloneRadio.PresetStore")
local RadioBrowser = require("applets.StandaloneRadio.RadioBrowser")
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
	if self._entry then
		self._entry.settings = settings
	end
	self.presetStore = PresetStore.new({
		applet = self,
		log = log,
		settings = settings,
	})
	self.radioBrowser = RadioBrowser.new({
		log = log,
	})
	self.lastStation = self.presetStore:getPreset(settings.lastPreset or 1) or Stations.getById(settings.lastStationId)
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
				if station.preset then
					settings.lastPreset = station.preset
				end
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
	return tostring(prefix):gsub("%%s", Stations.displayName(self.lastStation, self))
end


function _showPopup(self, text)
	local popup = Popup("popup", text)
	popup:addWidget(Label("text", text))
	popup:show()

	local timer = Timer(1800, function()
		popup:hide()
	end, true)
	timer:start()
end


function _playStation(self, station)
	if not station then
		return
	end

	self.streamPlayer:start(station)
	if station.source == "radiobrowser" then
		self.radioBrowser:recordClick(station)
	end
end


function _assignPreset(self, number)
	if not self:_ensureComponents() then
		return
	end

	local station = self.streamPlayer:getCurrentStation()
	if not station then
		_logInfo("no station selected for preset ", tostring(number))
		self:_showPopup(self:string("STANDALONE_RADIO_NO_STATION_SELECTED"))
		return
	end

	_logInfo("assigning ", Stations.displayName(station, self), " to preset ", tostring(number))
	local saved = self.presetStore:assign(number, station)
	if saved then
		self:_showPopup(tostring(self:string("STANDALONE_RADIO_PRESET_SAVED")):gsub("%%d", tostring(number)))
		self:_refreshMenu()
	end
end


function _refreshMenu(self)
	if not self.menuWidget then
		return
	end

	local items = {
		{ text = self:_statusText(), style = "item", weight = 0 },
	}

	items[#items + 1] = {
		text = self:string("STANDALONE_RADIO_BROWSER"),
		sound = "SELECT",
		weight = 1,
		callback = function()
			self:radioBrowserMenu()
		end,
	}

	for preset, station in ipairs(self.presetStore:all()) do
		items[#items + 1] = {
			text = tostring(preset) .. ". " .. Stations.displayName(station, self),
			sound = "SELECT",
			weight = preset + 10,
			callback = function()
				_logInfo("playing saved preset ", tostring(preset), " ", Stations.displayName(station, self))
				self:_playStation(station)
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


function radioBrowserMenu(self)
	if not self:_ensureComponents() then
		return
	end

	local window = Window("text_list", self:string("STANDALONE_RADIO_BROWSER"))
	local menu = SimpleMenu("menu")
	menu:setComparator(SimpleMenu.itemComparatorWeightAlpha)
	window:addWidget(menu)
	menu:setItems({
		{ text = self:string("STANDALONE_RADIO_LOADING"), style = "item", weight = 0 },
	})
	self:tieAndShowWindow(window)

	self.radioBrowser:fetch(function(stations, err)
		local items = {}
		if not stations then
			items[#items + 1] = {
				text = self:string("STANDALONE_RADIO_BROWSER_FAILED"),
				style = "item",
				weight = 0,
			}
			if err then
				_logInfo("Radio Browser menu failed: ", tostring(err))
			end
		else
			for index, station in ipairs(stations) do
				items[#items + 1] = {
					text = Stations.displayName(station, self),
					sound = "SELECT",
					weight = index,
					callback = function()
						_logInfo("selected Radio Browser station ", Stations.displayName(station, self))
						self:_playStation(station)
					end,
				}
			end
		end

		menu:setItems(items)
		menu:reLayout()
	end)
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
		self:_playStation(self.presetStore:getPreset(1))
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
		if station then
			_logInfo("preset action ", station.id)
			self:_playStation(station)
		else
			_logInfo("preset action ignored; no station assigned")
			self:_showPopup(self:string("STANDALONE_RADIO_NO_STATION_SELECTED"))
		end
		return EVENT_CONSUME
	end

	for i = 1, 6 do
		table.insert(self.listenerHandles, Framework:addActionListener("play_preset_" .. i, self,
			function(_, event)
				local station = self.presetStore:getPreset(i)
				return playPreset(self, event, station)
			end, -100))
		table.insert(self.listenerHandles, Framework:addActionListener("set_preset_" .. i, self,
			function()
				self:_assignPreset(i)
				return EVENT_CONSUME
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
