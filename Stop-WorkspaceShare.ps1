#requires -Version 5.1
[CmdletBinding()]
param([switch]$KeepArchives)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Continue'
$processModulePath = Join-Path $PSScriptRoot 'scripts\WorkspaceShare.Process.psm1'
try { Import-Module -Name $processModulePath -Force -ErrorAction Stop } catch { [Console]::Error.WriteLine("Shared process module could not be loaded: $($_.Exception.Message)"); exit 1 }
$sessionBase = if ($env:LOCALAPPDATA) { Join-Path $env:LOCALAPPDATA 'WorkspaceShare\sessions' } else { Join-Path ([IO.Path]::GetTempPath()) 'WorkspaceShare\sessions' }
$exitCode = 0

function Stop-SessionProcess {
    param($Session, [string]$Prefix, [string]$Role)
    $stopped = Stop-TrackedProcessConfirmed -ProcessId ([int]$Session.($Prefix + 'Pid')) -ExpectedPath ([string]$Session.($Prefix + 'Path')) -ExpectedStartTicks ([long]$Session.($Prefix + 'StartTicks')) -Attempts 10 -WaitMilliseconds 1000
    if (-not $stopped) { Write-Warning "$Role could not be confirmed stopped; session metadata is preserved." }
    return $stopped
}

if (-not (Test-Path -LiteralPath $sessionBase -PathType Container)) { Write-Host 'Keine WorkspaceShare-Sitzungen gefunden.'; exit 0 }
foreach ($directory in @(Get-ChildItem -LiteralPath $sessionBase -Directory)) {
    $metadataPath = Join-Path $directory.FullName 'session.json'
    try { $session = Get-Content -LiteralPath $metadataPath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop } catch { Write-Warning "Sitzung ohne gültige Metadaten bleibt unangetastet: $($directory.FullName)"; $exitCode = 1; continue }
    $required = @('schema','cloudflaredPid','cloudflaredPath','cloudflaredStartTicks','miniservePid','miniservePath','miniserveStartTicks','watchdogPid','watchdogPath','watchdogStartTicks')
    if ([int]$session.schema -ne 2 -or @($required | Where-Object { $session.PSObject.Properties.Name -notcontains $_ }).Count -gt 0) { Write-Warning "Sitzung hat kein unterstütztes sicheres Format und bleibt erhalten: $($directory.FullName)"; $exitCode = 1; continue }
    try { New-Item -ItemType File -Path (Join-Path $directory.FullName 'stop.requested') -Force -ErrorAction Stop | Out-Null } catch { Write-Warning "Stop-Marker konnte nicht erstellt werden: $($directory.FullName)"; $exitCode = 1; continue }
    $cloudStopped = Stop-SessionProcess $session 'cloudflared' 'cloudflared'
    Start-Sleep -Milliseconds 300
    $serverStopped = Stop-SessionProcess $session 'miniserve' 'miniserve'
    if (-not ($cloudStopped -and $serverStopped)) { $exitCode = 1; continue }
    $watchdogStopped = Stop-SessionProcess $session 'watchdog' 'Watchdog'
    if (-not $watchdogStopped) { $exitCode = 1; continue }
    $unsafe = $false
    foreach ($prefix in @('cloudflared','miniserve','watchdog')) {
        $state = Get-ProcessIdentityState -ProcessId ([int]$session.($prefix + 'Pid')) -ExpectedPath ([string]$session.($prefix + 'Path')) -ExpectedStartTicks ([long]$session.($prefix + 'StartTicks'))
        if ($state.State -in @('Match','Unknown')) { $unsafe = $true; break }
    }
    if ($unsafe) { Write-Warning "Sitzungsordner bleibt wegen unbestätigtem Prozesszustand erhalten: $($directory.FullName)"; $exitCode = 1; continue }
    if ($KeepArchives -or [bool]$session.keepArchive) { try { New-Item -ItemType File -Path (Join-Path $directory.FullName 'keep.archive') -Force | Out-Null } catch { $exitCode = 1 }; continue }
    try { Remove-Item -LiteralPath $directory.FullName -Recurse -Force -ErrorAction Stop } catch { Write-Warning "Sitzungsordner konnte nicht entfernt werden: $($directory.FullName)"; $exitCode = 1; continue }
    if (Test-Path -LiteralPath $directory.FullName) { Write-Warning "Sitzungsordner konnte nicht vollständig entfernt werden: $($directory.FullName)"; $exitCode = 1 }
}
exit $exitCode
