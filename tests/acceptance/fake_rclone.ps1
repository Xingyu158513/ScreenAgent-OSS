$ErrorActionPreference = 'Stop'

function Fail {
    param([string]$Message, [int]$Code = 1)
    [Console]::Error.WriteLine($Message)
    exit $Code
}

function Convert-RemotePath {
    param([string]$RemotePath)
    $Separator = $RemotePath.IndexOf(':')
    if ($Separator -lt 1) { Fail "Invalid fake remote path: $RemotePath" }
    $Relative = $RemotePath.Substring($Separator + 1).TrimStart('/', '\') -replace '/', '\'
    return Join-Path $env:SCREENAGENT_FAKE_REMOTE_ROOT $Relative
}

$Arguments = New-Object System.Collections.Generic.List[string]
foreach ($Value in $args) { $Arguments.Add([string]$Value) }
if ($Arguments.Count -ge 2 -and $Arguments[0] -eq '--config') {
    $Arguments.RemoveAt(0)
    $Arguments.RemoveAt(0)
}
if ($Arguments.Count -lt 1) { Fail 'No fake rclone command was supplied.' }
if ([string]::IsNullOrWhiteSpace($env:SCREENAGENT_FAKE_REMOTE_ROOT)) { Fail 'Fake remote root is missing.' }

$Command = $Arguments[0]
switch ($Command) {
    'mkdir' {
        if ($Arguments.Count -lt 2) { Fail 'mkdir requires a remote path.' }
        New-Item -ItemType Directory -Force -Path (Convert-RemotePath $Arguments[1]) | Out-Null
        exit 0
    }
    'lsd' {
        if ($Arguments.Count -lt 2) { Fail 'lsd requires a remote path.' }
        New-Item -ItemType Directory -Force -Path (Convert-RemotePath $Arguments[1]) | Out-Null
        exit 0
    }
    'lsjson' {
        if ($Arguments.Count -lt 2) { Fail 'lsjson requires a remote path.' }
        $Directory = Convert-RemotePath $Arguments[1]
        $Items = @()
        if (Test-Path -LiteralPath $Directory) {
            $Items = @(Get-ChildItem -LiteralPath $Directory -File | ForEach-Object {
                [pscustomobject]@{ Name = $_.Name; Size = [Int64]$_.Length }
            })
        }
        Write-Output (ConvertTo-Json -InputObject @($Items) -Compress)
        exit 0
    }
    'copyto' {
        if ($Arguments.Count -lt 3) { Fail 'copyto requires a source and destination.' }
        if ($env:SCREENAGENT_FAKE_RCLONE_MODE -eq 'fail_upload') {
            Fail 'Simulated upload failure.' 9
        }
        $Source = $Arguments[1]
        $Destination = Convert-RemotePath $Arguments[2]
        if (-not (Test-Path -LiteralPath $Source -PathType Leaf)) { Fail "Source does not exist: $Source" }
        if (Test-Path -LiteralPath $Destination) { Fail "Immutable destination already exists: $Destination" }
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $Destination) | Out-Null
        Copy-Item -LiteralPath $Source -Destination $Destination
        exit 0
    }
    default { Fail "Unsupported fake rclone command: $Command" }
}
