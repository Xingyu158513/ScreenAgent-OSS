param(
    [string]$PackageZip,
    [string]$EnvironmentLabel = 'temporary-profile harness (not a Windows account or VM)',
    [string]$ReportPath
)

$ErrorActionPreference = 'Stop'
$ProjectRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
if ([string]::IsNullOrWhiteSpace($PackageZip)) {
    $PackageZip = Join-Path $ProjectRoot 'dist\ScreenAgent-1.1.0-rc1-Windows.zip'
}
if ([string]::IsNullOrWhiteSpace($ReportPath)) {
    $ReportPath = Join-Path $ProjectRoot 'dist\ScreenAgent-1.1.0-rc1-acceptance-report.md'
}
if (-not (Test-Path -LiteralPath $PackageZip -PathType Leaf)) { throw "Package not found: $PackageZip" }

$TestRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('screenagent-acceptance-' + [guid]::NewGuid().ToString('N'))
$PackageRoot = Join-Path $TestRoot 'package'
$InstallRoot = Join-Path $TestRoot 'profile\ScreenAgent'
$FakeRemote = Join-Path $TestRoot 'fake-remote'
$FakeTool = Join-Path $TestRoot 'fake-rclone'
$Evidence = Join-Path $TestRoot 'evidence'
$UnattendedConfig = Join-Path $TestRoot 'acceptance-config.json'
$Results = [ordered]@{}

function Assert-Acceptance {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
}

