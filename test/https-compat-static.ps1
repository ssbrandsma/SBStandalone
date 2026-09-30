$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot

function Require-Text([string]$Path, [string]$Pattern, [string]$Message) {
	$content = Get-Content (Join-Path $root $Path) -Raw
	if ($content -notmatch $Pattern) { throw $Message }
}

Require-Text 'applet/StandaloneRadio/RadioFeedsClient.lua' 'UrlTransport\.forRequest\(url, self\.log\)' 'RadioFeeds does not use UrlTransport'
Require-Text 'applet/StandaloneRadio/RadioFeedsClient.lua' 'USER_AGENT = "Lyrion Music Server"' 'RadioFeeds User-Agent changed'
Require-Text 'applet/StandaloneRadio/RadioFeedsClient.lua' 'application/xml,text/xml,\*/\*' 'RadioFeeds XML Accept header changed'
Require-Text 'applet/StandaloneRadio/RadioFeedsClient.lua' '\^https\?://' 'HTTPS playlist entries are not accepted'
Require-Text 'applet/StandaloneRadio/LogoCache.lua' 'UrlTransport\.forRequest\(url, self\.log\)' 'Logos do not use UrlTransport'
Require-Text 'applet/StandaloneRadio/TrackArtwork.lua' 'UrlTransport\.forRequest\(picture, self\.log\)' 'Track artwork does not use UrlTransport'
Require-Text 'applet/StandaloneRadio/StreamPlayer.lua' 'transportStation\(playStation, self\.log\)' 'Playback does not translate at its boundary'
Require-Text 'applet/StandaloneRadio/PresetStore.lua' 'url = station\.url' 'Presets do not retain the station URL'
Require-Text 'scripts/build-applet-package.ps1' '"UrlTransport\.lua"' 'UrlTransport is missing from the package'
Require-Text 'scripts/build-applet-package.ps1' '"HttpsProxyStatus\.lua"' 'HttpsProxyStatus is missing from the package'
Require-Text 'applet/StandaloneRadio/StandaloneRadioApplet.lua' 'httpsProxyStatus:check\(false\)' 'Menu does not check HTTPS proxy health'
Require-Text 'applet/StandaloneRadio/HttpsProxyStatus.lua' '"/health"' 'HTTPS proxy health endpoint is missing'

$networkFiles = @(
	'applet/StandaloneRadio/LogoCache.lua',
	'applet/StandaloneRadio/TrackArtwork.lua'
)
foreach ($file in $networkFiles) {
	$content = Get-Content (Join-Path $root $file) -Raw
	if ($content -match '\bwget\b|bootstrap-bridge') { throw "$file still uses a legacy artwork transport" }
}

Write-Output 'HTTPS compatibility integration checks passed'
