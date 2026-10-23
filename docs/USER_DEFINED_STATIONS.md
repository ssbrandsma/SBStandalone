# User-Defined Radio Stations

## Overview

Standalone Radio reads user-managed stations created by the Standalone Base
web interface. The applet remains a read-only consumer: Standalone Base owns
all writes, validation, logo uploads, revision increments, and atomic file
replacement.

The Standalone Radio menu contains:

1. Radio Browser
2. TuneIn
3. RadioFeeds UK & Ireland
4. My Radio Stations

Custom stations use the existing stream player, HTTPS proxy, ICY metadata,
artwork lookup, presets, and Standalone Base Now Playing publisher. No second
player, proxy, background process, or polling timer is introduced.

## Standalone Base Integration

Standalone Base owns the existing station API and persistent storage.

Standalone Base atomically replaces this file after a successful edit:

```text
/mnt/sbdata/config/radio/stations.json
```

Uploaded logos are stored under:

```text
/mnt/sbdata/config/radio/logos/
```

## Configuration Schema

The implemented schema is version 1:

```json
{
  "schemaVersion": 1,
  "revision": 4,
  "stations": [
    {
      "id": "radio-paradise",
      "name": "Radio Paradise",
      "description": "Main Mix",
      "streamUrl": "https://example.org/stream.mp3",
      "logoUrl": "",
      "logoFile": "logo-0123456789abcdef.png",
      "codec": "auto",
      "enabled": true,
      "order": 10
    }
  ]
}
```

`schemaVersion`, `revision`, `stations`, `id`, `name`, `streamUrl`, `enabled`,
and `order` are required. `description`, `logoUrl`, `logoFile`, and `codec` are
optional to the applet. Missing optional string fields become empty strings and
the codec defaults to `auto`.

The loader mirrors Standalone Base's effective limits: 256 KiB per document,
250 stations, 64-byte IDs, 256-byte names, 1,024-byte descriptions, 8,192-byte
stream URLs, 4,096-byte logo URLs, and 128-byte logo filenames. Supported codec
hints are `auto`, `mp3`, `aac`, `ogg`, and `flac`. `auto` safely falls back to
the existing player's default MP3 decoder behavior; no decoder is inferred from
the filename.

IDs may contain ASCII letters, numbers, `_`, and `-`. Uploaded logo filenames
may additionally contain `.`. Path separators and `..` are rejected.

## Loading And Reloading

`UserStations.lua` opens and closes the JSON file for each menu activation. It
checks the file size before reading and decodes it once. The normalized list is
replaced only when the document revision changes. Returning to the list causes
another revision check; there is no continuous polling.

A malformed station is skipped without hiding other valid stations. Duplicate
IDs keep the first valid occurrence. Disabled stations are omitted. Enabled
stations sort by numeric `order`, case-insensitive name, then ID.

Missing, unreadable, oversized, empty, invalid, or unsupported documents do not
crash Jive. After one successful load the last-known-good list remains visible
when a later read fails. A valid empty list intentionally clears that cache.

## Menu And Playback

My Radio Stations is always visible. An empty valid configuration displays
"No custom stations configured." A configuration that cannot be loaded and has
no cached stations displays a temporary-unavailable message.

Selecting a station passes its normalized object to the same `_playStation`
entry point used by Radio Browser and RadioFeeds. HTTP/HTTPS transport,
redirects, buffering, reconnect limits, decoder selection, ICY metadata, and
errors therefore retain their existing behavior.

Configuration changes never interrupt current playback. New names, URLs, and
logos take effect the next time a station is selected.

## Logo Resolution

The precedence is:

1. A validated `logoFile` below the Standalone Base logo directory.
2. A valid external `logoUrl` downloaded through the existing logo cache and
   HTTPS proxy path.
3. The packaged generic radio icon.

Local logo paths are constructed only after strict filename validation. Their
bounded bytes may be copied into the existing preset logo cache; the read-only
source file is never removed or modified. External images retain the existing
512 KiB cache limit and PNG/JPEG validation.

Standalone Base 0.2.6 advertises `/api/radio/logos/<file>`, but its actual HTTP
handler requires the secret management token even for GET requests. Standalone
Radio deliberately does not read or expose that token. Consequently the local
file is used for Jive artwork, while the generic Standalone Base Now Playing API
cannot publish a usable HTTP URL for an uploaded logo. Making authenticated
logo GETs public/read-only in Standalone Base would be the smallest compatible
follow-up if native LMS artwork for uploaded logos is required.

## Presets

Preset assignment continues to use `PresetStore`. A user-station preset stores
the stable station ID as well as its last-known snapshot. On recall, the applet
reloads `stations.json` and resolves that ID against the latest enabled list.
Renames and stream URL changes therefore take effect without reassigning the
preset. Deleted or disabled stations show a clear unavailable message and do
not play stale or unrelated content. Existing Radio Browser and RadioFeeds
presets retain their previous snapshot behavior and format.

## Now Playing

User stations set `source="user"`, a stable ID and station name, then flow
through the existing Standalone Base claim/update/heartbeat/release client.
Playback state and ICY title/artist updates are published exactly as for other
radio sources. No changes are made to Spotify Connect or Qobuz Connect
ownership.

## Errors And Performance

