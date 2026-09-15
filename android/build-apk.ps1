[CmdletBinding()]
param(
    [ValidateSet("Debug", "Release", "Both")]
    [string]$Variant = "Debug",
    [switch]$SkipDownloads
)

$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

$androidDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$projectRoot = Split-Path -Parent $androidDir
$toolingRoot = Join-Path $projectRoot ".tooling"
$downloadRoot = Join-Path $toolingRoot "downloads"
$jdkRoot = Join-Path $toolingRoot "jdk-17"
$sdkRoot = Join-Path $toolingRoot "android-sdk"
$gradleRoot = Join-Path $toolingRoot "gradle-9.5.0"
$gradleUserHome = Join-Path $toolingRoot "gradle-home"
$releaseRoot = Join-Path $projectRoot "release"

$commandLineToolsUrl = "https://dl.google.com/android/repository/commandlinetools-win-15859902_latest.zip"
$commandLineToolsSha256 = "90ae805d20434428bffcb699c290860f19bb5f66a67e6b330067e3de801fb04a"
$jdkUrl = "https://api.adoptium.net/v3/binary/latest/17/ga/windows/x64/jdk/hotspot/normal/eclipse"
$gradleUrl = "https://services.gradle.org/distributions/gradle-9.5.0-bin.zip"
$gradleSha256 = "553c78f50dafcd54d65b9a444649057857469edf836431389695608536d6b746"

function Get-Download {
    param(
        [Parameter(Mandatory = $true)][string]$Uri,
        [Parameter(Mandatory = $true)][string]$Destination,
        [string]$Sha256
    )
    if ((Test-Path -LiteralPath $Destination) -and (Get-Item -LiteralPath $Destination).Length -lt 1MB) {
        Remove-Item -LiteralPath $Destination -Force
    }
    if (-not (Test-Path -LiteralPath $Destination)) {
        if ($SkipDownloads) {
            throw "Missing $Destination while -SkipDownloads was specified."
        }
        Write-Host "Downloading $Uri"
        $partial = "$Destination.partial"
        if (Test-Path -LiteralPath $partial) { Remove-Item -LiteralPath $partial -Force }
        & curl.exe -L --fail --retry 3 --connect-timeout 30 --output $partial $Uri
        if ($LASTEXITCODE -ne 0) {
            if (Test-Path -LiteralPath $partial) { Remove-Item -LiteralPath $partial -Force }
            throw "Download failed: $Uri"
        }
        Move-Item -LiteralPath $partial -Destination $Destination
    }
    if ($Sha256) {
        $actual = (Get-FileHash -LiteralPath $Destination -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($actual -ne $Sha256.ToLowerInvariant()) {
            throw "Checksum mismatch: $Destination`nExpected $Sha256`nActual $actual"
        }
    }
}

New-Item -ItemType Directory -Force -Path $toolingRoot, $downloadRoot, $gradleUserHome, $releaseRoot | Out-Null

if (-not (Test-Path -LiteralPath (Join-Path $jdkRoot "bin\java.exe"))) {
    $jdkZip = Join-Path $downloadRoot "temurin-jdk-17.zip"
    Get-Download -Uri $jdkUrl -Destination $jdkZip
    $jdkExtract = Join-Path $toolingRoot "jdk-extract"
    if (Test-Path -LiteralPath $jdkExtract) { Remove-Item -LiteralPath $jdkExtract -Recurse -Force }
    New-Item -ItemType Directory -Path $jdkExtract | Out-Null
    Expand-Archive -LiteralPath $jdkZip -DestinationPath $jdkExtract -Force
    $jdkSource = Get-ChildItem -LiteralPath $jdkExtract -Directory | Select-Object -First 1
    if (-not $jdkSource) { throw "No JDK root directory was found in the archive." }
    Move-Item -LiteralPath $jdkSource.FullName -Destination $jdkRoot
    Remove-Item -LiteralPath $jdkExtract -Recurse -Force
}

$sdkManager = Join-Path $sdkRoot "cmdline-tools\latest\bin\sdkmanager.bat"
if (-not (Test-Path -LiteralPath $sdkManager)) {
    $toolsZip = Join-Path $downloadRoot "android-command-line-tools.zip"
    Get-Download -Uri $commandLineToolsUrl -Destination $toolsZip -Sha256 $commandLineToolsSha256
    $toolsExtract = Join-Path $toolingRoot "android-tools-extract"
    if (Test-Path -LiteralPath $toolsExtract) { Remove-Item -LiteralPath $toolsExtract -Recurse -Force }
    New-Item -ItemType Directory -Path $toolsExtract | Out-Null
    Expand-Archive -LiteralPath $toolsZip -DestinationPath $toolsExtract -Force
    $latestDir = Join-Path $sdkRoot "cmdline-tools\latest"
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $latestDir) | Out-Null
    Move-Item -LiteralPath (Join-Path $toolsExtract "cmdline-tools") -Destination $latestDir
    Remove-Item -LiteralPath $toolsExtract -Recurse -Force
}

