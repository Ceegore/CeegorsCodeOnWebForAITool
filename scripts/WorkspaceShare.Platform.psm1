#requires -Version 5.1
# OS-specific helpers for WorkspaceShare. The only GUI file allowed to touch
# System.Windows.Forms, LOCALAPPDATA, explorer/Start-Process etc. (GUI_CONTRACT section 3).
# Windows implementation is the product; the Linux branches (PowerShell 7, docs/LINUX_PLAN.md)
# use xdg-open, zenity/kdialog, wl-copy/xclip and chmod. macOS is not supported.
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-WsPlatform {
    [CmdletBinding()]
    param()
    if ([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT) { return 'windows' }
    $mac = Get-Variable -Name IsMacOS -ErrorAction SilentlyContinue
    if ($null -ne $mac -and [bool]$mac.Value) { return 'macos' }
    return 'linux'
}

function Test-WsSta {
    # Internal: WinForms dialogs and the clipboard need a single-threaded apartment.
    return ([Threading.Thread]::CurrentThread.GetApartmentState() -eq [Threading.ApartmentState]::STA)
}

function Initialize-WsWinForms {
    # Internal: inbox assemblies only, no runtime-compiled code.
    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing
}

# ---------------------------------------------------------------- Linux helpers (internal and shared)

function Test-WsCommand {
    # True when an executable of that name is on PATH.
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Name)
    return (@(Get-Command -Name $Name -CommandType Application -ErrorAction SilentlyContinue).Count -gt 0)
}

function Get-WsCommandPath {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Name)
    $found = @(Get-Command -Name $Name -CommandType Application -ErrorAction SilentlyContinue)
    if ($found.Count -eq 0) { return $null }
    return [string]$found[0].Source
}

function Test-WsDisplay {
    # A graphical session is reachable (X11 or Wayland).
    return (-not [string]::IsNullOrEmpty($env:DISPLAY) -or -not [string]::IsNullOrEmpty($env:WAYLAND_DISPLAY))
}

function Invoke-WsTool {
    # Runs a native tool without a shell and captures stdout/stderr (Linux helper; also fine on Windows 7).
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [string[]]$Arguments = @(),
        [AllowNull()][string]$StandardInput = $null,
        [ValidateRange(1, 3600)][int]$TimeoutSeconds = 15
    )
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $FilePath
    foreach ($argument in @($Arguments)) { [void]$psi.ArgumentList.Add([string]$argument) }
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.RedirectStandardInput = ($null -ne $StandardInput)
    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $psi
    try {
        [void]$process.Start()
        $outTask = $process.StandardOutput.ReadToEndAsync()
        $errTask = $process.StandardError.ReadToEndAsync()
        if ($null -ne $StandardInput) {
            try { $process.StandardInput.Write($StandardInput) } catch { }
            try { $process.StandardInput.Close() } catch { }
        }
        if (-not $process.WaitForExit($TimeoutSeconds * 1000)) {
            try { $process.Kill() } catch { }
            return [pscustomobject]@{ ExitCode = -1; StdOut = ''; StdErr = 'timeout'; TimedOut = $true }
        }
        $process.WaitForExit()
        return [pscustomobject]@{ ExitCode = [int]$process.ExitCode; StdOut = [string]$outTask.Result; StdErr = [string]$errTask.Result; TimedOut = $false }
    }
    finally { $process.Dispose() }
}

