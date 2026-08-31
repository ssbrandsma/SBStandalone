local ipairs, os, pcall, tostring, tonumber, type = ipairs, os, pcall, tostring, tonumber, type

local oo = require("loop.simple")
local string = require("string")
local table = require("table")

local Applet = require("jive.Applet")
local Player = require("jive.slim.Player")
local Process = require("jive.net.Process")
local Stream = require("squeezeplay.stream")

local Framework = require("jive.ui.Framework")
local Group = require("jive.ui.Group")
local Icon = require("jive.ui.Icon")
local SimpleMenu = require("jive.ui.SimpleMenu")
local Surface = require("jive.ui.Surface")
local Window = require("jive.ui.Window")
local Popup = require("jive.ui.Popup")
local Label = require("jive.ui.Label")
local Task = require("jive.ui.Task")
local Timer = require("jive.ui.Timer")

local decode = require("squeezeplay.decode")

local log = require("jive.utils.log").logger("StandaloneRadio")

local jnt = jnt

module(..., Framework.constants)
oo.class(_M, Applet)


local stations = {
	{
		id = "npo1",
		nameToken = "STANDALONE_RADIO_NPO1",
		url = "http://icecast.omroep.nl/radio1-bb-mp3",
		host = "icecast.omroep.nl",
		port = 80,
		path = "/radio1-bb-mp3",
		logo = "images/npo1.png",
	},
	{
		id = "npo2",
		nameToken = "STANDALONE_RADIO_NPO2",
		url = "http://icecast.omroep.nl/radio2-bb-mp3",
		host = "icecast.omroep.nl",
                port = 80,
                path = "/radio2-bb-mp3",
		logo = "images/npo2.png",
        },
        {
                id = "radio538",
                nameToken = "STANDALONE_RADIO_538",
                url = "http://28513.live.streamtheworld.com/RADIO538.mp3",
                host = "28513.live.streamtheworld.com",
                port = 80,
                path = "/RADIO538.mp3",
		logo = "images/radio538.png",
        },
        {
                id = "radio10",
                nameToken = "STANDALONE_RADIO_10",
                url = "http://25683.live.streamtheworld.com/RADIO10.mp3",
                host = "25683.live.streamtheworld.com",
                port = 80,
                path = "/RADIO10.mp3",
		logo = "images/radio10.png",
        },
        {
                id = "veronica",
                nameToken = "STANDALONE_RADIO_VERONICA",
                url = "http://27903.live.streamtheworld.com/VERONICA.mp3",
                host = "27903.live.streamtheworld.com",
                port = 80,
                path = "/VERONICA.mp3",
		logo = "images/veronica.png",
        },
	{
		id = "bnr",
		nameToken = "STANDALONE_RADIO_BNR",
		url = "http://stream.bnr.nl/bnr_mp3_128_20",
		host = "stream.bnr.nl",
		port = 80,
		path = "/bnr_mp3_128_20",
		logo = "images/bnr.png",
	},
}

local AUTOTEST_MARKER = "/tmp/standalone-radio-autotest"
local _startStation


local function _localPlayer()
	return Player:getLocalPlayer() or Player:getCurrentPlayer()
end


local function _playback()
	local player = _localPlayer()
	if not player then
		return nil, "no local player"
	end

	if not player.playback then
		return nil, "local player has no playback instance"
	end

	return player.playback, player
end


local function _showBusy(self, token)
	local popup = Popup("waiting_popup")
	popup:addWidget(Label("text", self:string(token)))
	popup:show()
	return popup
end


local function _logInfo(...)
	log:info("StandaloneRadio: ", ...)
end


local function _ensureNowPlaying(self)
        if self.npWindow then
                return
        end

        local window = Window("linein")
        self.npStation = Label("text", "")
        self.npStatus = Label("nptrack", "")
        self.npArtwork = Icon("icon_linein")

        window:addWidget(Group("title", {
                lbutton = window:createDefaultLeftButton(),
                text = self.npStation,
                rbutton = nil,
        }))
        window:addWidget(Group("nptitle", {
                nptrack = self.npStatus,
                xofy = nil,
        }))
        window:addWidget(Group("npartwork", {
                artwork = self.npArtwork,
        }))
        window:addListener(EVENT_WINDOW_POP, function()
                self.npVisible = false
        end)

        self.npWindow = window
end


local function _nowPlayingStatus(self, state)
        return self:string("STANDALONE_RADIO_STATE_" .. state)
end


local function _setNowPlayingLogo(self, station)
        if not station or not station.logo then
                return
        end

        self.logoCache = self.logoCache or {}
        local surface = self.logoCache[station.logo]
        if surface == false then
                return
        end

        if not surface then
                local imagePath = "applets/StandaloneRadio/" .. station.logo
                local ok, loaded = pcall(function()
                        return Surface:loadImage(imagePath)
                end)
                if not ok or not loaded then
                        self.logoCache[station.logo] = false
                        log:warn("StandaloneRadio: unable to load logo ", imagePath)
                        return
                end
                surface = loaded
                self.logoCache[station.logo] = surface
        end

        self.npArtwork:setValue(surface)
        _logInfo("logo=", station.logo)
