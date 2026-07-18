Set-StrictMode -Version 2.0

function New-RcloneObscureStartInfo {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$RclonePath
    )

    if ([string]::IsNullOrWhiteSpace($RclonePath)) {
        throw 'rclone path cannot be empty.'
    }

    $Info = New-Object System.Diagnostics.ProcessStartInfo
    $Info.FileName = $RclonePath
    $Info.Arguments = 'obscure -'
    $Info.UseShellExecute = $false
    $Info.CreateNoWindow = $true
    $Info.RedirectStandardInput = $true
    $Info.RedirectStandardOutput = $true
    $Info.RedirectStandardError = $true
    return $Info
}

function ConvertTo-RcloneObscuredPassword {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$RclonePath,

        [Parameter(Mandatory = $true)]
        [Security.SecureString]$SecurePassword
    )

    $Info = New-RcloneObscureStartInfo -RclonePath $RclonePath
    $Process = New-Object System.Diagnostics.Process
    $Process.StartInfo = $Info
    $Bstr = [IntPtr]::Zero
    $PlainText = $null

    try {
        $Bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($SecurePassword)
        $PlainText = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($Bstr)
        if ([string]::IsNullOrWhiteSpace($PlainText)) {
            throw 'Password cannot be empty.'
        }

        if (-not $Process.Start()) {
            throw 'Unable to start rclone password obscuring process.'
        }

        $Process.StandardInput.WriteLine($PlainText)
        $Process.StandardInput.Close()
        $Output = $Process.StandardOutput.ReadToEnd().Trim()
        $ErrorOutput = $Process.StandardError.ReadToEnd().Trim()
        $Process.WaitForExit()

        if ($Process.ExitCode -ne 0) {
            throw "rclone obscure failed with exit code $($Process.ExitCode): $ErrorOutput"
        }
        if ([string]::IsNullOrWhiteSpace($Output)) {
            throw 'rclone obscure returned an empty value.'
        }
        return $Output
    }
    finally {
        $PlainText = $null
        if ($Bstr -ne [IntPtr]::Zero) {
            [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($Bstr)
        }
        $Process.Dispose()
    }
}

function Resolve-ScreenAgentCleanupMode {
    [CmdletBinding()]
    param([AllowNull()][string]$Mode)

    if ($Mode -eq 'keep_local') {
        return 'keep_local'
    }
    return 'move_after_verified_upload'
}

function ConvertTo-ScreenAgentSafeSegment {
    [CmdletBinding()]
    param(
        [AllowNull()][string]$Value,
        [string]$Fallback = 'ScreenAgent'
    )

    $Safe = [string]$Value
    $Safe = $Safe -replace '[\\/:*?"<>|]', ''
    $Safe = $Safe.Trim().Trim('.')
    $Safe = $Safe -replace '\s+', '_'
    if ([string]::IsNullOrWhiteSpace($Safe)) {
        $Safe = $Fallback
    }
    if ($Safe.Length -gt 80) {
        $Safe = $Safe.Substring(0, 80).TrimEnd('.')
    }
    return $Safe
}

function Assert-ScreenAgentHttpsUrl {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Url)

    $Uri = $null
    if (-not [Uri]::TryCreate($Url, [UriKind]::Absolute, [ref]$Uri)) {
        throw "Invalid WebDAV URL: $Url"
    }
    if ($Uri.Scheme -ne 'https') {
        throw 'WebDAV URL must use HTTPS to protect credentials and recordings in transit.'
    }
    return $Uri.AbsoluteUri
}

function Protect-ScreenAgentCredentialFile {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "Credential file does not exist: $Path"
    }

    $Identity = [Security.Principal.WindowsIdentity]::GetCurrent().User
    if ($null -eq $Identity) {
        throw 'Unable to determine the current Windows user SID.'
    }

    $Acl = Get-Acl -LiteralPath $Path
    $Acl.SetAccessRuleProtection($true, $false)
    $Rule = New-Object Security.AccessControl.FileSystemAccessRule($Identity, 'FullControl', 'Allow')
    $Acl.SetAccessRule($Rule)
    Set-Acl -LiteralPath $Path -AclObject $Acl
}

