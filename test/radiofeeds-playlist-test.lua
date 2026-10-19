-- Lua 5.1 + LuaSocket (the same URL resolver Jive uses). No network or disk writes.
local URL = require("socket.url")
local requests, responses = {}, {}
local mode, closed, held = "normal", 0, nil
package.preload["jive.net.RequestHttp"] = function()
    return function(sink, method, path, options)
        return {sink=sink, options=options,
            getURI=function() return {scheme="http", host="example.com", path=path} end,
            t_getResponseStatus=function() return 200, "HTTP/1.1 200 OK" end}
    end
end
package.preload["jive.net.SocketHttp"] = function()
    return function()
        return {close=function() closed=closed+1 end, fetch=function(_, request)
            request.options.headersSink({["Content-Type"]="audio/x-mpegurl"})
            if mode == "hold" then held=request; return end
            if mode == "large-header" then
                request.options.headersSink({["Content-Length"]="65537"})
            elseif mode == "large-body" then
                request.sink(string.rep("x", 65537))
            else
                request.sink("http://example.com/")
                request.sink("live.mp3")
            end
            request.sink(nil, nil)
            request.sink(nil, "late duplicate error")
        end}
    end
end
package.preload["applets.StandaloneRadio.Resolver"] = function()
    return {new=function() return {resolve=function(_, host, callback) callback("203.0.113.1") end} end}
end
package.preload["applets.StandaloneRadio.RadioFeedsOpml"] = function() return {} end
package.preload["applets.StandaloneRadio.Stations"] = function()
    assert(loadfile("applet/StandaloneRadio/Stations.lua"))("applets.StandaloneRadio.Stations")
    return package.loaded["applets.StandaloneRadio.Stations"]
end
package.preload["applets.StandaloneRadio.UrlTransport"] = function()
    return {forRequest=function(url)
        local parsed = URL.parse(url)
        return {host=parsed.host, hostHeader=parsed.host, port=80, path=parsed.path}
    end, redact=function(url) return url end}
end
assert(loadfile("applet/StandaloneRadio/RadioFeedsClient.lua"))("RadioFeedsPlaylistTest")
local module = package.loaded.RadioFeedsPlaylistTest
local client = module.new({log={info=function() end, warn=function() end}})
local calls = 0
client:_fetch("http://example.com/a.m3u", "*/*", 65536, 0, function(body, err, mime, effectiveUrl)
    assert(body == "http://example.com/live.mp3" and not err, tostring(body) .. ": " .. tostring(err))
    assert(effectiveUrl == "http://example.com/a.m3u")
    calls = calls + 1
end)
assert(calls == 1, "terminal callback must be delivered once")
for _, bad in ipairs({"large-header", "large-body"}) do
    mode = bad
    calls = 0
    client:_fetch("http://example.com/a.m3u", "*/*", 65536, 0, function(body, err)
        assert(not body and err:find("too large", 1, true)); calls=calls+1
    end)
    assert(calls == 1)
end
assert(closed == 2)
mode = "hold"
client:_fetch("http://example.com/a.m3u", "*/*", 65536, 0, function() error("cancelled request delivered") end)
client:cancelPlaylist()
assert(closed == 3 and not client.playlistHttp)
held.sink("late data"); held.sink(nil, nil)
mode = "normal"

local base = "https://example.com/list/sub/menu.m3u?token=one"
local function resolve(body)
    return module.resolvePlaylistResponse(base, body)
end
assert(resolve("#EXTM3U\nhttps://cdn.example.com/live.aac?q=a%2Fb\n") == "https://cdn.example.com/live.aac?q=a%2Fb")
assert(resolve("#EXTM3U\n../live.aac?q=a%2Fb\n") == "https://example.com/list/live.aac?q=a%2Fb")
assert(resolve("#EXTM3U\n//cdn.example.com/live.mp3\n") == "https://cdn.example.com/live.mp3")
assert(resolve("[playlist]\nNumberOfEntries=1\nFile1=../live.mp3\nTitle1=Radio\n") == "https://example.com/list/live.mp3")
assert(resolve("\239\187\191#EXTM3U\n/live.mp3\n") == "https://example.com/live.mp3")
assert(resolve("#EXTM3U\nhttp://127.0.0.1/live.mp3\n") == "http://example.com/live.mp3")
assert(not resolve("#EXTM3U\n"))
assert(not resolve("#EXTM3U\nfile:///tmp/audio\n"))
for _, body in ipairs({
    "#EXTM3U\n#EXT-X-TARGETDURATION:6\n#EXT-X-MEDIA-SEQUENCE:123\n#EXTINF:6.4,\naudio-123.ts\n",
    "#EXTM3U\n#EXT-X-TARGETDURATION:6\n#EXTINF:6.4,\nhttps://cdn.example.com/audio.ts\n",
    "#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=96000\nvariant.m3u8\n",
    "\239\187\191#EXTM3U\n#EXT-X-MAP:URI=init.mp4\nchunk.m4s\n"}) do
    local result, err, code = resolve(body)
    assert(result == base and not err and code == "hls")
