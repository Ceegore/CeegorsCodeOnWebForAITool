@echo off
setlocal
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0tests\Test-WorkspaceShare.ps1" %*
exit /b %ERRORLEVEL%
