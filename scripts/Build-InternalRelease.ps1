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
    [string]$OutputDirectory,
    [ValidateSet('','OldReleaseMoved','ArchivePublished','HashPublished','Committed','BackupCleanup')]
    [string]$TestFailAfter = ''
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

Import-Module (Join-Path $ToolRoot 'scripts\WorkspaceShare.Dependency.psm1') -Force -ErrorAction Stop
Import-Module (Join-Path $ToolRoot 'scripts\WorkspaceShare.Job.psm1') -Force -ErrorAction Stop

$version = (Get-Content -LiteralPath (Join-Path $ToolRoot 'VERSION') -Raw).Trim()
$lockPath = Join-Path $ToolRoot 'dependencies.lock.json'
$testScript = Join-Path $ToolRoot 'tests\Test-WorkspaceShare.ps1'
$lifecycleTestScript = Join-Path $ToolRoot 'tests\Test-LifecycleHardening.ps1'
$sevenZip = Join-Path $ToolRoot 'bin\7za.exe'
$temp = Join-Path ([IO.Path]::GetTempPath()) ('WorkspaceShare-Release-' + [Guid]::NewGuid().ToString('N'))
$stage = Join-Path $temp 'WorkspaceShare'
$archive = Join-Path $OutputDirectory ("WorkspaceShare-{0}.zip" -f $version)
$hashFile = $archive + '.sha256.txt'
$publicationId = [Guid]::NewGuid().ToString('N')
$pendingArchive = $archive + '.' + $publicationId + '.pending'
$pendingHashFile = $hashFile + '.' + $publicationId + '.pending'
$archiveBackup = $archive + '.' + $publicationId + '.previous'
$hashBackup = $hashFile + '.' + $publicationId + '.previous'
$publicationJournal = $archive + '.publish.json'
$releaseMutex = New-Object Threading.Mutex($false, 'Local\WorkspaceShare.DependencyInstall')
$releaseMutexHeld = $false
try { $releaseMutexHeld = $releaseMutex.WaitOne([TimeSpan]::FromSeconds(30)) } catch { throw 'The dependency/release mutex could not be acquired.' }
if (-not $releaseMutexHeld) { throw 'A dependency installation or another release build is active.' }
$dependencyLease = $null
$releaseJob=[IntPtr]::Zero

function Require-File {
    param([string]$Path, [string]$Name)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "$Name fehlt: $Path"
    }
}

function Write-JsonAtomic {
    param([Parameter(Mandatory)]$Value, [Parameter(Mandatory)][string]$Path)
    $temporary = $Path + '.' + [Guid]::NewGuid().ToString('N') + '.tmp'
    $replaceBackup=$Path+'.'+[Guid]::NewGuid().ToString('N')+'.replace-backup'
    try {
        $Value | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $temporary -Encoding UTF8 -ErrorAction Stop
        if (Test-Path -LiteralPath $Path -PathType Leaf) { [IO.File]::Replace($temporary, $Path, $replaceBackup) }
        else { [IO.File]::Move($temporary, $Path) }
    }
    finally { Remove-Item -LiteralPath $temporary,$replaceBackup -Force -ErrorAction SilentlyContinue }
}

function Invoke-TestFailure {
    param([string]$Phase)
    if ($TestFailAfter -eq $Phase) { throw "Injected release publication failure after $Phase." }
}

function Recover-ReleasePublication {
    if (-not (Test-Path -LiteralPath $publicationJournal -PathType Leaf)) { return }
    Write-Warning 'Recovering an interrupted release publication.'
    $journal = Get-Content -LiteralPath $publicationJournal -Raw | ConvertFrom-Json
    if ([int]$journal.schema -ne 1 -or [string]$journal.archive -ne $archive) {
        throw 'The release publication journal is invalid.'
    }
    if ([bool]$journal.oldArchiveExisted) {
        if (-not (Test-Path -LiteralPath ([string]$journal.archiveBackup) -PathType Leaf)) { throw 'Previous release archive backup is missing.' }
        Move-Item -LiteralPath ([string]$journal.archiveBackup) -Destination $archive -Force -ErrorAction Stop
    }
    else { Remove-Item -LiteralPath $archive -Force -ErrorAction SilentlyContinue }
    if ([bool]$journal.oldHashExisted) {
        if (-not (Test-Path -LiteralPath ([string]$journal.hashBackup) -PathType Leaf)) { throw 'Previous release hash backup is missing.' }
        Move-Item -LiteralPath ([string]$journal.hashBackup) -Destination $hashFile -Force -ErrorAction Stop
    }
    else { Remove-Item -LiteralPath $hashFile -Force -ErrorAction SilentlyContinue }
    Remove-Item -LiteralPath ([string]$journal.pendingArchive),([string]$journal.pendingHash) -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $publicationJournal -Force -ErrorAction Stop
}

