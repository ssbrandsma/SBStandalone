local pairs, pcall, setmetatable, tonumber, tostring, type = pairs, pcall, setmetatable, tonumber, tostring, type
local require = require
local appletManager = appletManager

local math = require("math")
local string = require("string")

local Player = require("jive.slim.Player")
local RequestHttp = require("jive.net.RequestHttp")
local Resolver = require("applets.StandaloneRadio.Resolver")
local SocketHttp = require("jive.net.SocketHttp")
local Stream = require("squeezeplay.stream")
local Framework = require("jive.ui.Framework")
local Task = require("jive.ui.Task")
local Timer = require("jive.ui.Timer")
local UrlTransport = require("applets.StandaloneRadio.UrlTransport")
local OpmlClient = require("applets.StandaloneRadio.OpmlClient")
local HlsMetadata = require("applets.StandaloneRadio.HlsMetadata")
local decode = require("squeezeplay.decode")
local jnt = jnt

module(...)


local StreamPlayer = {}
StreamPlayer.__index = StreamPlayer
local reconnectDelays = { 2000, 5000, 10000, 30000 }
local WATCHDOG_INTERVAL = 30000
local WATCHDOG_STALL_POLLS = 2
local MAX_STREAM_REDIRECTS = 5
local AUDIO_RECOVERY_INTERVAL = 1000
local POWER_KEEPALIVE_INTERVAL = 5 * 60 * 1000
local DECODE_UNDERRUN = (1 << 1)

local CODEC_DECODERS = {
    ["aac_mp4"] = { mode="a", accept="audio/mp4,audio/x-m4a,*/*", sampleSize="5" },
	-- For AAC mode, SqueezePlay overloads the first PCM parameter with the
	-- transport type. Radio Browser's raw AAC streams use ADTS (type 2).
	["aac"] = { mode = "a", accept = "audio/aac,audio/aacp,*/*", sampleSize = "2" },
	["aac+"] = { mode = "a", accept = "audio/aacp,audio/aac,*/*", sampleSize = "2" },
	["ogg"] = { mode = "o", accept = "audio/ogg,application/ogg,*/*" },
	["flac"] = { mode = "f", accept = "audio/flac,audio/x-flac,*/*" },
	["flc"] = { mode = "f", accept = "audio/flac,audio/x-flac,*/*" },
	["aif"] = { mode = "p", accept = "audio/aiff,audio/x-aiff,*/*", sampleSize = "1", sampleRate = "3", channels = "2", endianness = "0" },
	["aiff"] = { mode = "p", accept = "audio/aiff,audio/x-aiff,*/*", sampleSize = "1", sampleRate = "3", channels = "2", endianness = "0" },
	["pcm"] = { mode = "p", accept = "audio/L16,audio/L24,audio/wav,*/*", sampleSize = "1", sampleRate = "3", channels = "2", endianness = "1" },
	["mp3"] = { mode = "m", accept = "audio/mpeg,*/*" },
}


local function decoderFor(station)
	local codec = string.lower(tostring(station and station.codec or "mp3"))
	codec = string.gsub(codec, "^%s*(.-)%s*$", "%1")
	return CODEC_DECODERS[codec] or CODEC_DECODERS["mp3"]
end


local function localPlayback()
	local player = Player:getLocalPlayer() or Player:getCurrentPlayer()
	if not player then
		return nil, nil, "no local player"
	end
	if not player.playback then
		return nil, player, "local player has no playback instance"
	end
	return player.playback, player
end


function new(options)
	local player = setmetatable({
		log = options.log,
		callbacks = options.callbacks,
		lastStation = options.lastStation,
		retryIndex = 1,
		generation = 0,
		stationGeneration = 0,
		state = "STOPPED",
		watchdogStalls = 0,
		audioUnderrunRecovered = false,
		ownsPlayback = false,
		httpsProxyStatus = options.httpsProxyStatus,
	}, StreamPlayer)
	player.resolver = Resolver.new({
		log = options.log,
	})
	player:_startWatchdog()
	player:_startAudioRecovery()
	player:_startPowerKeepalive()
	return player
end


function StreamPlayer:_isCurrent(generation, station)
	return self.generation == generation and self.desiredStation == station
end


function StreamPlayer:_notifyState(station, state, show)
	self.state = state
	self.callbacks.onState(station, state, show, self.stationGeneration)
end


function StreamPlayer:_resetWatchdog()
	self.watchdogBytes = nil
	self.watchdogStalls = 0
end


function StreamPlayer:_resetAudioRecovery()
	self.audioUnderrunRecovered = false
end


