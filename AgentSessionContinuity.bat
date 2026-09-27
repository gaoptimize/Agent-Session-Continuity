@echo off
setlocal

set "PWSH="
for %%P in (pwsh.exe) do set "PWSH=%%~$PATH:P"

if not defined PWSH (
  echo Agent Session Continuity requires PowerShell 7 or later ^(pwsh.exe^).
  echo Install PowerShell 7, reopen this window, and try again.
  exit /b 1
)

"%PWSH%" -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0AgentSessionContinuity.ps1" %*
set "EXIT_CODE=%ERRORLEVEL%"

if "%~1"=="" pause
exit /b %EXIT_CODE%

