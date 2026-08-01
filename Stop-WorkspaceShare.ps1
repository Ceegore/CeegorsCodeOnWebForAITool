#requires -Version 5.1
[CmdletBinding()]
param([switch]$KeepArchives)
Set-StrictMode -Version Latest
$ErrorActionPreference='Continue'
try{Import-Module (Join-Path $PSScriptRoot 'scripts\WorkspaceShare.Process.psm1') -Force -ErrorAction Stop}catch{[Console]::Error.WriteLine("Shared process module could not be loaded: $($_.Exception.Message)");exit 1}
try{Import-Module (Join-Path $PSScriptRoot 'scripts\WorkspaceShare.Job.psm1') -Force -ErrorAction Stop}catch{[Console]::Error.WriteLine("Shared Job module could not be loaded: $($_.Exception.Message)");exit 1}
$sessionBase=if($env:LOCALAPPDATA){Join-Path $env:LOCALAPPDATA 'WorkspaceShare\sessions'}else{Join-Path ([IO.Path]::GetTempPath()) 'WorkspaceShare\sessions'}
$exitCode=0
function Test-SafeSession($Session){
    $required=@('magic','schema','phase','launcherPid','launcherPath','launcherStartTicks','cloudflaredPid','cloudflaredPath','cloudflaredStartTicks','miniservePid','miniservePath','miniserveStartTicks','watchdogPid','watchdogPath','watchdogStartTicks','archivePath','keepArchive','jobName')
    if(@($required|Where-Object{$Session.PSObject.Properties.Name -notcontains $_}).Count -gt 0 -or [string]$Session.magic -ne 'WorkspaceShareSession' -or [int]$Session.schema -ne 2){return $false}
    foreach($prefix in @('launcher','cloudflared','miniserve','watchdog')){if([int]$Session.($prefix+'Pid') -le 0 -or [long]$Session.($prefix+'StartTicks') -le 0 -or -not[IO.Path]::IsPathRooted([string]$Session.($prefix+'Path'))){return $false}}
    if([string]$Session.jobName -notmatch '^Local\\WorkspaceShare\.[A-Za-z0-9-]+$'){return $false}
    return $true
}
function Get-State($Session,[string]$Prefix){Get-ProcessIdentityState -ProcessId ([int]$Session.($Prefix+'Pid')) -ExpectedPath ([string]$Session.($Prefix+'Path')) -ExpectedStartTicks ([long]$Session.($Prefix+'StartTicks'))}
function Stop-One($Session,[string]$Prefix){Stop-TrackedProcessConfirmed -ProcessId ([int]$Session.($Prefix+'Pid')) -ExpectedPath ([string]$Session.($Prefix+'Path')) -ExpectedStartTicks ([long]$Session.($Prefix+'StartTicks')) -Attempts 20 -WaitMilliseconds 1000}

