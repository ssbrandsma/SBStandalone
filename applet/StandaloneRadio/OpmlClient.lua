local os = os
local ipairs, pairs, pcall, setmetatable, tonumber, tostring, type = ipairs, pairs, pcall, setmetatable, tonumber, tostring, type
local string = require("string")
local table = require("table")
local URL = require("socket.url")

local RequestHttp = require("jive.net.RequestHttp")
local Resolver = require("applets.StandaloneRadio.Resolver")
local OpmlParser = require("applets.StandaloneRadio.OpmlParser")
local SocketHttp = require("jive.net.SocketHttp")
local Stations = require("applets.StandaloneRadio.Stations")
local UrlTransport = require("applets.StandaloneRadio.UrlTransport")
local timerAvailable, Timer = pcall(require,"jive.ui.Timer")
local jnt = jnt

module(...)

local OpmlClient = {}
OpmlClient.__index = OpmlClient

local USER_AGENT = "Standalone/0.9.13"
local MAX_OPML_BYTES = 256 * 1024
local MAX_PLAYLIST_BYTES = 64 * 1024
local MAX_REDIRECTS = 5
local MAX_PLAYLISTS = 5


local function parseUrl(url)
	local scheme, host, port, path = string.match(tostring(url or ""), "^(https?)://([^/:]+):?(%d*)(/.*)$")
	if not host then return nil, "OPML requires an HTTP or HTTPS URL" end
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
	return tostring(hash)
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
	if type(body) ~= "string" then return nil, "OPML playlist is empty" end
	body = string.gsub(body, "^\239\187\191", "")
	for line in string.gmatch(body, "[^\r\n]+") do
		if string.match(line, "^%s*#EXT%-X%-") then
			return base, nil, "hls"
		end
	end
	local location = playlistUrl(body)
	local resolved = location and usablePlaylistUrl(base, location)
	if not resolved or string.find(resolved, "[%s%z<>]") then return nil, "OPML playlist has no HTTP stream" end
	return resolved
end

function new(options)
	return setmetatable({
		log = options.log,
		provider = options.provider,
		userAgent = options.userAgent or USER_AGENT,
		resolver = Resolver.new({ log = options.log }),
		httpsProxyStatus = options.httpsProxyStatus,
	}, OpmlClient)
end

function OpmlClient:rootUrl()
	return self.provider and self.provider.root
end

function OpmlClient:searchUrl()
	return self.provider and self.provider.search
end

