#requires -Version 5.1
# Minimal HTTP/1.x request parser and response writer for the local WorkspaceShare GUI backend.
# Pure functions over streams, no OS specifics (GUI_CONTRACT section 4).
#
# Read-WsHttpRequest failure statuses (exception .Data['WsHttpStatus']):
#   400 malformed request, premature end of stream, invalid UTF-8 body, unsupported framing
#   408 read timeout (IOException on the stream or TimeoutMs exceeded)
#   413 Content-Length above MaxBodyBytes
#   431 header block above MaxHeaderBytes
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function New-WsHttpError {
    param([int]$Status, [string]$Message)
    $ex = New-Object System.Exception $Message
    $ex.Data['WsHttpStatus'] = $Status
    return $ex
}

function Read-WsHttpChunk {
    # Internal: one bounded read; maps timeouts to 408, end of stream to a zero count.
    param($Stream, $Stopwatch, [int]$TimeoutMs, [byte[]]$Buffer)
    $remaining = $TimeoutMs - [int]$Stopwatch.ElapsedMilliseconds
    if ($remaining -le 0) { throw (New-WsHttpError 408 'Request timeout.') }
    if ($Stream.CanTimeout) { $Stream.ReadTimeout = $remaining }
    try { return [int]$Stream.Read($Buffer, 0, $Buffer.Length) }
    catch [System.IO.IOException] { throw (New-WsHttpError 408 'Request timeout.') }
}

function Find-WsHeaderEnd {
    # Internal: index of the first CR LF CR LF in $Bytes (first $Length bytes), or -1.
    param([byte[]]$Bytes, [int]$Length)
    for ($i = 0; $i -le $Length - 4; $i++) {
        if ($Bytes[$i] -eq 13 -and $Bytes[$i + 1] -eq 10 -and $Bytes[$i + 2] -eq 13 -and $Bytes[$i + 3] -eq 10) { return $i }
    }
    return -1
}

