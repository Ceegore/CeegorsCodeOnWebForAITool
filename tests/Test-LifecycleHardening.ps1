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
$dependencyModule = Join-Path $ToolRoot 'scripts\WorkspaceShare.Dependency.psm1'
Assert-True (Test-Path -LiteralPath $processModule -PathType Leaf) 'Shared process module exists'
Assert-True (Test-Path -LiteralPath $curlModule -PathType Leaf) 'Shared curl module exists'
Assert-True (Test-Path -LiteralPath $jobModule -PathType Leaf) 'Shared Job Object module exists'
Assert-True (Test-Path -LiteralPath $pathModule -PathType Leaf) 'Shared canonical path module exists'
Assert-True (Test-Path -LiteralPath $dependencyModule -PathType Leaf) 'Shared dependency lease module exists'
Import-Module $processModule -Force
Import-Module $curlModule -Force
Import-Module $healthModule -Force
Import-Module $jobModule -Force
Import-Module $pathModule -Force
Import-Module $dependencyModule -Force

$leaseRoot=Join-Path ([IO.Path]::GetTempPath()) ('WorkspaceShare-lease-root-'+[Guid]::NewGuid().ToString('N'));New-Item -ItemType Directory -Path $leaseRoot -Force|Out-Null
try{
$sharedLease=Enter-WorkspaceDependencyLease -ToolRoot $leaseRoot -Mode Shared -TimeoutSeconds 2;$secondSharedLease=Enter-WorkspaceDependencyLease -ToolRoot $leaseRoot -Mode Shared -TimeoutSeconds 2;$exclusiveBlocked=$false
try{Assert-True ($null -ne $secondSharedLease) 'Multiple launcher readers can hold the dependency lease';try{$unexpectedLease=Enter-WorkspaceDependencyLease -ToolRoot $leaseRoot -Mode Exclusive -TimeoutSeconds 1;try{$unexpectedLease.Dispose()}catch{}}catch{$exclusiveBlocked=($_.Exception.Message -match 'could not be acquired within')};Assert-True $exclusiveBlocked 'Shared launcher lease blocks exclusive dependency replacement with a lease timeout'}finally{$secondSharedLease.Dispose();$sharedLease.Dispose()}
$exclusiveLease=Enter-WorkspaceDependencyLease -ToolRoot $leaseRoot -Mode Exclusive -TimeoutSeconds 2;try{Assert-True ($null -ne $exclusiveLease) 'Exclusive dependency lease succeeds after readers release'}finally{$exclusiveLease.Dispose()}
}finally{try{Remove-Item -LiteralPath (Get-WorkspaceDependencyLeasePath -ToolRoot $leaseRoot) -Force -ErrorAction SilentlyContinue}catch{};Remove-Item -LiteralPath $leaseRoot -Recurse -Force -ErrorAction SilentlyContinue}

$absent = Get-ProcessIdentityState -ProcessId 2147483647 -ExpectedPath $PSHOME -ExpectedStartTicks 1
Assert-True ($absent.State -eq 'Absent') 'Missing process is distinguished from uncertainty'
$inspectionFailureState=$null
try{function global:Get-Process { throw [Microsoft.PowerShell.Commands.ProcessCommandException]::new('simulated access failure') };$inspectionFailureState=Get-ProcessIdentityState -ProcessId 1234 -ExpectedPath $PSHOME -ExpectedStartTicks 1}finally{Remove-Item Function:\Get-Process -Force -ErrorAction SilentlyContinue}
Assert-True ($inspectionFailureState.State -eq 'Unknown') 'Process inspection errors are never misclassified as absence'
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

