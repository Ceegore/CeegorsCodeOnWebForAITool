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
    [string]$ToolRoot,
    [ValidateSet('','OldBinMoved','NewBinInstalled','LockReplaced','Reverified','Committed','BackupCleanup')]
    [string]$TestFailAfter = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

if ([string]::IsNullOrWhiteSpace($ToolRoot)) {
    $ToolRoot = $PSScriptRoot
}

Import-Module (Join-Path $ToolRoot 'scripts\WorkspaceShare.Dependency.psm1') -Force -ErrorAction Stop
Import-Module (Join-Path $ToolRoot 'scripts\WorkspaceShare.Job.psm1') -Force -ErrorAction Stop

[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
Add-Type -AssemblyName System.Net.Http -ErrorAction Stop
if (-not [Environment]::Is64BitOperatingSystem -or -not [Environment]::Is64BitProcess) {
    throw 'WorkspaceShare dependencies support only 64-bit Windows/x64 PowerShell.'
}

$installMutex = New-Object Threading.Mutex($false, 'Local\WorkspaceShare.DependencyInstall')
$installMutexHeld = $false
try { $installMutexHeld = $installMutex.WaitOne([TimeSpan]::FromSeconds(30)) } catch { throw 'The dependency-install mutex could not be acquired.' }
if (-not $installMutexHeld) { throw 'Another dependency installation or release build is active.' }
$dependencyLease = $null
try { $dependencyLease = Enter-WorkspaceDependencyLease -ToolRoot $ToolRoot -Mode Exclusive -TimeoutSeconds 30 }
catch {
    if ($installMutexHeld) { try { $installMutex.ReleaseMutex() } catch {} }
    $installMutex.Dispose()
    throw
}
$installJob=[IntPtr]::Zero

$bin = Join-Path $ToolRoot 'bin'
$installId=[Guid]::NewGuid().ToString('N')
$stage = Join-Path $ToolRoot ('.bin-stage-' + $installId)
$backup = Join-Path $ToolRoot ('.bin-backup-' + $installId)
$licenses = Join-Path $stage 'licenses'
$lockPath = Join-Path $ToolRoot 'dependencies.lock.json'
$transactionPath = Join-Path $ToolRoot '.dependencies.transaction.json'
$temp = Join-Path ([IO.Path]::GetTempPath()) ('WorkspaceShare-Dependencies-' + [Guid]::NewGuid().ToString('N'))

$assets = @(
    # 2026.7.2 ist bewusst gepinnt: 2026.7.3 verlor im Langzeittest den
    # trycloudflare.com-DNS-Eintrag, obwohl der Connector weiterlief.
    [ordered]@{
        name = 'cloudflared'
        version = '2026.7.2'
        url = 'https://github.com/cloudflare/cloudflared/releases/download/2026.7.2/cloudflared-windows-amd64.exe'
        sha256 = 'CDB5D4432F6AE1595654A692A51308B69D2BF7AF961F5578D9391837CF072DF9'
        type = 'exe'
        output = 'cloudflared.exe'
        license = 'Apache-2.0'
        licenseUrl = 'https://raw.githubusercontent.com/cloudflare/cloudflared/2026.7.2/LICENSE'
        licenseSha256 = '58D1E17FFE5109A7AE296CAAFCADFDBE6A7D176F0BC4AB01E12A689B0499D8BD'
        source = 'https://github.com/cloudflare/cloudflared/releases/tag/2026.7.2'
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
        licenseSha256 = 'BEDB87F0760796C7BE677651EB10AD949410E90C55BC7F607D848E8E9D65375A'
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
        licenseSha256 = 'E3884B252B3BFC045E55BE43A34D1E80DA070BC6F804AC95BF4660E97D62EBC6'
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
        licenseSha256 = '39D2187B942CC88818DD959E53C6B7DDDD152097A42061467C4D56050168D646'
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

    $lastError = $null
    for ($attempt = 1; $attempt -le 3; $attempt++) {
        $client = New-Object Net.Http.HttpClient
        $client.Timeout = [TimeSpan]::FromMinutes(2)
        $client.DefaultRequestHeaders.UserAgent.ParseAdd('WorkspaceShare-DependencyInstaller/3.1')
        try {
            $response = $client.GetAsync($Url, [Net.Http.HttpCompletionOption]::ResponseHeadersRead).GetAwaiter().GetResult()
            $response.EnsureSuccessStatusCode() | Out-Null
            $stream = $response.Content.ReadAsStreamAsync().GetAwaiter().GetResult()
            $file = New-Object IO.FileStream($Destination, [IO.FileMode]::Create, [IO.FileAccess]::Write, [IO.FileShare]::None)
            try { [void]$stream.CopyToAsync($file).GetAwaiter().GetResult() } finally { $file.Dispose(); $stream.Dispose(); $response.Dispose() }
            $lastError = $null
            break
        }
        catch {
            $lastError = $_.Exception
            Remove-Item -LiteralPath $Destination -Force -ErrorAction SilentlyContinue
            if ($attempt -lt 3) { Start-Sleep -Seconds ([Math]::Pow(2, $attempt)) }
        }
        finally { $client.Dispose() }
    }

    if ($lastError) { throw "Download failed after three bounded attempts: $($lastError.Message)" }

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
    $expectedHash = '83967F1B02B43C4EFEDA302795722C809E0E81B8307DE73558D10484D5676A7D'
    $sevenZip = Find-SevenZip
    if ($sevenZip -and (Get-Sha256 $sevenZip) -eq $expectedHash) {
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
    Invoke-WorkspaceNativeProcess -Job $installJob -FilePath $winget.Source -Arguments @('install','--id','7zip.7zip','--version','26.02','--exact','--accept-package-agreements','--accept-source-agreements','--disable-interactivity') -WorkingDirectory $temp -TimeoutSeconds 900 -ExpectedExitCodes @(0)|Out-Null

    $sevenZip = Find-SevenZip
    if (-not $sevenZip -or (Get-Sha256 $sevenZip) -ne $expectedHash) {
        throw '7-Zip wurde angefordert, aber 7z.exe konnte anschließend nicht gefunden werden.'
    }

    return $sevenZip
}

function Get-VersionText {
    param(
        [string]$FilePath,
        [string[]]$Arguments
    )

    $result=Invoke-WorkspaceNativeProcess -Job $installJob -FilePath $FilePath -Arguments $Arguments -WorkingDirectory $temp -TimeoutSeconds 30 -ExpectedExitCodes @(0)
    return (($result.StdOut | Out-String).Trim())
}

function Write-JsonAtomic {
    param([Parameter(Mandatory)]$Value, [Parameter(Mandatory)][string]$Path)
    $temporary = $Path + '.' + [Guid]::NewGuid().ToString('N') + '.tmp'
    $replaceBackup=$Path+'.'+[Guid]::NewGuid().ToString('N')+'.replace-backup'
    try {
        $Value | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $temporary -Encoding UTF8 -ErrorAction Stop
        if (Test-Path -LiteralPath $Path -PathType Leaf) {
            [IO.File]::Replace($temporary, $Path, $replaceBackup)
        }
        else { [IO.File]::Move($temporary, $Path) }
    }
    finally { Remove-Item -LiteralPath $temporary,$replaceBackup -Force -ErrorAction SilentlyContinue }
}

function Invoke-TestFailure {
    param([string]$Phase)
    if ($TestFailAfter -eq $Phase) { throw "Injected installer failure after $Phase." }
}

function Recover-DependencyTransaction {
    if (-not (Test-Path -LiteralPath $transactionPath -PathType Leaf)) { return }

    Write-Warning 'Recovering an interrupted dependency transaction.'
    $journal = Get-Content -LiteralPath $transactionPath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
    if ([int]$journal.schema -ne 1 -or [string]$journal.toolRoot -ne [IO.Path]::GetFullPath($ToolRoot)) {
        throw 'The dependency transaction journal is invalid or belongs to another tool root.'
    }

    if (Test-Path -LiteralPath ([string]$journal.backupBin) -PathType Container) {
        if (Test-Path -LiteralPath ([string]$journal.bin) -PathType Container) {
            Remove-Item -LiteralPath ([string]$journal.bin) -Recurse -Force -ErrorAction Stop
        }
        Move-Item -LiteralPath ([string]$journal.backupBin) -Destination ([string]$journal.bin) -ErrorAction Stop
    }
    elseif (-not [bool]$journal.oldBinExisted -and (Test-Path -LiteralPath ([string]$journal.bin))) {
        Remove-Item -LiteralPath ([string]$journal.bin) -Recurse -Force -ErrorAction Stop
    }

    if ([bool]$journal.oldLockExisted) {
        if (-not (Test-Path -LiteralPath ([string]$journal.oldLockBackup) -PathType Leaf)) {
            throw 'Cannot recover the previous dependency lock: its journal backup is missing.'
        }
        Copy-Item -LiteralPath ([string]$journal.oldLockBackup) -Destination ([string]$journal.lockPath) -Force -ErrorAction Stop
    }
    else { Remove-Item -LiteralPath ([string]$journal.lockPath) -Force -ErrorAction SilentlyContinue }

    Remove-Item -LiteralPath ([string]$journal.stagedBin) -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath ([string]$journal.newLockTemporary) -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath ([string]$journal.oldLockBackup) -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $transactionPath -Force -ErrorAction Stop
}

try {
    $installJob=New-WorkspaceJob -Name ('Local\WorkspaceShare.DependencyInstall.'+[Guid]::NewGuid().ToString('N'))
    Recover-DependencyTransaction
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
    if(Test-Path -LiteralPath $stage){throw "Unerwartetes Staging-Verzeichnis vorhanden: $stage"}
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
    $extractResult=Invoke-WorkspaceNativeProcess -Job $installJob -FilePath $sevenZipExtractor -Arguments @('x',$downloaded['7-Zip'],("-o$sevenZipExtract"),'-y','-bd') -WorkingDirectory $temp -TimeoutSeconds 300 -ExpectedExitCodes @(0)
    $global:LASTEXITCODE=$extractResult.ExitCode
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
        @{ File = 'cloudflared.exe'; Args = @('--version'); Expected = '2026.7.2' },
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
                Assert-Hash -Path $licensePath -Expected $asset.licenseSha256 -Name ("$($asset.name) license")
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
    Assert-Hash -Path (Join-Path $licenses '7-Zip-LICENSE.txt') -Expected (($assets | Where-Object name -eq '7-Zip').licenseSha256) -Name '7-Zip license'

    Write-Phase 5 5 'Binärdateien atomar übernehmen und Lockfile erzeugen ...'

    if(Test-Path -LiteralPath (Join-Path $bin 'README.md') -PathType Leaf){Copy-Item -LiteralPath (Join-Path $bin 'README.md') -Destination (Join-Path $stage 'README.md') -Force}
    $allowedStageFiles = @('cloudflared.exe','miniserve.exe','gitleaks.exe','7za.exe','README.md','licenses\cloudflared-LICENSE.txt','licenses\miniserve-LICENSE.txt','licenses\Gitleaks-LICENSE.txt','licenses\7-Zip-LICENSE.txt')
    $actualStageFiles = @(Get-ChildItem -LiteralPath $stage -File -Recurse | ForEach-Object { $_.FullName.Substring($stage.Length).TrimStart('\') } | Sort-Object)
    $stageDifference = @(Compare-Object ($allowedStageFiles | Sort-Object) $actualStageFiles)
    if ($stageDifference.Count -gt 0) { throw ('Staged dependency files do not match the exact allowlist: ' + (($stageDifference | ForEach-Object InputObject) -join ', ')) }

    $lockDependencies = @()
    foreach ($asset in $assets) {
        $fileName = [string]$asset.output
        $installedPath = Join-Path $stage $fileName
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

    $lockTemporary=Join-Path $ToolRoot ('.dependencies.lock.'+$installId+'.tmp')
    $lockBackup=Join-Path $ToolRoot ('.dependencies.lock.'+$installId+'.previous')
    $lock|ConvertTo-Json -Depth 6|Set-Content -LiteralPath $lockTemporary -Encoding UTF8 -ErrorAction Stop
    $oldBinExisted = Test-Path -LiteralPath $bin -PathType Container
    $oldLockExisted = Test-Path -LiteralPath $lockPath -PathType Leaf
    if ($oldLockExisted) { Copy-Item -LiteralPath $lockPath -Destination $lockBackup -Force -ErrorAction Stop }
    $journal = [ordered]@{
        schema = 1; id = $installId; phase = 'Prepared'; toolRoot = [IO.Path]::GetFullPath($ToolRoot)
        bin = $bin; backupBin = $backup; stagedBin = $stage; lockPath = $lockPath
        oldLockBackup = $lockBackup; newLockTemporary = $lockTemporary
        oldBinExisted = [bool]$oldBinExisted; oldLockExisted = [bool]$oldLockExisted
    }
    Write-JsonAtomic -Value $journal -Path $transactionPath
    $committed = $false
    try{
        if($oldBinExisted){Move-Item -LiteralPath $bin -Destination $backup -ErrorAction Stop}
        $journal.phase='OldBinMoved'; Write-JsonAtomic -Value $journal -Path $transactionPath
        Invoke-TestFailure 'OldBinMoved'
        Move-Item -LiteralPath $stage -Destination $bin -ErrorAction Stop
        $journal.phase='NewBinInstalled'; Write-JsonAtomic -Value $journal -Path $transactionPath
        Invoke-TestFailure 'NewBinInstalled'
        if($oldLockExisted){$replaceBackup=$lockPath+'.'+$installId+'.replace-backup';try{[IO.File]::Replace($lockTemporary,$lockPath,$replaceBackup)}finally{Remove-Item -LiteralPath $replaceBackup -Force -ErrorAction SilentlyContinue}}else{[IO.File]::Move($lockTemporary,$lockPath)}
        $journal.phase='LockReplaced'; Write-JsonAtomic -Value $journal -Path $transactionPath
        Invoke-TestFailure 'LockReplaced'

        $installedLock = Get-Content -LiteralPath $lockPath -Raw | ConvertFrom-Json
        foreach ($dependency in $installedLock.dependencies) {
            $installedFile = Join-Path $ToolRoot ([string]$dependency.file).Replace('/','\')
            Assert-Hash -Path $installedFile -Expected ([string]$dependency.sha256) -Name ([string]$dependency.name)
        }
        $journal.phase='Reverified'; Write-JsonAtomic -Value $journal -Path $transactionPath
        Invoke-TestFailure 'Reverified'

        Remove-Item -LiteralPath $transactionPath -Force -ErrorAction Stop
        $committed = $true
        Invoke-TestFailure 'Committed'
        if(Test-Path -LiteralPath $backup){Remove-Item -LiteralPath $backup -Recurse -Force -ErrorAction Stop}
        Remove-Item -LiteralPath $lockBackup -Force -ErrorAction SilentlyContinue
        Invoke-TestFailure 'BackupCleanup'
    }catch{
        if(-not $committed){ Recover-DependencyTransaction }
        else{Remove-Item -LiteralPath $backup -Recurse -Force -ErrorAction SilentlyContinue;Remove-Item -LiteralPath $lockBackup -Force -ErrorAction SilentlyContinue}
        throw
    }finally{Remove-Item -LiteralPath $lockTemporary -Force -ErrorAction SilentlyContinue}

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
    Remove-Item -LiteralPath $stage -Recurse -Force -ErrorAction SilentlyContinue
    if($installJob -ne [IntPtr]::Zero){try{Stop-WorkspaceJob -Job $installJob}catch{};try{Close-WorkspaceJob -Job $installJob}catch{};$installJob=[IntPtr]::Zero}
    if ($dependencyLease) { $dependencyLease.Dispose() }
    if ($installMutexHeld) { try { $installMutex.ReleaseMutex() } catch {} }
    $installMutex.Dispose()
}
