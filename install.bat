@echo off
setlocal
chcp 65001 >nul
set "SCRIPT_DIR=%~dp0"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT_DIR%install.ps1"
set "EXITCODE=%ERRORLEVEL%"
echo.
if not "%EXITCODE%"=="0" (
  echo 安装未完成，退出码：%EXITCODE%
) else (
  echo 安装完成。
)
pause
exit /b %EXITCODE%
