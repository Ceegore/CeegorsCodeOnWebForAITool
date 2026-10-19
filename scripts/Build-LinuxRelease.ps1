#requires -Version 7.2
<#
.SYNOPSIS
    Erzeugt das Linux-x64-Release-Archiv (experimentell).

.DESCRIPTION
    Läuft unter Linux mit PowerShell 7 nach `pwsh ./Install-Dependencies.ps1`. Prüft, dass die vier
    Programme in bin/linux-x64 exakt dem Lockfile entsprechen, und packt die Projektdateien mit diesen
    Programmen in dist/WorkspaceShare-<Version>-linux-x64.tar.gz (+ .sha256.txt, prüfbar mit
    `sha256sum -c`). Die Tests laufen vorher im Release-Workflow (.github/workflows/release-linux.yml).

.EXAMPLE
    pwsh ./scripts/Build-LinuxRelease.ps1
#>

[CmdletBinding()]
param(
    [string]$ToolRoot,
    [string]$OutputDirectory
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

if (-not $IsLinux) { throw 'Build-LinuxRelease.ps1 läuft nur unter Linux (PowerShell 7).' }
if ([string]::IsNullOrWhiteSpace($ToolRoot)) { $ToolRoot = Split-Path $PSScriptRoot -Parent }
if ([string]::IsNullOrWhiteSpace($OutputDirectory)) { $OutputDirectory = Join-Path $ToolRoot 'dist' }

$version = (Get-Content -LiteralPath (Join-Path $ToolRoot 'VERSION') -Raw).Trim()
if ($version -notmatch '^\d+\.\d+\.\d+$') { throw "VERSION ist ungültig: $version" }
$archiveName = 'WorkspaceShare-{0}-linux-x64.tar.gz' -f $version
$archive = Join-Path $OutputDirectory $archiveName
$hashFile = $archive + '.sha256.txt'
$temp = Join-Path ([IO.Path]::GetTempPath()) ('WorkspaceShare-LinuxRelease-' + [Guid]::NewGuid().ToString('N'))
$stage = Join-Path $temp 'WorkspaceShare'

$binaries = @('bin/linux-x64/cloudflared', 'bin/linux-x64/miniserve', 'bin/linux-x64/gitleaks', 'bin/linux-x64/7zz')
$releasePaths = @(
    'Share-Workspace.ps1', 'Stop-WorkspaceShare.ps1', 'Install-Dependencies.ps1',
    'Start-WorkspaceShareGui.ps1', 'Install-GuiShortcut.ps1',
    'VERSION', 'README.md', 'SECURITY.md', 'THIRD_PARTY_NOTICES.md', 'LICENSE', 'dependencies.lock.json',
    'docs/DETAILS.md', 'docs/LINUX_PLAN.md',
    'config/mandatory-excludes.txt', 'config/generated-excludes.txt', 'config/gitleaks-workspaceshare.toml',
    'scripts/WorkspaceShare.Process.psm1', 'scripts/WorkspaceShare.Curl.psm1', 'scripts/WorkspaceShare.Health.psm1',
    'scripts/WorkspaceShare.Job.psm1', 'scripts/WorkspaceShare.Job.Linux.ps1', 'scripts/WorkspaceShare.Path.psm1',
    'scripts/WorkspaceShare.Path.Linux.ps1', 'scripts/WorkspaceShare.Dependency.psm1', 'scripts/WorkspaceShare.Platform.psm1',
    'scripts/WorkspaceShare.Gui.Http.psm1', 'scripts/Watch-WorkspaceShare.ps1', 'scripts/Test-TunnelSoak.ps1',
    'scripts/Test-QuickTunnelDns.ps1',
    'gui/index.html', 'gui/app.js', 'gui/app.css', 'gui/favicon.svg',
    'tests/Test-WorkspaceShare.ps1', 'tests/Test-LifecycleHardening.ps1', 'tests/Test-NativeRunnerSmoke.ps1',
    'tests/Test-LinuxPlatform.ps1', 'tests/Test-WorkspaceShareGui.Http.ps1', 'tests/Test-WorkspaceShareGui.ps1',
    'tests/Fake-WorkspaceShare.ps1',
    'bin/README.md',
    'bin/linux-x64/licenses/cloudflared-LICENSE.txt', 'bin/linux-x64/licenses/miniserve-LICENSE.txt',
    'bin/linux-x64/licenses/Gitleaks-LICENSE.txt', 'bin/linux-x64/licenses/7-Zip-LICENSE.txt'
) + $binaries

function Invoke-Checked {
    param([Parameter(Mandatory)][string]$FilePath, [Parameter(Mandatory)][string[]]$Arguments)
    & $FilePath @Arguments
    if ($LASTEXITCODE -ne 0) { throw "$FilePath $($Arguments -join ' ') endete mit Exit $LASTEXITCODE." }
}

try {
    Write-Host '[1/4] Abhängigkeiten gegen das Lockfile prüfen ...'
    $lockPath = Join-Path $ToolRoot 'dependencies.lock.json'
    if (-not (Test-Path -LiteralPath $lockPath -PathType Leaf)) { throw 'dependencies.lock.json fehlt; zuerst pwsh ./Install-Dependencies.ps1 ausführen.' }
    $lock = Get-Content -LiteralPath $lockPath -Raw | ConvertFrom-Json
    if ([int]$lock.schema -ne 2 -or -not $lock.installed -or [string]$lock.platform -ne 'linux-x64') {
        throw 'Das Lockfile beschreibt keine installierten linux-x64-Abhängigkeiten.'
    }
    $lockedFiles = @($lock.dependencies | ForEach-Object { [string]$_.file })
    if (@(Compare-Object ($lockedFiles | Sort-Object) ($binaries | Sort-Object)).Count -ne 0) { throw 'Das Lockfile listet nicht genau die vier Linux-Programme.' }
    # Never package binaries that differ from the lock that ships with them.
    foreach ($dependency in @($lock.dependencies)) {
        $path = Join-Path $ToolRoot ([string]$dependency.file)
        if (-not (Test-Path -LiteralPath $path -PathType Leaf) -or (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash -ne ([string]$dependency.sha256).ToUpperInvariant()) {
            throw "Programm entspricht nicht dependencies.lock.json: $($dependency.file)"
        }
    }

    Write-Host '[2/4] Staging-Verzeichnis erzeugen ...'
    New-Item -ItemType Directory -Path $stage -Force | Out-Null
    foreach ($relative in $releasePaths) {
        $source = Join-Path $ToolRoot $relative
        if (-not (Test-Path -LiteralPath $source -PathType Leaf)) { throw "Release-Pfad fehlt: $relative" }
        $destination = Join-Path $stage $relative
        New-Item -ItemType Directory -Path (Split-Path $destination -Parent) -Force | Out-Null
        Copy-Item -LiteralPath $source -Destination $destination -Force
    }
    # Deterministic modes: directories and programs 755, everything else 644.
    Invoke-Checked 'find' @($stage, '-type', 'd', '-exec', 'chmod', '0755', '{}', '+')
    Invoke-Checked 'find' @($stage, '-type', 'f', '-exec', 'chmod', '0644', '{}', '+')
    foreach ($binary in $binaries) { Invoke-Checked 'chmod' @('0755', (Join-Path $stage $binary)) }

    Write-Host '[3/4] Archiv erzeugen und prüfen ...'
    New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null
    $pending = $archive + '.' + [Guid]::NewGuid().ToString('N') + '.pending'
    $epoch = [string]([DateTimeOffset]::UtcNow.ToUnixTimeSeconds())
    if ($env:SOURCE_DATE_EPOCH -match '^\d+$') { $epoch = $env:SOURCE_DATE_EPOCH }
    Invoke-Checked 'tar' @('--sort=name', '--owner=0', '--group=0', '--numeric-owner', "--mtime=@$epoch", '-czf', $pending, '-C', $temp, 'WorkspaceShare')
    $listed = @(& tar -tzf $pending | Where-Object { -not $_.EndsWith('/') } | ForEach-Object { $_.Substring('WorkspaceShare/'.Length) } | Sort-Object)
    if ($LASTEXITCODE -ne 0) { throw 'Das erzeugte Archiv ist nicht lesbar.' }
    if (@(Compare-Object $listed ($releasePaths | Sort-Object)).Count -ne 0) { throw 'Der Archivinhalt stimmt nicht mit der Release-Liste überein.' }
    Move-Item -LiteralPath $pending -Destination $archive -Force

    Write-Host '[4/4] Release-Hash schreiben ...'
    $hash = (Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash.ToLowerInvariant()
    ('{0}  {1}' -f $hash, $archiveName) | Set-Content -LiteralPath $hashFile -Encoding ascii

    Write-Host ''
    Write-Host 'Linux-Release erfolgreich erzeugt:'
    Write-Host $archive
    Write-Host $hashFile
    Write-Host ('SHA-256: {0}' -f $hash)
}
finally {
    Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue
    Get-ChildItem -LiteralPath $OutputDirectory -Filter '*.pending' -File -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue
}
