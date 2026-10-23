local io, os, pcall, setmetatable, tonumber, tostring, type = io, os, pcall, setmetatable, tonumber, tostring, type
local pairs = pairs

local lfs = require("lfs")
local string = require("string")

local Process = require("jive.net.Process")
local RequestHttp = require("jive.net.RequestHttp")
local Resolver = require("applets.StandaloneRadio.Resolver")
local SocketHttp = require("jive.net.SocketHttp")
local UrlTransport = require("applets.StandaloneRadio.UrlTransport")

local jnt = jnt

module(...)


local LogoCache = {}
LogoCache.__index = LogoCache

local CACHE_DIR = "/etc/squeezeplay/userpath/StandaloneRadio/cache/logos"
local MAX_BYTES = 512 * 1024
local MAX_FILES = 100


local function trim(value)
	return tostring(value or ""):gsub("^%s*(.-)%s*$", "%1")
end


local function sanitize(value)
	value = trim(value)
	if string.match(value, "^[%w%-]+$") then
		return value
	end
	return nil
end


local function shellQuote(value)
	return "'" .. tostring(value):gsub("'", "'\\''") .. "'"
end


local function ensureDir(path)
	local current = ""
	for part in string.gmatch(path, "[^/]+") do
		current = current .. "/" .. part
		if not lfs.attributes(current, "mode") then
			lfs.mkdir(current)
		end
	end
end


local function isHttpUrl(url)
	return string.match(url, "^https?://[%w%.%-]+[:%d]*/?.*") ~= nil
end



local function firstBytes(path, count)
	local file = io.open(path, "rb")
	if not file then
		return nil
	end
	local data = file:read(count)
	file:close()
	return data
end


local function detectFormat(path)
	local data = firstBytes(path, 12)
	if not data then
		return nil
	end
	if string.sub(data, 1, 8) == "\137PNG\r\n\026\n" then
		return "png"
	end
	if string.sub(data, 1, 3) == "\255\216\255" then
		return "jpg"
	end
	return nil
end


local function cachedPath(uuid, ext)
	return CACHE_DIR .. "/" .. uuid .. "." .. ext
end


function new(options)
	ensureDir(CACHE_DIR)
	return setmetatable({
		applet = options.applet,
		log = options.log,
		active = {},
		resolver = Resolver.new({ log = options.log }),
		httpsProxyStatus = options.httpsProxyStatus,
	}, LogoCache)
end


function LogoCache:_knownPath(uuid)
	local png = cachedPath(uuid, "png")
	if lfs.attributes(png, "mode") == "file" then
		return png
	end
	local jpg = cachedPath(uuid, "jpg")
	if lfs.attributes(jpg, "mode") == "file" then
		return jpg
	end
	return nil
end


function LogoCache:_prune()
	local command = "ls -1t " .. shellQuote(CACHE_DIR) .. " 2>/dev/null | tail -n +" .. tostring(MAX_FILES + 1) ..
		" | while read f; do rm -f " .. shellQuote(CACHE_DIR) .. "/\"$f\"; done"
	Process(jnt, command):read(function() end)
end


function LogoCache:_finishDownload(station, tempPath, callback)
	local uuid = sanitize(station.stationuuid)
	local size = tonumber(lfs.attributes(tempPath, "size")) or 0
	if size <= 0 or size > MAX_BYTES then
		os.remove(tempPath)
		self.log:warn("StandaloneRadio: favicon download failed for ", tostring(station.id), " size=", tostring(size))
		callback(nil)
		return
	end

	local ext = detectFormat(tempPath)
	if not ext then
		os.remove(tempPath)
		self.log:warn("StandaloneRadio: unsupported station logo format")
		callback(nil)
		return
	end

	local path = cachedPath(uuid, ext)
	os.remove(path)
	local ok = os.rename(tempPath, path)
	if not ok then
		os.remove(tempPath)
		self.log:warn("StandaloneRadio: favicon cache write failed for ", tostring(station.id))
		callback(nil)
		return
	end

	station.favicon = station.favicon or station.remoteLogo
	station.logoPath = path
	self.log:info("StandaloneRadio: logo cached ", path)
	self:_prune()
	callback(path)
end


