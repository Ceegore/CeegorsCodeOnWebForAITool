@echo off
echo Bitte keinen Batch-Launcher verwenden.
echo Oeffne PowerShell im Projektordner und fuehre aus:
echo   .\Install-Dependencies.ps1
echo.
echo Falls die Dateien aus einem ZIP stammen:
echo   Get-ChildItem -File -Recurse -Filter *.ps1 ^| Unblock-File
exit /b 1
