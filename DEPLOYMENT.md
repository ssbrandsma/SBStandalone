# StandaloneRadio Deployment

This runbook covers a complete StandaloneRadio release: build the Applet
Installer package, update both local repositories, publish the files on the
VPS, reload the bootstrap server, and verify the public result.

## Locations

| Purpose | Location |
| --- | --- |
| Applet repository | `C:\Projects\squeezebox` |
| Bootstrap repository | `C:\Projects\squeezebox-bootstrap-server` |
| VPS | `root@49.12.198.91` |
| VPS SSH key | `C:\Users\Sjoerd\.ssh\remote_ssh_priv2.openssh` |
| Static StandaloneRadio directory | `/var/www/bytestack_nl_usr/data/www/bytestack.nl/sbstandalone` |
| Merged repository XML | `/var/www/bytestack_nl_usr/data/www/bytestack.nl/squeezebox/extensions.xml` |
| Bootstrap configuration | `/var/www/squeezebox_o_usr/data/squeezebox-bootstrap/config.json` |
| Bootstrap container | `squeezebox-bootstrap-squeezebox-bootstrap-1` |

The container bind-mounts the host configuration above as
`/config/config.json`. Update the host file and restart the container; do not
edit only the copy visible inside the container.

## 1. Prepare The Release

Work from `C:\Projects\squeezebox`.

1. Check both working trees and preserve unrelated changes.

   ```powershell
   git status --short
   git -C C:\Projects\squeezebox-bootstrap-server status --short
   ```

2. Update `VERSION` to the new semantic version.

3. Update every versioned StandaloneRadio `User-Agent`. Find them with:

   ```powershell
   rg -n 'StandaloneRadio/[0-9]+\.[0-9]+\.[0-9]+' applet
   ```

   At the time this guide was written, they are in `RadioBrowser.lua`,
   `TrackArtwork.lua`, and `ArtworkRequest.lua`.

4. Update the release description in `scripts/build-applet-package.ps1`.
   The script places it in both generated XML entries.

5. Parse all Lua files and check the patch.

   ```powershell
   Get-ChildItem applet\StandaloneRadio -Filter *.lua -File | ForEach-Object {
       & luac -p $_.FullName
       if ($LASTEXITCODE) { throw "Lua parse failed: $($_.FullName)" }
   }
   git diff --check
   ```

## 2. Build The Package

Run from the applet repository:

```powershell
.\scripts\build-applet-package.ps1
```

The script creates:

- `dist/StandaloneRadio-<version>.zip`
- `dist/extensions.xml`
- `dist/extensions.xml.sha1`

Record the ZIP SHA-1 printed by the script. The ZIP must contain the Lua files
at archive root and `images/radio.png`; it must not contain an enclosing
`StandaloneRadio` directory.

Confirm the result:

```powershell
$Version = (Get-Content .\VERSION -Raw).Trim()
$Zip = ".\dist\StandaloneRadio-$Version.zip"
$Sha = (Get-FileHash $Zip -Algorithm SHA1).Hash.ToLowerInvariant()
$Sha

Add-Type -AssemblyName System.IO.Compression.FileSystem
$Archive = [System.IO.Compression.ZipFile]::OpenRead((Resolve-Path $Zip))
$Archive.Entries.FullName
$Archive.Dispose()
```

## 3. Update Local Bootstrap Metadata

In `C:\Projects\squeezebox-bootstrap-server`, update only the two
`StandaloneRadio` entries (`baby` and `fab4`) in:

- `config.json`
- `config.example.json`
- `merged-extensions.xml`

For both targets, update the version, release description, ZIP SHA-1, and URL:

```text
http://49.12.198.91/sbstandalone/StandaloneRadio-<version>.zip
```

Do not replace the complete merged XML or JSON applet list. Preserve the
SpotifyConnect, Doom, and any future applet entries.

Validate JSON, XML, and matching metadata before uploading:

