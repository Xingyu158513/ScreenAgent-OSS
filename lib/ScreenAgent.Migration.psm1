Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

function Get-ScreenAgentScheduledTaskActionKind {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Action,
        [Parameter(Mandatory = $true)][string]$ScreenAgentRoot
    )

    $ResolvedRoot = [System.IO.Path]::GetFullPath($ScreenAgentRoot).TrimEnd('\')
    $LegacyWorker = [System.IO.Path]::GetFullPath((Join-Path $ResolvedRoot 'auto_upload_delete.ps1'))
    $LegacyHiddenWorker = [System.IO.Path]::GetFullPath((Join-Path $ResolvedRoot 'app\run_auto_archive_hidden.vbs'))
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
            if ($ResolvedWorker.Equals($LegacyHiddenWorker, [System.StringComparison]::OrdinalIgnoreCase)) {
                return 'LegacyHiddenWorker'
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

Export-ModuleMember -Function @(
    'Get-ScreenAgentScheduledTaskActionKind',
    'Remove-ScreenAgentKnownScheduledTask',
    'Move-ScreenAgentLegacyWorkerToBackup'
)
