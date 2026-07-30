#requires -Version 5.1
<#
.SYNOPSIS
    Beendet ausschließlich eindeutig verifizierte WorkspaceShare-Sitzungen.

.DESCRIPTION
    Eine Prozessbeendigung erfolgt nur, wenn PID, Executable-Pfad und
    Prozessstartzeit mit session.json übereinstimmen. Unbekannte oder beschädigte
    Sitzungsordner werden nicht automatisch gelöscht.
#>

[CmdletBinding()]
param(
    [switch]$KeepArchives
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Continue'

$sessionBase = if ($env:LOCALAPPDATA) {
    Join-Path $env:LOCALAPPDATA 'WorkspaceShare\sessions'
} else {
    Join-Path ([IO.Path]::GetTempPath()) 'WorkspaceShare\sessions'
}

function Get-VerifiedProcess {
    param(
        [int]$ProcessId,
        [string]$ExpectedPath,
        [long]$ExpectedStartTicks
    )

    if ($ProcessId -le 0 -or -not $ExpectedPath -or $ExpectedStartTicks -le 0) {
        return $null
    }

    try {
        $process = Get-Process -Id $ProcessId -ErrorAction Stop
        if (-not $process.Path) {
            return $null
        }

        if (
            [IO.Path]::GetFullPath($process.Path) -ne
            [IO.Path]::GetFullPath($ExpectedPath)
        ) {
            return $null
        }

        if ($process.StartTime.ToUniversalTime().Ticks -ne $ExpectedStartTicks) {
            return $null
        }

        return $process
    }
    catch {
        return $null
    }
}

function Stop-VerifiedProcess {
    param(
        [int]$ProcessId,
        [string]$ExpectedPath,
        [long]$ExpectedStartTicks,
        [string]$Role
    )

    $process = Get-VerifiedProcess `
        -ProcessId $ProcessId `
        -ExpectedPath $ExpectedPath `
        -ExpectedStartTicks $ExpectedStartTicks

    if (-not $process) {
        if ($ProcessId -gt 0) {
            Write-Host "$Role PID $ProcessId ist bereits beendet oder nicht eindeutig verifizierbar."
        }
        return
    }

    try {
        Stop-Process -Id $process.Id -Force -ErrorAction Stop
        try { [void]$process.WaitForExit(3000) } catch {}
        Write-Host "$Role PID $($process.Id) beendet."
    }
    catch {
        Write-Warning "$Role PID $($process.Id) konnte nicht beendet werden: $($_.Exception.Message)"
    }
}

if (-not (Test-Path -LiteralPath $sessionBase -PathType Container)) {
    Write-Host 'Keine WorkspaceShare-Sitzungen gefunden.'
    exit 0
}

$sessionDirectories = @(Get-ChildItem -LiteralPath $sessionBase -Directory)

if ($sessionDirectories.Count -eq 0) {
    Write-Host 'Keine WorkspaceShare-Sitzungen gefunden.'
    exit 0
}

foreach ($directory in $sessionDirectories) {
    Write-Host ''
    Write-Host "Prüfe Sitzung: $($directory.Name)"

    $metadataPath = Join-Path $directory.FullName 'session.json'
    if (-not (Test-Path -LiteralPath $metadataPath -PathType Leaf)) {
        Write-Warning (
            "Sitzung ohne verifizierbare Metadaten bleibt unangetastet: " +
            $directory.FullName
        )
        continue
    }

    try {
        $session = Get-Content -LiteralPath $metadataPath -Raw | ConvertFrom-Json
    }
    catch {
        Write-Warning (
            "Ungültige Sitzungsmetadaten; Ordner bleibt unangetastet: " +
            $directory.FullName
        )
        continue
    }

    if ([int]$session.schema -lt 2) {
        Write-Warning (
            "Altes Sitzungsformat ohne vollständigen PID-Reuse-Schutz. " +
            "Ordner bleibt unangetastet: $($directory.FullName)"
        )
        continue
    }

    # Tunnel zuerst, danach Dateiserver, zuletzt Watchdog.
    Stop-VerifiedProcess `
        -ProcessId ([int]$session.cloudflaredPid) `
        -ExpectedPath ([string]$session.cloudflaredPath) `
        -ExpectedStartTicks ([long]$session.cloudflaredStartTicks) `
        -Role 'cloudflared'

    Start-Sleep -Milliseconds 300

    Stop-VerifiedProcess `
        -ProcessId ([int]$session.miniservePid) `
        -ExpectedPath ([string]$session.miniservePath) `
        -ExpectedStartTicks ([long]$session.miniserveStartTicks) `
        -Role 'miniserve'

    Stop-VerifiedProcess `
        -ProcessId ([int]$session.watchdogPid) `
        -ExpectedPath ([string]$session.watchdogPath) `
        -ExpectedStartTicks ([long]$session.watchdogStartTicks) `
        -Role 'Watchdog'

    $effectiveKeep = $KeepArchives -or [bool]$session.keepArchive
    if ($effectiveKeep) {
        try {
            New-Item -ItemType File -Path (Join-Path $directory.FullName 'keep.archive') -Force | Out-Null
        }
        catch {}
        Write-Host "Sitzung beendet; lokale Dateien behalten: $($directory.FullName)"
        continue
    }

    # Vor dem Löschen erneut sicherstellen, dass keine verifizierten Prozesse laufen.
    $stillActive = $false
    foreach ($identity in @(
        @{ Pid = [int]$session.cloudflaredPid; Path = [string]$session.cloudflaredPath; Ticks = [long]$session.cloudflaredStartTicks },
        @{ Pid = [int]$session.miniservePid; Path = [string]$session.miniservePath; Ticks = [long]$session.miniserveStartTicks },
        @{ Pid = [int]$session.watchdogPid; Path = [string]$session.watchdogPath; Ticks = [long]$session.watchdogStartTicks }
    )) {
        if (Get-VerifiedProcess -ProcessId $identity.Pid -ExpectedPath $identity.Path -ExpectedStartTicks $identity.Ticks) {
            $stillActive = $true
            break
        }
    }

    if ($stillActive) {
        Write-Warning "Sitzungsordner wird nicht gelöscht, weil noch ein verifizierter Prozess läuft."
        continue
    }

    Remove-Item -LiteralPath $directory.FullName -Recurse -Force -ErrorAction SilentlyContinue
    if (Test-Path -LiteralPath $directory.FullName) {
        Write-Warning "Sitzungsordner konnte nicht vollständig entfernt werden: $($directory.FullName)"
    } else {
        Write-Host "Sitzung entfernt: $($directory.FullName)"
    }
}

exit 0
