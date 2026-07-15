$ErrorActionPreference = 'Continue'
$Root = Join-Path $env:USERPROFILE 'ScreenAgent'
$LogDir = Join-Path $Root 'logs'
$Report = Join-Path $LogDir 'report.txt'
$Csv = Join-Path $LogDir 'index.csv'

New-Item -ItemType Directory -Force -Path $LogDir | Out-Null
if (-not (Test-Path -LiteralPath $Report)) {
    "ScreenAgent 暂无日志。`r`nCSV 日志位置：$Csv" | Set-Content -LiteralPath $Report -Encoding UTF8
}
Start-Process notepad.exe -ArgumentList "`"$Report`""
