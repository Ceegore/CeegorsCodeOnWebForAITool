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
$jobModule = Join-Path $ToolRoot 'scripts\WorkspaceShare.Job.psm1'
$pathModule = Join-Path $ToolRoot 'scripts\WorkspaceShare.Path.psm1'
Assert-True (Test-Path -LiteralPath $processModule -PathType Leaf) 'Shared process module exists'
Assert-True (Test-Path -LiteralPath $curlModule -PathType Leaf) 'Shared curl module exists'
Assert-True (Test-Path -LiteralPath $jobModule -PathType Leaf) 'Shared Job Object module exists'
Assert-True (Test-Path -LiteralPath $pathModule -PathType Leaf) 'Shared canonical path module exists'
Import-Module $processModule -Force
Import-Module $curlModule -Force
Import-Module $healthModule -Force
Import-Module $jobModule -Force
Import-Module $pathModule -Force

$absent = Get-ProcessIdentityState -ProcessId 2147483647 -ExpectedPath $PSHOME -ExpectedStartTicks 1
Assert-True ($absent.State -eq 'Absent') 'Missing process is distinguished from uncertainty'
$self = Get-Process -Id $PID
for ($index = 0; $index -lt 100; $index++) { [void](Get-ProcessIdentityState -ProcessId $PID -ExpectedPath $self.Path -ExpectedStartTicks $self.StartTime.ToUniversalTime().Ticks) }
[GC]::Collect(); [GC]::WaitForPendingFinalizers(); $self.Refresh()
$handleCountBefore = $self.HandleCount
for ($index = 0; $index -lt 10000; $index++) {
    $identity = Get-ProcessIdentityState -ProcessId $PID -ExpectedPath $self.Path -ExpectedStartTicks $self.StartTime.ToUniversalTime().Ticks
    if ($identity.State -ne 'Match') { throw 'Process identity stress check returned a non-match.' }
}
$self.Refresh()
[GC]::Collect(); [GC]::WaitForPendingFinalizers(); $self.Refresh()
$handleDelta = $self.HandleCount - $handleCountBefore
Assert-True ($handleDelta -lt 250) ("10,000 identity checks do not accumulate handles (delta {0})" -f $handleDelta)
$self.Dispose()
$canonicalA = Resolve-WorkspaceDirectoryIdentity -Path $ToolRoot
$canonicalB = Resolve-WorkspaceDirectoryIdentity -Path (Join-Path $ToolRoot '.')
Assert-True ($canonicalA.Identity -eq $canonicalB.Identity -and $canonicalA.FinalPath -eq $canonicalB.FinalPath) 'Canonical directory identity collapses lexical aliases'

$killJob=New-WorkspaceJob -Name ('Local\WorkspaceShare.KillTest.'+[Guid]::NewGuid().ToString('N'))
$killChild=Start-Process -FilePath (Join-Path $PSHOME 'powershell.exe') -ArgumentList @('-NoProfile','-Command','Start-Sleep -Seconds 60') -PassThru
try{Add-ProcessToWorkspaceJob -Job $killJob -ProcessId $killChild.Id;Close-WorkspaceJob -Job $killJob;$killJob=[IntPtr]::Zero;[void]$killChild.WaitForExit(5000);Assert-True $killChild.HasExited 'Kill-on-close Job Object retires a child after owner loss'}finally{if($killJob -ne [IntPtr]::Zero){try{Close-WorkspaceJob -Job $killJob}catch{}};try{if(-not$killChild.HasExited){$killChild.Kill()}}catch{};try{$killChild.Dispose()}catch{}}

$atomicJob=New-WorkspaceJob -Name ('Local\WorkspaceShare.AtomicTest.'+[Guid]::NewGuid().ToString('N'))
$atomicOut=Join-Path ([IO.Path]::GetTempPath()) ('WorkspaceShare-atomic-'+[Guid]::NewGuid().ToString('N')+'.out')
$atomicErr=$atomicOut+'.err';$atomicChild=$null
try{$atomicChild=Start-WorkspaceProcessInJob -Job $atomicJob -FilePath (Join-Path $PSHOME 'powershell.exe') -Arguments @('-NoProfile','-Command','Write-Output atomic-output') -WorkingDirectory $ToolRoot -StdOutPath $atomicOut -StdErrPath $atomicErr;[void]$atomicChild.WaitForExit(5000);$atomicText=(Get-Content -LiteralPath $atomicOut -Raw -ErrorAction SilentlyContinue).Trim();Assert-True ($atomicChild.HasExited -and $atomicText -eq 'atomic-output') 'Suspended Job launch inherits bounded output handles and resumes'}finally{try{Stop-WorkspaceJob $atomicJob}catch{};try{Close-WorkspaceJob $atomicJob}catch{};try{if($atomicChild){$atomicChild.Dispose()}}catch{};Remove-Item -LiteralPath $atomicOut,$atomicErr -Force -ErrorAction SilentlyContinue}

