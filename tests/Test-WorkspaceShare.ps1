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

function Invoke-TestCurl {
    param([string]$Url,[string[]]$Arguments)
    $uri=$null
    if([Uri]::TryCreate($Url,[UriKind]::Absolute,[ref]$uri) -and $uri.Host -in @('127.0.0.1','localhost','::1')){
        $Arguments=@('--noproxy','*')+@($Arguments)
    }
    $result=WorkspaceShare.Curl\Invoke-CurlWithPrivateUrl -CurlPath $curl -Url $Url -Arguments $Arguments -ProcessTimeoutSeconds 90
    $global:LASTEXITCODE=$result.ExitCode
    if($result.ExitCode -ne 0){
        $safeError=WorkspaceShare.Curl\Protect-DiagnosticText -Text $result.StdErr -KnownSecretUrls @($Url)
        Write-Warning ("curl.exe failed with exit {0} ({1}): {2}" -f $result.ExitCode,$curl,$safeError.Trim())
    }
    return $result.StdOut
}

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

function Invoke-ShareChild {
    # Runs Share-Workspace.ps1 as a child process; returns exit code and stdout lines.
    param([string[]]$Arguments, [int]$TimeoutSeconds = 600)

    $psi = New-Object Diagnostics.ProcessStartInfo
    $psi.FileName = Join-Path $PSHOME 'powershell.exe'
    $childArguments = @('-NoLogo','-NoProfile','-NonInteractive','-File',$shareScript) + @($Arguments)
    $psi.Arguments = (($childArguments | ForEach-Object { ConvertTo-NativeArgument $_ }) -join ' ')
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardInput = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.StandardOutputEncoding = [Text.Encoding]::UTF8
    $psi.StandardErrorEncoding = [Text.Encoding]::UTF8

    $child = New-Object Diagnostics.Process
    $child.StartInfo = $psi
    [void]$child.Start()
    $child.StandardInput.Close()
    $stdoutTask = $child.StandardOutput.ReadToEndAsync()
    $stderrTask = $child.StandardError.ReadToEndAsync()
    if (-not $child.WaitForExit($TimeoutSeconds * 1000)) {
        try { $child.Kill() } catch {}
        [void]$child.WaitForExit(5000)
    }
    $child.WaitForExit()
    $text = $stdoutTask.Result
    $errorText = $stderrTask.Result
    $exitCode = $child.ExitCode
    $child.Dispose()
    return [pscustomobject]@{
        ExitCode = $exitCode
        Lines    = @($text -split "\r?\n" | Where-Object { $_ -ne '' })
        StdErr   = $errorText
    }
}

