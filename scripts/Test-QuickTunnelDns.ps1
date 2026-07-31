#requires -Version 5.1
[CmdletBinding()]
param([Parameter(Mandatory = $true)][string]$Hostname)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Resolve-Addresses {
    param([Parameter(Mandatory = $true)][string]$Name, [string]$Server)
    $addresses = @()
    foreach ($type in @('A', 'AAAA')) {
        try {
            $parameters = @{ Name = $Name; Type = $type; DnsOnly = $true; ErrorAction = 'Stop' }
            if ($Server) { $parameters.Server = $Server }
            $addresses += @(Resolve-DnsName @parameters | Where-Object { $_.IPAddress } | Select-Object -ExpandProperty IPAddress)
        }
        catch {}
    }
    return @($addresses | Select-Object -Unique)
}

$system = @(Resolve-Addresses -Name $Hostname)
$cloudflare = @(Resolve-Addresses -Name $Hostname -Server '1.1.1.1')
$google = @(Resolve-Addresses -Name $Hostname -Server '8.8.8.8')
$quad9 = @(Resolve-Addresses -Name $Hostname -Server '9.9.9.9')
[pscustomobject]@{ Hostname = '<redacted>.trycloudflare.com'; SystemResolved = ($system.Count -gt 0); CloudflareResolved = ($cloudflare.Count -gt 0); GoogleResolved = ($google.Count -gt 0); Quad9Resolved = ($quad9.Count -gt 0) } | Format-List
if ($system.Count -eq 0 -and ($cloudflare.Count -gt 0 -or $google.Count -gt 0 -or $quad9.Count -gt 0)) { Write-Error 'The configured system resolver returns no address while public resolvers do. Correct Windows/router DNS before acceptance testing.'; exit 2 }
if ($system.Count -eq 0) { Write-Error 'No tested resolver returned an address.'; exit 1 }
exit 0