```powershell
$Bootstrap = 'C:\Projects\squeezebox-bootstrap-server'
Get-Content "$Bootstrap\config.json" -Raw | ConvertFrom-Json | Out-Null
Get-Content "$Bootstrap\config.example.json" -Raw | ConvertFrom-Json | Out-Null
[xml](Get-Content .\dist\extensions.xml -Raw) | Out-Null
[xml](Get-Content "$Bootstrap\merged-extensions.xml" -Raw) | Out-Null

rg -n "StandaloneRadio-$Version|$Sha" `
    .\dist\extensions.xml `
    "$Bootstrap\config.json" `
    "$Bootstrap\config.example.json" `
    "$Bootstrap\merged-extensions.xml"
```

Each metadata file must contain two matching StandaloneRadio entries, one for
`baby` and one for `fab4`.

## 4. Stage Files On The VPS

Upload to `/tmp` first. Unique names prevent the standalone and merged XML
files from overwriting each other.

```powershell
$Version = (Get-Content C:\Projects\squeezebox\VERSION -Raw).Trim()
$Key = 'C:\Users\Sjoerd\.ssh\remote_ssh_priv2.openssh'
$Vps = 'root@49.12.198.91'
$Bootstrap = 'C:\Projects\squeezebox-bootstrap-server'

scp -i $Key -o BatchMode=yes `
    "C:\Projects\squeezebox\dist\StandaloneRadio-$Version.zip" `
    "${Vps}:/tmp/StandaloneRadio-$Version.zip"
scp -i $Key -o BatchMode=yes `
    'C:\Projects\squeezebox\dist\extensions.xml' `
    "${Vps}:/tmp/standalone-extensions-$Version.xml"
scp -i $Key -o BatchMode=yes `
    "$Bootstrap\merged-extensions.xml" `
    "${Vps}:/tmp/merged-extensions-$Version.xml"
scp -i $Key -o BatchMode=yes `
    "$Bootstrap\config.json" `
    "${Vps}:/tmp/squeezebox-config-$Version.json"
```

Stop immediately if any upload fails.

## 5. Back Up And Install

Connect to the VPS:

```powershell
ssh -i $Key -o BatchMode=yes $Vps
```

Run the following on the VPS. Set `version` and `expected_sha` from the local
build output.

```bash
set -eu
version='X.Y.Z'
expected_sha='replace-with-build-sha1'
stamp=$(date +%Y%m%d-%H%M%S)

standalone_root='/var/www/bytestack_nl_usr/data/www/bytestack.nl/sbstandalone'
merged_xml='/var/www/bytestack_nl_usr/data/www/bytestack.nl/squeezebox/extensions.xml'
bootstrap_config='/var/www/squeezebox_o_usr/data/squeezebox-bootstrap/config.json'

cp -p "$standalone_root/extensions.xml" "$standalone_root/extensions.xml.bak.$stamp"
cp -p "$merged_xml" "$merged_xml.bak.$stamp"
cp -p "$bootstrap_config" "$bootstrap_config.bak.$stamp"

install -o root -g root -m 0644 \
    "/tmp/StandaloneRadio-$version.zip" \
    "$standalone_root/StandaloneRadio-$version.zip"
install -o root -g root -m 0644 \
    "/tmp/standalone-extensions-$version.xml" \
    "$standalone_root/extensions.xml"
install -o bytestack_nl_usr -g bytestack_nl_usr -m 0644 \
    "/tmp/merged-extensions-$version.xml" \
    "$merged_xml"
install -o squeezebox_o_usr -g squeezebox_o_usr -m 0644 \
    "/tmp/squeezebox-config-$version.json" \
    "$bootstrap_config"

test "$(sha1sum "$standalone_root/StandaloneRadio-$version.zip" | cut -d' ' -f1)" = "$expected_sha"
python3 -m json.tool "$bootstrap_config" >/dev/null

docker restart squeezebox-bootstrap-squeezebox-bootstrap-1
docker ps --format '{{.Names}} {{.Status}}' \
    | grep '^squeezebox-bootstrap-squeezebox-bootstrap-1 '

echo "Backup timestamp: $stamp"
```

Expected ownership and mode:

| File | Owner | Mode |
| --- | --- | --- |
| Standalone ZIP and XML | `root:root` | `0644` |
| Merged XML | `bytestack_nl_usr:bytestack_nl_usr` | `0644` |
| Bootstrap config | `squeezebox_o_usr:squeezebox_o_usr` | `0644` |

## 6. Verify The Deployment

Verify the live container on the VPS:

```bash
docker exec squeezebox-bootstrap-squeezebox-bootstrap-1 \
    grep -n "StandaloneRadio-$version.zip" /config/config.json
docker exec squeezebox-bootstrap-squeezebox-bootstrap-1 \
    grep -n "$expected_sha" /config/config.json
docker logs --tail 30 squeezebox-bootstrap-squeezebox-bootstrap-1
```

The logs should include listeners on UDP/TCP `3483` and TCP `9000`.

Verify all public endpoints from the workstation:

```powershell
$ZipUrl = "http://49.12.198.91/sbstandalone/StandaloneRadio-$Version.zip"
$StandaloneXmlUrl = 'http://49.12.198.91/sbstandalone/extensions.xml'
$MergedXmlUrl = 'http://www.bytestack.nl/squeezebox/extensions.xml'

curl.exe -fL -o "$env:TEMP\StandaloneRadio-$Version.zip" $ZipUrl
$PublicSha = (Get-FileHash "$env:TEMP\StandaloneRadio-$Version.zip" -Algorithm SHA1).Hash.ToLowerInvariant()
if ($PublicSha -ne $Sha) { throw "Public ZIP SHA mismatch: $PublicSha" }

$StandaloneXml = [xml](Invoke-WebRequest $StandaloneXmlUrl -UseBasicParsing).Content
$MergedXml = [xml](Invoke-WebRequest $MergedXmlUrl -UseBasicParsing).Content

$StandaloneXml.extensions.applets.applet |
    Where-Object name -eq 'StandaloneRadio' |
    Select-Object name, version, target, sha, url
$MergedXml.extensions.applets.applet |
    Where-Object name -eq 'StandaloneRadio' |
    Select-Object name, version, target, sha, url
```

Final acceptance criteria:

- All three public URLs return HTTP `200`.
- The public ZIP SHA-1 equals the local build SHA-1.
- Both XML endpoints contain exactly two StandaloneRadio entries.
- Both entries use the new version, URL, and SHA-1.
- The live container config contains the same two entries.
- The container remains running and logs normal listeners.

## 7. Optional Radio Smoke Test

Before publishing, a development build can be copied to a test Radio with
`scripts/deploy.ps1`. After direct installation or an Applet Installer update,
verify:

- `Standalone Radio` opens.
- `Now Playing` and `Radio Browser` are sibling menu entries.
- A preset starts playback and displays metadata and artwork.
- Home restores the normal background without hanging or rebooting.
- Reopening `Now Playing` displays the station/default logo even when track
  artwork has already loaded.

Useful device logs:

```sh
tail -f /var/log/messages
```

Successful startup includes `Registering: StandaloneRadio` and
`standalone mode controls enabled`.

## 8. Commit, Tag, And Push

Do this only after the package and public metadata have passed verification.
Review both working trees first so unrelated local work is not committed.

In the applet repository:

```powershell
Set-Location C:\Projects\squeezebox
git status --short
git diff

# Stage only the reviewed release source and documentation files.
git add README.md DEPLOYMENT.md VERSION applet scripts
git diff --cached --check
git diff --cached
git commit -m "Release StandaloneRadio $Version"
git tag -a $Version -m "StandaloneRadio $Version"
git push origin HEAD
git push origin $Version
```

Tags use the plain semantic version (`0.8.1`), without a `v` prefix.

In the bootstrap repository, `config.json` is intentionally local/ignored.
Commit only the tracked example and merged catalog metadata:

```powershell
Set-Location C:\Projects\squeezebox-bootstrap-server
git status --short
git diff -- config.example.json merged-extensions.xml
git add config.example.json merged-extensions.xml
git diff --cached --check
git diff --cached
git commit -m "Publish StandaloneRadio $Version"
git push origin HEAD
```

If either repository contains unrelated modifications, leave them unstaged.

## 9. Rollback

Every deployment creates timestamped `.bak.<timestamp>` copies of both XML
files and the bootstrap config. To roll back metadata, reinstall the matching
backup with the ownership and mode shown above, then restart the bootstrap
container. Old versioned ZIPs are intentionally retained, so an XML/config
rollback can continue referencing the previous package.

Do not delete failed-release files until logs, hashes, and backups have been
reviewed.
