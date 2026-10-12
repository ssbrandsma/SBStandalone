# User-Defined Radio Stations

## Overview

Standalone Radio reads user-managed stations created by the Standalone Base
web interface. The applet remains a read-only consumer: Standalone Base owns
all writes, validation, logo uploads, revision increments, and atomic file
replacement.

The Standalone Radio menu contains:

1. Radio Browser
2. RadioFeeds UK & Ireland
3. My Radio Stations

Custom stations use the existing stream player, HTTPS proxy, ICY metadata,
artwork lookup, presets, and Standalone Base Now Playing publisher. No second
player, proxy, background process, or polling timer is introduced.

## Standalone Base Integration

The requested `docs/RADIO_STATIONS_MANAGEMENT.md` was not present in the
Standalone Base 0.2.6 source tree during implementation. The shipped
`native/sbwebserver/src/radio_stations.c` implementation was therefore treated
as authoritative.

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
   Base and active extended storage.
2. Add HTTP and HTTPS stations through the Standalone Base web interface,
   including external, uploaded, and absent logos.
3. Confirm the three main menu entries and configured ordering.
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

- If My Radio Stations is empty, confirm extended storage is mounted and
  `stations.json` is readable by the SqueezePlay process.
- Unsupported schema versions and root-level JSON errors preserve the previous
  valid list.
- The player supports codec hints only through its existing decoders. `auto`
  does not inspect content or URL extensions.
- Uploaded logos can be retained for presets, but cannot currently be sent as
  authenticated web URLs through generic native Now Playing.
- Physical-device behavior has to be validated separately; host tests cannot
  exercise the firmware decoder, renderer, preset buttons, or flash mount.
