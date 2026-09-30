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
local HttpsProxyStatus = require("applets.StandaloneRadio.HttpsProxyStatus")
local Countries = require("applets.StandaloneRadio.Countries")
local NowPlaying = require("applets.StandaloneRadio.NowPlaying")
local PresetStore = require("applets.StandaloneRadio.PresetStore")
local RadioBrowser = require("applets.StandaloneRadio.RadioBrowser")
local RadioFeedsClient = require("applets.StandaloneRadio.RadioFeedsClient")
local Stations = require("applets.StandaloneRadio.Stations")
local StreamPlayer = require("applets.StandaloneRadio.StreamPlayer")
local TrackArtwork = require("applets.StandaloneRadio.TrackArtwork")

local log = require("jive.utils.log").logger("StandaloneRadio")

local AUTOTEST_MARKER = "/tmp/standalone-radio-autotest"
local DEFAULT_COUNTRY_CODE = "NL"
local POPULAR_LIMIT = 100
local ALL_STATIONS_PAGE_SIZE = 100
local SEARCH_RESULT_LIMIT = 250

module(..., Framework.constants)
oo.class(_M, Applet)


local function _logInfo(...)
	log:info("StandaloneRadio: ", ...)
end


function _ensureComponents(self)
	if self.streamPlayer then
		return true
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
	self.httpsProxyStatus = HttpsProxyStatus.new({
		log = log,
		onUnavailable = function()
			self:_showPopup(self:string("STANDALONE_RADIO_HTTPS_PROXY_REQUIRED"), 4500)
		end,
	})
	self.logoCache = LogoCache.new({
		applet = self,
		log = log,
		httpsProxyStatus = self.httpsProxyStatus,
	})
	self.lastStation = self.presetStore:getPreset(settings.lastPreset or 1)
	self.nowPlaying = NowPlaying.new(self, log, {
		onClose = function()
			if self.streamPlayer then
				self.streamPlayer:stopConnecting()
			end
		end,
	})
	self.radioFeeds = RadioFeedsClient.new({ log = log, httpsProxyStatus = self.httpsProxyStatus })
	self.trackArtwork = TrackArtwork.new({
		log = log,
		nowPlaying = self.nowPlaying,
		httpsProxyStatus = self.httpsProxyStatus,
	})
	self.streamPlayer = StreamPlayer.new({
		log = log,
		lastStation = self.lastStation,
		httpsProxyStatus = self.httpsProxyStatus,
		callbacks = {
			onState = function(station, state, show)
				self.nowPlaying:update(station, state, show)
				self:_refreshMenu()
			end,
			onMetadata = function(title)
				self.nowPlaying:setMetadata(title)
				local station = self.streamPlayer:getCurrentStation()
				if not station or station.source ~= "radiofeeds" then
					self.trackArtwork:lookup(station, title)
				end
			end,
				onSelected = function(station)
					self.lastStation = station
					self.nowPlaying:selectStation(station)
					self.trackArtwork:reset(station)
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


function _showPopup(self, text, duration)
	local popup = Popup("popup", text)
	popup:addWidget(Label("text", text))
	popup:show()

	local timer = Timer(duration or 1800, function()
		popup:hide()
	end, true)
	timer:start()
end


function _playStation(self, station)
	if not station then
		return
	end

	if station.source == "radiofeeds" and string.match(string.lower(station.url or ""), "%.m3u[%?%#]?")
		or station.source == "radiofeeds" and string.match(string.lower(station.url or ""), "%.pls[%?%#]?") then
		self.radioFeeds:resolveStation(station, function(resolved, err)
			if not resolved then
				log:warn("StandaloneRadio: RadioFeeds playlist resolution failed: ", tostring(err))
				self:_showPopup(self:string("STANDALONE_RADIO_FAILED"))
				return
			end
			_logInfo("RadioFeeds playlist resolved ", station.url, " -> ", resolved.url)
			self:_playStation(resolved)
		end)
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
		{
			text = self:string("STANDALONE_RADIO_NOW_PLAYING"),
			sound = "WINDOW_OPEN",
			weight = 1,
			callback = function()
				local station = self.streamPlayer:getCurrentStation() or self.lastStation
				if station then
					self.nowPlaying:show(station)
				else
					self:_showPopup(self:string("STANDALONE_RADIO_NO_STATION_SELECTED"))
				end
			end,
		},
		{
			text = self:string("STANDALONE_RADIO_BROWSER"),
			sound = "SELECT",
			weight = 2,
			callback = function()
				self:radioBrowserMenu()
			end,
		},
		{
			text = self:string("STANDALONE_RADIO_RADIOFEEDS"),
			sound = "SELECT",
			weight = 3,
			callback = function()
				self:radioFeedsMenu(self.radioFeeds:rootUrl(), self:string("STANDALONE_RADIO_RADIOFEEDS"))
			end,
		},
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


function _setDirectory(self, code, directory)
	self.activeCountryCode = code
	self.activeDirectory = directory
	self:_renderRadioBrowserMenu()
end


function _refreshCountry(self, code, showProgress)
	local identity = self.directoryIdentity
	local started = self.radioBrowser:refresh(code, function(directory, err)
		-- A completed background fetch may update its own cache, but never the
		-- current country view after the user has switched away.
		if code ~= self.activeCountryCode or identity ~= self.directoryIdentity then
			return
		end
		if directory then
			self.directoryError = nil
			self.directoryRefreshing = nil
			self.directoryLoadingCount = nil
			self:_setDirectory(code, directory)
		elseif not self.activeDirectory or self.activeDirectory.count == 0 then
			self.directoryError = err
			self.directoryRefreshing = nil
			self.directoryLoadingCount = nil
			self:_renderRadioBrowserMenu()
		else
			self.directoryRefreshing = nil
			self.directoryLoadingCount = nil
			self:_renderRadioBrowserMenu()
		end
	end, function(count)
		if showProgress and code == self.activeCountryCode and identity == self.directoryIdentity then
			self.directoryLoadingCount = count
			self:_renderRadioBrowserMenu()
		end
	end)
	if started and showProgress and code == self.activeCountryCode and identity == self.directoryIdentity then
		self.directoryRefreshing = true
		self.directoryLoadingCount = 0
		self:_renderRadioBrowserMenu()
	end
	return started
end


function _activateCountry(self, code)
	self.directoryIdentity = (self.directoryIdentity or 0) + 1
	self.directoryError = nil
	self.directoryRefreshing = nil
	self.directoryLoadingCount = nil
	local directory, stale = self.radioBrowser:loadCache(code)
	self:_setDirectory(code, directory)
	if directory then
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
	local directory = self.activeDirectory
	if not directory then self:_showStationList(self:string("STANDALONE_RADIO_ALL_STATIONS"), {}); return end
	local window = Window("text_list", self:string("STANDALONE_RADIO_ALL_STATIONS"))
	local menu = SimpleMenu("menu")
	menu:setComparator(SimpleMenu.itemComparatorWeightAlpha)
	window:addWidget(menu)
	local showPage
	showPage = function(offset)
		local stations = self.radioBrowser:readPage(directory, offset, ALL_STATIONS_PAGE_SIZE) or {}
		local items = self:_stationItems(stations)
		if offset > 0 then
			items[#items + 1] = {
				text = self:string("STANDALONE_RADIO_PREVIOUS_PAGE"), sound = "SELECT", weight = ALL_STATIONS_PAGE_SIZE + 1,
				callback = function() showPage(offset - ALL_STATIONS_PAGE_SIZE) end,
			}
		end
		if offset + #stations < directory.count then
			items[#items + 1] = {
				text = self:string("STANDALONE_RADIO_NEXT_PAGE"), sound = "SELECT", weight = ALL_STATIONS_PAGE_SIZE + 2,
				callback = function() showPage(offset + ALL_STATIONS_PAGE_SIZE) end,
			}
		end
		menu:setItems(items)
		menu:reLayout()
	end
	showPage(0)
	self:tieAndShowWindow(window)
end


function _showPopular(self)
	local window = Window("text_list", self:string("STANDALONE_RADIO_POPULAR"))
	local menu = SimpleMenu("menu")
	menu:setComparator(SimpleMenu.itemComparatorWeightAlpha)
	window:addWidget(menu)
	menu:setItems({ { text = self:string("STANDALONE_RADIO_LOADING"), style = "item", weight = 0 } })
	self:tieAndShowWindow(window)

	self.popularIdentity = (self.popularIdentity or 0) + 1
	local identity = self.popularIdentity
	self.radioBrowser:popularAsync(self.activeDirectory, POPULAR_LIMIT, function(ranked, err)
		if identity ~= self.popularIdentity then return end
		if err then log:warn("StandaloneRadio: popular scan failed: ", tostring(err)) end
		menu:setItems(self:_stationItems(ranked or {}))
		menu:reLayout()
	end)
end


function _showSearchResults(self, query)
	query = tostring(query or ""):gsub("^%s*(.-)%s*$", "%1")
	local window = Window("text_list", self:string("STANDALONE_RADIO_SEARCH"))
	local menu = SimpleMenu("menu")
	menu:setComparator(SimpleMenu.itemComparatorWeightAlpha)
	window:addWidget(menu)
	menu:setItems({ { text = self:string("STANDALONE_RADIO_LOADING"), style = "item", weight = 0 } })
	self:tieAndShowWindow(window)

	self.searchIdentity = (self.searchIdentity or 0) + 1
	local identity = self.searchIdentity
	self.radioBrowser:searchAsync(self.activeDirectory, query, SEARCH_RESULT_LIMIT, function(matches, err)
		if identity ~= self.searchIdentity then return end
		if err then log:warn("StandaloneRadio: search failed: ", tostring(err)) end
		menu:setItems(self:_stationItems(matches or {}))
		menu:reLayout()
	end)
end


function _showSearch(self)
	local window = Window("text_list", self:string("STANDALONE_RADIO_SEARCH"))
	local function submitSearch(value)
		local query = tostring(value or "")
		_logInfo("search submitted query=", query)
		-- Push results above the keyboard. Hiding this window first races the
		-- touchscreen's finish action and can leave the screen unchanged.
		self:_showSearchResults(query)
		return true
	end
	local input = Textinput("textinput", Textinput.textValue("", 0, 64), function(_, value)
		return submitSearch(value)
	end)
	local backspace = Keyboard.backspace()
	local group = Group("keyboard_textinput", { textinput = input, backspace = backspace })
	window:addWidget(group)
	window:addWidget(Keyboard("keyboard", "qwerty", input))
	window:focusWidget(group)
	self:tieAndShowWindow(window)
end


local function urlEncode(value)
	return (tostring(value or ""):gsub("([^%w%-_%.~])", function(character)
		return string.format("%%%02X", string.byte(character))
	end))
end


function _showRadioFeedsSearch(self, entry)
	local window = Window("text_list", entry.title)
	local input = Textinput("textinput", Textinput.textValue("", 0, 64), function(_, value)
		local url = string.gsub(entry.url, "{QUERY}", urlEncode(value))
		self:radioFeedsMenu(url, entry.title)
		return true
	end)
	local backspace = Keyboard.backspace()
	local group = Group("keyboard_textinput", { textinput = input, backspace = backspace })
	window:addWidget(group)
	window:addWidget(Keyboard("keyboard", "qwerty", input))
	window:focusWidget(group)
	self:tieAndShowWindow(window)
end


function _radioFeedsItems(self, entries)
	local items = {}
	for index, entry in ipairs(entries or {}) do
		local selected = entry
		local item = { text = selected.title, sound = "SELECT", weight = index }
		if selected.type == "link" and selected.url then
			item.callback = function() self:radioFeedsMenu(selected.url, selected.title) end
		elseif selected.type == "search" and selected.url then
			item.callback = function() self:_showRadioFeedsSearch(selected) end
		elseif selected.type == "audio" and selected.url then
			item.callback = function()
				local station, err = self.radioFeeds:toStation(selected)
				if not station then
					log:warn("StandaloneRadio: invalid RadioFeeds station: ", tostring(err))
					self:_showPopup(self:string("STANDALONE_RADIO_FAILED"))
					return
				end
				_logInfo("selected RadioFeeds station ", station.name, " bitrate=", tostring(station.bitrate))
				self:_playStation(station)
			end
		elseif selected.type == "directory" then
			item.callback = function() self:_showRadioFeedsEntries(selected.title, selected.children or {}) end
		else
			item.style = "item"
		end
		items[#items + 1] = item
	end
	if #items == 0 then items[1] = { text = self:string("STANDALONE_RADIO_NO_STATIONS"), style = "item", weight = 0 } end
	return items
end


function _showRadioFeedsEntries(self, title, entries)
	local window = Window("text_list", title)
	local menu = SimpleMenu("menu")
	window:addWidget(menu)
	menu:setItems(self:_radioFeedsItems(entries))
	self:tieAndShowWindow(window)
end


function radioFeedsMenu(self, url, title)
	if not self:_ensureComponents() then return end
	local window = Window("text_list", title)
	local menu = SimpleMenu("menu")
	window:addWidget(menu)
	menu:setItems({ { text = self:string("STANDALONE_RADIO_LOADING"), style = "item", weight = 0 } })
	self:tieAndShowWindow(window)
	self.radioFeeds:fetchDirectory(url, function(directory, err)
		if err then
			log:warn("StandaloneRadio: RadioFeeds directory failed url=", url, " error=", tostring(err))
			menu:setItems({ { text = self:string("STANDALONE_RADIO_RADIOFEEDS_FAILED"), style = "item", weight = 0 } })
		else
			menu:setItems(self:_radioFeedsItems(directory.children))
		end
		menu:reLayout()
	end)
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
	local stationCount = self.activeDirectory and self.activeDirectory.count or nil
	local popularCount = stationCount and (stationCount > POPULAR_LIMIT and POPULAR_LIMIT or stationCount) or nil
	local popularLabel = tostring(self:string("STANDALONE_RADIO_POPULAR"))
	local allStationsLabel = tostring(self:string("STANDALONE_RADIO_ALL_STATIONS"))
	if popularCount then popularLabel = popularLabel .. " (" .. tostring(popularCount) .. ")" end
	if stationCount then allStationsLabel = allStationsLabel .. " (" .. tostring(stationCount) .. ")" end
	local items = {
		{ text = self:string("STANDALONE_RADIO_SEARCH"), sound = "SELECT", weight = 1, callback = function() self:_showSearch() end },
		{ text = popularLabel, sound = "SELECT", weight = 2, callback = function() self:_showPopular() end },
		{ text = allStationsLabel, sound = "SELECT", weight = 3, callback = function() self:_showAllStations() end },
		{ text = tostring(self:string("STANDALONE_RADIO_COUNTRY")) .. ": " .. Countries.displayName(code), sound = "SELECT", weight = 4, callback = function() self:_showCountryMenu() end },
		{ text = self:string("STANDALONE_RADIO_REFRESH"), sound = "SELECT", weight = 5, callback = function() self:_refreshCountry(code, true) end },
	}
	if self.directoryError then
		items[#items + 1] = { text = self:string("STANDALONE_RADIO_BROWSER_FAILED"), style = "item", weight = 6 }
	elseif not self.activeDirectory or self.directoryRefreshing then
		local loading = tostring(self:string("STANDALONE_RADIO_LOADING_STATIONS"))
		if self.directoryLoadingCount then loading = loading .. " " .. tostring(self.directoryLoadingCount) end
		items[#items + 1] = { text = loading, style = "item", weight = 6 }
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
	window:addListener(EVENT_WINDOW_POP, function()
		self.browserMenuWidget = nil
	end)
	-- Populate the browser before showing its window. Stock Jive menus can
	-- otherwise display an empty first frame while the directory activates.
	self:_renderRadioBrowserMenu()
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
	self.httpsProxyStatus:check(false)
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
