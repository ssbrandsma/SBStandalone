$ErrorActionPreference = "Stop"
$root = Join-Path $PSScriptRoot ".."
$applet = Get-Content (Join-Path $root "applet\StandaloneRadio\StandaloneRadioApplet.lua") -Raw
$build = Get-Content (Join-Path $root "scripts\build-applet-package.ps1") -Raw

foreach ($needle in @(
	'STANDALONE_RADIO_USER_STATIONS',
	'weight = 3',
	'function userStationsMenu',
	'EVENT_WINDOW_ACTIVE',
	'self.userStations:resolve(station.id)',
	'self:_playStation(selected)'
)) {
	if (-not $applet.Contains($needle)) { throw "Missing user-station integration: $needle" }
}
if (-not $build.Contains('"UserStations.lua"')) { throw "UserStations.lua is missing from package build" }
if (-not (Get-Content (Join-Path $root "applet\StandaloneRadio\LogoCache.lua") -Raw).Contains('station.localLogoPath')) {
	throw "User uploaded-logo cache integration is missing"
}
Write-Host "User station integration checks passed"
