$ErrorActionPreference = 'Continue'

function Write-Step {
    param([string]$Message)
    Write-Host "[ScreenAgent] $Message" -ForegroundColor Cyan
}

$TaskName = 'ScreenAgent-AutoUpload'
$SecurityModule = Join-Path $PSScriptRoot 'lib\ScreenAgent.Security.psm1'
if (Test-Path -LiteralPath $SecurityModule) {
    Import-Module $SecurityModule -Force
}
$AcceptanceMode = $env:SCREENAGENT_ACCEPTANCE_MODE -eq '1'
if ($AcceptanceMode -and -not (Get-Command Resolve-ScreenAgentInstallRoot -ErrorAction SilentlyContinue)) {
    throw '验收模式需要安全模块。'
}
$Root = if ($AcceptanceMode) {
    Resolve-ScreenAgentInstallRoot -DefaultRoot (Join-Path $env:USERPROFILE 'ScreenAgent') -AcceptanceMode $true -RequestedRoot $env:SCREENAGENT_INSTALL_ROOT
} else {
    Join-Path $env:USERPROFILE 'ScreenAgent'
}
$AppDir = Join-Path $Root 'app'
$ConfigPath = Join-Path $Root 'config\config.json'
$ProductName = 'ScreenAgent'
$ShortcutName = '启动录制-ScreenAgent'
if (Test-Path -LiteralPath $ConfigPath) {
    try {
        $Config = Get-Content -LiteralPath $ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($Config.product_name -and (Get-Command ConvertTo-ScreenAgentSafeSegment -ErrorAction SilentlyContinue)) {
            $ProductName = ConvertTo-ScreenAgentSafeSegment -Value ([string]$Config.product_name) -Fallback 'ScreenAgent'
        }
        if ($Config.shortcut_name -and (Get-Command ConvertTo-ScreenAgentSafeSegment -ErrorAction SilentlyContinue)) {
            $ShortcutName = ConvertTo-ScreenAgentSafeSegment -Value ([string]$Config.shortcut_name) -Fallback '启动录制-ScreenAgent'
        }
    }
    catch {}
}
$Desktop = if ($AcceptanceMode) { Join-Path $Root 'desktop' } else { [Environment]::GetFolderPath('Desktop') }
$Shortcuts = @(
    (Join-Path $Desktop ($ShortcutName + '.lnk')),
    (Join-Path $Desktop ("查看 $ProductName 日志.lnk")),
    (Join-Path $Desktop '启动录制-ScreenAgent.lnk'),
    (Join-Path $Desktop '查看 ScreenAgent 日志.lnk')
)

Write-Host ''
Write-Host 'ScreenAgent 卸载程序' -ForegroundColor Green
Write-Host ''

Write-Step '停止并删除计划任务'
if ($AcceptanceMode -and $env:SCREENAGENT_ACCEPTANCE_SKIP_TASK -eq '1') {
    Write-Host '验收模式：跳过真实计划任务操作。'
}
else {
try {
    $Task = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    if ($Task) {
        Stop-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
        Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
        Write-Host "已删除计划任务：$TaskName"
    }
    else {
        Write-Host "计划任务不存在：$TaskName"
    }
}
catch {
    Write-Host "删除计划任务失败：$($_.Exception.Message)" -ForegroundColor Yellow
}
}

Write-Step '删除桌面快捷方式'
foreach ($Shortcut in $Shortcuts) {
    if (Test-Path -LiteralPath $Shortcut) {
        Remove-Item -LiteralPath $Shortcut -Force -ErrorAction SilentlyContinue
        Write-Host "已删除：$Shortcut"
    }
}

Write-Host ''
Write-Host '默认不会删除录屏文件、日志和配置。' -ForegroundColor Yellow
Write-Host "用户数据目录：$Root"
$DeleteApp = if ($AcceptanceMode -and $env:SCREENAGENT_UNINSTALL_DELETE_APP -eq '1') { 'DELETEAPP' } else { Read-Host '是否删除程序文件 app 目录？输入 DELETEAPP 确认' }
if ($DeleteApp -eq 'DELETEAPP') {
    if (Get-Command Remove-ScreenAgentProgramDirectory -ErrorAction SilentlyContinue) {
        try {
            if (Remove-ScreenAgentProgramDirectory -AppDirectory $AppDir -ScreenAgentRoot $Root -Confirmed $true) {
                Write-Host "已删除程序目录：$AppDir"
            }
        }
        catch {
            Write-Host "程序目录安全检查失败，已保留：$($_.Exception.Message)" -ForegroundColor Yellow
        }
    }
    else {
        Write-Host '安全模块不可用，程序目录已保留。' -ForegroundColor Yellow
    }
}

Write-Host '录屏、日志和配置始终保留，卸载器不会递归删除用户数据。' -ForegroundColor Yellow
Write-Host "如确实需要清理，请先备份并在资源管理器中手动检查：$Root"

Write-Host ''
Write-Host '卸载完成。' -ForegroundColor Green
