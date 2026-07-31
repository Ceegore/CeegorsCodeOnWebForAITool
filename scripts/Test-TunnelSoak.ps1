#requires -Version 5.1
<#
.SYNOPSIS
    Performs an acceptance soak test without placing capability URLs in examples.
.EXAMPLE
    .\scripts\Test-TunnelSoak.ps1 -MetricsPort 12346 -Minutes 60
#>
[CmdletBinding()]
param(
    [string]$PublicUrl,
    [string]$LocalUrl,
    [Parameter(Mandatory = $true)][ValidateRange(1, 65535)][int]$MetricsPort,
    [ValidateRange(1, 1440)][int]$Minutes = 60,
    [ValidateRange(5, 300)][int]$IntervalSeconds = 15,
    [ValidateRange(0, 3600)][int]$MaximumAllowedOutageSeconds = 0,
    [string]$OutputPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$curl = (Get-Command curl.exe -ErrorAction Stop).Source

function Read-SecretString {
    param([Parameter(Mandatory = $true)][string]$Prompt)
    $secure = Read-Host $Prompt -AsSecureString
    $pointer = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
    try { return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($pointer) }
    finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($pointer) }
}

function Protect-DiagnosticText {
    param([AllowNull()][string]$Text, [string[]]$KnownSecretUrls = @())
    if ([string]::IsNullOrEmpty($Text)) { return '' }
    $safe = $Text
    foreach ($url in @($KnownSecretUrls)) { if ($url) { $safe = $safe.Replace($url, 'https://<redacted>.trycloudflare.com/d/<redacted>/') } }
    $safe = $safe -replace '(?i)\b[a-z0-9-]+\.trycloudflare\.com\b', '<redacted>.trycloudflare.com'
    $safe = $safe -replace '(?i)/d/[A-Za-z0-9_-]{43}(?=/|\s|"|''|$)', '/d/<redacted>'
    $safe = $safe -replace '(?i)%2Fd%2F[A-Za-z0-9_-]{43}', '%2Fd%2F<redacted>'
    return $safe
}

if ([string]::IsNullOrWhiteSpace($PublicUrl)) { $PublicUrl = [Environment]::GetEnvironmentVariable('WORKSPACESHARE_PUBLIC_URL', 'Process') }
if ([string]::IsNullOrWhiteSpace($LocalUrl)) { $LocalUrl = [Environment]::GetEnvironmentVariable('WORKSPACESHARE_LOCAL_URL', 'Process') }
if ([string]::IsNullOrWhiteSpace($PublicUrl)) { $PublicUrl = Read-SecretString -Prompt 'Paste the public WorkspaceShare URL' }
if ([string]::IsNullOrWhiteSpace($LocalUrl)) { $LocalUrl = Read-SecretString -Prompt 'Paste the local WorkspaceShare URL' }

if ([string]::IsNullOrWhiteSpace($OutputPath)) { $OutputPath = Join-Path $PWD ("tunnel-soak-{0}.jsonl" -f [DateTime]::UtcNow.ToString('yyyyMMdd-HHmmss')) }

function Invoke-Probe {
    param([string]$Url, [int]$TimeoutSeconds = 12, [string]$Range, [int]$ExpectedBytes = 0)
    $id = [Guid]::NewGuid().ToString('N'); $root = [IO.Path]::GetTempPath()
    $body = Join-Path $root "ws-soak-body-$id.tmp"; $headers = Join-Path $root "ws-soak-headers-$id.tmp"; $errors = Join-Path $root "ws-soak-error-$id.tmp"
    try {
        $arguments = @('--silent', '--show-error', '--stderr', $errors, '--output', $body, '--dump-header', $headers, '--max-time', [string]$TimeoutSeconds, '--max-filesize', '65536', '--write-out', '%{http_code}|%{remote_ip}|%{time_total}')
        if ($Range) { $arguments += @('--range', $Range) }; $arguments += $Url
        $raw = & $curl @arguments; $exit = $LASTEXITCODE; $parts = @(((($raw | Select-Object -Last 1) | Out-String).Trim()).Split('|'))
        $status = 0; if ($parts.Count -ge 1) { [void][int]::TryParse($parts[0], [ref]$status) }
        $remoteIp = if ($parts.Count -ge 2) { $parts[1] } else { '' }; $seconds = 0.0; if ($parts.Count -ge 3) { [void][double]::TryParse($parts[2], [Globalization.NumberStyles]::Float, [Globalization.CultureInfo]::InvariantCulture, [ref]$seconds) }
        $actualBytes = if (Test-Path $body) { [int](Get-Item $body).Length } else { 0 }; $sha256 = if ($actualBytes -gt 0) { (Get-FileHash $body -Algorithm SHA256).Hash } else { '' }
        $headerText = if (Test-Path $headers) { [string](Get-Content $headers -Raw -ErrorAction SilentlyContinue) } else { '' }; $errorText = if (Test-Path $errors) { [string](Get-Content $errors -Raw -ErrorAction SilentlyContinue) } else { '' }
        $contentRange = ''; $rangeMatch = [regex]::Match($headerText, '(?im)^Content-Range:\s*([^\r\n]+)'); if ($rangeMatch.Success) { $contentRange = $rangeMatch.Groups[1].Value.Trim() }
        $retryAfter = 0; $retry = [regex]::Match($headerText, '(?im)^Retry-After:\s*(\d+)\s*$'); if ($retry.Success) { [void][int]::TryParse($retry.Groups[1].Value, [ref]$retryAfter) }
        $cfError = 0; $bodyText = if (Test-Path $body) { [string](Get-Content $body -Raw -ErrorAction SilentlyContinue) } else { '' }; $match = [regex]::Match($bodyText, '(?i)(?:"code"\s*:\s*|\berror\s+)(10\d{2})|\b(1033)\b'); if ($match.Success) { [void][int]::TryParse(($match.Groups[1].Value + $match.Groups[2].Value), [ref]$cfError) }
        $sampleValid = if ($ExpectedBytes -gt 0) { $exit -eq 0 -and $status -eq 206 -and $actualBytes -eq $ExpectedBytes -and $contentRange -match '^bytes\s+0-' } else { $exit -eq 0 -and $status -in @(200,206) }
        return [pscustomobject]@{ Exit=$exit; Status=$status; RemoteIp=$remoteIp; Seconds=$seconds; Error=(Protect-DiagnosticText -Text (($errorText | Out-String).Trim()) -KnownSecretUrls @($PublicUrl,$LocalUrl)); CloudflareError=$cfError; RetryAfter=$retryAfter; ActualBytes=$actualBytes; Sha256=$sha256; SampleValid=$sampleValid; Body=(Protect-DiagnosticText -Text $bodyText -KnownSecretUrls @($PublicUrl,$LocalUrl)) }
    }
    finally { Remove-Item $body,$headers,$errors -Force -ErrorAction SilentlyContinue }
}

