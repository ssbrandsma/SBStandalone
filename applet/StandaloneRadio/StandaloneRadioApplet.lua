local ipairs, os, tostring = ipairs, os, tostring

local oo = require("loop.simple")
local table = require("table")
local string = require("string")

local Applet = require("jive.Applet")
local Framework = require("jive.ui.Framework")
local Group = require("jive.ui.Group")
local Keyboard = require("jive.ui.Keyboard")
local Label = require("jive.ui.Label")
local Popup = require("jive.ui.Popup")
local SimpleMenu = require("jive.ui.SimpleMenu")
local Textinput = require("jive.ui.Textinput")
local Timer = require("jive.ui.Timer")
local Window = require("jive.ui.Window")

local LogoCache = require("applets.StandaloneRadio.LogoCache")
local Countries = require("applets.StandaloneRadio.Countries")
local NowPlaying = require("applets.StandaloneRadio.NowPlaying")
local PresetStore = require("applets.StandaloneRadio.PresetStore")
local RadioBrowser = require("applets.StandaloneRadio.RadioBrowser")
local Stations = require("applets.StandaloneRadio.Stations")
local StreamPlayer = require("applets.StandaloneRadio.StreamPlayer")

local log = require("jive.utils.log").logger("StandaloneRadio")

local AUTOTEST_MARKER = "/tmp/standalone-radio-autotest"
local DEFAULT_COUNTRY_CODE = "NL"
local POPULAR_LIMIT = 100

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
	self.logoCache = LogoCache.new({
		applet = self,
		log = log,
	})
	self.lastStation = self.presetStore:getPreset(settings.lastPreset or 1) or Stations.getById(settings.lastStationId)
	self.nowPlaying = NowPlaying.new(self, log, {
		onClose = function()
			if self.streamPlayer then
				self.streamPlayer:stopConnecting()
			end
		end,
	})
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
	if self.logoCache then
		self.logoCache:ensure(station, function(path)
			if path then
				self.presetStore:updateLogo(station)
				self.nowPlaying:updateLogo(station)
			end
		end)
	end
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
		-- Persist the JSON favicon URL immediately; if the artwork has not yet
		-- arrived, this second lazy request is harmless and updates the preset.
		self.logoCache:ensure(station, function(path)
			if path then
				self.presetStore:updateLogo(station)
			end
		end)
		self:_showPopup(tostring(self:string("STANDALONE_RADIO_PRESET_SAVED")):gsub("%%d", tostring(number)))
		self:_refreshMenu()
	end
end


function _refreshMenu(self)
	if not self.menuWidget then
		return
	end

	local items = {
		text = self:string("STANDALONE_RADIO_BROWSER"),
		sound = "SELECT",
		weight = 1,
		callback = function()
			self:radioBrowserMenu()
		end,
	}

	self.menuWidget:setItems(items)
	self.menuWidget:reLayout()
end


function _selectedCountryCode(self)
	local settings = self:getSettings() or {}
	local code = settings.selectedCountryCode
	if not Countries.validCode(code) then
		code = DEFAULT_COUNTRY_CODE
		settings.selectedCountryCode = code
		self:setSettings(settings)
		self:storeSettings()
	end
	return code
end


function _setDirectory(self, code, stations)
	self.activeCountryCode = code
	self.activeStations = stations
	self:_renderRadioBrowserMenu()
end


function _refreshCountry(self, code, showProgress)
	local identity = self.directoryIdentity
	local started = self.radioBrowser:refresh(code, function(stations, err)
		-- A completed background fetch may update its own cache, but never the
		-- current country view after the user has switched away.
		if code ~= self.activeCountryCode or identity ~= self.directoryIdentity then
			return
		end
		if stations then
			self:_setDirectory(code, stations)
		elseif not self.activeStations or #self.activeStations == 0 then
			self.directoryError = err
			self:_renderRadioBrowserMenu()
		end
	end, function(count)
		if showProgress and code == self.activeCountryCode and identity == self.directoryIdentity then
			self.directoryLoadingCount = count
			self:_renderRadioBrowserMenu()
		end
	end)
	return started
end


function _activateCountry(self, code)
	self.directoryIdentity = (self.directoryIdentity or 0) + 1
	self.directoryError = nil
	self.directoryLoadingCount = nil
	local stations, stale = self.radioBrowser:loadCache(code)
	self:_setDirectory(code, stations)
	if stations then
		if stale then
			self:_refreshCountry(code, false)
		end
	else
		self:_refreshCountry(code, true)
	end
end


function _stationItems(self, stations)
	local items = {}
	for index, station in ipairs(stations or {}) do
		local selectedStation = station
		items[#items + 1] = {
			text = Stations.displayName(selectedStation, self), sound = "SELECT", weight = index,
			callback = function()
				_logInfo("selected Radio Browser station ", Stations.displayName(selectedStation, self))
				self:_playStation(selectedStation)
			end,
		}
	end
	if #items == 0 then
		items[1] = { text = self:string("STANDALONE_RADIO_NO_STATIONS"), style = "item", weight = 0 }
	end
	return items
end


function _showStationList(self, title, stations)
	local window = Window("text_list", title)
	local menu = SimpleMenu("menu")
	menu:setComparator(SimpleMenu.itemComparatorWeightAlpha)
	window:addWidget(menu)
	menu:setItems(self:_stationItems(stations))
	self:tieAndShowWindow(window)
