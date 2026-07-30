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
    [ValidateScript({ Test-Path -LiteralPath $_ -PathType Container })]
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

    [string]$ToolRoot
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

$BinDirectory = Join-Path $ToolRoot 'bin'
$ConfigDirectory = Join-Path $ToolRoot 'config'
$ScriptsDirectory = Join-Path $ToolRoot 'scripts'

$SevenZipPath = Join-Path $BinDirectory '7za.exe'
$MiniservePath = Join-Path $BinDirectory 'miniserve.exe'
$CloudflaredPath = Join-Path $BinDirectory 'cloudflared.exe'
$GitleaksPath = Join-Path $BinDirectory 'gitleaks.exe'
$curlCommand = Get-Command 'curl.exe' -ErrorAction SilentlyContinue
$CurlPath = if ($curlCommand) { $curlCommand.Source } else { $null }

$MandatoryExcludesPath = Join-Path $ConfigDirectory 'mandatory-excludes.txt'
$GeneratedExcludesPath = Join-Path $ConfigDirectory 'generated-excludes.txt'
$GitleaksConfigPath = Join-Path $ConfigDirectory 'gitleaks-workspaceshare.toml'
$DependencyLockPath = Join-Path $ToolRoot 'dependencies.lock.json'
$WatchdogScriptPath = Join-Path $ScriptsDirectory 'Watch-WorkspaceShare.ps1'

$SessionBase = if ($env:LOCALAPPDATA) {
    Join-Path $env:LOCALAPPDATA 'WorkspaceShare\sessions'
} else {
    Join-Path ([IO.Path]::GetTempPath()) 'WorkspaceShare\sessions'
}

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
}

