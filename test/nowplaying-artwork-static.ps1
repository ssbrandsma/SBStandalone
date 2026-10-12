$ErrorActionPreference = 'Stop'
$applet = Get-Content -Raw (Join-Path $PSScriptRoot '..\applet\StandaloneRadio\StandaloneRadioApplet.lua')
$track = Get-Content -Raw (Join-Path $PSScriptRoot '..\applet\StandaloneRadio\TrackArtwork.lua')
$client = Get-Content -Raw (Join-Path $PSScriptRoot '..\applet\StandaloneRadio\StandaloneBaseNowPlaying.lua')

if ($track -notmatch 'onArtworkUrl\(station, streamTitle, picture, stationGeneration\)') {
	throw 'TrackArtwork does not expose its discovered original URL with stale-check context'
}
if ($track -match 'nowPlaying|_downloadPicture|standalone-radio-track-') {
	throw 'TrackArtwork still contains the removed legacy artwork sink'
}
if ($applet -notmatch 'updateTrackArtwork\(url, station, stationGeneration, streamTitle\)') {
	throw 'Applet does not forward discovered artwork to the Now Playing client'
}
if ($client -notmatch 'artwork_url\s*=\s*artwork') {
	throw 'Now Playing snapshots do not contain artwork_url'
}
if ($client -match 'file://|base64') {
	throw 'Now Playing artwork integration contains a prohibited transport'
}

Write-Host 'Now Playing artwork integration checks passed'
