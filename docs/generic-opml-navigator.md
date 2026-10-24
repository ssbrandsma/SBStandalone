# Generic OPML navigator

## Inspection and reuse

The original RadioFeeds browsing code lived in `StandaloneRadioApplet.lua`:
`radioFeedsMenu`, `_radioFeedsItems` and the two search methods built Jive
windows directly. Its provider-named parser normalized a LuaExpat LOM tree;
its client handled asynchronous HTTP, XML, playlists and redirects.
The old directory callback had no window-lifetime guard. The search callback
guard did not cover closing a window or switching providers.

The following working components are reused:

| Component | Responsibility |
| --- | --- |
| `Resolver` / `UrlTransport` | DNS and existing Base HTTPS/image routes |
| `OpmlClient` | Shared bounded HTTP and playlist resolution transport |
| `Stations` | Existing HTTP(S) station and playback URL model |
| `StreamPlayer` | Existing redirect/MIME probes, native decoder, HLS relay, ICY and reconnects |
| `LogoCache` / `TrackArtwork` | Existing image cache, Base renderer, track artwork lookup |
| `StandaloneBaseNowPlaying` / `NativeNowPlaying` | Existing ownership/generation-based Now Playing integration |
| `PresetStore` | Existing applet settings, six hardware presets, and provider favorites |
| `UserStations` | Existing Base-managed station file; merged with local favorites in the UI |

Base APIs remain unchanged: the image URL service and HTTP image renderer,
the loopback HTTPS/HLS proxy, and `/api/nowplaying/claim`, update/heartbeat and
release endpoints. Provider metadata does not introduce a new Base protocol,
daemon, player, artwork downloader or native dependency.

## Architecture and provider interface

`OpmlNavigator.lua` owns provider-independent menus, inline/remote navigation,
loading, search results, retry, cancellation and window lifetime. A small UI
adapter in the applet supplies Jive windows, keyboard input, translated text,
station actions and the existing playback entry point. Tests inject that UI.

`OpmlProviders.lua` defines `id`, `name`, `root`, `search` (with `{QUERY}`), and
optional `prepareUrl(url)` / `isResolver(url)` functions. The navigator does
not contain TuneIn endpoint rules or RadioFeeds hierarchy rules.

`OpmlClient.lua` owns the bounded HTTP transport and stream resolution.
`OpmlParser.lua` owns XML parsing and metadata normalization. There are no
compatibility wrappers or provider-named implementations. Generic playback
playlist resolution creates a client without a directory provider.

Provider definitions also own station identity/codec overrides and whether
stations require resolution. RadioFeeds retains its historical URL hash IDs,
UUIDs and title-based codec inference through `stationKey` and
`decorateStation` hooks. TuneIn declares `requiresResolution=true` and uses
the generic guide-ID identity and explicit format handling. The shared client
contains no provider-name branches or RadioFeeds endpoint defaults.

RadioFeeds now uses the navigator through its existing applet methods. Its
root search entry, hierarchy, title codec hints, station IDs and image cache
keys are preserved. Radio Browser continues to use its existing navigator.

## OPML normalization

One LuaExpat LOM parse produces normalized outlines after the existing visible
entity/legacy-text repair. Attribute names are case-insensitive. Canonical XML
entities and UTF-8 are decoded by Expat. Text, descriptions, program attributes,
formats, bitrate, image/icon URLs and provider identifiers are retained.

Audio outlines require an HTTP(S) URL to play. Links open remote documents;
inline children and empty directories open nested menus. Text and unsupported
outline kinds remain nonplayable. Missing names use an untitled UI label rather
than an invented station name. Relative directory/artwork URLs resolve against
the document URL. Unsupported schemes and overlong URLs cannot become stations.
Non-200 OPML head status values become errors; DTDs are rejected.

## Navigation and memory limits