local function redirectedStation(station, location)
	local scheme, host, port, path = string.match(location, "^(https?)://([^:/]+):?(%d*)(/.*)$")
	if not host then
		return nil
	end
	local copy = {}
	for key, value in pairs(station) do copy[key] = value end
	copy.host = host
	copy.port = tonumber(port) or (scheme == "https" and 443 or 80)
	copy.path = path
	copy.scheme = scheme
	copy.url = location
	copy.url_resolved = location
	return copy
end


local function transportStation(station, log)
	local url = station and station.url
	if station and station.hls then url = UrlTransport.hlsUrl(url) end
	local target, err = UrlTransport.forRequest(url, log)
	if not target then return nil, err end
	local copy = {}
	for key, value in pairs(station) do copy[key] = value end
	copy.host, copy.port, copy.path = target.host, target.port, target.path
	copy.hostHeader = target.hostHeader
	copy.transportUrl = target.url
	return copy
end


local function responseLocation(headers)
	for name, value in pairs(headers or {}) do
		if string.lower(name) == "location" then
			return value
		end
	end
	return nil
end


function StreamPlayer:_startPowerKeepalive()
	if self.powerKeepaliveTimer then
		return
	end

	self.powerKeepaliveTimer = Timer(POWER_KEEPALIVE_INTERVAL, function()
		self:_powerKeepaliveTick()
	end)
	self.powerKeepaliveTimer:start()
end


function StreamPlayer:_powerKeepaliveTick()
	if not self.playbackActive or self.intentionalStop then
		return
	end

	-- Standalone playback bypasses normal player-mode updates. Keep the native
	-- Radio power manager awake so it does not switch the speaker endpoint off.
	Framework.wakeup()
end


function StreamPlayer:_startWatchdog()
	if self.watchdogTimer then
		return
	end

	self.watchdogTimer = Timer(WATCHDOG_INTERVAL, function()
		self:_watchdogTick()
	end)
	self.watchdogTimer:start()
end


function StreamPlayer:_startAudioRecovery()
	if self.audioRecoveryTimer then
		return
	end

	self.audioRecoveryTimer = Timer(AUDIO_RECOVERY_INTERVAL, function()
		self:_audioRecoveryTick()
	end)
	self.audioRecoveryTimer:start()
end


function StreamPlayer:_audioRecoveryTick()
	if not self.playbackActive or self.intentionalStop or self.paused then
		self:_resetAudioRecovery()
		return
	end

	local okStatus, status = pcall(function()
		return decode:status()
	end)
	if not okStatus or type(status) ~= "table" then
		return
	end

    if self.desiredStation and self.desiredStation.episode then
        if status.decodeState and status.decodeState & ((1 << 2) | (1 << 3)) ~= 0 then self:stop("FAILED");return end
        local position=tonumber(status.elapsed)
        if position and position>=0 then
            position=math.floor(position) -- native decode.status().elapsed is already milliseconds
            self.desiredStation.position_ms=position
            if self.callbacks.onPosition and (not self.lastPosition or math.abs(position-self.lastPosition)>=5000) then
                self.lastPosition=position;self.callbacks.onPosition(position,self.desiredStation,self.stationGeneration)
            end
        end
    end

	local playback = self.hookedPlayback
	local audioUnderrun = status.audioState & DECODE_UNDERRUN ~= 0
	local outputUnderrun = playback and playback.sentOutputUnderrunEvent
	if not audioUnderrun and not outputUnderrun then
		self:_resetAudioRecovery()
	else
		local threshold = tonumber(playback and playback.decodeThreshold) or 2048
		local buffered = tonumber(status.decodeFull) or 0
		if not self.audioUnderrunRecovered and buffered > threshold then
			-- Playback pauses audio after an output underrun and expects LMS to send strm-u.
			-- Its status bit can clear before this timer sees it, but the playback marker
			-- remains set until the native loop observes healthy audio again.
			-- In standalone mode, resume locally once enough stream data has accumulated.
			decode:resumeAudio()
			self.audioUnderrunRecovered = true
			self.log:warn("StandaloneRadio: resumed audio after output underrun")
		end
	end

end