end


function _showAllStations(self)
	self:_showStationList(self:string("STANDALONE_RADIO_ALL_STATIONS"), self.activeStations)
end


function _showPopular(self)
	local ranked = {}
	for _, station in ipairs(self.activeStations or {}) do ranked[#ranked + 1] = station end
	table.sort(ranked, function(a, b)
		if (a.clickcount or 0) ~= (b.clickcount or 0) then return (a.clickcount or 0) > (b.clickcount or 0) end
		if (a.votes or 0) ~= (b.votes or 0) then return (a.votes or 0) > (b.votes or 0) end
		local an, bn = string.lower(a.name or ""), string.lower(b.name or "")
		return an == bn and (a.stationuuid or "") < (b.stationuuid or "") or an < bn
	end)
	while #ranked > POPULAR_LIMIT do table.remove(ranked) end
	self:_showStationList(self:string("STANDALONE_RADIO_POPULAR"), ranked)
end


function _showSearchResults(self, query)
	query = tostring(query or ""):gsub("^%s*(.-)%s*$", "%1")
	local matches = {}
	if query ~= "" then
		local needle = string.lower(query)
		for _, station in ipairs(self.activeStations or {}) do
			if string.find(string.lower(station.name or ""), needle, 1, true) then
				matches[#matches + 1] = station
			end
		end
	end
	self:_showStationList(self:string("STANDALONE_RADIO_SEARCH"), matches)
end


function _showSearch(self)
	local window = Window("text_list", self:string("STANDALONE_RADIO_SEARCH"))
	local input = Textinput("textinput", Textinput.textValue("", 64, 200), function(_, value)
		window:hide()
		self:_showSearchResults(value)
		return true
	end)
	local backspace = Keyboard.backspace()
	local group = Group("keyboard_textinput", { textinput = input, backspace = backspace })
	window:addWidget(group)
	window:addWidget(Keyboard("keyboard", "qwerty", input))
	window:focusWidget(group)
	self:tieAndShowWindow(window)
end


function _showCountryMenu(self)
	local window = Window("text_list", self:string("STANDALONE_RADIO_COUNTRY"))
	local menu = SimpleMenu("menu")
	menu:setComparator(SimpleMenu.itemComparatorWeightAlpha)
	window:addWidget(menu)
	local selected = self:_selectedCountryCode()
	local items = {}
	for index, country in ipairs(Countries.all()) do
		local selectedCountry = country
		items[#items + 1] = {
			text = selectedCountry.name .. (selectedCountry.code == selected and " *" or ""), sound = "SELECT", weight = index,
			callback = function()
				if selectedCountry.code ~= self:_selectedCountryCode() then
					local settings = self:getSettings()
					local previous = settings.selectedCountryCode
					settings.selectedCountryCode = selectedCountry.code
					self:storeSettings()
					_logInfo("country changed ", tostring(previous), " -> ", selectedCountry.code)
					self:_activateCountry(selectedCountry.code)
				end
				window:hide()
			end,
		}
	end
	menu:setItems(items)
	self:tieAndShowWindow(window)
end


function _renderRadioBrowserMenu(self)
	if not self.browserMenuWidget then return end
	local code = self.activeCountryCode or self:_selectedCountryCode()
	local items = {
		{ text = self:string("STANDALONE_RADIO_SEARCH"), sound = "SELECT", weight = 1, callback = function() self:_showSearch() end },
		{ text = self:string("STANDALONE_RADIO_POPULAR"), sound = "SELECT", weight = 2, callback = function() self:_showPopular() end },
		{ text = self:string("STANDALONE_RADIO_ALL_STATIONS"), sound = "SELECT", weight = 3, callback = function() self:_showAllStations() end },
		{ text = self:string("STANDALONE_RADIO_COUNTRY") .. ": " .. Countries.displayName(code), sound = "SELECT", weight = 4, callback = function() self:_showCountryMenu() end },
		{ text = self:string("STANDALONE_RADIO_REFRESH"), sound = "SELECT", weight = 5, callback = function() self:_refreshCountry(code, false) end },
	}
	if not self.activeStations then
		local loading = self:string("STANDALONE_RADIO_LOADING_STATIONS")
		if self.directoryLoadingCount then loading = loading .. " " .. tostring(self.directoryLoadingCount) end
		items[#items + 1] = { text = loading, style = "item", weight = 6 }
	elseif self.directoryError then
		items[#items + 1] = { text = self:string("STANDALONE_RADIO_BROWSER_FAILED"), style = "item", weight = 6 }
	end
	self.browserMenuWidget:setItems(items)
	self.browserMenuWidget:reLayout()
end


function radioBrowserMenu(self)
	if not self:_ensureComponents() then return end
	local window = Window("text_list", self:string("STANDALONE_RADIO_BROWSER"))
	local menu = SimpleMenu("menu")
	menu:setComparator(SimpleMenu.itemComparatorWeightAlpha)
	window:addWidget(menu)
	self.browserMenuWidget = menu
	window:addListener(EVENT_WINDOW_POP, function() self.browserMenuWidget = nil end)
	self:tieAndShowWindow(window)
	self:_activateCountry(self:_selectedCountryCode())
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
