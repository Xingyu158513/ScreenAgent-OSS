@echo off
setlocal
chcp 65001 >nul
echo 正在打开官方软件下载页面和坚果云授权说明...
start "" "https://obsproject.com/download"
start "" "https://rclone.org/downloads/"
start "" "https://help.jianguoyun.com/?p=2064"
echo.
echo 只从官方页面下载软件。下载完成后，请阅读 docs\安装前准备.md。
pause
