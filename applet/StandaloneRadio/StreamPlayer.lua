local pcall, setmetatable, tonumber, tostring, type = pcall, setmetatable, tonumber, tostring, type

local string = require("string")

local Player = require("jive.slim.Player")
local Resolver = require("applets.StandaloneRadio.Resolver")
local Stream = require("squeezeplay.stream")
local Task = require("jive.ui.Task")
local Timer = require("jive.ui.Timer")
local decode = require("squeezeplay.decode")

module(...)


local StreamPlayer = {}
StreamPlayer.__index = StreamPlayer
local reconnectDelays = { 2000, 5000, 10000, 30000 }
local WATCHDOG_INTERVAL = 30000
local WATCHDOG_STALL_POLLS = 2
local AUDIO_RECOVERY_INTERVAL = 1000
local DECODE_UNDERRUN = (1 << 1)


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
	}, StreamPlayer)
	player.resolver = Resolver.new({
		log = options.log,
	})
	player:_startWatchdog()
	player:_startAudioRecovery()
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

	if status.audioState & DECODE_UNDERRUN == 0 then
		self:_resetAudioRecovery()
		return
	end

	local threshold = tonumber(self.hookedPlayback and self.hookedPlayback.decodeThreshold) or 2048
	local buffered = tonumber(status.decodeFull) or 0
	if self.audioUnderrunRecovered or buffered <= threshold then
		return
	end

	-- Playback pauses audio after an output underrun and expects LMS to send strm-u.
	-- In standalone mode, resume it locally once enough stream data has accumulated.
	decode:resumeAudio()
	self.audioUnderrunRecovered = true
	self.log:warn("StandaloneRadio: resumed audio after output underrun")
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


function StreamPlayer:_installHooks(playback)
	if self.hookedPlayback == playback then
		return
	end

	local originalHeaders = playback._streamHttpHeaders
	playback._streamHttpHeaders = function(instance, headers)
		originalHeaders(instance, headers)

		local headerText = type(headers) == "string" and headers or tostring(headers)
		local interval = tonumber(string.match(string.lower(headerText), "icy%-metaint:%s*(%d+)"))
		if interval and interval > 0 then
			Stream:icyMetaInterval(interval)
			self.log:info("StandaloneRadio: icy-metaint=", tostring(interval))
		end

		if self.desiredStation and not self.intentionalStop then
			self.playbackActive = true
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
	self.generation = self.generation + 1
	local generation = self.generation
	self.desiredStation = station
	self.pendingStation = station
	self.currentMetadata = nil
	self.playbackActive = false
	self:_resetWatchdog()
	self:_resetAudioRecovery()
	if not reconnect then
		self.retryIndex = 1
		self.lastStation = station
		self.callbacks.onSelected(station)
	end

	local playback, player, err = localPlayback()
	if not playback then
		self.pendingStation = nil
		self:_notifyState(station, "FAILED", true)
		self.log:warn("StandaloneRadio: ", err)
		return false
	end
	self:_installHooks(playback)
	self:_notifyState(station, "RESOLVING", true)

	Task("StandaloneRadioPlay", self, function()
		self.log:info("StandaloneRadio: selected ", station.id)
		self.log:info("StandaloneRadio: resolving ", station.host)
		self.resolver:resolve(station.host, function(ip)
			if not self:_isCurrent(generation, station) then
				return
			end
			if not ip then
				self.pendingStation = nil
				self:_notifyState(station, "FAILED", false)
				if reconnect then
					self:_scheduleReconnect(station, generation)
				end
				return
			end

			self:_notifyState(station, "CONNECTING", false)
			self.intentionalStop = true
			playback:stopInternal()
			self.intentionalStop = false
			player:incrementSequenceNumber()

			playback.flags = 0
			playback.mode = 'm'
			playback.header = "GET " .. station.path .. " HTTP/1.0\n" ..
				"Host: " .. station.host .. "\n" ..
				"User-Agent: SqueezePlay StandaloneRadio\n" ..
				"Icy-MetaData: 1\n" ..
				"Accept: audio/mpeg,*/*\n" ..
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

			decode:start(string.byte('m'), 0, 0, 0, 0, 0, 0, 0, 0, 0)
			self.pendingStation = nil
			self.log:info("StandaloneRadio: decoder started")
			playback:_streamConnect(ip, station.port)
		end)
	end):addTask()
	return true
end


function StreamPlayer:start(station)
	return self:_begin(station, false)
end


function StreamPlayer:stop()
	self.generation = self.generation + 1
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


function StreamPlayer:getLastStation()
	return self.lastStation
end


function StreamPlayer:getCurrentStation()
	return self.desiredStation or self.lastStation
end


function StreamPlayer:getState()
	return self.state
end


function StreamPlayer:isPlaying()
	return self.playbackActive
end
