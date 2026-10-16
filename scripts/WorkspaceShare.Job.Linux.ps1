# Linux implementation of the WorkspaceShare.Job function names (loaded by WorkspaceShare.Job.psm1 on
# non-Windows hosts; PowerShell 7). A "job" is a named list of child process groups:
#  - every child is started with setsid, so it leads its own session and process group;
#  - the job is stopped with kill -TERM -- -<pgid>, then kill -KILL -- -<pgid>;
#  - the list lives in a small registry file under the data folder, so the watchdog and Stop-WorkspaceShare
#    (other processes) can open the job by name, like Open-WorkspaceJob on Windows;
#  - a process is only signalled when /proc/<pid>/stat still shows the recorded start time and pgrp == pid.
# There is no kill-on-close on Linux when the launcher is killed hard; the watchdog covers that.
Set-StrictMode -Version Latest

$script:WsJobs = @{}
$script:WsJobNext = [int64]0

function Get-WsLinuxProcStat {
    # @{ State; ParentPid; Pgrp; Ticks } for a live process, $null when /proc/<pid>/stat is gone.
    param([int]$ProcessId)
    try {
        $text = [IO.File]::ReadAllText('/proc/' + $ProcessId + '/stat')
        $close = $text.LastIndexOf(')')
        if ($close -lt 0) { return $null }
        $fields = $text.Substring($close + 2).Split(' ')
        if ($fields.Count -lt 20) { return $null }
        return @{ State = [string]$fields[0]; ParentPid = [int]$fields[1]; Pgrp = [int]$fields[2]; Ticks = ([int64]$fields[19] + 1) }
    }
    catch { return $null }
}

function Get-WsJobDirectory {
    $base = $env:XDG_DATA_HOME
    if ([string]::IsNullOrWhiteSpace($base)) {
        $home1 = $env:HOME
        if ([string]::IsNullOrWhiteSpace($home1)) { $home1 = [Environment]::GetFolderPath('UserProfile') }
        $base = Join-Path (Join-Path $home1 '.local') 'share'
    }
    $dir = Join-Path (Join-Path $base 'workspaceshare') 'jobs'
    if (-not (Test-Path -LiteralPath $dir -PathType Container)) {
        [void](New-Item -ItemType Directory -Path $dir -Force)
        try { [IO.File]::SetUnixFileMode($dir, [IO.UnixFileMode]'UserRead,UserWrite,UserExecute') } catch { }
    }
    return $dir
}

function Get-WsJobFile {
    param([string]$Name)
    if ([string]::IsNullOrWhiteSpace($Name)) { throw 'A job name is required.' }
    return (Join-Path (Get-WsJobDirectory) (($Name -replace '[^A-Za-z0-9._-]', '_') + '.job'))
}

function Read-WsJobEntries {
    # Entries "pid ticks mode" (mode g = process group leader, p = single process).
    param([string]$Path)
    $entries = New-Object System.Collections.Generic.List[object]
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return @() }
    foreach ($line in @([IO.File]::ReadAllLines($Path))) {
        $parts = $line.Trim().Split(' ')
        if ($parts.Count -ne 3) { continue }
        $id = 0; $ticks = [int64]0
        if (-not [int]::TryParse($parts[0], [ref]$id)) { continue }
        if (-not [int64]::TryParse($parts[1], [ref]$ticks)) { continue }
        $entries.Add(@{ Pid = $id; Ticks = $ticks; Mode = [string]$parts[2] })
    }
    return @($entries.ToArray())
}

function Add-WsJobEntry {
    param($Job, [int]$ProcessId, [string]$Mode)
    $stat = Get-WsLinuxProcStat $ProcessId
    if ($null -eq $stat) { throw ('Process ' + $ProcessId + ' is not running; it cannot be added to the job.') }
    [IO.File]::AppendAllText($Job.Path, ('{0} {1} {2}' -f $ProcessId, $stat.Ticks, $Mode) + "`n")
}

function Get-WsJob {
    param([IntPtr]$Handle)
    $key = $Handle.ToInt64()
    if (-not $script:WsJobs.ContainsKey($key)) { throw 'The job handle is not valid.' }
    return $script:WsJobs[$key]
}

function Get-WsLiveEntries {
    # Entries whose process still has the recorded identity (alive, same start time, group leader for mode g).
    param($Job)
    $live = New-Object System.Collections.Generic.List[object]
    foreach ($entry in @(Read-WsJobEntries $Job.Path)) {
        $stat = Get-WsLinuxProcStat $entry.Pid
        if ($null -eq $stat -or $stat.State -eq 'Z' -or $stat.State -eq 'X') { continue }
        if ($stat.Ticks -ne $entry.Ticks) { continue }
        if ($entry.Mode -eq 'g' -and $stat.Pgrp -ne $entry.Pid) { continue }
        $live.Add($entry)
    }
    return @($live.ToArray())
}

