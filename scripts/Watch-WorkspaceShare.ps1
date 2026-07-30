#requires -Version 5.1
<#
.SYNOPSIS
    Sicherheits-Watchdog für WorkspaceShare.

.DESCRIPTION
    Besitzt niemals Capability-Token oder vollständige URL.
    Beendet ausschließlich über PID, Executable-Pfad und Prozessstartzeit
    verifizierte Prozesse. Dadurch werden PID-Reuse-Fehlabschüsse verhindert.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][int]$ParentPid,
    [Parameter(Mandatory = $true)][long]$ParentStartTicks,
    [Parameter(Mandatory = $true)][int]$MiniservePid,
    [Parameter(Mandatory = $true)][long]$MiniserveStartTicks,
    [Parameter(Mandatory = $true)][int]$CloudflaredPid,
    [Parameter(Mandatory = $true)][long]$CloudflaredStartTicks,
    [Parameter(Mandatory = $true)][string]$SessionPath,
    [Parameter(Mandatory = $true)][string]$NormalExitMarker,
    [Parameter(Mandatory = $true)][datetime]$ExpiresUtc,
    [Parameter(Mandatory = $true)][string]$ExpectedMiniservePath,
    [Parameter(Mandatory = $true)][string]$ExpectedCloudflaredPath,
    [switch]$KeepArchive
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'SilentlyContinue'

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
        [long]$ExpectedStartTicks
    )

    $process = Get-VerifiedProcess `
        -ProcessId $ProcessId `
        -ExpectedPath $ExpectedPath `
        -ExpectedStartTicks $ExpectedStartTicks

    if ($process) {
        Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue
        try { [void]$process.WaitForExit(3000) } catch {}
    }
}

function Test-OriginalParentAlive {
    try {
        $parent = Get-Process -Id $ParentPid -ErrorAction Stop
        return ($parent.StartTime.ToUniversalTime().Ticks -eq $ParentStartTicks)
    }
    catch {
        return $false
    }
}

while ($true) {
    $normalExitRequested = Test-Path -LiteralPath $NormalExitMarker -PathType Leaf

    if ($normalExitRequested) {
        # Der Launcher setzt den Marker erst nach dem Stoppen beider Kindprozesse.
        $cloudAlive = Get-VerifiedProcess `
            -ProcessId $CloudflaredPid `
            -ExpectedPath $ExpectedCloudflaredPath `
            -ExpectedStartTicks $CloudflaredStartTicks
        $serverAlive = Get-VerifiedProcess `
            -ProcessId $MiniservePid `
            -ExpectedPath $ExpectedMiniservePath `
            -ExpectedStartTicks $MiniserveStartTicks

        if (-not $cloudAlive -and -not $serverAlive) {
            exit 0
        }
    }

    if (-not (Test-OriginalParentAlive)) {
        break
    }

    if ([DateTime]::UtcNow -ge $ExpiresUtc.ToUniversalTime()) {
        break
    }

    Start-Sleep -Seconds 2
}

# Öffentliches Ende zuerst.
Stop-VerifiedProcess `
    -ProcessId $CloudflaredPid `
    -ExpectedPath $ExpectedCloudflaredPath `
    -ExpectedStartTicks $CloudflaredStartTicks

Start-Sleep -Milliseconds 300

Stop-VerifiedProcess `
    -ProcessId $MiniservePid `
    -ExpectedPath $ExpectedMiniservePath `
    -ExpectedStartTicks $MiniserveStartTicks

if ($KeepArchive) {
    try {
        New-Item -ItemType File -Path (Join-Path $SessionPath 'keep.archive') -Force | Out-Null
    }
    catch {}
}
else {
    Remove-Item -LiteralPath $SessionPath -Recurse -Force -ErrorAction SilentlyContinue
}

exit 0