function Get-WsProcessStartTicks {
    # Stable start identity of a process (0 when unknown). Windows: UTC ticks of StartTime (as before).
    # Linux: field 22 of /proc/<pid>/stat (clock ticks since boot, plus 1), identical in every process
    # that reads it (Process.StartTime is derived from the wall clock and can differ by a few ms).
    [CmdletBinding()]
    param([Parameter(Mandatory)][int]$ProcessId)
    try {
        if ((Get-WsPlatform) -eq 'windows') {
            $process = Get-Process -Id $ProcessId -ErrorAction Stop
            try { return [int64]$process.StartTime.ToUniversalTime().Ticks } finally { $process.Dispose() }
        }
        $text = [IO.File]::ReadAllText('/proc/' + $ProcessId + '/stat')
        $close = $text.LastIndexOf(')')
        if ($close -lt 0) { return [int64]0 }
        $fields = $text.Substring($close + 2).Split(' ')
        if ($fields.Count -lt 20) { return [int64]0 }
        return ([int64]$fields[19] + 1)
    }
    catch { return [int64]0 }
}

function Set-WsPrivateDirectory {
    # Linux: owner-only access (chmod 700). Windows callers keep their icacls code.
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)
    if ((Get-WsPlatform) -eq 'windows') { return }
    try {
        [IO.File]::SetUnixFileMode($Path, [IO.UnixFileMode]'UserRead,UserWrite,UserExecute')
    }
    catch {
        $chmod = Get-WsCommandPath 'chmod'
        if ($null -eq $chmod) { throw }
        $result = Invoke-WsTool -FilePath $chmod -Arguments @('700', '--', $Path)
        if ($result.ExitCode -ne 0) { throw ('chmod 700 failed: ' + $result.StdErr) }
    }
}

function New-WsInstanceLock {
    # Linux replacement for a named mutex: an exclusive lock file (FileShare.None is an flock).
    # The returned object offers WaitOne(ms), ReleaseMutex() and Dispose() like System.Threading.Mutex.
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Name, [Parameter(Mandatory)][string]$Directory)
    if (-not (Test-Path -LiteralPath $Directory -PathType Container)) { [void](New-Item -ItemType Directory -Path $Directory -Force) }
    $safe = ($Name -replace '[^A-Za-z0-9._-]', '_')
    $lock = [pscustomobject]@{ Path = (Join-Path $Directory ($safe + '.lock')); Stream = $null }
    Add-Member -InputObject $lock -MemberType ScriptMethod -Name WaitOne -Value {
        param([int]$Milliseconds = 0)
        if ($null -ne $this.Stream) { return $true }
        $watch = [Diagnostics.Stopwatch]::StartNew()
        while ($true) {
            try {
                $this.Stream = New-Object System.IO.FileStream($this.Path, [System.IO.FileMode]::OpenOrCreate, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::None)
                return $true
            }
            catch [System.IO.IOException] { }
            if ($watch.ElapsedMilliseconds -ge $Milliseconds) { return $false }
            Start-Sleep -Milliseconds 50
        }
    }
    Add-Member -InputObject $lock -MemberType ScriptMethod -Name ReleaseMutex -Value {
        if ($null -ne $this.Stream) { try { $this.Stream.Dispose() } catch { }; $this.Stream = $null }
    }
    Add-Member -InputObject $lock -MemberType ScriptMethod -Name Dispose -Value {
        if ($null -ne $this.Stream) { try { $this.Stream.Dispose() } catch { }; $this.Stream = $null }
    }
    return $lock
}

function Start-WsKeepAwake {
    # Linux: systemd-inhibit holding a sleep inhibitor until this process ends. Returns the helper
    # Process or $null (not available -> silently nothing). Windows callers use SetThreadExecutionState.
    [CmdletBinding()]
    param()
    if ((Get-WsPlatform) -ne 'linux') { return $null }
    $inhibit = Get-WsCommandPath 'systemd-inhibit'
    $tail = Get-WsCommandPath 'tail'
    if ($null -eq $inhibit -or $null -eq $tail) { return $null }
    try {
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = $inhibit
        foreach ($argument in @('--what=sleep', '--who=WorkspaceShare', '--why=Aktive Freigabe', '--mode=block', $tail, ('--pid=' + $PID), '-f', '/dev/null')) { [void]$psi.ArgumentList.Add($argument) }
        $psi.UseShellExecute = $false
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true
        $process = New-Object System.Diagnostics.Process
        $process.StartInfo = $psi
        [void]$process.Start()
        Start-Sleep -Milliseconds 300
        if ($process.HasExited) { $process.Dispose(); return $null }
        return $process
    }
    catch { return $null }
}

