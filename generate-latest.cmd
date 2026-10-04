@echo off
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\build-latest.ps1" %*
if errorlevel 1 echo Generation failed. Read the error above.
pause
