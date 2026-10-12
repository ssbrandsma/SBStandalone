# StandaloneBase Now Playing integration

Standalone Radio publishes its authoritative playback state to StandaloneBase's
version 1 loopback API. StandaloneBase converts that state to LMS playerstatus
and CometD notifications; this applet does not modify the stock NowPlayingApplet
or inject LMS events.

## Architecture

`StandaloneBaseNowPlaying.lua` is an optional, failure-isolated client owned by
`StandaloneRadioApplet.lua`. Existing `StreamPlayer` callbacks feed it alongside
the existing artwork model. API availability never gates audio, DNS is not used
(`127.0.0.1`), and the token remains only in RAM.

The legacy custom Now Playing menu entry has been removed. State callbacks
explicitly suppress its window navigation, including the initial `RESOLVING`
callback that historically carried `show=true`. The object remains isolated as
an artwork sink so station-logo and track-artwork code is not destabilized. The
stock Logitech Now Playing screen is the primary playback interface.

## Native Now Playing navigation

Firmware 7.7.3's `NowPlayingMeta.lua` registers the `goNowPlaying` service.
`NativeNowPlaying.lua` invokes that exact service through `AppletManager` with
`Window.transitionPushLeft`; no stock file or window is recreated. The stock
`NowPlayingApplet:showNowPlaying()` checks `Framework:isWindowInStack()`, moves
its existing window to the top, and creates a window only when none exists.

Navigation is requested only by the central `onSelected` callback produced by
an explicit `StreamPlayer:start()`. This covers lists, Radio Browser,
RadioFeeds/custom stations, and short preset actions. Reconnect uses
`_begin(..., true)` and does not emit `onSelected`; metadata, artwork, API
recovery, and heartbeat callbacks likewise cannot navigate. Long-press preset
assignment continues to call only `_assignPreset()`.

A 50 ms one-shot coalesces rapid preset presses. The current logical station
generation invalidates older callbacks. If the native service or current Player
is not ready, retries occur at 250 and 500 ms only. Before calling the service,
the controller obtains the resident NowPlaying applet and leaves it untouched
when `Framework:isCurrentWindow()` is true. When it is elsewhere in the stack,
the stock service performs the safe reuse/move. Pending navigation is canceled
on applet shutdown. Navigation never blocks playback and never falls back to the
legacy custom screen.

The client permits one in-flight operation. It stores the latest desired
snapshot, so rapid ICY changes are coalesced. Each completion is associated
with a request serial and obsolete callbacks are ignored. Responses are bounded
to 16 KiB and requests have a 15-second application timeout. Failed operations
retry after 2, 5, 10, then 30 seconds; no polling loop is used.

Stock SqueezePlay `RequestHttp` treats only HTTP 200 as successful. The client
overrides response dispatch on its own request instances so it can read the
documented HTTP 201 claim response. Shared Jive networking code is unchanged.

## Lifecycle and API calls

A user-selected station calls:

```text
POST /api/nowplaying/claim
```

```json
{"source":"radio","name":"Standalone Radio","capabilities":{"play":false,"pause":false,"stop":false,"next":false,"previous":false,"seek":false,"volume":false}}
```

Opening menus and downloading logos do not claim or release. A station switch
within the app retains the session and sends a complete update. Intentional stop
first publishes `stopped`, then calls `POST /api/nowplaying/release`. Reconnects
retain the session.

`StreamPlayer` increments a logical station generation only for explicit starts,
not reconnect attempts. Selection, state, connection, and metadata callbacks
carry that generation. The API client rejects callbacks whose generation or
station identity is no longer current. A new selection immediately clears ICY
fields and increments the desired revision. If an older HTTP update is already
in flight, its completion cannot mark the newer revision published; the newest
complete snapshot is sent next.

After the first successful complete update for each station generation, the
existing player staging hook runs once to ensure the stock playerstatus
subscription is active. It does not run for ICY-only changes and does not open
or move a window.

Every 45 seconds an owned session calls `POST /api/nowplaying/heartbeat`. An
update also renews the server's 120-second lease. A failed API operation does
not affect the decoder or stream reconnect logic.

