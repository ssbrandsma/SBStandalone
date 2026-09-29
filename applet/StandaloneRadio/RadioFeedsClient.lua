local ipairs, pairs, pcall, setmetatable, tonumber, tostring, type = ipairs, pairs, pcall, setmetatable, tonumber, tostring, type
local string = require("string")

local RequestHttp = require("jive.net.RequestHttp")
local Resolver = require("applets.StandaloneRadio.Resolver")
local RadioFeedsOpml = require("applets.StandaloneRadio.RadioFeedsOpml")
local SocketHttp = require("jive.net.SocketHttp")
local Stations = require("applets.StandaloneRadio.Stations")
local jnt = jnt

module(...)

local RadioFeedsClient = {}
RadioFeedsClient.__index = RadioFeedsClient

local ROOT_URL = "http://www.radiofeeds.co.uk/MyPicks/network.opml?username=forusewithstandalone"
local USER_AGENT = "Lyrion Music Server"
local MAX_OPML_BYTES = 256 * 1024
local MAX_PLAYLIST_BYTES = 64 * 1024
local MAX_REDIRECTS = 5

local function parseUrl(url)
	local host, port, path = string.match(tostring(url or ""), "^http://([^/:]+):?(%d*)(/.*)$")
	if not host then return nil, "RadioFeeds requires an HTTP URL" end
	return { host = host, port = tonumber(port) or 80, path = path, url = url }
end

local function header(headers, wanted)
	for name, value in pairs(headers or {}) do
		if string.lower(name) == wanted then return value end
	end
end

local function absoluteUrl(base, location)
	if string.match(location or "", "^http://") then return location end
	local parsed = parseUrl(base)
	if not parsed then return nil end
	if string.sub(location or "", 1, 1) == "/" then
		return "http://" .. parsed.host .. ((parsed.port ~= 80) and (":" .. parsed.port) or "") .. location
	end
	local directory = string.match(parsed.path, "^(.*)/") or ""
	return "http://" .. parsed.host .. ((parsed.port ~= 80) and (":" .. parsed.port) or "") .. directory .. "/" .. tostring(location)
end

local function stationKey(url)
	local hash = 5381
	for index = 1, #url do hash = (hash * 33 + string.byte(url, index)) % 2147483647 end
	return "rf" .. tostring(hash)
end

local function playlistUrl(body)
	for line in string.gmatch(body or "", "[^\r\n]+") do
		line = string.gsub(line, "^%s*(.-)%s*$", "%1")
		local value = string.match(line, "^[Ff][Ii][Ll][Ee]%d+=([^\r\n]+)$")
		if value then return string.gsub(value, "^%s*(.-)%s*$", "%1") end
		if line ~= "" and string.sub(line, 1, 1) ~= "#" and string.match(line, "^http://") then return line end
	end
end

function new(options)
	return setmetatable({ log = options.log, resolver = Resolver.new({ log = options.log }) }, RadioFeedsClient)
end

function RadioFeedsClient:rootUrl()
	return ROOT_URL
end

function RadioFeedsClient:_fetch(url, accept, maxBytes, redirects, callback)
	local parsed, parseErr = parseUrl(url)
	if not parsed then callback(nil, parseErr); return false end
	self.log:info("StandaloneRadio: RadioFeeds GET ", url)
	self.resolver:resolve(parsed.host, function(ip)
		if not ip then callback(nil, "RadioFeeds DNS failed"); return end
		local responseHeaders
		local request
		request = RequestHttp(function(body, err)
			if err then callback(nil, tostring(err)); return end
			if body == nil then return end
			local status, statusLine = request:t_getResponseStatus()
			local contentType = header(responseHeaders, "content-type") or ""
			self.log:info("StandaloneRadio: RadioFeeds response status=", tostring(statusLine), " type=", contentType, " bytes=", tostring(#body))
			if status and status >= 300 and status < 400 then
				local location = header(responseHeaders, "location")
				if not location or redirects >= MAX_REDIRECTS then callback(nil, "RadioFeeds redirect failed"); return end
				self:_fetch(absoluteUrl(url, location), accept, maxBytes, redirects + 1, callback)
				return
			end
			if not status or status < 200 or status >= 300 then callback(nil, "RadioFeeds HTTP " .. tostring(status or statusLine)); return end
			if #body > maxBytes then callback(nil, "RadioFeeds response is too large"); return end
			callback(body, nil, contentType)
		end, "GET", parsed.path, {
			headers = { Host = parsed.host, ["User-Agent"] = USER_AGENT, Accept = accept, Connection = "close" },
			headersSink = function(headers) responseHeaders = headers end,
		})
		local socket = SocketHttp(jnt, ip, parsed.port, "StandaloneRadioRadioFeeds")
		socket.t_getSendHeaders = function() return { ["User-Agent"] = USER_AGENT } end
		self.http = socket
		local ok, fetchErr = pcall(function() socket:fetch(request) end)
		if not ok then callback(nil, tostring(fetchErr)) end
	end)
	return true
end

function RadioFeedsClient:fetchDirectory(url, callback)
	return self:_fetch(url, "application/xml,text/xml,*/*", MAX_OPML_BYTES, 0, function(body, err, contentType)
		if err then callback(nil, err); return end
		local result, parseErr = parseDirectoryResponse(body, contentType)
		callback(result, parseErr)
	end)
end

function parseDirectoryResponse(body, contentType)
	if type(body) ~= "string" then return nil, "RadioFeeds response is empty" end
	if string.find(string.lower(contentType or ""), "html", 1, true) or string.match(body, "^%s*<[Hh][Tt][Mm][Ll]") then
		return nil, "RadioFeeds returned HTML instead of OPML"
	end
	return RadioFeedsOpml.parse(body)
end

function RadioFeedsClient:toStation(item)
	if not item or item.type ~= "audio" or not item.url then return nil, "invalid RadioFeeds station" end
	local station = {
		id = "radiofeeds:" .. stationKey(item.url), stationuuid = stationKey(item.url),
		name = item.title, url = item.url, source = "radiofeeds",
		favicon = item.icon, remoteLogo = item.icon, bitrate = item.bitrate,
		codec = "mp3", playlistUrl = item.url,
	}
	return Stations.normalize(station)
end

function RadioFeedsClient:resolveStation(station, callback)
	local url = station and station.url or ""
	if not string.match(string.lower(url), "%.m3u[%?%#]?") and not string.match(string.lower(url), "%.pls[%?%#]?") then
		callback(station); return true
	end
	return self:_fetch(url, "audio/x-mpegurl,audio/x-scpls,text/plain,*/*", MAX_PLAYLIST_BYTES, 0, function(body, err)
		if err then callback(nil, err); return end
		local resolved = playlistUrl(body)
		if not resolved then callback(nil, "RadioFeeds playlist has no HTTP stream"); return end
		local copy = {}
		for key, value in pairs(station) do copy[key] = value end
		copy.playlistUrl = station.playlistUrl or station.url
		copy.url = absoluteUrl(url, resolved) or resolved
		local normalized, normalizeErr = Stations.normalize(copy)
		callback(normalized, normalizeErr)
	end)
end
