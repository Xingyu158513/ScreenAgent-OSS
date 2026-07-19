$ErrorActionPreference = 'Stop'

$SecurityModule = Join-Path $PSScriptRoot 'lib\ScreenAgent.Security.psm1'
if (-not (Test-Path -LiteralPath $SecurityModule)) {
    throw "安全模块不存在：$SecurityModule"
}
Import-Module $SecurityModule -Force

function Write-Title {
    param([string]$Message)
    Write-Host ''
    Write-Host $Message -ForegroundColor Green
}

function Write-Step {
    param([string]$Message)
    Write-Host "[ScreenAgent] $Message" -ForegroundColor Cyan
}

function Read-Default {
    param([string]$Prompt, [string]$Default)
    $Value = Read-Host "$Prompt [$Default]"
    if ([string]::IsNullOrWhiteSpace($Value)) { return $Default }
    return $Value.Trim()
}

function Read-Required {
    param([string]$Prompt)
    while ($true) {
        $Value = Read-Host $Prompt
        if (-not [string]::IsNullOrWhiteSpace($Value)) { return $Value.Trim() }
        Write-Host '不能为空，请重新输入。' -ForegroundColor Yellow
    }
}

function Get-SafeAsciiName {
    param([string]$Name)
    $Lower = ($Name -replace '[^A-Za-z0-9_-]', '').ToLowerInvariant()
    if ([string]::IsNullOrWhiteSpace($Lower)) { return 'screenagent' }
    if ($Lower -notmatch '^[a-z]') { $Lower = 'screenagent' + $Lower }
    return $Lower
}

function Find-Rclone {
    $Candidates = @(
        (Join-Path $PSScriptRoot 'rclone.exe'),
        (Join-Path $PSScriptRoot 'tools\rclone.exe'),
        'C:\Tools\rclone\rclone.exe'
    )
    foreach ($Candidate in $Candidates) {
        if (Test-Path -LiteralPath $Candidate) { return $Candidate }
    }
    $Cmd = Get-Command rclone.exe -ErrorAction SilentlyContinue
    if ($Cmd) { return $Cmd.Source }
    return $null
}

