package.path = "./?.lua;./applet/StandaloneRadio/?.lua;" .. package.path

local parser = require("RadioFeedsOpml")

local fixturePath = arg and arg[1] or "test/fixtures/radiofeeds-root.opml"
local fixture = assert(io.open(fixturePath, "rb"))
local xml = fixture:read("*a")
fixture:close()

collectgarbage("collect")
local memoryBefore = collectgarbage("count")
local started = os.clock()
local result, err = parser.parse(xml)
local elapsed = os.clock() - started
assert(result, err)

print("RadioFeeds OPML parsed")
print("title: " .. result.title)
print("entries: " .. #result.children)
for _, directory in ipairs(result.children) do
	print("[directory] " .. directory.title)
	for _, station in ipairs(directory.children or {}) do
		print("[station] " .. station.title .. " -> " .. tostring(station.url))
	end
end

assert(result.title == "RadioFeeds for mysqueezebox")
assert(result.children[1].type == "link")
assert(result.children[1].url == "http://www.radiofeeds.co.uk/MyPicks/integ.opml?username=example")
assert(result.children[2].type == "search")
assert(result.children[2].url == "http://www.radiofeeds.co.uk/MyPicks/integsearch.opml?term={QUERY}&username=example&search=1")
assert(result.children[3].children[1].type == "audio")
assert(result.children[3].children[1].bitrate == 128)
assert(result.children[3].children[1].icon == "http://images.example.invalid/classic.png")
assert(result.children[3].children[1].url == "http://streams.example.invalid/ClassicFMMP3.m3u")
assert(result.children[3].children[2].title == "Caf\195\169 Radio \226\134\145 256k")

local malformed, malformedError = parser.parse("<opml><body></opml>")
assert(not malformed and malformedError:match("Invalid RadioFeeds XML"))
print("malformed XML: controlled error")
print(string.format("parse CPU: %.6f s", elapsed))
print(string.format("Lua memory delta: %.1f KiB", collectgarbage("count") - memoryBefore))
