# Standalone Radio Research

Date: 2026-08-31
Device firmware: Logitech Squeezebox Radio `baby`, 7.7.3 r16676

## Key findings from the device

1. `Playback` is instantiated in `/usr/share/jive/jive/slim/LocalPlayer.lua:90` as `obj.playback = Playback(jnt, obj.slimproto)`.
2. The retained reference lives on the `LocalPlayer` instance as the public field `playback`.
3. Applets can already reach the local player through `jive.slim.Player:getLocalPlayer()` in `/usr/share/jive/jive/slim/Player.lua:159`, and several stock applets also locate it through `appletManager:callService("iteratePlayers")`.
4. There is no existing `Playback` singleton/current accessor in `/usr/share/jive/jive/audio/Playback.lua`; the only public extension hook is `registerHandler()` at line 1287.
5. `spdr://` handlers are only invoked inside `Playback:_strm()` in `/usr/share/jive/jive/audio/Playback.lua:852-970`, after a SlimProto `strm` command has already been received. That makes `spdr://` unsuitable as the initial standalone entry point without LMS or another local caller that fabricates `strm` packets.
6. `_streamConnect()` is a normal instance method in `/usr/share/jive/jive/audio/Playback.lua:475`. It writes `self.header` in `_streamWrite()` at line 792 and starts the stock stream reader/writer tasks. This looks reusable from an applet if the applet sets the same state that `_strm()` normally sets.
7. Normal network playback state is established by `_strm('s')` in `/usr/share/jive/jive/audio/Playback.lua:852-970`:
   - copies `data.flags`, `data.mode`, `data.header`, `data.autostart`, and `data.threshold`
   - resets local resume/underrun flags
   - calls `decode:start(...)`
   - then calls `_streamConnect(...)`
8. The decoder resume state machine is timer-driven in `/usr/share/jive/jive/audio/Playback.lua:260-390`.
   - `decode:resumeDecoder()` happens when `decodeFull > self.decodeThreshold`, autostart is enabled, decoder is not running, and `sentResumeDecoder` is false.
   - `decode:resumeAudio()` happens later when track/output thresholds are met and `autostart == '1'`.
9. The cleanest stop path is `stopInternal()` in `/usr/share/jive/jive/audio/Playback.lua:1007-1018` because it calls `decode:stop()`, `_streamDisconnect(nil, true)`, `_proxyCleanup()`, and resets `tracksStarted`.
10. Based on the above, the least invasive first implementation is Option B: an applet that uses `Player:getLocalPlayer().playback` directly, without patching `Playback.lua`.

## Extra observations

- The live device already contains `/usr/share/jive/jive/audio/Playback.lua.backup`, so the box may have been edited previously. Treat stock assumptions carefully.
- `Playback:stop()` at `/usr/share/jive/jive/audio/Playback.lua:140-145` stops the timer, so it is not appropriate for ordinary station stop/start control. `stopInternal()` is the safer reusable runtime stop.
- `jive.net.DNS` in `/usr/share/jive/jive/net/DNS.lua` provides non-blocking `toip()` and must be called from a `Task`.
- Stock `TestTones` applet (`/usr/share/jive/applets/TestTones/TestTonesApplet.lua`) demonstrates direct local-player usage and confirms applets can interact with local audio logic without LMS.

## Milestone 4 input and DNS findings

