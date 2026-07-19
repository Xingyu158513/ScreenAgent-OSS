param(
    [Parameter(Mandatory = $true)][string]$SessionPath,
    [int]$NoFileTimeoutSeconds = 120,
    [int]$DeadlineMinutes = 720,
    [int]$QuietSeconds = 45
)

$ErrorActionPreference = 'Stop'

$ArchiveModule = Join-Path $PSScriptRoot 'lib\ScreenAgent.Archive.psm1'
Import-Module $ArchiveModule -Force

function Invoke-SessionWorker {
    $Config = Get-ScreenAgentRuntimeConfig
    $Runtime = Initialize-ScreenAgentArchive -Config $Config
    $ResolvedSessionPath = Resolve-ScreenAgentSessionPath -Path $SessionPath -SessionDirectory $Runtime.SessionDirectory
    $Session = Get-Content -LiteralPath $ResolvedSessionPath -Raw -Encoding UTF8 | ConvertFrom-Json
    if ([string]::IsNullOrWhiteSpace([string]$Session.id)) {
        throw '会话文件缺少 id。'
    }

    $BaselinePaths = @{}
    foreach ($Entry in @($Session.baseline_files)) {
        $BaselinePath = if ($Entry -is [string]) { [string]$Entry } else { [string]$Entry.path }
        if (-not [string]::IsNullOrWhiteSpace($BaselinePath)) {
            try { $BaselinePaths[[System.IO.Path]::GetFullPath($BaselinePath).ToLowerInvariant()] = $true } catch {}
        }
    }

    $SafeId = ([string]$Session.id) -replace '[^A-Za-z0-9_.-]', '_'
    $CreatedNew = $false
    $Mutex = New-Object System.Threading.Mutex($false, ('Local\ScreenAgent.Session.' + $SafeId), [ref]$CreatedNew)
    $HasMutex = $false
    try {
        $HasMutex = $Mutex.WaitOne(0)
        if (-not $HasMutex) {
            Write-ScreenAgentArchiveMessage -Message "会话已有 worker，当前进程退出：$($Session.id)"
            return 0
        }

        $NoFileTimeoutSeconds = [Math]::Max(5, $NoFileTimeoutSeconds)
        $DeadlineMinutes = [Math]::Max(1, $DeadlineMinutes)
        $QuietSeconds = [Math]::Max(1, $QuietSeconds)
        $ScanIntervalSeconds = 5
        if ($Config.scan_interval_seconds) {
            $ScanIntervalSeconds = [Math]::Max(1, [int]$Config.scan_interval_seconds)
        }

        $StartedAt = Get-Date
        $NoFileDeadline = $StartedAt.AddSeconds($NoFileTimeoutSeconds)
        $TotalDeadline = $StartedAt.AddMinutes($DeadlineMinutes)
        $LastProcessedAt = $null
        $SeenCandidate = $false
        $CompletedPaths = @{}
        Set-ScreenAgentSessionStatus -SessionPath $ResolvedSessionPath -Session $Session -Status 'waiting_for_recording' -Reason '会话 worker 已启动。'

        while ((Get-Date) -lt $TotalDeadline) {
            $PendingCount = 0
            foreach ($File in @(Get-ScreenAgentVideoFiles)) {
                $Key = [System.IO.Path]::GetFullPath($File.FullName).ToLowerInvariant()

                # A path that already existed before this session never belongs to the new session.
                if ($BaselinePaths.ContainsKey($Key) -or $CompletedPaths.ContainsKey($Key)) { continue }

                $SeenCandidate = $true
                $Result = Invoke-ScreenAgentArchiveFile -Path $File.FullName -Session $Session
                if ($Result -eq 'Pending') {
                    $PendingCount++
                    continue
                }
                if ($Result -eq 'Failed') {
                    Set-ScreenAgentSessionStatus -SessionPath $ResolvedSessionPath -Session $Session -Status 'needs_recovery' -Reason '录像处理失败，原文件已保留；请运行“恢复未归档录像”。'
                    return 0
                }

                $CompletedPaths[$Key] = $true
                $LastProcessedAt = Get-Date
                Set-ScreenAgentSessionStatus -SessionPath $ResolvedSessionPath -Session $Session -Status 'finalizing' -Reason '录像已处理，等待会话安静期结束。'
            }

            $Now = Get-Date
            if (-not $SeenCandidate -and $Now -ge $NoFileDeadline) {
                Set-ScreenAgentSessionStatus -SessionPath $ResolvedSessionPath -Session $Session -Status 'no_recording_found' -Reason '在等待时间内没有发现本次会话的新录像。'
                return 0
            }
            if ($null -ne $LastProcessedAt -and $PendingCount -eq 0 -and ($Now - $LastProcessedAt).TotalSeconds -ge $QuietSeconds) {
                Set-ScreenAgentSessionStatus -SessionPath $ResolvedSessionPath -Session $Session -Status 'completed' -Reason '录像已归档，会话 worker 正常退出。'
                return 0
            }

            Start-Sleep -Seconds $ScanIntervalSeconds
        }

        Set-ScreenAgentSessionStatus -SessionPath $ResolvedSessionPath -Session $Session -Status 'deadline_reached' -Reason '达到会话最长运行时间，未处理文件仍保留在 raw。'
        return 0
    }
    catch {
        try { Set-ScreenAgentSessionStatus -SessionPath $SessionPath -Session $Session -Status 'worker_error' -Reason $_.Exception.Message } catch {}
        Write-Error $_
        return 1
    }
    finally {
        if ($HasMutex) { $Mutex.ReleaseMutex() }
        $Mutex.Dispose()
    }
}

exit (Invoke-SessionWorker)
