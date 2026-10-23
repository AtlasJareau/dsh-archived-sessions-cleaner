@echo off
setlocal
set "SCRIPT=%~dp0delete-archived-sessions.ps1"
if not exist "%SCRIPT%" (
  echo [ERROR] delete-archived-sessions.ps1 not found next to this .cmd
  pause
  exit /b 1
)
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT%" %*
set "RC=%ERRORLEVEL%"
echo.
if not "%RC%"=="0" echo [exit code: %RC%]
pause
exit /b %RC%
