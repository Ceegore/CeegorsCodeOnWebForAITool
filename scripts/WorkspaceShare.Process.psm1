Set-StrictMode -Version Latest

function Test-WorkspaceUnixHost { return ([IO.Path]::DirectorySeparatorChar -eq '/') }

function Get-WorkspaceProcessStartTicks {
    # Windows: UTC ticks of StartTime (unchanged). Linux: /proc/<pid>/stat start time in clock ticks since boot
    # (+1), the same number in every process (Process.StartTime derives from the wall clock and can differ).
    param([Parameter(Mandatory=$true)][Diagnostics.Process]$Process)
    if(-not(Test-WorkspaceUnixHost)){return [int64]$Process.StartTime.ToUniversalTime().Ticks}
    $text=[IO.File]::ReadAllText('/proc/'+$Process.Id+'/stat')
    $close=$text.LastIndexOf(')')
    if($close -lt 0){throw 'Unexpected /proc stat format.'}
    $fields=$text.Substring($close+2).Split(' ')
    if($fields.Count -lt 20){throw 'Unexpected /proc stat format.'}
    return ([int64]$fields[19]+1)
}

function Get-WorkspaceProcessPath {
    # Windows: Process.Path (unchanged). Linux: the /proc/<pid>/exe link; Process.Path can report "[vdso]"
    # for static executables such as miniserve and cloudflared.
    param([Parameter(Mandatory=$true)][Diagnostics.Process]$Process)
    if(Test-WorkspaceUnixHost){
        try{
            $target=(New-Object IO.FileInfo('/proc/'+$Process.Id+'/exe')).LinkTarget
            if(-not[string]::IsNullOrWhiteSpace($target)){return $target}
        }catch{}
    }
    return $Process.Path
}

function Test-WorkspaceZombie {
    # Linux: a terminated child that nobody has reaped yet (no /proc/<pid>/exe any more) counts as gone.
    param([int]$ProcessId)
    if(-not(Test-WorkspaceUnixHost)){return $false}
    try{
        $text=[IO.File]::ReadAllText('/proc/'+$ProcessId+'/stat')
        $close=$text.LastIndexOf(')')
        return ($close -ge 0 -and $text.Substring($close+2,1) -eq 'Z')
    }catch{return $false}
}

function Test-WorkspaceSameExecutable {
    # Equal full paths; on Linux also equal after symlink resolution (/proc/<pid>/exe is always resolved).
    param([string]$ActualPath,[string]$ExpectedPath)
    $a=[IO.Path]::GetFullPath($ActualPath);$b=[IO.Path]::GetFullPath($ExpectedPath)
    if($a -eq $b){return $true}
    if(-not(Test-WorkspaceUnixHost)){return $false}
    try{
        $realpath=(Get-Command realpath -CommandType Application -ErrorAction Stop|Select-Object -First 1).Source
        $ra=(& $realpath -e -- $a 2>$null);$rb=(& $realpath -e -- $b 2>$null)
        return ([bool]$ra -and [bool]$rb -and ([string]$ra).Trim() -eq ([string]$rb).Trim())
    }catch{return $false}
}

function New-ProcessState {
    param([string]$State,[Diagnostics.Process]$Process,[string]$Message='')
    [pscustomobject]@{ State=$State; Process=$Process; Message=$Message }
}

function Get-ProcessIdentityState {
    param([Parameter(Mandatory=$true)][int]$ProcessId,[Parameter(Mandatory=$true)][string]$ExpectedPath,[Parameter(Mandatory=$true)][long]$ExpectedStartTicks,[switch]$IncludeProcessHandle)
    if($ProcessId -le 0 -or [string]::IsNullOrWhiteSpace($ExpectedPath) -or $ExpectedStartTicks -le 0){return New-ProcessState Unknown $null 'Invalid process identity input.'}
    try{$process=Get-Process -Id $ProcessId -ErrorAction Stop}
    catch [System.ArgumentException]{return New-ProcessState Absent $null}
    catch [System.Management.Automation.ItemNotFoundException]{return New-ProcessState Absent $null}
    catch [Microsoft.PowerShell.Commands.ProcessCommandException]{
        if([string]$_.FullyQualifiedErrorId -like 'NoProcessFoundForGivenId*'){return New-ProcessState Absent $null}
        return New-ProcessState Unknown $null $_.Exception.Message
    }
    catch{return New-ProcessState Unknown $null $_.Exception.Message}
    try {
        # Cache the handle before verifying, so a later Kill() acts on this exact process even if the PID is reused.
        try{$null=$process.Handle}catch{}
        $path=Get-WorkspaceProcessPath -Process $process
        $ticks=Get-WorkspaceProcessStartTicks -Process $process
        if([string]::IsNullOrWhiteSpace($path)){if(Test-WorkspaceZombie -ProcessId $ProcessId){try{$process.Dispose()}catch{};return New-ProcessState Absent $null};try{$process.Dispose()}catch{};return New-ProcessState Unknown $null 'Process path is unavailable.'}
        if((Test-WorkspaceSameExecutable -ActualPath $path -ExpectedPath $ExpectedPath) -and $ticks -eq $ExpectedStartTicks){if($IncludeProcessHandle){return New-ProcessState Match $process};try{$process.Dispose()}catch{};return New-ProcessState Match $null}
        try{$process.Dispose()}catch{}
        return New-ProcessState Conflict $null ("The PID belongs to another process (path '{0}' start {1}; expected path '{2}' start {3})." -f $path,$ticks,$ExpectedPath,$ExpectedStartTicks)
    }
    catch { try{$process.Dispose()}catch{}; return New-ProcessState Unknown $null $_.Exception.Message }
}

function Stop-TrackedProcessConfirmed {
    param([Parameter(Mandatory=$true)][int]$ProcessId,[Parameter(Mandatory=$true)][string]$ExpectedPath,[Parameter(Mandatory=$true)][long]$ExpectedStartTicks,[ValidateRange(1,120)][int]$Attempts=10,[ValidateRange(50,10000)][int]$WaitMilliseconds=1000)
    for($attempt=1;$attempt -le $Attempts;$attempt++){
        $state=Get-ProcessIdentityState -ProcessId $ProcessId -ExpectedPath $ExpectedPath -ExpectedStartTicks $ExpectedStartTicks -IncludeProcessHandle
        switch($state.State){
            'Absent' { return $true }
            'Conflict' { return $true }
            'Unknown' { if($attempt -lt $Attempts){Start-Sleep -Milliseconds $WaitMilliseconds}; continue }
            'Match' {
                try {
                    # Kill through the already identity-verified Process handle, not a fresh PID lookup.
                    $state.Process.Kill()
                    [void]$state.Process.WaitForExit($WaitMilliseconds)
                } catch {} finally { try{$state.Process.Dispose()}catch{} }
            }
        }
        Start-Sleep -Milliseconds 50
    }
    $final=Get-ProcessIdentityState -ProcessId $ProcessId -ExpectedPath $ExpectedPath -ExpectedStartTicks $ExpectedStartTicks
    try{if($final.Process){$final.Process.Dispose()}}catch{}
    return ($final.State -in @('Absent','Conflict'))
}

Export-ModuleMember -Function @('Get-ProcessIdentityState','Stop-TrackedProcessConfirmed','Get-WorkspaceProcessStartTicks','Get-WorkspaceProcessPath')
