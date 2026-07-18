$ErrorActionPreference = 'Stop'

function Write-Step {
    param([string]$Message)
    Write-Host "[ScreenAgent] $Message" -ForegroundColor Cyan
}

function Write-Warn {
    param([string]$Message)
    Write-Host "[警告] $Message" -ForegroundColor Yellow
}

function New-Shortcut {
    param(
        [string]$ShortcutPath,
        [string]$TargetPath,
        [string]$Arguments,
        [string]$WorkingDirectory,
        [string]$Description
    )
    $Shell = New-Object -ComObject WScript.Shell
    $Shortcut = $Shell.CreateShortcut($ShortcutPath)
    $Shortcut.TargetPath = $TargetPath
    $Shortcut.Arguments = $Arguments
    $Shortcut.WorkingDirectory = $WorkingDirectory
    $Shortcut.Description = $Description
    $Shortcut.Save()
}

$SecurityModule = Join-Path $PSScriptRoot 'lib\ScreenAgent.Security.psm1'
if (-not (Test-Path -LiteralPath $SecurityModule)) {
    throw "安全模块不存在：$SecurityModule"
}
Import-Module $SecurityModule -Force

$PackageDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$AcceptanceMode = $env:SCREENAGENT_ACCEPTANCE_MODE -eq '1'
$Root = Resolve-ScreenAgentInstallRoot `
    -DefaultRoot (Join-Path $env:USERPROFILE 'ScreenAgent') `
    -AcceptanceMode $AcceptanceMode `
    -RequestedRoot $env:SCREENAGENT_INSTALL_ROOT
$AppDir = Join-Path $Root 'app'
$ConfigDir = Join-Path $Root 'config'
$DocsDir = Join-Path $Root 'docs'
$Desktop = if ($AcceptanceMode) { Join-Path $Root 'desktop' } else { [Environment]::GetFolderPath('Desktop') }
$TaskName = 'ScreenAgent-AutoUpload'

Write-Host ''
Write-Host 'ScreenAgent 安装程序' -ForegroundColor Green
Write-Host '安装目录：' $Root
Write-Host ''

if ($AcceptanceMode -and $env:SCREENAGENT_ACCEPTANCE_SKIP_TASK -eq '1') {
    Write-Warn '验收模式：跳过真实计划任务迁移。'
}
else {
    Write-Step '检查并移除旧版后台计划任务'
    $TaskMigration = Remove-ScreenAgentKnownScheduledTask -ScreenAgentRoot $Root -TaskName $TaskName
    if ($TaskMigration.Removed) {
        Write-Step "已移除旧后台任务（$($TaskMigration.ActionKind)）"
    }
}

$LegacyWorkerMigration = Move-ScreenAgentLegacyWorkerToBackup -ScreenAgentRoot $Root
if ($LegacyWorkerMigration.Moved) {
    Write-Step "已隔离旧删除脚本：$($LegacyWorkerMigration.Destination)"
}

Write-Step '创建目录结构'
$Dirs = @(
    $Root,
    $AppDir,
    $ConfigDir,
    $DocsDir,
    $Desktop,
    (Join-Path $Root 'recordings'),
    (Join-Path $Root 'recordings\raw'),
    (Join-Path $Root 'recordings\uploaded'),
    (Join-Path $Root 'logs'),
    (Join-Path $Root 'sessions')
)
foreach ($Dir in $Dirs) {
    New-Item -ItemType Directory -Force -Path $Dir | Out-Null
}

Write-Step '复制程序文件'
$Files = @(
    'config_wizard.ps1',
    'start_recording.ps1',
    'auto_archive.ps1',
    'uninstall.ps1',
    'view_logs.ps1',
    'run_auto_archive_hidden.vbs',
    'README.md',
    '版本信息.json',
    '发行说明.md'
)
foreach ($File in $Files) {
    Copy-Item -LiteralPath (Join-Path $PackageDir $File) -Destination (Join-Path $AppDir $File) -Force
}
if (Test-Path -LiteralPath (Join-Path $PackageDir 'lib')) {
    Copy-Item -Path (Join-Path $PackageDir 'lib') -Destination $AppDir -Recurse -Force
}
if (Test-Path -LiteralPath (Join-Path $PackageDir 'docs')) {
    Copy-Item -Path (Join-Path $PackageDir 'docs\*') -Destination $DocsDir -Recurse -Force
}
if (Test-Path -LiteralPath (Join-Path $PackageDir 'config\config.json')) {
    Copy-Item -LiteralPath (Join-Path $PackageDir 'config\config.json') -Destination (Join-Path $ConfigDir 'config.template.json') -Force
}

$ConfigPath = Join-Path $ConfigDir 'config.json'
if (Test-Path -LiteralPath $ConfigPath -PathType Leaf) {
    Write-Step '检测到现有配置，升级时予以保留'
}
elseif ($AcceptanceMode -and -not [string]::IsNullOrWhiteSpace($env:SCREENAGENT_UNATTENDED_CONFIG)) {
    Write-Step '验收模式：导入非交互测试配置'
    Copy-Item -LiteralPath $env:SCREENAGENT_UNATTENDED_CONFIG -Destination $ConfigPath -Force
}
else {
    Write-Step '启动配置向导'
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $AppDir 'config_wizard.ps1')
    if ($LASTEXITCODE -ne 0) {
        throw '配置向导未成功完成。'
    }
}

if (-not (Test-Path -LiteralPath $ConfigPath)) {
    throw "配置文件未生成：$ConfigPath"
}
$Config = Get-Content -LiteralPath $ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
$TaskName = 'ScreenAgent-AutoUpload'
$ShortcutBaseName = ConvertTo-ScreenAgentSafeSegment -Value ([string]$Config.shortcut_name) -Fallback '启动录制-ScreenAgent'
$ProductName = ConvertTo-ScreenAgentSafeSegment -Value ([string]$Config.product_name) -Fallback 'ScreenAgent'

Write-Step '创建桌面快捷方式'
$StartShortcut = Join-Path $Desktop ($ShortcutBaseName + '.lnk')
$LogShortcut = Join-Path $Desktop ("查看 $ProductName 日志.lnk")
New-Shortcut `
    -ShortcutPath $StartShortcut `
    -TargetPath 'powershell.exe' `
    -Arguments ('-NoProfile -ExecutionPolicy Bypass -File "{0}"' -f (Join-Path $AppDir 'start_recording.ps1')) `
    -WorkingDirectory $AppDir `
    -Description '启动 ScreenAgent OBS 录屏'
New-Shortcut `
    -ShortcutPath $LogShortcut `
    -TargetPath 'powershell.exe' `
    -Arguments ('-NoProfile -ExecutionPolicy Bypass -File "{0}"' -f (Join-Path $AppDir 'view_logs.ps1')) `
    -WorkingDirectory $AppDir `
    -Description "查看 $ProductName 日志"

Write-Step '未创建开机常驻任务；后台处理将在录制会话中按需启动'

Write-Host ''
Write-Host '安装完成。' -ForegroundColor Green
Write-Host '请确认 OBS 录制路径设置为：' (Join-Path $Root 'recordings\raw')
$InstallReport = Join-Path $ConfigDir 'install_report.md'
if (Test-Path -LiteralPath $InstallReport) { Write-Host '安装报告：' $InstallReport }
Write-Host ''
