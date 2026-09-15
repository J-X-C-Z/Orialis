[CmdletBinding()]
param(
    [string]$OutputPath
)

$ErrorActionPreference = "Stop"
$projectRoot = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
if (-not $OutputPath) { $OutputPath = Join-Path $projectRoot "release\store-assets\fangcun-icon-512.png" }
$outputDirectory = Split-Path -Parent $OutputPath
New-Item -ItemType Directory -Force -Path $outputDirectory | Out-Null

Add-Type -AssemblyName System.Drawing
$bitmap = New-Object System.Drawing.Bitmap 512, 512
$graphics = [System.Drawing.Graphics]::FromImage($bitmap)
try {
    $graphics.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $graphics.Clear([System.Drawing.ColorTranslator]::FromHtml("#344F42"))
    $cream = New-Object System.Drawing.SolidBrush ([System.Drawing.ColorTranslator]::FromHtml("#F4F2ED"))
    $gold = New-Object System.Drawing.SolidBrush ([System.Drawing.ColorTranslator]::FromHtml("#C58A42"))
    try {
        $graphics.FillRectangle($cream, 104, 104, 132, 132)
        $graphics.FillRectangle($cream, 276, 104, 132, 132)
        $graphics.FillRectangle($cream, 104, 276, 132, 132)
        $graphics.FillRectangle($cream, 276, 276, 132, 132)
        $graphics.FillRectangle($gold, 236, 104, 40, 304)
        $graphics.FillRectangle($gold, 104, 236, 304, 40)
    } finally {
        $cream.Dispose()
        $gold.Dispose()
    }
    $bitmap.Save($OutputPath, [System.Drawing.Imaging.ImageFormat]::Png)
} finally {
    $graphics.Dispose()
    $bitmap.Dispose()
}

Write-Host "Store icon candidate: $OutputPath"
Get-FileHash -LiteralPath $OutputPath -Algorithm SHA256 | Format-List