function Read-WsHttpRequest {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][System.IO.Stream]$Stream,
        [int]$MaxHeaderBytes = 16384,
        [int]$MaxBodyBytes = 65536,
        [int]$TimeoutMs = 5000
    )
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $buffer = New-Object byte[] 4096
    $acc = New-Object System.IO.MemoryStream
    $headerEnd = -1
    $all = $null
    while ($true) {
        $all = $acc.ToArray()
        $headerEnd = Find-WsHeaderEnd $all $all.Length
        if ($headerEnd -ge 0) { break }
        if ($all.Length -gt $MaxHeaderBytes) { throw (New-WsHttpError 431 'Request header too large.') }
        $n = Read-WsHttpChunk $Stream $sw $TimeoutMs $buffer
        if ($n -le 0) { throw (New-WsHttpError 400 'Incomplete request header.') }
        $acc.Write($buffer, 0, $n)
    }
    if ($headerEnd + 4 -gt $MaxHeaderBytes) { throw (New-WsHttpError 431 'Request header too large.') }

    $latin1 = [Text.Encoding]::GetEncoding(28591)
    $headText = $latin1.GetString($all, 0, $headerEnd)
    $lines = $headText -split "`r`n"

    # Request line: METHOD SP target SP HTTP/1.x
    $parts = $lines[0].Split(' ')
    if ($parts.Count -ne 3) { throw (New-WsHttpError 400 'Bad request line.') }
    $method = $parts[0]
    $target = $parts[1]
    $version = $parts[2]
    if ($method -cnotmatch '^[A-Z]{1,16}$') { throw (New-WsHttpError 400 'Bad request method.') }
    if ($version -cnotmatch '^HTTP/1\.[01]$') { throw (New-WsHttpError 400 'Bad HTTP version.') }
    if (-not $target.StartsWith('/')) { throw (New-WsHttpError 400 'Bad request target.') }
    if ($target.Contains('\')) { throw (New-WsHttpError 400 'Bad request target.') }
    if ($target -match '[\x00-\x1F\x7F]') { throw (New-WsHttpError 400 'Bad request target.') }
    $q = $target.IndexOf('?')
    if ($q -ge 0) { $path = $target.Substring(0, $q); $query = $target.Substring($q + 1) }
    else { $path = $target; $query = '' }
    foreach ($segment in $path.Split('/')) {
        if ($segment -eq '..') { throw (New-WsHttpError 400 'Bad request target.') }
    }

    # Headers
    $headers = New-Object Collections.Hashtable ([StringComparer]::OrdinalIgnoreCase)
    for ($i = 1; $i -lt $lines.Count; $i++) {
        $line = $lines[$i]
        if ($line.Length -eq 0) { throw (New-WsHttpError 400 'Empty header line.') }
        if ($line -match '[\r\n\x00]') { throw (New-WsHttpError 400 'Bad header line.') }
        $colon = $line.IndexOf(':')
        if ($colon -lt 1) { throw (New-WsHttpError 400 'Bad header line.') }
        $name = $line.Substring(0, $colon)
        if ($name -notmatch '^[!#$%&''*+\-.^_`|~0-9A-Za-z]+$') { throw (New-WsHttpError 400 'Bad header name.') }
        $value = $line.Substring($colon + 1).Trim(' ', "`t")
        if ($headers.ContainsKey($name) -and ($name -ieq 'Host' -or $name -ieq 'Content-Length' -or $name -ieq 'Origin' -or $name -ieq 'X-WS-Token')) {
            throw (New-WsHttpError 400 ('Duplicate header: ' + $name))
        }
        $headers[$name] = $value
    }
    if ($headers.ContainsKey('Transfer-Encoding')) { throw (New-WsHttpError 400 'Transfer-Encoding is not supported.') }

    # Body: only with Content-Length
    $body = ''
    if ($headers.ContainsKey('Content-Length')) {
        $lenText = [string]$headers['Content-Length']
        if ($lenText -notmatch '^[0-9]{1,10}$') { throw (New-WsHttpError 400 'Bad Content-Length.') }
        $len = [long]$lenText
        if ($len -gt $MaxBodyBytes) { throw (New-WsHttpError 413 'Request body too large.') }
        $bodyStart = $headerEnd + 4
        $bodyAcc = New-Object System.IO.MemoryStream
        $have = [long]($all.Length - $bodyStart)
        if ($have -gt $len) { $have = $len }
        if ($have -gt 0) { $bodyAcc.Write($all, $bodyStart, [int]$have) }
        while ($have -lt $len) {
            $n = Read-WsHttpChunk $Stream $sw $TimeoutMs $buffer
            if ($n -le 0) { throw (New-WsHttpError 400 'Incomplete request body.') }
            $take = [long]$n
            if ($have + $take -gt $len) { $take = $len - $have }
            $bodyAcc.Write($buffer, 0, [int]$take)
            $have += $take
        }
        try {
            $strict = New-Object System.Text.UTF8Encoding ($false, $true)
            $body = $strict.GetString($bodyAcc.ToArray())
        }
        catch { throw (New-WsHttpError 400 'Request body is not valid UTF-8.') }
    }

    return [pscustomobject]@{
        Method  = $method
        Path    = $path
        Query   = $query
        Headers = $headers
        Body    = $body
    }
}

function Get-WsReasonPhrase {
    param([int]$Status)
    switch ($Status) {
        200 { 'OK' }
        202 { 'Accepted' }
        204 { 'No Content' }
        400 { 'Bad Request' }
        401 { 'Unauthorized' }
        403 { 'Forbidden' }
        404 { 'Not Found' }
        405 { 'Method Not Allowed' }
        408 { 'Request Timeout' }
        409 { 'Conflict' }
        413 { 'Payload Too Large' }
        431 { 'Request Header Fields Too Large' }
        500 { 'Internal Server Error' }
        501 { 'Not Implemented' }
        default { 'Unknown' }
    }
}

function Write-WsHttpResponse {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][System.IO.Stream]$Stream,
        [Parameter(Mandatory)][int]$Status,
        [string]$ContentType = 'text/plain; charset=utf-8',
        [AllowNull()]$Body = $null,
        [System.Collections.IDictionary]$Headers
    )
    $utf8 = New-Object System.Text.UTF8Encoding ($false)
    [byte[]]$bodyBytes = New-Object byte[] 0
    if ($null -ne $Body) {
        if ($Body -is [byte[]]) { $bodyBytes = $Body }
        else { $bodyBytes = $utf8.GetBytes([string]$Body) }
    }
    if ($ContentType -match '[\r\n]') { throw 'Invalid Content-Type.' }
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.Append('HTTP/1.1 ').Append($Status).Append(' ').Append((Get-WsReasonPhrase $Status)).Append("`r`n")
    [void]$sb.Append('Content-Type: ').Append($ContentType).Append("`r`n")
    [void]$sb.Append('Content-Length: ').Append($bodyBytes.Length).Append("`r`n")
    [void]$sb.Append("Connection: close`r`n")
    [void]$sb.Append("Cache-Control: no-store`r`n")
    [void]$sb.Append("X-Content-Type-Options: nosniff`r`n")
    [void]$sb.Append("X-Frame-Options: DENY`r`n")
    [void]$sb.Append("Referrer-Policy: no-referrer`r`n")
    [void]$sb.Append("Content-Security-Policy: default-src 'self'; img-src 'self' data:; style-src 'self'; script-src 'self'; connect-src 'self'; frame-ancestors 'none'; base-uri 'none'; form-action 'none'`r`n")
    if ($null -ne $Headers) {
        foreach ($key in $Headers.Keys) {
            $name = [string]$key
            $value = [string]$Headers[$key]
            if ($name -notmatch '^[A-Za-z0-9-]+$' -or $value -match '[\r\n]') { throw 'Invalid response header.' }
            [void]$sb.Append($name).Append(': ').Append($value).Append("`r`n")
        }
    }
    [void]$sb.Append("`r`n")
    $headBytes = $utf8.GetBytes($sb.ToString())
    $out = New-Object byte[] ($headBytes.Length + $bodyBytes.Length)
    [Array]::Copy($headBytes, 0, $out, 0, $headBytes.Length)
    if ($bodyBytes.Length -gt 0) { [Array]::Copy($bodyBytes, 0, $out, $headBytes.Length, $bodyBytes.Length) }
    $Stream.Write($out, 0, $out.Length)
    $Stream.Flush()
}