function Get-ScreenAgentScheduledTaskSpec {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$AppDirectory)

    $ResolvedApp = [System.IO.Path]::GetFullPath($AppDirectory)
    $Worker = Join-Path $ResolvedApp 'run_auto_archive_hidden.vbs'
    return [pscustomobject]@{
        TaskName = 'ScreenAgent-AutoUpload'
        Execute = 'wscript.exe'
        Argument = ('"{0}"' -f $Worker)
        WorkerPath = $Worker
    }
}

function Get-ScreenAgentScheduledTaskActionKind {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Action,
        [Parameter(Mandatory = $true)][string]$ScreenAgentRoot
    )

    $ResolvedRoot = [System.IO.Path]::GetFullPath($ScreenAgentRoot).TrimEnd('\')
    $LegacyWorker = [System.IO.Path]::GetFullPath((Join-Path $ResolvedRoot 'auto_upload_delete.ps1'))
    $HiddenWorker = [System.IO.Path]::GetFullPath((Join-Path $ResolvedRoot 'app\run_auto_archive_hidden.vbs'))
    $Execute = [string]$Action.Execute
    $Arguments = [string]$Action.Arguments
    $ExecutableName = [System.IO.Path]::GetFileName($Execute)

    if ($ExecutableName.Equals('powershell.exe', [System.StringComparison]::OrdinalIgnoreCase)) {
        $Match = [regex]::Match($Arguments, '(?i)(?:^|\s)-File\s+(?:"([^"]+)"|''([^'']+)''|([^\s]+))')
        if ($Match.Success) {
            $WorkerArgument = $Match.Groups[1].Value
            if ([string]::IsNullOrWhiteSpace($WorkerArgument)) { $WorkerArgument = $Match.Groups[2].Value }
            if ([string]::IsNullOrWhiteSpace($WorkerArgument)) { $WorkerArgument = $Match.Groups[3].Value }
            try {
                $ResolvedWorker = [System.IO.Path]::GetFullPath($WorkerArgument)
                if ($ResolvedWorker.Equals($LegacyWorker, [System.StringComparison]::OrdinalIgnoreCase)) {
                    return 'LegacyPowerShell'
                }
            }
            catch {}
        }
        return 'Unknown'
    }

    if ($ExecutableName.Equals('wscript.exe', [System.StringComparison]::OrdinalIgnoreCase)) {
        $WorkerArgument = $Arguments.Trim()
        if ($WorkerArgument.Length -ge 2 -and
            (($WorkerArgument[0] -eq '"' -and $WorkerArgument[$WorkerArgument.Length - 1] -eq '"') -or
             ($WorkerArgument[0] -eq "'" -and $WorkerArgument[$WorkerArgument.Length - 1] -eq "'"))) {
            $WorkerArgument = $WorkerArgument.Substring(1, $WorkerArgument.Length - 2)
        }
        try {
            $ResolvedWorker = [System.IO.Path]::GetFullPath($WorkerArgument)
            if ($ResolvedWorker.Equals($HiddenWorker, [System.StringComparison]::OrdinalIgnoreCase)) {
                return 'HiddenWorker'
            }
        }
        catch {}
    }

    return 'Unknown'
}

function Remove-ScreenAgentKnownScheduledTask {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$ScreenAgentRoot,
        [string]$TaskName = 'ScreenAgent-AutoUpload',
        [int]$StopTimeoutSeconds = 10
    )

    if (-not $TaskName.Equals('ScreenAgent-AutoUpload', [System.StringComparison]::Ordinal)) {
        throw "Refusing to operate on an unexpected scheduled task name: $TaskName"
    }

    $Task = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    if (-not $Task) {
        return [pscustomobject]@{ Found = $false; Removed = $false; ActionKind = 'None' }
    }

    $Actions = @($Task.Actions)
    if ($Actions.Count -ne 1) {
        throw "Scheduled task $TaskName has an unexpected number of actions; installation was stopped without changing it."
    }
    $ActionKind = Get-ScreenAgentScheduledTaskActionKind -Action $Actions[0] -ScreenAgentRoot $ScreenAgentRoot
    if ($ActionKind -eq 'Unknown') {
        throw "Scheduled task $TaskName does not point to a known ScreenAgent worker; installation was stopped without changing it."
    }

    Disable-ScheduledTask -TaskName $TaskName -ErrorAction Stop | Out-Null
    Stop-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    $Deadline = (Get-Date).AddSeconds([Math]::Max(1, $StopTimeoutSeconds))
    do {
        $Current = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
        if (-not $Current -or [string]$Current.State -ne 'Running') { break }
        Start-Sleep -Milliseconds 200
    } while ((Get-Date) -lt $Deadline)

    $Current = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    if ($Current -and [string]$Current.State -eq 'Running') {
        throw "Scheduled task $TaskName did not stop; installation was aborted before replacing any worker."
    }
    if ($Current) {
        Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction Stop
    }
    return [pscustomobject]@{ Found = $true; Removed = $true; ActionKind = $ActionKind }
}

