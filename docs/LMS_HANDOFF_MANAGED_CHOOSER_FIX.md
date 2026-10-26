# Explicit LMS switching: managed chooser and isolated module fix

The 0.9.15 handoff integration had two defects:

- `StreamPlayer.lua` used `require` inside `module(...)` without capturing it
  before entering Jive's isolated Lua 5.1 environment. The attempted chooser
  import could fail, leaving the decoder ownership guard enabled without the
  explicit-switch release hook.
- Patching a module returned by `require` did not reliably patch the managed
  applet. `AppletManager:_loadApplet` uses `loadfile`; freeing and reopening an
  applet can replace its methods and clear `package.loaded`.

The fix captures `require` and `appletManager` before `module(...)`. A bounded
wrapper around the existing managed `loadApplet` patches ChooseMusicSource
after each load, including newly created/reloaded instances. It is idempotent
for cached instances and passes unrelated applets and loader return values
through unchanged. It chains existing loader adapters, including Base's
installer compatibility wrapper.

Ownership still releases only for the local playback object's explicit chooser
transition to an external LMS, or selection of the already-connected external
library. Simply opening a chooser, transport reconnects and HELO do not release
ownership. Background incoming gain/decoder commands remain isolated until an
intentional handoff. Stock source authentication/compatibility checks remain.

The 192.168.1.228 logs showed repeated ChooseMusicSource connection timeouts
to DESKTOP-OVMHVD2 at 192.168.1.100 without the expected handoff log. The laptop
HTTP interface was reachable and both HTTP 9000 and SlimProto 3483 listeners
were present. This identifies an application defect; it does not prove that
every network/firewall path will always succeed.

Validation: all 21 Radio Lua suites pass. Added regression coverage executes
the actual imports and hooks with an isolated Lua 5.1 module environment,
different require/managed applet objects, method replacement, repeated cached
loads, full free/recreate, and explicit switching after reopening. Existing
background reconnect and gain-isolation scenarios still pass.

Device deployment is limited to StreamPlayer.lua, with an off-device original
and on-device rollback copy. No Base binary, firmware, storage initialization,
watchdog settings or unrelated pending Radio edits are changed. Physical LMS
selection must be retested after the UI reload; host simulation alone is not
audible or firmware-specific physical validation.

## Follow-up: wrong selected player

The next failed attempt logged `No method to connect Player
{00:04:20:2a:56:81}`. Read-only sysfs inspection identified the physical .228
Radio as `00:04:20:29:16:7f`. The former is a generic remembered player with no
server connection; the chooser was acting on it rather than the LocalPlayer
whose decoder Radio owns. The ownership hook correctly did not stop another
player's decoder, but the selection mismatch prevented the desired local switch.

On explicit station starts, `_begin` now selects the same LocalPlayer on which
it starts the stream. It does not change selection during background reconnects,
reselect an already-current player, or change selection when no valid decoder is
available. This repairs the UI/control identity at playback start instead of
silently redirecting arbitrary commands intended for other connected players.
All 22 Radio suites pass, including a fixture with the exact orphan/local player
distinction. A fresh station selection is required before retrying the library
switch on an already-running session.

## Release integration

The approved fixes are included in Standalone Radio 0.9.18 with the storage
and station-logo changes from 0.9.17. The complete Radio package is deployed;
all 23 Lua suites pass. Base code remains unchanged by this release, and its
Radio catalog reference is updated separately.
