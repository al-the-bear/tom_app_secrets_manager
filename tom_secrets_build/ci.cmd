@echo off
rem Manually driven CI for the Tom Secrets Manager - Windows (cmd.exe).
rem Starts ci.ps1 with the same arguments, e.g.  ci.cmd :all
rem Started by a person; nothing schedules it. See README.md.
setlocal
set "PS=powershell"
where pwsh >nul 2>nul && set "PS=pwsh"
%PS% -NoProfile -ExecutionPolicy Bypass -File "%~dp0ci.ps1" %*
exit /b %ERRORLEVEL%
