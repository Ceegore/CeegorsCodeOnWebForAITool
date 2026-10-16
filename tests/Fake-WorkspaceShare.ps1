#requires -Version 5.1
# Fake Share-Workspace.ps1 for the GUI backend tests. Emits the GUI_CONTRACT section 2 event stream.
# Scenario from env WS_FAKE_SCENARIO: success (default) | fail22 | parent | hang.
# Optional env WS_FAKE_PIDFILE: file that receives this process id (and "<file>.session" the session path).
[CmdletBinding()]
param(
    [string]$Path,
    [int]$Minutes = 0,
    [string]$Compression,
    [switch]$IncludeGenerated,
    [switch]$NoClipboard,
    [switch]$EventStream,
    [int]$ParentProcessId = 0,
    [Parameter(ValueFromRemainingArguments = $true)]$Rest
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$scenario = $env:WS_FAKE_SCENARIO
if ([string]::IsNullOrWhiteSpace($scenario)) { $scenario = 'success' }
$pidFile = $env:WS_FAKE_PIDFILE
if (-not [string]::IsNullOrWhiteSpace($pidFile)) {
    [IO.File]::WriteAllText($pidFile, [string]$PID, (New-Object System.Text.UTF8Encoding($false)))
}

function Send-Event {
    param([string]$Type, [System.Collections.IDictionary]$Fields)
    $o = [ordered]@{ v = 1; type = $Type; ts = [DateTime]::UtcNow.ToString('o') }
    if ($null -ne $Fields) { foreach ($k in $Fields.Keys) { $o[$k] = $Fields[$k] } }
    $json = ConvertTo-Json -InputObject $o -Compress -Depth 5
    $sb = New-Object System.Text.StringBuilder
    foreach ($ch in $json.ToCharArray()) {
        if ([int]$ch -gt 0x7E) { [void]$sb.Append('\u').Append(([int]$ch).ToString('x4')) }
        else { [void]$sb.Append($ch) }
    }
    # A broken pipe (parent gone) must not prevent the cleanup below.
    try {
        [Console]::Out.WriteLine('@@WSEVENT@@ ' + $sb.ToString())
        [Console]::Out.Flush()
    }
    catch { }
}

$stepTexts = @(
    'Parameter werden geprüft ...', 'Werkzeuge werden geprüft ...', 'Snapshot wird erstellt ...',
    'Archiv wird erstellt ...', 'Finaler Archivscan wird vorbereitet ...', 'Lokaler Server startet ...',
    'Tunnel wird aufgebaut ...', 'Öffentlicher Link wird geprüft ...'
)

Send-Event 'start' ([ordered]@{ pid = $PID; version = 'fake' })

if ($scenario -eq 'fail22') {
    Send-Event 'step' ([ordered]@{ n = 1; total = 8; text = $stepTexts[0] })
    Start-Sleep -Milliseconds 100
    Send-Event 'step' ([ordered]@{ n = 2; total = 8; text = $stepTexts[1] })
    Start-Sleep -Milliseconds 100
    Send-Event 'ended' ([ordered]@{ exitCode = 22; reason = 'Error'; message = 'Verbotene Datei gefunden: .env' })
    exit 22
}

if ($scenario -eq 'hang') {
    # Never announces a session, so the backend can only stop it by killing the process tree.
    Send-Event 'step' ([ordered]@{ n = 1; total = 8; text = $stepTexts[0] })
    Start-Sleep -Seconds 120
    Send-Event 'ended' ([ordered]@{ exitCode = 0; reason = 'Expired'; message = '' })
    exit 0
}

for ($n = 1; $n -le 8; $n++) {
    Send-Event 'step' ([ordered]@{ n = $n; total = 8; text = $stepTexts[$n - 1] })
    Start-Sleep -Milliseconds 100
}

$session = Join-Path $env:TEMP ('ws-fake-session-' + [Guid]::NewGuid().ToString('N'))
[void](New-Item -ItemType Directory -Path $session -Force)
if (-not [string]::IsNullOrWhiteSpace($pidFile)) {
    [IO.File]::WriteAllText($pidFile + '.session', $session, (New-Object System.Text.UTF8Encoding($false)))
}
Send-Event 'session' ([ordered]@{ path = $session })

$url = 'https://fake-test.trycloudflare.com/d/' + ('a' * 43) + '/'
Send-Event 'ready' ([ordered]@{
        url = $url
        expiresUtc = [DateTime]::UtcNow.AddMinutes(1).ToString('o')
        sizeBytes = 1234
        sha256 = ('A' * 64)
    })
[Console]::Out.WriteLine('Normale Ausgabe mit Umlauten: äöü')
[Console]::Out.WriteLine('Pfad=' + $Path)
[Console]::Out.WriteLine('Link-Test: ' + $url)
[Console]::Out.Flush()
[Console]::Error.WriteLine('Hinweis auf stderr: äöü')

$stopFile = Join-Path $session 'stop.requested'
$sw = [Diagnostics.Stopwatch]::StartNew()
$tick = 0
$reason = $null
$message = ''
while ($true) {
    Start-Sleep -Milliseconds 250
    $tick++
    if (Test-Path -LiteralPath $stopFile) { $reason = 'ManualStop'; break }
    if ($scenario -eq 'parent' -and $ParentProcessId -gt 0 -and ($tick % 2) -eq 0) {
        if ($null -eq (Get-Process -Id $ParentProcessId -ErrorAction SilentlyContinue)) {
            $reason = 'ParentExited'; $message = 'Der übergeordnete Prozess wurde beendet.'; break
        }
    }
    if ($sw.Elapsed.TotalSeconds -ge 60) { $reason = 'Expired'; break }
    if (($tick % 4) -eq 0) {
        $left = [Math]::Max(0, [int][Math]::Ceiling((60 - $sw.Elapsed.TotalSeconds) / 60))
        Send-Event 'status' ([ordered]@{ remainingMinutes = $left; text = 'Verbleibend: ' + $left + ' Minute(n)' })
    }
}
Send-Event 'ended' ([ordered]@{ exitCode = 0; reason = $reason; message = $message })
try { Remove-Item -LiteralPath $session -Recurse -Force -ErrorAction SilentlyContinue } catch { }
exit 0
