$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

$ProjectRoot = Split-Path -Parent $PSScriptRoot
$ModulePath = Join-Path $ProjectRoot 'lib\ScreenAgent.Security.psm1'
Import-Module $ModulePath -Force
$MigrationModulePath = Join-Path $ProjectRoot 'lib\ScreenAgent.Migration.psm1'
Import-Module $MigrationModulePath -Force

$script:Passed = 0
$script:Failed = 0

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
}

function Assert-Equal {
    param($Expected, $Actual, [string]$Message)
    if ($Expected -ne $Actual) {
        throw "$Message Expected=[$Expected] Actual=[$Actual]"
    }
}

function Invoke-Test {
    param([string]$Name, [scriptblock]$Body)
    try {
        & $Body
        $script:Passed++
        Write-Host "PASS $Name" -ForegroundColor Green
    }
    catch {
        $script:Failed++
        Write-Host "FAIL $Name :: $($_.Exception.Message)" -ForegroundColor Red
    }
}

function Get-ScriptAst {
    param([Parameter(Mandatory = $true)][string]$Path)
    $Tokens = $null
    $Errors = $null
    $Ast = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$Tokens, [ref]$Errors)
    if ($Errors.Count -gt 0) {
        throw "Unable to parse $Path`: $($Errors.Message -join '; ')"
    }
    return $Ast
}

function Get-ScriptCommandNames {
    param([Parameter(Mandatory = $true)][string]$Path)
    $Ast = Get-ScriptAst -Path $Path
    return @($Ast.FindAll({
        param($Node)
        $Node -is [System.Management.Automation.Language.CommandAst]
    }, $true) | ForEach-Object { $_.GetCommandName() } | Where-Object { $_ })
}

Invoke-Test 'PowerShell source files parse without syntax errors' {
    $Failures = @()
    Get-ChildItem -LiteralPath $ProjectRoot -Recurse -File |
        Where-Object { $_.Extension -in @('.ps1', '.psm1') } |
        ForEach-Object {
            $Tokens = $null
            $Errors = $null
            [void][System.Management.Automation.Language.Parser]::ParseFile($_.FullName, [ref]$Tokens, [ref]$Errors)
            if ($Errors.Count -gt 0) {
                $Failures += "$($_.FullName): $($Errors.Message -join '; ')"
            }
        }
    Assert-Equal 0 $Failures.Count ($Failures -join "`n")
}

Invoke-Test 'Unsupported cleanup modes fail closed to verified move' {
    Assert-Equal 'move_after_verified_upload' (Resolve-ScreenAgentCleanupMode 'delete_after_verified_upload') 'Legacy delete mode must not delete.'
    Assert-Equal 'move_after_verified_upload' (Resolve-ScreenAgentCleanupMode 'unknown') 'Unknown mode must fail closed.'
    Assert-Equal 'keep_local' (Resolve-ScreenAgentCleanupMode 'keep_local') 'Explicit keep mode must be preserved.'
}

Invoke-Test 'Path boundary rejects sibling-prefix paths' {
    $Base = Join-Path ([System.IO.Path]::GetTempPath()) ('screenagent-boundary-' + [guid]::NewGuid().ToString('N'))
    $Raw = Join-Path $Base 'raw'
    $Sibling = Join-Path $Base 'raw-evil\clip.mkv'
    Assert-True (Test-ScreenAgentPathWithinRoot -Path (Join-Path $Raw 'clip.mkv') -Root $Raw) 'Expected child path to be accepted.'
    Assert-True (-not (Test-ScreenAgentPathWithinRoot -Path $Sibling -Root $Raw)) 'Sibling-prefix path must be rejected.'
}

Invoke-Test 'User labels cannot escape a file or remote path segment' {
    Assert-Equal 'evil' (ConvertTo-ScreenAgentSafeSegment '..\\evil/..' 'fallback') 'Separators and surrounding dots must be removed.'
    Assert-Equal 'fallback' (ConvertTo-ScreenAgentSafeSegment '..' 'fallback') 'Dot-only segment must use fallback.'
    Assert-True ((ConvertTo-ScreenAgentSafeSegment ('a' * 200) 'fallback').Length -le 80) 'Segment length must be bounded.'
}

