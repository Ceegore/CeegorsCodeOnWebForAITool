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
    [switch]$IncludeLargeFiles,
    [switch]$ForceReset
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path (Split-Path $PSScriptRoot -Parent) 'scripts\WorkspaceShare.Path.psm1') -Force -ErrorAction Stop

$resolvedOutput=[IO.Path]::GetFullPath($OutputRoot).TrimEnd('\')
$safeBase=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')+'\'
if(-not $resolvedOutput.StartsWith($safeBase,[StringComparison]::OrdinalIgnoreCase)){throw 'Fixture output must be below the system temporary directory.'}
if($resolvedOutput -eq $safeBase.TrimEnd('\') -or $resolvedOutput -eq [IO.Path]::GetPathRoot($resolvedOutput).TrimEnd('\')){throw 'Refusing unsafe fixture root.'}
if (Test-Path -LiteralPath $resolvedOutput) {
    $rootItem=Get-Item -LiteralPath $resolvedOutput -Force -ErrorAction Stop
    if(($rootItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0){throw 'Refusing to reset a fixture root that is a reparse point.'}
    $marker=Join-Path $resolvedOutput '.workspace-share-fixtures-root'
    if(-not $ForceReset -or -not(Test-Path -LiteralPath $marker -PathType Leaf)){throw 'Existing fixture root may be deleted only with -ForceReset and its safety marker.'}
    $identity=Resolve-WorkspaceDirectoryIdentity -Path $resolvedOutput
    $tempIdentity=Resolve-WorkspaceDirectoryIdentity -Path ([IO.Path]::GetTempPath())
    if(-not($identity.FinalPath+'\').StartsWith($tempIdentity.FinalPath.TrimEnd('\')+'\',[StringComparison]::OrdinalIgnoreCase)){throw 'Fixture root does not resolve below the canonical system temporary directory.'}
    $markerData=Get-Content -LiteralPath $marker -Raw -ErrorAction Stop|ConvertFrom-Json -ErrorAction Stop
    if([string]$markerData.magic -ne 'WorkspaceShareFixtures' -or [string]$markerData.identity -ne $identity.Identity -or [string]$markerData.finalPath -ne $identity.FinalPath){throw 'Fixture safety marker does not match the current canonical root identity.'}
    # Reparse-Points zuerst nicht-rekursiv entfernen, damit der rekursive Löschlauf keine Junction-Ziele berührt.
    foreach($reparseItem in @(Get-ChildItem -LiteralPath $resolvedOutput -Recurse -Force -Attributes ReparsePoint -ErrorAction Stop)){
        if($reparseItem.PSIsContainer){[IO.Directory]::Delete($reparseItem.FullName)}else{Remove-Item -LiteralPath $reparseItem.FullName -Force}
    }
    Remove-Item -LiteralPath $resolvedOutput -Recurse -Force
}
New-Item -ItemType Directory -Path $resolvedOutput -Force | Out-Null
$OutputRoot=$resolvedOutput
$createdIdentity=Resolve-WorkspaceDirectoryIdentity -Path $OutputRoot
$canonicalTemp=Resolve-WorkspaceDirectoryIdentity -Path ([IO.Path]::GetTempPath())
if(-not($createdIdentity.FinalPath+'\').StartsWith($canonicalTemp.FinalPath.TrimEnd('\')+'\',[StringComparison]::OrdinalIgnoreCase)){throw 'Created fixture root escaped the canonical system temporary directory.'}
[ordered]@{magic='WorkspaceShareFixtures';schema=1;identity=$createdIdentity.Identity;finalPath=$createdIdentity.FinalPath}|ConvertTo-Json|Set-Content -LiteralPath (Join-Path $OutputRoot '.workspace-share-fixtures-root') -Encoding UTF8

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
        throw 'mklink /J lieferte einen Fehlercode.'
    }
    if (-not (Test-Path -LiteralPath $link) -or ((Get-Item -LiteralPath $link -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) -eq 0) {
        throw 'Die Junction wurde nicht als Reparse-Point angelegt.'
    }
}
catch {
    throw ('Junction konnte nicht erstellt werden; Fixture 06 ist unvollständig: ' + $_.Exception.Message)
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
