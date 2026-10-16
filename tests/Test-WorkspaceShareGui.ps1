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
    param([string]$Scenario, [string]$Name, [string]$InstanceFile)
    if (-not $InstanceFile) { $InstanceFile = Join-Path $tmp "gui-$Name.json" }
    $pidFile = Join-Path $tmp "fake-$Name.pid"
    $outFile = Join-Path $tmp "backend-$Name.out"
    $errFile = Join-Path $tmp "backend-$Name.err"
    $env:WS_FAKE_SCENARIO = $Scenario
    $env:WS_FAKE_PIDFILE = $pidFile
    $argText = '-NoLogo -NoProfile -STA -File "{0}" -TestMode -NoBrowser -InstanceFile "{1}" -TestShareScript "{2}"' -f $startScript, $InstanceFile, $fakeScript
    $p = Start-Process -FilePath $psExe -ArgumentList $argText -PassThru -WindowStyle Hidden -RedirectStandardOutput $outFile -RedirectStandardError $errFile
    $null = $p.Handle
    $b = [pscustomobject]@{
        Name = $Name; Proc = $p; Instance = $InstanceFile; PidFile = $pidFile; Out = $outFile; Err = $errFile
        Port = 0; Token = ''
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
    $argText = '-NoLogo -NoProfile -STA -File "{0}" -TestMode -NoBrowser -InstanceFile "{1}" -TestShareScript "{2}"' -f $startScript, $A.Instance, $fakeScript
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
