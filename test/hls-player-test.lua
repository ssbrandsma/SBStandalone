-- Exercise real transport/probe functions without the native decoder or Jive UI.
local function read(path)
    local f = assert(io.open(path)); local text = f:read("*a"); f:close(); return text
end
local compile = loadstring or load
UrlTransport = assert(loadfile("applet/StandaloneRadio/UrlTransport.lua"))()
local source = read("applet/StandaloneRadio/StreamPlayer.lua")
local transport = assert(source:match("(local function transportStation%b().-)local function responseLocation"))
local location = assert(source:match("(local function responseLocation%b().-)function StreamPlayer:_startPowerKeepalive"))
local probe = assert(source:match("(function StreamPlayer:_finishRedirectProbe%b().-)function StreamPlayer:_installHooks"))
StreamPlayer = {}
local statuses, seen, wire, resolution = {}, {}, {}, nil
RequestHttp = function(sink, method, path, options)
    local status = table.remove(statuses, 1)
    assert(status, "unexpected probe")
    seen[#seen+1] = path
    -- Reproduce legacy Jive: HEAD drops URI query and params by default.
    return {options=options, sink=sink,
        t_getRequestString=function() return method .. " " .. path:match("^[^?;#]*") end,
        t_getResponseStatus=function() return status.code, "test" end, status=status}
end
SocketHttp = function()
    return {fetch=function(_, request)
        wire[#wire+1] = request:t_getRequestString()
        if request.status.err then request.sink(nil, request.status.err)
        else request.options.headersSink({["Content-Type"]=request.status.mime}) end
    end}
end
OpmlClient = {new=function() return {resolveStation=function(_, station, callback, force)
    assert(force)
    callback(resolution)
end} end}
assert(compile("local MAX_STREAM_REDIRECTS=5\n" .. transport .. location .. probe))()
local player = setmetatable({generation=1, log={info=function() end,warn=function() end},
    resolver={resolve=function(_, host, cb) cb("127.0.0.1") end}}, {__index=StreamPlayer})
local original = {url="https://example.com/live.m3u8", codec="mp3", hls=true, name="Station", id="stable"}
statuses = {{code=200, mime="audio/aac"}}
local selected
player:_resolveStreamRedirect(original, 1, function(station) selected=station end)
assert(selected and selected.codec == "aac" and selected.hls and selected.id == "stable")
assert(original.codec == "mp3" and original.url == "https://example.com/live.m3u8")
assert(seen[1] == "/hls/https/example.com/live.m3u8")
assert(wire[1] == "HEAD /hls/https/example.com/live.m3u8")
statuses = {{code=200, mime="audio/aac"}}
local queryStation = {url="http://lsn.lv/bbcradio.m3u8?station=bbc_radio_nan_gaidheal&bitrate=48000&token=a%2Fb%26c", hls=true}
player:_resolveStreamRedirect(queryStation, 1, function(station) selected=station end)
assert(selected and selected.codec == "aac")
assert(wire[#wire] == "HEAD /hls/http/lsn.lv/bbcradio.m3u8?station=bbc_radio_nan_gaidheal&bitrate=48000&token=a%2Fb%26c",
    "HEAD must retain source query, numeric bitrate and original escaping")
statuses = {{code=200, mime="audio/mpeg"}}
player:_resolveStreamRedirect({url="http://example.com/live;param=one?token=a%2Fb#fragment"}, 1, function(station) selected=station end)
assert(wire[#wire] == "HEAD /live;param=one?token=a%2Fb", "preserve params but never send fragments")
statuses={{code=200,mime="audio/aac"}}
player:_resolveStreamRedirect({provider="tunein",url="https://example.com/unknown",declaredFormats="unknown"},1,function(station) selected=station end)
assert(selected and selected.codec=="aac" and selected.declaredCodec==nil)
statuses = {{code=415, mime="text/plain"}}
selected = "unset"
player:_resolveStreamRedirect(original, 1, function(station) selected=station end)
assert(selected == nil, "unsupported HLS must not reach the decoder")
statuses = {{err="timeout"}}
selected = "unset"
player:_resolveStreamRedirect(original, 1, function(station) selected=station end)
assert(selected == nil, "failed HLS probes must not fall back to raw playback")
statuses = {{code=200, mime="application/vnd.apple.mpegurl"}, {code=200, mime="audio/mpeg"}}
resolution = {url="https://example.com/media", hls=true, name="Station", id="stable"}
player:_resolveStreamRedirect({url="https://example.com/discover", id="stable"}, 1, function(station) selected=station end)
assert(selected and selected.codec == "mp3" and selected.hls)
statuses = {{code=200, mime="audio/x-mpegurl"}, {code=200, mime="audio/mpeg"}}
resolution = {url="https://example.com/plain.mp3", id="ordinary", codec="mp3"}
player:_resolveStreamRedirect({url="https://example.com/plain-list", id="ordinary"}, 1, function(station) selected=station end)
assert(selected and selected.id == "ordinary" and not selected.hls)

local browser = read("applet/StandaloneRadio/RadioBrowser.lua")
local functions = assert(browser:match("(local function compatible%b().-)local function sortByName"))
local prefix = [[
local function trim(v) return tostring(v or ""):gsub("^%s*(.-)%s*$", "%1") end
local function isOne(v) return v==true or v==1 or v=="1" end
local SUPPORTED_CODECS={aac=true,mp3=true,ogg=true}
local Stations={normalize=function(s) return s end}
]]
local helpers = assert(compile(prefix .. functions .. "return {compatible=compatible,toStation=toStation,cacheRecord=cacheRecord,recordStation=recordStation}"))()
local item = {url="https://example.com/live", stationuuid="one", name="Radio", codec="AAC", hls=1}
assert(helpers.compatible(item))
local record = helpers.cacheRecord(helpers.toStation(item, "GB"))
assert(record[9] == 1 and helpers.recordStation(record, "GB").hls)
item.codec="OGG"
assert(not helpers.compatible(item), "unsupported HLS codecs should not be listed")
print("HLS codec probing, MIME discovery, metadata and directory cache tests passed")
