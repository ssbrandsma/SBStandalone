# Standalone Radio 0.9.13

## Changes

- Browse custom OPML directories alongside direct streams in My Radio Stations,
  using the shared client, parser, navigator, playback and artwork paths.
- Read custom entries and uploaded logos from Base's active internal or Extended
  Storage root. Bound directory caching, traversal and artwork requests.
- Handle HTTP-to-HTTPS playlist redirects through sbproxy without Jive's unsafe
  automatic redirect/reused-request path. Bound loops, timeouts and cancellation,
  close completed readers and preserve trace correlation.
- Use `Standalone/0.9.13` for OPML requests and update versioned Radio user agents.

The custom directory form/API requires the accompanying updated Standalone Base
build; Radio remains compatible with existing direct-station configuration.
See [custom OPML behavior](USER_DEFINED_STATIONS.md#custom-opml-directories) and
[redirect root cause, device evidence and limitations](http-hls-redirects.md).

## Validation and publication

All 17 Lua suites and four static checks passed; all Radio Lua modules compiled.
The archive passed the deployment validator (23 files). Prior device validation
on 192.168.1.226 confirmed both IDR HLS URLs, successive segments, AAC decoder
startup, HTTP/HTTPS MP3 and nested OPML navigation. Native HLS unit/HTTP tests
passed under address and undefined-behavior sanitizers.

Package: `dist/StandaloneRadio-0.9.13.zip`

SHA-1: `d293a06fe201046001cd391d065c4f7f2ca7eedf`

Published [ZIP](http://49.12.198.91/sbstandalone/StandaloneRadio-0.9.13.zip),
[combined feed](http://49.12.198.91/sbstandalone/extensions.xml) and
[merged feed](http://www.bytestack.nl/squeezebox/extensions.xml) were downloaded
and compared with the prepared release files. Both Radio targets (`baby`,
`fab4`) use the same package/version/hash. Other applet entries were preserved.
Local Base and bootstrap catalogs were updated; the remote bootstrap installer
catalog retained its existing Base-only policy. The bootstrap container was
restarted and verified running with UDP/TCP 3483 and TCP 9000 listeners.
Remote metadata backup suffix: `.bak.20261023-175912`.
