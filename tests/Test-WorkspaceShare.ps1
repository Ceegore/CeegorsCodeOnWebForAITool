#requires -Version 5.1
<#
.SYNOPSIS
    Automatisierte lokale und optionale öffentliche Abnahmetests.

.DESCRIPTION
    Prüft Lockfile, EXE-Hashes, Tokenentropie, Loopback-Bindung, Geheimroute,
    Negativrouten, Range, Resume, No-Store-Header, Prozesskommandozeile und
    Read-only-Wirkung ungewöhnlicher HTTP-/WebDAV-Methoden.

.EXAMPLE
    .\tests\Test-WorkspaceShare.ps1

.EXAMPLE
    .\tests\Test-WorkspaceShare.ps1 -PublicUrl $env:WORKSPACESHARE_TEST_URL
#>

[CmdletBinding()]
param(
    [string]$ToolRoot = (Split-Path $PSScriptRoot -Parent),
    [string]$PublicUrl
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$bin = Join-Path $ToolRoot 'bin'
$miniserve = Join-Path $bin 'miniserve.exe'
$lockPath = Join-Path $ToolRoot 'dependencies.lock.json'
$shareScript = Join-Path $ToolRoot 'Share-Workspace.ps1'
$curl = (Get-Command 'curl.exe' -ErrorAction Stop).Source
$temp = Join-Path ([IO.Path]::GetTempPath()) ('WorkspaceShare-Test-' + [Guid]::NewGuid().ToString('N'))
$server = $null
$failed = 0
$passed = 0

function Assert-True {
    param([bool]$Condition, [string]$Message)

    if ($Condition) {
        $script:passed++
        Write-Host "[PASS] $Message"
    }
    else {
        $script:failed++
        Write-Host "[FAIL] $Message" -ForegroundColor Red
    }
}

function New-Token {
    $bytes = New-Object byte[] 32
    $rng = [Security.Cryptography.RandomNumberGenerator]::Create()
    try { $rng.GetBytes($bytes) } finally { $rng.Dispose() }
    return [Convert]::ToBase64String($bytes).TrimEnd('=').Replace('+','-').Replace('/','_')
}

function Get-Port {
    $listener = New-Object Net.Sockets.TcpListener([Net.IPAddress]::Loopback, 0)
    try {
        $listener.Start()
        return ([Net.IPEndPoint]$listener.LocalEndpoint).Port
    }
    finally {
        $listener.Stop()
    }
}

function ConvertTo-NativeArgument {
    param([AllowEmptyString()][string]$Value)

    if ($null -eq $Value -or $Value.Length -eq 0) {
        return '""'
    }
    if ($Value -notmatch '[\s"]') {
        return $Value
    }

    $builder = New-Object Text.StringBuilder
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
        [void]$builder.Append(('\' * ($backslashes * 2)))
    }
    [void]$builder.Append('"')
    return $builder.ToString()
}

function Curl-Status {
    param(
        [string]$Url,
        [string[]]$Extra = @()
    )

    $arguments = @(
        '--silent','--show-error',
        '--output','NUL',
        '--write-out','%{http_code}',
        '--max-time','15'
    )
    $arguments += $Extra
    $arguments += $Url

    $output = & $curl @arguments 2>$null
    if ($LASTEXITCODE -ne 0 -and -not $output) {
        return 0
    }

    $status = 0
    [void][int]::TryParse(
        (($output | Select-Object -Last 1) | Out-String).Trim(),
        [ref]$status
    )
    return $status
}

function Wait-Ready {
    param([string]$Url)

    $deadline = [DateTime]::UtcNow.AddSeconds(20)
    do {
        if ((Curl-Status -Url $Url -Extra @('--head')) -eq 200) {
            return $true
        }
        Start-Sleep -Milliseconds 300
    } while ([DateTime]::UtcNow -lt $deadline)
    return $false
}

function Get-RelativeFiles {
    param([string]$Root)

    return @(
        Get-ChildItem -LiteralPath $Root -File -Recurse |
        ForEach-Object { $_.FullName.Substring($Root.Length).ToLowerInvariant() } |
        Sort-Object
    )
}

try {
    New-Item -ItemType Directory -Path $temp -Force | Out-Null

    Write-Host 'WorkspaceShare – automatisierte Abnahmetests'
    Write-Host '=========================================='
    Write-Host ''

    Assert-True (Test-Path -LiteralPath $miniserve -PathType Leaf) 'miniserve.exe vorhanden'
    Assert-True (Test-Path -LiteralPath $lockPath -PathType Leaf) 'dependencies.lock.json vorhanden'
    Assert-True (Test-Path -LiteralPath $shareScript -PathType Leaf) 'Share-Workspace.ps1 vorhanden'
    Assert-True ([bool]$curl) 'curl.exe vorhanden'

    $lock = $null
    try {
        $lock = Get-Content -LiteralPath $lockPath -Raw | ConvertFrom-Json
    }
    catch {}

    Assert-True ($null -ne $lock) 'Lockfile ist gültiges JSON'
    if ($lock) {
        Assert-True ([int]$lock.schema -eq 2) 'Lockfile-Schema ist 2'
        Assert-True ([bool]$lock.installed) 'Lockfile bestätigt installierte Abhängigkeiten'

        foreach ($dependency in @($lock.dependencies)) {
            $path = Join-Path $ToolRoot ([string]$dependency.file).Replace('/', '\')
            $exists = Test-Path -LiteralPath $path -PathType Leaf
            Assert-True $exists ("Lockdatei vorhanden: " + $dependency.name)
            if ($exists) {
                $actual = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash
                Assert-True ($actual -eq [string]$dependency.sha256) ("Lockhash stimmt: " + $dependency.name)
            }
        }
    }

    $shareText = Get-Content -LiteralPath $shareScript -Raw
    foreach ($forbiddenFlag in @(
        '--upload-files','--mkdir','--rm-files','--enable-webdav','--pastebin'
    )) {
        Assert-True ($shareText -notmatch [regex]::Escape("'$forbiddenFlag'")) (
            "Gefährliches miniserve-Flag nicht aktiviert: $forbiddenFlag"
        )
    }

    Assert-True ($shareText -match "MINISERVE_ROUTE_PREFIX") 'Capability-Token wird über Environment gesetzt'
    Assert-True ($shareText -match "'--interfaces', '127.0.0.1'") 'Loopback-Bindung ist statisch konfiguriert'

    $token = New-Token
    Assert-True ($token.Length -eq 43) '256-Bit-Token hat Base64url-Länge 43'
    Assert-True ($token -match '^[A-Za-z0-9_-]{43}$') 'Token enthält nur URL-sichere Zeichen'

    # Mehrere MiB, damit Range-/Resume-Tests sinnvoll sind.
    $sample = Join-Path $temp 'sample.zip'
    $buffer = New-Object byte[] (8MB)
    $rng = [Security.Cryptography.RandomNumberGenerator]::Create()
    try { $rng.GetBytes($buffer) } finally { $rng.Dispose() }
    [IO.File]::WriteAllBytes($sample, $buffer)
    $originalHash = (Get-FileHash -LiteralPath $sample -Algorithm SHA256).Hash

    $port = Get-Port
    $localUrl = "http://127.0.0.1:$port/d/$token/"

    $psi = New-Object Diagnostics.ProcessStartInfo
    $psi.FileName = $miniserve
    $arguments = @(
        '--quiet',
        '--log-color','never',
        '--interfaces','127.0.0.1',
        '--port',"$port",
        '--workers','2',
        '--no-symlinks',
        '--header','Cache-Control: private, no-store, no-cache, max-age=0, must-revalidate',
        $sample
    )
    $psi.Arguments = (($arguments | ForEach-Object { ConvertTo-NativeArgument $_ }) -join ' ')
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.EnvironmentVariables['MINISERVE_ROUTE_PREFIX'] = "d/$token"

    $server = New-Object Diagnostics.Process
    $server.StartInfo = $psi
    [void]$server.Start()

    Assert-True (Wait-Ready $localUrl) 'Geheimroute liefert lokal HTTP 200'
    Assert-True ((Curl-Status -Url "http://127.0.0.1:$port/" -Extra @('--head')) -ne 200) 'Root ohne Token liefert nicht 200'
    Assert-True ((Curl-Status -Url "http://127.0.0.1:$port/d/$(New-Token)/" -Extra @('--head')) -ne 200) 'Falsches Token liefert nicht 200'

    try {
        $commandLine = (Get-CimInstance Win32_Process -Filter "ProcessId=$($server.Id)").CommandLine
        Assert-True ($commandLine -notmatch [regex]::Escape($token)) 'Token fehlt in miniserve-Prozesskommandozeile'
    }
    catch {
        Write-Host '[WARN] Prozesskommandozeile konnte nicht über CIM gelesen werden.'
    }

    try {
        $connections = @(Get-NetTCPConnection -OwningProcess $server.Id -State Listen -ErrorAction Stop)
        Assert-True ($connections.Count -gt 0) 'miniserve besitzt einen Listening-Socket'
        foreach ($connection in $connections) {
            Assert-True ($connection.LocalAddress -in @('127.0.0.1','::1')) 'Listening-Socket ist nur Loopback'
        }
    }
    catch {
        Write-Host '[WARN] Get-NetTCPConnection konnte nicht ausgeführt werden.'
    }

    $rangeFile = Join-Path $temp 'range.bin'
    $rangeStatus = & $curl @(
        '--silent','--show-error',
        '--header','Range: bytes=0-1023',
        '--output',$rangeFile,
        '--write-out','%{http_code}',
        $localUrl
    ) 2>$null

    Assert-True (((($rangeStatus | Select-Object -Last 1) | Out-String).Trim()) -eq '206') 'Range liefert HTTP 206'
    Assert-True ((Get-Item -LiteralPath $rangeFile).Length -eq 1024) 'Range liefert exakt 1024 Bytes'

    $resume = Join-Path $temp 'resume.zip'
    & $curl @(
        '--silent','--show-error',
        '--header','Range: bytes=0-1048575',
        '--output',$resume,
        $localUrl
    ) | Out-Null
    Assert-True ($LASTEXITCODE -eq 0) 'Erster Teil des Resume-Downloads erfolgreich'

    & $curl @(
        '--silent','--show-error',
        '--continue-at','-',
        '--output',$resume,
        $localUrl
    ) | Out-Null
    Assert-True ($LASTEXITCODE -eq 0) 'Resume-Aufruf erfolgreich'
    Assert-True ((Get-FileHash -LiteralPath $resume -Algorithm SHA256).Hash -eq $originalHash) 'Fortgesetzter Download besitzt korrekten Hash'

    $beforeFiles = Get-RelativeFiles $temp
    foreach ($method in @('POST','PUT','PATCH','DELETE','PROPFIND','MKCOL','MOVE','COPY')) {
        & $curl @(
            '--silent','--show-error',
            '--request',$method,
            '--header','Destination: /d/forbidden-target',
            '--data-binary','mutation-test',
            '--output','NUL',
            $localUrl
        ) 2>$null | Out-Null
    }
    $afterFiles = Get-RelativeFiles $temp

    Assert-True ((Get-FileHash -LiteralPath $sample -Algorithm SHA256).Hash -eq $originalHash) 'Mutation-Probes verändern die bereitgestellte Datei nicht'
    Assert-True (-not (Compare-Object $beforeFiles $afterFiles)) 'Mutation-Probes erzeugen keine zusätzlichen Dateien'

    $headers = Join-Path $temp 'local-headers.txt'
    & $curl @('--silent','--head','--dump-header',$headers,'--output','NUL',$localUrl) | Out-Null
    $headerText = Get-Content -LiteralPath $headers -Raw
    Assert-True ($headerText -match '(?im)^cache-control:.*no-store') 'Lokales Cache-Control enthält no-store'

    if ($PublicUrl) {
        Write-Host ''
        Write-Host 'Öffentliche Tests'
        Write-Host '------------------'

        $publicUri = [Uri]$PublicUrl
        $segments = @($publicUri.AbsolutePath.Trim('/').Split('/'))
        Assert-True ($segments.Count -ge 2 -and $segments[0] -eq 'd') 'Öffentlicher Link besitzt erwarteten Capability-Pfad'

        $publicBase = "{0}://{1}" -f $publicUri.Scheme, $publicUri.Authority
        $publicWrong = "{0}/d/{1}/" -f $publicBase, (New-Token)

        Assert-True ((Curl-Status -Url $PublicUrl -Extra @('--head')) -eq 200) 'Öffentliche Geheimroute liefert 200'
        Assert-True ((Curl-Status -Url ($publicBase + '/') -Extra @('--head')) -ne 200) 'Öffentliche Root-Route liefert nicht 200'
        Assert-True ((Curl-Status -Url $publicWrong -Extra @('--head')) -ne 200) 'Öffentliches falsches Token liefert nicht 200'

        $publicRange = Join-Path $temp 'public-range.bin'
        $publicStatus = & $curl @(
            '--silent','--show-error',
            '--header','Range: bytes=0-1023',
            '--output',$publicRange,
            '--write-out','%{http_code}',
            $PublicUrl
        ) 2>$null

        Assert-True (((($publicStatus | Select-Object -Last 1) | Out-String).Trim()) -eq '206') 'Öffentliche Range liefert 206'
        Assert-True ((Get-Item -LiteralPath $publicRange).Length -eq 1024) 'Öffentliche Range liefert 1024 Bytes'

        $publicHeaders = Join-Path $temp 'public-headers.txt'
        & $curl @('--silent','--head','--dump-header',$publicHeaders,'--output','NUL',$PublicUrl) | Out-Null
        $publicHeaderText = Get-Content -LiteralPath $publicHeaders -Raw
        Assert-True ($publicHeaderText -match '(?im)^cache-control:.*no-store') 'Öffentliches Cache-Control enthält no-store'
        Assert-True ($publicHeaderText -notmatch '(?im)^cf-cache-status:\s*HIT\s*$') 'Cloudflare meldet keinen Cache-HIT'
    }
}
finally {
    if ($server) {
        try {
            $server.Refresh()
            if (-not $server.HasExited) {
                Stop-Process -Id $server.Id -Force -ErrorAction SilentlyContinue
                [void]$server.WaitForExit(3000)
            }
        }
        catch {}
    }
    Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host ''
Write-Host "Bestanden: $passed"
Write-Host "Fehlgeschlagen: $failed"

if ($failed -gt 0) {
    exit 1
}

exit 0
