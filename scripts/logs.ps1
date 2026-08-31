param(
	[Parameter(Mandatory = $true)]
	[string]$HostName
)

$sshArgs = @(
	"-o", "HostKeyAlgorithms=+ssh-rsa,ssh-dss",
	"-o", "KexAlgorithms=+diffie-hellman-group1-sha1",
	"-o", "MACs=hmac-sha1,hmac-sha1-96,hmac-md5",
	"-o", "StrictHostKeyChecking=no",
	"-c", "aes128-cbc"
)

if ($env:SQUEEZEBOX_SSH_PASSWORD) {
	$env:SSH_ASKPASS = Join-Path $PSScriptRoot "ssh-askpass.cmd"
	$env:SSH_ASKPASS_REQUIRE = "force"
	$env:DISPLAY = "codex"
}

ssh @sshArgs root@$HostName "tail -200 /var/log/messages"
