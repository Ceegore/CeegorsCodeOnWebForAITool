#requires -Version 5.1
# End-to-end tests of Start-WorkspaceShareGui.ps1 with tests\Fake-WorkspaceShare.ps1 (no network, no tunnel).
# Exit: 0 = all passed, 1 = failures, 42 = environment blocked (CodeIntegrity events 3033/3077).
[CmdletBinding()]
param([string]$ToolRoot)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if ([string]::IsNullOrWhiteSpace($ToolRoot)) { $ToolRoot = Split-Path $PSScriptRoot -Parent }

$script:Pass = 0
$script:Fail = 0
function Assert-True {
    param($Condition, [string]$Name)
    if ([bool]$Condition) { $script:Pass++; Write-Host "[PASS] $Name" }
    else { $script:Fail++; Write-Host "[FAIL] $Name" }
}

$testStart = Get-Date
$psExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$curl = Join-Path $env:SystemRoot 'System32\curl.exe'
$startScript = Join-Path $ToolRoot 'Start-WorkspaceShareGui.ps1'
$fakeScript = Join-Path $PSScriptRoot 'Fake-WorkspaceShare.ps1'
$guiIndex = Join-Path (Join-Path $ToolRoot 'gui') 'index.html'
$tmp = Join-Path ([IO.Path]::GetTempPath()) ('wsgui-test-' + [Guid]::NewGuid().ToString('N'))
[void](New-Item -ItemType Directory -Path $tmp -Force)
$script:Backends = New-Object System.Collections.Generic.List[object]
$utf8 = New-Object System.Text.UTF8Encoding ($false)

# ---------------------------------------------------------------- helpers

function Invoke-Api {
    param(
        [string]$Method = 'GET', [string]$Path, $B, [string]$Token, [string]$BodyText,
        [string[]]$ExtraHeaders = @(), [switch]$PathAsIs
    )
    $id = [Guid]::NewGuid().ToString('N')
    $hf = Join-Path $tmp "h-$id.txt"
    $bf = Join-Path $tmp "b-$id.txt"
    $cargs = @('-s', '--noproxy', '*', '--max-time', '10', '-D', $hf, '-o', $bf, '-w', '%{http_code}', '-X', $Method)
    if ($PathAsIs) { $cargs += '--path-as-is' }
    if ($Token) { $cargs += @('-H', "X-WS-Token: $Token") }
    foreach ($h in $ExtraHeaders) { $cargs += @('-H', $h) }
    if ($PSBoundParameters.ContainsKey('BodyText')) {
        $inf = Join-Path $tmp "i-$id.txt"
        [IO.File]::WriteAllText($inf, $BodyText, $utf8)
        $cargs += @('-H', 'Content-Type: application/json', '--data-binary', "@$inf")
    }
    $cargs += ('http://127.0.0.1:{0}{1}' -f $B.Port, $Path)
    $codeText = (& $curl @cargs) -join ''
    $status = 0
    [void][int]::TryParse($codeText.Trim(), [ref]$status)
    $headers = New-Object Collections.Hashtable ([StringComparer]::OrdinalIgnoreCase)
    if (Test-Path -LiteralPath $hf) {
        foreach ($line in [IO.File]::ReadAllLines($hf)) {
            $i = $line.IndexOf(':')
            if ($i -gt 0) { $headers[$line.Substring(0, $i).Trim()] = $line.Substring($i + 1).Trim() }
        }
    }
    $body = ''
    if (Test-Path -LiteralPath $bf) { $body = [IO.File]::ReadAllText($bf, $utf8) }
    $json = $null
    if ($body.StartsWith('{')) { try { $json = $body | ConvertFrom-Json } catch { $json = $null } }
    return [pscustomobject]@{ Status = $status; Headers = $headers; Body = $body; Json = $json }
}

function Get-State {
    param($B)
    $r = Invoke-Api -Method GET -Path '/api/state' -B $B -Token $B.Token
    if ($r.Status -eq 200) { return $r.Json }
    return $null
}

function Invoke-Post {
    param($B, [string]$Path, $Object)
    $text = '{}'
    if ($null -ne $Object) { $text = ConvertTo-Json -InputObject $Object -Compress }
    return (Invoke-Api -Method POST -Path $Path -B $B -Token $B.Token -BodyText $text)
}

function Wait-Until {
    param([scriptblock]$Condition, [int]$TimeoutSec = 20, [int]$IntervalMs = 200)
    $sw = [Diagnostics.Stopwatch]::StartNew()
    while ($sw.Elapsed.TotalSeconds -lt $TimeoutSec) {
        $ok = $false
        try { $ok = [bool](& $Condition) } catch { $ok = $false }
        if ($ok) { return $true }
        Start-Sleep -Milliseconds $IntervalMs
    }
    return $false
}

function Wait-ForState {
    param($B, [scriptblock]$Test, [int]$TimeoutSec = 20)
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $last = $null
    while ($sw.Elapsed.TotalSeconds -lt $TimeoutSec) {
        $s = Get-State $B
        if ($null -ne $s) {
            $last = $s
            if (& $Test $s) { return $s }
        }
        Start-Sleep -Milliseconds 250
    }
    if ($null -ne $last) { Write-Host ("       last phase: {0}, step {1}, exit {2}" -f $last.phase, $last.step, $last.exitCode) }
    return $null
}

function Test-PidAlive {
    param($ProcessId)
    if ($null -eq $ProcessId) { return $false }
    return ($null -ne (Get-Process -Id ([int]$ProcessId) -ErrorAction SilentlyContinue))
}

function Get-FakePid {
    param($B)
    if (-not (Test-Path -LiteralPath $B.PidFile)) { return $null }
    $t = ([IO.File]::ReadAllText($B.PidFile)).Trim()
    $n = 0
    if ([int]::TryParse($t, [ref]$n)) { return $n }
    return $null
}

function Start-TestBackend {
    # Every test backend gets its own -DataRootOverride below $tmp, so tests never touch the real data folder.
    param([string]$Scenario, [string]$Name, [string]$InstanceFile, [string]$DataRoot, [string]$ExtraArgs = '')
    if (-not $InstanceFile) { $InstanceFile = Join-Path $tmp "gui-$Name.json" }
    if (-not $DataRoot) { $DataRoot = Join-Path $tmp "data-$Name" }
    $pidFile = Join-Path $tmp "fake-$Name.pid"
    $outFile = Join-Path $tmp "backend-$Name.out"
    $errFile = Join-Path $tmp "backend-$Name.err"
    $env:WS_FAKE_SCENARIO = $Scenario
    $env:WS_FAKE_PIDFILE = $pidFile
    $argText = '-NoLogo -NoProfile -STA -File "{0}" -TestMode -NoBrowser -InstanceFile "{1}" -TestShareScript "{2}" -DataRootOverride "{3}" {4}' -f $startScript, $InstanceFile, $fakeScript, $DataRoot, $ExtraArgs
    $p = Start-Process -FilePath $psExe -ArgumentList $argText -PassThru -WindowStyle Hidden -RedirectStandardOutput $outFile -RedirectStandardError $errFile
    $null = $p.Handle
    $b = [pscustomobject]@{
        Name = $Name; Proc = $p; Instance = $InstanceFile; PidFile = $pidFile; Out = $outFile; Err = $errFile
        DataRoot = $DataRoot; Port = 0; Token = ''
    }
    $script:Backends.Add($b)
    $ok = Wait-Until -TimeoutSec 20 -Condition {
        if ($p.HasExited) { return $true }
        if (-not (Test-Path -LiteralPath $InstanceFile)) { return $false }
        $o = ([IO.File]::ReadAllText($InstanceFile)) | ConvertFrom-Json
        return ($null -ne $o.port -and $o.token)
    }
    if ($ok -and -not $p.HasExited) {
        $o = ([IO.File]::ReadAllText($InstanceFile)) | ConvertFrom-Json
        $b.Port = [int]$o.port
        $b.Token = [string]$o.token
    }
    else {
        Write-Host "       backend '$Name' did not come up. stderr:"
        if (Test-Path -LiteralPath $errFile) { Get-Content -LiteralPath $errFile -TotalCount 15 | ForEach-Object { Write-Host "       $_" } }
    }
    return $b
}