Errors are logged once per menu reload with no stream credentials. Full stream
URLs are not logged by the loader. The design retains one decoded document only
during reload and one normalized cached list afterward. It adds no native
dependency, background process, open file descriptor, or timer.

## Build And Installation

From the repository root:

```powershell
Get-ChildItem applet\StandaloneRadio -Filter *.lua | ForEach-Object { luac -p $_.FullName }
Get-ChildItem test -Filter '*-test.lua' | ForEach-Object { lua $_.FullName }
Get-ChildItem test -Filter '*-static.ps1' | ForEach-Object { & $_.FullName }
.\scripts\build-applet-package.ps1
```

Install the generated package using the normal Applet Installer repository
workflow. Building does not deploy or restart a Radio.

## Physical-Device Test Procedure

1. Install a package containing `UserStations.lua` on a Radio with Standalone
   Base. Extended Storage is optional.
2. Add HTTP and HTTPS stations through the Standalone Base web interface,
   including external, uploaded, and absent logos.
3. Confirm the main menu entries and configured ordering.
4. Start each station and verify buffering, audio, ICY text, Home/Back behavior,
   and native Now Playing ownership.
5. Assign and recall a physical preset. Rename the station and change its URL,
   then verify that the same preset resolves the new values.
6. Disable and delete the station, verifying that preset recall reports it as
   unavailable.
7. Edit the configuration while the list is open, leave and return, and verify
   the revision reload without restarting Jive.
8. Temporarily corrupt or remove the JSON file and verify last-known-good and
   empty/error behavior.
9. Recheck Radio Browser, RadioFeeds, Spotify Connect, and Qobuz Connect.

## Troubleshooting And Known Limitations

- If My Radio Stations is empty, confirm the active configuration path and
  `stations.json` is readable by the SqueezePlay process.
- Unsupported schema versions and root-level JSON errors preserve the previous
  valid list.
- The player supports codec hints only through its existing decoders. `auto`
  does not inspect content or URL extensions.
- Uploaded logos can be retained for presets, but cannot currently be sent as
  authenticated web URLs through generic native Now Playing.
- Physical-device behavior has to be validated separately; host tests cannot
  exercise the firmware decoder, renderer, preset buttons, or flash mount.

## Custom OPML directories

In the Base portal, open **Standalone Radio ? Add Station**, choose **OPML directory**,
enter a name and HTTP(S) OPML URL, then save. Codec is hidden; description,
external/uploaded logo, order and enabled work as for stations. The list shows
both types. Edit or delete normally; reopen My Radio Stations to load changes.

The existing schema gains optional `type` (`station` by default, or `opml`):

```json
{"id":"my-directory","type":"opml","name":"My directory","streamUrl":"https://example.org/radio.opml","codec":"auto","enabled":true,"order":20}
```

Other existing fields remain supported. Unknown types are rejected by Base.
There is no fetch on save. Base writes atomically and increments the revision.
With Extended Storage mounted as `sbubifs`, configuration is
`/mnt/sbdata/config/radio/stations.json`; otherwise it is
`/mnt/storage/standalonebase/radio/stations.json`. Uploaded logos live in the
adjacent `logos/` directory. Radio follows the same active storage root.

Directories appear with `>` alongside playable stations. Opening one uses the
shared `OpmlClient`, `OpmlParser` and `OpmlNavigator`; playable children use
StreamPlayer. Inline folders need no request; remote folders load only when
selected. Back restores the previous menu and selection. A directory cannot
be played through a station preset.

Supported outlines include `text`/`title`, case-insensitive `URL`/`url`,
`xmlUrl`, audio entries, inline children, remote link/directory entries and
`image`/`icon`. `htmlUrl` is homepage metadata, never an inferred stream.
Relative links and artwork use the final redirected document URL. Unknown
entries retain the existing unsupported-item behavior. RSS feeds themselves
are not supported. Example: [custom-directory.opml](../test/fixtures/opml/custom-directory.opml).

Existing asynchronous HTTP, Base HTTPS proxy, tracing, redirects, cancellation,
stream resolution and artwork rendering are reused. Local logo wins over the
external logo. Icons use existing artwork fetching; only the first 24 rows in
a menu request icons to bound decoded artwork memory.

Limits: 250 configured entries / 256 KiB configuration; OPML 256 KiB,
1,024 XML nodes, XML depth 32, 12 active navigation levels, 15-second request
timeout, five redirects. XML DTD/entity declarations are rejected; no external
entities or local file URLs are fetched. Parsing is synchronous but bounded;
there is no recursive prefetch or new worker/process. Custom directory URLs
support query strings; fragments, userinfo and IPv6 literals are unsupported.

Custom directories cache at most two parsed pages in RAM for 60 seconds,
matching requested and effective URLs. One distinct directory request is
allowed at a time; up to eight listeners share the same pending request.
Cancellation releases a listener and cancels HTTP when none remain. Failed
requests are not cached. Revisiting after expiry refreshes. Nothing is cached
to flash. Ancestor URL checks reject circular links, including redirects;
the depth cap bounds alternate-URL cycles.

Loading, empty and failure menus preserve Back navigation. Malformed or
oversized XML, HTTP/network failures and unsupported entries do not replace
other custom stations. TuneIn and RadioFeeds retain their existing policies.
