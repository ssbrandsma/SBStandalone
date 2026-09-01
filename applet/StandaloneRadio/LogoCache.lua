local os, setmetatable, tonumber, tostring, type = os, setmetatable, tonumber, tostring, type

local lfs = require("lfs")
local string = require("string")

local Process = require("jive.net.Process")

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
	return string.match(url, "^http://[%w%.%-]+[:%d]*/?.*") ~= nil
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
	}, LogoCache)
end


function LogoCache:cacheDir()
	return CACHE_DIR
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


function LogoCache:ensure(station, callback)
	callback = callback or function() end
	if not station or station.source ~= "radiobrowser" then
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
	if favicon == "" then
		callback(nil)
		return
	end

	self.log:info("StandaloneRadio: favicon for ", tostring(station.name or station.id), " = ", favicon)
	if string.match(string.lower(favicon), "^https://") then
		self.log:warn("StandaloneRadio: favicon download failed; HTTPS not supported by stock wget")
		callback(nil)
		return
	end
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
	local command = "wget -q -T 20 -U StandaloneRadio/0.2 -O - " .. shellQuote(favicon) ..
		" 2>/dev/null | dd of=" .. shellQuote(tempPath) .. " bs=1024 count=513 2>/dev/null"
	local output = ""
	Process(jnt, command):read(function(chunk, err)
		if chunk then
			output = output .. chunk
			return
		end

		self.active[uuid] = nil
		if err then
			os.remove(tempPath)
			self.log:warn("StandaloneRadio: favicon download failed ", tostring(err))
			callback(nil)
			return
		end
		if output ~= "" then
			self.log:warn("StandaloneRadio: favicon download output ", output)
		end
		self:_finishDownload(station, tempPath, callback)
	end)
end
