local pairs, pcall, setmetatable, tonumber, tostring, type = pairs, pcall, setmetatable, tonumber, tostring, type

local string = require("string")

local Player = require("jive.slim.Player")
local RequestHttp = require("jive.net.RequestHttp")
local Resolver = require("applets.StandaloneRadio.Resolver")
local SocketHttp = require("jive.net.SocketHttp")
local Stream = require("squeezeplay.stream")
local Framework = require("jive.ui.Framework")
local Task = require("jive.ui.Task")
local Timer = require("jive.ui.Timer")
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


local function forceHttpUrl(url)
	url = tostring(url or "")
	if string.lower(string.sub(url, 1, 8)) == "https://" then
		return "http://" .. string.sub(url, 9)
	end
	return url
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
		state = "STOPPED",
		watchdogStalls = 0,
		audioUnderrunRecovered = false,
		ownsPlayback = false,
		forceHttp = options.forceHttp == true,
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
	self.callbacks.onState(station, state, show)
end


function StreamPlayer:_resetWatchdog()
	self.watchdogBytes = nil
	self.watchdogStalls = 0
end


function StreamPlayer:_resetAudioRecovery()
	self.audioUnderrunRecovered = false
end


function StreamPlayer:setForceHttp(forceHttp)
	self.forceHttp = forceHttp == true
end


local function redirectedStation(station, location, forceHttp)
	if forceHttp then location = forceHttpUrl(location) end
	local host, port, path = string.match(location, "^http://([^:/]+):?(%d*)(/.*)$")
	if not host then
		return nil
	end
	local copy = {}
	for key, value in pairs(station) do copy[key] = value end
	copy.host = host
	copy.port = tonumber(port) or 80
	copy.path = path
	copy.url = location
	copy.url_resolved = location
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
	if not self.playbackActive or self.intentionalStop then
		self:_resetAudioRecovery()
		return
	end

	local okStatus, status = pcall(function()
		return decode:status()
	end)
	if not okStatus or type(status) ~= "table" then
		return
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
	if not station or self.intentionalStop or self.pendingStation or self.reconnectTimer then
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
			self:_notifyState(self.desiredStation, "PLAYING", false)
		end
		return
	end

	if title ~= self.currentMetadata then
		self.currentMetadata = title
		self.callbacks.onMetadata(title)
		self.log:info("StandaloneRadio: StreamTitle=", title)
	end
end


function StreamPlayer:_scheduleReconnect(station, generation)
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

	local station = self.desiredStation
	local generation = self.generation
	self.playbackActive = false
	self.currentMetadata = nil
	self:_resetWatchdog()
	self:_resetAudioRecovery()
	self:_notifyState(station, "CONNECTION_LOST", false)
	self.log:warn("StandaloneRadio: stream disconnected ", tostring(reason))
	self:_scheduleReconnect(station, generation)
end


function StreamPlayer:_finishRedirectProbe(token, station, callback)
	if self.redirectProbeToken ~= token then
		return
	end
	self.redirectProbeSockets = nil
	self.redirectProbeRequests = nil
	callback(station)
end


