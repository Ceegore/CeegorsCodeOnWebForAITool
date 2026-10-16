#requires -Version 5.1
[CmdletBinding()]
param([string]$ToolRoot)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if ([string]::IsNullOrWhiteSpace($ToolRoot)) { $ToolRoot = Split-Path $PSScriptRoot -Parent }
Import-Module (Join-Path $ToolRoot 'scripts\WorkspaceShare.Platform.psm1') -Force -ErrorAction Stop
Import-Module (Join-Path $ToolRoot 'scripts\WorkspaceShare.Gui.Http.psm1') -Force -ErrorAction Stop

$script:Pass = 0
$script:Fail = 0
function Assert-True {
    param([bool]$Condition, [string]$Name)
    if ($Condition) { $script:Pass++; Write-Host "[PASS] $Name" }
    else { $script:Fail++; Write-Host "[FAIL] $Name" }
}

$utf8 = New-Object System.Text.UTF8Encoding ($false)
function New-RequestStream {
    param([string]$Text)
    return (New-Object System.IO.MemoryStream (, $utf8.GetBytes($Text)))
}
function Read-Request {
    param([string]$Text, [hashtable]$Params = @{})
    $s = New-RequestStream $Text
    return (Read-WsHttpRequest -Stream $s @Params)
}
function Get-ErrorStatus {
    # Returns the WsHttpStatus of a failed parse, 0 if parsing succeeded.
    param([string]$Text, [hashtable]$Params = @{})
    try { [void](Read-Request $Text $Params); return 0 }
    catch {
        if ($_.Exception.Data.Contains('WsHttpStatus')) { return [int]$_.Exception.Data['WsHttpStatus'] }
        return -1
    }
}
function Get-ResponseText {
    param([int]$Status, $Body, [string]$ContentType, [hashtable]$Headers)
    $ms = New-Object System.IO.MemoryStream
    $p = @{ Stream = $ms; Status = $Status }
    if ($PSBoundParameters.ContainsKey('Body')) { $p.Body = $Body }
    if ($ContentType) { $p.ContentType = $ContentType }
    if ($Headers) { $p.Headers = $Headers }
    Write-WsHttpResponse @p
    return @{ Bytes = $ms.ToArray(); Text = [Text.Encoding]::GetEncoding(28591).GetString($ms.ToArray()) }
}

# ---- Read-WsHttpRequest ----
$r = Read-Request "GET /api/state?x=1&y=2 HTTP/1.1`r`nHost: 127.0.0.1:5000`r`nX-WS-Token:  abc `r`n`r`n"
Assert-True ($r.Method -ceq 'GET' -and $r.Path -ceq '/api/state' -and $r.Query -ceq 'x=1&y=2' -and $r.Body -ceq '') 'valid GET: method, path, query, empty body'
Assert-True ($r.Headers['host'] -ceq '127.0.0.1:5000' -and $r.Headers['x-ws-token'] -ceq 'abc') 'headers are case-insensitive and trimmed'

$json = '{"path":"C:\\Temp\\Ordner Ä","minutes":240}'
$len = $utf8.GetByteCount($json)
$r = Read-Request "POST /api/start HTTP/1.1`r`nHost: 127.0.0.1:5000`r`nContent-Type: application/json`r`nContent-Length: $len`r`n`r`n$json"
$obj = $r.Body | ConvertFrom-Json
Assert-True ($r.Method -ceq 'POST' -and $r.Body -ceq $json -and $obj.minutes -eq 240) 'POST with UTF-8 JSON body is read completely'
Assert-True ($r.Query -ceq '') 'no query string gives empty Query'

$r = Read-Request "GET / HTTP/1.0`r`nHost: x`r`n`r`n"
Assert-True ($r.Path -ceq '/') 'HTTP/1.0 request line is accepted'

$big = "GET / HTTP/1.1`r`nHost: x`r`nX-Pad: " + ('a' * 600) + "`r`n`r`n"
Assert-True ((Get-ErrorStatus $big @{ MaxHeaderBytes = 256 }) -eq 431) 'header block over limit (terminator present) -> 431'
$bigOpen = "GET / HTTP/1.1`r`nHost: x`r`nX-Pad: " + ('a' * 40000)
Assert-True ((Get-ErrorStatus $bigOpen) -eq 431) 'endless header without CRLFCRLF -> 431 at default limit'

