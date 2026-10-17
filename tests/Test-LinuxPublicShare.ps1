#requires -Version 5.1
<#
.SYNOPSIS
    Optional Linux check with a real Cloudflare Quick Tunnel (needs outbound network): one full share
    from start to a verified download and a clean stop. Run manually (workflow_dispatch input).
#>
[CmdletBinding()]
param([string]$ToolRoot, [int]$ReadyTimeoutSeconds = 360)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if ([string]::IsNullOrWhiteSpace($ToolRoot)) { $ToolRoot = Split-Path $PSScriptRoot -Parent }
if ([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT) { Write-Host '[SKIP] Test-LinuxPublicShare: nur unter Linux.'; exit 0 }

$script:Fail = 0
function Assert-True { param($Condition, [string]$Name) if ([bool]$Condition) { Write-Host "[PASS] $Name" } else { $script:Fail++; Write-Host "[FAIL] $Name" } }

$tmp = Join-Path ([IO.Path]::GetTempPath()) ('ws-public-' + [Guid]::NewGuid().ToString('N'))
$ws = Join-Path $tmp 'workspace'
[void](New-Item -ItemType Directory -Path (Join-Path $ws 'src') -Force)
Set-Content -LiteralPath (Join-Path $ws 'hello.txt') -Value 'hello from the Linux public share test'
$rng = New-Object byte[] (3MB)
[Security.Cryptography.RandomNumberGenerator]::Fill($rng)
[IO.File]::WriteAllBytes((Join-Path (Join-Path $ws 'src') 'random.bin'), $rng)

$psi = New-Object System.Diagnostics.ProcessStartInfo
$psi.FileName = Join-Path $PSHOME 'pwsh'
foreach ($a in @('-NoLogo', '-NoProfile', '-NonInteractive', '-File', (Join-Path $ToolRoot 'Share-Workspace.ps1'), '-Path', $ws, '-Minutes', '3', '-EventStream', '-NoClipboard')) { [void]$psi.ArgumentList.Add($a) }
$psi.UseShellExecute = $false
$psi.RedirectStandardOutput = $true
$psi.RedirectStandardError = $true
$launcher = New-Object System.Diagnostics.Process
$launcher.StartInfo = $psi
[void]$launcher.Start()
$errTask = $launcher.StandardError.ReadToEndAsync()
$events = New-Object System.Collections.Generic.List[object]
$sessionPath = $null
$ready = $null
$lines = New-Object System.Collections.Generic.List[string]
$readTask = $launcher.StandardOutput.ReadLineAsync()
$watch = [Diagnostics.Stopwatch]::StartNew()
try {
    while ($watch.Elapsed.TotalSeconds -lt $ReadyTimeoutSeconds -and $null -eq $ready) {
        if ($readTask.Wait(500)) {
            $line = $readTask.Result
            if ($null -eq $line) { break }
            $lines.Add($line)
            if ($line.StartsWith('@@WSEVENT@@ ')) {
                $e = $line.Substring(12) | ConvertFrom-Json
                $events.Add($e)
                if ($e.type -eq 'session') { $sessionPath = [string]$e.path }
                if ($e.type -eq 'step') { Write-Host ('       step {0}/{1}: {2}' -f $e.n, $e.total, $e.text) }
                if ($e.type -eq 'ready') { $ready = $e }
                if ($e.type -eq 'ended') { break }
            }
            else { Write-Host ('       | ' + $line) }
            $readTask = $launcher.StandardOutput.ReadLineAsync()
        }
    }
    Assert-True ($null -ne $ready) ('share became ready within ' + [int]$watch.Elapsed.TotalSeconds + ' s')
    if ($null -eq $ready) {
        Write-Host ('       last output: ' + (($lines | Select-Object -Last 15) -join "`n       "))
        [void]$launcher.WaitForExit(20000)
        [void]$errTask.Wait(5000)
        Write-Host ('       stderr: ' + $(if ($errTask.IsCompleted) { $errTask.Result } else { '(still running)' }))
    }
    else {
        $url = [string]$ready.url
        Assert-True ($url -match '^https://[a-z0-9-]+\.trycloudflare\.com/d/[A-Za-z0-9_-]{43}/$') 'ready event carries a Quick Tunnel URL with a 256-bit token'
        $zip = Join-Path $tmp 'download.zip'
        & curl --silent --show-error --max-time 120 --output $zip $url
        Assert-True ($LASTEXITCODE -eq 0 -and (Test-Path -LiteralPath $zip)) 'full download through the tunnel works'
        if (Test-Path -LiteralPath $zip) {
            $hash = (Get-FileHash -LiteralPath $zip -Algorithm SHA256).Hash
            Assert-True ($hash -eq [string]$ready.sha256) 'downloaded ZIP matches the announced SHA-256'
        }
        $range = & curl --silent --show-error --max-time 60 --header 'Range: bytes=0-99' --output /dev/null --write-out '%{http_code}' $url
        Assert-True ($range -eq '206') 'range request through the tunnel -> 206'
        $root = $url.Substring(0, $url.IndexOf('/d/') + 1)
        $deny = & curl --silent --max-time 30 --output /dev/null --write-out '%{http_code}' $root
        Assert-True ($deny -in @('401', '403', '404')) "tunnel root without token is refused ($deny)"
        # cooperative stop through the stop marker (what the GUI and Stop-WorkspaceShare do)
        if ($sessionPath) { [void](New-Item -ItemType File -Path (Join-Path $sessionPath 'stop.requested') -Force) }
        Assert-True ($launcher.WaitForExit(120000)) 'launcher ends after the stop marker'
        if ($launcher.HasExited) { Assert-True ($launcher.ExitCode -eq 0) ('launcher exit code 0 (was ' + $launcher.ExitCode + ')') }
    }
}
finally {
    if (-not $launcher.HasExited) { try { $launcher.Kill($true) } catch { } }
    Start-Sleep -Seconds 2
    $leftovers = @(Get-Process -ErrorAction SilentlyContinue | Where-Object { $_.ProcessName -in @('cloudflared', 'miniserve') })
    Assert-True ($leftovers.Count -eq 0) ('no cloudflared/miniserve process is left (' + $leftovers.Count + ')')
    foreach ($p in $leftovers) { try { $p.Kill() } catch { } }
    if ($sessionPath) { Assert-True (-not (Test-Path -LiteralPath $sessionPath)) 'session folder was cleaned up' }
    Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
}
Write-Host ("Failed: {0}" -f $script:Fail)
if ($script:Fail -gt 0) { exit 1 }
exit 0
