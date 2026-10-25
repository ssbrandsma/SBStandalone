# Standalone Radio 0.9.15: ownership and LMS reconnect regression

## Confirmed causes

1. `StreamPlayer:_installHooks`, previously lines 658–672, intercepted outgoing
   HELO and called `stop()` whenever its destination was not loopback. That stops
   the decoder, cancels reconnect/metadata work and calls `onHandoff`, releasing
   the Base Now Playing claim. HELO also occurs on automatic reconnect, before
   LMS has accepted a connection. Even an unreachable remembered LMS could stop
   Radio. IP address and reachability are not evidence of user intent.
2. Playback subscribes to `audg` with a callback invoking `obj:_audg(data)`.
   Radio only filtered outgoing packets, not incoming gain/decoder commands.
   Stock `_audg` calls `decode:audioGain`; therefore a stale server session could
   change the same decoder gain. Incoming `strm`, `cont` and `aude` could also
   stop, replace or reconfigure the independent stream.
3. Base `np_playerstatus_json` emitted numeric `playlist repeat` and `playlist
   shuffle` for an active playlist but omitted them in its stopped/inactive
   branch. Stock NowPlaying `_updateShuffle`/`_updateRepeat` concatenate these
   values with `mode`. The reported nil is a repeat/shuffle mode, not necessarily
   the playback `mode` field. Unexpected handoff exposes the incomplete empty
   status, but an initially empty local playlist can expose it independently.

These mechanisms are confirmed in source and host simulation. The user's exact
six-second delay and physical firmware 7.7.3 reproduction have not been measured.
The reported SocketTcp write timeouts indicate connection trouble; this fix
does not claim to diagnose the underlying network/server failure.

## Source and integration review

The inspected local upstream checkout is commit
`9bad3c1f55f45575d985c37d73c4f1513c5a64d7`:

- `jive/net/SlimProto.lua`: `connectTask`, `_connect`, `_handleTimer` perform
  automatic retries and send HELO; incoming commands mark the transport connected.
- `jive/slim/LocalPlayer.lua`: `updateInit` calls `connectToServer` automatically;
  `connectIp` is a transport operation, not reliable intent. `volumeLocal` reaches
  Playback `setVolume`, whose `_audg(data, true)` identifies a local gain change.
- `applets/ChooseMusicSource/ChooseMusicSourceApplet.lua`: `selectServer` performs
  authentication/compatibility/confirmation checks; `_doConnectPlayer` commits
  the selected transition and invokes `player:connectToServer(server)`.
- `jive/audio/Playback.lua`: dynamic subscriptions for `_audg`, `_strm`, `_cont`
  and `_aude`; `_reconnect` resends status rather than selecting a library.
- `applets/NowPlaying/NowPlayingApplet.lua`: `_updateShuffle`/`_updateRepeat`
  consume the corresponding player status keys, including on opening the screen.

Public source: [LocalPlayer](https://github.com/ralph-irving/squeezeplay/blob/master/src/squeezeplay/share/jive/slim/LocalPlayer.lua),
[SlimProto](https://github.com/ralph-irving/squeezeplay/blob/master/src/squeezeplay/share/jive/net/SlimProto.lua),
[ChooseMusicSource](https://github.com/ralph-irving/squeezeplay/blob/master/src/squeezeplay/share/applets/ChooseMusicSource/ChooseMusicSourceApplet.lua).
Line numbers differ between upstream and firmware builds. Saved installed Jive
Playback and NowPlaying sources were also inspected; these are not proof that
every vendor firmware build has identical internals.

## Implemented policy

- Always pass HELO and transport reconnects through; never release for them.
- Wrap the chooser's committed `_doConnectPlayer` integration point at runtime.
  Verify the exact local playback object, a valid target and non-loopback address.
  This is an explicit selection plus object identity check, not an IP-only rule.
- Cover the chooser's already-connected `selectServer` early return as well,
  while retaining password/compatibility checks. Another player's selection and
  selection of local Base do not release Radio.
- Stop once and clear the desired stream before releasing the claim. Existing
  generation/cancellation mechanisms invalidate delayed stream callbacks.
- While Radio owns the decoder, ignore wire `_audg` and incoming `_strm`, `_cont`,
  `_aude`. Physical/controller `setVolume` calls still pass through `_audg(...,
  true)`. Base virtual controls use the same local action path.
- Original handlers are retained and automatically pass through when ownership
  is released. No stock Lua files are edited; no new timer, polling or transport
  disconnection is introduced. Overhead is a bounded set of closures and guards.
- Base's empty player status now includes numeric zero repeat/shuffle fields.
  These match its existing fixed-off radio semantics, not invented toggle support.

An explicit switch intentionally stops local audio even if that chosen LMS later
fails to connect. No timed auto-resume is introduced. Starting Radio again restores
local ownership and isolation. Raw remote `serv`/`strm` commands alone are not
authorized takeover: a caller must use the source-selection workflow. Firmware
without the known chooser method logs a warning and retains ownership rather
than falling back to unsafe HELO-based release.

## Validation

- `python test/handoff-baseline.py`: the same regression fails on pinned 0.9.14
  and passes on the fixed worktree.
- `python test/run-tests.py`: 20 Radio Lua suites pass, including 38 virtual
  13-second reconnect cycles, unchanged ownership/generation/stream, gain and
  decoder isolation, loopback/unrelated-player selection, genuine handoff,
  repeated selection, restored LMS commands and restarting Radio.
- `python test/jive-volume-contract.py PATH/TO/Playback.lua`: passes with both
  the upstream and saved installed gain handlers. This executes the actual stock
  gain function behind Radio's actual hook, not just a replacement gain mock.
- Base's C tests cover buffering, playing, paused, stopped, released and expired
  status with numeric repeat/shuffle values. The full suite and ARM build results
  passed: 49/49 tests in 150.59 seconds and the static ARMv5 build. Existing image
  scratch-path and third-party NanoSVG signedness warnings remain unchanged.
- No live Radio deployment, playback interruption, firmware/storage operation or
  watchdog change was performed. Exact firmware 7.7.3 hardware coverage remains
  required; source contract compatibility is not physical validation.

## Forum changelog

Standalone Radio no longer stops when a remembered LMS reconnects in the
background. Old LMS sessions cannot overwrite local volume or interfere with the
radio stream. Choosing an LMS library still hands playback over normally.
The companion Standalone Base fix supplies the missing stopped-state values
needed by stock Now Playing, preventing repeat/shuffle nil-mode errors.

## Release assessment

Background HELO/reconnects and stale wire gain/decoder commands no longer take
ownership in the tested paths. Intentional library switching still works in
simulation. The local stopped-status defect is fixed at its source; malformed
responses from a separate external LMS cannot be repaired by this change.
Radio is versioned 0.9.15 in preparation, not published. Ship the Base status fix
alongside Radio; Radio alone cannot correct an older Base binary. Host validation
is not a substitute for bounded 7.7.3 and 9.x library-switch/audio tests before
calling the release physically verified.
