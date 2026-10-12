$ErrorActionPreference = 'Stop'
$source = Get-Content -Raw (Join-Path $PSScriptRoot '..\applet\StandaloneRadio\StandaloneRadioApplet.lua')
$stream = Get-Content -Raw (Join-Path $PSScriptRoot '..\applet\StandaloneRadio\StreamPlayer.lua')
$native = Get-Content -Raw (Join-Path $PSScriptRoot '..\applet\StandaloneRadio\NativeNowPlaying.lua')

if ($source -match 'StandaloneRadio\.NowPlaying|self\.nowPlaying|STANDALONE_RADIO_NOW_PLAYING') {
	throw 'legacy NowPlaying integration is still referenced by the applet'
}
if ($stream -notmatch 'stationGeneration') {
	throw 'StreamPlayer does not publish logical station generations'
}
if ($source -notmatch 'self\.nativeNowPlaying:request\(stationGeneration\)') {
	throw 'explicit station selection does not request native Now Playing navigation'
}
if (($source | Select-String -Pattern 'nativeNowPlaying:request' -AllMatches).Matches.Count -ne 1) {
	throw 'native navigation must have exactly one centralized invocation path'
}
if ($native -notmatch 'callService\("goNowPlaying"') {
	throw 'firmware goNowPlaying service is not used'
}
if ($native -notmatch 'isCurrentWindow') {
	throw 'current native Now Playing window is not detected'
}

Write-Host 'Now Playing navigation checks passed'