end
for _, path in ipairs({"a.m3u", "a.m3u8", "A.M3U8?q=1", "a.pls#x"}) do
    assert(module.isPlaylistUrl("http://example.com/" .. path))
end
for _, path in ipairs({"a.m3u8evil", "a.mp3?x=.m3u", "a.pls2", "a.aac"}) do
    assert(not module.isPlaylistUrl("http://example.com/" .. path))
end
client._fetch = function(_, url, accept, limit, redirects, callback)
    requests[#requests+1] = url
    local body = assert(responses[url], "unexpected fetch: " .. url)
    callback(body, nil, "audio/x-mpegurl", url)
end
responses = {
    ["http://example.com/first.m3u"]="#EXTM3U\nsub/next.m3u8\n",
    ["http://example.com/sub/next.m3u8"]="#EXTM3U\n../live.aac\n",
}
local station = {url="http://example.com/first.m3u", codec="aac", name="Radio", source="radiofeeds"}
calls = 0
client:resolveStation(station, function(result, err)
    assert(result and not err and result.url == "http://example.com/live.aac")
    assert(result.playlistUrl == station.url and result.codec == "aac")
    calls = calls + 1
end)
assert(calls == 1 and #requests == 2 and station.url == "http://example.com/first.m3u")
responses = {[station.url]="#EXTM3U\nfirst.m3u\n"}
client:resolveStation(station, function(result, err)
    assert(not result and err:find("loop", 1, true))
end)
responses = {[station.url]="#EXTM3U\n#EXT-X-TARGETDURATION:6\naudio.ts\n"}
client:resolveStation(station, function(result, err, code)
    assert(result and result.hls and result.url == station.url and not err)
end)
assert(client:toStation({type="audio", url=station.url, title="BBC (AAC (HLS))"}).codec == "aac")
requests = {}
client._fetch = function(_, url, accept, limit, redirects, callback)
    requests[#requests+1] = url
    callback("#EXTM3U\nnext" .. #requests .. ".m3u\n", nil, "audio/x-mpegurl", url)
end
client:resolveStation(station, function(result, err)
    assert(not result and err:find("limit", 1, true))
end)
assert(#requests == 5, "playlist nesting must be bounded")

-- Execute the real UI method in isolation: selection races must not start old
-- audio, and HLS errors must select the dedicated popup rather than a decoder.
local file = assert(io.open("applet/StandaloneRadio/StandaloneRadioApplet.lua"))
local source = file:read("*a")
file:close()
local method = assert(source:match("(function _playStation%b().-)function _assignPreset"))
RadioFeedsClient = module
UrlTransport = {redact=function(url) return url end}
log = {warn=function() end}
_logInfo = function() end
assert(loadstring(method))()
local pending, playing, popups = {}, {}, {}
local applet = {
    radioFeeds={resolveStation=function(_, selected, callback) pending[#pending+1]=callback end},
    streamPlayer={start=function(_, selected) playing[#playing+1]=selected.url end},
    string=function(_, token) return token end,
    _showPopup=function(_, text) popups[#popups+1]=text end,
    _playStation=_playStation,
}
applet:_playStation(station)
applet:_playStation({url="http://example.com/new.mp3", source="user"})
pending[1]({url="http://example.com/stale.mp3", source="radiofeeds"})
assert(#playing == 1 and playing[1] == "http://example.com/new.mp3")
applet:_playStation(station)
pending[2](nil, "segmented HLS", "hls_unsupported")
assert(#playing == 1 and popups[1] == "STANDALONE_RADIO_HLS_UNSUPPORTED")
print("RadioFeeds playlist, HLS routing, loop and callback tests passed")
