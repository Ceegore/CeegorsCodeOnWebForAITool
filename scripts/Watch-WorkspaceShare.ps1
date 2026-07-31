#requires -Version 5.1
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][int]$ParentPid,
    [Parameter(Mandatory = $true)][long]$ParentStartTicks,
    [Parameter(Mandatory = $true)][string]$ExpectedParentPath,
    [Parameter(Mandatory = $true)][int]$MiniservePid,
    [Parameter(Mandatory = $true)][long]$MiniserveStartTicks,
    [Parameter(Mandatory = $true)][int]$CloudflaredPid,
    [Parameter(Mandatory = $true)][long]$CloudflaredStartTicks,
    [Parameter(Mandatory = $true)][string]$SessionPath,
    [Parameter(Mandatory = $true)][string]$NormalExitMarker,
    [Parameter(Mandatory = $true)][string]$ReadyMarker,
    [Parameter(Mandatory = $true)][datetime]$ExpiresUtc,
    [Parameter(Mandatory = $true)][string]$ExpectedMiniservePath,
    [Parameter(Mandatory = $true)][string]$ExpectedCloudflaredPath,
    [switch]$KeepArchive
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$processModulePath = Join-Path (Split-Path $PSScriptRoot -Parent) 'scripts\WorkspaceShare.Process.psm1'
Import-Module -Name $processModulePath -Force -ErrorAction Stop

function Test-GoneState { param($State) return $State.State -in @('Absent', 'Conflict') }

try {
    New-Item -ItemType File -Path $ReadyMarker -Force -ErrorAction Stop | Out-Null
}
catch { exit 50 }

while ($true) {
    if (Test-Path -LiteralPath $NormalExitMarker -PathType Leaf) {
        $cloudState = Get-ProcessIdentityState -ProcessId $CloudflaredPid -ExpectedPath $ExpectedCloudflaredPath -ExpectedStartTicks $CloudflaredStartTicks
        $serverState = Get-ProcessIdentityState -ProcessId $MiniservePid -ExpectedPath $ExpectedMiniservePath -ExpectedStartTicks $MiniserveStartTicks
        if ((Test-GoneState $cloudState) -and (Test-GoneState $serverState)) { exit 0 }
    }

    $parentState = Get-ProcessIdentityState -ProcessId $ParentPid -ExpectedPath $ExpectedParentPath -ExpectedStartTicks $ParentStartTicks
    if ($parentState.State -in @('Absent', 'Conflict')) { break }
    if ($parentState.State -eq 'Unknown') { Start-Sleep -Seconds 2; continue }
    if ([DateTime]::UtcNow -ge $ExpiresUtc.ToUniversalTime()) { break }
    Start-Sleep -Seconds 2
}

$cloudStopped = Stop-TrackedProcessConfirmed -ProcessId $CloudflaredPid -ExpectedPath $ExpectedCloudflaredPath -ExpectedStartTicks $CloudflaredStartTicks -Attempts 60 -WaitMilliseconds 1000
Start-Sleep -Milliseconds 300
$serverStopped = Stop-TrackedProcessConfirmed -ProcessId $MiniservePid -ExpectedPath $ExpectedMiniservePath -ExpectedStartTicks $MiniserveStartTicks -Attempts 60 -WaitMilliseconds 1000
if (-not ($cloudStopped -and $serverStopped)) { exit 51 }

if ($KeepArchive) {
    try { New-Item -ItemType File -Path (Join-Path $SessionPath 'keep.archive') -Force | Out-Null } catch {}
}
else {
    try { Remove-Item -LiteralPath $SessionPath -Recurse -Force -ErrorAction Stop } catch { exit 52 }
    if (Test-Path -LiteralPath $SessionPath) { exit 52 }
}
exit 0