function Stop-WsKeepAwake {
    [CmdletBinding()]
    param([AllowNull()]$Process)
    if ($null -eq $Process) { return }
    try { if (-not $Process.HasExited) { $Process.Kill($true) } } catch { }
    try { $Process.Dispose() } catch { }
}

function Get-WsResolvedAddress {
    # Addresses of a host name. Windows: Resolve-DnsName (as before). Linux: the system resolver; with
    # -Server a dig query (throws when dig is missing). Throws when nothing resolves.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Name,
        [ValidateSet('A', 'AAAA')][string]$Type = 'A',
        [string]$Server
    )
    if ((Get-WsPlatform) -eq 'windows') {
        $arguments = @{ Name = $Name; Type = $Type; DnsOnly = $true; QuickTimeout = $true; ErrorAction = 'Stop' }
        if (-not [string]::IsNullOrEmpty($Server)) { $arguments['Server'] = $Server }
        return @(Resolve-DnsName @arguments | Where-Object { $_.PSObject.Properties['IPAddress'] -and $_.IPAddress } | Select-Object -ExpandProperty IPAddress -Unique)
    }
    if ([string]::IsNullOrEmpty($Server)) {
        $family = [System.Net.Sockets.AddressFamily]::InterNetwork
        if ($Type -eq 'AAAA') { $family = [System.Net.Sockets.AddressFamily]::InterNetworkV6 }
        $addresses = @([System.Net.Dns]::GetHostAddresses($Name) | Where-Object { $_.AddressFamily -eq $family } | ForEach-Object { $_.ToString() } | Select-Object -Unique)
        if ($addresses.Count -eq 0) { throw ('No ' + $Type + ' record for ' + $Name) }
        return $addresses
    }
    $dig = Get-WsCommandPath 'dig'
    if ($null -eq $dig) { throw 'dig is not installed; public resolver checks are skipped.' }
    $result = Invoke-WsTool -FilePath $dig -Arguments @('+short', '+time=2', '+tries=1', ('@' + $Server), $Name, $Type) -TimeoutSeconds 10
    $found = @($result.StdOut -split "\r?\n" | ForEach-Object { $_.Trim() } | Where-Object { $_ -match '^[0-9a-fA-F:.]+$' -and $_ -match '[.:]' } | Select-Object -Unique)
    if ($result.ExitCode -ne 0 -or $found.Count -eq 0) { throw ('No ' + $Type + ' answer from ' + $Server + ' for ' + $Name) }
    return $found
}

function Test-WsPublicResolverSupport {
    # True when the public-resolver comparisons (1.1.1.1/8.8.8.8/9.9.9.9) can run on this host.
    [CmdletBinding()]
    param()
    if ((Get-WsPlatform) -eq 'windows') { return $true }
    return (Test-WsCommand 'dig')
}

# ---------------------------------------------------------------- public API (GUI_CONTRACT section 3)

function Get-WsCapabilities {
    [CmdletBinding()]
    param()
    $platform = Get-WsPlatform
    if ($platform -eq 'windows') {
        $sta = Test-WsSta
        return @{ folderPicker = [bool]$sta; clipboard = [bool]$sta; openBrowser = $true }
    }
    if ($platform -eq 'linux') {
        $display = Test-WsDisplay
        $picker = ($display -and ((Test-WsCommand 'zenity') -or (Test-WsCommand 'kdialog')))
        $clip = ($display -and ((Test-WsCommand 'wl-copy') -or (Test-WsCommand 'xclip') -or (Test-WsCommand 'xsel')))
        $open = ($display -and (Test-WsCommand 'xdg-open'))
        return @{ folderPicker = [bool]$picker; clipboard = [bool]$clip; openBrowser = [bool]$open }
    }
    return @{ folderPicker = $false; clipboard = $false; openBrowser = $false }
}