function Send-WsSignal {
    param([string]$Signal, [object[]]$Entries)
    if (@($Entries).Count -eq 0) { return }
    $script = 'sig=$1; shift; k=/bin/kill; [ -x "$k" ] || k=/usr/bin/kill; for e in "$@"; do mode=${e%%:*}; p=${e#*:}; if [ "$mode" = g ]; then target="-$p"; else target="$p"; fi; if [ -x "$k" ]; then "$k" -s "$sig" -- "$target" 2>/dev/null; else kill -s "$sig" -- "$target" 2>/dev/null; fi; done; exit 0'
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = '/bin/sh'
    foreach ($argument in @('-c', $script, 'sh', $Signal)) { [void]$psi.ArgumentList.Add($argument) }
    foreach ($entry in @($Entries)) { [void]$psi.ArgumentList.Add(('{0}:{1}' -f $entry.Mode, $entry.Pid)) }
    $psi.UseShellExecute = $false
    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $psi
    try { [void]$process.Start(); [void]$process.WaitForExit(10000) } finally { $process.Dispose() }
}

function New-WorkspaceChildEnvironment {
    param([hashtable]$Additional = @{}, [switch]$AllowProxy)
    $environment = @{}
    $environment['PATH'] = '/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin'
    foreach ($name in @('HOME', 'USER', 'LOGNAME', 'LANG', 'LC_ALL', 'TMPDIR', 'TZ', 'SSL_CERT_FILE', 'SSL_CERT_DIR')) {
        $value = [Environment]::GetEnvironmentVariable($name, 'Process')
        if (-not [string]::IsNullOrWhiteSpace($value)) { $environment[$name] = $value }
    }
    if (-not $environment.ContainsKey('LANG') -and -not $environment.ContainsKey('LC_ALL')) { $environment['LC_ALL'] = 'C.UTF-8' }
    if (-not $environment.ContainsKey('HOME')) { $environment['HOME'] = [Environment]::GetFolderPath('UserProfile') }
    if ($AllowProxy) {
        foreach ($name in @('HTTP_PROXY', 'HTTPS_PROXY', 'NO_PROXY', 'http_proxy', 'https_proxy', 'no_proxy')) {
            $value = [Environment]::GetEnvironmentVariable($name, 'Process')
            if (-not [string]::IsNullOrWhiteSpace($value)) { $environment[$name] = $value }
        }
    }
    foreach ($name in $Additional.Keys) { $environment[[string]$name] = [string]$Additional[$name] }
    return $environment
}

function ConvertTo-WorkspaceEnvironmentEntries {
    param([hashtable]$Environment)
    @($Environment.Keys | Sort-Object | ForEach-Object { $name = [string]$_; $value = [string]$Environment[$_]; if ($name -match '[=\x00]' -or $value -match '\x00') { throw 'Invalid child environment entry.' }; '{0}={1}' -f $name, $value })
}

function New-WorkspaceJob {
    param([Parameter(Mandatory = $true)][string]$Name)
    $path = Get-WsJobFile $Name
    if (Test-Path -LiteralPath $path) { throw 'A Job Object with this name already exists.' }
    [IO.File]::WriteAllText($path, '')
    try { [IO.File]::SetUnixFileMode($path, [IO.UnixFileMode]'UserRead,UserWrite') } catch { }
    $script:WsJobNext = $script:WsJobNext + 1
    $script:WsJobs[$script:WsJobNext] = @{ Name = $Name; Path = $path; Owner = $true }
    return [IntPtr]$script:WsJobNext
}

function Open-WorkspaceJob {
    param([Parameter(Mandatory = $true)][string]$Name)
    $path = Get-WsJobFile $Name
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw 'OpenJobObject: the job does not exist.' }
    $script:WsJobNext = $script:WsJobNext + 1
    $script:WsJobs[$script:WsJobNext] = @{ Name = $Name; Path = $path; Owner = $false }
    return [IntPtr]$script:WsJobNext
}

function Add-ProcessToWorkspaceJob {
    # Adds a single, already running process (not its group: it is not a group leader).
    param([Parameter(Mandatory = $true)][IntPtr]$Job, [Parameter(Mandatory = $true)][int]$ProcessId)
    Add-WsJobEntry (Get-WsJob $Job) $ProcessId 'p'
}

