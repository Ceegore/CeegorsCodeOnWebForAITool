#requires -Version 5.1
<#
.SYNOPSIS
    Installiert die exakt gepinnten WorkspaceShare-Abhängigkeiten.

.DESCRIPTION
    Lädt ausschließlich fest definierte offizielle Release-Assets, prüft deren
    SHA-256-Werte vor dem Entpacken und erzeugt anschließend ein Lockfile mit
    den SHA-256-Werten der tatsächlich ausgeführten EXE-Dateien.

    Für das Entpacken des offiziellen 7-Zip-Extra-Pakets wird eine vorhandene
    7z.exe verwendet. Fehlt sie, installiert das Skript 7-Zip 26.02 über WinGet.

.EXAMPLE
    .\Install-Dependencies.ps1

.EXAMPLE
    .\Install-Dependencies.ps1 -Force
#>

[CmdletBinding()]
param(
    [switch]$Force,
    [string]$ToolRoot
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

if ([string]::IsNullOrWhiteSpace($ToolRoot)) {
    $ToolRoot = $PSScriptRoot
}

[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$bin = Join-Path $ToolRoot 'bin'
$licenses = Join-Path $bin 'licenses'
$lockPath = Join-Path $ToolRoot 'dependencies.lock.json'
$temp = Join-Path ([IO.Path]::GetTempPath()) ('WorkspaceShare-Dependencies-' + [Guid]::NewGuid().ToString('N'))
$stage = Join-Path $temp 'stage'

$assets = @(
    [ordered]@{
        name = 'cloudflared'
        version = '2026.7.3'
        url = 'https://github.com/cloudflare/cloudflared/releases/download/2026.7.3/cloudflared-windows-amd64.exe'
        sha256 = '8635DA433B6DF8194746E88ED9D2589566C20E38BFC2A80E431A348B7C765841'
        type = 'exe'
        output = 'cloudflared.exe'
        license = 'Apache-2.0'
        licenseUrl = 'https://raw.githubusercontent.com/cloudflare/cloudflared/2026.7.3/LICENSE'
        source = 'https://github.com/cloudflare/cloudflared/releases/tag/2026.7.3'
    },
    [ordered]@{
        name = 'miniserve'
        version = '0.35.0'
        url = 'https://github.com/svenstaro/miniserve/releases/download/v0.35.0/miniserve-0.35.0-x86_64-pc-windows-msvc.exe'
        sha256 = '3229E75B40B3870382D23C9A0ECEC880B9BD5F6E49160CE602BB15D00F275B6A'
        type = 'exe'
        output = 'miniserve.exe'
        license = 'MIT'
        licenseUrl = 'https://raw.githubusercontent.com/svenstaro/miniserve/v0.35.0/LICENSE'
        source = 'https://github.com/svenstaro/miniserve/releases/tag/v0.35.0'
    },
    [ordered]@{
        name = 'Gitleaks'
        version = '8.30.1'
        url = 'https://github.com/gitleaks/gitleaks/releases/download/v8.30.1/gitleaks_8.30.1_windows_x64.zip'
        # GitHub-Asset-Digest des aktuellen offiziellen Assets.
        sha256 = 'D29144DEFF3A68AA93CED33DDDF84B7FDC26070ADD4AA0F4513094C8332AFC4E'
        type = 'zip'
        output = 'gitleaks.exe'
        license = 'MIT'
        licenseUrl = 'https://raw.githubusercontent.com/gitleaks/gitleaks/v8.30.1/LICENSE'
        source = 'https://github.com/gitleaks/gitleaks/releases/tag/v8.30.1'
    },
    [ordered]@{
        name = '7-Zip'
        version = '26.02'
        url = 'https://github.com/ip7z/7zip/releases/download/26.02/7z2602-extra.7z'
        sha256 = '081DF9E9311DFD9C9E0E98C1C80180B99BB51E4CB24156B5F3057FE3C259D70A'
        type = '7z'
        output = '7za.exe'
        license = 'LGPL-2.1-or-later plus bundled notices/exceptions'
        licenseUrl = ''
        source = 'https://github.com/ip7z/7zip/releases/tag/26.02'
    }
)

function Write-Phase {
    param([int]$Number, [int]$Total, [string]$Text)
    Write-Host ("[{0}/{1}] {2}" -f $Number, $Total, $Text)
}

function Get-Sha256 {
    param([string]$Path)
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToUpperInvariant()
}

function Assert-Hash {
    param(
        [string]$Path,
        [string]$Expected,
        [string]$Name
    )

    $actual = Get-Sha256 $Path
    if ($actual -ne $Expected.ToUpperInvariant()) {
        throw (
            "SHA-256-Prüfung fehlgeschlagen für $Name.`n" +
            "Erwartet: $Expected`nTatsächlich: $actual`n" +
            "Die Datei wurde nicht installiert."
        )
    }
}

function Download-File {
    param(
        [string]$Url,
        [string]$Destination
    )

    $directory = Split-Path -Path $Destination -Parent
    New-Item -ItemType Directory -Path $directory -Force | Out-Null

    $client = New-Object System.Net.WebClient
    $client.Headers['User-Agent'] = 'WorkspaceShare-DependencyInstaller/3.1'
    try {
        $client.DownloadFile($Url, $Destination)
    }
    finally {
        $client.Dispose()
    }

    if (-not (Test-Path -LiteralPath $Destination -PathType Leaf)) {
        throw "Download wurde nicht erstellt: $Destination"
    }
}

function Find-SevenZip {
    $command = Get-Command '7z.exe' -ErrorAction SilentlyContinue
    if ($command) {
        return $command.Source
    }

    $candidates = @()
    if ($env:ProgramFiles) {
        $candidates += (Join-Path $env:ProgramFiles '7-Zip\7z.exe')
    }
    if (${env:ProgramFiles(x86)}) {
        $candidates += (Join-Path ${env:ProgramFiles(x86)} '7-Zip\7z.exe')
    }

    foreach ($candidate in $candidates) {
        if (Test-Path -LiteralPath $candidate -PathType Leaf) {
            return $candidate
        }
    }

    return $null
}

function Ensure-SevenZipExtractor {
    $sevenZip = Find-SevenZip
    if ($sevenZip) {
        return $sevenZip
    }

    $winget = Get-Command 'winget.exe' -ErrorAction SilentlyContinue
    if (-not $winget) {
        throw (
            "Zum einmaligen Entpacken des offiziellen 7-Zip-Extra-Pakets wird 7z.exe benötigt. " +
            "Installiere 7-Zip 26.02 oder stelle winget.exe bereit und starte erneut."
        )
    }

    Write-Host '      7z.exe fehlt; installiere 7-Zip 26.02 über WinGet ...'
    & $winget.Source install `
        --id 7zip.7zip `
        --version 26.02 `
        --exact `
        --accept-package-agreements `
        --accept-source-agreements `
        --disable-interactivity

    if ($LASTEXITCODE -ne 0) {
        throw "WinGet konnte 7-Zip 26.02 nicht installieren (Exit $LASTEXITCODE)."
    }

    $sevenZip = Find-SevenZip
    if (-not $sevenZip) {
        throw '7-Zip wurde angefordert, aber 7z.exe konnte anschließend nicht gefunden werden.'
    }

    return $sevenZip
}

function Get-VersionText {
    param(
        [string]$FilePath,
        [string[]]$Arguments
    )

    $output = & $FilePath @Arguments 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "Versionsabfrage fehlgeschlagen: $FilePath"
    }
    return (($output | Out-String).Trim())
}

try {
    if ((Test-Path -LiteralPath $lockPath -PathType Leaf) -and -not $Force) {
        $existing = $null
        try {
            $existing = Get-Content -LiteralPath $lockPath -Raw | ConvertFrom-Json
        }
        catch {
            # Ungültige oder leere Lockdatei darf repariert werden.
        }

        if ($existing -and $existing.installed) {
            throw (
                "dependencies.lock.json zeigt bereits eine Installation an. " +
                "Nutze -Force für eine bewusste Neuinstallation."
            )
        }
    }

    New-Item -ItemType Directory -Path $temp -Force | Out-Null
    New-Item -ItemType Directory -Path $stage -Force | Out-Null
    New-Item -ItemType Directory -Path $licenses -Force | Out-Null

    Write-Phase 1 5 'Offizielle Release-Assets herunterladen und prüfen ...'

    $downloaded = @{}
    foreach ($asset in $assets) {
        $extension = switch ($asset.type) {
            'exe' { '.exe' }
            'zip' { '.zip' }
            '7z'  { '.7z' }
            default { '.bin' }
        }

        $downloadPath = Join-Path $temp ($asset.name.Replace(' ','-') + $extension)
        Write-Host ("      {0} {1}" -f $asset.name, $asset.version)
        Download-File -Url $asset.url -Destination $downloadPath
        Assert-Hash -Path $downloadPath -Expected $asset.sha256 -Name $asset.name
        $downloaded[$asset.name] = $downloadPath
    }

    Write-Phase 2 5 'Archive sicher entpacken und Binärdateien bereitstellen ...'

    Copy-Item -LiteralPath $downloaded['cloudflared'] -Destination (Join-Path $stage 'cloudflared.exe') -Force
    Copy-Item -LiteralPath $downloaded['miniserve'] -Destination (Join-Path $stage 'miniserve.exe') -Force

    $gitleaksExtract = Join-Path $temp 'gitleaks'
    Expand-Archive -LiteralPath $downloaded['Gitleaks'] -DestinationPath $gitleaksExtract -Force
    $gitleaksExe = Get-ChildItem -LiteralPath $gitleaksExtract -Filter 'gitleaks.exe' -File -Recurse |
        Select-Object -First 1
    if (-not $gitleaksExe) {
        throw 'gitleaks.exe fehlt im geprüften Release-Archiv.'
    }
    Copy-Item -LiteralPath $gitleaksExe.FullName -Destination (Join-Path $stage 'gitleaks.exe') -Force

    $sevenZipExtractor = Ensure-SevenZipExtractor
    $sevenZipExtract = Join-Path $temp '7zip-extra'
    New-Item -ItemType Directory -Path $sevenZipExtract -Force | Out-Null
    & $sevenZipExtractor x $downloaded['7-Zip'] "-o$sevenZipExtract" -y -bd | Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw "Das geprüfte 7-Zip-Extra-Paket konnte nicht entpackt werden (Exit $LASTEXITCODE)."
    }

    $sevenZipCandidates = @(
        Get-ChildItem -LiteralPath $sevenZipExtract -Filter '7za.exe' -File -Recurse
    )
    $sevenZipExe = $sevenZipCandidates |
        Where-Object { $_.FullName -match '(?i)[\\/]x64[\\/]' } |
        Select-Object -First 1
    if (-not $sevenZipExe) {
        $sevenZipExe = $sevenZipCandidates | Select-Object -First 1
    }
    if (-not $sevenZipExe) {
        throw '7za.exe fehlt im geprüften 7-Zip-Extra-Paket.'
    }
    Copy-Item -LiteralPath $sevenZipExe.FullName -Destination (Join-Path $stage '7za.exe') -Force

    Write-Phase 3 5 'Versionen der ausführbaren Dateien prüfen ...'

    $versionChecks = @(
        @{ File = 'cloudflared.exe'; Args = @('--version'); Expected = '2026.7.3' },
        @{ File = 'miniserve.exe'; Args = @('--version'); Expected = '0.35.0' },
        @{ File = 'gitleaks.exe'; Args = @('version'); Expected = '8.30.1' },
        @{ File = '7za.exe'; Args = @('i'); Expected = '26.02' }
    )

    foreach ($check in $versionChecks) {
        $path = Join-Path $stage $check.File
        $text = Get-VersionText -FilePath $path -Arguments $check.Args
        if ($text -notmatch [regex]::Escape($check.Expected)) {
            throw (
                "Unerwartete Version für $($check.File).`n" +
                "Erwartet: $($check.Expected)`nAusgabe: $text"
            )
        }
        Write-Host ("      {0}: {1}" -f $check.File, $check.Expected)
    }

    Write-Phase 4 5 'Lizenztexte und Notices ablegen ...'

    foreach ($asset in $assets) {
        if ($asset.licenseUrl) {
            $licensePath = Join-Path $licenses ($asset.name.Replace(' ','-') + '-LICENSE.txt')
            try {
                Download-File -Url $asset.licenseUrl -Destination $licensePath
            }
            catch {
                throw "Lizenztext für $($asset.name) konnte nicht geladen werden: $($_.Exception.Message)"
            }
        }
    }

    $sevenZipLicense = Get-ChildItem -LiteralPath $sevenZipExtract -File -Recurse |
        Where-Object { $_.Name -match '(?i)^(license|copying)(\..+)?$' } |
        Select-Object -First 1
    if ($sevenZipLicense) {
        Copy-Item -LiteralPath $sevenZipLicense.FullName -Destination (Join-Path $licenses '7-Zip-LICENSE.txt') -Force
    }
    else {
        @'
7-Zip 26.02
Siehe die Lizenz- und Copyright-Hinweise der offiziellen 7-Zip-Distribution
sowie THIRD_PARTY_NOTICES.md. Vor interner Weitergabe muss das vollständige
Original-Lizenzpaket mitgeführt werden.
'@ | Set-Content -LiteralPath (Join-Path $licenses '7-Zip-LICENSE.txt') -Encoding UTF8
    }

    Write-Phase 5 5 'Binärdateien atomar übernehmen und Lockfile erzeugen ...'

    New-Item -ItemType Directory -Path $bin -Force | Out-Null
    foreach ($file in @('cloudflared.exe','miniserve.exe','gitleaks.exe','7za.exe')) {
        $source = Join-Path $stage $file
        $destination = Join-Path $bin $file
        Copy-Item -LiteralPath $source -Destination $destination -Force
    }

    $lockDependencies = @()
    foreach ($asset in $assets) {
        $fileName = [string]$asset.output
        $installedPath = Join-Path $bin $fileName
        $lockDependencies += [ordered]@{
            name = [string]$asset.name
            file = ('bin/' + $fileName)
            version = [string]$asset.version
            sha256 = Get-Sha256 $installedPath
            license = [string]$asset.license
            source = [string]$asset.source
            sourceAssetSha256 = [string]$asset.sha256
        }
    }

    $lock = [ordered]@{
        schema = 2
        installed = $true
        generatedUtc = [DateTime]::UtcNow.ToString('o')
        platform = 'windows-x64'
        installerVersion = '3.1.0'
        dependencies = $lockDependencies
    }

    $lock | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $lockPath -Encoding UTF8

    Write-Host ''
    Write-Host 'Abhängigkeiten wurden erfolgreich installiert und gesperrt.'
    Write-Host ("Lockfile: {0}" -f $lockPath)
    Write-Host ''
    foreach ($dependency in $lockDependencies) {
        Write-Host ("{0,-12} {1}  {2}" -f $dependency.name, $dependency.version, $dependency.sha256)
    }
}
finally {
    Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue
}
