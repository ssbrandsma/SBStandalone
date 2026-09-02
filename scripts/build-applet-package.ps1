[CmdletBinding()]
param(
	[string]$BaseUrl = "http://49.12.198.91/sbstandalone",
	[string]$OutputDirectory
)

$ErrorActionPreference = "Stop"

function Fail([string]$Message) {
	throw "StandaloneRadio package build failed: $Message"
}

function Escape-Xml([string]$Value) {
	return [System.Security.SecurityElement]::Escape($Value)
}

$projectRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot ".."))
$appletRoot = Join-Path $projectRoot "applet\StandaloneRadio"
$versionFile = Join-Path $projectRoot "VERSION"

if (-not $OutputDirectory) {
	$OutputDirectory = Join-Path $projectRoot "dist"
}
$OutputDirectory = [System.IO.Path]::GetFullPath($OutputDirectory)

if (-not (Test-Path -LiteralPath $versionFile -PathType Leaf)) {
	Fail "missing version file: $versionFile"
}

$version = (Get-Content -LiteralPath $versionFile -Raw).Trim()
if ($version -notmatch '^[0-9]+\.[0-9]+\.[0-9]+(?:[-+][0-9A-Za-z.-]+)?$') {
	Fail "VERSION must be a semantic version; found '$version'"
}

try {
	$repositoryUri = [Uri]$BaseUrl
}
catch {
	Fail "BaseUrl is not a valid absolute URL: $BaseUrl"
}
if (-not $repositoryUri.IsAbsoluteUri -or $repositoryUri.Scheme -notin @("http", "https")) {
	Fail "BaseUrl must use http or https: $BaseUrl"
}
$BaseUrl = $BaseUrl.TrimEnd('/')

$requiredRootFiles = @(
	"LogoCache.lua",
	"NowPlaying.lua",
	"PresetStore.lua",
	"RadioBrowser.lua",
	"Resolver.lua",
	"StandaloneRadioApplet.lua",
	"StandaloneRadioMeta.lua",
	"Stations.lua",
	"StreamPlayer.lua",
	"strings.txt"
)
$requiredImageFiles = @(
	"radio.png"
)

foreach ($file in $requiredRootFiles) {
	if (-not (Test-Path -LiteralPath (Join-Path $appletRoot $file) -PathType Leaf)) {
		Fail "required runtime file is missing: applet/StandaloneRadio/$file"
	}
}
foreach ($file in $requiredImageFiles) {
	if (-not (Test-Path -LiteralPath (Join-Path $appletRoot "images\$file") -PathType Leaf)) {
		Fail "required artwork is missing: applet/StandaloneRadio/images/$file"
	}
}

New-Item -ItemType Directory -Force -Path $OutputDirectory | Out-Null
$stageDirectory = Join-Path ([System.IO.Path]::GetTempPath()) ("SBStandalone-" + [Guid]::NewGuid().ToString("N"))
$zipName = "StandaloneRadio-$version.zip"
$zipPath = Join-Path $OutputDirectory $zipName
$repositoryPath = Join-Path $OutputDirectory "extensions.xml"

try {
	New-Item -ItemType Directory -Force -Path $stageDirectory | Out-Null
	New-Item -ItemType Directory -Force -Path (Join-Path $stageDirectory "images") | Out-Null

	foreach ($file in $requiredRootFiles) {
		Copy-Item -LiteralPath (Join-Path $appletRoot $file) -Destination (Join-Path $stageDirectory $file)
	}
	foreach ($file in $requiredImageFiles) {
		Copy-Item -LiteralPath (Join-Path $appletRoot "images\$file") -Destination (Join-Path $stageDirectory "images\$file")
	}

	Remove-Item -LiteralPath $zipPath -Force -ErrorAction SilentlyContinue
	Push-Location $stageDirectory
	try {
		Compress-Archive -Path * -DestinationPath $zipPath -CompressionLevel Optimal
	}
	finally {
		Pop-Location
	}

	if (-not (Test-Path -LiteralPath $zipPath -PathType Leaf)) {
		Fail "ZIP was not created: $zipPath"
	}

	$archive = [System.IO.Compression.ZipFile]::OpenRead($zipPath)
	try {
		$zipEntries = @($archive.Entries | Where-Object { -not $_.FullName.EndsWith('/') } | ForEach-Object { $_.FullName.Replace('\', '/') })
	}
	finally {
		$archive.Dispose()
	}

	$expectedEntries = @($requiredRootFiles + ($requiredImageFiles | ForEach-Object { "images/$_" }))
	$unexpectedEntries = @($zipEntries | Where-Object { $_ -notin $expectedEntries })
	$missingEntries = @($expectedEntries | Where-Object { $_ -notin $zipEntries })
	if ($unexpectedEntries.Count -gt 0) {
		Fail "ZIP contains unexpected runtime files: $($unexpectedEntries -join ', ')"
	}
	if ($missingEntries.Count -gt 0) {
		Fail "ZIP is missing required runtime files: $($missingEntries -join ', ')"
	}
	if ($zipEntries | Where-Object { $_ -match '^(StandaloneRadio/|applet/)' }) {
		Fail "ZIP has an enclosing root directory; Applet Installer needs files at archive root"
	}

	$sha1 = (Get-FileHash -LiteralPath $zipPath -Algorithm SHA1).Hash.ToLowerInvariant()
	$zipUrl = "$BaseUrl/$zipName"
	$xml = @"
<?xml version="1.0" encoding="UTF-8"?>
<extensions>
  <details>
    <title lang="EN">SBStandalone Applet Repository</title>
  </details>
  <applets>
    <applet name="StandaloneRadio" version="$(Escape-Xml $version)" target="baby" minTarget="7.7" maxTarget="*">
      <title lang="EN">Standalone Radio</title>
      <desc lang="EN">Standalone internet radio playback for Squeezebox Radio. LMS is only needed to install the applet.</desc>
      <changes lang="EN">Applet Installer package release $version.</changes>
      <creator>Sjoerd Brandsma</creator>
      <url>$(Escape-Xml $zipUrl)</url>
      <sha>$sha1</sha>
    </applet>
  </applets>
</extensions>
"@
	$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
	[System.IO.File]::WriteAllText($repositoryPath, $xml, $utf8NoBom)

	[xml]$parsedXml = Get-Content -LiteralPath $repositoryPath -Raw
	$applet = $parsedXml.extensions.applets.applet
	if ($applet.name -ne "StandaloneRadio" -or $applet.version -ne $version -or $applet.sha -ne $sha1 -or $applet.url -ne $zipUrl) {
		Fail "generated extensions.xml did not round-trip with the expected applet metadata"
	}
}
finally {
	if (Test-Path -LiteralPath $stageDirectory) {
		Remove-Item -LiteralPath $stageDirectory -Recurse -Force
	}
}

Write-Host "Built StandaloneRadio Applet Installer package"
Write-Host "Version:       $version"
Write-Host "ZIP:           $zipPath"
Write-Host "SHA-1:         $sha1"
Write-Host "Repository XML:$repositoryPath"
Write-Host "ZIP URL:       $zipUrl"
Write-Host "Repository URL:$BaseUrl/extensions.xml"
Write-Host "Archive entries:"
$zipEntries | ForEach-Object { Write-Host "  $_" }
