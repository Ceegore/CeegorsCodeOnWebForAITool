#requires -Version 5.1
[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][int]$ParentPid,[Parameter(Mandatory=$true)][long]$ParentStartTicks,[Parameter(Mandatory=$true)][string]$ExpectedParentPath,
    [Parameter(Mandatory=$true)][int]$MiniservePid,[Parameter(Mandatory=$true)][long]$MiniserveStartTicks,
    [Parameter(Mandatory=$true)][int]$CloudflaredPid,[Parameter(Mandatory=$true)][long]$CloudflaredStartTicks,
    [Parameter(Mandatory=$true)][string]$SessionPath,[Parameter(Mandatory=$true)][string]$ArchivePath,[Parameter(Mandatory=$true)][string]$JobName,[Parameter(Mandatory=$true)][string]$NormalExitMarker,[Parameter(Mandatory=$true)][string]$ReadyMarker,
    [Parameter(Mandatory=$true)][datetime]$ExpiresUtc,[Parameter(Mandatory=$true)][string]$ExpectedMiniservePath,[Parameter(Mandatory=$true)][string]$ExpectedCloudflaredPath,[switch]$KeepArchive
)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
Import-Module (Join-Path (Split-Path $PSScriptRoot -Parent) 'scripts\WorkspaceShare.Process.psm1') -Force -ErrorAction Stop
Import-Module (Join-Path (Split-Path $PSScriptRoot -Parent) 'scripts\WorkspaceShare.Job.psm1') -Force -ErrorAction Stop
function Get-State([int]$Id,[string]$Path,[long]$Ticks){Get-ProcessIdentityState -ProcessId $Id -ExpectedPath $Path -ExpectedStartTicks $Ticks}
function Test-Gone($State){$State.State -in @('Absent','Conflict')}

if(-not(Test-Path -LiteralPath $SessionPath -PathType Container)){exit 50}
$parentState=Get-State $ParentPid $ExpectedParentPath $ParentStartTicks
$serverState=Get-State $MiniservePid $ExpectedMiniservePath $MiniserveStartTicks
$cloudState=Get-State $CloudflaredPid $ExpectedCloudflaredPath $CloudflaredStartTicks
if($parentState.State -ne 'Match' -or $serverState.State -ne 'Match' -or $cloudState.State -ne 'Match'){exit 50}
$job=[IntPtr]::Zero
try{$job=Open-WorkspaceJob -Name $JobName}catch{exit 50}
$archiveLock=$null
try{$archiveLock=New-Object IO.FileStream($ArchivePath,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)}catch{exit 50}
try{New-Item -ItemType File -Path $ReadyMarker -Force -ErrorAction Stop|Out-Null}catch{exit 50}

$durationSeconds=[Math]::Max(0.001,($ExpiresUtc.ToUniversalTime()-[DateTime]::UtcNow).TotalSeconds)
$timer=[Diagnostics.Stopwatch]::StartNew()
while($true){
    if([DateTime]::UtcNow -ge $ExpiresUtc.ToUniversalTime() -or $timer.Elapsed.TotalSeconds -ge $durationSeconds){break}
    if(Test-Path -LiteralPath $NormalExitMarker -PathType Leaf){
        $cloudState=Get-State $CloudflaredPid $ExpectedCloudflaredPath $CloudflaredStartTicks
        $serverState=Get-State $MiniservePid $ExpectedMiniservePath $MiniserveStartTicks
        if((Test-Gone $cloudState) -and (Test-Gone $serverState)){exit 0}
    }
    $parentState=Get-State $ParentPid $ExpectedParentPath $ParentStartTicks
    if($parentState.State -in @('Absent','Conflict')){break}
    Start-Sleep -Seconds 1
}

$delay=1
try{Stop-WorkspaceJob -Job $job}catch{}
while($true){
    $cloudState=Get-State $CloudflaredPid $ExpectedCloudflaredPath $CloudflaredStartTicks
    $serverState=Get-State $MiniservePid $ExpectedMiniservePath $MiniserveStartTicks
    $cloudGone=Test-Gone $cloudState;$serverGone=Test-Gone $serverState
    if($cloudGone -and $serverGone){break}
    if(-not $cloudGone){[void](Stop-TrackedProcessConfirmed -ProcessId $CloudflaredPid -ExpectedPath $ExpectedCloudflaredPath -ExpectedStartTicks $CloudflaredStartTicks -Attempts 1 -WaitMilliseconds 1000)}
    if($cloudGone -and -not $serverGone){[void](Stop-TrackedProcessConfirmed -ProcessId $MiniservePid -ExpectedPath $ExpectedMiniservePath -ExpectedStartTicks $MiniserveStartTicks -Attempts 1 -WaitMilliseconds 1000)}
    Start-Sleep -Seconds $delay;$delay=[Math]::Min(30,$delay*2)
}
try{$archiveLock.Dispose()}catch{exit 52}
try{Close-WorkspaceJob -Job $job}catch{exit 52}
$effectiveKeep=$KeepArchive -or (Test-Path -LiteralPath (Join-Path $SessionPath 'keep.archive') -PathType Leaf)
if($effectiveKeep){try{New-Item -ItemType File -Path (Join-Path $SessionPath 'keep.archive') -Force -ErrorAction Stop|Out-Null}catch{exit 52}}
else{try{Remove-Item -LiteralPath $SessionPath -Recurse -Force -ErrorAction Stop}catch{exit 52};if(Test-Path -LiteralPath $SessionPath){exit 52}}
exit 0
