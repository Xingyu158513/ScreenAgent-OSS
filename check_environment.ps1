$ErrorActionPreference = 'Continue'

function Show-Result {
    param([string]$Name, [bool]$Passed, [string]$Detail)
    $Mark = if ($Passed) { '[通过]' } else { '[需要处理]' }
    $Color = if ($Passed) { 'Green' } else { 'Yellow' }
    Write-Host ("{0} {1}：{2}" -f $Mark, $Name, $Detail) -ForegroundColor $Color
}

Write-Host ''
Write-Host 'ScreenAgent 安装前环境检查' -ForegroundColor Cyan
Write-Host ''

$OsOk = [Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT
Show-Result 'Windows' $OsOk ([Environment]::OSVersion.VersionString)

$PsOk = $PSVersionTable.PSVersion.Major -ge 5
Show-Result 'PowerShell' $PsOk ($PSVersionTable.PSVersion.ToString())

$ObsCandidates = @(
    'C:\Program Files\obs-studio\bin\64bit\obs64.exe',
    'C:\Program Files (x86)\obs-studio\bin\64bit\obs64.exe'
)
$Obs = $ObsCandidates | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
Show-Result 'OBS Studio' ([bool]$Obs) $(if ($Obs) { $Obs } else { '未在常见路径找到；请安装或稍后在向导中指定路径' })

$RcloneCandidates = @(
    (Join-Path $PSScriptRoot 'rclone.exe'),
    (Join-Path $PSScriptRoot 'tools\rclone.exe'),
    'C:\Tools\rclone\rclone.exe'
)
$Rclone = $RcloneCandidates | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
if (-not $Rclone) {
    $Command = Get-Command rclone.exe -ErrorAction SilentlyContinue
    if ($Command) { $Rclone = $Command.Source }
}
Show-Result 'rclone' ([bool]$Rclone) $(if ($Rclone) { $Rclone } else { '未找到；云端模式需要下载，纯本地模式不需要' })

$Root = Join-Path $env:USERPROFILE 'ScreenAgent'
$WriteOk = $false
try {
    New-Item -ItemType Directory -Force -Path $Root | Out-Null
    $Probe = Join-Path $Root ('.write-test-' + [guid]::NewGuid().ToString('N'))
    'ok' | Set-Content -LiteralPath $Probe -Encoding UTF8
    Remove-Item -LiteralPath $Probe -Force
    $WriteOk = $true
} catch {}
Show-Result '用户目录写入权限' $WriteOk $Root

Write-Host ''
Write-Host '说明：云端账号、应用密码和连接测试会在安装配置向导中完成。'
if (-not ($OsOk -and $PsOk -and $WriteOk)) { exit 1 }
exit 0