function ConvertTo-WsJson {
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowNull()]$Object)
    if ($null -eq $Object) { return 'null' }
    $json = ConvertTo-Json -InputObject $Object -Compress -Depth 8
    if ($null -eq $json) { return 'null' }
    $sb = New-Object System.Text.StringBuilder
    foreach ($ch in $json.ToCharArray()) {
        if ([int]$ch -gt 0x7E) { [void]$sb.Append('\u').Append(([int]$ch).ToString('x4')) }
        else { [void]$sb.Append($ch) }
    }
    return $sb.ToString()
}

function Write-WsJsonResponse {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][System.IO.Stream]$Stream,
        [Parameter(Mandatory)][int]$Status,
        [Parameter(Mandatory)][AllowNull()]$Object
    )
    $json = ConvertTo-WsJson -Object $Object
    Write-WsHttpResponse -Stream $Stream -Status $Status -ContentType 'application/json; charset=utf-8' -Body $json
}

function Test-WsConstantTimeEqual {
    param([string]$A, [string]$B)
    $diff = $A.Length -bxor $B.Length
    $max = [Math]::Max($A.Length, $B.Length)
    for ($i = 0; $i -lt $max; $i++) {
        $ca = 0; $cb = 0
        if ($i -lt $A.Length) { $ca = [int]$A[$i] }
        if ($i -lt $B.Length) { $cb = [int]$B[$i] }
        $diff = $diff -bor ($ca -bxor $cb)
    }
    return ($diff -eq 0)
}

function Test-WsRequestAllowed {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Request,
        [Parameter(Mandatory)][int]$Port,
        [string]$Token,
        [switch]$RequireToken
    )
    if ($Request.Method -ceq 'OPTIONS') {
        return @{ Allowed = $false; Status = 405; Reason = 'OPTIONS is not allowed.' }
    }
    $headers = $Request.Headers
    $expectedHost = '127.0.0.1:' + $Port
    if (-not $headers.ContainsKey('Host') -or [string]$headers['Host'] -cne $expectedHost) {
        return @{ Allowed = $false; Status = 403; Reason = 'Host header mismatch.' }
    }
    if ($headers.ContainsKey('Origin') -and [string]$headers['Origin'] -cne ('http://' + $expectedHost)) {
        return @{ Allowed = $false; Status = 403; Reason = 'Origin header mismatch.' }
    }
    if ($RequireToken) {
        $supplied = ''
        if ($headers.ContainsKey('X-WS-Token')) { $supplied = [string]$headers['X-WS-Token'] }
        $expectedToken = ''
        if ($null -ne $Token) { $expectedToken = $Token }
        $same = Test-WsConstantTimeEqual $supplied $expectedToken
        if (-not $same -or $expectedToken.Length -eq 0) {
            return @{ Allowed = $false; Status = 401; Reason = 'Missing or invalid token.' }
        }
    }
    return @{ Allowed = $true; Status = 200; Reason = '' }
}

function Get-WsStaticFile {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$GuiRoot
    )
    # Fixed map; the request path never becomes part of a file path.
    $name = $null
    $type = $null
    switch -CaseSensitive ($Path) {
        '/'            { $name = 'index.html'; $type = 'text/html; charset=utf-8' }
        '/index.html'  { $name = 'index.html'; $type = 'text/html; charset=utf-8' }
        '/app.js'      { $name = 'app.js'; $type = 'application/javascript; charset=utf-8' }
        '/app.css'     { $name = 'app.css'; $type = 'text/css; charset=utf-8' }
        '/favicon.svg' { $name = 'favicon.svg'; $type = 'image/svg+xml' }
    }
    if ($null -eq $name) { return $null }
    $file = Join-Path $GuiRoot $name
    if (-not (Test-Path -LiteralPath $file -PathType Leaf)) { return $null }
    return @{ Bytes = [byte[]][System.IO.File]::ReadAllBytes($file); ContentType = $type }
}

Export-ModuleMember -Function Read-WsHttpRequest, Write-WsHttpResponse, Write-WsJsonResponse, Test-WsRequestAllowed, Get-WsStaticFile, ConvertTo-WsJson