if (-not (Test-Path -LiteralPath (Join-Path $gradleRoot "bin\gradle.bat"))) {
    $gradleZip = Join-Path $downloadRoot "gradle-9.5.0-bin.zip"
    Get-Download -Uri $gradleUrl -Destination $gradleZip -Sha256 $gradleSha256
    Expand-Archive -LiteralPath $gradleZip -DestinationPath $toolingRoot -Force
}

$env:JAVA_HOME = $jdkRoot
$env:ANDROID_HOME = $sdkRoot
$env:ANDROID_SDK_ROOT = $sdkRoot
$env:GRADLE_USER_HOME = $gradleUserHome
$env:Path = "$(Join-Path $jdkRoot 'bin');$(Join-Path $sdkRoot 'platform-tools');$env:Path"

if (-not (Test-Path -LiteralPath (Join-Path $sdkRoot "platforms\android-36\android.jar"))) {
    if ($SkipDownloads) { throw "Android SDK 36 is missing while -SkipDownloads was specified." }
    Write-Host "Accepting Android SDK licenses and installing API 36, Build Tools 36.0.0, and Platform Tools"
    1..100 | ForEach-Object { "y" } | & $sdkManager "--sdk_root=$sdkRoot" --licenses | Out-Host
    & $sdkManager "--sdk_root=$sdkRoot" "platforms;android-36" "build-tools;36.0.0" "platform-tools"
    if ($LASTEXITCODE -ne 0) { throw "Android SDK component installation failed." }
}

$gradlew = Join-Path $androidDir "gradlew.bat"
$gradleCommand = Join-Path $gradleRoot "bin\gradle.bat"
if (-not (Test-Path -LiteralPath $gradlew)) {
    & $gradleCommand -p $androidDir wrapper --gradle-version 9.5.0
    if ($LASTEXITCODE -ne 0) { throw "Gradle Wrapper generation failed." }
}

$tasks = switch ($Variant) {
    "Debug" { @("assembleDebug") }
    "Release" { @("assembleRelease") }
    "Both" { @("assembleDebug", "assembleRelease") }
}

if (($Variant -eq "Release" -or $Variant -eq "Both") -and
    @("FANGCUN_KEYSTORE_PATH", "FANGCUN_KEYSTORE_PASSWORD", "FANGCUN_KEY_ALIAS", "FANGCUN_KEY_PASSWORD").Where({ [string]::IsNullOrWhiteSpace([Environment]::GetEnvironmentVariable($_)) }).Count -gt 0) {
    throw "Release builds require all four signing environment variables. See android/README.md."
}

Push-Location $androidDir
try {
    & $gradleCommand -p $androidDir --no-daemon --stacktrace $tasks
    if ($LASTEXITCODE -ne 0) { throw "Android build failed." }
} finally {
    Pop-Location
}

if ($Variant -eq "Debug" -or $Variant -eq "Both") {
    $debugApk = Join-Path $androidDir "app\build\outputs\apk\debug\app-debug.apk"
    $debugTarget = Join-Path $releaseRoot "fangcun-v2.7.0-debug.apk"
    Copy-Item -LiteralPath $debugApk -Destination $debugTarget -Force
    Write-Host "Installable debug APK: $debugTarget"
    Get-FileHash -LiteralPath $debugTarget -Algorithm SHA256 | Format-List
}

if ($Variant -eq "Release" -or $Variant -eq "Both") {
    $releaseApk = Join-Path $androidDir "app\build\outputs\apk\release\app-release.apk"
    $releaseTarget = Join-Path $releaseRoot "fangcun-v2.7.0-release.apk"
    Copy-Item -LiteralPath $releaseApk -Destination $releaseTarget -Force
    $apksigner = Join-Path $sdkRoot "build-tools\36.0.0\apksigner.bat"
    $zipalign = Join-Path $sdkRoot "build-tools\36.0.0\zipalign.exe"
    & $zipalign -c -P 16 4 $releaseTarget
    if ($LASTEXITCODE -ne 0) { throw "Release APK zip alignment verification failed." }
    & $apksigner verify --verbose --print-certs $releaseTarget
    if ($LASTEXITCODE -ne 0) { throw "Release APK signature verification failed." }
    Write-Host "Signed release APK: $releaseTarget"
    Get-FileHash -LiteralPath $releaseTarget -Algorithm SHA256 | Format-List
}
