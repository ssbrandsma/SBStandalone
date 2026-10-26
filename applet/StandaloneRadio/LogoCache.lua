local io, os, pcall, setmetatable, tonumber, tostring, type = io, os, pcall, setmetatable, tonumber, tostring, type
local pairs, ipairs, require = pairs, ipairs, require

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
local NEGATIVE_TTL = 3600
local MAX_LISTENERS = 16


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
		active = {}, pending = {}, negative = {},
        clock = options.clock or os.time,
        logoSearchClient = options.logoSearchClient,
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
    local command = "ls -1t " .. shellQuote(CACHE_DIR) .. "/*.png " .. shellQuote(CACHE_DIR) ..
        "/*.jpg 2>/dev/null | tail -n +" .. tostring(MAX_FILES + 1) ..
        " | while read f; do rm -f \"$f\" \"${f%.*}.url\"; done"
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
		socket.t_getSendHeaders = function() return { ["User-Agent"] = "StandaloneRadio/0.9.18" } end
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


local function imageUrl(url)
    if type(url) ~= "string" or not isHttpUrl(url) or #url > 4096 or url:find("[%c%s]") then return nil end
    local path = url:lower():match("^[^?#]+") or ""
    if path:match("%.ico$") then return nil end
    if path:match("^https?://cdn%-radiotime%-logos%.tunein%.com:?%d*/s0q%.png$") then return nil end
    return url
end

local function exactLogo(directory, name)
    local matches, candidate, visited = 0, nil, 0
    local function collect(entries)
        for _,entry in ipairs(entries or {}) do
            visited = visited + 1
            if visited > 1000 then return end
            local text = entry.metadata and entry.metadata.text
            if entry.type == "audio" and entry.item == "station" and not entry.episode
                and type(text) == "string" and text:lower() == name:lower() then
                matches = matches + 1
                candidate = imageUrl(entry.image) -- Never substitute a website icon.
            end
            if entry.children then collect(entry.children) end
        end
    end
    collect(directory and directory.children)
    if visited > 1000 then return nil,"result limit" end
    if matches > 1 then return nil,"ambiguous exact matches" end
    if matches == 0 then return nil,"no exact station match" end
    if not candidate then return nil,"exact match has no usable image or has a placeholder" end
    return candidate
end

function LogoCache:_rememberFailure(uuid)
    local now, count, oldest, oldestTime = self.clock(), 0
    for key, timestamp in pairs(self.negative) do
        if now < timestamp or now - timestamp >= NEGATIVE_TTL then self.negative[key] = nil
        else
            count = count + 1
            if not oldestTime or timestamp < oldestTime then oldest, oldestTime = key, timestamp end
        end
    end
    if not self.negative[uuid] and count >= MAX_FILES then self.negative[oldest] = nil end
    self.negative[uuid] = now
end

function LogoCache:_lookupLogo(station, callback)
    local name = trim(station.name)
    if name == "" or #name > 256 or station.episode then callback(nil);return end
    if not self.logoSearchClient then
        local ok, client = pcall(function()
            local OpmlClient = require("applets.StandaloneRadio.OpmlClient")
            local Providers = require("applets.StandaloneRadio.OpmlProviders")
            return OpmlClient.new({log=self.log,httpsProxyStatus=self.httpsProxyStatus,provider=Providers.get("tunein")})
        end)
        if not ok then self.log:warn("StandaloneRadio: logo lookup unavailable: ",tostring(client));callback(nil);return end
        self.logoSearchClient = client
    end
    local query = name:gsub("([^A-Za-z0-9%-_%.~])",function(c) return string.format("%%%02X",c:byte()) end)
    local url = self.logoSearchClient:searchUrl():gsub("{QUERY}",function() return query end)
    self.log:info("StandaloneRadio: logo lookup station=",name," uuid=",station.stationuuid)
    self.logoSearchClient:fetchDirectory(url,function(directory,err)
        if not directory then self.log:warn("StandaloneRadio: logo lookup failed: ",tostring(err));callback(nil);return end
        local image, reason = exactLogo(directory,name)
        if not image then self.log:info("StandaloneRadio: logo lookup rejected station=",name," reason=",reason);callback(nil);return end
        self.log:info("StandaloneRadio: logo lookup matched station=",name," image=",UrlTransport.redact(image))
        callback(image)
    end)
end