if(-not(Test-Path -LiteralPath $sessionBase -PathType Container)){Write-Host 'Keine WorkspaceShare-Sitzungen gefunden.';exit 0}
foreach($directory in @(Get-ChildItem -LiteralPath $sessionBase -Directory -ErrorAction SilentlyContinue)){
    $metadataPath=Join-Path $directory.FullName 'session.json'
    if(-not(Test-Path -LiteralPath $metadataPath -PathType Leaf)){
        try{$owner=Get-Content -LiteralPath (Join-Path $directory.FullName 'owner.json') -Raw -ErrorAction Stop|ConvertFrom-Json -ErrorAction Stop}catch{Write-Warning "Session without valid owner metadata remains untouched: $($directory.FullName)";$exitCode=1;continue}
        $ownerProperties=@($owner.PSObject.Properties.Name)
        $missingOwnerProperties=@(@('magic','schema','phase','launcherPid','launcherPath','launcherStartTicks','jobName')|Where-Object{$ownerProperties -notcontains $_})
        if($missingOwnerProperties.Count -gt 0 -or [string]$owner.magic -ne 'WorkspaceShareSession' -or [int]$owner.schema -ne 1 -or [int]$owner.launcherPid -le 0 -or [long]$owner.launcherStartTicks -le 0 -or -not[IO.Path]::IsPathRooted([string]$owner.launcherPath) -or [string]$owner.jobName -notmatch '^Local\\WorkspaceShare\.[A-Za-z0-9-]+$'){Write-Warning "Session with unsafe owner metadata remains untouched: $($directory.FullName)";$exitCode=1;continue}
        if($KeepArchives){try{New-Item -ItemType File -Path (Join-Path $directory.FullName 'keep.archive') -Force -ErrorAction Stop|Out-Null}catch{Write-Warning 'The retention marker could not be written.';$exitCode=1;continue}}
        try{New-Item -ItemType File -Path (Join-Path $directory.FullName 'stop.requested') -Force -ErrorAction Stop|Out-Null}catch{Write-Warning 'The stop marker could not be written.';$exitCode=1;continue}
        $ownerState=Get-ProcessIdentityState -ProcessId ([int]$owner.launcherPid) -ExpectedPath ([string]$owner.launcherPath) -ExpectedStartTicks ([long]$owner.launcherStartTicks)
        if($ownerState.State -eq 'Match'){$timer=[Diagnostics.Stopwatch]::StartNew();while($timer.Elapsed.TotalSeconds -lt 30 -and (Test-Path -LiteralPath $directory.FullName)){Start-Sleep -Milliseconds 250;$ownerState=Get-ProcessIdentityState -ProcessId ([int]$owner.launcherPid) -ExpectedPath ([string]$owner.launcherPath) -ExpectedStartTicks ([long]$owner.launcherStartTicks);if($ownerState.State -in @('Absent','Conflict')){break}}}
        if($ownerState.State -in @('Match','Unknown')){Write-Warning 'The launcher of an incomplete session remains active or uncertain; the session is preserved.';$exitCode=1;continue}
        if([string]$owner.jobName -match '^Local\\WorkspaceShare\.[A-Za-z0-9-]+$'){try{$job=Open-WorkspaceJob -Name ([string]$owner.jobName);try{Stop-WorkspaceJob -Job $job}finally{Close-WorkspaceJob -Job $job}}catch{}}
        if($KeepArchives -or (Test-Path -LiteralPath (Join-Path $directory.FullName 'keep.archive') -PathType Leaf)){continue}
        try{Remove-Item -LiteralPath $directory.FullName -Recurse -Force -ErrorAction Stop}catch{Write-Warning "Incomplete session could not be removed: $($directory.FullName)";$exitCode=1}
        continue
    }
    try{$session=Get-Content -LiteralPath (Join-Path $directory.FullName 'session.json') -Raw -ErrorAction Stop|ConvertFrom-Json -ErrorAction Stop}catch{Write-Warning "Sitzung ohne gültige Metadaten bleibt unangetastet: $($directory.FullName)";$exitCode=1;continue}
    if(-not(Test-SafeSession $session)){Write-Warning "Sitzung hat kein unterstütztes sicheres Format: $($directory.FullName)";$exitCode=1;continue}
    if($KeepArchives){try{New-Item -ItemType File -Path (Join-Path $directory.FullName 'keep.archive') -Force -ErrorAction Stop|Out-Null}catch{Write-Warning 'Der Aufbewahrungsmarker konnte nicht geschrieben werden; Stop wurde nicht gestartet.';$exitCode=1;continue}}
    try{New-Item -ItemType File -Path (Join-Path $directory.FullName 'stop.requested') -Force -ErrorAction Stop|Out-Null}catch{Write-Warning "Stop-Marker konnte nicht erstellt werden: $($directory.FullName)";$exitCode=1;continue}
    $launcherState=Get-State $session 'launcher'
    if($launcherState.State -eq 'Unknown'){Write-Warning 'Der Launcherzustand ist unbekannt; direkte parallele Bereinigung wäre unsicher.';$exitCode=1;continue}
    if($launcherState.State -eq 'Match'){
        $timer=[Diagnostics.Stopwatch]::StartNew()
        $cooperativeComplete=$false
        while($timer.Elapsed.TotalSeconds -lt 30){
            if(-not(Test-Path -LiteralPath $directory.FullName)){$cooperativeComplete=$true;break}
            $states=@(Get-State $session 'cloudflared';Get-State $session 'miniserve';Get-State $session 'watchdog')
            $effectiveKeep=$KeepArchives -or [bool]$session.keepArchive -or (Test-Path -LiteralPath (Join-Path $directory.FullName 'keep.archive') -PathType Leaf)
            if(@($states|Where-Object{$_.State -in @('Match','Unknown')}).Count -eq 0 -and $effectiveKeep){$cooperativeComplete=$true;break}
            Start-Sleep -Milliseconds 250
        }
        if($cooperativeComplete){continue}
        $launcherState=Get-State $session 'launcher'
        if($launcherState.State -in @('Match','Unknown')){Write-Warning 'Der Launcher hat die kooperative Bereinigung nicht bestätigt; die Sitzung bleibt erhalten.';$exitCode=1;continue}
    }
    try{$job=Open-WorkspaceJob -Name ([string]$session.jobName);try{Stop-WorkspaceJob -Job $job}finally{Close-WorkspaceJob -Job $job}}catch{}
    $cloudStopped=Stop-One $session 'cloudflared';Start-Sleep -Milliseconds 300;$serverStopped=Stop-One $session 'miniserve';$watchdogStopped=Stop-One $session 'watchdog'
    if(-not($cloudStopped -and $serverStopped -and $watchdogStopped)){Write-Warning 'Notfallbereinigung konnte nicht vollständig bestätigt werden; Sitzung bleibt erhalten.';$exitCode=1;continue}
    $effectiveKeep=$KeepArchives -or [bool]$session.keepArchive -or (Test-Path -LiteralPath (Join-Path $directory.FullName 'keep.archive') -PathType Leaf)
    if($effectiveKeep){continue}
    try{Remove-Item -LiteralPath $directory.FullName -Recurse -Force -ErrorAction Stop}catch{Write-Warning "Sitzung konnte nicht entfernt werden: $($directory.FullName)";$exitCode=1}
}
exit $exitCode
