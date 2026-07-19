$ErrorActionPreference = 'Stop'

$SecurityModule = Join-Path $PSScriptRoot 'ScreenAgent.Security.psm1'
Import-Module $SecurityModule -Force

$script:Initialized = $false
$script:Extensions = @('.mkv', '.mp4', '.mov')

function Get-ScreenAgentRuntimeConfig {
    [CmdletBinding()]
    param()

    $Root = Join-Path $env:USERPROFILE 'ScreenAgent'
    $ConfigPath = Join-Path $Root 'config\config.json'
    if ($env:SCREENAGENT_ACCEPTANCE_MODE -eq '1' -and -not [string]::IsNullOrWhiteSpace($env:SCREENAGENT_CONFIG_PATH)) {
        $ConfigPath = [System.IO.Path]::GetFullPath($env:SCREENAGENT_CONFIG_PATH)
    }
    if (-not (Test-Path -LiteralPath $ConfigPath -PathType Leaf)) {
        throw "找不到配置文件：$ConfigPath"
    }
    return Get-Content -LiteralPath $ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
}

function Initialize-ScreenAgentArchive {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)]$Config)

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
    $script:DefaultCleanupMode = Resolve-ScreenAgentCleanupMode -Mode ([string]$Config.cleanup_mode)
    $script:StableSeconds = 12
    if ($Config.stable_seconds) { $script:StableSeconds = [Math]::Max(5, [int]$Config.stable_seconds) }

    New-Item -ItemType Directory -Force -Path $script:RawDir, $script:UploadedDir, $script:LogDir, $script:SessionDir | Out-Null
    Initialize-ArchiveLog

    if ($script:Mode -ne 'local_only') {
        if ([string]::IsNullOrWhiteSpace($script:RclonePath) -or -not (Test-Path -LiteralPath $script:RclonePath -PathType Leaf)) {
            throw "rclone 不存在，无法上传：$script:RclonePath"
        }
        if ([string]::IsNullOrWhiteSpace($script:RemoteRoot)) { throw 'remote_root 为空，无法上传。' }
        if (-not (Test-Path -LiteralPath $script:RcloneConfigPath -PathType Leaf)) {
            throw "rclone 专用配置不存在：$script:RcloneConfigPath"
        }
    }

    $script:Initialized = $true
    return [pscustomobject]@{
        Root = $script:Root
        RawDirectory = $script:RawDir
        UploadedDirectory = $script:UploadedDir
        LogDirectory = $script:LogDir
        SessionDirectory = $script:SessionDir
        StableSeconds = $script:StableSeconds
        Mode = $script:Mode
    }
}

function Assert-ArchiveInitialized {
    if (-not $script:Initialized) { throw 'ScreenAgent archive module has not been initialized.' }
}

function Get-NowText { return (Get-Date).ToString('yyyy-MM-dd HH:mm:ss') }

function Write-ScreenAgentArchiveMessage {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Message)
    Write-Host ("[{0}] {1}" -f (Get-NowText), $Message)
}

function ConvertTo-CsvField {
    param([object]$Value)
    $Text = ''
    if ($null -ne $Value) { $Text = [string]$Value }
    return '"' + $Text.Replace('"', '""') + '"'
}

function Initialize-ArchiveLog {
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

function Write-ScreenAgentArchiveReport {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Message)
    Assert-ArchiveInitialized
    Add-Content -LiteralPath $script:ReportLog -Encoding UTF8 -Value ("[{0}] {1}" -f (Get-NowText), $Message)
}

function Write-IndexLog {
    param(
        [string]$Id, [string]$StartTime, [string]$EndTime,
        [string]$Category, [string]$Topic, [string]$Title,
        [string]$RemotePath, [string]$LocalPath, [string]$LocalDeleted,
        [string]$Status, [string]$Reason
    )
    $Fields = @($Id, $StartTime, $EndTime, $Category, $Topic, $Title, $RemotePath, $LocalPath, $LocalDeleted, $Status, $Reason)
    Add-Content -LiteralPath $script:CsvLog -Encoding UTF8 -Value (($Fields | ForEach-Object { ConvertTo-CsvField $_ }) -join ',')
    Write-ScreenAgentArchiveReport -Message "标题=$Title；状态=$Status；远程=$RemotePath；本地=$LocalPath；原因=$Reason"
}

