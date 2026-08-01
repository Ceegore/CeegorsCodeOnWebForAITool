#requires -Version 5.1
[CmdletBinding()]
param([string]$ToolRoot)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
if([string]::IsNullOrWhiteSpace($ToolRoot)){$ToolRoot=Split-Path $PSScriptRoot -Parent}
Import-Module (Join-Path $ToolRoot 'scripts\WorkspaceShare.Job.psm1') -Force -ErrorAction Stop
$job=New-WorkspaceJob -Name ('Local\WorkspaceShare.NativeSmoke.'+[Guid]::NewGuid().ToString('N'))
try{
    $result=Invoke-WorkspaceNativeProcess -Job $job -FilePath (Join-Path $env:SystemRoot 'System32\cmd.exe') -Arguments @('/d','/c','echo native-runner-ok') -WorkingDirectory ([IO.Path]::GetTempPath()) -TimeoutSeconds 10 -ExpectedExitCodes @(0)
    if([int]$result.ExitCode -ne 0 -or $result.StdOut -notmatch 'native-runner-ok'){throw 'Native runner smoke output mismatch.'}
    Write-Host '[PASS] Job-owned native runner reports exit code and bounded output'
}
finally{try{Stop-WorkspaceJob -Job $job}catch{};try{Close-WorkspaceJob -Job $job}catch{}}