Assert-True ((Get-ErrorStatus "POST /x HTTP/1.1`r`nHost: x`r`nContent-Length: 70000`r`n`r`n") -eq 413) 'Content-Length over limit -> 413'
Assert-True ((Get-ErrorStatus "POST /x HTTP/1.1`r`nHost: x`r`nContent-Length: 11`r`n`r`nabc" ) -eq 400) 'body shorter than Content-Length (stream ends) -> 400'
Assert-True ((Get-ErrorStatus "POST /x HTTP/1.1`r`nHost: x`r`nContent-Length: 1x`r`n`r`na") -eq 400) 'non-numeric Content-Length -> 400'
Assert-True ((Get-ErrorStatus "POST /x HTTP/1.1`r`nHost: x`r`nContent-Length: -1`r`n`r`n") -eq 400) 'negative Content-Length -> 400'
Assert-True ((Get-ErrorStatus "GET / HTTP/1.1`r`nHost: x`r`n") -eq 400) 'missing CRLFCRLF (stream ends early) -> 400'
Assert-True ((Get-ErrorStatus '') -eq 400) 'empty stream -> 400'
Assert-True ((Get-ErrorStatus "GET / HTTP/2.0`r`nHost: x`r`n`r`n") -eq 400) 'unsupported HTTP version -> 400'
Assert-True ((Get-ErrorStatus "GET /`r`nHost: x`r`n`r`n") -eq 400) 'bad request line (two parts) -> 400'
Assert-True ((Get-ErrorStatus "GET  / HTTP/1.1`r`nHost: x`r`n`r`n") -eq 400) 'bad request line (double space) -> 400'
Assert-True ((Get-ErrorStatus "get / HTTP/1.1`r`nHost: x`r`n`r`n") -eq 400) 'lower-case method -> 400'
Assert-True ((Get-ErrorStatus "GET index.html HTTP/1.1`r`nHost: x`r`n`r`n") -eq 400) 'target without leading slash -> 400'
Assert-True ((Get-ErrorStatus "GET /../x HTTP/1.1`r`nHost: x`r`n`r`n") -eq 400) "'..' traversal -> 400"
Assert-True ((Get-ErrorStatus "GET /a/../x HTTP/1.1`r`nHost: x`r`n`r`n") -eq 400) "'..' segment in the middle -> 400"
Assert-True ((Get-ErrorStatus "GET /a\b HTTP/1.1`r`nHost: x`r`n`r`n") -eq 400) 'backslash in target -> 400'
Assert-True ((Get-ErrorStatus ("GET /a" + [char]1 + "b HTTP/1.1`r`nHost: x`r`n`r`n")) -eq 400) 'control character in target -> 400'
Assert-True ((Get-ErrorStatus "GET /...x HTTP/1.1`r`nHost: x`r`n`r`n") -eq 0) "'..' inside a longer segment is not traversal"
Assert-True ((Get-ErrorStatus "POST /x HTTP/1.1`r`nHost: x`r`nTransfer-Encoding: chunked`r`n`r`n0`r`n`r`n") -eq 400) 'Transfer-Encoding -> 400'
Assert-True ((Get-ErrorStatus "GET / HTTP/1.1`r`nHost: a`r`nHost: b`r`n`r`n") -eq 400) 'duplicate Host -> 400'
Assert-True ((Get-ErrorStatus "GET / HTTP/1.1`r`nHost x`r`n`r`n") -eq 400) 'header line without colon -> 400'
Assert-True ((Get-ErrorStatus "GET / HTTP/1.1`r`nHost : x`r`n`r`n") -eq 400) 'space before colon in header name -> 400'

