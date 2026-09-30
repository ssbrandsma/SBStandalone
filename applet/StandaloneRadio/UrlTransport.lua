local tonumber, tostring, type = tonumber, tostring, type

local string = require("string")

local UrlTransport = {}

local PROXY_PREFIX = "http://127.0.0.1:8765/https/"

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
	return (string.gsub(url, "([%?#]).*$", "%1[redacted]"))
end

function UrlTransport.isHttps(url)
	return type(url) == "string" and string.lower(string.sub(url, 1, 8)) == "https://"
end

function UrlTransport.transportUrl(url, log)
	if type(url) ~= "string" then return url end
	url = trim(url)
	if url == "" or string.lower(string.sub(url, 1, #PROXY_PREFIX)) == PROXY_PREFIX then return url end
	if not UrlTransport.isHttps(url) or localHost(url) then return url end
	if not string.match(string.lower(url), "^https://[%w%.%-]+[:%d]*[/#%?]?.*$") then return url end
	if log then log:info("StandaloneRadio: HTTPS via sbproxy: ", UrlTransport.redact(url)) end
	return PROXY_PREFIX .. string.sub(url, 9)
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
