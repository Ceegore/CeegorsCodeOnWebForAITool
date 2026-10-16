#requires -Version 5.1
<#
.SYNOPSIS
    Erstellt einen read-only Workspace-Snapshot und veröffentlicht ihn für kurze Zeit
    über einen geheimen Cloudflare-Quick-Tunnel-Link.

.DESCRIPTION
    Sicherheitsmodell:
    - exakt ein ZIP-Snapshot wird bereitgestellt;
    - keine Verzeichnisfreigabe;
    - keine Upload-, Lösch-, mkdir- oder WebDAV-Funktionen;
    - lokaler Server bindet ausschließlich an 127.0.0.1;
    - 256-Bit-Capability-Token im URL-Pfad;
    - Cloudflare Quick Tunnel;
    - automatische Abschaltung und Bereinigung;
    - Token und vollständige URL werden nicht dauerhaft protokolliert.

    Diese Referenzimplementierung ist absichtlich Windows-/PowerShell-5.1-kompatibel.
    Vor produktiver interner Nutzung müssen alle Gates aus _internetKonzept3.md
    erfolgreich bestanden werden.

.EXAMPLE
    .\Share-Workspace.ps1 -Path "D:\Projekte\Roswell" -Hours 4

.EXAMPLE
    .\Share-Workspace.ps1 -Path "D:\Projekte\Roswell" -Minutes 15 -KeepArchive
#>