# ---- Test-WsRequestAllowed ----
function New-FakeRequest {
    param([string]$Method = 'GET', [hashtable]$H = @{})
    $h2 = New-Object Collections.Hashtable ([StringComparer]::OrdinalIgnoreCase)
    foreach ($k in $H.Keys) { $h2[$k] = $H[$k] }
    return [pscustomobject]@{ Method = $Method; Path = '/api/state'; Query = ''; Headers = $h2; Body = '' }
}
$port = 4711
$a = Test-WsRequestAllowed -Request (New-FakeRequest 'GET' @{ Host = '127.0.0.1:4711' }) -Port $port -Token 'secret'
Assert-True ($a.Allowed -eq $true -and $a.Status -eq 200) 'correct Host without token requirement is allowed'
$a = Test-WsRequestAllowed -Request (New-FakeRequest 'GET' @{ Host = '127.0.0.1:9999' }) -Port $port -Token 'secret'
Assert-True ($a.Allowed -eq $false -and $a.Status -eq 403) 'wrong Host port -> 403'
$a = Test-WsRequestAllowed -Request (New-FakeRequest 'GET' @{ Host = 'localhost:4711' }) -Port $port -Token 'secret'
Assert-True ($a.Allowed -eq $false -and $a.Status -eq 403) "Host 'localhost' -> 403 (DNS rebinding)"
$a = Test-WsRequestAllowed -Request (New-FakeRequest 'GET' @{}) -Port $port -Token 'secret'
Assert-True ($a.Allowed -eq $false -and $a.Status -eq 403) 'missing Host -> 403'
$a = Test-WsRequestAllowed -Request (New-FakeRequest 'GET' @{ Host = '127.0.0.1:4711'; Origin = 'http://evil.example' }) -Port $port -Token 'secret'
Assert-True ($a.Allowed -eq $false -and $a.Status -eq 403) 'Origin mismatch -> 403'
$a = Test-WsRequestAllowed -Request (New-FakeRequest 'POST' @{ Host = '127.0.0.1:4711'; Origin = 'http://127.0.0.1:4711' }) -Port $port -Token 'secret'
Assert-True ($a.Allowed -eq $true) 'matching Origin is allowed'
$a = Test-WsRequestAllowed -Request (New-FakeRequest 'GET' @{ Host = '127.0.0.1:4711' }) -Port $port -Token 'secret' -RequireToken
Assert-True ($a.Allowed -eq $false -and $a.Status -eq 401) 'missing token with -RequireToken -> 401'
$a = Test-WsRequestAllowed -Request (New-FakeRequest 'GET' @{ Host = '127.0.0.1:4711'; 'X-WS-Token' = 'wrong' }) -Port $port -Token 'secret' -RequireToken
Assert-True ($a.Allowed -eq $false -and $a.Status -eq 401) 'wrong token -> 401'
$a = Test-WsRequestAllowed -Request (New-FakeRequest 'GET' @{ Host = '127.0.0.1:4711'; 'X-WS-Token' = 'secre' }) -Port $port -Token 'secret' -RequireToken
Assert-True ($a.Allowed -eq $false -and $a.Status -eq 401) 'token prefix of the real token -> 401'
$a = Test-WsRequestAllowed -Request (New-FakeRequest 'GET' @{ Host = '127.0.0.1:4711'; 'X-WS-Token' = 'secret' }) -Port $port -Token 'secret' -RequireToken
Assert-True ($a.Allowed -eq $true -and $a.Status -eq 200) 'right token -> allowed'
$a = Test-WsRequestAllowed -Request (New-FakeRequest 'GET' @{ Host = '127.0.0.1:4711'; 'X-WS-Token' = '' }) -Port $port -Token '' -RequireToken
Assert-True ($a.Allowed -eq $false -and $a.Status -eq 401) 'empty expected token never matches'
$a = Test-WsRequestAllowed -Request (New-FakeRequest 'OPTIONS' @{ Host = '127.0.0.1:4711'; 'X-WS-Token' = 'secret' }) -Port $port -Token 'secret' -RequireToken
Assert-True ($a.Allowed -eq $false -and $a.Status -eq 405) 'OPTIONS -> 405 even with valid Host and token'

