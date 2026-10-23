local pcall, setmetatable, tonumber, tostring, type = pcall, setmetatable, tonumber, tostring, type
local string = require("string")

local okHttp, RequestHttp = pcall(require, "jive.net.RequestHttp")
local okSocket, SocketHttp = pcall(require, "jive.net.SocketHttp")
local okTimer, Timer = pcall(require, "jive.ui.Timer")
local okLtn12, ltn12 = pcall(require, "ltn12")
local okJson, json = pcall(require, "json")
local StreamMetadata = require("applets.StandaloneRadio.StreamMetadata")
local UrlTransport = require("applets.StandaloneRadio.UrlTransport")
local jnt = jnt

module(...)

local Client = {}
Client.__index = Client

local HEARTBEAT_MS = 45000
local REQUEST_TIMEOUT_MS = 15000
local MAX_RESPONSE_BYTES = 16 * 1024
local RETRY_MS = { 2000, 5000, 10000, 30000 }

local STATE_MAP = {
	RESOLVING = "buffering", CONNECTING = "buffering",
	RECONNECTING = "buffering", CONNECTION_LOST = "buffering",
	PLAYING = "playing", FAILED = "error", STOPPED = "stopped",
}

local function trim(value)
	return tostring(value or ""):gsub("^%s*(.-)%s*$", "%1")
end

local function metadataText(value, maximum)
	if type(value) ~= "string" or value == "" or #value >= maximum then return nil end
	return value
end

local function safeStationId(station)
	local uuid = trim(station and station.stationuuid)
	if uuid ~= "" then return "radio:" .. trim(station.source or "station") .. ":" .. uuid end
	local id = trim(station and station.id)
	local name = trim(station and station.name)
	if id ~= "" and (id ~= name or station.source == "radiobrowser" or station.source == "radiofeeds") then
		return "radio:" .. id
	end
	-- Legacy/custom stations should normally already have an id from Stations,
	-- but use a bounded deterministic URL hash rather than credentials or name.
	local url = tostring(station and (station.playlistUrl or station.url) or "")
	url = string.gsub(url, "//[^/@]+@", "//")
	local hash = 5381
	for i = 1, #url do hash = (hash * 33 + string.byte(url, i)) % 2147483647 end
	return "radio:url:" .. tostring(hash)
end

local function stationName(station)
	return trim(station and (station.name or station.id or station.nameToken))
end

local function falseCapabilities()
	return { play=false, pause=false, stop=false, next=false, previous=false, seek=false, volume=false }
end

function new(options)
	options = options or {}
	local client = setmetatable({
		log = options.log,
		debug = options.debug == true,
		host = options.host or "127.0.0.1",
		port = options.port or 9000,
		requestFn = options.request,
		timerFactory = options.timerFactory,
		isPlaybackOwner = options.isPlaybackOwner,
		onPublished = options.onPublished,
		retryIndex = 1,
		revision = 0,
		publishedRevision = -1,
		requestSerial = 0,
		stationGeneration = 0,
	}, Client)
	return client
end

function Client:_log(level, ...)
	if self.log and self.log[level] then self.log[level](self.log, "StandaloneRadio NowPlayingAPI: ", ...) end
end

function Client:_debug(...)
	if self.debug then self:_log("info", ...) end
end

function Client:_timer(delay, callback, once)
	if self.timerFactory then return self.timerFactory(delay, callback, once) end
	if not okTimer then return nil end
	return Timer(delay, callback, once)
end

function Client:_stopTimer(name)
	local timer = self[name]
	self[name] = nil
	if timer and timer.stop then timer:stop() end
end

function Client:_bump()
	self.revision = self.revision + 1
end

