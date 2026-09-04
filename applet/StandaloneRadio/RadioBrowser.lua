local ipairs, os, pcall, setmetatable, tonumber, tostring, type = ipairs, os, pcall, setmetatable, tonumber, tostring, type

local lfs = require("lfs")
local string = require("string")
local RequestHttp = require("jive.net.RequestHttp")
local Resolver = require("applets.StandaloneRadio.Resolver")
local SocketHttp = require("jive.net.SocketHttp")
local Stations = require("applets.StandaloneRadio.Stations")

local okJson, json = pcall(require, "json")
if not okJson then json = nil end
local jnt = jnt

module(...)

local RadioBrowser = {}
RadioBrowser.__index = RadioBrowser

local API_HOST = "all.api.radio-browser.info"
local API_PORT = 80
local USER_AGENT = "StandaloneRadio/0.5"
local CACHE_DIR = "/etc/squeezeplay/userpath/StandaloneRadio/cache/stations"

local PAGE_SIZE = 250
local MAX_STATIONS_PER_COUNTRY = 5000
local CACHE_MAX_AGE_SECONDS = 86400
local STATION_CACHE_VERSION = 1

local function trim(value) return tostring(value or ""):gsub("^%s*(.-)%s*$", "%1") end
local function isOne(value) return value == 1 or value == "1" or value == true end

local function ensureDir(path)
	local current = ""
	for part in string.gmatch(path, "[^/]+") do
		current = current .. "/" .. part
		if not lfs.attributes(current, "mode") then lfs.mkdir(current) end
	end
end

local function cachePath(code) return CACHE_DIR .. "/station-cache-" .. code .. ".json" end

local function compatible(item)
	if type(item) ~= "table" then return false end
	local url = trim(item.url_resolved)
	if url == "" then url = trim(item.url) end
	return trim(item.name) ~= "" and trim(item.stationuuid) ~= ""
		and string.lower(trim(item.codec)) == "mp3"
		and string.lower(string.sub(url, 1, 7)) == "http://"
		and (item.lastcheckok == nil or isOne(item.lastcheckok)) and not isOne(item.hls)
end

local function toStation(item)
	local url = trim(item.url_resolved)
	if url == "" then url = trim(item.url) end
	local station = {
		id = "radiobrowser:" .. trim(item.stationuuid), stationuuid = trim(item.stationuuid), name = trim(item.name),
		url = url, url_resolved = trim(item.url_resolved), favicon = trim(item.favicon), remoteLogo = trim(item.favicon),
		source = "radiobrowser", codec = trim(item.codec), bitrate = tonumber(item.bitrate) or 0,
		clickcount = tonumber(item.clickcount) or 0, votes = tonumber(item.votes) or 0,
		countrycode = string.upper(trim(item.countrycode)),
	}
	return Stations.normalize(station) and station or nil
end

local function sortByName(a, b)
	local an, bn = string.lower(a.name or ""), string.lower(b.name or "")
	return an == bn and (a.stationuuid or "") < (b.stationuuid or "") or an < bn
end

local function newSocket(ip)
	local http = SocketHttp(jnt, ip, API_PORT, "StandaloneRadioRadioBrowser")
	http.t_getSendHeaders = function() return { ["User-Agent"] = USER_AGENT } end
	return http
end

function new(options)
	ensureDir(CACHE_DIR)
	return setmetatable({ log = options.log, refreshes = {}, resolver = Resolver.new({ log = options.log }) }, RadioBrowser)
end

function RadioBrowser:_fetchWithIp(ip, path, sink, headers, slot)
	local requestHeaders = headers or {}
	requestHeaders["Host"] = API_HOST
	local request = RequestHttp(sink, "GET", path, { headers = requestHeaders })
	self[slot or "http"] = newSocket(ip)
	self[slot or "http"]:fetch(request)
end

