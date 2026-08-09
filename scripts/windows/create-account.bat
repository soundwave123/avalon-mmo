@echo off
rem Avalon — create a player account on your own server (double-click me).
set /p AV_USER="Username (lowercase, 3-20 chars, a-z 0-9 _ -): "
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0create-account.ps1" %AV_USER%
pause
