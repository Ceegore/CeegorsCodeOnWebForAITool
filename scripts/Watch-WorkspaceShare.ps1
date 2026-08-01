#requires -Version 5.1
[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][int]$ParentPid,
    [Parameter(Mandatory=$true)][long]$ParentStartTicks,
    [Parameter(Mandatory=$true)][string]$ExpectedParentPath,
    [Parameter(Mandatory=$true)][int]$MiniservePid,
    [Parameter(Mandatory=$true)][long]$MiniserveStartTicks,
    [Parameter(Mandatory=$true)][int]$CloudflaredPid,
    [Parameter(Mandatory=$true)][long]$CloudflaredStartTicks,
    [Parameter(Mandatory=$true)][string]$SessionPath,
    [Parameter(Mandatory=$true)][string]$ArchivePath,
    [Parameter(Mandatory=$true)][string]$JobName,
    [Parameter(Mandatory=$true)][string]$NormalExitMarker,
    [Parameter(Mandatory=$true)][string]$ReadyMarker,
    [Parameter(Mandatory=$true)][datetime]$ExpiresUtc,
    [Parameter(Mandatory=$true)][long]$StartTimestamp,
    [Parameter(Mandatory=$true)][long]$DurationTicks,
    [Parameter(Mandatory=$true)][string]$ExpectedMiniservePath,
    [Parameter(Mandatory=$true)][string]$ExpectedCloudflaredPath,
    [switch]$KeepArchive,
    [ValidateSet('','AfterReady','AfterParentInspection','AfterExpiryCheck','AfterJobTermination','AfterChildQuery')]
    [string]$TestFault = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
Import-Module (Join-Path (Split-Path $PSScriptRoot -Parent) 'scripts\WorkspaceShare.Process.psm1') -Force -ErrorAction Stop
Import-Module (Join-Path (Split-Path $PSScriptRoot -Parent) 'scripts\WorkspaceShare.Job.psm1') -Force -ErrorAction Stop

function Get-State([int]$Id,[string]$Path,[long]$Ticks){Get-ProcessIdentityState -ProcessId $Id -ExpectedPath $Path -ExpectedStartTicks $Ticks}
function Test-Gone($State){$State.State -in @('Absent','Conflict')}
$script:FaultInjected=$false
function Invoke-TestFault([string]$Point){if(-not $script:FaultInjected -and $TestFault -eq $Point){$script:FaultInjected=$true;throw "Injected watchdog fault at $Point."}}

$job=[IntPtr]::Zero
$archiveLock=$null
$normalCompletion=$false
$childrenGone=$false
$exitCode=50

try {
    if(-not(Test-Path -LiteralPath $SessionPath -PathType Container)){throw 'Session directory is missing.'}
    $parentState=Get-State $ParentPid $ExpectedParentPath $ParentStartTicks
    $serverState=Get-State $MiniservePid $ExpectedMiniservePath $MiniserveStartTicks
    $cloudState=Get-State $CloudflaredPid $ExpectedCloudflaredPath $CloudflaredStartTicks
    if($parentState.State -ne 'Match' -or $serverState.State -ne 'Match' -or $cloudState.State -ne 'Match'){throw 'Tracked process identity validation failed.'}
    $job=Open-WorkspaceJob -Name $JobName
    $archiveLock=New-Object IO.FileStream($ArchivePath,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)
    New-Item -ItemType File -Path $ReadyMarker -Force -ErrorAction Stop|Out-Null
    Invoke-TestFault 'AfterReady'

    while($true){
        $parentState=Get-State $ParentPid $ExpectedParentPath $ParentStartTicks
        Invoke-TestFault 'AfterParentInspection'
        $elapsedTicks=[Diagnostics.Stopwatch]::GetTimestamp()-$StartTimestamp
        $expired=$elapsedTicks -ge $DurationTicks
        Invoke-TestFault 'AfterExpiryCheck'
        if($expired -or $parentState.State -in @('Absent','Conflict')){break}

        if(Test-Path -LiteralPath $NormalExitMarker -PathType Leaf){
            $cloudState=Get-State $CloudflaredPid $ExpectedCloudflaredPath $CloudflaredStartTicks
            $serverState=Get-State $MiniservePid $ExpectedMiniservePath $MiniserveStartTicks
            if((Test-Gone $cloudState) -and (Test-Gone $serverState)){
                $childrenGone=$true
                $normalCompletion=$true
                $exitCode=0
                break
            }
        }
        Start-Sleep -Seconds 1
    }

    if(-not $normalCompletion){
        Stop-WorkspaceJob -Job $job
        Invoke-TestFault 'AfterJobTermination'
    }
}
catch {
    $exitCode=50
}
finally {
    if(-not $normalCompletion -and $job -ne [IntPtr]::Zero){try{Stop-WorkspaceJob -Job $job}catch{}}

    if(-not $childrenGone){
        $delay=1
        while($true){
            try {
                $cloudState=Get-State $CloudflaredPid $ExpectedCloudflaredPath $CloudflaredStartTicks
                $serverState=Get-State $MiniservePid $ExpectedMiniservePath $MiniserveStartTicks
                Invoke-TestFault 'AfterChildQuery'
                $cloudGone=Test-Gone $cloudState
                $serverGone=Test-Gone $serverState
                if($cloudGone -and $serverGone){$childrenGone=$true;break}
                if(-not $cloudGone){[void](Stop-TrackedProcessConfirmed -ProcessId $CloudflaredPid -ExpectedPath $ExpectedCloudflaredPath -ExpectedStartTicks $CloudflaredStartTicks -Attempts 1 -WaitMilliseconds 1000)}
                if($cloudGone -and -not $serverGone){[void](Stop-TrackedProcessConfirmed -ProcessId $MiniservePid -ExpectedPath $ExpectedMiniservePath -ExpectedStartTicks $MiniserveStartTicks -Attempts 1 -WaitMilliseconds 1000)}
            }
            catch {}
            Start-Sleep -Seconds $delay
            $delay=[Math]::Min(30,$delay*2)
        }
    }

    if($archiveLock){try{$archiveLock.Dispose()}catch{$exitCode=52}}
    if($job -ne [IntPtr]::Zero){try{Close-WorkspaceJob -Job $job}catch{$exitCode=52}}

    if(-not $normalCompletion -and $childrenGone){
        $effectiveKeep=$KeepArchive -or (Test-Path -LiteralPath (Join-Path $SessionPath 'keep.archive') -PathType Leaf)
        if($effectiveKeep){try{New-Item -ItemType File -Path (Join-Path $SessionPath 'keep.archive') -Force -ErrorAction Stop|Out-Null}catch{$exitCode=52}}
        else {
            try{Remove-Item -LiteralPath $SessionPath -Recurse -Force -ErrorAction Stop}catch{$exitCode=52}
            if(Test-Path -LiteralPath $SessionPath){$exitCode=52}
        }
    }
}

exit $exitCode