function Client:_snapshot()
	local station = self.station
	if not station then return nil end
	local title, artist = StreamMetadata.parse(self.metadata)
	if self.timedMetadata then title=self.timedMetadata.title; artist=self.timedMetadata.artist end
	local artwork = self.trackArtwork or self.stationArtwork
	local declaredCodec=station.codec
	if station.provider then declaredCodec=station.declaredCodec end
	return {
		state = self.desiredState or "buffering",
		live = true,
		position_ms = 0,
		-- Directory values are declared station properties, not measured stream
		-- quality. Keep them separate from observed track.audio values.
		station = {
			id = safeStationId(station), name = stationName(station),
			description = metadataText(station.description or station.programDescription, 256),
			homepage = metadataText(station.homepage, 384),
			country = metadataText(station.country or station.countrycode, 96),
			language = metadataText(station.language, 96),
			genre = metadataText(station.tags or station.genre, 256),
			logo = metadataText(self.stationArtwork, 384),
			stream_url = metadataText(station.url, 384),
			audio = {
				codec = metadataText(declaredCodec, 32),
				bitrate_kbps = tonumber(station.bitrate),
			},
		},
		track = {
			id = safeStationId(station),
			station = stationName(station),
			title = title or station.catalogPlaying or "",
			artist = artist or "",
			album = self.timedMetadata and self.timedMetadata.album or "",
			artwork_url = artwork,
			audio = station.observedAudio or {},
		},
	}
end

