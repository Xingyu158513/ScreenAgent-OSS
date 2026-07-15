@echo off
setlocal
chcp 65001 >nul
set "ROOT=%~dp0"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%ROOT%程序文件（请勿修改）\install.ps1"
set "EXITCODE=%ERRORLEVEL%"
echo.
if not "%EXITCODE%"=="0" (
  echo 安装未完成，退出码：%EXITCODE%
) else (
  echo 安装完成。现在可以使用桌面的“启动录制”快捷方式。
)
pause
exit /b %EXITCODE%
