# WorkspaceShare GUI – Implementation contract v1

Binding for all GUI work; see `docs/GUI_PLAN.md` for the why. Every piece is written
against this contract so the parts can be built in parallel. Change the contract first,
then the code.

## 1. Compatibility rules for all new GUI code

- Must run unchanged on **Windows PowerShell 5.1** (the product host) and must parse on
  **PowerShell 7** (the future Linux host). No `??`, `?.`, ternary `a ? b : c`,
  `ConvertFrom-Json -AsHashtable`, `ForEach-Object -Parallel`, `&&`/`||` pipeline chains.
- No `Add-Type -TypeDefinition` / `-MemberDefinition` (no runtime-compiled assemblies).
  `Add-Type -AssemblyName <inbox assembly>` is allowed, only inside the platform module.
- Every OS-specific call (dialogs, browser start, clipboard, host paths, data folder) goes
  through `scripts\WorkspaceShare.Platform.psm1`. No other GUI file may call
  `System.Windows.Forms`, `explorer.exe`, `$env:LOCALAPPDATA` etc. directly.
- `Set-StrictMode -Version Latest`, `$ErrorActionPreference='Stop'`.
- All `.ps1`/`.psm1` files UTF-8 **with BOM**; HTML/JS/CSS UTF-8 without BOM.
- German user-facing text; sparse English code comments.

## 2. Event stream of `Share-Workspace.ps1 -EventStream`

One event per line on **stdout**, written with `[Console]::Out.WriteLine(...)` followed by
`[Console]::Out.Flush()`:

```
@@WSEVENT@@ {"v":1,"type":"step","ts":"2026-10-16T18:00:00.0000000Z","n":3,"total":8,"text":"Finaler Archivscan wird vorbereitet ..."}
```

- Prefix exactly `@@WSEVENT@@ ` (one trailing space), then compact JSON on one line.
- All non-ASCII characters in the JSON are escaped as `\uXXXX`, so the line survives any
  console code page.
- Every event has `"v":1`, `"type"` and `"ts"` (UTC, `ToString('o')`).

| type | additional fields | when |
|---|---|---|
| `start` | `pid`, `version` | right after parameter validation |
| `step` | `n`, `total`, `text` | inside `Write-Step` |
| `session` | `path` (final session directory) | once the final session folder exists |
| `ready` | `url`, `expiresUtc`, `sizeBytes`, `sha256` | when the link is printed – the **only** event carrying the URL |
| `status` | `remainingMinutes`, `text` | where the "Verbleibend" line is printed |
| `health` | `state` (`ok`/`degraded`/`recovered`), `text` | where the monitor reports an outage or a recovery |
| `warning` | `text` | for the launcher's own `Write-Warning` calls |
| `ended` | `exitCode`, `reason`, `message` | exactly once, at the very end (also on failure) |

All `text`/`message` fields go through `Protect-DiagnosticText`. Without `-EventStream`
the console behaviour is unchanged.

`-ParentProcessId <int>`: at start the launcher records that process's start time. If the
process disappears later (or the PID then has another start time), `Test-StopRequested`
returns true with stop reason `ParentExited`; cleanup is the normal stop path.

`-TestStopAfterSnapshot` (only together with `-TestMode`, otherwise exit 10): after the
snapshot is created and verified (end of step 4) the launcher ends with exit 0 and reason
`TestSnapshotOnly`, without starting miniserve or cloudflared. For tests without network.

## 3. Platform module `scripts\WorkspaceShare.Platform.psm1`

```
Get-WsPlatform                           -> 'windows' | 'linux' | 'macos'
Get-WsCapabilities                       -> @{ folderPicker=[bool]; clipboard=[bool]; openBrowser=[bool] }
Get-WsDataRoot                           -> per-user data folder (Windows: %LOCALAPPDATA%\WorkspaceShare), created if missing
Get-WsPowerShellHost                     -> full path of the host for child scripts
                                            (Windows: %SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe)
Open-WsBrowser -Url <string>             -> starts the default browser; $true/$false
Show-WsFolderPicker [-InitialPath <s>]   -> selected full path, or $null on cancel/unsupported
Set-WsClipboardText -Text <string>       -> $true/$false; excludes Win+V history and cloud clipboard
Clear-WsClipboardText -Expected <string> -> clears only if the clipboard still equals Expected; $true/$false
```

Linux/macOS branches exist but report "unsupported" (`$null` / `$false`, capabilities
`$false`, `Get-WsPowerShellHost` returns the `pwsh` path) until the Linux port
(`docs/LINUX_PLAN.md`).

## 4. HTTP module `scripts\WorkspaceShare.Gui.Http.psm1`

Pure functions over streams, no OS specifics:

```
Read-WsHttpRequest -Stream <IO.Stream> [-MaxHeaderBytes 16384] [-MaxBodyBytes 65536] [-TimeoutMs 5000]
    -> [pscustomobject]@{ Method; Path; Query; Headers (case-insensitive hashtable); Body (UTF-8 string) }
       throws an exception with .Data['WsHttpStatus'] = 400|408|413|431 on bad input
Write-WsHttpResponse -Stream <IO.Stream> -Status <int> [-ContentType <string>] [-Body <string|byte[]>] [-Headers <hashtable>]
    always adds: Connection: close; Cache-Control: no-store; X-Content-Type-Options: nosniff;
    X-Frame-Options: DENY; Referrer-Policy: no-referrer;
    Content-Security-Policy: default-src 'self'; img-src 'self' data:; style-src 'self'; script-src 'self'; connect-src 'self'; frame-ancestors 'none'; base-uri 'none'; form-action 'none'
Write-WsJsonResponse -Stream <IO.Stream> -Status <int> -Object <object>
Test-WsRequestAllowed -Request <obj> -Port <int> -Token <string> [-RequireToken]
    -> @{ Allowed=[bool]; Status=<int>; Reason=<string> }
       Host must equal "127.0.0.1:<port>" exactly (403 otherwise); an Origin header, if present,
       must equal "http://127.0.0.1:<port>" (403); with -RequireToken the X-WS-Token header must
       match (constant-time compare, 401); OPTIONS is always rejected (405).
Get-WsStaticFile -Path <string> -GuiRoot <string>
    -> @{ Bytes=[byte[]]; ContentType=<string> } only for '/', '/index.html', '/app.js', '/app.css',
       '/favicon.svg'; $null otherwise. Never builds a file path from request input.
ConvertTo-WsJson -Object <object> -> compact JSON, non-ASCII escaped as \uXXXX (PS 5.1 safe)
```

## 5. Backend `Start-WorkspaceShareGui.ps1` – HTTP API

Parameters: `[-Port 0] [-NoBrowser] [-InstanceFile <path>] [-TestMode] [-TestShareScript <path>]`.
`-TestShareScript` requires `-TestMode` and replaces `Share-Workspace.ps1` (a fake share for
tests). The instance file (default `<DataRoot>\gui-instance.json`) holds
`{"pid":..,"startTicks":..,"port":..,"token":".."}`, is written after binding and deleted on
exit. Single instance via named mutex `Local\WorkspaceShare.Gui` (test mode: that name plus a
hash of the instance-file path). A second start while an instance is alive only opens the
browser at the existing URL and exits 0.

Static (Host check applies, no token): `GET /`, `/index.html`, `/app.js`, `/app.css`, `/favicon.svg`.
The browser URL is `http://127.0.0.1:<port>/#<token>`. `app.js` reads the token from
`location.hash`, removes it with `history.replaceState`, and sends it as `X-WS-Token` on every
`/api/*` call. Every `/api/*` call requires the token. Request bodies are JSON.

| Method + path | Body | 200 response |
|---|---|---|
| `GET /api/state` | – | state object (below) |
| `POST /api/pick-folder` | `{}` | `{"path":"C:\\..."}` or `{"cancelled":true}`; 409 unless phase is `idle`/`ended`/`error`; 501 if unsupported |
| `POST /api/start` | `{"path":"..","minutes":240,"compression":"Fast","includeGenerated":false}` | `{"ok":true}`; 400 `{"error":".."}` invalid input; 409 share running |
| `POST /api/stop` | `{}` | `{"ok":true}` – writes `stop.requested`; before the `session` event it kills the child |
| `POST /api/copy` | `{}` | `{"ok":true}`; 409 if no link |
| `POST /api/quit` | `{}` | `{"ok":true}`; stops a running share first, then the backend exits |

Validation for `/api/start`: `path` is an existing folder; `minutes` integer 1..1440;
`compression` `Fast`|`Store`; `includeGenerated` boolean. Child command line:
`<Get-WsPowerShellHost> -NoLogo -NoProfile -NonInteractive -File <Share-Workspace.ps1> -Path <path> -Minutes <m> -Compression <c> [-IncludeGenerated] -NoClipboard -EventStream -ParentProcessId <backendPid>`
(each argument quoted with the Windows argv rules).

State object:

```json
{
  "v": 1,
  "phase": "idle",
  "platform": "windows",
  "capabilities": {"folderPicker": true, "clipboard": true, "openBrowser": true},
  "step": 0, "total": 8, "stepText": null,
  "steps": [{"n": 1, "text": "..."}],
  "url": null, "expiresUtc": null, "sizeBytes": null, "sha256": null,
  "remainingMinutes": null, "health": null,
  "exitCode": null, "reason": null, "message": null,
  "log": ["last 200 redacted non-event lines"],
  "request": {"path": "..", "minutes": 240, "compression": "Fast", "includeGenerated": false}
}
```

`phase` values: `idle` before the first start; `starting` from start until `ready`; `active`
after `ready`; `stopping` after `/api/stop` or `/api/quit`; `ended` when the child exited with
0; `error` when it exited non-zero (message from the `ended` event, else the last log line).

## 6. Front end `gui\` (no build step, no external resources)

`gui\index.html`, `gui\app.js`, `gui\app.css`, `gui\favicon.svg`. Polls `GET /api/state` every
1000 ms. Hides "Ordner wählen…" when `capabilities.folderPicker` is false (Linux prep).
Error texts for exit codes come from a table in `app.js` that mirrors the README table.