$fixtureTarget=Join-Path ([IO.Path]::GetTempPath()) ('WorkspaceShare-fixture-target-'+[Guid]::NewGuid().ToString('N'));$fixtureJunction=Join-Path ([IO.Path]::GetTempPath()) ('WorkspaceShare-fixture-junction-'+[Guid]::NewGuid().ToString('N'))
try{New-Item -ItemType Directory -Path $fixtureTarget|Out-Null;$sentinel=Join-Path $fixtureTarget 'sentinel.txt';[IO.File]::WriteAllText($sentinel,'keep');& cmd.exe /d /c mklink /J $fixtureJunction $fixtureTarget|Out-Null;if($LASTEXITCODE -ne 0){throw 'Could not create fixture junction test.'};$fixtureProcess=Start-Process -FilePath (Join-Path $PSHOME 'powershell.exe') -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-File',('"{0}"' -f (Join-Path $ToolRoot 'tests\New-TestFixtures.ps1')),'-OutputRoot',('"{0}"' -f $fixtureJunction),'-ForceReset') -WindowStyle Hidden -Wait -PassThru;$fixtureExit=$fixtureProcess.ExitCode;$fixtureProcess.Dispose();Assert-True ($fixtureExit -ne 0 -and (Test-Path -LiteralPath $sentinel -PathType Leaf)) 'Fixture reset refuses a junction root without touching its target'}finally{if(Test-Path -LiteralPath $fixtureJunction){try{[IO.Directory]::Delete($fixtureJunction)}catch{}};Remove-Item -LiteralPath $fixtureTarget -Recurse -Force -ErrorAction SilentlyContinue}

$killJob=New-WorkspaceJob -Name ('Local\WorkspaceShare.KillTest.'+[Guid]::NewGuid().ToString('N'))
$killChild=Start-Process -FilePath (Join-Path $PSHOME 'powershell.exe') -ArgumentList @('-NoProfile','-Command','Start-Sleep -Seconds 60') -PassThru
try{Add-ProcessToWorkspaceJob -Job $killJob -ProcessId $killChild.Id;Close-WorkspaceJob -Job $killJob;$killJob=[IntPtr]::Zero;[void]$killChild.WaitForExit(5000);Assert-True $killChild.HasExited 'Kill-on-close Job Object retires a child after owner loss'}finally{if($killJob -ne [IntPtr]::Zero){try{Close-WorkspaceJob -Job $killJob}catch{}};try{if(-not$killChild.HasExited){$killChild.Kill()}}catch{};try{$killChild.Dispose()}catch{}}

$atomicJob=New-WorkspaceJob -Name ('Local\WorkspaceShare.AtomicTest.'+[Guid]::NewGuid().ToString('N'))
$atomicOut=Join-Path ([IO.Path]::GetTempPath()) ('WorkspaceShare-atomic-'+[Guid]::NewGuid().ToString('N')+'.out')
$atomicErr=$atomicOut+'.err';$atomicChild=$null
try{$atomicChild=Start-WorkspaceProcessInJob -Job $atomicJob -FilePath (Join-Path $PSHOME 'powershell.exe') -Arguments @('-NoProfile','-Command','Write-Output atomic-output') -WorkingDirectory $ToolRoot -StdOutPath $atomicOut -StdErrPath $atomicErr;$atomicExited=$atomicChild.WaitForExit(30000);$atomicText=if(Test-Path -LiteralPath $atomicOut -PathType Leaf){([string](Get-Content -LiteralPath $atomicOut -Raw -ErrorAction SilentlyContinue)).Trim()}else{''};Assert-True ($atomicExited -and $atomicChild.HasExited -and $atomicText -eq 'atomic-output') 'Suspended Job launch inherits bounded output handles and resumes'}finally{try{Stop-WorkspaceJob $atomicJob}catch{};try{Close-WorkspaceJob $atomicJob}catch{};try{if($atomicChild){$atomicChild.Dispose()}}catch{};Remove-Item -LiteralPath $atomicOut,$atomicErr -Force -ErrorAction SilentlyContinue}

$collisionName='Local\WorkspaceShare.Collision.'+[Guid]::NewGuid().ToString('N');$collisionJob=New-WorkspaceJob -Name $collisionName;$collisionRejected=$false
try{try{$unexpectedJob=New-WorkspaceJob -Name $collisionName;try{Close-WorkspaceJob $unexpectedJob}catch{}}catch{$collisionRejected=($_.Exception.Message -match 'already exists')};Assert-True $collisionRejected 'Existing named Job collision is rejected'}finally{Close-WorkspaceJob $collisionJob}

$resumeJob=New-WorkspaceJob -Name ('Local\WorkspaceShare.ResumeFault.'+[Guid]::NewGuid().ToString('N'));$resumeOut=Join-Path ([IO.Path]::GetTempPath()) ('WorkspaceShare-resume-'+[Guid]::NewGuid().ToString('N')+'.out');$resumeErr=$resumeOut+'.err'
try{$resumeFailed=$false;$resumePid=0;try{Start-WorkspaceProcessInJob -Job $resumeJob -FilePath (Join-Path $PSHOME 'powershell.exe') -Arguments @('-NoProfile','-Command','Start-Sleep -Seconds 30') -WorkingDirectory $ToolRoot -StdOutPath $resumeOut -StdErrPath $resumeErr -TestForceResumeFailure|Out-Null}catch{$resumeFailed=$true;$fault=$_.Exception;while($fault -and -not $fault.Data.Contains('ProcessId')){$fault=$fault.InnerException};if($fault){$resumePid=[int]$fault.Data['ProcessId']}};$resumeAbsent=$false;for($attempt=0;$attempt -lt 25;$attempt++){if($resumePid -gt 0 -and -not(Get-Process -Id $resumePid -ErrorAction SilentlyContinue)){$resumeAbsent=$true;break};Start-Sleep -Milliseconds 200};Assert-True ($resumeFailed -and $resumePid -gt 0 -and $resumeAbsent) 'Injected ResumeThread failure terminates the hidden child'}finally{try{Stop-WorkspaceJob $resumeJob}catch{};try{Close-WorkspaceJob $resumeJob}catch{};Remove-Item -LiteralPath $resumeOut,$resumeErr -Force -ErrorAction SilentlyContinue}

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
    $watchStart=[Diagnostics.Stopwatch]::GetTimestamp();$watchDuration=[int64](10*[Diagnostics.Stopwatch]::Frequency)
    Start-Sleep -Milliseconds 500
    $watchdog = Start-Process -FilePath $shell -ArgumentList @('-NoProfile','-File',('"{0}"' -f $watchScript),'-ParentPid',$PID,'-ParentStartTicks',$parent.StartTime.ToUniversalTime().Ticks,'-ExpectedParentPath',('"{0}"' -f $parent.Path),'-MiniservePid',$watchServer.Id,'-MiniserveStartTicks',$watchServer.StartTime.ToUniversalTime().Ticks,'-CloudflaredPid',$watchCloud.Id,'-CloudflaredStartTicks',$watchCloud.StartTime.ToUniversalTime().Ticks,'-SessionPath',('"{0}"' -f $watchSession),'-ArchivePath',('"{0}"' -f $archive),'-JobName',$jobName,'-NormalExitMarker',('"{0}"' -f (Join-Path $watchSession 'normal.exit')),'-ReadyMarker',('"{0}"' -f (Join-Path $watchSession 'watch.ready')),'-ExpiresUtc',([DateTime]::UtcNow.AddSeconds(10).ToString('o')),'-StartTimestamp',$watchStart,'-DurationTicks',$watchDuration,'-ExpectedMiniservePath',('"{0}"' -f $watchServer.Path),'-ExpectedCloudflaredPath',('"{0}"' -f $watchCloud.Path)) -PassThru
    $readyDeadline = [DateTime]::UtcNow.AddSeconds(20)
    while(-not (Test-Path -LiteralPath (Join-Path $watchSession 'watch.ready')) -and [DateTime]::UtcNow -lt $readyDeadline){Start-Sleep -Milliseconds 100}
    Assert-True (Test-Path -LiteralPath (Join-Path $watchSession 'watch.ready')) 'Watchdog publishes readiness before monitoring'
    [void]$watchdog.WaitForExit(30000); $watchCloud.Refresh(); $watchServer.Refresh()
    Assert-True ($watchdog.HasExited -and $watchCloud.HasExited -and $watchServer.HasExited) 'Watchdog retires tracked children at expiry'
    $sharedElapsed=([Diagnostics.Stopwatch]::GetTimestamp()-$watchStart)/[double][Diagnostics.Stopwatch]::Frequency
    Assert-True ($sharedElapsed -ge 9.5 -and $sharedElapsed -lt 25) ("Watchdog expiry uses the supplied shared monotonic deadline ({0:N2}s including cleanup)" -f $sharedElapsed)
} finally { foreach($process in @($watchdog,$watchCloud,$watchServer)){try{if($process -and -not $process.HasExited){Stop-Process -Id $process.Id -Force}}catch{};try{if($process){$process.Dispose()}}catch{}};if($job -ne [IntPtr]::Zero){try{Close-WorkspaceJob -Job $job}catch{}}; Remove-Item -LiteralPath $watchSession -Recurse -Force -ErrorAction SilentlyContinue }

