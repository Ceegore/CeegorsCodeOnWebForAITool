#requires -Version 5.1
[CmdletBinding()]
param([string]$ToolRoot)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
if([string]::IsNullOrWhiteSpace($ToolRoot)){$ToolRoot=Split-Path $PSScriptRoot -Parent}
Import-Module (Join-Path $ToolRoot 'scripts\WorkspaceShare.Job.psm1') -Force -ErrorAction Stop
$cmd=Join-Path $env:SystemRoot 'System32\cmd.exe'
$job=New-WorkspaceJob -Name ('Local\WorkspaceShare.NativeSmoke.'+[Guid]::NewGuid().ToString('N'))
try{
    $result=Invoke-WorkspaceNativeProcess -Job $job -FilePath $cmd -Arguments @('/d','/c','echo native-runner-ok') -WorkingDirectory ([IO.Path]::GetTempPath()) -TimeoutSeconds 10 -ExpectedExitCodes @(0)
    if($null -eq $result.ExitCode -or [int]$result.ExitCode -ne 0 -or $result.StdOut -notmatch 'native-runner-ok'){throw 'Native runner smoke output mismatch.'}
    Write-Host '[PASS] Job-owned native runner reports exit code and bounded output'
    $unexpectedExit=$null;$exitRejected=$false
    try{$unexpectedExit=Invoke-WorkspaceNativeProcess -Job $job -FilePath $cmd -Arguments @('/d','/c','exit 3') -WorkingDirectory ([IO.Path]::GetTempPath()) -TimeoutSeconds 10 -ExpectedExitCodes @(0)}catch{$exitRejected=($_.Exception.Message -match 'exit 3')}
    if(-not $exitRejected -or $null -ne $unexpectedExit){throw 'Native runner did not reject an unexpected exit code.'}
    Write-Host '[PASS] Job-owned native runner rejects an unexpected exit code'
}
finally{try{Stop-WorkspaceJob -Job $job}catch{};try{Close-WorkspaceJob -Job $job}catch{}}
$timeoutJob=New-WorkspaceJob -Name ('Local\WorkspaceShare.NativeSmokeTimeout.'+[Guid]::NewGuid().ToString('N'))
try{
    $timeoutRejected=$false;$timeoutWatch=[Diagnostics.Stopwatch]::StartNew()
    try{[void](Invoke-WorkspaceNativeProcess -Job $timeoutJob -FilePath (Join-Path $env:SystemRoot 'System32\ping.exe') -Arguments @('-n','30','127.0.0.1') -WorkingDirectory ([IO.Path]::GetTempPath()) -TimeoutSeconds 2 -ExpectedExitCodes @(0))}catch{$timeoutRejected=($_.Exception.Message -match 'exceeded 2 seconds')}
    if(-not $timeoutRejected -or $timeoutWatch.Elapsed.TotalSeconds -ge 20){throw 'Native runner did not enforce its timeout.'}
    Write-Host '[PASS] Job-owned native runner enforces the timeout and terminates the child'
}
finally{try{Stop-WorkspaceJob -Job $timeoutJob}catch{};try{Close-WorkspaceJob -Job $timeoutJob}catch{}}
exit 0
