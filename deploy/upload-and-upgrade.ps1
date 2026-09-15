[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][ValidatePattern('^[A-Za-z0-9._:-]+$')][string]$Server,
    [ValidatePattern('^[A-Za-z_][A-Za-z0-9_-]*$')][string]$UserName = "admin",
    [ValidateRange(1, 65535)][int]$Port = 22,
    [string]$IdentityFile,
    [string]$ReleaseArchive
)

$ErrorActionPreference = "Stop"
$projectRoot = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
if (-not $ReleaseArchive) {
    $ReleaseArchive = Join-Path $projectRoot "release\fangcun-release-2.7.0.tar.gz"
}
$ReleaseArchive = (Resolve-Path -LiteralPath $ReleaseArchive).Path

if (-not (Get-Command ssh -ErrorAction SilentlyContinue)) { throw "Windows OpenSSH ssh command was not found." }
if (-not (Get-Command scp -ErrorAction SilentlyContinue)) { throw "Windows OpenSSH scp command was not found." }

Push-Location $projectRoot
try {
    Write-Host "[1/5] Running local verification"
    & npm run check
    if ($LASTEXITCODE -ne 0) { throw "Local verification failed; upload was cancelled." }
} finally {
    Pop-Location
}

$target = "${UserName}@${Server}"
$remoteArchive = "/tmp/fangcun-release-2.7.0.tar.gz"
$remoteStage = "/tmp/fangcun-release-2.7.0"
$identityArgs = @()
if ($IdentityFile) {
    $identityPath = (Resolve-Path -LiteralPath $IdentityFile).Path
    $identityArgs = @("-i", $identityPath)
}

Write-Host "[2/5] Uploading the release archive to $target"
& scp @identityArgs -P $Port -- $ReleaseArchive "${target}:$remoteArchive"
if ($LASTEXITCODE -ne 0) { throw "SCP upload failed." }

$remoteCommand = @"
set -euo pipefail
install -d -m 0700 '$remoteStage'
tar -xzf '$remoteArchive' -C '$remoteStage'
cd '$remoteStage'
if systemctl cat fangcun.service >/dev/null 2>&1 && [[ -f /var/lib/fangcun/fangcun.sqlite ]]; then
  sudo bash deploy/backup.sh
else
  echo 'No existing Fangcun database was found; skipping backup for this first install.'
fi
sudo bash deploy/install.sh
sudo bash deploy/verify.sh
"@

Write-Host "[3/5] Backing up remote data"
Write-Host "[4/5] Installing 2.7.0 and restarting the service"
Write-Host "[5/5] Verifying service health, bind address, and logs"
$remoteCommand | & ssh @identityArgs -tt -p $Port -- $target "bash -s"
if ($LASTEXITCODE -ne 0) { throw "Remote upgrade or verification failed. Backups remain in /var/backups/fangcun." }

Write-Host "Deployment complete. Keep Cloudflare Tunnel pointed at http://127.0.0.1:18443."
