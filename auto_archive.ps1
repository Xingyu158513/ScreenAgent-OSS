$ErrorActionPreference = 'Continue'

$SecurityModule = Join-Path $PSScriptRoot 'lib\ScreenAgent.Security.psm1'
if (-not (Test-Path -LiteralPath $SecurityModule)) {
    throw "安全模块不存在：$SecurityModule"
}
Import-Module $SecurityModule -Force

function Get-NowText { return (Get-Date).ToString('yyyy-MM-dd HH:mm:ss') }

function Write-AgentMessage {
    param([string]$Message)
    Write-Host ("[{0}] {1}" -f (Get-NowText), $Message)
}

function ConvertTo-CsvField {
    param([object]$Value)
    $Text = ''
    if ($null -ne $Value) { $Text = [string]$Value }
    $Text = $Text.Replace('"', '""')
    return '"' + $Text + '"'
}

function Initialize-Log {
    if (-not (Test-Path -LiteralPath $script:CsvLog)) {
        'id,start_time,end_time,category,topic,title,remote_path,local_path,local_deleted,status,reason' | Set-Content -LiteralPath $script:CsvLog -Encoding UTF8
    }
    if (-not (Test-Path -LiteralPath $script:ReportLog)) {
        "ScreenAgent 日志`r`n" | Set-Content -LiteralPath $script:ReportLog -Encoding UTF8
    }
    if (-not (Test-Path -LiteralPath $script:ProcessedFile)) {
        New-Item -ItemType File -Path $script:ProcessedFile -Force | Out-Null
    }
}

function Write-Report {
    param([string]$Message)
    Add-Content -LiteralPath $script:ReportLog -Encoding UTF8 -Value ("[{0}] {1}" -f (Get-NowText), $Message)
}

function Write-IndexLog {
    param(
        [string]$Id,
        [string]$StartTime,
        [string]$EndTime,
        [string]$Category,
        [string]$Topic,
        [string]$Title,
        [string]$RemotePath,
        [string]$LocalPath,
        [string]$LocalDeleted,
        [string]$Status,
        [string]$Reason
    )
    $Fields = @($Id, $StartTime, $EndTime, $Category, $Topic, $Title, $RemotePath, $LocalPath, $LocalDeleted, $Status, $Reason)
    $Line = ($Fields | ForEach-Object { ConvertTo-CsvField $_ }) -join ','
    Add-Content -LiteralPath $script:CsvLog -Encoding UTF8 -Value $Line
    $Human = "标题=$Title；状态=$Status；远程=$RemotePath；本地=$LocalPath；原因=$Reason"
    Write-Report $Human
}

function Get-SafeName {
    param([string]$Name)
    return ConvertTo-ScreenAgentSafeSegment -Value $Name -Fallback '未命名录屏'
}

function Join-RemotePath {
    param([string]$Base, [string]$Child)
    $Base = $Base.TrimEnd('/')
    $Child = $Child.TrimStart('/')
    return "$Base/$Child"
}

function Load-Config {
    $Root = Join-Path $env:USERPROFILE 'ScreenAgent'
    $ConfigPath = Join-Path $Root 'config\config.json'
    if ($env:SCREENAGENT_ACCEPTANCE_MODE -eq '1' -and -not [string]::IsNullOrWhiteSpace($env:SCREENAGENT_CONFIG_PATH)) {
        $ConfigPath = [System.IO.Path]::GetFullPath($env:SCREENAGENT_CONFIG_PATH)
    }
    if (-not (Test-Path -LiteralPath $ConfigPath)) {
        throw "找不到配置文件：$ConfigPath"
    }
    return Get-Content -LiteralPath $ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
}

