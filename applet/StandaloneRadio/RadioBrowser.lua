local ipairs, pcall, setmetatable, tonumber, tostring, type = ipairs, pcall, setmetatable, tonumber, tostring, type

local string = require("string")

local RequestHttp = require("jive.net.RequestHttp")
local Resolver = require("applets.StandaloneRadio.Resolver")
local SocketHttp = require("jive.net.SocketHttp")
local Stations = require("applets.StandaloneRadio.Stations")

local okJson, json = pcall(require, "json")
if not okJson then
	json = nil
end

local jnt = jnt

module(...)


local RadioBrowser = {}
RadioBrowser.__index = RadioBrowser

local API_HOST = "all.api.radio-browser.info"
local API_PORT = 80
local USER_AGENT = "StandaloneRadio/0.2"
local SEARCH_PATH = "/json/stations/search?countrycode=NL&codec=MP3&is_https=false&hidebroken=true&order=clickcount&reverse=true&limit=75"


local function trim(value)
	return tostring(value or ""):gsub("^%s*(.-)%s*$", "%1")
end


local function isOne(value)
	return value == 1 or value == "1" or value == true
end


local function compatible(apiStation)
	if type(apiStation) ~= "table" then
		return false
	end

	local url = trim(apiStation.url_resolved)
	if url == "" then
		url = trim(apiStation.url)
	end

	return trim(apiStation.name) ~= ""
		and trim(apiStation.stationuuid) ~= ""
		and string.lower(trim(apiStation.codec)) == "mp3"
		and string.lower(string.sub(url, 1, 7)) == "http://"
		and isOne(apiStation.lastcheckok)
		and not isOne(apiStation.hls)
end


local function toStation(apiStation)
	local url = trim(apiStation.url_resolved)
	if url == "" then
		url = trim(apiStation.url)
	end

	local station = {
		id = "radiobrowser:" .. trim(apiStation.stationuuid),
		stationuuid = trim(apiStation.stationuuid),
		name = trim(apiStation.name),
		url = url,
		remoteLogo = trim(apiStation.favicon),
		source = "radiobrowser",
		codec = trim(apiStation.codec),
		bitrate = tonumber(apiStation.bitrate) or 0,
		countrycode = trim(apiStation.countrycode),
	}

	local ok = Stations.normalize(station)
	if ok then
		return station
	end
	return nil
end


local function newSocket(ip)
	local http = SocketHttp(jnt, ip, API_PORT, "StandaloneRadioRadioBrowser")
	http.t_getSendHeaders = function()
		return {
			["User-Agent"] = USER_AGENT,
		}
	end
	return http
end


function new(options)
	return setmetatable({
		log = options.log,
		cache = nil,
		resolver = Resolver.new({
			log = options.log,
		}),
	}, RadioBrowser)
end


function RadioBrowser:_fetchWithIp(ip, path, sink, headers, slot)
	local reqHeaders = headers or {}
	reqHeaders["Host"] = API_HOST

	local req = RequestHttp(sink, "GET", path, {
		headers = reqHeaders,
	})

	self[slot or "http"] = newSocket(ip)
	self[slot or "http"]:fetch(req)
end


function RadioBrowser:fetch(callback)
	if not json then
		self.log:warn("StandaloneRadio: Radio Browser JSON support unavailable")
		callback(nil, "JSON support unavailable")
		return
	end

	self.log:info("StandaloneRadio: Radio Browser request started")

	self.resolver:resolve(API_HOST, function(ip)
		if not ip then
			self.log:warn("StandaloneRadio: Radio Browser DNS failed")
			callback(nil, "DNS failed")
			return
		end

		self:_fetchWithIp(ip, SEARCH_PATH, function(body, err)
			if err then
				self.log:warn("StandaloneRadio: Radio Browser request failed: ", tostring(err))
				callback(nil, err)
				return
			end
			if not body then
				return
			end

			local ok, decoded = pcall(function()
				return json.decode(body)
			end)
			if not ok or type(decoded) ~= "table" then
				self.log:warn("StandaloneRadio: Radio Browser invalid JSON")
				callback(nil, "invalid JSON")
				return
			end

			local stations = {}
			local returned = 0
			for _, apiStation in ipairs(decoded) do
				returned = returned + 1
				if compatible(apiStation) then
					local station = toStation(apiStation)
					if station then
						stations[#stations + 1] = station
					end
				end
			end

			self.log:info("StandaloneRadio: Radio Browser returned ", tostring(returned), " stations")
			self.log:info("StandaloneRadio: Radio Browser filtered to ", tostring(#stations), " compatible stations")
			if #stations > 0 then
				self.cache = stations
				callback(stations)
			elseif self.cache then
				callback(self.cache)
			else
				callback(nil, "empty station list")
			end
		end, {
			["Accept"] = "application/json",
			["Content-Type"] = "application/json; charset=utf-8",
		}, "http")
	end)
end


function RadioBrowser:recordClick(station)
	if not station or station.source ~= "radiobrowser" or not station.stationuuid or station.stationuuid == "" then
		return
	end

	local path = "/json/url/" .. station.stationuuid
	self.resolver:resolve(API_HOST, function(ip)
		if not ip then
			self.log:warn("StandaloneRadio: Radio Browser click DNS failed")
			return
		end

		self:_fetchWithIp(ip, path, function(_, err)
			if err then
				self.log:warn("StandaloneRadio: Radio Browser click failed: ", tostring(err))
			end
		end, {
			["Accept"] = "application/json",
		}, "clickHttp")
	end)
end
