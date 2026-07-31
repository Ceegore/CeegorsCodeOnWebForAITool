#requires -Version 5.1
<#
.SYNOPSIS
    Monitors a live WorkspaceShare tunnel without retaining its secret URLs.

.EXAMPLE
    .\scripts\Test-TunnelSoak.ps1 -PublicUrl 'https://...trycloudflare.com/d/<token>/' `
        -LocalUrl 'http://127.0.0.1:12345/d/<token>/' -MetricsPort 12346 -Minutes 60
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$PublicUrl,
    [Parameter(Mandatory = $true)][string]$LocalUrl,
    [Parameter(Mandatory = $true)][ValidateRange(1, 65535)][int]$MetricsPort,
    [ValidateRange(1, 1440)][int]$Minutes = 60,
    [ValidateRange(5, 300)][int]$IntervalSeconds = 15,
    [string]$OutputPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$curl = (Get-Command curl.exe -ErrorAction Stop).Source

if ([string]::IsNullOrWhiteSpace($OutputPath)) {
    $OutputPath = Join-Path $PWD ("tunnel-soak-{0}.jsonl" -f [DateTime]::UtcNow.ToString('yyyyMMdd-HHmmss'))
}

function Invoke-Probe {
    param([string]$Url, [int]$TimeoutSeconds = 12, [string]$Range)
    $id = [Guid]::NewGuid().ToString('N')
    $root = [IO.Path]::GetTempPath()
    $body = Join-Path $root "ws-soak-body-$id.tmp"
    $headers = Join-Path $root "ws-soak-headers-$id.tmp"
    $errors = Join-Path $root "ws-soak-error-$id.tmp"
    try {
        $arguments = @('--silent', '--show-error', '--stderr', $errors, '--output', $body,
            '--dump-header', $headers, '--max-time', [string]$TimeoutSeconds,
            '--write-out', '%{http_code}|%{remote_ip}|%{time_total}')
        if ($Range) { $arguments += @('--range', $Range) }
        $arguments += $Url
        $raw = & $curl @arguments
        $exit = $LASTEXITCODE
        $parts = @(((($raw | Select-Object -Last 1) | Out-String).Trim()).Split('|'))
        $status = 0; if ($parts.Count -ge 1) { [void][int]::TryParse($parts[0], [ref]$status) }
        $remoteIp = if ($parts.Count -ge 2) { $parts[1] } else { '' }
        $seconds = 0.0; if ($parts.Count -ge 3) { [void][double]::TryParse($parts[2], [Globalization.NumberStyles]::Float, [Globalization.CultureInfo]::InvariantCulture, [ref]$seconds) }
        $bodyText = if (Test-Path $body) { Get-Content $body -Raw -ErrorAction SilentlyContinue } else { '' }
        $headerText = if (Test-Path $headers) { Get-Content $headers -Raw -ErrorAction SilentlyContinue } else { '' }
        $errorText = if (Test-Path $errors) { Get-Content $errors -Raw -ErrorAction SilentlyContinue } else { '' }
        $cfError = 0
        $match = [regex]::Match($bodyText, '(?i)(?:"code"\s*:\s*|\berror\s+)(10\d{2})|\b(1033)\b')
        if ($match.Success) { [void][int]::TryParse(($match.Groups[1].Value + $match.Groups[2].Value), [ref]$cfError) }
        $retryAfter = 0
        $retry = [regex]::Match($headerText, '(?im)^Retry-After:\s*(\d+)\s*$')
        if ($retry.Success) { [void][int]::TryParse($retry.Groups[1].Value, [ref]$retryAfter) }
        return [pscustomobject]@{ Exit = $exit; Status = $status; RemoteIp = $remoteIp; Seconds = $seconds; Error = ($errorText | Out-String).Trim(); CloudflareError = $cfError; RetryAfter = $retryAfter; Success = ($exit -eq 0 -and $status -in @(200, 206)); Body = $bodyText }
    }
    finally { Remove-Item $body,$headers,$errors -Force -ErrorAction SilentlyContinue }
}

function Get-DnsResults {
    param([string]$HostName)
    $rows = @()
    foreach ($resolver in @('system', '1.1.1.1', '8.8.8.8', '9.9.9.9')) {
        $addresses = @(); $errorText = ''
        try {
            $parameters = @{ Name = $HostName; Type = 'A'; DnsOnly = $true; ErrorAction = 'Stop' }
            if ($resolver -ne 'system') { $parameters.Server = $resolver }
            $addresses = @(Resolve-DnsName @parameters | Where-Object { $_.IPAddress } | Select-Object -ExpandProperty IPAddress -Unique)
        } catch { $errorText = $_.Exception.Message }
        $rows += [pscustomobject]@{ Resolver = $resolver; Success = ($addresses.Count -gt 0); Addresses = $addresses; Error = $errorText }
    }
    return $rows
}

$hostname = ([Uri]$PublicUrl).DnsSafeHost.ToLowerInvariant()
$deadline = [DateTime]::UtcNow.AddMinutes($Minutes)
$lastUtc = [DateTime]::UtcNow
$iteration = 0
Write-Host "Soak test: $hostname for $Minutes minute(s); output: $OutputPath"
Write-Host 'The output contains the hostname only, never either full secret URL.'

while ([DateTime]::UtcNow -lt $deadline) {
    $iteration++; $now = [DateTime]::UtcNow
    $gap = ($now - $lastUtc).TotalSeconds; $lastUtc = $now
    $local = Invoke-Probe -Url $LocalUrl -TimeoutSeconds 5 -Range '0-0'
    $ready = Invoke-Probe -Url "http://127.0.0.1:$MetricsPort/ready" -TimeoutSeconds 5
    $quick = Invoke-Probe -Url "http://127.0.0.1:$MetricsPort/quicktunnel" -TimeoutSeconds 5
    $public = Invoke-Probe -Url $PublicUrl -TimeoutSeconds 12 -Range '0-0'
    $readyConnections = 0; try { $readyConnections = [int](($ready.Body | ConvertFrom-Json).readyConnections) } catch {}
    $reportedHostname = ''; try { $reportedHostname = [string](($quick.Body | ConvertFrom-Json).hostname) } catch {}
    $dns = @(Get-DnsResults -HostName $hostname)
    $healthy = $local.Success -and $ready.Success -and $readyConnections -gt 0 -and $public.Success -and (-not $reportedHostname -or $reportedHostname.ToLowerInvariant() -eq $hostname)
    [ordered]@{ utc = $now.ToString('o'); iteration = $iteration; loopGapSeconds = [Math]::Round($gap, 3); hostname = $hostname; localSuccess = $local.Success; localStatus = $local.Status; readySuccess = $ready.Success; readyStatus = $ready.Status; readyConnections = $readyConnections; reportedHostname = $reportedHostname; publicSuccess = $public.Success; publicExit = $public.Exit; publicStatus = $public.Status; cloudflareError = $public.CloudflareError; retryAfter = $public.RetryAfter; remoteIp = $public.RemoteIp; publicSeconds = $public.Seconds; publicError = $public.Error; dns = $dns } | ConvertTo-Json -Depth 8 -Compress | Add-Content -LiteralPath $OutputPath -Encoding UTF8
    Write-Host ("[{0}] {1} local={2}/{3} ready={4}/{5}/{6} public={7}/{8}/cf{9} dns={10}/4 gap={11:N0}s" -f $now.ToLocalTime().ToString('HH:mm:ss'), $(if ($healthy) { 'HEALTHY' } else { 'FAILED' }), $local.Exit, $local.Status, $ready.Exit, $ready.Status, $readyConnections, $public.Exit, $public.Status, $public.CloudflareError, @($dns | Where-Object Success).Count, $gap)
    Start-Sleep -Seconds $IntervalSeconds
}

Write-Host "Soak test complete: $OutputPath"