function Get-CurrentSession {
    $Fallback = [ordered]@{
        id = (Get-Date -Format 'yyyyMMdd-HHmmss')
        category = 'recovered'
        topic = 'unknown'
        title = '恢复的录屏'
        start_time = (Get-Date).ToString('s')
        cleanup_mode = $script:DefaultCleanupMode
        is_recovered = $true
    }
    if (-not (Test-Path -LiteralPath $script:CurrentSessionPath)) {
        return $Fallback
    }
    try {
        $SessionFile = Get-Item -LiteralPath $script:CurrentSessionPath -ErrorAction Stop
        if ($SessionFile.LastWriteTime -lt (Get-Date).AddHours(-1 * $script:SessionStaleHours)) {
            Write-AgentMessage 'current_session.json 超过 stale 时间，raw 残留文件按 recovered 处理。'
            return $Fallback
        }
        $Session = Get-Content -LiteralPath $script:CurrentSessionPath -Raw -Encoding UTF8 | ConvertFrom-Json
        if (-not $Session.id) { $Session | Add-Member -NotePropertyName id -NotePropertyValue (Get-Date -Format 'yyyyMMdd-HHmmss') }
        if (-not $Session.category) { $Session | Add-Member -NotePropertyName category -NotePropertyValue 'recovered' }
        if (-not $Session.topic) { $Session | Add-Member -NotePropertyName topic -NotePropertyValue 'unknown' }
        if (-not $Session.title) { $Session | Add-Member -NotePropertyName title -NotePropertyValue '未分类录屏' }
        if (-not $Session.start_time) { $Session | Add-Member -NotePropertyName start_time -NotePropertyValue (Get-Date).ToString('s') }
        if (-not $Session.cleanup_mode) { $Session | Add-Member -NotePropertyName cleanup_mode -NotePropertyValue $script:DefaultCleanupMode }
        return $Session
    }
    catch {
        Write-AgentMessage "读取 session 失败，按 recovered 处理：$($_.Exception.Message)"
        return $Fallback
    }
}

function Test-FileStable {
    param([string]$Path)
    try {
        if (-not (Test-Path -LiteralPath $Path)) { return $false }
        $First = (Get-Item -LiteralPath $Path -ErrorAction Stop).Length
        Start-Sleep -Seconds $script:StableSeconds
        $Second = (Get-Item -LiteralPath $Path -ErrorAction Stop).Length
        if ($First -ne $Second) { return $false }
        Start-Sleep -Seconds 2
        $Third = (Get-Item -LiteralPath $Path -ErrorAction Stop).Length
        if ($Second -ne $Third) { return $false }
        try {
            $Stream = [System.IO.File]::Open($Path, 'Open', 'Read', 'None')
            $Stream.Close()
            return $true
        }
        catch {
            return $false
        }
    }
    catch {
        return $false
    }
}

function Invoke-RcloneCapture {
    param([string[]]$Arguments)
    $PreviousOutputEncoding = [Console]::OutputEncoding
    try {
        [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false)
        $EffectiveArguments = @('--config', $script:RcloneConfigPath) + $Arguments
        $Output = & $script:RclonePath @EffectiveArguments 2>&1
        $ExitCode = $LASTEXITCODE
    }
    finally {
        [Console]::OutputEncoding = $PreviousOutputEncoding
    }
    return [pscustomobject]@{
        ExitCode = $ExitCode
        Output = ($Output -join "`n")
    }
}

function Get-RemoteFiles {
    param([string]$RemoteDir)
    $Result = Invoke-RcloneCapture -Arguments @('lsjson', $RemoteDir, '--files-only')
    if ($Result.ExitCode -ne 0) {
        throw "rclone lsjson 失败，退出码 $($Result.ExitCode)：$($Result.Output)"
    }
    if ([string]::IsNullOrWhiteSpace($Result.Output)) { return @() }
    $Parsed = $Result.Output | ConvertFrom-Json
    if ($null -eq $Parsed) { return @() }
    if ($Parsed -is [System.Array]) { return $Parsed }
    return @($Parsed)
}

