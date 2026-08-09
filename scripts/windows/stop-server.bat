@echo off
rem Avalon — stop the server stack started by run-server.bat.
rem Kills the three headless Godot server processes and stops the Postgres container
rem (data is kept — it lives in the avalon-pgdata Docker volume).
echo [avalon] stopping Godot server processes...
taskkill /F /FI "IMAGENAME eq Godot*" >nul 2>&1
echo [avalon] stopping Postgres container...
docker stop avalon-postgres >nul 2>&1
echo [avalon] done.
pause