function Start-WorkspaceProcessInJob {
    param([Parameter(Mandatory = $true)][IntPtr]$Job, [Parameter(Mandatory = $true)][string]$FilePath, [string[]]$Arguments = @(), [string]$WorkingDirectory, [Parameter(Mandatory = $true)][string]$StdOutPath, [Parameter(Mandatory = $true)][string]$StdErrPath, [AllowNull()][string]$StandardInputText = $null, [hashtable]$Environment, [switch]$TestForceResumeFailure)
    $jobObject = Get-WsJob $Job
    if ($null -eq $Environment) { $Environment = New-WorkspaceChildEnvironment }
    $entries = ConvertTo-WorkspaceEnvironmentEntries $Environment
    # umask 077: logs and extracted files are private. setsid: own session/process group (no fork: the
    # shell is not a group leader). stdin is /dev/null unless the caller passes text through a pipe.
    $redirect = '>"$out" 2>"$err"'
    if ($null -eq $StandardInputText) { $redirect = $redirect + ' </dev/null' }
    $script = 'umask 077; out=$1; err=$2; shift 2; if command -v setsid >/dev/null 2>&1; then exec setsid "$@" ' + $redirect + '; else exec "$@" ' + $redirect + '; fi'
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = '/bin/sh'
    foreach ($argument in @('-c', $script, 'sh', $StdOutPath, $StdErrPath, $FilePath)) { [void]$psi.ArgumentList.Add($argument) }
    foreach ($argument in @($Arguments)) { [void]$psi.ArgumentList.Add([string]$argument) }
    $psi.UseShellExecute = $false
    $psi.RedirectStandardInput = ($null -ne $StandardInputText)
    if (-not [string]::IsNullOrEmpty($WorkingDirectory)) { $psi.WorkingDirectory = $WorkingDirectory }
    $psi.Environment.Clear()
    foreach ($entry in $entries) {
        $separator = $entry.IndexOf('=')
        $psi.Environment[$entry.Substring(0, $separator)] = $entry.Substring($separator + 1)
    }
    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $psi
    try {
        [void]$process.Start()
        if ($TestForceResumeFailure) { throw 'Injected ResumeThread failure.' }
        if ($null -ne $StandardInputText) {
            $bytes = (New-Object System.Text.UTF8Encoding($false)).GetBytes($StandardInputText)
            if ($bytes.Length -gt 0) { $process.StandardInput.BaseStream.Write($bytes, 0, $bytes.Length); $process.StandardInput.BaseStream.Flush() }
            $process.StandardInput.Close()
        }
        # Wait until sh -> setsid -> target exec chain has finished (the identity then shows the target binary).
        $expected = [IO.Path]::GetFullPath($FilePath)
        $watch = [Diagnostics.Stopwatch]::StartNew()
        $mode = 'p'
        while ($watch.ElapsedMilliseconds -lt 3000) {
            $stat = Get-WsLinuxProcStat $process.Id
            if ($null -eq $stat -or $process.HasExited) { break }
            $target = $null
            try { $target = (New-Object System.IO.FileInfo('/proc/' + $process.Id + '/exe')).LinkTarget } catch { $target = $null }
            $reached = $false
            if ($target) {
                $targetName = [IO.Path]::GetFileName($target)
                if ($target -eq $expected -or $targetName -eq [IO.Path]::GetFileName($expected)) { $reached = $true }
                elseif ($stat.Pgrp -eq $process.Id -and $targetName -ne 'setsid') { $reached = $true }   # setsid done, target binary is another name (symlink / multi-call)
            }
            if ($reached) {
                if ($stat.Pgrp -eq $process.Id) { $mode = 'g' }
                break
            }
            Start-Sleep -Milliseconds 10
        }
        $stat = Get-WsLinuxProcStat $process.Id
        if ($null -ne $stat -and $stat.Pgrp -eq $process.Id) { $mode = 'g' }
        if ($null -ne $stat) {
            [IO.File]::AppendAllText($jobObject.Path, ('{0} {1} {2}' -f $process.Id, $stat.Ticks, $mode) + "`n")
        }
        return $process
    }
    catch {
        try { if (-not $process.HasExited) { $process.Kill($true) } } catch { }
        try { $process.Dispose() } catch { }
        throw
    }
}

function Read-WorkspaceBoundedText { param([string]$Path, [int]$MaximumBytes = 4194304); if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return '' }; $stream = New-Object IO.FileStream($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite); try { $length = [Math]::Min([int64]$MaximumBytes, $stream.Length); [void]$stream.Seek(-$length, [IO.SeekOrigin]::End); $bytes = New-Object byte[] ([int]$length); [void]$stream.Read($bytes, 0, $bytes.Length); [Text.Encoding]::UTF8.GetString($bytes) } finally { $stream.Dispose() } }

