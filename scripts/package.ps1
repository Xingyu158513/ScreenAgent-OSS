param(
    [string]$Version = '1.1.0-rc1'
)

$ErrorActionPreference = 'Stop'
$ProjectRoot = Split-Path -Parent $PSScriptRoot
$Dist = Join-Path $ProjectRoot 'dist'
$Stage = Join-Path $Dist ("ScreenAgent-$Version-Windows")
$Zip = Join-Path $Dist ("ScreenAgent-$Version-Windows.zip")
$Checksum = $Zip + '.sha256'

& powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $ProjectRoot 'tests\run_tests.ps1')
if ($LASTEXITCODE -ne 0) { throw 'Safety tests failed; package was not created.' }

if (Test-Path -LiteralPath $Stage) { Remove-Item -LiteralPath $Stage -Recurse -Force }
if (Test-Path -LiteralPath $Zip) { Remove-Item -LiteralPath $Zip -Force }
if (Test-Path -LiteralPath $Checksum) { Remove-Item -LiteralPath $Checksum -Force }
New-Item -ItemType Directory -Force -Path $Stage | Out-Null

$PackageRootFiles = Get-ChildItem -LiteralPath $ProjectRoot -File | Where-Object {
    $_.Extension -in @('.bat', '.ps1', '.vbs', '.md', '.json', '.html') -or $_.Name -eq 'LICENSE'
}
foreach ($Source in $PackageRootFiles) {
    Copy-Item -LiteralPath $Source.FullName -Destination (Join-Path $Stage $Source.Name) -Force
}

foreach ($Required in @('install.ps1', 'config_wizard.ps1', 'start_recording.ps1', 'auto_archive.ps1', 'uninstall.ps1', 'LICENSE')) {
    if (-not (Test-Path -LiteralPath (Join-Path $Stage $Required))) {
        throw "Missing package file: $Required"
    }
}

foreach ($Directory in @('lib', 'docs', 'config')) {
    Copy-Item -LiteralPath (Join-Path $ProjectRoot $Directory) -Destination $Stage -Recurse -Force
}

$Forbidden = Get-ChildItem -LiteralPath $Stage -Recurse -File | Where-Object {
    $_.Name -match 'rclone\.conf|\.log$|\.mkv$|\.mp4$|\.mov$|current_session\.json|install_report\.md'
}
if ($Forbidden) {
    throw "Forbidden runtime or credential files entered the package: $($Forbidden.FullName -join ', ')"
}

Compress-Archive -Path (Join-Path $Stage '*') -DestinationPath $Zip -CompressionLevel Optimal
$Hash = (Get-FileHash -LiteralPath $Zip -Algorithm SHA256).Hash.ToLowerInvariant()
"$Hash  $([System.IO.Path]::GetFileName($Zip))" | Set-Content -LiteralPath $Checksum -Encoding ASCII

Write-Host "Package: $Zip" -ForegroundColor Green
Write-Host "SHA256: $Hash" -ForegroundColor Green
