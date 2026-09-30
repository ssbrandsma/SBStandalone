local io, os, pcall, setmetatable, tostring, type = io, os, pcall, setmetatable, tostring, type

local string = require("string")

local RequestHttp = require("jive.net.RequestHttp")
local Resolver = require("applets.StandaloneRadio.Resolver")
local SocketHttp = require("jive.net.SocketHttp")
local UrlTransport = require("applets.StandaloneRadio.UrlTransport")

local okJson, json = pcall(require, "json")
if not okJson then json = nil end
local jnt = jnt

module(...)


local TrackArtwork = {}
TrackArtwork.__index = TrackArtwork
local API_HOST = "api.lms-community.org"
local API_PORT = 80
local MAX_BYTES = 512 * 1024


local function trim(value)
	return tostring(value or ""):gsub("^%s*(.-)%s*$", "%1")
end


local function encodePathSegment(value)
	return (string.gsub(value, "[^%w%-%._~]", function(character)
		return string.format("%%%02X", string.byte(character))
	end))
end


local function parseStreamTitle(streamTitle)
	local artist, title = string.match(streamTitle, "^(.-)%s%-%s(.+)$")
	artist = trim(artist)
	title = trim(title)
	if artist == "" or title == "" then
		return nil
	end
	return artist, title
end


local function httpPictureUrl(value)
	local url = trim(value)
	if not string.match(url, "^https?://[%w%.%-]+[:%d]*/?.*") then
		return nil
	end
	return url
end


function new(options)
	return setmetatable({
		log = options.log,
		nowPlaying = options.nowPlaying,
		resolver = Resolver.new({ log = options.log }),
		httpsProxyStatus = options.httpsProxyStatus,
		generation = 0,
	}, TrackArtwork)
end


function TrackArtwork:_isCurrent(generation, key, station)
	return self.generation == generation and self.currentKey == key
		and self.currentStationId == station.id
end


function TrackArtwork:_removeTemp()
	if self.tempPath then
		os.remove(self.tempPath)
		self.tempPath = nil
	end
end


function TrackArtwork:reset(station)
	self.generation = self.generation + 1
	self.currentKey = nil
	self.currentStationId = station and station.id or nil
	self:_removeTemp()
	self.nowPlaying:clearTrackArtwork(station)
end


function TrackArtwork:lookup(station, streamTitle)
	if not station or not json then
		return
	end

	local artist, title = parseStreamTitle(streamTitle)
	if not artist then
		if self.currentKey ~= false then
			self:reset(station)
			self.currentKey = false
		end
		return
	end

	local key = artist .. "\0" .. title
	if key == self.currentKey and station.id == self.currentStationId then
		return
	end

	self.generation = self.generation + 1
	local generation = self.generation
	self.currentKey = key
	self.currentStationId = station.id
	self:_removeTemp()
	self.nowPlaying:beginTrackArtwork(station, key)
	self.log:info("StandaloneRadio: track artwork lookup artist=", artist, " title=", title)

	local path = "/music/track/" .. encodePathSegment(title) .. "/" .. encodePathSegment(artist) .. "/cover"
	self.resolver:resolve(API_HOST, function(ip)
		if not self:_isCurrent(generation, key, station) then
			self.log:info("StandaloneRadio: ignoring stale artwork result")
			return
		end
		if not ip then
			self.log:warn("StandaloneRadio: track artwork lookup failed DNS")
			return
		end

		-- The stock Squeezebox HTTP client stalls on this Cloudflare endpoint
		-- when the connection is kept alive. Close it after this small response.
		local request = RequestHttp(function(body, err)
			if not self:_isCurrent(generation, key, station) then
				self.log:info("StandaloneRadio: ignoring stale artwork result")
				return
			end
			-- SocketHttp reports a final empty callback after Connection: close.
			if not body and not err then
				return
			end
			if err or not body then
				self.log:warn("StandaloneRadio: track artwork lookup failed ", tostring(err))
				return
			end
			local ok, response = pcall(function() return json.decode(body) end)
			local picture = ok and type(response) == "table" and httpPictureUrl(response.picture)
			if not picture then
				self.log:info("StandaloneRadio: track artwork not found")
				return
			end

			self.log:info("StandaloneRadio: track artwork API picture=", UrlTransport.redact(picture))
			self:_downloadPicture(station, key, generation, picture)
		end, "GET", path, { headers = {
			["Host"] = API_HOST,
			["Accept"] = "application/json",
			["Connection"] = "close",
		} })
		self.http = SocketHttp(jnt, ip, API_PORT, "StandaloneRadioTrackArtwork")
		self.http.t_getSendHeaders = function() return { ["User-Agent"] = "StandaloneRadio/0.9.1" } end
		self.http:fetch(request)
	end)
end


function TrackArtwork:_downloadPicture(station, key, generation, picture)
	self.log:info("StandaloneRadio: artwork download start url=", UrlTransport.redact(picture))
	local tempPath = "/tmp/standalone-radio-track-" .. tostring(generation) .. ".img"
	self.tempPath = tempPath
	os.remove(tempPath)
	local target, targetErr = UrlTransport.forRequest(picture, self.log)
	if not target then self.log:warn("StandaloneRadio: artwork transport failed ", tostring(targetErr)); return end
	self.resolver:resolve(target.host, function(ip)
		if not self:_isCurrent(generation, key, station) then return end
		if not ip then self.log:warn("StandaloneRadio: artwork DNS failed"); return end
		local request
		local done = false
		request = RequestHttp(function(body, err)
			if done then return end
			if body == nil and not err then return end
			done = true
			if not self:_isCurrent(generation, key, station) then
				self.log:info("StandaloneRadio: ignoring stale artwork result")
				return
			end
			local status = request:t_getResponseStatus()
			if err or type(body) ~= "string" or #body == 0 or #body > MAX_BYTES
				or (status and (status < 200 or status >= 300)) then
				if err and target.proxied and self.httpsProxyStatus then self.httpsProxyStatus:transportFailed(picture) end
				self.log:warn("StandaloneRadio: track artwork image failed ", tostring(err or status or "invalid size"))
				return
			end
			local file = io.open(tempPath, "wb")
			if file then file:write(body); file:close() end
			if not file or not self.nowPlaying:setTrackArtwork(station, key, tempPath) then
				self.log:warn("StandaloneRadio: track artwork image failed")
			else
				self.log:info("StandaloneRadio: artwork download complete url=", UrlTransport.redact(picture))
			end
			os.remove(tempPath)
			if self.tempPath == tempPath then self.tempPath = nil end
		end, "GET", target.path, { headers = {
			Host = target.hostHeader, Accept = "image/png,image/jpeg,*/*", Connection = "close",
		} })
		local socket = SocketHttp(jnt, ip, target.port, "StandaloneRadioTrackArtworkImage")
		socket.t_getSendHeaders = function() return { ["User-Agent"] = "StandaloneRadio/0.9.1" } end
		self.imageHttp = socket
		local ok, fetchErr = pcall(function() socket:fetch(request) end)
		if not ok then
			if target.proxied and self.httpsProxyStatus then self.httpsProxyStatus:transportFailed(picture) end
			self.log:warn("StandaloneRadio: artwork request failed ", tostring(fetchErr))
		end
	end)
end
