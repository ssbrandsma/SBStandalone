# RadioFeeds proof-of-concept

## Architecture

StandaloneRadio's root menu exposes independent directory sources as sibling items. Radio Browser keeps its existing menu and cache implementation. RadioFeeds is loaded only when its root item is selected:

```text
StandaloneRadio root
    -> Radio Browser -> existing RadioBrowser implementation
    -> RadioFeeds UK & Ireland -> OpmlClient -> OpmlParser
                                               -> common station model
                                               -> existing playback/presets/artwork
```

Adding a future `My Stations` source requires one root item and its own loader; it does not require another root-menu redesign or a provider framework.

## Network behavior

`OpmlClient` starts at:

```text
http://www.radiofeeds.co.uk/MyPicks/menu.opml?username=forusewithstandalone
```

Every OPML request is asynchronous and sends:

```http
User-Agent: Lyrion Music Server
Accept: application/xml,text/xml,*/*
Connection: close
```

Responses must be successful, no larger than 256 KiB, non-HTML, and valid OPML with a body. The requested URL, status, content type and byte count are logged without logging the body. Redirects are limited by the HTTP stack and client to five hops.

The browser renders `type="link"` recursively using the exact URL from RadioFeeds. `type="search"` reuses Jive's existing keyboard, URL-encodes the query, substitutes `{QUERY}`, and opens the returned OPML. No category or alphabet URL is constructed locally.

The root feed advertises **Search All Radio by Name** using
`http://www.radiofeeds.co.uk/MyPicks/integsearchall.opml?term={QUERY}&username=forusewithstandalone&search=1&center=1`.
`term` contains the percent-encoded station-name query. The username is required:
omitting it returns an OPML registration message instead of stations. Keep the
other parameters supplied by the feed. Requests use the same `Lyrion Music
Server` User-Agent as directory browsing. Results contain section headings and
normal audio entries, handled by the existing station selection code. Blank
searches are ignored; replacement uses a function so percent escapes in spaces,
punctuation, and UTF-8 cannot be interpreted as Lua replacement captures.

Standalone Radio supplies its own localized **Search** item at the top of the
RadioFeeds root menu, including during directory loading or failure. The client
holds the search endpoint, so this entry does not depend on the upstream menu
including a search outline. The equivalent upstream root search entry is hidden
to avoid duplication. The keyboard opens an asynchronous results window using
the same station-list renderer as Radio Browser Search. Parsed OPML audio entries
are normalized through `OpmlClient:toStation`; nested groups are flattened
and section headings are omitted. Selecting a result uses normal RadioFeeds
playback and preset handling. Empty results and request errors have explicit
menu messages, and older requests cannot replace a newer search's results.

The search API currently labels its response UTF-8 while emitting a Latin-1
`É` byte in its Irish section heading. For UTF-8 documents, the OPML parser
preserves valid UTF-8 and converts isolated legacy bytes in visible fields to
numeric references before Expat parses them. Documents declaring Latin-1 retain
their normal XML encoding behavior; technical attributes are not repaired.

## Stations and playback

`type="audio"` maps to the existing station model with `source="radiofeeds"`, name, URL, numeric bitrate, icon and a stable local identifier. M3U and PLS URLs are fetched asynchronously with a 64 KiB limit and resolved to their first HTTP or HTTPS stream before invoking the existing `StreamPlayer`. HTTPS transport uses local `sbproxy`; redirect handling, decoder selection, ICY metadata, stop, volume, reconnect behavior and Now Playing remain shared.

Presets save the resolved stream and retain `playlistUrl` as provenance. No Radio Browser fields or behavior were removed.

HTTP icons use the existing logo cache. HTTPS icons and track artwork pass through local `sbproxy` using the same asynchronous Jive HTTP stack. Artwork failure never blocks playback and does not require the bootstrap server at runtime.

## Runtime dependencies

The implementation runs directly on the Radio with firmware-provided LuaExpat (`lxp.lom`) and Jive networking. It has no LMS, bootstrap-server, proxy, transcoder or external conversion-service runtime dependency.
