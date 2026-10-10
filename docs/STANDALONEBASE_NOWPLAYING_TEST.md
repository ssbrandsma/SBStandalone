# Standalone Radio / StandaloneBase device validation

This procedure has not been run. Do not deploy automatically. It targets a
Radio (`baby`) on firmware 7.7.3 r16676 and changes only the installed applet.

## Prepare, deploy, and roll back

1. Build on the development PC:

   ```powershell
   powershell -ExecutionPolicy Bypass -File .\scripts\build-applet-package.ps1
   ```

2. Record the ZIP SHA-256 and retain the currently installed applet directory.
   Follow `DEPLOYMENT.md`; do not write firmware or UBIFS partitions. Do not
   overwrite the backup until validation is complete.
3. Install the generated `dist/StandaloneRadio-0.9.1.zip` using the existing
   applet installation workflow and restart SqueezePlay only when that workflow
   requires it. Do not restart or replace StandaloneBase for the initial test.
4. Roll back by restoring the saved StandaloneRadio applet directory using the
   same atomic staging/rename procedure from `DEPLOYMENT.md`, then restart
   SqueezePlay. Runtime API tokens need no cleanup because they are in RAM.

Useful BusyBox checks (do not assume `curl`):

```sh
netstat -lnt | grep ':9000'
wget -qO- http://127.0.0.1:9000/api/nowplaying
top
logread | grep -E 'StandaloneRadio|NowPlayingAPI'
```

Port 9000 must remain loopback-only. When BusyBox `wget` lacks JSON POST
support, use only the status GET above and exercise writes through the applet.

## 1. Start a station

Start StandaloneBase Phase 2, open Standalone Radio, and select a station.
Confirm audible playback first. Fetch `/api/nowplaying`; expect `active:true`,
source `radio`, the selected station, and first `buffering`, then `playing` after
the stream response is accepted. Open the stock Logitech Now Playing screen
through its normal Home/menu entry and verify station and playing state. The
applet should open that native screen automatically, and its menu no longer
contains a custom Now Playing item.

### Native navigation regression

1. Return to Home and short-press preset 1. Confirm the original Logitech Now
   Playing screen opens.
2. While it remains visible, press preset 2. Confirm the station changes without
   flicker or a duplicate window.
3. Return to Home and wait for ICY metadata and artwork changes. Confirm Home
   remains visible.
4. Press preset 3 and confirm native Now Playing opens again.
5. Long-press a preset and verify assignment behavior without playback or
   navigation.
6. Open a Standalone Radio/Radio Browser/custom station list, select a station,
   and confirm the same native screen opens.
7. Leave native Now Playing, interrupt the stream briefly, and verify automatic
   reconnect does not steal focus.
8. Press presets 1, 2, and 3 rapidly. Confirm only preset 3 plays and there is a
   single native Now Playing window.

## 2. ICY metadata

Choose a known ICY station. Record `generation` and `track.id`, then wait for two
songs. Verify artist/title changes in the native screen while generation and
station ID remain constant. There must be no duration/seek presentation and no
old song from a previously selected station.

Observe `/api/nowplaying` immediately after a title change. It should first
contain the station logo in `track.artwork`, then change to the discovered album
cover when available. HTTPS sources must use the local
`http://127.0.0.1:8765/https/...` form. Select a title with no lookup result and
verify the station logo remains. Also test a station without a favicon; it must
publish empty artwork rather than the preceding station's image.

## 3. Switch stations

While station A plays with native Now Playing visible, select preset B. Verify
that the native screen remains on top, the custom screen does not appear, B's
ID/name replaces A immediately, A metadata is cleared until B supplies its own,
and no late A data returns. Repeat rapidly with A→B→C. The API session generation
should normally remain unchanged.

## 4. Stream reconnection

Briefly interrupt only stream connectivity, then restore it. Confirm the
existing reconnect behavior, `buffering` during recovery, `playing` after the
new response, stable session generation, and no repeated claims.

## 5. Intentional stop/cancel

Stop active radio playback, and separately cancel a pending connection with the
Back behavior. Expect a final stopped update, then `active:false`; heartbeat
traffic must cease. Navigating away from native Now Playing while audio is active
must not release the session or stop audio.

## 6. Restart StandaloneBase

Keep radio audio playing and restart only StandaloneBase. Audio must continue.
The next update/heartbeat should lose its old token, observe an inactive v1 API,
claim a new generation, and republish current station/state/metadata. Check that
only the metadata service recovers; the audio stream must not restart. The
current cover or station-logo fallback must be present in the reclaimed full
snapshot.

## 7. API unavailable and takeover

Start the applet with StandaloneBase stopped or an older build. Confirm normal
audio, no popups, and bounded warnings (2, 5, 10,
then about 30 seconds). Start Phase 2 and verify eventual publication.

For takeover testing, claim another source through an approved PC-side client
while radio plays. The next radio call should get 409; verify the other source
remains active and Radio does not repeatedly reclaim. Selecting a radio station
again is an explicit takeover and may claim.

## 8. Thirty-minute reliability run

Run a metadata-producing station for at least 30 minutes. Observe CPU, memory,
audio underruns, request rate, stable generation, one heartbeat about every 45
seconds when otherwise idle, CometD stability, and absence of recurring
“Connecting to Standalone Base”. Save firmware/build versions, package hashes,
timestamps, API snapshots, logs, and screenshots.

## Pass boundary

Host mocks prove client logic only. Hardware validation requires audible radio
to continue while the original Logitech Now Playing screen shows the real
station, at least two changing ICY titles, and the corresponding cover/logo
fallback. Controls, automatic native-screen activation, seek, and volume are
explicitly outside this test.
