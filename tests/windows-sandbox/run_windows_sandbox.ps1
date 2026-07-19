param(
    [int]$MemoryInMB = 4096
)

$ErrorActionPreference = 'Stop'
$ProjectRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$SandboxExe = Join-Path $env:SystemRoot 'System32\WindowsSandbox.exe'
if (-not (Test-Path -LiteralPath $SandboxExe -PathType Leaf)) {
    throw 'Windows Sandbox is not enabled. Enable Containers-DisposableClientVM and restart Windows first.'
}

$PackageZip = Join-Path $ProjectRoot 'dist\ScreenAgent-1.1.0-rc2-Windows.zip'
if (-not (Test-Path -LiteralPath $PackageZip -PathType Leaf)) {
    throw "Package not found: $PackageZip"
}

$OutputRoot = Join-Path $ProjectRoot 'dist\windows-sandbox-output'
New-Item -ItemType Directory -Force -Path $OutputRoot | Out-Null
Remove-Item -LiteralPath (Join-Path $OutputRoot 'windows-sandbox-status.txt') -Force -ErrorAction SilentlyContinue
Remove-Item -LiteralPath (Join-Path $OutputRoot 'windows-sandbox-error.txt') -Force -ErrorAction SilentlyContinue

function Escape-Xml([string]$Value) {
    return [System.Security.SecurityElement]::Escape($Value)
}

$ConfigPath = Join-Path ([System.IO.Path]::GetTempPath()) ('ScreenAgent-' + [guid]::NewGuid().ToString('N') + '.wsb')
$ProjectXml = Escape-Xml ([System.IO.Path]::GetFullPath($ProjectRoot))
$OutputXml = Escape-Xml ([System.IO.Path]::GetFullPath($OutputRoot))
$Command = 'powershell.exe -NoProfile -ExecutionPolicy Bypass -File C:\ScreenAgentProject\tests\windows-sandbox\sandbox_bootstrap.ps1'
$Config = @"
<Configuration>
  <VGpu>Disable</VGpu>
  <Networking>Disable</Networking>
  <AudioInput>Disable</AudioInput>
  <VideoInput>Disable</VideoInput>
  <ClipboardRedirection>Disable</ClipboardRedirection>
  <PrinterRedirection>Disable</PrinterRedirection>
  <MemoryInMB>$MemoryInMB</MemoryInMB>
  <MappedFolders>
    <MappedFolder>
      <HostFolder>$ProjectXml</HostFolder>
      <SandboxFolder>C:\ScreenAgentProject</SandboxFolder>
      <ReadOnly>true</ReadOnly>
    </MappedFolder>
    <MappedFolder>
      <HostFolder>$OutputXml</HostFolder>
      <SandboxFolder>C:\ScreenAgentOutput</SandboxFolder>
      <ReadOnly>false</ReadOnly>
    </MappedFolder>
  </MappedFolders>
  <LogonCommand>
    <Command>$Command</Command>
  </LogonCommand>
</Configuration>
"@

$Utf8Bom = New-Object System.Text.UTF8Encoding($true)
[System.IO.File]::WriteAllText($ConfigPath, $Config, $Utf8Bom)
try {
    Write-Host 'Starting a fresh Windows Sandbox with networking disabled...' -ForegroundColor Cyan
    Start-Process -FilePath $SandboxExe -ArgumentList ('"{0}"' -f $ConfigPath) -Wait | Out-Null
    $StatusPath = Join-Path $OutputRoot 'windows-sandbox-status.txt'
    if (-not (Test-Path -LiteralPath $StatusPath -PathType Leaf)) {
        throw "Windows Sandbox closed without a status file. See: $OutputRoot"
    }
    $Status = (Get-Content -LiteralPath $StatusPath -Raw).Trim()
    if ($Status -ne 'PASSED') {
        $ErrorPath = Join-Path $OutputRoot 'windows-sandbox-error.txt'
        throw "Windows Sandbox acceptance failed. See: $ErrorPath"
    }
    Write-Host "Windows Sandbox acceptance passed. Output: $OutputRoot" -ForegroundColor Green
}
finally {
    Remove-Item -LiteralPath $ConfigPath -Force -ErrorAction SilentlyContinue
}