function Get-SafeName {
    param([string]$Name)
    return ConvertTo-ScreenAgentSafeSegment -Value $Name -Fallback '未命名录屏'
}

function Join-RemotePath {
    param([string]$Base, [string]$Child)
    return $Base.TrimEnd('/') + '/' + $Child.TrimStart('/')
}

function Get-ScreenAgentVideoFiles {
    [CmdletBinding()]
    param()
    Assert-ArchiveInitialized
    return @(Get-ChildItem -LiteralPath $script:RawDir -File -ErrorAction SilentlyContinue |
        Where-Object { $script:Extensions -contains $_.Extension.ToLowerInvariant() } |
        Sort-Object LastWriteTime)
}

function Test-ScreenAgentRecordingStable {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Path)
    Assert-ArchiveInitialized
    try {
        if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $false }
        $First = (Get-Item -LiteralPath $Path -ErrorAction Stop).Length
        Start-Sleep -Seconds $script:StableSeconds
        $Second = (Get-Item -LiteralPath $Path -ErrorAction Stop).Length
        if ($First -ne $Second) { return $false }
        Start-Sleep -Seconds 2
        $Third = (Get-Item -LiteralPath $Path -ErrorAction Stop).Length
        if ($Second -ne $Third) { return $false }
        $Stream = [System.IO.File]::Open($Path, 'Open', 'Read', 'None')
        $Stream.Close()
        return $true
    }
    catch { return $false }
}

function Invoke-RcloneCapture {
    param([string[]]$Arguments)
    $PreviousOutputEncoding = [Console]::OutputEncoding
    $PreviousErrorActionPreference = $ErrorActionPreference
    try {
        [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false)
        $ErrorActionPreference = 'Continue'
        $EffectiveArguments = @('--config', $script:RcloneConfigPath) + $Arguments
        $Output = & $script:RclonePath @EffectiveArguments 2>&1
        $ExitCode = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $PreviousErrorActionPreference
        [Console]::OutputEncoding = $PreviousOutputEncoding
    }
    return [pscustomobject]@{ ExitCode = $ExitCode; Output = ($Output -join "`n") }
}

function Get-RemoteFiles {
    param([string]$RemoteDir)
    $Result = Invoke-RcloneCapture -Arguments @('lsjson', $RemoteDir, '--files-only')
    if ($Result.ExitCode -ne 0) { throw "rclone lsjson 失败，退出码 $($Result.ExitCode)：$($Result.Output)" }
    if ([string]::IsNullOrWhiteSpace($Result.Output)) { return @() }
    $Parsed = $Result.Output | ConvertFrom-Json
    if ($null -eq $Parsed) { return @() }
    return @($Parsed)
}

function Test-RemoteFileExists {
    param([string]$RemoteDir, [string]$FileName, [Int64]$LocalSize)
    try {
        foreach ($File in @(Get-RemoteFiles -RemoteDir $RemoteDir)) {
            if ($File.Name -ceq $FileName) {
                if ([Int64]$File.Size -eq $LocalSize) { return $true }
                Write-ScreenAgentArchiveMessage -Message "云端同名文件大小不一致：$FileName；本地=$LocalSize；云端=$($File.Size)"
                return $false
            }
        }
        Write-ScreenAgentArchiveMessage -Message "云端验证未找到文件：$RemoteDir/$FileName"
        return $false
    }
    catch {
        Write-ScreenAgentArchiveMessage -Message "云端验证失败：$($_.Exception.Message)"
        return $false
    }
}

