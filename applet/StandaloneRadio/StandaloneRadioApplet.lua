local assert, io, ipairs, os, pairs, pcall, tostring = assert, io, ipairs, os, pairs, pcall, tostring

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
local NativeNowPlaying = require("applets.StandaloneRadio.NativeNowPlaying")
local HttpsProxyStatus = require("applets.StandaloneRadio.HttpsProxyStatus")
local Countries = require("applets.StandaloneRadio.Countries")
local PresetStore = require("applets.StandaloneRadio.PresetStore")
local RadioBrowser = require("applets.StandaloneRadio.RadioBrowser")
local OpmlNavigator = require("applets.StandaloneRadio.OpmlNavigator")
local OpmlClient = require("applets.StandaloneRadio.OpmlClient")
local OpmlProviders = require("applets.StandaloneRadio.OpmlProviders")
local Stations = require("applets.StandaloneRadio.Stations")
local StreamPlayer = require("applets.StandaloneRadio.StreamPlayer")
local StandaloneBaseNowPlaying = require("applets.StandaloneRadio.StandaloneBaseNowPlaying")
local TrackArtwork = require("applets.StandaloneRadio.TrackArtwork")
local UserStations = require("applets.StandaloneRadio.UserStations")
local UrlTransport = require("applets.StandaloneRadio.UrlTransport")

