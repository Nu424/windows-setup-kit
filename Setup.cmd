@echo off
rem Windows setup entry point. Double-click this file.
rem All settings live in settings.ps1 / all payload files live in assets\.
rem Extra arguments are passed through to setup.ps1 (e.g. Setup.cmd -DryRun).

cd /d "%~dp0"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0setup.ps1" %*

if errorlevel 1 (
  echo.
  echo Setup finished with errors. See the log file next to this script.
  pause
)