function StreamPlayer:_watchdogTick()
	local station = self.desiredStation
	if not station or self.intentionalStop or self.paused or self.episodeEOF or self.pendingStation or self.reconnectTimer then
		self:_resetWatchdog()
		return
	end

	local playback = localPlayback()
	if not playback then
		self:_resetWatchdog()
		return
	end

	if self.playbackActive and not playback.stream then
		self.log:warn("StandaloneRadio: watchdog found no active stream; reconnecting ", station.id)
		self:_resetWatchdog()
		self:_scheduleReconnect(station, self.generation)
		return
	end

	if not self.playbackActive or not playback.stream then
		self:_resetWatchdog()
		return
	end

	local okStatus, status = pcall(function()
		return decode:status()
	end)
	if not okStatus or type(status) ~= "table" then
		self:_resetWatchdog()
		return
	end

	local bytes = tonumber(status.bytesReceivedL) or tonumber(status.bytesReceived) or 0
	if bytes <= 0 or bytes ~= self.watchdogBytes then
		self.watchdogBytes = bytes
		self.watchdogStalls = 0
		return
	end

	self.watchdogStalls = self.watchdogStalls + 1
	if self.watchdogStalls >= WATCHDOG_STALL_POLLS then
		self.log:warn("StandaloneRadio: watchdog found stalled stream; reconnecting ", station.id)
		self:_resetWatchdog()
		self:_scheduleReconnect(station, self.generation)
	end
end


function StreamPlayer:_cancelReconnect()
	if self.reconnectTimer then
		self.reconnectTimer:stop()
		self.reconnectTimer = nil
	end
end


function StreamPlayer:_stopPlayback()
	local playback = localPlayback()
	if playback then
		self.intentionalStop = true
		playback:stopInternal()
		self.intentionalStop = false
	else
		decode:stop()
	end
end


function StreamPlayer:_handleMetadata(data)
	if not self.desiredStation or not self.playbackActive or type(data) ~= "string" then
		return
	end

	local title = string.match(data, "StreamTitle='(.-)';")
		or string.match(data, 'StreamTitle="(.-)";')
	if not title then
		return
	end

	title = string.gsub(title, "%z.*", "")
	title = string.gsub(title, "^%s*(.-)%s*$", "%1")
	if title == "" then
		if self.currentMetadata ~= nil then
			self.currentMetadata = nil
			self.callbacks.onMetadata(nil, self.desiredStation, self.stationGeneration)
			self:_notifyState(self.desiredStation, "PLAYING", false)
		end
		return
	end

	if title ~= self.currentMetadata then
		self.currentMetadata = title
		self.callbacks.onMetadata(title, self.desiredStation, self.stationGeneration)
		self.log:info("StandaloneRadio: StreamTitle=", title)
	end
end


