local ipairs, pairs, pcall, setmetatable, tonumber, tostring, type = ipairs, pairs, pcall, setmetatable, tonumber, tostring, type
local string = require("string")
local table = require("table")
local URL = require("socket.url")

local RequestHttp = require("jive.net.RequestHttp")
local Resolver = require("applets.StandaloneRadio.Resolver")
local RadioFeedsOpml = require("applets.StandaloneRadio.RadioFeedsOpml")
local SocketHttp = require("jive.net.SocketHttp")
local Stations = require("applets.StandaloneRadio.Stations")
local UrlTransport = require("applets.StandaloneRadio.UrlTransport")
local jnt = jnt

module(...)

local RadioFeedsClient = {}
RadioFeedsClient.__index = RadioFeedsClient

local ROOT_URL = "http://www.radiofeeds.co.uk/MyPicks/menu.opml?username=forusewithstandalone"
local SEARCH_URL = "http://www.radiofeeds.co.uk/MyPicks/integsearchall.opml?term={QUERY}&username=forusewithstandalone&search=1&center=1"
local USER_AGENT = "Lyrion Music Server"
local MAX_OPML_BYTES = 256 * 1024
local MAX_PLAYLIST_BYTES = 64 * 1024
local MAX_REDIRECTS = 5
local MAX_PLAYLISTS = 5


local function parseUrl(url)
	local scheme, host, port, path = string.match(tostring(url or ""), "^(https?)://([^/:]+):?(%d*)(/.*)$")
	if not host then return nil, "RadioFeeds requires an HTTP or HTTPS URL" end
	return { scheme = scheme, host = host, port = tonumber(port) or (scheme == "https" and 443 or 80), path = path, url = url }
end

local function header(headers, wanted)
	for name, value in pairs(headers or {}) do
		if string.lower(name) == wanted then return value end
	end
end

local function absoluteUrl(base, location)
	if type(location) ~= "string" or location == "" then return nil end
	local resolved = URL.absolute(base, location)
	if not parseUrl(resolved) then return nil end
	return resolved
end

local function usablePlaylistUrl(base, location)
	local resolved = absoluteUrl(base, location)
	local baseParts = parseUrl(base)
	local resolvedParts = parseUrl(resolved)
	if not baseParts or not resolvedParts then return resolved end
	local host = string.lower(resolvedParts.host)
	if host ~= "localhost" and host ~= "127.0.0.1" and host ~= "0.0.0.0" then return resolved end
	return resolvedParts.scheme .. "://" .. baseParts.host
		.. ((resolvedParts.port ~= (resolvedParts.scheme == "https" and 443 or 80)) and (":" .. resolvedParts.port) or "")
		.. resolvedParts.path
end

local function stationKey(url)
	local hash = 5381
	for index = 1, #url do hash = (hash * 33 + string.byte(url, index)) % 2147483647 end
	return "rf" .. tostring(hash)
end

local function playlistUrl(body)
	local isPLS = string.find(string.lower(body or ""), "%[playlist%]") ~= nil
	for line in string.gmatch(body or "", "[^\r\n]+") do
		line = string.gsub(line, "^%s*(.-)%s*$", "%1")
		local value = string.match(line, "^[Ff][Ii][Ll][Ee]%d+=([^\r\n]+)$")
		if value then return string.gsub(value, "^%s*(.-)%s*$", "%1") end
		if not isPLS and line ~= "" and string.sub(line, 1, 1) ~= "#" then return line end
	end
end

function isPlaylistUrl(url)
	local path = string.match(string.lower(tostring(url or "")), "^[^?#]+") or ""
	return string.match(path, "%.m3u8?$") ~= nil or string.match(path, "%.pls$") ~= nil
end

-- HLS may contain absolute or relative segment URLs. Neither is a complete
-- continuous stream: never pass its first segment to the ordinary decoder.
function resolvePlaylistResponse(base, body)
	if type(body) ~= "string" then return nil, "RadioFeeds playlist is empty" end
	body = string.gsub(body, "^\239\187\191", "")
	for line in string.gmatch(body, "[^\r\n]+") do
		if string.match(line, "^%s*#EXT%-X%-") then
			return base, nil, "hls"
		end
	end
	local location = playlistUrl(body)
	local resolved = location and usablePlaylistUrl(base, location)
	if not resolved or string.find(resolved, "[%s%z<>]") then return nil, "RadioFeeds playlist has no HTTP stream" end
	return resolved
end

local function stationCodec(item)
	local explicit = string.lower(tostring(item.codec or ""))
	if explicit ~= "" then return explicit end
	local title = string.lower(tostring(item.title or ""))
	if string.find(title, "(aacplus)", 1, true) or string.find(title, "(aac+)", 1, true) then return "aac+" end
	if string.find(title, "%(aac[%s%)]") then return "aac" end
	if string.find(title, "(ogg)", 1, true) then return "ogg" end
	if string.find(title, "(flac)", 1, true) then return "flac" end
	if string.find(title, "(aiff)", 1, true) or string.find(title, "(aif)", 1, true) then return "aif" end
	if string.find(title, "(pcm)", 1, true) then return "pcm" end
	return "mp3"
end

function new(options)
	return setmetatable({
		log = options.log,
		resolver = Resolver.new({ log = options.log }),
		httpsProxyStatus = options.httpsProxyStatus,
	}, RadioFeedsClient)