Only the requested menu is fetched. There is no full-catalog download or
persistent OPML cache. Search shares the existing Jive text input and bytewise
URL encoding. Search results flatten inline station groups as RadioFeeds did;
regular browsing keeps folders and remote links.

Every load gets a generation and cancellation closure. Hiding a loading window,
popping it, a newer navigation, switching providers or closing the navigator
invalidates its callback. Pop releases menu items/references. Back retains
navigation context, reloading an interrupted or evicted document when needed.
Failures replace the loading indicator with a selectable retry entry.

| Resource | Limit |
| --- | --- |
| Directory XML | 256 KiB, checked during download |
| Resolver/playlist response | 64 KiB, checked during download |
| XML tree | 1,024 element nodes; nesting depth 32 |
| Per-request deadline | 15 seconds, including DNS/redirect work |
| Explicit redirects | 5; stock Jive also bounds its automatic redirect handling |
| Resolution graph | Depth 5; 8 fetches; visited-URL loop detection |
| Stream candidates | 16 |
| Open navigation contexts | 12; at most two retained remote menu payloads |
| Visible title / station URL | 1,024 / 4,096 bytes |
| Provider favorites | 100 in the existing applet settings |

XML size/node/depth limits are configurable on the parser call. A lexical
preflight bounds allocation before Expat builds the tree; it is not a second
XML parse. There are no new background polling loops. Native audio responses
encountered during resolution are recognized at headers and closed without
collecting audio; regular stream playback remains the player's responsibility.
These are enforced bounds, not measured physical-device heap benchmarks.

## TuneIn endpoints and access

Verified on 22 October 2026 from the development environment, without credentials:

| Request | Observed response |
| --- | --- |
| `https://opml.radiotime.com/Browse.ashx` | OPML links for Local Radio, Music, Talk, Sports, Location, Language and Podcasts |
| `Browse.ashx?c=music` | A category menu in OPML |
| `Search.ashx?query=1%20Vallei` | OPML including station `s329637` |
| `Tune.ashx?id=s329637` | `audio/x-mpegurl`, plain URL `https://xon.luisteren.link/1vallei` |

The root hierarchy comes from responses. No country, coordinate or location is
hardcoded. The provider uses the public HTTP OPML endpoint and preserves outline URL schemes.
Device testing found that forcing HTTPS fails during the wolfSSL handshake
and produces a proxy HTTP 502; HTTP Browse/Search/Tune works on the radio.
HTTPS stream and image URLs still use the existing Base proxy.
An assigned partner ID can be supplied in applet settings as `tuneInPartnerId`;
none is fabricated or borrowed. Returned access errors are shown, not bypassed.