function Stop-TestBackendHard {
    param($B)
    if ($null -ne $B.Proc) { try { if (-not $B.Proc.HasExited) { Stop-Process -Id $B.Proc.Id -Force -ErrorAction SilentlyContinue } } catch { } }
    $fakePid = Get-FakePid $B
    if ($fakePid -and (Test-PidAlive $fakePid)) { Stop-Process -Id $fakePid -Force -ErrorAction SilentlyContinue }
    $sessionFile = $B.PidFile + '.session'
    if (Test-Path -LiteralPath $sessionFile) {
        $sd = ([IO.File]::ReadAllText($sessionFile)).Trim()
        if ($sd -and (Test-Path -LiteralPath $sd)) { Remove-Item -LiteralPath $sd -Recurse -Force -ErrorAction SilentlyContinue }
    }
}

function Test-GuiQuit {
    # Quit via API; true when the backend exits within 15 s and removes its instance file.
    param($B, [string]$Label)
    $r = Invoke-Post $B '/api/quit' $null
    Assert-True ($r.Status -eq 200 -and $r.Json.ok -eq $true) "$Label /api/quit -> 200 {ok:true}"
    $exited = Wait-Until -TimeoutSec 15 -Condition { $B.Proc.HasExited }
    Assert-True $exited "$Label backend exits within 15 s after quit"
    Assert-True (-not (Test-Path -LiteralPath $B.Instance)) "$Label instance file deleted on exit"
    if ($exited) { Assert-True ($B.Proc.ExitCode -eq 0) "$Label backend exit code 0" }
}

function Invoke-Upload {
    # POST /api/drop/file with curl (--data-binary @file, raw octet-stream).
    param($B, [string]$DropId, [string]$Rel, [string]$File, [switch]$NoToken, [string[]]$ExtraHeaders = @())
    $id = [Guid]::NewGuid().ToString('N')
    $bf = Join-Path $tmp "ub-$id.txt"
    $url = 'http://127.0.0.1:{0}/api/drop/file?drop={1}&path={2}' -f $B.Port, $DropId, [Uri]::EscapeDataString($Rel)
    $cargs = @('-s', '--noproxy', '*', '--max-time', '60', '-o', $bf, '-w', '%{http_code}', '-X', 'POST',
        '-H', 'Content-Type: application/octet-stream', '--data-binary', "@$File")
    if (-not $NoToken) { $cargs += @('-H', "X-WS-Token: $($B.Token)") }
    foreach ($h in $ExtraHeaders) { $cargs += @('-H', $h) }
    $cargs += $url
    $codeText = (& $curl @cargs) -join ''
    $status = 0
    [void][int]::TryParse($codeText.Trim(), [ref]$status)
    $body = ''
    if (Test-Path -LiteralPath $bf) { $body = [IO.File]::ReadAllText($bf, $utf8) }
    $json = $null
    if ($body.StartsWith('{')) { try { $json = $body | ConvertFrom-Json } catch { $json = $null } }
    return [pscustomobject]@{ Status = $status; Body = $body; Json = $json }
}

function Send-RawHttp {
    # Sends the given text on a fresh TCP connection and returns the full response text.
    param($B, [string]$Text)
    $c = New-Object System.Net.Sockets.TcpClient
    try {
        $c.Connect('127.0.0.1', $B.Port)
        $s = $c.GetStream()
        $s.ReadTimeout = 10000
        $bytes = [Text.Encoding]::ASCII.GetBytes($Text)
        $s.Write($bytes, 0, $bytes.Length)
        $ms = New-Object System.IO.MemoryStream
        $buf = New-Object byte[] 4096
        try { while (($n = $s.Read($buf, 0, $buf.Length)) -gt 0) { $ms.Write($buf, 0, $n) } } catch { }
        return $utf8.GetString($ms.ToArray())
    }
    finally { $c.Close() }
}

function New-RandomFile {
    param([string]$Path, [int]$Count, [int]$Seed)
    $b = New-Object byte[] $Count
    (New-Object System.Random $Seed).NextBytes($b)
    [IO.File]::WriteAllBytes($Path, $b)
}

function Get-FileSha {
    param([string]$Path)
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash
}

function Get-FileCount {
    param([string]$Dir)
    if (-not (Test-Path -LiteralPath $Dir)) { return 0 }
    return @(Get-ChildItem -LiteralPath $Dir -Recurse -File -Force -ErrorAction SilentlyContinue).Count
}

function New-StartBody {
    param([string]$Path, $Minutes = 5, $Compression = 'Fast', $Include = $false)
    return [ordered]@{ path = $Path; minutes = $Minutes; compression = $Compression; includeGenerated = $Include }
}

# ---------------------------------------------------------------- run