function StreamPlayer:_scheduleReconnect(station, generation, redirect)
    if station and station.episode and not redirect then self:stop("FAILED");return end
	if not self:_isCurrent(generation, station) or self.reconnectTimer then
		return
	end

	local delay = reconnectDelays[self.retryIndex] or reconnectDelays[#reconnectDelays]
	if self.retryIndex < #reconnectDelays then
		self.retryIndex = self.retryIndex + 1
	end

	self:_notifyState(station, "RECONNECTING", false)
	self.log:warn("StandaloneRadio: reconnecting ", station.id, " in ", tostring(delay), "ms")
	self.reconnectTimer = Timer(delay, function()
		self.reconnectTimer = nil
		if self:_isCurrent(generation, station) then
			self:_begin(station, true)
		end
	end, true)
	self.reconnectTimer:start()
end


function StreamPlayer:_handleDisconnect(reason, flush)
	if self.intentionalStop or flush or not reason or not self.desiredStation then
		return
	end
	if self.hlsMetadata then self.hlsMetadata:stop() end

	local station = self.desiredStation
    if station.episode then
        if reason==0 then self.episodeEOF=true;return end -- FIN: let decoded audio drain
        self.log:warn("StandaloneRadio: episode transfer failed; not restarting from zero")
        self:stop("FAILED");return
    end
	if self.httpsProxyStatus and UrlTransport.isHttps(station.url) then
		self.httpsProxyStatus:transportFailed(station.url)
	end
	local generation = self.generation
	self.playbackActive = false
	self.currentMetadata = nil
	self:_resetWatchdog()
	self:_resetAudioRecovery()
	self:_notifyState(station, "CONNECTION_LOST", false)
	self.log:warn("StandaloneRadio: stream disconnected ", tostring(reason))
	self:_scheduleReconnect(station, generation)
end


function StreamPlayer:_finishRedirectProbe(token, station, callback, failed)
	if self.redirectProbeToken ~= token then
		return
	end
	self.redirectProbeSockets = nil
	self.redirectProbeRequests = nil
	if failed and station and station.hls then station = nil end
	callback(station)
end


function StreamPlayer:_probeStreamRedirect(station, generation, redirectCount, token, callback)
	if self.generation ~= generation or self.redirectProbeToken ~= token then
		return
	end

	local target, targetErr = transportStation(station, self.log)
	if not target then
		self.log:warn("StandaloneRadio: redirect probe transport failed: ", tostring(targetErr))
		self:_finishRedirectProbe(token, station, callback, true)
		return
	end
	self.log:info("StandaloneRadio: redirect probe resolving ", target.host)
	self.resolver:resolve(target.host, function(ip, method, resolveErr)
		if self.generation ~= generation or self.redirectProbeToken ~= token then
			return
		end
		if not ip then
			self.log:warn("StandaloneRadio: redirect probe DNS failed; using current URL: ", tostring(resolveErr))
			self:_finishRedirectProbe(token, station, callback, true)
			return
		end

		local hopDone = false
		local request
		request = RequestHttp(function(body, err)
			if hopDone or self.generation ~= generation or self.redirectProbeToken ~= token then
				return
			end
			hopDone = true
			if target.proxied and self.httpsProxyStatus then self.httpsProxyStatus:transportFailed(station.url) end
			self.log:warn("StandaloneRadio: redirect probe failed; using current URL: ", tostring(err))
			self:_finishRedirectProbe(token, station, callback, true)
		end, "HEAD", target.path, {
			headers = {
				["Host"] = target.hostHeader,
				["Connection"] = "close",
				["User-Agent"] = "SqueezePlay StandaloneRadio",
			},
			headersSink = function(headers)
				if hopDone or self.generation ~= generation or self.redirectProbeToken ~= token then
					return
				end
				hopDone = true
				local status, statusLine = request:t_getResponseStatus()
				local location = responseLocation(headers)
				self.log:info("StandaloneRadio: redirect probe response=", tostring(statusLine))

				-- A local HEAD probe determines the actual elementary codec before
				-- the decoder starts. Directory codec hints are not authoritative.
				local contentType
				for name, value in pairs(headers or {}) do
					if string.lower(name) == "content-type" then contentType = string.lower(value) end
				end
				if not station.hls and status and status >= 200 and status < 300 and contentType and
					(contentType:find("mpegurl", 1, true)) then
					if redirectCount >= MAX_STREAM_REDIRECTS then
						self:_finishRedirectProbe(token, nil, callback); return
					end
					self.playlistResolver = self.playlistResolver or OpmlClient.new({log=self.log, httpsProxyStatus=self.httpsProxyStatus})
					self.playlistResolver:resolveStation(station, function(resolved, err)
						if self.generation ~= generation or self.redirectProbeToken ~= token then return end
						if not resolved or (resolved.url == station.url and not resolved.hls) then
							self.log:warn("StandaloneRadio: MIME playlist resolution failed: ", tostring(err))
							self:_finishRedirectProbe(token, nil, callback); return
						end
						self:_probeStreamRedirect(resolved, generation, redirectCount + 1, token, callback)
					end, true)
					return
				end
				if station.hls then
					if not status or status < 200 or status >= 300 or
						(contentType ~= "audio/aac" and contentType ~= "audio/mpeg") then
						self.log:warn("StandaloneRadio: native HLS probe failed/unsupported status=", tostring(status))
						for name, value in pairs(headers or {}) do
							if string.lower(name) == "x-sb-hls-error" then self.log:warn("StandaloneRadio: HLS: ", tostring(value)) end
						end
						self:_finishRedirectProbe(token, nil, callback)
						return
					end
					local copy = {}
					for key, value in pairs(station) do copy[key] = value end
					copy.codec = contentType == "audio/aac" and "aac" or "mp3"
					self:_finishRedirectProbe(token, copy, callback)
					return
				end

				if status and status >= 300 and status < 400 then
				self.log:info("StandaloneRadio: redirect probe Location=", UrlTransport.redact(location))
					if not location or redirectCount >= MAX_STREAM_REDIRECTS then
						self.log:warn("StandaloneRadio: redirect probe has no usable Location")
						self:_finishRedirectProbe(token, station, callback, true)
						return
					end
					local redirected = redirectedStation(station, location)
					if not redirected then
						self.log:warn("StandaloneRadio: redirect probe ignored non-HTTP Location")
						self:_finishRedirectProbe(token, station, callback, true)
						return
					end
					self:_probeStreamRedirect(redirected, generation, redirectCount + 1, token, callback)
					return
				end

				if status and status >= 200 and status < 300 then
				self.log:info("StandaloneRadio: redirect probe final URL=", UrlTransport.redact(station.url))
					if station.provider then
						local mime=contentType and contentType:match("^[^;]+")
						local codecs={["audio/aac"]="aac",["audio/aacp"]="aac+",["audio/mpeg"]="mp3",["audio/ogg"]="ogg",["application/ogg"]="ogg",["audio/flac"]="flac"}
						if codecs[mime] then
							local copy={};for key,value in pairs(station) do copy[key]=value end
							copy.codec=codecs[mime];station=copy
						end
					end
					self:_finishRedirectProbe(token, station, callback)
					return
				end

				self.log:warn("StandaloneRadio: redirect probe unexpected status; using current URL")
				self:_finishRedirectProbe(token, station, callback, true)
			end,
		})

		-- Firmware 7.7.3 RequestHttp serializes query/params only for GET.
		-- Keep the original encoded request target for this HEAD instance;
		-- do not patch the shared framework or decode signed URL components.
		request.t_getRequestString = function()
			return "HEAD " .. string.match(target.path, "^[^#]*")
		end

		local socket = SocketHttp(jnt, ip, target.port or 80, "StandaloneRadioRedirectProbe")
		self.redirectProbeSockets[#self.redirectProbeSockets + 1] = socket
		self.redirectProbeRequests[#self.redirectProbeRequests + 1] = request
		local ok, fetchErr = pcall(function() socket:fetch(request) end)
		if not ok and not hopDone then
			hopDone = true
			if target.proxied and self.httpsProxyStatus then self.httpsProxyStatus:transportFailed(station.url) end
			self.log:warn("StandaloneRadio: redirect probe could not start: ", tostring(fetchErr))
			self:_finishRedirectProbe(token, station, callback, true)
		end
	end)
end


function StreamPlayer:_resolveStreamRedirect(station, generation, callback)
	if self.playlistResolver and self.playlistResolver.cancelPlaylist then self.playlistResolver:cancelPlaylist() end
	self.redirectProbeToken = (self.redirectProbeToken or 0) + 1
	local token = self.redirectProbeToken
	self.redirectProbeSockets = {}
	self.redirectProbeRequests = {}
	self:_probeStreamRedirect(station, generation, 0, token, callback)
end


-- Metadata is bound to the decoder generation and audio-consumption clock.
function StreamPlayer:_startHlsMetadata(session)
	if not session then return end
	self.hlsMetadata=self.hlsMetadata or HlsMetadata.new({
		current=function(generation)
			return generation==self.generation and self.ownsPlayback and
				self.desiredStation and self.desiredStation.hls and not self.intentionalStop
		end,
		position=function()
			local ok,status=pcall(function() return decode:status() end)
			return ok and type(status)=="table" and tonumber(status.elapsed) or nil
		end,
		update=function(event,generation)
			if generation==self.generation and self.callbacks.onTimedMetadata then
				self.callbacks.onTimedMetadata(event,self.desiredStation,self.stationGeneration)
			end
		end,
	})
	self.hlsMetadata:start(session,self.generation)
end

function StreamPlayer:_installHooks(playback)
	if self.hookedPlayback == playback then
		return
	end

	-- Connection control is not user intent. Only the source chooser's committed
	-- transition may release this decoder; background connect/updateInit/HELO
	-- paths never enter this method. Keep this guard on the actual local player.
	local function handoff(player, server)
		if not self.ownsPlayback or not player or player.playback ~= playback or not server then return end
		local address = server:getIpPort()
		if type(address) ~= "string" or address == "" then return end
		if address == "localhost" or (type(address) == "string" and string.match(address, "^127%.")) then return end
		self.log:info("StandaloneRadio: releasing playback for explicit library selection")
		self:stop()
		self.desiredStation = nil
		if self.callbacks.onHandoff then self.callbacks.onHandoff() end
	end
	local function patchChooser(chooser)
		if type(chooser) ~= "table" or type(chooser._doConnectPlayer) ~= "function" then return false end
		if chooser._standaloneRadioHandoff == chooser._doConnectPlayer and
			chooser._standaloneRadioHandoffOwner == self then return true end
		local originalConnect = chooser._doConnectPlayer
		chooser._doConnectPlayer = function(instance, player, server, ...)
			handoff(player, server)
			return originalConnect(instance, player, server, ...)
		end
		-- Selecting the already-connected library returns before _doConnectPlayer.
		local originalSelect = chooser.selectServer
		if type(originalSelect) == "function" then
			chooser.selectServer = function(instance, server, ...)
				local player = Player:getLocalPlayer()
				if player and player:getSlimServer() == server and player:isConnected() and
					not instance.ignoreServerConnected and not server:isPasswordProtected() and
					(not server:getVersion() or server:isCompatible()) then
					handoff(player, server)
				end
				return originalSelect(instance, server, ...)
			end
		end
		chooser._standaloneRadioHandoff = chooser._doConnectPlayer
		chooser._standaloneRadioHandoffOwner = self
		return true
	end
	-- AppletManager executes loadfile and can replace methods loaded by require.
	-- Its managed instance (including every reopen after free) must be patched.
	local manager = appletManager
	local ok, patched
	if manager and type(manager.loadApplet) == "function" then
		manager._standaloneRadioPatchChooser = patchChooser
		if manager._standaloneRadioChooserLoader ~= manager.loadApplet then
			local originalLoad = manager.loadApplet
			local wrapped = function(instance, name, ...)
				local applet = originalLoad(instance, name, ...)
				if name == "ChooseMusicSource" then instance._standaloneRadioPatchChooser(applet) end
				return applet
			end
			manager.loadApplet = wrapped
			manager._standaloneRadioChooserLoader = wrapped
		end
		ok, patched = pcall(function() return patchChooser(manager:loadApplet("ChooseMusicSource")) end)
	else
		-- Standalone fixtures and alternative Jive loaders without AppletManager.
		ok, patched = pcall(function()
			return patchChooser(require("applets.ChooseMusicSource.ChooseMusicSourceApplet"))
		end)
	end
	if not ok or not patched then
		self.log:warn("StandaloneRadio: source chooser unavailable; automatic handoff disabled")
	end

	-- Playback subscriptions call these methods dynamically. Do not replace the
	-- SlimProto transport or reconnect machinery. isLocal is how stock setVolume
	-- distinguishes physical/controller gain updates from wire audg commands.
	local originalGain = playback._audg
	if originalGain then
		playback._audg = function(instance, data, isLocal)
			if self.ownsPlayback and not isLocal then return end
			return originalGain(instance, data, isLocal)
		end
	end
	for _, name in pairs({"_strm", "_cont", "_aude"}) do
		local original = playback[name]
		if original then
			playback[name] = function(instance, ...)
				if self.ownsPlayback then return end
				return original(instance, ...)
			end
		end
	end

		local originalHeaders = playback._streamHttpHeaders
		playback._streamHttpHeaders = function(instance, headers)
			-- Let the native player parse and accept the response before our
			-- diagnostic/redirect handling examines it.
			originalHeaders(instance, headers)
			local headerText = type(headers) == "string" and headers or tostring(headers)
		local statusLine = string.match(headerText, "^([^\r\n]+)")
			local status = tonumber(string.match(statusLine or "", "^HTTP/%d%.%d%s+(%d%d%d)"))
			if self.desiredStation and (status == 200 or string.match(statusLine or "", "^ICY%s+200")) then
				local lower = string.lower(headerText)
				local contentType = string.match(lower, "\ncontent%-type:%s*([^;%s\r\n]+)")
				local codecs = { ["audio/mpeg"]="mp3", ["audio/mp3"]="mp3",
					["audio/aac"]="aac", ["audio/aacp"]="aac",
					["audio/flac"]="flc", ["audio/x-flac"]="flc",
					["audio/ogg"]="ogg" }
				local bitrate = tonumber(string.match(lower, "\nicy%-br:%s*(%d+)"))
				self.desiredStation.observedAudio = {
					codec = codecs[contentType],
					bitrate_kbps = bitrate and bitrate > 0 and bitrate <= 100000 and bitrate or nil,
				}
			end
			if self.streamTrace then
				local values={}
				for name,value in headerText:gmatch("\r?\n([^:\r\n]+):%s*([^\r\n]*)") do values[name]=value end
				self.streamTrace:headers(status or tonumber((statusLine or ""):match("^ICY%s+(%d+)")),values)
			end
			if self.desiredStation and self.desiredStation.hls and status==200 then
				local session=string.match(string.lower(headerText), "x%-sb%-hls%-session:%s*([0-9a-f]+)")
				self:_startHlsMetadata(session)
			end
			self.log:info("StandaloneRadio: stream response=", tostring(statusLine))
            if self.desiredStation and self.desiredStation.episode and status and status>=400 then self:stop("FAILED");return end
			local location = string.match(headerText, "[Ll]ocation:%s*([^\r\n]+)")
			if status and status >= 300 and status < 400 and location then
				self.log:info("StandaloneRadio: stream redirect location=", UrlTransport.redact(location))
			if self.redirectCount >= MAX_STREAM_REDIRECTS then
				self.log:warn("StandaloneRadio: too many stream redirects")
				return
			end
			local redirected = redirectedStation(self.desiredStation, location)
			if not redirected then
				self.log:warn("StandaloneRadio: ignoring non-HTTP stream redirect")
				return
			end
			self.redirectCount = self.redirectCount + 1
			self.desiredStation = redirected
			self.retryIndex = 1
			self:_scheduleReconnect(redirected, self.generation, true)
			return
			elseif status and status >= 200 and status < 300 then
				self.redirectCount = 0
			end
			local interval = tonumber(string.match(string.lower(headerText), "icy%-metaint:%s*(%d+)"))
		if interval and interval > 0 then
			Stream:icyMetaInterval(interval)
			self.log:info("StandaloneRadio: icy-metaint=", tostring(interval))
		end

		if self.desiredStation and not self.intentionalStop then
			self.playbackActive = true
			self:_powerKeepaliveTick()
			self.retryIndex = 1
			self:_notifyState(self.desiredStation, "PLAYING", false)
			self.callbacks.onConnected(self.desiredStation, self.stationGeneration)
		end
	end

	local slimproto = playback.slimproto
	local originalSend = slimproto.send
	slimproto.send = function(proto, packet, force)
		local opcode = type(packet) == "table" and packet.opcode or nil
		-- HELO is connection control, not standalone stream metadata. Suppressing
		-- it makes both local sbbase and an external LMS time out the connection.
		if opcode == "HELO" then
			return originalSend(proto, packet, force)
		end
        if self.ownsPlayback and self.desiredStation and self.desiredStation.episode and opcode=="STAT" then
            if packet.event=="STMu" then self:stop();return true end -- audio drained, not merely network EOF
            if packet.event=="STMn" then self:stop("FAILED");return true end
        end
		if type(packet) == "table" and packet.opcode == "META" then
			self:_handleMetadata(packet.data)
		end
		-- Keep the loopback LMS session alive while standalone audio owns the
		-- decoder. STAT carries both the periodic SlimProto heartbeat and benign
		-- playback state updates; StandaloneBase consumes these locally. Other
		-- packets remain suppressed so an unrelated LMS cannot control this
		-- independently managed stream.
		if self.ownsPlayback and not (type(packet) == "table" and packet.opcode == "STAT") then
			return true
		end
		return originalSend(proto, packet, force)
	end

	local originalDisconnect = playback._streamDisconnect
	playback._streamDisconnect = function(instance, reason, flush)
		if self.streamTrace then self.streamTrace:finish(tostring(reason or "disconnected"),"unknown") end
		originalDisconnect(instance, reason, flush)
		self:_handleDisconnect(reason, flush)
	end

	self.hookedPlayback = playback
	self.log:info("StandaloneRadio: ICY and disconnect hooks installed")
end


function StreamPlayer:_begin(station, reconnect)
    self.paused=false;self.episodeEOF=false;self.lastPosition=nil
    if station.episode then station.position_ms=0 end
	if self.hlsMetadata then self.hlsMetadata:stop() end
	self:_cancelReconnect()
	self.ownsPlayback = true
	self.generation = self.generation + 1
	local generation = self.generation
	self.desiredStation = station
	station.observedAudio = nil
	self.redirectCount = self.redirectCount or 0
	self.pendingStation = station
	self.currentMetadata = nil
	self.playbackActive = false
	self:_resetWatchdog()
	self:_resetAudioRecovery()
	if not reconnect then
		self.stationGeneration = self.stationGeneration + 1
		self.retryIndex = 1
		self.redirectCount = 0
		self.lastStation = station
		self.callbacks.onSelected(station, self.stationGeneration)
	end

	local playback, player, err = localPlayback()
	if not playback then
		self.ownsPlayback = false
		self.pendingStation = nil
		self:_notifyState(station, "FAILED", true)
		self.log:warn("StandaloneRadio: ", err)
		return false
	end
	-- Audio is always started on this Radio's local decoder. Keep the UI's
	-- library chooser on that same player instead of a remembered remote/orphan
	-- player. Background stream recovery must not change a user's selection.
	if not reconnect and Player:getCurrentPlayer() ~= player then
		self.log:info("StandaloneRadio: selecting the local playback owner")
		Player:setCurrentPlayer(player)
	end
	self:_installHooks(playback)
	-- Do not disconnect SlimProto here. StandaloneBase is a loopback-only LMS;
	-- retaining its session preserves the current player identity and lets the
	-- stock Home/Now Playing UI continue to receive server state.
	self:_notifyState(station, "RESOLVING", true)

	self:_resolveStreamRedirect(station, generation, function(playStation)
		if self.generation ~= generation then
			return
		end
		if not playStation then
			self.ownsPlayback = false
			self.pendingStation = nil
			self:_notifyState(station, "FAILED", false)
			return
		end
		self.desiredStation = playStation
		self.pendingStation = playStation
		Task("StandaloneRadioPlay", self, function()
		local networkStation, transportErr = transportStation(playStation, self.log)
		if not networkStation then
			self.log:warn("StandaloneRadio: playback transport failed: ", tostring(transportErr))
			self:_notifyState(playStation, "FAILED", false)
			return
		end
		self.log:info("StandaloneRadio: selected ", playStation.id)
		self.log:info("StandaloneRadio: resolving playback host ", networkStation.host)
		local trace=UrlTransport.beginTrace and UrlTransport.beginTrace("radio-stream:"..tostring(playStation.id),playStation.url)
		self.resolver:resolve(networkStation.host, function(ip)
			if not self:_isCurrent(generation, playStation) then
				if trace then trace:finish("cancelled","unknown") end
				return
			end
			if not ip then
				if trace then trace:finish("DNS failed: "..networkStation.host,"unknown") end
				self.pendingStation = nil
				self:_notifyState(playStation, "FAILED", false)
				if reconnect then
					self:_scheduleReconnect(playStation, generation)
				end
				return
			end

			self:_notifyState(playStation, "CONNECTING", false)
			self.intentionalStop = true
			playback:stopInternal()
			self.intentionalStop = false
			self.streamTrace=trace
			player:incrementSequenceNumber()

			local decoder = decoderFor(playStation)
			playback.flags = 0
			playback.mode = decoder.mode
			playback.header = "GET " .. networkStation.path .. " HTTP/1.0\r\n" ..
				"Host: " .. networkStation.hostHeader .. "\r\n" ..
				"User-Agent: SqueezePlay StandaloneRadio\r\n" ..
				(trace and ("X-SB-Trace-Id: "..trace.id.."\r\n") or "") ..
				"Icy-MetaData: 1\r\n" ..
				"Accept: " .. decoder.accept .. "\r\n" ..
				(playStation.hls and ("X-SB-HLS-Codec: " .. (decoder.mode == "a" and "aac" or "mp3") .. "\r\n") or "") ..
				"Cache-Control: no-cache\r\n\r\n"
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

			decode:start(
				string.byte(decoder.mode), 0, 0, 0, 0, 0, 0,
				string.byte(decoder.sampleSize or "0"),
				string.byte(decoder.sampleRate or "0"),
				string.byte(decoder.channels or "0"),
				string.byte(decoder.endianness or "0")
			)
			self.pendingStation = nil
			self.log:info("StandaloneRadio: decoder started codec=", tostring(playStation.codec), " mode=", decoder.mode)
			playback:_streamConnect(ip, networkStation.port)
		end)
		end):addTask()
	end)
	return true
end


function StreamPlayer:start(station)
	return self:_begin(station, false)
end


function StreamPlayer:stop(state)
    self.paused=false;self.episodeEOF=false;self.lastPosition=nil
	if self.hlsMetadata then self.hlsMetadata:stop() end
	if self.playlistResolver and self.playlistResolver.cancelPlaylist then self.playlistResolver:cancelPlaylist() end
	self.generation = self.generation + 1
	self.ownsPlayback = false
	self:_cancelReconnect()
	self.pendingStation = nil
	self.currentMetadata = nil
	self.playbackActive = false
	self:_resetWatchdog()
	self:_resetAudioRecovery()
	self:_stopPlayback()
	if self.lastStation then
		self:_notifyState(self.lastStation, state or "STOPPED", false)
	end
	self.log:info("StandaloneRadio: stopped")
end


function StreamPlayer:stopConnecting()
	if self.playbackActive then
		self.log:info("StandaloneRadio: back ignored; stream is playing")
		return false
	end
	if not self.desiredStation and not self.pendingStation and not self.reconnectTimer then
		return false
	end

	self.log:info("StandaloneRadio: back cancels pending connection")
	self:stop()
	return true
end


function StreamPlayer:pause()
    if not self.desiredStation or not self.desiredStation.episode then return self:stop() end
    if not self.playbackActive or self.paused then return end
    self.paused=true;decode:pauseAudio(0)
    self:_notifyState(self.desiredStation,"PAUSED",false)
end

function StreamPlayer:play()
    if self.paused and self.desiredStation and self.desiredStation.episode then
        self.paused=false;decode:resumeAudio();self:_notifyState(self.desiredStation,"PLAYING",false);return true
    end
	if self.desiredStation then
		return self:start(self.desiredStation)
	end
	if self.lastStation then
		return self:start(self.lastStation)
	end
	return false
end


function StreamPlayer:getCurrentStation()
	return self.desiredStation or self.lastStation
end


function StreamPlayer:isPlaying()
	return self.playbackActive and not self.paused
end