After HTTP 409, the client invalidates its token and reads
`GET /api/nowplaying`. If API version 1 reports no active session and
`StreamPlayer` still owns local playback, it reclaims and republishes a complete
snapshot. If another source is active, it stops publishing until the next
explicit radio activation. This prevents an ownership fight with Spotify,
Qobuz, or another future source.

## State and metadata mapping

| StreamPlayer | API state |
|---|---|
| `RESOLVING`, `CONNECTING` | `buffering` |
| `PLAYING` | `playing` |
| `RECONNECTING`, `CONNECTION_LOST` | `buffering` |
| `FAILED` | `error` |
| `STOPPED` | `stopped`, then release |

Updates always set `live:true`, `position_ms:0`, omit duration, and advertise no
seek or command capability. `StreamMetadata.lua` trims metadata and splits only
the conventional spaced `Artist - Title` delimiter. Title-only and ambiguous
values remain intact. Empty metadata clears song fields. Duplicate values cause
no request.

Station identity is `radio:` plus the normalized project station ID. Radio
Browser UUIDs, RadioFeeds IDs, custom station IDs, and persisted preset IDs are
therefore stable. A legacy station missing an ID gets a deterministic hash of
its canonical URL after user-info removal; the URL itself is never published.
Redirected station copies preserve the original ID, so redirects and ICY song
changes do not change playlist identity.

Example live update:

```json
{"session_id":"TOKEN","state":"playing","live":true,"position_ms":0,"track":{"id":"radio:radiobrowser:abc","station":"Radio Paradise","title":"Sultans of Swing","artist":"Dire Straits"}}
```

## Compatibility and limitations

Older StandaloneBase versions return 404 or fail to connect. The applet keeps
playing and retries at the bounded
backoff. Malformed JSON, timeout, 4xx/5xx, or restart are similarly isolated.
Logs use `StandaloneRadio NowPlayingAPI:` and never include session tokens or
stream URLs.

## Artwork selection

The client publishes `track.artwork_url` with this priority:

1. The current song cover reported by the existing `TrackArtwork` lookup.
2. The current station's original `favicon`/`remoteLogo` URL.
3. No artwork field.

Changing ICY metadata immediately clears the preceding cover and republishes
the station logo while the existing asynchronous lookup runs. Its discovery
callback retains the original remote URL and publishes it directly to native
Now Playing through Standalone Base. A successful result replaces the logo
without changing session or station identity. No local artwork copy or custom
Now Playing window is maintained. Exact station generation,
station ID, and StreamTitle checks reject delayed results.

`UrlTransport.artworkUrl()` accepts bounded credential-free HTTP(S) URLs only.
HTTP remains unchanged. HTTPS becomes
`http://127.0.0.1:8765/https/<host>/<path>` using the existing SBHttpsProxy
format, including query strings and percent encoding. Already-proxied URLs are
unchanged. Unsupported schemes, whitespace, user-info, malformed authorities,
and values exceeding StandaloneBase's 383-byte payload limit are omitted. No
filesystem path, image bytes, upload, new cache, or new downloader is used.

Native playback commands, command polling, seek, and volume synchronization are
not implemented or advertised. Native artwork retrieval by firmware 7.7.3 is
implemented but remains hardware-unverified. Native screen auto-opening is also
deliberately deferred.

## Tests

`lua test/nowplaying-client-test.lua` covers parsing, idle startup, claim,
coalescing, playing publication, rapid A→B→C switching, stale metadata,
delayed HTTP completion, API unavailability, stopped-before-release, restart
reclaim, takeover handling, state mapping, cover priority, logo fallback, URL
proxying, invalid URLs, duplicate covers, stale artwork, and artwork
republication after reclaim. The static navigation test
verifies there is no legacy window-opening/menu path. The native navigation
test covers list/preset-equivalent selection, duplicate prevention, rapid input,
temporarily missing service/player, stale retry cancellation, and shutdown.
These are host tests, not device validation.