-- Keep the discovered URL with the image: native Now Playing publishes HTTP
-- artwork URLs, not private Lua cache paths. This also survives a Jive restart.
function LogoCache:_cachedUrl(uuid)
    local file = io.open(cachedPath(uuid,"url"),"rb")
    if not file then return nil end
    local url = file:read(4097)
    file:close()
    return imageUrl(url)
end

function LogoCache:_rememberUrl(uuid,url)
    if not imageUrl(url) then return end
    local temp = cachedPath(uuid,"url.tmp")
    local file = io.open(temp,"wb")
    if not file then return end
    local ok = file:write(url)
    local closed = file:close()
    if not ok or not closed or not os.rename(temp,cachedPath(uuid,"url")) then
        os.remove(temp)
        self.log:warn("StandaloneRadio: logo URL cache write failed ",uuid)
    end
end

function LogoCache:_notifyLogo(waiting,path,url)
    if path then
        waiting.station.logoPath = path
        local base = self.applet and self.applet.baseNowPlaying
        if url and base then
            local ok,err = pcall(base.updateStationArtwork,base,url,waiting.station,waiting.generation)
            if not ok then self.log:warn("StandaloneRadio: logo publication failed: ",tostring(err)) end
        end
    end
    waiting.callback(path)
end

function LogoCache:ensure(station, callback)
    callback = callback or function() end
    if not station or (station.source ~= "radiobrowser" and station.source ~= "radiofeeds"
        and station.source ~= "user" and station.source ~= "tunein" and station.source ~= "custom") then
        callback(nil);return
    end
    local uuid = sanitize(station.stationuuid)
    if not uuid then callback(nil);return end
    local generation = self.applet and self.applet.streamPlayer and self.applet.streamPlayer.stationGeneration
    local waiting = {station=station,callback=callback,generation=generation}
    local existing = self:_knownPath(uuid)
    local cachedUrl = existing and (self:_cachedUrl(uuid) or imageUrl(station.remoteLogo or station.favicon))
    if existing and (cachedUrl or station.localLogoPath) then
        self.log:info("StandaloneRadio: logo cache hit ",uuid)
        self:_notifyLogo(waiting,existing,cachedUrl);return
    end
    local pending = self.pending[uuid]
    if pending then
        if #pending < MAX_LISTENERS then pending[#pending+1] = waiting
        else self.log:warn("StandaloneRadio: logo listener limit ",uuid);callback(nil) end
        return
    end
    local failed = self.negative[uuid]
    local now = self.clock()
    if failed and now >= failed and now - failed < NEGATIVE_TTL then callback(nil);return end
    self.negative[uuid] = nil
    pending = {waiting}
    self.pending[uuid], self.active[uuid] = pending, true
    local finished, resolvedUrl = false, nil
    local function finish(path)
        if finished then return end
        finished = true
        self.pending[uuid], self.active[uuid] = nil, nil
        if path then
            self.negative[uuid] = nil
            self:_rememberUrl(uuid,resolvedUrl)
        else self:_rememberFailure(uuid) end
        for _,waiting in ipairs(pending) do
            local ok,err = pcall(self._notifyLogo,self,waiting,path,resolvedUrl)
            if not ok then self.log:warn("StandaloneRadio: logo callback failed: ",tostring(err)) end
        end
    end
    local tempPath = CACHE_DIR .. "/" .. uuid .. ".tmp"
    os.remove(tempPath)
    local function fallback()
        local ok,err = pcall(function()
            self:_lookupLogo(station,function(image)
                if finished then return end
                if not image then finish(nil);return end
                resolvedUrl = image
                self:_download(station,uuid,image,tempPath,finish)
            end)
        end)
        if not ok then self.log:warn("StandaloneRadio: logo fallback failed: ",tostring(err));finish(nil) end
    end
    local function suppliedLogo()
        local favicon = trim(station.favicon or station.remoteLogo)
        if not imageUrl(favicon) then fallback();return end
        self.log:info("StandaloneRadio: downloading logo ",uuid," url=",UrlTransport.redact(favicon))
        resolvedUrl = favicon
        self:_download(station,uuid,favicon,tempPath,function(path)
            if path then finish(path) else fallback() end
        end)
    end
    local ok,err = pcall(function()
        if station.source == "user" and station.localLogoPath then
            self:_cacheLocal(station,tempPath,function(path)
                if path then finish(path) else suppliedLogo() end
            end)
        else suppliedLogo() end
    end)
    if not ok then self.log:warn("StandaloneRadio: logo request failed: ",tostring(err));finish(nil) end
end
