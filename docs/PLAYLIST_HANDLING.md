# RadioFeeds playlists and HLS

## Diagnosis

The supplied BBC examples successfully fetched both the lsn.lv wrapper and the
BBC manifest (HTTP 200). Failure occurred in local playlist handling, before
audio decoding: the parser accepted only absolute HTTP entries and the loose
`.m3u` pattern also matched `.m3u8`. The fetched HLS media manifest contains
`EXT-X-MEDIA-SEQUENCE`, `EXT-X-TARGETDURATION`, and relative `.ts` segment names.
A read-only workstation fetch confirmed that structure for the example source.

Resolving one `.ts` URI is not sufficient. HLS requires ordered segment loading,
playlist refresh and container handling; see the primary specification,
[RFC 8216](https://www.rfc-editor.org/rfc/rfc8216). The existing StreamPlayer
opens one continuous audio stream. Standalone Base now supplies the missing
HLS loader/demultiplexer through its existing sbproxy process.

Supported AAC/MP3 HLS streams, including MPEG-TS audio, now use the native relay.
Both Base and Radio must be updated together. The full architecture, resource
measurements, test results and limitations are in Standalone Base's
`docs/HLS_AUDIO.md`. Physical Radio playback remains unverified for this change.

## Changes

- Exact `.m3u`, `.m3u8` and `.pls` suffix checks, excluding query/fragment.
- Ordinary playlists accept absolute, relative, root-relative and scheme-relative
  entries using Jive's existing LuaSocket URL resolver, including dot segments.
- PLS header/metadata is skipped; File entries and UTF-8 BOMs are handled.
- HLS `EXT-X-` markers retain the manifest URL and set `hls=true`, rather than
  returning the first segment/variant as an ordinary audio stream.
- All station directories share this resolution path. Playlist MIME types also
  trigger shared content inspection, preserving ordinary extensionless playlists.
- `UrlTransport.hlsUrl` points HLS to loopback sbproxy. A local HEAD probe reports
  actual AAC/MP3 output before Jive chooses its decoder. Failed/unsupported HLS
  probes never fall back to passing the manifest/container to that decoder.
- Supported Radio Browser HLS audio entries are included; the station cache and
  presets retain the HLS flag. Cache version changes invalidate the old filtered
  directory data.
- Nested playlists are resolved inside one operation, with a five-playlist
  limit and loop detection, rather than recursively restarting UI playback.
- The first selection's callback cannot start playback after a later selection.
- Terminal HTTP callbacks are delivered once; original station data and playlist
  identity are preserved. Logs redact resolved URL query parameters.
- AAC titles such as `(AAC (HLS))` no longer get misclassified as MP3 metadata;
  that does not enable HLS decoding.
- Unsupported HLS formats produce a failed probe and detailed native diagnostics;
  encrypted/fMP4/container data is not forwarded as AAC. Error-popup text no
  longer claims that all HLS playback is unsupported.

The existing TLS policy and SqueezePlay decoders are unchanged. A small native
internal module, not a new daemon, handles HLS downloads and demux. No segment
cache or transcoder was added. LuaSocket was already part of Jive.

## Validation

`test/radiofeeds-playlist-test.lua` runs under Lua 5.1 with LuaSocket, mocked HTTP,
and no network requests or disk writes. Coverage includes ordinary M3U/M3U8/PLS,
query strings, relative URL resolution, HLS detection without choosing a segment,
BOMs, invalid schemes, empty input, loop detection, bounded nested resolution,
callback deduplication and source station preservation. `test/hls-player-test.lua`
executes the real transport/probe methods in isolation, testing codec selection,
MIME discovery, failed probes, station metadata and directory-cache preservation.
Native manifest/container rejection tests belong to Base. Existing transport,
logo-cache, user-station and Now Playing regressions also pass.

Manually validate on a future approved deployment:

1. Select a BBC HLS entry with updated Base and Radio: expect the local relay,
   `audio/aac`, an ADTS AAC decoder and successful playback, not “playlist has no
   HTTP stream”. This is a required future physical-device acceptance test, not
   an already observed hardware result.
2. Select an ordinary M3U/PLS direct MP3/AAC station: expect playback as before.
3. Select another station while a playlist is loading: the older response must
   not switch playback back.
4. Exercise a looping/nested playlist: expect one bounded failure popup.

No physical-device deployment, restart or playback validation was performed for
this correction. The supplied desktop-LMS timeout/disconnection messages and
freed-SDL-surface error are separate findings, not fixed by this playlist change.

## Remaining limitations

The native relay rejects encrypted media, fMP4/CMAF, byte ranges, explicit
discontinuities and unsupported codecs. Timed ID3 metadata now uses Base's bounded
per-stream queue and decoder elapsed time; station information remains the fallback.
See Base's `docs/HLS_TIMED_METADATA.md` report for timing/artwork limits and the
exact format/resource limits and hardware validation checklist.

Ordinary playlist fetching still uses the existing legacy HTTP/proxy transport.
A redirect handled entirely inside the generic HTTPS proxy does not expose its
final origin URL to Lua; a relative ordinary-playlist entry may then use the
original base URL. HLS manifests handled by the native relay use curl's effective
URL and do not have that specific limitation.
