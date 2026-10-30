@echo off
start "" "%~dp0CodexDualController.exe" --configure --config "%~dp0instances.local.json" %*