function Get-WsDataRoot {
    [CmdletBinding()]
    param()
    if ((Get-WsPlatform) -eq 'windows') {
        $base = $env:LOCALAPPDATA
        if ([string]::IsNullOrWhiteSpace($base)) { $base = [Environment]::GetFolderPath('LocalApplicationData') }
        $root = Join-Path $base 'WorkspaceShare'
    }
    else {
        $base = $env:XDG_DATA_HOME
        if ([string]::IsNullOrWhiteSpace($base)) {
            $home1 = $env:HOME
            if ([string]::IsNullOrWhiteSpace($home1)) { $home1 = [Environment]::GetFolderPath('UserProfile') }
            $base = Join-Path (Join-Path $home1 '.local') 'share'
        }
        $root = Join-Path $base 'workspaceshare'
    }
    if (-not (Test-Path -LiteralPath $root -PathType Container)) {
        [void](New-Item -ItemType Directory -Path $root -Force)
        if ((Get-WsPlatform) -ne 'windows') { try { Set-WsPrivateDirectory -Path $root } catch { } }
    }
    return $root
}

function Get-WsPowerShellHost {
    [CmdletBinding()]
    param()
    if ((Get-WsPlatform) -eq 'windows') {
        return (Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe')
    }
    # The running pwsh itself (its real path, as /proc/<pid>/exe reports it) when possible.
    try {
        $self = (Get-Process -Id $PID -ErrorAction Stop).Path
        if (-not [string]::IsNullOrEmpty($self) -and [IO.Path]::GetFileName($self) -eq 'pwsh') { return $self }
    }
    catch { }
    $candidate = Join-Path $PSHOME 'pwsh'
    if (Test-Path -LiteralPath $candidate -PathType Leaf) { return $candidate }
    return (Get-Command pwsh -ErrorAction Stop).Source
}

function Open-WsBrowser {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Url)
    # Only the local GUI URL is ever opened.
    if ($Url -notmatch '^http://127\.0\.0\.1:[0-9]{1,5}(/[^\s]*)?$') { return $false }
    $platform = Get-WsPlatform
    if ($platform -eq 'linux') {
        $opener = Get-WsCommandPath 'xdg-open'
        if ($null -eq $opener) { return $false }
        try {
            $psi = New-Object System.Diagnostics.ProcessStartInfo
            $psi.FileName = $opener
            [void]$psi.ArgumentList.Add($Url)
            $psi.UseShellExecute = $false
            $psi.RedirectStandardOutput = $true
            $psi.RedirectStandardError = $true
            $process = New-Object System.Diagnostics.Process
            $process.StartInfo = $psi
            [void]$process.Start()
            # Do not wait: some desktops keep xdg-open alive as long as the browser runs.
            $process.Dispose()
            return $true
        }
        catch { return $false }
    }
    if ($platform -ne 'windows') { return $false }
    try {
        Start-Process -FilePath $Url
        return $true
    }
    catch { return $false }
}