$faultSession=Join-Path ([IO.Path]::GetTempPath()) ('WorkspaceShare-watch-fault-'+[Guid]::NewGuid().ToString('N'));$faultCloud=$null;$faultServer=$null;$faultWatch=$null;$faultJob=[IntPtr]::Zero
try{New-Item -ItemType Directory -Path $faultSession -Force|Out-Null;$shell=Join-Path $PSHOME 'powershell.exe';$faultCloud=Start-Process -FilePath $shell -ArgumentList @('-NoProfile','-Command','Start-Sleep -Seconds 60') -PassThru;$faultServer=Start-Process -FilePath $shell -ArgumentList @('-NoProfile','-Command','Start-Sleep -Seconds 60') -PassThru;$faultJobName='Local\WorkspaceShare.Fault.'+[Guid]::NewGuid().ToString('N');$faultJob=New-WorkspaceJob -Name $faultJobName;Add-ProcessToWorkspaceJob -Job $faultJob -ProcessId $faultCloud.Id;Add-ProcessToWorkspaceJob -Job $faultJob -ProcessId $faultServer.Id;$faultArchive=Join-Path $faultSession 'archive.zip';[IO.File]::WriteAllText($faultArchive,'test');$parent=Get-Process -Id $PID;$faultReady=Join-Path $faultSession 'ready';$faultStart=[Diagnostics.Stopwatch]::GetTimestamp();$faultDuration=[int64](60*[Diagnostics.Stopwatch]::Frequency);$faultWatch=Start-Process -FilePath $shell -ArgumentList @('-NoProfile','-File',('"{0}"' -f (Join-Path $ToolRoot 'scripts\Watch-WorkspaceShare.ps1')),'-ParentPid',$PID,'-ParentStartTicks',$parent.StartTime.ToUniversalTime().Ticks,'-ExpectedParentPath',('"{0}"' -f $parent.Path),'-MiniservePid',$faultServer.Id,'-MiniserveStartTicks',$faultServer.StartTime.ToUniversalTime().Ticks,'-CloudflaredPid',$faultCloud.Id,'-CloudflaredStartTicks',$faultCloud.StartTime.ToUniversalTime().Ticks,'-SessionPath',('"{0}"' -f $faultSession),'-ArchivePath',('"{0}"' -f $faultArchive),'-JobName',$faultJobName,'-NormalExitMarker',('"{0}"' -f (Join-Path $faultSession 'normal')),'-ReadyMarker',('"{0}"' -f $faultReady),'-ExpiresUtc',([DateTime]::UtcNow.AddMinutes(1).ToString('o')),'-StartTimestamp',$faultStart,'-DurationTicks',$faultDuration,'-ExpectedMiniservePath',('"{0}"' -f $faultServer.Path),'-ExpectedCloudflaredPath',('"{0}"' -f $faultCloud.Path),'-KeepArchive','-TestFault','AfterReady') -PassThru;$null=$faultWatch.Handle;[void]$faultWatch.WaitForExit(10000);$faultCloud.Refresh();$faultServer.Refresh();Assert-True ($faultWatch.HasExited -and $faultWatch.ExitCode -ne 0 -and $faultCloud.HasExited -and $faultServer.HasExited -and (Test-Path -LiteralPath $faultReady)) 'Unexpected watchdog exception after readiness terminates the entire Job'}finally{foreach($p in @($faultWatch,$faultCloud,$faultServer)){try{if($p -and -not$p.HasExited){$p.Kill()}}catch{};try{if($p){$p.Dispose()}}catch{}};if($faultJob -ne [IntPtr]::Zero){try{Close-WorkspaceJob $faultJob}catch{}};Remove-Item -LiteralPath $faultSession -Recurse -Force -ErrorAction SilentlyContinue}

