package.path = "./applet/StandaloneRadio/?.lua;" .. package.path

local transport = require("UrlTransport")

local function equal(actual, expected)
	assert(actual == expected, "expected " .. tostring(expected) .. ", got " .. tostring(actual))
end

equal(transport.transportUrl("http://example.com/a.mp3"), "http://example.com/a.mp3")
equal(transport.transportUrl("https://example.com/a.mp3"), "http://127.0.0.1:8765/https/example.com/a.mp3")
equal(transport.transportUrl("https://example.com/a/b?q=hello%20world&x=1"),
	"http://127.0.0.1:8765/https/example.com/a/b?q=hello%20world&x=1")
equal(transport.transportUrl("http://127.0.0.1:8765/https/example.com/a.mp3"),
	"http://127.0.0.1:8765/https/example.com/a.mp3")
equal(transport.transportUrl("https://localhost/private"), "https://localhost/private")
equal(transport.transportUrl("file:///tmp/image.png"), "file:///tmp/image.png")
equal(transport.transportUrl("not a url"), "not a url")
equal(transport.transportUrl("https://"), "https://")
equal(transport.transportUrl(""), "")
assert(transport.transportUrl(nil) == nil)

equal(transport.artworkUrl("http://example.com/a%20b.jpg?q=one%20two"),
	"http://example.com/a%20b.jpg?q=one%20two")
equal(transport.artworkUrl("https://example.com/a%20b.jpg?q=one%20two"),
	"http://127.0.0.1:8765/https/example.com/a%20b.jpg?q=one%20two")
equal(transport.artworkUrl("http://127.0.0.1:8765/https/example.com/a.jpg"),
	"http://127.0.0.1:8765/https/example.com/a.jpg")
assert(transport.artworkUrl("ftp://example.com/a.jpg") == nil)
assert(transport.artworkUrl("http://user:secret@example.com/a.jpg") == nil)
assert(transport.artworkUrl("not a url") == nil)

local original = { url = "https://station.example.com/live.mp3" }
equal(transport.transportUrl(original.url), "http://127.0.0.1:8765/https/station.example.com/live.mp3")
equal(original.url, "https://station.example.com/live.mp3")

local parsed = assert(transport.forRequest("https://example.com/listen.m3u"))
equal(parsed.host, "127.0.0.1")
equal(parsed.port, 8765)
equal(parsed.path, "/https/example.com/listen.m3u")
equal(parsed.hostHeader, "127.0.0.1:8765")

print("UrlTransport tests passed")
equal(transport.hlsUrl("https://example.com/live.m3u8?q=a%2Fb"),
    "http://127.0.0.1:8765/hls/https/example.com/live.m3u8?q=a%2Fb")
equal(transport.hlsUrl("http://example.com/live.m3u8"),
    "http://127.0.0.1:8765/hls/http/example.com/live.m3u8")
local localHls = "http://127.0.0.1:8765/hls/https/example.com/live.m3u8"
equal(transport.hlsUrl(localHls), localHls)
assert(transport.hlsUrl("file:///tmp/audio") == nil)
assert(transport.hlsUrl("https://user:secret@example.com/live.m3u8") == nil)