function LogoCache:_download(station, uuid, url, tempPath, callback, svgRetry)
	local trace=UrlTransport.beginTrace and UrlTransport.beginTrace("logo:"..tostring(station.id),url)
	if trace then
		local original=callback
		callback=function(path) trace:result(path and "decoded and cached" or "logo unavailable"); return original(path) end
	end
	local target, targetErr = UrlTransport.forRequest(url, self.log)
	if not target then
		if trace then trace:finish(targetErr) end
		self.active[uuid] = nil
		self.log:warn("StandaloneRadio: favicon transport failed: ", tostring(targetErr))
		callback(nil)
		return
	end
	self.resolver:resolve(target.host, function(ip)
		if not ip then
			if trace then trace:finish("DNS failed: "..target.host) end
			self.active[uuid] = nil
			self.log:warn("StandaloneRadio: favicon DNS failed")
			callback(nil)
			return
		end
		local request
		local responseHeaders
		local done = false
		request = RequestHttp(function(body, err)
			if done then return end
			if body == nil and not err then return end
			done = true
			self.active[uuid] = nil
			if err or type(body) ~= "string" or #body == 0 or #body > MAX_BYTES then
				if err and target.proxied and self.httpsProxyStatus then self.httpsProxyStatus:transportFailed(url) end
				self.log:warn("StandaloneRadio: favicon download failed ", tostring(err or "invalid size"))
				callback(nil)
				return
			end
			local status = request:t_getResponseStatus()
			if status and (status < 200 or status >= 300) then
				self.log:warn("StandaloneRadio: favicon HTTP ", tostring(status))
				callback(nil)
				return
			end
			-- MIME-less SVG endpoints can be recognized as XML and retried once.
			-- The native service validates/renders the content; Lua does not parse it.
			local svgMime = false
			for name, value in pairs(responseHeaders or {}) do
				if tostring(name):lower() == "content-type" and tostring(value):lower():match("^image/svg%+xml") then svgMime = true end
			end
			if not svgRetry and (svgMime or body:match("^%s*<")) then
				local rendered = UrlTransport.renderSvgUrl(url, "image/svg+xml")
				if rendered and rendered ~= url then
					self.active[uuid] = true
					self:_download(station, uuid, rendered, tempPath, callback, true)
					return
				end
			end
			local file = io.open(tempPath, "wb")
			if not file then callback(nil); return end
			file:write(body)
			file:close()
			self:_finishDownload(station, tempPath, callback)
		end, "GET", target.path, { headers = {
			Host = target.hostHeader, Accept = "image/png,image/jpeg,*/*", Connection = "close",
		}, headersSink = function(headers) responseHeaders = headers end })
		request._standaloneTrace=trace
		local socket = SocketHttp(jnt, ip, target.port, "StandaloneRadioLogo")
		socket.t_getSendHeaders = function() return { ["User-Agent"] = "StandaloneRadio/0.9.12" } end
		self.http = socket
		local ok, fetchErr = pcall(function() socket:fetch(request) end)
		if not ok then
			self.active[uuid] = nil
			if target.proxied and self.httpsProxyStatus then self.httpsProxyStatus:transportFailed(url) end
			self.log:warn("StandaloneRadio: favicon request failed ", tostring(fetchErr))
			callback(nil)
		end
	end)
end


function LogoCache:_cacheLocal(station, tempPath, callback)
	local file = io.open(station.localLogoPath, "rb")
	if not file then callback(nil); return end
	local body = file:read(MAX_BYTES + 1)
	file:close()
	if type(body) ~= "string" or #body == 0 or #body > MAX_BYTES then
		self.log:warn("StandaloneRadio: local station logo is empty or too large id=", tostring(station.id))
		callback(nil)
		return
	end
	local output = io.open(tempPath, "wb")
	if not output then callback(nil); return end
	output:write(body)
	output:close()
	self:_finishDownload(station, tempPath, callback)
end


function LogoCache:ensure(station, callback)
	callback = callback or function() end
	if not station or (station.source ~= "radiobrowser" and station.source ~= "radiofeeds"
		and station.source ~= "user" and station.source ~= "tunein") then
		callback(nil)
		return
	end
	local uuid = sanitize(station.stationuuid)
	if not uuid then
		callback(nil)
		return
	end

	local existing = self:_knownPath(uuid)
	if existing then
		station.logoPath = existing
		self.log:info("StandaloneRadio: logo cache hit ", uuid)
		callback(existing)
		return
	end
	local tempPath = CACHE_DIR .. "/" .. uuid .. ".tmp"
	if station.source == "user" and station.localLogoPath then
		os.remove(tempPath)
		self:_cacheLocal(station, tempPath, function(path)
			if path then callback(path); return end
			station.localLogoPath = nil
			self:ensure(station, callback)
		end)
		return
	end

	local favicon = trim(station.favicon or station.remoteLogo)
	station.favicon = favicon
	station.remoteLogo = favicon
	if favicon == "" then
		callback(nil)
		return
	end

	self.log:info("StandaloneRadio: favicon for ", tostring(station.name or station.id), " = ", UrlTransport.redact(favicon))
	if not isHttpUrl(favicon) then
		self.log:warn("StandaloneRadio: favicon download failed; invalid URL")
		callback(nil)
		return
	end
	if string.match(string.lower(favicon), "%.ico[%?%#]?$") then
		self.log:warn("StandaloneRadio: unsupported station logo format")
		callback(nil)
		return
	end
	if self.active[uuid] then
		callback(nil)
		return
	end

	self.active[uuid] = true
	os.remove(tempPath)
	self.log:info("StandaloneRadio: downloading logo ", uuid)
	self.log:info("StandaloneRadio: logo route=async-http url=", UrlTransport.redact(favicon))
	self:_download(station, uuid, favicon, tempPath, callback)
end