$invalidSession=Join-Path ([IO.Path]::GetTempPath()) ('WorkspaceShare-invalid-watch-'+[Guid]::NewGuid().ToString('N'));$invalidChild=$null;$invalidWatch=$null;$invalidJob=[IntPtr]::Zero
try{New-Item -ItemType Directory -Path $invalidSession -Force|Out-Null;$shell=Join-Path $PSHOME 'powershell.exe';$invalidChild=Start-Process -FilePath $shell -ArgumentList @('-NoProfile','-Command','Start-Sleep -Seconds 30') -PassThru;$invalidJob=New-WorkspaceJob -Name ('Local\WorkspaceShare.Invalid.'+[Guid]::NewGuid().ToString('N'));Add-ProcessToWorkspaceJob -Job $invalidJob -ProcessId $invalidChild.Id;$invalidArchive=Join-Path $invalidSession 'archive.zip';[IO.File]::WriteAllText($invalidArchive,'test');$parent=Get-Process -Id $PID;$invalidReady=Join-Path $invalidSession 'ready';$invalidStart=[Diagnostics.Stopwatch]::GetTimestamp();$invalidDuration=[int64](60*[Diagnostics.Stopwatch]::Frequency);$invalidWatch=Start-Process -FilePath $shell -ArgumentList @('-NoProfile','-File',('"{0}"' -f (Join-Path $ToolRoot 'scripts\Watch-WorkspaceShare.ps1')),'-ParentPid',$PID,'-ParentStartTicks',$parent.StartTime.ToUniversalTime().Ticks,'-ExpectedParentPath',('"{0}"' -f $parent.Path),'-MiniservePid',$invalidChild.Id,'-MiniserveStartTicks',($invalidChild.StartTime.ToUniversalTime().Ticks+1),'-CloudflaredPid',$invalidChild.Id,'-CloudflaredStartTicks',$invalidChild.StartTime.ToUniversalTime().Ticks,'-SessionPath',('"{0}"' -f $invalidSession),'-ArchivePath',('"{0}"' -f $invalidArchive),'-JobName','missing-job','-NormalExitMarker',('"{0}"' -f (Join-Path $invalidSession 'normal')),'-ReadyMarker',('"{0}"' -f $invalidReady),'-ExpiresUtc',([DateTime]::UtcNow.AddMinutes(1).ToString('o')),'-StartTimestamp',$invalidStart,'-DurationTicks',$invalidDuration,'-ExpectedMiniservePath',('"{0}"' -f $invalidChild.Path),'-ExpectedCloudflaredPath',('"{0}"' -f $invalidChild.Path)) -PassThru;$null=$invalidWatch.Handle;[void]$invalidWatch.WaitForExit(5000);Assert-True ($invalidWatch.HasExited -and $invalidWatch.ExitCode -ne 0 -and -not(Test-Path -LiteralPath $invalidReady)) 'Invalid child identity never publishes watchdog readiness'}finally{foreach($p in @($invalidWatch,$invalidChild)){try{if($p -and -not$p.HasExited){$p.Kill()}}catch{};try{if($p){$p.Dispose()}}catch{}};if($invalidJob -ne [IntPtr]::Zero){try{Close-WorkspaceJob $invalidJob}catch{}};Remove-Item -LiteralPath $invalidSession -Recurse -Force -ErrorAction SilentlyContinue}

$token = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
$safe = WorkspaceShare.Curl\Protect-DiagnosticText -Text ("https://x.trycloudflare.com/d/{0} %2Fd%2F{0} %252Fd%252F{0}" -f $token) -KnownSecretUrls @()
Assert-True ($safe -notmatch [regex]::Escape($token)) 'Curl diagnostic sanitizer redacts capability routes'
$standaloneSafe=WorkspaceShare.Curl\Protect-DiagnosticText -Text ("standalone=$token") -SecretTokens @($token)
Assert-True ($standaloneSafe -notmatch [regex]::Escape($token)) 'Curl diagnostic sanitizer redacts an exact standalone token'

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
exit 0
