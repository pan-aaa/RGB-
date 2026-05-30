@echo off
setlocal
cd /d "%~dp0"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0sync-artifacts-and-push.ps1"
set "exit_code=%ERRORLEVEL%"
if not "%exit_code%"=="0" (
  echo.
  echo Sync failed with exit code %exit_code%.
  pause
  exit /b %exit_code%
)
echo.
echo Sync finished successfully.
pause
