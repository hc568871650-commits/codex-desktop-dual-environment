@echo off
if not exist "%~dp0instances.local.json" (
  echo An existing instances.local.json is required for this migration build.
  pause
  exit /b 1
)
start "" "%~dp0CodexDualController.exe" --config "%~dp0instances.local.json" %*