function Test-RemoteFileExists {
    param(
        [string]$RemoteDir,
        [string]$FileName,
        [Int64]$LocalSize
    )
    try {
        $Files = Get-RemoteFiles -RemoteDir $RemoteDir
        foreach ($File in $Files) {
            if ($File.Name -ceq $FileName) {
                $RemoteSize = [Int64]$File.Size
                if ($RemoteSize -eq $LocalSize) {
                    return $true
                }
                Write-AgentMessage "云端同名文件大小不一致：$FileName；本地=$LocalSize；云端=$RemoteSize"
                return $false
            }
        }
        Write-AgentMessage "云端验证未找到文件：$RemoteDir/$FileName"
        return $false
    }
    catch {
        Write-AgentMessage "云端验证失败：$($_.Exception.Message)"
        return $false
    }
}

function Ensure-RemoteDir {
    param([string]$RemoteDir)
    $Result = Invoke-RcloneCapture -Arguments @('mkdir', $RemoteDir)
    if ($Result.ExitCode -ne 0) {
        throw "创建远程目录失败：$RemoteDir；$($Result.Output)"
    }
}

function Get-UniqueName {
    param([string]$Directory, [string]$FileName)
    $Base = [System.IO.Path]::GetFileNameWithoutExtension($FileName)
    $Ext = [System.IO.Path]::GetExtension($FileName)
    $Candidate = $FileName
    $Index = 1
    while (Test-Path -LiteralPath (Join-Path $Directory $Candidate)) {
        $Candidate = "{0}_{1}{2}" -f $Base, $Index, $Ext
        $Index++
    }
    return $Candidate
}

function Get-UniqueRemoteName {
    param([string]$RemoteDir, [string]$FileName)
    if ($script:Mode -eq 'local_only') { return $FileName }
    try {
        $Files = Get-RemoteFiles -RemoteDir $RemoteDir
        $Names = @{}
        foreach ($File in $Files) {
            if ($File.Name) { $Names[[string]$File.Name] = $true }
        }
        $Base = [System.IO.Path]::GetFileNameWithoutExtension($FileName)
        $Ext = [System.IO.Path]::GetExtension($FileName)
        $Candidate = $FileName
        $Index = 1
        while ($Names.ContainsKey($Candidate)) {
            $Candidate = "{0}_{1}{2}" -f $Base, $Index, $Ext
            $Index++
        }
        return $Candidate
    }
    catch {
        throw "检查远程重名失败，为防止覆盖云端文件，本次不上传：$($_.Exception.Message)"
    }
}

