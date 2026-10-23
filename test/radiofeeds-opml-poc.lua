package.path = "./?.lua;./applet/StandaloneRadio/?.lua;" .. package.path

local parser = require("OpmlParser")

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

local entities = [[<?xml version="1.0" encoding="UTF-8"?>
<opml version="1.1"><head><title>R&amp;D &eacute;missions</title></head><body>
<outline text="Fran&ccedil;ais &amp; Espa&ntilde;ol &#224; &#xE9; déjà &unknown; &broken &amp;agrave;" title="ignored">
  <outline text="Caf&eacute; &lt;Live&gt; &quot;One&quot; &apos;Two&apos;" type="audio"
    id="station&amp;eacute;" icon="http://images.example.invalid/a&amp;eacute;.png"
    URL="http://streams.example.invalid/live?name=&amp;eacute;&amp;amp=1" />
</outline></body></opml>]]
local decoded, entityError = parser.parse(entities)
assert(decoded, entityError)
assert(decoded.title == "R&D \195\169missions")
assert(decoded.children[1].title == "Fran\195\167ais & Espa\195\177ol \195\160 \195\169 déjà &unknown; &broken \195\160")
assert(decoded.children[1].children[1].title == "Caf\195\169 <Live> \"One\" 'Two'")
assert(decoded.children[1].children[1].id == "station&eacute;")
assert(decoded.children[1].children[1].icon == "http://images.example.invalid/a&eacute;.png")
assert(decoded.children[1].children[1].url == "http://streams.example.invalid/live?name=&eacute;&amp=1")

local malformedEntities = [[<opml><body>
<outline text="Bad &#xZZ; &#999999999; &also-bad;" type="audio" URL="http://example.invalid/live" />
</body></opml>]]
local preserved, preservedError = parser.parse(malformedEntities)
assert(preserved, preservedError)
assert(preserved.children[1].title == "Bad &#xZZ; &#999999999; &also-bad;")

local gaelic = assert(parser.parse([[<opml><body>
<outline text="Fort William"><outline type="audio"
text="BBC Radio nan G&amp;agrave;idheal (AAC (HLS))"
URL="http://example.invalid/live?station=gaelic&amp;bitrate=48000" /></outline>
<outline title="&amp;amp;agrave; &amp;#224; &amp;#xE0;" />
</body></opml>]]))
assert(gaelic.children[1].children[1].title == "BBC Radio nan G\195\160idheal (AAC (HLS))")
assert(gaelic.children[1].children[1].url == "http://example.invalid/live?station=gaelic&bitrate=48000")
assert(gaelic.children[2].title == "&agrave; \195\160 \195\160")

local malformed, malformedError = parser.parse("<opml><body></opml>")
local mixed = assert(parser.parse('<?xml version="1.0" encoding="UTF-8"?><opml><body><outline type="text" text="Irish RT\201 &amp; Commercial" /><outline type="audio" text="Caf\195\169" URL="http://example.invalid/live" /></body></opml>'))
assert(mixed.children[1].title == "Irish RT\195\137 & Commercial")
assert(mixed.children[2].title == "Caf\195\169")
assert(not malformed and malformedError:match("Invalid RadioFeeds XML"))
print("malformed XML: controlled error")
print(string.format("parse CPU: %.6f s", elapsed))
print(string.format("Lua memory delta: %.1f KiB", collectgarbage("count") - memoryBefore))
