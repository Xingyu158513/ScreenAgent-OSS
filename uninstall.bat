@echo off
setlocal
chcp 65001 >nul
set "SCRIPT_DIR=%~dp0"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT_DIR%uninstall.ps1"
set "EXITCODE=%ERRORLEVEL%"
echo.
pause
exit /b %EXITCODE%
