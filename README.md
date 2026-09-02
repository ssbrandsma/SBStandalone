# Squeezebox Standalone Radio

Bring a Logitech Squeezebox Radio back to life as a self-contained internet radio. This project installs one native SqueezePlay applet on the radio itself: no Logitech Media Server (LMS), mysqueezebox.com account, or always-on computer is required after installation.

The applet is designed for the stock Squeezebox Radio firmware and uses the radio's existing audio playback engine. It adds files only under `/usr/share/jive/applets/StandaloneRadio/`; it does not replace or edit `Playback.lua` or other stock SqueezePlay files.

## What It Does

- Starts one of six internet stations with the physical preset buttons, even from the Home screen.
- Provides a `Standalone Radio` Home menu for selecting stations on-screen.
- Shows a native-style Now Playing screen with the station name, local logo, connection state, and available song title metadata.
- Uses the radio's configured network DNS server. No station IP addresses are hardcoded.
- Treats Pause and Stop as Stop for live radio. Play restarts the last selected station.

The included presets are NPO Radio 1, NPO Radio 2, Radio 538, Radio 10, Radio Veronica, and BNR Nieuwsradio. They can be changed in the centralized `stations` table in [StandaloneRadioApplet.lua](applet/StandaloneRadio/StandaloneRadioApplet.lua).

## Requirements

- A Logitech Squeezebox Radio running stock SqueezePlay firmware. This has been tested on firmware `7.7.3 r16676` (`baby`). Other SqueezePlay-based players may work, but are not yet verified.
- The radio connected to your network and reachable by IP address.
- Root SSH access to the radio. This project uses the radio's legacy Dropbear SSH service.
- A Windows machine with PowerShell and the OpenSSH `ssh` and `scp` clients available. Windows 10/11 normally include them.
- Internet access for the radio streams.

This project does not flash firmware or enable SSH for you. If SSH is not already available on your radio, enable it using the method appropriate for your firmware before proceeding.

## Install

1. Clone or download this project onto the Windows machine.
2. Find the radio's IP address in your router's DHCP client list, then confirm it is reachable:

```powershell
Test-Connection -ComputerName <radio-ip> -Count 1
```

3. Open PowerShell in the project directory and set the root SSH password only for the current shell session:

```powershell
$env:SQUEEZEBOX_SSH_PASSWORD = '<radio root password>'
```

4. Deploy the applet. Replace `<radio-ip>` with the address from step 2:

```powershell
.\scripts\deploy.ps1 -HostName <radio-ip>
```

The script creates `/usr/share/jive/applets/StandaloneRadio/`, copies the applet and local artwork, then restarts SqueezePlay. The screen can take a minute or two to recover after the restart while it reconnects to Wi-Fi.

5. When the Home screen returns, select `Standalone Radio` or press preset `1`. Audio should begin shortly after the `Resolving...` and `Connecting...` states.

The password is provided only to the temporary SSH askpass helper through the process environment. It is not saved in the repository or written to the radio.

## Install Using Applet Installer

Applet Installer is an alternative to SSH deployment. It uses LMS only to discover and install the applet; Standalone Radio does not need LMS or mysqueezebox.com after it has been installed and SqueezePlay has restarted.

