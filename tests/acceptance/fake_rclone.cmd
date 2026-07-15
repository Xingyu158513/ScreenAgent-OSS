@echo off
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0fake_rclone.ps1" %*
exit /b %ERRORLEVEL%
