local collectgarbage, io, ipairs, os, pcall, setmetatable, tonumber, tostring, type = collectgarbage, io, ipairs, os, pcall, setmetatable, tonumber, tostring, type

local lfs = require("lfs")
local string = require("string")
local table = require("table")
local RequestHttp = require("jive.net.RequestHttp")
local Resolver = require("applets.StandaloneRadio.Resolver")
local SocketHttp = require("jive.net.SocketHttp")
local Stations = require("applets.StandaloneRadio.Stations")
local UrlTransport = require("applets.StandaloneRadio.UrlTransport")
local Timer = require("jive.ui.Timer")

local okJson, json = pcall(require, "json")
if not okJson then json = nil end
local jnt = jnt

module(...)

local RadioBrowser = {}
RadioBrowser.__index = RadioBrowser

local API_HOST = "all.api.radio-browser.info"
local API_BASE = "http://" .. API_HOST
local USER_AGENT = "StandaloneRadio/0.9.0"
local CACHE_DIR = "/etc/squeezeplay/userpath/StandaloneRadio/cache/stations"

local PAGE_SIZE = 250
local SEARCH_CHUNK_SIZE = 100
local POPULAR_CHUNK_SIZE = 50
local CACHE_MAX_AGE_SECONDS = 86400
local STATION_CACHE_VERSION = 5

local SUPPORTED_CODECS = {
	["aac"] = true, ["aac+"] = true, ["ogg"] = true,
	["flac"] = true, ["flc"] = true, ["aif"] = true,
	["aiff"] = true, ["pcm"] = true, ["mp3"] = true,
}

local function trim(value) return tostring(value or ""):gsub("^%s*(.-)%s*$", "%1") end
local function isOne(value) return value == 1 or value == "1" or value == true end

local function ensureDir(path)
	local current = ""
	for part in string.gmatch(path, "[^/]+") do
		current = current .. "/" .. part
		if not lfs.attributes(current, "mode") then lfs.mkdir(current) end
	end
end

local function cacheBase(code) return CACHE_DIR .. "/station-cache-" .. code end
local function dataPath(code) return cacheBase(code) .. ".jsonl" end
local function popularPath(code) return cacheBase(code) .. ".popular.jsonl" end
local function metadataPath(code) return cacheBase(code) .. ".meta.json" end
local function legacyPath(code) return cacheBase(code) .. ".json" end

local function compatible(item)
	if type(item) ~= "table" then return false end
	local url = trim(item.url_resolved)
	if url == "" then url = trim(item.url) end
	local scheme = string.lower(string.sub(url, 1, 8))
	return trim(item.name) ~= "" and trim(item.stationuuid) ~= ""
		and SUPPORTED_CODECS[string.lower(trim(item.codec))] == true
		and (string.sub(scheme, 1, 7) == "http://" or scheme == "https://")
		and (item.lastcheckok == nil or isOne(item.lastcheckok)) and not isOne(item.hls)
end

local function toStation(item, countrycode)
	local url = trim(item.url_resolved)
	if url == "" then url = trim(item.url) end
	local station = {
		id = "radiobrowser:" .. trim(item.stationuuid), stationuuid = trim(item.stationuuid),
		name = trim(item.name), url = url, favicon = trim(item.favicon), source = "radiobrowser",
		codec = trim(item.codec), bitrate = tonumber(item.bitrate) or 0,
		clickcount = tonumber(item.clickcount) or 0, votes = tonumber(item.votes) or 0,
		countrycode = string.upper(trim(countrycode or item.countrycode)),
	}
	return Stations.normalize(station) and station or nil
end

local function cacheRecord(station)
	return {
		station.stationuuid, station.name, station.url, station.favicon or "",
		station.codec or "", station.bitrate or 0, station.clickcount or 0, station.votes or 0,
	}
end

local function recordStation(record, countrycode)
	if type(record) ~= "table" then return nil end
	return toStation({
		stationuuid = record[1], name = record[2], url = record[3], favicon = record[4],
		codec = record[5], bitrate = record[6], clickcount = record[7], votes = record[8],
		lastcheckok = 1, hls = 0,
	}, countrycode)
end

local function sortByName(a, b)
	local an, bn = string.lower(a.name or ""), string.lower(b.name or "")
	return an == bn and (a.stationuuid or "") < (b.stationuuid or "") or an < bn
end

local function morePopular(a, b)
	if (a.clickcount or 0) ~= (b.clickcount or 0) then return (a.clickcount or 0) > (b.clickcount or 0) end
	if (a.votes or 0) ~= (b.votes or 0) then return (a.votes or 0) > (b.votes or 0) end
	return sortByName(a, b)
end