1. Build and publish the package as described in [Build And Publish](#build-and-publish).
2. Connect the Radio to Wi-Fi.
3. On the Radio, go to `Settings -> Advanced -> Networking -> Remote Libraries -> Add New Library` and enter the installer LMS hostname or IP address.
4. Connect the Radio to that LMS.
5. In the LMS web interface, open `Settings -> Manage Plugins`.
6. Add `http://49.12.198.91/sbstandalone/extensions.xml` under `Additional Repositories`, then apply the change. Replace the address if you built with a different `-BaseUrl`.
7. Restart LMS if its plugin page asks for it.
8. On the Radio, open `Settings -> Advanced -> Applet Installer`.
9. Select `Standalone Radio`, then select `Install`.
10. Let the Radio restart SqueezePlay, then open `Standalone Radio` from the Home menu and play a station.

Applet Installer on stock Radio firmware can remove an installed repository applet: open `Settings -> Advanced -> Applet Installer`, select `Standalone Radio`, and select `Remove`. It deletes only `/usr/share/jive/applets/StandaloneRadio/`. The next Applet Installer refresh must still be able to see the repository entry for the installed version; otherwise its non-repository listing also offers `Remove`.

### Build And Publish

`VERSION` is the single authoritative applet version. Increase it before a release, then build the installer artifacts:

```powershell
.\scripts\build-applet-package.ps1 -BaseUrl 'http://49.12.198.91/sbstandalone'
```

The build creates ignored files in `dist/`:

- `StandaloneRadio-<version>.zip`: the package downloaded by the Radio.
- `extensions.xml`: repository metadata for LMS.

The ZIP contains runtime files directly at archive root, plus `images/`. It intentionally does not contain an enclosing `StandaloneRadio/` folder, source-control files, development scripts, backups, or documentation. The build validates this layout, parses the generated XML, checks the version, and calculates the SHA-1 included in the XML.

Publish both generated files into one static web directory, for example `/var/www/sbstandalone/` on the VPS. The directory must make these URLs externally reachable:

```text
http://49.12.198.91/sbstandalone/extensions.xml
http://49.12.198.91/sbstandalone/StandaloneRadio-<version>.zip
```

The default repository URL deliberately uses HTTP and the server IP address. The stock 7.7.3 Radio's old HTTP stack and BusyBox tools have limited TLS support, and its DNS resolution can be unreliable, so HTTPS or a hostname must be tested on the actual Radio before being used for installation. HTTP allows a network attacker to replace the applet download in transit; SHA-1 detects accidental corruption but is not a modern security guarantee. Use a tested HTTPS hostname with `-BaseUrl` only after the target firmware is proven to download it reliably.

The build never publishes files or stores VPS credentials. Copy the two generated files to the web server using the deployment method already configured for that server. A versioned ZIP filename is required to avoid LMS and proxy caches serving an earlier artifact.

## Everyday Use

| Control | Action |
| --- | --- |
| `1` | NPO Radio 1 |
| `2` | NPO Radio 2 |
| `3` | Radio 538 |
| `4` | Radio 10 |
| `5` | Radio Veronica |
| `6` | BNR Nieuwsradio |
| Pause or Stop | Stop the live stream |
| Play | Restart the last selected station |
| Back, from Now Playing | Return to the station menu while playback continues |

Preset and transport handling is enabled when SqueezePlay starts, so the six station buttons work without first opening the applet menu. Volume remains the normal stock volume control.

## Radio Browser

The `Radio Browser` menu opens a dynamic station directory using the public Radio Browser API. Version 0.2 deliberately shows a conservative list of popular Dutch stations: HTTP streams, MP3 codec, reported working, and limited to a small result set so the Radio is not asked to hold a large database in memory.

Browsing Radio Browser requires internet access at the time you open that menu. Saved presets do not: once a station is assigned to a preset, the station name and stream URL are stored locally and can be played without contacting Radio Browser again.

## Station Artwork

Radio Browser stations may provide artwork through their `favicon` field. StandaloneRadio downloads supported artwork asynchronously after playback has already started, stores it locally on the Radio, and uses the cached artwork later for saved presets.

On stock 7.7.3 firmware, runtime artwork download is intentionally conservative: HTTP PNG and JPEG images are supported, oversized files are rejected, and unsupported or unreachable artwork falls back to the packaged generic radio icon. Many Radio Browser favicons are HTTPS or SVG/ICO, and those may show the fallback because the stock BusyBox `wget` cannot fetch HTTPS.

## Assigning Presets

To replace a preset:

1. Open `Standalone Radio`.
2. Open `Radio Browser`.
3. Select and play a station.
4. Press and hold preset button `1`-`6`.
5. Short-press that preset later to play the saved station.

Preset assignments survive reboot. Existing installations are migrated to the original six defaults until you replace them: NPO Radio 1, NPO Radio 2, Radio 538, Radio 10, Radio Veronica, and BNR Nieuwsradio.

## Now Playing And Metadata

Selecting a station opens Now Playing immediately. It keeps the station logo and name visible and displays one of these statuses: `Resolving...`, `Connecting...`, `Playing`, `Stopped`, or `Connection failed`.

The applet requests ICY metadata only through the stock stream engine. When a stream provides it, its `StreamTitle` replaces `Playing`; otherwise the screen simply stays on `Playing`. Radio 538, Radio 10, and Radio Veronica advertised ICY metadata when last tested. NPO Radio 1 and NPO Radio 2 may not provide a track title. A `StreamTitle` log entry is metadata only; it does not affect audio.

## Update And Diagnose

After editing the applet locally, run the same deployment command again. It copies the whole package and restarts SqueezePlay:

```powershell
.\scripts\deploy.ps1 -HostName <radio-ip> -ShowLogs
```

To inspect the latest radio log without deploying:

```powershell
.\scripts\logs.ps1 -HostName <radio-ip>
```

Useful log entries start with `StandaloneRadio:`. A successful boot includes `Registering: StandaloneRadio` and `standalone mode controls enabled`.

If deployment cannot connect, first confirm the radio's current DHCP address, Wi-Fi connection, root SSH access, and password. If a station shows `Connection failed`, check the radio has DNS/internet access and verify the stream endpoint has not changed. The applet logs the resolver failure but never displays internal addresses on the radio screen.

## Applet Installer Troubleshooting

### Applet Does Not Appear

Confirm LMS can fetch and parse `extensions.xml`, then restart or reload LMS after adding the repository. Verify the Radio is connected to that LMS and that the entry has `target="baby"`, `minTarget="7.7"`, and `maxTarget="*"`. The installer requests the applet list from its connected LMS, not directly from the repository URL.

### Download Fails

Verify the published ZIP URL is reachable over HTTP without a login page, redirect, or firewall block. Confirm the URL in `extensions.xml` has the versioned filename and its SHA-1 exactly matches `Get-FileHash -Algorithm SHA1 dist\StandaloneRadio-<version>.zip`. Do not use HTTPS until it has been tested on the stock Radio.

### Applet Installs But Does Not Load

The ZIP must contain `StandaloneRadioApplet.lua` and `StandaloneRadioMeta.lua` at archive root, with `images/` beneath that root. Inspect `/var/log/messages` for `Registering: StandaloneRadio` and any Lua error. The SSH deployment remains a useful way to restore or debug the applet.

### Wrong Version Or No Update

Increase `VERSION`, rebuild, and publish a ZIP with the new version in its filename. Confirm that `extensions.xml` references the same version and new SHA-1. LMS caches repository XML briefly, and HTTP caches may retain an old file when a ZIP filename is reused.

## How It Works

The applet obtains the existing local player through `Player:getLocalPlayer().playback`, resolves station hosts asynchronously through BusyBox `nslookup`, and starts the stock MP3 stream/decode path with `playback:_streamConnect()`. Stop and station switches use `playback:stopInternal()`.

For ICY-capable streams, it asks for metadata, reads the server's `icy-metaint` response through the playback instance, and enables SqueezePlay's built-in native metadata filter. That filter keeps metadata bytes out of the MP3 decoder. The applet observes the resulting native `META` notifications to update the on-screen label. It does not implement its own socket reader or modify stock playback code.

The stock playback engine pauses audio after an output-buffer underrun and normally waits for LMS to send a resume command. StandaloneRadio checks for that paused state once per second and resumes audio locally once the encoded stream buffer has refilled. This avoids a temporary network hiccup leaving a healthy stream silent.

See [research.md](research.md) for the firmware-specific investigation and [device-backups/README.md](device-backups/README.md) for the stock-file backup policy.
