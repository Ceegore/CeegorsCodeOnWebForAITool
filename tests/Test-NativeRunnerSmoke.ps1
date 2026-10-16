#requires -Version 5.1
[CmdletBinding()]
param([string]$ToolRoot)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
if([string]::IsNullOrWhiteSpace($ToolRoot)){$ToolRoot=Split-Path $PSScriptRoot -Parent}
Import-Module (Join-Path (Join-Path $ToolRoot 'scripts') 'WorkspaceShare.Job.psm1') -Force -ErrorAction Stop
$isWin=([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT)
if($isWin){$cmd=Join-Path $env:SystemRoot 'System32\cmd.exe';$okArguments=@('/d','/c','echo native-runner-ok');$exit3Arguments=@('/d','/c','exit 3');$sleeper=Join-Path $env:SystemRoot 'System32\ping.exe';$sleeperArguments=@('-n','30','127.0.0.1')}else{$cmd='/bin/sh';$okArguments=@('-c','echo native-runner-ok');$exit3Arguments=@('-c','exit 3');$sleeper='/bin/sleep';$sleeperArguments=@('30')}
$job=New-WorkspaceJob -Name ('Local\WorkspaceShare.NativeSmoke.'+[Guid]::NewGuid().ToString('N'))
try{
    $result=Invoke-WorkspaceNativeProcess -Job $job -FilePath $cmd -Arguments $okArguments -WorkingDirectory ([IO.Path]::GetTempPath()) -TimeoutSeconds 10 -ExpectedExitCodes @(0)
    if($null -eq $result.ExitCode -or [int]$result.ExitCode -ne 0 -or $result.StdOut -notmatch 'native-runner-ok'){throw 'Native runner smoke output mismatch.'}
    Write-Host '[PASS] Job-owned native runner reports exit code and bounded output'
    $unexpectedExit=$null;$exitRejected=$false
    try{$unexpectedExit=Invoke-WorkspaceNativeProcess -Job $job -FilePath $cmd -Arguments $exit3Arguments -WorkingDirectory ([IO.Path]::GetTempPath()) -TimeoutSeconds 10 -ExpectedExitCodes @(0)}catch{$exitRejected=($_.Exception.Message -match 'exit 3')}
    if(-not $exitRejected -or $null -ne $unexpectedExit){throw 'Native runner did not reject an unexpected exit code.'}
    Write-Host '[PASS] Job-owned native runner rejects an unexpected exit code'
}
finally{try{Stop-WorkspaceJob -Job $job}catch{};try{Close-WorkspaceJob -Job $job}catch{}}
$timeoutJob=New-WorkspaceJob -Name ('Local\WorkspaceShare.NativeSmokeTimeout.'+[Guid]::NewGuid().ToString('N'))
try{
    $timeoutRejected=$false;$timeoutWatch=[Diagnostics.Stopwatch]::StartNew()
    try{[void](Invoke-WorkspaceNativeProcess -Job $timeoutJob -FilePath $sleeper -Arguments $sleeperArguments -WorkingDirectory ([IO.Path]::GetTempPath()) -TimeoutSeconds 2 -ExpectedExitCodes @(0))}catch{$timeoutRejected=($_.Exception.Message -match 'exceeded 2 seconds')}
    if(-not $timeoutRejected -or $timeoutWatch.Elapsed.TotalSeconds -ge 20){throw 'Native runner did not enforce its timeout.'}
    Write-Host '[PASS] Job-owned native runner enforces the timeout and terminates the child'
}
finally{try{Stop-WorkspaceJob -Job $timeoutJob}catch{};try{Close-WorkspaceJob -Job $timeoutJob}catch{}}
exit 0