$hostname = ([Uri]$PublicUrl).DnsSafeHost.ToLowerInvariant(); $sampleBytes = 32; $sampleRange = '0-31'; $deadline = [DateTime]::UtcNow.AddMinutes($Minutes); $lastUtc = [DateTime]::UtcNow; $iteration = 0; $totalSamples = 0; $failedSamples = 0; $currentOutageStartedUtc = $null; $longestOutageSeconds = 0.0
Write-Host "Soak test: $hostname for $Minutes minute(s); output: $OutputPath"
while ([DateTime]::UtcNow -lt $deadline) {
    $iteration++; $totalSamples++; $now = [DateTime]::UtcNow; $gap = ($now - $lastUtc).TotalSeconds; $lastUtc = $now
    $local = Invoke-Probe -Url $LocalUrl -TimeoutSeconds 5 -Range $sampleRange -ExpectedBytes $sampleBytes
    $ready = Invoke-Probe -Url "http://127.0.0.1:$MetricsPort/ready" -TimeoutSeconds 5
    $quick = Invoke-Probe -Url "http://127.0.0.1:$MetricsPort/quicktunnel" -TimeoutSeconds 5
    $public = Invoke-Probe -Url $PublicUrl -TimeoutSeconds 12 -Range $sampleRange -ExpectedBytes $sampleBytes
    $readyConnections = 0; try { $readyConnections = [int](($ready.Body | ConvertFrom-Json).readyConnections) } catch {}; $reportedHostname = ''; try { $reportedHostname = [string](($quick.Body | ConvertFrom-Json).hostname) } catch {}
    $healthy = $local.SampleValid -and $public.SampleValid -and $local.Sha256 -eq $public.Sha256
    if ($healthy) { if ($currentOutageStartedUtc) { $longestOutageSeconds = [Math]::Max($longestOutageSeconds, ($now - $currentOutageStartedUtc).TotalSeconds); $currentOutageStartedUtc = $null } } else { $failedSamples++; if (-not $currentOutageStartedUtc) { $currentOutageStartedUtc = $now } }
    [ordered]@{utc=$now.ToString('o');iteration=$iteration;loopGapSeconds=[Math]::Round($gap,3);hostname=$hostname;localSampleValid=$local.SampleValid;localStatus=$local.Status;readySuccess=($ready.Status -eq 200);readyConnections=$readyConnections;reportedHostname=$reportedHostname;publicSampleValid=$public.SampleValid;publicExit=$public.Exit;publicStatus=$public.Status;cloudflareError=$public.CloudflareError;retryAfter=$public.RetryAfter;remoteIp=$public.RemoteIp;publicSeconds=$public.Seconds;publicError=$public.Error} | ConvertTo-Json -Depth 6 -Compress | Add-Content -LiteralPath $OutputPath -Encoding UTF8
    Write-Host ("[{0}] {1} local={2}/{3} ready={4}/{5} public={6}/{7}/cf{8} gap={9:N0}s" -f $now.ToLocalTime().ToString('HH:mm:ss'), $(if($healthy){'HEALTHY'}else{'FAILED'}),$local.SampleValid,$local.Status,$ready.Status,$readyConnections,$public.SampleValid,$public.Status,$public.CloudflareError,$gap)
    Start-Sleep -Seconds $IntervalSeconds
}
if ($currentOutageStartedUtc) { $longestOutageSeconds = [Math]::Max($longestOutageSeconds, ([DateTime]::UtcNow - $currentOutageStartedUtc).TotalSeconds) }
Write-Host ("Samples: {0}; failed: {1}; longest outage: {2:N0}s" -f $totalSamples,$failedSamples,$longestOutageSeconds)
if ($failedSamples -gt 0 -or $longestOutageSeconds -gt $MaximumAllowedOutageSeconds) { exit 1 }
exit 0
