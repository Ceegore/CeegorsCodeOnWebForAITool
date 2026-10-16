#requires -Version 5.1
# WorkspaceShare GUI backend (GUI_CONTRACT section 5): local HTTP server on 127.0.0.1 that serves gui\*
# and starts/stops Share-Workspace.ps1 as a child process. Single-threaded loop, compile-free (no Add-Type).
[CmdletBinding()]
param(
    [int]$Port = 0,
    [switch]$NoBrowser,
    [string]$InstanceFile,
    [switch]$TestMode,
    [string]$TestShareScript
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (-not [string]::IsNullOrEmpty($TestShareScript) -and -not $TestMode) {
    [Console]::Error.WriteLine('-TestShareScript ist nur zusammen mit -TestMode erlaubt.')
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
if ([string]::IsNullOrWhiteSpace($InstanceFile)) {
    $InstanceFile = Join-Path (Get-WsDataRoot) 'gui-instance.json'
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
    }
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

# ---------------------------------------------------------------- HTTP plumbing

function Send-ErrorJson {
    param($Stream, [int]$Status)
    $text = switch ($Status) {
        400 { 'Ungültige Anfrage.' }
        401 { 'Nicht autorisiert.' }
        403 { 'Zugriff verweigert.' }
        404 { 'Nicht gefunden.' }
        405 { 'Methode nicht erlaubt.' }
        408 { 'Zeitüberschreitung.' }
        413 { 'Anfrage zu groß.' }
        431 { 'Anfrage-Header zu groß.' }
        default { 'Interner Fehler.' }
    }
    Write-WsJsonResponse -Stream $Stream -Status $Status -Object @{ error = $text }
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
        try { $req = Read-WsHttpRequest -Stream $stream -TimeoutMs 5000 }
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
