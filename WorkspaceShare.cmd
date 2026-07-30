@echo off
setlocal
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0Share-Workspace.ps1" %*
exit /b %ERRORLEVEL%