-- RequestHttp historically considers only status 200 successful. Override its
-- response dispatch per request so the API's standards-compliant 201 claim
-- response remains available without patching SqueezePlay globally.
function Client:_nativeRequest(method, path, payload, callback)
	if not (okHttp and okSocket and okLtn12 and okJson) then
		callback(nil, nil, "HTTP/JSON support unavailable")
		return
	end
	local body = payload and json.encode(payload) or ""
	local completed = false
	local request
	local function finish(status, response, err)
		if completed then return end
		completed = true
		callback(status, response, err)
	end
	request = RequestHttp(function(response, err)
		local status = request:t_getResponseStatus()
		if err then finish(status, nil, tostring(err)); return end
		if response == nil then return end
		finish(status, response, nil)
	end, method, path, {
		t_bodySource = method == "POST" and ltn12.source.string(body) or nil,
		headers = {
			Host = self.host .. ":" .. tostring(self.port),
			["Content-Type"] = "application/json",
			["Content-Length"] = tostring(#body),
			Accept = "application/json", Connection = "close",
		},
	})
	request.t_setResponseBody = function(instance, response)
		local status = instance:t_getResponseStatus()
		if type(response) == "string" and #response > MAX_RESPONSE_BYTES then
			finish(status, nil, "response too large")
		else
			finish(status, response or "", nil)
		end
	end
	local socket = SocketHttp(jnt, self.host, self.port, "StandaloneRadioNowPlayingAPI")
	socket.t_getSendHeaders = function() return { ["User-Agent"] = "StandaloneRadio/0.9.13" } end
	self.http = socket
	local ok, err = pcall(function() socket:fetch(request) end)
	if not ok then finish(nil, nil, tostring(err)) end
end

function Client:_request(method, path, payload, callback)
	if self.requestFn then self.requestFn(method, path, payload, callback); return end
	self:_nativeRequest(method, path, payload, callback)
end

function Client:_scheduleRetry(reason)
	if not self.activeIntent and not self.releaseRequested then return end
	if self.retryTimer then return end
	local delay = RETRY_MS[self.retryIndex] or RETRY_MS[#RETRY_MS]
	if self.retryIndex < #RETRY_MS then self.retryIndex = self.retryIndex + 1 end
	self:_log("warn", tostring(reason), "; retry in ", tostring(delay), "ms")
	self.retryTimer = self:_timer(delay, function()
		self.retryTimer = nil
		self:_sync()
	end, true)
	if self.retryTimer then self.retryTimer:start() end
end

function Client:_startHeartbeat()
	if self.heartbeatTimer then return end
	self.heartbeatTimer = self:_timer(HEARTBEAT_MS, function()
		if self.sessionId and self.activeIntent and not self.inFlight then self:_heartbeat() end
	end)
	if self.heartbeatTimer then self.heartbeatTimer:start() end
end

function Client:_invalidateSession()
	self.sessionId, self.sessionGeneration = nil, nil
	self.publishedStationGeneration = nil
	self.publishedRevision = -1
	self:_stopTimer("heartbeatTimer")
end

function Client:_send(kind, method, path, payload, handler)
	if self.inFlight then return false end
	self.requestSerial = self.requestSerial + 1
	local serial = self.requestSerial
	self.inFlight = { serial=serial, kind=kind }
	self:_debug("request seq=", tostring(serial), " kind=", kind,
		" stationGeneration=", tostring(self.stationGeneration),
		" sessionGeneration=", tostring(self.sessionGeneration or "none"))
	self:_stopTimer("requestTimer")
	self.requestTimer = self:_timer(REQUEST_TIMEOUT_MS, function()
		if not self.inFlight or self.inFlight.serial ~= serial then return end
		self.inFlight = nil
		if self.http and self.http.close then pcall(function() self.http:close("timeout") end) end
		self:_scheduleRetry(kind .. " timeout")
	end, true)
	if self.requestTimer then self.requestTimer:start() end
	self:_request(method, path, payload, function(status, body, err)
		if not self.inFlight or self.inFlight.serial ~= serial then return end
		self.inFlight = nil
		self:_stopTimer("requestTimer")
		self:_debug("response seq=", tostring(serial), " kind=", kind,
			" status=", tostring(status or err or "unavailable"),
			" stationGeneration=", tostring(self.stationGeneration))
		local decoded
		if body and body ~= "" and okJson then
			local ok, value = pcall(function() return json.decode(body) end)
			if ok and type(value) == "table" then decoded = value else err = err or "invalid JSON response" end
		end
		handler(status, decoded, err)
	end)
	return true
end

function Client:_claim()
	if not self.activeIntent or self.sessionId then return end
	self:_log("info", "claim requested station=", stationName(self.station))
	self:_send("claim", "POST", "/api/nowplaying/claim", {
		source="radio", name="Standalone Radio", capabilities=falseCapabilities(),
	}, function(status, response, err)
		if status == 201 and response and response.success == true and response.active == true
			and type(response.session_id) == "string" and response.session_id ~= ""
			and tonumber(response.generation) then
			self.sessionId = response.session_id
			self.sessionGeneration = tonumber(response.generation)
			self.retryIndex = 1
			self:_log("info", "session acquired generation=", tostring(self.sessionGeneration))
			self:_startHeartbeat()
			self:_sync()
		else
			self:_scheduleRetry("claim failed HTTP " .. tostring(status or err or "unavailable"))
		end
	end)
end

function Client:_probeOwnership()
	self:_send("status", "GET", "/api/nowplaying", nil, function(status, response, err)
		if status == 200 and response and response.api_version == 1 then
			if response.active == true then
				-- A real owner replaced us. Wait for a new explicit radio activation;
				-- repeatedly reclaiming here would create an ownership fight.
				self.activeIntent = false
				self.releaseRequested = false
				self:_log("warn", "session replaced by another active source")
			else
				self:_sync()
			end
		else
			self:_scheduleRetry("status probe failed HTTP " .. tostring(status or err or "unavailable"))
		end
	end)
end

function Client:_sessionLost()
	self:_log("warn", "session lost")
	self:_invalidateSession()
	if self.activeIntent and (not self.isPlaybackOwner or self.isPlaybackOwner()) then
		self:_probeOwnership()
	else
		self.activeIntent = false
		self.releaseRequested = false
	end
end

function Client:_update()
	local snapshot = self:_snapshot()
	if not snapshot or not self.sessionId then return end
	local revision, token = self.revision, self.sessionId
	local stationGeneration = self.stationGeneration
	snapshot.session_id = token
	self:_send("update", "POST", "/api/nowplaying/update", snapshot, function(status, response, err)
		if token ~= self.sessionId then self:_sync(); return end
		if status == 200 and response and response.success == true then
			self.retryIndex = 1
			if revision > self.publishedRevision then self.publishedRevision = revision end
			self:_debug("published station=", safeStationId(self.station),
				" stationGeneration=", tostring(stationGeneration),
				" revision=", tostring(revision), " state=", tostring(snapshot.state),
				" metadata=", snapshot.track.title and "present" or "empty")
			if stationGeneration == self.stationGeneration
				and self.publishedStationGeneration ~= stationGeneration then
				self.publishedStationGeneration = stationGeneration
				if self.onPublished then
					local ok, callbackErr = pcall(self.onPublished, stationGeneration)
					if not ok then self:_log("warn", "onPublished failed: ", tostring(callbackErr)) end
				end
			end
			self:_sync()
		elseif status == 409 then self:_sessionLost()
		else self:_scheduleRetry("update failed HTTP " .. tostring(status or err or "unavailable")) end
	end)
end

function Client:_heartbeat()
	local token = self.sessionId
	self:_send("heartbeat", "POST", "/api/nowplaying/heartbeat", {session_id=token}, function(status, response, err)
		if token ~= self.sessionId then return end
		if status == 200 and response and response.success == true then self.retryIndex = 1
		elseif status == 409 then self:_sessionLost()
		else self:_scheduleRetry("heartbeat failed HTTP " .. tostring(status or err or "unavailable")) end
	end)
end

function Client:_release()
	local token = self.sessionId
	if not token then self.releaseRequested = false; return end
	self:_send("release", "POST", "/api/nowplaying/release", {session_id=token}, function(status, response, err)
		if token ~= self.sessionId then return end
		if status == 200 and response and response.success == true then
			self:_log("info", "released")
			self.releaseRequested = false
			self:_invalidateSession()
		elseif status == 409 then
			self.releaseRequested = false
			self:_invalidateSession()
		else self:_scheduleRetry("release failed HTTP " .. tostring(status or err or "unavailable")) end
	end)
end

function Client:_sync()
	if self.inFlight then return end
	self:_stopTimer("retryTimer")
	if not self.sessionId then
		if self.activeIntent then self:_claim() else self.releaseRequested = false end
	elseif self.publishedRevision < self.revision then
		self:_update()
	elseif self.releaseRequested then
		self:_release()
	end
end

function Client:activate(station, stationGeneration)
	if not station then return end
	stationGeneration = tonumber(stationGeneration) or (self.stationGeneration + 1)
	if stationGeneration < self.stationGeneration then
		self:_debug("ignored stale activation stationGeneration=", tostring(stationGeneration))
		return
	end
	local changed = not self.station or safeStationId(self.station) ~= safeStationId(station)
	self.station = station
	self.stationGeneration = stationGeneration
	self.stationArtwork = UrlTransport.artworkUrl(station.remoteLogo or station.favicon, self.debug and self.log or nil)
	self.trackArtwork = nil
	self.metadataGeneration = (self.metadataGeneration or 0) + 1
	self.activeIntent = true
	self.releaseRequested = false
	if changed then self.metadata = nil; self.timedMetadata = nil end
	self.desiredState = "buffering"
	self:_bump()
	self:_debug("station activated id=", safeStationId(station),
		" stationGeneration=", tostring(self.stationGeneration))
	self:_sync()
end

function Client:updateStation(station, stationGeneration)
	if not station then return end
	stationGeneration = tonumber(stationGeneration) or self.stationGeneration
	if stationGeneration ~= self.stationGeneration then
		self:_debug("ignored stale station callback stationGeneration=", tostring(stationGeneration))
		return
	end
	if not self.station or safeStationId(self.station) ~= safeStationId(station) then
		self.station, self.metadata = station, nil
		self:_bump()
		self:_sync()
	end
end

function Client:updateState(state, station, stationGeneration)
	stationGeneration = tonumber(stationGeneration) or self.stationGeneration
	if stationGeneration ~= self.stationGeneration then
		self:_debug("ignored stale state=", tostring(state),
			" stationGeneration=", tostring(stationGeneration))
		return
	end
	local mapped = STATE_MAP[state] or state
	if not mapped then return end
	if station and self.station and safeStationId(station) == safeStationId(self.station) then
		local oldAudio, newAudio = self.station.observedAudio or {}, station.observedAudio or {}
		if oldAudio.codec ~= newAudio.codec or oldAudio.bitrate_kbps ~= newAudio.bitrate_kbps then self:_bump() end
		self.station = station
	end
	self:_debug("state=", tostring(state), " mapped=", tostring(mapped),
		" station=", station and safeStationId(station) or "none",
		" stationGeneration=", tostring(self.stationGeneration))
	if mapped == "stopped" then
		self.activeIntent = false
		self.releaseRequested = true
	end
	if self.desiredState ~= mapped then self.desiredState = mapped; self:_bump() end
	self:_sync()
end

function Client:updateMetadata(streamTitle, station, stationGeneration)
	stationGeneration = tonumber(stationGeneration) or self.stationGeneration
	if stationGeneration ~= self.stationGeneration
		or (station and self.station and safeStationId(station) ~= safeStationId(self.station)) then
		self:_debug("ignored stale metadata stationGeneration=", tostring(stationGeneration))
		return
	end
	local value = trim(streamTitle)
	if value == "" then value = nil end
	if value == self.metadata then return end
	self.metadata = value
	self.timedMetadata = nil
	self.trackArtwork = nil
	self.metadataGeneration = (self.metadataGeneration or 0) + 1
	self:_bump()
	self:_debug("metadata changed station=", self.station and safeStationId(self.station) or "none",
		" stationGeneration=", tostring(self.stationGeneration),
		" value=", value and "present" or "empty")
	self:_sync()
end

-- Structured HLS updates bypass ICY's display-string splitting and external
-- artwork lookup. Timestamp-only tags never reach this path.
function Client:updateTimedMetadata(event, station, stationGeneration)
	if stationGeneration~=self.stationGeneration or not station or not self.station or
		safeStationId(station)~=safeStationId(self.station) then return false end
	local prior=self.timedMetadata or {}
	local title=type(event.title)=="string" and event.title~="" and event.title or prior.title
	local artist=type(event.artist)=="string" and event.artist~="" and event.artist or prior.artist
	local album=type(event.album)=="string" and event.album~="" and event.album or prior.album
	local changed=title~=prior.title or artist~=prior.artist or
		(type(event.album)=="string" and event.album~="" and album~=prior.album)
	if changed then self.trackArtwork=nil; if not event.album or event.album=="" then album=nil end end
	local artwork=type(event.artwork_url)=="string" and UrlTransport.artworkUrl(event.artwork_url) or nil
	local different=changed or album~=prior.album or (artwork and artwork~=self.trackArtwork)
	if not different then return true end
	self.timedMetadata={title=title,artist=artist,album=album}
	if artwork then self.trackArtwork=artwork end
	self.metadataGeneration=(self.metadataGeneration or 0)+1
	self:_bump(); self:_sync(); return true
end

function Client:updateStationArtwork(url, station, stationGeneration)
	stationGeneration = tonumber(stationGeneration) or self.stationGeneration
	if stationGeneration ~= self.stationGeneration
		or (station and self.station and safeStationId(station) ~= safeStationId(self.station)) then
		self:_debug("ignored stale station artwork stationGeneration=", tostring(stationGeneration))
		return false
	end
	local value = UrlTransport.artworkUrl(url, self.debug and self.log or nil)
	if value == self.stationArtwork then return value ~= nil end
	self.stationArtwork = value
	self:_bump()
	self:_sync()
	return value ~= nil
end

function Client:updateTrackArtwork(url, station, stationGeneration, streamTitle)
	stationGeneration = tonumber(stationGeneration) or self.stationGeneration
	local metadata = trim(streamTitle)
	if metadata == "" then metadata = nil end
	if stationGeneration ~= self.stationGeneration or metadata ~= self.metadata
		or (station and self.station and safeStationId(station) ~= safeStationId(self.station)) then
		self:_debug("ignored stale track artwork stationGeneration=", tostring(stationGeneration))
		return false
	end
	local value = UrlTransport.artworkUrl(url, self.debug and self.log or nil)
	if not value then return false end
	if value == self.trackArtwork then return true end
	self.trackArtwork = value
	self:_bump()
	self:_debug("track artwork changed stationGeneration=", tostring(self.stationGeneration))
	self:_sync()
	return true
end

function Client:release()
	self.activeIntent = false
	self.releaseRequested = true
	if self.desiredState ~= "stopped" then self.desiredState = "stopped"; self:_bump() end
	self:_sync()
end

function Client:shutdown()
	self:release()
	self:_stopTimer("retryTimer")
	self:_stopTimer("heartbeatTimer")
end

-- Test/support exports; no session token is exposed.
function Client:status()
	return { activeIntent=self.activeIntent == true, hasSession=self.sessionId ~= nil,
		generation=self.sessionGeneration, stationGeneration=self.stationGeneration,
		state=self.desiredState, revision=self.revision }
end

function mapState(state) return STATE_MAP[state] end
function stationId(station) return safeStationId(station) end