end


local function _updateNowPlaying(self, station, state, show)
        _ensureNowPlaying(self)

        if station then
                self.npStation:setValue(self:string(station.nameToken))
                _setNowPlayingLogo(self, station)
        end
        self.npStatus:setValue(_nowPlayingStatus(self, state))
        self.playbackState = state

        if show then
                if Framework:isWindowInStack(self.npWindow) then
                        self.npWindow:moveToTop()
                else
                        self.npWindow:show()
                end
                self.npVisible = true
        end
end


function updateNowPlayingMetadata(self, title)
        self.currentMetadata = title
        if self.npStatus then
                self.npStatus:setValue(title)
        end
        _logInfo("StreamTitle=", title)
end


local function _handleMetadata(self, data)
        if not self.lastStation or not self.isPlaying or type(data) ~= "string" then
                return
        end

        local title = string.match(data, "StreamTitle='(.-)';")
                or string.match(data, 'StreamTitle="(.-)";')
        if not title then
                return
        end

        title = string.gsub(title, "%z.*", "")
        title = string.gsub(title, "^%s*(.-)%s*$", "%1")
        if title ~= "" and title ~= self.currentMetadata then
                self:updateNowPlayingMetadata(title)
        end
end


local function _installMetadataHooks(self, playback)
        if self.metadataHooksInstalled then
                return
        end

        local originalHeaders = playback._streamHttpHeaders
        playback._streamHttpHeaders = function(instance, headers)
                originalHeaders(instance, headers)

                local headerText = type(headers) == "string" and headers or tostring(headers)
                local interval = tonumber(string.match(string.lower(headerText), "icy%-metaint:%s*(%d+)"))
                if interval and interval > 0 then
                        Stream:icyMetaInterval(interval)
                        _logInfo("icy-metaint=", tostring(interval))
                end
        end

        local slimproto = playback.slimproto
        local originalSend = slimproto.send
        slimproto.send = function(proto, packet, force)
                if type(packet) == "table" and packet.opcode == "META" then
                        _handleMetadata(self, packet.data)
                end
                return originalSend(proto, packet, force)
        end

        self.metadataHooksInstalled = true
        _logInfo("ICY metadata hooks installed")
end


local function _stopPlayback(self)
	local playback = _playback()
	if not playback then
		decode:stop()
		return false
	end

	_logInfo("stopping")
	playback:stopInternal()
        self.currentMetadata = nil
        if self.lastStation then
                _updateNowPlaying(self, self.lastStation, "STOPPED", false)
        end
        return true
end


-- The firmware's jive.dns bridge fails on this radio, while BusyBox nslookup
-- reliably uses the DHCP-provided resolver in /etc/resolv.conf.
local function _resolveHost(host, callback)
        local output = ""
        local process = Process(jnt, "nslookup " .. host .. " 2>&1")

        process:read(function(chunk, err)
                if chunk then
                        output = output .. chunk
                        return
                end

                -- BusyBox prints the configured DNS server first. Only parse
                -- addresses after the query result's Name: section.
                local result = string.match(output, "Name:[%s%S]*")
                local ip = result and string.match(result, "Address [0-9]+:%s*([0-9]+%.[0-9]+%.[0-9]+%.[0-9]+)")
                if not ip then
                        log:warn("StandaloneRadio: nslookup failed for ", host, ": ", tostring(err or output))
                end
                callback(ip)
        end)
end


local function _statusText(self)
        if not self.lastStation then
                return self:string("STANDALONE_RADIO_STATUS_IDLE")
        end

        local prefix = self.isPlaying and self:string("STANDALONE_RADIO_STATUS_PLAYING")
                or self:string("STANDALONE_RADIO_STATUS_STOPPED")
        return tostring(prefix):gsub("%%s", tostring(self:string(self.lastStation.nameToken)))
end


local function _refreshMenu(self)
        if not self.menuWidget then
                return
        end

        local items = {
                { text = _statusText(self), style = "item", weight = 0 },
        }

        for index, station in ipairs(stations) do
                items[#items + 1] = {
                        text = tostring(index) .. ". " .. tostring(self:string(station.nameToken)),
                        sound = "SELECT",
                        weight = index,
                        callback = function()
                                _startStation(self, station, true)
                        end,
                }
        end

        items[#items + 1] = {
                text = self:string("STANDALONE_RADIO_STOP"),
                sound = "WINDOWHIDE",
                weight = 100,
                callback = function()
                        _stopPlayback(self)
                        self.isPlaying = false
                        _refreshMenu(self)
                end,
        }

        self.menuWidget:setItems(items)
        self.menuWidget:reLayout()
end