# ---- Get-WsStaticFile ----
$guiRoot = Join-Path ([IO.Path]::GetTempPath()) ('wsgui-test-' + [Guid]::NewGuid().ToString('N'))
[void](New-Item -ItemType Directory -Path $guiRoot)
try {
    foreach ($f in 'index.html', 'app.js', 'app.css', 'favicon.svg') { [IO.File]::WriteAllText((Join-Path $guiRoot $f), "dummy $f Ä", $utf8) }
    [IO.File]::WriteAllText((Join-Path $guiRoot 'secret.txt'), 'secret', $utf8)
    $map = [ordered]@{
        '/'            = @('index.html', 'text/html; charset=utf-8')
        '/index.html'  = @('index.html', 'text/html; charset=utf-8')
        '/app.js'      = @('app.js', 'application/javascript; charset=utf-8')
        '/app.css'     = @('app.css', 'text/css; charset=utf-8')
        '/favicon.svg' = @('favicon.svg', 'image/svg+xml')
    }
    foreach ($p in $map.Keys) {
        $f = Get-WsStaticFile -Path $p -GuiRoot $guiRoot
        $expected = $utf8.GetBytes("dummy $($map[$p][0]) Ä")
        $ok = ($null -ne $f) -and $f.ContentType -ceq $map[$p][1] -and (($f.Bytes -join ',') -ceq ($expected -join ','))
        Assert-True $ok "static map: $p -> $($map[$p][0]) ($($map[$p][1]))"
    }
    Assert-True ($null -eq (Get-WsStaticFile -Path '/../x' -GuiRoot $guiRoot)) "static: '/../x' -> `$null"
    Assert-True ($null -eq (Get-WsStaticFile -Path '/secret.txt' -GuiRoot $guiRoot)) "static: '/secret.txt' -> `$null although the file exists"
    Assert-True ($null -eq (Get-WsStaticFile -Path '/APP.JS' -GuiRoot $guiRoot)) 'static: path match is case-sensitive'
    Assert-True ($null -eq (Get-WsStaticFile -Path '/api/state' -GuiRoot $guiRoot)) 'static: /api/state -> $null'
    Remove-Item -LiteralPath (Join-Path $guiRoot 'app.css')
    Assert-True ($null -eq (Get-WsStaticFile -Path '/app.css' -GuiRoot $guiRoot)) 'static: mapped but missing file -> $null'
}
finally { Remove-Item -LiteralPath $guiRoot -Recurse -Force -ErrorAction SilentlyContinue }

# ---- Write-WsHttpResponse ----
$resp = Get-ResponseText -Status 200 -Body 'Grüße äöü €' -ContentType 'text/plain; charset=utf-8'
$bodyBytes = $utf8.GetBytes('Grüße äöü €')
$sepIdx = $resp.Text.IndexOf("`r`n`r`n")
Assert-True ($resp.Text.StartsWith("HTTP/1.1 200 OK`r`n")) 'status line 200 OK'
Assert-True ($resp.Text.Contains("Content-Length: $($bodyBytes.Length)`r`n")) 'Content-Length counts UTF-8 bytes, not characters'
Assert-True (($resp.Bytes.Length - ($sepIdx + 4)) -eq $bodyBytes.Length) 'body bytes after the header block match Content-Length'
foreach ($h in @('Connection: close', 'Cache-Control: no-store', 'X-Content-Type-Options: nosniff', 'X-Frame-Options: DENY', 'Referrer-Policy: no-referrer',
        "Content-Security-Policy: default-src 'self'; img-src 'self' data:; style-src 'self'; script-src 'self'; connect-src 'self'; frame-ancestors 'none'; base-uri 'none'; form-action 'none'")) {
    Assert-True ($resp.Text.Contains("`r`n$h`r`n")) "security header present: $($h.Split(':')[0])"
}
$resp = Get-ResponseText -Status 404
Assert-True ($resp.Text.StartsWith("HTTP/1.1 404 Not Found`r`n") -and $resp.Text.Contains("Content-Length: 0`r`n") -and $resp.Text.Contains("Content-Type: text/plain; charset=utf-8`r`n")) '404 without body: reason, Content-Length 0, default Content-Type'
$resp = Get-ResponseText -Status 200 -Body ([byte[]](1, 2, 3, 255)) -ContentType 'application/octet-stream' -Headers @{ 'X-Extra' = 'yes' }
Assert-True ($resp.Text.Contains("Content-Length: 4`r`n") -and $resp.Text.Contains("X-Extra: yes`r`n") -and $resp.Bytes[$resp.Bytes.Length - 1] -eq 255) 'byte[] body and extra headers'
foreach ($pair in @(@(204, 'No Content'), @(401, 'Unauthorized'), @(405, 'Method Not Allowed'), @(408, 'Request Timeout'), @(409, 'Conflict'), @(413, 'Payload Too Large'), @(431, 'Request Header Fields Too Large'), @(501, 'Not Implemented'))) {
    $resp = Get-ResponseText -Status $pair[0]
    Assert-True ($resp.Text.StartsWith("HTTP/1.1 $($pair[0]) $($pair[1])`r`n")) "reason phrase $($pair[0])"
}
$headerInjection = $false
try { [void](Get-ResponseText -Status 200 -Headers @{ 'X-Bad' = "a`r`nSet-Cookie: x=1" }) } catch { $headerInjection = $true }
Assert-True $headerInjection 'CR/LF in an extra header value is rejected'