end

function RadioFeedsClient:rootUrl()
	return ROOT_URL
end

function RadioFeedsClient:searchUrl()
	return SEARCH_URL
end

function RadioFeedsClient:_fetch(url, accept, maxBytes, redirects, callback)
	local streaming = maxBytes == MAX_PLAYLIST_BYTES
	local generation = self.playlistGeneration
	local parsed, parseErr = UrlTransport.forRequest(url, self.log)
	if not parsed then callback(nil, parseErr); return false end
	self.log:info("StandaloneRadio: RadioFeeds GET ", UrlTransport.redact(url))
	self.resolver:resolve(parsed.host, function(ip)
		if streaming and generation ~= self.playlistGeneration then return end
		if not ip then callback(nil, "RadioFeeds DNS failed"); return end
		local responseHeaders
		local request
		local socket
		local completed = false
		local chunks, bytes = {}, 0
		local function tooLarge()
			if completed then return end
			completed = true
			chunks = {}
			if self.playlistHttp == socket then self.playlistHttp = nil end
			if self.http == socket then self.http = nil end
			if socket and socket.close then pcall(function() socket:close() end) end
			callback(nil, "RadioFeeds response is too large")
		end
		request = RequestHttp(function(body, err)
			if completed or (streaming and generation ~= self.playlistGeneration) then return end
			if streaming and body and not err then
				if #body > maxBytes - bytes then tooLarge(); return end
				bytes = bytes + #body
				chunks[#chunks+1] = body
				if #chunks >= 128 then chunks = {table.concat(chunks)} end
				return
			end
			if not streaming and body == nil and not err then return end
			completed = true
			if streaming then
				if self.playlistHttp == socket then self.playlistHttp = nil end
				if self.http == socket then self.http = nil end
				if not err then body = table.concat(chunks) end
				chunks = {}
			end
			if err then
				if parsed.proxied and self.httpsProxyStatus then self.httpsProxyStatus:transportFailed(url) end
				callback(nil, tostring(err)); return
			end
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
			local effectiveUrl = url
			if not parsed.proxied and request.getURI then
				local candidate = URL.build(request:getURI())
				if parseUrl(candidate) then effectiveUrl = candidate end
			end
			callback(body, nil, contentType, effectiveUrl)
		end, "GET", parsed.path, {
			stream = streaming,
			headers = { Host = parsed.hostHeader, ["User-Agent"] = USER_AGENT, Accept = accept, Connection = "close" },
			headersSink = function(headers)
				responseHeaders = headers
				local length = tonumber(header(headers, "content-length") or "")
				if streaming and length and length > maxBytes then tooLarge() end
			end,
		})
		socket = SocketHttp(jnt, ip, parsed.port, "StandaloneRadioRadioFeeds")
		socket.t_getSendHeaders = function() return { ["User-Agent"] = USER_AGENT } end
		self.http = socket
		if streaming then self.playlistHttp = socket end
		local ok, fetchErr = pcall(function() socket:fetch(request) end)
		if not ok and not completed then
			completed = true
			if parsed.proxied and self.httpsProxyStatus then self.httpsProxyStatus:transportFailed(url) end
			callback(nil, tostring(fetchErr))
		end
	end)
	return true
end

-- Cancel only playlist work, not a directory/search request on this client.
function RadioFeedsClient:cancelPlaylist()
	self.playlistGeneration = (self.playlistGeneration or 0) + 1
	local socket = self.playlistHttp
	self.playlistHttp = nil
	if self.http == socket then self.http = nil end
	if socket and socket.close then pcall(function() socket:close() end) end
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
		codec = stationCodec(item), playlistUrl = item.url,
	}
	return Stations.normalize(station)
end

function RadioFeedsClient:resolveStation(station, callback, force)
	self:cancelPlaylist()
	local generation = self.playlistGeneration
	local url = station and station.url or ""
	if station and station.hls then callback(station); return true end
	if not force and not isPlaylistUrl(url) then
		callback(station); return true
	end
	local visited, depth, finished = {}, 0, false
	local function finish(result, err, code)
		if finished or generation ~= self.playlistGeneration then return end
		finished = true
		callback(result, err, code)
	end
	local resolve
	resolve = function(current)
		if visited[current] or depth >= MAX_PLAYLISTS then
			finish(nil, "RadioFeeds playlist loop or nesting limit reached"); return
		end
		visited[current], depth = true, depth + 1
		self:_fetch(current, "audio/x-mpegurl,application/vnd.apple.mpegurl,audio/x-scpls,text/plain,*/*", MAX_PLAYLIST_BYTES, 0, function(body, err, contentType, effectiveUrl)
			if finished then return end
			if err then finish(nil, err); return end
			local resolved, parseErr, code = resolvePlaylistResponse(effectiveUrl or current, body)
			if not resolved then finish(nil, parseErr, code); return end
			if code ~= "hls" and isPlaylistUrl(resolved) then resolve(resolved); return end
			local copy = {}
			for key, value in pairs(station) do copy[key] = value end
			copy.playlistUrl = station.playlistUrl or station.url
			copy.url = resolved
			copy.hls = code == "hls" or nil
			local normalized, normalizeErr = Stations.normalize(copy)
			finish(normalized, normalizeErr)
		end)
	end
	resolve(url)
	return true
end
