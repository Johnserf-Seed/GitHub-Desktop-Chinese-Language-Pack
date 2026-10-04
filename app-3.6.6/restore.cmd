@echo off
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0restore.ps1" %*
if errorlevel 1 echo Restore failed. Read the error above.
pause