function Move-ScreenAgentLegacyWorkerToBackup {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$ScreenAgentRoot,
        [datetime]$Timestamp = (Get-Date)
    )

    $ResolvedRoot = [System.IO.Path]::GetFullPath($ScreenAgentRoot).TrimEnd('\')
    $LegacyWorker = [System.IO.Path]::GetFullPath((Join-Path $ResolvedRoot 'auto_upload_delete.ps1'))
    if (-not (Test-Path -LiteralPath $LegacyWorker)) {
        return [pscustomobject]@{ Found = $false; Moved = $false; Destination = $null }
    }

    $Item = Get-Item -LiteralPath $LegacyWorker -Force -ErrorAction Stop
    if ($Item.PSIsContainer -or (($Item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0)) {
        throw "Refusing to move an unsafe legacy worker path: $LegacyWorker"
    }

    $BackupRoot = Join-Path $ResolvedRoot 'legacy-backup'
    $BaseName = $Timestamp.ToString('yyyyMMdd-HHmmssfff')
    $BackupDirectory = Join-Path $BackupRoot $BaseName
    $Index = 1
    while (Test-Path -LiteralPath $BackupDirectory) {
        $BackupDirectory = Join-Path $BackupRoot ("{0}_{1}" -f $BaseName, $Index)
        $Index++
    }
    New-Item -ItemType Directory -Path $BackupDirectory -Force -ErrorAction Stop | Out-Null
    $Destination = Join-Path $BackupDirectory 'auto_upload_delete.ps1.disabled'
    Move-Item -LiteralPath $LegacyWorker -Destination $Destination -ErrorAction Stop
    return [pscustomobject]@{ Found = $true; Moved = $true; Destination = $Destination }
}

function Remove-ScreenAgentProgramDirectory {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$AppDirectory,
        [Parameter(Mandatory = $true)][string]$ScreenAgentRoot,
        [Parameter(Mandatory = $true)][bool]$Confirmed
    )

    if (-not $Confirmed) { return $false }

    $ResolvedRoot = [System.IO.Path]::GetFullPath($ScreenAgentRoot).TrimEnd('\')
    $ExpectedApp = [System.IO.Path]::GetFullPath((Join-Path $ResolvedRoot 'app')).TrimEnd('\')
    $ResolvedApp = [System.IO.Path]::GetFullPath($AppDirectory).TrimEnd('\')
    if (-not $ResolvedApp.Equals($ExpectedApp, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "Refusing to remove an unexpected program directory: $ResolvedApp"
    }
    if (-not (Test-Path -LiteralPath $ResolvedApp)) { return $false }

    $Item = Get-Item -LiteralPath $ResolvedApp -Force -ErrorAction Stop
    if (-not $Item.PSIsContainer) {
        throw "Program path is not a directory: $ResolvedApp"
    }
    if (($Item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw "Refusing to recursively remove a reparse point: $ResolvedApp"
    }

    Remove-Item -LiteralPath $ResolvedApp -Recurse -Force -ErrorAction Stop
    return $true
}

function Resolve-ScreenAgentInstallRoot {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$DefaultRoot,
        [Parameter(Mandatory = $true)][bool]$AcceptanceMode,
        [AllowNull()][string]$RequestedRoot
    )

    if (-not $AcceptanceMode) {
        return [System.IO.Path]::GetFullPath($DefaultRoot).TrimEnd('\')
    }
    if ([string]::IsNullOrWhiteSpace($RequestedRoot)) {
        throw 'Acceptance mode requires an explicit temporary install root.'
    }

    $Resolved = [System.IO.Path]::GetFullPath($RequestedRoot).TrimEnd('\')
    $TempRoot = [System.IO.Path]::GetFullPath([System.IO.Path]::GetTempPath()).TrimEnd('\')
    if (-not (Test-ScreenAgentPathWithinRoot -Path $Resolved -Root $TempRoot)) {
        throw "Acceptance install root must be inside the Windows temporary directory: $Resolved"
    }
    return $Resolved
}

function Test-ScreenAgentPathWithinRoot {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Root
    )

    $ResolvedPath = [System.IO.Path]::GetFullPath($Path)
    $ResolvedRoot = [System.IO.Path]::GetFullPath($Root).TrimEnd('\') + '\'
    return $ResolvedPath.StartsWith($ResolvedRoot, [System.StringComparison]::OrdinalIgnoreCase)
}

function Assert-ScreenAgentSafeSourceFile {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$RawRoot
    )

    if (-not (Test-ScreenAgentPathWithinRoot -Path $Path -Root $RawRoot)) {
        throw "Refusing to process a file outside the raw recording directory: $Path"
    }

    $Item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
    if ($Item.PSIsContainer) {
        throw "Refusing to process a directory as a recording: $Path"
    }
    if (($Item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw "Refusing to process a symbolic link or reparse point: $Path"
    }
}

function Get-ScreenAgentUniquePath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Directory,
        [Parameter(Mandatory = $true)][string]$FileName
    )

    $Base = [System.IO.Path]::GetFileNameWithoutExtension($FileName)
    $Extension = [System.IO.Path]::GetExtension($FileName)
    $Candidate = Join-Path $Directory $FileName
    $Index = 1
    while (Test-Path -LiteralPath $Candidate) {
        $Candidate = Join-Path $Directory ("{0}_{1}{2}" -f $Base, $Index, $Extension)
        $Index++
    }
    return $Candidate
}

function Complete-ScreenAgentVerifiedLocalAction {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Mode,
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$RawRoot,
        [Parameter(Mandatory = $true)][string]$UploadedRoot,
        [Parameter(Mandatory = $true)][bool]$Verified
    )

    if (-not $Verified) {
        throw 'Local handling requires a successful remote verification.'
    }

    Assert-ScreenAgentSafeSourceFile -Path $Path -RawRoot $RawRoot
    $SafeMode = Resolve-ScreenAgentCleanupMode -Mode $Mode
    if ($SafeMode -eq 'keep_local') {
        return [pscustomobject]@{
            Status = 'success_kept_local'
            LocalDeleted = 'false'
            LocalPath = $Path
            Reason = 'Remote verification succeeded; local recording was retained.'
        }
    }

    New-Item -ItemType Directory -Force -Path $UploadedRoot | Out-Null
    $Destination = Get-ScreenAgentUniquePath -Directory $UploadedRoot -FileName ([System.IO.Path]::GetFileName($Path))
    Move-Item -LiteralPath $Path -Destination $Destination -ErrorAction Stop
    return [pscustomobject]@{
        Status = 'success_moved'
        LocalDeleted = 'false'
        LocalPath = $Destination
        Reason = 'Remote verification succeeded; local recording was moved to the uploaded directory.'
    }
}

Export-ModuleMember -Function @(
    'New-RcloneObscureStartInfo',
    'ConvertTo-RcloneObscuredPassword',
    'Resolve-ScreenAgentCleanupMode',
    'ConvertTo-ScreenAgentSafeSegment',
    'Assert-ScreenAgentHttpsUrl',
    'Protect-ScreenAgentCredentialFile',
    'Get-ScreenAgentScheduledTaskSpec',
    'Get-ScreenAgentScheduledTaskActionKind',
    'Remove-ScreenAgentKnownScheduledTask',
    'Move-ScreenAgentLegacyWorkerToBackup',
    'Remove-ScreenAgentProgramDirectory',
    'Resolve-ScreenAgentInstallRoot',
    'Test-ScreenAgentPathWithinRoot',
    'Assert-ScreenAgentSafeSourceFile',
    'Get-ScreenAgentUniquePath',
    'Complete-ScreenAgentVerifiedLocalAction'
)
