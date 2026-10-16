#requires -Version 5.1
<#
.SYNOPSIS
    Linux-specific checks of the platform layer (PowerShell 7): process groups, job registry, path identity,
    symlink rejection, watchdog, instance lock, end-to-end snapshot rules. Skipped on Windows.

.DESCRIPTION
    Every check prints [PASS]/[FAIL]/[SKIP]; an unexpected exception inside a check is reported as [FAIL]
    and the run continues. Exit 0 = all passed, 1 = at least one failure.
#>
[CmdletBinding()]
param([string]$ToolRoot)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
if ([string]::IsNullOrWhiteSpace($ToolRoot)) { $ToolRoot = Split-Path $PSScriptRoot -Parent }

if ([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT) {
    Write-Host '[SKIP] Test-LinuxPlatform: nur unter Linux (PowerShell 7) sinnvoll.'
    exit 0
}

$script:Pass = 0
$script:Fail = 0
function Assert-True {
    param($Condition, [string]$Name)
    if ([bool]$Condition) { $script:Pass++; Write-Host "[PASS] $Name" }
    else { $script:Fail++; Write-Host "[FAIL] $Name" }
}
function Skip-Check { param([string]$Name) Write-Host "[SKIP] $Name" }
function Invoke-Check {
    # Runs one named block; an exception counts as a failure but never stops the run.
    param([string]$Name, [scriptblock]$Block)
    Write-Host ''
    Write-Host ('--- ' + $Name)
    try { & $Block }
    catch {
        $script:Fail++
        Write-Host ('[FAIL] ' + $Name + ': unexpected error: ' + $_.Exception.Message)
        Write-Host ('       at ' + ($_.InvocationInfo.PositionMessage -replace "`r?`n", ' | '))
    }
}

$scripts = Join-Path $ToolRoot 'scripts'
$tmp = Join-Path ([IO.Path]::GetTempPath()) ('ws-linux-test-' + [Guid]::NewGuid().ToString('N'))
[void](New-Item -ItemType Directory -Path $tmp -Force)
$pwshPath = Join-Path $PSHOME 'pwsh'
$bin = Join-Path (Join-Path $ToolRoot 'bin') 'linux-x64'

Write-Host 'WorkspaceShare - Linux platform checks'
Write-Host '======================================'
Write-Host ('PowerShell : ' + $PSVersionTable.PSVersion + ' (' + $PSVersionTable.PSEdition + ')')
Write-Host ('OS         : ' + [Runtime.InteropServices.RuntimeInformation]::OSDescription + ' / ' + [Runtime.InteropServices.RuntimeInformation]::OSArchitecture)
Write-Host ('User/HOME  : ' + [Environment]::UserName + ' ' + $env:HOME)
Write-Host ('DISPLAY    : [' + $env:DISPLAY + '] WAYLAND_DISPLAY: [' + $env:WAYLAND_DISPLAY + ']')
foreach ($tool in 'sh', 'setsid', 'kill', 'tar', 'xz', 'curl', 'realpath', 'stat', 'ss', 'dig', 'systemd-inhibit', 'zenity', 'kdialog', 'xclip', 'wl-copy', 'xdg-open', 'sleep', 'cat', 'env') {
    $found = Get-Command $tool -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    Write-Host ('tool {0,-16}: {1}' -f $tool, $(if ($found) { $found.Source } else { '-' }))
}

Import-Module (Join-Path $scripts 'WorkspaceShare.Platform.psm1') -Force
Import-Module (Join-Path $scripts 'WorkspaceShare.Process.psm1') -Force
Import-Module (Join-Path $scripts 'WorkspaceShare.Job.psm1') -Force
Import-Module (Join-Path $scripts 'WorkspaceShare.Path.psm1') -Force
Import-Module (Join-Path $scripts 'WorkspaceShare.Dependency.psm1') -Force

function Get-GroupMembers {
    # PIDs (not zombies) whose process group id is $GroupId.
    param([int]$GroupId)
    $members = @()
    foreach ($dir in [IO.Directory]::GetDirectories('/proc')) {
        $leaf = [IO.Path]::GetFileName($dir)
        if ($leaf -notmatch '^\d+$') { continue }
        try {
            $text = [IO.File]::ReadAllText($dir + '/stat')
            $fields = $text.Substring($text.LastIndexOf(')') + 2).Split(' ')
            if ([int]$fields[2] -eq $GroupId -and $fields[0] -ne 'Z') { $members += [int]$leaf }
        }
        catch { }
    }
    return $members
}

function Get-WsLinuxSelfGroup {
    $stat = [IO.File]::ReadAllText('/proc/self/stat')
    return [int]($stat.Substring($stat.LastIndexOf(')') + 2).Split(' ')[2])
}
function Wait-Until {
    param([scriptblock]$Condition, [int]$TimeoutSec = 15)
    $watch = [Diagnostics.Stopwatch]::StartNew()
    while ($watch.Elapsed.TotalSeconds -lt $TimeoutSec) {
        if (& $Condition) { return $true }
        Start-Sleep -Milliseconds 100
    }
    return [bool](& $Condition)
}

function Test-PidAlive {
    param([int]$ProcessId)
    $text = $null
    try { $text = [IO.File]::ReadAllText('/proc/' + $ProcessId + '/stat') } catch { return $false }
    $fields = $text.Substring($text.LastIndexOf(')') + 2).Split(' ')
    return ($fields[0] -ne 'Z')
}

# ------------------------------------------------------------------------------------------------
Invoke-Check 'platform module' {
    Assert-True ((Get-WsPlatform) -eq 'linux') 'Get-WsPlatform reports linux'
    $root = Get-WsDataRoot
    Assert-True ((Test-Path -LiteralPath $root -PathType Container) -and $root -like '*workspaceshare') 'Get-WsDataRoot returns an existing .../workspaceshare folder'
    $hostPath = Get-WsPowerShellHost
    Assert-True ((Test-Path -LiteralPath $hostPath -PathType Leaf) -and [IO.Path]::GetFileName($hostPath) -eq 'pwsh') 'Get-WsPowerShellHost returns the pwsh executable'
    $caps = Get-WsCapabilities
    Assert-True ($null -ne $caps.folderPicker -and $null -ne $caps.clipboard -and $null -ne $caps.openBrowser) 'Get-WsCapabilities has the three keys'
    Write-Host ('       capabilities: folderPicker={0} clipboard={1} openBrowser={2}' -f $caps.folderPicker, $caps.clipboard, $caps.openBrowser)
    Assert-True (-not (Open-WsBrowser -Url 'https://example.com/')) 'Open-WsBrowser refuses non-local URLs'
    $ticksA = Get-WsProcessStartTicks -ProcessId $PID
    $self = Get-Process -Id $PID
    $ticksB = Get-WorkspaceProcessStartTicks -Process $self
    $self.Dispose()
    Assert-True ($ticksA -gt 0 -and $ticksA -eq $ticksB) 'start ticks come from /proc/<pid>/stat in both modules'
    $private = Join-Path $tmp 'private-dir'
    [void](New-Item -ItemType Directory -Path $private)
    Set-WsPrivateDirectory -Path $private
    $mode = [int][IO.File]::GetUnixFileMode($private)
    Assert-True ($mode -eq 448) ("Set-WsPrivateDirectory sets chmod 700 (was: $([Convert]::ToString($mode, 8)))")
    $addresses = @(Get-WsResolvedAddress -Name 'localhost' -Type A)
    Assert-True ($addresses -contains '127.0.0.1') 'system resolver resolves localhost'
    Write-Host ('       public resolver comparison supported (dig): ' + (Test-WsPublicResolverSupport))
    $keep = Start-WsKeepAwake
    Write-Host ('       keep-awake helper: ' + $(if ($null -eq $keep) { 'not available (silently skipped)' } else { 'running, pid ' + $keep.Id }))
    Stop-WsKeepAwake -Process $keep
    if ($null -ne $keep) { Assert-True (Wait-Until { -not (Test-PidAlive $keep.Id) } 5) 'keep-awake helper stops' }
    else { Assert-True $true 'keep-awake is optional (systemd-inhibit missing or refused)' }
}

Invoke-Check 'instance lock (replaces named mutex)' {
    $dir = Join-Path $tmp 'locks'
    $a = New-WsInstanceLock -Name 'Local\WorkspaceShare.Gui' -Directory $dir
    $b = New-WsInstanceLock -Name 'Local\WorkspaceShare.Gui' -Directory $dir
    Assert-True ($a.WaitOne(0)) 'first lock owner acquires'
    Assert-True (-not $b.WaitOne(200)) 'second owner is refused while the first holds the lock'
    $a.ReleaseMutex()
    Assert-True ($b.WaitOne(1000)) 'second owner acquires after the first released'
    $b.Dispose()
    $c = New-WsInstanceLock -Name 'Local\WorkspaceShare.Gui' -Directory $dir
    Assert-True ($c.WaitOne(0)) 'lock can be taken again after Dispose'
    $c.Dispose()
}

Invoke-Check 'dependency lease' {
    $root = Join-Path $tmp 'lease-root'
    [void](New-Item -ItemType Directory -Path $root)
    $s1 = Enter-WorkspaceDependencyLease -ToolRoot $root -Mode Shared -TimeoutSeconds 2
    $s2 = Enter-WorkspaceDependencyLease -ToolRoot $root -Mode Shared -TimeoutSeconds 2
    Assert-True ($null -ne $s2) 'two shared leases coexist'
    $blocked = $false
    try { $x = Enter-WorkspaceDependencyLease -ToolRoot $root -Mode Exclusive -TimeoutSeconds 1; $x.Dispose() } catch { $blocked = ($_.Exception.Message -match 'could not be acquired within') }
    Assert-True $blocked 'exclusive lease is blocked while shared leases are held'
    $s1.Dispose(); $s2.Dispose()
    $e = Enter-WorkspaceDependencyLease -ToolRoot $root -Mode Exclusive -TimeoutSeconds 2
    Assert-True ($null -ne $e) 'exclusive lease works after the readers left'
    $e.Dispose()
}

Invoke-Check 'path identity and symlinks' {
    $real = Join-Path $tmp 'real-dir'
    [void](New-Item -ItemType Directory -Path $real)
    $link = Join-Path $tmp 'link-dir'
    [void](New-Item -ItemType SymbolicLink -Path $link -Target $real)
    $fileLink = Join-Path $tmp 'link-file'
    Set-Content -LiteralPath (Join-Path $real 'f.txt') -Value 'x'
    [void](New-Item -ItemType SymbolicLink -Path $fileLink -Target (Join-Path $real 'f.txt'))
    $a = Resolve-WorkspaceDirectoryIdentity -Path $real
    $b = Resolve-WorkspaceDirectoryIdentity -Path (Join-Path $real '.')
    $c = Resolve-WorkspaceDirectoryIdentity -Path $link
    Assert-True ($a.Identity -match '^\d+:\d+$') ("identity is device:inode ($($a.Identity))")
    Assert-True ($a.Identity -eq $b.Identity -and $a.FinalPath -eq $b.FinalPath) 'lexical aliases collapse to one identity'
    Assert-True ($c.Identity -eq $a.Identity -and $c.FinalPath -eq $a.FinalPath) 'a symlink resolves to its target identity and real path'
    Assert-True (Test-WorkspaceSymbolicLink -Path $link) 'Test-WorkspaceSymbolicLink: directory symlink detected'
    Assert-True (Test-WorkspaceSymbolicLink -Path $fileLink) 'Test-WorkspaceSymbolicLink: file symlink detected'
    Assert-True (-not (Test-WorkspaceSymbolicLink -Path $real)) 'Test-WorkspaceSymbolicLink: plain directory is not a link'
    $item = Get-Item -LiteralPath $link -Force
    Assert-True (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) 'a symlink carries the ReparsePoint attribute (the launcher gate relies on it)'
}

Invoke-Check 'process identity' {
    $self = Get-Process -Id $PID
    $ticks = Get-WorkspaceProcessStartTicks -Process $self
    $state = Get-ProcessIdentityState -ProcessId $PID -ExpectedPath $self.Path -ExpectedStartTicks $ticks
    Assert-True ($state.State -eq 'Match') 'own process: Match (path from /proc/<pid>/exe)'
    $wrong = Get-ProcessIdentityState -ProcessId $PID -ExpectedPath '/bin/true' -ExpectedStartTicks $ticks
    Assert-True ($wrong.State -eq 'Conflict') 'different executable path: Conflict'
    $wrongTicks = Get-ProcessIdentityState -ProcessId $PID -ExpectedPath $self.Path -ExpectedStartTicks ($ticks + 1)
    Assert-True ($wrongTicks.State -eq 'Conflict') 'different start time: Conflict'
    $absent = Get-ProcessIdentityState -ProcessId 2147483647 -ExpectedPath $self.Path -ExpectedStartTicks 1
    Assert-True ($absent.State -eq 'Absent') 'missing process: Absent'
    $self.Dispose()
    $sleeper = Start-Process -FilePath 'sleep' -ArgumentList @('60') -PassThru
    Start-Sleep -Milliseconds 200
    $sleeperTicks = Get-WorkspaceProcessStartTicks -Process $sleeper
    $aliasPath = (Get-Command sleep -CommandType Application | Select-Object -First 1).Source
    Assert-True ((Get-ProcessIdentityState -ProcessId $sleeper.Id -ExpectedPath $aliasPath -ExpectedStartTicks $sleeperTicks).State -eq 'Match') ('path given through a symlinked directory still matches (' + $aliasPath + ')')
    Assert-True (Stop-TrackedProcessConfirmed -ProcessId $sleeper.Id -ExpectedPath $aliasPath -ExpectedStartTicks $sleeperTicks -Attempts 5 -WaitMilliseconds 300) 'Stop-TrackedProcessConfirmed stops the tracked child'
    Assert-True (Wait-Until { -not (Test-PidAlive $sleeper.Id) } 5) 'tracked child is gone'
    $sleeper.Dispose()
}

Invoke-Check 'job: output, exit codes, stdin, environment, timeout' {
    $job = New-WorkspaceJob -Name ('Local\WorkspaceShare.LinuxTest.' + [Guid]::NewGuid().ToString('N'))
    try {
        $r = Invoke-WorkspaceNativeProcess -Job $job -FilePath '/bin/sh' -Arguments @('-c', 'echo native-ok; echo err-line 1>&2') -WorkingDirectory $tmp -TimeoutSeconds 20
        Assert-True ($r.ExitCode -eq 0 -and $r.StdOut -match 'native-ok' -and $r.StdErr -match 'err-line') 'stdout/stderr captured, exit 0'
        $rejected = $false
        try { [void](Invoke-WorkspaceNativeProcess -Job $job -FilePath '/bin/sh' -Arguments @('-c', 'exit 3') -WorkingDirectory $tmp -TimeoutSeconds 20) } catch { $rejected = ($_.Exception.Message -match 'exit 3') }
        Assert-True $rejected 'unexpected exit code 3 is rejected'
        $accepted = Invoke-WorkspaceNativeProcess -Job $job -FilePath '/bin/sh' -Arguments @('-c', 'exit 3') -WorkingDirectory $tmp -TimeoutSeconds 20 -ExpectedExitCodes @(0, 3)
        Assert-True ($accepted.ExitCode -eq 3) 'ExpectedExitCodes accepts 3'
        $cat = Invoke-WorkspaceNativeProcess -Job $job -FilePath (Get-Command cat -CommandType Application | Select-Object -First 1).Source -WorkingDirectory $tmp -TimeoutSeconds 20 -StandardInputText "private-stdin-text`n"
        Assert-True ($cat.StdOut -match 'private-stdin-text') 'text is delivered through a private stdin pipe'
        $env:WS_PARENT_CANARY = 'must-not-leak'
        $childEnv = New-WorkspaceChildEnvironment -Additional @{ WS_ALLOWED = 'yes' }
        $envOut = Invoke-WorkspaceNativeProcess -Job $job -FilePath (Get-Command env -CommandType Application | Select-Object -First 1).Source -WorkingDirectory $tmp -TimeoutSeconds 20 -Environment $childEnv
        Remove-Item Env:\WS_PARENT_CANARY -ErrorAction SilentlyContinue
        Assert-True ($envOut.StdOut -match '(?m)^WS_ALLOWED=yes' -and $envOut.StdOut -notmatch 'WS_PARENT_CANARY') 'child environment is an allowlist plus the explicit additions'
        Assert-True ($envOut.StdOut -match '(?m)^PATH=' -and $envOut.StdOut -match '(?m)^HOME=') 'child environment keeps PATH and HOME'
        $watch = [Diagnostics.Stopwatch]::StartNew()
        $timedOut = $false
        try { [void](Invoke-WorkspaceNativeProcess -Job $job -FilePath '/bin/sleep' -Arguments @('30') -WorkingDirectory $tmp -TimeoutSeconds 2) } catch { $timedOut = ($_.Exception.Message -match 'exceeded 2 seconds') }
        Assert-True ($timedOut -and $watch.Elapsed.TotalSeconds -lt 20) ('timeout is enforced and the child is killed (' + [int]$watch.Elapsed.TotalSeconds + ' s)')
    }
    finally { try { Stop-WorkspaceJob -Job $job } catch { }; try { Close-WorkspaceJob -Job $job } catch { } }
}

Invoke-Check 'job: process groups, cross-process stop, kill-on-close' {
    $name = 'Local\WorkspaceShare.LinuxGroup.' + [Guid]::NewGuid().ToString('N')
    $job = New-WorkspaceJob -Name $name
    $collision = $false
    try { $dup = New-WorkspaceJob -Name $name; try { Close-WorkspaceJob -Job $dup } catch { } } catch { $collision = ($_.Exception.Message -match 'already exists') }
    Assert-True $collision 'a second job with the same name is rejected'
    $out = Join-Path $tmp 'group.out'; $err = Join-Path $tmp 'group.err'
    $leader = Start-WorkspaceProcessInJob -Job $job -FilePath '/bin/sh' -Arguments @('-c', 'sleep 60 & sleep 60 & wait') -WorkingDirectory $tmp -StdOutPath $out -StdErrPath $err
    $leaderPid = $leader.Id
    Assert-True (Wait-Until { (Get-GroupMembers $leaderPid).Count -ge 3 } 10) ('child runs in its own process group with its subprocesses (members: ' + ((Get-GroupMembers $leaderPid) -join ',') + ')')
    $stat = [IO.File]::ReadAllText("/proc/$leaderPid/stat")
    $fields = $stat.Substring($stat.LastIndexOf(')') + 2).Split(' ')
    Assert-True ([int]$fields[2] -eq $leaderPid -and [int]$fields[3] -eq $leaderPid) 'child is group and session leader (setsid)'
    Assert-True ([int]$fields[2] -ne (Get-WsLinuxSelfGroup)) 'child is not in the launcher process group'
    # another process (the watchdog / Stop-WorkspaceShare case) opens the job by name and stops it
    $helper = Join-Path $tmp 'stop-job.ps1'
    Set-Content -LiteralPath $helper -Value @"
Import-Module '$((Join-Path $scripts 'WorkspaceShare.Job.psm1'))' -Force
`$j = Open-WorkspaceJob -Name '$name'
Stop-WorkspaceJob -Job `$j
Close-WorkspaceJob -Job `$j
"@
    $helperJob = New-WorkspaceJob -Name ('Local\WorkspaceShare.LinuxHelper.' + [Guid]::NewGuid().ToString('N'))
    $helperResult = Invoke-WorkspaceNativeProcess -Job $helperJob -FilePath $pwshPath -Arguments @('-NoProfile', '-NonInteractive', '-File', $helper) -WorkingDirectory $tmp -TimeoutSeconds 60 -ExpectedExitCodes @(0, 1)
    Write-Host ("       helper exit {0} {1} {2}" -f $helperResult.ExitCode, $helperResult.StdOut.Trim(), $helperResult.StdErr.Trim())
    Close-WorkspaceJob -Job $helperJob
    Assert-True (Wait-Until { (Get-GroupMembers $leaderPid).Count -eq 0 } 10) 'a second process stopped the whole group through Open-WorkspaceJob'
    Assert-True ($leader.WaitForExit(5000)) 'the .NET Process object saw the exit'
    $leader.Dispose()
    # kill-on-close: owner close terminates what is left
    $job2 = New-WorkspaceJob -Name ('Local\WorkspaceShare.LinuxClose.' + [Guid]::NewGuid().ToString('N'))
    $p2 = Start-WorkspaceProcessInJob -Job $job2 -FilePath '/bin/sleep' -Arguments @('60') -WorkingDirectory $tmp -StdOutPath (Join-Path $tmp 'c.out') -StdErrPath (Join-Path $tmp 'c.err')
    $p2Pid = $p2.Id
    Close-WorkspaceJob -Job $job2
    Assert-True ($p2.WaitForExit(10000)) 'closing the owner handle kills the remaining children'
    $p2.Dispose()
    # Add-ProcessToWorkspaceJob (single process mode)
    $job3 = New-WorkspaceJob -Name ('Local\WorkspaceShare.LinuxAdd.' + [Guid]::NewGuid().ToString('N'))
    $plain = Start-Process -FilePath 'sleep' -ArgumentList @('60') -PassThru
    Start-Sleep -Milliseconds 200
    Add-ProcessToWorkspaceJob -Job $job3 -ProcessId $plain.Id
    Stop-WorkspaceJob -Job $job3
    Assert-True ($plain.WaitForExit(10000)) 'a process added with Add-ProcessToWorkspaceJob is stopped (single-process mode)'
    Close-WorkspaceJob -Job $job3
    $plain.Dispose()
}

Invoke-Check 'watchdog (expiry and parent loss)' {
    $watchScript = Join-Path $scripts 'Watch-WorkspaceShare.ps1'
    foreach ($scenario in 'expiry', 'parent-exit') {
        $session = Join-Path $tmp ('watch-' + $scenario)
        [void](New-Item -ItemType Directory -Path $session)
        $archive = Join-Path $session 'archive.zip'
        [IO.File]::WriteAllText($archive, 'test')
        $jobName = 'Local\WorkspaceShare.LinuxWatch.' + [Guid]::NewGuid().ToString('N')
        $job = New-WorkspaceJob -Name $jobName
        $cloud = Start-WorkspaceProcessInJob -Job $job -FilePath '/bin/sleep' -Arguments @('120') -WorkingDirectory $session -StdOutPath (Join-Path $session 'cloud.out') -StdErrPath (Join-Path $session 'cloud.err')
        $server = Start-WorkspaceProcessInJob -Job $job -FilePath '/bin/sleep' -Arguments @('121') -WorkingDirectory $session -StdOutPath (Join-Path $session 'server.out') -StdErrPath (Join-Path $session 'server.err')
        $cloudPath = (Get-Process -Id $cloud.Id).Path
        $serverPath = (Get-Process -Id $server.Id).Path
        $parent = $null
        $parentProcess = $null
        if ($scenario -eq 'parent-exit') {
            $parentProcess = Start-Process -FilePath 'sleep' -ArgumentList @('4') -PassThru
            Start-Sleep -Milliseconds 300
            $parentId = $parentProcess.Id
            $parentPath = (Get-Process -Id $parentId).Path
            $parentTicks = Get-WorkspaceProcessStartTicks -Process $parentProcess
            $duration = 120
        }
        else {
            $self = Get-Process -Id $PID
            $parentId = $PID; $parentPath = $self.Path; $parentTicks = Get-WorkspaceProcessStartTicks -Process $self; $self.Dispose()
            $duration = 6
        }
        $startStamp = [Diagnostics.Stopwatch]::GetTimestamp()
        $durationTicks = [int64]($duration * [Diagnostics.Stopwatch]::Frequency)
        $ready = Join-Path $session 'watch.ready'
        $arguments = @('-NoProfile', '-NonInteractive', '-File', $watchScript,
            '-ParentPid', [string]$parentId, '-ParentStartTicks', [string]$parentTicks, '-ExpectedParentPath', $parentPath,
            '-MiniservePid', [string]$server.Id, '-MiniserveStartTicks', [string](Get-WorkspaceProcessStartTicks -Process $server),
            '-CloudflaredPid', [string]$cloud.Id, '-CloudflaredStartTicks', [string](Get-WorkspaceProcessStartTicks -Process $cloud),
            '-SessionPath', $session, '-ArchivePath', $archive, '-JobName', $jobName,
            '-NormalExitMarker', (Join-Path $session 'normal.exit'), '-ReadyMarker', $ready,
            '-ExpiresUtc', ([DateTime]::UtcNow.AddSeconds($duration).ToString('o')),
            '-StartTimestamp', [string]$startStamp, '-DurationTicks', [string]$durationTicks,
            '-ExpectedMiniservePath', $serverPath, '-ExpectedCloudflaredPath', $cloudPath)
        $watchdog = Start-WorkspaceProcessInJob -Job (New-WorkspaceJob -Name ('Local\WorkspaceShare.LinuxWatchHost.' + [Guid]::NewGuid().ToString('N'))) -FilePath $pwshPath -Arguments $arguments -WorkingDirectory $session -StdOutPath (Join-Path $tmp ('watch-' + $scenario + '.out')) -StdErrPath (Join-Path $tmp ('watch-' + $scenario + '.err'))
        Assert-True (Wait-Until { Test-Path -LiteralPath $ready } 30) "[$scenario] watchdog publishes readiness"
        Assert-True (Test-PidAlive $cloud.Id) "[$scenario] children are alive while the watchdog waits"
        $t0 = [Diagnostics.Stopwatch]::StartNew()
        $exited = $watchdog.WaitForExit(60000)
        Write-Host ("       [{0}] watchdog exit={1} after {2:N1}s" -f $scenario, $(if ($exited) { $watchdog.ExitCode } else { 'running' }), $t0.Elapsed.TotalSeconds)
        Assert-True $exited "[$scenario] watchdog ends"
        Assert-True ($cloud.WaitForExit(10000) -and $server.WaitForExit(10000)) "[$scenario] watchdog killed both tracked children"
        Assert-True (-not (Test-Path -LiteralPath $session)) "[$scenario] watchdog removed the session folder"
        foreach ($suffix in '.out', '.err') { $log = Join-Path $tmp ('watch-' + $scenario + $suffix); if ((Test-Path -LiteralPath $log) -and (Get-Item -LiteralPath $log).Length -gt 0) { Write-Host ('       watchdog ' + $suffix + ': ' + (Get-Content -LiteralPath $log -Raw)) } }
        if ($parentProcess) { try { $parentProcess.Kill() } catch { }; $parentProcess.Dispose() }
        try { Close-WorkspaceJob -Job $job } catch { }
    }
}

Invoke-Check 'installed dependencies run' {
    $lockPath = Join-Path $ToolRoot 'dependencies.lock.json'
    if (-not (Test-Path -LiteralPath $lockPath -PathType Leaf)) { Skip-Check 'dependencies.lock.json fehlt (Install-Dependencies.ps1 nicht gelaufen)'; return }
    $lock = Get-Content -LiteralPath $lockPath -Raw | ConvertFrom-Json
    Assert-True ([string]$lock.platform -eq 'linux-x64' -and [bool]$lock.installed) 'lockfile: platform linux-x64, installed'
    $job = New-WorkspaceJob -Name ('Local\WorkspaceShare.LinuxVer.' + [Guid]::NewGuid().ToString('N'))
    try {
        foreach ($check in @(@('cloudflared', '--version', '2026.7.2'), @('miniserve', '--version', '0.35.0'), @('gitleaks', 'version', '8.30.1'), @('7zz', 'i', '26.02'))) {
            $exe = Join-Path $bin $check[0]
            $result = Invoke-WorkspaceNativeProcess -Job $job -FilePath $exe -Arguments @($check[1]) -WorkingDirectory $tmp -TimeoutSeconds 30
            Assert-True ($result.StdOut -match [regex]::Escape($check[2])) ("{0} runs and reports {1}" -f $check[0], $check[2])
            $mode = [string][IO.File]::GetUnixFileMode($exe)
            Assert-True ($mode -match 'UserExecute') ("{0} is executable" -f $check[0])
        }
    }
    finally { try { Stop-WorkspaceJob -Job $job } catch { }; try { Close-WorkspaceJob -Job $job } catch { } }
}


function Invoke-ShareScript {
    param([string[]]$Arguments)
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $pwshPath
    foreach ($a in (@('-NoLogo', '-NoProfile', '-NonInteractive', '-File', (Join-Path $ToolRoot 'Share-Workspace.ps1')) + @($Arguments))) { [void]$psi.ArgumentList.Add($a) }
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.RedirectStandardInput = $true
    $p = New-Object System.Diagnostics.Process
    $p.StartInfo = $psi
    [void]$p.Start()
    $p.StandardInput.Close()
    $o = $p.StandardOutput.ReadToEndAsync()
    $e = $p.StandardError.ReadToEndAsync()
    if (-not $p.WaitForExit(300000)) { try { $p.Kill($true) } catch { } }
    $p.WaitForExit()
    $result = [pscustomobject]@{ ExitCode = $p.ExitCode; Lines = @($o.Result -split "\r?\n" | Where-Object { $_ -ne '' }); StdErr = $e.Result }
    $p.Dispose()
    return $result
}

Invoke-Check 'launcher end-to-end (snapshot stage, no network)' {
    if (-not (Test-Path -LiteralPath (Join-Path $ToolRoot 'dependencies.lock.json') -PathType Leaf)) { Skip-Check 'Abhängigkeiten nicht installiert'; return }
    $ws = Join-Path $tmp 'workspace'
    foreach ($d in 'sub', '.git', 'node_modules', 'Mixed Case Dir') { [void](New-Item -ItemType Directory -Path (Join-Path $ws $d) -Force) }
    Set-Content -LiteralPath (Join-Path $ws 'hello.txt') -Value 'hello' -Encoding ASCII
    Set-Content -LiteralPath (Join-Path $ws 'README.MD') -Value 'upper' -Encoding ASCII
    Set-Content -LiteralPath (Join-Path $ws 'readme.md') -Value 'lower' -Encoding ASCII
    Set-Content -LiteralPath (Join-Path (Join-Path $ws 'Mixed Case Dir') ('Stra' + [char]0xDF + 'e [1] (x).txt')) -Value 'umlaut' -Encoding UTF8
    Set-Content -LiteralPath (Join-Path (Join-Path $ws 'sub') 'readme.md') -Value '# readme' -Encoding ASCII
    Set-Content -LiteralPath (Join-Path (Join-Path $ws 'sub') '.npmrc') -Value 'registry=https://example.invalid/' -Encoding ASCII
    Set-Content -LiteralPath (Join-Path (Join-Path $ws '.git') 'config') -Value '[core]' -Encoding ASCII
    Set-Content -LiteralPath (Join-Path (Join-Path $ws 'node_modules') 'x.js') -Value 'x' -Encoding ASCII
    $run = Invoke-ShareScript -Arguments @('-Path', $ws, '-TestMode', '-TestStopAfterSnapshot', '-EventStream', '-Minutes', '1', '-NoClipboard', '-KeepArchive')
    $events = @($run.Lines | Where-Object { $_.StartsWith('@@WSEVENT@@ ') } | ForEach-Object { $_.Substring(12) | ConvertFrom-Json })
    Write-Host ('       exit ' + $run.ExitCode + ', events: ' + (($events | ForEach-Object { $_.type }) -join ','))
    if ($run.ExitCode -ne 0) { Write-Host ($run.Lines -join "`n"); Write-Host $run.StdErr }
    Assert-True ($run.ExitCode -eq 0) 'snapshot run exits 0'
    $ended = @($events | Where-Object { $_.type -eq 'ended' })
    Assert-True ($ended.Count -eq 1 -and $ended[0].reason -eq 'TestSnapshotOnly') 'ended event: TestSnapshotOnly'
    $session = @($events | Where-Object { $_.type -eq 'session' } | ForEach-Object { [string]$_.path })
    Assert-True ($session.Count -eq 1 -and (Test-Path -LiteralPath $session[0] -PathType Container)) 'session folder exists with -KeepArchive'
    if ($session.Count -eq 1 -and (Test-Path -LiteralPath $session[0])) {
        $mode = [int][IO.File]::GetUnixFileMode($session[0])
        Assert-True ($mode -eq 448) ("session folder is chmod 700 (was: $([Convert]::ToString($mode, 8)))")
        $zip = Get-ChildItem -LiteralPath $session[0] -Filter 'workspace-*.zip' -File | Select-Object -First 1
        Assert-True ($null -ne $zip) 'ZIP exists in the session folder'
        if ($zip) {
            $listing = (& (Join-Path $bin '7zz') l -ba -scsUTF-8 $zip.FullName) -join "`n"
            Write-Host ($listing -replace '(?m)^', '       | ')
            Assert-True ($listing -match '(?m) hello\.txt\s*$') 'ZIP contains hello.txt'
            Assert-True ($listing -match '(?m) README\.MD\s*$' -and $listing -match '(?m) readme\.md\s*$') 'ZIP keeps names that differ only in case (README.MD and readme.md)'
            Assert-True ($listing -match 'sub/readme\.md') 'ZIP contains sub/readme.md'
            Assert-True ($listing -match 'Mixed Case Dir/Stra.e \[1\] \(x\)\.txt') 'ZIP contains a name with space, umlaut, brackets and parentheses'
            Assert-True ($listing -notmatch '\.npmrc' -and $listing -notmatch '(^|[\s/])\.git([/\s]|$)' -and $listing -notmatch 'node_modules') 'ZIP excludes .npmrc, .git and node_modules'
            $zipMode = [string][IO.File]::GetUnixFileMode($zip.FullName)
            Write-Host ('       zip mode: ' + $zipMode)
        }
        Remove-Item -LiteralPath $session[0] -Recurse -Force -ErrorAction SilentlyContinue
    }
    # no -KeepArchive: the session folder is removed again
    $run2 = Invoke-ShareScript -Arguments @('-Path', $ws, '-TestMode', '-TestStopAfterSnapshot', '-EventStream', '-Minutes', '1', '-NoClipboard')
    $session2 = @($run2.Lines | Where-Object { $_.StartsWith('@@WSEVENT@@ ') } | ForEach-Object { $_.Substring(12) | ConvertFrom-Json } | Where-Object { $_.type -eq 'session' } | ForEach-Object { [string]$_.path })
    Assert-True ($run2.ExitCode -eq 0 -and $session2.Count -eq 1 -and -not (Test-Path -LiteralPath $session2[0])) 'without -KeepArchive the session folder is cleaned up'

    # symlink inside the workspace -> refused (exit 20)
    $wsLink = Join-Path $tmp 'workspace-symlink'
    [void](New-Item -ItemType Directory -Path $wsLink)
    Set-Content -LiteralPath (Join-Path $wsLink 'a.txt') -Value 'a'
    [void](New-Item -ItemType SymbolicLink -Path (Join-Path $wsLink 'evil-link') -Target '/etc')
    $runLink = Invoke-ShareScript -Arguments @('-Path', $wsLink, '-TestMode', '-TestStopAfterSnapshot', '-EventStream', '-Minutes', '1', '-NoClipboard')
    Assert-True ($runLink.ExitCode -eq 20) ("workspace with a symlink is refused with exit 20 (was $($runLink.ExitCode))")
    # root itself is a symlink -> refused (exit 10)
    $rootLink = Join-Path $tmp 'workspace-root-link'
    [void](New-Item -ItemType SymbolicLink -Path $rootLink -Target $ws)
    $runRoot = Invoke-ShareScript -Arguments @('-Path', $rootLink, '-TestMode', '-TestStopAfterSnapshot', '-EventStream', '-Minutes', '1', '-NoClipboard')
    Assert-True ($runRoot.ExitCode -eq 10) ("a symlink as share root is refused with exit 10 (was $($runRoot.ExitCode))")
    # key file -> refused (exit 22)
    $wsEnv = Join-Path $tmp 'workspace-env'
    [void](New-Item -ItemType Directory -Path $wsEnv)
    Set-Content -LiteralPath (Join-Path $wsEnv '.env') -Value 'API_KEY=not-a-real-key'
    Set-Content -LiteralPath (Join-Path $wsEnv 'a.txt') -Value 'a'
    $runEnv = Invoke-ShareScript -Arguments @('-Path', $wsEnv, '-TestMode', '-TestStopAfterSnapshot', '-EventStream', '-Minutes', '1', '-NoClipboard')
    Assert-True ($runEnv.ExitCode -eq 22) ("workspace with .env is refused with exit 22 (was $($runEnv.ExitCode))")
    # a real secret inside a normal file -> gitleaks gate (exit 22)
    $wsSecret = Join-Path $tmp 'workspace-secret'
    [void](New-Item -ItemType Directory -Path $wsSecret)
    Set-Content -LiteralPath (Join-Path $wsSecret 'config.txt') -Value 'aws_access_key_id = AKIAIOSFODNN7EXAMPLQ'
    $runSecret = Invoke-ShareScript -Arguments @('-Path', $wsSecret, '-TestMode', '-TestStopAfterSnapshot', '-EventStream', '-Minutes', '1', '-NoClipboard')
    Write-Host ('       secret-scan run: exit ' + $runSecret.ExitCode)
    Assert-True ($runSecret.ExitCode -in @(0, 22)) 'secret scan ran (exit 22 when gitleaks flags the sample key, 0 otherwise)'
}

Invoke-Check 'installer shortcut (.desktop)' {
    $dir = Join-Path $tmp 'desktop-entries'
    & $pwshPath -NoLogo -NoProfile -File (Join-Path $ToolRoot 'Install-GuiShortcut.ps1') -TargetDirectory $dir | Out-Null
    $file = Join-Path $dir 'workspaceshare.desktop'
    $text = if (Test-Path -LiteralPath $file) { [IO.File]::ReadAllText($file) } else { '' }
    Assert-True ($text -match '(?m)^Exec=".*pwsh" -NoLogo -NoProfile -File ".*Start-WorkspaceShareGui\.ps1"$' -and $text -match '(?m)^\[Desktop Entry\]') '.desktop file has a quoted pwsh Exec line'
}

Write-Host ''
Write-Host "Passed: $($script:Pass)  Failed: $($script:Fail)"
Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
if ($script:Fail -gt 0) { exit 1 }
exit 0
