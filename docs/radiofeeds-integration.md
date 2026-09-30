# RadioFeeds proof-of-concept

## Architecture

StandaloneRadio's root menu exposes independent directory sources as sibling items. Radio Browser keeps its existing menu and cache implementation. RadioFeeds is loaded only when its root item is selected:

```text
StandaloneRadio root
    -> Radio Browser -> existing RadioBrowser implementation
    -> RadioFeeds UK & Ireland -> RadioFeedsClient -> RadioFeedsOpml
                                               -> common station model
                                               -> existing playback/presets/artwork
```

Adding a future `My Stations` source requires one root item and its own loader; it does not require another root-menu redesign or a provider framework.

## Network behavior

`RadioFeedsClient` starts at:

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

## Stations and playback

`type="audio"` maps to the existing station model with `source="radiofeeds"`, name, URL, numeric bitrate, icon and a stable local identifier. M3U and PLS URLs are fetched asynchronously with a 64 KiB limit and resolved to their first HTTP or HTTPS stream before invoking the existing `StreamPlayer`. HTTPS transport uses local `sbproxy`; redirect handling, decoder selection, ICY metadata, stop, volume, reconnect behavior and Now Playing remain shared.

Presets save the resolved stream and retain `playlistUrl` as provenance. No Radio Browser fields or behavior were removed.

HTTP icons use the existing logo cache. HTTPS icons and track artwork pass through local `sbproxy` using the same asynchronous Jive HTTP stack. Artwork failure never blocks playback and does not require the bootstrap server at runtime.

## Runtime dependencies

The implementation runs directly on the Radio with firmware-provided LuaExpat (`lxp.lom`) and Jive networking. It has no LMS, bootstrap-server, proxy, transcoder or external conversion-service runtime dependency.
