@echo off
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\generate.ps1" %*
if errorlevel 1 echo Generation failed. Read the error above.
pause
