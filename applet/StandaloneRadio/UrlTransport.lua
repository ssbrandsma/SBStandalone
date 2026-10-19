local tonumber, tostring, type = tonumber, tostring, type

local string = require("string")

local UrlTransport = {}

-- Optional Standalone Base service keeps SVG handling out of the audio applet.
function UrlTransport.renderSvgUrl(url, mime)
    local manager = appletManager
    if not manager then return url end
    local ok, result = pcall(function()
        return manager:callService("getStandaloneImageURL", url, 320, 320, mime)
    end)
    return ok and result or url
end

local PROXY_PREFIX = "http://127.0.0.1:8765/https/"
local MAX_ARTWORK_URL_BYTES = 383

-- One shared local HLS route for every directory. The native relay validates
-- manifests, redirects, containers and actual public socket destinations.
function UrlTransport.hlsUrl(url)
    if type(url) ~= "string" then return nil end
    if url:match("^http://127%.0%.0%.1:8765/hls/") then return url end
    local wrapped, source = url:match("^http://127%.0%.0%.1:8765/(https?)/(.+)$")
    if wrapped then url = wrapped .. "://" .. source end
    if #url > 4095 or url:find("[%c%s]") then return nil end
    local scheme, rest = url:match("^(https?)://(.+)$")
    if not scheme or rest:find("[#\\]") or (rest:match("^[^/]+") or ""):find("@", 1, true) then return nil end
    return "http://127.0.0.1:8765/hls/" .. scheme .. "/" .. rest
end

local function trim(value)
	return tostring(value or ""):gsub("^%s*(.-)%s*$", "%1")
end

local function localHost(url)
	local host = string.match(string.lower(url), "^https?://([^/:]+)")
	host = string.lower(host or "")
	return host == "localhost" or host == "127.0.0.1" or host == "0.0.0.0"
end

function UrlTransport.redact(url)
	if type(url) ~= "string" then return tostring(url) end
	url = string.gsub(url, "^(https?://)[^/@]+@", "%1[redacted]@")
	return (string.gsub(url, "([%?#]).*$", "%1[redacted]"))
end

function UrlTransport.isHttps(url)
	return type(url) == "string" and string.lower(string.sub(url, 1, 8)) == "https://"
end

function UrlTransport.transportUrl(url, log)
	if type(url) ~= "string" then return url end
	url = trim(url)
	if url == "" or string.lower(string.sub(url, 1, #PROXY_PREFIX)) == PROXY_PREFIX then return url end
	url = UrlTransport.renderSvgUrl(url)
	if not UrlTransport.isHttps(url) or localHost(url) then return url end
	if not string.match(string.lower(url), "^https://[%w%.%-]+[:%d]*[/#%?]?.*$") then return url end
	if log then log:info("StandaloneRadio: HTTPS via sbproxy: ", UrlTransport.redact(url)) end
	return PROXY_PREFIX .. string.sub(url, 9)
end

-- Return a URL suitable for the stock playerstatus artwork field. This is
-- deliberately stricter than transportUrl(), which preserves unsupported
-- inputs for callers that only want best-effort translation.
function UrlTransport.artworkUrl(url, log)
	if type(url) ~= "string" then return nil end
	url = trim(url)
	if url == "" or #url > MAX_ARTWORK_URL_BYTES or string.find(url, "[%s%z]") then return nil end
	local scheme, authority = string.match(url, "^(https?)://([^/%?#]+)")
	if not scheme or not authority or string.find(authority, "@", 1, true) then return nil end
	if not string.match(authority, "^[%w%.%-]+:?%d*$") then return nil end
	local translated = UrlTransport.transportUrl(url, log)
	if type(translated) ~= "string" or not string.match(translated, "^http://[^/]+/?.*$")
		or #translated > MAX_ARTWORK_URL_BYTES then return nil end
	return translated
end

function UrlTransport.parseHttp(url)
	if type(url) ~= "string" then return nil, "URL required" end
	local host, port, path = string.match(url, "^http://([^/:]+):?(%d*)(/.*)$")
	if not host then return nil, "URL must be HTTP with a path" end
	return { host = host, port = tonumber(port) or 80, path = path, url = url }
end

function UrlTransport.forRequest(url, log)
	local translated = UrlTransport.transportUrl(url, log)
	local parsed, err = UrlTransport.parseHttp(translated)
	if not parsed then return nil, err end
	parsed.hostHeader = parsed.host .. ((parsed.port ~= 80) and (":" .. tostring(parsed.port)) or "")
	parsed.originalUrl = url
	parsed.proxied = translated ~= url
	return parsed
end

function UrlTransport.proxyPrefix()
	return PROXY_PREFIX
end

return UrlTransport