function Ensure-RemoteDir {
    param([string]$RemoteDir)
    $Result = Invoke-RcloneCapture -Arguments @('mkdir', $RemoteDir)
    if ($Result.ExitCode -ne 0) { throw "创建远程目录失败：$RemoteDir；$($Result.Output)" }
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
    $Names = @{}
    foreach ($File in @(Get-RemoteFiles -RemoteDir $RemoteDir)) {
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

function Assert-SafeLocalPath {
    param([string]$Path)
    $ResolvedPath = [System.IO.Path]::GetFullPath($Path)
    if (-not (Test-ScreenAgentPathWithinRoot -Path $ResolvedPath -Root $script:RawDir)) {
        throw "安全检查失败：拒绝处理 raw 目录以外的文件：$ResolvedPath"
    }
    $Item = Get-Item -LiteralPath $ResolvedPath -Force -ErrorAction Stop
    if (($Item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw "安全检查失败：拒绝处理符号链接或重解析点：$ResolvedPath"
    }
    return $ResolvedPath
}

function Test-Processed {
    param([string]$Key)
    if (-not (Test-Path -LiteralPath $script:ProcessedFile)) { return $false }
    return [bool](Select-String -LiteralPath $script:ProcessedFile -SimpleMatch -Pattern $Key.ToLowerInvariant() -Quiet -ErrorAction SilentlyContinue)
}

function Add-Processed {
    param([string]$Key)
    Add-Content -LiteralPath $script:ProcessedFile -Encoding UTF8 -Value $Key.ToLowerInvariant()
}

function New-ScreenAgentRecoverySession {
    [CmdletBinding()]
    param()
    Assert-ArchiveInitialized
    return [pscustomobject]@{
        id = (Get-Date -Format 'yyyyMMdd-HHmmss')
        category = 'recovered'
        topic = 'unknown'
        title = '恢复的录屏'
        start_time = (Get-Date).ToString('s')
        cleanup_mode = $script:DefaultCleanupMode
        is_recovered = $true
    }
}

function Invoke-ScreenAgentArchiveFile {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)]$Session
    )
    Assert-ArchiveInitialized
    $Path = Assert-SafeLocalPath -Path $Path
    $LocalKey = 'local::' + $Path.ToLowerInvariant()
    if (Test-Processed -Key $LocalKey) { return 'AlreadyProcessed' }
    if (-not (Test-ScreenAgentRecordingStable -Path $Path)) {
        Write-ScreenAgentArchiveMessage -Message "文件仍在写入，稍后重试：$Path"
        return 'Pending'
    }

    $Category = Get-SafeName ([string]$Session.category)
    $Topic = Get-SafeName ([string]$Session.topic)
    $Title = [string]$Session.title
    $SafeTitle = Get-SafeName $Title
    $SessionId = Get-SafeName ([string]$Session.id)
    $StartTime = [string]$Session.start_time
    $CleanupMode = Resolve-ScreenAgentCleanupMode -Mode ([string]$Session.cleanup_mode)
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
            return 'Failed'
        }
    }

    $TargetPath = Join-Path (Split-Path -Parent $Path) $CanonicalName
    if ($Path -ne $TargetPath) {
        $CanonicalName = Get-UniqueName -Directory (Split-Path -Parent $Path) -FileName $CanonicalName
        $TargetPath = Join-Path (Split-Path -Parent $Path) $CanonicalName
        Move-Item -LiteralPath $Path -Destination $TargetPath -ErrorAction Stop
    }

    if ($script:Mode -eq 'local_only') {
        try {
            $CleanupResult = Complete-ScreenAgentVerifiedLocalAction -Mode 'move_after_verified_upload' -Path $TargetPath -RawRoot $script:RawDir -UploadedRoot $script:UploadedDir -Verified $true
            Add-Processed -Key ('local::' + $TargetPath.ToLowerInvariant())
            Write-IndexLog -Id $SessionId -StartTime $StartTime -EndTime (Get-NowText) -Category $Category -Topic $Topic -Title $Title -RemotePath '' -LocalPath $CleanupResult.LocalPath -LocalDeleted $CleanupResult.LocalDeleted -Status 'local_saved' -Reason '本地保存模式，文件已移入 uploaded'
            return 'Processed'
        }
        catch {
            Write-IndexLog -Id $SessionId -StartTime $StartTime -EndTime (Get-NowText) -Category $Category -Topic $Topic -Title $Title -RemotePath '' -LocalPath $TargetPath -LocalDeleted 'false' -Status 'local_save_failed' -Reason $_.Exception.Message
            return 'Failed'
        }
    }

    $RemotePath = Join-RemotePath -Base $RemoteDir -Child $CanonicalName
    $LocalSize = (Get-Item -LiteralPath $TargetPath -ErrorAction Stop).Length
    Write-ScreenAgentArchiveMessage -Message "开始上传：$TargetPath -> $RemotePath"
    try { Ensure-RemoteDir -RemoteDir $RemoteDir }
    catch {
        Write-IndexLog -Id $SessionId -StartTime $StartTime -EndTime (Get-NowText) -Category $Category -Topic $Topic -Title $Title -RemotePath $RemotePath -LocalPath $TargetPath -LocalDeleted 'false' -Status 'upload_failed' -Reason $_.Exception.Message
        return 'Failed'
    }

    $Upload = Invoke-RcloneCapture -Arguments @('copyto', $TargetPath, $RemotePath, '--create-empty-src-dirs', '--immutable')
    if ($Upload.ExitCode -ne 0) {
        Write-IndexLog -Id $SessionId -StartTime $StartTime -EndTime (Get-NowText) -Category $Category -Topic $Topic -Title $Title -RemotePath $RemotePath -LocalPath $TargetPath -LocalDeleted 'false' -Status 'upload_failed' -Reason $Upload.Output
        return 'Failed'
    }
    if (-not (Test-RemoteFileExists -RemoteDir $RemoteDir -FileName $CanonicalName -LocalSize $LocalSize)) {
        Write-IndexLog -Id $SessionId -StartTime $StartTime -EndTime (Get-NowText) -Category $Category -Topic $Topic -Title $Title -RemotePath $RemotePath -LocalPath $TargetPath -LocalDeleted 'false' -Status 'verify_failed' -Reason '上传命令成功，但云端未验证到同名同大小文件'
        return 'Failed'
    }

    try {
        $CleanupResult = Complete-ScreenAgentVerifiedLocalAction -Mode $CleanupMode -Path $TargetPath -RawRoot $script:RawDir -UploadedRoot $script:UploadedDir -Verified $true
        Add-Processed -Key $RemotePath
        Add-Processed -Key ('local::' + $TargetPath.ToLowerInvariant())
        Write-IndexLog -Id $SessionId -StartTime $StartTime -EndTime (Get-NowText) -Category $Category -Topic $Topic -Title $Title -RemotePath $RemotePath -LocalPath $CleanupResult.LocalPath -LocalDeleted $CleanupResult.LocalDeleted -Status $CleanupResult.Status -Reason $CleanupResult.Reason
        return 'Processed'
    }
    catch {
        Write-IndexLog -Id $SessionId -StartTime $StartTime -EndTime (Get-NowText) -Category $Category -Topic $Topic -Title $Title -RemotePath $RemotePath -LocalPath $TargetPath -LocalDeleted 'false' -Status 'cleanup_failed' -Reason $_.Exception.Message
        return 'Failed'
    }
}