- `/usr/share/jive/jive/InputToActionMap.lua` maps the six physical preset buttons to `play_preset_1` through `play_preset_6`, Play to `play`, and Pause press/hold to `pause`/`stop`.
- `LineInApplet.lua` is the stock reference for scoped transport overrides: it registers `Framework:addActionListener(...)`, returns `EVENT_CONSUME`, and removes the listener handles when inactive.
- `Framework:addListener` treats negative priorities as pre-widget listeners; positive priorities run only after widgets leave the event unused. Standalone Radio must therefore use a negative priority to reliably consume hardware actions.
- The applet metadata preloads Standalone Radio and enables its controls during registration, so `play_preset_1` through `play_preset_6` work immediately after boot. The applet menu makes this state visible.
- On the offline Home layout shown on the device, the `music` node is unavailable. The Standalone Radio menu item belongs on the `home` node instead.
- BusyBox `nslookup` prints the configured DNS server before the answer. The resolver must parse an IPv4 address only after `Name:`; otherwise it can incorrectly connect to the local router instead of the stream host.
- SqueezePlay applet `strings.txt` files are token blocks with language rows, not colon-delimited key/value pairs.
- The locale API accepts only primitive formatting arguments. Status text must stringify nested localized station names before formatting; otherwise it raises a task error before `_streamConnect` executes.
- Localized values are locale objects. Convert them with `tostring` before concatenating menu labels with ordinary Lua strings.
- The firmware's `jive.net.DNS` resolver returned `Try again` from an applet, but `/usr/bin/nslookup` (BusyBox 1.18.2) correctly resolved `icecast.omroep.nl` using the DHCP-provided resolver in `/etc/resolv.conf`. The first working proof of concept therefore used `jive.net.Process` to run `nslookup` asynchronously and parsed its first IPv4 result, avoiding hardcoded IP addresses.
- On-device two-second `wget` reads confirmed that the configured HTTP MP3 endpoints for NPO Radio 1, Radio 538, Radio 10, Radio Veronica, and BNR all returned audio data on 2026-08-31.

## Milestone 5 Now Playing and metadata findings

- The stock Line-In applet is the suitable local UI reference: it uses `Window("linein")`, `Group("title")`, `Group("npartwork")`, `Group("nptitle")`, `Icon`, and mutable `Label` widgets without requiring LMS state.
- The native `/usr/bin/jive` binary contains `streambuf_icy_filter` and emits a `META` packet for ICY metadata. `Playback:_cont()` already configures the filter through `Stream:icyMetaInterval(...)` when LMS supplies an interval.
- The applet can preserve the working `_streamConnect()` path by requesting `Icy-MetaData: 1`, parsing `icy-metaint` from the stock `_streamHttpHeaders` callback, and configuring `Stream:icyMetaInterval(...)`. No custom socket reader or `Playback.lua` change is required.
- Header probes on 2026-09-01 found `icy-metaint: 16000` on Radio 538, Radio 10, and Radio Veronica. NPO Radio 1 and NPO Radio 2 did not advertise an ICY metadata interval.
- The applet wraps only its local `Playback` instance's `_streamHttpHeaders()` method to extract `icy-metaint`, calls the native `Stream:icyMetaInterval()` filter, and observes native `META` packets from that instance's `slimproto:send()` path. The stock filter removes the interleaved metadata before MP3 decoding; the applet safely extracts and displays `StreamTitle` without replacing the working stream reader.
- The Now Playing UI follows the stock Line-In layout: `Window("linein")`, `Group("title")`, `Group("npartwork")`, `Group("nptitle")`, `Icon`, and mutable `Label` widgets. Back uses the stock default left button, so it returns normally without stopping audio or disabling display power management.
- Six local PNG logos are stored in `applet/StandaloneRadio/images/`, constrained to a maximum of 180 by 110 pixels. They are loaded with `Surface:loadImage()` and cached per station; the radio never downloads artwork at runtime.

## Forum feedback DNS follow-up

- Michael Herger pointed out on the Lyrion forum thread that launching `nslookup` instead of using non-blocking DNS was a proof-of-concept shortcut rather than idiomatic SqueezePlay code.
- The resolver is isolated in `Resolver.lua`. Live v0.2 testing showed `jive.net.DNS` could fail or raise coroutine boundary warnings from this applet context, while BusyBox `nslookup` resolved reliably. The current resolver validates hostnames and uses asynchronous BusyBox `nslookup` directly.
- The `nslookup` fallback keeps the previous answer-section parsing rule: parse IPv4 addresses only after `Name:` so the configured DNS server address is not mistaken for the station endpoint.

## Long-running stream stability follow-up