try {
    New-Item -ItemType Directory -Force -Path $PackageRoot, $InstallRoot, $FakeRemote, $FakeTool, $Evidence | Out-Null
    Expand-Archive -LiteralPath $PackageZip -DestinationPath $PackageRoot
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'fake_rclone.ps1') -Destination $FakeTool
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'fake_rclone.cmd') -Destination $FakeTool
    $FakeRclone = Join-Path $FakeTool 'fake_rclone.cmd'

    $Config = [ordered]@{
        product_name = 'ScreenAgent-Acceptance'
        base_dir = $InstallRoot
        obs_exe = ''
        rclone_exe = $FakeRclone
        rclone_config_path = (Join-Path $InstallRoot 'config\rclone.conf')
        remote_name = 'screenagent'
        cloud_folder_name = 'acceptance'
        remote_root = 'screenagent:acceptance'
        cleanup_mode = 'move_after_verified_upload'
        scan_interval_seconds = 5
        stable_seconds = 5
        cloud_type = 'webdav'
        shortcut_name = '启动录制-ScreenAgent-Acceptance'
        config_version = 4
    }
    $Utf8Bom = New-Object System.Text.UTF8Encoding($true)
    [System.IO.File]::WriteAllText($UnattendedConfig, ($Config | ConvertTo-Json -Depth 5), $Utf8Bom)

    $env:SCREENAGENT_ACCEPTANCE_MODE = '1'
    $env:SCREENAGENT_INSTALL_ROOT = $InstallRoot
    $env:SCREENAGENT_UNATTENDED_CONFIG = $UnattendedConfig
    $env:SCREENAGENT_ACCEPTANCE_SKIP_TASK = '1'
    $env:SCREENAGENT_FAKE_REMOTE_ROOT = $FakeRemote
    $env:SCREENAGENT_CONFIG_PATH = Join-Path $InstallRoot 'config\config.json'

    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PackageRoot 'install.ps1')
    if ($LASTEXITCODE -ne 0) { throw "Acceptance install failed: $LASTEXITCODE" }
    Assert-Acceptance (Test-Path -LiteralPath (Join-Path $InstallRoot 'app\session_worker.ps1')) 'Installed session worker is missing.'
    Assert-Acceptance (Test-Path -LiteralPath (Join-Path $InstallRoot 'app\recover_pending.ps1')) 'Installed recovery command is missing.'
    Assert-Acceptance (Test-Path -LiteralPath (Join-Path $InstallRoot 'desktop\启动录制-ScreenAgent-Acceptance.lnk')) 'Acceptance shortcut is missing.'
    $ShortcutFiles = @(Get-ChildItem -LiteralPath (Join-Path $InstallRoot 'desktop') -Filter '*.lnk')
    $ShortcutShell = New-Object -ComObject WScript.Shell
    $RecoveryShortcuts = @($ShortcutFiles | Where-Object { $ShortcutShell.CreateShortcut($_.FullName).Arguments -match 'recover_pending\.ps1' })
    Assert-Acceptance ($RecoveryShortcuts.Count -eq 1) 'Exactly one recovery shortcut must target recover_pending.ps1.'
    New-Item -ItemType File -Force -Path (Join-Path $InstallRoot 'config\rclone.conf') | Out-Null
    $Results.Install = 'passed (temporary root and shortcuts)'

    $RawDir = Join-Path $InstallRoot 'recordings\raw'
    $UploadedDir = Join-Path $InstallRoot 'recordings\uploaded'
    $LogsDir = Join-Path $InstallRoot 'logs'

    $FailureSource = Join-Path $RawDir 'failure.mkv'
    [System.IO.File]::WriteAllBytes($FailureSource, [byte[]](1..64))
    $env:SCREENAGENT_FAKE_RCLONE_MODE = 'fail_upload'
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $InstallRoot 'app\recover_pending.ps1')
    if ($LASTEXITCODE -ne 0) { throw "Failure scenario worker exited unexpectedly: $LASTEXITCODE" }
    $Retained = @(Get-ChildItem -LiteralPath $RawDir -File)
    Assert-Acceptance ($Retained.Count -eq 1) 'Upload failure did not retain exactly one local recording.'
    Assert-Acceptance (@(Get-ChildItem -LiteralPath $UploadedDir -File).Count -eq 0) 'Upload failure unexpectedly moved a local recording.'
    Move-Item -LiteralPath $Retained[0].FullName -Destination (Join-Path $Evidence 'failure-retained.mkv')
    $Results.UploadFailure = 'passed (local file retained; uploaded directory unchanged)'

    $SuccessSource = Join-Path $RawDir 'success.mkv'
    [System.IO.File]::WriteAllBytes($SuccessSource, [byte[]](65..128))
    $env:SCREENAGENT_FAKE_RCLONE_MODE = 'success'
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $InstallRoot 'app\recover_pending.ps1')
    if ($LASTEXITCODE -ne 0) { throw "Success scenario worker exited unexpectedly: $LASTEXITCODE" }
    Assert-Acceptance (@(Get-ChildItem -LiteralPath $RawDir -File).Count -eq 0) 'Verified upload left a file in raw.'
    $Uploaded = @(Get-ChildItem -LiteralPath $UploadedDir -File)
    $RemoteFiles = @(Get-ChildItem -LiteralPath $FakeRemote -Recurse -File)
    Assert-Acceptance ($Uploaded.Count -eq 1) 'Verified upload did not move exactly one local recording.'
    Assert-Acceptance ($RemoteFiles.Count -eq 1) 'Fake remote did not receive exactly one recording.'
    Assert-Acceptance ($Uploaded[0].Length -eq $RemoteFiles[0].Length) 'Local and remote file sizes differ after verification.'
    $Results.VerifiedMove = 'passed (same-name same-size remote check, local move, byte count preserved)'

    $env:SCREENAGENT_UNINSTALL_DELETE_APP = '1'
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $InstallRoot 'app\uninstall.ps1')
    if ($LASTEXITCODE -ne 0) { throw "Acceptance uninstall failed: $LASTEXITCODE" }
    Assert-Acceptance (-not (Test-Path -LiteralPath (Join-Path $InstallRoot 'app'))) 'Program app directory remained after confirmed uninstall.'
    Assert-Acceptance (Test-Path -LiteralPath $Uploaded[0].FullName) 'Uninstall removed the uploaded recording.'
    Assert-Acceptance (Test-Path -LiteralPath (Join-Path $InstallRoot 'config\config.json')) 'Uninstall removed configuration.'
    Assert-Acceptance (Test-Path -LiteralPath $LogsDir) 'Uninstall removed logs.'
    $Results.Uninstall = 'passed (program removed; recordings, config, and logs preserved)'

    $Lines = @(
        '# ScreenAgent acceptance report',
        '',
        "- Timestamp: $((Get-Date).ToString('s'))",
        "- Environment: $EnvironmentLabel",
        "- Package: $([System.IO.Path]::GetFileName($PackageZip))",
        "- Package SHA-256: $((Get-FileHash -LiteralPath $PackageZip -Algorithm SHA256).Hash.ToLowerInvariant())",
        '- Real credentials used: no',
        '- Real WebDAV service used: no (deterministic fake rclone)',
        '- Real scheduled task created: no',
        '',
        '## Results',
        ''
    )
    foreach ($Key in $Results.Keys) { $Lines += "- ${Key}: $($Results[$Key])" }
    $Lines += @('', '## Limitations', '', '- This report does not replace a run in a separate Windows account or VM.', '- OBS launch, real WebDAV authentication, and real Task Scheduler registration remain unverified here.')
    [System.IO.File]::WriteAllLines($ReportPath, $Lines, $Utf8Bom)
    Write-Host "Acceptance report: $ReportPath" -ForegroundColor Green
}
finally {
    Remove-Item Env:SCREENAGENT_ACCEPTANCE_MODE,Env:SCREENAGENT_INSTALL_ROOT,Env:SCREENAGENT_UNATTENDED_CONFIG,Env:SCREENAGENT_ACCEPTANCE_SKIP_TASK,Env:SCREENAGENT_FAKE_REMOTE_ROOT,Env:SCREENAGENT_CONFIG_PATH,Env:SCREENAGENT_FAKE_RCLONE_MODE,Env:SCREENAGENT_UNINSTALL_DELETE_APP -ErrorAction SilentlyContinue
    if (Test-Path -LiteralPath $TestRoot) { Remove-Item -LiteralPath $TestRoot -Recurse -Force -ErrorAction SilentlyContinue }
}
