$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

$ProjectRoot = Split-Path -Parent $PSScriptRoot
$ModulePath = Join-Path $ProjectRoot 'lib\ScreenAgent.Security.psm1'
Import-Module $ModulePath -Force

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
    $Uploader = Get-Content -LiteralPath (Join-Path $ProjectRoot 'auto_archive.ps1') -Raw -Encoding UTF8
    $Wizard = Get-Content -LiteralPath (Join-Path $ProjectRoot 'config_wizard.ps1') -Raw -Encoding UTF8
    Assert-True ($Uploader -match '@\(''--config'', \$script:RcloneConfigPath\)') 'Uploader must prepend the dedicated config path.'
    Assert-True ($Wizard -match 'rclone_config_path') 'Wizard must persist the dedicated config path.'
    Assert-True ($Wizard -match 'Protect-ScreenAgentCredentialFile') 'Wizard must restrict credential file access.'
}

Invoke-Test 'Production scripts contain no automatic permanent-delete mode' {
    $Uploader = Get-Content -LiteralPath (Join-Path $ProjectRoot 'auto_archive.ps1') -Raw -Encoding UTF8
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

Invoke-Test 'Scheduled task name is fixed and cannot be redirected by config' {
    $Installer = Get-Content -LiteralPath (Join-Path $ProjectRoot 'install.ps1') -Raw -Encoding UTF8
    $Uninstaller = Get-Content -LiteralPath (Join-Path $ProjectRoot 'uninstall.ps1') -Raw -Encoding UTF8
    $Spec = Get-ScreenAgentScheduledTaskSpec -AppDirectory 'C:\Users\Example\ScreenAgent\app'
    Assert-Equal 'ScreenAgent-AutoUpload' $Spec.TaskName 'Task name must be fixed.'
    Assert-Equal 'wscript.exe' $Spec.Execute 'Task executable must be Windows Script Host.'
    Assert-True ($Spec.WorkerPath.EndsWith('ScreenAgent\app\run_auto_archive_hidden.vbs')) 'Task worker must stay inside the ScreenAgent app directory.'
    Assert-Equal ('"{0}"' -f $Spec.WorkerPath) $Spec.Argument 'Task worker path must be quoted.'
    Assert-True ($Installer -match 'Get-ScreenAgentScheduledTaskSpec') 'Installer must use the tested task specification.'
    Assert-True ($Uninstaller -match '\$TaskName\s*=\s*''ScreenAgent-AutoUpload''') 'Uninstaller must use the fixed task name.'
    Assert-True ($Installer -notmatch '\$Config\.task_name') 'Installer must ignore config-supplied task names.'
    Assert-True ($Uninstaller -notmatch '\$Config\.task_name') 'Uninstaller must ignore config-supplied task names.'
}

Write-Host ''
Write-Host "Tests passed: $script:Passed"
Write-Host "Tests failed: $script:Failed"
if ($script:Failed -gt 0) { exit 1 }