- Reports after longer playback showed internet radio sometimes stops after roughly 20 to 60 minutes and resumes when a preset is pressed again.
- Live log inspection was not possible from the development PC at the time because SSH authentication was unavailable in the shell, but the code had two plausible weak spots: the HTTP request explicitly sent `Connection: close`, and automatic recovery depended on `_streamDisconnect()` receiving a useful disconnect callback.
- The stream request no longer asks the server to close the connection. A retained repeating watchdog now checks the active playback stream every 30 seconds and schedules the existing reconnect path if the stream disappears or byte progress stalls for two consecutive checks.

## v0.2 Radio Browser and preset findings

- Radio Browser's documented advanced search endpoint supports the v0.2 filter shape: `/json/stations/search?countrycode=NL&codec=MP3&is_https=false&hidebroken=true&order=clickcount&reverse=true&limit=175`.
- The Radio Browser station model includes `url_resolved`, `codec`, `lastcheckok`, `hls`, `favicon`, `bitrate`, `countrycode`, and `stationuuid`. The applet retains only the fields needed for playback and future preset refresh.
- On-device `wget` confirmed that `http://all.api.radio-browser.info/json/stations/search?...limit=5` returns Dutch MP3 station JSON over plain HTTP. One direct mirror request timed out mid-transfer during testing, so v0.2 uses `all.api.radio-browser.info`, a small limit, and graceful failure handling.
- Stock SqueezePlay firmware provides `jive.net.SocketHttp` and `jive.net.RequestHttp` for asynchronous HTTP requests, and a `json` module used by `jive.utils.jsonfilters`; these are used instead of shelling out for the directory.
- `/usr/share/jive/jive/InputToActionMap.lua` maps preset key press actions to `play_preset_1` through `play_preset_6` and preset key hold actions to `set_preset_1` through `set_preset_6`. v0.2 uses those native hold actions for assignment.
- `PresetStore.lua` initializes applet settings with the original six presets if no saved preset table exists, then persists full station objects for user assignments. Saved preset playback does not call Radio Browser.

## v0.2.x dynamic artwork findings

- Runtime-downloaded artwork is cached under `/etc/squeezeplay/userpath/StandaloneRadio/cache/logos`, which maps through the union filesystem to persistent UBIFS storage under `/mnt/storage/etc/squeezeplay/userpath/StandaloneRadio/cache/logos`.
- The cache key is Radio Browser `stationuuid`, sanitized to alphanumeric and dash characters, with `.png` or `.jpg` chosen from the downloaded file's magic bytes. Station names and preset numbers are not used for cache filenames.
- Stock firmware has `libpng` and `libjpeg`, and stock ImageViewer loads absolute local image paths with `Surface:loadImage(file)`. StandaloneRadio therefore supports cached PNG/JPEG files and relies on the skin to scale them in the existing `Icon` widget.
- BusyBox `wget` on firmware 7.7.3 supports HTTP and FTP only; it rejects HTTPS URLs with `not an http or ftp url`. HTTPS, SVG, ICO, empty, oversized, and corrupt favicons fall back to the packaged `images/radio.png` generic logo.
- `LogoCache.lua` downloads favicons asynchronously through `jive.net.Process` after playback has started. Downloads are capped at roughly 512 KB and the cache is pruned to the newest 100 logo files with a simple oldest-file removal strategy.
- `NowPlaying.lua` now selects artwork from the station object in this order: cached `logoPath`, packaged built-in `logo`, then generic fallback. This removes any conceptual link between preset number and artwork.

## Decision for milestone 2/3

Proceed with a new standalone applet under `/usr/share/jive/applets/StandaloneRadio/` that:

- adds a `Standalone Radio` menu entry
- resolves hostnames with SqueezePlay's non-blocking `jive.net.DNS` resolver, falling back to BusyBox `nslookup` through `jive.net.Process`
- uses the existing local player's `playback` instance
- starts MP3 decode with the stock decoder signature
- calls `_streamConnect()` with a plain HTTP/1.0 request in `self.header`
- uses `stopInternal()` for Stop and before switching stations
- preloads physical preset and transport action listeners at boot

This approach was verified on the live device with all six presets and menu-selected stations working. `Playback.lua` remains unmodified.
