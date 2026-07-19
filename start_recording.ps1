$ErrorActionPreference = 'Stop'

function Read-Default {
    param([string]$Prompt, [string]$Default)
    $Value = Read-Host "$Prompt [$Default]"
    if ([string]::IsNullOrWhiteSpace($Value)) { return $Default }
    return $Value.Trim()
}

function Get-CleanupMode {
    Write-Host ''
    Write-Host '上传成功并完成云端验证后，如何处理本地视频？'
    Write-Host '1. 安全模式：移动到 uploaded 文件夹（默认）'
    Write-Host '2. 保留本地视频'
    Write-Host '公开版不提供自动永久删除。'
    $Choice = Read-Default '请选择 1/2' '1'
    if ($Choice -eq '2') { return 'keep_local' }
    return 'move_after_verified_upload'
}

function Load-Config {
    $Root = Join-Path $env:USERPROFILE 'ScreenAgent'
    $ConfigPath = Join-Path $Root 'config\config.json'
    if (-not (Test-Path -LiteralPath $ConfigPath)) {
        throw "找不到配置文件：$ConfigPath。请先运行 config_wizard.ps1。"
    }
    return Get-Content -LiteralPath $ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
}

function Find-Obs {
    param($Config)
    if ($Config.obs_path -and (Test-Path -LiteralPath $Config.obs_path)) {
        return [string]$Config.obs_path
    }
    if ($Config.obs_exe -and (Test-Path -LiteralPath $Config.obs_exe)) {
        return [string]$Config.obs_exe
    }
    $Candidates = @(
        'C:\Program Files\obs-studio\bin\64bit\obs64.exe',
        'C:\Program Files (x86)\obs-studio\bin\64bit\obs64.exe'
    )
    foreach ($Candidate in $Candidates) {
        if (Test-Path -LiteralPath $Candidate) { return $Candidate }
    }
    $Cmd = Get-Command obs64.exe -ErrorAction SilentlyContinue
    if ($Cmd) { return $Cmd.Source }
    return $null
}

$Config = Load-Config
$Root = [string]$Config.install_root
if ([string]::IsNullOrWhiteSpace($Root)) { $Root = Join-Path $env:USERPROFILE 'ScreenAgent' }
$Root = [string]$Config.base_dir
if ([string]::IsNullOrWhiteSpace($Root)) { $Root = Join-Path $env:USERPROFILE 'ScreenAgent' }
$SessionDir = [string]$Config.sessions_dir
if ([string]::IsNullOrWhiteSpace($SessionDir)) { $SessionDir = Join-Path $Root 'sessions' }
$RawDir = [string]$Config.raw_dir
if ([string]::IsNullOrWhiteSpace($RawDir)) { $RawDir = Join-Path $Root 'recordings\raw' }

New-Item -ItemType Directory -Force -Path $SessionDir, $RawDir | Out-Null

$Title = Read-Default '请输入本次录制标题' '未命名录屏'
$Category = Read-Default '分类 category' 'study'
$Topic = Read-Default '主题 topic' 'general'
$CleanupMode = Get-CleanupMode

$SessionId = Get-Date -Format 'yyyyMMdd-HHmmss-fff'
$SessionStartedAt = Get-Date
$VideoExtensions = @('.mkv', '.mp4', '.mov')
$BaselineFiles = @(Get-ChildItem -LiteralPath $RawDir -File -ErrorAction SilentlyContinue |
    Where-Object { $VideoExtensions -contains $_.Extension.ToLowerInvariant() } |
    ForEach-Object {
        [ordered]@{
            path = $_.FullName
            length = [Int64]$_.Length
            last_write_utc = $_.LastWriteTimeUtc.ToString('o')
        }
    })
$Session = [ordered]@{
    id = $SessionId
    category = $Category
    topic = $Topic
    title = $Title
    start_time = $SessionStartedAt.ToString('s')
    start_time_utc = $SessionStartedAt.ToUniversalTime().ToString('o')
    status = 'recording'
    cleanup_mode = $CleanupMode
    baseline_files = $BaselineFiles
}

$SessionPath = Join-Path $SessionDir ($SessionId + '.json')
$Utf8Bom = New-Object System.Text.UTF8Encoding($true)
[System.IO.File]::WriteAllText($SessionPath, ($Session | ConvertTo-Json -Depth 5), $Utf8Bom)

$ObsPath = Find-Obs -Config $Config
if (-not $ObsPath) {
    Write-Host ''
    Write-Host '找不到 OBS Studio。' -ForegroundColor Red
    Write-Host '请安装 OBS Studio，或运行 config_wizard.ps1 设置 obs64.exe 路径。'
    Write-Host '常见路径：C:\Program Files\obs-studio\bin\64bit\obs64.exe'
    exit 1
}

Write-Host ''
Write-Host "会话已创建：$SessionId"
Write-Host "录制标题：$Title"
Write-Host "OBS 路径：$ObsPath"
Write-Host "请确认 OBS 录制路径为：$RawDir"
Write-Host ''

$HiddenWorker = Join-Path $PSScriptRoot 'run_session_worker_hidden.vbs'
$WscriptPath = Join-Path $env:SystemRoot 'System32\wscript.exe'
$ObsWorkingDirectory = Split-Path -Parent $ObsPath
try {
    Start-Process -FilePath $ObsPath -WorkingDirectory $ObsWorkingDirectory -ArgumentList '--startrecording' -ErrorAction Stop | Out-Null
}
catch {
    $Session.status = 'obs_start_failed'
    $Session | Add-Member -NotePropertyName worker_reason -NotePropertyValue $_.Exception.Message -Force
    [System.IO.File]::WriteAllText($SessionPath, ($Session | ConvertTo-Json -Depth 5), $Utf8Bom)
    throw "OBS 启动失败：$($_.Exception.Message)"
}

if (-not (Test-Path -LiteralPath $HiddenWorker -PathType Leaf)) {
    Write-Host "后台 worker 启动器不存在：$HiddenWorker" -ForegroundColor Yellow
    Write-Host 'OBS 已开始录制；本次文件将保留在 raw，并可在下次启动时恢复处理。' -ForegroundColor Yellow
    exit 0
}

try {
    $WorkerArguments = '"{0}" "{1}"' -f $HiddenWorker, $SessionPath
    Start-Process -FilePath $WscriptPath -ArgumentList $WorkerArguments -WindowStyle Hidden -ErrorAction Stop | Out-Null
    Write-Host '会话后台处理已启动；录制完成后会自动归档并退出。' -ForegroundColor Green
}
catch {
    $Session.status = 'worker_start_failed'
    $Session | Add-Member -NotePropertyName worker_reason -NotePropertyValue $_.Exception.Message -Force
    [System.IO.File]::WriteAllText($SessionPath, ($Session | ConvertTo-Json -Depth 5), $Utf8Bom)
    Write-Host "后台 worker 启动失败：$($_.Exception.Message)" -ForegroundColor Yellow
    Write-Host 'OBS 已开始录制；本次文件不会自动移动，可在下次启动时恢复处理。' -ForegroundColor Yellow
}