Public responses prove current reachability, not a production license or
guaranteed availability. [TuneIn's official developer documentation](https://developer.tunein.com/cfp_login)
describes partner access, agreements and certification. Confirm the applicable
access conditions with TuneIn before distributing a production integration.
No account/premium authentication, DRM, or geolocation override is implemented.

The recorded responses live in `test/fixtures/opml/`. `tunein-station.opml` is
the supplied station example; the other TuneIn fixtures are recorded public
root/category/search/tune responses. Tests do not depend on live availability.

## Stream resolution

A TuneIn selection retains its provider ID and original resolver URL. The
shared client handles plain-text URLs, OPML/XML candidate outlines, M3U, PLS,
relative URLs, HTTP redirects and HTTPS. HLS manifests are passed to the
existing native HLS path, never treated as individual playable segments.

Explicitly unsupported XML candidate formats are skipped. Supported candidates
retain order; failed nested resolver/playlist candidates can fall back to the
next candidate within the common graph/request limits. The final stream goes
through the existing redirect/MIME probe and decoder. MIME codec observations
can select the decoder without replacing the catalog's declared codec field.

Final audio URLs are not downloaded to determine whether they sound playable.
Availability of each direct candidate is not pre-tested with extra requests;
normal player failure/reconnect handling remains in force. There is no new
alternate-stream playback engine or automatic premium/access workaround.

## Metadata, artwork and saved stations

`provider`, `providerId`, `resolverUrl` and `providerMetadata` retain identity.
TuneIn `guide_id`, preset/Now Playing/show IDs and reliability are preserved.
`image`/`icon` feeds the existing artwork path. `formats` and bitrate remain
declared data; missing values stay unknown.

`description` is a description when supplied. `subtext` is retained separately
as `programDescription`, not assumed to be a permanent tagline. `playing` or
`current_track` becomes a catalog title fallback without inventing an artist.
Actual ICY or timed metadata takes precedence. Declared station audio remains
separate from `observedAudio` in Base's track snapshot. Existing generation and
revision guards prevent duplicate/stale Now Playing updates.

Hold a provider station row to save it to My Radio Stations or assign preset
1–6. Favorites share `PresetStore` and the existing applet settings, and appear
alongside Base-managed user stations. They do not alter the Base station file
or create a TuneIn database. Saved entries keep the stable resolver URL, image,
declared characteristics and bounded identifier metadata; transient catalog
program text is not saved. A TuneIn favorite/preset resolves again on replay.
Existing user stations, Radio Browser presets and RadioFeeds IDs are preserved.

## Tests and physical validation

Run `python test/run-tests.py` with Lupa installed. The runner bridges Python
Expat to the LOM interface, using Jive's pure LuaSocket URL code. A different
LuaSocket location can be passed with `--socket-url`. Existing Lua/Jive fixture
tests remain usable with their regular dependencies. The four PowerShell
static integration checks should also pass.

Coverage includes the real recorded OPML fixtures, entities/Unicode/missing
fields, malformed/access errors and limits; RadioFeeds hierarchy/search/play;
TuneIn root/category/search, supplied station metadata, resolution formats,
redirects, candidate fallback, cancellation, timeouts and byte limits; preset
and favorite replay; artwork reuse; catalog/ICY precedence; rapid station
switching; stale callbacks; retry and repeated window lifetimes.

Physical-device validation is still required:

1. Confirm existing RadioFeeds and Radio Browser browsing/playback/presets.
2. Open TuneIn, enter a category, go Back, search, and play 1 Vallei.
3. Check native audio, track updates, station logo and artwork failures.
4. Save a favorite and hardware preset, restart Jive and replay both.
5. Close a loading menu, rapidly switch categories/providers, retry failures.
6. Repeatedly open/close menus and monitor memory, responsiveness and traces.
7. Confirm catalog text does not replace fresh ICY/timed metadata.

Released as Radio 0.9.11, deployed to the test radio and published on the
release server. HTTP Browse/Search/Tune requests were verified on the radio;
the remaining physical interaction and playback checks above still apply.

## Adding another provider

Add a definition to `OpmlProviders`, construct an `OpmlClient` using it, add a
translated root entry and use `_getOpmlNavigator(providerId)`. Put provider URL
preparation/resolver recognition in the definition. Extend normalized metadata
only when needed, add recorded fixtures and test cancellation, presets and
access failures. Reuse the same parser, navigator, player and artwork services.

## User-configured directories

The `custom` provider reuses this stack without provider endpoints. Its station
keys derive from stream URLs, avoiding guide-ID collisions across directories.
A provider may opt into the bounded client cache with `directoryCacheTtl`;
custom uses 60 seconds and the navigator receives the same TTL. Redirect
results carry their effective URL for relative resolution and cycle checks.
The navigator accepts an optional UI icon hook and preserves loading/error,
cancellation and bounded window state. See [custom directory behavior and
limits](USER_DEFINED_STATIONS.md#custom-opml-directories).

HTTP redirect ownership and HLS validation are documented in [HTTP redirects and HLS transport](http-hls-redirects.md).

RSS 2.0 links and directly configured feeds use the same navigator via the incremental reader described in [podcast support](PODCAST_RSS.md). OPML parsing limits remain separate.