$exitCode = 0
try {
    $shareDir = Join-Path $tmp 'ws share ä'
    [void](New-Item -ItemType Directory -Path $shareDir -Force)
    [IO.File]::WriteAllText((Join-Path $shareDir 'a.txt'), 'x', $utf8)

    # ---- CLI contract
    $p = Start-Process -FilePath $psExe -ArgumentList ('-NoLogo -NoProfile -File "{0}" -TestShareScript "{1}" -NoBrowser' -f $startScript, $fakeScript) -PassThru -WindowStyle Hidden -Wait
    Assert-True ($p.ExitCode -eq 10) '-TestShareScript without -TestMode exits with 10'

    # ---- shortcut installer (never touches the real desktop / start menu)
    $lnkDir = Join-Path $tmp 'lnk'
    & $psExe -NoLogo -NoProfile -File (Join-Path $ToolRoot 'Install-GuiShortcut.ps1') -TargetDirectory $lnkDir | Out-Null
    $lnkCode = $LASTEXITCODE
    $lnk = Join-Path $lnkDir 'WorkspaceShare.lnk'
    Assert-True ($lnkCode -eq 0 -and (Test-Path -LiteralPath $lnk)) 'Install-GuiShortcut -TargetDirectory creates WorkspaceShare.lnk'
    if (Test-Path -LiteralPath $lnk) {
        $wsh = New-Object -ComObject WScript.Shell
        $sc = $wsh.CreateShortcut($lnk)
        Assert-True ($sc.TargetPath -ieq $psExe) 'shortcut target is the Windows PowerShell host'
        Assert-True ($sc.Arguments -like '*-STA*-WindowStyle Hidden -File "*Start-WorkspaceShareGui.ps1"') 'shortcut arguments start the GUI script hidden'
        Assert-True ($sc.WorkingDirectory -ieq $ToolRoot) 'shortcut working directory is the repo'
        [void][Runtime.InteropServices.Marshal]::ReleaseComObject($wsh)
    }
    & $psExe -NoLogo -NoProfile -File (Join-Path $ToolRoot 'Install-GuiShortcut.ps1') -Remove -TargetDirectory $lnkDir | Out-Null
    Assert-True (-not (Test-Path -LiteralPath $lnk)) 'Install-GuiShortcut -Remove deletes the shortcut'

    # ================= backend A: success scenario
    $A = Start-TestBackend -Scenario 'success' -Name 'A'
    Assert-True ($A.Port -gt 0 -and $A.Token.Length -ge 40) 'backend A starts; instance file has port and token'
    if ($A.Port -le 0) { throw 'Backend A did not start.' }
    $inst = [IO.File]::ReadAllText($A.Instance) | ConvertFrom-Json
    Assert-True ([int]$inst.pid -eq $A.Proc.Id -and [long]$inst.startTicks -gt 0) 'instance file holds pid and startTicks'
    Assert-True ($A.Token -match '^[A-Za-z0-9_-]+$') 'token is base64url'

    # static + security headers
    $r = Invoke-Api -Path '/' -B $A
    if (Test-Path -LiteralPath $guiIndex) {
        Assert-True ($r.Status -eq 200) 'GET / -> 200 without token'
    }
    else {
        Write-Host '[NOTE] gui\index.html does not exist yet; static 200 check skipped (404 accepted)'
        Assert-True ($r.Status -eq 404) 'GET / -> 404 while gui\index.html is missing'
    }
    Assert-True ($r.Headers['Content-Security-Policy'] -like "default-src 'self'*" -and $r.Headers['X-Frame-Options'] -eq 'DENY') 'GET / carries CSP and X-Frame-Options'
    Assert-True ($r.Headers['Cache-Control'] -eq 'no-store' -and $r.Headers['X-Content-Type-Options'] -eq 'nosniff') 'GET / carries no-store and nosniff'
    $r = Invoke-Api -Path '/nope.txt' -B $A
    Assert-True ($r.Status -eq 404) 'unknown static path -> 404'
    $r = Invoke-Api -Path '/a/../index.html' -B $A -PathAsIs
    Assert-True ($r.Status -eq 400) 'path traversal in request target -> 400'
    $r = Invoke-Api -Path '/' -B $A -ExtraHeaders @("Host: localhost:$($A.Port)")
    Assert-True ($r.Status -eq 403) 'wrong Host header on static file -> 403'
    $r = Invoke-Api -Path '/api/state' -B $A -Token $A.Token -ExtraHeaders @("Host: localhost:$($A.Port)")
    Assert-True ($r.Status -eq 403) 'wrong Host header on API -> 403'
    $r = Invoke-Api -Path '/api/state' -B $A -Token $A.Token -ExtraHeaders @('Origin: http://evil.example')
    Assert-True ($r.Status -eq 403) 'foreign Origin on API -> 403'

    # auth + routing
    $r = Invoke-Api -Path '/api/state' -B $A
    Assert-True ($r.Status -eq 401) '/api/state without token -> 401'
    $r = Invoke-Api -Path '/api/state' -B $A -Token ($A.Token + 'x')
    Assert-True ($r.Status -eq 401) '/api/state with wrong token -> 401'
    $r = Invoke-Api -Method POST -Path '/api/stop' -B $A -BodyText '{}'
    Assert-True ($r.Status -eq 401) 'POST /api/stop without token -> 401'
    $r = Invoke-Api -Method OPTIONS -Path '/api/state' -B $A -Token $A.Token
    Assert-True ($r.Status -eq 405) 'OPTIONS /api/state -> 405'
    $r = Invoke-Api -Method GET -Path '/api/start' -B $A -Token $A.Token
    Assert-True ($r.Status -eq 405) 'GET /api/start -> 405'
    $r = Invoke-Api -Method POST -Path '/api/state' -B $A -Token $A.Token -BodyText '{}'
    Assert-True ($r.Status -eq 405) 'POST /api/state -> 405'
    $r = Invoke-Api -Method POST -Path '/api/nonexistent' -B $A -Token $A.Token -BodyText '{}'
    Assert-True ($r.Status -eq 404) 'unknown /api path with token -> 404'

    # idle state
    $r = Invoke-Api -Path '/api/state' -B $A -Token $A.Token
    $s = $r.Json
    Assert-True ($r.Status -eq 200 -and $s.phase -eq 'idle' -and $s.v -eq 1 -and $s.platform -eq 'windows') '/api/state with token -> 200, phase idle'
    Assert-True ($null -ne $s.capabilities -and $null -ne $s.capabilities.folderPicker -and $null -ne $s.capabilities.clipboard -and $null -ne $s.capabilities.openBrowser) 'state has capabilities'
    Assert-True ($s.total -eq 8 -and $s.step -eq 0 -and @($s.steps).Count -eq 0 -and @($s.log).Count -eq 0 -and $null -eq $s.url -and $null -eq $s.request) 'idle state: no steps, log, url or request'
    Assert-True ($null -eq $s.drop -and $s.limits.maxDropBytes -eq 4GB -and $s.limits.maxDropFiles -eq 10000) 'idle state: drop is null, limits carry the defaults (4 GiB, 10000 files)'
    $r = Invoke-Post $A '/api/stop' $null
    Assert-True ($r.Status -eq 409) '/api/stop while idle -> 409'
    $r = Invoke-Post $A '/api/copy' $null
    Assert-True ($r.Status -eq 409) '/api/copy without link -> 409'

    # invalid start input
    $bad = @(
        @{ n = 'minutes 0'; b = (New-StartBody $shareDir 0) },
        @{ n = 'minutes 1441'; b = (New-StartBody $shareDir 1441) },
        @{ n = 'minutes "x"'; b = (New-StartBody $shareDir 'x') },
        @{ n = 'minutes 1.5'; b = (New-StartBody $shareDir 1.5) },
        @{ n = 'nonexistent path'; b = (New-StartBody (Join-Path $tmp 'gibt-es-nicht') 5) },
        @{ n = 'path is a file'; b = (New-StartBody (Join-Path $shareDir 'a.txt') 5) },
        @{ n = 'compression Zip'; b = (New-StartBody $shareDir 5 'Zip') },
        @{ n = 'includeGenerated "yes"'; b = (New-StartBody $shareDir 5 'Fast' 'yes') }
    )
    foreach ($case in $bad) {
        $r = Invoke-Post $A '/api/start' $case.b
        Assert-True ($r.Status -eq 400 -and $null -ne $r.Json -and [string]$r.Json.error) "/api/start with $($case.n) -> 400 with error text"
    }
    $r = Invoke-Api -Method POST -Path '/api/start' -B $A -Token $A.Token -BodyText 'kein json'
    Assert-True ($r.Status -eq 400) '/api/start with invalid JSON -> 400'
    Assert-True ((Get-State $A).phase -eq 'idle') 'rejected starts leave the phase idle'

    # valid start
    $r = Invoke-Post $A '/api/start' (New-StartBody $shareDir 5 'Fast' $false)
    Assert-True ($r.Status -eq 200 -and $r.Json.ok -eq $true) '/api/start with valid input -> 200'
    $r2 = Invoke-Post $A '/api/start' (New-StartBody $shareDir 5)
    Assert-True ($r2.Status -eq 409) 'second /api/start while running -> 409'
    $s = Wait-ForState $A { param($x) $x.phase -eq 'active' }
    Assert-True ($null -ne $s) 'phase becomes active within 20 s'
    if ($null -ne $s) {
        Assert-True ($s.url -match '^https://fake-test\.trycloudflare\.com/d/a{43}/$') 'active state carries the link'
        Assert-True (@($s.steps).Count -eq 8 -and $s.step -eq 8 -and $s.total -eq 8) 'state lists all 8 steps'
        Assert-True ((@($s.steps) | Where-Object { $_.n -eq 3 }).text -eq 'Snapshot wird erstellt ...') 'step text with umlauts is decoded correctly'
        Assert-True ($s.sizeBytes -eq 1234 -and $s.sha256 -eq ('A' * 64) -and $s.expiresUtc) 'ready fields: sizeBytes, sha256, expiresUtc'
        Assert-True ($s.request.minutes -eq 5 -and $s.request.path -eq $shareDir -and $s.request.compression -eq 'Fast' -and $s.request.includeGenerated -eq $false) 'state echoes the request'
        # The plain lines follow the ready event closely; wait until the last one is drained.
        $s2 = Wait-ForState $A { param($x) @($x.log) -like 'Link-Test:*' } 8
        if ($null -ne $s2) { $s = $s2 }
        $logLines = @($s.log)
        Assert-True ($logLines -ccontains 'Normale Ausgabe mit Umlauten: äöü') 'stdout log line with umlauts is decoded correctly'
        Assert-True ($logLines -ccontains 'Hinweis auf stderr: äöü') 'stderr line is logged'
        Assert-True ($logLines -ccontains ('Pfad=' + $shareDir)) 'path with spaces and umlaut reaches the child intact'
        $linkLine = @($logLines | Where-Object { $_ -like 'Link-Test:*' })
        Assert-True ($linkLine.Count -eq 1 -and $linkLine[0] -notlike '*aaaaaaaaaa*' -and $linkLine[0] -like '*<redacted>*') 'log redacts the link'
        Assert-True (@($logLines | Where-Object { $_ -like '*@@WSEVENT@@*' }).Count -eq 0) 'event lines are not part of the log'
    }
    $r = Invoke-Post $A '/api/pick-folder' $null
    if ($r.Status -ne 409) { Write-Host ("       pick-folder status: {0} body: {1}" -f $r.Status, $r.Body) }
    Assert-True ($r.Status -eq 409) '/api/pick-folder while a share runs -> 409'
    $s = Wait-ForState $A { param($x) $null -ne $x.remainingMinutes } 8
    Assert-True ($null -ne $s) 'status event updates remainingMinutes'

    $copyOk = $false
    $caps = (Get-State $A).capabilities
    if ($caps.clipboard) {
        $r = Invoke-Post $A '/api/copy' $null
        $copyOk = ($r.Status -eq 200)
        Assert-True $copyOk '/api/copy -> 200 while the link is available'
    }
    else { Write-Host '[NOTE] clipboard capability is false; /api/copy check skipped' }

    $fakePidA = Get-FakePid $A
    $sessionDirA = $null
    if (Test-Path -LiteralPath ($A.PidFile + '.session')) { $sessionDirA = ([IO.File]::ReadAllText($A.PidFile + '.session')).Trim() }
    Assert-True ($fakePidA -and (Test-PidAlive $fakePidA) -and $sessionDirA -and (Test-Path -LiteralPath $sessionDirA)) 'fake share process and its session folder exist'

    # single instance: second backend with the same instance file exits 0 quickly, file unchanged
    $before = [IO.File]::ReadAllText($A.Instance)
    $argText = '-NoLogo -NoProfile -STA -File "{0}" -TestMode -NoBrowser -InstanceFile "{1}" -TestShareScript "{2}" -DataRootOverride "{3}"' -f $startScript, $A.Instance, $fakeScript, $A.DataRoot
    $second = Start-Process -FilePath $psExe -ArgumentList $argText -PassThru -WindowStyle Hidden
    $null = $second.Handle
    $secondExited = $second.WaitForExit(10000)
    Assert-True ($secondExited -and $second.ExitCode -eq 0) 'second backend with the same instance file exits 0 within 10 s'
    if (-not $secondExited) { try { $second.Kill() } catch { } }
    Assert-True (([IO.File]::ReadAllText($A.Instance)) -ceq $before) 'second backend leaves the instance file unchanged'
    Assert-True (-not $A.Proc.HasExited) 'first backend is still running'

    # stop
    $r = Invoke-Post $A '/api/stop' $null
    Assert-True ($r.Status -eq 200 -and $r.Json.ok -eq $true) '/api/stop -> 200'
    $s = Wait-ForState $A { param($x) $x.phase -eq 'ended' }
    Assert-True ($null -ne $s) 'phase becomes ended after stop'
    if ($null -ne $s) {
        Assert-True ($null -eq $s.url) 'link is gone after the share ended'
        Assert-True ($s.reason -eq 'ManualStop' -and $s.exitCode -eq 0) 'ended with reason ManualStop and exit code 0'
    }
    Assert-True ($sessionDirA -and -not (Test-Path -LiteralPath $sessionDirA)) 'stop.requested reached the session (fake cleaned its folder)'
    Assert-True (Wait-Until -TimeoutSec 5 -Condition { -not (Test-PidAlive $fakePidA) }) 'fake share process has exited'
    $r = Invoke-Post $A '/api/stop' $null
    Assert-True ($r.Status -eq 409) '/api/stop after the end -> 409'
    $r = Invoke-Post $A '/api/copy' $null
    Assert-True ($r.Status -eq 409) '/api/copy after the end -> 409'

    # restart resets the share state; quit with a running share stops it first
    $r = Invoke-Post $A '/api/start' (New-StartBody $shareDir 2 'Store' $true)
    Assert-True ($r.Status -eq 200) 'restart after ended -> 200'
    $s = Get-State $A
    Assert-True ($s.phase -in @('starting', 'active') -and $null -eq $s.exitCode -and $null -eq $s.reason -and $s.request.compression -eq 'Store' -and $s.request.includeGenerated -eq $true) 'new start resets exit code and reason'
    $s = Wait-ForState $A { param($x) $x.phase -eq 'active' }
    Assert-True ($null -ne $s) 'second share becomes active'
    $fakePidA2 = Get-FakePid $A
    Test-GuiQuit $A 'A (running share)'
    Assert-True (Wait-Until -TimeoutSec 5 -Condition { -not (Test-PidAlive $fakePidA2) }) 'quit stopped the running share (fake process gone)'
    if ($copyOk) {
        $clip = (& $psExe -NoLogo -NoProfile -STA -Command 'Add-Type -AssemblyName System.Windows.Forms; [System.Windows.Forms.Clipboard]::GetText()') -join ''
        Assert-True ($clip -notlike '*fake-test.trycloudflare.com*') 'backend exit cleared the copied link from the clipboard'
    }

    # ================= backend B: fail22
    $B = Start-TestBackend -Scenario 'fail22' -Name 'B'
    if ($B.Port -le 0) { throw 'Backend B did not start.' }
    $r = Invoke-Post $B '/api/start' (New-StartBody $shareDir 5)
    Assert-True ($r.Status -eq 200) 'B: start -> 200'
    $s = Wait-ForState $B { param($x) $x.phase -eq 'error' }
    Assert-True ($null -ne $s) 'B: phase becomes error'
    if ($null -ne $s) {
        Assert-True ($s.exitCode -eq 22 -and $s.reason -eq 'Error') 'B: exit code 22 and reason Error'
        Assert-True ($s.message -like '*.env*') 'B: message from the ended event'
        Assert-True ($null -eq $s.url -and @($s.steps).Count -eq 2) 'B: no link, 2 steps'
    }
    $r = Invoke-Post $B '/api/start' (New-StartBody $shareDir 5)
    Assert-True ($r.Status -eq 200) 'B: restart after an error -> 200'
    $s = Wait-ForState $B { param($x) $x.phase -eq 'error' }
    Assert-True ($null -ne $s -and $s.exitCode -eq 22) 'B: second run fails with 22 again'
    Test-GuiQuit $B 'B (idle after error)'

    # ================= backend C: hang (no session -> kill path)
    $C = Start-TestBackend -Scenario 'hang' -Name 'C'
    if ($C.Port -le 0) { throw 'Backend C did not start.' }
    $r = Invoke-Post $C '/api/start' (New-StartBody $shareDir 5)
    Assert-True ($r.Status -eq 200) 'C: start -> 200'
    $s = Wait-ForState $C { param($x) @($x.steps).Count -ge 1 }
    $fakePidC = $null
    Assert-True ($null -ne $s -and $s.phase -eq 'starting') 'C: first step arrived, still starting'
    $fakePidC = Get-FakePid $C
    Assert-True ($fakePidC -and (Test-PidAlive $fakePidC)) 'C: fake process is running'
    $r = Invoke-Post $C '/api/stop' $null
    Assert-True ($r.Status -eq 200) 'C: /api/stop before the session event -> 200'
    $s = Wait-ForState $C { param($x) $x.phase -in @('ended', 'error') }
    Assert-True ($null -ne $s -and $s.phase -eq 'ended' -and $s.reason -eq 'ManualStop') 'C: killed share ends as ManualStop'
    Assert-True (Wait-Until -TimeoutSec 5 -Condition { -not (Test-PidAlive $fakePidC) }) 'C: process was killed'
    Test-GuiQuit $C 'C'

    # ================= backend D: backend crash -> child notices the missing parent
    $D = Start-TestBackend -Scenario 'parent' -Name 'D'
    if ($D.Port -le 0) { throw 'Backend D did not start.' }
    $r = Invoke-Post $D '/api/start' (New-StartBody $shareDir 5)
    Assert-True ($r.Status -eq 200) 'D: start -> 200'
    $s = Wait-ForState $D { param($x) $x.phase -eq 'active' }
    $fakePidD = Get-FakePid $D
    Assert-True ($null -ne $s -and $fakePidD -and (Test-PidAlive $fakePidD)) 'D: share active, fake process running'
    Stop-Process -Id $D.Proc.Id -Force
    Assert-True (Wait-Until -TimeoutSec 10 -Condition { -not (Test-PidAlive $fakePidD) }) 'D: fake share exits within 10 s after the backend was killed'

    # ================= -DataRootOverride is a test-only parameter
    $p = Start-Process -FilePath $psExe -ArgumentList ('-NoLogo -NoProfile -File "{0}" -DataRootOverride "{1}" -NoBrowser' -f $startScript, (Join-Path $tmp 'data-x')) -PassThru -WindowStyle Hidden -Wait
    Assert-True ($p.ExitCode -eq 10 -and -not (Test-Path -LiteralPath (Join-Path $tmp 'data-x'))) '-DataRootOverride without -TestMode exits with 10'

    # ================= backend E: drag & drop (GUI_CONTRACT section 7)
    $dataE = Join-Path $tmp 'data-E'
    $dropsE = Join-Path $dataE 'drops'
    $staleLeaf = Join-Path (Join-Path $dropsE ('deadbeef' * 4)) 'Dateien-alt'
    [void](New-Item -ItemType Directory -Path $staleLeaf -Force)
    [IO.File]::WriteAllText((Join-Path $staleLeaf 'alt.txt'), 'x', $utf8)
    $E = Start-TestBackend -Scenario 'success' -Name 'E' -DataRoot $dataE
    if ($E.Port -le 0) { throw 'Backend E did not start.' }
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $dropsE ('deadbeef' * 4)))) 'E: stale drop folder from an earlier run is removed at backend start'
    $s = Get-State $E
    Assert-True ($s.phase -eq 'idle' -and $null -eq $s.drop -and $s.limits.maxDropBytes -eq 4GB) 'E: idle, no drop'

    $srcBig = Join-Path $tmp 'src-big.bin'; New-RandomFile $srcBig 5242880 11
    $srcC = Join-Path $tmp 'src-c.bin'; New-RandomFile $srcC 1234 12
    $srcUml = Join-Path $tmp 'src-uml.txt'; [IO.File]::WriteAllText($srcUml, 'Grüße äöü € Ende', $utf8)
    $srcTiny = Join-Path $tmp 'src-tiny.txt'; [IO.File]::WriteAllText($srcTiny, 'x', $utf8)
    $srcEmpty = Join-Path $tmp 'src-empty.bin'; [IO.File]::WriteAllBytes($srcEmpty, (New-Object byte[] 0))
    $src300k = Join-Path $tmp 'src-300k.bin'; New-RandomFile $src300k 307200 13

    $r = Invoke-Api -Method POST -Path '/api/drop/begin' -B $E -BodyText '{}'
    Assert-True ($r.Status -eq 401) 'E: drop/begin without token -> 401'
    $r = Invoke-Api -Method GET -Path '/api/drop/begin' -B $E -Token $E.Token
    Assert-True ($r.Status -eq 405) 'E: GET drop/begin -> 405'
    $r = Invoke-Post $E '/api/drop/finish' @{ dropId = ('0' * 32) }
    Assert-True ($r.Status -eq 400) 'E: drop/finish with an unknown drop id -> 400'
    $r = Invoke-Post $E '/api/drop/begin' $null
    Assert-True ($r.Status -eq 200 -and $r.Json.dropId -match '^[0-9a-f]{32}$') 'E: drop/begin -> 200 with a 32 hex dropId'
    $drop1 = [string]$r.Json.dropId
    $drop1Root = Join-Path $dropsE $drop1
    $leafDirs = @(Get-ChildItem -LiteralPath $drop1Root -Directory -ErrorAction SilentlyContinue)
    Assert-True ($leafDirs.Count -eq 1 -and $leafDirs[0].Name -match '^Dateien-\d{8}-\d{6}$') 'E: drop folder <DataRoot>\drops\<id>\Dateien-yyyyMMdd-HHmmss exists'
    $leaf1 = $leafDirs[0].FullName
    $s = Get-State $E
    Assert-True ($null -ne $s.drop -and $s.drop.id -eq $drop1 -and $s.drop.path -eq $leaf1 -and $s.drop.files -eq 0 -and $s.drop.finished -eq $false) 'E: state.drop after begin (unfinished, 0 files)'
    $r = Invoke-Post $E '/api/drop/finish' @{ dropId = $drop1 }
    Assert-True ($r.Status -eq 400) 'E: drop/finish without any file -> 400'

    # upload 3 files: nested path, umlaut name, 5 MB random
    $r = Invoke-Upload $E $drop1 'sub/ordner/c.bin' $srcC
    Assert-True ($r.Status -eq 200 -and $r.Json.ok -eq $true -and $r.Json.bytes -eq 1234) 'E: upload of sub/ordner/c.bin -> 200 {ok, bytes}'
    $r = Invoke-Upload $E $drop1 'Bericht ä.txt' $srcUml
    Assert-True ($r.Status -eq 200 -and $r.Json.bytes -eq ([IO.FileInfo]$srcUml).Length) 'E: upload of "Bericht ä.txt" -> 200'
    $sw5 = [Diagnostics.Stopwatch]::StartNew()
    $r = Invoke-Upload $E $drop1 'big.bin' $srcBig
    Assert-True ($r.Status -eq 200 -and $r.Json.bytes -eq 5242880) 'E: upload of a 5 MB random file -> 200'
    Write-Host ("       5 MB upload took {0:N1} s" -f $sw5.Elapsed.TotalSeconds)
    $s = Get-State $E
    Assert-True ($s.drop.files -eq 3 -and $s.drop.finished -eq $false -and $s.drop.totalBytes -eq (1234 + ([IO.FileInfo]$srcUml).Length + 5242880)) 'E: state.drop counts files and bytes while unfinished'
    $r = Invoke-Post $E '/api/drop/finish' @{ dropId = $drop1 }
    $expectedTotal = 1234 + ([IO.FileInfo]$srcUml).Length + 5242880
    Assert-True ($r.Status -eq 200 -and $r.Json.path -eq $leaf1 -and $r.Json.files -eq 3 -and $r.Json.totalBytes -eq $expectedTotal) 'E: drop/finish -> path, files 3, totalBytes'
    Assert-True ((Test-Path -LiteralPath (Join-Path $leaf1 'sub\ordner\c.bin')) -and (Test-Path -LiteralPath (Join-Path $leaf1 'Bericht ä.txt')) -and (Test-Path -LiteralPath (Join-Path $leaf1 'big.bin'))) 'E: all three files exist in the drop folder with their relative paths'
    Assert-True ((Get-FileSha (Join-Path $leaf1 'big.bin')) -eq (Get-FileSha $srcBig) -and (Get-FileSha (Join-Path $leaf1 'sub\ordner\c.bin')) -eq (Get-FileSha $srcC) -and (Get-FileSha (Join-Path $leaf1 'Bericht ä.txt')) -eq (Get-FileSha $srcUml)) 'E: uploaded files are bit-identical (SHA-256)'
    Assert-True ((Get-FileCount $dropsE) -eq 3) 'E: exactly three files below drops'
    $s = Get-State $E
    Assert-True ($s.drop.finished -eq $true -and $s.drop.files -eq 3 -and $s.drop.totalBytes -eq $expectedTotal -and $s.drop.path -eq $leaf1) 'E: state.drop finished with path, files, totalBytes'
    $r = Invoke-Upload $E $drop1 'late.txt' $srcTiny
    Assert-True ($r.Status -eq 409 -and -not (Test-Path -LiteralPath (Join-Path $leaf1 'late.txt'))) 'E: upload into a finished drop -> 409'

    # /api/start: only the finished drop may be shared from inside the drops folder
    $r = Invoke-Post $E '/api/start' (New-StartBody $dropsE 5)
    Assert-True ($r.Status -eq 400) 'E: /api/start with the drops root itself -> 400'
    $r = Invoke-Post $E '/api/start' (New-StartBody (Join-Path $leaf1 'sub') 5)
    Assert-True ($r.Status -eq 400) 'E: /api/start with a sub folder of the drop -> 400'
    $r = Invoke-Post $E '/api/start' (New-StartBody $drop1Root 5)
    Assert-True ($r.Status -eq 400) 'E: /api/start with the drop id folder (not the leaf) -> 400'
    Assert-True ((Get-State $E).phase -eq 'idle') 'E: rejected drop starts leave the phase idle'

    # share the drop: active -> stop -> ended -> drop deleted
    $r = Invoke-Post $E '/api/start' (New-StartBody $leaf1 5)
    Assert-True ($r.Status -eq 200) 'E: /api/start with the finished drop path -> 200'
    $s = Wait-ForState $E { param($x) $x.phase -eq 'active' }
    Assert-True ($null -ne $s) 'E: share of the drop becomes active'
    if ($null -ne $s) {
        Assert-True ($null -ne $s.drop -and $s.drop.path -eq $leaf1 -and (Test-Path -LiteralPath (Join-Path $leaf1 'big.bin'))) 'E: drop folder stays in place while its share runs'
        $s2 = Wait-ForState $E { param($x) @($x.log) -like 'Pfad=*' } 8
        Assert-True ($null -ne $s2 -and @($s2.log) -ccontains ('Pfad=' + $leaf1)) 'E: the share process received the drop folder as -Path'
    }
    $r = Invoke-Post $E '/api/drop/begin' $null
    Assert-True ($r.Status -eq 409) 'E: drop/begin while a share runs -> 409'
    $r = Invoke-Upload $E $drop1 'x.txt' $srcTiny
    Assert-True ($r.Status -eq 409) 'E: upload while a share runs -> 409'
    $r = Invoke-Post $E '/api/drop/discard' @{ dropId = $drop1 }
    Assert-True ($r.Status -eq 409 -and (Test-Path -LiteralPath $leaf1)) 'E: drop/discard while a share runs -> 409, folder stays'
    $r = Invoke-Post $E '/api/stop' $null
    Assert-True ($r.Status -eq 200) 'E: stop the drop share'
    $s = Wait-ForState $E { param($x) $x.phase -eq 'ended' }
    Assert-True ($null -ne $s) 'E: drop share ends'
    Assert-True (Wait-Until -TimeoutSec 10 -Condition { -not (Test-Path -LiteralPath $drop1Root) }) 'E: drop folder is deleted after the share ended'
    $s = Get-State $E
    Assert-True ($null -eq $s.drop) 'E: state.drop is null after the share ended'

    # path validation on an unfinished drop
    $r = Invoke-Post $E '/api/drop/begin' $null
    $drop2 = [string]$r.Json.dropId
    $drop2Root = Join-Path $dropsE $drop2
    $leaf2 = [string](Get-State $E).drop.path
    $badPaths = [ordered]@{
        'dot-dot'            = '../x'
        'dot-dot in middle'  = 'a/../b'
        'drive letter'       = 'C:/x'
        'absolute'           = '/abs'
        'reserved con.txt'   = 'con.txt'
        'reserved CON'       = 'CON'
        'reserved nested'    = 'ok/Com1.log'
        'reserved lpt9'      = 'lpt9.x.y'
        'backslash'          = 'a\b'
        'colon'              = 'x:y'
        'trailing dot'       = 'name.'
        'trailing space'     = 'name '
        'empty segment'      = 'a//b'
        'trailing slash'     = 'a/'
        'dot segment'        = 'a/./b'
        'lone dot'           = '.'
        'question mark'      = 'a?b'
        'asterisk'           = 'a*b'
        'angle brackets'     = '<x>'
        'pipe'               = 'a|b'
        'double quote'       = 'a"b'
        'control character'  = ("a" + [char]1 + "b")
        '300-char segment'   = ('a' * 300)
        '65 segments'        = ((1..65 | ForEach-Object { 'd' }) -join '/')
        '401-char path'      = ((1..5 | ForEach-Object { 'q' * 100 }) -join '/')
    }
    foreach ($name in $badPaths.Keys) {
        $r = Invoke-Upload $E $drop2 $badPaths[$name] $srcTiny
        Assert-True ($r.Status -eq 400) "E: invalid upload path ($name) -> 400"
    }
    $r = Invoke-Upload $E $drop2 '' $srcTiny
    Assert-True ($r.Status -eq 400) 'E: empty upload path -> 400'
    Assert-True ((Get-FileCount $dataE) -eq 0 -and -not (Test-Path -LiteralPath (Join-Path $dataE 'x')) -and -not (Test-Path -LiteralPath (Join-Path $dropsE 'x')) -and -not (Test-Path -LiteralPath (Join-Path $tmp 'x'))) 'E: rejected paths created no file anywhere'
    $r = Invoke-Upload $E ('1' * 32) 'a.txt' $srcTiny
    Assert-True ($r.Status -eq 400) 'E: upload with an unknown drop id -> 400'
    $r = Invoke-Upload $E 'zz' 'a.txt' $srcTiny
    Assert-True ($r.Status -eq 400) 'E: upload with a malformed drop id -> 400'

    # auth
    $r = Invoke-Upload $E $drop2 'notoken.bin' $src300k -NoToken
    Assert-True ($r.Status -eq 401) 'E: upload without token -> 401 (reaches the client although it sends 300 KB)'
    $r = Invoke-Upload $E $drop2 'wrongtoken.bin' $srcTiny -NoToken -ExtraHeaders @('X-WS-Token: nope')
    Assert-True ($r.Status -eq 401) 'E: upload with a wrong token -> 401'
    $r = Invoke-Upload $E $drop2 'badhost.bin' $srcTiny -ExtraHeaders @("Host: localhost:$($E.Port)")
    Assert-True ($r.Status -eq 403) 'E: upload with a foreign Host header -> 403'
    $r = Invoke-Upload $E $drop2 'badorigin.bin' $srcTiny -ExtraHeaders @('Origin: http://evil.example')
    Assert-True ($r.Status -eq 403) 'E: upload with a foreign Origin -> 403'
    Assert-True ((Get-FileCount $dataE) -eq 0) 'E: unauthorized uploads wrote no file'

    # 411: no Content-Length
    $raw = Send-RawHttp $E ("POST /api/drop/file?drop=$drop2&path=nolen.txt HTTP/1.1`r`nHost: 127.0.0.1:$($E.Port)`r`nX-WS-Token: $($E.Token)`r`nContent-Type: application/octet-stream`r`n`r`n")
    Assert-True ($raw.StartsWith('HTTP/1.1 411 ') -and -not (Test-Path -LiteralPath (Join-Path $leaf2 'nolen.txt'))) 'E: upload without Content-Length -> 411'
    $raw = Send-RawHttp $E ("POST /api/drop/file?drop=$drop2&path=chunked.txt HTTP/1.1`r`nHost: 127.0.0.1:$($E.Port)`r`nX-WS-Token: $($E.Token)`r`nTransfer-Encoding: chunked`r`n`r`n1`r`nx`r`n0`r`n`r`n")
    Assert-True ($raw.StartsWith('HTTP/1.1 400 ') -and (Get-FileCount $dataE) -eq 0) 'E: chunked upload -> 400, no file'
    $raw = Send-RawHttp $E ("GET /api/drop/file?drop=$drop2&path=x.txt HTTP/1.1`r`nHost: 127.0.0.1:$($E.Port)`r`nX-WS-Token: $($E.Token)`r`n`r`n")
    Assert-True ($raw.StartsWith('HTTP/1.1 405 ')) 'E: GET drop/file -> 405'

    # duplicates and name clashes
    $r = Invoke-Upload $E $drop2 'dup.txt' $srcTiny
    Assert-True ($r.Status -eq 200) 'E: first upload of dup.txt -> 200'
    $r = Invoke-Upload $E $drop2 'dup.txt' $srcUml
    Assert-True ($r.Status -eq 409 -and (Get-FileSha (Join-Path $leaf2 'dup.txt')) -eq (Get-FileSha $srcTiny)) 'E: duplicate path -> 409, original untouched'
    $r = Invoke-Upload $E $drop2 'DUP.TXT' $srcUml
    Assert-True ($r.Status -eq 409) 'E: duplicate path differing only in case -> 409'
    $r = Invoke-Upload $E $drop2 'dup.txt/inner.bin' $srcTiny
    Assert-True ($r.Status -eq 409) 'E: path below an existing file -> 409'
    $r = Invoke-Upload $E $drop2 'tree/leaf.bin' $srcTiny
    Assert-True ($r.Status -eq 200) 'E: tree/leaf.bin -> 200'
    $r = Invoke-Upload $E $drop2 'tree' $srcTiny
    Assert-True ($r.Status -eq 409) 'E: file named like an existing folder -> 409'
    $r = Invoke-Upload $E $drop2 'leer.bin' $srcEmpty
    Assert-True ($r.Status -eq 200 -and $r.Json.bytes -eq 0 -and (Test-Path -LiteralPath (Join-Path $leaf2 'leer.bin')) -and ([IO.FileInfo](Join-Path $leaf2 'leer.bin')).Length -eq 0) 'E: empty file -> 200, empty file on disk'
    Assert-True ((Get-FileCount $dataE) -eq 3) 'E: only the three accepted files exist'

    # new begin discards the previous (unfinished) drop
    $r = Invoke-Post $E '/api/drop/begin' $null
    $drop3 = [string]$r.Json.dropId
    Assert-True ($r.Status -eq 200 -and $drop3 -ne $drop2) 'E: second drop/begin -> new drop id'
    Assert-True (-not (Test-Path -LiteralPath $drop2Root)) 'E: a new begin discards the previous unfinished drop'
    $s = Get-State $E
    Assert-True ($s.drop.id -eq $drop3 -and $s.drop.files -eq 0) 'E: state.drop describes the new drop'
    $r = Invoke-Upload $E $drop2 'old.txt' $srcTiny
    Assert-True ($r.Status -eq 400) 'E: upload into the discarded drop id -> 400'

    # discard
    $drop3Root = Join-Path $dropsE $drop3
    $r = Invoke-Upload $E $drop3 'a.txt' $srcTiny
    Assert-True ($r.Status -eq 200 -and (Get-FileCount $drop3Root) -eq 1) 'E: upload into drop 3'
    $r = Invoke-Post $E '/api/drop/discard' @{ dropId = $drop3 }
    Assert-True ($r.Status -eq 200 -and $r.Json.ok -eq $true) 'E: drop/discard -> 200'
    Assert-True (-not (Test-Path -LiteralPath $drop3Root) -and $null -eq (Get-State $E).drop) 'E: discard deletes the folder and clears state.drop'
    $r = Invoke-Post $E '/api/drop/discard' @{ dropId = $drop3 }
    Assert-True ($r.Status -eq 400) 'E: discarding an unknown drop -> 400'

    # quit removes the current drop
    $r = Invoke-Post $E '/api/drop/begin' $null
    $drop4 = [string]$r.Json.dropId
    $drop4Root = Join-Path $dropsE $drop4
    $r = Invoke-Upload $E $drop4 'keep.bin' $srcC
    Assert-True ($r.Status -eq 200 -and (Get-FileCount $drop4Root) -eq 1) 'E: drop 4 has a file before quit'
    Test-GuiQuit $E 'E (drop present)'
    Assert-True (-not (Test-Path -LiteralPath $drop4Root)) 'E: quit removes the current drop folder'
    Assert-True ((Get-FileCount $dataE) -eq 0) 'E: no drop file remains after quit'

    # ================= backend F: limits (-MaxDropBytes 1 MB, -MaxDropFiles 2)
    $F = Start-TestBackend -Scenario 'success' -Name 'F' -ExtraArgs '-MaxDropBytes 1048576 -MaxDropFiles 2'
    if ($F.Port -le 0) { throw 'Backend F did not start.' }
    $dropsF = Join-Path $F.DataRoot 'drops'
    $s = Get-State $F
    Assert-True ($s.limits.maxDropBytes -eq 1048576 -and $s.limits.maxDropFiles -eq 2) 'F: state.limits reflect the parameters'
    $r = Invoke-Post $F '/api/drop/begin' $null
    $dropF = [string]$r.Json.dropId
    $src2m = Join-Path $tmp 'src-2m.bin'; New-RandomFile $src2m 2097152 21
    $src400k = Join-Path $tmp 'src-400k.bin'; New-RandomFile $src400k 409600 22
    $src700k = Join-Path $tmp 'src-700k.bin'; New-RandomFile $src700k 716800 23
    $r = Invoke-Upload $F $dropF 'zu-gross.bin' $src2m
    Assert-True ($r.Status -eq 413) 'F: 2 MB upload with -MaxDropBytes 1 MB -> 413'
    Assert-True ((Get-FileCount $dropsF) -eq 0) 'F: no partial file is left after the 413'
    $r = Invoke-Upload $F $dropF 'a.bin' $src400k
    Assert-True ($r.Status -eq 200) 'F: 400 KB upload -> 200'
    $r = Invoke-Upload $F $dropF 'b.bin' $src700k
    Assert-True ($r.Status -eq 413) 'F: cumulative total above the limit -> 413'
    Assert-True ((Get-FileCount $dropsF) -eq 1) 'F: only the first file exists after the cumulative 413'
    $r = Invoke-Upload $F $dropF 'b2.bin' $srcTiny
    Assert-True ($r.Status -eq 200) 'F: a small second file still fits -> 200'
    $r = Invoke-Upload $F $dropF 'c.bin' $srcTiny
    Assert-True ($r.Status -eq 413) 'F: third file above -MaxDropFiles 2 -> 413'
    $r = Invoke-Post $F '/api/drop/finish' @{ dropId = $dropF }
    Assert-True ($r.Status -eq 200 -and $r.Json.files -eq 2 -and $r.Json.totalBytes -eq (409600 + 1) -and (Get-FileCount $dropsF) -eq 2) 'F: finish reports exactly the accepted files'
    Test-GuiQuit $F 'F (finished drop present)'
    Assert-True ((Get-FileCount $dropsF) -eq 0) 'F: quit removed the finished, unused drop'
}
catch {
    $script:Fail++
    Write-Host ('[FAIL] unexpected error: ' + $_.Exception.Message)
    Write-Host ('       at ' + $_.InvocationInfo.PositionMessage)
}
finally {
    foreach ($b in $script:Backends) { Stop-TestBackendHard $b }
    Remove-Item Env:\WS_FAKE_SCENARIO -ErrorAction SilentlyContinue
    Remove-Item Env:\WS_FAKE_PIDFILE -ErrorAction SilentlyContinue
    for ($i = 0; $i -lt 5; $i++) {
        try { Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction Stop; break }
        catch { Start-Sleep -Milliseconds 400 }
    }
}

