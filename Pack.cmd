@echo off
rem Build a dated distribution zip under dist\.
rem Extra arguments are passed through to pack.ps1 (e.g. Pack.cmd -DryRun).

cd /d "%~dp0"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0pack.ps1" %*

if errorlevel 1 (
  echo.
  echo Pack failed.
  pause
)
