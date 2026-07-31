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
    [string]$ToolRoot,
    [string]$PublicUrl
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

if ([string]::IsNullOrWhiteSpace($ToolRoot)) {
    $ToolRoot = Split-Path $PSScriptRoot -Parent
}

$bin = Join-Path $ToolRoot 'bin'
$miniserve = Join-Path $bin 'miniserve.exe'
$lockPath = Join-Path $ToolRoot 'dependencies.lock.json'
$shareScript = Join-Path $ToolRoot 'Share-Workspace.ps1'
$healthModule = Join-Path $ToolRoot 'scripts\WorkspaceShare.Health.psm1'
$curlModule = Join-Path $ToolRoot 'scripts\WorkspaceShare.Curl.psm1'
$curl = (Get-Command 'curl.exe' -ErrorAction Stop).Source
$temp = Join-Path ([IO.Path]::GetTempPath()) ('WorkspaceShare-Test-' + [Guid]::NewGuid().ToString('N'))
$server = $null
$failed = 0
$passed = 0
Import-Module $curlModule -Force -ErrorAction Stop

function Invoke-TestCurl { param([string]$Url,[string[]]$Arguments);$result=WorkspaceShare.Curl\Invoke-CurlWithPrivateUrl -CurlPath $curl -Url $Url -Arguments $Arguments -ProcessTimeoutSeconds 90;$global:LASTEXITCODE=$result.ExitCode;return $result.StdOut }

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
    $output = Invoke-TestCurl -Url $Url -Arguments $arguments
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
    Assert-True (Test-Path -LiteralPath $healthModule -PathType Leaf) 'Gemeinsames Health-Modul vorhanden'
    Assert-True ([bool]$curl) 'curl.exe vorhanden'

    foreach ($powerShellFile in @(Get-ChildItem -LiteralPath $ToolRoot -Filter '*.ps1' -File -Recurse) + @(Get-ChildItem -LiteralPath $ToolRoot -Filter '*.psm1' -File -Recurse)) {
        $tokens = $null
        $parseErrors = $null
        [System.Management.Automation.Language.Parser]::ParseFile($powerShellFile.FullName, [ref]$tokens, [ref]$parseErrors) | Out-Null
        Assert-True (@($parseErrors).Count -eq 0) ("PowerShell-Syntax gültig: " + $powerShellFile.FullName.Substring($ToolRoot.Length))
    }

    $lock = $null
    try {
        $lock = Get-Content -LiteralPath $lockPath -Raw | ConvertFrom-Json
    }
    catch {}

    Assert-True ($null -ne $lock) 'Lockfile ist gültiges JSON'
    if ($lock) {
        Assert-True ([int]$lock.schema -eq 2) 'Lockfile-Schema ist 2'
        Assert-True ([bool]$lock.installed) 'Lockfile bestätigt installierte Abhängigkeiten'
        $expectedLockPaths = @{ cloudflared='bin/cloudflared.exe'; miniserve='bin/miniserve.exe'; Gitleaks='bin/gitleaks.exe'; '7-Zip'='bin/7za.exe' }
        Assert-True (@($lock.dependencies).Count -eq $expectedLockPaths.Count) 'Lockfile enthält exakt die erwartete Abhängigkeitsanzahl'

        foreach ($dependency in @($lock.dependencies)) {
            $expectedPath = $expectedLockPaths[[string]$dependency.name]
            Assert-True ($null -ne $expectedPath -and ([string]$dependency.file).Replace('\','/') -eq $expectedPath) ('Lockpfad stimmt: ' + $dependency.name)
            $path = Join-Path $ToolRoot $expectedPath.Replace('/', '\')
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
    Assert-True ($shareText -match 'Invoke-CurlProbe') 'Strukturierte curl-Probes erfassen HTTP- und Fehlerdetails'
    Assert-True ($shareText -match '''--protocol'',\s*\$Protocol') 'Tunnel-Protokoll ist konfigurierbar'
    Assert-True ($shareText -match '''--edge-ip-version'',\s*\$EdgeIpVersion') 'Edge-IP-Modus ist konfigurierbar'
    Assert-True ($shareText -match "'--metrics'") 'cloudflared-Metrics-Endpunkt wird explizit konfiguriert'
    Assert-True ($shareText -match "'--no-autoupdate'") 'cloudflared Auto-Update ist für überwachte Binärdateien deaktiviert'
    Assert-True ($shareText -match '/ready') 'Laufzeit prüft cloudflared-Readiness'
    Assert-True ($shareText -match '/quicktunnel') 'Laufzeit prüft Quick-Tunnel-Hostname'
    Assert-True ($shareText -match 'Get-AllowedOutageSeconds') 'Laufzeit besitzt ein zeitbasiertes Ausfallbudget'
    Assert-True ($shareText -match 'Get-QuickTunnelHostnameState') 'Quick-Tunnel-Hostname wird roh und nur im Speicher verglichen'
    Assert-True ($shareText -notmatch 'ReportedHostname') 'Roher Quick-Tunnel-Hostname wird nicht persistiert'
    Assert-True ($shareText -match 'Stop-ProcessConfirmed') 'Launcher bestätigt das Stoppen von Kindprozessen'
    Assert-True ($shareText -match 'Get-HealthSamplePlan') 'Laufzeit verwendet rotierende Health-Samples'
    Assert-True ($shareText -match 'Invoke-CurlWithPrivateUrl') 'Capability-URLs werden nicht an curl-Kommandozeilen übergeben'
    Assert-True ($shareText -match 'BodySha256') 'Health-Probes vergleichen Byte-Samples per SHA-256'
    Assert-True ($shareText -match 'Protect-DiagnosticText') 'Diagnosetext wird zentral bereinigt'
    Assert-True ($shareText -match 'KeepDiagnosticsOnError') 'Sichere Fehlerdiagnosen können erhalten werden'
    Assert-True ($shareText -match 'https://<redacted>\.trycloudflare\.com') 'Diagnoselogs schwärzen die Tunnel-URL'
    Assert-True ($shareText -notmatch 'DnsOverrideCache') 'Permanenter DNS-IP-Cache wurde entfernt'
    Assert-True ($shareText -match 'Get-LiveDnsOverrideConfigLines') 'DNS-Override existiert nur als private frische Diagnosehilfe'
    Assert-True ($shareText -notmatch 'Get-CurlStatusViaCloudflareDns') 'Veralteter DNS-Fallback wurde entfernt'
    Assert-True ($shareText -notmatch 'Get-CloudflareDnsOverrideArguments') 'Veraltete DNS-Override-Hilfe wurde entfernt'
    foreach ($resolver in @('1.1.1.1', '8.8.8.8', '9.9.9.9')) {
        Assert-True ($shareText -match [regex]::Escape("'$resolver'")) ("DNS-Fallback enthält Resolver: $resolver")
    }

    Import-Module -Name $healthModule -Force -ErrorAction Stop
    $sourceTokens = $null
    $sourceErrors = $null
    $sourceAst = [System.Management.Automation.Language.Parser]::ParseFile($shareScript, [ref]$sourceTokens, [ref]$sourceErrors)
    $sanitizerAst = $sourceAst.FindAll({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Protect-DiagnosticText' }, $true) | Select-Object -First 1
    Assert-True ($null -ne $sanitizerAst) 'Zentraler Diagnosesanitizer ist vorhanden'
    if ($sanitizerAst) {
        Invoke-Expression $sanitizerAst.Extent.Text
        Assert-True ((Get-AllowedOutageSeconds -Classification 'EdgeDisconnected') -eq 150) 'Edge-Ausfallbudget ist zeitbasiert'
        Assert-True ((Get-AllowedOutageSeconds -Classification 'RateLimited' -RetryAfterSeconds 999999) -eq 660) 'Retry-After erweitert das Rate-Limit-Budget nur endlich'
        Assert-True ((Get-BoundedRetryAfterSeconds -RetryAfterSeconds -1) -eq 0) 'Negativer Retry-After wird begrenzt'
        Assert-True ((Get-BoundedRetryAfterSeconds -RetryAfterSeconds 999999) -eq 600) 'Übermäßiger Retry-After wird begrenzt'
        $samplePlan = @(Get-HealthSamplePlan -ArchiveSize 1048576)
        Assert-True ($samplePlan.Count -eq 3 -and $samplePlan[0].Start -eq 0 -and $samplePlan[2].End -eq 1048575) 'Health-Sample-Plan deckt Anfang, Mitte und Ende ab'
        Assert-True (@(Get-HealthSamplePlan -ArchiveSize 1).Count -eq 1) 'Kleine Archive erhalten genau einen Vollfile-Sample'
        $classification = Get-TunnelClassification -LocalSampleValid $true -EndToEndSampleValid $true -HostnameAvailable $true -HostnameMatches $false -PublicHttpStatus 206 -CloudflareError 0 -PublicCurlExit 0 -OverrideDiagnosticSuccess $false -PublicDnsSuccessCount 3 -Ready $false
        Assert-True ($classification -eq 'Healthy') 'End-to-End-Hash schlägt abweichende Hilfssignale'
        $classification = Get-TunnelClassification -LocalSampleValid $true -EndToEndSampleValid $false -HostnameAvailable $true -HostnameMatches $true -PublicHttpStatus 429 -CloudflareError 0 -PublicCurlExit 0 -OverrideDiagnosticSuccess $false -PublicDnsSuccessCount 3 -Ready $true
        Assert-True ($classification -eq 'RateLimited') 'Rate-Limit wird nicht als Hostname-Wechsel klassifiziert'
        $classification = Get-TunnelClassification -LocalSampleValid $true -EndToEndSampleValid $false -HostnameAvailable $true -HostnameMatches $true -PublicHttpStatus 500 -CloudflareError 0 -PublicCurlExit 0 -OverrideDiagnosticSuccess $false -PublicDnsSuccessCount 0 -DnsChecked $true -SystemDnsSuccess $false -Ready $true
        Assert-True ($classification -ne 'DnsMissing') 'HTTP-Fehler ohne curl-Resolverfehler wird nicht als DnsMissing klassifiziert'
        $diagnosticToken = New-Token
        $diagnosticUrl = "https://unit-test.trycloudflare.com/d/$diagnosticToken/"
        $sanitized = Protect-DiagnosticText -Text ("curl failed: $diagnosticUrl Location: /d/$diagnosticToken/") -KnownSecretUrls @($diagnosticUrl)
        Assert-True ($sanitized -notmatch [regex]::Escape($diagnosticToken)) 'Diagnosesanitizer entfernt Capability-Token'
        Assert-True ($sanitized -notmatch 'unit-test\.trycloudflare\.com') 'Diagnosesanitizer entfernt Tunnel-Hostname'
        $hostnameOnlySanitized = Protect-DiagnosticText -Text 'Raw hostname: unit-test.trycloudflare.com'
        Assert-True ($hostnameOnlySanitized -notmatch 'unit-test\.trycloudflare\.com') 'Diagnosesanitizer entfernt auch hostname-only Felder'
    }

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
    $resolveLine='resolve = "fake.example:{0}:127.0.0.1"' -f $port
    $resolvedResult=WorkspaceShare.Curl\Invoke-CurlWithPrivateUrl -CurlPath $curl -Url ("http://fake.example:{0}/d/{1}/" -f $port,$token) -Arguments @('--silent','--show-error','--noproxy','*','--head','--output','NUL') -PrivateConfigLines @($resolveLine)
    Assert-True ($resolvedResult.ExitCode -eq 0 -and $resolveLine -notmatch '\\"') 'Private resolve-Konfiguration ist syntaktisch gültig und bleibt aus argv'
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
    $rangeStatus = Invoke-TestCurl -Url $localUrl -Arguments @(
        '--silent','--show-error',
        '--header','Range: bytes=0-1023',
        '--output',$rangeFile,
        '--write-out','%{http_code}'
    )

    Assert-True (((($rangeStatus | Select-Object -Last 1) | Out-String).Trim()) -eq '206') 'Range liefert HTTP 206'
    Assert-True ((Get-Item -LiteralPath $rangeFile).Length -eq 1024) 'Range liefert exakt 1024 Bytes'

    $resume = Join-Path $temp 'resume.zip'
    [void](Invoke-TestCurl -Url $localUrl -Arguments @(
        '--silent','--show-error',
        '--header','Range: bytes=0-1048575',
        '--output',$resume
    ))
    Assert-True ($LASTEXITCODE -eq 0) 'Erster Teil des Resume-Downloads erfolgreich'

    [void](Invoke-TestCurl -Url $localUrl -Arguments @(
        '--silent','--show-error',
        '--continue-at','-',
        '--output',$resume
    ))
    Assert-True ($LASTEXITCODE -eq 0) 'Resume-Aufruf erfolgreich'
    Assert-True ((Get-FileHash -LiteralPath $resume -Algorithm SHA256).Hash -eq $originalHash) 'Fortgesetzter Download besitzt korrekten Hash'

    $beforeFiles = Get-RelativeFiles $temp
    foreach ($method in @('POST','PUT','PATCH','DELETE','PROPFIND','MKCOL','MOVE','COPY')) {
        [void](Invoke-TestCurl -Url $localUrl -Arguments @(
            '--silent','--show-error',
            '--request',$method,
            '--header','Destination: /d/forbidden-target',
            '--data-binary','mutation-test',
            '--output','NUL'
        ))
    }
    $afterFiles = Get-RelativeFiles $temp

    Assert-True ((Get-FileHash -LiteralPath $sample -Algorithm SHA256).Hash -eq $originalHash) 'Mutation-Probes verändern die bereitgestellte Datei nicht'
    Assert-True (-not (Compare-Object $beforeFiles $afterFiles)) 'Mutation-Probes erzeugen keine zusätzlichen Dateien'

    $headers = Join-Path $temp 'local-headers.txt'
    [void](Invoke-TestCurl -Url $localUrl -Arguments @('--silent','--head','--dump-header',$headers,'--output','NUL'))
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
        $publicStatus = Invoke-TestCurl -Url $PublicUrl -Arguments @(
            '--silent','--show-error',
            '--header','Range: bytes=0-1023',
            '--output',$publicRange,
            '--write-out','%{http_code}'
        )

        Assert-True (((($publicStatus | Select-Object -Last 1) | Out-String).Trim()) -eq '206') 'Öffentliche Range liefert 206'
        Assert-True ((Get-Item -LiteralPath $publicRange).Length -eq 1024) 'Öffentliche Range liefert 1024 Bytes'

        $publicHeaders = Join-Path $temp 'public-headers.txt'
        [void](Invoke-TestCurl -Url $PublicUrl -Arguments @('--silent','--head','--dump-header',$publicHeaders,'--output','NUL'))
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