# ---------------------------------------------------------------- CodeIntegrity (Smart App Control) check
$blocked = @()
try {
    $events = @(Get-WinEvent -FilterHashtable @{ LogName = 'Microsoft-Windows-CodeIntegrity/Operational'; Id = 3033, 3077; StartTime = $testStart } -ErrorAction SilentlyContinue)
    $repoTail = $ToolRoot
    if ($repoTail.Length -gt 3 -and $repoTail[1] -eq ':') { $repoTail = $repoTail.Substring(2) }
    foreach ($e in $events) {
        $m = [string]$e.Message
        if ($m -match '(?i)powershell' -or $m.IndexOf($repoTail, [StringComparison]::OrdinalIgnoreCase) -ge 0) { $blocked += $e }
    }
}
catch { }

Write-Host ''
Write-Host "Passed: $($script:Pass)  Failed: $($script:Fail)"
if ($blocked.Count -gt 0) {
    Write-Host "[ENV] Windows Code Integrity / Smart App Control hat $($blocked.Count) Datei(en) blockiert; das Testergebnis ist nicht aussagekräftig."
    foreach ($e in $blocked | Select-Object -First 5) { Write-Host ('[ENV] ' + (([string]$e.Message) -replace '\s+', ' ')) }
    exit 42
}
if ($script:Fail -gt 0) { exit 1 }
exit 0