function Show-WsFolderPicker {
    [CmdletBinding()]
    param([string]$InitialPath)
    $platform = Get-WsPlatform
    if ($platform -eq 'linux') {
        if (-not (Test-WsDisplay)) { return $null }
        $zenity = Get-WsCommandPath 'zenity'
        $kdialog = Get-WsCommandPath 'kdialog'
        $start = $null
        if (-not [string]::IsNullOrWhiteSpace($InitialPath) -and (Test-Path -LiteralPath $InitialPath -PathType Container)) {
            $start = [IO.Path]::GetFullPath($InitialPath).TrimEnd('/') + '/'
        }
        try {
            if ($null -ne $zenity) {
                $arguments = @('--file-selection', '--directory', '--title=Ordner für die Freigabe auswählen')
                if ($start) { $arguments += ('--filename=' + $start) }
                $result = Invoke-WsTool -FilePath $zenity -Arguments $arguments -TimeoutSeconds 900
            }
            elseif ($null -ne $kdialog) {
                $arguments = @('--getexistingdirectory')
                if ($start) { $arguments += $start }
                $result = Invoke-WsTool -FilePath $kdialog -Arguments $arguments -TimeoutSeconds 900
            }
            else { return $null }
            if ($result.ExitCode -ne 0) { return $null }
            $picked = ([string]$result.StdOut).Trim()
            if ([string]::IsNullOrWhiteSpace($picked)) { return $null }
            return $picked
        }
        catch { return $null }
    }
    if ($platform -ne 'windows') { return $null }
    if (-not (Test-WsSta)) { return $null }
    Initialize-WsWinForms
    $owner = $null
    $dialog = $null
    try {
        # Hidden TopMost owner so the dialog opens in front of the browser.
        $owner = New-Object System.Windows.Forms.Form
        $owner.TopMost = $true
        $owner.ShowInTaskbar = $false
        $owner.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::None
        $owner.StartPosition = [System.Windows.Forms.FormStartPosition]::CenterScreen
        $owner.Size = New-Object System.Drawing.Size(0, 0)
        $owner.Opacity = 0
        $owner.Show()
        $owner.Activate()
        $dialog = New-Object System.Windows.Forms.FolderBrowserDialog
        $dialog.Description = 'Ordner für die Freigabe auswählen'
        $dialog.ShowNewFolderButton = $false
        if (-not [string]::IsNullOrWhiteSpace($InitialPath) -and (Test-Path -LiteralPath $InitialPath -PathType Container)) {
            $dialog.SelectedPath = $InitialPath
        }
        $result = $dialog.ShowDialog($owner)
        if ($result -eq [System.Windows.Forms.DialogResult]::OK -and -not [string]::IsNullOrWhiteSpace($dialog.SelectedPath)) {
            return [string]$dialog.SelectedPath
        }
        return $null
    }
    finally {
        if ($null -ne $dialog) { try { $dialog.Dispose() } catch { } }
        if ($null -ne $owner) { try { $owner.Dispose() } catch { } }
    }
}

function Get-WsClipboardTool {
    # Internal (Linux): @{ Set = @(file, args...); Get = @(file, args...); Clear = ... } or $null.
    if (-not (Test-WsDisplay)) { return $null }
    $wlCopy = Get-WsCommandPath 'wl-copy'
    $wlPaste = Get-WsCommandPath 'wl-paste'
    if (-not [string]::IsNullOrEmpty($env:WAYLAND_DISPLAY) -and $null -ne $wlCopy) {
        return @{ Set = @($wlCopy); Get = $(if ($null -ne $wlPaste) { @($wlPaste, '--no-newline') } else { $null }); Clear = @($wlCopy, '--clear') }
    }
    $xclip = Get-WsCommandPath 'xclip'
    if (-not [string]::IsNullOrEmpty($env:DISPLAY) -and $null -ne $xclip) {
        return @{ Set = @($xclip, '-selection', 'clipboard', '-in'); Get = @($xclip, '-selection', 'clipboard', '-out'); Clear = $null }
    }
    $xsel = Get-WsCommandPath 'xsel'
    if (-not [string]::IsNullOrEmpty($env:DISPLAY) -and $null -ne $xsel) {
        return @{ Set = @($xsel, '--clipboard', '--input'); Get = @($xsel, '--clipboard', '--output'); Clear = $null }
    }
    return $null
}

