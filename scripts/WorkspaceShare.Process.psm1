Set-StrictMode -Version Latest

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
    catch [Microsoft.PowerShell.Commands.ProcessCommandException]{return New-ProcessState Absent $null}
    catch{return New-ProcessState Unknown $null $_.Exception.Message}
    try {
        $path=$process.Path
        $ticks=$process.StartTime.ToUniversalTime().Ticks
        if([string]::IsNullOrWhiteSpace($path)){try{$process.Dispose()}catch{};return New-ProcessState Unknown $null 'Process path is unavailable.'}
        if([IO.Path]::GetFullPath($path) -eq [IO.Path]::GetFullPath($ExpectedPath) -and $ticks -eq $ExpectedStartTicks){if($IncludeProcessHandle){return New-ProcessState Match $process};try{$process.Dispose()}catch{};return New-ProcessState Match $null}
        try{$process.Dispose()}catch{}
        return New-ProcessState Conflict $null 'The PID belongs to another process.'
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

Export-ModuleMember -Function @('Get-ProcessIdentityState','Stop-TrackedProcessConfirmed')