# ---- ConvertTo-WsJson ----
$j = ConvertTo-WsJson -Object @{ text = 'Bärenstark ä' }
Assert-True ($j -ceq '{"text":"B\u00e4renstark \u00e4"}') 'non-ASCII escaped as \uXXXX (lower-case hex)'
Assert-True (-not ($j -match '[^\x00-\x7E]')) 'escaped JSON is pure ASCII'
$round = ConvertFrom-Json $j
Assert-True ($round.text -ceq 'Bärenstark ä') 'round-trips via ConvertFrom-Json'
$round2 = ConvertFrom-Json (ConvertTo-WsJson -Object @{ s = "emoji $([char]::ConvertFromUtf32(0x1F600)) x" })
Assert-True ($round2.s -ceq "emoji $([char]::ConvertFromUtf32(0x1F600)) x") 'surrogate pair round-trips'
Assert-True ((ConvertTo-WsJson -Object $null) -ceq 'null') '$null -> null'
Assert-True ((ConvertTo-WsJson -Object $true) -ceq 'true' -and (ConvertTo-WsJson -Object $false) -ceq 'false') 'booleans'
Assert-True ((ConvertTo-WsJson -Object @(5)) -ceq '[5]') 'single-element array stays an array'
Assert-True ((ConvertTo-WsJson -Object @()) -ceq '[]') 'empty array -> []'
Assert-True ((ConvertTo-WsJson -Object @{ list = @('only') }) -ceq '{"list":["only"]}') 'single-element array inside a hashtable stays an array'
$nested = [ordered]@{ v = 1; phase = 'idle'; capabilities = @{ folderPicker = $true }; steps = @(@{ n = 1; text = 'Schritt ä' }); url = $null; log = @() }
$nj = ConvertTo-WsJson -Object $nested
$np = ConvertFrom-Json $nj
Assert-True ($np.v -eq 1 -and $np.capabilities.folderPicker -eq $true -and $np.steps.Count -eq 1 -and $np.steps[0].text -ceq 'Schritt ä' -and $null -eq $np.url) 'nested ordered dictionary / hashtable / null'
Assert-True ($nj -match '^\{"v":1,"phase":"idle"') 'ordered dictionary keeps key order'
Assert-True ((ConvertTo-WsJson -Object @{ q = 'a"b\c' }) -ceq '{"q":"a\"b\\c"}') 'quotes and backslashes escaped'

# ---- Platform module ----
Assert-True ((Get-WsPlatform) -ceq 'windows') "Get-WsPlatform returns 'windows'"
$ps = Get-WsPowerShellHost
Assert-True ((Test-Path -LiteralPath $ps -PathType Leaf) -and $ps -match 'WindowsPowerShell\\v1\.0\\powershell\.exe$') 'Get-WsPowerShellHost points at powershell.exe'
$dr = Get-WsDataRoot
Assert-True ((Test-Path -LiteralPath $dr -PathType Container) -and $dr -match 'WorkspaceShare$') 'Get-WsDataRoot exists and ends with WorkspaceShare'
$caps = Get-WsCapabilities
Assert-True ($caps.ContainsKey('folderPicker') -and $caps.ContainsKey('clipboard') -and $caps.ContainsKey('openBrowser') -and $caps.Count -eq 3 -and $caps.openBrowser -eq $true) 'Get-WsCapabilities has exactly the 3 keys'
Assert-True ((Open-WsBrowser -Url 'https://example.com/') -eq $false -and (Open-WsBrowser -Url 'http://localhost:80/') -eq $false -and (Open-WsBrowser -Url 'file:///C:/Windows/notepad.exe') -eq $false) 'Open-WsBrowser rejects non-127.0.0.1 URLs without starting anything'
if ([Threading.Thread]::CurrentThread.GetApartmentState() -ne [Threading.ApartmentState]::STA) {
    Assert-True ($null -eq (Show-WsFolderPicker)) 'Show-WsFolderPicker returns $null in a non-STA thread'
    Assert-True ((Set-WsClipboardText -Text 'x') -eq $false) 'Set-WsClipboardText returns $false in a non-STA thread'
    Assert-True ((Clear-WsClipboardText -Expected 'x') -eq $false) 'Clear-WsClipboardText returns $false in a non-STA thread'
}

