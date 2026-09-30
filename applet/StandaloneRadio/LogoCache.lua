local io, os, setmetatable, tonumber, tostring, type = io, os, setmetatable, tonumber, tostring, type

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


function LogoCache:_download(station, uuid, url, tempPath, callback)
	local target, targetErr = UrlTransport.forRequest(url, self.log)
	if not target then
		self.active[uuid] = nil
		self.log:warn("StandaloneRadio: favicon transport failed: ", tostring(targetErr))
		callback(nil)
		return
	end
	self.resolver:resolve(target.host, function(ip)
		if not ip then
			self.active[uuid] = nil
			self.log:warn("StandaloneRadio: favicon DNS failed")
			callback(nil)
			return
		end
		local request
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
			local file = io.open(tempPath, "wb")
			if not file then callback(nil); return end
			file:write(body)
			file:close()
			self:_finishDownload(station, tempPath, callback)
		end, "GET", target.path, { headers = {
			Host = target.hostHeader, Accept = "image/png,image/jpeg,*/*", Connection = "close",
		} })
		local socket = SocketHttp(jnt, ip, target.port, "StandaloneRadioLogo")
		socket.t_getSendHeaders = function() return { ["User-Agent"] = "StandaloneRadio/0.9.0" } end
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


function LogoCache:ensure(station, callback)
	callback = callback or function() end
	if not station or (station.source ~= "radiobrowser" and station.source ~= "radiofeeds") then
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

	local favicon = trim(station.favicon or station.remoteLogo)
	station.favicon = favicon
	station.remoteLogo = favicon
	if favicon == "" then
		callback(nil)
		return
	end

	self.log:info("StandaloneRadio: favicon for ", tostring(station.name or station.id), " = ", favicon)
	if not isHttpUrl(favicon) then
		self.log:warn("StandaloneRadio: favicon download failed; invalid URL")
		callback(nil)
		return
	end
	if string.match(string.lower(favicon), "%.svg[%?%#]?$") or string.match(string.lower(favicon), "%.ico[%?%#]?$") then
		self.log:warn("StandaloneRadio: unsupported station logo format")
		callback(nil)
		return
	end
	if self.active[uuid] then
		callback(nil)
		return
	end

	self.active[uuid] = true
	local tempPath = CACHE_DIR .. "/" .. uuid .. ".tmp"
	os.remove(tempPath)
	self.log:info("StandaloneRadio: downloading logo ", uuid)
	self.log:info("StandaloneRadio: logo route=async-http url=", UrlTransport.redact(favicon))
	self:_download(station, uuid, favicon, tempPath, callback)
end
