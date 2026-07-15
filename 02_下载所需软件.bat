@echo off
setlocal
chcp 65001 >nul
echo 正在打开 OBS、rclone 和坚果云授权的官方页面...
start "" "https://obsproject.com/download"
start "" "https://rclone.org/downloads/"
start "" "https://help.jianguoyun.com/?p=2064"
echo.
echo 请只从官方页面下载软件。完成后运行 03_安装ScreenAgent.bat。
pause
