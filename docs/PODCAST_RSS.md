# Generic RSS podcasts

## Confirmed causes and changed files

BBC HTTP requests succeeded, but the directory path always invoked the OPML
parser. An RSS root failed format validation; large feeds also exceeded OPML's
256 KiB / 1,024-node limits. RSS now has its own bounded incremental reader,
without relaxing the OPML parser's limits.

The observed pre-playback HTTP 400 has a concrete compatible-client cause:
Jive's `luajson` encoder emits `[]` for an empty table, while Base requires audio
objects. Unknown audio snapshots are now omitted until values exist. Text bounds
also match Base's existing contract. Native decoder elapsed values are already
milliseconds. Native Now Playing navigation waits for successful publication and
playlist metadata instead of opening the empty-playlist view prematurely.

| Files | Change |
|---|---|
| `PodcastRssParser.lua` | Streaming RSS metadata, selection, ordering and XML/resource guards |
| `OpmlClient.lua` | Shared streamed directory fetching, RSS deadlines/read budget and episode conversion |
| `OpmlParser.lua`, `OpmlNavigator.lua`, applet/strings | RSS outlines and direct feeds in existing menus |
| `StreamPlayer.lua`, `PresetStore.lua` | Finite playback, pause/resume, completion and saved episode semantics |
| `StandaloneBaseNowPlaying.lua`, `NativeNowPlaying.lua` | Existing API metadata/position and publication-aware navigation |
| Build/deployment scripts and `test/` | Package inclusion/validation and deterministic regression fixtures |

## Architecture and use

In Base's Standalone Radio form choose **OPML directory** and enter either an
OPML URL or an RSS 2.0 feed URL. On the radio open **My Radio Stations**, open
the source, choose a podcast, then an episode. `type="rss"`, `xmlUrl` and ordinary
remote directory links share the existing OPML navigator. Actual XML root
selects OPML or RSS; filenames and Content-Type are hints, not trusted format
identifiers. The web schema and Base API are unchanged.

`PodcastRssParser.lua` uses the already-installed LuaExpat SAX API for RSS.
`OpmlClient` sends chunks directly to it and retains no complete RSS body.
OPML still delegates to the existing parser, including its provider text/entity
compatibility. Transport, proxy, redirects, cancellation, TTL cache, menu state,
StreamPlayer and artwork fetching remain shared. No daemon, TLS stack, cloud
service or production dependency is added.

RSS channel fields: title, description, language, author, homepage and iTunes/RSS
artwork. Episode fields: title, summary/description, publication date, GUID,
audio enclosure URL/type/length, iTunes duration/episode number and artwork.
Namespace URIs are used, so iTunes prefixes need not literally be `itunes`.
CDATA and XML entities are handled by Expat; visible HTML markup is stripped.
Missing optional metadata is allowed. Episode artwork precedes channel artwork.

Only supported, HTTP(S) audio enclosures are selectable. The deterministic
preference is MP3, raw AAC/AAC+, AAC-in-MP4/M4A, Ogg, then FLAC; feed order breaks
ties. Video/unknown MIME types and file/credential URLs are excluded. Original
query parameters are preserved. AAC MP4 uses native decoder transport type `5`,
while raw AAC retains ADTS type `2`; no transcoding is introduced.

Dated episodes sort newest first; undated episodes follow in feed order. The
best 50 are retained while validating the entire feed to EOF. There is no
recursive prefetch, partial XML success, episode download cache or flash cache.
Empty feeds display `No playable episodes`. Invalid, truncated,
oversized or unsupported documents display a retryable directory error; Back
and cancellation remain available. There is no automatic retry of invalid feeds.

## Finite audio and Now Playing

Episodes use actual enclosure URLs through the existing player and HTTPS proxy.
Network FIN allows buffered audio to drain; native audio-end notifications stop
playback and release ownership. Transfer/decoder failures stop without restarting
the episode from zero in a live-radio retry loop. Selecting another episode is
explicit; there is no automatic next/previous queue.

Short Pause pauses an episode; Play resumes its buffered decoder. Long Pause
(the native Stop action) stops and releases ownership. Live-radio Pause retains
its existing Stop behavior. Seeking/range-based resume across Stop or restart
is not implemented and is not advertised. After Stop, Play starts from the
beginning. Very long pauses remain subject to the server/socket's behavior.

The existing Now Playing API receives `live=false`, episode title, podcast as
artist/album, episode/channel artwork, `track.duration_ms` when known and native
decoder position in milliseconds. The native Now Playing view opens after publication and waits for the native
Player to receive its playlist metadata, avoiding the empty-playlist race.
Position is sampled at five-second intervals;
Base advances the displayed clock between samples. Stop/completion releases the
session. Text is bounded to Base's 256-byte fields at UTF-8 boundaries. Unknown
optional audio properties are omitted, avoiding empty Lua tables being serialized
as JSON arrays where Base expects objects. Rejection diagnostics include Base's
error code without logging ownership tokens or whole payloads.

## Resource limits

