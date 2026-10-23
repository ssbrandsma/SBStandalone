-- Run with Lua 5.1: its module() environment reproduces the device failure.
local writes, completed, requests = {}, {}, {}
local responses = {}
package.preload["lfs"] = function()
    return {attributes=function() return "directory" end}
end
package.preload["jive.net.Process"] = function() return function() error("unexpected process") end end
package.preload["jive.net.RequestHttp"] = function()
    return function(sink, method, path, options)
        return {sink=sink, options=options, t_getResponseStatus=function() return 200 end}
    end
end
package.preload["applets.StandaloneRadio.Resolver"] = function()
    return {new=function() return {resolve=function(_, host, callback) callback("127.0.0.1") end} end}
end
package.preload["applets.StandaloneRadio.UrlTransport"] = function()
    return {forRequest=function(url) return {host="example.com", port=80, path=url} end,
        redact=function(url) return url end,
        renderSvgUrl=function() return "http://127.0.0.1/rendered.png" end}
end
package.preload["jive.net.SocketHttp"] = function()
    return function()
        return {fetch=function(_, request)
            requests[#requests+1] = request
            local response = table.remove(responses, 1)
            assert(response, "unexpected request")
            request.options.headersSink(response.headers)
            request.sink(response.body, response.err)
            request.sink(nil, nil)
        end}
    end
end

local realIO, realOS = io, os
io = {open=function() return {write=function(_, bytes) writes[#writes+1]=bytes end, close=function() end} end}
os = {remove=function() end}
local cacheModule = assert(loadfile("applet/StandaloneRadio/LogoCache.lua"))("LogoCacheTest")
-- Lua 5.1 module files register exports in package.loaded, not a return value.
cacheModule = package.loaded.LogoCacheTest
io, os = realIO, realOS
local cache = cacheModule.new({log={warn=function() end}})
cache._finishDownload = function(_, station, path, callback)
    completed[#completed+1] = path
    callback(path)
end
local function download()
    local result
    cache.active.station = true
    cache:_download({stationuuid="station"}, "station", "http://example.com/logo", "temporary-logo",
        function(path) result=path end)
    return result
end
responses = {{headers={["Content-Type"]="image/png"}, body="PNG unchanged"}}
assert(download() == "temporary-logo")
assert(writes[1] == "PNG unchanged" and cache.active.station == nil)
responses = {{headers={["content-type"]="image/svg+xml; charset=utf-8"}, body="<svg/>"},
             {headers={["Content-Type"]="image/png"}, body="rendered PNG"}}
assert(download() == "temporary-logo")
assert(writes[2] == "rendered PNG" and #requests == 3)
responses = {{headers={}, err="timeout"}}
assert(download() == nil and cache.active.station == nil)
responses = {{headers={["Content-Type"]="image/jpeg"}, body="JPEG unchanged"}}
assert(download() == "temporary-logo" and writes[3] == "JPEG unchanged")
cache.log.info=function() end
responses={{headers={["Content-Type"]="image/png"},body="TuneIn PNG"}}
local tuneinLogo
cache:ensure({source="tunein",id="tunein:s1",stationuuid="tunein-s1",favicon="http://example.com/logo"},function(path) tuneinLogo=path end)
assert(tuneinLogo and writes[4]=="TuneIn PNG")
print("LogoCache PNG/JPEG, SVG MIME retry and failure/retry tests passed")