[CmdletBinding(DefaultParameterSetName = 'Hours')]
param(
    [Parameter(Mandatory = $true, Position = 0)]
    [ValidateNotNullOrEmpty()]
    [string]$Path,

    [Parameter(ParameterSetName = 'Hours')]
    [ValidateRange(1, 24)]
    [int]$Hours = 4,

    [Parameter(Mandatory = $true, ParameterSetName = 'Minutes')]
    [ValidateRange(1, 1440)]
    [int]$Minutes,

    [ValidateSet('Fast', 'Store')]
    [string]$Compression = 'Fast',

    [switch]$IncludeGenerated,
    [switch]$UnsafeSkipSecretScan,
    [switch]$TestMode,
    [switch]$KeepArchive,
    [switch]$KeepClipboard,
    [switch]$NoClipboard,

    [ValidateSet('auto', 'quic', 'http2')]
    [string]$TunnelProtocol = 'auto',

    [ValidateSet('auto', '4', '6')]
    [string]$TunnelEdgeIpVersion = 'auto',

    [ValidateRange(5, 120)]
    [int]$HealthCheckSeconds = 15,

    [ValidateRange(2, 12)]
    [int]$HealthFailureThreshold = 4,

    [ValidateRange(5, 12)]
    [int]$TunnelRetries = 8,

    [bool]$KeepDiagnosticsOnError = $true,

    [string]$ToolRoot,

    [switch]$EventStream,
    [int]$ParentProcessId = 0,
    [switch]$TestStopAfterSnapshot
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

if ([string]::IsNullOrWhiteSpace($ToolRoot)) {
    $ToolRoot = $PSScriptRoot
}

# ---------------------------------------------------------------------------
# Konstanten
# ---------------------------------------------------------------------------

$script:ExitCode = 0
$script:SessionDirectory = $null
$script:ArchivePath = $null
$script:MiniserveProcess = $null
$script:CloudflaredProcess = $null
$script:WatchdogProcess = $null
$script:SleepPreventionEnabled = $false
$script:NormalExitMarker = $null
$script:ClipboardUrl = $null
$script:KeepArchiveMarker = $null
$script:CloudflaredMetricsPort = 0
$script:HealthLogPath = $null
$script:DiagnosticsPath = $null
$script:FailureDiagnosticsSaved = $false
$script:LastHealthLogWarningUtc = [DateTime]::MinValue
$script:SecretUrls = @()
$script:SecretTokens = @()
$script:RetiredWatchdogProcesses = New-Object 'System.Collections.Generic.List[System.Diagnostics.Process]'
$script:ArchiveLockStream = $null
$script:LastDnsDiagnosticTimestamp = [int64]0
$script:LastDnsObservation = $null
$script:StopReason = 'StartupFailure'
$script:RuntimeTimer = $null
$script:JobHandle = [IntPtr]::Zero
$script:JobName = $null
$script:DependencyLease = $null
$script:ActiveStartTimestamp = [int64]0
$script:ActiveDurationTicks = [int64]0
$script:ParentProcessRecorded = $false
$script:ParentStartTicks = [int64]0
$script:ParentGone = $false
$script:ParentCheckTimer = $null
$script:EndedEventSent = $false
$script:LastErrorMessage = ''

$BinDirectory = Join-Path $ToolRoot 'bin'
$ConfigDirectory = Join-Path $ToolRoot 'config'
$ScriptsDirectory = Join-Path $ToolRoot 'scripts'

$SevenZipPath = Join-Path $BinDirectory '7za.exe'
$MiniservePath = Join-Path $BinDirectory 'miniserve.exe'
$CloudflaredPath = Join-Path $BinDirectory 'cloudflared.exe'
$GitleaksPath = Join-Path $BinDirectory 'gitleaks.exe'
$curlCommand = Get-Command 'curl.exe' -ErrorAction SilentlyContinue
$script:CurlPath = if ($curlCommand) { $curlCommand.Source } else { $null }

$MandatoryExcludesPath = Join-Path $ConfigDirectory 'mandatory-excludes.txt'
$GeneratedExcludesPath = Join-Path $ConfigDirectory 'generated-excludes.txt'
$GitleaksConfigPath = Join-Path $ConfigDirectory 'gitleaks-workspaceshare.toml'
$DependencyLockPath = Join-Path $ToolRoot 'dependencies.lock.json'
$WatchdogScriptPath = Join-Path $ScriptsDirectory 'Watch-WorkspaceShare.ps1'
$HealthModulePath = Join-Path $ScriptsDirectory 'WorkspaceShare.Health.psm1'
$ProcessModulePath = Join-Path $ScriptsDirectory 'WorkspaceShare.Process.psm1'
$CurlModulePath = Join-Path $ScriptsDirectory 'WorkspaceShare.Curl.psm1'
$JobModulePath = Join-Path $ScriptsDirectory 'WorkspaceShare.Job.psm1'
$PathModulePath = Join-Path $ScriptsDirectory 'WorkspaceShare.Path.psm1'
$DependencyModulePath = Join-Path $ScriptsDirectory 'WorkspaceShare.Dependency.psm1'

$SessionBase = if ($env:LOCALAPPDATA) {
    Join-Path $env:LOCALAPPDATA 'WorkspaceShare\sessions'
} else {
    Join-Path ([IO.Path]::GetTempPath()) 'WorkspaceShare\sessions'
}
$SessionStagingBase=Join-Path (Split-Path $SessionBase -Parent) 'staging'

# ---------------------------------------------------------------------------
# Hilfsfunktionen
# ---------------------------------------------------------------------------

function Write-Step {
    param(
        [Parameter(Mandatory = $true)][int]$Number,
        [Parameter(Mandatory = $true)][int]$Total,
        [Parameter(Mandatory = $true)][string]$Text
    )
    Write-Host ("[{0}/{1}] {2}" -f $Number, $Total, $Text)
    Write-ShareEvent -Type 'step' -Fields ([ordered]@{ n = $Number; total = $Total; text = $Text })
}

# Machine-readable event line for the GUI backend (see docs\GUI_CONTRACT.md, section 2).
# No-op without -EventStream; never throws.
function Write-ShareEvent {
    param(
        [Parameter(Mandatory = $true)][string]$Type,
        [System.Collections.IDictionary]$Fields = @{}
    )
    if (-not $EventStream) { return }
    try {
        $evt = [ordered]@{ v = 1; type = $Type; ts = [DateTime]::UtcNow.ToString('o') }
        foreach ($key in @($Fields.Keys)) {
            $value = $Fields[$key]
            if (($key -eq 'text' -or $key -eq 'message') -and $null -ne $value) {
                $value = Protect-DiagnosticText -Text ([string]$value) -KnownSecretUrls $script:SecretUrls
            }
            $evt[[string]$key] = $value
        }
        $json = ConvertTo-Json -InputObject $evt -Compress -Depth 5
        $json = [regex]::Replace($json, '[^\x00-\x7E]', [System.Text.RegularExpressions.MatchEvaluator]{ param($m) ('\u{0:x4}' -f [int][char]$m.Value) })
        [Console]::Out.WriteLine('@@WSEVENT@@ ' + $json)
        [Console]::Out.Flush()
    }
    catch {}
}

# Launcher warnings are mirrored as events (shadows the cmdlet inside this script only).
function Write-Warning {
    param([Parameter(Mandatory = $true, Position = 0)][AllowEmptyString()][string]$Message)
    Write-ShareEvent -Type 'warning' -Fields ([ordered]@{ text = $Message })
    Microsoft.PowerShell.Utility\Write-Warning -Message $Message
}

function Set-ManualStopReason {
    if ($script:ParentGone) { $script:StopReason = 'ParentExited' } else { $script:StopReason = 'ManualStop' }
}

function Write-EndedEvent {
    if ($script:EndedEventSent) { return }
    $script:EndedEventSent = $true
    try {
        $reason = [string]$script:StopReason
        if ($script:ExitCode -ne 0 -and ([string]::IsNullOrEmpty($reason) -or $reason -eq 'Expired')) { $reason = 'Error' }
        Write-ShareEvent -Type 'ended' -Fields ([ordered]@{ exitCode = [int]$script:ExitCode; reason = $reason; message = [string]$script:LastErrorMessage })
    }
    catch {}
}

function Stop-WithError {
    param(
        [Parameter(Mandatory = $true)][string]$Message,
        [int]$Code = 50
    )
    $exception = [System.Exception]::new($Message)
    $exception.Data['WorkspaceShareExitCode'] = $Code
    throw $exception
}

function Require-File {
    param(
        [Parameter(Mandatory = $true)][string]$FilePath,
        [Parameter(Mandatory = $true)][string]$FriendlyName,
        [int]$Code = 10
    )
    if (-not (Test-Path -LiteralPath $FilePath -PathType Leaf)) {
        Stop-WithError -Code $Code -Message (
            "{0} wurde nicht gefunden.`nErwarteter Pfad: {1}" -f
            $FriendlyName, $FilePath
        )
    }
}

function Test-DirectoryPathsOverlap {
    param([Parameter(Mandatory = $true)][string]$First,[Parameter(Mandatory = $true)][string]$Second)
    if ((Test-Path -LiteralPath $First -PathType Container) -and (Test-Path -LiteralPath $Second -PathType Container)) {
        $firstIdentity = Resolve-WorkspaceDirectoryIdentity -Path $First
        $secondIdentity = Resolve-WorkspaceDirectoryIdentity -Path $Second
        if ($firstIdentity.Identity -eq $secondIdentity.Identity) { return $true }
        $separator = [IO.Path]::DirectorySeparatorChar
        $firstFinal = $firstIdentity.FinalPath.TrimEnd('\','/') + $separator
        $secondFinal = $secondIdentity.FinalPath.TrimEnd('\','/') + $separator
        return ($firstFinal.StartsWith($secondFinal,[StringComparison]::OrdinalIgnoreCase) -or $secondFinal.StartsWith($firstFinal,[StringComparison]::OrdinalIgnoreCase))
    }
    $normalize = { param($candidate) ([IO.Path]::GetFullPath($candidate).TrimEnd([IO.Path]::DirectorySeparatorChar,[IO.Path]::AltDirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar) }
    $firstPath=& $normalize $First; $secondPath=& $normalize $Second
    return ($firstPath.StartsWith($secondPath,[StringComparison]::OrdinalIgnoreCase) -or $secondPath.StartsWith($firstPath,[StringComparison]::OrdinalIgnoreCase))
}

function Write-JsonFileAtomic {
    param([Parameter(Mandatory = $true)]$Value,[Parameter(Mandatory = $true)][string]$Destination)
    $temporary=Join-Path (Split-Path $Destination -Parent) ('.{0}.{1}.tmp' -f (Split-Path $Destination -Leaf),[Guid]::NewGuid().ToString('N'))
    $replaceBackup=$Destination+'.'+[Guid]::NewGuid().ToString('N')+'.replace-backup'
    try{$Value|ConvertTo-Json -Depth 6|Set-Content -LiteralPath $temporary -Encoding UTF8 -ErrorAction Stop;if(Test-Path -LiteralPath $Destination -PathType Leaf){[IO.File]::Replace($temporary,$Destination,$replaceBackup)}else{[IO.File]::Move($temporary,$Destination)}}finally{Remove-Item -LiteralPath $temporary,$replaceBackup -Force -ErrorAction SilentlyContinue}
}

function Lock-ArchiveReadOnly {
    param([Parameter(Mandatory = $true)][string]$ArchivePath)
    $script:ArchiveLockStream = New-Object IO.FileStream($ArchivePath,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)
}

function Test-StopRequested {
    if($script:WatchdogProcess){
        try{$script:WatchdogProcess.Refresh();if($script:WatchdogProcess.HasExited -and ($script:ActiveStartTimestamp -le 0 -or (Get-ActiveElapsedSeconds) -lt ($script:ActiveDurationTicks/[double][Diagnostics.Stopwatch]::Frequency))){Stop-WithError -Code 50 -Message 'Der Sicherheits-Watchdog wurde unerwartet beendet.'}}catch{throw}
    }
    if ($script:SessionDirectory -and (Test-Path -LiteralPath (Join-Path $script:SessionDirectory 'stop.requested') -PathType Leaf)) { return $true }
    if ($script:ParentProcessRecorded) {
        if ($script:ParentGone) { return $true }
        # Cheap: re-check the parent at most every 2 seconds.
        if ($null -eq $script:ParentCheckTimer) { $script:ParentCheckTimer = [Diagnostics.Stopwatch]::StartNew() }
        elseif ($script:ParentCheckTimer.ElapsedMilliseconds -lt 2000) { return $false }
        else { $script:ParentCheckTimer.Restart() }
        $parent = $null
        try { $parent = Get-Process -Id $ParentProcessId -ErrorAction Stop } catch { $parent = $null }
        $gone = ($null -eq $parent)
        if (-not $gone) {
            try { if ($parent.HasExited) { $gone = $true } } catch {}
        }
        if (-not $gone -and $script:ParentStartTicks -gt 0) {
            $ticks = Get-ProcessStartTicksSafe $parent
            if ($ticks -gt 0 -and $ticks -ne $script:ParentStartTicks) { $gone = $true }
        }
        if ($null -ne $parent) { try { $parent.Dispose() } catch {} }
        if ($gone) {
            $script:ParentGone = $true
            $script:StopReason = 'ParentExited'
            return $true
        }
    }
    return $false
}

function Test-EffectiveKeepArchive {
    return ([bool]$KeepArchive -or ($script:KeepArchiveMarker -and (Test-Path -LiteralPath $script:KeepArchiveMarker -PathType Leaf)))
}

function Get-ActiveElapsedSeconds {
    if($script:ActiveStartTimestamp -le 0){return 0.0}
    return ([Diagnostics.Stopwatch]::GetTimestamp()-$script:ActiveStartTimestamp)/[double][Diagnostics.Stopwatch]::Frequency
}

function Write-OwnerMetadata {
    param([Parameter(Mandatory=$true)][string]$Phase)
    $launcher=Get-Process -Id $PID -ErrorAction Stop
    $owner=[ordered]@{magic='WorkspaceShareSession';schema=1;phase=$Phase;createdUtc=[DateTime]::UtcNow.ToString('o');launcherPid=$PID;launcherPath=$launcher.Path;launcherStartTicks=$launcher.StartTime.ToUniversalTime().Ticks;jobName=$script:JobName}
    Write-JsonFileAtomic -Value $owner -Destination (Join-Path $script:SessionDirectory 'owner.json')
}

function Set-PrivateDirectoryAcl {
    param([Parameter(Mandatory=$true)][string]$Directory)
    $sid=[Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    & "$env:SystemRoot\System32\icacls.exe" $Directory '/inheritance:r' '/grant:r' ("*{0}:(OI)(CI)F" -f $sid)|Out-Null
    if($LASTEXITCODE -ne 0){Stop-WithError -Code 10 -Message "Private Verzeichnisrechte konnten nicht gesetzt werden: $Directory"}
}

function Read-BoundedDiagnosticText {
    param([Parameter(Mandatory=$true)][string]$Path,[int]$MaximumBytes=1048576)
    $stream=New-Object IO.FileStream($Path,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::ReadWrite)
    try{$length=[Math]::Min([int64]$MaximumBytes,$stream.Length);$stream.Seek(-$length,[IO.SeekOrigin]::End)|Out-Null;$bytes=New-Object byte[] $length;[void]$stream.Read($bytes,0,$bytes.Length);return [Text.Encoding]::UTF8.GetString($bytes)}finally{$stream.Dispose()}
}

function Get-SessionIntegrityMap {
    $map=New-Object 'System.Collections.Generic.List[string]'
    foreach($file in @(Get-ChildItem -LiteralPath $script:SessionDirectory -File -Recurse -ErrorAction Stop|Where-Object{
        $_.Name -notmatch '^probe-(body|headers|error)-.*\.tmp$' -and
        $_.Name -notin @('miniserve.stdout.log','miniserve.stderr.log')
    })){$relative=$file.FullName.Substring($script:SessionDirectory.Length).ToLowerInvariant();$map.Add(('{0}|{1}|{2}' -f $relative,$file.Length,(Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash))}
    return @($map|Sort-Object)
}

function Test-ExactArchiveContents {
    param([Parameter(Mandatory = $true)][string]$ArchivePath,[Parameter(Mandatory = $true)][string]$VerificationRoot,[Parameter(Mandatory = $true)][string]$GitleaksReportPath,[string[]]$ExclusionPatterns=@(),[string[]]$IncludedRelativePaths=@(),[switch]$RunSecretScan)
    New-Item -ItemType Directory -Path $VerificationRoot -Force | Out-Null
    try {
        try{$extract=Invoke-WorkspaceNativeProcess -Job $script:JobHandle -FilePath $SevenZipPath -Arguments @('x','-y','-bd','-bb1',("-o$VerificationRoot"),$ArchivePath) -WorkingDirectory $script:SessionDirectory -TimeoutSeconds 1800 -ExpectedExitCodes @(0)}catch{if($_.Exception.Data.Contains('WorkspaceShareExitCode')){throw};Stop-WithError -Code 23 -Message ('7-Zip ist fehlgeschlagen: '+(Protect-DiagnosticText $_.Exception.Message))}
        foreach($entry in @(Get-ChildItem -LiteralPath $VerificationRoot -Recurse -Force -ErrorAction Stop)){
            $relative=$entry.FullName.Substring($VerificationRoot.Length).TrimStart('\','/') -replace '/','\'
            $parts=@($relative -split '\\')
            if(@($parts|Where-Object{$_ -in @('.git','.svn','.hg')}).Count -gt 0){Stop-WithError -Code 22 -Message "Das fertige Archiv enthält ausgeschlossene Versionskontrolldaten: $relative"}
            if(Test-SourcePathExcluded -RelativePath $relative -Name $entry.Name -Patterns $ExclusionPatterns){Stop-WithError -Code 22 -Message "Das fertige Archiv enthält einen ausgeschlossenen Pfad: $relative"}
        }
        $actualFiles=@(Get-ChildItem -LiteralPath $VerificationRoot -File -Recurse -Force|ForEach-Object{$_.FullName.Substring($VerificationRoot.Length).TrimStart('\','/').ToLowerInvariant()}|Sort-Object)
        $expectedFiles=@($IncludedRelativePaths|ForEach-Object{([string]$_).Replace('/','\').ToLowerInvariant()}|Sort-Object)
        if(Compare-Object $expectedFiles $actualFiles){Stop-WithError -Code 22 -Message 'Das fertige Archiv stimmt nicht exakt mit der eingeschlossenen Quelldateiliste überein.'}
        $inspection=Inspect-Workspace -Root $VerificationRoot -IncludeGeneratedContent
        if($inspection.AccessErrors.Count -gt 0 -or $inspection.ReparsePoints.Count -gt 0 -or $inspection.ForbiddenFiles.Count -gt 0){Stop-WithError -Code 22 -Message 'Das fertige Archiv hat die exakte Inhaltsprüfung nicht bestanden.'}
        if($RunSecretScan){Invoke-GitleaksScan -SourceRoot $VerificationRoot -ReportPath $GitleaksReportPath}
    } finally { Remove-Item -LiteralPath $VerificationRoot -Recurse -Force -ErrorAction SilentlyContinue }
}


function Get-ProcessStartTicksSafe {
    param([System.Diagnostics.Process]$Process)

    if ($null -eq $Process) {
        return [int64]0
    }

    try {
        $Process.Refresh()
        return [int64]$Process.StartTime.ToUniversalTime().Ticks
    }
    catch {
        return [int64]0
    }
}

function Assert-DependencyLock {
    Require-File -FilePath $DependencyLockPath -FriendlyName 'dependencies.lock.json' -Code 11

    try {
        $lock = Get-Content -LiteralPath $DependencyLockPath -Raw | ConvertFrom-Json
    }
    catch {
        Stop-WithError -Code 11 -Message (
            "dependencies.lock.json ist ungültig. " +
            "Führe .\Install-Dependencies.ps1 erneut aus."
        )
    }

    try {
    if ([int]$lock.schema -ne 2 -or -not $lock.installed) {
        Stop-WithError -Code 11 -Message (
            "Die Abhängigkeiten wurden noch nicht reproduzierbar installiert. " +
            "Führe zuerst .\Install-Dependencies.ps1 aus."
        )
    }

    if ([string]$lock.installerVersion -ne '3.1.0') {
        Stop-WithError -Code 11 -Message (
            "Das Dependency-Lockfile wurde von einer anderen Installer-Version erzeugt. " +
            "Führe .\Install-Dependencies.ps1 -Force aus."
        )
    }

    $expectedDependencies = [ordered]@{
        'cloudflared' = [ordered]@{ Version = '2026.7.2'; File = 'bin/cloudflared.exe' }
        'miniserve' = [ordered]@{ Version = '0.35.0'; File = 'bin/miniserve.exe' }
        'Gitleaks' = [ordered]@{ Version = '8.30.1'; File = 'bin/gitleaks.exe' }
        '7-Zip' = [ordered]@{ Version = '26.02'; File = 'bin/7za.exe' }
    }

    $seen = @{}
    foreach ($dependency in @($lock.dependencies)) {
        $dependencyName = [string]$dependency.name
        if (-not $expectedDependencies.Contains($dependencyName) -or $seen.ContainsKey($dependencyName)) {
            Stop-WithError -Code 11 -Message "Das Lockfile enthält eine unbekannte oder doppelte Abhängigkeit: $dependencyName"
        }
        $expected = $expectedDependencies[$dependencyName]
        $actualRelativePath = ([string]$dependency.file).Replace('\', '/')
        if ($actualRelativePath -ne $expected.File -or [string]$dependency.version -ne $expected.Version) {
            Stop-WithError -Code 11 -Message "Das Lockfile enthält einen unerwarteten Pfad oder eine unerwartete Version für $dependencyName."
        }
        $filePath = [IO.Path]::GetFullPath((Join-Path $ToolRoot $expected.File.Replace('/', [IO.Path]::DirectorySeparatorChar)))
        $resolvedToolRoot = [IO.Path]::GetFullPath($ToolRoot).TrimEnd('\') + '\'
        if (-not $filePath.StartsWith($resolvedToolRoot, [StringComparison]::OrdinalIgnoreCase)) {
            Stop-WithError -Code 11 -Message "Der Abhängigkeitspfad verlässt ToolRoot: $dependencyName"
        }
        Require-File -FilePath $filePath -FriendlyName $dependencyName -Code 11

        $expectedHash = ([string]$dependency.sha256).ToUpperInvariant()
        if ($expectedHash -notmatch '^[A-F0-9]{64}$') {
            Stop-WithError -Code 11 -Message (
                "Ungültiger SHA-256-Lockwert für $($dependency.name). " +
                "Führe .\Install-Dependencies.ps1 erneut aus."
            )
        }

        $actualHash = (Get-FileHash -LiteralPath $filePath -Algorithm SHA256).Hash.ToUpperInvariant()
        if ($actualHash -ne $expectedHash) {
            Stop-WithError -Code 11 -Message (
                "Checksumme stimmt nicht für $($dependency.name).`n" +
                "Erwartet: $expectedHash`nTatsächlich: $actualHash`n" +
                "Die Freigabe wurde fail-closed abgebrochen."
            )
        }

        $seen[$dependencyName] = $true
    }

    if ($seen.Count -ne $expectedDependencies.Count) {
        Stop-WithError -Code 11 -Message 'Das Lockfile enthält nicht exakt die erwarteten vier Abhängigkeiten.'
    }
    }
    catch {
        if ($_.Exception.Data.Contains('WorkspaceShareExitCode')) { throw }
        Stop-WithError -Code 11 -Message ('dependencies.lock.json ist ungültig: ' + $_.Exception.Message)
    }
}

function Get-ExecutableVersionText {
    param(
        [Parameter(Mandatory = $true)][string]$FilePath,
        [string[]]$Arguments = @('--version')
    )
    try {
        $result=Invoke-WorkspaceNativeProcess -Job $script:JobHandle -FilePath $FilePath -Arguments $Arguments -WorkingDirectory $script:SessionDirectory -TimeoutSeconds 20 -ExpectedExitCodes @(0)
        if ($result.ExitCode -ne 0) {
            return "Version konnte nicht gelesen werden (Exit $($result.ExitCode))"
        }
        return (($result.StdOut | Out-String).Trim())
    }
    catch {
        return "Version konnte nicht gelesen werden: $($_.Exception.Message)"
    }
}

function New-CapabilityToken {
    # 32 kryptografisch zufällige Bytes = 256 Bit Entropie.
    $bytes = New-Object byte[] 32
    $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    try {
        $rng.GetBytes($bytes)
    }
    finally {
        $rng.Dispose()
    }

    return [Convert]::ToBase64String($bytes).
        TrimEnd('=').
        Replace('+', '-').
        Replace('/', '_')
}

function Get-FreeTcpPort {
    # Zwischen Freigabe und Serverstart besteht theoretisch eine kleine Port-Race.
    # Der Aufrufer versucht deshalb bei Bindefehlern mehrere Ports.
    $listener = New-Object System.Net.Sockets.TcpListener(
        [System.Net.IPAddress]::Loopback, 0
    )
    try {
        $listener.Start()
        return ([System.Net.IPEndPoint]$listener.LocalEndpoint).Port
    }
    finally {
        $listener.Stop()
    }
}

function ConvertTo-NativeArgument {
    <#
        Korrektes Windows-Quoting für ProcessStartInfo.Arguments.
        Notwendig für Pfade und Header mit Leerzeichen/Anführungszeichen.
    #>
    param([AllowEmptyString()][string]$Value)

    if ($null -eq $Value -or $Value.Length -eq 0) {
        return '""'
    }

    if ($Value -notmatch '[\s"]') {
        return $Value
    }

    $builder = New-Object System.Text.StringBuilder
    [void]$builder.Append('"')
    $backslashes = 0

    foreach ($character in $Value.ToCharArray()) {
        if ($character -eq '\') {
            $backslashes++
            continue
        }

        if ($character -eq '"') {
            [void]$builder.Append(('\' * (($backslashes * 2) + 1)))
            [void]$builder.Append('"')
            $backslashes = 0
            continue
        }

        if ($backslashes -gt 0) {
            [void]$builder.Append(('\' * $backslashes))
            $backslashes = 0
        }

        [void]$builder.Append($character)
    }

    if ($backslashes -gt 0) {
        # Backslashes direkt vor dem schließenden Quote müssen verdoppelt werden.
        [void]$builder.Append(('\' * ($backslashes * 2)))
    }

    [void]$builder.Append('"')
    return $builder.ToString()
}

function Join-NativeArguments {
    param([string[]]$Arguments)
    return (($Arguments | ForEach-Object { ConvertTo-NativeArgument $_ }) -join ' ')
}

function Start-NativeProcess {
    param(
        [Parameter(Mandatory = $true)][string]$FilePath,
        [string[]]$Arguments = @(),
        [hashtable]$Environment = @{},
        [string]$WorkingDirectory = $ToolRoot,
        [switch]$CreateNoWindow
    )

    $startInfo = New-Object System.Diagnostics.ProcessStartInfo
    $startInfo.FileName = $FilePath
    $startInfo.Arguments = Join-NativeArguments $Arguments
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = [bool]$CreateNoWindow
    $startInfo.WorkingDirectory = $WorkingDirectory

    if($PSBoundParameters.ContainsKey('Environment')){
        foreach($key in @($startInfo.EnvironmentVariables.Keys)){[void]$startInfo.EnvironmentVariables.Remove([string]$key)}
        foreach ($key in $Environment.Keys) {$startInfo.EnvironmentVariables[$key] = [string]$Environment[$key]}
    }

    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $startInfo

    if (-not $process.Start()) {
        Stop-WithError -Code 30 -Message "Prozess konnte nicht gestartet werden: $FilePath"
    }

    $process|Add-Member -NotePropertyName WorkspaceShareStartTicks -NotePropertyValue $process.StartTime.ToUniversalTime().Ticks -Force

    return $process
}

function Get-ProcessSafe {
    param([int]$ProcessId)
    try {
        return Get-Process -Id $ProcessId -ErrorAction Stop
    }
    catch {
        return $null
    }
}

function Stop-ProcessSafe {
    param(
        [System.Diagnostics.Process]$Process,
        [int]$WaitMilliseconds = 2000
    )

    if ($null -eq $Process) {
        return
    }

    try {
        $Process.Refresh()
        if (-not $Process.HasExited) {
            Stop-Process -Id $Process.Id -Force -ErrorAction SilentlyContinue
            [void]$Process.WaitForExit($WaitMilliseconds)
        }
    }
    catch {
        # Cleanup ist best effort; der finale Verfügbarkeitstest erkennt Restfehler.
    }
}

function Stop-ProcessConfirmed {
    param(
        [System.Diagnostics.Process]$Process,
        [Parameter(Mandatory = $true)][string]$ExpectedPath,
        [ValidateRange(1, 20)][int]$Attempts = 5,
        [ValidateRange(100, 10000)][int]$WaitMilliseconds = 1500
    )

    if ($null -eq $Process) { return $true }
    try{$Process.Refresh();$ticks=if($Process.PSObject.Properties.Name -contains 'WorkspaceShareStartTicks'){[long]$Process.WorkspaceShareStartTicks}else{[long]$Process.StartTime.ToUniversalTime().Ticks};return (Stop-TrackedProcessConfirmed -ProcessId $Process.Id -ExpectedPath $ExpectedPath -ExpectedStartTicks $ticks -Attempts $Attempts -WaitMilliseconds $WaitMilliseconds)}catch{return $false}
}

function Get-CurlStatus {
    param(
        [Parameter(Mandatory = $true)][string]$Url,
        [int]$TimeoutSeconds = 10,
        [switch]$Head
    )

    $probe=Invoke-CurlProbe -Url $Url -TimeoutSeconds $TimeoutSeconds -Head:$Head
    if($probe.CurlExit -ne 0){return 0}
    return $probe.HttpStatus
}

function Assert-DeniedRoute {
    param([Parameter(Mandatory = $true)][string]$Url, [Parameter(Mandatory = $true)][string]$Description, [int]$Code = 43)
    foreach($head in @($true,$false)){
        $probe = Invoke-CurlProbe -Url $Url -TimeoutSeconds 10 -Head:$head -MaximumBytes 65536
        if ($probe.CurlExit -ne 0) { Stop-WithError -Code $Code -Message "$Description konnte nicht geprüft werden (curl exit $($probe.CurlExit))." }
        if ($probe.HttpStatus -notin @(401,403,404)) { Stop-WithError -Code $Code -Message "$Description lieferte unerwartetes HTTP $($probe.HttpStatus); erwartet wird eine explizite 4xx-Ablehnung." }
    }
}

function Protect-DiagnosticText {
    param(
        [AllowNull()][string]$Text,
        [AllowNull()][string[]]$KnownSecretUrls = @()
    )

    if ([string]::IsNullOrEmpty($Text)) { return '' }
    $safe = $Text
    $knownTokens=@();$tokenVariable=Get-Variable -Name SecretTokens -Scope Script -ErrorAction SilentlyContinue;if($tokenVariable){$knownTokens=@($tokenVariable.Value)}
    foreach($secret in $knownTokens){if(-not[string]::IsNullOrWhiteSpace($secret)){$safe=$safe.Replace($secret,'<redacted-token>')}}
    foreach ($secretUrl in @($KnownSecretUrls)) {
        if (-not [string]::IsNullOrWhiteSpace($secretUrl)) {
            $safe = $safe.Replace($secretUrl, 'https://<redacted>.trycloudflare.com/d/<redacted>/')
        }
    }
    $safe = $safe -replace '(?i)\b[a-z0-9-]+\.trycloudflare\.com\b', '<redacted>.trycloudflare.com'
    $safe = $safe -replace '(?i)/d/[A-Za-z0-9_-]{43}(?=/|\?|#|\s|"|''|$)', '/d/<redacted>'
    $safe = $safe -replace '(?i)%2Fd%2F[A-Za-z0-9_-]{43}', '%2Fd%2F<redacted>'
    return $safe
}

function Invoke-WorkspaceCurl {
    param([Parameter(Mandatory = $true)][string]$Url, [Parameter(Mandatory = $true)][string[]]$Arguments, [string[]]$PrivateConfigLines = @())
    return WorkspaceShare.Curl\Invoke-CurlWithPrivateUrl -CurlPath $script:CurlPath -Url $Url -Arguments $Arguments -PrivateConfigLines $PrivateConfigLines -Job $script:JobHandle
}

function Invoke-CurlProbe {
    param(
        [Parameter(Mandatory = $true)][string]$Url,
        [int]$TimeoutSeconds = 10,
        [switch]$Head,
        [string]$Range,
        [string[]]$ExtraArguments = @(),
        [string[]]$PrivateConfigLines = @(),
        [int64]$ExpectedBytes = 0,
        [int64]$ExpectedRangeStart = 0,
        [int64]$MaximumBytes = 65536,
        [switch]$ReadTextBody,
        [switch]$AllowFullFileResponse
    )

    $temporaryDirectory = if ($script:SessionDirectory) { $script:SessionDirectory } else { [IO.Path]::GetTempPath() }
    $id = [Guid]::NewGuid().ToString('N')
    $bodyPath = Join-Path $temporaryDirectory "probe-body-$id.tmp"
    $headerPath = Join-Path $temporaryDirectory "probe-headers-$id.tmp"
    $errorPath = Join-Path $temporaryDirectory "probe-error-$id.tmp"

    try {
        $arguments = @('--silent', '--show-error', '--stderr', $errorPath, '--output', $bodyPath,
            '--dump-header', $headerPath, '--max-time', [string]$TimeoutSeconds,
            '--header', 'Accept: application/json', '--write-out', '%{http_code}|%{remote_ip}|%{time_total}|%{size_download}')
        if (-not $Head -and $MaximumBytes -gt 0) { $arguments += @('--max-filesize', [string]$MaximumBytes) }
        if ($Head) { $arguments += '--head' }
        if (-not [string]::IsNullOrWhiteSpace($Range)) { $arguments += @('--range', $Range) }
        if ($ExtraArguments) { $arguments += $ExtraArguments }
        $result = Invoke-WorkspaceCurl -Url $Url -Arguments $arguments -PrivateConfigLines $PrivateConfigLines
        $raw = $result.StdOut
        $curlExit = $result.ExitCode
        $parts = @(((($raw | Select-Object -Last 1) | Out-String).Trim()).Split('|'))
        $httpStatus = 0
        if ($parts.Count -ge 1) { [void][int]::TryParse($parts[0], [ref]$httpStatus) }
        $remoteIp = if ($parts.Count -ge 2) { $parts[1] } else { '' }
        $timeTotal = 0.0
        if ($parts.Count -ge 3) { [void][double]::TryParse($parts[2], [Globalization.NumberStyles]::Float, [Globalization.CultureInfo]::InvariantCulture, [ref]$timeTotal) }
        $sizeDownload = 0.0
        if ($parts.Count -ge 4) { [void][double]::TryParse($parts[3], [Globalization.NumberStyles]::Float, [Globalization.CultureInfo]::InvariantCulture, [ref]$sizeDownload) }
        $actualBodyBytes = if (Test-Path -LiteralPath $bodyPath -PathType Leaf) { [int64](Get-Item -LiteralPath $bodyPath).Length } else { [int64]0 }
        $bodySha256 = if ($actualBodyBytes -gt 0) { (Get-FileHash -LiteralPath $bodyPath -Algorithm SHA256).Hash } else { '' }
        $body = ''
        $headers = if (Test-Path -LiteralPath $headerPath) { [string](Get-Content -LiteralPath $headerPath -Raw -ErrorAction SilentlyContinue) } else { '' }
        $errorText = if (Test-Path -LiteralPath $errorPath) { [string](Get-Content -LiteralPath $errorPath -Raw -ErrorAction SilentlyContinue) } else { '' }
        if ($result.StdErr) { $errorText += [Environment]::NewLine + $result.StdErr }
        $retryAfter = 0
        $retryMatch = [regex]::Match($headers, '(?im)^Retry-After:\s*([^\r\n]+)')
        if($retryMatch.Success){$value=$retryMatch.Groups[1].Value.Trim();if(-not[int]::TryParse($value,[ref]$retryAfter)){$date=[DateTime]::MinValue;if([DateTime]::TryParseExact($value,'r',[Globalization.CultureInfo]::InvariantCulture,[Globalization.DateTimeStyles]::AssumeUniversal,[ref]$date)){$retryAfter=[int][Math]::Max(0,[Math]::Ceiling(($date.ToUniversalTime()-[DateTime]::UtcNow).TotalSeconds))}}}
        $cfRay = ''
        $rayMatch = [regex]::Match($headers, '(?im)^CF-Ray:\s*([^\r\n]+)')
        if ($rayMatch.Success) { $cfRay = $rayMatch.Groups[1].Value.Trim() }
        $contentRange = ''
        $contentRangeMatch = [regex]::Match($headers, '(?im)^Content-Range:\s*([^\r\n]+)')
        if ($contentRangeMatch.Success) { $contentRange = $contentRangeMatch.Groups[1].Value.Trim() }
        $cloudflareError = 0
        if(($ReadTextBody -or $httpStatus -ge 400) -and (Test-Path -LiteralPath $bodyPath)){$body=[string](Get-Content -LiteralPath $bodyPath -Raw -ErrorAction SilentlyContinue);if($httpStatus -ge 400){foreach($pattern in @('(?i)"code"\s*:\s*(10\d{2})','(?i)\berror\s+(10\d{2})\b','(?i)\b(1033)\b')){$match=[regex]::Match($body,$pattern);if($match.Success){[void][int]::TryParse($match.Groups[1].Value,[ref]$cloudflareError);break}}}}
        $sampleValid = if ($ExpectedBytes -gt 0) {
            $expectedRangeEnd = $ExpectedRangeStart + $ExpectedBytes - 1
            $validStatus = ($httpStatus -eq 206 -and $contentRange -match ('^bytes\s+{0}-{1}/' -f $ExpectedRangeStart, $expectedRangeEnd))
            if ($AllowFullFileResponse) { $validStatus = $validStatus -or ($httpStatus -eq 200 -and $ExpectedRangeStart -eq 0) }
            ($curlExit -eq 0 -and $validStatus -and $actualBodyBytes -eq $ExpectedBytes)
        } else { ($curlExit -eq 0 -and $httpStatus -in @(200, 206)) }
        $safeErrorText = Protect-DiagnosticText -Text (($errorText | Out-String).Trim()) -KnownSecretUrls $script:SecretUrls
        $safeHeaders = Protect-DiagnosticText -Text $headers -KnownSecretUrls $script:SecretUrls
        $safeBody = Protect-DiagnosticText -Text $body -KnownSecretUrls $script:SecretUrls
        return [pscustomobject]@{ CurlExit = $curlExit; HttpStatus = $httpStatus; CloudflareError = $cloudflareError; RetryAfterSeconds = $retryAfter; RemoteIp = $remoteIp; TimeSeconds = $timeTotal; SizeDownloaded = [int64]$sizeDownload; ActualBodyBytes = $actualBodyBytes; BodySha256 = $bodySha256; ContentRange = $contentRange; CfRay = $cfRay; ErrorText = $safeErrorText; Body = $safeBody; Headers = $safeHeaders; SampleValid = $sampleValid; Success = $sampleValid }
    }
    catch {
        return [pscustomobject]@{ CurlExit = -1; HttpStatus = 0; CloudflareError = 0; RetryAfterSeconds = 0; RemoteIp = ''; TimeSeconds = 0.0; SizeDownloaded = 0; ActualBodyBytes = 0; BodySha256 = ''; ContentRange = ''; CfRay = ''; ErrorText = (Protect-DiagnosticText -Text $_.Exception.Message -KnownSecretUrls $script:SecretUrls); Body = ''; Headers = ''; SampleValid = $false; Success = $false }
    }
    finally {
        Remove-Item -LiteralPath $bodyPath -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $headerPath -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $errorPath -Force -ErrorAction SilentlyContinue
    }
}

function Get-LiveDnsOverrideConfigLines {
    param([Parameter(Mandatory = $true)][string]$HostName)
    foreach ($resolver in @('1.1.1.1', '8.8.8.8', '9.9.9.9')) {
        try {
            $address = Resolve-DnsName -Name $HostName -Type A -Server $resolver -DnsOnly -QuickTimeout -ErrorAction Stop | Where-Object { $_.PSObject.Properties['IPAddress'] -and $_.IPAddress } | Select-Object -First 1 -ExpandProperty IPAddress
            if ($address) {$value='{0}:443:{1}' -f $HostName,$address;return @('resolve = "{0}"' -f (WorkspaceShare.Curl\ConvertTo-CurlConfigQuoted $value))}
        } catch {}
    }
    return @()
}

function Get-DnsObservation {
    param([Parameter(Mandatory = $true)][string]$HostName)
    $systemAddresses = @()
    foreach ($type in @('A', 'AAAA')) {
        try { $systemAddresses += @(Resolve-DnsName -Name $HostName -Type $type -DnsOnly -QuickTimeout -ErrorAction Stop | Where-Object { $_.PSObject.Properties['IPAddress'] -and $_.IPAddress } | Select-Object -ExpandProperty IPAddress -Unique) } catch {}
    }
    $systemAddresses = @($systemAddresses | Select-Object -Unique)
    $publicResults = @()
    foreach ($resolver in @('1.1.1.1', '8.8.8.8', '9.9.9.9')) {
        $addresses = @(); $errorText = ''
        foreach ($type in @('A', 'AAAA')) {
            try { $addresses += @(Resolve-DnsName -Name $HostName -Type $type -Server $resolver -DnsOnly -QuickTimeout -ErrorAction Stop | Where-Object { $_.PSObject.Properties['IPAddress'] -and $_.IPAddress } | Select-Object -ExpandProperty IPAddress -Unique) } catch { $errorText = Protect-DiagnosticText -Text $_.Exception.Message -KnownSecretUrls $script:SecretUrls }
        }
        $addresses = @($addresses | Select-Object -Unique)
        $publicResults += [pscustomobject]@{ Resolver = $resolver; Addresses = $addresses; Success = ($addresses.Count -gt 0); Error = $errorText }
    }
    return [pscustomobject]@{ SystemAddresses = $systemAddresses; SystemSuccess = ($systemAddresses.Count -gt 0); PublicResults = $publicResults; PublicSuccessCount = @($publicResults | Where-Object { $_.Success }).Count }
}

function Wait-ForPublicDnsPublication {
    param([Parameter(Mandatory=$true)][string]$HostName,[ValidateRange(5,600)][int]$TimeoutSeconds=180)
    $timer=[Diagnostics.Stopwatch]::StartNew()
    do{
        if(Test-StopRequested){Set-ManualStopReason;Stop-WithError -Code 0 -Message 'Die Freigabe wurde manuell beendet.'}
        $successfulResolvers=0
        foreach($resolver in @('1.1.1.1','8.8.8.8','9.9.9.9')){
            try{$answer=Resolve-DnsName -Name $HostName -Type A -Server $resolver -DnsOnly -QuickTimeout -ErrorAction Stop|Where-Object { $_.PSObject.Properties['IPAddress'] -and $_.IPAddress }|Select-Object -First 1;if($answer){$successfulResolvers++}}catch{}
        }
        if($successfulResolvers -ge 2){return $true}
        Start-Sleep -Seconds 2
    }while($timer.Elapsed.TotalSeconds -lt $TimeoutSeconds)
    return $false
}

function Wait-ForHttpStatus {
    param(
        [Parameter(Mandatory = $true)][string]$Url,
        [int[]]$AcceptedStatus = @(200),
        [int]$TimeoutSeconds = 30
    )

    $timer = [Diagnostics.Stopwatch]::StartNew()
    $script:LastHttpProbe = $null

    do {
        $probe = Invoke-CurlProbe -Url $Url -TimeoutSeconds 5 -Head
        $script:LastHttpProbe = $probe
        if ($probe.CurlExit -eq 0 -and $AcceptedStatus -contains $probe.HttpStatus) {
            return $probe.HttpStatus
        }
        Start-Sleep -Milliseconds 500
    } while ($timer.Elapsed.TotalSeconds -lt $TimeoutSeconds)

    return 0
}

function Test-RangeRequest {
    param(
        [Parameter(Mandatory = $true)][string]$Url,
        [int64]$Start = 0,
        [ValidateRange(1, 10485760)][int]$LengthBytes = 1024,
        [switch]$AllowFullFileResponse
    )

    $probe = Invoke-CurlProbe -Url $Url -TimeoutSeconds 60 -Range ("{0}-{1}" -f $Start, ($Start + $LengthBytes - 1)) -ExpectedRangeStart $Start -ExpectedBytes $LengthBytes -MaximumBytes ($LengthBytes + 1024) -AllowFullFileResponse:$AllowFullFileResponse
    return $probe.SampleValid
}

function Test-MatchingRangeRequest {
    param(
        [Parameter(Mandatory = $true)][string]$LocalUrl,
        [Parameter(Mandatory = $true)][string]$PublicUrl,
        [Parameter(Mandatory = $true)][int64]$Start,
        [Parameter(Mandatory = $true)][int]$Length,
        [switch]$AllowFullFileResponse
    )
    $range = "{0}-{1}" -f $Start, ($Start + $Length - 1)
    $local = Invoke-CurlProbe -Url $LocalUrl -TimeoutSeconds 60 -Range $range -ExpectedRangeStart $Start -ExpectedBytes $Length -MaximumBytes ($Length + 1024) -AllowFullFileResponse:$AllowFullFileResponse
    $public = Invoke-CurlProbe -Url $PublicUrl -TimeoutSeconds 60 -Range $range -ExpectedRangeStart $Start -ExpectedBytes $Length -MaximumBytes ($Length + 1024) -AllowFullFileResponse:$AllowFullFileResponse
    return ($local.SampleValid -and $public.SampleValid -and $local.BodySha256 -eq $public.BodySha256)
}

function Get-HeaderDump {
    param(
        [Parameter(Mandatory = $true)][string]$Url,
        [Parameter(Mandatory = $true)][string]$OutputPath,
        [switch]$Head
    )

    $arguments = @(
        '--silent',
        '--show-error',
        '--stderr', 'NUL',
        '--max-time', '20',
        '--dump-header', $OutputPath,
        '--output', 'NUL'
    )
    if($Head){$arguments+='--head'}else{$arguments+=@('--range','0-0','--max-filesize','1')}
    return (Invoke-WorkspaceCurl -Url $Url -Arguments $arguments).ExitCode
}

function Read-PatternFile {
    param([Parameter(Mandatory = $true)][string]$FilePath)

    if (-not (Test-Path -LiteralPath $FilePath -PathType Leaf)) {
        return @()
    }

    return @(
        Get-Content -LiteralPath $FilePath -Encoding UTF8 |
        ForEach-Object { $_.Trim() } |
        Where-Object {
            $_ -and -not $_.StartsWith('#')
        }
    )
}

function Test-ForbiddenFilename {
    param([Parameter(Mandatory = $true)][string]$Name)

    $lower = $Name.ToLowerInvariant()

    # Dokumentations-/Beispieldateien sind erlaubt.
    if (
        $lower -in @('.env.example', '.env.template', '.env.sample') -or
        $lower.EndsWith('.example') -or
        $lower.EndsWith('.template') -or
        $lower.EndsWith('.sample')
    ) {
        return $false
    }

    if ($lower -eq '.env' -or $lower.StartsWith('.env.')) {
        return $true
    }

    $patterns = @(
        '*.pem',
        '*.key',
        '*.pfx',
        '*.p12',
        '*.jks',
        '*.keystore',
        'id_rsa',
        'id_rsa.*',
        'id_ed25519',
        'id_ed25519.*',
        'id_ecdsa',
        'id_ecdsa.*',
        'id_dsa',
        'id_dsa.*',
        '*.ppk',
        '*.p8',
        '*.kdbx',
        'credentials.json',
        'service-account*.json',
        'service_account*.json',
        'secrets.json',
        'secret.json',
        '*.mobileprovision',
        '*.ovpn'
    )

    foreach ($pattern in $patterns) {
        if ($lower -like $pattern) {
            return $true
        }
    }

    return $false
}

function Inspect-Workspace {
    param(
        [Parameter(Mandatory = $true)][string]$Root,
        [switch]$IncludeGeneratedContent
    )

    $skipDirectoryNames = @{
        '.git' = $true
        '.svn' = $true
        '.hg' = $true
    }

    if (-not $IncludeGeneratedContent) {
        foreach ($name in @(
            'node_modules', 'Library', 'Temp', 'obj', 'dist', 'build',
            'out', 'coverage', '.cache', '.gradle', 'DerivedData',
            '.vs', 'Logs'
        )) {
            $skipDirectoryNames[$name] = $true
        }
    }

    $stack = New-Object 'System.Collections.Generic.Stack[System.IO.DirectoryInfo]'
    $stack.Push((Get-Item -LiteralPath $Root))

    $estimatedBytes = [int64]0
    $fileCount = [int64]0
    $forbiddenFiles = New-Object System.Collections.Generic.List[string]
    $reparsePoints = New-Object System.Collections.Generic.List[string]
    $accessErrors = New-Object System.Collections.Generic.List[string]

    while ($stack.Count -gt 0) {
        $directory = $stack.Pop()

        try {
            $entries = $directory.EnumerateFileSystemInfos()
        }
        catch {
            $accessErrors.Add($directory.FullName)
            continue
        }

        foreach ($entry in $entries) {
            $isReparse = (
                ($entry.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0
            )

            if ($isReparse) {
                $reparsePoints.Add($entry.FullName)
                continue
            }

            if ($entry -is [System.IO.DirectoryInfo]) {
                if (-not $skipDirectoryNames.ContainsKey($entry.Name)) {
                    $stack.Push($entry)
                }
                continue
            }

            if ($entry -is [System.IO.FileInfo]) {
                $fileCount++
                $estimatedBytes += $entry.Length

                if (Test-ForbiddenFilename -Name $entry.Name) {
                    $forbiddenFiles.Add($entry.FullName)
                }
            }
        }
    }

    return [pscustomobject]@{
        EstimatedBytes = $estimatedBytes
        FileCount = $fileCount
        ForbiddenFiles = @($forbiddenFiles)
        ReparsePoints = @($reparsePoints)
        AccessErrors = @($accessErrors)
    }
}

function Test-SourcePathExcluded {
    param([string]$RelativePath,[string]$Name,[string[]]$Patterns)
    $normalized=$RelativePath -replace '/','\'
    $parts=@($normalized -split '\\')
    if(@($parts|Where-Object{$_ -in @('.git','.svn','.hg')}).Count -gt 0){return $true}
    foreach($pattern in @($Patterns)){
        $candidate=($pattern -replace '/','\') -replace '([\[\]`])','`$1'
        if($normalized -like $candidate -or $Name -like $candidate -or @($parts|Where-Object{$_ -like $candidate}).Count -gt 0){return $true}
    }
    return $false
}

function Get-SourceConsistencyManifest {
    param([Parameter(Mandatory=$true)][string]$Root,[string[]]$ExclusionPatterns=@())
    $result=New-Object 'System.Collections.Generic.List[string]'
    try{
        $stack=New-Object 'System.Collections.Generic.Stack[System.IO.DirectoryInfo]'
        $stack.Push((Get-Item -LiteralPath $Root -Force -ErrorAction Stop))
        while($stack.Count -gt 0){
            $directory=$stack.Pop()
            foreach($file in @($directory.EnumerateFileSystemInfos())){
                if(($file.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0){continue}
                $relative=$file.FullName.Substring($Root.Length).TrimStart('\','/').ToLowerInvariant()
                $excluded=Test-SourcePathExcluded -RelativePath $relative -Name $file.Name -Patterns $ExclusionPatterns
                if($file -is [System.IO.DirectoryInfo]){if(-not $excluded){$stack.Push($file)};continue}
                if($excluded){continue}
                $fileIdentity=(Resolve-WorkspaceDirectoryIdentity -Path $file.FullName).Identity
                $hash=(Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256 -ErrorAction Stop).Hash
                $result.Add(('{0}|{1}|{2}|{3}|{4}' -f $relative,$fileIdentity,$file.Length,$file.LastWriteTimeUtc.Ticks,$hash))
            }
        }
    }catch{Stop-WithError -Code 20 -Message ('Die Quelle änderte sich oder konnte während der Snapshot-Prüfung nicht gelesen werden: '+$_.Exception.Message)}
    return @($result|Sort-Object)
}

function Get-CloudflaredConfigConflicts {
    $directory = Join-Path $env:USERPROFILE '.cloudflared'
    return @(
        Join-Path $directory 'config.yml'
        Join-Path $directory 'config.yaml'
    ) | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf }
}

function Assert-FreeDiskSpace {
    param(
        [Parameter(Mandatory = $true)][string]$TargetDirectory,
        [Parameter(Mandatory = $true)][int64]$EstimatedSourceBytes
    )

    $root = [IO.Path]::GetPathRoot([IO.Path]::GetFullPath($TargetDirectory))
    $drive = New-Object System.IO.DriveInfo($root)
    $required = ($EstimatedSourceBytes * 2) + 2GB

    if ($drive.AvailableFreeSpace -lt $required) {
        Stop-WithError -Code 21 -Message (
            "Nicht genügend freier Speicher für den Snapshot.`n" +
            "Konservativ benötigt: {0:N2} GB`nVerfügbar: {1:N2} GB" -f
            ($required / 1GB), ($drive.AvailableFreeSpace / 1GB)
        )
    }
}

function Invoke-GitleaksScan {
    param(
        [Parameter(Mandatory = $true)][string]$SourceRoot,
        [Parameter(Mandatory = $true)][string]$ReportPath
    )

    $arguments = @(
        'dir',
        '--config', $GitleaksConfigPath,
        '--no-banner',
        '--no-color',
        '--ignore-gitleaks-allow',
        '--max-archive-depth','3',
        '--redact=100',
        '--report-format', 'json',
        '--report-path', $ReportPath,
        '--exit-code', '20',
        '--timeout', '900',
        $SourceRoot
    )

    try{$result=Invoke-WorkspaceNativeProcess -Job $script:JobHandle -FilePath $GitleaksPath -Arguments $arguments -WorkingDirectory $script:SessionDirectory -TimeoutSeconds 930 -ExpectedExitCodes @(0,20)}catch{if($_.Exception.Data.Contains('WorkspaceShareExitCode')){throw};Stop-WithError -Code 22 -Message ('Gitleaks-Prüfung fehlgeschlagen: '+(Protect-DiagnosticText $_.Exception.Message))}
    $code = $result.ExitCode

    if ($code -eq 20) {
        Stop-WithError -Code 22 -Message (
            "Gitleaks hat mögliche Geheimnisse gefunden. " +
            'Der redigierte Bericht wird mit den sicheren Diagnoseinformationen aufbewahrt.'
        )
    }

    if ($code -ne 0) {
        Stop-WithError -Code 22 -Message (
            "Gitleaks konnte den Workspace nicht zuverlässig prüfen (Exit $code). " +
            "Die Freigabe wurde sicherheitshalber abgebrochen."
        )
    }
}

function Invoke-SevenZipSnapshot {
    param(
        [Parameter(Mandatory = $true)][string]$SourceRoot,
        [Parameter(Mandatory = $true)][string]$DestinationArchive,
        [Parameter(Mandatory = $true)][string]$IncludeListPath,
        [Parameter(Mandatory = $true)][string]$LogPath
    )

    $compressionArgument = if ($Compression -eq 'Store') { '-mx=0' } else { '-mx=1' }

    $arguments = @(
        'a',
        '-tzip',
        $compressionArgument,
        '-mmt=on',
        '-sse',
        '-y',
        '-bd',
        '-bb1',
        '-scsUTF-8',
        $DestinationArchive,
        ("@$IncludeListPath")
    )

    # Der Workspace selbst ist nur das Arbeitsverzeichnis. Dadurch enthält das
    # ZIP direkt dessen Inhalt statt einer zusätzlichen Root-Ordner-Ebene.
    try{$result=Invoke-WorkspaceNativeProcess -Job $script:JobHandle -FilePath $SevenZipPath -Arguments $arguments -WorkingDirectory $SourceRoot -TimeoutSeconds 3600 -ExpectedExitCodes @(0) -StdOutPath $LogPath -StdErrPath ($LogPath+'.stderr') -KeepLogs}catch{if($_.Exception.Data.Contains('WorkspaceShareExitCode')){throw};Stop-WithError -Code 23 -Message ('7-Zip ist fehlgeschlagen: '+(Protect-DiagnosticText $_.Exception.Message))}
    $code = $result.ExitCode
    if($result.StdOut){Write-Host $result.StdOut}

    if ($code -ne 0) {
        Stop-WithError -Code 23 -Message (
            "7-Zip konnte keinen vollständigen Snapshot erstellen (Exit $code). " +
            "Details: $LogPath"
        )
    }

    if (
        -not (Test-Path -LiteralPath $DestinationArchive -PathType Leaf) -or
        (Get-Item -LiteralPath $DestinationArchive).Length -le 0
    ) {
        Stop-WithError -Code 23 -Message "Das erzeugte Archiv fehlt oder ist leer."
    }
}

function Test-SevenZipArchive {
    param(
        [Parameter(Mandatory = $true)][string]$ArchivePath,
        [Parameter(Mandatory = $true)][string]$LogPath
    )

    try{$result=Invoke-WorkspaceNativeProcess -Job $script:JobHandle -FilePath $SevenZipPath -Arguments @('t','-bd','-bb1',$ArchivePath) -WorkingDirectory $script:SessionDirectory -TimeoutSeconds 1800 -ExpectedExitCodes @(0) -StdOutPath $LogPath -StdErrPath ($LogPath+'.stderr') -KeepLogs}catch{if($_.Exception.Data.Contains('WorkspaceShareExitCode')){throw};Stop-WithError -Code 23 -Message ('7-Zip ist fehlgeschlagen: '+(Protect-DiagnosticText $_.Exception.Message))}
    if ($result.ExitCode -ne 0) {
        Stop-WithError -Code 23 -Message (
            "Die Integritätsprüfung des ZIP-Archivs ist fehlgeschlagen. Details: $LogPath"
        )
    }
}

function Write-SevenZipManifest {
    param(
        [Parameter(Mandatory = $true)][string]$ArchivePath,
        [Parameter(Mandatory = $true)][string]$ManifestPath
    )

    try{$result=Invoke-WorkspaceNativeProcess -Job $script:JobHandle -FilePath $SevenZipPath -Arguments @('l','-slt',$ArchivePath) -WorkingDirectory $script:SessionDirectory -TimeoutSeconds 600 -ExpectedExitCodes @(0) -StdOutPath $ManifestPath -StdErrPath ($ManifestPath+'.stderr') -KeepLogs}catch{if($_.Exception.Data.Contains('WorkspaceShareExitCode')){throw};Stop-WithError -Code 23 -Message ('7-Zip ist fehlgeschlagen: '+(Protect-DiagnosticText $_.Exception.Message))}
    if ($result.ExitCode -ne 0) {
        Stop-WithError -Code 23 -Message "Das Archivmanifest konnte nicht erstellt werden."
    }
}

function Start-MiniserveReadOnly {
    param(
        [Parameter(Mandatory = $true)][string]$Archive,
        [Parameter(Mandatory = $true)][string]$CapabilityToken,
        [Parameter(Mandatory = $true)][int]$Port
    )

    $arguments = @(
        '--quiet',
        '--log-color', 'never',
        '--interfaces', '127.0.0.1',
        '--port', [string]$Port,
        '--workers', '2',
        '--no-symlinks',

        '--header', 'Cache-Control: private, no-store, no-cache, max-age=0, must-revalidate',
        '--header', 'Cloudflare-CDN-Cache-Control: no-store',
        '--header', 'Pragma: no-cache',
        '--header', 'Expires: 0',
        '--header', 'Referrer-Policy: no-referrer',
        '--header', 'X-Content-Type-Options: nosniff',
        '--header', 'X-Frame-Options: DENY',
        '--header', 'Cross-Origin-Resource-Policy: same-origin',

        $Archive
    )

    # Das Token bleibt aus argv und aus der Launcher-Umgebung. CreateProcess
    # erhält einen expliziten, allowlist-basierten Child-Environment-Block.
    $childEnvironment=New-WorkspaceChildEnvironment -Additional @{MINISERVE_ROUTE_PREFIX=("d/{0}" -f $CapabilityToken)}
    $process = Start-WorkspaceProcessInJob `
            -Job $script:JobHandle `
            -FilePath $MiniservePath `
            -Arguments $arguments `
            -WorkingDirectory $script:SessionDirectory `
            -StdOutPath (Join-Path $script:SessionDirectory 'miniserve.stdout.log') `
            -StdErrPath (Join-Path $script:SessionDirectory 'miniserve.stderr.log') `
            -Environment $childEnvironment
    $process | Add-Member -NotePropertyName WorkspaceShareStartTicks -NotePropertyValue $process.StartTime.ToUniversalTime().Ticks -Force
    return $process
}

function Start-CloudflaredQuickTunnel {
    param(
        [Parameter(Mandatory = $true)][string]$OriginUrl,
        [Parameter(Mandatory = $true)][string]$StdOutPath,
        [Parameter(Mandatory = $true)][string]$StdErrPath,
        [Parameter(Mandatory = $true)][int]$MetricsPort,
        [Parameter(Mandatory = $true)][string]$Protocol,
        [Parameter(Mandatory = $true)][string]$EdgeIpVersion,
        [Parameter(Mandatory = $true)][int]$Retries
    )

    $arguments = @(
        'tunnel', '--url', $OriginUrl,
        '--no-autoupdate',
        '--metrics', ("127.0.0.1:{0}" -f $MetricsPort),
        '--protocol', $Protocol,
        '--edge-ip-version', $EdgeIpVersion,
        '--retries', [string]$Retries,
        '--loglevel', 'info'
    )

    $childEnvironment=New-WorkspaceChildEnvironment
    $process=Start-WorkspaceProcessInJob -Job $script:JobHandle -FilePath $CloudflaredPath -Arguments $arguments -WorkingDirectory $script:SessionDirectory -StdOutPath $StdOutPath -StdErrPath $StdErrPath -Environment $childEnvironment
    $process|Add-Member -NotePropertyName WorkspaceShareStartTicks -NotePropertyValue $process.StartTime.ToUniversalTime().Ticks -Force
    return $process
}

function Wait-ForCloudflaredMetrics {
    param(
        [Parameter(Mandatory = $true)][System.Diagnostics.Process]$Process,
        [Parameter(Mandatory = $true)][int]$MetricsPort,
        [int]$TimeoutSeconds = 15
    )

    $timer=[Diagnostics.Stopwatch]::StartNew()
    do {
        if(Test-StopRequested){Set-ManualStopReason;Stop-WithError -Code 0 -Message 'Die Freigabe wurde manuell beendet.'}
        $Process.Refresh()
        if ($Process.HasExited) { return $false }
        $probe = Invoke-CurlProbe -Url "http://127.0.0.1:$MetricsPort/healthcheck" -TimeoutSeconds 3
        if ($probe.CurlExit -eq 0 -and $probe.HttpStatus -eq 200) { return $true }
        Start-Sleep -Milliseconds 500
    } while ($timer.Elapsed.TotalSeconds -lt $TimeoutSeconds)
    return $false
}

function Get-CloudflaredReadiness {
    param([Parameter(Mandatory = $true)][int]$MetricsPort)
    $probe = Invoke-CurlProbe -Url "http://127.0.0.1:$MetricsPort/ready" -TimeoutSeconds 5 -ReadTextBody
    $readyConnections = 0
    $connectorId = ''
    if ($probe.Body) {
        try {
            $json = $probe.Body | ConvertFrom-Json
            if ($null -ne $json.readyConnections) { $readyConnections = [int]$json.readyConnections }
            if ($null -ne $json.connectorId) { $connectorId = [string]$json.connectorId }
        } catch {}
    }
    return [pscustomobject]@{ Ready = ($probe.CurlExit -eq 0 -and $probe.HttpStatus -eq 200 -and $readyConnections -gt 0); HttpStatus = $probe.HttpStatus; CurlExit = $probe.CurlExit; ReadyConnections = $readyConnections; ConnectorId = $connectorId; ErrorText = $probe.ErrorText }
}

function Get-QuickTunnelHostnameState {
    param([Parameter(Mandatory = $true)][int]$MetricsPort, [Parameter(Mandatory = $true)][string]$ExpectedHostname)
    $temporaryPath = Join-Path ([IO.Path]::GetTempPath()) ("workspaceshare-quicktunnel-{0}.json" -f [Guid]::NewGuid().ToString('N'))
    try {
        $result = Invoke-WorkspaceCurl -Url "http://127.0.0.1:$MetricsPort/quicktunnel" -Arguments @('--silent', '--show-error', '--max-time', '5', '--max-filesize', '65536', '--output', $temporaryPath)
        if ($result.ExitCode -ne 0 -or -not (Test-Path -LiteralPath $temporaryPath -PathType Leaf)) {
            return [pscustomobject]@{ Available = $false; Matches = $false; CurlExit = $result.ExitCode; ParseError = $false }
        }
        $actualHostname = ([string]((Get-Content -LiteralPath $temporaryPath -Raw -ErrorAction Stop | ConvertFrom-Json).hostname)).Trim().ToLowerInvariant()
        $expected = $ExpectedHostname.Trim().ToLowerInvariant()
        return [pscustomobject]@{ Available = -not [string]::IsNullOrWhiteSpace($actualHostname); Matches = (-not [string]::IsNullOrWhiteSpace($actualHostname) -and $actualHostname -eq $expected); CurlExit = $result.ExitCode; ParseError = $false }
    }
    catch { return [pscustomobject]@{ Available = $false; Matches = $false; CurlExit = -1; ParseError = $true } }
    finally { Remove-Item -LiteralPath $temporaryPath -Force -ErrorAction SilentlyContinue }
}

function Get-CloudflaredConnectionMetric {
    param([Parameter(Mandatory = $true)][int]$MetricsPort)
    $probe = Invoke-CurlProbe -Url "http://127.0.0.1:$MetricsPort/metrics" -TimeoutSeconds 5 -MaximumBytes 4194304 -ReadTextBody
    if ($probe.CurlExit -ne 0 -or $probe.HttpStatus -ne 200) { return -1 }
    $matches = [regex]::Matches($probe.Body, '(?m)^cloudflared_tunnel_ha_connections(?:\{[^}]*\})?\s+([0-9.eE+-]+)\s*$')
    if ($matches.Count -eq 0) { return -1 }
    $sum = 0.0
    foreach ($match in $matches) {
        $value = 0.0
        if ([double]::TryParse($match.Groups[1].Value, [Globalization.NumberStyles]::Float, [Globalization.CultureInfo]::InvariantCulture, [ref]$value)) { $sum += $value }
    }
    return [int][Math]::Round($sum)
}

function Get-TunnelHealthSnapshot {
    param(
        [Parameter(Mandatory = $true)][string]$PublicUrl,
        [Parameter(Mandatory = $true)][string]$LocalUrl,
        [Parameter(Mandatory = $true)][int]$MetricsPort,
        [Parameter(Mandatory = $true)][int64]$SampleStart,
        [Parameter(Mandatory = $true)][int]$SampleBytes,
        [switch]$AllowFullFileResponse
    )

    $startedUtc = [DateTime]::UtcNow
    $now = $startedUtc
    $expectedHost = ([Uri]$PublicUrl).DnsSafeHost.ToLowerInvariant()
    $sampleRange = "{0}-{1}" -f $SampleStart, ($SampleStart + $SampleBytes - 1)
    $localProbe = Invoke-CurlProbe -Url $LocalUrl -TimeoutSeconds 5 -Range $sampleRange -ExpectedRangeStart $SampleStart -ExpectedBytes $SampleBytes -MaximumBytes 65536 -AllowFullFileResponse:$AllowFullFileResponse
    $readiness = Get-CloudflaredReadiness -MetricsPort $MetricsPort
    $hostnameState = Get-QuickTunnelHostnameState -MetricsPort $MetricsPort -ExpectedHostname $expectedHost
    # This is the authoritative client check: it deliberately never uses --resolve.
    $publicProbe = Invoke-CurlProbe -Url $PublicUrl -TimeoutSeconds 12 -Range $sampleRange -ExpectedRangeStart $SampleStart -ExpectedBytes $SampleBytes -MaximumBytes 65536 -AllowFullFileResponse:$AllowFullFileResponse
    $endToEndSampleValid = ($localProbe.SampleValid -and $publicProbe.SampleValid -and $localProbe.BodySha256 -eq $publicProbe.BodySha256)
    $overrideProbe = $null
    $dns = $null
    $connectionMetric = -1
    if (-not $endToEndSampleValid) {
        $connectionMetric = Get-CloudflaredConnectionMetric -MetricsPort $MetricsPort
        $dnsAgeSeconds=if($script:LastDnsDiagnosticTimestamp -gt 0){([Diagnostics.Stopwatch]::GetTimestamp()-$script:LastDnsDiagnosticTimestamp)/[double][Diagnostics.Stopwatch]::Frequency}else{[double]::PositiveInfinity}
        if ($script:LastDnsObservation -and $dnsAgeSeconds -lt 60) {
            $dns = $script:LastDnsObservation
        }
        else {
            $dns = Get-DnsObservation -HostName $expectedHost
            $script:LastDnsObservation = $dns
            $script:LastDnsDiagnosticTimestamp = [Diagnostics.Stopwatch]::GetTimestamp()
        }
        $overrideArguments = @(Get-LiveDnsOverrideConfigLines -HostName $expectedHost)
        if ($overrideArguments.Count -gt 0) {
            $overrideProbe = Invoke-CurlProbe -Url $PublicUrl -TimeoutSeconds 12 -Range $sampleRange -ExpectedRangeStart $SampleStart -ExpectedBytes $SampleBytes -MaximumBytes 65536 -PrivateConfigLines $overrideArguments -AllowFullFileResponse:$AllowFullFileResponse
        }
    }

    $overrideSuccess = if ($overrideProbe) { [bool]$overrideProbe.Success } else { $false }
    $classification = Get-TunnelClassification -LocalSampleValid $localProbe.SampleValid -EndToEndSampleValid $endToEndSampleValid -HostnameAvailable $hostnameState.Available -HostnameMatches $hostnameState.Matches -PublicHttpStatus $publicProbe.HttpStatus -CloudflareError $publicProbe.CloudflareError -PublicCurlExit $publicProbe.CurlExit -OverrideDiagnosticSuccess $overrideSuccess -PublicDnsSuccessCount $(if ($dns) { [int]$dns.PublicSuccessCount } else { 0 }) -DnsChecked ($null -ne $dns) -SystemDnsSuccess $(if ($dns) { [bool]$dns.SystemSuccess } else { $false }) -Ready $readiness.Ready
    $message = 'Exact public archive sample matches the local archive sample.'
    $readinessDisagreement = ($endToEndSampleValid -and -not $readiness.Ready)
    switch ($classification) {
        'LocalOriginFailure' { $message = 'miniserve process exists, but the local archive sample is invalid.' }
        'HostnameChanged' { $message = 'cloudflared reports a different Quick Tunnel hostname than the shared URL.' }
        'RateLimited' { $message = 'Cloudflare rate limiting or Quick Tunnel concurrent-request limiting was observed.' }
        'NoHealthyConnector' { $message = 'Cloudflare reports that no healthy cloudflared connector can receive traffic.' }
        'DnsResolutionFailure' { $message = 'Normal DNS failed, but a fresh direct Cloudflare-IP diagnostic request succeeded.' }
        'DnsMissing' { $message = 'No tested public resolver returned an A or AAAA record for the Quick Tunnel hostname.' }
        'EdgeDisconnected' { $message = 'cloudflared is running but /ready reports no active Cloudflare edge connection.' }
        'CloudflareProxyFailure' { $message = 'Cloudflare returned an origin or routing failure.' }
        'PublicTransportFailure' { $message = 'The ordinary public archive sample was invalid or did not match the local archive.' }
    }

    $completedUtc = [DateTime]::UtcNow
    return [pscustomobject]@{
        Utc = $completedUtc.ToString('o'); StartedUtc = $startedUtc.ToString('o'); CompletedUtc = $completedUtc.ToString('o'); DurationSeconds = ($completedUtc - $startedUtc).TotalSeconds; Classification = $classification; Message = $message
        LocalSuccess = [bool]$localProbe.SampleValid; LocalCurlExit = [int]$localProbe.CurlExit; LocalHttpStatus = [int]$localProbe.HttpStatus; LocalSampleSha256 = $localProbe.BodySha256
        Ready = [bool]$readiness.Ready; ReadyHttpStatus = [int]$readiness.HttpStatus; ReadyConnections = [int]$readiness.ReadyConnections; ConnectionMetric = [int]$connectionMetric
        ReadinessDisagreement = $readinessDisagreement; QuickTunnelHostnameAvailable = [bool]$hostnameState.Available; QuickTunnelHostnameMatches = [bool]$hostnameState.Matches; QuickTunnelHostnameParseError = [bool]$hostnameState.ParseError; DnsChecked = ($null -ne $dns); SystemDns = if ($dns) { [Nullable[bool]]$dns.SystemSuccess } else { $null }; PublicDnsSuccessCount = if ($dns) { [Nullable[int]]$dns.PublicSuccessCount } else { $null }
        PublicSuccess = [bool]$endToEndSampleValid; PublicCurlExit = [int]$publicProbe.CurlExit; PublicHttpStatus = [int]$publicProbe.HttpStatus; PublicSampleSha256 = $publicProbe.BodySha256
        CloudflareError = [int]$publicProbe.CloudflareError; RetryAfterSeconds = [int]$publicProbe.RetryAfterSeconds; RemoteIp = [string]$publicProbe.RemoteIp
        PublicTimeSeconds = [double]$publicProbe.TimeSeconds; CfRay = [string]$publicProbe.CfRay; CurlError = [string]$publicProbe.ErrorText
        OverrideDiagnosticSuccess = if ($overrideProbe) { [bool]$overrideProbe.Success } else { $false }
    }
}

function Write-HealthSnapshot {
    param([Parameter(Mandatory = $true)]$Snapshot)
    try {
        $serialized = Protect-DiagnosticText -Text ($Snapshot | ConvertTo-Json -Depth 6 -Compress) -KnownSecretUrls $script:SecretUrls
        Add-Content -LiteralPath $script:HealthLogPath -Value $serialized -Encoding UTF8 -ErrorAction Stop
        return $true
    }
    catch {
        if (([DateTime]::UtcNow - $script:LastHealthLogWarningUtc).TotalSeconds -ge 60) {
            Write-Warning ("Health state could not be written: " + (Protect-DiagnosticText -Text $_.Exception.Message -KnownSecretUrls $script:SecretUrls))
            $script:LastHealthLogWarningUtc = [DateTime]::UtcNow
        }
        return $false
    }
}

function Wait-ForHealthyTunnel {
    param(
        [Parameter(Mandatory = $true)][string]$PublicUrl,
        [Parameter(Mandatory = $true)][string]$LocalUrl,
        [Parameter(Mandatory = $true)][int]$MetricsPort,
        [Parameter(Mandatory = $true)][int64]$SampleStart,
        [Parameter(Mandatory = $true)][int]$SampleBytes,
        [switch]$AllowFullFileResponse,
        [ValidateRange(5, 600)][int]$TimeoutSeconds = 180
    )
    $timer=[Diagnostics.Stopwatch]::StartNew()
    $snapshot = $null
    do {
        if(Test-StopRequested){Set-ManualStopReason;return $null}
        $snapshot = Get-TunnelHealthSnapshot -PublicUrl $PublicUrl -LocalUrl $LocalUrl -MetricsPort $MetricsPort -SampleStart $SampleStart -SampleBytes $SampleBytes -AllowFullFileResponse:$AllowFullFileResponse
        [void](Write-HealthSnapshot -Snapshot $snapshot)
        if ($snapshot.Classification -eq 'Healthy') { return $snapshot }
        if(Test-StopRequested){Set-ManualStopReason;return $null}
        Start-Sleep -Seconds 2
    } while ($timer.Elapsed.TotalSeconds -lt $TimeoutSeconds)
    return $snapshot
}

function Save-FailureDiagnostics {
    param([string]$SessionId, [string]$CloudflaredStdOut, [string]$CloudflaredStdErr)
    if (-not $KeepDiagnosticsOnError -or $script:FailureDiagnosticsSaved -or -not $script:SessionDirectory) { return }
    try {
        $diagnosticsBase = Join-Path (Split-Path $SessionBase -Parent) 'diagnostics'
        New-Item -ItemType Directory -Path $diagnosticsBase -Force | Out-Null
        $safeSessionName = if ($SessionId) { $SessionId } else { [DateTime]::UtcNow.ToString('yyyyMMdd-HHmmss') }
        $script:DiagnosticsPath = Join-Path $diagnosticsBase $safeSessionName
        New-Item -ItemType Directory -Path $script:DiagnosticsPath -Force | Out-Null
        Set-PrivateDirectoryAcl -Directory $script:DiagnosticsPath
        $sources = New-Object 'System.Collections.Generic.List[string]'
        foreach ($source in @($CloudflaredStdOut, $CloudflaredStdErr, $script:HealthLogPath, (Join-Path $script:SessionDirectory 'public-headers.txt'), (Join-Path $script:SessionDirectory 'volatile-cloudflared-ready.txt'))) {
            if ($source) { $sources.Add($source) }
        }
        foreach ($name in @('gitleaks-redacted.json','7zip-create.log','7zip-test.log','archive.sha256.txt')) {
            $candidate = Join-Path $script:SessionDirectory $name
            if (Test-Path -LiteralPath $candidate -PathType Leaf) { $sources.Add($candidate) }
        }
        foreach ($attemptLog in @(Get-ChildItem -LiteralPath $script:SessionDirectory -File -ErrorAction SilentlyContinue | Where-Object { $_.Name -match '^cloudflared-attempt-\d+\.(stdout|stderr)\.log$' })) {
            $sources.Add($attemptLog.FullName)
        }
        foreach ($source in @($sources | Select-Object -Unique)) {
            if ($source -and (Test-Path -LiteralPath $source -PathType Leaf)) {
                $destination = Join-Path $script:DiagnosticsPath (Split-Path $source -Leaf)
                $sanitized = Protect-DiagnosticText -Text (Read-BoundedDiagnosticText -Path $source) -KnownSecretUrls $script:SecretUrls
                Set-Content -LiteralPath $destination -Value $sanitized -Encoding UTF8
            }
        }
        $environment = [ordered]@{
            capturedUtc = [DateTime]::UtcNow.ToString('o'); powershell = $PSVersionTable.PSVersion.ToString()
            cloudflared = Get-ExecutableVersionText -FilePath $CloudflaredPath
            cloudflaredSha256 = if (Test-Path -LiteralPath $CloudflaredPath -PathType Leaf) { (Get-FileHash -LiteralPath $CloudflaredPath -Algorithm SHA256).Hash } else { '' }
            miniserve = Get-ExecutableVersionText -FilePath $MiniservePath
            tunnelProtocol = $TunnelProtocol; edgeIpVersion = $TunnelEdgeIpVersion; healthCheckSeconds = $HealthCheckSeconds; tunnelRetries = $TunnelRetries
        }
        $environment | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $script:DiagnosticsPath 'environment.json') -Encoding UTF8
        Get-ChildItem -LiteralPath $script:DiagnosticsPath -Filter '*.zip' -File -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue
        $script:FailureDiagnosticsSaved = $true
        Write-Warning ("Sichere Diagnoseinformationen wurden gespeichert:`n" + $script:DiagnosticsPath)
    }
    catch {
        $safeMessage = Protect-DiagnosticText -Text $_.Exception.Message -KnownSecretUrls $script:SecretUrls
        Write-Warning ("Diagnoseinformationen konnten nicht vollständig gespeichert werden: " + $safeMessage)
    }
}

function Wait-ForQuickTunnelUrl {
    param(
        [Parameter(Mandatory = $true)][System.Diagnostics.Process]$Process,
        [Parameter(Mandatory = $true)][string[]]$LogPaths,
        [int]$TimeoutSeconds = 60
    )

    $timer=[Diagnostics.Stopwatch]::StartNew()
    $regex = '(?<![a-z0-9.-])https://(?!api\.)[a-z0-9-]+\.trycloudflare\.com(?:/|\s|$)'

    do {
        if(Test-StopRequested){Set-ManualStopReason;Stop-WithError -Code 0 -Message 'Die Freigabe wurde manuell beendet.'}
        $Process.Refresh()
        if ($Process.HasExited) {
            Stop-WithError -Code 41 -Message (
                "cloudflared wurde vor Bereitstellung des Tunnels beendet (Exit " +
                "$($Process.ExitCode))."
            )
        }

        $combined = ''
        foreach ($logPath in $LogPaths) {
            if (Test-Path -LiteralPath $logPath) {
                $combined += "`n" + (Get-Content -LiteralPath $logPath -Raw -ErrorAction SilentlyContinue)
            }
        }

        $match = [regex]::Match($combined, $regex)
        if ($match.Success) {
            return $match.Value.Trim().TrimEnd('/')
        }

        Start-Sleep -Milliseconds 500
    } while ($timer.Elapsed.TotalSeconds -lt $TimeoutSeconds)

    Stop-WithError -Code 42 -Message (
        "Cloudflare hat innerhalb von $TimeoutSeconds Sekunden keine Quick-Tunnel-URL geliefert."
    )
}

function Assert-CacheHeaders {
    param(
        [Parameter(Mandatory = $true)][string]$Url,
        [Parameter(Mandatory = $true)][string]$HeaderPath
    )

    foreach($head in @($true,$false)){
        $path=if($head){$HeaderPath}else{[IO.Path]::ChangeExtension($HeaderPath,'get.txt')}
        $curlExit=Get-HeaderDump -Url $Url -OutputPath $path -Head:$head
        if($curlExit -ne 0){Stop-WithError -Code 43 -Message 'Öffentliche Antwortheader konnten nicht geprüft werden.'}
        $headers=Get-Content -LiteralPath $path -Raw
        if($headers -match '(?im)^cf-cache-status:\s*HIT\s*$'){Stop-WithError -Code 43 -Message 'Cloudflare meldet CF-Cache-Status: HIT. Die Freigabe wird nicht fortgesetzt.'}
        if($headers -notmatch '(?im)^cache-control:.*\bno-store\b'){Stop-WithError -Code 43 -Message 'Der öffentliche Endpunkt liefert keinen bestätigten Cache-Control:no-store-Header.'}
    }
}

function Enable-SystemAwake {
    try {
        if (-not ('WorkspaceShare.NativePower' -as [type])) {
            Add-Type @'
using System;
using System.Runtime.InteropServices;

namespace WorkspaceShare {
    public static class NativePower {
        [DllImport("kernel32.dll", SetLastError = true)]
        public static extern uint SetThreadExecutionState(uint esFlags);
    }
}
'@
        }

        # ES_CONTINUOUS | ES_SYSTEM_REQUIRED (0x80000001; als uint32, da PS 5.1 das Hex-Literal als negatives Int32 liest)
        $result = [WorkspaceShare.NativePower]::SetThreadExecutionState([uint32]2147483649)
        if ($result -eq 0) {
            throw 'SetThreadExecutionState returned zero.'
        }
        $script:SleepPreventionEnabled = $true
    }
    catch {
        Write-Warning (
            "Windows-Energiesparmodus konnte nicht automatisch verhindert werden. " +
            "Bitte den Rechner während der Freigabe wach halten."
        )
    }
}

function Disable-SystemAwake {
    if ($script:SleepPreventionEnabled) {
        try {
            # ES_CONTINUOUS (0x80000000)
            [void][WorkspaceShare.NativePower]::SetThreadExecutionState([uint32]2147483648)
        }
        catch {
        }
    }
}

function Copy-LinkToClipboard {
    param([Parameter(Mandatory = $true)][string]$Url)

    if ($NoClipboard) {
        return $false
    }

    try {
        # Bevorzugt: Clipboard-Verlauf (Win+V) und Cloud-Clipboard ausschließen (nur im STA-Thread möglich).
        $copied = $false
        if ([Threading.Thread]::CurrentThread.GetApartmentState() -eq 'STA') {
            try {
                Add-Type -AssemblyName System.Windows.Forms
                $data = New-Object System.Windows.Forms.DataObject
                $data.SetData([System.Windows.Forms.DataFormats]::UnicodeText, $Url)
                foreach ($format in @('ExcludeClipboardContentFromMonitorProcessing', 'CanIncludeInClipboardHistory', 'CanUploadToCloudClipboard')) {
                    $data.SetData($format, (New-Object IO.MemoryStream(, [byte[]](0, 0, 0, 0))))
                }
                [System.Windows.Forms.Clipboard]::SetDataObject($data, $true)
                $copied = $true
            }
            catch { $copied = $false }
        }

        if (-not $copied) {
            $setClipboard = Get-Command 'Set-Clipboard' -ErrorAction SilentlyContinue
            if ($setClipboard) {
                Set-Clipboard -Value $Url -ErrorAction Stop
            }
            else {
                $Url | & "$env:SystemRoot\System32\clip.exe"
                if ($LASTEXITCODE -ne 0) { return $false }
            }
        }

        $script:ClipboardUrl = $Url
        return $true
    }
    catch {
        return $false
    }
}

function Clear-SensitiveClipboard {
    if ($NoClipboard -or $KeepClipboard -or -not $script:ClipboardUrl) {
        return
    }

    try {
        $getClipboard = Get-Command 'Get-Clipboard' -ErrorAction SilentlyContinue
        $setClipboard = Get-Command 'Set-Clipboard' -ErrorAction SilentlyContinue
        if ($getClipboard -and $setClipboard) {
            $current = Get-Clipboard -Raw -ErrorAction Stop
            if ($current.TrimEnd([char[]]"`r`n") -eq $script:ClipboardUrl) {
                # Set-Clipboard akzeptiert in Windows PowerShell keinen leeren Wert.
                # Ein einzelnes Leerzeichen entfernt den geheimen Link zuverlässig.
                Set-Clipboard -Value ' '
            }
        }
    }
    catch {
        # Keine Freigabe darf wegen einer Clipboard-Bereinigung scheitern.
    }
}

function Write-SessionMetadata {
    param(
        [ValidateSet('SetupProtected','Active','Stopping','Retained')][string]$Phase='SetupProtected',
        [Parameter(Mandatory = $true)][datetime]$ExpiresUtc,
        [Parameter(Mandatory = $true)][string]$SourceRoot,
        [Parameter(Mandatory = $true)][string]$Archive,
        [int]$WatchdogPid = 0,
        [long]$WatchdogStartTicks = 0
    )

    $powershellExe = Join-Path $PSHOME 'powershell.exe'
    $launcherProcess = Get-Process -Id $PID

    $metadata = [ordered]@{
        magic = 'WorkspaceShareSession'
        schema = 2
        phase = $Phase
        createdUtc = [DateTime]::UtcNow.ToString('o')
        expiresUtc = $ExpiresUtc.ToString('o')
        sourceRoot = $SourceRoot
        archivePath = $Archive
        jobName = $script:JobName

        launcherPid = $PID
        launcherStartTicks = $launcherProcess.StartTime.ToUniversalTime().Ticks
        launcherPath = $launcherProcess.Path

        miniservePid = if ($script:MiniserveProcess) { $script:MiniserveProcess.Id } else { 0 }
        miniserveStartTicks = Get-ProcessStartTicksSafe $script:MiniserveProcess
        miniservePath = $MiniservePath

        cloudflaredPid = if ($script:CloudflaredProcess) { $script:CloudflaredProcess.Id } else { 0 }
        cloudflaredStartTicks = Get-ProcessStartTicksSafe $script:CloudflaredProcess
        cloudflaredPath = $CloudflaredPath

        watchdogPid = $WatchdogPid
        watchdogStartTicks = $WatchdogStartTicks
        watchdogPath = $powershellExe

        keepArchive = [bool](Test-EffectiveKeepArchive)
        # Bewusst keine URL und kein Capability-Token.
    }

    Write-JsonFileAtomic -Value $metadata -Destination (Join-Path $script:SessionDirectory 'session.json')
}

function Test-SessionMetadataShape {
    param([Parameter(Mandatory = $true)]$Session)
    $requiredProperties = @('magic','schema','phase','launcherPid','launcherStartTicks','launcherPath','miniservePid','miniserveStartTicks','miniservePath','cloudflaredPid','cloudflaredStartTicks','cloudflaredPath','watchdogPid','watchdogStartTicks','watchdogPath','archivePath','expiresUtc','keepArchive','jobName')
    $present = @($Session.PSObject.Properties.Name)
    foreach ($propertyName in $requiredProperties) { if ($present -notcontains $propertyName) { return $false } }
    if([string]$Session.magic -ne 'WorkspaceShareSession' -or [int]$Session.schema -ne 2 -or [string]$Session.phase -notin @('SetupProtected','Active','Stopping','Retained')){return $false}
    foreach($prefix in @('launcher','miniserve','cloudflared','watchdog')){if([int]$Session.($prefix+'Pid') -le 0 -or [long]$Session.($prefix+'StartTicks') -le 0 -or [string]::IsNullOrWhiteSpace([string]$Session.($prefix+'Path')) -or -not[IO.Path]::IsPathRooted([string]$Session.($prefix+'Path'))){return $false}}
    if(-not[IO.Path]::IsPathRooted([string]$Session.archivePath)){return $false};$expiry=[DateTime]::MinValue;if(-not[DateTime]::TryParse([string]$Session.expiresUtc,[ref]$expiry)){return $false}
    if([string]$Session.jobName -notmatch '^Local\\WorkspaceShare\.[A-Za-z0-9-]+$'){return $false}
    return $true
}

function Remove-OldDiagnostics {
    param([int]$MaximumAgeDays = 30, [int]$MaximumDirectories = 50)
    $diagnosticsBase = Join-Path (Split-Path $SessionBase -Parent) 'diagnostics'
    if (-not (Test-Path -LiteralPath $diagnosticsBase -PathType Container)) { return }
    $directories = @(Get-ChildItem -LiteralPath $diagnosticsBase -Directory -ErrorAction SilentlyContinue | Sort-Object LastWriteTimeUtc -Descending)
    $cutoff = [DateTime]::UtcNow.AddDays(-$MaximumAgeDays)
    for ($index = 0; $index -lt $directories.Count; $index++) {
        $directory = $directories[$index]
        if ($directory.LastWriteTimeUtc -lt $cutoff -or $index -ge $MaximumDirectories) {
            Remove-Item -LiteralPath $directory.FullName -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

function Start-Watchdog {
    param(
        [Parameter(Mandatory = $true)][datetime]$ExpiresUtc,
        [Parameter(Mandatory = $true)][long]$StartTimestamp,
        [Parameter(Mandatory = $true)][long]$DurationTicks,
        [Parameter(Mandatory = $true)][string]$ReadyMarker
    )

    Require-File -FilePath $WatchdogScriptPath -FriendlyName 'Watchdog-Skript' -Code 10

    $parent = Get-Process -Id $PID
    $parentStartTicks = $parent.StartTime.ToUniversalTime().Ticks
    $miniserveStartTicks = Get-ProcessStartTicksSafe $script:MiniserveProcess
    $cloudflaredStartTicks = Get-ProcessStartTicksSafe $script:CloudflaredProcess

    $arguments = @(
        '-NoProfile',
        '-ExecutionPolicy', 'Bypass',
        '-File', $WatchdogScriptPath,
        '-ParentPid', [string]$PID,
        '-ParentStartTicks', [string]$parentStartTicks,
        '-ExpectedParentPath', $parent.Path,
        '-MiniservePid', [string]$script:MiniserveProcess.Id,
        '-MiniserveStartTicks', [string]$miniserveStartTicks,
        '-CloudflaredPid', [string]$script:CloudflaredProcess.Id,
        '-CloudflaredStartTicks', [string]$cloudflaredStartTicks,
        '-SessionPath', $script:SessionDirectory,
        '-ArchivePath', $script:ArchivePath,
        '-JobName', $script:JobName,
        '-NormalExitMarker', $script:NormalExitMarker,
        '-ReadyMarker', $ReadyMarker,
        '-ExpiresUtc', $ExpiresUtc.ToString('o'),
        '-StartTimestamp', [string]$StartTimestamp,
        '-DurationTicks', [string]$DurationTicks,
        '-ExpectedMiniservePath', $MiniservePath,
        '-ExpectedCloudflaredPath', $CloudflaredPath
    )

    if ($KeepArchive) {
        $arguments += '-KeepArchive'
    }

    $powershellExe = Join-Path $PSHOME 'powershell.exe'
    return Start-NativeProcess `
        -FilePath $powershellExe `
        -Arguments $arguments `
        -WorkingDirectory $ToolRoot `
        -Environment (New-WorkspaceChildEnvironment) `
        -CreateNoWindow
}

function Start-ValidatedWatchdog {
    param([Parameter(Mandatory = $true)][datetime]$ExpiresUtc,[Parameter(Mandatory = $true)][long]$StartTimestamp,[Parameter(Mandatory = $true)][long]$DurationTicks)
    $readyMarker = Join-Path $script:SessionDirectory ('watchdog-{0}.ready' -f [Guid]::NewGuid().ToString('N'))
    $watchdog = Start-Watchdog -ExpiresUtc $ExpiresUtc -StartTimestamp $StartTimestamp -DurationTicks $DurationTicks -ReadyMarker $readyMarker
    $script:RetiredWatchdogProcesses.Add($watchdog)
    $timer=[Diagnostics.Stopwatch]::StartNew()
    try {
        do { $watchdog.Refresh();if($watchdog.HasExited){Stop-WithError -Code 50 -Message 'Der Watchdog wurde beendet, bevor er bereit war.'};if(Test-Path -LiteralPath $readyMarker -PathType Leaf){return [pscustomobject]@{Process=$watchdog;ReadyMarker=$readyMarker}};Start-Sleep -Milliseconds 100 } while($timer.Elapsed.TotalSeconds -lt 5)
        Stop-WithError -Code 50 -Message 'Der Watchdog hat seinen Bereitschaftsmarker nicht veröffentlicht.'
    } catch {
        $stopped=Stop-ProcessConfirmed -Process $watchdog -ExpectedPath (Join-Path $PSHOME 'powershell.exe') -Attempts 20 -WaitMilliseconds 1000
        if(-not $stopped){$script:ExitCode=50;throw [Exception]::new('Ein unbereiter Watchdog konnte nicht bestätigt beendet werden; die Sitzung bleibt erhalten.',$_.Exception)}
        throw
    }
}

function Remove-StaleSessions {
    $stagingCutoff=[DateTime]::UtcNow.AddHours(-48)
    foreach($staged in @(Get-ChildItem -LiteralPath $SessionStagingBase -Directory -ErrorAction SilentlyContinue|Where-Object LastWriteTimeUtc -lt $stagingCutoff)){
        try{$owner=Get-Content -LiteralPath (Join-Path $staged.FullName 'owner.json') -Raw -ErrorAction Stop|ConvertFrom-Json -ErrorAction Stop;if([string]$owner.magic -ne 'WorkspaceShareSession' -or [int]$owner.schema -ne 1){continue};$state=Get-ProcessIdentityState -ProcessId ([int]$owner.launcherPid) -ExpectedPath ([string]$owner.launcherPath) -ExpectedStartTicks ([long]$owner.launcherStartTicks);if($state.State -in @('Absent','Conflict')){Remove-Item -LiteralPath $staged.FullName -Recurse -Force -ErrorAction SilentlyContinue}}catch{}
    }
    if (-not (Test-Path -LiteralPath $SessionBase -PathType Container)) {
        return
    }

    $cutoff = [DateTime]::UtcNow.AddHours(-48)

    foreach ($directory in Get-ChildItem -LiteralPath $SessionBase -Directory -ErrorAction SilentlyContinue) {
        if ($directory.LastWriteTimeUtc -ge $cutoff) {
            continue
        }

        if (Test-Path -LiteralPath (Join-Path $directory.FullName 'keep.archive') -PathType Leaf) {
            continue
        }

        $metadataPath = Join-Path $directory.FullName 'session.json'
        if (-not (Test-Path -LiteralPath $metadataPath -PathType Leaf)) {
            $ownerPath=Join-Path $directory.FullName 'owner.json'
            try{$owner=Get-Content -LiteralPath $ownerPath -Raw -ErrorAction Stop|ConvertFrom-Json -ErrorAction Stop}catch{Write-Warning "Alte Sitzung ohne verifizierbare Eigentümerdaten bleibt bestehen: $($directory.FullName)";continue}
            $ownerProperties=if($owner){$owner.PSObject.Properties}else{$null}
            if(-not $ownerProperties -or -not $ownerProperties['magic'] -or -not $ownerProperties['schema'] -or -not $ownerProperties['launcherPid'] -or -not $ownerProperties['launcherPath'] -or -not $ownerProperties['launcherStartTicks'] -or [string]$owner.magic -ne 'WorkspaceShareSession' -or [int]$owner.schema -ne 1){Write-Warning "Alte Sitzung mit ungültigen Eigentümerdaten bleibt bestehen: $($directory.FullName)";continue}
            $ownerState=Get-ProcessIdentityState -ProcessId ([int]$owner.launcherPid) -ExpectedPath ([string]$owner.launcherPath) -ExpectedStartTicks ([long]$owner.launcherStartTicks)
            if($ownerState.State -in @('Absent','Conflict')){Remove-Item -LiteralPath $directory.FullName -Recurse -Force -ErrorAction SilentlyContinue}
            continue
        }

        try {
            $session = Get-Content -LiteralPath $metadataPath -Raw | ConvertFrom-Json
        }
        catch {
            Write-Warning "Alte Sitzung mit ungültigen Metadaten bleibt bestehen: $($directory.FullName)"
            continue
        }

        if (-not (Test-SessionMetadataShape -Session $session)) {
            Write-Warning "Alte Sitzung mit unvollständigen Metadaten bleibt bestehen: $($directory.FullName)"
            continue
        }

        if([bool]$session.keepArchive){continue}

        $active = $false
        try {
            foreach ($identity in @(
                @{ Pid = [int]$session.miniservePid; Path = [string]$session.miniservePath; Ticks = [long]$session.miniserveStartTicks },
                @{ Pid = [int]$session.cloudflaredPid; Path = [string]$session.cloudflaredPath; Ticks = [long]$session.cloudflaredStartTicks },
                @{ Pid = [int]$session.watchdogPid; Path = [string]$session.watchdogPath; Ticks = [long]$session.watchdogStartTicks }
            )) {
                $state = Get-ProcessIdentityState -ProcessId $identity.Pid -ExpectedPath $identity.Path -ExpectedStartTicks $identity.Ticks
                if ($state.State -in @('Match', 'Unknown')) {
                    $active = $true
                    break
                }
            }
        }
        catch { Write-Warning "Alte Sitzung mit nicht lesbaren Prozessmetadaten bleibt bestehen: $($directory.FullName)"; continue }

        if (-not $active) {
            Remove-Item -LiteralPath $directory.FullName -Recurse -Force -ErrorAction SilentlyContinue
            if (Test-Path -LiteralPath $directory.FullName) { Write-Warning "Alte Sitzung konnte nicht vollständig entfernt werden: $($directory.FullName)" }
        }
    }
}

# ---------------------------------------------------------------------------
# Hauptablauf
# ---------------------------------------------------------------------------

$localUrl = $null
$finalUrl = $null
$publicBaseUrl = $null
$cloudflaredStdOut = $null
$cloudflaredStdErr = $null
$sessionId = $null

try {
    $toolVersion = ''
    try { $toolVersion = (Get-Content -LiteralPath (Join-Path $ToolRoot 'VERSION') -TotalCount 1 -ErrorAction Stop).Trim() } catch {}
    Write-ShareEvent -Type 'start' -Fields ([ordered]@{ pid = $PID; version = $toolVersion })
    if(-not(Test-Path -LiteralPath $Path -PathType Container)){Stop-WithError -Code 10 -Message "Der Pfad ist kein vorhandener Ordner: $Path"}
    Write-Host ''
    Write-Host 'WorkspaceShare 3.1 – read-only Quick-Tunnel-Freigabe'
    Write-Host '====================================================='
    Write-Host ''

    $totalSteps = 8
    if ($HealthFailureThreshold -ne 4) {
        Write-Warning '-HealthFailureThreshold is retained for compatibility; version 3.1 uses bounded time-based outage budgets.'
    }

    if($PSVersionTable.PSEdition -ne 'Desktop' -or $PSVersionTable.PSVersion.Major -ne 5){Stop-WithError -Code 10 -Message 'WorkspaceShare benötigt Windows PowerShell 5.1 (powershell.exe), nicht pwsh.exe.'}

    foreach ($module in @(
        @{ Path = $HealthModulePath; Name = 'Health-Modul' },
        @{ Path = $ProcessModulePath; Name = 'Process-Modul' },
        @{ Path = $CurlModulePath; Name = 'Curl-Modul' }
        @{ Path = $JobModulePath; Name = 'Job-Modul' }
        @{ Path = $PathModulePath; Name = 'Path-Modul' }
        @{ Path = $DependencyModulePath; Name = 'Dependency-Lease-Modul' }
    )) { Require-File -FilePath $module.Path -FriendlyName $module.Name -Code 10 }
    Import-Module -Name $HealthModulePath -Force -ErrorAction Stop
    Import-Module -Name $ProcessModulePath -Force -ErrorAction Stop
    Import-Module -Name $CurlModulePath -Force -ErrorAction Stop -Function Invoke-CurlWithPrivateUrl,ConvertTo-CurlConfigQuoted
    Import-Module -Name $JobModulePath -Force -ErrorAction Stop
    Import-Module -Name $PathModulePath -Force -ErrorAction Stop
    Import-Module -Name $DependencyModulePath -Force -ErrorAction Stop

    if ($ParentProcessId -gt 0) {
        $parentAtStart = $null
        try { $parentAtStart = Get-Process -Id $ParentProcessId -ErrorAction Stop } catch { $parentAtStart = $null }
        if ($null -eq $parentAtStart) { Stop-WithError -Code 10 -Message "Der angegebene Elternprozess existiert nicht: $ParentProcessId" }
        $script:ParentStartTicks = Get-ProcessStartTicksSafe $parentAtStart
        try { $parentAtStart.Dispose() } catch {}
        $script:ParentProcessRecorded = $true
    }

    Enable-SystemAwake

    Write-Step 1 $totalSteps 'Abhängigkeiten und Umgebung prüfen ...'

    if ($UnsafeSkipSecretScan -and -not $TestMode) {
        Stop-WithError -Code 10 -Message (
            "-UnsafeSkipSecretScan ist ausschließlich zusammen mit -TestMode zulässig. " +
            "Im normalen Betrieb ist der Secret-Scan verpflichtend."
        )
    }

    if ($TestStopAfterSnapshot -and -not $TestMode) {
        Stop-WithError -Code 10 -Message '-TestStopAfterSnapshot ist ausschließlich zusammen mit -TestMode zulässig.'
    }

    $script:DependencyLease=Enter-WorkspaceDependencyLease -ToolRoot $ToolRoot -Mode Shared -TimeoutSeconds 30
    Assert-DependencyLock

    foreach ($required in @(
        @{ Path = $SevenZipPath; Name = '7za.exe'; Code = 10 },
        @{ Path = $MiniservePath; Name = 'miniserve.exe'; Code = 10 },
        @{ Path = $CloudflaredPath; Name = 'cloudflared.exe'; Code = 10 },
        @{ Path = $MandatoryExcludesPath; Name = 'mandatory-excludes.txt'; Code = 10 },
        @{ Path = $GeneratedExcludesPath; Name = 'generated-excludes.txt'; Code = 10 }
    )) {
        Require-File -FilePath $required.Path -FriendlyName $required.Name -Code $required.Code
    }

    if (-not $script:CurlPath) {
        Stop-WithError -Code 10 -Message (
            "curl.exe wurde nicht gefunden. Moderne Windows-10/11-Versionen enthalten curl.exe."
        )
    }

    if (-not $UnsafeSkipSecretScan) {
        Require-File -FilePath $GitleaksPath -FriendlyName 'gitleaks.exe' -Code 10
        Require-File -FilePath $GitleaksConfigPath -FriendlyName 'Gitleaks-Konfiguration' -Code 10
    }

    $cloudflaredConflicts = @(Get-CloudflaredConfigConflicts)
    if ($cloudflaredConflicts.Count -gt 0) {
        Stop-WithError -Code 10 -Message (
            "Eine bestehende cloudflared-Konfiguration kann Quick Tunnels blockieren:`n" +
            ($cloudflaredConflicts -join "`n") +
            "`nDatei vorübergehend umbenennen oder einen separaten Windows-Benutzer verwenden."
        )
    }

    $diagnosticsBase = Join-Path (Split-Path $SessionBase -Parent) 'diagnostics'
    foreach($privateBase in @($SessionBase,$SessionStagingBase,$diagnosticsBase)){
        New-Item -ItemType Directory -Path $privateBase -Force -ErrorAction Stop|Out-Null
        Set-PrivateDirectoryAcl -Directory $privateBase
    }
    Remove-StaleSessions
    Remove-OldDiagnostics

    $resolvedRoot = (Resolve-Path -LiteralPath $Path).Path.TrimEnd('\')
    $sourceRootItem = Get-Item -LiteralPath $resolvedRoot -Force -ErrorAction Stop
    if (($sourceRootItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        Stop-WithError -Code 10 -Message 'Die Quellwurzel ist ein Symlink, Junction oder anderer Reparse-Point. Bitte das echte Projektverzeichnis wählen.'
    }
    $rootParentInfo = [IO.Directory]::GetParent($resolvedRoot)
    $rootParent = if ($rootParentInfo) { $rootParentInfo.FullName } else { $null }
    $rootLeaf = [IO.Path]::GetFileName($resolvedRoot)

    if (-not $rootParent -or -not $rootLeaf) {
        Stop-WithError -Code 10 -Message "Ein Laufwerksstamm kann nicht freigegeben werden."
    }

    foreach ($reservedPath in @($SessionBase,$SessionStagingBase,$diagnosticsBase)) {
        if (Test-DirectoryPathsOverlap -First $resolvedRoot -Second $reservedPath) {
            Stop-WithError -Code 10 -Message "Die Quelle überschneidet sich mit WorkspaceShare-Interna: $reservedPath"
        }
    }
    if (Test-DirectoryPathsOverlap -First $resolvedRoot -Second $ToolRoot) {
        Stop-WithError -Code 10 -Message 'Die Quelle darf das WorkspaceShare-Toolverzeichnis nicht enthalten.'
    }

    $duration = if ($PSCmdlet.ParameterSetName -eq 'Minutes') {
        [TimeSpan]::FromMinutes($Minutes)
    } else {
        [TimeSpan]::FromHours($Hours)
    }

    $expiresUtc = $null

    Write-Host ("      Quelle: {0}" -f $resolvedRoot)
    Write-Host ("      Laufzeit: {0}" -f $duration)
    Write-Step 2 $totalSteps 'Workspace auf offensichtliche Risiken prüfen ...'

    $inspection = Inspect-Workspace `
        -Root $resolvedRoot `
        -IncludeGeneratedContent:$IncludeGenerated

    if ($inspection.AccessErrors.Count -gt 0) {
        $preview = $inspection.AccessErrors | Select-Object -First 20
        Stop-WithError -Code 20 -Message (
            "Mindestens ein Verzeichnis konnte nicht gelesen werden. " +
            "Ein unvollständiger Snapshot wird nicht erzeugt:`n" +
            ($preview -join "`n")
        )
    }

    if ($inspection.ReparsePoints.Count -gt 0) {
        $preview = $inspection.ReparsePoints | Select-Object -First 20
        Stop-WithError -Code 20 -Message (
            "Symlinks/Junctions/Reparse-Points wurden gefunden. " +
            "Sie müssen entfernt oder bewusst außerhalb des Share-Roots abgelegt werden:`n" +
            ($preview -join "`n")
        )
    }

    if ($inspection.ForbiddenFiles.Count -gt 0) {
        $preview = $inspection.ForbiddenFiles | Select-Object -First 30
        Stop-WithError -Code 22 -Message (
            "Potenziell sensible Schlüssel-/Konfigurationsdateien wurden gefunden:`n" +
            ($preview -join "`n") +
            "`nDiese Dateien dürfen nicht stillschweigend mitgeteilt werden."
        )
    }

    Write-Host ("      Geprüfte Dateien: {0:N0}" -f $inspection.FileCount)
    Write-Host ("      Konservative Quellgröße: {0:N2} GB" -f ($inspection.EstimatedBytes / 1GB))
    if(Test-StopRequested){Set-ManualStopReason;Stop-WithError -Code 0 -Message 'Die Freigabe wurde manuell beendet.'}

    $sessionId = "{0}-{1}" -f (
        [DateTime]::UtcNow.ToString('yyyyMMdd-HHmmss'),
        [Guid]::NewGuid().ToString('N').Substring(0, 8)
    )
    $finalSessionDirectory = Join-Path $SessionBase $sessionId
    $script:SessionDirectory = Join-Path $SessionStagingBase ($sessionId+'.staging')
    New-Item -ItemType Directory -Path $script:SessionDirectory -ErrorAction Stop | Out-Null
    $script:JobName='Local\WorkspaceShare.{0}' -f $sessionId
    Set-PrivateDirectoryAcl -Directory $script:SessionDirectory
    Write-OwnerMetadata -Phase 'Preparing'
    Move-Item -LiteralPath $script:SessionDirectory -Destination $finalSessionDirectory -ErrorAction Stop
    $script:SessionDirectory=$finalSessionDirectory
    Write-ShareEvent -Type 'session' -Fields ([ordered]@{ path = $script:SessionDirectory })
    $script:HealthLogPath = Join-Path $script:SessionDirectory 'health.jsonl'

    $script:NormalExitMarker = Join-Path $script:SessionDirectory 'normal.exit'
    $script:KeepArchiveMarker = Join-Path $script:SessionDirectory 'keep.archive'
    $script:ArchivePath = Join-Path $script:SessionDirectory (
        "workspace-{0}.zip" -f [DateTime]::UtcNow.ToString('yyyyMMdd-HHmmss')
    )
    $script:JobHandle=New-WorkspaceJob -Name $script:JobName

    Write-Host ("      7-Zip: {0}" -f [string](((Get-ExecutableVersionText -FilePath $SevenZipPath -Arguments @('i')) -split '\r?\n')|Where-Object{$_.Trim()}|Select-Object -First 1))
    Write-Host ("      miniserve: {0}" -f (Get-ExecutableVersionText -FilePath $MiniservePath))
    Write-Host ("      cloudflared: {0}" -f (Get-ExecutableVersionText -FilePath $CloudflaredPath))
    if (-not $UnsafeSkipSecretScan) { Write-Host ("      Gitleaks: {0}" -f (Get-ExecutableVersionText -FilePath $GitleaksPath -Arguments @('version'))) }

    Assert-FreeDiskSpace `
        -TargetDirectory $script:SessionDirectory `
        -EstimatedSourceBytes $inspection.EstimatedBytes

    $gitleaksReport = Join-Path $script:SessionDirectory 'gitleaks-redacted.json'
    if (-not $UnsafeSkipSecretScan) {
        Write-Step 3 $totalSteps 'Finaler Archivscan wird vorbereitet ...'
        Write-Host '      Der maßgebliche Gitleaks-Scan läuft auf dem exakt extrahierten ZIP.'
    } else {
        Write-Step 3 $totalSteps 'Gitleaks-Prüfung wurde explizit übersprungen.'
        Write-Warning (
            'Die inhaltliche Secret-Prüfung ist deaktiviert. ' +
            'Dateinamen- und Reparse-Point-Gates bleiben aktiv.'
        )
    }

    Write-Step 4 $totalSteps 'Bereinigten ZIP64-Snapshot erzeugen ...'
    if(Test-StopRequested){Set-ManualStopReason;Stop-WithError -Code 0 -Message 'Die Freigabe wurde manuell beendet.'}

    $exclusions = New-Object System.Collections.Generic.List[string]

    foreach ($pattern in Read-PatternFile $MandatoryExcludesPath) {
        $exclusions.Add($pattern)
    }

    if (-not $IncludeGenerated) {
        foreach ($pattern in Read-PatternFile $GeneratedExcludesPath) {
            $exclusions.Add($pattern)
        }
    }

    $projectExcludePath = Join-Path $resolvedRoot '.workspace-share.exclude.txt'
    if (Test-Path -LiteralPath $projectExcludePath -PathType Leaf) {
        foreach ($pattern in Read-PatternFile $projectExcludePath) {
            $exclusions.Add($pattern)
        }
        Write-Host ("      Projektausschlüsse geladen: {0}" -f $projectExcludePath)
    }

    $archiveCreateLog = Join-Path $script:SessionDirectory '7zip-create.log'
    $archiveTestLog = Join-Path $script:SessionDirectory '7zip-test.log'
    $archiveManifest = Join-Path $script:SessionDirectory 'archive-manifest.txt'
    $archiveIncludeList = Join-Path $script:SessionDirectory 'archive-includes.txt'

    $snapshotConsistent=$false
    for($snapshotAttempt=1;$snapshotAttempt -le 2;$snapshotAttempt++){
        $sourceManifestBefore=@(Get-SourceConsistencyManifest -Root $resolvedRoot -ExclusionPatterns @($exclusions|Select-Object -Unique))
        $includedRelativePaths=@($sourceManifestBefore|ForEach-Object{($_ -split '\|',2)[0]})
        if($includedRelativePaths.Count -eq 0){Stop-WithError -Code 20 -Message 'Nach Anwendung der Ausschlussregeln bleiben keine regulären Dateien für den Snapshot übrig.'}
        $includedRelativePaths|Set-Content -LiteralPath $archiveIncludeList -Encoding UTF8
        Remove-Item -LiteralPath $script:ArchivePath -Force -ErrorAction SilentlyContinue
        Invoke-SevenZipSnapshot `
            -SourceRoot $resolvedRoot `
            -DestinationArchive $script:ArchivePath `
            -IncludeListPath $archiveIncludeList `
            -LogPath $archiveCreateLog
        $sourceManifestAfter=@(Get-SourceConsistencyManifest -Root $resolvedRoot -ExclusionPatterns @($exclusions|Select-Object -Unique))
        if(-not(Compare-Object $sourceManifestBefore $sourceManifestAfter)){$snapshotConsistent=$true;break}
        Remove-Item -LiteralPath $script:ArchivePath -Force -ErrorAction SilentlyContinue
        if($snapshotAttempt -lt 2){Write-Warning 'Included source files changed while 7-Zip was reading them; retrying the snapshot once.'}
    }
    if(-not $snapshotConsistent){Stop-WithError -Code 20 -Message 'Enthaltene Quelldateien änderten sich während beider Snapshot-Versuche; das inkonsistente Archiv wird nicht freigegeben.'}

    Test-SevenZipArchive `
        -ArchivePath $script:ArchivePath `
        -LogPath $archiveTestLog

    # From here on the verified archive must not be replaceable or writable.
    Lock-ArchiveReadOnly -ArchivePath $script:ArchivePath

    Test-ExactArchiveContents -ArchivePath $script:ArchivePath -VerificationRoot (Join-Path $script:SessionDirectory 'archive-verification') -GitleaksReportPath $gitleaksReport -ExclusionPatterns @($exclusions|Select-Object -Unique) -IncludedRelativePaths $includedRelativePaths -RunSecretScan:(-not $UnsafeSkipSecretScan)

    if ($TestStopAfterSnapshot) {
        # Test hook: snapshot is created and verified; end without miniserve/cloudflared.
        $script:StopReason = 'TestSnapshotOnly'
        Stop-WithError -Code 0 -Message 'Test: Snapshot wurde erstellt und geprüft; die Freigabe wird nicht gestartet.'
    }

    Write-SevenZipManifest `
        -ArchivePath $script:ArchivePath `
        -ManifestPath $archiveManifest

    $archiveHash = (Get-FileHash -LiteralPath $script:ArchivePath -Algorithm SHA256).Hash
    $archiveSize = (Get-Item -LiteralPath $script:ArchivePath).Length
    $healthSamples = @(Get-HealthSamplePlan -ArchiveSize $archiveSize)
    $startupSample = $healthSamples[0]

    Set-Content `
        -LiteralPath (Join-Path $script:SessionDirectory 'archive.sha256.txt') `
        -Value ("{0}  {1}" -f $archiveHash, (Split-Path $script:ArchivePath -Leaf)) `
        -Encoding ASCII

    Write-Host ("      Archivgröße: {0:N2} GB" -f ($archiveSize / 1GB))
    Write-Host ("      SHA-256: {0}" -f $archiveHash)

    Write-Step 5 $totalSteps 'Read-only-Dateiserver auf Loopback starten ...'

    $token = New-CapabilityToken
    $script:SecretTokens=@($token)
    $miniserveStarted = $false
    $port = 0

    for ($attempt = 1; $attempt -le 5; $attempt++) {
        $port = Get-FreeTcpPort
        try {
            $script:MiniserveProcess = Start-MiniserveReadOnly `
                -Archive $script:ArchivePath `
                -CapabilityToken $token `
                -Port $port

            $localUrl = "http://127.0.0.1:{0}/d/{1}/" -f $port, $token
            $script:SecretUrls = @($localUrl)
            $localStatus = Wait-ForHttpStatus `
                -Url $localUrl `
                -AcceptedStatus @(200) `
                -TimeoutSeconds 10

            if ($localStatus -eq 200) {
                $miniserveStarted = $true
                break
            }

            $stopped = Stop-ProcessConfirmed -Process $script:MiniserveProcess -ExpectedPath $MiniservePath -Attempts 10 -WaitMilliseconds 1000
            if (-not $stopped) { Stop-WithError -Code 30 -Message 'Ein fehlgeschlagener miniserve-Versuch konnte nicht bestätigt beendet werden.' }
            $script:MiniserveProcess = $null
        }
        catch {
            if($_.Exception.Data.Contains('WorkspaceShareExitCode')){throw}
            $stopped = Stop-ProcessConfirmed -Process $script:MiniserveProcess -ExpectedPath $MiniservePath -Attempts 10 -WaitMilliseconds 1000
            if (-not $stopped) { Stop-WithError -Code 30 -Message 'Ein fehlgeschlagener miniserve-Versuch konnte nicht bestätigt beendet werden.' }
            $script:MiniserveProcess = $null
        }
    }

    if (-not $miniserveStarted) {
        $probeSummary = if ($script:LastHttpProbe) {
            " Letzte Probe: curl exit $($script:LastHttpProbe.CurlExit), HTTP $($script:LastHttpProbe.HttpStatus), Fehler '$($script:LastHttpProbe.ErrorText)'."
        } else { '' }
        Stop-WithError -Code 30 -Message (
            "miniserve konnte nach fünf Versuchen nicht zuverlässig auf Loopback starten.$probeSummary"
        )
    }

    $localWrongTokenUrl = "http://127.0.0.1:{0}/d/{1}/" -f $port, (New-CapabilityToken)
    Assert-DeniedRoute -Url ("http://127.0.0.1:{0}/" -f $port) -Description 'Lokale Tunnelwurzel ohne Geheimtoken' -Code 31
    Assert-DeniedRoute -Url $localWrongTokenUrl -Description 'Lokale Route mit falschem Geheimtoken' -Code 31

    $localRangeLength = [int][Math]::Min([int64]65536, $archiveSize)
    if (-not (Test-RangeRequest -Url $localUrl -LengthBytes $localRangeLength -AllowFullFileResponse:($localRangeLength -eq $archiveSize))) {
        Stop-WithError -Code 31 -Message (
            "Lokaler Range-Test (206/$localRangeLength Bytes) ist fehlgeschlagen."
        )
    }

    # Read-only-Prüfung: Methoden dürfen weder Datei noch Sitzungsverzeichnis verändern.
    $hashBeforeMethodTests = (Get-FileHash -LiteralPath $script:ArchivePath -Algorithm SHA256).Hash
    $filesBeforeMethodTests=@(Get-SessionIntegrityMap)
    $mutationReference = Invoke-CurlProbe -Url $localUrl -TimeoutSeconds 10 -Range '0-0' -ExpectedRangeStart 0 -ExpectedBytes 1 -MaximumBytes 1024 -AllowFullFileResponse:($archiveSize -eq 1)
    if (-not $mutationReference.SampleValid) {
        Stop-WithError -Code 31 -Message 'Die Referenzantwort für Read-only-Mutationstests konnte nicht bestätigt werden.'
    }

    foreach ($method in @('POST', 'PUT', 'PATCH', 'DELETE', 'PROPFIND', 'MKCOL', 'MOVE', 'COPY')) {
        $mutationProbe = Invoke-CurlProbe -Url $localUrl -TimeoutSeconds 10 -Range '0-0' -ExpectedRangeStart 0 -ExpectedBytes 1 -MaximumBytes 1024 -AllowFullFileResponse:($archiveSize -eq 1) -ExtraArguments @(
            '--request', $method,
            '--header', 'Destination: /d/forbidden-target',
            '--data-binary', 'WorkspaceShare mutation probe'
        )
        $explicitlyDenied = ($mutationProbe.CurlExit -eq 0 -and $mutationProbe.HttpStatus -ge 400 -and $mutationProbe.HttpStatus -lt 500)
        $servedUnchangedByte = ($mutationProbe.SampleValid -and $mutationProbe.BodySha256 -eq $mutationReference.BodySha256)
        $servedUnchangedArchive = ($mutationProbe.CurlExit -eq 0 -and $mutationProbe.HttpStatus -eq 200 -and $mutationProbe.ActualBodyBytes -eq $archiveSize -and $mutationProbe.BodySha256 -eq $archiveHash)
        $contentLengthMatch = [regex]::Match($mutationProbe.Headers, '(?im)^Content-Length:\s*(\d+)\s*$')
        $boundedStaticResponse = ($mutationProbe.CurlExit -eq 63 -and $mutationProbe.HttpStatus -eq 200 -and $contentLengthMatch.Success -and [int64]$contentLengthMatch.Groups[1].Value -eq $archiveSize -and $mutationProbe.ActualBodyBytes -le 1024)
        if (-not ($explicitlyDenied -or $servedUnchangedByte -or $servedUnchangedArchive -or $boundedStaticResponse)) {
            Stop-WithError -Code 31 -Message "Read-only-Mutationstest $method lieferte weder eine 4xx-Ablehnung noch den unveränderten bestätigten Dateiinhalt (curl=$($mutationProbe.CurlExit), HTTP=$($mutationProbe.HttpStatus))."
        }
    }

    $hashAfterMethodTests = (Get-FileHash -LiteralPath $script:ArchivePath -Algorithm SHA256).Hash
    $filesAfterMethodTests=@(Get-SessionIntegrityMap)

    if (
        $hashBeforeMethodTests -ne $hashAfterMethodTests -or
        (Compare-Object $filesBeforeMethodTests $filesAfterMethodTests)
    ) {
        Stop-WithError -Code 31 -Message (
            "Die Mutation-Probes haben Datei- oder Verzeichnisinhalt verändert. Read-only-Gate fehlgeschlagen."
        )
    }

    Write-Host ("      Lokaler Port: {0} (nur 127.0.0.1)" -f $port)
    Write-Host '      HEAD, Geheimroute, Range und Unveränderlichkeit bestätigt.'

    Write-Step 6 $totalSteps 'Kostenlosen Cloudflare Quick Tunnel starten ...'

    $cloudflaredStdOut = $null
    $cloudflaredStdErr = $null
    $originUrl = "http://127.0.0.1:{0}" -f $port
    $expiresUtc = $null

    $cloudflaredStarted = $false
    for ($attempt = 1; $attempt -le 3; $attempt++) {
        $expiresUtc = [DateTime]::UtcNow.AddMinutes(15)
        $setupStartTimestamp=[Diagnostics.Stopwatch]::GetTimestamp()
        $setupDurationTicks=[int64](15*60*[Diagnostics.Stopwatch]::Frequency)
        $attemptStdOut = Join-Path $script:SessionDirectory ("cloudflared-attempt-{0}.stdout.log" -f $attempt)
        $attemptStdErr = Join-Path $script:SessionDirectory ("cloudflared-attempt-{0}.stderr.log" -f $attempt)
        $script:CloudflaredMetricsPort = Get-FreeTcpPort
        $script:CloudflaredProcess = Start-CloudflaredQuickTunnel `
            -OriginUrl $originUrl `
            -StdOutPath $attemptStdOut `
            -StdErrPath $attemptStdErr `
            -MetricsPort $script:CloudflaredMetricsPort `
            -Protocol $TunnelProtocol `
            -EdgeIpVersion $TunnelEdgeIpVersion `
            -Retries $TunnelRetries
        $attemptWatchdogInfo = Start-ValidatedWatchdog -ExpiresUtc $expiresUtc -StartTimestamp $setupStartTimestamp -DurationTicks $setupDurationTicks
        $attemptWatchdog = $attemptWatchdogInfo.Process
        $script:WatchdogProcess = $attemptWatchdog
        if (Wait-ForCloudflaredMetrics -Process $script:CloudflaredProcess -MetricsPort $script:CloudflaredMetricsPort -TimeoutSeconds 15) {
            $cloudflaredStdOut = $attemptStdOut
            $cloudflaredStdErr = $attemptStdErr
            $cloudflaredStarted = $true
            break
        }
        $stopped = Stop-ProcessConfirmed -Process $script:CloudflaredProcess -ExpectedPath $CloudflaredPath -Attempts 5 -WaitMilliseconds 1000
        if (-not $stopped) { Stop-WithError -Code 41 -Message 'Ein fehlgeschlagener cloudflared-Versuch konnte nicht bestätigt beendet werden.' }
        $watchdogStopped = Stop-ProcessConfirmed -Process $attemptWatchdog -ExpectedPath (Join-Path $PSHOME 'powershell.exe') -Attempts 10 -WaitMilliseconds 1000
        if (-not $watchdogStopped) { Stop-WithError -Code 41 -Message 'Der Watchdog eines fehlgeschlagenen cloudflared-Versuchs konnte nicht bestätigt beendet werden. Ein weiterer Versuch wäre unsicher.' }
        $script:WatchdogProcess = $null
        $script:CloudflaredProcess = $null
    }
    if (-not $cloudflaredStarted) {
        Stop-WithError -Code 41 -Message 'cloudflared konnte nach drei Versuchen keinen stabilen lokalen Metrics-Endpunkt starten.'
    }

    Write-Host ("      Tunnel-Protokoll: {0}" -f $TunnelProtocol)
    Write-Host ("      Edge-IP-Modus: {0}" -f $TunnelEdgeIpVersion)
    Write-Host ("      Metrics: 127.0.0.1:{0}" -f $script:CloudflaredMetricsPort)

    # A short setup lease ensures cleanup during URL discovery. The requested
    # duration is assigned only after the normal-client public gates succeed.
    # Ab dem Moment, in dem ein öffentlicher Tunnelprozess existiert, muss der
    # Watchdog aktiv sein. Ein harter Launcher-Abbruch während URL-Erkennung oder
    # öffentlicher Tests darf keinen verwaisten Tunnel hinterlassen.
    Write-SessionMetadata `
        -Phase 'SetupProtected' `
        -ExpiresUtc $expiresUtc `
        -SourceRoot $resolvedRoot `
        -Archive $script:ArchivePath `
        -WatchdogPid $script:WatchdogProcess.Id `
        -WatchdogStartTicks (Get-ProcessStartTicksSafe $script:WatchdogProcess)

    $publicBaseUrl = Wait-ForQuickTunnelUrl `
        -Process $script:CloudflaredProcess `
        -LogPaths @($cloudflaredStdOut, $cloudflaredStdErr) `
        -TimeoutSeconds 60

    $finalUrl = "{0}/d/{1}/" -f $publicBaseUrl, $token
    $script:SecretUrls = @($localUrl, $finalUrl)
    $finalHost=([Uri]$finalUrl).DnsSafeHost
    if(-not(Wait-ForPublicDnsPublication -HostName $finalHost -TimeoutSeconds 180)){
        Stop-WithError -Code 43 -Message 'Der neue Quick-Tunnel-Hostname wurde nicht von mindestens zwei öffentlichen DNS-Resolvern veröffentlicht.'
    }

    Write-Step 7 $totalSteps 'Öffentlichen Endpunkt vollständig prüfen ...'
    Write-Host '      Cloudflare stellt neue Quick-Tunnel-Hosts gelegentlich verzögert bereit (maximal 3 Minuten).'

    $initialSnapshot = Wait-ForHealthyTunnel `
        -PublicUrl $finalUrl `
        -LocalUrl $localUrl `
        -MetricsPort $script:CloudflaredMetricsPort `
        -SampleStart $startupSample.Start `
        -SampleBytes $startupSample.Length `
        -AllowFullFileResponse:$startupSample.AllowFullFileResponse `
        -TimeoutSeconds 180

    if (-not $initialSnapshot) { Set-ManualStopReason; Stop-WithError -Code 0 -Message 'Die Freigabe wurde manuell beendet.' }
    if (-not $initialSnapshot -or $initialSnapshot.Classification -ne 'Healthy') {
        $hostName = ([Uri]$finalUrl).DnsSafeHost
        $diagnosticArguments = @(Get-LiveDnsOverrideConfigLines -HostName $hostName)
        if ($diagnosticArguments.Count -gt 0) {
            $overrideDiagnostic = Invoke-CurlProbe -Url $finalUrl -TimeoutSeconds 10 -Range ("{0}-{1}" -f $startupSample.Start, $startupSample.End) -ExpectedRangeStart $startupSample.Start -ExpectedBytes $startupSample.Length -MaximumBytes 65536 -PrivateConfigLines $diagnosticArguments -AllowFullFileResponse:$startupSample.AllowFullFileResponse
            if ($overrideDiagnostic.Success) {
                Stop-WithError -Code 43 -Message 'Der Link funktioniert nur mit einem internen DNS-IP-Override, aber nicht wie ein normaler Browser oder externer Dienst.'
            }
        }
        Stop-WithError -Code 43 -Message (
            "Der öffentliche Geheimlink wurde über normales DNS und HTTP nicht rechtzeitig erreichbar. " +
            "Fehlerklasse: $($initialSnapshot.Classification)."
        )
    }

    foreach ($sample in $healthSamples) {
        if(Test-StopRequested){Set-ManualStopReason;Stop-WithError -Code 0 -Message 'Die Freigabe wurde manuell beendet.'}
        $sampleSnapshot = Get-TunnelHealthSnapshot -PublicUrl $finalUrl -LocalUrl $localUrl -MetricsPort $script:CloudflaredMetricsPort -SampleStart $sample.Start -SampleBytes $sample.Length -AllowFullFileResponse:$sample.AllowFullFileResponse
        [void](Write-HealthSnapshot -Snapshot $sampleSnapshot)
        if ($sampleSnapshot.Classification -ne 'Healthy') {
            Stop-WithError -Code 43 -Message "Ein rotierender Start-Sample-Gate war nicht gesund: $($sampleSnapshot.Classification)."
        }
    }

    $wrongTokenUrl = "{0}/d/{1}/" -f $publicBaseUrl, (New-CapabilityToken)
    Assert-DeniedRoute -Url ($publicBaseUrl + '/') -Description 'Öffentliche Tunnelwurzel ohne Geheimtoken'
    Assert-DeniedRoute -Url $wrongTokenUrl -Description 'Öffentliche Route mit falschem Geheimtoken'

    $publicRangeLength = [int][Math]::Min([int64]1048576, $archiveSize)
    if (-not (Test-MatchingRangeRequest -LocalUrl $localUrl -PublicUrl $finalUrl -Start 0 -Length $publicRangeLength -AllowFullFileResponse:($publicRangeLength -eq $archiveSize))) {
        Stop-WithError -Code 43 -Message (
            "Der öffentliche Range-Test (206/$publicRangeLength Bytes) ist fehlgeschlagen."
        )
    }
    if(Test-StopRequested){Set-ManualStopReason;Stop-WithError -Code 0 -Message 'Die Freigabe wurde manuell beendet.'}

    $publicHeadersPath = Join-Path $script:SessionDirectory 'public-headers.txt'
    Assert-CacheHeaders -Url $finalUrl -HeaderPath $publicHeadersPath
    if(Test-StopRequested){Set-ManualStopReason;Stop-WithError -Code 0 -Message 'Die Freigabe wurde manuell beendet.'}

    # Replace the temporary setup lease with the requested lifetime only after
    # every public gate has succeeded.
    $script:ActiveStartTimestamp=[Diagnostics.Stopwatch]::GetTimestamp();$activeStartUtc=[DateTime]::UtcNow
    $script:ActiveDurationTicks=[int64]($duration.TotalSeconds*[Diagnostics.Stopwatch]::Frequency)
    $expiresUtc = $activeStartUtc.Add($duration)
    $oldWatchdog = $script:WatchdogProcess
    $newWatchdog = (Start-ValidatedWatchdog -ExpiresUtc $expiresUtc -StartTimestamp $script:ActiveStartTimestamp -DurationTicks $script:ActiveDurationTicks).Process
    # The replacement is live before retiring the temporary setup watchdog.
    $script:WatchdogProcess = $newWatchdog
    Write-SessionMetadata `
        -Phase 'Active' `
        -ExpiresUtc $expiresUtc `
        -SourceRoot $resolvedRoot `
        -Archive $script:ArchivePath `
        -WatchdogPid $newWatchdog.Id `
        -WatchdogStartTicks (Get-ProcessStartTicksSafe $newWatchdog)
    if ($oldWatchdog) {
        $oldWatchdogStopped = Stop-ProcessConfirmed -Process $oldWatchdog -ExpectedPath (Join-Path $PSHOME 'powershell.exe') -Attempts 10 -WaitMilliseconds 1000
        if (-not $oldWatchdogStopped) {
            Stop-WithError -Code 50 -Message 'Der temporäre Setup-Watchdog konnte nicht beendet werden.'
        }
    }

    Write-Host '      Öffentliche HEAD-, Negativ-, Range- und Cache-Gates bestanden.'

    Write-Step 8 $totalSteps 'Freigabe aktivieren und Ablauf überwachen ...'

    $linkCopied = Copy-LinkToClipboard -Url $finalUrl

    Write-Host ''
    Write-Host 'FREIGABE BEREIT'
    Write-Host '================'
    Write-Host ''
    Write-Host 'Direktlink:'
    Write-Host $finalUrl
    Write-Host ''
    if ($linkCopied) {
        Write-Host '✓ Link ist bereits kopiert. Einfach im Chat oder in einer E-Mail Strg+V drücken.' -ForegroundColor Green
    }
    elseif (-not $NoClipboard) {
        Write-Warning 'Link konnte nicht automatisch kopiert werden. Bitte einmal markieren und kopieren.'
    }
    Write-Host ("Aktiv bis: {0}" -f $expiresUtc.ToLocalTime().ToString('dd.MM.yyyy HH:mm:ss'))
    Write-Host ("Archiv: {0:N2} GB" -f ($archiveSize / 1GB))
    Write-Host ("SHA-256: {0}" -f $archiveHash)
    Write-ShareEvent -Type 'ready' -Fields ([ordered]@{ url = $finalUrl; expiresUtc = $expiresUtc.ToUniversalTime().ToString('o'); sizeBytes = [int64]$archiveSize; sha256 = [string]$archiveHash })
    Write-Host ''
    Write-Host 'Dieses Fenster geöffnet lassen. Vorzeitig beenden: Strg+C'
    Write-Host ''

    $lastMinuteShown = -1
    $nextHealthCheckSeconds=0.0
    $lastLoopSeconds=0.0
    $unhealthySinceSeconds=$null
    $observedOutageBudget=[double]::PositiveInfinity
    $lastRateLimitWarningUtc = [DateTime]::MinValue
    $healthSampleIndex = 0

    $script:StopReason='Expired'
    while ((Get-ActiveElapsedSeconds) -lt $duration.TotalSeconds) {
        $nowUtc = [DateTime]::UtcNow
        $nowSeconds=Get-ActiveElapsedSeconds
        if(Test-StopRequested){Set-ManualStopReason;$script:ExitCode=0;break}
        $loopGapSeconds = $nowSeconds-$lastLoopSeconds
        $lastLoopSeconds=$nowSeconds
        $script:MiniserveProcess.Refresh()
        $script:CloudflaredProcess.Refresh()
        $script:WatchdogProcess.Refresh()
        $stopRequested=Test-StopRequested
        if ($script:MiniserveProcess.HasExited) { if ((Get-ActiveElapsedSeconds) -ge $duration.TotalSeconds -or $stopRequested) {if($stopRequested){Set-ManualStopReason};$script:ExitCode=0;break}; Stop-WithError -Code 50 -Message "miniserve wurde unerwartet beendet (Exit $($script:MiniserveProcess.ExitCode))." }
        if ($script:CloudflaredProcess.HasExited) { if ((Get-ActiveElapsedSeconds) -ge $duration.TotalSeconds -or $stopRequested) {if($stopRequested){Set-ManualStopReason};$script:ExitCode=0;break}; Stop-WithError -Code 50 -Message "cloudflared wurde unerwartet beendet (Exit $($script:CloudflaredProcess.ExitCode))." }
        if ($script:WatchdogProcess.HasExited) { if ((Get-ActiveElapsedSeconds) -ge $duration.TotalSeconds -or $stopRequested) {if($stopRequested){Set-ManualStopReason};$script:ExitCode=0;break}; Stop-WithError -Code 50 -Message 'Der Sicherheits-Watchdog wurde unerwartet beendet.' }

        if ($loopGapSeconds -gt [Math]::Max(30, $HealthCheckSeconds * 3)) {
            Write-Warning ("Die Überwachung war {0:N0} Sekunden unterbrochen. Möglicher Standby-/Netzwerkwechsel; vollständige Prüfung läuft sofort." -f $loopGapSeconds)
            $nextHealthCheckSeconds=$nowSeconds
        }
        if ((Get-ActiveElapsedSeconds) -ge $nextHealthCheckSeconds) {
            if (($duration.TotalSeconds-(Get-ActiveElapsedSeconds)) -le 2) { Start-Sleep -Milliseconds 250; continue }
            $probeStartedSeconds=Get-ActiveElapsedSeconds
            $sample = $healthSamples[$healthSampleIndex % $healthSamples.Count]
            $healthSampleIndex++
            $snapshot = Get-TunnelHealthSnapshot -PublicUrl $finalUrl -LocalUrl $localUrl -MetricsPort $script:CloudflaredMetricsPort -SampleStart $sample.Start -SampleBytes $sample.Length -AllowFullFileResponse:$sample.AllowFullFileResponse
            [void](Write-HealthSnapshot -Snapshot $snapshot)
            if(Test-StopRequested){Set-ManualStopReason;$script:ExitCode=0;break}
            if ((Get-ActiveElapsedSeconds) -ge $duration.TotalSeconds) { $script:ExitCode = 0; break }
            if ($snapshot.Classification -eq 'Healthy') {
                if ($null -ne $unhealthySinceSeconds) {
                    $outageSeconds = (Get-ActiveElapsedSeconds)-$unhealthySinceSeconds
                    Write-Host ("      Tunnel wieder gesund nach etwa {0:N0} Sekunden." -f $outageSeconds) -ForegroundColor Green
                    Write-ShareEvent -Type 'health' -Fields ([ordered]@{ state = 'recovered'; text = ("Tunnel wieder gesund nach etwa {0:N0} Sekunden." -f $outageSeconds) })
                }
                $unhealthySinceSeconds = $null;$observedOutageBudget=[double]::PositiveInfinity
            }
            else {
                if ($null -eq $unhealthySinceSeconds) { $unhealthySinceSeconds=$probeStartedSeconds }
                $unhealthySeconds = (Get-ActiveElapsedSeconds)-$unhealthySinceSeconds
                $currentBudget=Get-AllowedOutageSeconds -Classification $snapshot.Classification -RetryAfterSeconds $snapshot.RetryAfterSeconds
                $observedOutageBudget=[Math]::Min($observedOutageBudget,$currentBudget)
                $allowedSeconds=[Math]::Min(600,$observedOutageBudget)
                if ($snapshot.Classification -eq 'RateLimited') {
                    if (([DateTime]::UtcNow - $lastRateLimitWarningUtc).TotalSeconds -ge 60) {
                        $degradedText = ("Quick Tunnel meldet Rate-Limiting. Ungesund seit {0:N0}/{1}s; HTTP={2}, Retry-After={3}s." -f $unhealthySeconds, $allowedSeconds, $snapshot.PublicHttpStatus, $snapshot.RetryAfterSeconds)
                        Microsoft.PowerShell.Utility\Write-Warning $degradedText
                        Write-ShareEvent -Type 'health' -Fields ([ordered]@{ state = 'degraded'; text = $degradedText })
                        $lastRateLimitWarningUtc = [DateTime]::UtcNow
                    }
                }
                else {
                    $degradedText = ("Tunnel nicht gesund: {0}. Ununterbrochener Ausfall: {1:N0}/{2}s. HTTP={3}, curl={4}, CF={5}, Ready={6}. {7}" -f $snapshot.Classification, $unhealthySeconds, $allowedSeconds, $snapshot.PublicHttpStatus, $snapshot.PublicCurlExit, $snapshot.CloudflareError, $snapshot.Ready, $snapshot.Message)
                    Microsoft.PowerShell.Utility\Write-Warning $degradedText
                    Write-ShareEvent -Type 'health' -Fields ([ordered]@{ state = 'degraded'; text = $degradedText })
                }
                if ($unhealthySeconds -ge $allowedSeconds) {
                    Stop-WithError -Code 50 -Message ("Der öffentliche Quick Tunnel blieb {0:N0} Sekunden ungesund.`nAktuelle Fehlerklasse: {1}." -f $unhealthySeconds, $snapshot.Classification)
                }
            }
            $elapsedAfterProbe=Get-ActiveElapsedSeconds
            $nextHealthCheckSeconds=([Math]::Floor($elapsedAfterProbe/$HealthCheckSeconds)+1)*$HealthCheckSeconds
        }

        $remaining = [TimeSpan]::FromSeconds([Math]::Max(0,$duration.TotalSeconds-(Get-ActiveElapsedSeconds)))
        $wholeMinutes = [Math]::Max(0, [Math]::Ceiling($remaining.TotalMinutes))
        if ($wholeMinutes -ne $lastMinuteShown) {
            $remainingText = ("Verbleibend: ca. {0} Minute(n); letzte Tunnelprüfung wird alle {1}s ausgeführt." -f $wholeMinutes, $HealthCheckSeconds)
            Write-Host ("      " + $remainingText)
            Write-ShareEvent -Type 'status' -Fields ([ordered]@{ remainingMinutes = [int]$wholeMinutes; text = $remainingText })
            $lastMinuteShown = $wholeMinutes
        }
        $lastLoopSeconds=Get-ActiveElapsedSeconds
        Start-Sleep -Seconds 2
    }

    Write-Host ''
    if($script:StopReason -in @('ManualStop','ParentExited')){Write-Host 'Die Freigabe wurde auf Benutzerwunsch beendet.'}else{Write-Host 'Die festgelegte Freigabezeit ist abgelaufen.'}
    $script:ExitCode = 0
}
catch {
    $message = $_.Exception.Message
    $parsedCode = 50

    if ($_.Exception.Data.Contains('WorkspaceShareExitCode')) { $parsedCode = [int]$_.Exception.Data['WorkspaceShareExitCode'] }
    $message = Protect-DiagnosticText -Text $message -KnownSecretUrls $script:SecretUrls

    $script:ExitCode = $parsedCode
    if ($parsedCode -ne 0) { $script:LastErrorMessage = $message }
    if ($script:ExitCode -ne 0 -and $script:SessionDirectory) {
        try {
            if ($script:CloudflaredMetricsPort -gt 0) {
                $volatileDiagnosticPath = Join-Path $script:SessionDirectory 'volatile-cloudflared-ready.txt'
                $volatileProbe=Invoke-CurlProbe -Url ("http://127.0.0.1:{0}/ready" -f $script:CloudflaredMetricsPort) -TimeoutSeconds 2 -ReadTextBody
                (Protect-DiagnosticText -Text ($volatileProbe|ConvertTo-Json -Depth 4) -KnownSecretUrls $script:SecretUrls)|Set-Content -LiteralPath $volatileDiagnosticPath -Encoding UTF8
            }
        }
        catch {}
    }
    Write-Host ''
    [Console]::Error.WriteLine($message)
}
finally {
    if ($script:ExitCode -ne 0 -and $script:SessionDirectory) { Save-FailureDiagnostics -SessionId $sessionId -CloudflaredStdOut $cloudflaredStdOut -CloudflaredStdErr $cloudflaredStdErr }
    # Öffentliches Ende zuerst. Der Watchdog bleibt bis zur bestätigten Beendigung aktiv.
    $cloudflaredStopped = Stop-ProcessConfirmed -Process $script:CloudflaredProcess -ExpectedPath $CloudflaredPath -Attempts 5 -WaitMilliseconds 1500
    Start-Sleep -Milliseconds 300
    $miniserveStopped = Stop-ProcessConfirmed -Process $script:MiniserveProcess -ExpectedPath $MiniservePath -Attempts 5 -WaitMilliseconds 1500
    $childrenStopped = ($cloudflaredStopped -and $miniserveStopped)
    if ($miniserveStopped -and $script:ArchiveLockStream) { try { $script:ArchiveLockStream.Dispose() } catch {$script:ExitCode=50}; $script:ArchiveLockStream = $null }
    elseif(-not $miniserveStopped -and $script:ArchiveLockStream){$script:ExitCode=50;Write-Warning 'Die Archivsperre bleibt aktiv, weil miniserve nicht bestätigt beendet wurde.'}

    $allWatchdogsStopped=$false
    if (-not $childrenStopped) {
        $script:ExitCode = 50
        Write-Warning 'Mindestens ein Kindprozess konnte nicht bestätigt beendet werden. Watchdog und Sitzungsmetadaten bleiben erhalten.'
    }
    else {
        if ($script:NormalExitMarker -and $script:SessionDirectory) {
            try { New-Item -ItemType File -Path $script:NormalExitMarker -Force | Out-Null } catch {}
        }
        $allWatchdogsStopped=$true
        if(-not(Stop-ProcessConfirmed -Process $script:WatchdogProcess -ExpectedPath (Join-Path $PSHOME 'powershell.exe') -Attempts 20 -WaitMilliseconds 1000)){$allWatchdogsStopped=$false}
        foreach ($retiredWatchdog in $script:RetiredWatchdogProcesses) {
            if(-not(Stop-ProcessConfirmed -Process $retiredWatchdog -ExpectedPath (Join-Path $PSHOME 'powershell.exe') -Attempts 20 -WaitMilliseconds 1000)){$allWatchdogsStopped=$false}
        }
    }
    $cleanupComplete=($childrenStopped -and $allWatchdogsStopped)
    if(-not $cleanupComplete){$script:ExitCode=50}
    Disable-SystemAwake
    Clear-SensitiveClipboard

    if ($cleanupComplete -and $script:SessionDirectory -and (Test-Path -LiteralPath $script:SessionDirectory)) {
        if (Test-EffectiveKeepArchive) {
            try {
                New-Item -ItemType File -Path $script:KeepArchiveMarker -Force -ErrorAction Stop | Out-Null
            }
            catch {$script:ExitCode=50;Write-Warning 'Der Aufbewahrungsmarker konnte nicht bestätigt geschrieben werden; die Sitzung bleibt vorsichtshalber erhalten.'}

            Write-Warning (
                "Der lokale Sitzungsordner bleibt wegen -KeepArchive bestehen:`n" +
                $script:SessionDirectory
            )
        }
        else {
            for ($removeAttempt = 1; $removeAttempt -le 10; $removeAttempt++) {
                Remove-Item `
                    -LiteralPath $script:SessionDirectory `
                    -Recurse `
                    -Force `
                    -ErrorAction SilentlyContinue
                if (-not (Test-Path -LiteralPath $script:SessionDirectory)) { break }
                Start-Sleep -Milliseconds 500
            }
            if (Test-Path -LiteralPath $script:SessionDirectory) {
                $script:ExitCode = 50
                Write-Warning 'Der Sitzungsordner konnte nicht vollständig entfernt werden.'
            }
        }
    }

    if (-not $cleanupComplete -and $script:SessionDirectory) {
        Write-Warning ("Sitzungsordner für die Watchdog-Bereinigung erhalten:`n" + $script:SessionDirectory)
    }

    Write-Host ''
    if ($childrenStopped -and $script:SessionDirectory) { Write-Host 'Tunnel und lokaler Server wurden beendet.' }
    if ($cleanupComplete -and -not (Test-EffectiveKeepArchive) -and $script:SessionDirectory -and -not (Test-Path -LiteralPath $script:SessionDirectory)) {
        Write-Host 'Der temporäre Snapshot wurde gelöscht.'
    }
    if($cleanupComplete -and $script:JobHandle -ne [IntPtr]::Zero){try{Close-WorkspaceJob -Job $script:JobHandle}catch{$script:ExitCode=50};$script:JobHandle=[IntPtr]::Zero}
    if($script:DependencyLease){try{$script:DependencyLease.Dispose()}catch{$script:ExitCode=50};$script:DependencyLease=$null}
    Write-EndedEvent
}

Write-EndedEvent
exit $script:ExitCode