local log = require("jive.utils.log").logger("StandaloneRadio")
local appletManager = appletManager

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
	self.userStations = UserStations.new({ log = log })
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
	self.radioFeeds = OpmlClient.new({log=log,httpsProxyStatus=self.httpsProxyStatus,provider=OpmlProviders.get("radiofeeds")})
    self.opmlClients={radiofeeds=self.radioFeeds,tunein=OpmlClient.new({log=log,httpsProxyStatus=self.httpsProxyStatus,
        provider=OpmlProviders.get("tunein",{partnerId=settings.tuneInPartnerId})})}
	self.trackArtwork = TrackArtwork.new({
		log = log,
		onArtworkUrl = function(station, streamTitle, url, stationGeneration)
			if self.baseNowPlaying then
				self.baseNowPlaying:updateTrackArtwork(url, station, stationGeneration, streamTitle)
			end
		end,
	})
	self.baseNowPlaying = StandaloneBaseNowPlaying.new({
		log = log,
		debug = settings.nowPlayingDebug == true,
		isPlaybackOwner = function()
			return self.streamPlayer and self.streamPlayer.ownsPlayback == true
		end,
		onPublished = function()
			-- A source can start after the local LMS bootstrap completed while
			-- stopped. Ensure the current Player is staged so it subscribes to
			-- playerstatus before the stock Now Playing menu checks playlist size.
			local player = appletManager:callService("getCurrentPlayer")
			if player and player.onStage then
				player:onStage()
			end
		end,
	})
	self.nativeNowPlaying = NativeNowPlaying.new({
		appletManager = appletManager,
		framework = Framework,
		timerFactory = function(delay, callback, once) return Timer(delay, callback, once) end,
		transition = Window.transitionPushLeft,
		log = log,
		getGeneration = function()
			return self.streamPlayer and self.streamPlayer.stationGeneration or nil
		end,
	})
	self.streamPlayer = StreamPlayer.new({
		log = log,
		lastStation = self.lastStation,
		httpsProxyStatus = self.httpsProxyStatus,
		callbacks = {
			onHandoff = function()
				self.nativeNowPlaying:shutdown()
				self.trackArtwork:reset(nil)
				self.baseNowPlaying:release()
			end,
			onTimedMetadata = function(event, station, stationGeneration)
				self.baseNowPlaying:updateTimedMetadata(event, station, stationGeneration)
			end,
			onState = function(station, state, show, stationGeneration)
				self.baseNowPlaying:updateState(state, station, stationGeneration)
				self:_refreshMenu()
			end,
			onMetadata = function(title, station, stationGeneration)
				self.baseNowPlaying:updateMetadata(title, station, stationGeneration)
				if not station or station.source ~= "radiofeeds" then
					self.trackArtwork:lookup(station, title, stationGeneration)
				end
			end,
			onSelected = function(station, stationGeneration)
				self.lastStation = station
				self.trackArtwork:reset(station)
				self.baseNowPlaying:activate(station, stationGeneration)
				self.nativeNowPlaying:request(stationGeneration)
				settings.lastStationId = station.id
				if station.preset then
					settings.lastPreset = station.preset
				end
				self:storeSettings()
				self:_refreshMenu()
			end,
			onConnected = function(station, stationGeneration)
				self.lastStation = station
				self.baseNowPlaying:updateStation(station, stationGeneration)
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
	if self.nativeNowPlaying then self.nativeNowPlaying:shutdown() end
	if self.activeOpmlNavigator then self.activeOpmlNavigator:close() end
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
	if station.source == "user" and station.preset and self.userStations then
		local current, err = self.userStations:resolve(station.id)
		if not current then
			log:warn("StandaloneRadio: saved user station unavailable id=", tostring(station.id),
				" reason=", tostring(err))
			self:_showPopup(self:string("STANDALONE_RADIO_USER_STATION_UNAVAILABLE"), 3500)
			return
		end
		local resolved = {}
		for key, value in pairs(current) do resolved[key] = value end
		resolved.preset = station.preset
		station = resolved
	end

    if station.type=="opml" then self:_showPopup(self:string("STANDALONE_RADIO_USER_STATION_UNAVAILABLE"));return end
	self.playlistRequestGeneration = (self.playlistRequestGeneration or 0) + 1
	if self.playlistClient and self.playlistClient.cancelPlaylist then self.playlistClient:cancelPlaylist() end
    if self.radioFeeds.cancelPlaylist then self.radioFeeds:cancelPlaylist() end
	local playlistGeneration = self.playlistRequestGeneration
	if station.requiresResolution or (not station.hls and OpmlClient.isPlaylistUrl(station.url)) then
        local resolver=self.opmlClients and self.opmlClients[station.provider] or self.radioFeeds
        self.playlistClient=resolver
		resolver:resolveStation(station, function(resolved, err, code)
			if self.playlistRequestGeneration ~= playlistGeneration then return end
			if not resolved then
				log:warn("StandaloneRadio: OPML playlist resolution failed: ", tostring(err))
				self:_showPopup(self:string(code == "hls_unsupported" and "STANDALONE_RADIO_HLS_UNSUPPORTED" or "STANDALONE_RADIO_FAILED"), 5000)
				return
			end
			_logInfo("OPML playlist resolved ", UrlTransport.redact(station.url), " -> ", UrlTransport.redact(resolved.url))
			self:_playStation(resolved)
		end)
		return
	end

	self.streamPlayer:start(station)
	if self.logoCache then
		self.logoCache:ensure(station, function(path)
			if path then
				self.presetStore:updateLogo(station)
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
			text = self:string("STANDALONE_RADIO_BROWSER"),
			sound = "SELECT",
			weight = 1,
			callback = function()
				self:radioBrowserMenu()
			end,
		},
		{
			text = self:string("STANDALONE_RADIO_RADIOFEEDS"),
			sound = "SELECT",
			weight = 2,
			callback = function()
				self:radioFeedsMenu(self.radioFeeds:rootUrl(), self:string("STANDALONE_RADIO_RADIOFEEDS"))
			end,
		},
        {
            text = self:string("STANDALONE_RADIO_TUNEIN"),sound="SELECT",weight=3,
            callback=function() self:tuneInMenu() end,
        },
		{
			text = self:string("STANDALONE_RADIO_USER_STATIONS"),
			sound = "SELECT",
			weight = 4,
			callback = function()
				self:userStationsMenu()
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
            cmCallback=selectedStation.provider and function() self:_showOpmlStationActions(selectedStation) end or nil,
			callback = function()
				_logInfo("selected station ", Stations.displayName(selectedStation, self))
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


-- Reuse Jive's bounded artwork queue/cache and Base routing; no image decoder
-- or independent downloader is introduced for directory icons.
function _customItemIcon(self,station)
    local url=station.remoteLogo or station.image or station.icon
    if station.localLogoPath and station.logoFile then
        local file=io.open(station.localLogoPath,"rb")
        if file then
            file:close()
            local available,helper=pcall(require,"applets.StandaloneBase.ImageRender")
            local port=available and helper.webPort() or 80
            url="http://127.0.0.1:"..port.."/api/radio/logos/"..station.logoFile
        end
    end
    if not url or url=="" then return nil end
    local haveIcon,Icon=pcall(require,"jive.ui.Icon")
    local haveServer,SlimServer=pcall(require,"jive.slim.SlimServer")
    local server=haveServer and SlimServer:getCurrentServer()
    if not haveIcon or not server then return nil end
    local icon=Icon("icon")
    server:fetchArtwork(url,icon,"40x40")
    return icon
end

function _renderUserStations(self)
	if not self.userStationsMenuWidget then return end
	local stations, err = self.userStations:reload()
    local combined={}
    for _,station in ipairs(stations or {}) do combined[#combined+1]=station end
    for _,station in ipairs(self.presetStore:getFavorites()) do combined[#combined+1]=station end
    stations=combined
	local items = {}
	for index, station in ipairs(stations or {}) do
		local selected = station
		items[#items + 1] = {
			text = Stations.displayName(selected, self)..(selected.type=="opml" and "  >" or ""), sound = "SELECT", weight = index,
            icon=selected.type=="opml" and index<=24 and self:_customItemIcon(selected) or nil,
			callback = function()
				_logInfo("selected user station id=", selected.id)
                if selected.type=="opml" then
                    self.opmlClients=self.opmlClients or {}
                    self.opmlClients.custom=self.opmlClients.custom or OpmlClient.new({log=log,httpsProxyStatus=self.httpsProxyStatus,provider=OpmlProviders.get("custom")})
                    self:_getOpmlNavigator("custom"):open(selected.url,selected.name)
                else self:_playStation(selected) end
			end,
		}
	end
	if #items == 0 then
		items[1] = {
			text = self:string(err and "STANDALONE_RADIO_USER_STATIONS_UNAVAILABLE"
				or "STANDALONE_RADIO_NO_USER_STATIONS"),
			style = "item", weight = 0,
		}
	end
	self.userStationsMenuWidget:setItems(items)
	self.userStationsMenuWidget:reLayout()
end


function userStationsMenu(self)
	if not self:_ensureComponents() then return end
	local window = Window("text_list", self:string("STANDALONE_RADIO_USER_STATIONS"))
	local menu = SimpleMenu("menu")
	menu:setComparator(SimpleMenu.itemComparatorWeightAlpha)
	window:addWidget(menu)
	self.userStationsMenuWidget = menu
	window:addListener(EVENT_WINDOW_ACTIVE, function() self:_renderUserStations() end)
	window:addListener(EVENT_WINDOW_POP, function() self.userStationsMenuWidget = nil end)
	self:_renderUserStations()
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


function _getOpmlNavigator(self, provider)
    self.opmlNavigators=self.opmlNavigators or {}
    local navigator=self.opmlNavigators[provider]
    if not navigator then
        local client=assert(self.opmlClients and self.opmlClients[provider] or (provider=="radiofeeds" and self.radioFeeds))
        navigator=OpmlNavigator.new({client=client,cacheTtl=client.provider and client.provider.directoryCacheTtl,ui={
            window=function(title)
                local window=Window("text_list",title)
                local menu=SimpleMenu("menu")
                menu:setComparator(SimpleMenu.itemComparatorWeightAlpha)
                window:addWidget(menu);return window,menu
            end,
            listen=function(window,inactive,pop,active)
                window:addListener(EVENT_WINDOW_INACTIVE,inactive)
                window:addListener(EVENT_WINDOW_POP,pop)
                window:addListener(EVENT_WINDOW_ACTIVE,active)
            end,
            show=function(window) self:tieAndShowWindow(window) end,
            text=function(key)
                local tokens={search="STANDALONE_RADIO_SEARCH",loading="STANDALONE_RADIO_LOADING",empty="STANDALONE_RADIO_NO_STATIONS",untitled="STANDALONE_RADIO_OPML_UNTITLED",
                    failed=provider=="radiofeeds" and "STANDALONE_RADIO_RADIOFEEDS_FAILED" or "STANDALONE_RADIO_OPML_FAILED"}
                return self:string(tokens[key])
            end,
            icon=function(entry) return self:_customItemIcon(entry) end,
            search=function(entry,submit,cancel) self:_showOpmlSearchInput(entry,submit,cancel) end,
            play=function(station) self:_playStation(station) end,
            actions=function(station) self:_showOpmlStationActions(station) end,
            stations=function(stations) return self:_stationItems(stations) end,
            error=function(err,quiet)
                log:warn("StandaloneRadio: OPML ",provider,": ",tostring(err))
                if not quiet then self:_showPopup(self:string("STANDALONE_RADIO_FAILED")) end
            end,
        }})
        self.opmlNavigators[provider]=navigator
    end
    if self.activeOpmlNavigator and self.activeOpmlNavigator~=navigator then self.activeOpmlNavigator:close() end
    self.activeOpmlNavigator=navigator
    return navigator
end

function _showOpmlSearchInput(self, entry, submit, cancel)
	local window = Window("text_list", entry.title)
	if cancel then window:addListener(EVENT_WINDOW_POP,cancel) end
	local input = Textinput("textinput", Textinput.textValue("", 0, 64), function(_, value)
		local query = tostring(value or ""):match("^%s*(.-)%s*$")
		if query == "" then return false end
		-- Percent escapes in a replacement string are interpreted by gsub.
		-- Return the encoded query from a function to preserve its bytes.
		local url = string.gsub(entry.url, "{QUERY}", function() return urlEncode(query) end)
		submit(url)
		return true
	end)
	local backspace = Keyboard.backspace()
	local group = Group("keyboard_textinput", { textinput = input, backspace = backspace })
	window:addWidget(group)
	window:addWidget(Keyboard("keyboard", "qwerty", input))
	window:focusWidget(group)
	self:tieAndShowWindow(window)
end


function _showRadioFeedsSearch(self,entry)
    return self:_getOpmlNavigator("radiofeeds"):search(entry)
end
function _showRadioFeedsSearchResults(self,url,title)
    return self:_getOpmlNavigator("radiofeeds"):open(url,title,nil,true)
end
function _radioFeedsItems(self,entries)
    return self:_getOpmlNavigator("radiofeeds"):items(entries)
end
function _showRadioFeedsEntries(self,title,entries)
    return self:_getOpmlNavigator("radiofeeds"):open(nil,title,entries)
end
function radioFeedsMenu(self,url,title)
    if not self:_ensureComponents() then return end
    return self:_getOpmlNavigator("radiofeeds"):open(url,title)
end


function tuneInMenu(self)
    if not self:_ensureComponents() then return end
    return self:_getOpmlNavigator("tunein"):open(self.opmlClients.tunein:rootUrl(),self:string("STANDALONE_RADIO_TUNEIN"))
end

function _showOpmlStationActions(self,station)
    local window=Window("text_list",station.name)
    local menu=SimpleMenu("menu");window:addWidget(menu)
    local items={{text=self:string("STANDALONE_RADIO_SAVE_FAVORITE"),sound="SELECT",weight=0,
        callback=function()
            local saved=self.presetStore:saveFavorite(station)
            self:_showPopup(self:string(saved and "STANDALONE_RADIO_FAVORITE_SAVED" or "STANDALONE_RADIO_FAILED"))
        end}}
    for i=1,6 do
        local number=i
        items[#items+1]={text=self:string("STANDALONE_RADIO_PRESET").." "..i,sound="SELECT",weight=i,
            callback=function() self.presetStore:assign(number,station);window:hide() end}
    end
    menu:setItems(items);self:tieAndShowWindow(window)
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