function Get-ShareEvents {
    param($Lines)
    $parsed = New-Object System.Collections.Generic.List[object]
    $allParsed = $true
    foreach ($line in @($Lines)) {
        if (([string]$line).StartsWith('@@WSEVENT@@ ')) {
            try { $parsed.Add((([string]$line).Substring(12) | ConvertFrom-Json)) }
            catch { $allParsed = $false }
        }
    }
    return [pscustomobject]@{ Events = @($parsed.ToArray()); AllParsed = $allParsed }
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
    Assert-True ($shareText -match 'Test-ExactArchiveContents[^\r\n]+-RunSecretScan:\(-not \$UnsafeSkipSecretScan\)') 'Finale Archivrichtlinie läuft auch bei Test-Scan-Bypass'
    Assert-True ($shareText -match 'Get-SourceConsistencyManifest[^\r\n]+-ExclusionPatterns') 'Quellkonsistenz berücksichtigt nur eingeschlossene Dateien'
    Assert-True ($shareText -match 'archive-includes\.txt' -and $shareText -match 'IncludedRelativePaths') 'Eingeschlossene Dateiliste steuert und verifiziert das finale Archiv'
    Assert-True ($shareText -notmatch '\[Environment\]::SetEnvironmentVariable\(') 'Launcher mutiert seine Prozessumgebung nicht für Kindprozesse'
    foreach ($resolver in @('1.1.1.1', '8.8.8.8', '9.9.9.9')) {
        Assert-True ($shareText -match [regex]::Escape("'$resolver'")) ("DNS-Fallback enthält Resolver: $resolver")
    }

    Import-Module -Name $healthModule -Force -ErrorAction Stop
    $sourceTokens = $null
    $sourceErrors = $null
    $sourceAst = [System.Management.Automation.Language.Parser]::ParseFile($shareScript, [ref]$sourceTokens, [ref]$sourceErrors)
    $sanitizerAst = $sourceAst.FindAll({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Protect-DiagnosticText' }, $true) | Select-Object -First 1
    $excludeAst = $sourceAst.FindAll({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Test-SourcePathExcluded' }, $true) | Select-Object -First 1
    $manifestAst = $sourceAst.FindAll({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Get-SourceConsistencyManifest' }, $true) | Select-Object -First 1
    Assert-True ($null -ne $sanitizerAst) 'Zentraler Diagnosesanitizer ist vorhanden'
    Assert-True ($null -ne $excludeAst) 'Test-SourcePathExcluded ist in Share-Workspace.ps1 vorhanden'
    Assert-True ($null -ne $manifestAst) 'Get-SourceConsistencyManifest ist in Share-Workspace.ps1 vorhanden'
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
    if($excludeAst -and $manifestAst){
        Import-Module (Join-Path $ToolRoot 'scripts\WorkspaceShare.Path.psm1') -Force
        Invoke-Expression $excludeAst.Extent.Text;Invoke-Expression $manifestAst.Extent.Text
        $readPatterns={param($file)@(Get-Content -LiteralPath $file|ForEach-Object{$_.Trim()}|Where-Object{$_ -and -not $_.StartsWith('#')})}
        $mandatoryPatterns=@(& $readPatterns (Join-Path $ToolRoot 'config\mandatory-excludes.txt'));$generatedPatterns=@(& $readPatterns (Join-Path $ToolRoot 'config\generated-excludes.txt'))
        Assert-True ($mandatoryPatterns.Count -gt 0 -and $generatedPatterns.Count -gt 0) 'Ausschlussmuster werden aus config\ geladen'
        $allPatterns=@($mandatoryPatterns)+@($generatedPatterns)
        $isExcluded={param($relative,$patterns)Test-SourcePathExcluded -RelativePath $relative -Name ([IO.Path]::GetFileName($relative)) -Patterns $patterns}
        Assert-True (& $isExcluded '.git\config' $mandatoryPatterns) 'Pflichtausschluss: .git\config wird ausgeschlossen'
        Assert-True (& $isExcluded '.ssh\id_rsa' $mandatoryPatterns) 'Pflichtausschluss: .ssh\id_rsa wird ausgeschlossen'
        Assert-True (& $isExcluded 'sub\.npmrc' $mandatoryPatterns) 'Pflichtausschluss: .npmrc wird in jeder Tiefe ausgeschlossen'
        Assert-True (-not(& $isExcluded 'src\Library\x.cs' $allPatterns)) 'Root-verankertes Library\* schließt src\Library\x.cs nicht aus'
        Assert-True (& $isExcluded 'Library\x.asset' $allPatterns) 'Root-verankertes Library\* schließt Library\x.asset aus'
        Assert-True (& $isExcluded 'pages\[id]\page.tsx' @('pages\[id]\*')) 'Klammermuster pages\[id]\* trifft den literalen Pfad'
        Assert-True (-not(& $isExcluded 'pages\i\page.tsx' @('pages\[id]\*'))) 'Klammermuster pages\[id]\* wird nicht als Zeichenklasse interpretiert'
        $manifestRoot=Join-Path $temp 'manifest-fixture';New-Item -ItemType Directory -Path (Join-Path $manifestRoot 'node_modules') -Force|Out-Null
        Set-Content -LiteralPath (Join-Path $manifestRoot 'included.txt') -Value 'one';Set-Content -LiteralPath (Join-Path $manifestRoot 'node_modules\cache.txt') -Value 'one'
        $manifestOne=@(Get-SourceConsistencyManifest -Root $manifestRoot -ExclusionPatterns @('node_modules'))
        Set-Content -LiteralPath (Join-Path $manifestRoot 'node_modules\cache.txt') -Value 'two'
        $manifestTwo=@(Get-SourceConsistencyManifest -Root $manifestRoot -ExclusionPatterns @('node_modules'))
        Assert-True (-not(Compare-Object $manifestOne $manifestTwo)) 'Änderungen an ausgeschlossenen Dateien ändern das Konsistenzmanifest nicht'
        Set-Content -LiteralPath (Join-Path $manifestRoot 'included.txt') -Value 'two'
        $manifestThree=@(Get-SourceConsistencyManifest -Root $manifestRoot -ExclusionPatterns @('node_modules'))
        Assert-True ([bool](Compare-Object $manifestTwo $manifestThree)) 'Änderungen an eingeschlossenen Dateien ändern das Konsistenzmanifest'
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

    $serverReady = Wait-Ready $localUrl
    Assert-True $serverReady 'Geheimroute liefert lokal HTTP 200'
    if (-not $serverReady) {
        Write-Host '[FAIL] miniserve wurde nicht bereit; Live-Server-Abschnitt wird abgebrochen.' -ForegroundColor Red
        Write-Host ''
        Write-Host "Bestanden: $passed"
        Write-Host "Fehlgeschlagen: $failed"
        exit 1
    }
    $resolveLine='resolve = "fake.example:{0}:127.0.0.1"' -f $port
    $resolvedResult=WorkspaceShare.Curl\Invoke-CurlWithPrivateUrl -CurlPath $curl -Url ("http://fake.example:{0}/d/{1}/" -f $port,$token) -Arguments @('--silent','--show-error','--noproxy','*','--head','--output','NUL','--write-out','%{http_code}') -PrivateConfigLines @($resolveLine)
    Assert-True ($resolvedResult.ExitCode -eq 0 -and ((($resolvedResult.StdOut | Select-Object -Last 1) | Out-String).Trim()) -eq '200') 'Private resolve-Konfiguration ist gültig, wird angewendet und bleibt aus argv'
    Assert-True ((Curl-Status -Url "http://127.0.0.1:$port/" -Extra @('--head')) -in @(401,403,404)) 'Root ohne Token liefert eine explizite 4xx-Ablehnung'
    Assert-True ((Curl-Status -Url "http://127.0.0.1:$port/d/$(New-Token)/" -Extra @('--head')) -in @(401,403,404)) 'Falsches Token liefert eine explizite 4xx-Ablehnung'

    try {
        $commandLine = (Get-CimInstance Win32_Process -Filter "ProcessId=$($server.Id)").CommandLine
        Assert-True ($commandLine -notmatch [regex]::Escape($token)) 'Token fehlt in miniserve-Prozesskommandozeile'
    }
    catch {
        Assert-True $false "Prozesskommandozeile nicht prüfbar: $($_.Exception.Message)"
    }

    try {
        $connections = @(Get-NetTCPConnection -OwningProcess $server.Id -State Listen -ErrorAction Stop)
        Assert-True ($connections.Count -gt 0) 'miniserve besitzt einen Listening-Socket'
        foreach ($connection in $connections) {
            Assert-True ($connection.LocalAddress -in @('127.0.0.1','::1')) 'Listening-Socket ist nur Loopback'
        }
    }
    catch {
        Assert-True $false "Loopback-Listen-Bindung nicht prüfbar: $($_.Exception.Message)"
    }

    $rangeFile = Join-Path $temp 'range.bin'
    $rangeStatus = Invoke-TestCurl -Url $localUrl -Arguments @(
        '--silent','--show-error',
        '--header','Range: bytes=0-1023',
        '--output',$rangeFile,
        '--write-out','%{http_code}'
    )

    Assert-True (((($rangeStatus | Select-Object -Last 1) | Out-String).Trim()) -eq '206') 'Range liefert HTTP 206'
    $rangeLength=if(Test-Path -LiteralPath $rangeFile -PathType Leaf){(Get-Item -LiteralPath $rangeFile).Length}else{-1}
    Assert-True ($rangeLength -eq 1024) 'Range liefert exakt 1024 Bytes'

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
    $resumeHash=if(Test-Path -LiteralPath $resume -PathType Leaf){(Get-FileHash -LiteralPath $resume -Algorithm SHA256).Hash}else{''}
    Assert-True ($resumeHash -eq $originalHash) 'Fortgesetzter Download besitzt korrekten Hash'

    $beforeFiles = Get-RelativeFiles $temp
    $mutationBody = Join-Path ([IO.Path]::GetTempPath()) ('ws-mutation-' + [Guid]::NewGuid().ToString('N') + '.bin')
    foreach ($method in @('POST','PUT','PATCH','DELETE','PROPFIND','MKCOL','MOVE','COPY')) {
        $mutationOutput = Invoke-TestCurl -Url $localUrl -Arguments @(
            '--silent','--show-error',
            '--request',$method,
            '--header','Destination: /d/forbidden-target',
            '--data-binary','mutation-test',
            '--output',$mutationBody,
            '--write-out','%{http_code}'
        )
        $mutationStatus = 0
        [void][int]::TryParse((($mutationOutput | Select-Object -Last 1) | Out-String).Trim(), [ref]$mutationStatus)
        # Same contract as the launcher gate: explicit 4xx, or the unchanged file served as if it were a GET.
        $mutationBodyHash=if(Test-Path -LiteralPath $mutationBody -PathType Leaf){(Get-FileHash -LiteralPath $mutationBody -Algorithm SHA256).Hash}else{''}
        Remove-Item -LiteralPath $mutationBody -Force -ErrorAction SilentlyContinue
        Assert-True (($mutationStatus -ge 400 -and $mutationStatus -lt 500) -or ($mutationStatus -eq 200 -and $mutationBodyHash -eq $originalHash)) ("Mutation-Probe $method wird abgelehnt oder liefert nur die unveränderte Datei (HTTP $mutationStatus)")
    }
    $afterFiles = Get-RelativeFiles $temp

    Assert-True ((Get-FileHash -LiteralPath $sample -Algorithm SHA256).Hash -eq $originalHash) 'Mutation-Probes verändern die bereitgestellte Datei nicht'
    Assert-True (-not (Compare-Object $beforeFiles $afterFiles)) 'Mutation-Probes erzeugen keine zusätzlichen Dateien'

    $headers = Join-Path $temp 'local-headers.txt'
    [void](Invoke-TestCurl -Url $localUrl -Arguments @('--silent','--head','--dump-header',$headers,'--output','NUL'))
    $headerText = if(Test-Path -LiteralPath $headers -PathType Leaf){Get-Content -LiteralPath $headers -Raw}else{''}
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

    # ------------------------------------------------------------------
    # Ende-zu-Ende bis zum Snapshot (kein Netzwerk, kein miniserve/cloudflared)
    # ------------------------------------------------------------------
    Write-Host ''
    Write-Host 'Snapshot-Stufe und Event-Stream'
    Write-Host '-------------------------------'

    $snapshotWorkspace = Join-Path $temp 'snapshot-workspace'
    New-Item -ItemType Directory -Path (Join-Path $snapshotWorkspace 'sub') -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $snapshotWorkspace '.git') -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $snapshotWorkspace 'node_modules') -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $snapshotWorkspace 'hello.txt') -Value 'hello' -Encoding ASCII
    Set-Content -LiteralPath (Join-Path $snapshotWorkspace 'sub\readme.md') -Value '# readme' -Encoding ASCII
    Set-Content -LiteralPath (Join-Path $snapshotWorkspace 'sub\.npmrc') -Value 'registry=https://example.invalid/' -Encoding ASCII
    Set-Content -LiteralPath (Join-Path $snapshotWorkspace '.git\config') -Value '[core]' -Encoding ASCII
    Set-Content -LiteralPath (Join-Path $snapshotWorkspace 'node_modules\x.js') -Value 'x' -Encoding ASCII

    $keptSessionPath = $null
    try {
        # (a) Erfolgreicher Snapshot-Lauf; -KeepArchive erhält das ZIP für die Inhaltsprüfung.
        $runA = Invoke-ShareChild -Arguments @('-Path',$snapshotWorkspace,'-TestMode','-TestStopAfterSnapshot','-EventStream','-Minutes','1','-NoClipboard','-KeepArchive')
        $parsedA = Get-ShareEvents $runA.Lines
        $eventsA = @($parsedA.Events)
        $eventLinesA = @($runA.Lines | Where-Object { $_.StartsWith('@@WSEVENT@@ ') })
        # Remember the kept session first so cleanup works even if an assertion below throws.
        $earlySession = @($eventsA | Where-Object { $_.type -eq 'session' })
        if ($earlySession.Count -eq 1) { $keptSessionPath = [string]$earlySession[0].path }
        Assert-True ($runA.ExitCode -eq 0) "Snapshot-Lauf endet mit Exit 0 (war $($runA.ExitCode))"
        Assert-True ($eventLinesA.Count -gt 0 -and $parsedA.AllParsed -and $eventsA.Count -eq $eventLinesA.Count) 'Alle @@WSEVENT@@-Zeilen sind gültiges JSON'
        Assert-True (@($eventsA | Where-Object { $_.v -eq 1 -and $_.type -and $_.ts }).Count -eq $eventsA.Count) 'Jedes Event hat v=1, type und ts'
        Assert-True (@($eventsA | Where-Object { $_.type -eq 'start' }).Count -eq 1) 'Genau ein start-Event'
        $endedA = @($eventsA | Where-Object { $_.type -eq 'ended' })
        Assert-True ($endedA.Count -eq 1) 'Genau ein ended-Event'
        Assert-True ($endedA.Count -eq 1 -and $endedA[0].exitCode -eq 0 -and $endedA[0].reason -eq 'TestSnapshotOnly') 'ended-Event: exitCode 0, reason TestSnapshotOnly'
        Assert-True ($eventsA.Count -gt 0 -and $eventsA[$eventsA.Count - 1].type -eq 'ended') 'ended ist das letzte Event'
        $stepNumbers = @($eventsA | Where-Object { $_.type -eq 'step' } | ForEach-Object { [int]$_.n })
        Assert-True (@(@(1,2,3,4) | Where-Object { $_ -notin $stepNumbers }).Count -eq 0) 'step-Events 1..4 vorhanden'
        $sessionEvents = @($eventsA | Where-Object { $_.type -eq 'session' })
        Assert-True ($sessionEvents.Count -eq 1 -and [bool]$sessionEvents[0].path) 'session-Event mit Pfad vorhanden'
        Assert-True (@($eventsA | Where-Object { $_.type -eq 'ready' }).Count -eq 0) 'Kein ready-Event vor dem Tunnelstart'
        Assert-True (@($eventLinesA | Where-Object { $_ -cmatch '[^\x00-\x7E]' }).Count -eq 0) 'Event-Zeilen enthalten nur ASCII'
        Assert-True (@($runA.Lines | Where-Object { $_ -match 'trycloudflare\.com' }).Count -eq 0) 'Kein Tunnel-Link im Snapshot-Lauf'

        if ($sessionEvents.Count -eq 1) { $keptSessionPath = [string]$sessionEvents[0].path }
        $zipItem = $null
        if ($keptSessionPath -and (Test-Path -LiteralPath $keptSessionPath -PathType Container)) {
            $zipItem = Get-ChildItem -LiteralPath $keptSessionPath -Filter 'workspace-*.zip' -File | Select-Object -First 1
        }
        Assert-True ($null -ne $zipItem) '-KeepArchive erhält das ZIP im gemeldeten Sitzungsordner'
        if ($zipItem) {
            $sevenZip = Join-Path $bin '7za.exe'
            $zipListing = @(& $sevenZip l -ba $zipItem.FullName)
            Assert-True ($LASTEXITCODE -eq 0) '7-Zip kann das erhaltene ZIP auflisten'
            $zipText = ($zipListing -join "`n")
            Assert-True ($zipText -match '(?m)hello\.txt\s*$') 'Snapshot enthält hello.txt'
            Assert-True ($zipText -match '(?m)sub[\\/]readme\.md\s*$') 'Snapshot enthält sub\readme.md'
            Assert-True ($zipText -notmatch '\.npmrc') 'Snapshot enthält keine .npmrc'
            Assert-True ($zipText -notmatch '(?i)(^|[\s\\/])\.git([\\/]|\s|$)') 'Snapshot enthält kein .git'
            Assert-True ($zipText -notmatch 'node_modules') 'Snapshot enthält kein node_modules'
        }

        # (b) .env im Workspace -> Secret-Gate (Exit 22), ended-Event trägt denselben Code.
        $envWorkspace = Join-Path $temp 'snapshot-workspace-env'
        New-Item -ItemType Directory -Path $envWorkspace -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $envWorkspace 'hello.txt') -Value 'hello' -Encoding ASCII
        Set-Content -LiteralPath (Join-Path $envWorkspace '.env') -Value 'API_KEY=not-a-real-key' -Encoding ASCII
        $runB = Invoke-ShareChild -Arguments @('-Path',$envWorkspace,'-TestMode','-TestStopAfterSnapshot','-EventStream','-Minutes','1','-NoClipboard')
        $endedB = @((Get-ShareEvents $runB.Lines).Events | Where-Object { $_.type -eq 'ended' })
        Assert-True ($runB.ExitCode -eq 22) "Workspace mit .env endet mit Exit 22 (war $($runB.ExitCode))"
        Assert-True ($endedB.Count -eq 1 -and $endedB[0].exitCode -eq 22) 'ended-Event meldet exitCode 22 bei .env'

        # (c) -TestStopAfterSnapshot ohne -TestMode -> Exit 10.
        $runC = Invoke-ShareChild -Arguments @('-Path',$snapshotWorkspace,'-TestStopAfterSnapshot','-EventStream','-Minutes','1','-NoClipboard')
        $endedC = @((Get-ShareEvents $runC.Lines).Events | Where-Object { $_.type -eq 'ended' })
        Assert-True ($runC.ExitCode -eq 10) "-TestStopAfterSnapshot ohne -TestMode endet mit Exit 10 (war $($runC.ExitCode))"
        Assert-True ($endedC.Count -eq 1 -and $endedC[0].exitCode -eq 10) 'ended-Event meldet exitCode 10 ohne -TestMode'

        # (d) Nicht vorhandener Pfad -> Exit 10.
        $runD = Invoke-ShareChild -Arguments @('-Path',(Join-Path $temp 'does-not-exist'),'-TestMode','-TestStopAfterSnapshot','-EventStream','-Minutes','1','-NoClipboard')
        $endedD = @((Get-ShareEvents $runD.Lines).Events | Where-Object { $_.type -eq 'ended' })
        Assert-True ($runD.ExitCode -eq 10) "Nicht vorhandener Pfad endet mit Exit 10 (war $($runD.ExitCode))"
        Assert-True ($endedD.Count -eq 1 -and $endedD[0].exitCode -eq 10) 'ended-Event meldet exitCode 10 bei fehlendem Pfad'

        # (e) Ohne -EventStream erscheinen keine Event-Zeilen.
        $runE = Invoke-ShareChild -Arguments @('-Path',(Join-Path $temp 'does-not-exist'),'-Minutes','1','-NoClipboard')
        Assert-True ($runE.ExitCode -eq 10 -and @($runE.Lines | Where-Object { $_.StartsWith('@@WSEVENT@@') }).Count -eq 0) 'Ohne -EventStream werden keine Events ausgegeben'

        # (f) Elternprozess existiert nicht -> Exit 10.
        $runF = Invoke-ShareChild -Arguments @('-Path',$snapshotWorkspace,'-TestMode','-TestStopAfterSnapshot','-EventStream','-Minutes','1','-NoClipboard','-ParentProcessId','2147483000')
        Assert-True ($runF.ExitCode -eq 10) "Nicht vorhandene -ParentProcessId endet mit Exit 10 (war $($runF.ExitCode))"
    }
    finally {
        # Nur den eigenen, per Event gemeldeten Sitzungsordner unterhalb des Sitzungsbasisordners löschen.
        if ($keptSessionPath -and $env:LOCALAPPDATA) {
            $sessionRoot = [IO.Path]::GetFullPath((Join-Path $env:LOCALAPPDATA 'WorkspaceShare\sessions')).TrimEnd('\') + '\'
            $fullKept = [IO.Path]::GetFullPath($keptSessionPath)
            if ($fullKept.StartsWith($sessionRoot, [StringComparison]::OrdinalIgnoreCase) -and (Split-Path $fullKept -Leaf) -match '^\d{8}-\d{6}-[0-9a-f]{8}$') {
                Remove-Item -LiteralPath $fullKept -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
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