function Resolve-ScreenAgentSessionPath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$SessionDirectory
    )
    $Resolved = [System.IO.Path]::GetFullPath($Path)
    if ([System.IO.Path]::GetExtension($Resolved) -ine '.json') { throw "会话文件必须是 JSON：$Resolved" }
    if (-not (Test-ScreenAgentPathWithinRoot -Path $Resolved -Root $SessionDirectory)) {
        throw "拒绝读取 sessions 目录以外的会话文件：$Resolved"
    }
    if (-not (Test-Path -LiteralPath $Resolved -PathType Leaf)) { throw "会话文件不存在：$Resolved" }
    return $Resolved
}

function Set-ScreenAgentSessionStatus {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$SessionPath,
        [Parameter(Mandatory = $true)]$Session,
        [Parameter(Mandatory = $true)][string]$Status,
        [Parameter(Mandatory = $true)][string]$Reason
    )
    $Session | Add-Member -NotePropertyName status -NotePropertyValue $Status -Force
    $Session | Add-Member -NotePropertyName worker_reason -NotePropertyValue $Reason -Force
    $Session | Add-Member -NotePropertyName worker_updated_at -NotePropertyValue ((Get-Date).ToString('s')) -Force
    $TempPath = $SessionPath + '.tmp.' + $PID
    $Utf8Bom = New-Object System.Text.UTF8Encoding($true)
    [System.IO.File]::WriteAllText($TempPath, ($Session | ConvertTo-Json -Depth 8), $Utf8Bom)
    try { [System.IO.File]::Replace($TempPath, $SessionPath, $null) }
    catch { Move-Item -LiteralPath $TempPath -Destination $SessionPath -Force -ErrorAction Stop }
}

Export-ModuleMember -Function @(
    'Get-ScreenAgentRuntimeConfig',
    'Initialize-ScreenAgentArchive',
    'Get-ScreenAgentVideoFiles',
    'Test-ScreenAgentRecordingStable',
    'Invoke-ScreenAgentArchiveFile',
    'New-ScreenAgentRecoverySession',
    'Resolve-ScreenAgentSessionPath',
    'Set-ScreenAgentSessionStatus',
    'Write-ScreenAgentArchiveMessage',
    'Write-ScreenAgentArchiveReport'
)
