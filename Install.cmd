@echo off
setlocal
set "PSModulePath="
"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -STA -ExecutionPolicy Bypass -File "%~dp0scripts\Bootstrap.ps1" %*
set "CODEX_DUAL_EXIT_CODE=%errorlevel%"
if not "%CODEX_DUAL_EXIT_CODE%"=="0" pause
exit /b %CODEX_DUAL_EXIT_CODE%