local function newSocket(ip, port)
	local http = SocketHttp(jnt, ip, port, "StandaloneRadioRadioBrowser")
	http.t_getSendHeaders = function() return { ["User-Agent"] = USER_AGENT } end
	return http
end

local function closeFile(file)
	if file then pcall(function() file:close() end) end
end

function new(options)
	ensureDir(CACHE_DIR)
	return setmetatable({
		log = options.log, refreshes = {},
		resolver = Resolver.new({ log = options.log }),
	}, RadioBrowser)
end

function RadioBrowser:_fetchWithIp(ip, url, sink, headers, slot)
	local target, targetErr = UrlTransport.forRequest(url, self.log)
	if not target then sink(nil, targetErr); return end
	local requestHeaders = headers or {}
	requestHeaders["Host"] = target.hostHeader
	local request = RequestHttp(sink, "GET", target.path, { headers = requestHeaders })
	self[slot or "http"] = newSocket(ip, target.port)
	self[slot or "http"]:fetch(request)
end

function RadioBrowser:loadCache(code)
	if not json then return nil, false, "JSON support unavailable" end
	local file = io.open(metadataPath(code), "rb")
	if not file then return nil, false end
	local body = file:read("*a")
	file:close()
	local ok, metadata = pcall(function() return json.decode(body) end)
	if not ok or type(metadata) ~= "table" or metadata.version ~= STATION_CACHE_VERSION
		or metadata.countrycode ~= code
		or not tonumber(metadata.count) or not lfs.attributes(dataPath(code), "mode") then
		self.log:warn("StandaloneRadio: incompatible station cache country=", code)
		return nil, false, "incompatible cache"
	end
	local directory = {
		countrycode = code, count = tonumber(metadata.count) or 0,
		path = dataPath(code),
	}
	local fetchedAt = tonumber(metadata.fetchedAt) or 0
	local stale = fetchedAt <= 0 or os.time() - fetchedAt > CACHE_MAX_AGE_SECONDS
	self.log:info("StandaloneRadio: cache load country=", code, " stations=", tostring(directory.count))
	if stale then self.log:info("StandaloneRadio: cache stale country=", code) end
	return directory, stale
end

function RadioBrowser:_writeMetadata(code, count)
	local ok, body = pcall(function()
		return json.encode({
			version = STATION_CACHE_VERSION, countrycode = code,
			fetchedAt = os.time(), count = count,
		})
	end)
	if not ok or not body then return false, "metadata encode failed" end
	local temporary = metadataPath(code) .. ".tmp"
	local file = io.open(temporary, "wb")
	if not file then return false, "metadata write failed" end
	file:write(body)
	file:close()
	if not os.rename(temporary, metadataPath(code)) then
		os.remove(temporary)
		return false, "metadata rename failed"
	end
	return true
end

function RadioBrowser:_forEach(directory, callback)
	if not directory or not directory.path then return false, "station cache unavailable" end
	local file = io.open(directory.path, "rb")
	if not file then return false, "station cache unavailable" end
	local lineNumber = 0
	for line in file:lines() do
		lineNumber = lineNumber + 1
		local ok, record = pcall(function() return json.decode(line) end)
		if ok then
			local station = recordStation(record, directory.countrycode)
			if station and callback(station, lineNumber) == false then break end
		end
		if lineNumber % PAGE_SIZE == 0 then collectgarbage("step", 100) end
	end
	file:close()
	return true
end