function Stop-WithError {
    param(
        [Parameter(Mandatory = $true)][string]$Message,
        [int]$Code = 50
    )
    throw [System.Exception]::new(("E{0}: {1}" -f $Code, $Message))
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

function Test-ProcessIdentity {
    param(
        [int]$ProcessId,
        [string]$ExpectedPath,
        [long]$ExpectedStartTicks
    )

    if ($ProcessId -le 0 -or -not $ExpectedPath -or $ExpectedStartTicks -le 0) {
        return $false
    }

    try {
        $process = Get-Process -Id $ProcessId -ErrorAction Stop
        if (-not $process.Path) {
            return $false
        }

        $samePath = (
            [IO.Path]::GetFullPath($process.Path) -eq
            [IO.Path]::GetFullPath($ExpectedPath)
        )
        $sameStart = (
            $process.StartTime.ToUniversalTime().Ticks -eq
            $ExpectedStartTicks
        )
        return ($samePath -and $sameStart)
    }
    catch {
        return $false
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

    if ([int]$lock.schema -ne 2 -or -not $lock.installed) {
        Stop-WithError -Code 11 -Message (
            "Die Abhängigkeiten wurden noch nicht reproduzierbar installiert. " +
            "Führe zuerst .\Install-Dependencies.ps1 aus."
        )
    }

    $seen = @{}
    foreach ($dependency in @($lock.dependencies)) {
        $relative = ([string]$dependency.file).Replace('/', [IO.Path]::DirectorySeparatorChar)
        $filePath = Join-Path $ToolRoot $relative
        Require-File -FilePath $filePath -FriendlyName ([string]$dependency.name) -Code 11

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

        $seen[[string]$dependency.name] = $true
    }

    foreach ($requiredName in @('cloudflared','miniserve','7-Zip','Gitleaks')) {
        if (-not $seen.ContainsKey($requiredName)) {
            Stop-WithError -Code 11 -Message (
                "Lockfile enthält die Pflichtabhängigkeit '$requiredName' nicht."
            )
        }
    }
}

function Get-ExecutableVersionText {
    param(
        [Parameter(Mandatory = $true)][string]$FilePath,
        [string[]]$Arguments = @('--version')
    )
    try {
        $output = & $FilePath @Arguments 2>&1
        if ($LASTEXITCODE -ne 0) {
            return "Version konnte nicht gelesen werden (Exit $LASTEXITCODE)"
        }
        return (($output | Out-String).Trim())
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

    foreach ($key in $Environment.Keys) {
        $startInfo.EnvironmentVariables[$key] = [string]$Environment[$key]
    }

    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $startInfo

    if (-not $process.Start()) {
        Stop-WithError -Code 30 -Message "Prozess konnte nicht gestartet werden: $FilePath"
    }

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

function Get-CurlStatus {
    param(
        [Parameter(Mandatory = $true)][string]$Url,
        [int]$TimeoutSeconds = 10,
        [switch]$Head
    )

    $arguments = @(
        '--silent',
        '--show-error',
        '--output', 'NUL',
        '--write-out', '%{http_code}',
        '--max-time', [string]$TimeoutSeconds
    )

    if ($Head) {
        $arguments += '--head'
    }

    $arguments += $Url

    try {
        $result = & $CurlPath @arguments 2>$null
        $curlExit = $LASTEXITCODE
    }
    catch {
        # DNS-Propagation eines neuen Quick Tunnels kann kurzzeitig fehlschlagen.
        return Get-CurlStatusViaCloudflareDns -Url $Url -TimeoutSeconds $TimeoutSeconds -Head:$Head
    }

    # curl schreibt bei DNS-/Verbindungsfehlern trotz Fehlercode häufig "000".
    # Entscheidend ist der Exitcode; "000" darf den DNS-Fallback nicht verhindern.
    if ($curlExit -ne 0) {
        return Get-CurlStatusViaCloudflareDns -Url $Url -TimeoutSeconds $TimeoutSeconds -Head:$Head
    }

    $statusText = (($result | Select-Object -Last 1) | Out-String).Trim()
    $status = 0
    if ([int]::TryParse($statusText, [ref]$status)) {
        return $status
    }

    return 0
}

function Get-CurlStatusViaCloudflareDns {
    param(
        [Parameter(Mandatory = $true)][string]$Url,
        [int]$TimeoutSeconds = 10,
        [switch]$Head
    )

    # Ein neuer Quick-Tunnel-Hostname kann beim lokalen Resolver kurz nach
    # der Ausgabe noch unbekannt sein. Für das eigene Gate fragen wir einmal
    # Cloudflares öffentlichen Resolver; der normale Link bleibt unverändert.
    try {
        $uri = [Uri]$Url
        if ($uri.Scheme -ne 'https') { return 0 }

        $address = Resolve-DnsName -Name $uri.DnsSafeHost -Type A -Server '1.1.1.1' -DnsOnly -ErrorAction Stop |
            Where-Object { $_.IPAddress } |
            Select-Object -First 1 -ExpandProperty IPAddress
        if (-not $address) { return 0 }

        $arguments = @(
            '--silent', '--show-error', '--output', 'NUL',
            '--write-out', '%{http_code}', '--max-time', [string]$TimeoutSeconds,
            '--resolve', ("{0}:443:{1}" -f $uri.DnsSafeHost, $address)
        )
        if ($Head) { $arguments += '--head' }
        $arguments += $Url

        $result = & $CurlPath @arguments 2>$null
        if ($LASTEXITCODE -ne 0) { return 0 }
        $status = 0
        [void][int]::TryParse((($result | Select-Object -Last 1) | Out-String).Trim(), [ref]$status)
        return $status
    }
    catch {
        return 0
    }
}

function Get-CloudflareDnsOverrideArguments {
    param([Parameter(Mandatory = $true)][string]$Url)

    try {
        $uri = [Uri]$Url
        if ($uri.Scheme -ne 'https') { return @() }
        $address = Resolve-DnsName -Name $uri.DnsSafeHost -Type A -Server '1.1.1.1' -DnsOnly -ErrorAction Stop |
            Where-Object { $_.IPAddress } |
            Select-Object -First 1 -ExpandProperty IPAddress
        if ($address) { return @('--resolve', ("{0}:443:{1}" -f $uri.DnsSafeHost, $address)) }
    }
    catch {}
    return @()
}

function Wait-ForHttpStatus {
    param(
        [Parameter(Mandatory = $true)][string]$Url,
        [int[]]$AcceptedStatus = @(200),
        [int]$TimeoutSeconds = 30
    )

    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)

    do {
        $status = Get-CurlStatus -Url $Url -TimeoutSeconds 5 -Head
        if ($AcceptedStatus -contains $status) {
            return $status
        }
        Start-Sleep -Milliseconds 500
    } while ([DateTime]::UtcNow -lt $deadline)

    return 0
}

function Test-RangeRequest {
    param(
        [Parameter(Mandatory = $true)][string]$Url,
        [Parameter(Mandatory = $true)][string]$TemporaryDirectory
    )

    $bodyPath = Join-Path $TemporaryDirectory ('range-' + [Guid]::NewGuid().ToString('N') + '.bin')
    $headerPath = Join-Path $TemporaryDirectory ('headers-' + [Guid]::NewGuid().ToString('N') + '.txt')

    try {
        $arguments = @(
            '--silent',
            '--show-error',
            '--max-time', '30',
            '--header', 'Range: bytes=0-1023',
            '--dump-header', $headerPath,
            '--output', $bodyPath,
            '--write-out', '%{http_code}'
        )
        $arguments += Get-CloudflareDnsOverrideArguments -Url $Url
        $arguments += $Url
        $result = & $CurlPath @arguments 2>$null

        if ($LASTEXITCODE -ne 0) {
            return $false
        }

        $statusText = (($result | Select-Object -Last 1) | Out-String).Trim()
        $length = if (Test-Path -LiteralPath $bodyPath) {
            (Get-Item -LiteralPath $bodyPath).Length
        } else {
            0
        }

        return ($statusText -eq '206' -and $length -eq 1024)
    }
    finally {
        Remove-Item -LiteralPath $bodyPath -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $headerPath -Force -ErrorAction SilentlyContinue
    }
}

function Get-HeaderDump {
    param(
        [Parameter(Mandatory = $true)][string]$Url,
        [Parameter(Mandatory = $true)][string]$OutputPath
    )

    $arguments = @(
        '--silent',
        '--show-error',
        '--max-time', '20',
        '--head',
        '--dump-header', $OutputPath,
        '--output', 'NUL'
    )
    $arguments += Get-CloudflareDnsOverrideArguments -Url $Url
    $arguments += $Url
    & $CurlPath @arguments 2>$null | Out-Null

    return $LASTEXITCODE
}

function Read-PatternFile {
    param([Parameter(Mandatory = $true)][string]$FilePath)

    if (-not (Test-Path -LiteralPath $FilePath -PathType Leaf)) {
        return @()
    }

    return @(
        Get-Content -LiteralPath $FilePath |
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
    $required = $EstimatedSourceBytes + 2GB

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
        '--redact=100',
        '--report-format', 'json',
        '--report-path', $ReportPath,
        '--exit-code', '20',
        '--timeout', '900',
        $SourceRoot
    )

    & $GitleaksPath @arguments
    $code = $LASTEXITCODE

    if ($code -eq 20) {
        Stop-WithError -Code 22 -Message (
            "Gitleaks hat mögliche Geheimnisse gefunden. " +
            "Der redigierte Bericht liegt unter:`n$ReportPath"
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
        [Parameter(Mandatory = $true)][string[]]$ExclusionPatterns,
        [Parameter(Mandatory = $true)][string]$LogPath
    )

    $parentInfo = [IO.Directory]::GetParent($SourceRoot)
    $parent = if ($parentInfo) { $parentInfo.FullName } else { $null }
    $leaf = [IO.Path]::GetFileName($SourceRoot)

    if (-not $parent -or -not $leaf) {
        Stop-WithError -Code 23 -Message (
            "Ein Laufwerksstamm kann im MVP nicht direkt freigegeben werden: $SourceRoot"
        )
    }

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
        $DestinationArchive,
        $leaf
    )

    foreach ($pattern in $ExclusionPatterns) {
        $arguments += ("-xr!{0}" -f $pattern)
    }

    Push-Location $parent
    try {
        & $SevenZipPath @arguments 2>&1 |
            Tee-Object -FilePath $LogPath |
            Write-Host
        $code = $LASTEXITCODE
    }
    finally {
        Pop-Location
    }

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

    & $SevenZipPath @('t', '-bd', '-bb1', $ArchivePath) 2>&1 |
        Tee-Object -FilePath $LogPath |
        Write-Host

    if ($LASTEXITCODE -ne 0) {
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

    & $SevenZipPath @('l', '-slt', $ArchivePath) 2>&1 |
        Set-Content -LiteralPath $ManifestPath -Encoding UTF8

    if ($LASTEXITCODE -ne 0) {
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

    # Token bewusst nicht in der Prozesskommandozeile:
    $environment = @{
        MINISERVE_ROUTE_PREFIX = ("d/{0}" -f $CapabilityToken)
    }

    return Start-NativeProcess `
        -FilePath $MiniservePath `
        -Arguments $arguments `
        -Environment $environment `
        -WorkingDirectory $script:SessionDirectory `
        -CreateNoWindow
}

function Start-CloudflaredQuickTunnel {
    param(
        [Parameter(Mandatory = $true)][string]$OriginUrl,
        [Parameter(Mandatory = $true)][string]$StdOutPath,
        [Parameter(Mandatory = $true)][string]$StdErrPath
    )

    return Start-Process `
        -FilePath $CloudflaredPath `
        -ArgumentList @(
            'tunnel', '--url', $OriginUrl,
            '--edge-ip-version', '4',
            '--protocol', 'http2',
            '--loglevel', 'info'
        ) `
        -RedirectStandardOutput $StdOutPath `
        -RedirectStandardError $StdErrPath `
        -WindowStyle Hidden `
        -PassThru
}

function Wait-ForQuickTunnelUrl {
    param(
        [Parameter(Mandatory = $true)][System.Diagnostics.Process]$Process,
        [Parameter(Mandatory = $true)][string[]]$LogPaths,
        [int]$TimeoutSeconds = 60
    )

    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    $regex = 'https://[a-z0-9-]+\.trycloudflare\.com'

    do {
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
            return $match.Value.TrimEnd('/')
        }

        Start-Sleep -Milliseconds 500
    } while ([DateTime]::UtcNow -lt $deadline)

    Stop-WithError -Code 42 -Message (
        "Cloudflare hat innerhalb von $TimeoutSeconds Sekunden keine Quick-Tunnel-URL geliefert."
    )
}

function Assert-CacheHeaders {
    param(
        [Parameter(Mandatory = $true)][string]$Url,
        [Parameter(Mandatory = $true)][string]$HeaderPath
    )

    $curlExit = Get-HeaderDump -Url $Url -OutputPath $HeaderPath
    if ($curlExit -ne 0) {
        Stop-WithError -Code 43 -Message "Öffentliche Antwortheader konnten nicht geprüft werden."
    }

    $headers = Get-Content -LiteralPath $HeaderPath -Raw

    if ($headers -match '(?im)^cf-cache-status:\s*HIT\s*$') {
        Stop-WithError -Code 43 -Message (
            "Cloudflare meldet CF-Cache-Status: HIT. Die Freigabe wird nicht fortgesetzt."
        )
    }

    if ($headers -notmatch '(?im)^cache-control:.*\bno-store\b') {
        Stop-WithError -Code 43 -Message (
            "Der öffentliche Endpunkt liefert keinen bestätigten Cache-Control:no-store-Header."
        )
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

        # ES_CONTINUOUS | ES_SYSTEM_REQUIRED
        [void][WorkspaceShare.NativePower]::SetThreadExecutionState(0x80000001)
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
            # ES_CONTINUOUS
            [void][WorkspaceShare.NativePower]::SetThreadExecutionState(0x80000000)
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
        $setClipboard = Get-Command 'Set-Clipboard' -ErrorAction SilentlyContinue
        if ($setClipboard) {
            Set-Clipboard -Value $Url -ErrorAction Stop
        }
        else {
            $Url | & "$env:SystemRoot\System32\clip.exe"
            if ($LASTEXITCODE -ne 0) { return $false }
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
        [Parameter(Mandatory = $true)][datetime]$ExpiresUtc,
        [Parameter(Mandatory = $true)][string]$SourceRoot,
        [Parameter(Mandatory = $true)][string]$Archive,
        [int]$WatchdogPid = 0,
        [long]$WatchdogStartTicks = 0
    )

    $powershellExe = Join-Path $PSHOME 'powershell.exe'
    $launcherProcess = Get-Process -Id $PID

    $metadata = [ordered]@{
        schema = 2
        createdUtc = [DateTime]::UtcNow.ToString('o')
        expiresUtc = $ExpiresUtc.ToString('o')
        sourceRoot = $SourceRoot
        archivePath = $Archive

        launcherPid = $PID
        launcherStartTicks = $launcherProcess.StartTime.ToUniversalTime().Ticks
        launcherPath = $powershellExe

        miniservePid = if ($script:MiniserveProcess) { $script:MiniserveProcess.Id } else { 0 }
        miniserveStartTicks = Get-ProcessStartTicksSafe $script:MiniserveProcess
        miniservePath = $MiniservePath

        cloudflaredPid = if ($script:CloudflaredProcess) { $script:CloudflaredProcess.Id } else { 0 }
        cloudflaredStartTicks = Get-ProcessStartTicksSafe $script:CloudflaredProcess
        cloudflaredPath = $CloudflaredPath

        watchdogPid = $WatchdogPid
        watchdogStartTicks = $WatchdogStartTicks
        watchdogPath = $powershellExe

        keepArchive = [bool]$KeepArchive
        # Bewusst keine URL und kein Capability-Token.
    }

    $metadata |
        ConvertTo-Json -Depth 4 |
        Set-Content -LiteralPath (Join-Path $script:SessionDirectory 'session.json') -Encoding UTF8
}

function Start-Watchdog {
    param(
        [Parameter(Mandatory = $true)][datetime]$ExpiresUtc
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
        '-MiniservePid', [string]$script:MiniserveProcess.Id,
        '-MiniserveStartTicks', [string]$miniserveStartTicks,
        '-CloudflaredPid', [string]$script:CloudflaredProcess.Id,
        '-CloudflaredStartTicks', [string]$cloudflaredStartTicks,
        '-SessionPath', $script:SessionDirectory,
        '-NormalExitMarker', $script:NormalExitMarker,
        '-ExpiresUtc', $ExpiresUtc.ToString('o'),
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
        -CreateNoWindow
}

function Remove-StaleSessions {
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
            Write-Warning "Alte Sitzung ohne verifizierbare Metadaten bleibt bestehen: $($directory.FullName)"
            continue
        }

        try {
            $session = Get-Content -LiteralPath $metadataPath -Raw | ConvertFrom-Json
        }
        catch {
            Write-Warning "Alte Sitzung mit ungültigen Metadaten bleibt bestehen: $($directory.FullName)"
            continue
        }

        $active = $false
        foreach ($identity in @(
            @{ Pid = [int]$session.miniservePid; Path = [string]$session.miniservePath; Ticks = [long]$session.miniserveStartTicks },
            @{ Pid = [int]$session.cloudflaredPid; Path = [string]$session.cloudflaredPath; Ticks = [long]$session.cloudflaredStartTicks },
            @{ Pid = [int]$session.watchdogPid; Path = [string]$session.watchdogPath; Ticks = [long]$session.watchdogStartTicks }
        )) {
            if (Test-ProcessIdentity -ProcessId $identity.Pid -ExpectedPath $identity.Path -ExpectedStartTicks $identity.Ticks) {
                $active = $true
                break
            }
        }

        if (-not $active) {
            Remove-Item -LiteralPath $directory.FullName -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

# ---------------------------------------------------------------------------
# Hauptablauf
# ---------------------------------------------------------------------------

try {
    Write-Host ''
    Write-Host 'WorkspaceShare 3.1 – read-only Quick-Tunnel-Freigabe'
    Write-Host '====================================================='
    Write-Host ''

    $totalSteps = 8

    Write-Step 1 $totalSteps 'Abhängigkeiten und Umgebung prüfen ...'

    if ($UnsafeSkipSecretScan -and -not $TestMode) {
        Stop-WithError -Code 10 -Message (
            "-UnsafeSkipSecretScan ist ausschließlich zusammen mit -TestMode zulässig. " +
            "Im normalen Betrieb ist der Secret-Scan verpflichtend."
        )
    }

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

    if (-not $CurlPath) {
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

    Remove-StaleSessions

    $resolvedRoot = (Resolve-Path -LiteralPath $Path).Path.TrimEnd('\')
    $rootParentInfo = [IO.Directory]::GetParent($resolvedRoot)
    $rootParent = if ($rootParentInfo) { $rootParentInfo.FullName } else { $null }
    $rootLeaf = [IO.Path]::GetFileName($resolvedRoot)

    if (-not $rootParent -or -not $rootLeaf) {
        Stop-WithError -Code 10 -Message "Ein Laufwerksstamm kann nicht freigegeben werden."
    }

    $duration = if ($PSCmdlet.ParameterSetName -eq 'Minutes') {
        [TimeSpan]::FromMinutes($Minutes)
    } else {
        [TimeSpan]::FromHours($Hours)
    }

    $expiresUtc = $null

    Write-Host ("      Quelle: {0}" -f $resolvedRoot)
    Write-Host ("      Laufzeit: {0}" -f $duration)
    Write-Host ("      7-Zip: {0}" -f (Get-ExecutableVersionText -FilePath $SevenZipPath -Arguments @('i')))
    Write-Host ("      miniserve: {0}" -f (Get-ExecutableVersionText -FilePath $MiniservePath))
    Write-Host ("      cloudflared: {0}" -f (Get-ExecutableVersionText -FilePath $CloudflaredPath))
    if (-not $UnsafeSkipSecretScan) {
        Write-Host ("      Gitleaks: {0}" -f (Get-ExecutableVersionText -FilePath $GitleaksPath -Arguments @('version')))
    }

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

    $sessionId = "{0}-{1}" -f (
        [DateTime]::UtcNow.ToString('yyyyMMdd-HHmmss'),
        [Guid]::NewGuid().ToString('N').Substring(0, 8)
    )
    $script:SessionDirectory = Join-Path $SessionBase $sessionId
    New-Item -ItemType Directory -Path $script:SessionDirectory -Force | Out-Null

    $script:NormalExitMarker = Join-Path $script:SessionDirectory 'normal.exit'
    $script:KeepArchiveMarker = Join-Path $script:SessionDirectory 'keep.archive'
    $script:ArchivePath = Join-Path $script:SessionDirectory (
        "workspace-{0}.zip" -f [DateTime]::UtcNow.ToString('yyyyMMdd-HHmmss')
    )

    Assert-FreeDiskSpace `
        -TargetDirectory $script:SessionDirectory `
        -EstimatedSourceBytes $inspection.EstimatedBytes

    if (-not $UnsafeSkipSecretScan) {
        Write-Step 3 $totalSteps 'Workspace mit Gitleaks prüfen ...'
        $gitleaksReport = Join-Path $script:SessionDirectory 'gitleaks-redacted.json'
        Invoke-GitleaksScan -SourceRoot $resolvedRoot -ReportPath $gitleaksReport
        Write-Host '      Keine von Gitleaks erkannten Secrets.'
    } else {
        Write-Step 3 $totalSteps 'Gitleaks-Prüfung wurde explizit übersprungen.'
        Write-Warning (
            'Die inhaltliche Secret-Prüfung ist deaktiviert. ' +
            'Dateinamen- und Reparse-Point-Gates bleiben aktiv.'
        )
    }

    Write-Step 4 $totalSteps 'Bereinigten ZIP64-Snapshot erzeugen ...'

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

    Invoke-SevenZipSnapshot `
        -SourceRoot $resolvedRoot `
        -DestinationArchive $script:ArchivePath `
        -ExclusionPatterns @($exclusions | Select-Object -Unique) `
        -LogPath $archiveCreateLog

    Test-SevenZipArchive `
        -ArchivePath $script:ArchivePath `
        -LogPath $archiveTestLog

    Write-SevenZipManifest `
        -ArchivePath $script:ArchivePath `
        -ManifestPath $archiveManifest

    $archiveHash = (Get-FileHash -LiteralPath $script:ArchivePath -Algorithm SHA256).Hash
    $archiveSize = (Get-Item -LiteralPath $script:ArchivePath).Length

    Set-Content `
        -LiteralPath (Join-Path $script:SessionDirectory 'archive.sha256.txt') `
        -Value ("{0}  {1}" -f $archiveHash, (Split-Path $script:ArchivePath -Leaf)) `
        -Encoding ASCII

    Write-Host ("      Archivgröße: {0:N2} GB" -f ($archiveSize / 1GB))
    Write-Host ("      SHA-256: {0}" -f $archiveHash)

    Write-Step 5 $totalSteps 'Read-only-Dateiserver auf Loopback starten ...'

    $token = New-CapabilityToken
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
            $localStatus = Wait-ForHttpStatus `
                -Url $localUrl `
                -AcceptedStatus @(200) `
                -TimeoutSeconds 10

            if ($localStatus -eq 200) {
                $miniserveStarted = $true
                break
            }

            Stop-ProcessSafe $script:MiniserveProcess
            $script:MiniserveProcess = $null
        }
        catch {
            Stop-ProcessSafe $script:MiniserveProcess
            $script:MiniserveProcess = $null
        }
    }

    if (-not $miniserveStarted) {
        Stop-WithError -Code 30 -Message (
            "miniserve konnte nach fünf Versuchen nicht zuverlässig auf Loopback starten."
        )
    }

    # Negativtest: ohne Capability-Pfad darf der Root nicht erfolgreich sein.
    $localRootStatus = Get-CurlStatus `
        -Url ("http://127.0.0.1:{0}/" -f $port) `
        -TimeoutSeconds 5 `
        -Head

    if ($localRootStatus -eq 200) {
        Stop-WithError -Code 31 -Message (
            "Der lokale Server liefert ohne Geheimtoken HTTP 200. Sicherheits-Gate fehlgeschlagen."
        )
    }

    $localWrongTokenUrl = "http://127.0.0.1:{0}/d/{1}/" -f $port, (New-CapabilityToken)
    $localWrongTokenStatus = Get-CurlStatus -Url $localWrongTokenUrl -TimeoutSeconds 5 -Head
    if ($localWrongTokenStatus -eq 200) {
        Stop-WithError -Code 31 -Message (
            "Der lokale Server liefert mit einem falschen Capability-Token HTTP 200."
        )
    }

    if (-not (Test-RangeRequest -Url $localUrl -TemporaryDirectory $script:SessionDirectory)) {
        Stop-WithError -Code 31 -Message (
            "Lokaler Range-Test (206/1024 Bytes) ist fehlgeschlagen."
        )
    }

    # Read-only-Prüfung: Methoden dürfen weder Datei noch Sitzungsverzeichnis verändern.
    $hashBeforeMethodTests = (Get-FileHash -LiteralPath $script:ArchivePath -Algorithm SHA256).Hash
    $filesBeforeMethodTests = @(
        Get-ChildItem -LiteralPath $script:SessionDirectory -File -Recurse |
        ForEach-Object { $_.FullName.Substring($script:SessionDirectory.Length).ToLowerInvariant() } |
        Sort-Object
    )

    foreach ($method in @('POST', 'PUT', 'PATCH', 'DELETE', 'PROPFIND', 'MKCOL', 'MOVE', 'COPY')) {
        & $CurlPath @(
            '--silent',
            '--show-error',
            '--max-time', '10',
            '--request', $method,
            '--header', 'Destination: /d/forbidden-target',
            '--data-binary', 'WorkspaceShare mutation probe',
            '--output', 'NUL',
            $localUrl
        ) 2>$null | Out-Null
    }

    $hashAfterMethodTests = (Get-FileHash -LiteralPath $script:ArchivePath -Algorithm SHA256).Hash
    $filesAfterMethodTests = @(
        Get-ChildItem -LiteralPath $script:SessionDirectory -File -Recurse |
        ForEach-Object { $_.FullName.Substring($script:SessionDirectory.Length).ToLowerInvariant() } |
        Sort-Object
    )

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

    # Die bestellte Link-Laufzeit beginnt erst jetzt. Langsame Secret-Scans und
    # Snapshot-Erstellung verbrauchen keine Freigabezeit.
    $expiresUtc = [DateTime]::UtcNow.Add($duration)

    $cloudflaredStdOut = Join-Path $script:SessionDirectory 'cloudflared.stdout.log'
    $cloudflaredStdErr = Join-Path $script:SessionDirectory 'cloudflared.stderr.log'
    $originUrl = "http://127.0.0.1:{0}" -f $port

    $script:CloudflaredProcess = Start-CloudflaredQuickTunnel `
        -OriginUrl $originUrl `
        -StdOutPath $cloudflaredStdOut `
        -StdErrPath $cloudflaredStdErr

    # Ab dem Moment, in dem ein öffentlicher Tunnelprozess existiert, muss der
    # Watchdog aktiv sein. Ein harter Launcher-Abbruch während URL-Erkennung oder
    # öffentlicher Tests darf keinen verwaisten Tunnel hinterlassen.
    Write-SessionMetadata `
        -ExpiresUtc $expiresUtc `
        -SourceRoot $resolvedRoot `
        -Archive $script:ArchivePath

    $script:WatchdogProcess = Start-Watchdog -ExpiresUtc $expiresUtc

    Write-SessionMetadata `
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

    Write-Step 7 $totalSteps 'Öffentlichen Endpunkt vollständig prüfen ...'
    Write-Host '      Cloudflare stellt neue Quick-Tunnel-Hosts gelegentlich verzögert bereit (maximal 3 Minuten).'

    $publicStatus = Wait-ForHttpStatus `
        -Url $finalUrl `
        -AcceptedStatus @(200) `
        -TimeoutSeconds 180

    if ($publicStatus -ne 200) {
        Stop-WithError -Code 43 -Message (
            "Der öffentliche Geheimlink lieferte nicht rechtzeitig HTTP 200."
        )
    }

    $publicRootStatus = Get-CurlStatus `
        -Url ($publicBaseUrl + '/') `
        -TimeoutSeconds 10 `
        -Head

    if ($publicRootStatus -eq 200) {
        Stop-WithError -Code 43 -Message (
            "Die öffentliche Tunnelwurzel ist ohne Geheimtoken erfolgreich erreichbar."
        )
    }

    $wrongTokenUrl = "{0}/d/{1}/" -f $publicBaseUrl, (New-CapabilityToken)
    $wrongTokenStatus = Get-CurlStatus `
        -Url $wrongTokenUrl `
        -TimeoutSeconds 10 `
        -Head

    if ($wrongTokenStatus -eq 200) {
        Stop-WithError -Code 43 -Message "Ein falsches Capability-Token lieferte HTTP 200."
    }

    if (-not (Test-RangeRequest -Url $finalUrl -TemporaryDirectory $script:SessionDirectory)) {
        Stop-WithError -Code 43 -Message (
            "Der öffentliche Range-Test (206/1024 Bytes) ist fehlgeschlagen."
        )
    }

    $publicHeadersPath = Join-Path $script:SessionDirectory 'public-headers.txt'
    Assert-CacheHeaders -Url $finalUrl -HeaderPath $publicHeadersPath

    Write-Host '      Öffentliche HEAD-, Negativ-, Range- und Cache-Gates bestanden.'

    Write-Step 8 $totalSteps 'Freigabe aktivieren und Ablauf überwachen ...'

    Enable-SystemAwake

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
    Write-Host ''
    Write-Host 'Dieses Fenster geöffnet lassen. Vorzeitig beenden: Strg+C'
    Write-Host ''

    $lastMinuteShown = -1

    while ([DateTime]::UtcNow -lt $expiresUtc) {
        $script:MiniserveProcess.Refresh()
        $script:CloudflaredProcess.Refresh()
        $script:WatchdogProcess.Refresh()

        if ($script:MiniserveProcess.HasExited) {
            Stop-WithError -Code 50 -Message (
                "miniserve wurde unerwartet beendet (Exit $($script:MiniserveProcess.ExitCode))."
            )
        }

        if ($script:CloudflaredProcess.HasExited) {
            Stop-WithError -Code 50 -Message (
                "cloudflared wurde unerwartet beendet (Exit $($script:CloudflaredProcess.ExitCode))."
            )
        }

        if ($script:WatchdogProcess.HasExited) {
            Stop-WithError -Code 50 -Message (
                "Der Sicherheits-Watchdog wurde unerwartet beendet."
            )
        }

        $remaining = $expiresUtc - [DateTime]::UtcNow
        $wholeMinutes = [Math]::Max(0, [Math]::Ceiling($remaining.TotalMinutes))

        if ($wholeMinutes -ne $lastMinuteShown) {
            Write-Host ("      Verbleibend: ca. {0} Minute(n)" -f $wholeMinutes)
            $lastMinuteShown = $wholeMinutes
        }

        Start-Sleep -Seconds 2
    }

    Write-Host ''
    Write-Host 'Die festgelegte Freigabezeit ist abgelaufen.'
    $script:ExitCode = 0
}
catch {
    $message = $_.Exception.Message
    $parsedCode = 50

    if ($message -match '^E(\d+):\s*(.*)$') {
        $parsedCode = [int]$matches[1]
        $message = $matches[2]
    }

    $script:ExitCode = $parsedCode
    Write-Host ''
    Write-Error $message
}
finally {
    # Öffentliches Ende zuerst. Der Watchdog bleibt bis nach dem Prozessende aktiv.
    Stop-ProcessSafe $script:CloudflaredProcess
    Start-Sleep -Milliseconds 300
    Stop-ProcessSafe $script:MiniserveProcess

    # Erst jetzt darf der Watchdog regulär aussteigen. So entsteht kein Fenster,
    # in dem der Marker gesetzt ist, aber der Tunnel noch läuft.
    if ($script:NormalExitMarker -and $script:SessionDirectory) {
        try {
            New-Item -ItemType File -Path $script:NormalExitMarker -Force | Out-Null
        }
        catch {
        }
    }

    Stop-ProcessSafe $script:WatchdogProcess
    Disable-SystemAwake
    Clear-SensitiveClipboard

    if ($script:SessionDirectory -and (Test-Path -LiteralPath $script:SessionDirectory)) {
        if ($KeepArchive) {
            try {
                New-Item -ItemType File -Path $script:KeepArchiveMarker -Force | Out-Null
            }
            catch {
            }

            Write-Warning (
                "Der lokale Sitzungsordner bleibt wegen -KeepArchive bestehen:`n" +
                $script:SessionDirectory
            )
        }
        else {
            Remove-Item `
                -LiteralPath $script:SessionDirectory `
                -Recurse `
                -Force `
                -ErrorAction SilentlyContinue
        }
    }

    Write-Host ''
    Write-Host 'Tunnel und lokaler Server wurden beendet.'
    if (-not $KeepArchive) {
        Write-Host 'Der temporäre Snapshot wurde gelöscht.'
    }
}

exit $script:ExitCode