function RadioBrowser:loadCache(code)
	if not json then return nil, false, "JSON support unavailable" end
	local file = io.open(cachePath(code), "rb")
	if not file then return nil, false end
	local body = file:read("*a")
	file:close()
	local ok, cache = pcall(function() return json.decode(body) end)
	if not ok or type(cache) ~= "table" or cache.version ~= STATION_CACHE_VERSION
		or cache.countrycode ~= code or type(cache.stations) ~= "table" then
		self.log:warn("StandaloneRadio: corrupt station cache country=", code)
		return nil, false, "corrupt cache"
	end
	local stations, seen = {}, {}
	for _, item in ipairs(cache.stations) do
		if compatible(item) and not seen[item.stationuuid] then
			local station = toStation(item)
			if station then seen[station.stationuuid] = true; stations[#stations + 1] = station end
		end
	end
	table.sort(stations, sortByName)
	local stale = (tonumber(cache.fetchedAt) or 0) <= 0 or os.time() - (tonumber(cache.fetchedAt) or 0) > CACHE_MAX_AGE_SECONDS
	self.log:info("StandaloneRadio: cache load country=", code, " stations=", tostring(#stations))
	if stale then self.log:info("StandaloneRadio: cache stale country=", code) end
	return stations, stale
end

function RadioBrowser:_saveCache(code, stations)
	if not json then return false end
	local ok, body = pcall(function()
		return json.encode({ version = STATION_CACHE_VERSION, countrycode = code, fetchedAt = os.time(), stations = stations })
	end)
	if not ok or not body then self.log:warn("StandaloneRadio: cache encode failed country=", code); return false end
	local temporary = cachePath(code) .. ".tmp"
	local file = io.open(temporary, "wb")
	if not file then self.log:warn("StandaloneRadio: cache write failed country=", code); return false end
	file:write(body)
	file:close()
	if not os.rename(temporary, cachePath(code)) then
		os.remove(temporary); self.log:warn("StandaloneRadio: cache rename failed country=", code); return false
	end
	self.log:info("StandaloneRadio: cache saved country=", code, " stations=", tostring(#stations))
	return true
end

function RadioBrowser:refresh(code, callback, progress)
	if self.refreshes[code] then return false end
	if not json then callback(nil, "JSON support unavailable"); return false end
	local request = { stations = {}, seen = {}, offset = 0 }
	self.refreshes[code] = request
	self.log:info("StandaloneRadio: refresh country=", code, " start")
	local function finish(stations, err)
		self.refreshes[code] = nil
		if err then self.log:warn("StandaloneRadio: refresh country=", code, " failed: ", tostring(err)); callback(nil, err); return end
		table.sort(stations, sortByName)
		self:_saveCache(code, stations)
		self.log:info("StandaloneRadio: refresh complete country=", code, " stations=", tostring(#stations))
		callback(stations)
	end
	local function fetchPage(ip)
		local path = "/json/stations/search?countrycode=" .. code .. "&codec=MP3&is_https=false&hidebroken=true"
			.. "&order=name&reverse=false&offset=" .. tostring(request.offset) .. "&limit=" .. tostring(PAGE_SIZE)
		self:_fetchWithIp(ip, path, function(body, err)
			if err then finish(nil, err); return end
			if not body then return end
			local ok, page = pcall(function() return json.decode(body) end)
			if not ok or type(page) ~= "table" then finish(nil, "invalid JSON"); return end
			local returned = #page
			for _, item in ipairs(page) do
				if compatible(item) and not request.seen[item.stationuuid] then
					local station = toStation(item)
					if station then
						request.seen[station.stationuuid] = true; request.stations[#request.stations + 1] = station
						if #request.stations >= MAX_STATIONS_PER_COUNTRY then break end
					end
				end
			end
			self.log:info("StandaloneRadio: page country=", code, " offset=", tostring(request.offset), " count=", tostring(returned), " total=", tostring(#request.stations))
			if progress then progress(#request.stations) end
			if returned == 0 or returned < PAGE_SIZE or #request.stations >= MAX_STATIONS_PER_COUNTRY then
				finish(request.stations)
			else request.offset = request.offset + PAGE_SIZE; fetchPage(ip) end
		end, { ["Accept"] = "application/json" }, "http")
	end
	self.resolver:resolve(API_HOST, function(ip)
		if not ip then finish(nil, "DNS failed"); return end
		fetchPage(ip)
	end)
	return true
end

function RadioBrowser:recordClick(station)
	if not station or station.source ~= "radiobrowser" or not station.stationuuid or station.stationuuid == "" then return end
	self.resolver:resolve(API_HOST, function(ip)
		if not ip then self.log:warn("StandaloneRadio: Radio Browser click DNS failed"); return end
		self:_fetchWithIp(ip, "/json/url/" .. station.stationuuid, function(_, err)
			if err then self.log:warn("StandaloneRadio: Radio Browser click failed: ", tostring(err)) end
		end, { ["Accept"] = "application/json" }, "clickHttp")
	end)
end
