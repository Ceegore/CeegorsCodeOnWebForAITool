Set-StrictMode -Version Latest

function Get-HealthSamplePlan {
    param(
        [Parameter(Mandatory = $true)][ValidateRange(1, 9223372036854775807)][int64]$ArchiveSize,
        [ValidateRange(16, 4096)][int]$PreferredSampleBytes = 64
    )

    $length = [int][Math]::Min([int64]$PreferredSampleBytes, $ArchiveSize)
    $maximumStart = [Math]::Max([int64]0, $ArchiveSize - $length)
    $middleStart = [int64][Math]::Floor($maximumStart / 2)
    foreach ($start in @([int64]0, $middleStart, $maximumStart | Select-Object -Unique)) {
        [pscustomobject]@{
            Start = [int64]$start
            Length = $length
            End = [int64]($start + $length - 1)
            AllowFullFileResponse = ($start -eq 0 -and $length -eq $ArchiveSize)
        }
    }
}

function Get-BoundedRetryAfterSeconds {
    param([int]$RetryAfterSeconds, [ValidateRange(0, 86400)][int]$MaximumRetryAfterSeconds = 600)
    return [Math]::Min($MaximumRetryAfterSeconds, [Math]::Max(0, $RetryAfterSeconds))
}

function Get-AllowedOutageSeconds {
    param([Parameter(Mandatory = $true)][string]$Classification, [int]$RetryAfterSeconds = 0)
    $retryAfter = Get-BoundedRetryAfterSeconds -RetryAfterSeconds $RetryAfterSeconds
    switch ($Classification) {
        'HostnameChanged' { return 30 }
        'LocalOriginFailure' { return 45 }
        'DnsMissing' { return 90 }
        'DnsResolutionFailure' { return 90 }
        'EdgeDisconnected' { return 150 }
        'NoHealthyConnector' { return [Math]::Max(150, $retryAfter + 30) }
        'RateLimited' { return [Math]::Max(300, $retryAfter + 60) }
        'CloudflareProxyFailure' { return 120 }
        default { return 120 }
    }
}

function Get-TunnelClassification {
    param(
        [bool]$LocalSampleValid,
        [bool]$EndToEndSampleValid,
        [bool]$HostnameAvailable,
        [bool]$HostnameMatches,
        [int]$PublicHttpStatus,
        [int]$CloudflareError,
        [int]$PublicCurlExit,
        [bool]$OverrideDiagnosticSuccess,
        [int]$PublicDnsSuccessCount,
        [bool]$DnsChecked = $false,
        [bool]$SystemDnsSuccess = $false,
        [bool]$Ready
    )

    if (-not $LocalSampleValid) { return 'LocalOriginFailure' }
    if ($EndToEndSampleValid) { return 'Healthy' }
    if ($HostnameAvailable -and -not $HostnameMatches) { return 'HostnameChanged' }
    if ($PublicHttpStatus -eq 429 -or $CloudflareError -eq 1015) { return 'RateLimited' }
    if ($CloudflareError -eq 1033) { return 'NoHealthyConnector' }
    if ($PublicCurlExit -eq 6 -and -not $SystemDnsSuccess -and ($PublicDnsSuccessCount -gt 0 -or $OverrideDiagnosticSuccess)) { return 'DnsResolutionFailure' }
    if ($PublicCurlExit -eq 6 -and $DnsChecked -and -not $SystemDnsSuccess -and $PublicDnsSuccessCount -eq 0) { return 'DnsMissing' }
    if (-not $Ready) { return 'EdgeDisconnected' }
    if ($PublicHttpStatus -eq 502 -or ($PublicHttpStatus -eq 530 -and $CloudflareError -ne 1033)) { return 'CloudflareProxyFailure' }
    return 'PublicTransportFailure'
}

Export-ModuleMember -Function @('Get-HealthSamplePlan', 'Get-BoundedRetryAfterSeconds', 'Get-AllowedOutageSeconds', 'Get-TunnelClassification')
