@echo off
setlocal
chcp 65001 >nul
set "ROOT=%~dp0"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%ROOT%程序文件（请勿修改）\check_environment.ps1"
set "EXITCODE=%ERRORLEVEL%"
echo.
pause
exit /b %EXITCODE%
