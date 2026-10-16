#requires -Version 5.1
# Creates (or removes) the WorkspaceShare shortcut on the desktop and in the Start menu.
# The shortcut starts the signed powershell.exe with Start-WorkspaceShareGui.ps1 (no .cmd, no Bypass).
[CmdletBinding()]
param(
    [switch]$Desktop,
    [switch]$StartMenu,
    [switch]$Remove,
    [string]$TargetDirectory
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path (Join-Path $PSScriptRoot 'scripts') 'WorkspaceShare.Platform.psm1') -Force -ErrorAction Stop

if ((Get-WsPlatform) -ne 'windows') {
    Write-Warning 'Noch nicht unterstützt (siehe docs\LINUX_PLAN.md)'
    exit 0
}

# Desktop and Start menu are the defaults; naming one of them restricts the choice.
$wantDesktop = $true
$wantStartMenu = $true
if ($PSBoundParameters.ContainsKey('Desktop') -or $PSBoundParameters.ContainsKey('StartMenu')) {
    $wantDesktop = [bool]$Desktop
    $wantStartMenu = [bool]$StartMenu
}

$directories = @()
if (-not [string]::IsNullOrWhiteSpace($TargetDirectory)) {
    $directories += $TargetDirectory
}
else {
    if ($wantDesktop) { $directories += [Environment]::GetFolderPath('Desktop') }
    if ($wantStartMenu) { $directories += [Environment]::GetFolderPath('Programs') }
}

$shortcutName = 'WorkspaceShare.lnk'
$repo = $PSScriptRoot
$startScript = Join-Path $repo 'Start-WorkspaceShareGui.ps1'

if ($Remove) {
    foreach ($dir in $directories) {
        $link = Join-Path $dir $shortcutName
        if (Test-Path -LiteralPath $link -PathType Leaf) {
            Remove-Item -LiteralPath $link -Force
            Write-Host "Entfernt: $link"
        }
    }
    exit 0
}

if (-not (Test-Path -LiteralPath $startScript -PathType Leaf)) {
    Write-Error "Start-WorkspaceShareGui.ps1 wurde nicht gefunden: $startScript"
    exit 1
}

$shell = New-Object -ComObject WScript.Shell
try {
    foreach ($dir in $directories) {
        if (-not (Test-Path -LiteralPath $dir -PathType Container)) { [void](New-Item -ItemType Directory -Path $dir -Force) }
        $link = Join-Path $dir $shortcutName
        $sc = $shell.CreateShortcut($link)
        $sc.TargetPath = Get-WsPowerShellHost
        $sc.Arguments = '-NoLogo -NoProfile -STA -WindowStyle Hidden -File "' + $startScript + '"'
        $sc.WorkingDirectory = $repo
        $sc.IconLocation = (Join-Path $env:SystemRoot 'System32\shell32.dll') + ',146'
        $sc.Description = 'WorkspaceShare – Ordner sicher teilen'
        $sc.WindowStyle = 7
        $sc.Save()
        Write-Host "Verknüpfung erstellt: $link"
    }
}
finally {
    [void][Runtime.InteropServices.Marshal]::ReleaseComObject($shell)
}
exit 0
