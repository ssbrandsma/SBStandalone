param(
	[Parameter(Mandatory = $true)]
	[string]$HostName,
	[string]$RemoteRoot = "/usr/share/jive/applets/StandaloneRadio",
	[switch]$ShowLogs
)

$sshArgs = @(
	"-o", "HostKeyAlgorithms=+ssh-rsa,ssh-dss",
	"-o", "KexAlgorithms=+diffie-hellman-group1-sha1",
	"-o", "MACs=hmac-sha1,hmac-sha1-96,hmac-md5",
	"-o", "StrictHostKeyChecking=no",
	"-c", "aes128-cbc"
)

$localApplet = Join-Path $PSScriptRoot "..\applet\StandaloneRadio"

if ($env:SQUEEZEBOX_SSH_PASSWORD) {
	$env:SSH_ASKPASS = Join-Path $PSScriptRoot "ssh-askpass.cmd"
	$env:SSH_ASKPASS_REQUIRE = "force"
	$env:DISPLAY = "codex"
}

Write-Host "Creating remote applet directory on $HostName"
ssh @sshArgs root@$HostName "mkdir -p $RemoteRoot"
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

Write-Host "Copying applet files"
scp -O -r @sshArgs (Join-Path $localApplet "*") root@${HostName}:$RemoteRoot/
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

Write-Host "Restarting SqueezePlay"
ssh @sshArgs root@$HostName "/etc/init.d/squeezeplay stopwdog && /etc/init.d/squeezeplay restart"
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

if ($ShowLogs) {
	ssh @sshArgs root@$HostName "tail -200 /var/log/messages"
}
