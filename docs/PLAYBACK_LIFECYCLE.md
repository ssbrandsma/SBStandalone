# Playback ownership and standby

Global Play/Pause/Stop actions belong to Standalone Radio only while it owns
playback. Otherwise they pass through to the selected source. Unassigned preset
buttons and non-owner preset assignment also pass through; selecting an assigned
Radio preset remains an explicit request to start Radio.

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
local and its server UUID matches Standalone Base. Awake non-owner Play and
external-server Play pass through. Base's identity module is optional: its absence
does not prevent Radio from loading and does not enable non-owner standby resume.
The last selected station is saved even when it has no hardware preset, with
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

On 2026-11-06 a local Touch trial of these lifecycle changes confirmed physical
remote **playing -> Power -> clock -> Play** resumes audio. After the power-off
correction, a six-minute standby check sampled state every thirty seconds and
remained stopped/inactive across the five-minute keepalive boundary. Explicit
web-remote Play resumed playback and Power stopped it again. The standby cycle
used web actions through the same patched LocalPlayer power method; it was not
an acoustic or overnight soak. The optional-Base import guard and isolated PR
assembly have host regression coverage but were not redeployed for this PR.
Baby hardware and complete external-LMS coexistence remain to be checked.
