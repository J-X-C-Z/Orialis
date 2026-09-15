[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$ApkPath,
    [Parameter(Mandatory = $true)][string]$ScreenshotDirectory,
    [string]$PublicOrigin = "https://fangcun.example.org"
)

$ErrorActionPreference = "Stop"
$projectRoot = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$apk = (Resolve-Path -LiteralPath $ApkPath).Path
$screenshots = (Resolve-Path -LiteralPath $ScreenshotDirectory).Path

Write-Host "[1/5] Local test suite"
Push-Location $projectRoot
try {
    & npm run check
    if ($LASTEXITCODE -ne 0) { throw "Local verification failed." }
} finally {
    Pop-Location
}

Write-Host "[2/5] Public privacy policy"
$privacy = (Invoke-WebRequest -UseBasicParsing -Uri "$($PublicOrigin.TrimEnd('/'))/privacy.html").Content
if ($privacy -notmatch "Fangcun|方寸") { throw "The public privacy policy is unavailable." }
if ($privacy -match "发布前待配置|\{\{[^}]+\}\}") { throw "The public privacy policy still contains placeholders." }

Write-Host "[3/5] Release signature and alignment"
$sdkRoot = Join-Path $projectRoot ".tooling\android-sdk"
$apksigner = Join-Path $sdkRoot "build-tools\36.0.0\apksigner.bat"
$zipalign = Join-Path $sdkRoot "build-tools\36.0.0\zipalign.exe"
if (-not (Test-Path -LiteralPath $apksigner) -or -not (Test-Path -LiteralPath $zipalign)) { throw "Android Build Tools 36.0.0 are missing." }
$signature = (& $apksigner verify --verbose --print-certs $apk 2>&1 | Out-String)
if ($LASTEXITCODE -ne 0) { throw "APK signature verification failed." }
if ($signature -match "Android Debug") { throw "A debug certificate cannot be submitted to an app store." }
& $zipalign -c -P 16 4 $apk
if ($LASTEXITCODE -ne 0) { throw "APK alignment verification failed." }

Write-Host "[4/5] Store screenshots"
$images = @(Get-ChildItem -LiteralPath $screenshots -File | Where-Object { $_.Extension -match '^\.(png|jpg|jpeg)$' })
if ($images.Count -lt 4) { throw "At least four store screenshots are required." }
$uniqueHashes = @($images | Get-FileHash -Algorithm SHA256 | Select-Object -ExpandProperty Hash -Unique)
if ($uniqueHashes.Count -lt 4) { throw "At least four distinct store screenshots are required." }

Write-Host "[5/5] Artifact digest"
Get-FileHash -LiteralPath $apk -Algorithm SHA256 | Format-List
Write-Host "Store preflight passed. Manual device QA and portal qualification review are still required."