function StreamPlayer:_probeStreamRedirect(station, generation, redirectCount, token, callback)
	if self.generation ~= generation or self.redirectProbeToken ~= token then
		return
	end

	self.log:info("StandaloneRadio: redirect probe resolving ", station.host)
	self.resolver:resolve(station.host, function(ip, method, resolveErr)
		if self.generation ~= generation or self.redirectProbeToken ~= token then
			return
		end
		if not ip then
			self.log:warn("StandaloneRadio: redirect probe DNS failed; using current URL: ", tostring(resolveErr))
			self:_finishRedirectProbe(token, station, callback)
			return
		end

		local hopDone = false
		local request
		request = RequestHttp(function(body, err)
			if hopDone or self.generation ~= generation or self.redirectProbeToken ~= token then
				return
			end
			hopDone = true
			self.log:warn("StandaloneRadio: redirect probe failed; using current URL: ", tostring(err))
			self:_finishRedirectProbe(token, station, callback)
		end, "HEAD", station.path, {
			headers = {
				["Host"] = station.host .. ((station.port and station.port ~= 80) and (":" .. tostring(station.port)) or ""),
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

				if status and status >= 300 and status < 400 then
					self.log:info("StandaloneRadio: redirect probe Location=", tostring(location))
					if not location or redirectCount >= MAX_STREAM_REDIRECTS then
						self.log:warn("StandaloneRadio: redirect probe has no usable Location")
						self:_finishRedirectProbe(token, station, callback)
						return
					end
					local redirected = redirectedStation(station, location, self.forceHttp)
					if not redirected then
						self.log:warn("StandaloneRadio: redirect probe ignored non-HTTP Location")
						self:_finishRedirectProbe(token, station, callback)
						return
					end
					self:_probeStreamRedirect(redirected, generation, redirectCount + 1, token, callback)
					return
				end

				if status and status >= 200 and status < 300 then
					self.log:info("StandaloneRadio: redirect probe final URL=", tostring(station.url))
					self:_finishRedirectProbe(token, station, callback)
					return
				end

				self.log:warn("StandaloneRadio: redirect probe unexpected status; using current URL")
				self:_finishRedirectProbe(token, station, callback)
			end,
		})

		local socket = SocketHttp(jnt, ip, station.port or 80, "StandaloneRadioRedirectProbe")
		self.redirectProbeSockets[#self.redirectProbeSockets + 1] = socket
		self.redirectProbeRequests[#self.redirectProbeRequests + 1] = request
		local ok, fetchErr = pcall(function() socket:fetch(request) end)
		if not ok and not hopDone then
			hopDone = true
			self.log:warn("StandaloneRadio: redirect probe could not start: ", tostring(fetchErr))
			self:_finishRedirectProbe(token, station, callback)
		end
	end)
end


function StreamPlayer:_resolveStreamRedirect(station, generation, callback)
	self.redirectProbeToken = (self.redirectProbeToken or 0) + 1
	local token = self.redirectProbeToken
	self.redirectProbeSockets = {}
	self.redirectProbeRequests = {}
	self:_probeStreamRedirect(station, generation, 0, token, callback)
end


function StreamPlayer:_installHooks(playback)
	if self.hookedPlayback == playback then
		return
	end

		local originalHeaders = playback._streamHttpHeaders
		playback._streamHttpHeaders = function(instance, headers)
			-- Let the native player parse and accept the response before our
			-- diagnostic/redirect handling examines it.
			originalHeaders(instance, headers)
			local headerText = type(headers) == "string" and headers or tostring(headers)
		local statusLine = string.match(headerText, "^([^\r\n]+)")
			local status = tonumber(string.match(statusLine or "", "^HTTP/%d%.%d%s+(%d%d%d)"))
			self.log:info("StandaloneRadio: stream response=", tostring(statusLine))
			local location = string.match(headerText, "[Ll]ocation:%s*([^\r\n]+)")
			if status and status >= 300 and status < 400 and location then
				self.log:info("StandaloneRadio: stream redirect location=", location)
			if self.redirectCount >= MAX_STREAM_REDIRECTS then
				self.log:warn("StandaloneRadio: too many stream redirects")
				return
			end
			local redirected = redirectedStation(self.desiredStation, location, self.forceHttp)
			if not redirected then
				self.log:warn("StandaloneRadio: ignoring non-HTTP stream redirect")
				return
			end
			self.redirectCount = self.redirectCount + 1
			self.desiredStation = redirected
			self.retryIndex = 1
			self:_scheduleReconnect(redirected, self.generation)
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
			self.callbacks.onConnected(self.desiredStation)
		end
	end

	local slimproto = playback.slimproto
	local originalSend = slimproto.send
	slimproto.send = function(proto, packet, force)
		if type(packet) == "table" and packet.opcode == "META" then
			self:_handleMetadata(packet.data)
		end
		-- Standalone playback has no LMS command loop to consume status events.
		-- Forwarding them to a stale server blocks SqueezePlay's shared network
		-- thread and can starve the radio stream until the output is paused.
		if self.ownsPlayback then
			return true
		end
		return originalSend(proto, packet, force)
	end

	local originalDisconnect = playback._streamDisconnect
	playback._streamDisconnect = function(instance, reason, flush)
		originalDisconnect(instance, reason, flush)
		self:_handleDisconnect(reason, flush)
	end

	self.hookedPlayback = playback
	self.log:info("StandaloneRadio: ICY and disconnect hooks installed")
end


function StreamPlayer:_begin(station, reconnect)
	self:_cancelReconnect()
	if self.forceHttp and string.lower(string.sub(tostring(station and station.url or ""), 1, 8)) == "https://" then
		station = redirectedStation(station, station.url, true)
		if not station then
			self.log:warn("StandaloneRadio: could not force stream URL to HTTP")
			return false
		end
	end
	self.ownsPlayback = true
	self.generation = self.generation + 1
	local generation = self.generation
	self.desiredStation = station
	self.redirectCount = self.redirectCount or 0
	self.pendingStation = station
	self.currentMetadata = nil
	self.playbackActive = false
	self:_resetWatchdog()
	self:_resetAudioRecovery()
	if not reconnect then
		self.retryIndex = 1
		self.redirectCount = 0
		self.lastStation = station
		self.callbacks.onSelected(station)
	end

	local playback, player, err = localPlayback()
	if not playback then
		self.ownsPlayback = false
		self.pendingStation = nil
		self:_notifyState(station, "FAILED", true)
		self.log:warn("StandaloneRadio: ", err)
		return false
	end
	self:_installHooks(playback)
	-- Drop queued writes to a previous LMS/bootstrap connection before the
	-- standalone stream starts using the same network event loop.
	if playback.slimproto then
		playback.slimproto:disconnect()
	end
	self:_notifyState(station, "RESOLVING", true)

	self:_resolveStreamRedirect(station, generation, function(playStation)
		if self.generation ~= generation then
			return
		end
		self.desiredStation = playStation
		self.pendingStation = playStation
		Task("StandaloneRadioPlay", self, function()
		self.log:info("StandaloneRadio: selected ", playStation.id)
		self.log:info("StandaloneRadio: resolving playback host ", playStation.host)
		self.resolver:resolve(playStation.host, function(ip)
			if not self:_isCurrent(generation, playStation) then
				return
			end
			if not ip then
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
			player:incrementSequenceNumber()

			local decoder = decoderFor(playStation)
			playback.flags = 0
			playback.mode = decoder.mode
			playback.header = "GET " .. playStation.path .. " HTTP/1.0\n" ..
				"Host: " .. playStation.host .. "\n" ..
				"User-Agent: SqueezePlay StandaloneRadio\n" ..
				"Icy-MetaData: 1\n" ..
				"Accept: " .. decoder.accept .. "\n" ..
				"Cache-Control: no-cache\n\n"
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
			playback:_streamConnect(ip, playStation.port)
		end)
		end):addTask()
	end)
	return true
end


function StreamPlayer:start(station)
	return self:_begin(station, false)
end


function StreamPlayer:stop()
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
		self:_notifyState(self.lastStation, "STOPPED", false)
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


function StreamPlayer:play()
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
	return self.playbackActive
end
