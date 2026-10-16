#requires -Version 5.1
# WorkspaceShare GUI backend (GUI_CONTRACT section 5): local HTTP server on 127.0.0.1 that serves gui\*
# and starts/stops Share-Workspace.ps1 as a child process. Single-threaded loop, compile-free (no Add-Type).
[CmdletBinding()]
param(
    [int]$Port = 0,
    [switch]$NoBrowser,
    [string]$InstanceFile,
    [switch]$TestMode,
    [string]$TestShareScript,
    [int64]$MaxDropBytes = 4GB,
    [int]$MaxDropFiles = 10000,
    [string]$DataRootOverride
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (-not [string]::IsNullOrEmpty($TestShareScript) -and -not $TestMode) {
    [Console]::Error.WriteLine('-TestShareScript ist nur zusammen mit -TestMode erlaubt.')
    exit 10
}
if (-not [string]::IsNullOrEmpty($DataRootOverride) -and -not $TestMode) {
    [Console]::Error.WriteLine('-DataRootOverride ist nur zusammen mit -TestMode erlaubt.')
    exit 10
}
if ($MaxDropBytes -lt 1 -or $MaxDropFiles -lt 1) {
    [Console]::Error.WriteLine('Ungültige Drop-Limits.')
    exit 10
}
if ($Port -lt 0 -or $Port -gt 65535) {
    [Console]::Error.WriteLine('Ungültiger Port.')
    exit 10
}

$ToolRoot = $PSScriptRoot
$GuiRoot = Join-Path $PSScriptRoot 'gui'
$ScriptsDir = Join-Path $PSScriptRoot 'scripts'
Import-Module (Join-Path $ScriptsDir 'WorkspaceShare.Platform.psm1') -Force -ErrorAction Stop
Import-Module (Join-Path $ScriptsDir 'WorkspaceShare.Gui.Http.psm1') -Force -ErrorAction Stop
# The Curl module only defines functions; it loads the compiled Job module lazily inside
# Invoke-CurlWithPrivateUrl, which this backend never calls.
Import-Module (Join-Path $ScriptsDir 'WorkspaceShare.Curl.psm1') -Force -Function Protect-DiagnosticText -ErrorAction Stop

$ShareScript = Join-Path $ToolRoot 'Share-Workspace.ps1'
if ($TestMode -and -not [string]::IsNullOrEmpty($TestShareScript)) {
    if (-not (Test-Path -LiteralPath $TestShareScript -PathType Leaf)) {
        [Console]::Error.WriteLine('TestShareScript nicht gefunden.')
        exit 10
    }
    $ShareScript = (Resolve-Path -LiteralPath $TestShareScript).ProviderPath
}
# Data folder: the platform's per-user folder; tests may point it elsewhere (never the real one).
$StaleDropCleanup = $true
if ([string]::IsNullOrWhiteSpace($DataRootOverride)) {
    $DataRoot = Get-WsDataRoot
    # -TestMode without an override must not delete anything in the real data folder at start.
    if ($TestMode) { $StaleDropCleanup = $false }
}
else {
    $DataRoot = [IO.Path]::GetFullPath($DataRootOverride)
    [void][IO.Directory]::CreateDirectory($DataRoot)
}
$DropsRoot = [IO.Path]::GetFullPath((Join-Path $DataRoot 'drops'))
if ([string]::IsNullOrWhiteSpace($InstanceFile)) {
    $InstanceFile = Join-Path $DataRoot 'gui-instance.json'
}
$InstanceFile = [IO.Path]::GetFullPath($InstanceFile)

# ---------------------------------------------------------------- helpers

function ConvertTo-NativeArgument {
    # Windows argv quoting (same rule as ConvertTo-WorkspaceNativeArgument in WorkspaceShare.Job.psm1)
    param([AllowEmptyString()][string]$Value)
    if ($null -eq $Value -or $Value.Length -eq 0) { return '""' }
    if ($Value -notmatch '[\s"]') { return $Value }
    return '"' + ($Value -replace '(\\*)"', '$1$1\"' -replace '(\\+)$', '$1$1') + '"'
}

function Test-ProcessAlive {
    param($ProcessId, $StartTicks)
    try {
        $p = [Diagnostics.Process]::GetProcessById([int]$ProcessId)
        if ($p.HasExited) { return $false }
        return ($p.StartTime.ToUniversalTime().Ticks -eq [long]$StartTicks)
    }
    catch { return $false }
}

function Read-InstanceFile {
    param([string]$Path)
    try {
        if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
        $o = [IO.File]::ReadAllText($Path) | ConvertFrom-Json
        foreach ($n in 'pid', 'startTicks', 'port', 'token') {
            if ($null -eq $o.PSObject.Properties[$n]) { return $null }
        }
        return $o
    }
    catch { return $null }
}

function Enter-InstanceMutex {
    param($Mutex, [int]$Milliseconds)
    try { return [bool]$Mutex.WaitOne($Milliseconds) }
    catch [System.Threading.AbandonedMutexException] { return $true }
}

function Open-ExistingInstance {
    # Returns $true when a live instance was found (and the browser opened unless -NoBrowser).
    param($Inst)
    if ($null -eq $Inst) { return $false }
    if (-not (Test-ProcessAlive $Inst.pid $Inst.startTicks)) { return $false }
    if (-not $NoBrowser) {
        $url = 'http://127.0.0.1:{0}/#{1}' -f [int]$Inst.port, [string]$Inst.token
        [void](Open-WsBrowser -Url $url)
    }
    return $true
}

function New-GuiToken {
    $bytes = New-Object byte[] 32
    $rng = New-Object System.Security.Cryptography.RNGCryptoServiceProvider
    try { $rng.GetBytes($bytes) } finally { $rng.Dispose() }
    return ([Convert]::ToBase64String($bytes).TrimEnd('=').Replace('+', '-').Replace('/', '_'))
}

# ---------------------------------------------------------------- share state

$script:Platform = Get-WsPlatform
$script:Caps = Get-WsCapabilities
$script:Log = New-Object 'System.Collections.Generic.List[string]'
$script:Proc = $null
$script:Readers = @{ out = $null; err = $null }
$script:Tasks = @{ out = $null; err = $null }
$script:Eof = @{ out = $true; err = $true }
$script:ExitSeen = $null
$script:StopSw = $null
$script:KillSent = $false
$script:KnownUrl = $null
$script:CopiedUrl = $null
$script:LastPath = $null
$script:QuitRequested = $false
$script:QuitSw = $null
$script:QuitStopSent = $false
$script:QuitKillSw = $null
$script:Token = ''
$script:BoundPort = 0
$script:CurrentDrop = $null
$script:PendingDeletes = New-Object 'System.Collections.Generic.List[string]'
$script:PendingSw = [Diagnostics.Stopwatch]::StartNew()
$script:PathComparison = [StringComparison]::Ordinal
if ($script:Platform -eq 'windows') { $script:PathComparison = [StringComparison]::OrdinalIgnoreCase }

function New-ShareState {
    return @{
        phase = 'idle'; step = 0; total = 8; stepText = $null
        steps = (New-Object 'System.Collections.Generic.List[object]')
        url = $null; expiresUtc = $null; sizeBytes = $null; sha256 = $null
        remainingMinutes = $null; health = $null
        exitCode = $null; reason = $null; message = $null
        request = $null; sessionPath = $null
        stopRequested = $false; endedGot = $false
    }
}
$script:Share = New-ShareState

function Protect-Text {
    param([AllowNull()][string]$Text)
    if ([string]::IsNullOrEmpty($Text)) { return '' }
    $urls = @()
    if ($script:KnownUrl) { $urls = @([string]$script:KnownUrl) }
    $safe = Protect-DiagnosticText -Text $Text -KnownSecretUrls $urls -SecretTokens @([string]$script:Token)
    if ($safe.Length -gt 2000) { $safe = $safe.Substring(0, 2000) }
    return $safe
}

function Add-LogLine {
    param([AllowNull()][string]$Text)
    $safe = Protect-Text $Text
    if ($safe.Length -eq 0) { return }
    $script:Log.Add($safe)
    while ($script:Log.Count -gt 200) { $script:Log.RemoveAt(0) }
}

function Write-ConsoleLog {
    param([string]$Text)
    try { Write-Host ('[GUI] ' + (Protect-Text $Text)) } catch { }
}

function Get-EventProp {
    param($Obj, [string]$Name)
    $p = $Obj.PSObject.Properties[$Name]
    if ($null -eq $p) { return $null }
    return $p.Value
}

function ConvertTo-IsoText {
    param($Value)
    if ($null -eq $Value) { return $null }
    if ($Value -is [datetime]) { return $Value.ToUniversalTime().ToString('o') }
    return [string]$Value
}

function ConvertTo-StrictInt {
    # Integral JSON numbers only (no strings, no booleans, no fractions); $null otherwise.
    param($Value)
    if ($Value -is [int] -or $Value -is [long]) { return [long]$Value }
    if ($Value -is [double] -or $Value -is [decimal]) {
        if ($Value -eq [Math]::Floor($Value) -and [Math]::Abs($Value) -lt 1e15) { return [long]$Value }
    }
    return $null
}

function Set-ShareEvent {
    param($Ev)
    $s = $script:Share
    $type = [string](Get-EventProp $Ev 'type')
    switch ($type) {
        'start' { }
        'step' {
            $n = ConvertTo-StrictInt (Get-EventProp $Ev 'n')
            if ($null -eq $n) { return }
            $text = Protect-Text ([string](Get-EventProp $Ev 'text'))
            $total = ConvertTo-StrictInt (Get-EventProp $Ev 'total')
            $s.step = [int]$n
            if ($null -ne $total -and $total -gt 0) { $s.total = [int]$total }
            $s.stepText = $text
            $found = $false
            for ($i = 0; $i -lt $s.steps.Count; $i++) {
                if ([int]$s.steps[$i].n -eq [int]$n) { $s.steps[$i] = @{ n = [int]$n; text = $text }; $found = $true; break }
            }
            if (-not $found) { $s.steps.Add(@{ n = [int]$n; text = $text }) }
        }
        'session' {
            $p = [string](Get-EventProp $Ev 'path')
            if (-not [string]::IsNullOrWhiteSpace($p)) { $s.sessionPath = $p }
        }
        'ready' {
            $url = [string](Get-EventProp $Ev 'url')
            if (-not [string]::IsNullOrEmpty($url)) { $script:KnownUrl = $url }
            if ($s.phase -eq 'stopping') { return }
            $s.url = $url
            $s.expiresUtc = ConvertTo-IsoText (Get-EventProp $Ev 'expiresUtc')
            $size = ConvertTo-StrictInt (Get-EventProp $Ev 'sizeBytes')
            $s.sizeBytes = $size
            $sha = Get-EventProp $Ev 'sha256'
            if ($null -ne $sha) { $s.sha256 = [string]$sha }
            $s.phase = 'active'
        }
        'status' {
            $m = ConvertTo-StrictInt (Get-EventProp $Ev 'remainingMinutes')
            if ($null -ne $m) { $s.remainingMinutes = [int]$m }
        }
        'health' {
            $state = [string](Get-EventProp $Ev 'state')
            if ($state -in @('ok', 'degraded', 'recovered')) {
                $previous = $s.health
                $s.health = $state
                $text = [string](Get-EventProp $Ev 'text')
                if ($state -ne 'ok' -and $state -ne $previous -and $text) { Add-LogLine ('Verbindung: ' + $text) }
            }
        }
        'warning' {
            $text = [string](Get-EventProp $Ev 'text')
            if ($text) { Add-LogLine ('Warnung: ' + $text) }
        }
        'ended' {
            $s.endedGot = $true
            $code = ConvertTo-StrictInt (Get-EventProp $Ev 'exitCode')
            if ($null -ne $code) { $s.exitCode = [int]$code }
            $reason = Get-EventProp $Ev 'reason'
            if ($null -ne $reason) { $s.reason = Protect-Text ([string]$reason) }
            $msg = Get-EventProp $Ev 'message'
            if ($null -ne $msg -and [string]$msg -ne '') { $s.message = Protect-Text ([string]$msg) }
        }
        default { }
    }
}

function Receive-ChildLine {
    param([string]$Line, [bool]$FromStdout)
    if ($Line.Length -eq 0) { return }
    if ($FromStdout -and $Line.StartsWith('@@WSEVENT@@ ', [StringComparison]::Ordinal)) {
        $ev = $null
        try { $ev = $Line.Substring(12) | ConvertFrom-Json } catch { $ev = $null }
        if ($null -ne $ev -and $null -ne $ev.PSObject.Properties['type']) {
            try { Set-ShareEvent $ev } catch { Add-LogLine 'Ungültiges Ereignis vom Freigabeprozess ignoriert.' }
            return
        }
    }
    Add-LogLine $Line
}

function Stop-ChildTree {
    $p = $script:Proc
    if ($null -eq $p) { return }
    $script:KillSent = $true
    if ($script:Platform -eq 'windows') {
        try {
            $tk = Join-Path $env:SystemRoot 'System32\taskkill.exe'
            Start-Process -FilePath $tk -ArgumentList @('/PID', [string]$p.Id, '/T', '/F') -WindowStyle Hidden -Wait
        }
        catch { }
    }
    try { $p.Kill() } catch { }
}

function Request-ShareStop {
    if ($null -eq $script:Proc) { return }
    $s = $script:Share
    $s.stopRequested = $true
    $s.phase = 'stopping'
    if ($null -eq $script:StopSw) { $script:StopSw = [Diagnostics.Stopwatch]::StartNew() }
    $done = $false
    $sp = $s.sessionPath
    if (-not [string]::IsNullOrWhiteSpace($sp) -and [IO.Path]::IsPathRooted($sp)) {
        try {
            if (Test-Path -LiteralPath $sp -PathType Container) {
                [void](New-Item -ItemType File -Path (Join-Path $sp 'stop.requested') -Force)
                $done = $true
            }
        }
        catch { $done = $false }
    }
    if (-not $done) { Stop-ChildTree }
}

function Complete-Share {
    $s = $script:Share
    $proc = $script:Proc
    $code = $null
    if ($s.endedGot -and $null -ne $s.exitCode) { $code = [int]$s.exitCode }
    else {
        try { $code = [int]$proc.ExitCode } catch { $code = -1 }
        $s.exitCode = $code
    }
    $lastLog = $null
    if ($script:Log.Count -gt 0) { $lastLog = $script:Log[$script:Log.Count - 1] }
    if ($code -eq 0) {
        $s.phase = 'ended'
    }
    elseif (-not $s.endedGot -and $s.stopRequested) {
        # Cancelled by the user (killed before the share announced its own end): not an error.
        $s.phase = 'ended'
        $s.reason = 'ManualStop'
        $s.message = 'Die Freigabe wurde abgebrochen.'
    }
    else {
        $s.phase = 'error'
    }
    if ($s.phase -eq 'error' -and [string]::IsNullOrEmpty([string]$s.message)) {
        if ($lastLog) { $s.message = $lastLog }
        else { $s.message = 'Die Freigabe wurde mit Exit-Code {0} beendet.' -f $code }
    }
    $s.url = $null
    $s.remainingMinutes = $null
    $script:KnownUrl = $null
    try { $proc.Dispose() } catch { }
    $script:Proc = $null
    $script:Tasks.out = $null; $script:Tasks.err = $null
    $script:Readers.out = $null; $script:Readers.err = $null
    $script:ExitSeen = $null
    $script:StopSw = $null
    $script:KillSent = $false
    # The share is over: a drop folder that was shared is not needed any more.
    if ($null -ne $script:CurrentDrop -and $script:CurrentDrop.InUse) { Remove-CurrentDrop }
}

function Update-Child {
    if ($null -eq $script:Proc) { return }
    foreach ($which in @('out', 'err')) {
        $guard = 0
        while ($guard -lt 500) {
            $task = $script:Tasks[$which]
            if ($null -eq $task -or -not $task.IsCompleted) { break }
            $guard++
            $line = $null
            if ($task.IsFaulted) { [void]$task.Exception }
            elseif (-not $task.IsCanceled) { $line = $task.Result }
            if ($null -eq $line) {
                $script:Tasks[$which] = $null
                $script:Eof[$which] = $true
                break
            }
            Receive-ChildLine ([string]$line) ($which -eq 'out')
            $script:Tasks[$which] = $script:Readers[$which].ReadLineAsync()
        }
    }
    if ($null -eq $script:Proc) { return }
    $exited = $false
    try { $exited = $script:Proc.HasExited } catch { $exited = $true }
    if ($exited) {
        if ($null -eq $script:ExitSeen) { $script:ExitSeen = [Diagnostics.Stopwatch]::StartNew() }
        # Grandchildren may keep the pipes open: give the streams a short grace period.
        if (($script:Eof.out -and $script:Eof.err) -or $script:ExitSeen.ElapsedMilliseconds -gt 3000) {
            Complete-Share
        }
    }
    elseif ($script:Share.phase -eq 'stopping' -and $null -ne $script:StopSw -and -not $script:KillSent -and $script:StopSw.Elapsed.TotalSeconds -gt 150) {
        Add-LogLine 'Die Freigabe reagiert nicht auf die Stopp-Anforderung und wird beendet.'
        Stop-ChildTree
    }
}

function Stop-ShareForShutdown {
    # Blocking variant used on backend exit: cooperative stop, wait up to 120 s, then kill.
    if ($null -eq $script:Proc) { return }
    if (-not $script:Share.stopRequested) { try { Request-ShareStop } catch { } }
    $sw = [Diagnostics.Stopwatch]::StartNew()
    while ($null -ne $script:Proc -and $sw.Elapsed.TotalSeconds -lt 120) {
        Update-Child
        if ($null -eq $script:Proc) { break }
        Start-Sleep -Milliseconds 100
    }
    if ($null -ne $script:Proc) {
        Stop-ChildTree
        $sw2 = [Diagnostics.Stopwatch]::StartNew()
        while ($null -ne $script:Proc -and $sw2.Elapsed.TotalSeconds -lt 10) {
            Update-Child
            if ($null -eq $script:Proc) { break }
            Start-Sleep -Milliseconds 100
        }
    }
}

function Get-StateObject {
    $s = $script:Share
    $steps = @()
    foreach ($st in $s.steps) { $steps += , ([ordered]@{ n = $st.n; text = $st.text }) }
    return [ordered]@{
        v = 1
        phase = $s.phase
        platform = $script:Platform
        capabilities = [ordered]@{
            folderPicker = [bool]$script:Caps.folderPicker
            clipboard = [bool]$script:Caps.clipboard
            openBrowser = [bool]$script:Caps.openBrowser
        }
        step = $s.step
        total = $s.total
        stepText = $s.stepText
        steps = $steps
        url = $s.url
        expiresUtc = $s.expiresUtc
        sizeBytes = $s.sizeBytes
        sha256 = $s.sha256
        remainingMinutes = $s.remainingMinutes
        health = $s.health
        exitCode = $s.exitCode
        reason = $s.reason
        message = $s.message
        log = [string[]]$script:Log.ToArray()
        request = $s.request
        drop = (Get-DropState)
        limits = [ordered]@{ maxDropBytes = [int64]$MaxDropBytes; maxDropFiles = [int]$MaxDropFiles }
    }
}

# ---------------------------------------------------------------- drop folder (GUI_CONTRACT section 7)

function Get-DropState {
    $d = $script:CurrentDrop
    if ($null -eq $d) { return $null }
    return [ordered]@{ id = $d.Id; path = $d.Leaf; files = [int]$d.Files; totalBytes = [int64]$d.Bytes; finished = [bool]$d.Finished }
}

function Remove-DropDirectory {
    # Deletes a folder tree; when something is locked the path is retried later (loop / exit).
    param([string]$Path)
    if ([string]::IsNullOrEmpty($Path)) { return }
    try {
        if ([IO.Directory]::Exists($Path)) { [IO.Directory]::Delete($Path, $true) }
    }
    catch {
        if (-not $script:PendingDeletes.Contains($Path)) { $script:PendingDeletes.Add($Path) }
        Write-ConsoleLog ('Drop-Ordner konnte noch nicht gelöscht werden: ' + $_.Exception.Message)
    }
}

function Clear-PendingDeletes {
    if ($script:PendingDeletes.Count -eq 0) { return }
    $paths = @($script:PendingDeletes.ToArray())
    $script:PendingDeletes.Clear()
    foreach ($p in $paths) { Remove-DropDirectory $p }
}

function Remove-CurrentDrop {
    $d = $script:CurrentDrop
    $script:CurrentDrop = $null
    if ($null -eq $d) { return }
    Remove-DropDirectory $d.Root
}

function Clear-StaleDrops {
    # Backend start: this process is the only instance, so every existing drop folder is stale.
    if (-not [IO.Directory]::Exists($DropsRoot)) { return }
    foreach ($dir in [IO.Directory]::GetDirectories($DropsRoot)) { Remove-DropDirectory $dir }
}

function Test-SamePath {
    param([string]$A, [string]$B)
    return [string]::Equals($A, $B, $script:PathComparison)
}

function Test-IsInsidePath {
    # True when $Path is $Root itself or below it.
    param([string]$Path, [string]$Root)
    if (Test-SamePath $Path $Root) { return $true }
    $sep = [string][IO.Path]::DirectorySeparatorChar
    $prefix = $Root.TrimEnd('\', '/') + $sep
    return $Path.StartsWith($prefix, $script:PathComparison)
}

function Convert-DropRelativePath {
    # Validates the relative path of an uploaded file (rules of GUI_CONTRACT 7.2). Returns the
    # normalized path ('/' separated) or $null.
    param([AllowNull()][string]$Rel)
    if ([string]::IsNullOrEmpty($Rel) -or $Rel.Length -gt 400) { return $null }
    foreach ($ch in $Rel.ToCharArray()) {
        if ([char]::IsControl($ch) -or $ch -eq [char]0xFFFD) { return $null }
    }
    $segments = $Rel.Split('/')
    if ($segments.Count -lt 1 -or $segments.Count -gt 64) { return $null }
    foreach ($seg in $segments) {
        if ($seg.Length -lt 1 -or $seg.Length -gt 255) { return $null }
        if ($seg -eq '.' -or $seg -eq '..') { return $null }
        if ($seg.IndexOfAny([char[]]'<>:"\|?*') -ge 0) { return $null }
        if ($seg.EndsWith('.') -or $seg.EndsWith(' ')) { return $null }
        $dot = $seg.IndexOf('.')
        $stem = $seg
        if ($dot -ge 0) { $stem = $seg.Substring(0, $dot) }
        if ($stem.TrimEnd(' ') -match '^(?i:CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])$') { return $null }
    }
    return ($segments -join '/')
}

function Get-DropQueryValues {
    # Parses 'drop=..&path=..' (percent-decoded). Returns $null on duplicates or malformed input.
    param([string]$Query)
    $values = @{}
    if ([string]::IsNullOrEmpty($Query)) { return $values }
    foreach ($pair in $Query.Split('&')) {
        if ($pair.Length -eq 0) { continue }
        $eq = $pair.IndexOf('=')
        if ($eq -lt 1) { return $null }
        $name = $pair.Substring(0, $eq)
        if ($values.ContainsKey($name)) { return $null }
        try { $values[$name] = [Uri]::UnescapeDataString($pair.Substring($eq + 1)) } catch { return $null }
    }
    return $values
}

function Get-FreeSpaceBytes {
    # Free bytes on the data drive, or -1 when it cannot be determined.
    try {
        $drivePath = $DataRoot
        if ($script:Platform -eq 'windows') {
            $drivePath = [IO.Path]::GetPathRoot($DataRoot)
            if ([string]::IsNullOrEmpty($drivePath) -or $drivePath.StartsWith('\\')) { return [int64]-1 }
        }
        $di = New-Object System.IO.DriveInfo -ArgumentList $drivePath
        return [int64]$di.AvailableFreeSpace
    }
    catch { return [int64]-1 }
}

# ---------------------------------------------------------------- API handlers (return @{Status; Body})

function New-ApiResult {
    param([int]$Status, $Body)
    return @{ Status = $Status; Body = $Body }
}

function Test-ShareBusyPhase {
    return ($script:Share.phase -in @('starting', 'active', 'stopping'))
}

function Invoke-ApiStart {
    param($Req)
    if ($script:QuitRequested -or (Test-ShareBusyPhase)) {
        return (New-ApiResult 409 @{ error = 'Es läuft bereits eine Freigabe.' })
    }
    $obj = $null
    try { $obj = $Req.Body | ConvertFrom-Json } catch { $obj = $null }
    if ($null -eq $obj -or $obj -isnot [pscustomobject]) {
        return (New-ApiResult 400 @{ error = 'Ungültige Anfrage (kein gültiges JSON-Objekt).' })
    }
    $pathValue = Get-EventProp $obj 'path'
    if ($pathValue -isnot [string] -or [string]::IsNullOrWhiteSpace($pathValue)) {
        return (New-ApiResult 400 @{ error = 'Bitte einen Ordner angeben.' })
    }
    $fullPath = $null
    try {
        if ($pathValue.Length -gt 4096 -or $pathValue -match '[\x00-\x1F]') { throw 'invalid' }
        if (-not (Test-Path -LiteralPath $pathValue -PathType Container)) { throw 'missing' }
        $fullPath = [IO.Path]::GetFullPath($pathValue)
        if ($fullPath.Length -gt 3) { $fullPath = $fullPath.TrimEnd('\', '/') }
    }
    catch {
        return (New-ApiResult 400 @{ error = 'Der Ordner existiert nicht oder der Pfad ist ungültig.' })
    }
    # Only the finished drop of this backend may be shared from inside the drops folder.
    $useDrop = $false
    if (Test-IsInsidePath $fullPath $DropsRoot) {
        $d = $script:CurrentDrop
        if ($null -ne $d -and $d.Finished -and -not $d.InUse -and (Test-SamePath $fullPath $d.Leaf)) { $useDrop = $true }
        else { return (New-ApiResult 400 @{ error = 'Dieser Ordner ist nicht freigebbar.' }) }
    }
    $minutes = ConvertTo-StrictInt (Get-EventProp $obj 'minutes')
    if ($null -eq $minutes -or $minutes -lt 1 -or $minutes -gt 1440) {
        return (New-ApiResult 400 @{ error = 'Die Dauer muss eine ganze Zahl zwischen 1 und 1440 Minuten sein.' })
    }
    $compression = Get-EventProp $obj 'compression'
    if ($null -eq $compression) { $compression = 'Fast' }
    if ($compression -isnot [string] -or ($compression -cne 'Fast' -and $compression -cne 'Store')) {
        return (New-ApiResult 400 @{ error = 'Die Kompression muss "Fast" oder "Store" sein.' })
    }
    $include = Get-EventProp $obj 'includeGenerated'
    if ($null -eq $include) { $include = $false }
    if ($include -isnot [bool]) {
        return (New-ApiResult 400 @{ error = 'Die Option "Build-Ordner einschließen" muss ein Ja/Nein-Wert sein.' })
    }

    if (-not (Test-Path -LiteralPath $ShareScript -PathType Leaf)) {
        return (New-ApiResult 500 @{ error = 'Share-Workspace.ps1 wurde nicht gefunden.' })
    }

    $argList = @('-NoLogo', '-NoProfile', '-NonInteractive', '-File', $ShareScript,
        '-Path', $fullPath, '-Minutes', [string]$minutes, '-Compression', [string]$compression)
    if ($include) { $argList += '-IncludeGenerated' }
    $argList += @('-NoClipboard', '-EventStream', '-ParentProcessId', [string]$PID)

    $encoding = [Text.Encoding]::UTF8
    if ($script:Platform -eq 'windows') {
        try { $encoding = [Text.Encoding]::GetEncoding([Globalization.CultureInfo]::CurrentCulture.TextInfo.OEMCodePage) } catch { $encoding = [Text.Encoding]::UTF8 }
    }
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = Get-WsPowerShellHost
    $psi.Arguments = (($argList | ForEach-Object { ConvertTo-NativeArgument ([string]$_) }) -join ' ')
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.StandardOutputEncoding = $encoding
    $psi.StandardErrorEncoding = $encoding
    $psi.WorkingDirectory = $ToolRoot

    # New share: reset every share field and the log.
    $script:Share = New-ShareState
    $script:Log.Clear()
    $script:KnownUrl = $null
    $script:KillSent = $false
    $script:StopSw = $null
    $script:ExitSeen = $null
    $script:Share.request = [ordered]@{
        path = $fullPath; minutes = [int]$minutes; compression = [string]$compression; includeGenerated = [bool]$include
    }
    $script:LastPath = $fullPath
    $script:Share.phase = 'starting'
    if ($useDrop) { $script:CurrentDrop.InUse = $true }

    $proc = New-Object System.Diagnostics.Process
    $proc.StartInfo = $psi
    try {
        [void]$proc.Start()
        # Touch the handle so ExitCode stays readable after the process has exited.
        $null = $proc.Handle
    }
    catch {
        try { $proc.Dispose() } catch { }
        $script:Share.phase = 'error'
        $script:Share.message = 'Der Freigabeprozess konnte nicht gestartet werden.'
        if ($useDrop) { Remove-CurrentDrop }
        Write-ConsoleLog ('Start fehlgeschlagen: ' + $_.Exception.Message)
        return (New-ApiResult 500 @{ error = 'Der Freigabeprozess konnte nicht gestartet werden.' })
    }
    $script:Proc = $proc
    $script:Readers.out = $proc.StandardOutput
    $script:Readers.err = $proc.StandardError
    $script:Tasks.out = $proc.StandardOutput.ReadLineAsync()
    $script:Tasks.err = $proc.StandardError.ReadLineAsync()
    $script:Eof.out = $false
    $script:Eof.err = $false
    return (New-ApiResult 200 @{ ok = $true })
}

function Invoke-ApiStop {
    if ($null -eq $script:Proc) {
        return (New-ApiResult 409 @{ error = 'Es läuft keine Freigabe.' })
    }
    Request-ShareStop
    return (New-ApiResult 200 @{ ok = $true })
}

function Invoke-ApiCopy {
    $url = $script:Share.url
    if ([string]::IsNullOrEmpty([string]$url)) {
        return (New-ApiResult 409 @{ error = 'Es gibt keinen Link zum Kopieren.' })
    }
    $ok = $false
    try { $ok = [bool](Set-WsClipboardText -Text ([string]$url)) } catch { $ok = $false }
    if (-not $ok) {
        return (New-ApiResult 500 @{ error = 'Der Link konnte nicht in die Zwischenablage kopiert werden.' })
    }
    $script:CopiedUrl = [string]$url
    return (New-ApiResult 200 @{ ok = $true })
}

function Invoke-ApiPickFolder {
    if (Test-ShareBusyPhase) {
        return (New-ApiResult 409 @{ error = 'Während einer Freigabe kann kein Ordner gewählt werden.' })
    }
    if (-not $script:Caps.folderPicker) {
        return (New-ApiResult 501 @{ error = 'Die Ordnerauswahl wird auf diesem System nicht unterstützt.' })
    }
    $picked = $null
    try { $picked = Show-WsFolderPicker -InitialPath $script:LastPath } catch { $picked = $null }
    if ([string]::IsNullOrWhiteSpace([string]$picked)) {
        return (New-ApiResult 200 @{ cancelled = $true })
    }
    $script:LastPath = [string]$picked
    return (New-ApiResult 200 @{ path = [string]$picked })
}

function Invoke-ApiQuit {
    $script:QuitRequested = $true
    return (New-ApiResult 200 @{ ok = $true })
}

function Test-DropPhaseBusy {
    return ($script:QuitRequested -or (Test-ShareBusyPhase))
}

function New-DropId {
    $bytes = New-Object byte[] 16
    $rng = New-Object System.Security.Cryptography.RNGCryptoServiceProvider
    try { $rng.GetBytes($bytes) } finally { $rng.Dispose() }
    return (($bytes | ForEach-Object { $_.ToString('x2') }) -join '')
}

function Get-RequestDropId {
    # dropId from a JSON body, or $null when the body or the id is malformed.
    param($Req)
    $obj = $null
    try { $obj = $Req.Body | ConvertFrom-Json } catch { $obj = $null }
    if ($null -eq $obj -or $obj -isnot [pscustomobject]) { return $null }
    $id = Get-EventProp $obj 'dropId'
    if ($id -isnot [string] -or $id -cnotmatch '^[0-9a-f]{32}$') { return $null }
    return $id
}

function Invoke-ApiDropBegin {
    if (Test-DropPhaseBusy) {
        return (New-ApiResult 409 @{ error = 'Es läuft bereits eine Freigabe.' })
    }
    Remove-CurrentDrop
    $id = New-DropId
    $leafName = 'Dateien-' + (Get-Date).ToString('yyyyMMdd-HHmmss', [Globalization.CultureInfo]::InvariantCulture)
    $root = Join-Path $DropsRoot $id
    $leaf = Join-Path $root $leafName
    try { [void][IO.Directory]::CreateDirectory($leaf) }
    catch {
        Write-ConsoleLog ('Drop-Ordner konnte nicht angelegt werden: ' + $_.Exception.Message)
        return (New-ApiResult 500 @{ error = 'Der temporäre Ordner konnte nicht angelegt werden.' })
    }
    $script:CurrentDrop = @{
        Id = $id; Root = $root; Leaf = [IO.Path]::GetFullPath($leaf)
        Files = 0; Bytes = [int64]0; Finished = $false; InUse = $false
        Paths = (New-Object 'System.Collections.Generic.HashSet[string]' -ArgumentList ([StringComparer]::OrdinalIgnoreCase))
    }
    return (New-ApiResult 200 @{ dropId = $id })
}

function Invoke-ApiDropFinish {
    param($Req)
    if (Test-DropPhaseBusy) {
        return (New-ApiResult 409 @{ error = 'Es läuft bereits eine Freigabe.' })
    }
    $id = Get-RequestDropId $Req
    $d = $script:CurrentDrop
    if ($null -eq $id -or $null -eq $d -or $id -cne $d.Id) {
        return (New-ApiResult 400 @{ error = 'Unbekannte Drop-ID.' })
    }
    if ($d.Files -lt 1) {
        return (New-ApiResult 400 @{ error = 'Es wurde keine Datei übertragen.' })
    }
    $d.Finished = $true
    return (New-ApiResult 200 ([ordered]@{ path = $d.Leaf; files = [int]$d.Files; totalBytes = [int64]$d.Bytes }))
}

function Invoke-ApiDropDiscard {
    param($Req)
    if (Test-DropPhaseBusy) {
        return (New-ApiResult 409 @{ error = 'Es läuft bereits eine Freigabe.' })
    }
    $id = Get-RequestDropId $Req
    $d = $script:CurrentDrop
    if ($null -eq $id -or $null -eq $d -or $id -cne $d.Id) {
        return (New-ApiResult 400 @{ error = 'Unbekannte Drop-ID.' })
    }
    Remove-CurrentDrop
    return (New-ApiResult 200 @{ ok = $true })
}

function Get-ErrorText {
    param([int]$Status)
    switch ($Status) {
        400 { 'Ungültige Anfrage.' }
        401 { 'Nicht autorisiert.' }
        403 { 'Zugriff verweigert.' }
        404 { 'Nicht gefunden.' }
        405 { 'Methode nicht erlaubt.' }
        408 { 'Zeitüberschreitung.' }
        409 { 'Konflikt.' }
        411 { 'Content-Length fehlt.' }
        413 { 'Anfrage zu groß.' }
        431 { 'Anfrage-Header zu groß.' }
        507 { 'Nicht genügend Speicherplatz.' }
        default { 'Interner Fehler.' }
    }
}

function Skip-RequestBody {
    # After an early rejection: read and discard (a bounded amount of) the body so the peer can finish
    # sending and sees the response instead of a connection reset.
    param($Stream, $Client, $Req, [int64]$Limit)
    try {
        if ($Req.Headers.ContainsKey('Expect')) { return }
        $remaining = [int64]$Req.ContentLength - [int64]$Req.BodyPrefix.Length
        if ($remaining -le 0) { return }
        if ($remaining -gt $Limit) { $remaining = $Limit }
        try { $Client.Client.Shutdown([System.Net.Sockets.SocketShutdown]::Send) } catch { }
        $buf = New-Object byte[] 65536
        $sw = [Diagnostics.Stopwatch]::StartNew()
        while ($remaining -gt 0 -and $sw.Elapsed.TotalSeconds -lt 20) {
            $Stream.ReadTimeout = 2000
            $want = $buf.Length
            if ($remaining -lt $want) { $want = [int]$remaining }
            $n = $Stream.Read($buf, 0, $want)
            if ($n -le 0) { break }
            $remaining -= $n
        }
    }
    catch { }
}

function Send-UploadReject {
    param($Stream, $Client, $Req, [int]$Status, [string]$Message, [int64]$DrainLimit = 67108864)
    if ([string]::IsNullOrEmpty($Message)) { $Message = Get-ErrorText $Status }
    try { Write-WsJsonResponse -Stream $Stream -Status $Status -Object @{ error = $Message } } catch { return }
    Skip-RequestBody $Stream $Client $Req $DrainLimit
}

function Get-DeepestException {
    param($Exception)
    $e = $Exception
    while ($null -ne $e.InnerException) { $e = $e.InnerException }
    return $e
}

function Get-IoFailureStatus {
    # Maps a failure while creating or writing a drop file to an HTTP status.
    param($Exception, [string]$FullPath)
    $e = Get-DeepestException $Exception
    if ($e -is [System.IO.PathTooLongException] -or $e -is [System.ArgumentException] -or $e -is [System.NotSupportedException]) { return 400 }
    $code = 0
    try { $code = [int]($e.HResult -band 0xFFFF) } catch { $code = 0 }
    if ($code -eq 112 -or $code -eq 39) { return 507 }
    if ($e -is [System.IO.IOException] -and -not [string]::IsNullOrEmpty($FullPath) -and (Test-Path -LiteralPath $FullPath)) { return 409 }
    if ($e -is [System.IO.IOException] -and $e.Message -match '(?i)no space|disk full') { return 507 }
    return 500
}

function Remove-PartialDropFile {
    param([string]$FullPath, [string]$Leaf)
    for ($i = 0; $i -lt 5; $i++) {
        try { if ([IO.File]::Exists($FullPath)) { [IO.File]::Delete($FullPath) }; break }
        catch { Start-Sleep -Milliseconds 100 }
    }
    # Remove directories this upload created (empty ones only), up to the drop leaf.
    try {
        $p = [IO.Path]::GetDirectoryName($FullPath)
        $sepChar = [string][IO.Path]::DirectorySeparatorChar
        while (-not [string]::IsNullOrEmpty($p) -and $p.StartsWith($Leaf + $sepChar, $script:PathComparison)) {
            if (-not [IO.Directory]::Exists($p) -or [IO.Directory]::GetFileSystemEntries($p).Length -gt 0) { break }
            [IO.Directory]::Delete($p)
            $p = [IO.Path]::GetDirectoryName($p)
        }
    }
    catch { }
}

function Invoke-DropFileUpload {
    # POST /api/drop/file?drop=<id>&path=<relative path>: the body streams straight to disk.
    # Called with a -HeadersOnly request, before anything of the body has been read.
    param($Req, $Stream, $Client)
    $rejectSmall = [int64]1048576
    $chk = Test-WsRequestAllowed -Request $Req -Port $script:BoundPort -Token $script:Token -RequireToken
    if (-not $chk.Allowed) {
        Send-UploadReject $Stream $Client $Req ([int]$chk.Status) '' $rejectSmall
        return
    }
    if (Test-DropPhaseBusy) {
        Send-UploadReject $Stream $Client $Req 409 'Es läuft bereits eine Freigabe.'
        return
    }
    $q = Get-DropQueryValues $Req.Query
    $d = $script:CurrentDrop
    if ($null -eq $q -or -not $q.ContainsKey('drop') -or -not $q.ContainsKey('path') -or $null -eq $d -or [string]$q['drop'] -cne $d.Id) {
        Send-UploadReject $Stream $Client $Req 400 'Unbekannte Drop-ID.'
        return
    }
    if ($d.Finished) {
        Send-UploadReject $Stream $Client $Req 409 'Der Drop ist bereits abgeschlossen.'
        return
    }
    $rel = Convert-DropRelativePath ([string]$q['path'])
    if ($null -eq $rel) {
        Send-UploadReject $Stream $Client $Req 400 'Ungültiger Datei- oder Ordnername.'
        return
    }
    $leaf = [string]$d.Leaf
    $sepChar = [string][IO.Path]::DirectorySeparatorChar
    $full = $null
    try {
        $full = [IO.Path]::GetFullPath([IO.Path]::Combine($leaf, $rel.Replace('/', $sepChar)))
        if (-not $full.StartsWith($leaf + $sepChar, $script:PathComparison)) { $full = $null }
    }
    catch { $full = $null }
    if ($null -eq $full) {
        Send-UploadReject $Stream $Client $Req 400 'Ungültiger oder zu langer Pfad.'
        return
    }
    # Duplicate, or a file/folder name clash with an earlier path.
    $clash = $d.Paths.Contains($rel)
    $segs = $rel.Split('/')
    for ($i = 1; $i -lt $segs.Count -and -not $clash; $i++) {
        if ($d.Paths.Contains((($segs[0..($i - 1)]) -join '/'))) { $clash = $true }
    }
    if (-not $clash -and (Test-Path -LiteralPath $full)) { $clash = $true }
    if ($clash) {
        Send-UploadReject $Stream $Client $Req 409 'Dieser Pfad wurde bereits übertragen.'
        return
    }
    $len = [int64]$Req.ContentLength
    if ($len -lt 0) {
        Send-UploadReject $Stream $Client $Req 411 '' $rejectSmall
        return
    }
    if (([int64]$d.Files + 1) -gt [int64]$MaxDropFiles) {
        Send-UploadReject $Stream $Client $Req 413 'Zu viele Dateien.'
        return
    }
    if ($len -gt $MaxDropBytes -or ([int64]$d.Bytes + $len) -gt $MaxDropBytes) {
        Send-UploadReject $Stream $Client $Req 413 'Die Dateien sind zu groß.'
        return
    }
    $free = Get-FreeSpaceBytes
    if ($free -ge 0 -and $free -lt ($len + [int64]536870912)) {
        Send-UploadReject $Stream $Client $Req 507 'Nicht genügend Speicherplatz.'
        return
    }

    $fs = $null
    try {
        [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($full))
        $fs = New-Object System.IO.FileStream -ArgumentList $full, ([IO.FileMode]::CreateNew), ([IO.FileAccess]::Write), ([IO.FileShare]::None), 65536
    }
    catch {
        if ($null -ne $fs) { try { $fs.Dispose() } catch { } }
        $st = Get-IoFailureStatus $_.Exception $full
        Write-ConsoleLog ('Drop-Datei konnte nicht angelegt werden: ' + $_.Exception.Message)
        Send-UploadReject $Stream $Client $Req $st ''
        return
    }

    if ($Req.Headers.ContainsKey('Expect') -and [string]$Req.Headers['Expect'] -ieq '100-continue') {
        try {
            $cont = [Text.Encoding]::ASCII.GetBytes("HTTP/1.1 100 Continue`r`n`r`n")
            $Stream.Write($cont, 0, $cont.Length)
            $Stream.Flush()
        }
        catch { }
    }

    $failStatus = 0
    $failText = ''
    try {
        try { $Client.ReceiveTimeout = 30000 } catch { }
        Copy-WsHttpBody -Stream $Stream -Request $Req -Destination $fs -MaxBytes ([int64]$MaxDropBytes - [int64]$d.Bytes) -IdleTimeoutMs 30000
        $fs.Flush()
    }
    catch {
        $ex = $_.Exception
        if ($ex.Data.Contains('WsHttpStatus')) { $failStatus = [int]$ex.Data['WsHttpStatus'] }
        else { $failStatus = Get-IoFailureStatus $ex $null; if ($failStatus -eq 409) { $failStatus = 500 } }
        $failText = $ex.Message
        Write-ConsoleLog ('Drop-Upload fehlgeschlagen (' + $failStatus + '): ' + $failText)
    }
    finally {
        try { $fs.Dispose() } catch { if ($failStatus -eq 0) { $failStatus = 500 } }
    }
    if ($failStatus -ne 0) {
        Remove-PartialDropFile $full $leaf
        # A dead or stalled peer gets no drain; otherwise the unread rest of the body is discarded.
        $drain = [int64]67108864
        if ($failStatus -eq 400 -or $failStatus -eq 408) { $drain = [int64]0 }
        Send-UploadReject $Stream $Client $Req $failStatus '' $drain
        return
    }
    $d.Files = [int]$d.Files + 1
    $d.Bytes = [int64]$d.Bytes + $len
    [void]$d.Paths.Add($rel)
    Write-WsJsonResponse -Stream $Stream -Status 200 -Object ([ordered]@{ ok = $true; bytes = $len })
}

# ---------------------------------------------------------------- HTTP plumbing

function Send-ErrorJson {
    param($Stream, [int]$Status)
    Write-WsJsonResponse -Stream $Stream -Status $Status -Object @{ error = (Get-ErrorText $Status) }
}

function Complete-RequestBody {
    # Reads the (small) JSON body of a request that was parsed with -HeadersOnly; same limits and
    # statuses as Read-WsHttpRequest without the switch (413 / 400 / 408).
    param($Req, $Stream)
    $len = [int64]$Req.ContentLength
    if ($len -le 0) { return $Req }
    $ms = New-Object System.IO.MemoryStream
    Copy-WsHttpBody -Stream $Stream -Request $Req -Destination $ms -MaxBytes 65536 -IdleTimeoutMs 5000
    try {
        $strict = New-Object System.Text.UTF8Encoding ($false, $true)
        $Req.Body = $strict.GetString($ms.ToArray())
    }
    catch {
        $ex = New-Object System.Exception 'Request body is not valid UTF-8.'
        $ex.Data['WsHttpStatus'] = 400
        throw $ex
    }
    return $Req
}

function Invoke-Route {
    param($Req, $Stream)
    $isApi = $Req.Path.StartsWith('/api/', [StringComparison]::Ordinal)
    if ($isApi) {
        $chk = Test-WsRequestAllowed -Request $Req -Port $script:BoundPort -Token $script:Token -RequireToken
    }
    else {
        $chk = Test-WsRequestAllowed -Request $Req -Port $script:BoundPort -Token $script:Token
    }
    if (-not $chk.Allowed) { Send-ErrorJson $Stream ([int]$chk.Status); return }

    if (-not $isApi) {
        $file = $null
        if ($Req.Method -ceq 'GET') {
            $file = Get-WsStaticFile -Path $Req.Path -GuiRoot $GuiRoot
            if ($null -ne $file) {
                Write-WsHttpResponse -Stream $Stream -Status 200 -ContentType $file.ContentType -Body $file.Bytes
                return
            }
            Send-ErrorJson $Stream 404
            return
        }
        # Known static path with a wrong method -> 405, anything else -> 404.
        $probe = Get-WsStaticFile -Path $Req.Path -GuiRoot $GuiRoot
        if ($null -ne $probe) { Send-ErrorJson $Stream 405 } else { Send-ErrorJson $Stream 404 }
        return
    }

    $result = $null
    switch -CaseSensitive ($Req.Path) {
        '/api/state' {
            if ($Req.Method -cne 'GET') { Send-ErrorJson $Stream 405; return }
            $result = New-ApiResult 200 (Get-StateObject)
        }
        '/api/pick-folder' {
            if ($Req.Method -cne 'POST') { Send-ErrorJson $Stream 405; return }
            $result = Invoke-ApiPickFolder
        }
        '/api/start' {
            if ($Req.Method -cne 'POST') { Send-ErrorJson $Stream 405; return }
            $result = Invoke-ApiStart $Req
        }
        '/api/stop' {
            if ($Req.Method -cne 'POST') { Send-ErrorJson $Stream 405; return }
            $result = Invoke-ApiStop
        }
        '/api/copy' {
            if ($Req.Method -cne 'POST') { Send-ErrorJson $Stream 405; return }
            $result = Invoke-ApiCopy
        }
        '/api/quit' {
            if ($Req.Method -cne 'POST') { Send-ErrorJson $Stream 405; return }
            $result = Invoke-ApiQuit
        }
        '/api/drop/begin' {
            if ($Req.Method -cne 'POST') { Send-ErrorJson $Stream 405; return }
            $result = Invoke-ApiDropBegin
        }
        '/api/drop/finish' {
            if ($Req.Method -cne 'POST') { Send-ErrorJson $Stream 405; return }
            $result = Invoke-ApiDropFinish $Req
        }
        '/api/drop/discard' {
            if ($Req.Method -cne 'POST') { Send-ErrorJson $Stream 405; return }
            $result = Invoke-ApiDropDiscard $Req
        }
        '/api/drop/file' {
            # POST is handled earlier by Invoke-DropFileUpload; anything else is a wrong method.
            Send-ErrorJson $Stream 405; return
        }
        default { Send-ErrorJson $Stream 404; return }
    }
    Write-WsJsonResponse -Stream $Stream -Status $result.Status -Object $result.Body
}

function Invoke-Connection {
    param($Client)
    $stream = $null
    try {
        $Client.ReceiveTimeout = 5000
        $Client.SendTimeout = 5000
        $stream = $Client.GetStream()
        $req = $null
        try {
            $req = Read-WsHttpRequest -Stream $stream -TimeoutMs 5000 -HeadersOnly
            if ($req.Method -ceq 'POST' -and $req.Path -ceq '/api/drop/file') {
                # File uploads stream straight to disk; authorization happens before any body byte is read.
                Invoke-DropFileUpload $req $stream $Client
                return
            }
            $req = Complete-RequestBody $req $stream
        }
        catch {
            $status = 0
            if ($_.Exception.Data.Contains('WsHttpStatus')) { $status = [int]$_.Exception.Data['WsHttpStatus'] }
            if ($status -gt 0) {
                try { Send-ErrorJson $stream $status } catch { }
                return
            }
            throw
        }
        Invoke-Route $req $stream
    }
    catch {
        Write-ConsoleLog ('Anfrage fehlgeschlagen: ' + $_.Exception.Message)
        if ($null -ne $stream) {
            try { Send-ErrorJson $stream 500 } catch { }
        }
    }
    finally {
        if ($null -ne $stream) { try { $stream.Dispose() } catch { } }
        try { $Client.Close() } catch { }
    }
}

# ---------------------------------------------------------------- single instance

$mutexName = 'Local\WorkspaceShare.Gui'
if ($TestMode) {
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try { $hash = $sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($InstanceFile.ToLowerInvariant())) } finally { $sha.Dispose() }
    $hex = (($hash | ForEach-Object { $_.ToString('x2') }) -join '')
    $mutexName = $mutexName + '.' + $hex.Substring(0, 16)
}
$mutex = New-Object System.Threading.Mutex($false, $mutexName)
$ownsMutex = Enter-InstanceMutex $mutex 0
if (-not $ownsMutex) {
    if (Open-ExistingInstance (Read-InstanceFile $InstanceFile)) { $mutex.Dispose(); exit 0 }
    # Stale or still starting instance: wait up to 5 s.
    $waitSw = [Diagnostics.Stopwatch]::StartNew()
    while (-not $ownsMutex -and $waitSw.Elapsed.TotalSeconds -lt 5) {
        $ownsMutex = Enter-InstanceMutex $mutex 250
        if (-not $ownsMutex -and (Open-ExistingInstance (Read-InstanceFile $InstanceFile))) { $mutex.Dispose(); exit 0 }
    }
    if (-not $ownsMutex) {
        [Console]::Error.WriteLine('Eine andere WorkspaceShare-GUI blockiert den Start.')
        $mutex.Dispose()
        exit 1
    }
}

# ---------------------------------------------------------------- main

$listener = $null
$instanceWritten = $false
$exitCode = 0
try {
    $script:Token = New-GuiToken
    # Single instance holds the mutex: every drop folder found now is left over from a crashed run.
    if ($StaleDropCleanup) { try { Clear-StaleDrops } catch { Write-ConsoleLog ('Alte Drop-Ordner: ' + $_.Exception.Message) } }
    $listener = New-Object System.Net.Sockets.TcpListener -ArgumentList ([System.Net.IPAddress]::Loopback), $Port
    try { $listener.ExclusiveAddressUse = $true } catch { }
    $listener.Start()
    $script:BoundPort = ([System.Net.IPEndPoint]$listener.LocalEndpoint).Port

    $startTicks = (Get-Process -Id $PID).StartTime.ToUniversalTime().Ticks
    $instanceJson = ConvertTo-WsJson -Object ([ordered]@{ pid = $PID; startTicks = $startTicks; port = $script:BoundPort; token = $script:Token })
    $instanceDir = Split-Path -Parent $InstanceFile
    if (-not (Test-Path -LiteralPath $instanceDir -PathType Container)) { [void](New-Item -ItemType Directory -Path $instanceDir -Force) }
    $tmpFile = $InstanceFile + '.tmp'
    [IO.File]::WriteAllText($tmpFile, $instanceJson, (New-Object System.Text.UTF8Encoding($false)))
    Move-Item -LiteralPath $tmpFile -Destination $InstanceFile -Force
    $instanceWritten = $true

    Write-Host ('WorkspaceShare-GUI läuft auf http://127.0.0.1:{0}/' -f $script:BoundPort)
    if (-not $NoBrowser) {
        [void](Open-WsBrowser -Url ('http://127.0.0.1:{0}/#{1}' -f $script:BoundPort, $script:Token))
    }

    # Accepted connections wait here until their first bytes arrive, so idle browser
    # preconnects cannot stall the single-threaded loop.
    $pending = New-Object 'System.Collections.Generic.List[object]'
    $loopOn = $true
    while ($loopOn) {
        $busy = $false
        try {
            Update-Child
            if ($script:PendingDeletes.Count -gt 0 -and $script:PendingSw.Elapsed.TotalSeconds -gt 5) {
                $script:PendingSw.Restart()
                Clear-PendingDeletes
            }
            while ($listener.Pending() -and $pending.Count -lt 32) {
                $c = $listener.AcceptTcpClient()
                $pending.Add(@{ Client = $c; Sw = [Diagnostics.Stopwatch]::StartNew() })
                $busy = $true
            }
            for ($i = $pending.Count - 1; $i -ge 0; $i--) {
                $entry = $pending[$i]
                $c = $entry.Client
                $ready = $false
                $drop = $false
                try {
                    if ($c.Available -gt 0) { $ready = $true }
                    elseif ($c.Client.Poll(0, [System.Net.Sockets.SelectMode]::SelectRead)) {
                        # Readable with nothing available means the peer closed; data may have arrived since the first check.
                        if ($c.Available -gt 0) { $ready = $true } else { $drop = $true }
                    }
                    elseif ($entry.Sw.ElapsedMilliseconds -gt 5000) { $drop = $true }
                }
                catch { $drop = $true }
                if ($ready) {
                    $pending.RemoveAt($i)
                    Invoke-Connection $c
                    $busy = $true
                }
                elseif ($drop) {
                    $pending.RemoveAt($i)
                    try { $c.Close() } catch { }
                }
            }
            if ($script:QuitRequested) {
                if ($null -eq $script:Proc) { $loopOn = $false }
                elseif (-not $script:QuitStopSent) {
                    $script:QuitStopSent = $true
                    $script:QuitSw = [Diagnostics.Stopwatch]::StartNew()
                    Request-ShareStop
                }
                elseif ($null -eq $script:QuitKillSw -and $script:QuitSw.Elapsed.TotalSeconds -gt 120) {
                    Stop-ChildTree
                    $script:QuitKillSw = [Diagnostics.Stopwatch]::StartNew()
                }
                elseif ($null -ne $script:QuitKillSw -and $script:QuitKillSw.Elapsed.TotalSeconds -gt 10) {
                    $loopOn = $false
                }
            }
        }
        catch {
            Write-ConsoleLog ('Schleifenfehler: ' + $_.Exception.Message)
            Start-Sleep -Milliseconds 200
        }
        if ($loopOn -and -not $busy) { Start-Sleep -Milliseconds 50 }
    }
    foreach ($e in $pending) { try { $e.Client.Close() } catch { } }
}
catch {
    [Console]::Error.WriteLine('WorkspaceShare-GUI konnte nicht gestartet werden: ' + (Protect-Text $_.Exception.Message))
    $exitCode = 1
}
finally {
    try { Stop-ShareForShutdown } catch { }
    try { Remove-CurrentDrop; Clear-PendingDeletes } catch { }
    if ($script:CopiedUrl) { try { [void](Clear-WsClipboardText -Expected $script:CopiedUrl) } catch { } }
    if ($null -ne $listener) { try { $listener.Stop() } catch { } }
    if ($instanceWritten) {
        $inst = Read-InstanceFile $InstanceFile
        if ($null -eq $inst -or [int]$inst.pid -eq $PID) {
            try { Remove-Item -LiteralPath $InstanceFile -Force -ErrorAction SilentlyContinue } catch { }
        }
    }
    try { $mutex.ReleaseMutex() } catch { }
    try { $mutex.Dispose() } catch { }
}
exit $exitCode
