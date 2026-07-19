$ErrorActionPreference = 'Stop'

$ArchiveModule = Join-Path $PSScriptRoot 'lib\ScreenAgent.Archive.psm1'
Import-Module $ArchiveModule -Force

try {
    $Config = Get-ScreenAgentRuntimeConfig
    $Runtime = Initialize-ScreenAgentArchive -Config $Config
    $Session = New-ScreenAgentRecoverySession
    $Files = @(Get-ScreenAgentVideoFiles)

    if ($Files.Count -eq 0) {
        Write-Host 'raw 文件夹中没有待恢复的录像。' -ForegroundColor Green
        exit 0
    }

    $Processed = 0
    $Pending = 0
    $Failed = 0
    foreach ($File in $Files) {
        $Result = Invoke-ScreenAgentArchiveFile -Path $File.FullName -Session $Session
        switch ($Result) {
            'Processed' { $Processed++ }
            'AlreadyProcessed' { $Processed++ }
            'Pending' { $Pending++ }
            default { $Failed++ }
        }
    }

    Write-Host "恢复完成：成功 $Processed，仍在写入 $Pending，失败并保留 $Failed。"
    if (($Pending + $Failed) -gt 0) {
        Write-Host '未成功处理的文件仍保留在 raw，可稍后再次运行。' -ForegroundColor Yellow
    }
    exit 0
}
catch {
    Write-Host "恢复失败：$($_.Exception.Message)" -ForegroundColor Red
    Write-Host '程序不会因本次失败删除 raw 中的录像。' -ForegroundColor Yellow
    exit 1
}
