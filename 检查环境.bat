@echo off
setlocal
chcp 65001 >nul
set "SCRIPT_DIR=%~dp0"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT_DIR%check_environment.ps1"
set "EXITCODE=%ERRORLEVEL%"
echo.
pause
exit /b %EXITCODE%
