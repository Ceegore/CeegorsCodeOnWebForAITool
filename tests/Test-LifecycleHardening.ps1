#requires -Version 5.1
[CmdletBinding()]
param([string]$ToolRoot)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if ([string]::IsNullOrWhiteSpace($ToolRoot)) { $ToolRoot = Split-Path $PSScriptRoot -Parent }
$failed = 0
function Assert-True { param([bool]$Condition,[string]$Message) if($Condition){Write-Host "[PASS] $Message"}else{Write-Host "[FAIL] $Message" -ForegroundColor Red;$script:failed++} }

$processModule = Join-Path $ToolRoot 'scripts\WorkspaceShare.Process.psm1'
$curlModule = Join-Path $ToolRoot 'scripts\WorkspaceShare.Curl.psm1'
$healthModule = Join-Path $ToolRoot 'scripts\WorkspaceShare.Health.psm1'
Assert-True (Test-Path -LiteralPath $processModule -PathType Leaf) 'Shared process module exists'
Assert-True (Test-Path -LiteralPath $curlModule -PathType Leaf) 'Shared curl module exists'
Import-Module $processModule -Force
Import-Module $curlModule -Force
Import-Module $healthModule -Force

$absent = Get-ProcessIdentityState -ProcessId 2147483647 -ExpectedPath $PSHOME -ExpectedStartTicks 1
Assert-True ($absent.State -eq 'Absent') 'Missing process is distinguished from uncertainty'

$child = Start-Process -FilePath (Join-Path $PSHOME 'powershell.exe') -ArgumentList @('-NoProfile','-Command','Start-Sleep -Seconds 60') -PassThru
try {
    Start-Sleep -Milliseconds 200
    $ticks = $child.StartTime.ToUniversalTime().Ticks
    $state = Get-ProcessIdentityState -ProcessId $child.Id -ExpectedPath $child.Path -ExpectedStartTicks $ticks
    Assert-True ($state.State -eq 'Match') 'Tracked child process identity matches'
    Assert-True (Stop-TrackedProcessConfirmed -ProcessId $child.Id -ExpectedPath $child.Path -ExpectedStartTicks $ticks -Attempts 5 -WaitMilliseconds 200) 'Tracked child process is confirmed stopped'
} finally { try { if(-not $child.HasExited){Stop-Process -Id $child.Id -Force} } catch{}; try{$child.Dispose()}catch{} }

$watchSession = Join-Path ([IO.Path]::GetTempPath()) ('WorkspaceShare-watch-' + [Guid]::NewGuid().ToString('N'))
$watchCloud = $null; $watchServer = $null; $watchdog = $null
try {
    New-Item -ItemType Directory -Path $watchSession -Force | Out-Null
    $shell = Join-Path $PSHOME 'powershell.exe'
    $watchCloud = Start-Process -FilePath $shell -ArgumentList @('-NoProfile','-Command','Start-Sleep -Seconds 60') -PassThru
    $watchServer = Start-Process -FilePath $shell -ArgumentList @('-NoProfile','-Command','Start-Sleep -Seconds 60') -PassThru
    $parent = Get-Process -Id $PID
    $watchScript = Join-Path $ToolRoot 'scripts\Watch-WorkspaceShare.ps1'
    $watchdog = Start-Process -FilePath $shell -ArgumentList @('-NoProfile','-File',$watchScript,'-ParentPid',$PID,'-ParentStartTicks',$parent.StartTime.ToUniversalTime().Ticks,'-ExpectedParentPath',$parent.Path,'-MiniservePid',$watchServer.Id,'-MiniserveStartTicks',$watchServer.StartTime.ToUniversalTime().Ticks,'-CloudflaredPid',$watchCloud.Id,'-CloudflaredStartTicks',$watchCloud.StartTime.ToUniversalTime().Ticks,'-SessionPath',$watchSession,'-NormalExitMarker',(Join-Path $watchSession 'normal.exit'),'-ReadyMarker',(Join-Path $watchSession 'watch.ready'),'-ExpiresUtc',([DateTime]::UtcNow.AddSeconds(1).ToString('o')),'-ExpectedMiniservePath',$watchServer.Path,'-ExpectedCloudflaredPath',$watchCloud.Path) -PassThru
    $readyDeadline = [DateTime]::UtcNow.AddSeconds(5)
    while(-not (Test-Path -LiteralPath (Join-Path $watchSession 'watch.ready')) -and [DateTime]::UtcNow -lt $readyDeadline){Start-Sleep -Milliseconds 100}
    Assert-True (Test-Path -LiteralPath (Join-Path $watchSession 'watch.ready')) 'Watchdog publishes readiness before monitoring'
    [void]$watchdog.WaitForExit(10000); $watchCloud.Refresh(); $watchServer.Refresh()
    Assert-True ($watchdog.HasExited -and $watchCloud.HasExited -and $watchServer.HasExited) 'Watchdog retires tracked children at expiry'
} finally { foreach($process in @($watchdog,$watchCloud,$watchServer)){try{if($process -and -not $process.HasExited){Stop-Process -Id $process.Id -Force}}catch{};try{if($process){$process.Dispose()}}catch{}}; Remove-Item -LiteralPath $watchSession -Recurse -Force -ErrorAction SilentlyContinue }

$token = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
$safe = WorkspaceShare.Curl\Protect-DiagnosticText -Text ("https://x.trycloudflare.com/d/{0} %2Fd%2F{0}" -f $token) -KnownSecretUrls @()
Assert-True ($safe -notmatch [regex]::Escape($token)) 'Curl diagnostic sanitizer redacts capability routes'

$classification = Get-TunnelClassification -LocalSampleValid $true -EndToEndSampleValid $false -HostnameAvailable $true -HostnameMatches $true -PublicHttpStatus 0 -CloudflareError 0 -PublicCurlExit 6 -OverrideDiagnosticSuccess $false -PublicDnsSuccessCount 0 -DnsChecked $true -SystemDnsSuccess $true -Ready $true -PublicSampleValid $false
Assert-True ($classification -ne 'DnsMissing') 'Working system DNS is not misclassified as missing'
$classification = Get-TunnelClassification -LocalSampleValid $true -EndToEndSampleValid $false -HostnameAvailable $true -HostnameMatches $true -PublicHttpStatus 0 -CloudflareError 0 -PublicCurlExit 6 -OverrideDiagnosticSuccess $false -PublicDnsSuccessCount 0 -DnsChecked $true -SystemDnsSuccess $false -Ready $true -PublicSampleValid $false
Assert-True ($classification -eq 'DnsMissing') 'All failed DNS paths are classified as missing'

$temporary = Join-Path ([IO.Path]::GetTempPath()) ('WorkspaceShare-lock-' + [Guid]::NewGuid().ToString('N'))
try {
    [IO.File]::WriteAllText($temporary, 'verified bytes')
    $lock = New-Object IO.FileStream($temporary,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)
    try { $blocked = $false; try { $writer = New-Object IO.FileStream($temporary,[IO.FileMode]::Open,[IO.FileAccess]::Write,[IO.FileShare]::ReadWrite); $writer.Dispose() } catch { $blocked = $true }; Assert-True $blocked 'Archive read lock prevents concurrent writes' } finally { $lock.Dispose() }
} finally { Remove-Item -LiteralPath $temporary -Force -ErrorAction SilentlyContinue }

if($failed -gt 0){exit 1}
