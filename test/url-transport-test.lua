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

local original = { url = "https://station.example.com/live.mp3" }
equal(transport.transportUrl(original.url), "http://127.0.0.1:8765/https/station.example.com/live.mp3")
equal(original.url, "https://station.example.com/live.mp3")

local parsed = assert(transport.forRequest("https://example.com/listen.m3u"))
equal(parsed.host, "127.0.0.1")
equal(parsed.port, 8765)
equal(parsed.path, "/https/example.com/listen.m3u")
equal(parsed.hostHeader, "127.0.0.1:8765")

print("UrlTransport tests passed")