function Invoke-WorkspaceNativeProcess {
    param([Parameter(Mandatory = $true)][IntPtr]$Job, [Parameter(Mandatory = $true)][string]$FilePath, [string[]]$Arguments = @(), [string]$WorkingDirectory, [ValidateRange(1, 86400)][int]$TimeoutSeconds = 300, [int[]]$ExpectedExitCodes = @(0), [string]$StdOutPath, [string]$StdErrPath, [AllowNull()][string]$StandardInputText = $null, [hashtable]$Environment, [switch]$KeepLogs)
    $base = if ($WorkingDirectory) { $WorkingDirectory } else { [IO.Path]::GetTempPath() }
    $id = [Guid]::NewGuid().ToString('N')
    $createdOut = [string]::IsNullOrWhiteSpace($StdOutPath); $createdErr = [string]::IsNullOrWhiteSpace($StdErrPath)
    if ($createdOut) { $StdOutPath = Join-Path $base ('.workspace-native-' + $id + '.stdout.log') }
    if ($createdErr) { $StdErrPath = Join-Path $base ('.workspace-native-' + $id + '.stderr.log') }
    $process = $null
    try {
        $process = Start-WorkspaceProcessInJob -Job $Job -FilePath $FilePath -Arguments $Arguments -WorkingDirectory $WorkingDirectory -StdOutPath $StdOutPath -StdErrPath $StdErrPath -StandardInputText $StandardInputText -Environment $Environment
        if (-not $process.WaitForExit($TimeoutSeconds * 1000)) {
            try { Stop-WorkspaceJob -Job $Job } catch { }
            throw "Native process exceeded $TimeoutSeconds seconds; the session Job was terminated."
        }
        $process.WaitForExit()
        $exitCode = [int]$process.ExitCode
        $stdout = Read-WorkspaceBoundedText $StdOutPath
        $stderr = Read-WorkspaceBoundedText $StdErrPath
        if ($ExpectedExitCodes -notcontains $exitCode) { throw "Native process failed with exit $exitCode. $stderr" }
        [pscustomobject]@{ ExitCode = $exitCode; StdOut = $stdout; StdErr = $stderr; StdOutPath = $StdOutPath; StdErrPath = $StdErrPath }
    }
    finally {
        try { if ($process) { $process.Dispose() } } catch { }
        if (-not $KeepLogs) {
            if ($createdOut) { Remove-Item -LiteralPath $StdOutPath -Force -ErrorAction SilentlyContinue }
            if ($createdErr) { Remove-Item -LiteralPath $StdErrPath -Force -ErrorAction SilentlyContinue }
        }
    }
}

function Stop-WorkspaceJob {
    param([Parameter(Mandatory = $true)][IntPtr]$Job)
    $jobObject = Get-WsJob $Job
    $live = @(Get-WsLiveEntries $jobObject)
    if ($live.Count -eq 0) { return }
    Send-WsSignal 'TERM' $live
    $watch = [Diagnostics.Stopwatch]::StartNew()
    while ($watch.ElapsedMilliseconds -lt 2000) {
        $live = @(Get-WsLiveEntries $jobObject)
        if ($live.Count -eq 0) { return }
        Start-Sleep -Milliseconds 100
    }
    Send-WsSignal 'KILL' $live
    $watch.Restart()
    while ($watch.ElapsedMilliseconds -lt 3000) {
        if (@(Get-WsLiveEntries $jobObject).Count -eq 0) { return }
        Start-Sleep -Milliseconds 50
    }
}

function Close-WorkspaceJob {
    param([Parameter(Mandatory = $true)][IntPtr]$Job)
    if ($Job -eq [IntPtr]::Zero) { return }
    $key = $Job.ToInt64()
    if (-not $script:WsJobs.ContainsKey($key)) { return }
    $jobObject = $script:WsJobs[$key]
    # The owner's close terminates what is left (kill-on-close); a reader's close only drops its handle.
    if ($jobObject.Owner) { try { Stop-WorkspaceJob -Job $Job } catch { } }
    $script:WsJobs.Remove($key)
    if ($jobObject.Owner -or @(Get-WsLiveEntries $jobObject).Count -eq 0) {
        Remove-Item -LiteralPath $jobObject.Path -Force -ErrorAction SilentlyContinue
    }
}

Export-ModuleMember -Function @('New-WorkspaceChildEnvironment', 'New-WorkspaceJob', 'Open-WorkspaceJob', 'Add-ProcessToWorkspaceJob', 'Start-WorkspaceProcessInJob', 'Invoke-WorkspaceNativeProcess', 'Stop-WorkspaceJob', 'Close-WorkspaceJob')