function _startStation(self, station, showPopup)
	if self.pendingStation then
		_logInfo("ignoring repeated selection while connecting ", self.pendingStation.id)
		return true
	end

	local playback, player = _playback()
	if not playback then
		log:warn("StandaloneRadio: no playback instance available")
		return
	end
	_installMetadataHooks(self, playback)

	self.pendingStation = station
	self.currentMetadata = nil
	_updateNowPlaying(self, station, "RESOLVING", true)
	local popup = nil

        Task("StandaloneRadioPlay", self, function()
                _logInfo("selected ", station.id)
                _logInfo("resolving ", station.host)

                _resolveHost(station.host, function(ip)
				if not ip then
					self.pendingStation = nil
					_updateNowPlaying(self, station, "FAILED", false)
					return
				end

				_logInfo("resolved to ", tostring(ip))
				_logInfo("connecting port ", tostring(station.port))
				_updateNowPlaying(self, station, "CONNECTING", false)

                        playback:stopInternal()
                        player:incrementSequenceNumber()

                        playback.flags = 0
                        playback.mode = 'm'
				playback.header = "GET " .. station.path .. " HTTP/1.0\n" ..
						"Host: " .. station.host .. "\n" ..
						"User-Agent: SqueezePlay StandaloneRadio\n" ..
						"Icy-MetaData: 1\n" ..
						"Accept: audio/mpeg,*/*\n" ..
                                "Connection: close\n\n"
                        playback.autostart = '1'
                        playback.threshold = 0
                        playback.sentResume = false
                        playback.sentResumeDecoder = false
                        playback.sentDecoderFullEvent = false
                        playback.sentOutputUnderrunEvent = false
                        playback.sentAudioUnderrunEvent = false
                        playback.isLooping = false
                        playback.ignoreStream = false
				playback.decodeThreshold = 2048
				Stream:icyMetaInterval(0)

                        decode:start(string.byte('m'), 0, 0, 0, 0, 0, 0, 0, 0, 0)
				self.lastStation = station
				self.isPlaying = true
				_refreshMenu(self)
				_logInfo("decoder started")
				playback:_streamConnect(ip, station.port)
				self.pendingStation = nil
				_updateNowPlaying(self, station, "PLAYING", false)
				_logInfo("stream connected")
                end)
        end):addTask()
        return true
end


function scheduleStartupTest(self)
	_logInfo("startup self-test scheduled")
	os.remove(AUTOTEST_MARKER)

	local timer = Timer(5000, function()
		_logInfo("startup self-test starting npo1")
		_startStation(self, stations[1], false)
	end, true)

	timer:start()
	self._startupTimer = timer
end


-- Called by the applet metadata at boot so the radio buttons work without
-- first navigating into the menu.
function enableStandaloneMode(self)
        self:_addControlListeners()
end


function menu(self)
	local window = Window("text_list", self:string("STANDALONE_RADIO"))

        local menu = SimpleMenu("menu")
        menu:setComparator(SimpleMenu.itemComparatorWeightAlpha)
        window:addWidget(menu)

        self.menuWidget = menu
        self:enableStandaloneMode()
        _refreshMenu(self)
        window:addListener(EVENT_WINDOW_POP, function()
                self.menuWidget = nil
        end)

        self:tieAndShowWindow(window)
end


function _addControlListeners(self)
        if self.listenerHandles then
                return
        end

        _logInfo("standalone mode controls enabled")
        self.listenerHandles = {}

        table.insert(self.listenerHandles, Framework:addListener(EVENT_KEY_PRESS | EVENT_KEY_HOLD,
                function(event)
                        local keycode = event:getKeycode()
                        if keycode == KEY_PRESET_1 or keycode == KEY_PRESET_2 or keycode == KEY_PRESET_3
                                or keycode == KEY_PRESET_4 or keycode == KEY_PRESET_5 or keycode == KEY_PRESET_6
                                or keycode == KEY_PLAY or keycode == KEY_PAUSE then
                                _logInfo("raw hardware key ", tostring(keycode), " type ", tostring(event:getType()))
                        end
                        return EVENT_UNUSED
                end, -100))

        local function playPreset(_, event, station)
                _logInfo("preset action ", station.id)
                _startStation(self, station, false)
                return EVENT_CONSUME
        end

        for index, station in ipairs(stations) do
                table.insert(self.listenerHandles, Framework:addActionListener("play_preset_" .. index, self,
                        function(_, event) return playPreset(self, event, station) end, -100))
        end

        local function stopAction()
                _stopPlayback(self)
                self.isPlaying = false
                _refreshMenu(self)
                return EVENT_CONSUME
        end
        table.insert(self.listenerHandles, Framework:addActionListener("pause", self, stopAction, -100))
        table.insert(self.listenerHandles, Framework:addActionListener("stop", self, stopAction, -100))
        table.insert(self.listenerHandles, Framework:addActionListener("play", self, function()
                if self.lastStation then
                        _startStation(self, self.lastStation, false)
                end
                return EVENT_CONSUME
        end, -100))
end


function _removeControlListeners(self)
        if not self.listenerHandles then
                return
        end
        for _, handle in ipairs(self.listenerHandles) do
                Framework:removeListener(handle)
        end
        self.listenerHandles = nil
end