| Resource | Limit |
|---|---|
| RSS bytes | 8 MiB; `rssMaxBytes` may lower the client limit |
| Retained episodes | 50; `rssMaxEpisodes` may lower the client limit |
| XML elements / depth | 200,000 / 32 |
| Individual XML token or text span | 64 KiB |
| Captured title/GUID/simple fields | 1,024 bytes before display normalization |
| Captured description/summary | 2,048 bytes |
| Enclosure/artwork URL | 4,096 bytes, HTTP(S) only |
| RSS total deadline after detection | 180 seconds, not reset per chunk |
| OPML limits | unchanged: 256 KiB, 1,024 nodes, depth 32, 15 seconds |
| Native read callback | 16 blocks; soft 8 ms CPU budget between blocks |
| Cache / navigation | existing two pages, 60 seconds, 12 levels |
| Menu artwork | existing first-24-row bound |

The read burst uses each request's existing SocketHttp pump and yields between
bounded callbacks. XML parsing is incremental within those callbacks, not one
large UI-thread parse. Attributes, comments, CDATA and text spans are bounded
before Expat can accumulate large strings/tables. DTD/entity declarations are
rejected across chunk boundaries before parsing. LuaExpat 1.0.2 lacks the newer
DTD callback; the lexical guard is compatible with that installed version.
NUL-containing UTF-16/32 documents are rejected so the guard cannot be bypassed.

## Validation

Deterministic tests cover RSS/iTunes namespaces, CDATA/entities, missing fields,
enclosure preference, artwork fallback, dates/order, large feeds, byte/episode/
token/depth caps, unsafe/truncated XML, streaming cancellation, OPML delegation,
read scheduling, finite-player state and Now Playing mapping. Existing TuneIn,
RadioFeeds, HLS and live-radio regressions remain in `python test/run-tests.py`.
The package includes the new module, and the deployment validator checks it.

All four supplied BBC feeds were downloaded and parsed in host tests:

| Feed | Bytes | Retained episodes |
|---|---:|---:|
| p05299nl.rss | 7,007,611 | 50 of 2,000 |
| p0gkff2h.rss | 151,906 | 48 |
| p0926q6m.rss | 107,949 | 50 of 51 |
| p0bqztzm.rss | 1,757,372 | 50 of 506 |

A separate host build using Lua 5.1.5 and the actual LuaExpat 1.0.2 C source
parsed the 7 MiB feed with approximately 535 KiB peak additional Lua-managed
heap and 171 KiB retained heap (about 1.0 CPU seconds on the host). This excludes
Expat/native allocator overhead and is not a device CPU benchmark.

## Manual radio checks and limitations

1. Add `https://b19.se/data/opml/bbc/bbc-news.opml` as an OPML directory.
2. Open it, select **The Conflict** or **Newscast**, and wait for episodes.
3. Select an episode; verify the native decoder starts and audio is audible.
4. Open Now Playing; verify title, podcast, artwork, duration and moving position.
5. Pause, wait, resume, then long-press Pause to Stop. Verify ownership releases.
6. Reopen the menu, choose another episode, then test Back while a feed loads.
7. Test a directly configured RSS URL and an invalid/truncated local fixture.
8. Recheck a live MP3 station, TuneIn, RadioFeeds and an HLS station.

Atom, video enclosures, encrypted media, seeking and automatic episode queues
are unsupported. MPEG-4 playback depends on the installed native AAC decoder
and a streamable MP4 layout; unsupported containers are not transcoded. Very
large or unusually slow feeds can still reach the bounded deadline. The
existing compatibility HTTPS proxy hides internally redirected effective URLs;
relative links then use the requested HTTPS base, as documented for OPML.

Device development validation uses 192.168.1.226. Original Lua modules are backed
up under `/mnt/storage/podcast-backup-20261023`. The complete 7,007,611-byte BBC
Newscast feed transferred through sbproxy in approximately 144 seconds (149 seconds
to parse completion and the episode list) with
Virtual Radio active; the RSS deadline is therefore 180 seconds. OPML retains
its shorter timeout. A smaller BBC feed displayed its episodes, and selecting
one started the MP3 decoder with HTTP 200. The generic Now Playing API returned
non-live episode title, podcast artist/album, artwork and duration. Audible
speaker output cannot be independently verified through SSH/browser control.
MP3 is device-validated; other enclosure formats have parser/decoder-selection
coverage but have not all been played as real files on this radio. No Base
source/API changes or public release are part of this implementation.

The native Now Playing screen was visually verified with Newscast title, artist,
album and artwork. The API reported `live=false`, a 2,008,000 ms duration and a
moving position. Pause held position at 31,745 ms across repeated reads; Play
resumed the existing decoder. Long Pause/Stop returned the API to stopped and
cleared the track. The final source set was checksum-verified on the device;
configuration was preserved apart from adding/removing temporary test entries.
The test package was built in a temporary directory, leaving public 0.9.13
artifacts, version metadata and release tags unchanged.

Final direct-feed validation used `https://podcasts.files.bbci.co.uk/p0gkff2h.rss`
configured directly as an OPML source. It displayed the episode list and played
an episode with native metadata. Pause/resume preserved the same episode and
advanced the position after resume. The API's active/source fields confirmed
ownership during playback; Stop returned `active=false`, an empty source and
a cleared track before cleanup.

End-of-audio completion is covered by deterministic native-callback tests (FIN, decoder completion, then output completion); the real BBC episodes were stopped during validation rather than played to their full duration.
