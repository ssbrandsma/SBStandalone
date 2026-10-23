# HTTP redirects and HLS transport

## Confirmed failure

Inspection of the radio's `/usr/share/jive/jive/net/RequestHttp.lua` (7.7.2)
confirmed that its GET body handler automatically follows 301/302/307 responses.
It mutates the same request, resets `t_httpResponse.statusCode` and status line
to boolean `false`, and creates another `SocketHttp` directly. Its URL defaults
retain port 80 even for HTTPS. There is no TLS routing through UrlTransport.
A later body/EOF callback from the old socket observes the reset status and
tries to concatenate `false` into an error at line 406. The boolean is assigned
by RequestHttp, not returned by LuaSocket. Repeated callbacks can reenter this
broken shared request; these exceptions are not evidence of a player retry loop.

## Fix

`UrlTransport.explicitRedirects(request)` intercepts 3xx body dispatch only on
that request instance. It completes the existing safe sink once without letting
Jive mutate the request or create another socket. Neither Jive nor sbproxy is
modified. OpmlClient's existing redirect handler creates a fresh request for
each target after UrlTransport selects HTTP or the existing sbproxy HTTPS route.
Relative Location uses LuaSocket URL resolution, preserving encoded queries.
HTTP-to-HTTP, HTTP-to-HTTPS, HTTPS-to-HTTPS and HTTPS-to-HTTP follow the existing
HTTP(S) policy. Other schemes fail; missing Location, repeated URLs and more
than five applet-visible redirects terminate with an error. Once a request is
inside the compatibility HTTPS proxy, libcurl already follows redirects itself
(up to its existing eight-hop cap). That behavior is unchanged; it does not
create Jive sockets. The native HLS relay retains its separate existing public-
fetch policy and three-hop libcurl cap.

Each hop has the existing 15-second timeout and size limits. Completed redirect
readers close on a deferred one-shot timer, avoiding both reentrant close and
orphan readers when a redirect body stalls. Cancellation stops the active child
chain; existing finished/cancelled/generation guards discard stale data and
duplicate errors. Failed playlist resolution has one terminal callback and
introduces no retries. Redirect traces retain parent IDs and record schemes,
transport and status; playlist-resolution traces record classification/outcome.

## Playlist and HLS behavior

OpmlClient intentionally resolves OPML, M3U, PLS and HLS through one bounded
fetch path for RadioFeeds, TuneIn and custom entries. Existing content-based
classification is unchanged: EXT-X tags identify HLS, and the effective manifest
URL is handed to the native `/hls/<scheme>/...` relay instead of treating segment
URLs as independent stations. The relay handles master variants, relative
segments, media refresh and segment redirects using its existing libcurl/TLS,
container validation and bounded retry rules. No new daemon or TLS stack exists.

The native relay supports its existing AAC/MP3 elementary and MPEG-TS audio
formats; unsupported encryption/containers remain explicit HLS failures.
The compatibility proxy does not expose its final upstream URL to Lua. Relative
links in non-HLS OPML/M3U/PLS documents redirected internally by that proxy still
use the requested HTTPS base; changing that requires a proxy API change outside
this task. Applet-visible redirects resolve against the actual target, and the
native HLS relay independently uses libcurl's final effective URL for manifest
and segment resolution, so this limitation does not affect the tested HLS URLs.
Changing the network during device playback was not part of live validation;
deterministic relay tests cover interrupted transfers and bounded recovery.

## Validation

`python test/run-tests.py` includes a dedicated redirect suite exercising Jive-
style body dispatch and duplicate EOF callbacks, both exact IDR1/IDR2 URLs,
proxy routing, relative/query redirects, scheme changes, loops/limits, missing
or unsafe Location, connection errors, cancellation, timeout and once-only
completion. Existing M3U/PLS, OPML, provider and HLS suites remain enabled.
The native HLS unit and HTTP integration suites run with address/undefined-
behavior sanitizers and cover manifest/variant selection, relative and redirected
segments, TLS, invalid formats, refresh and interruption/recovery.

Development validation uses 192.168.1.226 (the user's updated address), with
backups at `/mnt/storage/hls-redirect-backup-20261023`. IDR1 and IDR2 both
resolved HTTP 301 through sbproxy via a temporary OPML fixture, started the native AAC decoder, and fetched
successive HTTPS media playlists and MPEG-TS segments. In the final IDR2 run,
the relay reported 11 segments / 2,060 audio frames / 1,420,752 bytes with zero
retries or skipped segments before the intentional station switch. Nested OPML
navigation then started an HTTPS MP3 stream (HTTP 200, MP3 decoder and ICY). This is runtime transport
and decoder evidence; remote testing cannot independently confirm audible sound.
A separate HTTP MP3 station selected through RadioFeeds also reached HTTP 200,
started the MP3 decoder and delivered ICY titles. Native proxy RSS was about
1.35 MiB with three threads during sampling; the device has no swap. Virtual
Radio was active during interactive checks, so CPU measurements include screen
capture/remote-control overhead and do not establish an audio-only CPU baseline.
The device also logged unrelated SlimProto server inactivity reconnects; those
are distinct from the eliminated RequestHttp task exception. Existing stock
NowPlaying notification errors involving a nil shuffle/repeat `mode` also
occurred before the final HLS start; Now Playing remains outside this task.
No release version, public repository feed or production download was published.
