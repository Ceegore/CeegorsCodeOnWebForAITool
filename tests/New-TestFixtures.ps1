#requires -Version 5.1
<#
.SYNOPSIS
    Erzeugt lokale Test-Workspaces für die Snapshot- und Sicherheits-Gates.

.DESCRIPTION
    Die Fixtures enthalten absichtlich verbotene Dateien oder Reparse-Points.
    Sie dürfen niemals produktiv freigegeben werden.

.EXAMPLE
    .\tests\New-TestFixtures.ps1

.EXAMPLE
    .\tests\New-TestFixtures.ps1 -IncludeLargeFiles
#>

[CmdletBinding()]
param(
    [string]$OutputRoot = (Join-Path ([IO.Path]::GetTempPath()) 'WorkspaceShare-Fixtures'),
    [switch]$IncludeLargeFiles
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (Test-Path -LiteralPath $OutputRoot) {
    Remove-Item -LiteralPath $OutputRoot -Recurse -Force
}
New-Item -ItemType Directory -Path $OutputRoot -Force | Out-Null

function New-Fixture {
    param([string]$Name)

    $path = Join-Path $OutputRoot $Name
    New-Item -ItemType Directory -Path $path -Force | Out-Null
    return $path
}

$clean = New-Fixture '01-clean'
@'
# Clean fixture
This workspace contains ordinary source files.
'@ | Set-Content -LiteralPath (Join-Path $clean 'README.md') -Encoding UTF8
New-Item -ItemType Directory -Path (Join-Path $clean 'src') | Out-Null
'console.log("hello");' | Set-Content -LiteralPath (Join-Path $clean 'src\index.js') -Encoding UTF8
'EXAMPLE_KEY=not-a-real-secret' | Set-Content -LiteralPath (Join-Path $clean '.env.example') -Encoding UTF8
New-Item -ItemType Directory -Path (Join-Path $clean 'node_modules\demo') -Force | Out-Null
'generated' | Set-Content -LiteralPath (Join-Path $clean 'node_modules\demo\index.js') -Encoding UTF8

$forbidden = New-Fixture '02-forbidden-filename'
'REAL_SECRET=must-block' | Set-Content -LiteralPath (Join-Path $forbidden '.env') -Encoding UTF8

$gitleaks = New-Fixture '03-gitleaks-content'
@'
This fixture intentionally contains a fake AWS access key pattern for scanner tests:
AKIAIOSFODNN7EXAMPLE
'@ | Set-Content -LiteralPath (Join-Path $gitleaks 'intentional-secret-fixture.txt') -Encoding UTF8

$locked = New-Fixture '04-locked-file'
'This file should be opened exclusively by the manual gate test.' |
    Set-Content -LiteralPath (Join-Path $locked 'locked.bin') -Encoding UTF8

$exclude = New-Fixture '05-project-excludes'
'keep' | Set-Content -LiteralPath (Join-Path $exclude 'keep.txt') -Encoding UTF8
'remove' | Set-Content -LiteralPath (Join-Path $exclude 'large.psd') -Encoding UTF8
@'
*.psd
'@ | Set-Content -LiteralPath (Join-Path $exclude '.workspace-share.exclude.txt') -Encoding UTF8

$reparse = New-Fixture '06-reparse-point'
$target = Join-Path $OutputRoot 'reparse-target'
New-Item -ItemType Directory -Path $target -Force | Out-Null
'target' | Set-Content -LiteralPath (Join-Path $target 'outside.txt') -Encoding UTF8
$link = Join-Path $reparse 'junction-outside'
try {
    cmd.exe /c "mklink /J `"$link`" `"$target`"" | Out-Null
    if ($LASTEXITCODE -ne 0) {
        Write-Warning 'Junction konnte nicht erstellt werden; Fixture 06 ist unvollständig.'
    }
}
catch {
    Write-Warning 'Junction konnte nicht erstellt werden; Fixture 06 ist unvollständig.'
}

if ($IncludeLargeFiles) {
    $large = New-Fixture '07-large-files'
    $single = Join-Path $large 'single-over-2gb.bin'
    $stream = [IO.File]::Open($single, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
    try {
        $stream.SetLength(2GB + 1MB)
    }
    finally {
        $stream.Dispose()
    }

    Write-Warning (
        "Eine Datei mit logischer Größe über 2 GB wurde erzeugt. " +
        "Je nach Dateisystem belegt sie real entsprechend viel Speicher."
    )
}

Write-Host ''
Write-Host "Fixtures erstellt: $OutputRoot"
Get-ChildItem -LiteralPath $OutputRoot -Directory | Select-Object Name, FullName | Format-Table -AutoSize
