# RadioFeeds XML/OPML parser research

## Recommendation

Use the firmware-provided `lxp.lom` module inside a dedicated RadioFeeds parser module. It is already installed, loads successfully in SqueezePlay's Lua 5.1 runtime, uses the firmware's native Expat library, correctly handles XML syntax, entities and UTF-8, and produces a small tree that is straightforward to convert into applet-owned directory and station objects.

Do not parse OPML with Lua patterns. Do not route it through LMS or the bootstrap server. A SAX implementation using `lxp` remains an option if a future feed proves too large for LOM, but its additional state and integration complexity are not justified by the expected small RadioFeeds menu.

## Tested environment

The physical proof of concept was run on a Logitech Squeezebox Radio reachable at `10.171.148.226`:

| Item | Result |
| --- | --- |
| Hardware/kernel | ARMv5TEJ, Linux `2.6.26.8-rt16` |
| SqueezePlay | `7.7.3 r16676` |
| Lua | 5.1 |
| Standalone Lua executable | Not installed |
| Safe console runner | `/usr/bin/jive <module>` in a temporary directory |

Relevant module paths reported by the device were:

```text
package.path  = /root/.squeezeplay/userpath/?.lua;./?.lua;/usr/share/lua/5.1/?.lua;/usr/share/lua/5.1/?/init.lua;/usr/lib/lua/5.1/?.lua;/usr/lib/lua/5.1/?/init.lua;/usr/share/lua/5.1/?.lua;/usr/share/lua/5.1/?/?.lua;/usr/share/jive/?.lua;;
package.cpath = ./?.so;/usr/lib/lua/5.1/?.so;/usr/lib/lua/5.1/loadall.so;/usr/lib/lua/5.1/?.so;/usr/lib/lua/5.1/?/core.so;/usr/share/jive/?.so;
```

## Parser facilities found

The installed radio contains the complete callable LuaExpat path, not merely an unused native library:

| Facility | Device result |
| --- | --- |
| `/usr/lib/libexpat.so.1.5.0` | Present; `/usr/lib/libexpat.so.1` links to it |
| `/usr/lib/lua/5.1/lxp.so.1.0.2` | Present; `lxp.so` links to it |
| `require("lxp")` | Success, reports `LuaExpat 1.0.2` |
| `/usr/share/lua/5.1/lxp/lom.lua` | Present |
| `require("lxp.lom")` | Success |
| `require("xml")` | Not found |
| `require("XML")` | Not found |
| `require("SimpleXML")` | Not found |

The local upstream SqueezePlay tree confirms this is an intentional ARM firmware dependency. `src/Makefile.linuxarm` builds Expat 2.0.1, then builds and installs LuaExpat 1.0.2. Its bundled `lxp/lom.lua` uses `lxp` callbacks to construct elements with `tag`, `attr`, and numeric child/text entries.

## Existing OPML support

SqueezePlay's client applets do not contain a reusable local OPML-to-menu parser. References such as `opmlmyapps` in `SlimMenusApplet.lua` are server menu identifiers. `SlimBrowserApplet.lua` sends JSON/CLI requests through `_server:userRequest(...)` and renders the returned `data.item_loop`; it does not fetch and parse OPML locally.

The official RadioFeeds LMS plugin confirms that historical path. Its `Plugin.pm` derives from Perl `Slim::Plugin::OPMLBased` and supplies the remote feed URL. Consequently, the complete existing OPML browser is coupled to LMS and cannot satisfy standalone operation. Only the generic `lxp`/`lxp.lom` parser is reusable locally.

## RadioFeeds endpoint and document shape

RadioFeeds still documents this legacy endpoint:

```text
http://www.radiofeeds.co.uk/mypicks/menu.opml?username=<username>
```

The standalone entry point is `network.opml?username=forusewithstandalone`. Every request must identify itself with `User-Agent: Lyrion Music Server` and should send `Accept: application/xml,text/xml,*/*`; without that user agent the site returns its HTML instructions page. With those headers the root returns HTTP 200 and `Content-Type: text/x-opml`.

The live root is OPML 1.1 declared as ISO-8859-1; directory/station documents have also been observed as UTF-8. Navigation uses `text`, `type="link"`, and uppercase `URL`. Search entries use `type="search"` with `{QUERY}` in the URL. Audio entries use `text`, `type="audio"`, uppercase `URL`, `icon`, and `bitrate`; their URLs commonly point to M3U or PLS playlists rather than final streams. XML includes `&amp;`, `&#8211;`, and `&#8593;`. Logos commonly request 600x600 artwork and include both HTTP and HTTPS URLs.

`test/fixtures/radiofeeds-root.opml` is a shortened, sanitized fixture based on those observed live structures. Expat is left to honor each document's encoding declaration and decode entities.

## Proof of concept

`applet/StandaloneRadio/RadioFeedsOpml.lua` parses the XML with `lxp.lom`, validates the OPML root/body, and converts the LOM tree into applet-owned objects before any UI code sees it:

```lua
{
	title = "RadioFeeds UK & Ireland",
	children = {
		{
			title = "BBC & national stations",
			type = "directory",
			children = {
				{
					title = "BBC Radio 1",
					type = "audio",
					url = "http://...",
				}
			}
		}
	}
}
```

`test/radiofeeds-opml-poc.lua` was copied with the fixture and parser to a temporary directory on the physical radio and run in an isolated Jive Lua state. Results:

| Check | Result |
| --- | --- |
| Module load | Passed |
| Nested outlines and attributes | Passed |
| `&amp;` in text and URLs | Decoded correctly |
| Numeric entities and UTF-8 | `Café Radio – UK` preserved exactly |
| Malformed XML | Controlled `Invalid RadioFeeds XML` error |
| Parse CPU for the original research fixture | Approximately 0.01 seconds |
| Lua memory delta | Approximately 6.7 KiB |
| Existing SqueezePlay process | Remained running; no UI freeze or reboot |

The first run also identified a firmware-relevant Lua 5.1 detail: globals used after `module(...)` must be localized. The checked-in parser does this and the subsequent physical run passed.

## Options compared

| Approach | Present | Standalone | Correct XML handling | Cost and conclusion |
| --- | --- | --- | --- | --- |
| Generic SqueezePlay XML parser | Yes: LuaExpat | Yes | Yes | This is `lxp`/`lxp.lom`; reuse it |
| SqueezePlay OPML browser | Server-side only | No | Server handles it | Reject for standalone use |
| `lxp` SAX callbacks | Yes | Yes | Yes | Lowest peak memory, but more parser state and code |
| `lxp.lom` tree | Yes | Yes | Yes | Chosen: smallest integration and acceptable memory for a small feed |
| Bundled pure-Lua parser | No | Potentially | Depends on library | Adds code and maintenance with no benefit here |
| Lua patterns/regex | Built in | Yes | No | Reject: unsafe for nesting, entities, quoting, CDATA and malformed XML |

## Future integration

Keep the transport, parsing and UI layers separate:

```text
RadioFeedsClient HTTP request
    -> validate status/content type and response size
    -> RadioFeedsOpml.parse(response body)
    -> ordinary directory/station objects
    -> existing StandaloneRadio menu components
```

The future client should use plain HTTP as required by the endpoint, enforce a conservative response-size limit before building the LOM tree, reject an HTML response explicitly, and report parser/network errors through the existing loading/error UI. Once a genuine authenticated OPML response is available, save a sanitized capture, update the attribute mapping to only observed fields, and rerun the physical PoC before implementing the menu.