# ---- Real socket round trip ----
$listener = New-Object System.Net.Sockets.TcpListener ([Net.IPAddress]::Loopback), 0
$listener.Start()
$client = $null; $srv = $null
try {
    $sockPort = ([Net.IPEndPoint]$listener.LocalEndpoint).Port
    $client = New-Object System.Net.Sockets.TcpClient
    $client.Connect('127.0.0.1', $sockPort)
    $cs = $client.GetStream()
    $cs.ReadTimeout = 5000
    $reqBytes = $utf8.GetBytes("GET /api/state HTTP/1.1`r`nHost: 127.0.0.1:$sockPort`r`nX-WS-Token: tok`r`n`r`n")
    $cs.Write($reqBytes, 0, $reqBytes.Length)
    $cs.Flush()
    $srv = $listener.AcceptTcpClient()
    $ss = $srv.GetStream()
    $req = Read-WsHttpRequest -Stream $ss -TimeoutMs 3000
    $allowed = Test-WsRequestAllowed -Request $req -Port $sockPort -Token 'tok' -RequireToken
    Assert-True ($req.Path -ceq '/api/state' -and $allowed.Allowed -eq $true) 'socket: server parsed the request and it is allowed'
    Write-WsJsonResponse -Stream $ss -Status 200 -Object ([ordered]@{ phase = 'idle'; text = 'Grüße'; items = @(1) })
    $srv.Close(); $srv = $null
    $ms = New-Object System.IO.MemoryStream
    $buf = New-Object byte[] 4096
    while (($n = $cs.Read($buf, 0, $buf.Length)) -gt 0) { $ms.Write($buf, 0, $n) }
    $text = $utf8.GetString($ms.ToArray())
    $sep = $text.IndexOf("`r`n`r`n")
    $bodyText = $text.Substring($sep + 4)
    $o = ConvertFrom-Json $bodyText
    Assert-True ($text.StartsWith("HTTP/1.1 200 OK`r`n") -and $text.Contains('Content-Type: application/json; charset=utf-8') -and $o.phase -ceq 'idle' -and $o.text -ceq 'Grüße' -and @($o.items).Count -eq 1) 'socket: client received 200 and the JSON body'
    $client.Close(); $client = $null

    # a peer that connects and never sends anything -> 408
    $client = New-Object System.Net.Sockets.TcpClient
    $client.Connect('127.0.0.1', $sockPort)
    $srv = $listener.AcceptTcpClient()
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $status = 0
    try { [void](Read-WsHttpRequest -Stream $srv.GetStream() -TimeoutMs 400) }
    catch { if ($_.Exception.Data.Contains('WsHttpStatus')) { $status = [int]$_.Exception.Data['WsHttpStatus'] } }
    Assert-True ($status -eq 408 -and $sw.Elapsed.TotalSeconds -lt 4) 'socket: silent client -> 408 within the timeout'
    $srv.Close(); $srv = $null; $client.Close(); $client = $null

    # a slow sender that stops mid-header -> 408
    $client = New-Object System.Net.Sockets.TcpClient
    $client.Connect('127.0.0.1', $sockPort)
    $half = $utf8.GetBytes("GET / HTTP/1.1`r`nHost: x")
    $client.GetStream().Write($half, 0, $half.Length)
    $srv = $listener.AcceptTcpClient()
    $status = 0
    try { [void](Read-WsHttpRequest -Stream $srv.GetStream() -TimeoutMs 400) }
    catch { if ($_.Exception.Data.Contains('WsHttpStatus')) { $status = [int]$_.Exception.Data['WsHttpStatus'] } }
    Assert-True ($status -eq 408) 'socket: partial header then silence -> 408'
}
finally {
    if ($null -ne $srv) { try { $srv.Close() } catch { } }
    if ($null -ne $client) { try { $client.Close() } catch { } }
    try { $listener.Stop() } catch { }
}

Write-Host ''
Write-Host "Passed: $($script:Pass)  Failed: $($script:Fail)"
if ($script:Fail -gt 0) { exit 1 }
exit 0
