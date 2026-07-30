@echo off
setlocal
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0Stop-WorkspaceShare.ps1" %*
exit /b %ERRORLEVEL%