function OpmlClient:_fetch(url, accept, maxBytes, redirects, callback, visited, parent)
    visited=visited or {}
    if visited[url] then callback(nil,"OPML redirect loop");return function() end end
    visited[url]=true
	local trace=UrlTransport.beginTrace and UrlTransport.beginTrace(self.provider and self.provider.id or "opml",url,parent)
	local playlist = maxBytes == MAX_PLAYLIST_BYTES
	local streaming = true
	local generation = self.playlistGeneration
    local finished,cancelled=false,false
    local timer,socketRef,childCancel
    local originalCallback=callback
    local function cancel()
        if cancelled or finished then return end
        cancelled=true
        if timer then timer:stop() end
        if childCancel then childCancel() end
        if trace then trace:finish("cancelled") end
        if socketRef and socketRef.close then socketRef:close("cancelled") end
    end
    callback=function(body,err,mime,effective)
        if finished or cancelled then return end
        finished=true
        if timer then timer:stop() end
        if trace then trace:finish(err, type(body)=="string" and #body or nil) end
        return originalCallback(body,err,mime,effective,trace and trace.id)
    end
    if timerAvailable then
        timer=Timer(15000,function()
            if finished or cancelled then return end
            callback(nil,"OPML request timed out")
            if childCancel then childCancel() end
            if socketRef and socketRef.close then socketRef:close("timeout") end
        end,true);timer:start()
    end
	local parsed, parseErr = UrlTransport.forRequest(url, self.log)
	if not parsed then if trace then trace:finish(parseErr) end; callback(nil, parseErr); return false end
	self.log:info("StandaloneRadio: OPML GET ", UrlTransport.redact(url))
	self.resolver:resolve(parsed.host, function(ip)
		if cancelled or finished then return end
		if playlist and generation ~= self.playlistGeneration then if trace then trace:finish("cancelled") end; return end
		if not ip then if trace then trace:finish("DNS failed: "..parsed.host) end; callback(nil, "OPML DNS failed"); return end
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
			callback(nil, "OPML response is too large")
		end
		request = RequestHttp(function(body, err)
			if completed or finished or cancelled or (playlist and generation ~= self.playlistGeneration) then return end
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
			self.log:info("StandaloneRadio: OPML response status=", tostring(statusLine), " type=", contentType, " bytes=", tostring(#body))
			if status and status >= 300 and status < 400 then
                if trace then trace:finish(nil,bytes) end
                -- Stop reading this hop without closing a socket inside its read task.
                -- A redirect body may never finish; it must not leave an orphan reader.
                if socket and socket.close then
                    if timerAvailable then
                        local closeTimer
                        closeTimer=Timer(1,function() closeTimer:stop();socket:close("redirect complete") end,true)
                        closeTimer:start()
                    else pcall(function() socket:close("redirect complete") end) end
                end
				local location = header(responseHeaders, "location")
				if not location or location=="" or redirects >= MAX_REDIRECTS then callback(nil, "OPML redirect failed"); return end
                local nextUrl=absoluteUrl(url, location)
                local target,targetErr=UrlTransport.forRequest(nextUrl,self.log)
                if not target then callback(nil,"OPML redirect transport error: "..tostring(targetErr));return end
                if timer then timer:stop() end
                self.log:info("HTTPTRACE event=redirect id=",trace and trace.id or "-",
                    " from_scheme=",url:match("^(%w+):")," to_scheme=",nextUrl:match("^(%w+):"),
                    " transport=",target.proxied and "sbproxy" or "http", " status=",tostring(status))
                childCancel = self:_fetch(nextUrl, accept, maxBytes, redirects + 1, callback,visited,trace and trace.id)
				return
			end
			if not status or status < 200 or status >= 300 then callback(nil, "OPML HTTP " .. tostring(status or statusLine)); return end
			if #body > maxBytes then callback(nil, "OPML response is too large"); return end
			local effectiveUrl = url
			if not parsed.proxied and request.getURI then
				local candidate = URL.build(request:getURI())
				if parseUrl(candidate) then effectiveUrl = candidate end
			end
			callback(body, nil, contentType, effectiveUrl)
		end, "GET", parsed.path, {
			stream = streaming,
			headers = { Host = parsed.hostHeader, ["User-Agent"] = self.userAgent, Accept = accept, Connection = "close" },
			headersSink = function(headers)
				responseHeaders = headers
				local mime=string.lower(header(headers,"content-type") or "")
				local status=request:t_getResponseStatus()
				if playlist and status==200 and not mime:find("url",1,true) and (mime:match("^audio/mpeg") or mime:match("^audio/aac") or mime:match("^audio/ogg") or mime:match("^audio/flac")) then
					completed=true
					local effective=url
					if not parsed.proxied and request.getURI then effective=URL.build(request:getURI()) end
					callback("",nil,mime,effective)
					if socket and socket.close then
						if timerAvailable then
							socket._opmlCloseTimer=Timer(1,function() socket._opmlCloseTimer=nil;socket:close() end,true)
							socket._opmlCloseTimer:start()
						else socket:close() end
					end
					return
				end
				if status and status>=300 and status<400 then return end -- redirect bodies are discarded
				local length = tonumber(header(headers, "content-length") or "")
				if streaming and length and length > maxBytes then tooLarge() end
			end,
		})
		if UrlTransport.explicitRedirects then UrlTransport.explicitRedirects(request) end
		request._standaloneTrace=trace
		socket = SocketHttp(jnt, ip, parsed.port, "StandaloneRadioOpml")
		socket.t_getSendHeaders = function() return { ["User-Agent"] = self.userAgent } end
		self.http = socket
		if playlist then self.playlistHttp = socket end
		socketRef=socket
		local ok, fetchErr = pcall(function() socket:fetch(request) end)
		if not ok and not completed then
			completed = true
			if parsed.proxied and self.httpsProxyStatus then self.httpsProxyStatus:transportFailed(url) end
			callback(nil, tostring(fetchErr))
		end
	end)
	return cancel
end

-- Cancel only playlist work, not a directory/search request on this client.
function OpmlClient:cancelPlaylist()
	if type(self.playlistCancel)=="function" then self.playlistCancel() end
	self.playlistCancel=nil
	self.playlistGeneration = (self.playlistGeneration or 0) + 1
	local socket = self.playlistHttp
	self.playlistHttp = nil
	if self.http == socket then self.http = nil end
	if socket and socket.close then pcall(function() socket:close() end) end
end

-- Only custom directories opt into this short-lived, RAM-only two-page cache.
-- At most one distinct directory fetch is active; identical requests coalesce.
function OpmlClient:fetchDirectory(url,callback)
    local ttl=self.provider and self.provider.directoryCacheTtl
    if not ttl then return self:_fetchDirectory(url,callback) end
    local now=os.time()
    self.directoryCache=self.directoryCache or {}
    for _,entry in ipairs(self.directoryCache) do
        if (entry.url==url or entry.request==url) and now>=entry.time and now-entry.time<ttl then callback(entry.value);return function() end end
    end
    local pending=self.directoryPending
    if pending and pending.url~=url then callback(nil,"OPML directory request busy");return function() end end
    if pending and #pending.listeners>=8 then callback(nil,"OPML listener limit reached");return function() end end
    if not pending then pending={url=url,listeners={}};self.directoryPending=pending end
    local listener={callback=callback};pending.listeners[#pending.listeners+1]=listener
    if not pending.started then
        pending.started=true
        pending.cancel=self:_fetchDirectory(url,function(directory,err)
            if self.directoryPending~=pending then return end
            self.directoryPending=nil
            if directory then
                for i=#self.directoryCache,1,-1 do if self.directoryCache[i].url==directory.url then table.remove(self.directoryCache,i) end end
                self.directoryCache[#self.directoryCache+1]={url=directory.url,request=url,value=directory,time=os.time()}
                while #self.directoryCache>2 do table.remove(self.directoryCache,1) end
            end
            for _,waiting in ipairs(pending.listeners) do if not waiting.cancelled then waiting.callback(directory,err) end end
        end)
    end
    return function()
        listener.cancelled=true
        for _,waiting in ipairs(pending.listeners) do if not waiting.cancelled then return end end
        if self.directoryPending==pending then self.directoryPending=nil;if pending.cancel then pending.cancel() end end
    end
end

function OpmlClient:_fetchDirectory(url, callback)
	if self.provider and self.provider.prepareUrl then url=self.provider.prepareUrl(url) end
	return self:_fetch(url, "application/xml,text/xml,*/*", MAX_OPML_BYTES, 0, function(body, err, contentType, effectiveUrl)
		if err then callback(nil, err); return end
		local result, parseErr = parseDirectoryResponse(body, contentType)
		if result then
			local function normalize(entries)
				for _,entry in ipairs(entries or {}) do
					for _,field in ipairs({"url","image","icon","homepage"}) do
						if entry[field] then
							entry[field]=absoluteUrl(effectiveUrl or url,entry[field])
							if field=="url" and entry[field] and self.provider and self.provider.prepareUrl then entry[field]=self.provider.prepareUrl(entry[field]) end
						end
					end
					if entry.children then normalize(entry.children) end
				end
			end
			normalize(result.children)
		end
		if result then result.url=effectiveUrl or url end
        callback(result, parseErr)
	end)
end

function parseDirectoryResponse(body, contentType)
	if type(body) ~= "string" then return nil, "OPML response is empty" end
	if string.find(string.lower(contentType or ""), "html", 1, true) or string.match(body, "^%s*<[Hh][Tt][Mm][Ll]") then
		return nil, "OPML returned HTML instead of OPML"
	end
	return OpmlParser.parse(body)
end

local function preferredCodec(formats)
	local supported={mp3=true,aac=true,["aac+"]=true,ogg=true,flac=true,pcm=true,aif=true,aiff=true}
	for token in tostring(formats or ""):lower():gmatch("[%w+]+") do
		if token=="aacplus" then token="aac+" end
		if supported[token] then return token end
	end
end

-- Return a bounded candidate list without fetching audio payloads.
function streamCandidates(base, body, contentType)
	if type(body)~="string" then return nil,"OPML resolver response is empty" end
	body=body:gsub("^\239\187\191","")
	if body:find("#EXT%-X%-") then return {{url=base,hls=true}} end
	local candidates={}
	local function add(location, codec, resolver, bitrate)
		if #candidates>=16 or type(location)~="string" then return end
		location=location:match("^%s*(.-)%s*$")
		local scheme=location:match("^(%a[%w+.-]*):")
		if scheme and scheme~="http" and scheme~="https" then return end
		local url=usablePlaylistUrl(base,location)
		if url and #url<=4096 and not url:find("[%s%z<>]") then candidates[#candidates+1]={url=url,codec=codec,resolver=resolver,bitrate=bitrate} end
	end
	if body:match("^%s*<") then
		local directory,err=OpmlParser.parse(body)
		if not directory then return nil,err end
		local function collect(entries)
			for _,entry in ipairs(entries or {}) do
				if entry.url and (entry.type=="audio" or entry.type=="link") then
					local declared=entry.codec or entry.formats
					local codec=preferredCodec(declared)
					if not declared or codec then add(entry.url,codec,entry.type=="link",entry.bitrate) end
				end
				if entry.children then collect(entry.children) end
			end
		end
		collect(directory.children)
	else
		local pls=body:lower():find("%[playlist%]")
		for line in body:gmatch("[^\r\n]+") do
			line=line:match("^%s*(.-)%s*$")
			local value=line:match("^[Ff][Ii][Ll][Ee]%d+%s*=%s*(.+)$")
			if value then add(value)
			elseif not pls and line~="" and line:sub(1,1)~="#" then add(line) end
		end
	end
	if #candidates==0 then return nil,"OPML resolver has no supported HTTP stream" end
	return candidates
end

function OpmlClient:toStation(item)
    if not item or item.type ~= "audio" or not item.url then return nil, "invalid OPML station" end
    local provider=self.provider or {id="opml"}
    local key=tostring(provider.stationKey and provider.stationKey(item) or item.guide_id or item.id or stationKey(item.url))
    local url=provider.prepareUrl and provider.prepareUrl(item.url) or item.url
    local codec=preferredCodec(item.codec or item.formats)
    local station={
        id=provider.id..":"..key,stationuuid=provider.id.."-"..key:gsub("[^%w%-]","-"),
        name=item.title,url=url,source=provider.id,provider=provider.id,providerId=key,
        resolverUrl=url,playlistUrl=url,requiresResolution=provider.requiresResolution or false,
        codec=codec,declaredCodec=codec,declaredFormats=item.formats or item.codec,bitrate=item.bitrate,
        favicon=item.image or item.icon,remoteLogo=item.image or item.icon,
        description=item.description,programDescription=item.subtext,
        catalogPlaying=item.playing or item.current_track,genre=item.genre or item.genre_id,
        homepage=item.homepage,providerMetadata=item.metadata,
    }
    if provider.decorateStation then provider.decorateStation(station,item) end
    return Stations.normalize(station)
end

function OpmlClient:resolveStation(station, callback, force)
    self:cancelPlaylist()
    local generation=self.playlistGeneration
    local url=station and (station.requiresResolution and station.resolverUrl or station.url) or ""
    if station and station.hls and not station.requiresResolution then callback(station);return true end
    if not force and not station.requiresResolution and not isPlaylistUrl(url) then callback(station);return true end
    local visited,requests,finished={},0,false
    local resolutionTrace
    local resolutionType=url:lower():match("%.m3u8[%?#]?") and "hls" or "playlist"
    local function finish(result,err,code)
        if finished or generation~=self.playlistGeneration then return end
        finished=true;self.playlistCancel=nil
        self.log:info("HTTPTRACE event=playlist_resolution id=",resolutionTrace or "-",
            " type=",result and result.hls and "hls" or resolutionType,
            " status=",result and "success" or "failed", " reason=",err and UrlTransport.redact(tostring(err)) or "-")
        callback(result,err,code)
    end
    local resolve
    resolve=function(current,depth,done)
        if generation~=self.playlistGeneration then return end
        if self.provider and self.provider.prepareUrl then current=self.provider.prepareUrl(current) end
        if visited[current] or depth>=MAX_PLAYLISTS or requests>=8 then done(nil,"OPML resolution loop or request limit reached");return end
        visited[current]=true;requests=requests+1
        local cancel=self:_fetch(current,"audio/x-mpegurl,application/vnd.apple.mpegurl,audio/x-scpls,text/plain,application/xml,*/*",MAX_PLAYLIST_BYTES,0,function(body,err,contentType,effectiveUrl,traceId)
            resolutionTrace=traceId
            if finished or generation~=self.playlistGeneration then return end
            if err then done(nil,err);return end
            local candidates,parseErr
            if body=="" and tostring(contentType):match("^audio/") then candidates={{url=effectiveUrl or current}}
            else candidates,parseErr=streamCandidates(effectiveUrl or current,body,contentType) end
            if not candidates then done(nil,parseErr);return end
            local index=0
            local function nextCandidate(lastError)
                index=index+1
                local candidate=candidates[index]
                if not candidate then done(nil,lastError or "No supported stream candidate");return end
                local nested=candidate.resolver or (not candidate.hls and isPlaylistUrl(candidate.url))
                    or (self.provider and self.provider.isResolver and self.provider.isResolver(candidate.url))
                if nested then
                    resolve(candidate.url,depth+1,function(result,error)
                        if result then done(result) else nextCandidate(error) end
                    end)
                else
                    local copy={}
                    for key,value in pairs(station) do copy[key]=value end
                    copy.playlistUrl=station.resolverUrl or station.playlistUrl or station.url
                    copy.url=candidate.url;copy.requiresResolution=false;copy.hls=candidate.hls or nil
                    if candidate.codec then copy.codec=candidate.codec end
                    local normalized,error=Stations.normalize(copy)
                    if normalized then done(normalized) else nextCandidate(error) end
                end
            end
            nextCandidate()
        end)
        if not finished and type(cancel)=="function" then self.playlistCancel=cancel end
    end
    resolve(url,0,finish)
    return true
end