$child = Start-Process -FilePath (Join-Path $PSHOME 'powershell.exe') -ArgumentList @('-NoProfile','-Command','Start-Sleep -Seconds 60') -PassThru
try {
    Start-Sleep -Milliseconds 200
    $ticks = $child.StartTime.ToUniversalTime().Ticks
    $state = Get-ProcessIdentityState -ProcessId $child.Id -ExpectedPath $child.Path -ExpectedStartTicks $ticks
    Assert-True ($state.State -eq 'Match') 'Tracked child process identity matches'
    Assert-True (Stop-TrackedProcessConfirmed -ProcessId $child.Id -ExpectedPath $child.Path -ExpectedStartTicks $ticks -Attempts 5 -WaitMilliseconds 200) 'Tracked child process is confirmed stopped'
} finally { try { if(-not $child.HasExited){Stop-Process -Id $child.Id -Force} } catch{}; try{$child.Dispose()}catch{} }

$watchSession = Join-Path ([IO.Path]::GetTempPath()) ('WorkspaceShare-watch-' + [Guid]::NewGuid().ToString('N'))
$watchCloud = $null; $watchServer = $null; $watchdog = $null; $job=[IntPtr]::Zero
try {
    New-Item -ItemType Directory -Path $watchSession -Force | Out-Null
    $shell = Join-Path $PSHOME 'powershell.exe'
    $watchCloud = Start-Process -FilePath $shell -ArgumentList @('-NoProfile','-Command','Start-Sleep -Seconds 60') -PassThru
    $watchServer = Start-Process -FilePath $shell -ArgumentList @('-NoProfile','-Command','Start-Sleep -Seconds 60') -PassThru
    $jobName='Local\WorkspaceShare.Test.'+[Guid]::NewGuid().ToString('N');$job=New-WorkspaceJob -Name $jobName;Add-ProcessToWorkspaceJob -Job $job -ProcessId $watchCloud.Id;Add-ProcessToWorkspaceJob -Job $job -ProcessId $watchServer.Id
    $archive=Join-Path $watchSession 'archive.zip';[IO.File]::WriteAllText($archive,'test')
    $parent = Get-Process -Id $PID
    $watchScript = Join-Path $ToolRoot 'scripts\Watch-WorkspaceShare.ps1'
    $watchdog = Start-Process -FilePath $shell -ArgumentList @('-NoProfile','-File',$watchScript,'-ParentPid',$PID,'-ParentStartTicks',$parent.StartTime.ToUniversalTime().Ticks,'-ExpectedParentPath',$parent.Path,'-MiniservePid',$watchServer.Id,'-MiniserveStartTicks',$watchServer.StartTime.ToUniversalTime().Ticks,'-CloudflaredPid',$watchCloud.Id,'-CloudflaredStartTicks',$watchCloud.StartTime.ToUniversalTime().Ticks,'-SessionPath',$watchSession,'-ArchivePath',$archive,'-JobName',$jobName,'-NormalExitMarker',(Join-Path $watchSession 'normal.exit'),'-ReadyMarker',(Join-Path $watchSession 'watch.ready'),'-ExpiresUtc',([DateTime]::UtcNow.AddSeconds(1).ToString('o')),'-ExpectedMiniservePath',$watchServer.Path,'-ExpectedCloudflaredPath',$watchCloud.Path) -PassThru
    $readyDeadline = [DateTime]::UtcNow.AddSeconds(5)
    while(-not (Test-Path -LiteralPath (Join-Path $watchSession 'watch.ready')) -and [DateTime]::UtcNow -lt $readyDeadline){Start-Sleep -Milliseconds 100}
    Assert-True (Test-Path -LiteralPath (Join-Path $watchSession 'watch.ready')) 'Watchdog publishes readiness before monitoring'
    [void]$watchdog.WaitForExit(10000); $watchCloud.Refresh(); $watchServer.Refresh()
    Assert-True ($watchdog.HasExited -and $watchCloud.HasExited -and $watchServer.HasExited) 'Watchdog retires tracked children at expiry'
} finally { foreach($process in @($watchdog,$watchCloud,$watchServer)){try{if($process -and -not $process.HasExited){Stop-Process -Id $process.Id -Force}}catch{};try{if($process){$process.Dispose()}}catch{}};if($job -ne [IntPtr]::Zero){try{Close-WorkspaceJob -Job $job}catch{}}; Remove-Item -LiteralPath $watchSession -Recurse -Force -ErrorAction SilentlyContinue }