function Set-WsClipboardText {
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text)
    $platform = Get-WsPlatform
    if ($platform -eq 'linux') {
        $tool = Get-WsClipboardTool
        if ($null -eq $tool) { return $false }
        try {
            $psi = New-Object System.Diagnostics.ProcessStartInfo
            $psi.FileName = [string]$tool.Set[0]
            for ($i = 1; $i -lt $tool.Set.Count; $i++) { [void]$psi.ArgumentList.Add([string]$tool.Set[$i]) }
            $psi.UseShellExecute = $false
            $psi.RedirectStandardInput = $true
            $psi.RedirectStandardOutput = $true
            $psi.RedirectStandardError = $true
            $process = New-Object System.Diagnostics.Process
            $process.StartInfo = $psi
            [void]$process.Start()
            $process.StandardInput.Write($Text)
            $process.StandardInput.Close()
            # The tools fork a selection owner into the background; the foreground part ends quickly.
            $exited = $process.WaitForExit(3000)
            $code = 1
            if ($exited) { $code = [int]$process.ExitCode }
            $process.Dispose()
            return ($exited -and $code -eq 0)
        }
        catch { return $false }
    }
    if ($platform -ne 'windows') { return $false }
    if (-not (Test-WsSta)) { return $false }
    try {
        Initialize-WsWinForms
        $data = New-Object System.Windows.Forms.DataObject
        $data.SetData([System.Windows.Forms.DataFormats]::UnicodeText, $Text)
        # Four zero bytes (DWORD 0): keep out of Win+V history, cloud clipboard and monitors.
        foreach ($format in @('ExcludeClipboardContentFromMonitorProcessing', 'CanIncludeInClipboardHistory', 'CanUploadToCloudClipboard')) {
            $stream = New-Object System.IO.MemoryStream (, (New-Object byte[] 4))
            $data.SetData($format, $stream)
        }
        [System.Windows.Forms.Clipboard]::SetDataObject($data, $true, 10, 100)
        return $true
    }
    catch { return $false }
}

function Clear-WsClipboardText {
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Expected)
    $platform = Get-WsPlatform
    if ($platform -eq 'linux') {
        $tool = Get-WsClipboardTool
        if ($null -eq $tool -or $null -eq $tool.Get) { return $false }
        try {
            $getArguments = @()
            for ($i = 1; $i -lt $tool.Get.Count; $i++) { $getArguments += [string]$tool.Get[$i] }
            $current = Invoke-WsTool -FilePath ([string]$tool.Get[0]) -Arguments $getArguments -TimeoutSeconds 5
            if ($current.ExitCode -ne 0 -or -not (([string]$current.StdOut).TrimEnd("`r", "`n") -ceq $Expected)) { return $false }
            if ($null -ne $tool.Clear) {
                $clearArguments = @()
                for ($i = 1; $i -lt $tool.Clear.Count; $i++) { $clearArguments += [string]$tool.Clear[$i] }
                $cleared = Invoke-WsTool -FilePath ([string]$tool.Clear[0]) -Arguments $clearArguments -TimeoutSeconds 5
                return ($cleared.ExitCode -eq 0)
            }
            return (Set-WsClipboardText -Text ' ')
        }
        catch { return $false }
    }
    if ($platform -ne 'windows') { return $false }
    if (-not (Test-WsSta)) { return $false }
    try {
        Initialize-WsWinForms
        $current = [System.Windows.Forms.Clipboard]::GetText()
        if ($current -ceq $Expected) {
            [System.Windows.Forms.Clipboard]::Clear()
            return $true
        }
        return $false
    }
    catch { return $false }
}

Export-ModuleMember -Function Get-WsPlatform, Get-WsCapabilities, Get-WsDataRoot, Get-WsPowerShellHost, Open-WsBrowser, Show-WsFolderPicker, Set-WsClipboardText, Clear-WsClipboardText, Test-WsCommand, Get-WsCommandPath, Invoke-WsTool, Get-WsProcessStartTicks, Set-WsPrivateDirectory, New-WsInstanceLock, Start-WsKeepAwake, Stop-WsKeepAwake, Get-WsResolvedAddress, Test-WsPublicResolverSupport
