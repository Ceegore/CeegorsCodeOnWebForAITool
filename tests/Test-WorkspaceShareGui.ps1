#requires -Version 5.1
# End-to-end tests of Start-WorkspaceShareGui.ps1 (contract v2: several shares at the same time) with
# tests\Fake-WorkspaceShare.ps1 (no network, no tunnel).
# Exit: 0 = all passed, 1 = failures, 42 = environment blocked (CodeIntegrity events 3033/3077).
[CmdletBinding()]
param([string]$ToolRoot)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if ([string]::IsNullOrWhiteSpace($ToolRoot)) { $ToolRoot = Split-Path $PSScriptRoot -Parent }

$script:Pass = 0
$script:DebugCurl = 0
$script:Fail = 0
function Assert-True {
    param($Condition, [string]$Name)
    if ([bool]$Condition) { $script:Pass++; Write-Host "[PASS] $Name" }
    else { $script:Fail++; Write-Host "[FAIL] $Name" }
}

$testStart = Get-Date
$isWin = ([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT)
# Start-Process -WindowStyle exists only on Windows; the splat is empty on Linux.
$hiddenWindow = @{}
if ($isWin) { $hiddenWindow['WindowStyle'] = 'Hidden' }
if ($isWin) {
    $psExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $curl = Join-Path $env:SystemRoot 'System32\curl.exe'
}
else {
    $psExe = Join-Path $PSHOME 'pwsh'
    $curl = (Get-Command curl -CommandType Application -ErrorAction Stop | Select-Object -First 1).Source
}
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
    $cargs = @('-s', '--noproxy', '127.0.0.1', '--max-time', '10', '-D', $hf, '-o', $bf, '-w', '%{http_code}', '-X', $Method)
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
    if ($status -eq 0 -and $script:DebugCurl -lt 3) { $script:DebugCurl++; Write-Host ('[DEBUG] curl exit ' + $LASTEXITCODE + ' out=[' + $codeText + '] args=' + ($cargs -join ' ')) }
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

function Get-Fakes {
    # All fake share processes a backend has started (the fake writes fake-<name>-<pid>.pid plus .session/.path).
    param($B)
    $list = @()
    $dir = Split-Path -Parent $B.PidFile
    $files = @(Get-ChildItem -LiteralPath $dir -Filter ('fake-' + $B.Name + '-*.pid') -File -ErrorAction SilentlyContinue | Sort-Object LastWriteTimeUtc, Name)
    foreach ($f in $files) {
        $n = 0
        $text = ''
        try { $text = ([IO.File]::ReadAllText($f.FullName)).Trim() } catch { continue }
        if (-not [int]::TryParse($text, [ref]$n)) { continue }
        $sessionFile = $f.FullName + '.session'
        $pathFile = $f.FullName + '.path'
        $session = $null
        $sharePath = $null
        if (Test-Path -LiteralPath $sessionFile) { $session = ([IO.File]::ReadAllText($sessionFile)).Trim() }
        if (Test-Path -LiteralPath $pathFile) { $sharePath = ([IO.File]::ReadAllText($pathFile)).Trim() }
        $list += , ([pscustomobject]@{ Pid = $n; Session = $session; Path = $sharePath; File = $f.FullName })
    }
    return $list
}

function Get-FakePid {
    # Process id of the newest fake share of a backend.
    param($B)
    $all = @(Get-Fakes $B)
    if ($all.Count -eq 0) { return $null }
    return $all[$all.Count - 1].Pid
}

function Get-FakeByPath {
    param($B, [string]$Path)
    foreach ($f in @(Get-Fakes $B)) { if ($f.Path -ceq $Path) { return $f } }
    return $null
}

function Get-ShareFromState {
    param($State, [string]$Id)
    if ($null -eq $State) { return $null }
    foreach ($sh in @($State.shares)) { if ($sh.id -ceq $Id) { return $sh } }
    return $null
}

function Wait-ForShare {
    # Polls /api/state until the share <Id> satisfies the test; returns the share object (or $null on timeout).
    param($B, [string]$Id, [scriptblock]$Test, [int]$TimeoutSec = 20)
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $last = $null
    while ($sw.Elapsed.TotalSeconds -lt $TimeoutSec) {
        $sh = Get-ShareFromState (Get-State $B) $Id
        if ($null -ne $sh) {
            $last = $sh
            if (& $Test $sh) { return $sh }
        }
        Start-Sleep -Milliseconds 250
    }
    if ($null -ne $last) { Write-Host ("       last phase of share {0}: {1}, step {2}, exit {3}" -f $Id, $last.phase, $last.step, $last.exitCode) }
    return $null
}

function Start-Share {
    # POST /api/start; returns Status, Id (shareId or $null) and the raw response.
    param($B, [string]$Path, $Minutes = 5, $Compression = 'Fast', $Include = $false, $Name = $null)
    $body = New-StartBody $Path $Minutes $Compression $Include
    if ($null -ne $Name) { $body['name'] = $Name }
    $r = Invoke-Post $B '/api/start' $body
    $id = $null
    if ($r.Status -eq 200 -and $null -ne $r.Json -and $r.Json.shareId) { $id = [string]$r.Json.shareId }
    return [pscustomobject]@{ Status = $r.Status; Id = $id; R = $r }
}

function New-ShareDir {
    # A small folder to share; returns its path.
    param([string]$Name)
    $d = Join-Path $tmp $Name
    [void](New-Item -ItemType Directory -Path $d -Force)
    [IO.File]::WriteAllText((Join-Path $d 'a.txt'), 'x', $utf8)
    return $d
}

function Start-BackgroundCurl {
    # Runs curl detached (so the test can keep talking to the backend meanwhile); returns the process and its files.
    param([string[]]$CurlArgs, [string]$Tag)
    $out = Join-Path $tmp ("bg-$Tag-" + [Guid]::NewGuid().ToString('N') + '.txt')
    $all = @('-s', '--noproxy', '127.0.0.1', '--max-time', '120', '-o', $out, '-w', '%{http_code}') + $CurlArgs
    $quoted = @($all | ForEach-Object { if ($_ -match '[\s"]') { '"' + $_ + '"' } else { $_ } })
    $codeF = $out + '.code'
    $p = Start-Process -FilePath $curl -ArgumentList $quoted -PassThru @hiddenWindow -RedirectStandardOutput $codeF -RedirectStandardError ($out + '.err')
    $null = $p.Handle
    return [pscustomobject]@{ Proc = $p; Body = $out; CodeFile = $codeF }
}

function Get-BackgroundCurlResult {
    param($Bg)
    $status = 0
    if (Test-Path -LiteralPath $Bg.CodeFile) { [void][int]::TryParse(([IO.File]::ReadAllText($Bg.CodeFile)).Trim(), [ref]$status) }
    $body = ''
    if (Test-Path -LiteralPath $Bg.Body) { $body = [IO.File]::ReadAllText($Bg.Body, $utf8) }
    $json = $null
    if ($body.StartsWith('{')) { try { $json = $body | ConvertFrom-Json } catch { $json = $null } }
    return [pscustomobject]@{ Status = $status; Body = $body; Json = $json }
}

function Start-TestBackend {
    # Every test backend gets its own -DataRootOverride below $tmp, so tests never touch the real data folder.
    # -NoWait returns right after the process started (for a start that takes over from a running instance);
    # -Script starts a copy of the repo instead of $startScript.
    param([string]$Scenario, [string]$Name, [string]$InstanceFile, [string]$DataRoot, [string]$ExtraArgs = '', [switch]$NoWait, [string]$StartScriptPath)
    if (-not $StartScriptPath) { $StartScriptPath = $startScript }
    if (-not $InstanceFile) { $InstanceFile = Join-Path $tmp "gui-$Name.json" }
    if (-not $DataRoot) { $DataRoot = Join-Path $tmp "data-$Name" }
    # '{pid}' makes every fake share of this backend write its own files (several shares run in parallel).
    $pidFile = Join-Path $tmp "fake-$Name-{pid}.pid"
    $outFile = Join-Path $tmp "backend-$Name.out"
    $errFile = Join-Path $tmp "backend-$Name.err"
    $env:WS_FAKE_SCENARIO = $Scenario
    $env:WS_FAKE_PIDFILE = $pidFile
    $argText = '-NoLogo -NoProfile -STA -File "{0}" -TestMode -NoBrowser -InstanceFile "{1}" -TestShareScript "{2}" -DataRootOverride "{3}" {4}' -f $StartScriptPath, $InstanceFile, $fakeScript, $DataRoot, $ExtraArgs
    if (-not $isWin) { $argText = $argText.Replace(' -STA', '') }
    $p = Start-Process -FilePath $psExe -ArgumentList $argText -PassThru @hiddenWindow -RedirectStandardOutput $outFile -RedirectStandardError $errFile
    $null = $p.Handle
    $b = [pscustomobject]@{
        Name = $Name; Proc = $p; Instance = $InstanceFile; PidFile = $pidFile; Out = $outFile; Err = $errFile
        DataRoot = $DataRoot; Port = 0; Token = ''
    }
    $script:Backends.Add($b)
    if ($NoWait) { return $b }
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
    foreach ($f in @(Get-Fakes $B)) {
        if ($f.Pid -and (Test-PidAlive $f.Pid)) { Stop-Process -Id $f.Pid -Force -ErrorAction SilentlyContinue }
        if ($f.Session -and (Test-Path -LiteralPath $f.Session)) { Remove-Item -LiteralPath $f.Session -Recurse -Force -ErrorAction SilentlyContinue }
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
    $cargs = @('-s', '--noproxy', '127.0.0.1', '--max-time', '60', '-o', $bf, '-w', '%{http_code}', '-X', 'POST',
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
    # The Linux single-instance lock file (<data root>/locks) is not a drop file.
    return @(Get-ChildItem -LiteralPath $Dir -Recurse -File -Force -ErrorAction SilentlyContinue | Where-Object { $_.FullName -notmatch '[\\/]locks[\\/]' }).Count
}

function Get-ExpectedBuild {
    # Independent implementation of the build id (GUI_CONTRACT section 5) for a repo root.
    param([string]$Root)
    $names = @('VERSION', 'Start-WorkspaceShareGui.ps1', 'scripts/WorkspaceShare.Gui.Http.psm1',
        'scripts/WorkspaceShare.Platform.psm1', 'gui/index.html', 'gui/app.js', 'gui/app.css', 'gui/favicon.svg')
    $all = New-Object System.Collections.Generic.List[byte]
    foreach ($n in $names) {
        $full = Join-Path $Root $n
        if (Test-Path -LiteralPath $full -PathType Leaf) { $all.AddRange([byte[]][IO.File]::ReadAllBytes($full)) }
        else { $all.AddRange([byte[]][Text.Encoding]::UTF8.GetBytes($n)) }
    }
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try { $hash = $sha.ComputeHash($all.ToArray()) } finally { $sha.Dispose() }
    return ((($hash | ForEach-Object { $_.ToString('x2') }) -join '').Substring(0, 16))
}

function Get-StaticFile {
    # GET a static path without token; saves the body bytes to $OutFile and returns the HTTP status.
    param($B, [string]$Path, [string]$OutFile)
    if (Test-Path -LiteralPath $OutFile) { Remove-Item -LiteralPath $OutFile -Force }
    $codeText = (& $curl -s --noproxy 127.0.0.1 --max-time 10 -o $OutFile -w '%{http_code}' ('http://127.0.0.1:{0}{1}' -f $B.Port, $Path)) -join ''
    $status = 0
    [void][int]::TryParse($codeText.Trim(), [ref]$status)
    return $status
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
    $p = Start-Process -FilePath $psExe -ArgumentList ('-NoLogo -NoProfile -File "{0}" -TestShareScript "{1}" -NoBrowser' -f $startScript, $fakeScript) -PassThru @hiddenWindow -Wait
    Assert-True ($p.ExitCode -eq 10) '-TestShareScript without -TestMode exits with 10'

    # ---- shortcut installer (never touches the real desktop / start menu)
    $lnkDir = Join-Path $tmp 'lnk'
    if (-not $isWin) {
        & $psExe -NoLogo -NoProfile -File (Join-Path $ToolRoot 'Install-GuiShortcut.ps1') -TargetDirectory $lnkDir | Out-Null
        $desktopFile = Join-Path $lnkDir 'workspaceshare.desktop'
        $desktopText = if (Test-Path -LiteralPath $desktopFile) { [IO.File]::ReadAllText($desktopFile) } else { '' }
        Assert-True ($LASTEXITCODE -eq 0 -and $desktopText -match '(?m)^Exec=.*pwsh.*Start-WorkspaceShareGui\.ps1') 'Install-GuiShortcut -TargetDirectory creates workspaceshare.desktop (Exec uses pwsh)'
        & $psExe -NoLogo -NoProfile -File (Join-Path $ToolRoot 'Install-GuiShortcut.ps1') -Remove -TargetDirectory $lnkDir | Out-Null
        Assert-True (-not (Test-Path -LiteralPath $desktopFile)) 'Install-GuiShortcut -Remove deletes workspaceshare.desktop'
    }
    else {
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
    }

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
    $r = Invoke-Api -Method POST -Path '/api/shares/deadbeef/stop' -B $A -BodyText '{}'
    Assert-True ($r.Status -eq 401) 'POST /api/shares/<id>/stop without token -> 401'
    $r = Invoke-Api -Method OPTIONS -Path '/api/state' -B $A -Token $A.Token
    Assert-True ($r.Status -eq 405) 'OPTIONS /api/state -> 405'
    $r = Invoke-Api -Method GET -Path '/api/start' -B $A -Token $A.Token
    Assert-True ($r.Status -eq 405) 'GET /api/start -> 405'
    $r = Invoke-Api -Method POST -Path '/api/state' -B $A -Token $A.Token -BodyText '{}'
    Assert-True ($r.Status -eq 405) 'POST /api/state -> 405'
    $r = Invoke-Api -Method POST -Path '/api/nonexistent' -B $A -Token $A.Token -BodyText '{}'
    Assert-True ($r.Status -eq 404) 'unknown /api path with token -> 404'
    $r = Invoke-Post $A '/api/stop' $null
    Assert-True ($r.Status -eq 404) 'v1 endpoint POST /api/stop was removed -> 404'
    $r = Invoke-Post $A '/api/copy' $null
    Assert-True ($r.Status -eq 404) 'v1 endpoint POST /api/copy was removed -> 404'
    foreach ($action in 'stop', 'copy', 'rename', 'dismiss') {
        $r = Invoke-Post $A "/api/shares/deadbeef/$action" @{ name = 'x' }
        Assert-True ($r.Status -eq 404) "POST /api/shares/<unknown id>/$action -> 404"
    }
    $r = Invoke-Post $A '/api/shares/ZZZZ/stop' $null
    Assert-True ($r.Status -eq 404) 'malformed share id -> 404'
    $r = Invoke-Post $A '/api/shares/deadbeef/explode' $null
    Assert-True ($r.Status -eq 404) 'unknown share action -> 404'
    $r = Invoke-Api -Method GET -Path '/api/shares/deadbeef/rename' -B $A -Token $A.Token
    Assert-True ($r.Status -eq 405) 'GET on a share route -> 405'

    # idle state (v2)
    $r = Invoke-Api -Path '/api/state' -B $A -Token $A.Token
    $s = $r.Json
    Assert-True ($r.Status -eq 200 -and $s.v -eq 2 -and $s.platform -eq $(if ($isWin) { 'windows' } else { 'linux' }) -and $s.running -eq 0 -and @($s.shares).Count -eq 0) '/api/state with token -> 200, state v2, no shares, running 0'
    Assert-True ($null -eq $s.PSObject.Properties['phase'] -and $null -eq $s.PSObject.Properties['url'] -and $null -eq $s.PSObject.Properties['drop']) 'state v2 has no top-level phase/url/drop (they live in shares[] and draft)'
    Assert-True ($null -ne $s.capabilities -and $null -ne $s.capabilities.folderPicker -and $null -ne $s.capabilities.clipboard -and $null -ne $s.capabilities.openBrowser) 'state has capabilities'
    Assert-True ($null -ne $s.draft -and $null -eq $s.draft.drop -and $s.limits.maxDropBytes -eq 4GB -and $s.limits.maxDropFiles -eq 10000 -and $s.limits.maxShares -eq 5) 'idle state: draft.drop is null, limits carry the defaults (4 GiB, 10000 files, 5 shares)'
    Assert-True ($s.build -match '^[0-9a-f]{16}$') 'state carries the build id'

    # invalid start input
    $bad = @(
        @{ n = 'minutes 0'; b = (New-StartBody $shareDir 0) },
        @{ n = 'minutes 1441'; b = (New-StartBody $shareDir 1441) },
        @{ n = 'minutes "x"'; b = (New-StartBody $shareDir 'x') },
        @{ n = 'minutes 1.5'; b = (New-StartBody $shareDir 1.5) },
        @{ n = 'nonexistent path'; b = (New-StartBody (Join-Path $tmp 'gibt-es-nicht') 5) },
        @{ n = 'path is a file'; b = (New-StartBody (Join-Path $shareDir 'a.txt') 5) },
        @{ n = 'compression Zip'; b = (New-StartBody $shareDir 5 'Zip') },
        @{ n = 'includeGenerated "yes"'; b = (New-StartBody $shareDir 5 'Fast' 'yes') },
        @{ n = 'name of 61 characters'; b = ([ordered]@{ path = $shareDir; minutes = 5; compression = 'Fast'; includeGenerated = $false; name = ('n' * 61) }) },
        @{ n = 'name with a control character'; b = ([ordered]@{ path = $shareDir; minutes = 5; compression = 'Fast'; includeGenerated = $false; name = ('a' + [char]7 + 'b') }) },
        @{ n = 'name that is not a string'; b = ([ordered]@{ path = $shareDir; minutes = 5; compression = 'Fast'; includeGenerated = $false; name = 42 }) }
    )
    foreach ($case in $bad) {
        $r = Invoke-Post $A '/api/start' $case.b
        Assert-True ($r.Status -eq 400 -and $null -ne $r.Json -and [string]$r.Json.error) "/api/start with $($case.n) -> 400 with error text"
    }
    $r = Invoke-Api -Method POST -Path '/api/start' -B $A -Token $A.Token -BodyText 'kein json'
    Assert-True ($r.Status -eq 400) '/api/start with invalid JSON -> 400'
    $s = Get-State $A
    Assert-True ($s.running -eq 0 -and @($s.shares).Count -eq 0) 'rejected starts create no share'

    # valid start
    $st = Start-Share $A $shareDir 5 'Fast' $false
    Assert-True ($st.Status -eq 200 -and $st.R.Json.ok -eq $true -and $st.Id -match '^[0-9a-f]{8}$') '/api/start with valid input -> 200 {ok, shareId (8 hex)}'
    $idA1 = $st.Id
    $s = Get-State $A
    $shA1 = Get-ShareFromState $s $idA1
    Assert-True ($null -ne $shA1 -and $shA1.phase -in @('starting', 'active') -and $s.running -eq 1) 'the new share is listed at once (starting/active), running 1'
    $sh = Wait-ForShare $A $idA1 { param($x) $x.phase -eq 'active' }
    Assert-True ($null -ne $sh) 'phase becomes active within 20 s'
    if ($null -ne $sh) {
        Assert-True ($sh.url -match '^https://fake-test\.trycloudflare\.com/d/[A-Za-z0-9]{43}/$') 'active share carries the link'
        Assert-True (@($sh.steps).Count -eq 8 -and $sh.step -eq 8 -and $sh.total -eq 8) 'share lists all 8 steps'
        Assert-True ((@($sh.steps) | Where-Object { $_.n -eq 3 }).text -eq 'Snapshot wird erstellt ...') 'step text with umlauts is decoded correctly'
        Assert-True ($sh.sizeBytes -eq 1234 -and $sh.sha256 -eq ('A' * 64) -and $sh.expiresUtc) 'ready fields: sizeBytes, sha256, expiresUtc'
        Assert-True ($sh.request.minutes -eq 5 -and $sh.request.path -eq $shareDir -and $sh.request.compression -eq 'Fast' -and $sh.request.includeGenerated -eq $false) 'share echoes the request'
        Assert-True ($sh.name -ceq 'ws share ä' -and $null -eq $sh.dropFiles -and [datetime]::Parse([string]$sh.createdUtc).Year -ge 2026) 'default name is the folder leaf name; dropFiles null; createdUtc set'
        # The plain lines follow the ready event closely; wait until the last one is drained.
        $sh2 = Wait-ForShare $A $idA1 { param($x) @($x.log) -like 'Link-Test:*' } 8
        if ($null -ne $sh2) { $sh = $sh2 }
        $logLines = @($sh.log)
        Assert-True ($logLines -ccontains 'Normale Ausgabe mit Umlauten: äöü') 'stdout log line with umlauts is decoded correctly'
        Assert-True ($logLines -ccontains 'Hinweis auf stderr: äöü') 'stderr line is logged'
        Assert-True ($logLines -ccontains ('Pfad=' + $shareDir)) 'path with spaces and umlaut reaches the child intact'
        $linkLine = @($logLines | Where-Object { $_ -like 'Link-Test:*' })
        Assert-True ($linkLine.Count -eq 1 -and $linkLine[0] -notlike '*qqqqqqqqqq*' -and $linkLine[0] -like '*<redacted>*') 'log redacts the link'
        Assert-True (@($logLines | Where-Object { $_ -like '*@@WSEVENT@@*' }).Count -eq 0) 'event lines are not part of the log'
    }
    $sh = Wait-ForShare $A $idA1 { param($x) $null -ne $x.remainingMinutes } 8
    Assert-True ($null -ne $sh) 'status event updates remainingMinutes'

    $copyOk = $false
    $caps = (Get-State $A).capabilities
    if ($caps.clipboard) {
        $r = Invoke-Post $A "/api/shares/$idA1/copy" $null
        $copyOk = ($r.Status -eq 200)
        Assert-True $copyOk '/api/shares/<id>/copy -> 200 while the link is available'
    }
    else { Write-Host '[NOTE] clipboard capability is false; copy check skipped' }

    $fakeA = @(Get-Fakes $A)
    $fakePidA = $null
    $sessionDirA = $null
    if ($fakeA.Count -ge 1) { $fakePidA = $fakeA[0].Pid; $sessionDirA = $fakeA[0].Session }
    Assert-True ($fakePidA -and (Test-PidAlive $fakePidA) -and $sessionDirA -and (Test-Path -LiteralPath $sessionDirA)) 'fake share process and its session folder exist'

    # single instance: second backend with the same instance file exits 0 quickly, file unchanged
    $before = [IO.File]::ReadAllText($A.Instance)
    $argText = '-NoLogo -NoProfile -STA -File "{0}" -TestMode -NoBrowser -InstanceFile "{1}" -TestShareScript "{2}" -DataRootOverride "{3}"' -f $startScript, $A.Instance, $fakeScript, $A.DataRoot
    if (-not $isWin) { $argText = $argText.Replace(' -STA', '') }
    $second = Start-Process -FilePath $psExe -ArgumentList $argText -PassThru @hiddenWindow
    $null = $second.Handle
    $secondExited = $second.WaitForExit(10000)
    Assert-True ($secondExited -and $second.ExitCode -eq 0) 'second backend with the same instance file exits 0 within 10 s'
    if (-not $secondExited) { try { $second.Kill() } catch { } }
    Assert-True (([IO.File]::ReadAllText($A.Instance)) -ceq $before) 'second backend leaves the instance file unchanged'
    Assert-True (-not $A.Proc.HasExited) 'first backend is still running'

    # stop
    $r = Invoke-Post $A "/api/shares/$idA1/stop" $null
    Assert-True ($r.Status -eq 200 -and $r.Json.ok -eq $true) '/api/shares/<id>/stop -> 200'
    $r2 = Invoke-Post $A "/api/shares/$idA1/stop" $null
    $shNow = Get-ShareFromState (Get-State $A) $idA1
    Assert-True ($r2.Status -eq 200 -or ($r2.Status -eq 409 -and $shNow.phase -eq 'ended')) 'a second stop is idempotent while stopping (409 only once the share has ended)'
    $sh = Wait-ForShare $A $idA1 { param($x) $x.phase -eq 'ended' }
    Assert-True ($null -ne $sh) 'phase becomes ended after stop'
    if ($null -ne $sh) {
        Assert-True ($null -eq $sh.url) 'link is gone after the share ended'
        Assert-True ($sh.reason -eq 'ManualStop' -and $sh.exitCode -eq 0) 'ended with reason ManualStop and exit code 0'
    }
    Assert-True ($sessionDirA -and -not (Test-Path -LiteralPath $sessionDirA)) 'stop.requested reached the session (fake cleaned its folder)'
    Assert-True (Wait-Until -TimeoutSec 5 -Condition { -not (Test-PidAlive $fakePidA) }) 'fake share process has exited'
    $r = Invoke-Post $A "/api/shares/$idA1/stop" $null
    Assert-True ($r.Status -eq 409) 'stop after the end -> 409'
    $r = Invoke-Post $A "/api/shares/$idA1/copy" $null
    Assert-True ($r.Status -eq 409) 'copy after the end -> 409'
    Assert-True ((Get-State $A).running -eq 0 -and $null -ne (Get-ShareFromState (Get-State $A) $idA1)) 'an ended share stays listed until it is dismissed; running is 0'

    # a new start creates a new share (the ended one stays); quit with a running share stops it first
    $st = Start-Share $A $shareDir 2 'Store' $true
    Assert-True ($st.Status -eq 200 -and $st.Id -ne $idA1) 'new start after an ended share -> 200 with a new shareId'
    $idA2 = $st.Id
    $s = Get-State $A
    $shA2 = Get-ShareFromState $s $idA2
    Assert-True (@($s.shares).Count -eq 2 -and @($s.shares)[0].id -eq $idA1 -and @($s.shares)[1].id -eq $idA2) 'shares are ordered by creation (oldest first)'
    Assert-True ($shA2.phase -in @('starting', 'active') -and $null -eq $shA2.exitCode -and $null -eq $shA2.reason -and $shA2.request.compression -eq 'Store' -and $shA2.request.includeGenerated -eq $true) 'the new share starts with a clean state and its own request'
    $sh = Wait-ForShare $A $idA2 { param($x) $x.phase -eq 'active' }
    Assert-True ($null -ne $sh) 'second share becomes active'
    $fakePidA2 = Get-FakePid $A
    Test-GuiQuit $A 'A (running share)'
    Assert-True (Wait-Until -TimeoutSec 5 -Condition { -not (Test-PidAlive $fakePidA2) }) 'quit stopped the running share (fake process gone)'
    if ($copyOk) {
        $clip = (& $psExe -NoLogo -NoProfile -STA -Command 'Add-Type -AssemblyName System.Windows.Forms; [System.Windows.Forms.Clipboard]::GetText()') -join ''
        Assert-True ($clip -notlike '*fake-test.trycloudflare.com*') 'the copied link was cleared from the clipboard when its share ended'
    }

    # ================= backend B: fail22
    $B = Start-TestBackend -Scenario 'fail22' -Name 'B'
    if ($B.Port -le 0) { throw 'Backend B did not start.' }
    $st = Start-Share $B $shareDir 5
    Assert-True ($st.Status -eq 200) 'B: start -> 200'
    $idB1 = $st.Id
    $sh = Wait-ForShare $B $idB1 { param($x) $x.phase -eq 'error' }
    Assert-True ($null -ne $sh) 'B: phase becomes error'
    if ($null -ne $sh) {
        Assert-True ($sh.exitCode -eq 22 -and $sh.reason -eq 'Error') 'B: exit code 22 and reason Error'
        Assert-True ($sh.message -like '*.env*') 'B: message from the ended event'
        Assert-True ($null -eq $sh.url -and @($sh.steps).Count -eq 2) 'B: no link, 2 steps'
    }
    $st = Start-Share $B $shareDir 5
    Assert-True ($st.Status -eq 200 -and $st.Id -ne $idB1) 'B: a new start after an error -> 200 with a new share'
    $idB2 = $st.Id
    $sh = Wait-ForShare $B $idB2 { param($x) $x.phase -eq 'error' }
    Assert-True ($null -ne $sh -and $sh.exitCode -eq 22) 'B: second run fails with 22 again'
    Assert-True (@((Get-State $B).shares).Count -eq 2) 'B: both failed shares stay listed'
    $r = Invoke-Post $B "/api/shares/$idB1/dismiss" $null
    Assert-True ($r.Status -eq 200 -and $r.Json.ok -eq $true) 'B: dismiss of an error share -> 200'
    $s = Get-State $B
    Assert-True ($null -eq (Get-ShareFromState $s $idB1) -and $null -ne (Get-ShareFromState $s $idB2) -and @($s.shares).Count -eq 1) 'B: the dismissed share is gone from the list, the other one stays'
    Test-GuiQuit $B 'B (no running share)'

    # ================= backend C: hang (no session -> kill path)
    $C = Start-TestBackend -Scenario 'hang' -Name 'C'
    if ($C.Port -le 0) { throw 'Backend C did not start.' }
    $st = Start-Share $C $shareDir 5
    Assert-True ($st.Status -eq 200) 'C: start -> 200'
    $idC1 = $st.Id
    $sh = Wait-ForShare $C $idC1 { param($x) @($x.steps).Count -ge 1 }
    Assert-True ($null -ne $sh -and $sh.phase -eq 'starting') 'C: first step arrived, still starting'
    $fakePidC = Get-FakePid $C
    Assert-True ($fakePidC -and (Test-PidAlive $fakePidC)) 'C: fake process is running'
    $r = Invoke-Post $C "/api/shares/$idC1/stop" $null
    Assert-True ($r.Status -eq 200) 'C: stop before the session event -> 200'
    $sh = Wait-ForShare $C $idC1 { param($x) $x.phase -in @('ended', 'error') }
    Assert-True ($null -ne $sh -and $sh.phase -eq 'ended' -and $sh.reason -eq 'ManualStop') 'C: killed share ends as ManualStop'
    Assert-True (Wait-Until -TimeoutSec 5 -Condition { -not (Test-PidAlive $fakePidC) }) 'C: process was killed'
    Test-GuiQuit $C 'C'

    # ================= backend D: backend crash -> both children notice the missing parent
    $D = Start-TestBackend -Scenario 'parent' -Name 'D'
    if ($D.Port -le 0) { throw 'Backend D did not start.' }
    $dirD1 = New-ShareDir 'share-d1'
    $dirD2 = New-ShareDir 'share-d2'
    $stD1 = Start-Share $D $dirD1 5
    $stD2 = Start-Share $D $dirD2 5
    Assert-True ($stD1.Status -eq 200 -and $stD2.Status -eq 200 -and $stD1.Id -ne $stD2.Id) 'D: two shares start -> 200'
    $shD1 = Wait-ForShare $D $stD1.Id { param($x) $x.phase -eq 'active' }
    $shD2 = Wait-ForShare $D $stD2.Id { param($x) $x.phase -eq 'active' }
    $fakesD = @(Get-Fakes $D)
    Assert-True ($null -ne $shD1 -and $null -ne $shD2 -and $fakesD.Count -eq 2 -and (Test-PidAlive $fakesD[0].Pid) -and (Test-PidAlive $fakesD[1].Pid)) 'D: both shares active, two fake processes running'
    Stop-Process -Id $D.Proc.Id -Force
    Assert-True (Wait-Until -TimeoutSec 15 -Condition { -not (Test-PidAlive $fakesD[0].Pid) -and -not (Test-PidAlive $fakesD[1].Pid) }) 'D: both fake shares exit within 15 s after the backend was killed'

    # ================= -DataRootOverride is a test-only parameter
    $p = Start-Process -FilePath $psExe -ArgumentList ('-NoLogo -NoProfile -File "{0}" -DataRootOverride "{1}" -NoBrowser' -f $startScript, (Join-Path $tmp 'data-x')) -PassThru @hiddenWindow -Wait
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
    Assert-True ($s.running -eq 0 -and $null -eq $s.draft.drop -and $s.limits.maxDropBytes -eq 4GB) 'E: idle, no drop'

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
    Assert-True ($null -ne $s.draft.drop -and $s.draft.drop.id -eq $drop1 -and $s.draft.drop.path -eq $leaf1 -and $s.draft.drop.files -eq 0 -and $s.draft.drop.finished -eq $false) 'E: state.draft.drop after begin (unfinished, 0 files)'
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
    Assert-True ($s.draft.drop.files -eq 3 -and $s.draft.drop.finished -eq $false -and $s.draft.drop.totalBytes -eq (1234 + ([IO.FileInfo]$srcUml).Length + 5242880)) 'E: state.draft.drop counts files and bytes while unfinished'
    $r = Invoke-Post $E '/api/drop/finish' @{ dropId = $drop1 }
    $expectedTotal = 1234 + ([IO.FileInfo]$srcUml).Length + 5242880
    Assert-True ($r.Status -eq 200 -and $r.Json.path -eq $leaf1 -and $r.Json.files -eq 3 -and $r.Json.totalBytes -eq $expectedTotal) 'E: drop/finish -> path, files 3, totalBytes'
    Assert-True ((Test-Path -LiteralPath (Join-Path (Join-Path (Join-Path $leaf1 'sub') 'ordner') 'c.bin')) -and (Test-Path -LiteralPath (Join-Path $leaf1 'Bericht ä.txt')) -and (Test-Path -LiteralPath (Join-Path $leaf1 'big.bin'))) 'E: all three files exist in the drop folder with their relative paths'
    Assert-True ((Get-FileSha (Join-Path $leaf1 'big.bin')) -eq (Get-FileSha $srcBig) -and (Get-FileSha (Join-Path (Join-Path (Join-Path $leaf1 'sub') 'ordner') 'c.bin')) -eq (Get-FileSha $srcC) -and (Get-FileSha (Join-Path $leaf1 'Bericht ä.txt')) -eq (Get-FileSha $srcUml)) 'E: uploaded files are bit-identical (SHA-256)'
    Assert-True ((Get-FileCount $dropsE) -eq 3) 'E: exactly three files below drops'
    $s = Get-State $E
    Assert-True ($s.draft.drop.finished -eq $true -and $s.draft.drop.files -eq 3 -and $s.draft.drop.totalBytes -eq $expectedTotal -and $s.draft.drop.path -eq $leaf1) 'E: state.draft.drop finished with path, files, totalBytes'
    $r = Invoke-Upload $E $drop1 'late.txt' $srcTiny
    Assert-True ($r.Status -eq 409 -and -not (Test-Path -LiteralPath (Join-Path $leaf1 'late.txt'))) 'E: upload into a finished drop -> 409'

    # /api/start: only the finished drop may be shared from inside the drops folder
    $r = Invoke-Post $E '/api/start' (New-StartBody $dropsE 5)
    Assert-True ($r.Status -eq 400) 'E: /api/start with the drops root itself -> 400'
    $r = Invoke-Post $E '/api/start' (New-StartBody (Join-Path $leaf1 'sub') 5)
    Assert-True ($r.Status -eq 400) 'E: /api/start with a sub folder of the drop -> 400'
    $r = Invoke-Post $E '/api/start' (New-StartBody $drop1Root 5)
    Assert-True ($r.Status -eq 400) 'E: /api/start with the drop id folder (not the leaf) -> 400'
    Assert-True ((Get-State $E).running -eq 0 -and @((Get-State $E).shares).Count -eq 0) 'E: rejected drop starts create no share'

    # share the drop: active -> stop -> ended -> drop deleted
    $stE = Start-Share $E $leaf1 5
    Assert-True ($stE.Status -eq 200) 'E: /api/start with the finished drop path -> 200'
    $idE1 = $stE.Id
    $sh = Wait-ForShare $E $idE1 { param($x) $x.phase -eq 'active' }
    Assert-True ($null -ne $sh) 'E: share of the drop becomes active'
    if ($null -ne $sh) {
        $s = Get-State $E
        Assert-True ($null -eq $s.draft.drop -and $sh.dropFiles -eq 3 -and $sh.name -ceq 'sub +2' -and (Test-Path -LiteralPath (Join-Path $leaf1 'big.bin'))) 'E: the drop moved from the draft to the share (name "sub +2", dropFiles 3) and stays in place while it runs'
        $sh2 = Wait-ForShare $E $idE1 { param($x) @($x.log) -like 'Pfad=*' } 8
        Assert-True ($null -ne $sh2 -and @($sh2.log) -ccontains ('Pfad=' + $leaf1)) 'E: the share process received the drop folder as -Path'
    }
    $r = Invoke-Post $E '/api/start' (New-StartBody $leaf1 5)
    Assert-True ($r.Status -eq 400) 'E: the drop folder of a running share cannot be started again -> 400'
    # drops are allowed while a share runs; the running share's drop is no draft any more
    $r = Invoke-Upload $E $drop1 'x.txt' $srcTiny
    Assert-True ($r.Status -eq 400 -and -not (Test-Path -LiteralPath (Join-Path $leaf1 'x.txt'))) 'E: upload into the drop of a running share -> 400'
    $r = Invoke-Post $E '/api/drop/discard' @{ dropId = $drop1 }
    Assert-True ($r.Status -eq 400 -and (Test-Path -LiteralPath $leaf1)) 'E: drop/discard of a running share''s drop -> 400, folder stays'
    $r = Invoke-Post $E '/api/drop/begin' $null
    Assert-True ($r.Status -eq 200) 'E: drop/begin while a share runs -> 200'
    $dropWhile = [string]$r.Json.dropId
    $r = Invoke-Upload $E $dropWhile 'while.txt' $srcTiny
    Assert-True ($r.Status -eq 200) 'E: upload while a share runs -> 200'
    $r = Invoke-Post $E '/api/drop/discard' @{ dropId = $dropWhile }
    Assert-True ($r.Status -eq 200 -and (Test-Path -LiteralPath $leaf1) -and -not (Test-Path -LiteralPath (Join-Path $dropsE $dropWhile))) 'E: discarding the draft leaves the drop of the running share alone'
    $r = Invoke-Post $E "/api/shares/$idE1/stop" $null
    Assert-True ($r.Status -eq 200) 'E: stop the drop share'
    $sh = Wait-ForShare $E $idE1 { param($x) $x.phase -eq 'ended' }
    Assert-True ($null -ne $sh) 'E: drop share ends'
    Assert-True (Wait-Until -TimeoutSec 10 -Condition { -not (Test-Path -LiteralPath $drop1Root) }) 'E: drop folder is deleted after the share ended'
    $s = Get-State $E
    Assert-True ($null -eq $s.draft.drop) 'E: draft.drop is null after the share ended'

    # path validation on an unfinished drop
    $r = Invoke-Post $E '/api/drop/begin' $null
    $drop2 = [string]$r.Json.dropId
    $drop2Root = Join-Path $dropsE $drop2
    $leaf2 = [string](Get-State $E).draft.drop.path
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
    Assert-True ($s.draft.drop.id -eq $drop3 -and $s.draft.drop.files -eq 0) 'E: state.draft.drop describes the new drop'
    $r = Invoke-Upload $E $drop2 'old.txt' $srcTiny
    Assert-True ($r.Status -eq 400) 'E: upload into the discarded drop id -> 400'

    # discard
    $drop3Root = Join-Path $dropsE $drop3
    $r = Invoke-Upload $E $drop3 'a.txt' $srcTiny
    Assert-True ($r.Status -eq 200 -and (Get-FileCount $drop3Root) -eq 1) 'E: upload into drop 3'
    $r = Invoke-Post $E '/api/drop/discard' @{ dropId = $drop3 }
    Assert-True ($r.Status -eq 200 -and $r.Json.ok -eq $true) 'E: drop/discard -> 200'
    Assert-True (-not (Test-Path -LiteralPath $drop3Root) -and $null -eq (Get-State $E).draft.drop) 'E: discard deletes the folder and clears state.draft.drop'
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
    Assert-True ($s.limits.maxDropBytes -eq 1048576 -and $s.limits.maxDropFiles -eq 2 -and $s.limits.maxShares -eq 5) 'F: state.limits reflect the parameters'
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

    # ================= build id and static cache (backend G runs from a copy of the repo)
    $p = Start-Process -FilePath $psExe -ArgumentList ('-NoLogo -NoProfile -File "{0}" -TestBuildId abc -NoBrowser' -f $startScript) -PassThru @hiddenWindow -Wait
    Assert-True ($p.ExitCode -eq 10) '-TestBuildId without -TestMode exits with 10'
    $copyRoot = Join-Path $tmp 'repo-copy'
    [void](New-Item -ItemType Directory -Path (Join-Path $copyRoot 'scripts') -Force)
    [void](New-Item -ItemType Directory -Path (Join-Path $copyRoot 'gui') -Force)
    foreach ($f in @('VERSION', 'Start-WorkspaceShareGui.ps1')) { Copy-Item -LiteralPath (Join-Path $ToolRoot $f) -Destination $copyRoot }
    Copy-Item -Path (Join-Path $ToolRoot 'scripts\*.psm1') -Destination (Join-Path $copyRoot 'scripts')
    Copy-Item -Path (Join-Path $ToolRoot 'gui\*') -Destination (Join-Path $copyRoot 'gui')
    Remove-Item -LiteralPath (Join-Path (Join-Path $copyRoot 'gui') 'favicon.svg') -Force   # a missing file contributes its name only
    $copyApp = Join-Path (Join-Path $copyRoot 'gui') 'app.js'
    $copyCss = Join-Path (Join-Path $copyRoot 'gui') 'app.css'
    $appShaAtStart = Get-FileSha $copyApp
    $expectedBuild = Get-ExpectedBuild $copyRoot
    $G = Start-TestBackend -Scenario 'success' -Name 'G' -StartScriptPath (Join-Path $copyRoot 'Start-WorkspaceShareGui.ps1')
    if ($G.Port -le 0) { throw 'Backend G did not start.' }
    $instG = [IO.File]::ReadAllText($G.Instance) | ConvertFrom-Json
    $sG = Get-State $G
    Assert-True ($expectedBuild -match '^[0-9a-f]{16}$' -and [string]$instG.build -ceq $expectedBuild) 'G: instance file build = first 16 hex of SHA-256 over the version files'
    Assert-True ($sG.build -ceq $expectedBuild) 'G: /api/state carries the same build'
    $dl = Join-Path $tmp 'dl-app.js'
    $code = Get-StaticFile $G '/app.js' $dl
    Assert-True ($code -eq 200 -and (Get-FileSha $dl) -eq $appShaAtStart) 'G: GET /app.js returns exactly the bytes of the file at start'
    Assert-True ((Get-StaticFile $G '/favicon.svg' (Join-Path $tmp 'dl-fav.svg')) -eq 404) 'G: a file missing at start -> 404'
    # Update on disk after the start: the running backend keeps serving the version it started with.
    [IO.File]::AppendAllText($copyApp, "`n// changed after start`n", $utf8)
    Remove-Item -LiteralPath $copyCss -Force
    $code = Get-StaticFile $G '/app.js' $dl
    Assert-True ($code -eq 200 -and (Get-FileSha $dl) -eq $appShaAtStart -and (Get-FileSha $dl) -ne (Get-FileSha $copyApp)) 'G: /app.js stays the cached start version after the file changed on disk'
    Assert-True ((Get-StaticFile $G '/app.css' (Join-Path $tmp 'dl-app.css')) -eq 200) 'G: /app.css is still served after the file was deleted from disk'
    Assert-True ((Get-StaticFile $G '/' (Join-Path $tmp 'dl-index.html')) -eq 200) 'G: GET / is served from the cache'
    Test-GuiQuit $G 'G'

    # ================= update takeover (GUI_CONTRACT section 5): -TestBuildId simulates two versions
    # (a) older backend idle -> the newer start quits it and takes over
    $instTk = Join-Path $tmp 'gui-takeover.json'
    $dataTk = Join-Path $tmp 'data-takeover'
    $TA = Start-TestBackend -Scenario 'success' -Name 'TA' -InstanceFile $instTk -DataRoot $dataTk -ExtraArgs '-TestBuildId aaaa'
    if ($TA.Port -le 0) { throw 'Backend TA did not start.' }
    $instTA = [IO.File]::ReadAllText($instTk) | ConvertFrom-Json
    Assert-True ([string]$instTA.build -ceq 'aaaa' -and (Get-State $TA).build -ceq 'aaaa' -and (Get-State $TA).running -eq 0) 'takeover: backend A (build aaaa) is idle and reports its build'
    $TB = Start-TestBackend -Scenario 'success' -Name 'TB' -InstanceFile $instTk -DataRoot $dataTk -ExtraArgs '-TestBuildId bbbb' -NoWait
    $aGone = $TA.Proc.WaitForExit(20000)
    Assert-True $aGone 'takeover: idle backend A exits within 20 s after the start of build bbbb'
    $took = Wait-Until -TimeoutSec 25 -Condition {
        if ($TB.Proc.HasExited) { return $true }
        if (-not (Test-Path -LiteralPath $instTk)) { return $false }
        $o = ([IO.File]::ReadAllText($instTk)) | ConvertFrom-Json
        return ([int]$o.pid -eq $TB.Proc.Id -and $o.token)
    }
    $instTB = $null
    if ($took -and -not $TB.Proc.HasExited) {
        $instTB = [IO.File]::ReadAllText($instTk) | ConvertFrom-Json
        $TB.Port = [int]$instTB.port
        $TB.Token = [string]$instTB.token
    }
    Assert-True ($null -ne $instTB -and [int]$instTB.pid -eq $TB.Proc.Id -and [string]$instTB.build -ceq 'bbbb') 'takeover: instance file now holds backend B (pid, build bbbb)'
    if ($null -ne $instTB) {
        $sTB = Get-State $TB
        Assert-True ($null -ne $sTB -and $sTB.build -ceq 'bbbb' -and $sTB.running -eq 0) 'takeover: B serves /api/state with build bbbb'
        Test-GuiQuit $TB 'takeover B'
    }

    # (b) + (c) running share keeps its backend; same build only reopens
    $instBz = Join-Path $tmp 'gui-busy.json'
    $dataBz = Join-Path $tmp 'data-busy'
    $BA = Start-TestBackend -Scenario 'success' -Name 'BA' -InstanceFile $instBz -DataRoot $dataBz -ExtraArgs '-TestBuildId aaaa'
    if ($BA.Port -le 0) { throw 'Backend BA did not start.' }
    $stBA = Start-Share $BA $shareDir 5
    $s = Wait-ForShare $BA $stBA.Id { param($x) $x.phase -eq 'active' }
    Assert-True ($stBA.Status -eq 200 -and $null -ne $s) 'busy: backend A (build aaaa) has an active share'
    $beforeBz = [IO.File]::ReadAllText($instBz)
    $BC = Start-TestBackend -Scenario 'success' -Name 'BC' -InstanceFile $instBz -DataRoot $dataBz -ExtraArgs '-TestBuildId aaaa' -NoWait
    $cExit = $BC.Proc.WaitForExit(10000)
    Assert-True ($cExit -and $BC.Proc.ExitCode -eq 0) 'same build: second start exits 0 within 10 s'
    if (-not $cExit) { try { $BC.Proc.Kill() } catch { } }
    Assert-True (([IO.File]::ReadAllText($instBz)) -ceq $beforeBz -and -not $BA.Proc.HasExited -and (Get-ShareFromState (Get-State $BA) $stBA.Id).phase -eq 'active') 'same build: instance file unchanged, A keeps running its share'
    $BB = Start-TestBackend -Scenario 'success' -Name 'BB' -InstanceFile $instBz -DataRoot $dataBz -ExtraArgs '-TestBuildId bbbb' -NoWait
    $bExit = $BB.Proc.WaitForExit(15000)
    Assert-True ($bExit -and $BB.Proc.ExitCode -eq 0) 'busy: newer start while a share is active exits 0 within 15 s'
    if (-not $bExit) { try { $BB.Proc.Kill() } catch { } }
    $bbOut = ''
    if (Test-Path -LiteralPath $BB.Out) { $bbOut = [IO.File]::ReadAllText($BB.Out) }
    Assert-True ($bbOut -like '*nutzt noch die vorherige Version*') 'busy: console tells that the running share still uses the previous version'
    $sBz = Get-State $BA
    Assert-True (-not $BA.Proc.HasExited -and $null -ne $sBz -and $sBz.running -eq 1 -and (Get-ShareFromState $sBz $stBA.Id).phase -eq 'active' -and $sBz.build -ceq 'aaaa') 'busy: backend A is still alive and its share still active'
    Assert-True (([IO.File]::ReadAllText($instBz)) -ceq $beforeBz) 'busy: instance file unchanged'
    Test-GuiQuit $BA 'busy A'

    # ================= several shares at the same time (GUI_CONTRACT section 8)
    foreach ($mx in @('0', '11', '-3')) {
        $p = Start-Process -FilePath $psExe -ArgumentList ('-NoLogo -NoProfile -File "{0}" -TestMode -NoBrowser -MaxShares {1}' -f $startScript, $mx) -PassThru @hiddenWindow -Wait
        Assert-True ($p.ExitCode -eq 10) "-MaxShares $mx exits with 10 (allowed range 1..10)"
    }
    $p = Start-Process -FilePath $psExe -ArgumentList ('-NoLogo -NoProfile -File "{0}" -TestPickerResult "0:" -NoBrowser' -f $startScript) -PassThru @hiddenWindow -Wait
    Assert-True ($p.ExitCode -eq 10) '-TestPickerResult without -TestMode exits with 10'

    $srcTinyN = Join-Path $tmp 'src-tiny-n.txt'
    [IO.File]::WriteAllText($srcTinyN, 'tiny', $utf8)

    function New-DropShare {
        # begin -> upload tiny files for the given relative paths -> finish -> start a share from the drop folder.
        param($B, [string[]]$RelPaths, $Name = $null)
        $r = Invoke-Post $B '/api/drop/begin' $null
        $dropId = [string]$r.Json.dropId
        $allOk = ($r.Status -eq 200)
        foreach ($rel in $RelPaths) {
            $u = Invoke-Upload $B $dropId $rel $srcTinyN
            if ($u.Status -ne 200) { $allOk = $false }
        }
        $f = Invoke-Post $B '/api/drop/finish' @{ dropId = $dropId }
        $leaf = [string]$f.Json.path
        $st = Start-Share $B $leaf 5 'Fast' $false $Name
        return [pscustomobject]@{ Id = $st.Id; Status = $st.Status; UploadsOk = $allOk -and ($f.Status -eq 200); DropId = $dropId; Leaf = $leaf; Root = (Split-Path -Parent $leaf) }
    }

    # ---- backend N: default names, drops that belong to shares, 5 shares in parallel
    $N = Start-TestBackend -Scenario 'success' -Name 'N'
    if ($N.Port -le 0) { throw 'Backend N did not start.' }
    $dropsN = Join-Path $N.DataRoot 'drops'
    $dirN = New-ShareDir 'Mein Projekt'

    $n1 = New-DropShare $N @('Bericht.pdf')
    Assert-True ($n1.UploadsOk -and $n1.Status -eq 200 -and $n1.Id) 'N: a single dropped file starts a share'
    $shN1 = Wait-ForShare $N $n1.Id { param($x) $x.phase -eq 'active' }
    Assert-True ($null -ne $shN1 -and $shN1.name -ceq 'Bericht.pdf' -and $shN1.dropFiles -eq 1) 'N: default name of a single dropped file is the file name (dropFiles 1)'
    $sN = Get-State $N
    Assert-True ($null -eq $sN.draft.drop -and (Test-Path -LiteralPath $n1.Leaf)) 'N: the draft is empty after the start and the drop folder now belongs to the share'

    # a drop while another share is active works, and the new share owns its drop
    $n2 = New-DropShare $N @('a.txt', 'b.txt', 'c.txt')
    Assert-True ($n2.UploadsOk -and $n2.Status -eq 200 -and $n2.Id) 'N: drop + start while another share is active works'
    $shN2 = Wait-ForShare $N $n2.Id { param($x) $x.phase -eq 'active' }
    Assert-True ($null -ne $shN2 -and $shN2.name -ceq 'a.txt +2' -and $shN2.dropFiles -eq 3) 'N: 3 dropped files -> default name "a.txt +2" (dropFiles 3)'
    Assert-True ((Test-Path -LiteralPath $n1.Leaf) -and (Test-Path -LiteralPath $n2.Leaf) -and $n1.Root -ne $n2.Root) 'N: both shares own their own drop folder'

    $n3 = New-DropShare $N @('Projekt/x.txt', 'Projekt/sub/y.txt')
    $shN3 = Wait-ForShare $N $n3.Id { param($x) $x.phase -eq 'active' }
    Assert-True ($null -ne $shN3 -and $shN3.name -ceq 'Projekt' -and $shN3.dropFiles -eq 2) 'N: a dropped folder -> default name is the folder name'

    $n4 = New-DropShare $N @('p.txt', 'q.txt') '  Eigener Name  '
    $shN4 = Wait-ForShare $N $n4.Id { param($x) $x.phase -eq 'active' }
    Assert-True ($null -ne $shN4 -and $shN4.name -ceq 'Eigener Name') 'N: a name sent by the client wins (and is trimmed)'

    $stN5 = Start-Share $N $dirN 5
    $shN5 = Wait-ForShare $N $stN5.Id { param($x) $x.phase -eq 'active' }
    Assert-True ($null -ne $shN5 -and $shN5.name -ceq 'Mein Projekt' -and $null -eq $shN5.dropFiles) 'N: a picked/typed folder -> default name is its leaf name'

    $sN = Get-State $N
    $ids = @($sN.shares | ForEach-Object { $_.id })
    $urls = @($sN.shares | ForEach-Object { $_.url })
    Assert-True ($sN.running -eq 5 -and @($sN.shares).Count -eq 5 -and @($ids | Select-Object -Unique).Count -eq 5 -and @($urls | Select-Object -Unique).Count -eq 5) 'N: five shares run in parallel with distinct shareIds and links'
    $stN6 = Start-Share $N $dirN 5
    Assert-True ($stN6.Status -eq 409 -and [string]$stN6.R.Json.error) 'N: the sixth start with the default -MaxShares 5 -> 409'
    $fakesN = @(Get-Fakes $N)
    Assert-True ($fakesN.Count -eq 5 -and @($fakesN | Where-Object { Test-PidAlive $_.Pid }).Count -eq 5) 'N: five fake share processes are running'

    # the drop of share 1 is deleted when share 1 ends while the other shares keep running
    $r = Invoke-Post $N "/api/shares/$($n1.Id)/stop" $null
    Assert-True ($r.Status -eq 200) 'N: stop share 1'
    $shN1 = Wait-ForShare $N $n1.Id { param($x) $x.phase -eq 'ended' }
    Assert-True ($null -ne $shN1) 'N: share 1 ends'
    Assert-True (Wait-Until -TimeoutSec 10 -Condition { -not (Test-Path -LiteralPath $n1.Root) }) 'N: the drop folder of share 1 is deleted when it ends'
    $sN = Get-State $N
    Assert-True ((Get-ShareFromState $sN $n2.Id).phase -eq 'active' -and (Get-ShareFromState $sN $n3.Id).phase -eq 'active' -and $sN.running -eq 4) 'N: the other shares are still active'
    Assert-True ((Test-Path -LiteralPath $n2.Leaf) -and (Test-Path -LiteralPath (Join-Path $n2.Leaf 'c.txt')) -and (Test-Path -LiteralPath $n3.Leaf)) 'N: the drop folders of the running shares are untouched'
    $f2 = Get-FakeByPath $N $n2.Leaf
    Assert-True ($null -ne $f2 -and (Test-PidAlive $f2.Pid)) 'N: the process of share 2 is still alive'
    # a finished drop path cannot be shared a second time, and a share's drop cannot be touched through the draft
    $stDup = Start-Share $N $n2.Leaf 5
    Assert-True ($stDup.Status -eq 400) 'N: the drop folder of a running share cannot be started again -> 400'
    $r = Invoke-Post $N '/api/drop/discard' @{ dropId = $n2.DropId }
    Assert-True ($r.Status -eq 400 -and (Test-Path -LiteralPath $n2.Leaf)) 'N: a share''s drop cannot be discarded through the draft (400, folder stays)'
    $r = Invoke-Upload $N $n2.DropId 'late.txt' $srcTinyN
    Assert-True ($r.Status -eq 400 -and -not (Test-Path -LiteralPath (Join-Path $n2.Leaf 'late.txt'))) 'N: no upload into a share''s drop (400)'
    # the draft: begin works while shares run; a start frees the slot of share 1 again
    $r = Invoke-Post $N '/api/drop/begin' $null
    $draftN = [string]$r.Json.dropId
    $u = Invoke-Upload $N $draftN 'draft.txt' $srcTinyN
    $sN = Get-State $N
    Assert-True ($r.Status -eq 200 -and $u.Status -eq 200 -and $sN.draft.drop.id -eq $draftN -and $sN.draft.drop.files -eq 1 -and $sN.draft.drop.finished -eq $false) 'N: the draft collects files while four shares run (state.draft.drop)'
    $draftRoot = Join-Path $dropsN $draftN
    Test-GuiQuit $N 'N (4 active shares + a draft drop)'
    Assert-True (@(Get-Fakes $N | Where-Object { Test-PidAlive $_.Pid }).Count -eq 0) 'N: quit stopped all four running shares'
    Assert-True ((Get-FileCount $dropsN) -eq 0 -and -not (Test-Path -LiteralPath $draftRoot)) 'N: quit removed the draft drop and the drops of all shares'

    # ---- backend M: -MaxShares 2, rename, dismiss, quit with two active shares
    $M = Start-TestBackend -Scenario 'success' -Name 'M' -ExtraArgs '-MaxShares 2'
    if ($M.Port -le 0) { throw 'Backend M did not start.' }
    Assert-True ((Get-State $M).limits.maxShares -eq 2) 'M: state.limits.maxShares reflects -MaxShares 2'
    $dirM1 = New-ShareDir 'one'
    $dirM2 = New-ShareDir 'two'
    $dirM3 = New-ShareDir 'three'
    $stM1 = Start-Share $M $dirM1 5
    $stM2 = Start-Share $M $dirM2 5
    Assert-True ($stM1.Status -eq 200 -and $stM2.Status -eq 200 -and $stM1.Id -ne $stM2.Id) 'M: two shares started in parallel -> 200 with distinct shareIds'
    $stM3 = Start-Share $M $dirM3 5
    Assert-True ($stM3.Status -eq 409 -and [string]$stM3.R.Json.error) 'M: a third start with -MaxShares 2 -> 409'
    $shM1 = Wait-ForShare $M $stM1.Id { param($x) $x.phase -eq 'active' }
    $shM2 = Wait-ForShare $M $stM2.Id { param($x) $x.phase -eq 'active' }
    Assert-True ($null -ne $shM1 -and $null -ne $shM2) 'M: both shares reach active'
    if ($null -ne $shM1 -and $null -ne $shM2) {
        Assert-True ($shM1.url -ne $shM2.url -and $shM1.url -match '^https://' -and $shM2.url -match '^https://') 'M: the two shares have distinct links'
        Assert-True ($shM1.name -ceq 'one' -and $shM2.name -ceq 'two') 'M: default names are the folder leaf names'
    }
    $sM = Get-State $M
    Assert-True ($sM.running -eq 2 -and @($sM.shares).Count -eq 2 -and [datetime]::Parse([string]@($sM.shares)[0].createdUtc) -le [datetime]::Parse([string]@($sM.shares)[1].createdUtc) -and @($sM.shares)[0].id -eq $stM1.Id) 'M: running 2, shares ordered by creation time'
    $fM1 = Get-FakeByPath $M $dirM1
    $fM2 = Get-FakeByPath $M $dirM2
    Assert-True ($null -ne $fM1 -and $null -ne $fM2 -and $fM1.Pid -ne $fM2.Pid -and $fM1.Session -ne $fM2.Session) 'M: two fake processes with their own session folders'

    # dismiss is refused while a share runs
    $r = Invoke-Post $M "/api/shares/$($stM1.Id)/dismiss" $null
    Assert-True ($r.Status -eq 409) 'M: dismiss of an active share -> 409'

    # stop one share: the other one stays active
    $r = Invoke-Post $M "/api/shares/$($stM1.Id)/stop" $null
    Assert-True ($r.Status -eq 200) 'M: stop share one'
    $shM1 = Wait-ForShare $M $stM1.Id { param($x) $x.phase -eq 'ended' }
    Assert-True ($null -ne $shM1 -and $shM1.reason -eq 'ManualStop') 'M: share one ends'
    Assert-True ((Wait-Until -TimeoutSec 5 -Condition { -not (Test-PidAlive $fM1.Pid) }) -and (Test-PidAlive $fM2.Pid) -and (Test-Path -LiteralPath $fM2.Session)) 'M: only the process of share one exited; share two keeps running'
    $sM = Get-State $M
    Assert-True ((Get-ShareFromState $sM $stM2.Id).phase -eq 'active' -and $sM.running -eq 1) 'M: share two stays active, running 1'

    # a slot is free again
    $stM3 = Start-Share $M $dirM3 5
    Assert-True ($stM3.Status -eq 200) 'M: after one share ended a new start works'
    $shM3 = Wait-ForShare $M $stM3.Id { param($x) $x.phase -eq 'active' }
    Assert-True ($null -ne $shM3 -and @((Get-State $M).shares).Count -eq 3) 'M: the third share becomes active; the ended one is still listed'
    $stM4 = Start-Share $M $dirM3 5
    Assert-True ($stM4.Status -eq 409) 'M: two running again -> the next start is 409'

    # rename
    $idR = $stM2.Id
    $r = Invoke-Post $M "/api/shares/$idR/rename" @{ name = '  Neuer Name ä  ' }
    Assert-True ($r.Status -eq 200 -and $r.Json.ok -eq $true -and $r.Json.name -ceq 'Neuer Name ä') 'M: rename -> 200 {ok, name} (trimmed, umlaut kept)'
    Assert-True ((Get-ShareFromState (Get-State $M) $idR).name -ceq 'Neuer Name ä') 'M: the new name shows in the state'
    $r = Invoke-Post $M "/api/shares/$idR/rename" @{ name = '' }
    Assert-True ($r.Status -eq 400) 'M: rename to an empty name -> 400'
    $r = Invoke-Post $M "/api/shares/$idR/rename" @{ name = '    ' }
    Assert-True ($r.Status -eq 400) 'M: rename to blanks only -> 400'
    $r = Invoke-Post $M "/api/shares/$idR/rename" @{ name = ('x' * 61) }
    Assert-True ($r.Status -eq 400) 'M: rename to 61 characters -> 400'
    $r = Invoke-Post $M "/api/shares/$idR/rename" @{ name = ('y' * 60) }
    Assert-True ($r.Status -eq 200 -and $r.Json.name.Length -eq 60) 'M: rename to exactly 60 characters -> 200'
    $r = Invoke-Post $M "/api/shares/$idR/rename" @{ name = ('a' + [char]1 + 'b') }
    Assert-True ($r.Status -eq 400) 'M: rename with a control character -> 400'
    $r = Invoke-Post $M "/api/shares/$idR/rename" @{ name = ('a' + [char]10) }
    Assert-True ($r.Status -eq 400) 'M: rename with a line break -> 400'
    $r = Invoke-Post $M "/api/shares/$idR/rename" @{ nom = 'x' }
    Assert-True ($r.Status -eq 400) 'M: rename without a name field -> 400'
    $r = Invoke-Post $M "/api/shares/$idR/rename" @{ name = 123 }
    Assert-True ($r.Status -eq 400) 'M: rename with a non-string name -> 400'
    $r = Invoke-Api -Method POST -Path "/api/shares/$idR/rename" -B $M -Token $M.Token -BodyText 'kein json'
    Assert-True ($r.Status -eq 400) 'M: rename with invalid JSON -> 400'
    Assert-True ((Get-ShareFromState (Get-State $M) $idR).name -ceq ('y' * 60)) 'M: rejected renames leave the name unchanged'
    $r = Invoke-Post $M "/api/shares/$idR/rename" @{ name = 'three' }
    Assert-True ($r.Status -eq 200) 'M: names do not have to be unique'
    $r = Invoke-Post $M "/api/shares/$($stM1.Id)/rename" @{ name = 'beendet' }
    Assert-True ($r.Status -eq 200 -and (Get-ShareFromState (Get-State $M) $stM1.Id).name -ceq 'beendet') 'M: an ended share can be renamed too'

    # dismiss
    $r = Invoke-Post $M "/api/shares/$idR/dismiss" $null
    Assert-True ($r.Status -eq 409) 'M: dismiss of an active (renamed) share -> 409'
    $r = Invoke-Post $M "/api/shares/$($stM1.Id)/dismiss" $null
    Assert-True ($r.Status -eq 200 -and $r.Json.ok -eq $true) 'M: dismiss of an ended share -> 200'
    $sM = Get-State $M
    Assert-True ($null -eq (Get-ShareFromState $sM $stM1.Id) -and @($sM.shares).Count -eq 2) 'M: the dismissed share is gone from the list'
    $r = Invoke-Post $M "/api/shares/$($stM1.Id)/dismiss" $null
    Assert-True ($r.Status -eq 404) 'M: dismissing it again -> 404'
    $r = Invoke-Post $M "/api/shares/$($stM1.Id)/stop" $null
    Assert-True ($r.Status -eq 404) 'M: a dismissed share id is unknown -> 404'

    # quit with two active shares stops both
    $fM3 = Get-FakeByPath $M $dirM3
    Test-GuiQuit $M 'M (2 active shares)'
    Assert-True ((Wait-Until -TimeoutSec 5 -Condition { -not (Test-PidAlive $fM2.Pid) -and -not (Test-PidAlive $fM3.Pid) })) 'M: quit stopped both running shares (both fakes exited)'

    # ---- backend K: gitleaks findings are shown compactly and can be released explicitly (GUI_CONTRACT 8.6)
    $K = Start-TestBackend -Scenario 'findings' -Name 'K'
    if ($K.Port -le 0) { throw 'Backend K did not start.' }
    $fakeDigest = 'ab' * 32
    $dirK = New-ShareDir 'findings-share'
    $stK = Start-Share $K $dirK 5
    $shK = Wait-ForShare $K $stK.Id { param($x) $x.phase -eq 'error' }
    Assert-True ($null -ne $shK -and $shK.exitCode -eq 22 -and $shK.reason -eq 'SecretFindings') 'K: findings end the share with 22 / SecretFindings'
    if ($null -ne $shK) {
        $fK = $shK.findings
        Assert-True ($null -ne $fK -and $fK.digest -ceq $fakeDigest -and $fK.total -eq 421 -and $fK.fileCount -eq 30 -and $fK.accepted -eq $false) 'K: the state carries the findings summary with digest and counts'
        Assert-True ($null -ne $fK -and @($fK.files).Count -eq 2 -and @($fK.files)[0].path -ceq 'locales/ru/Spiel-5.1.2.po' -and @(@($fK.files)[0].lines).Count -eq 10 -and @($fK.files)[0].moreLines -eq 408) 'K: findings are grouped per file with the first lines and the number of further lines'
        Assert-True ($null -ne $fK -and @($fK.rules).Count -eq 2 -and @($fK.rules)[0].description.Length -gt 0) 'K: rule descriptions are passed on'
        Assert-True ($null -eq $shK.acceptedFindings) 'K: acceptedFindings is null before a confirmation'
    }
    $r = Invoke-Post $K "/api/shares/$($stK.Id)/override" @{ digest = ('cd' * 32) }
    Assert-True ($r.Status -eq 409) 'K: override with another digest -> 409'
    $r = Invoke-Post $K "/api/shares/$($stK.Id)/override" $null
    Assert-True ($r.Status -eq 409) 'K: override without digest -> 409'
    $r = Invoke-Api -Method POST -Path "/api/shares/$($stK.Id)/override" -B $K -Token $K.Token -BodyText 'kein json'
    Assert-True ($r.Status -eq 400) 'K: override with invalid JSON -> 400'
    $r = Invoke-Api -Method GET -Path "/api/shares/$($stK.Id)/override" -B $K -Token $K.Token
    Assert-True ($r.Status -eq 405) 'K: GET override -> 405'
    $r = Invoke-Post $K "/api/shares/$($stK.Id)/override" @{ digest = $fakeDigest }
    Assert-True ($r.Status -eq 200 -and $r.Json.ok -eq $true -and $r.Json.shareId -ceq $stK.Id) 'K: override with the shown digest -> 200, same share'
    $shK2 = Wait-ForShare $K $stK.Id { param($x) $x.phase -eq 'active' }
    Assert-True ($null -ne $shK2 -and $shK2.acceptedFindings -eq 421 -and $null -eq $shK2.findings) 'K: the share runs again and becomes active with acceptedFindings 421'
    $fakeK = @(Get-Fakes $K | Where-Object { $_.Path -ceq $dirK })
    $acceptArgs = @($fakeK | ForEach-Object { $a = $_.File + '.accept'; if (Test-Path -LiteralPath $a) { ([IO.File]::ReadAllText($a)).Trim() } else { '' } })
    Assert-True ($fakeK.Count -eq 2 -and $acceptArgs[0] -eq '' -and $acceptArgs[1] -ceq $fakeDigest) 'K: only the second run got -AcceptSecretFindings with exactly that digest'
    $r = Invoke-Post $K "/api/shares/$($stK.Id)/override" @{ digest = $fakeDigest }
    Assert-True ($r.Status -eq 409) 'K: override of an active share -> 409'
    $r = Invoke-Post $K "/api/shares/$($stK.Id)/stop" $null
    $null = Wait-ForShare $K $stK.Id { param($x) $x.phase -eq 'ended' }

    # a dropped share keeps its drop folder while the findings can still be confirmed
    $dK = New-DropShare $K @('notes.po')
    $shD = Wait-ForShare $K $dK.Id { param($x) $x.phase -eq 'error' }
    Assert-True ($null -ne $shD -and $null -ne $shD.findings -and (Test-Path -LiteralPath $dK.Leaf)) 'K: a dropped share blocked by findings keeps its drop folder'
    $r = Invoke-Post $K "/api/shares/$($dK.Id)/override" @{ digest = $fakeDigest }
    $shD2 = Wait-ForShare $K $dK.Id { param($x) $x.phase -eq 'active' }
    Assert-True ($r.Status -eq 200 -and $null -ne $shD2 -and $shD2.dropFiles -eq 1 -and $null -ne (Get-FakeByPath $K $dK.Leaf)) 'K: override of a dropped share runs again on the same drop folder'
    $null = Invoke-Post $K "/api/shares/$($dK.Id)/stop" $null
    $null = Wait-ForShare $K $dK.Id { param($x) $x.phase -eq 'ended' }
    Assert-True (Wait-Until -TimeoutSec 5 -Condition { -not (Test-Path -LiteralPath $dK.Root) }) 'K: the drop folder is deleted when the released share ends'

    $dK2 = New-DropShare $K @('other.po')
    $null = Wait-ForShare $K $dK2.Id { param($x) $x.phase -eq 'error' }
    $r = Invoke-Post $K "/api/shares/$($dK2.Id)/dismiss" $null
    Assert-True ($r.Status -eq 200 -and (Wait-Until -TimeoutSec 5 -Condition { -not (Test-Path -LiteralPath $dK2.Root) })) 'K: dismissing a share with unconfirmed findings deletes its drop folder'
    Test-GuiQuit $K 'K'

    # ---- backend L: the list holds at most 20 shares (the oldest ended/error one is dismissed automatically)
    $L = Start-TestBackend -Scenario 'fail22' -Name 'L'
    if ($L.Port -le 0) { throw 'Backend L did not start.' }
    $firstId = $null
    $lastId = $null
    $started = 0
    while ($started -lt 22) {
        $batch = @()
        for ($i = 0; $i -lt 5 -and $started -lt 22; $i++) {
            $st = Start-Share $L $shareDir 5
            if ($st.Status -ne 200) { Write-Host ("       start #{0} -> {1} {2}" -f ($started + 1), $st.Status, $st.R.Body) }
            if ($null -eq $firstId) { $firstId = $st.Id }
            $lastId = $st.Id
            $batch += $st.Id
            $started++
        }
        $null = Wait-Until -TimeoutSec 30 -Condition {
            $cur = Get-State $L
            foreach ($bid in $batch) { $x = Get-ShareFromState $cur $bid; if ($null -ne $x -and $x.phase -notin @('error', 'ended')) { return $false } }
            return $true
        }
    }
    $sL = Get-State $L
    Assert-True (@($sL.shares).Count -eq 20 -and $null -eq (Get-ShareFromState $sL $firstId) -and $null -ne (Get-ShareFromState $sL $lastId) -and $sL.running -eq 0) 'L: 22 starts -> at most 20 shares are listed; the oldest ended/error ones were dismissed automatically'
    Test-GuiQuit $L 'L'

    # ---- backend P: the folder picker runs in its own runspace and answers asynchronously (GUI_CONTRACT 8.4)
    $dirP = New-ShareDir 'picker-target'
    $dirPS = New-ShareDir 'picker-share'
    $P = Start-TestBackend -Scenario 'success' -Name 'P' -ExtraArgs ('-TestPickerResult "7000:{0}"' -f $dirP)
    if ($P.Port -le 0) { throw 'Backend P did not start.' }
    $swPick = [Diagnostics.Stopwatch]::StartNew()
    $bgPick = Start-BackgroundCurl -Tag 'pick' -CurlArgs @('-X', 'POST', '-H', "X-WS-Token: $($P.Token)", '-H', 'Content-Type: application/json', '--data-binary', '{}', ('http://127.0.0.1:{0}/api/pick-folder' -f $P.Port))
    Start-Sleep -Milliseconds 1200
    Assert-True (-not $bgPick.Proc.HasExited) 'P: the pick-folder request stays open while the dialog is "open"'
    $r = Invoke-Post $P '/api/pick-folder' $null
    Assert-True ($r.Status -eq 409) 'P: a second pick-folder while one is open -> 409'
    $sP = Get-State $P
    Assert-True ($null -ne $sP -and -not $bgPick.Proc.HasExited) 'P: /api/state is answered while the picker is open'
    $stP = Start-Share $P $dirPS 5
    $shP = Wait-ForShare $P $stP.Id { param($x) $x.phase -eq 'active' }
    Assert-True ($stP.Status -eq 200 -and $null -ne $shP -and -not $bgPick.Proc.HasExited) 'P: a share starts and reaches active while the picker is still open (loop and pipes keep running)'
    $null = $bgPick.Proc.WaitForExit(20000)
    $resP = Get-BackgroundCurlResult $bgPick
    Assert-True ($resP.Status -eq 200 -and $resP.Json.path -ceq $dirP) 'P: the deferred answer carries the picked path'
    Assert-True ($swPick.Elapsed.TotalSeconds -ge 6.5) 'P: the answer came after the dialog delay, not before'
    # a picker that is still open when the backend quits must not keep it alive
    $bgPick2 = Start-BackgroundCurl -Tag 'pick2' -CurlArgs @('-X', 'POST', '-H', "X-WS-Token: $($P.Token)", '-H', 'Content-Type: application/json', '--data-binary', '{}', ('http://127.0.0.1:{0}/api/pick-folder' -f $P.Port))
    Start-Sleep -Milliseconds 500
    $r = Invoke-Post $P '/api/pick-folder' $null
    Assert-True ($r.Status -eq 409) 'P: after the first answer a new picker can be opened (and is open now)'
    Test-GuiQuit $P 'P (picker open, 1 share)'
    try { if (-not $bgPick2.Proc.HasExited) { $bgPick2.Proc.Kill() } } catch { }

    $P2 = Start-TestBackend -Scenario 'success' -Name 'P2' -ExtraArgs '-TestPickerResult "0:"'
    if ($P2.Port -le 0) { throw 'Backend P2 did not start.' }
    $r = Invoke-Post $P2 '/api/pick-folder' $null
    Assert-True ($r.Status -eq 200 -and $r.Json.cancelled -eq $true) 'P2: a cancelled dialog -> {cancelled:true}'
    $r = Invoke-Post $P2 '/api/pick-folder' $null
    Assert-True ($r.Status -eq 200 -and $r.Json.cancelled -eq $true) 'P2: the picker can be used again after it finished'
    Test-GuiQuit $P2 'P2'

    # ---- backend X: a chatty share must not stall while a big upload blocks the request (pipes are drained)
    $X = Start-TestBackend -Scenario 'chatty' -Name 'X'
    if ($X.Port -le 0) { throw 'Backend X did not start.' }
    $big = Join-Path $tmp 'src-20m.bin'
    New-RandomFile $big 20971520 31
    $r = Invoke-Post $X '/api/drop/begin' $null
    $dropX = [string]$r.Json.dropId
    $dirX = New-ShareDir 'chatty-share'
    $stX = Start-Share $X $dirX 5
    Assert-True ($stX.Status -eq 200) 'X: chatty share starts'
    $upUrl = 'http://127.0.0.1:{0}/api/drop/file?drop={1}&path={2}' -f $X.Port, $dropX, [Uri]::EscapeDataString('big20.bin')
    $swUp = [Diagnostics.Stopwatch]::StartNew()
    $bgUp = Start-BackgroundCurl -Tag 'up' -CurlArgs @('--limit-rate', '4M', '-X', 'POST', '-H', "X-WS-Token: $($X.Token)", '-H', 'Content-Type: application/octet-stream', '--data-binary', "@$big", $upUrl)
    # While the backend is busy with the upload it cannot answer HTTP; the fake reports when its last noise line went through the pipe.
    $noiseFile = $null
    $gotNoise = Wait-Until -TimeoutSec 20 -IntervalMs 100 -Condition {
        if ($bgUp.Proc.HasExited) { return $true }
        foreach ($f in @(Get-Fakes $X)) { if (Test-Path -LiteralPath ($f.File + '.noise')) { return $true } }
        return $false
    }
    $noiseDuringUpload = $false
    foreach ($f in @(Get-Fakes $X)) { if (Test-Path -LiteralPath ($f.File + '.noise')) { $noiseDuringUpload = $true } }
    $uploadStillRunning = -not $bgUp.Proc.HasExited
    Write-Host ("       noise written after {0:N1} s, upload still running: {1}" -f $swUp.Elapsed.TotalSeconds, $uploadStillRunning)
    Assert-True ($gotNoise -and $noiseDuringUpload -and $uploadStillRunning) 'X: the chatty share wrote its 200 KB of output while the 20 MB upload was still in progress (children are drained during the upload)'
    $null = $bgUp.Proc.WaitForExit(60000)
    $resUp = Get-BackgroundCurlResult $bgUp
    if ($resUp.Status -ne 200) { Write-Host ('       [DEBUG] upload status ' + $resUp.Status + ' body=[' + $resUp.Body + ']') }
    Assert-True ($resUp.Status -eq 200 -and $resUp.Json.bytes -eq 20971520) 'X: the 20 MB upload succeeds'
    $shX = Wait-ForShare $X $stX.Id { param($x) $x.phase -eq 'active' }
    Assert-True ($null -ne $shX) 'X: the chatty share reaches active'
    if ($null -ne $shX) {
        $noiseLines = @($shX.log | Where-Object { $_ -match '^N{50,}$' })
        Assert-True ($noiseLines.Count -ge 100) "X: the noise lines were captured in the share's log ring buffer ($($noiseLines.Count) lines, max 200 kept)"
        Assert-True (@($shX.log).Count -le 200) 'X: the log ring buffer keeps at most 200 lines'
    }
    $r = Invoke-Post $X '/api/drop/finish' @{ dropId = $dropX }
    $dropFileX = Join-Path (Join-Path $X.DataRoot 'drops') $dropX
    $leafX = [string]$r.Json.path
    Assert-True ($r.Status -eq 200 -and $r.Json.files -eq 1 -and (Get-FileSha (Join-Path $leafX 'big20.bin')) -eq (Get-FileSha $big)) 'X: the uploaded 20 MB file is bit-identical'
    Test-GuiQuit $X 'X'
    Assert-True (@(Get-Fakes $X | Where-Object { Test-PidAlive $_.Pid }).Count -eq 0) 'X: the chatty share is gone after quit'

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
if ($isWin) { try {
    $events = @(Get-WinEvent -FilterHashtable @{ LogName = 'Microsoft-Windows-CodeIntegrity/Operational'; Id = 3033, 3077; StartTime = $testStart } -ErrorAction SilentlyContinue)
    $repoTail = $ToolRoot
    if ($repoTail.Length -gt 3 -and $repoTail[1] -eq ':') { $repoTail = $repoTail.Substring(2) }
    foreach ($e in $events) {
        $m = [string]$e.Message
        if ($m -match '(?i)powershell' -or $m.IndexOf($repoTail, [StringComparison]::OrdinalIgnoreCase) -ge 0) { $blocked += $e }
    }
}
catch { } }
else { Write-Host '[SKIP] CodeIntegrity/Smart-App-Control-Prüfung gibt es nur unter Windows' }

Write-Host ''
Write-Host "Passed: $($script:Pass)  Failed: $($script:Fail)"
if ($blocked.Count -gt 0) {
    Write-Host "[ENV] Windows Code Integrity / Smart App Control hat $($blocked.Count) Datei(en) blockiert; das Testergebnis ist nicht aussagekräftig."
    foreach ($e in $blocked | Select-Object -First 5) { Write-Host ('[ENV] ' + (([string]$e.Message) -replace '\s+', ' ')) }
    exit 42
}
if ($script:Fail -gt 0) { exit 1 }
exit 0