function Find-Obs {
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

function Invoke-RcloneConfigCreate {
    param(
        [string]$RclonePath,
        [string]$RcloneConfigPath,
        [string]$RemoteName,
        [string]$Url,
        [string]$UserName,
        [string]$ObscuredPassword,
        [string]$Vendor
    )
    Write-Step "自动写入 rclone WebDAV 配置：$RemoteName"
    $Args = @(
        '--config', $RcloneConfigPath,
        'config', 'create', $RemoteName, 'webdav',
        'url', $Url,
        'vendor', $Vendor,
        'user', $UserName,
        'pass', $ObscuredPassword,
        '--no-obscure',
        '--non-interactive'
    )
    & $RclonePath @Args
    if ($LASTEXITCODE -ne 0) {
        throw "rclone 配置失败，退出码：$LASTEXITCODE"
    }
}

function Test-AndCreateRemoteRoot {
    param([string]$RclonePath, [string]$RcloneConfigPath, [string]$RemoteRoot)
    Write-Step "创建云端文件夹：$RemoteRoot"
    & $RclonePath --config $RcloneConfigPath mkdir $RemoteRoot | Out-Host
    if ($LASTEXITCODE -ne 0) { throw "云端文件夹创建失败：$RemoteRoot" }

    Write-Step "测试云端访问：$RemoteRoot"
    & $RclonePath --config $RcloneConfigPath lsd $RemoteRoot | Out-Host
    if ($LASTEXITCODE -ne 0) { throw "云端访问失败：$RemoteRoot" }
}

function Test-WritableDirectory {
    param([string]$Directory)
    New-Item -ItemType Directory -Force -Path $Directory | Out-Null
    $TestFile = Join-Path $Directory ('write-test-' + [guid]::NewGuid().ToString('N') + '.tmp')
    'ok' | Set-Content -LiteralPath $TestFile -Encoding UTF8
    Remove-Item -LiteralPath $TestFile -Force
}

function Show-ObsGuide {
    param([string]$RawDir)
    Write-Title 'OBS 录制路径设置'
    Write-Host "请在 OBS 中设置录制路径为：$RawDir"
    Write-Host '建议录制格式：mkv'
    Write-Host ''
    Write-Host '如果 OBS 预览黑屏，请尝试：'
    Write-Host '1. 用管理员身份启动 OBS'
    Write-Host '2. 重新添加“显示器采集”'
    Write-Host '3. 右键采集源，选择“变换 > 适应屏幕”'
    Write-Host '4. Windows 设置中将 OBS 图形性能设为“高性能”'
}

function Start-ObsTestRecording {
    param([string]$ObsPath)
    if (-not (Test-Path -LiteralPath $ObsPath)) {
        Write-Host '未找到 OBS，跳过测试录制。' -ForegroundColor Yellow
        return
    }
    $Choice = Read-Host '是否启动 5 秒 OBS 测试录制？输入 y 开始，其他跳过'
    if ($Choice -ne 'y' -and $Choice -ne 'Y') { return }
    $Proc = Start-Process -FilePath $ObsPath -ArgumentList '--startrecording' -PassThru
    Start-Sleep -Seconds 5
    try {
        if (-not $Proc.HasExited) {
            $Proc.CloseMainWindow() | Out-Null
            Start-Sleep -Seconds 5
        }
        if (-not $Proc.HasExited) {
            Write-Host 'OBS 仍在运行。请手动停止录制并关闭 OBS。' -ForegroundColor Yellow
        }
    }
    catch {
        Write-Host "测试录制结束处理失败：$($_.Exception.Message)" -ForegroundColor Yellow
    }
}

function Write-InstallReport {
    param($Config, [string]$ReportPath, [string]$ShortcutName)
    $Strategy = switch ($Config.cleanup_mode) {
        'keep_local' { '保留模式：云端验证成功后仍保留本地视频' }
        default { '安全模式：云端验证成功后移动到 uploaded 文件夹' }
    }
    $Lines = @(
        "# ScreenAgent 安装报告",
        "",
        "- 产品名称：$($Config.product_name)",
        "- 本地目录：$($Config.base_dir)",
        "- OBS 路径：$($Config.obs_exe)",
        "- 录制目录：$(Join-Path $Config.base_dir 'recordings\raw')",
        "- 云端路径：$($Config.remote_root)",
        "- 后台处理：开始录制时按需启动，处理完成后自动退出",
        "- 本地处理策略：$Strategy",
        "",
        "## 如何启动",
        "",
        "双击桌面快捷方式：$ShortcutName",
        "",
        "## 如何查看日志",
        "",
        "双击桌面快捷方式：查看 $($Config.product_name) 日志",
        "",
        "日志目录：$(Join-Path $Config.base_dir 'logs')",
        "",
        "## 如何卸载",
        "",
        "双击安装包里的 uninstall.bat，或运行：",
        "",
        '```powershell',
        "powershell.exe -NoProfile -ExecutionPolicy Bypass -File `"$(Join-Path $Config.base_dir 'app\uninstall.ps1')`"",
        '```',
        "",
        "注意：本报告不包含任何密码。"
    )
    $Utf8Bom = New-Object System.Text.UTF8Encoding($true)
    [System.IO.File]::WriteAllText($ReportPath, ($Lines -join "`r`n"), $Utf8Bom)
}

$Root = Join-Path $env:USERPROFILE 'ScreenAgent'
$ConfigDir = Join-Path $Root 'config'
$RawDir = Join-Path $Root 'recordings\raw'
$UploadedDir = Join-Path $Root 'recordings\uploaded'
$LogsDir = Join-Path $Root 'logs'
$SessionsDir = Join-Path $Root 'sessions'
$ConfigPath = Join-Path $ConfigDir 'config.json'
$RcloneConfigPath = Join-Path $ConfigDir 'rclone.conf'
$ReportPath = Join-Path $ConfigDir 'install_report.md'

New-Item -ItemType Directory -Force -Path $ConfigDir, $RawDir, $UploadedDir, $LogsDir, $SessionsDir | Out-Null
Test-WritableDirectory -Directory $Root

Write-Title 'ScreenAgent 配置向导'
$ProductName = ConvertTo-ScreenAgentSafeSegment -Value (Read-Default '产品显示名称' 'ScreenAgent') -Fallback 'ScreenAgent'
$CloudFolderName = ConvertTo-ScreenAgentSafeSegment -Value (Read-Default '云端文件夹名称' $ProductName) -Fallback 'ScreenAgent'
$ShortcutName = ConvertTo-ScreenAgentSafeSegment -Value (Read-Default '桌面快捷方式名称' ("启动录制-$ProductName")) -Fallback '启动录制-ScreenAgent'
$RemoteName = Get-SafeAsciiName $ProductName
if ($RemoteName -eq 'screenagent') { $RemoteName = 'screenagent' }
else { $RemoteName = 'screenagent_' + $RemoteName }

Write-Title '选择保存方式'
Write-Host '1. 坚果云 WebDAV'
Write-Host '2. 通用 WebDAV'
Write-Host '3. 只保存本地'
$ModeChoice = Read-Default '请输入 1/2/3' '1'

$Mode = 'nutstore_webdav'
$RclonePath = Find-Rclone
$RemoteRoot = ''
$CloudType = 'nutstore'

if ($ModeChoice -eq '3') {
    $Mode = 'local_only'
    $CloudType = 'local'
}
elseif ($ModeChoice -eq '2') {
    $Mode = 'generic_webdav'
    $CloudType = 'webdav'
}

if ($Mode -ne 'local_only') {
    if (-not $RclonePath) {
        Write-Host '未找到 rclone.exe。' -ForegroundColor Red
        Write-Host '请将 rclone.exe 放到 C:\Tools\rclone\rclone.exe，或使用内置 rclone 的产品包。'
        Write-Host '下载地址：https://rclone.org/downloads/'
        exit 1
    }
    Write-Step "检测到 rclone：$RclonePath"
    if ($Mode -eq 'nutstore_webdav') {
        Write-Title '坚果云授权'
        Write-Host '请先到坚果云网页版生成“第三方应用密码”。'
        Write-Host '不要输入坚果云登录密码，建议输入第三方应用密码。'
        $Url = 'https://dav.jianguoyun.com/dav/'
        $Vendor = 'other'
        $UserName = Read-Required '坚果云账号'
        $SecurePassword = Read-Host '坚果云第三方应用密码（不会写入 ScreenAgent 配置文件）' -AsSecureString
    }
    else {
        $Url = Read-Required 'WebDAV 地址'
        $Url = Assert-ScreenAgentHttpsUrl -Url $Url
        $Vendor = Read-Default 'WebDAV vendor，通常填 other' 'other'
        $UserName = Read-Required 'WebDAV 用户名'
        $SecurePassword = Read-Host 'WebDAV 密码或应用密码（不会写入 ScreenAgent 配置文件）' -AsSecureString
    }
    $ObscuredPassword = ConvertTo-RcloneObscuredPassword -RclonePath $RclonePath -SecurePassword $SecurePassword
    Invoke-RcloneConfigCreate -RclonePath $RclonePath -RcloneConfigPath $RcloneConfigPath -RemoteName $RemoteName -Url $Url -UserName $UserName -ObscuredPassword $ObscuredPassword -Vendor $Vendor
    $ObscuredPassword = $null
    Protect-ScreenAgentCredentialFile -Path $RcloneConfigPath
    $RemoteRoot = "$RemoteName`:$CloudFolderName"
    Test-AndCreateRemoteRoot -RclonePath $RclonePath -RcloneConfigPath $RcloneConfigPath -RemoteRoot $RemoteRoot
}

Write-Title '本地处理策略'
Write-Host '1. 安全模式：上传验证成功后移动到 uploaded 文件夹（默认）'
Write-Host '2. 保留本地视频'
Write-Host '公开版不提供自动永久删除。'
$CleanupChoice = Read-Default '请输入 1/2' '1'
$CleanupMode = 'move_after_verified_upload'
if ($CleanupChoice -eq '2') { $CleanupMode = 'keep_local' }

$ObsPath = Find-Obs
if ($ObsPath) {
    Write-Step "检测到 OBS：$ObsPath"
}
else {
    Write-Host '未自动检测到 OBS。' -ForegroundColor Yellow
    $ObsPath = Read-Default '请输入 obs64.exe 完整路径；暂时没有可直接回车' ''
}

Show-ObsGuide -RawDir $RawDir
if (-not [string]::IsNullOrWhiteSpace($ObsPath)) {
    Start-ObsTestRecording -ObsPath $ObsPath
}

$Config = [ordered]@{
    product_name = $ProductName
    base_dir = $Root
    obs_exe = $ObsPath
    rclone_exe = $RclonePath
    rclone_config_path = if ($Mode -eq 'local_only') { '' } else { $RcloneConfigPath }
    remote_name = $RemoteName
    cloud_folder_name = $CloudFolderName
    remote_root = $RemoteRoot
    cleanup_mode = $CleanupMode
    scan_interval_seconds = 15
    stable_seconds = 12
    cloud_type = $CloudType
    shortcut_name = $ShortcutName
    config_version = 4
}

$Utf8Bom = New-Object System.Text.UTF8Encoding($true)
[System.IO.File]::WriteAllText($ConfigPath, ($Config | ConvertTo-Json -Depth 5), $Utf8Bom)
Write-InstallReport -Config ([pscustomobject]$Config) -ReportPath $ReportPath -ShortcutName $ShortcutName

Write-Host ''
Write-Host "配置已写入：$ConfigPath" -ForegroundColor Green
Write-Host "安装报告已生成：$ReportPath" -ForegroundColor Green
