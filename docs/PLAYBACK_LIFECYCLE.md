# Playback ownership and standby

Global Pause/Stop actions belong to Standalone Radio only while it owns
playback. Play can also resume an explicitly stopped Radio on the selected
local Standalone Base player. Otherwise actions pass through to the selected
source. Unassigned preset buttons and non-owner preset assignment also pass
through; selecting an assigned Radio preset remains an explicit request to
start Radio.

## Power off and resume

The Touch's stock `LocalPlayer:setPower(false)` pauses the native decoder without
stopping Radio's independently managed stream. Underrun recovery, the watchdog,
or the five-minute keepalive can subsequently revive audio behind the clock.
Radio now stops its stream before forwarding the native power transition with
the original arguments. Stop invalidates the callback generation and clears
station intent before cancellation, preventing synchronous cancellation callbacks
and queued retries from restarting playback. The remembered station is retained;
power on alone does not start it.

Play from standby may resume a remembered station when the selected player is
local and its server UUID matches Standalone Base. While awake, Play may resume
only after Radio was stopped (including live-radio Pause or power off). An
explicit external-library selection or another native stream start revokes that
permission, even if Radio was already stopped. Keepalive traffic does not revoke
it. A remembered station by itself does not capture awake non-owner Play;
external-server Play still passes through. Base's identity module is optional:
its absence does not prevent Radio from loading and does not enable non-owner
resume. The last selected station is saved even when it has no hardware preset, with
fallback to the existing `lastPreset` setting. Provider stations retain their
resolver URL rather than a temporary stream URL.

The global Play action runs before ScreenSavers regardless of applet load order.
The Touch clock also converts short infrared Play synchronously inside its window
and translates it into Pause without emitting a global Play action. A listener
before that window sends only standby `EVENT_IR_PRESS` mapped to Play through the
same guarded handler. Awake input, other buttons, and held Play pass through.

## Validation

Run `python test/run-tests.py --socket-url /path/to/socket/url.lua` with Lupa.
The runner uses Lua 5.4 for the standby fixture because the extracted firmware
callback code includes Jive's bitwise syntax, as in the podcast fixture. The
ownership and persistence fixtures run under Lua 5.1.

The standby regression exercises power argument forwarding, non-stacking hooks,
underrun/watchdog/keepalive ticks, queued retries, cancellation callbacks, late
headers/disconnects, and explicit Play. Control fixtures cover listener ordering,
physical infrared routing, source guards, missing Base, and preset behavior.
The stopped-playback fixture runs the registered action handlers with the real
Stop/Pause/Play methods and source hooks. It covers awake Stop/Pause -> Play,
in-place podcast resume, stopped-source handoff, new native playback on the same
Base, and missing/remote player guards. It fails on the prior PR revision at
the awake Stop -> Play assertion. All 27 Lua suites pass with this correction.

On 2026-11-06 a local Touch trial of these lifecycle changes confirmed physical
remote **playing -> Power -> clock -> Play** resumes audio. After the power-off
correction, a six-minute standby check sampled state every thirty seconds and
remained stopped/inactive across the five-minute keepalive boundary. Explicit
web-remote Play resumed playback and Power stopped it again. The standby cycle
used web actions through the same patched LocalPlayer power method; it was not
an acoustic or overnight soak. The optional-Base import guard and isolated PR
assembly have host regression coverage but were not redeployed for this PR.
Baby hardware and complete external-LMS coexistence remain to be checked.
The awake Stop/Pause -> Play correction has host regression coverage and has
not been deployed to the Touch for hardware validation.

## Integration with standby recovery and opt-in ownership

The power-off hook is backed by soft-power checks in recovery ticks, stream
starts and asynchronous callback guards. These retain the last station while
clearing pending playback intent; waking the UI alone cannot start audio.

When playback ownership is explicitly enabled, the local player's power hook
is recorded with the stream hooks and restored during ownership release.
Retired power callbacks forward native power arguments without stopping a new
owner's playback. The combined standby fixture covers restoration, reinstallation
and callbacks after epoch changes or revocation. Ownership remains opt-in and
requires Standalone Base's OwnershipRuntime, OwnershipBinding and OwnershipHooks
modules; ordinary startup does not load or enable that integration.

## Local Base synchronization after a SqueezePlay restart

Base can outlive SqueezePlay and retain a higher player sequence number than
its restarted local controller. Stock Jive responds to each mismatched status
snapshot by sending volume followed by power with a new sequence. Intermediate
snapshots can trigger the same refresh again, filling its Comet request queue.

Radio installs its compatibility hooks when the local player becomes available
on the watchdog tick, even before the first station starts. Only for Standalone
Base's UUID on a loopback address, a refresh rebases an older firmware counter
to the advertised Base sequence and briefly coalesces unchanged refreshes.
Volume, power and sequence changes pass immediately; unchanged refreshes may
retry after two seconds. External LMS synchronization remains native. The
refresh hook participates in opt-in ownership restoration.

The local-parameter-sync fixture covers feedback convergence, counter reset,
state changes, retry timing, external-server passthrough and hook recording.
