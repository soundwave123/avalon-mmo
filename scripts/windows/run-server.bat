@echo off
rem Avalon — start the full server stack on Windows (double-click me).
rem Requires Docker Desktop (running) and Godot 4.7.1 for Windows — see run-server.ps1 for details.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0run-server.ps1"
pause
