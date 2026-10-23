if not module then
	function module(name)
		local target = package.loaded[name] or {}
		package.loaded[name] = target
		local info, index = debug.getinfo(2, "f"), 1
		while true do
			local upname = debug.getupvalue(info.func, index)
			if not upname then break end
			if upname == "_ENV" then
				setmetatable(target, { __index = _G })
				debug.setupvalue(info.func, index, target)
				break
			end
			index = index + 1
		end
	end
end

local captured
package.preload["lxp.lom"] = function()
	return { parse=function(xml)
		captured = xml
		return {
			tag="opml", attr={},
			{ tag="head", attr={}, { tag="title", attr={}, "R&D émissions" } },
			{ tag="body", attr={},
				{ tag="outline", attr={
					text="Français & Español à é déjà &unknown; &broken &agrave;", id="dir&eacute;" },
					{ tag="outline", attr={
						text="Café <Live> \"One\" 'Two'", type="audio",
						id="station&eacute;", icon="http://images.example/a&eacute;.png",
						URL="http://streams.example/live?name=&eacute;&amp=1",
					} },
				},
			},
		}
	end }
end

assert(loadfile("./applet/StandaloneRadio/OpmlParser.lua"))(
	"applets.StandaloneRadio.OpmlParser")
local parser = package.loaded["applets.StandaloneRadio.OpmlParser"]

local xml = [[<opml><head><title>R&amp;D &eacute;missions</title></head><body>
<outline text="Fran&ccedil;ais &amp; Espa&ntilde;ol &#224; &#xE9; déjà &unknown; &broken &amp;agrave;" id="dir&amp;eacute;">
<outline text="Caf&eacute; &lt;Live&gt; &quot;One&quot; &apos;Two&apos;" type="audio"
 id="station&amp;eacute;" icon="http://images.example/a&amp;eacute;.png"
 URL="http://streams.example/live?name=&amp;eacute;&amp;amp=1" />
</outline></body></opml>]]

local result, err = parser.parse(xml)
assert(result, err)

-- Only user-visible text fields are normalized before LuaExpat sees them.
assert(captured:find("R&amp;D &#233;missions", 1, true))
assert(captured:find("Fran&#231;ais &amp; Espa&#241;ol &#224; &#xE9; déjà &amp;unknown; &amp;broken &#224;", 1, true))
assert(captured:find("Caf&#233; &lt;Live&gt; &quot;One&quot; &apos;Two&apos;", 1, true))
assert(captured:find('id="station&amp;eacute;"', 1, true))
assert(captured:find('icon="http://images.example/a&amp;eacute;.png"', 1, true))
assert(captured:find('URL="http://streams.example/live?name=&amp;eacute;&amp;amp=1"', 1, true))

assert(result.title == "R&D émissions")
assert(result.children[1].title == "Français & Español à é déjà &unknown; &broken &agrave;")
assert(result.children[1].id == "dir&eacute;")
local station = result.children[1].children[1]
assert(station.title == "Café <Live> \"One\" 'Two'")
assert(station.id == "station&eacute;")
assert(station.icon == "http://images.example/a&eacute;.png")
assert(station.url == "http://streams.example/live?name=&eacute;&amp=1")

-- Malformed and invalid numeric references remain literal rather than making
-- the XML parser reject an otherwise usable menu.
parser.parse([[<opml><body><outline text="Bad &#xZZ; &#999999999; &also-bad;" /></body></opml>]])
assert(captured:find("Bad &amp;#xZZ; &amp;#999999999; &amp;also%-bad;"))

parser.parse([[<opml><body><outline text="BBC Radio nan G&amp;agrave;idheal" />
<outline title="&amp;amp;agrave; &amp;#224; &amp;#xE0;" /></body></opml>]])
assert(captured:find('text="BBC Radio nan G&#224;idheal"', 1, true))
assert(captured:find('title="&amp;agrave; &#224; &#xE0;"', 1, true))

print("RadioFeeds HTML entity checks passed")

parser.parse('<?xml version="1.0" encoding="UTF-8"?><opml><head><title>RT\201</title></head><body><outline text="Irish RT\201 &amp; Commercial; Caf\195\169; \240\159\142\181" /></body></opml>')
assert(captured:find('<title>RT&#201;</title>',1,true))
assert(captured:find('Irish RT&#201; &amp; Commercial; Caf\195\169; \240\159\142\181',1,true))
parser.parse('<?xml version="1.0" encoding="ISO-8859-1"?><opml><body><outline text="RT\201" /></body></opml>')
assert(captured:find('text="RT\201"',1,true))
print("RadioFeeds mislabeled UTF-8 text checks passed")
