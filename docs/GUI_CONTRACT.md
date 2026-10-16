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

Parameters: `[-Port 0] [-NoBrowser] [-InstanceFile <path>] [-TestMode] [-TestShareScript <path>] [-TestBuildId <id>]`.
`-TestShareScript` and `-TestBuildId` require `-TestMode`; the first replaces `Share-Workspace.ps1`
(a fake share for tests), the second overrides the build id (`[A-Za-z0-9_-]{1,64}`). The instance
file (default `<DataRoot>\gui-instance.json`) holds
`{"pid":..,"startTicks":..,"port":..,"token":"..","build":".."}`, is written after binding and
deleted on exit. Single instance via named mutex `Local\WorkspaceShare.Gui` (test mode: that name
plus a hash of the instance-file path).

**Build id, static cache, update takeover.**

- `build` = first 16 lowercase hex chars of SHA-256 over the bytes of `VERSION`,
  `Start-WorkspaceShareGui.ps1`, `scripts/WorkspaceShare.Gui.Http.psm1`,
  `scripts/WorkspaceShare.Platform.psm1`, `gui/index.html`, `gui/app.js`, `gui/app.css`,
  `gui/favicon.svg` (in that order, concatenated; a missing file contributes its name only). It is
  written to the instance file and returned as `"build"` in `/api/state`.
- The static files are loaded **once at backend start** (via `Get-WsStaticFile`, one call per
  allowed path) and served from memory, so UI and API always belong to the same version. A file
  missing at start gives 404 for its route, as before. Changing the files on disk later has no
  effect until the backend is restarted.
- A second start that finds a live instance compares builds. **Same build:** open the existing
  URL, exit 0. **Different or missing `build`** (older version): read its `/api/state` (raw
  loopback request with its token, 5 s timeout). Phase `idle`/`ended`/`error`: `POST /api/quit`,
  wait up to 20 s until that PID is gone and the mutex is free, then start normally as the new
  instance (browser at the new URL unless `-NoBrowser`). Phase `starting`/`active`/`stopping`:
  the share is never interrupted; the browser opens at the old instance, the console prints "Eine
  laufende Freigabe nutzt noch die vorherige Version. ..." and the process exits 0. No answer
  within 5 s (PID alive): nothing is killed; the old URL is opened and the process exits 0.
- `app.js` shows a "service outdated" message (and disables the drop zone) when an `/api/drop/*`
  call returns 404 or `/api/state` has no `limits`; if `build` changes between polls it stops
  polling and asks to close the window and reopen it via the shortcut.

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
  "build": "0123456789abcdef",
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

## 7. Drag & drop of files (contract v1.1)

Goal: files (and optionally folders) dragged from Windows Explorer – or any Linux file
manager – into the browser page are copied into a private temporary folder, and that
folder is then shared through the **unchanged** `Share-Workspace.ps1` process, exactly like a
folder the user picked. Everything here is platform-neutral: the browser File API on the
client, plain .NET streams on the backend, the folder under `Get-WsDataRoot`. No new
platform-module function is needed, so it works on Linux as soon as the backend runs on `pwsh`.

### 7.1 Drop folder

- `<DataRoot>/drops/<dropId>/<leaf>`; `dropId` = 32 lowercase hex chars (random);
  `<leaf>` = `Dateien-yyyyMMdd-HHmmss` (local time). The leaf is the folder that gets shared, so
  the recipient's ZIP gets a meaningful name. Built with `Join-Path` only.
- `drops` is a sibling of `sessions`/`staging`/`diagnostics`, never inside them.
- At most one drop exists at a time. A new `begin` discards the previous unused drop.
- Cleanup: the backend deletes a drop folder (a) when its share ends (phase `ended`/`error`),
  (b) on `/api/drop/discard`, (c) on `/api/quit` / backend exit, and (d) at backend start for
  every drop folder not owned by this process (stale after a crash).

### 7.2 Endpoints (token required, only in phase `idle`/`ended`/`error`, else 409)

| Method + path | Body | 200 response |
|---|---|---|
| `POST /api/drop/begin` | `{}` | `{"dropId":"<hex>"}` |
| `POST /api/drop/file?drop=<dropId>&path=<urlencoded relative path>` | raw file bytes, `Content-Type: application/octet-stream`, `Content-Length` required | `{"ok":true,"bytes":n}` |
| `POST /api/drop/finish` | `{"dropId":".."}` | `{"path":"<full drop leaf path>","files":n,"totalBytes":n}`; 400 if no file was received |
| `POST /api/drop/discard` | `{"dropId":".."}` | `{"ok":true}` |

Errors: 400 invalid path/name or unknown dropId; 409 duplicate path or wrong phase;
411 missing Content-Length; 413 file or total too large; 507 not enough disk space
(Content-Length + 512 MiB headroom must fit on the data drive). A failed or aborted file
upload deletes the partial file.

Relative path rules (both OSes, checked on the backend): segments separated by `/`;
1–64 segments; each segment 1–255 chars; not `.` or `..`; no control chars; none of
`< > : " \ | ? *`; no trailing dot or space; not a Windows reserved name (`CON`, `PRN`, `AUX`,
`NUL`, `COM1`–`COM9`, `LPT1`–`LPT9`, also with an extension); whole path at most 400 chars. The
final full path must stay inside the drop leaf (`GetFullPath` prefix check).

Limits (backend parameters): `-MaxDropBytes` (default 4 GiB, applies per file and in total),
`-MaxDropFiles` (default 10000).

### 7.3 HTTP module additions

```
Read-WsHttpRequest ... [-HeadersOnly]
    -> with -HeadersOnly the body is not read; the result additionally has
       ContentLength ([int64], -1 if absent) and BodyPrefix ([byte[]] bytes already read past the headers)
Copy-WsHttpBody -Stream <IO.Stream> -Request <obj from -HeadersOnly> -Destination <IO.Stream>
                [-MaxBytes <int64>] [-IdleTimeoutMs 30000]
    -> copies exactly ContentLength bytes (BodyPrefix first) in 64 KiB chunks; throws with
       Data['WsHttpStatus'] = 400 (stream ended early), 408 (idle timeout), 413 (> MaxBytes)
```

### 7.4 State object additions

`"drop": null` or `{"id":"..","path":"..","files":n,"totalBytes":n,"finished":true|false}`,
and `"limits": {"maxDropBytes":n,"maxDropFiles":n}`. When a share is started with
`path` equal to the finished drop path, the backend marks the drop as in use and deletes it
after that share ends.

### 7.5 Front end

- A drop zone in the form view ("Dateien oder Ordner hierher ziehen") plus a button
  "Dateien auswählen…" (`<input type="file" multiple>`, works everywhere, also on Linux).
- `dragover`/`drop` are prevented on `window`, so a file dropped outside the zone never makes
  the browser open it.
- Folders: `DataTransferItem.webkitGetAsEntry()` recursively; relative paths are kept (`/`).
- Upload: `begin`, then files one after another (`fetch` with the `File` as body), with a
  progress bar (bytes done / total), then `finish`. On success the folder field shows the drop
  path read-only plus a summary ("3 Dateien, 12,4 MB") and an "Entfernen" button (`discard`).
  Picking or typing another folder discards the drop.
- Client-side pre-checks mirror the limits in `state.limits`; the backend stays authoritative.
