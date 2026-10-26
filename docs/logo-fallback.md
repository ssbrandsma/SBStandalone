# Station logo fallback ? Radio 0.9.17

Supplied station artwork still takes precedence. Missing/invalid URLs, ICO
paths (including query strings), TuneIn placeholders and failed downloads
trigger an asynchronous TuneIn OPML search through the existing OpmlClient.

Only one audio/station outline whose original text matches the station name
case-insensitively is accepted. Podcasts, partial names, duplicate exact matches,
missing images and cdn-radiotime-logos.tunein.com/s0q.png are rejected. No fuzzy
matching, station stream resolution or provider/identity substitution occurs.
The returned image follows the existing bounded HTTP/image cache path and uses
the original stationuuid. A bounded URL sidecar survives Jive restarts and feeds
the existing native Now Playing station-art API. Callbacks retain their station
generation; stale results cannot replace another station, and track artwork
keeps precedence. Uploaded user logos still take precedence.

Concurrent calls for a station share lookup/download and notify up to 16
listeners. Successful images persist in the existing 100-image cache; eviction
allows another lookup. Failures have a one-hour RAM-only negative cache capped
at 100 stations. Lookup, rejection, match and download failures are logged.
There is no new process, image decoder or dependency. The OPML client and its
existing timeouts/body limits are reused and loaded only when necessary.

Regression tests cover real parsed OPML, exact/case/partial matching, podcasts,
placeholders, duplicate matches across categories, invalid/failed original
artwork, failed fallback downloads, positive/negative caching, eviction,
coalescing, identity preservation and isolated Jive Lua 5.1 module imports.

Live check on 26 October 2026: literal DR P1, DR P3 and DR P5 each returned a
unique exact match and a valid PNG (1762, 1959 and 4064 bytes respectively).
Literal DR P2, DR P4 and DR P6 returned no exact match; this does not promise
logos for every regional or differently named DR station. Provider responses
can change. Saved raw responses/signatures are in local release diagnostics.
