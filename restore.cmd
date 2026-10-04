@echo off
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\restore.ps1" %*
set "patchExitCode=%ERRORLEVEL%"
if not "%patchExitCode%"=="0" echo Restore failed. No need to run as administrator. Read the error above.
pause
exit /b %patchExitCode%
