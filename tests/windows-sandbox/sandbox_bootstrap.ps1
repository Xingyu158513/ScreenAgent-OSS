param(
    [string]$ProjectRoot = 'C:\ScreenAgentProject',
    [string]$OutputRoot = 'C:\ScreenAgentOutput'
)

$ErrorActionPreference = 'Stop'
$ReportPath = Join-Path $OutputRoot 'ScreenAgent-1.1.0-rc1-windows-sandbox-report.md'
$StatusPath = Join-Path $OutputRoot 'windows-sandbox-status.txt'
$ErrorPath = Join-Path $OutputRoot 'windows-sandbox-error.txt'
$ExitCode = 1

try {
    $AcceptanceScript = Join-Path $ProjectRoot 'tests\acceptance\run_acceptance.ps1'
    $PackageZip = Join-Path $ProjectRoot 'dist\ScreenAgent-1.1.0-rc1-Windows.zip'
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $AcceptanceScript `
        -PackageZip $PackageZip `
        -EnvironmentLabel 'Windows Sandbox (fresh disposable Windows instance; network disabled)' `
        -ReportPath $ReportPath
    if ($LASTEXITCODE -ne 0) { throw "Acceptance script failed with exit code $LASTEXITCODE." }
    'PASSED' | Set-Content -LiteralPath $StatusPath -Encoding ASCII
    $ExitCode = 0
}
catch {
    'FAILED' | Set-Content -LiteralPath $StatusPath -Encoding ASCII
    ($_ | Out-String) | Set-Content -LiteralPath $ErrorPath -Encoding UTF8
}
finally {
    Start-Process -FilePath shutdown.exe -ArgumentList '/s', '/t', '5' -WindowStyle Hidden
}

exit $ExitCode