function Assert-SafeLocalPath {
    param([string]$Path)
    $ResolvedPath = [System.IO.Path]::GetFullPath($Path)
    $ResolvedRaw = [System.IO.Path]::GetFullPath($script:RawDir).TrimEnd('\') + '\'
    if (-not $ResolvedPath.StartsWith($ResolvedRaw, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "安全检查失败：拒绝处理 raw 目录以外的文件：$ResolvedPath"
    }
    $Item = Get-Item -LiteralPath $ResolvedPath -Force -ErrorAction Stop
    if (($Item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw "安全检查失败：拒绝处理符号链接或重解析点：$ResolvedPath"
    }
}

function Test-Processed {
    param([string]$Key)
    if (-not (Test-Path -LiteralPath $script:ProcessedFile)) { return $false }
    $Needle = $Key.ToLowerInvariant()
    $Found = Select-String -LiteralPath $script:ProcessedFile -SimpleMatch -Pattern $Needle -Quiet -ErrorAction SilentlyContinue
    return [bool]$Found
}

function Add-Processed {
    param([string]$Key)
    Add-Content -LiteralPath $script:ProcessedFile -Encoding UTF8 -Value ($Key.ToLowerInvariant())
}

function Complete-LocalCleanup {
    param(
        [string]$Mode,
        [string]$Path
    )
    return Complete-ScreenAgentVerifiedLocalAction `
        -Mode $Mode `
        -Path $Path `
        -RawRoot $script:RawDir `
        -UploadedRoot $script:UploadedDir `
        -Verified $true
}

function Process-VideoFile {
    param([string]$Path)
    $LocalKey = 'local::' + $Path.ToLowerInvariant()
    if (Test-Processed -Key $LocalKey) { return }
    if (-not (Test-FileStable -Path $Path)) {
        Write-AgentMessage "文件仍在写入，稍后重试：$Path"
        return
    }

    $Session = Get-CurrentSession
    $Category = Get-SafeName ([string]$Session.category)
    $Topic = Get-SafeName ([string]$Session.topic)
    $Title = [string]$Session.title
    $SafeTitle = Get-SafeName $Title
    $SessionId = Get-SafeName ([string]$Session.id)
    $StartTime = [string]$Session.start_time
    $CleanupMode = [string]$Session.cleanup_mode
    $CleanupMode = Resolve-ScreenAgentCleanupMode -Mode $CleanupMode

    $Ext = [System.IO.Path]::GetExtension($Path).ToLowerInvariant()
    $CanonicalName = "{0}__{1}_{2}__{3}{4}" -f $SessionId, $Category, $Topic, $SafeTitle, $Ext
    $RemoteDir = ''
    if ($script:Mode -ne 'local_only') {
        $RemoteDir = Join-RemotePath -Base $script:RemoteRoot -Child "$Category/$Topic"
        try {
            Ensure-RemoteDir -RemoteDir $RemoteDir
            $CanonicalName = Get-UniqueRemoteName -RemoteDir $RemoteDir -FileName $CanonicalName
        }
        catch {
            Write-IndexLog -Id $SessionId -StartTime $StartTime -EndTime (Get-NowText) -Category $Category -Topic $Topic -Title $Title -RemotePath $RemoteDir -LocalPath $Path -LocalDeleted 'false' -Status 'remote_name_check_failed' -Reason $_.Exception.Message
            return
        }
    }
    $TargetPath = Join-Path (Split-Path -Parent $Path) $CanonicalName
    if ($Path -ne $TargetPath) {
        $CanonicalName = Get-UniqueName -Directory (Split-Path -Parent $Path) -FileName $CanonicalName
        $TargetPath = Join-Path (Split-Path -Parent $Path) $CanonicalName
        Move-Item -LiteralPath $Path -Destination $TargetPath -Force -ErrorAction Stop
        $Path = $TargetPath
    }

    $RemotePath = ''
    if ($script:Mode -eq 'local_only') {
        try {
            $CleanupResult = Complete-LocalCleanup -Mode 'move_after_verified_upload' -Path $TargetPath
            Add-Processed -Key ('local::' + $TargetPath.ToLowerInvariant())
            Write-IndexLog -Id $SessionId -StartTime $StartTime -EndTime (Get-NowText) -Category $Category -Topic $Topic -Title $Title -RemotePath '' -LocalPath $CleanupResult.LocalPath -LocalDeleted $CleanupResult.LocalDeleted -Status 'local_saved' -Reason '本地保存模式，文件已移入 uploaded'
        }
        catch {
            Write-IndexLog -Id $SessionId -StartTime $StartTime -EndTime (Get-NowText) -Category $Category -Topic $Topic -Title $Title -RemotePath '' -LocalPath $TargetPath -LocalDeleted 'false' -Status 'local_save_failed' -Reason $_.Exception.Message
        }
        return
    }

    $RemotePath = Join-RemotePath -Base $RemoteDir -Child $CanonicalName
    $LocalSize = (Get-Item -LiteralPath $TargetPath -ErrorAction Stop).Length

    Write-AgentMessage "开始上传：$TargetPath -> $RemotePath"
    try {
        Ensure-RemoteDir -RemoteDir $RemoteDir
    }
    catch {
        Write-IndexLog -Id $SessionId -StartTime $StartTime -EndTime (Get-NowText) -Category $Category -Topic $Topic -Title $Title -RemotePath $RemotePath -LocalPath $TargetPath -LocalDeleted 'false' -Status 'upload_failed' -Reason $_.Exception.Message
        return
    }
    $Upload = Invoke-RcloneCapture -Arguments @('copyto', $TargetPath, $RemotePath, '--create-empty-src-dirs', '--immutable')
    if ($Upload.ExitCode -ne 0) {
        Write-IndexLog -Id $SessionId -StartTime $StartTime -EndTime (Get-NowText) -Category $Category -Topic $Topic -Title $Title -RemotePath $RemotePath -LocalPath $TargetPath -LocalDeleted 'false' -Status 'upload_failed' -Reason $Upload.Output
        return
    }

    $Exists = Test-RemoteFileExists -RemoteDir $RemoteDir -FileName $CanonicalName -LocalSize $LocalSize
    if (-not $Exists) {
        Write-IndexLog -Id $SessionId -StartTime $StartTime -EndTime (Get-NowText) -Category $Category -Topic $Topic -Title $Title -RemotePath $RemotePath -LocalPath $TargetPath -LocalDeleted 'false' -Status 'verify_failed' -Reason '上传命令成功，但云端未验证到同名同大小文件'
        return
    }

    try {
        $CleanupResult = Complete-LocalCleanup -Mode $CleanupMode -Path $TargetPath
        Add-Processed -Key $RemotePath
        Add-Processed -Key ('local::' + $TargetPath.ToLowerInvariant())
        Write-IndexLog -Id $SessionId -StartTime $StartTime -EndTime (Get-NowText) -Category $Category -Topic $Topic -Title $Title -RemotePath $RemotePath -LocalPath $CleanupResult.LocalPath -LocalDeleted $CleanupResult.LocalDeleted -Status $CleanupResult.Status -Reason $CleanupResult.Reason
    }
    catch {
        Write-IndexLog -Id $SessionId -StartTime $StartTime -EndTime (Get-NowText) -Category $Category -Topic $Topic -Title $Title -RemotePath $RemotePath -LocalPath $TargetPath -LocalDeleted 'false' -Status 'cleanup_failed' -Reason $_.Exception.Message
    }
}

try {
    $Config = Load-Config
}
catch {
    Write-Host "ScreenAgent 启动失败：$($_.Exception.Message)" -ForegroundColor Red
    Start-Sleep -Seconds 10
    exit 1
}

$script:Root = [string]$Config.install_root
if ($Config.base_dir) { $script:Root = [string]$Config.base_dir }
if ([string]::IsNullOrWhiteSpace($script:Root)) { $script:Root = Join-Path $env:USERPROFILE 'ScreenAgent' }
$script:RawDir = [string]$Config.raw_dir
if ([string]::IsNullOrWhiteSpace($script:RawDir)) { $script:RawDir = Join-Path $script:Root 'recordings\raw' }
$script:UploadedDir = [string]$Config.uploaded_dir
if ([string]::IsNullOrWhiteSpace($script:UploadedDir)) { $script:UploadedDir = Join-Path $script:Root 'recordings\uploaded' }
$script:LogDir = [string]$Config.logs_dir
if ([string]::IsNullOrWhiteSpace($script:LogDir)) { $script:LogDir = Join-Path $script:Root 'logs' }
$script:SessionDir = [string]$Config.sessions_dir
if ([string]::IsNullOrWhiteSpace($script:SessionDir)) { $script:SessionDir = Join-Path $script:Root 'sessions' }
$script:CurrentSessionPath = Join-Path $script:SessionDir 'current_session.json'
$script:CsvLog = Join-Path $script:LogDir 'index.csv'
$script:ReportLog = Join-Path $script:LogDir 'report.txt'
$script:ProcessedFile = Join-Path $script:LogDir 'processed.txt'
$script:Mode = [string]$Config.mode
if ([string]::IsNullOrWhiteSpace($script:Mode) -and $Config.cloud_type) {
    if ([string]$Config.cloud_type -eq 'local') { $script:Mode = 'local_only' }
    elseif ([string]$Config.cloud_type -eq 'nutstore') { $script:Mode = 'nutstore_webdav' }
    else { $script:Mode = 'generic_webdav' }
}
if ([string]::IsNullOrWhiteSpace($script:Mode)) { $script:Mode = 'local_only' }
$script:RclonePath = [string]$Config.rclone_path
if ($Config.rclone_exe) { $script:RclonePath = [string]$Config.rclone_exe }
$script:RcloneConfigPath = [string]$Config.rclone_config_path
if ([string]::IsNullOrWhiteSpace($script:RcloneConfigPath)) {
    $script:RcloneConfigPath = Join-Path $script:Root 'config\rclone.conf'
}
$script:RemoteRoot = [string]$Config.remote_root
$script:DefaultCleanupMode = [string]$Config.cleanup_mode
$script:DefaultCleanupMode = Resolve-ScreenAgentCleanupMode -Mode $script:DefaultCleanupMode
$script:SessionStaleHours = 6
if ($Config.session_stale_hours) { $script:SessionStaleHours = [int]$Config.session_stale_hours }
$script:StableSeconds = 12
if ($Config.stable_seconds) { $script:StableSeconds = [Math]::Max(5, [int]$Config.stable_seconds) }
$ScanMin = 10
$ScanMax = 20
if ($Config.scan_interval_min_seconds) { $ScanMin = [int]$Config.scan_interval_min_seconds }
if ($Config.scan_interval_max_seconds) { $ScanMax = [int]$Config.scan_interval_max_seconds }
if ($Config.scan_interval_seconds) {
    $ScanMin = [Math]::Max(5, [int]$Config.scan_interval_seconds - 3)
    $ScanMax = [Math]::Max($ScanMin, [int]$Config.scan_interval_seconds + 3)
}

New-Item -ItemType Directory -Force -Path $script:RawDir, $script:UploadedDir, $script:LogDir, $script:SessionDir | Out-Null
Initialize-Log

if ($script:Mode -ne 'local_only') {
    if ([string]::IsNullOrWhiteSpace($script:RclonePath) -or -not (Test-Path -LiteralPath $script:RclonePath)) {
        Write-Report "rclone 不存在，后台任务无法上传：$script:RclonePath"
        exit 1
    }
    if ([string]::IsNullOrWhiteSpace($script:RemoteRoot)) {
        Write-Report 'remote_root 为空，后台任务无法上传。'
        exit 1
    }
    if (-not (Test-Path -LiteralPath $script:RcloneConfigPath -PathType Leaf)) {
        Write-Report "rclone 专用配置不存在：$script:RcloneConfigPath"
        exit 1
    }
}

Write-AgentMessage 'ScreenAgent 后台任务已启动。'
Write-Report '后台任务已启动。'

$Extensions = @('.mkv', '.mp4', '.mov')
while ($true) {
    try {
        $Files = Get-ChildItem -LiteralPath $script:RawDir -File -ErrorAction SilentlyContinue |
            Where-Object { $Extensions -contains $_.Extension.ToLowerInvariant() } |
            Sort-Object LastWriteTime
        foreach ($File in $Files) {
            Process-VideoFile -Path $File.FullName
        }
    }
    catch {
        Write-AgentMessage "扫描循环异常：$($_.Exception.Message)"
        Write-Report "扫描循环异常：$($_.Exception.Message)"
    }
    if ($env:SCREENAGENT_ACCEPTANCE_MODE -eq '1' -and $env:SCREENAGENT_RUN_ONCE -eq '1') {
        break
    }
    $Delay = Get-Random -Minimum $ScanMin -Maximum ($ScanMax + 1)
    Start-Sleep -Seconds $Delay
}
