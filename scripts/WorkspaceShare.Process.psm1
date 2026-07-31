Set-StrictMode -Version Latest

function Get-ProcessIdentityState {
    param([Parameter(Mandatory = $true)][int]$ProcessId,[Parameter(Mandatory = $true)][string]$ExpectedPath,[Parameter(Mandatory = $true)][long]$ExpectedStartTicks)
    if($ProcessId -le 0 -or [string]::IsNullOrWhiteSpace($ExpectedPath) -or $ExpectedStartTicks -le 0){return [pscustomobject]@{State='Unknown';Process=$null;Message='Invalid process identity input.'}}
    try{$process=Get-Process -Id $ProcessId -ErrorAction Stop}catch [System.ArgumentException]{return [pscustomobject]@{State='Absent';Process=$null;Message=''}}catch [System.Management.Automation.ItemNotFoundException]{return [pscustomobject]@{State='Absent';Process=$null;Message=''}}catch [Microsoft.PowerShell.Commands.ProcessCommandException]{return [pscustomobject]@{State='Absent';Process=$null;Message=''}}catch{return [pscustomobject]@{State='Unknown';Process=$null;Message=$_.Exception.Message}}
    try{$path=$process.Path;$ticks=$process.StartTime.ToUniversalTime().Ticks;if([string]::IsNullOrWhiteSpace($path)){return [pscustomobject]@{State='Unknown';Process=$process;Message='Process path is unavailable.'}};if([IO.Path]::GetFullPath($path) -eq [IO.Path]::GetFullPath($ExpectedPath) -and $ticks -eq $ExpectedStartTicks){return [pscustomobject]@{State='Match';Process=$process;Message=''}};return [pscustomobject]@{State='Conflict';Process=$process;Message='The PID belongs to another process.'}}catch{return [pscustomobject]@{State='Unknown';Process=$process;Message=$_.Exception.Message}}
}

function Stop-TrackedProcessConfirmed {
    param([Parameter(Mandatory = $true)][int]$ProcessId,[Parameter(Mandatory = $true)][string]$ExpectedPath,[Parameter(Mandatory = $true)][long]$ExpectedStartTicks,[ValidateRange(1,60)][int]$Attempts=10,[ValidateRange(100,10000)][int]$WaitMilliseconds=1000)
    for($attempt=1;$attempt -le $Attempts;$attempt++){$state=Get-ProcessIdentityState -ProcessId $ProcessId -ExpectedPath $ExpectedPath -ExpectedStartTicks $ExpectedStartTicks;switch($state.State){'Absent'{return $true}'Conflict'{return $true}'Unknown'{if($attempt -eq $Attempts){return $false};Start-Sleep -Milliseconds $WaitMilliseconds;continue}'Match'{try{Stop-Process -Id $ProcessId -Force -ErrorAction Stop}catch{};try{[void]$state.Process.WaitForExit($WaitMilliseconds)}catch{};try{$state.Process.Dispose()}catch{}}};Start-Sleep -Milliseconds 100}
    return $false
}

Export-ModuleMember -Function @('Get-ProcessIdentityState','Stop-TrackedProcessConfirmed')