try {
    $releaseJob=New-WorkspaceJob -Name ('Local\WorkspaceShare.Release.'+[Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null
    Recover-ReleasePublication
    Require-File $lockPath 'Lockfile'
    Require-File $testScript 'Testskript'
    Require-File $lifecycleTestScript 'Lifecycle-Testskript'
    Require-File $sevenZip '7za.exe'

    $lock = Get-Content -LiteralPath $lockPath -Raw | ConvertFrom-Json
    if ([int]$lock.schema -ne 2 -or -not $lock.installed) {
        throw 'Abhängigkeiten sind nicht installiert oder nicht gesperrt.'
    }

    Write-Host '[1/5] Automatisierte Tests ausführen ...'
    $testResult=Invoke-WorkspaceNativeProcess -Job $releaseJob -FilePath (Join-Path $PSHOME 'powershell.exe') -Arguments @('-NoLogo','-NoProfile','-ExecutionPolicy','Bypass','-File',$testScript,'-ToolRoot',$ToolRoot) -WorkingDirectory $ToolRoot -TimeoutSeconds 1200 -ExpectedExitCodes @(0,1)
    if($testResult.StdOut){Write-Host $testResult.StdOut}
    if($testResult.StdErr){Write-Warning $testResult.StdErr}
    if($testResult.ExitCode -ne 0){throw "Acceptance tests failed with exit $($testResult.ExitCode)."}
    $lifecycleResult=Invoke-WorkspaceNativeProcess -Job $releaseJob -FilePath (Join-Path $PSHOME 'powershell.exe') -Arguments @('-NoLogo','-NoProfile','-ExecutionPolicy','Bypass','-File',$lifecycleTestScript,'-ToolRoot',$ToolRoot) -WorkingDirectory $ToolRoot -TimeoutSeconds 1200 -ExpectedExitCodes @(0,1)
    if($lifecycleResult.StdOut){Write-Host $lifecycleResult.StdOut}
    if($lifecycleResult.StdErr){Write-Warning $lifecycleResult.StdErr}
    if($lifecycleResult.ExitCode -ne 0){throw "Lifecycle tests failed with exit $($lifecycleResult.ExitCode)."}
    $dependencyLease=Enter-WorkspaceDependencyLease -ToolRoot $ToolRoot -Mode Exclusive -TimeoutSeconds 30

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
        'config\mandatory-excludes.txt','config\generated-excludes.txt','config\gitleaks-workspaceshare.toml',
        'scripts\WorkspaceShare.Process.psm1','scripts\WorkspaceShare.Curl.psm1','scripts\WorkspaceShare.Health.psm1','scripts\WorkspaceShare.Job.psm1','scripts\WorkspaceShare.Path.psm1','scripts\WorkspaceShare.Dependency.psm1','scripts\Watch-WorkspaceShare.ps1','scripts\Test-TunnelSoak.ps1','scripts\Test-QuickTunnelDns.ps1',
        'tests\Test-WorkspaceShare.ps1','tests\Test-LifecycleHardening.ps1','tests\Test-NativeRunnerSmoke.ps1',
        'bin\cloudflared.exe','bin\miniserve.exe','bin\gitleaks.exe','bin\7za.exe','bin\README.md',
        'bin\licenses\cloudflared-LICENSE.txt','bin\licenses\miniserve-LICENSE.txt','bin\licenses\Gitleaks-LICENSE.txt','bin\licenses\7-Zip-LICENSE.txt'
    )

    foreach ($relative in $releasePaths) {
        $source = Join-Path $ToolRoot $relative
        if (-not (Test-Path -LiteralPath $source)) {
            throw "Release-Pfad fehlt: $relative"
        }
        $destination=Join-Path $stage $relative
        New-Item -ItemType Directory -Path (Split-Path $destination -Parent) -Force|Out-Null
        Copy-Item -LiteralPath $source -Destination $destination -Force
    }

    Write-Host '[4/5] Distributions-ZIP erzeugen und testen ...'

    Invoke-WorkspaceNativeProcess -Job $releaseJob -FilePath $sevenZip -Arguments @('a','-tzip','-mx=9','-mmt=on','-sse','-y','-bd',$pendingArchive,'WorkspaceShare') -WorkingDirectory $temp -TimeoutSeconds 1200 -ExpectedExitCodes @(0)|Out-Null

    $releaseTest=Invoke-WorkspaceNativeProcess -Job $releaseJob -FilePath $sevenZip -Arguments @('t','-bd',$pendingArchive) -WorkingDirectory $temp -TimeoutSeconds 600 -ExpectedExitCodes @(0)
    $global:LASTEXITCODE=$releaseTest.ExitCode
    if ($LASTEXITCODE -ne 0) {
        throw "Release-ZIP-Integritätsprüfung fehlgeschlagen (Exit $LASTEXITCODE)."
    }

    Write-Host '[5/5] Release-Hash schreiben ...'
    $hash = (Get-FileHash -LiteralPath $pendingArchive -Algorithm SHA256).Hash
    ("{0}  {1}" -f $hash, (Split-Path $archive -Leaf)) |
        Set-Content -LiteralPath $pendingHashFile -Encoding ASCII

    $oldArchiveExisted = Test-Path -LiteralPath $archive -PathType Leaf
    $oldHashExisted = Test-Path -LiteralPath $hashFile -PathType Leaf
    $journal = [ordered]@{
        schema=1; id=$publicationId; archive=$archive; hashFile=$hashFile
        pendingArchive=$pendingArchive; pendingHash=$pendingHashFile
        archiveBackup=$archiveBackup; hashBackup=$hashBackup
        oldArchiveExisted=[bool]$oldArchiveExisted; oldHashExisted=[bool]$oldHashExisted
    }
    Write-JsonAtomic -Value $journal -Path $publicationJournal
    $committed = $false
    try {
        if ($oldArchiveExisted) { Copy-Item -LiteralPath $archive -Destination $archiveBackup -Force -ErrorAction Stop }
        if ($oldHashExisted) { Copy-Item -LiteralPath $hashFile -Destination $hashBackup -Force -ErrorAction Stop }
        Invoke-TestFailure 'OldReleaseMoved'
        Move-Item -LiteralPath $pendingArchive -Destination $archive -Force -ErrorAction Stop
        Invoke-TestFailure 'ArchivePublished'
        Move-Item -LiteralPath $pendingHashFile -Destination $hashFile -Force -ErrorAction Stop
        Invoke-TestFailure 'HashPublished'
        Remove-Item -LiteralPath $publicationJournal -Force -ErrorAction Stop
        $committed = $true
        Invoke-TestFailure 'Committed'
        Remove-Item -LiteralPath $archiveBackup,$hashBackup -Force -ErrorAction SilentlyContinue
        Invoke-TestFailure 'BackupCleanup'
    }
    catch {
        if (-not $committed) { Recover-ReleasePublication }
        else { Remove-Item -LiteralPath $archiveBackup,$hashBackup -Force -ErrorAction SilentlyContinue }
        throw
    }

    Write-Host ''
    Write-Host 'Interne Distribution erfolgreich erzeugt:'
    Write-Host $archive
    Write-Host $hashFile
    Write-Host ("SHA-256: {0}" -f $hash)
}
finally {
    Remove-Item -LiteralPath $pendingArchive,$pendingHashFile -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue
    if($releaseJob -ne [IntPtr]::Zero){try{Stop-WorkspaceJob -Job $releaseJob}catch{};try{Close-WorkspaceJob -Job $releaseJob}catch{};$releaseJob=[IntPtr]::Zero}
    if ($dependencyLease) { $dependencyLease.Dispose() }
    if ($releaseMutexHeld) { try { $releaseMutex.ReleaseMutex() } catch {} }
    $releaseMutex.Dispose()
}
