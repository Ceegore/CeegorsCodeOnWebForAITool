#requires -Version 5.1
<#
.SYNOPSIS
    Führt das lokale Release-Gate aus und erzeugt ein internes Distributions-ZIP.

.EXAMPLE
    .\scripts\Build-InternalRelease.ps1
#>

[CmdletBinding()]
param(
    [string]$ToolRoot,
    [string]$OutputDirectory
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

if ([string]::IsNullOrWhiteSpace($ToolRoot)) {
    $ToolRoot = Split-Path $PSScriptRoot -Parent
}
if ([string]::IsNullOrWhiteSpace($OutputDirectory)) {
    $OutputDirectory = Join-Path $ToolRoot 'dist'
}

$version = (Get-Content -LiteralPath (Join-Path $ToolRoot 'VERSION') -Raw).Trim()
$lockPath = Join-Path $ToolRoot 'dependencies.lock.json'
$testScript = Join-Path $ToolRoot 'tests\Test-WorkspaceShare.ps1'
$sevenZip = Join-Path $ToolRoot 'bin\7za.exe'
$temp = Join-Path ([IO.Path]::GetTempPath()) ('WorkspaceShare-Release-' + [Guid]::NewGuid().ToString('N'))
$stage = Join-Path $temp 'WorkspaceShare'
$archive = Join-Path $OutputDirectory ("WorkspaceShare-{0}.zip" -f $version)
$hashFile = $archive + '.sha256.txt'

function Require-File {
    param([string]$Path, [string]$Name)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "$Name fehlt: $Path"
    }
}

try {
    Require-File $lockPath 'Lockfile'
    Require-File $testScript 'Testskript'
    Require-File $sevenZip '7za.exe'

    $lock = Get-Content -LiteralPath $lockPath -Raw | ConvertFrom-Json
    if ([int]$lock.schema -ne 2 -or -not $lock.installed) {
        throw 'Abhängigkeiten sind nicht installiert oder nicht gesperrt.'
    }

    Write-Host '[1/5] Automatisierte Tests ausführen ...'
    & powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File $testScript -ToolRoot $ToolRoot
    if ($LASTEXITCODE -ne 0) {
        throw "Automatisierte Tests fehlgeschlagen (Exit $LASTEXITCODE)."
    }

    Write-Host '[2/5] Release-Inhalt statisch prüfen ...'
    $textFiles = @(
        Get-ChildItem -LiteralPath $ToolRoot -File -Recurse |
        Where-Object {
            $_.FullName -notmatch '(?i)[\\/](bin|dist|docs)[\\/]' -and
            $_.Extension -in @('.ps1','.psm1','.cmd','.json','.toml','.txt','.md')
        }
    )

    $placeholderWords = @(
        ('TO' + 'DO'),
        ('TB' + 'D'),
        ('FILL_' + 'SHA256'),
        ('PIN_' + 'TESTED_VERSION')
    )
    $placeholderPattern = '(?i)\b(' + ($placeholderWords -join '|') + ')\b'
    $placeholderHits = @()
    foreach ($file in $textFiles) {
        $matches = Select-String -LiteralPath $file.FullName -Pattern $placeholderPattern -AllMatches
        if ($matches) {
            $placeholderHits += $matches
        }
    }
    if ($placeholderHits.Count -gt 0) {
        $preview = $placeholderHits | Select-Object -First 20
        throw ("Nicht aufgelöste Platzhalter gefunden:`n" + ($preview -join "`n"))
    }

    foreach ($requiredLicense in @(
        'cloudflared-LICENSE.txt',
        'miniserve-LICENSE.txt',
        'Gitleaks-LICENSE.txt',
        '7-Zip-LICENSE.txt'
    )) {
        Require-File (Join-Path $ToolRoot ('bin\licenses\' + $requiredLicense)) $requiredLicense
    }

    Write-Host '[3/5] Staging-Verzeichnis erzeugen ...'
    New-Item -ItemType Directory -Path $stage -Force | Out-Null

    $releasePaths = @(
        'Share-Workspace.ps1',
        'Stop-WorkspaceShare.ps1',
        'Install-Dependencies.ps1',
        'WorkspaceShare.cmd',
        'Install.cmd',
        'Stop.cmd',
        'Test.cmd',
        'VERSION',
        'README.md',
        'SECURITY.md',
        'THIRD_PARTY_NOTICES.md',
        'dependencies.lock.json',
        'config',
        'scripts',
        'tests',
        'bin'
    )

    foreach ($relative in $releasePaths) {
        $source = Join-Path $ToolRoot $relative
        if (-not (Test-Path -LiteralPath $source)) {
            throw "Release-Pfad fehlt: $relative"
        }
        Copy-Item -LiteralPath $source -Destination $stage -Recurse -Force
    }

    # Keine Laufzeitdaten oder Entwicklungsartefakte verteilen.
    Remove-Item -LiteralPath (Join-Path $stage 'scripts\Build-InternalRelease.ps1') -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath (Join-Path $stage 'tests\New-TestFixtures.ps1') -Force -ErrorAction SilentlyContinue

    Write-Host '[4/5] Distributions-ZIP erzeugen und testen ...'
    New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null
    Remove-Item -LiteralPath $archive -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $hashFile -Force -ErrorAction SilentlyContinue

    Push-Location $temp
    try {
        & $sevenZip a -tzip -mx=9 -mmt=on -sse -y -bd $archive 'WorkspaceShare'
        if ($LASTEXITCODE -ne 0) {
            throw "Release-ZIP konnte nicht erstellt werden (Exit $LASTEXITCODE)."
        }
    }
    finally {
        Pop-Location
    }

    & $sevenZip t -bd $archive | Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw "Release-ZIP-Integritätsprüfung fehlgeschlagen (Exit $LASTEXITCODE)."
    }

    Write-Host '[5/5] Release-Hash schreiben ...'
    $hash = (Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash
    ("{0}  {1}" -f $hash, (Split-Path $archive -Leaf)) |
        Set-Content -LiteralPath $hashFile -Encoding ASCII

    Write-Host ''
    Write-Host 'Interne Distribution erfolgreich erzeugt:'
    Write-Host $archive
    Write-Host $hashFile
    Write-Host ("SHA-256: {0}" -f $hash)
}
finally {
    Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue
}