function RadioBrowser:readPage(directory, offset, limit)
	offset = tonumber(offset) or 0
	limit = tonumber(limit) or 100
	if not directory or not directory.path then return nil, "station cache unavailable" end
	local file = io.open(directory.path, "rb")
	if not file then return nil, "station cache unavailable" end
	local stations = {}
	local lineNumber = 0
	for line in file:lines() do
		lineNumber = lineNumber + 1
		if lineNumber > offset then
			local ok, record = pcall(function() return json.decode(line) end)
			if ok then
				local station = recordStation(record, directory.countrycode)
				if station then stations[#stations + 1] = station end
			end
			if #stations >= limit then break end
		end
	end
	file:close()
	return stations
end

function RadioBrowser:search(directory, query, limit)
	local needle = string.lower(trim(query))
	local stations = {}
	if needle == "" then return stations end
	local ok, err = self:_forEach(directory, function(station)
		if string.find(string.lower(station.name or ""), needle, 1, true) then
			stations[#stations + 1] = station
		end
		return #stations < (tonumber(limit) or 250)
	end)
	return ok and stations or nil, err
end

function RadioBrowser:cancelSearch()
	local request = self.searchRequest
	if not request then return end
	self.searchRequest = nil
	if request.timer then request.timer:stop() end
	closeFile(request.file)
end

function RadioBrowser:searchAsync(directory, query, limit, callback)
	self:cancelSearch()
	self:cancelPopular()
	local needle = string.lower(trim(query))
	if needle == "" then callback({}); return true end
	if not directory or not directory.path then callback(nil, "station cache unavailable"); return false end
	local file = io.open(directory.path, "rb")
	if not file then callback(nil, "station cache unavailable"); return false end

	local request = { file = file, matches = {}, scanned = 0 }
	self.searchRequest = request
	limit = tonumber(limit) or 250
	self.log:info("StandaloneRadio: search start query=", query, " stations=", tostring(directory.count or 0))

	local function finish(err)
		if self.searchRequest ~= request then return end
		self.searchRequest = nil
		if request.timer then request.timer:stop() end
		closeFile(request.file)
		request.file = nil
		collectgarbage("collect")
		self.log:info("StandaloneRadio: search complete query=", query,
			" scanned=", tostring(request.scanned), " matches=", tostring(#request.matches),
			" error=", tostring(err or "none"))
		callback(err and nil or request.matches, err)
	end

	local function processChunk()
		for _ = 1, SEARCH_CHUNK_SIZE do
			local line = request.file:read("*l")
			if not line then finish(); return end
			request.scanned = request.scanned + 1
			-- Most rows are rejected before invoking the comparatively expensive JSON decoder.
			if string.find(string.lower(line), needle, 1, true) then
				local ok, record = pcall(function() return json.decode(line) end)
				local station = ok and recordStation(record, directory.countrycode) or nil
				if station and string.find(string.lower(station.name or ""), needle, 1, true) then
					request.matches[#request.matches + 1] = station
					if #request.matches >= limit then finish(); return end
				end
			end
		end
	end

	request.timer = Timer(10, processChunk)
	request.timer:start()
	return true
end

function RadioBrowser:popular(directory, limit)
	limit = tonumber(limit) or 100
	local stations = {}
	local ok, err = self:_forEach(directory, function(station)
		self:_addPopular(stations, station, limit)
	end)
	return ok and stations or nil, err
end

function RadioBrowser:_addPopular(stations, station, limit)
	if #stations >= limit and not morePopular(station, stations[#stations]) then return end
	local position = #stations + 1
	for index, current in ipairs(stations) do
		if morePopular(station, current) then position = index; break end
	end
	table.insert(stations, position, station)
	if #stations > limit then table.remove(stations) end
end

function RadioBrowser:cancelPopular()
	local request = self.popularRequest
	if not request then return end
	self.popularRequest = nil
	if request.timer then request.timer:stop() end
	closeFile(request.file)
end

function RadioBrowser:popularAsync(directory, limit, callback)
	self:cancelPopular()
	self:cancelSearch()
	if not directory or not directory.path then callback(nil, "station cache unavailable"); return false end
	local cachedPopular = popularPath(directory.countrycode)
	if lfs.attributes(cachedPopular, "mode") then
		local stations, err = self:readPage({
			path = cachedPopular, countrycode = directory.countrycode, count = limit,
		}, 0, limit)
		callback(stations, err)
		return stations ~= nil
	end
	local file = io.open(directory.path, "rb")
	if not file then callback(nil, "station cache unavailable"); return false end

	local request = { file = file, stations = {}, scanned = 0 }
	self.popularRequest = request
	limit = tonumber(limit) or 100
	self.log:info("StandaloneRadio: popular scan start stations=", tostring(directory.count or 0))

	local function finish(err)
		if self.popularRequest ~= request then return end
		self.popularRequest = nil
		if request.timer then request.timer:stop() end
		closeFile(request.file)
		request.file = nil
		collectgarbage("collect")
		self.log:info("StandaloneRadio: popular scan complete scanned=", tostring(request.scanned),
			" matches=", tostring(#request.stations), " error=", tostring(err or "none"))
		callback(err and nil or request.stations, err)
	end

	local function processChunk()
		for _ = 1, POPULAR_CHUNK_SIZE do
			local line = request.file:read("*l")
			if not line then finish(); return end
			request.scanned = request.scanned + 1
			local ok, record = pcall(function() return json.decode(line) end)
			local station = ok and recordStation(record, directory.countrycode) or nil
			if station then self:_addPopular(request.stations, station, limit) end
		end
	end

	request.timer = Timer(10, processChunk)
	request.timer:start()
	return true
end

function RadioBrowser:_writePopular(code, stations)
	local path = popularPath(code)
	local temporary = path .. ".tmp"
	local file = io.open(temporary, "wb")
	if not file then return false, "popular cache write failed" end
	for _, station in ipairs(stations or {}) do
		local ok, line = pcall(function() return json.encode(cacheRecord(station)) end)
		if not ok or not line then closeFile(file); os.remove(temporary); return false, "popular cache encode failed" end
		file:write(line, "\n")
	end
	file:close()
	if not os.rename(temporary, path) then
		os.remove(temporary)
		return false, "popular cache rename failed"
	end
	return true
end

function RadioBrowser:refresh(code, callback, progress)
	if self.refreshes[code] then return false end
	if not json then callback(nil, "JSON support unavailable"); return false end
	local temporary = dataPath(code) .. ".tmp"
	local output = io.open(temporary, "wb")
	if not output then callback(nil, "station cache write failed"); return false end
	local request = {
		count = 0, offset = 0,
		file = output, temporaryPath = temporary, popular = {},
	}
	self.refreshes[code] = request
	self.log:info("StandaloneRadio: refresh country=", code, " start")

	local function finish(err)
		if self.refreshes[code] ~= request then return end
		self.refreshes[code] = nil
		closeFile(request.file)
		request.file = nil
		if err then
			os.remove(request.temporaryPath)
			self.log:warn("StandaloneRadio: refresh country=", code, " failed: ", tostring(err))
			callback(nil, err)
			return
		end
		if not os.rename(request.temporaryPath, dataPath(code)) then
			os.remove(request.temporaryPath)
			callback(nil, "station cache rename failed")
			return
		end
		local saved, metadataErr = self:_writeMetadata(code, request.count)
		if not saved then callback(nil, metadataErr); return end
		local popularSaved, popularErr = self:_writePopular(code, request.popular)
		if not popularSaved then self.log:warn("StandaloneRadio: ", tostring(popularErr)) end
		os.remove(legacyPath(code))
		local directory = {
			countrycode = code, count = request.count,
			path = dataPath(code),
		}
		self.log:info("StandaloneRadio: refresh complete country=", code, " stations=", tostring(request.count))
		callback(directory)
	end

	local function fetchPage(ip)
		local path = "/json/stations/search?countrycode=" .. code
			.. "&hidebroken=true&order=name&reverse=false&offset=" .. tostring(request.offset)
			.. "&limit=" .. tostring(PAGE_SIZE)
		self:_fetchWithIp(ip, API_BASE .. path, function(body, err)
			if self.refreshes[code] ~= request then return end
			if err then finish(err); return end
			-- RequestHttp calls the sink once before the response body is available.
			if body == nil then return end
			self.log:info("StandaloneRadio: response country=", code, " offset=", tostring(request.offset), " bytes=", tostring(#body))
			local ok, page = pcall(function() return json.decode(body) end)
			if not ok or type(page) ~= "table" then finish("invalid JSON"); return end
			local returned = #page
			for _, item in ipairs(page) do
				if compatible(item) then
					local station = toStation(item, code)
					if station then
						local encoded, line = pcall(function() return json.encode(cacheRecord(station)) end)
						if not encoded or not line then finish("station cache encode failed"); return end
						request.file:write(line, "\n")
						request.count = request.count + 1
						self:_addPopular(request.popular, station, 100)
					end
				end
			end
			self.log:info("StandaloneRadio: page country=", code, " offset=", tostring(request.offset), " count=", tostring(returned), " total=", tostring(request.count))
			if progress then progress(request.count) end
			page, body = nil, nil
			collectgarbage("collect")
			if returned < PAGE_SIZE then
				finish()
			else
				request.offset = request.offset + PAGE_SIZE
				fetchPage(ip)
			end
		end, { ["Accept"] = "application/json" }, "http")
	end

	local apiTarget, targetErr = UrlTransport.forRequest(API_BASE .. "/json/stations/search", self.log)
	if not apiTarget then
		finish(targetErr or "invalid Radio Browser API URL")
		return false
	end
	self.resolver:resolve(apiTarget.host, function(ip)
		if self.refreshes[code] ~= request then return end
		if not ip then finish("DNS failed"); return end
		fetchPage(ip)
	end)
	return true
end

function RadioBrowser:recordClick(station)
	if not station or station.source ~= "radiobrowser" or not station.stationuuid or station.stationuuid == "" then return end
	local clickUrl = API_BASE .. "/json/url/" .. station.stationuuid
	local target = UrlTransport.forRequest(clickUrl, self.log)
	if not target then return end
	self.resolver:resolve(target.host, function(ip)
		if not ip then self.log:warn("StandaloneRadio: Radio Browser click DNS failed"); return end
		self:_fetchWithIp(ip, clickUrl, function(_, err)
			if err then self.log:warn("StandaloneRadio: Radio Browser click failed: ", tostring(err)) end
		end, { ["Accept"] = "application/json" }, "clickHttp")
	end)
end