Invoke-Test 'Generic WebDAV requires HTTPS' {
    Assert-Equal 'https://example.com/dav' (Assert-ScreenAgentHttpsUrl 'https://example.com/dav') 'HTTPS URL should be accepted.'
    $Threw = $false
    try { Assert-ScreenAgentHttpsUrl 'http://example.com/dav' | Out-Null } catch { $Threw = $true }
    Assert-True $Threw 'HTTP WebDAV URL must be rejected.'
}

Invoke-Test 'Unverified upload never moves a local recording' {
    $Base = Join-Path ([System.IO.Path]::GetTempPath()) ('screenagent-unverified-' + [guid]::NewGuid().ToString('N'))
    $Raw = Join-Path $Base 'raw'
    $Uploaded = Join-Path $Base 'uploaded'
    New-Item -ItemType Directory -Force -Path $Raw | Out-Null
    $Source = Join-Path $Raw 'clip.mkv'
    [System.IO.File]::WriteAllText($Source, 'video')
    try {
        $Threw = $false
        try {
            Complete-ScreenAgentVerifiedLocalAction -Mode 'move_after_verified_upload' -Path $Source -RawRoot $Raw -UploadedRoot $Uploaded -Verified $false | Out-Null
        }
        catch { $Threw = $true }
        Assert-True $Threw 'Expected unverified action to throw.'
        Assert-True (Test-Path -LiteralPath $Source) 'Unverified source file must remain in place.'
    }
    finally {
        Remove-Item -LiteralPath $Base -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Invoke-Test 'Verified move preserves bytes and avoids overwrite' {
    $Base = Join-Path ([System.IO.Path]::GetTempPath()) ('screenagent-move-' + [guid]::NewGuid().ToString('N'))
    $Raw = Join-Path $Base 'raw'
    $Uploaded = Join-Path $Base 'uploaded'
    New-Item -ItemType Directory -Force -Path $Raw, $Uploaded | Out-Null
    $Existing = Join-Path $Uploaded 'clip.mkv'
    [System.IO.File]::WriteAllText($Existing, 'existing')
    $Source = Join-Path $Raw 'clip.mkv'
    [System.IO.File]::WriteAllText($Source, 'new-video')
    try {
        $Result = Complete-ScreenAgentVerifiedLocalAction -Mode 'move_after_verified_upload' -Path $Source -RawRoot $Raw -UploadedRoot $Uploaded -Verified $true
        Assert-Equal 'success_moved' $Result.Status 'Expected a move result.'
        Assert-Equal 'false' $Result.LocalDeleted 'Public OSS mode must never report deletion.'
        Assert-True (-not (Test-Path -LiteralPath $Source)) 'Moved source should no longer remain in raw.'
        Assert-Equal 'existing' ([System.IO.File]::ReadAllText($Existing)) 'Existing destination must not be overwritten.'
        Assert-Equal 'new-video' ([System.IO.File]::ReadAllText($Result.LocalPath)) 'Moved bytes must be preserved.'
        Assert-True ($Result.LocalPath -ne $Existing) 'Move must choose a unique destination.'
    }
    finally {
        Remove-Item -LiteralPath $Base -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Invoke-Test 'Keep-local mode leaves the verified file untouched' {
    $Base = Join-Path ([System.IO.Path]::GetTempPath()) ('screenagent-keep-' + [guid]::NewGuid().ToString('N'))
    $Raw = Join-Path $Base 'raw'
    $Uploaded = Join-Path $Base 'uploaded'
    New-Item -ItemType Directory -Force -Path $Raw | Out-Null
    $Source = Join-Path $Raw 'clip.mkv'
    [System.IO.File]::WriteAllText($Source, 'video')
    try {
        $Result = Complete-ScreenAgentVerifiedLocalAction -Mode 'keep_local' -Path $Source -RawRoot $Raw -UploadedRoot $Uploaded -Verified $true
        Assert-Equal 'success_kept_local' $Result.Status 'Expected keep-local result.'
        Assert-True (Test-Path -LiteralPath $Source) 'Keep-local source file must remain.'
    }
    finally {
        Remove-Item -LiteralPath $Base -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Invoke-Test 'rclone password input uses stdin and never a secret argument' {
    $Info = New-RcloneObscureStartInfo -RclonePath 'C:\Tools\rclone\rclone.exe'
    Assert-Equal 'obscure -' $Info.Arguments 'Only the stdin marker may appear in rclone arguments.'
    Assert-True $Info.RedirectStandardInput 'Standard input must be redirected.'
    Assert-True $Info.RedirectStandardOutput 'Standard output must be redirected.'
}

Invoke-Test 'Credential file inheritance is removed and current user retains access' {
    $Base = Join-Path ([System.IO.Path]::GetTempPath()) ('screenagent-acl-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Force -Path $Base | Out-Null
    $CredentialFile = Join-Path $Base 'rclone.conf'
    [System.IO.File]::WriteAllText($CredentialFile, '[dummy]')
    try {
        Protect-ScreenAgentCredentialFile -Path $CredentialFile
        $Acl = Get-Acl -LiteralPath $CredentialFile
        Assert-True $Acl.AreAccessRulesProtected 'Credential file must not inherit broad parent permissions.'
        $CurrentSid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
        $HasCurrentUser = @($Acl.Access | Where-Object {
            $_.IdentityReference.Translate([Security.Principal.SecurityIdentifier]).Value -eq $CurrentSid -and
            $_.AccessControlType -eq [Security.AccessControl.AccessControlType]::Allow
        }).Count -gt 0
        Assert-True $HasCurrentUser 'Current user must retain access to the credential file.'
    }
    finally {
        Remove-Item -LiteralPath $Base -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Invoke-Test 'Cloud commands use the ScreenAgent-specific rclone config' {
    $Uploader = Get-Content -LiteralPath (Join-Path $ProjectRoot 'lib\ScreenAgent.Archive.psm1') -Raw -Encoding UTF8
    $Wizard = Get-Content -LiteralPath (Join-Path $ProjectRoot 'config_wizard.ps1') -Raw -Encoding UTF8
    Assert-True ($Uploader.Contains("@('--config', `$script:RcloneConfigPath)")) 'Uploader must prepend the dedicated config path.'
    Assert-True ($Wizard -match 'rclone_config_path') 'Wizard must persist the dedicated config path.'
    Assert-True ($Wizard -match 'Protect-ScreenAgentCredentialFile') 'Wizard must restrict credential file access.'
}

Invoke-Test 'Production scripts contain no automatic permanent-delete mode' {
    $Uploader = Get-Content -LiteralPath (Join-Path $ProjectRoot 'lib\ScreenAgent.Archive.psm1') -Raw -Encoding UTF8
    $Starter = Get-Content -LiteralPath (Join-Path $ProjectRoot 'start_recording.ps1') -Raw -Encoding UTF8
    $Wizard = Get-Content -LiteralPath (Join-Path $ProjectRoot 'config_wizard.ps1') -Raw -Encoding UTF8
    Assert-True ($Uploader -notmatch 'Remove-Item') 'Uploader must not permanently delete files.'
    Assert-True ($Uploader -notmatch 'delete_after_verified_upload') 'Uploader must not recognize legacy delete mode.'
    Assert-True ($Starter -notmatch 'delete_after_verified_upload') 'Recording UI must not offer legacy delete mode.'
    Assert-True ($Wizard -notmatch '\$Password') 'Wizard must not pass a plaintext password argument.'
    Assert-True ($Wizard -match '\$ObscuredPassword') 'Wizard must pass only the obscured password value.'
}

Invoke-Test 'Uninstaller never recursively removes the user data root' {
    $Uninstaller = Get-Content -LiteralPath (Join-Path $ProjectRoot 'uninstall.ps1') -Raw -Encoding UTF8
    Assert-True ($Uninstaller -notmatch 'DELETEALL') 'Uninstaller must not expose recursive user-data deletion.'
    Assert-True ($Uninstaller -notmatch 'Remove-Item\s+-LiteralPath\s+\$Root') 'Uninstaller must never remove the ScreenAgent data root.'
    Assert-True ($Uninstaller -notmatch 'Remove-Item\s+-LiteralPath\s+\$AppDir\s+-Recurse') 'Uninstaller must use the tested program-directory helper.'
}

Invoke-Test 'Recursive program removal requires exact path and confirmation' {
    $Base = Join-Path ([System.IO.Path]::GetTempPath()) ('screenagent-uninstall-' + [guid]::NewGuid().ToString('N'))
    $App = Join-Path $Base 'app'
    $Sibling = Join-Path $Base 'app-evil'
    New-Item -ItemType Directory -Force -Path $App, $Sibling | Out-Null
    [System.IO.File]::WriteAllText((Join-Path $App 'program.txt'), 'program')
    try {
        Assert-True (-not (Remove-ScreenAgentProgramDirectory -AppDirectory $App -ScreenAgentRoot $Base -Confirmed $false)) 'Unconfirmed removal must do nothing.'
        Assert-True (Test-Path -LiteralPath $App) 'Unconfirmed app directory must remain.'
        $Threw = $false
        try { Remove-ScreenAgentProgramDirectory -AppDirectory $Sibling -ScreenAgentRoot $Base -Confirmed $true | Out-Null } catch { $Threw = $true }
        Assert-True $Threw 'Sibling directory must be rejected.'
        Assert-True (Test-Path -LiteralPath $Sibling) 'Rejected sibling directory must remain.'
        Assert-True (Remove-ScreenAgentProgramDirectory -AppDirectory $App -ScreenAgentRoot $Base -Confirmed $true) 'Exact confirmed app directory should be removed.'
        Assert-True (-not (Test-Path -LiteralPath $App)) 'Confirmed exact app directory should be gone.'
    }
    finally {
        Remove-Item -LiteralPath $Base -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Invoke-Test 'Acceptance install root is restricted to Windows temp' {
    $Default = Join-Path $env:USERPROFILE 'ScreenAgent'
    Assert-Equal ([System.IO.Path]::GetFullPath($Default).TrimEnd('\')) (Resolve-ScreenAgentInstallRoot -DefaultRoot $Default -AcceptanceMode $false -RequestedRoot 'C:\unexpected') 'Normal mode must ignore override.'
    $Requested = Join-Path ([System.IO.Path]::GetTempPath()) ('screenagent-acceptance-' + [guid]::NewGuid().ToString('N'))
    Assert-Equal ([System.IO.Path]::GetFullPath($Requested).TrimEnd('\')) (Resolve-ScreenAgentInstallRoot -DefaultRoot $Default -AcceptanceMode $true -RequestedRoot $Requested) 'Acceptance temp root should be accepted.'
    $Threw = $false
    try { Resolve-ScreenAgentInstallRoot -DefaultRoot $Default -AcceptanceMode $true -RequestedRoot 'C:\ScreenAgent-Escape' | Out-Null } catch { $Threw = $true }
    Assert-True $Threw 'Acceptance root outside Windows temp must be rejected.'
}

Invoke-Test 'Installer removes legacy tasks but never creates or starts a logon task' {
    $Installer = Get-Content -LiteralPath (Join-Path $ProjectRoot 'install.ps1') -Raw -Encoding UTF8
    $Uninstaller = Get-Content -LiteralPath (Join-Path $ProjectRoot 'uninstall.ps1') -Raw -Encoding UTF8
    $Commands = Get-ScriptCommandNames -Path (Join-Path $ProjectRoot 'install.ps1')
    Assert-True ($Commands -notcontains 'Register-ScheduledTask') 'Installer must not register a background task.'
    Assert-True ($Commands -notcontains 'Start-ScheduledTask') 'Installer must not start a background task.'
    Assert-True ($Commands -notcontains 'New-ScheduledTaskTrigger') 'Installer must not create any scheduled-task trigger.'
    Assert-True ($Installer -notmatch '(?i)-AtLogOn\b') 'Installer must not contain a logon trigger.'
    Assert-True ($Installer -match 'Remove-ScreenAgentKnownScheduledTask') 'Installer must explicitly migrate a known legacy ScreenAgent task.'
    Assert-True ($Uninstaller -match '\$TaskName\s*=\s*''ScreenAgent-AutoUpload''') 'Uninstaller must use the fixed task name.'
    Assert-True ($Installer -notmatch '\$Config\.task_name') 'Installer must ignore config-supplied task names.'
    Assert-True ($Uninstaller -notmatch '\$Config\.task_name') 'Uninstaller must ignore config-supplied task names.'
}

Invoke-Test 'Legacy scheduled-task action recognition is exact and rejects unrelated actions' {
    $Root = 'C:\Users\Example\ScreenAgent'
    $Legacy = [pscustomobject]@{
        Execute = 'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe'
        Arguments = '-NoProfile -ExecutionPolicy Bypass -File "C:\Users\Example\ScreenAgent\auto_upload_delete.ps1"'
    }
    $Hidden = [pscustomobject]@{
        Execute = 'wscript.exe'
        Arguments = '"C:\Users\Example\ScreenAgent\app\run_auto_archive_hidden.vbs"'
    }
    $SiblingPrefix = [pscustomobject]@{
        Execute = 'powershell.exe'
        Arguments = '-File "C:\Users\Example\ScreenAgent-Other\auto_upload_delete.ps1"'
    }
    $Unrelated = [pscustomobject]@{
        Execute = 'powershell.exe'
        Arguments = '-NoProfile -Command "Write-Host unrelated"'
    }
    Assert-Equal 'LegacyPowerShell' (Get-ScreenAgentScheduledTaskActionKind -Action $Legacy -ScreenAgentRoot $Root) 'Exact legacy worker action must be recognized.'
    Assert-Equal 'LegacyHiddenWorker' (Get-ScreenAgentScheduledTaskActionKind -Action $Hidden -ScreenAgentRoot $Root) 'Exact hidden worker action must be recognized for migration.'
    Assert-Equal 'Unknown' (Get-ScreenAgentScheduledTaskActionKind -Action $SiblingPrefix -ScreenAgentRoot $Root) 'Sibling-prefix paths must not be treated as ScreenAgent.'
    Assert-Equal 'Unknown' (Get-ScreenAgentScheduledTaskActionKind -Action $Unrelated -ScreenAgentRoot $Root) 'An unrelated same-name task action must be rejected.'

    $Threw = $false
    try { Remove-ScreenAgentKnownScheduledTask -ScreenAgentRoot $Root -TaskName 'Unrelated-Task' | Out-Null } catch { $Threw = $true }
    Assert-True $Threw 'Migration must refuse every task name except the fixed legacy name.'
}

Invoke-Test 'Legacy delete worker is quarantined without touching recordings or user data' {
    $Base = Join-Path ([System.IO.Path]::GetTempPath()) ('screenagent-legacy-migration-' + [guid]::NewGuid().ToString('N'))
    $Raw = Join-Path $Base 'recordings\raw'
    $ConfigDir = Join-Path $Base 'config'
    $Logs = Join-Path $Base 'logs'
    New-Item -ItemType Directory -Force -Path $Raw, $ConfigDir, $Logs | Out-Null
    $LegacyWorker = Join-Path $Base 'auto_upload_delete.ps1'
    $Recording = Join-Path $Raw 'keep-me.mkv'
    $ConfigFile = Join-Path $ConfigDir 'config.json'
    $LogFile = Join-Path $Logs 'report.txt'
    [System.IO.File]::WriteAllText($LegacyWorker, '# legacy worker bytes')
    [System.IO.File]::WriteAllBytes($Recording, [byte[]](1..32))
    [System.IO.File]::WriteAllText($ConfigFile, '{"keep":true}')
    [System.IO.File]::WriteAllText($LogFile, 'keep log')
    $RecordingHash = (Get-FileHash -LiteralPath $Recording -Algorithm SHA256).Hash
    try {
        $Result = Move-ScreenAgentLegacyWorkerToBackup -ScreenAgentRoot $Base -Timestamp ([datetime]'2026-07-19T12:00:00')
        Assert-True $Result.Found 'Legacy worker should be found.'
        Assert-True $Result.Moved 'Legacy worker should be moved to quarantine.'
        Assert-True (-not (Test-Path -LiteralPath $LegacyWorker)) 'Executable legacy worker must no longer remain at its active path.'
        Assert-True (Test-Path -LiteralPath $Result.Destination -PathType Leaf) 'Quarantined legacy worker must remain available as evidence.'
        Assert-Equal '# legacy worker bytes' ([System.IO.File]::ReadAllText($Result.Destination)) 'Quarantine must preserve the legacy worker bytes.'
        Assert-Equal $RecordingHash (Get-FileHash -LiteralPath $Recording -Algorithm SHA256).Hash 'Migration must not change a recording.'
        Assert-Equal '{"keep":true}' ([System.IO.File]::ReadAllText($ConfigFile)) 'Migration must preserve configuration.'
        Assert-Equal 'keep log' ([System.IO.File]::ReadAllText($LogFile)) 'Migration must preserve logs.'

        $Again = Move-ScreenAgentLegacyWorkerToBackup -ScreenAgentRoot $Base -Timestamp ([datetime]'2026-07-19T12:00:00')
        Assert-True (-not $Again.Found) 'Migration must be idempotent once the active legacy worker is gone.'
        Assert-True (-not $Again.Moved) 'An idempotent migration must not move unrelated files.'
    }
    finally {
        Remove-Item -LiteralPath $Base -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Invoke-Test 'Archive worker has no unconditional permanent loop' {
    $WorkerPath = Join-Path $ProjectRoot 'session_worker.ps1'
    $Ast = Get-ScriptAst -Path $WorkerPath
    $InfiniteLoops = @($Ast.FindAll({
        param($Node)
        if ($Node -isnot [System.Management.Automation.Language.WhileStatementAst]) { return $false }
        $Condition = $Node.Condition.Extent.Text -replace '[\s()]', ''
        return $Condition -ieq '$true'
    }, $true))
    Assert-Equal 0 $InfiniteLoops.Count 'Worker must not contain while ($true); every loop needs an observable exit condition.'
}

Invoke-Test 'Session worker never assigns a baseline file to the new session' {
    $Worker = Get-Content -LiteralPath (Join-Path $ProjectRoot 'session_worker.ps1') -Raw -Encoding UTF8
    Assert-True ($Worker -match 'A path that already existed before this session never belongs') 'Worker must explicitly keep baseline paths out of the new session.'
    Assert-True ($Worker -notmatch '\$File\.Length\s+-ne\s+\$BaselineLength') 'A growing baseline file must not be reclassified as a new-session file.'
}

Invoke-Test 'Recording launcher and VBS wrapper use a bounded per-session worker' {
    $Starter = Get-Content -LiteralPath (Join-Path $ProjectRoot 'start_recording.ps1') -Raw -Encoding UTF8
    $Wrapper = Get-Content -LiteralPath (Join-Path $ProjectRoot 'run_session_worker_hidden.vbs') -Raw -Encoding UTF8
    $Worker = Get-Content -LiteralPath (Join-Path $ProjectRoot 'session_worker.ps1') -Raw -Encoding UTF8
    Assert-True ($Worker -notmatch '(?i)RunMode') 'Session worker must not contain a multi-purpose mode switch.'
    Assert-True ($Worker -match '(?i)SessionPath') 'Worker must accept an explicit session path.'
    Assert-True ($Worker -match 'Resolve-ScreenAgentSessionPath') 'Worker must validate that SessionPath stays inside sessions_dir.'
    Assert-True ($Starter -match 'run_session_worker_hidden\.vbs') 'Recording launcher must invoke the hidden session wrapper.'
    Assert-True ($Starter -notmatch '(?i)WorkerArguments\s*=.*\bSession\b') 'Recording launcher must not pass a mode switch.'
    Assert-True ($Starter -match '(?i)SessionPath|SessionFile|SessionJson') 'Recording launcher must pass the newly created session file to the worker.'
    Assert-True ($Wrapper -match 'WScript\.Arguments\.Count\s*<>\s*1') 'VBS wrapper must accept exactly one session path.'
    Assert-True ($Wrapper -match 'session_worker\.ps1') 'VBS wrapper must target only the session worker.'
    Assert-True ($Wrapper -notmatch '(?i)Recovery|RunMode') 'VBS wrapper must not expose recovery or mode switching.'
    Assert-True ($Wrapper -match '(?i)SessionPath|sessionPath|sessionFile|WScript\.Arguments') 'VBS wrapper must forward the explicit session file.'
}

Invoke-Test 'Empty session worker exits within a deterministic timeout' {
    $Base = Join-Path ([System.IO.Path]::GetTempPath()) ('screenagent-session-exit-' + [guid]::NewGuid().ToString('N'))
    $Raw = Join-Path $Base 'recordings\raw'
    $Uploaded = Join-Path $Base 'recordings\uploaded'
    $Sessions = Join-Path $Base 'sessions'
    $Logs = Join-Path $Base 'logs'
    New-Item -ItemType Directory -Force -Path $Raw, $Uploaded, $Sessions, $Logs | Out-Null
    $ConfigPath = Join-Path $Base 'config.json'
    $SessionPath = Join-Path $Sessions 'empty-session.json'
    $Utf8Bom = New-Object System.Text.UTF8Encoding($true)
    $Config = [ordered]@{
        base_dir = $Base
        raw_dir = $Raw
        uploaded_dir = $Uploaded
        sessions_dir = $Sessions
        logs_dir = $Logs
        mode = 'local_only'
        cleanup_mode = 'move_after_verified_upload'
        stable_seconds = 5
        scan_interval_seconds = 2
    }
    $Session = [ordered]@{
        id = 'empty-session'
        category = 'test'
        topic = 'lifecycle'
        title = 'empty'
        start_time = (Get-Date).ToString('s')
        cleanup_mode = 'move_after_verified_upload'
        baseline_files = @()
    }
    [System.IO.File]::WriteAllText($ConfigPath, ($Config | ConvertTo-Json -Depth 5), $Utf8Bom)
    [System.IO.File]::WriteAllText($SessionPath, ($Session | ConvertTo-Json -Depth 5), $Utf8Bom)
    $Process = $null
    try {
        $Info = New-Object System.Diagnostics.ProcessStartInfo
        $Info.FileName = 'powershell.exe'
        $Info.Arguments = ('-NoProfile -ExecutionPolicy Bypass -File "{0}" -SessionPath "{1}" -NoFileTimeoutSeconds 5 -DeadlineMinutes 1 -QuietSeconds 1' -f (Join-Path $ProjectRoot 'session_worker.ps1'), $SessionPath)
        $Info.UseShellExecute = $false
        $Info.CreateNoWindow = $true
        $Info.EnvironmentVariables['SCREENAGENT_ACCEPTANCE_MODE'] = '1'
        $Info.EnvironmentVariables['SCREENAGENT_CONFIG_PATH'] = $ConfigPath
        $Process = New-Object System.Diagnostics.Process
        $Process.StartInfo = $Info
        Assert-True $Process.Start() 'Session worker process did not start.'
        $Exited = $Process.WaitForExit(15000)
        Assert-True $Exited 'Empty session worker did not exit within fifteen seconds.'
        Assert-Equal 0 $Process.ExitCode 'Empty session worker must exit successfully after its no-file timeout.'
    }
    finally {
        if ($null -ne $Process) {
            if (-not $Process.HasExited) { $Process.Kill() }
            $Process.Dispose()
        }
        Remove-Item -LiteralPath $Base -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Invoke-Test 'Session worker processes one new recording and exits' {
    $Base = Join-Path ([System.IO.Path]::GetTempPath()) ('screenagent-session-success-' + [guid]::NewGuid().ToString('N'))
    $Raw = Join-Path $Base 'recordings\raw'
    $Uploaded = Join-Path $Base 'recordings\uploaded'
    $Sessions = Join-Path $Base 'sessions'
    $Logs = Join-Path $Base 'logs'
    New-Item -ItemType Directory -Force -Path $Raw, $Uploaded, $Sessions, $Logs | Out-Null
    $ConfigPath = Join-Path $Base 'config.json'
    $SessionPath = Join-Path $Sessions 'success-session.json'
    $Source = Join-Path $Raw 'new-recording.mkv'
    $Utf8Bom = New-Object System.Text.UTF8Encoding($true)
    $Config = [ordered]@{
        base_dir = $Base
        raw_dir = $Raw
        uploaded_dir = $Uploaded
        sessions_dir = $Sessions
        logs_dir = $Logs
        mode = 'local_only'
        cleanup_mode = 'move_after_verified_upload'
        stable_seconds = 5
        scan_interval_seconds = 2
    }
    $StartedAt = Get-Date
    $Session = [ordered]@{
        id = 'success-session'
        category = 'test'
        topic = 'lifecycle'
        title = 'new-recording'
        start_time = $StartedAt.ToString('s')
        start_time_utc = $StartedAt.ToUniversalTime().ToString('o')
        cleanup_mode = 'move_after_verified_upload'
        baseline_files = @()
    }
    [System.IO.File]::WriteAllText($ConfigPath, ($Config | ConvertTo-Json -Depth 5), $Utf8Bom)
    [System.IO.File]::WriteAllText($SessionPath, ($Session | ConvertTo-Json -Depth 5), $Utf8Bom)
    [System.IO.File]::WriteAllBytes($Source, [byte[]](1..64))
    $SourceHash = (Get-FileHash -LiteralPath $Source -Algorithm SHA256).Hash
    $Process = $null
    try {
        $Info = New-Object System.Diagnostics.ProcessStartInfo
        $Info.FileName = 'powershell.exe'
        $Info.Arguments = ('-NoProfile -ExecutionPolicy Bypass -File "{0}" -SessionPath "{1}" -NoFileTimeoutSeconds 10 -DeadlineMinutes 1 -QuietSeconds 1' -f (Join-Path $ProjectRoot 'session_worker.ps1'), $SessionPath)
        $Info.UseShellExecute = $false
        $Info.CreateNoWindow = $true
        $Info.EnvironmentVariables['SCREENAGENT_ACCEPTANCE_MODE'] = '1'
        $Info.EnvironmentVariables['SCREENAGENT_CONFIG_PATH'] = $ConfigPath
        $Process = New-Object System.Diagnostics.Process
        $Process.StartInfo = $Info
        Assert-True $Process.Start() 'Session worker process did not start.'
        $Exited = $Process.WaitForExit(30000)
        Assert-True $Exited 'Session worker did not exit after processing a stable recording.'
        Assert-Equal 0 $Process.ExitCode 'Successful session worker must exit with code zero.'
        Assert-Equal 0 @(Get-ChildItem -LiteralPath $Raw -File).Count 'Processed recording must leave raw.'
        $Saved = @(Get-ChildItem -LiteralPath $Uploaded -File)
        Assert-Equal 1 $Saved.Count 'Session worker must save exactly one recording.'
        Assert-Equal $SourceHash (Get-FileHash -LiteralPath $Saved[0].FullName -Algorithm SHA256).Hash 'Saved recording bytes must remain unchanged.'
        $UpdatedSession = Get-Content -LiteralPath $SessionPath -Raw -Encoding UTF8 | ConvertFrom-Json
        Assert-Equal 'completed' ([string]$UpdatedSession.status) 'Session file must record terminal completion.'
    }
    finally {
        if ($null -ne $Process) {
            if (-not $Process.HasExited) { $Process.Kill() }
            $Process.Dispose()
        }
        Remove-Item -LiteralPath $Base -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Write-Host ''
Write-Host "Tests passed: $script:Passed"
Write-Host "Tests failed: $script:Failed"
if ($script:Failed -gt 0) { exit 1 }
