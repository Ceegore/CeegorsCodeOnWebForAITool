#requires -Version 5.1
# WorkspaceShare GUI backend (GUI_CONTRACT sections 5, 7, 8): local HTTP server on 127.0.0.1 that serves gui\*
# and runs several shares at once, each as its own Share-Workspace.ps1 child process. Single-threaded loop that
# drains every child pipe in every iteration (also while an upload runs), compile-free (no Add-Type).
[CmdletBinding()]
param(
    [int]$Port = 0,
    [switch]$NoBrowser,
    [string]$InstanceFile,
    [switch]$TestMode,
    [string]$TestShareScript,
    [int64]$MaxDropBytes = 4GB,
    [int]$MaxDropFiles = 10000,
    [int]$MaxShares = 5,
    [string]$DataRootOverride,
    [string]$TestBuildId,
    [string]$TestPickerResult
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
if (-not [string]::IsNullOrEmpty($TestBuildId) -and -not $TestMode) {
    [Console]::Error.WriteLine('-TestBuildId ist nur zusammen mit -TestMode erlaubt.')
    exit 10
}
if (-not [string]::IsNullOrEmpty($TestBuildId) -and $TestBuildId -cnotmatch '^[A-Za-z0-9_-]{1,64}$') {
    [Console]::Error.WriteLine('Ungültige -TestBuildId.')
    exit 10
}
if ($MaxDropBytes -lt 1 -or $MaxDropFiles -lt 1) {
    [Console]::Error.WriteLine('Ungültige Drop-Limits.')
    exit 10
}
if ($MaxShares -lt 1 -or $MaxShares -gt 10) {
    [Console]::Error.WriteLine('Ungültiges -MaxShares (erlaubt: 1 bis 10).')
    exit 10
}
if (-not [string]::IsNullOrEmpty($TestPickerResult) -and -not $TestMode) {
    [Console]::Error.WriteLine('-TestPickerResult ist nur zusammen mit -TestMode erlaubt.')
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
        return ((Get-WsProcessStartTicks -ProcessId ([int]$ProcessId)) -eq [long]$StartTicks)
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

function Get-BuildIdentity {
    # First 16 hex chars of SHA-256 over the files that make up this version (a missing file contributes
    # its name only). Names use '/' so the id is the same on every OS. Tests may override it.
    if ($TestMode -and -not [string]::IsNullOrEmpty($TestBuildId)) { return $TestBuildId }
    $names = @('VERSION', 'Start-WorkspaceShareGui.ps1', 'scripts/WorkspaceShare.Gui.Http.psm1',
        'scripts/WorkspaceShare.Platform.psm1', 'gui/index.html', 'gui/app.js', 'gui/app.css', 'gui/favicon.svg')
    $ms = New-Object System.IO.MemoryStream
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        foreach ($name in $names) {
            $full = Join-Path $ToolRoot $name
            [byte[]]$bytes = $null
            if (Test-Path -LiteralPath $full -PathType Leaf) {
                try { $bytes = [IO.File]::ReadAllBytes($full) } catch { $bytes = $null }
            }
            if ($null -eq $bytes) { $bytes = [Text.Encoding]::UTF8.GetBytes($name) }
            $ms.Write($bytes, 0, $bytes.Length)
        }
        $hash = $sha.ComputeHash($ms.ToArray())
    }
    finally { $sha.Dispose(); $ms.Dispose() }
    return ((($hash | ForEach-Object { $_.ToString('x2') }) -join '').Substring(0, 16))
}

function Initialize-StaticCache {
    # Static files are read once at start, so UI and API always come from the same version.
    $script:Static = New-Object 'System.Collections.Generic.Dictionary[string,object]'
    foreach ($p in @('/index.html', '/app.js', '/app.css', '/favicon.svg')) {
        $f = Get-WsStaticFile -Path $p -GuiRoot $GuiRoot
        if ($null -ne $f) { $script:Static[$p] = $f }
    }
    if ($script:Static.ContainsKey('/index.html')) { $script:Static['/'] = $script:Static['/index.html'] }
}

function Invoke-LocalApi {
    # Minimal HTTP/1.1 request to a GUI backend on 127.0.0.1 over a raw TcpClient (no proxy, same on
    # PS 5.1 and 7). Returns @{ Status; Body } or $null when it does not answer within TimeoutMs.
    param([int]$Port, [string]$Token, [string]$Method, [string]$Path, [int]$TimeoutMs = 5000)
    $client = $null
    try {
        $sw = [Diagnostics.Stopwatch]::StartNew()
        $client = New-Object System.Net.Sockets.TcpClient
        $ar = $client.BeginConnect('127.0.0.1', $Port, $null, $null)
        if (-not $ar.AsyncWaitHandle.WaitOne($TimeoutMs)) { return $null }
        $client.EndConnect($ar)
        $utf8 = New-Object System.Text.UTF8Encoding ($false)
        $bodyBytes = New-Object byte[] 0
        $head = 'Host: 127.0.0.1:{0}' -f $Port
        $head += "`r`nX-WS-Token: " + $Token
        if ($Method -ceq 'POST') {
            $bodyBytes = $utf8.GetBytes('{}')
            $head += "`r`nContent-Type: application/json`r`nContent-Length: " + $bodyBytes.Length
        }
        $head += "`r`nConnection: close`r`n`r`n"
        $headBytes = $utf8.GetBytes($Method + ' ' + $Path + " HTTP/1.1`r`n" + $head)
        $stream = $client.GetStream()
        $stream.Write($headBytes, 0, $headBytes.Length)
        if ($bodyBytes.Length -gt 0) { $stream.Write($bodyBytes, 0, $bodyBytes.Length) }
        $stream.Flush()
        $acc = New-Object System.IO.MemoryStream
        $buf = New-Object byte[] 8192
        while ($true) {
            $left = $TimeoutMs - [int]$sw.ElapsedMilliseconds
            if ($left -le 0) { return $null }
            $stream.ReadTimeout = $left
            $n = [int]$stream.Read($buf, 0, $buf.Length)
            if ($n -le 0) { break }
            $acc.Write($buf, 0, $n)
        }
        $text = $utf8.GetString($acc.ToArray())
        $split = $text.IndexOf("`r`n`r`n")
        if ($split -lt 0 -or -not ($text -cmatch '^HTTP/1\.[01] (\d{3}) ')) { return $null }
        return @{ Status = [int]$Matches[1]; Body = $text.Substring($split + 4) }
    }
    catch { return $null }
    finally { if ($null -ne $client) { try { $client.Close() } catch { } } }
}

function Resolve-ExistingInstance {
    # A live instance holds the mutex. Returns 'None' (nothing alive), 'Handled' (browser opened at the
    # existing instance, caller exits 0) or 'Replaced' (older idle instance quit; this process now owns
    # the mutex and starts normally).
    param($Inst)
    if ($null -eq $Inst) { return 'None' }
    if (-not (Test-ProcessAlive $Inst.pid $Inst.startTicks)) { return 'None' }
    $theirs = ''
    $bp = $Inst.PSObject.Properties['build']
    if ($null -ne $bp -and $null -ne $bp.Value) { $theirs = [string]$bp.Value }
    if ($theirs -ceq $script:BuildId) {
        [void](Open-ExistingInstance $Inst)
        return 'Handled'
    }
    $phase = ''
    $resp = Invoke-LocalApi -Port ([int]$Inst.port) -Token ([string]$Inst.token) -Method 'GET' -Path '/api/state' -TimeoutMs 5000
    if ($null -ne $resp -and $resp.Status -eq 200) {
        # v2 state: any share in starting/active/stopping counts as busy; v1 state: its single phase.
        try {
            $st = $resp.Body | ConvertFrom-Json
            $runP = $st.PSObject.Properties['running']
            $phaseP = $st.PSObject.Properties['phase']
            if ($null -ne $runP) { if ([int]$runP.Value -gt 0) { $phase = 'active' } else { $phase = 'idle' } }
            elseif ($null -ne $phaseP) { $phase = [string]$phaseP.Value }
        }
        catch { $phase = '' }
    }
    if ($phase -in @('idle', 'ended', 'error')) {
        # Nothing is shared: replace the old backend with this (newer) one.
        [void](Invoke-LocalApi -Port ([int]$Inst.port) -Token ([string]$Inst.token) -Method 'POST' -Path '/api/quit' -TimeoutMs 5000)
        $sw = [Diagnostics.Stopwatch]::StartNew()
        while ($sw.Elapsed.TotalSeconds -lt 20) {
            if (-not (Test-ProcessAlive $Inst.pid $Inst.startTicks)) {
                $script:ownsMutex = Enter-InstanceMutex $mutex 250
                if ($script:ownsMutex) {
                    Write-Host 'Die vorherige Version von WorkspaceShare wurde beendet. Die neue Version wird gestartet.'
                    return 'Replaced'
                }
            }
            else { Start-Sleep -Milliseconds 200 }
        }
        if (-not (Test-ProcessAlive $Inst.pid $Inst.startTicks)) { return 'None' }
        Write-Host 'Die vorherige Version von WorkspaceShare lässt sich nicht beenden. Das vorhandene Fenster wird geöffnet.'
    }
    elseif ($phase -in @('starting', 'active', 'stopping')) {
        Write-Host 'Eine laufende Freigabe nutzt noch die vorherige Version. Nach dem Beenden der Freigabe WorkspaceShare über die Verknüpfung neu starten.'
    }
    else {
        Write-Host 'Der laufende WorkspaceShare-Dienst antwortet nicht. Das vorhandene Fenster wird geöffnet.'
    }
    [void](Open-ExistingInstance $Inst)
    return 'Handled'
}

function New-GuiToken {
    $bytes = New-Object byte[] 32
    $rng = New-Object System.Security.Cryptography.RNGCryptoServiceProvider
    try { $rng.GetBytes($bytes) } finally { $rng.Dispose() }
    return ([Convert]::ToBase64String($bytes).TrimEnd('=').Replace('+', '-').Replace('/', '_'))
}

# ---------------------------------------------------------------- shares (GUI_CONTRACT section 8)

$script:Platform = Get-WsPlatform
$script:Caps = Get-WsCapabilities
# Test hook: the folder-picker answer is simulated, so the capability does not depend on the desktop session.
if ($TestMode -and -not [string]::IsNullOrEmpty($TestPickerResult)) { $script:Caps.folderPicker = $true }
$script:Shares = New-Object 'System.Collections.Generic.List[object]'
$script:ShareListCap = 20
$script:LastPath = $null
$script:QuitRequested = $false
$script:QuitSw = $null
$script:QuitStopSent = $false
$script:QuitKillSw = $null
$script:Token = ''
$script:BoundPort = 0
$script:CurrentDrop = $null      # draft drop of the "new share" form (no share owns it yet)
$script:UploadBusy = $false
$script:Picker = $null           # folder picker running in its own STA runspace (deferred HTTP answer)
$script:ConnectionDeferred = $false
$script:PendingDeletes = New-Object 'System.Collections.Generic.List[string]'
$script:PendingSw = [Diagnostics.Stopwatch]::StartNew()
$script:PathComparison = [StringComparison]::Ordinal
if ($script:Platform -eq 'windows') { $script:PathComparison = [StringComparison]::OrdinalIgnoreCase }

function New-Share {
    param([string]$Id, [string]$Name, $Request, $Drop)
    $dropFiles = $null
    if ($null -ne $Drop) { $dropFiles = [int]$Drop.Files }
    return @{
        id = $Id; name = $Name; createdUtc = [DateTime]::UtcNow.ToString('o')
        phase = 'starting'; step = 0; total = 8; stepText = $null
        steps = (New-Object 'System.Collections.Generic.List[object]')
        url = $null; expiresUtc = $null; sizeBytes = $null; sha256 = $null
        remainingMinutes = $null; health = $null
        exitCode = $null; reason = $null; message = $null
        request = $Request; dropFiles = $dropFiles
        # Gitleaks findings that blocked the last run (contract 8.6), and the number of findings a run was
        # explicitly started with ("share anyway").
        findings = $null; acceptedFindings = $null
        log = (New-Object 'System.Collections.Generic.List[string]')
        sessionPath = $null; stopRequested = $false; endedGot = $false
        # runtime: child process, async line readers, timers
        proc = $null
        readers = @{ out = $null; err = $null }
        tasks = @{ out = $null; err = $null }
        eof = @{ out = $true; err = $true }
        exitSeen = $null; stopSw = $null; killSent = $false
        knownUrl = $null; copiedUrl = $null
        drop = $Drop
    }
}

function Get-ShareById {
    param([string]$Id)
    foreach ($s in $script:Shares) { if ($s.id -ceq $Id) { return $s } }
    return $null
}

function Test-ShareRunning {
    param($Share)
    return ($Share.phase -in @('starting', 'active', 'stopping'))
}

function Get-RunningCount {
    $n = 0
    foreach ($s in $script:Shares) { if (Test-ShareRunning $s) { $n++ } }
    return $n
}

function Test-AnyChild {
    foreach ($s in $script:Shares) { if ($null -ne $s.proc) { return $true } }
    return $false
}

function Protect-Text {
    # Redacts the links of every known share (and the GUI token) from a text.
    param([AllowNull()][string]$Text)
    if ([string]::IsNullOrEmpty($Text)) { return '' }
    $urls = @()
    foreach ($s in $script:Shares) { if ($s.knownUrl) { $urls += [string]$s.knownUrl } }
    $safe = Protect-DiagnosticText -Text $Text -KnownSecretUrls $urls -SecretTokens @([string]$script:Token)
    if ($safe.Length -gt 2000) { $safe = $safe.Substring(0, 2000) }
    return $safe
}

function Add-LogLine {
    param($Share, [AllowNull()][string]$Text)
    $safe = Protect-Text $Text
    if ($safe.Length -eq 0) { return }
    $Share.log.Add($safe)
    while ($Share.log.Count -gt 200) { $Share.log.RemoveAt(0) }
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

function ConvertTo-LimitedText {
    param([AllowNull()]$Value, [int]$MaxLength)
    $text = Protect-Text ([string]$Value)
    if ($text.Length -gt $MaxLength) { $text = $text.Substring(0, $MaxLength) }
    return $text
}

function ConvertTo-FindingsState {
    # Validates a "findings" event and keeps a bounded copy for the state object; $null if it is unusable.
    param($Ev)
    $digest = Get-EventProp $Ev 'digest'
    if ($digest -isnot [string] -or $digest -cnotmatch '^[0-9a-f]{64}$') { return $null }
    $total = ConvertTo-StrictInt (Get-EventProp $Ev 'total')
    $fileCount = ConvertTo-StrictInt (Get-EventProp $Ev 'fileCount')
    if ($null -eq $total -or $total -lt 1 -or $null -eq $fileCount -or $fileCount -lt 1) { return $null }
    $files = @()
    foreach ($f in @(Get-EventProp $Ev 'files' | Select-Object -First 25)) {
        if ($null -eq $f) { continue }
        $fileRules = @()
        foreach ($r in @(Get-EventProp $f 'rules' | Select-Object -First 10)) {
            if ($null -eq $r) { continue }
            $fileRules += , ([ordered]@{ id = (ConvertTo-LimitedText (Get-EventProp $r 'id') 100); count = [int](ConvertTo-StrictInt (Get-EventProp $r 'count')) })
        }
        $lines = @()
        foreach ($l in @(Get-EventProp $f 'lines' | Select-Object -First 10)) {
            $n = ConvertTo-StrictInt $l
            if ($null -ne $n) { $lines += [int]$n }
        }
        $samples = @()
        foreach ($sm in @(Get-EventProp $f 'samples' | Select-Object -First 3)) {
            if ($null -eq $sm) { continue }
            $samples += , ([ordered]@{
                line = [int](ConvertTo-StrictInt (Get-EventProp $sm 'line'))
                rule = (ConvertTo-LimitedText (Get-EventProp $sm 'rule') 100)
                match = (ConvertTo-LimitedText (Get-EventProp $sm 'match') 160)
            })
        }
        $files += , ([ordered]@{
            path = (ConvertTo-LimitedText (Get-EventProp $f 'path') 400)
            count = [int](ConvertTo-StrictInt (Get-EventProp $f 'count'))
            rules = $fileRules
            lines = $lines
            moreLines = [int](ConvertTo-StrictInt (Get-EventProp $f 'moreLines'))
            samples = $samples
        })
    }
    $rules = @()
    foreach ($r in @(Get-EventProp $Ev 'rules' | Select-Object -First 20)) {
        if ($null -eq $r) { continue }
        $rules += , ([ordered]@{
            id = (ConvertTo-LimitedText (Get-EventProp $r 'id') 100)
            count = [int](ConvertTo-StrictInt (Get-EventProp $r 'count'))
            description = (ConvertTo-LimitedText (Get-EventProp $r 'description') 300)
        })
    }
    return [ordered]@{
        total = [int]$total; fileCount = [int]$fileCount; digest = $digest
        accepted = ((Get-EventProp $Ev 'accepted') -is [bool] -and (Get-EventProp $Ev 'accepted')); files = $files; rules = $rules
    }
}

function Set-ShareEvent {
    param($Share, $Ev)
    $s = $Share
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
            if (-not [string]::IsNullOrEmpty($url)) { $s.knownUrl = $url }
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
                if ($state -ne 'ok' -and $state -ne $previous -and $text) { Add-LogLine $s ('Verbindung: ' + $text) }
            }
        }
        'warning' {
            $text = [string](Get-EventProp $Ev 'text')
            if ($text) { Add-LogLine $s ('Warnung: ' + $text) }
        }
        'findings' {
            $f = ConvertTo-FindingsState $Ev
            if ($null -eq $f) { return }
            if ($f.accepted) { $s.acceptedFindings = [int]$f.total; $s.findings = $null }
            else { $s.findings = $f }
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
    param($Share, [string]$Line, [bool]$FromStdout)
    if ($Line.Length -eq 0) { return }
    if ($FromStdout -and $Line.StartsWith('@@WSEVENT@@ ', [StringComparison]::Ordinal)) {
        $ev = $null
        try { $ev = $Line.Substring(12) | ConvertFrom-Json } catch { $ev = $null }
        if ($null -ne $ev -and $null -ne $ev.PSObject.Properties['type']) {
            try { Set-ShareEvent $Share $ev } catch { Add-LogLine $Share 'Ungültiges Ereignis vom Freigabeprozess ignoriert.' }
            return
        }
    }
    Add-LogLine $Share $Line
}

function Stop-ChildTree {
    param($Share)
    $p = $Share.proc
    if ($null -eq $p) { return }
    $Share.killSent = $true
    if ($script:Platform -eq 'windows') {
        try {
            $tk = Join-Path $env:SystemRoot 'System32\taskkill.exe'
            Start-Process -FilePath $tk -ArgumentList @('/PID', [string]$p.Id, '/T', '/F') -WindowStyle Hidden -Wait
        }
        catch { }
    }
    else {
        # Linux: the whole process tree (the launcher's children run in their own sessions but keep it as parent).
        try { $p.Kill($true) } catch { }
    }
    try { $p.Kill() } catch { }
}

function Request-ShareStop {
    # Cooperative stop through stop.requested in the share's own session folder; before the session event
    # there is no such folder yet, so the child tree is killed.
    param($Share)
    if ($null -eq $Share.proc) { return }
    $Share.stopRequested = $true
    $Share.phase = 'stopping'
    if ($null -eq $Share.stopSw) { $Share.stopSw = [Diagnostics.Stopwatch]::StartNew() }
    $done = $false
    $sp = $Share.sessionPath
    if (-not [string]::IsNullOrWhiteSpace($sp) -and [IO.Path]::IsPathRooted($sp)) {
        try {
            if (Test-Path -LiteralPath $sp -PathType Container) {
                [void](New-Item -ItemType File -Path (Join-Path $sp 'stop.requested') -Force)
                $done = $true
            }
        }
        catch { $done = $false }
    }
    if (-not $done) { Stop-ChildTree $Share }
}

function Clear-ShareClipboard {
    # Removes the copied link from the clipboard (only if it is still there).
    param($Share)
    $u = $Share.copiedUrl
    if ([string]::IsNullOrEmpty([string]$u)) { return }
    $Share.copiedUrl = $null
    try { [void](Clear-WsClipboardText -Expected ([string]$u)) } catch { }
}

function Complete-Share {
    param($Share)
    $s = $Share
    $proc = $s.proc
    $code = $null
    if ($s.endedGot -and $null -ne $s.exitCode) { $code = [int]$s.exitCode }
    else {
        try { $code = [int]$proc.ExitCode } catch { $code = -1 }
        $s.exitCode = $code
    }
    $lastLog = $null
    if ($s.log.Count -gt 0) { $lastLog = $s.log[$s.log.Count - 1] }
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
    $s.knownUrl = $null
    try { $proc.Dispose() } catch { }
    $s.proc = $null
    $s.tasks.out = $null; $s.tasks.err = $null
    $s.readers.out = $null; $s.readers.err = $null
    $s.exitSeen = $null
    $s.stopSw = $null
    $s.killSent = $false
    Clear-ShareClipboard $s
    # Findings stay confirmable only when the run failed because of them.
    if ($s.phase -ne 'error' -or $s.exitCode -ne 22) { $s.findings = $null }
    # The share is over: the drop folder it owned is not needed any more - unless the user may still
    # confirm the findings and run it again (then dismiss/quit deletes it).
    if ($null -ne $s.drop -and $null -eq $s.findings) {
        $d = $s.drop
        $s.drop = $null
        Remove-DropDirectory $d.Root
    }
}

function Update-ShareChild {
    # Drains the stdout/stderr of one share (never blocks) and finalizes the share after the process exit.
    param($Share)
    $s = $Share
    if ($null -eq $s.proc) { return }
    foreach ($which in @('out', 'err')) {
        $guard = 0
        while ($guard -lt 500) {
            $task = $s.tasks[$which]
            if ($null -eq $task -or -not $task.IsCompleted) { break }
            $guard++
            $line = $null
            if ($task.IsFaulted) { [void]$task.Exception }
            elseif (-not $task.IsCanceled) { $line = $task.Result }
            if ($null -eq $line) {
                $s.tasks[$which] = $null
                $s.eof[$which] = $true
                break
            }
            Receive-ChildLine $s ([string]$line) ($which -eq 'out')
            $s.tasks[$which] = $s.readers[$which].ReadLineAsync()
        }
    }
    if ($null -eq $s.proc) { return }
    $exited = $false
    try { $exited = $s.proc.HasExited } catch { $exited = $true }
    if ($exited) {
        if ($null -eq $s.exitSeen) { $s.exitSeen = [Diagnostics.Stopwatch]::StartNew() }
        # Grandchildren may keep the pipes open: give the streams a short grace period.
        if (($s.eof.out -and $s.eof.err) -or $s.exitSeen.ElapsedMilliseconds -gt 3000) {
            Complete-Share $s
        }
    }
    elseif ($s.phase -eq 'stopping' -and $null -ne $s.stopSw -and -not $s.killSent -and $s.stopSw.Elapsed.TotalSeconds -gt 150) {
        Add-LogLine $s 'Die Freigabe reagiert nicht auf die Stopp-Anforderung und wird beendet.'
        Stop-ChildTree $s
    }
}

function Update-AllChildren {
    # Drains every share, every time. Never throws: it also runs as the upload hook and in wait loops.
    foreach ($s in $script:Shares.ToArray()) {
        if ($null -eq $s.proc) { continue }
        try { Update-ShareChild $s }
        catch { Write-ConsoleLog ('Freigabe ' + $s.id + ': ' + $_.Exception.Message) }
    }
}

function Stop-SharesForShutdown {
    # Blocking variant used on backend exit: cooperative stop of all shares, wait up to 120 s, then kill.
    if (-not (Test-AnyChild)) { return }
    foreach ($s in $script:Shares.ToArray()) {
        if ($null -ne $s.proc -and -not $s.stopRequested) { try { Request-ShareStop $s } catch { } }
    }
    $sw = [Diagnostics.Stopwatch]::StartNew()
    while ((Test-AnyChild) -and $sw.Elapsed.TotalSeconds -lt 120) {
        Update-AllChildren
        if (-not (Test-AnyChild)) { break }
        Start-Sleep -Milliseconds 100
    }
    if (Test-AnyChild) {
        foreach ($s in $script:Shares.ToArray()) { if ($null -ne $s.proc) { Stop-ChildTree $s } }
        $sw2 = [Diagnostics.Stopwatch]::StartNew()
        while ((Test-AnyChild) -and $sw2.Elapsed.TotalSeconds -lt 10) {
            Update-AllChildren
            if (-not (Test-AnyChild)) { break }
            Start-Sleep -Milliseconds 100
        }
    }
}

function Remove-ShareFromList {
    param($Share)
    [void]$script:Shares.Remove($Share)
    Clear-ShareClipboard $Share
    if ($null -ne $Share.drop) {
        $d = $Share.drop
        $Share.drop = $null
        Remove-DropDirectory $d.Root
    }
}

function Invoke-ShareListCap {
    # At most $ShareListCap listed shares: the oldest ended/error share is dismissed automatically.
    while ($script:Shares.Count -ge $script:ShareListCap) {
        $victim = $null
        foreach ($s in $script:Shares) {
            if ($s.phase -in @('ended', 'error')) { $victim = $s; break }
        }
        if ($null -eq $victim) { break }
        Remove-ShareFromList $victim
    }
}

function Get-ShareObject {
    param($Share)
    $s = $Share
    $steps = @()
    foreach ($st in $s.steps) { $steps += , ([ordered]@{ n = $st.n; text = $st.text }) }
    return [ordered]@{
        id = $s.id
        name = $s.name
        createdUtc = $s.createdUtc
        phase = $s.phase
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
        log = [string[]]$s.log.ToArray()
        request = $s.request
        dropFiles = $s.dropFiles
        findings = $s.findings
        acceptedFindings = $s.acceptedFindings
    }
}

function Get-StateObject {
    $list = @()
    foreach ($s in $script:Shares) { $list += , (Get-ShareObject $s) }
    return [ordered]@{
        v = 2
        build = [string]$script:BuildId
        platform = $script:Platform
        capabilities = [ordered]@{
            folderPicker = [bool]$script:Caps.folderPicker
            clipboard = [bool]$script:Caps.clipboard
            openBrowser = [bool]$script:Caps.openBrowser
        }
        limits = [ordered]@{ maxDropBytes = [int64]$MaxDropBytes; maxDropFiles = [int]$MaxDropFiles; maxShares = [int]$MaxShares }
        running = [int](Get-RunningCount)
        draft = [ordered]@{ drop = (Get-DropState) }
        shares = $list
    }
}

# ---------------------------------------------------------------- names (section 8.2)

function ConvertTo-ShareName {
    # Trimmed 1..60 characters without control characters; $null when invalid.
    param($Value)
    if ($Value -isnot [string]) { return $null }
    foreach ($ch in $Value.ToCharArray()) { if ([char]::IsControl($ch)) { return $null } }
    $t = $Value.Trim()
    if ($t.Length -lt 1 -or $t.Length -gt 60) { return $null }
    return $t
}

function Get-DefaultShareName {
    # Dropped files: the single top-level entry, or "first +N"; a picked/typed folder: its leaf name.
    param([string]$FullPath, $Drop)
    $name = $null
    if ($null -ne $Drop) {
        $top = @($Drop.Top.ToArray())
        if ($top.Count -eq 1) { $name = [string]$top[0] }
        elseif ($top.Count -gt 1) {
            $suffix = ' +' + ($top.Count - 1)
            $first = [string]$top[0]
            if ($first.Length + $suffix.Length -gt 60) { $first = $first.Substring(0, 60 - $suffix.Length) }
            $name = $first + $suffix
        }
    }
    if ([string]::IsNullOrWhiteSpace($name)) {
        $trimmed = $FullPath.TrimEnd('\', '/')
        $name = [IO.Path]::GetFileName($trimmed)
        if ([string]::IsNullOrWhiteSpace($name)) { $name = $FullPath }
    }
    $clean = New-Object System.Text.StringBuilder
    foreach ($ch in $name.ToCharArray()) {
        if ([char]::IsControl($ch)) { [void]$clean.Append('_') } else { [void]$clean.Append($ch) }
    }
    $name = $clean.ToString().Trim()
    if ($name.Length -gt 60) { $name = $name.Substring(0, 60).Trim() }
    if ($name.Length -eq 0) { $name = 'Freigabe' }
    return $name
}

# ---------------------------------------------------------------- drop folder (GUI_CONTRACT sections 7 and 8)

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

function New-HexId {
    param([int]$Bytes)
    $b = New-Object byte[] $Bytes
    $rng = New-Object System.Security.Cryptography.RNGCryptoServiceProvider
    try { $rng.GetBytes($b) } finally { $rng.Dispose() }
    return (($b | ForEach-Object { $_.ToString('x2') }) -join '')
}

function New-ShareId {
    $id = New-HexId 4
    while ($null -ne (Get-ShareById $id)) { $id = New-HexId 4 }
    return $id
}

function Invoke-ApiStart {
    param($Req)
    if ($script:QuitRequested) {
        return (New-ApiResult 409 @{ error = 'WorkspaceShare wird gerade beendet.' })
    }
    if ((Get-RunningCount) -ge $MaxShares) {
        return (New-ApiResult 409 @{ error = ('Es laufen bereits {0} Freigaben (Maximum). Bitte zuerst eine Freigabe beenden.' -f $MaxShares) })
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
    # Only the finished draft drop may be shared from inside the drops folder (shares own their drops).
    $useDrop = $false
    if (Test-IsInsidePath $fullPath $DropsRoot) {
        $d = $script:CurrentDrop
        if ($null -ne $d -and $d.Finished -and -not $script:UploadBusy -and (Test-SamePath $fullPath $d.Leaf)) { $useDrop = $true }
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
    # Optional name chosen by the client; null/empty means "default name".
    $name = $null
    $nameValue = Get-EventProp $obj 'name'
    if ($null -ne $nameValue -and -not ($nameValue -is [string] -and $nameValue.Trim().Length -eq 0)) {
        $name = ConvertTo-ShareName $nameValue
        if ($null -eq $name) {
            return (New-ApiResult 400 @{ error = 'Der Name muss aus 1 bis 60 Zeichen ohne Steuerzeichen bestehen.' })
        }
    }

    if (-not (Test-Path -LiteralPath $ShareScript -PathType Leaf)) {
        return (New-ApiResult 500 @{ error = 'Share-Workspace.ps1 wurde nicht gefunden.' })
    }

    $drop = $null
    if ($useDrop) { $drop = $script:CurrentDrop }
    if ($null -eq $name) { $name = Get-DefaultShareName $fullPath $drop }

    $request = [ordered]@{
        path = $fullPath; minutes = [int]$minutes; compression = [string]$compression; includeGenerated = [bool]$include
    }
    $proc = Start-ShareProcess $request $null
    if ($null -eq $proc) { return (New-ApiResult 500 @{ error = 'Der Freigabeprozess konnte nicht gestartet werden.' }) }

    # The share now owns the drop; the draft form starts empty again.
    if ($useDrop) { $script:CurrentDrop = $null }
    else { $script:LastPath = $fullPath }
    Invoke-ShareListCap
    $sh = New-Share (New-ShareId) $name $request $drop
    Connect-ShareProcess $sh $proc
    $script:Shares.Add($sh)
    return (New-ApiResult 200 ([ordered]@{ ok = $true; shareId = $sh.id }))
}

function Start-ShareProcess {
    # Starts Share-Workspace.ps1 for a validated request; $AcceptDigest releases exactly those gitleaks findings.
    # Returns the process, or $null if it could not be started.
    param($Request, [string]$AcceptDigest)
    $argList = @('-NoLogo', '-NoProfile', '-NonInteractive', '-File', $ShareScript,
        '-Path', [string]$Request.path, '-Minutes', [string]$Request.minutes, '-Compression', [string]$Request.compression)
    if ($Request.includeGenerated) { $argList += '-IncludeGenerated' }
    if (-not [string]::IsNullOrEmpty($AcceptDigest)) { $argList += @('-AcceptSecretFindings', $AcceptDigest) }
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

    $proc = New-Object System.Diagnostics.Process
    $proc.StartInfo = $psi
    try {
        [void]$proc.Start()
        # Touch the handle so ExitCode stays readable after the process has exited.
        $null = $proc.Handle
    }
    catch {
        try { $proc.Dispose() } catch { }
        Write-ConsoleLog ('Start fehlgeschlagen: ' + $_.Exception.Message)
        return $null
    }
    return $proc
}

function Connect-ShareProcess {
    param($Share, $Proc)
    $Share.proc = $Proc
    $Share.readers.out = $Proc.StandardOutput
    $Share.readers.err = $Proc.StandardError
    $Share.tasks.out = $Proc.StandardOutput.ReadLineAsync()
    $Share.tasks.err = $Proc.StandardError.ReadLineAsync()
    $Share.eof.out = $false
    $Share.eof.err = $false
}

function Invoke-ApiShareOverride {
    # "Trotzdem freigeben" (contract 8.6): runs the same share again, releasing exactly the findings shown.
    param($Share, $Req)
    if ($script:QuitRequested) {
        return (New-ApiResult 409 @{ error = 'WorkspaceShare wird gerade beendet.' })
    }
    $f = $Share.findings
    if ($Share.phase -ne 'error' -or $null -eq $f) {
        return (New-ApiResult 409 @{ error = 'Für diese Freigabe gibt es keine Funde zu bestätigen.' })
    }
    $obj = $null
    try { $obj = $Req.Body | ConvertFrom-Json } catch { $obj = $null }
    if ($null -eq $obj -or $obj -isnot [pscustomobject]) {
        return (New-ApiResult 400 @{ error = 'Ungültige Anfrage (kein gültiges JSON-Objekt).' })
    }
    $digest = Get-EventProp $obj 'digest'
    if ($digest -isnot [string] -or $digest -cne [string]$f.digest) {
        return (New-ApiResult 409 @{ error = 'Die Funde haben sich geändert. Bitte die aktuelle Liste prüfen.' })
    }
    if ((Get-RunningCount) -ge $MaxShares) {
        return (New-ApiResult 409 @{ error = ('Es laufen bereits {0} Freigaben (Maximum). Bitte zuerst eine Freigabe beenden.' -f $MaxShares) })
    }
    $path = [string]$Share.request.path
    if ($null -ne $Share.dropFiles -and $null -eq $Share.drop) {
        return (New-ApiResult 409 @{ error = 'Die abgelegten Dateien sind nicht mehr vorhanden. Bitte neu ablegen.' })
    }
    if (-not (Test-Path -LiteralPath $path -PathType Container)) {
        return (New-ApiResult 400 @{ error = 'Der Ordner existiert nicht mehr.' })
    }
    $proc = Start-ShareProcess $Share.request ([string]$f.digest)
    if ($null -eq $proc) { return (New-ApiResult 500 @{ error = 'Der Freigabeprozess konnte nicht gestartet werden.' }) }

    $s = $Share
    $s.phase = 'starting'; $s.step = 0; $s.total = 8; $s.stepText = $null
    $s.steps.Clear()
    $s.url = $null; $s.expiresUtc = $null; $s.sizeBytes = $null; $s.sha256 = $null
    $s.remainingMinutes = $null; $s.health = $null
    $s.exitCode = $null; $s.reason = $null; $s.message = $null
    $s.findings = $null; $s.acceptedFindings = $null
    $s.sessionPath = $null; $s.stopRequested = $false; $s.endedGot = $false
    $s.log.Clear()
    Add-LogLine $s ('Freigabe trotz {0} Gitleaks-Fund(en) bestätigt; Snapshot und Prüfung laufen erneut.' -f [int]$f.total)
    Connect-ShareProcess $s $proc
    return (New-ApiResult 200 ([ordered]@{ ok = $true; shareId = $s.id }))
}

function Invoke-ApiShareStop {
    param($Share)
    if ($Share.phase -in @('ended', 'error')) {
        return (New-ApiResult 409 @{ error = 'Diese Freigabe ist bereits beendet.' })
    }
    if ($Share.phase -ne 'stopping' -and $null -ne $Share.proc) { Request-ShareStop $Share }
    return (New-ApiResult 200 @{ ok = $true })
}

function Invoke-ApiShareCopy {
    param($Share)
    $url = $Share.url
    if ([string]::IsNullOrEmpty([string]$url)) {
        return (New-ApiResult 409 @{ error = 'Es gibt keinen Link zum Kopieren.' })
    }
    $ok = $false
    try { $ok = [bool](Set-WsClipboardText -Text ([string]$url)) } catch { $ok = $false }
    if (-not $ok) {
        return (New-ApiResult 500 @{ error = 'Der Link konnte nicht in die Zwischenablage kopiert werden.' })
    }
    $Share.copiedUrl = [string]$url
    return (New-ApiResult 200 @{ ok = $true })
}

function Invoke-ApiShareRename {
    param($Share, $Req)
    $obj = $null
    try { $obj = $Req.Body | ConvertFrom-Json } catch { $obj = $null }
    if ($null -eq $obj -or $obj -isnot [pscustomobject]) {
        return (New-ApiResult 400 @{ error = 'Ungültige Anfrage (kein gültiges JSON-Objekt).' })
    }
    $name = ConvertTo-ShareName (Get-EventProp $obj 'name')
    if ($null -eq $name) {
        return (New-ApiResult 400 @{ error = 'Der Name muss aus 1 bis 60 Zeichen ohne Steuerzeichen bestehen.' })
    }
    $Share.name = $name
    return (New-ApiResult 200 ([ordered]@{ ok = $true; name = $name }))
}

function Invoke-ApiShareDismiss {
    param($Share)
    if ($Share.phase -notin @('ended', 'error')) {
        return (New-ApiResult 409 @{ error = 'Eine laufende Freigabe kann nicht geschlossen werden.' })
    }
    Remove-ShareFromList $Share
    return (New-ApiResult 200 @{ ok = $true })
}

# The folder picker runs in its own STA runspace so the loop keeps draining the shares (section 8.4).
# Test hook (-TestMode -TestPickerResult "<delayMs>:<path>"): wait and answer without opening a dialog.
$script:PickerScript = @'
param($Module, $Initial, $TestSpec)
$ErrorActionPreference = 'Stop'
if (-not [string]::IsNullOrEmpty($TestSpec)) {
    $i = $TestSpec.IndexOf(':')
    $delay = 0
    $answer = ''
    if ($i -ge 0) { [void][int]::TryParse($TestSpec.Substring(0, $i), [ref]$delay); $answer = $TestSpec.Substring($i + 1) }
    Start-Sleep -Milliseconds $delay
    return $answer
}
Import-Module $Module -Force
Show-WsFolderPicker -InitialPath $Initial
'@

function Invoke-ApiPickFolder {
    # Returns an API result, or $null when the answer is deferred (the client socket now belongs to the picker).
    param($Stream, $Client)
    if ($script:QuitRequested) {
        return (New-ApiResult 409 @{ error = 'WorkspaceShare wird gerade beendet.' })
    }
    if (-not $script:Caps.folderPicker) {
        return (New-ApiResult 501 @{ error = 'Die Ordnerauswahl wird auf diesem System nicht unterstützt.' })
    }
    if ($null -ne $script:Picker) {
        return (New-ApiResult 409 @{ error = 'Die Ordnerauswahl ist bereits geöffnet.' })
    }
    $rs = $null
    $ps = $null
    $async = $null
    try {
        $rs = [runspacefactory]::CreateRunspace()
        if ($script:Platform -eq 'windows') {
            $rs.ApartmentState = [System.Threading.ApartmentState]::STA
            $rs.ThreadOptions = [System.Management.Automation.Runspaces.PSThreadOptions]::ReuseThread
        }
        $rs.Open()
        $ps = [powershell]::Create()
        $ps.Runspace = $rs
        $spec = ''
        if ($TestMode -and -not [string]::IsNullOrEmpty($TestPickerResult)) { $spec = $TestPickerResult }
        [void]$ps.AddScript($script:PickerScript).AddArgument((Join-Path $ScriptsDir 'WorkspaceShare.Platform.psm1')).AddArgument([string]$script:LastPath).AddArgument($spec)
        $async = $ps.BeginInvoke()
    }
    catch {
        Write-ConsoleLog ('Ordnerauswahl konnte nicht gestartet werden: ' + $_.Exception.Message)
        if ($null -ne $ps) { try { $ps.Dispose() } catch { } }
        if ($null -ne $rs) { try { $rs.Dispose() } catch { } }
        return (New-ApiResult 500 @{ error = 'Die Ordnerauswahl konnte nicht geöffnet werden.' })
    }
    $script:Picker = @{ Rs = $rs; Ps = $ps; Async = $async; Stream = $Stream; Client = $Client }
    $script:ConnectionDeferred = $true
    return $null
}

function Update-Picker {
    # Answers the waiting pick-folder request once the dialog runspace has finished.
    $pk = $script:Picker
    if ($null -eq $pk) { return }
    if (-not $pk.Async.IsCompleted) { return }
    $script:Picker = $null
    $picked = $null
    try {
        $res = $pk.Ps.EndInvoke($pk.Async)
        if ($null -ne $res -and $res.Count -gt 0) { $picked = [string]$res[$res.Count - 1] }
    }
    catch { $picked = $null }
    try { $pk.Ps.Dispose() } catch { }
    try { $pk.Rs.Close() } catch { }
    try { $pk.Rs.Dispose() } catch { }
    $body = $null
    if ([string]::IsNullOrWhiteSpace($picked)) { $body = @{ cancelled = $true } }
    else {
        $script:LastPath = $picked
        $body = @{ path = $picked }
    }
    try { Write-WsJsonResponse -Stream $pk.Stream -Status 200 -Object $body } catch { }
    try { $pk.Stream.Dispose() } catch { }
    try { $pk.Client.Close() } catch { }
}

function Invoke-ApiQuit {
    $script:QuitRequested = $true
    return (New-ApiResult 200 @{ ok = $true })
}

function Test-DropPhaseBusy {
    # Drops work while shares run; only a backend that is shutting down, or an upload in progress, blocks them.
    return ($script:QuitRequested -or $script:UploadBusy)
}

function New-DropId {
    return (New-HexId 16)
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
        return (New-ApiResult 409 @{ error = 'Gerade läuft ein Upload oder WorkspaceShare wird beendet.' })
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
        Files = 0; Bytes = [int64]0; Finished = $false
        Paths = (New-Object 'System.Collections.Generic.HashSet[string]' -ArgumentList ([StringComparer]::OrdinalIgnoreCase))
        # Top-level entries in upload order (first path segment), for the default share name.
        Top = (New-Object 'System.Collections.Generic.List[string]')
        TopSet = (New-Object 'System.Collections.Generic.HashSet[string]' -ArgumentList ([StringComparer]::OrdinalIgnoreCase))
    }
    return (New-ApiResult 200 @{ dropId = $id })
}

function Invoke-ApiDropFinish {
    param($Req)
    if (Test-DropPhaseBusy) {
        return (New-ApiResult 409 @{ error = 'Gerade läuft ein Upload oder WorkspaceShare wird beendet.' })
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
        return (New-ApiResult 409 @{ error = 'Gerade läuft ein Upload oder WorkspaceShare wird beendet.' })
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
            Update-AllChildren
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
        Send-UploadReject $Stream $Client $Req 409 'Gerade läuft ein Upload oder WorkspaceShare wird beendet.'
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
    $script:UploadBusy = $true
    try {
        try { $Client.ReceiveTimeout = 30000 } catch { }
        # OnChunk keeps every share's stdout/stderr pipe drained while the body streams in (section 8.4).
        Copy-WsHttpBody -Stream $Stream -Request $Req -Destination $fs -MaxBytes ([int64]$MaxDropBytes - [int64]$d.Bytes) -IdleTimeoutMs 30000 -OnChunk $script:DrainChildren
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
        $script:UploadBusy = $false
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
    $topName = $segs[0]
    if ($d.TopSet.Add($topName)) { $d.Top.Add($topName) }
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

function Invoke-ShareRoute {
    # /api/shares/<id>/<action>: unknown id -> 404, GET -> 405.
    param($Req, $Stream, [string]$IdText, [string]$Action)
    if ($Action -cnotin @('stop', 'copy', 'rename', 'dismiss', 'override')) { Send-ErrorJson $Stream 404; return }
    if ($Req.Method -cne 'POST') { Send-ErrorJson $Stream 405; return }
    $sh = $null
    if ($IdText -cmatch '^[0-9a-f]{8}$') { $sh = Get-ShareById $IdText }
    if ($null -eq $sh) { Send-ErrorJson $Stream 404; return }
    $result = $null
    switch -CaseSensitive ($Action) {
        'stop' { $result = Invoke-ApiShareStop $sh }
        'copy' { $result = Invoke-ApiShareCopy $sh }
        'rename' { $result = Invoke-ApiShareRename $sh $Req }
        'dismiss' { $result = Invoke-ApiShareDismiss $sh }
        'override' { $result = Invoke-ApiShareOverride $sh $Req }
    }
    Write-WsJsonResponse -Stream $Stream -Status $result.Status -Object $result.Body
}

function Invoke-Route {
    param($Req, $Stream, $Client)
    $isApi = $Req.Path.StartsWith('/api/', [StringComparison]::Ordinal)
    if ($isApi) {
        $chk = Test-WsRequestAllowed -Request $Req -Port $script:BoundPort -Token $script:Token -RequireToken
    }
    else {
        $chk = Test-WsRequestAllowed -Request $Req -Port $script:BoundPort -Token $script:Token
    }
    if (-not $chk.Allowed) { Send-ErrorJson $Stream ([int]$chk.Status); return }

    if (-not $isApi) {
        # Served from the cache filled at backend start (ordinal path match; no file access per request).
        if ($Req.Method -ceq 'GET') {
            if ($script:Static.ContainsKey($Req.Path)) {
                $file = $script:Static[$Req.Path]
                Write-WsHttpResponse -Stream $Stream -Status 200 -ContentType $file.ContentType -Body $file.Bytes
                return
            }
            Send-ErrorJson $Stream 404
            return
        }
        # Known static path with a wrong method -> 405, anything else -> 404.
        if ($script:Static.ContainsKey($Req.Path)) { Send-ErrorJson $Stream 405 } else { Send-ErrorJson $Stream 404 }
        return
    }

    if ($Req.Path -cmatch '^/api/shares/([^/]+)/([^/]+)$') {
        Invoke-ShareRoute $Req $Stream $Matches[1] $Matches[2]
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
            $result = Invoke-ApiPickFolder $Stream $Client
            # Deferred: the picker runspace answers on this socket later (Update-Picker).
            if ($null -eq $result) { return }
        }
        '/api/start' {
            if ($Req.Method -cne 'POST') { Send-ErrorJson $Stream 405; return }
            $result = Invoke-ApiStart $Req
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
    $script:ConnectionDeferred = $false
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
        Invoke-Route $req $stream $Client
    }
    catch {
        Write-ConsoleLog ('Anfrage fehlgeschlagen: ' + $_.Exception.Message)
        if ($null -ne $stream -and -not $script:ConnectionDeferred) {
            try { Send-ErrorJson $stream 500 } catch { }
        }
    }
    finally {
        # A deferred connection (folder picker) stays open; Update-Picker answers and closes it.
        if (-not $script:ConnectionDeferred) {
            if ($null -ne $stream) { try { $stream.Dispose() } catch { } }
            try { $Client.Close() } catch { }
        }
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
if ($script:Platform -eq 'windows') { $mutex = New-Object System.Threading.Mutex($false, $mutexName) }
else { $mutex = New-WsInstanceLock -Name $mutexName -Directory (Join-Path $DataRoot 'locks') }   # Linux: lock file
$script:BuildId = Get-BuildIdentity
$script:Static = New-Object 'System.Collections.Generic.Dictionary[string,object]'
$script:DrainChildren = { Update-AllChildren }
$ownsMutex = Enter-InstanceMutex $mutex 0
if (-not $ownsMutex) {
    # A live instance of the same build -> only open it; an older idle one is replaced (Resolve-ExistingInstance).
    $resolved = Resolve-ExistingInstance (Read-InstanceFile $InstanceFile)
    if ($resolved -eq 'Handled') { $mutex.Dispose(); exit 0 }
    # Stale or still starting instance: wait up to 5 s.
    $waitSw = [Diagnostics.Stopwatch]::StartNew()
    while (-not $ownsMutex -and $waitSw.Elapsed.TotalSeconds -lt 5) {
        $ownsMutex = Enter-InstanceMutex $mutex 250
        if (-not $ownsMutex -and (Resolve-ExistingInstance (Read-InstanceFile $InstanceFile)) -eq 'Handled') { $mutex.Dispose(); exit 0 }
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
    # Identity and static files are fixed now (the mutex is ours): a later update on disk changes neither.
    $script:BuildId = Get-BuildIdentity
    Initialize-StaticCache
    # Single instance holds the mutex: every drop folder found now is left over from a crashed run.
    if ($StaleDropCleanup) { try { Clear-StaleDrops } catch { Write-ConsoleLog ('Alte Drop-Ordner: ' + $_.Exception.Message) } }
    $listener = New-Object System.Net.Sockets.TcpListener -ArgumentList ([System.Net.IPAddress]::Loopback), $Port
    try { $listener.ExclusiveAddressUse = $true } catch { }
    $listener.Start()
    $script:BoundPort = ([System.Net.IPEndPoint]$listener.LocalEndpoint).Port

    $startTicks = Get-WsProcessStartTicks -ProcessId $PID
    $instanceJson = ConvertTo-WsJson -Object ([ordered]@{ pid = $PID; startTicks = $startTicks; port = $script:BoundPort; token = $script:Token; build = $script:BuildId })
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
            Update-AllChildren
            Update-Picker
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
                if (-not (Test-AnyChild)) { $loopOn = $false }
                elseif (-not $script:QuitStopSent) {
                    # Quit stops every running share (cooperatively; killed when there is no session yet).
                    $script:QuitStopSent = $true
                    $script:QuitSw = [Diagnostics.Stopwatch]::StartNew()
                    foreach ($qs in $script:Shares.ToArray()) { if ($null -ne $qs.proc) { Request-ShareStop $qs } }
                }
                elseif ($null -eq $script:QuitKillSw -and $script:QuitSw.Elapsed.TotalSeconds -gt 120) {
                    foreach ($qs in $script:Shares.ToArray()) { if ($null -ne $qs.proc) { Stop-ChildTree $qs } }
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
    try { Stop-SharesForShutdown } catch { }
    try {
        Remove-CurrentDrop
        foreach ($fs1 in $script:Shares.ToArray()) {
            if ($null -ne $fs1.drop) { $dd = $fs1.drop; $fs1.drop = $null; Remove-DropDirectory $dd.Root }
            Clear-ShareClipboard $fs1
        }
        Clear-PendingDeletes
    }
    catch { }
    if ($null -ne $script:Picker) {
        try { $script:Picker.Stream.Dispose() } catch { }
        try { $script:Picker.Client.Close() } catch { }
    }
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