$invalidSession=Join-Path ([IO.Path]::GetTempPath()) ('WorkspaceShare-invalid-watch-'+[Guid]::NewGuid().ToString('N'));$invalidChild=$null;$invalidWatch=$null;$invalidJob=[IntPtr]::Zero
try{New-Item -ItemType Directory -Path $invalidSession -Force|Out-Null;$shell=Join-Path $PSHOME 'powershell.exe';$invalidChild=Start-Process -FilePath $shell -ArgumentList @('-NoProfile','-Command','Start-Sleep -Seconds 30') -PassThru;$invalidJob=New-WorkspaceJob -Name ('Local\WorkspaceShare.Invalid.'+[Guid]::NewGuid().ToString('N'));Add-ProcessToWorkspaceJob -Job $invalidJob -ProcessId $invalidChild.Id;$invalidArchive=Join-Path $invalidSession 'archive.zip';[IO.File]::WriteAllText($invalidArchive,'test');$parent=Get-Process -Id $PID;$invalidReady=Join-Path $invalidSession 'ready';$invalidWatch=Start-Process -FilePath $shell -ArgumentList @('-NoProfile','-File',(Join-Path $ToolRoot 'scripts\Watch-WorkspaceShare.ps1'),'-ParentPid',$PID,'-ParentStartTicks',$parent.StartTime.ToUniversalTime().Ticks,'-ExpectedParentPath',$parent.Path,'-MiniservePid',$invalidChild.Id,'-MiniserveStartTicks',($invalidChild.StartTime.ToUniversalTime().Ticks+1),'-CloudflaredPid',$invalidChild.Id,'-CloudflaredStartTicks',$invalidChild.StartTime.ToUniversalTime().Ticks,'-SessionPath',$invalidSession,'-ArchivePath',$invalidArchive,'-JobName','missing-job','-NormalExitMarker',(Join-Path $invalidSession 'normal'),'-ReadyMarker',$invalidReady,'-ExpiresUtc',([DateTime]::UtcNow.AddMinutes(1).ToString('o')),'-ExpectedMiniservePath',$invalidChild.Path,'-ExpectedCloudflaredPath',$invalidChild.Path) -PassThru;[void]$invalidWatch.WaitForExit(5000);Assert-True ($invalidWatch.HasExited -and -not(Test-Path -LiteralPath $invalidReady)) 'Invalid child identity never publishes watchdog readiness'}finally{foreach($p in @($invalidWatch,$invalidChild)){try{if($p -and -not$p.HasExited){$p.Kill()}}catch{};try{if($p){$p.Dispose()}}catch{}};if($invalidJob -ne [IntPtr]::Zero){try{Close-WorkspaceJob $invalidJob}catch{}};Remove-Item -LiteralPath $invalidSession -Recurse -Force -ErrorAction SilentlyContinue}

$token = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
$safe = WorkspaceShare.Curl\Protect-DiagnosticText -Text ("https://x.trycloudflare.com/d/{0} %2Fd%2F{0} %252Fd%252F{0}" -f $token) -KnownSecretUrls @()
Assert-True ($safe -notmatch [regex]::Escape($token)) 'Curl diagnostic sanitizer redacts capability routes'

$classification = Get-TunnelClassification -LocalSampleValid $true -EndToEndSampleValid $false -HostnameAvailable $true -HostnameMatches $true -PublicHttpStatus 0 -CloudflareError 0 -PublicCurlExit 6 -OverrideDiagnosticSuccess $false -PublicDnsSuccessCount 0 -DnsChecked $true -SystemDnsSuccess $true -Ready $true
Assert-True ($classification -ne 'DnsMissing') 'Working system DNS is not misclassified as missing'
$classification = Get-TunnelClassification -LocalSampleValid $true -EndToEndSampleValid $false -HostnameAvailable $true -HostnameMatches $true -PublicHttpStatus 0 -CloudflareError 0 -PublicCurlExit 6 -OverrideDiagnosticSuccess $false -PublicDnsSuccessCount 0 -DnsChecked $true -SystemDnsSuccess $false -Ready $true
Assert-True ($classification -eq 'DnsMissing') 'All failed DNS paths are classified as missing'

$temporary = Join-Path ([IO.Path]::GetTempPath()) ('WorkspaceShare-lock-' + [Guid]::NewGuid().ToString('N'))
try {
    [IO.File]::WriteAllText($temporary, 'verified bytes')
    $lock = New-Object IO.FileStream($temporary,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)
    try { $blocked = $false; try { $writer = New-Object IO.FileStream($temporary,[IO.FileMode]::Open,[IO.FileAccess]::Write,[IO.FileShare]::ReadWrite); $writer.Dispose() } catch { $blocked = $true }; Assert-True $blocked 'Archive read lock prevents concurrent writes' } finally { $lock.Dispose() }
} finally { Remove-Item -LiteralPath $temporary -Force -ErrorAction SilentlyContinue }

if($failed -gt 0){exit 1}
