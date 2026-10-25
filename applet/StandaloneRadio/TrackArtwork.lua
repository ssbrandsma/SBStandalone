local pcall, setmetatable, tostring, type = pcall, setmetatable, tostring, type

local string = require("string")

local RequestHttp = require("jive.net.RequestHttp")
local Resolver = require("applets.StandaloneRadio.Resolver")
local SocketHttp = require("jive.net.SocketHttp")
local UrlTransport = require("applets.StandaloneRadio.UrlTransport")
local StreamMetadata = require("applets.StandaloneRadio.StreamMetadata")

local okJson, json = pcall(require, "json")
if not okJson then json = nil end
local jnt = jnt

module(...)


local TrackArtwork = {}
TrackArtwork.__index = TrackArtwork
local API_HOST = "api.lms-community.org"
local API_PORT = 80


local function trim(value)
	return tostring(value or ""):gsub("^%s*(.-)%s*$", "%1")
end


local function encodePathSegment(value)
	return (string.gsub(value, "[^%w%-%._~]", function(character)
		return string.format("%%%02X", string.byte(character))
	end))
end


local function httpPictureUrl(value)
	local url = trim(value)
	if not UrlTransport.artworkUrl(url) then
		return nil
	end
	return url
end


function new(options)
	return setmetatable({
		log = options.log,
		resolver = Resolver.new({ log = options.log }),
		onArtworkUrl = options.onArtworkUrl,
		generation = 0,
	}, TrackArtwork)
end


function TrackArtwork:_isCurrent(generation, key, station)
	return self.generation == generation and self.currentKey == key
		and self.currentStationId == station.id
end


function TrackArtwork:reset(station)
	self.generation = self.generation + 1
	self.currentKey = nil
	self.currentStationId = station and station.id or nil
end


function TrackArtwork:lookup(station, streamTitle, stationGeneration)
	if not station or not json then
		return
	end

	local title, artist = StreamMetadata.parse(streamTitle)
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
	self.log:info("StandaloneRadio: track artwork lookup artist=", artist, " title=", title)

	local path = "/music/track/" .. encodePathSegment(title) .. "/" .. encodePathSegment(artist) .. "/cover"
	local trace=UrlTransport.beginTrace and UrlTransport.beginTrace("track-artwork:"..tostring(station.id),"http://"..API_HOST..path)
	self.resolver:resolve(API_HOST, function(ip)
		if not self:_isCurrent(generation, key, station) then
			if trace then trace:finish("cancelled") end
			self.log:info("StandaloneRadio: ignoring stale artwork result")
			return
		end
		if not ip then
			if trace then trace:finish("DNS failed: "..API_HOST) end
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
			if self.onArtworkUrl then
				self.onArtworkUrl(station, streamTitle, picture, stationGeneration)
			end
		end, "GET", path, { headers = {
			["Host"] = API_HOST,
			["Accept"] = "application/json",
			["Connection"] = "close",
		} })
		request._standaloneTrace=trace
		self.http = SocketHttp(jnt, ip, API_PORT, "StandaloneRadioTrackArtwork")
		self.http.t_getSendHeaders = function() return { ["User-Agent"] = "StandaloneRadio/0.9.15" } end
		self.http:fetch(request)
	end)
end
