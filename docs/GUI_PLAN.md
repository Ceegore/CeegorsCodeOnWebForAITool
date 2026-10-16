# WorkspaceShare GUI – Plan (not implemented yet)

Status: implemented 2026-10-16 (steps 1–7 of §8; the binding interfaces are in
`docs/GUI_CONTRACT.md`). Step 8, manual acceptance through the shortcut on the SAC
machine, is still open. Linux port: `docs/LINUX_PLAN.md`.

## 1. Goal

A very simple GUI on top of the existing, tested `Share-Workspace.ps1`:

1. pick a folder,
2. pick a duration (and optionally "Store" compression / include generated files),
3. press **Freigeben**, watch the 8 steps progress,
4. get the link with a **Kopieren** button and the expiry time,
5. press **Beenden** to stop early; see "beendet" when the share ends.

The GUI must not re-implement any security logic. All gates (snapshot, excludes,
gitleaks, local/public checks, Job Object, watchdog, cleanup) stay in
`Share-Workspace.ps1`. The GUI only starts it, reads its progress, shows the link
and requests a stop.

## 2. Hard constraint: Smart App Control (SAC)

This machine runs with SAC **on** (`VerifiedAndReputablePolicyState = 1`). Rules taken
from `C:\Projects\_SACsolutions.md` and from measurements made on 2026-10-16:

| Rule | Consequence for the GUI |
|---|---|
| No new unsigned PE images (no `.exe`/`.dll` we build) | No C#/.NET/Electron/Tauri/Go GUI binary. No `Add-Type -TypeDefinition` in GUI code. |
| Source-only PowerShell 5.1 in the Microsoft-signed `powershell.exe` is the measured working path (§9 of the SAC guide) | The GUI backend is a `.ps1` script that uses only inbox .NET types. |
| `.cmd`/`.bat` launched from an extracted download is blocked (§12) | Start through a `.lnk` shortcut whose target is `powershell.exe`, not through a `.cmd`. |
| No `-ExecutionPolicy Bypass`, no `Unblock-File` as product steps (§7, §9) | Use a git clone (no Mark-of-the-Web) and the existing `RemoteSigned` policy. |
| Keep `.ps1` files UTF-8 **with BOM** (§9.3) | All new GUI files are saved as UTF-8 with BOM. |

Measured on 2026-10-16 in a clean clone with SAC on: the full existing test suite
(105 + 24 + 1 tests) passed and Code Integrity logged **0** events 3033/3077. So the
existing third-party binaries (`cloudflared` signed; `miniserve`, `gitleaks`, `7za`
unsigned but with public reputation) and the existing `Add-Type` P/Invoke modules load
today. Per §9.2 of the SAC guide a pass can be transient. The GUI must therefore
detect and report a block (see §7) instead of assuming it never happens.

A browser GUI fits these rules: the browser (Edge/Chrome, signed) renders plain
HTML/CSS/JS, and the backend is the same signed `powershell.exe` that already runs
the tool. No new PE image is created anywhere.

## 3. Architecture

```
 Browser tab (Edge/Chrome)                 powershell.exe #1  (GUI backend, -STA, hidden)
 http://127.0.0.1:<port>/                  Start-WorkspaceShareGui.ps1
   index.html + app.js   --- fetch/JSON --> TcpListener on 127.0.0.1:<random port>
                                            - serves gui\index.html, gui\app.js, gui\app.css
                                            - /api/state, /api/start, /api/stop, /api/pick-folder
                                            - holds the share link in memory only
                                                 |
                                                 | stdout pipe (JSON lines), no files
                                                 v
                                            powershell.exe #2  Share-Workspace.ps1 -EventStream
                                            (unchanged security logic, own Job Object,
                                             own watchdog, miniserve, cloudflared)
```

### 3.1 Why a raw `TcpListener` and not `HttpListener`

`System.Net.HttpListener` goes through http.sys and URL ACLs. `TcpListener` bound to
`127.0.0.1` needs no ACL, no admin rights and no firewall rule, and it never listens
on a LAN interface. The HTTP needed is tiny: GET for 3 static files, GET/POST for
4 JSON endpoints, `Connection: close`, no keep-alive, request bodies ≤ 4 KB. A
~150-line PowerShell request parser is enough and easy to test.

### 3.2 Why a separate process for the share

`Share-Workspace.ps1` is a long-running, fail-closed script with its own
`try/finally`, Job Object, watchdog and exit codes. Running it as a child process
keeps all of that unchanged and lets the GUI survive a failed share (show the exit
code and message, allow a retry).

## 4. Changes to the existing tool (small, testable)

1. **`-EventStream` switch in `Share-Workspace.ps1`.** When set, the script also
   writes one JSON object per line to stdout through a single helper
   `Write-ShareEvent`:
   - `{"type":"step","n":3,"total":8,"text":"..."}` (emitted inside `Write-Step`)
   - `{"type":"ready","url":"https://…/d/<token>/<file>.zip","expiresUtc":"…","sizeBytes":…,"sha256":"…"}`
   - `{"type":"health","state":"ok|degraded","text":"…"}`
   - `{"type":"ended","exitCode":0,"reason":"Expired|ManualStop|…","message":"…"}`

   The link travels only over the anonymous stdout pipe to the parent process. It is
   **never** written to a file, a log, `session.json` or a command line. That matches
   today's rule ("session.json enthält niemals Capability-Token oder Link").
   Human-readable `Write-Host` output stays unchanged for console use.
2. **`-NoClipboard` is passed by the GUI.** The GUI copies on button press, using the
   same history-excluding clipboard routine (`Copy-LinkToClipboard`), so the link does
   not land in Win+V history.
3. **`-ParentProcessId <pid>`** (optional). The share stops cooperatively (same path
   as `stop.requested`) if the GUI backend process disappears. Without it, a crashed
   GUI would leave a share running with no window.
4. **Stop request.** The GUI writes `stop.requested` into the session folder, which is
   the mechanism `Stop-WorkspaceShare.ps1` already uses. The session folder is known
   from a `{"type":"session","path":"…"}` event that contains no secret.

No change to the gates, the Job module or the dependency lock.

## 5. GUI backend `Start-WorkspaceShareGui.ps1`

- `#requires -Version 5.1`; runs with `-NoLogo -NoProfile -STA -WindowStyle Hidden`.
- Uses only inbox types: `System.Net.Sockets.TcpListener`, `System.Diagnostics.Process`,
  `System.Windows.Forms.FolderBrowserDialog` (loaded with `Add-Type -AssemblyName`,
  which loads a signed GAC assembly and compiles nothing).
- Startup:
  1. Verifies `dependencies.lock.json` (reuses `WorkspaceShare.Dependency.psm1`) and
     shows a clear page if dependencies are missing, with the exact command
     `.\Install-Dependencies.ps1`.
  2. Binds `127.0.0.1:0` (OS-chosen free port).
  3. Generates a 256-bit **GUI session token** (same generator as the share token).
  4. Opens the default browser at `http://127.0.0.1:<port>/#<guiToken>` with
     `Start-Process`. The token sits in the fragment, so it never appears in a request
     line or in proxy/server logs. `app.js` sends it in an `X-WS-Token` header.
- Request handling (single-threaded loop with `Pending()` polling every 100 ms, which
  also polls the child's stdout):
  - Reject unless `Host` is exactly `127.0.0.1:<port>` (blocks DNS rebinding).
  - Every `/api/*` request needs the `X-WS-Token` header (constant-time compare). A
    custom header also forces a CORS preflight, so a hostile web page cannot POST
    to the API. No CORS headers are ever sent.
  - Response headers: `Cache-Control: no-store`, a strict
    `Content-Security-Policy: default-src 'self'`, `X-Frame-Options: DENY`,
    `Referrer-Policy: no-referrer`.
- Endpoints:
  - `GET /api/state` → `{phase, step, total, text, url?, expiresUtc?, error?}`. The URL
    is returned only to a request with the GUI token.
  - `POST /api/pick-folder` → opens `FolderBrowserDialog` on a hidden `TopMost` owner
    form and returns the path. A browser cannot provide a full local folder path, so
    the native dialog is the reliable way. A plain text field stays as a fallback.
  - `POST /api/start {path, minutes, compression, includeGenerated}` → validates the
    input (folder exists, 1..1440 minutes, enum values), then starts
    `powershell.exe -NoLogo -NoProfile -File Share-Workspace.ps1 -Path … -Minutes …
    -NoClipboard -EventStream -ParentProcessId <pid>` with
    `RedirectStandardOutput/Error`, `UseShellExecute=$false`, `CreateNoWindow=$true`.
    Arguments are passed as a properly quoted string (one quoting helper, unit-tested
    with spaces, quotes and trailing backslashes). Only one share at a time.
  - `POST /api/stop` → creates `stop.requested` in the announced session folder.
  - `POST /api/copy` → copies the link (history-excluded) on the backend side.
  - `POST /api/quit` → stops a running share (stop request, then wait for the
    `ended` event), then exits the backend.
- Child output: read with `StandardOutput.ReadLineAsync()` tasks polled in the loop;
  lines that are not JSON events are kept (redacted with the existing
  `Protect-DiagnosticText`) for an expandable "Details" panel.
- When the browser tab is closed the share keeps running. Re-opening the shortcut
  finds the running backend through a named mutex
  `Local\WorkspaceShare.Gui` and opens the existing URL. A second backend is never
  started.

## 6. Front end (`gui\index.html`, `gui\app.js`, `gui\app.css`)

- Plain HTML/CSS/JS, no framework, no CDN, no external fonts. Everything is served
  from the backend (`default-src 'self'`) and works offline.
- One card, three states:
  1. **Bereit**: folder field + "Ordner wählen…", duration select (15 min, 1 h, 4 h,
     8 h, 24 h), an "Erweitert" disclosure with compression and "Build-Ordner
     einschließen", and a big **Freigeben** button.
  2. **Läuft**: an 8-step progress list with the current step text, plus
     **Abbrechen**.
  3. **Aktiv**: the link in a read-only field with **Kopieren**, "Aktiv bis HH:MM",
     a health dot, archive size, and **Freigabe beenden**.
  Failure: the German error text and exit code from the README table, plus
  "Details" with the redacted log and a "Neu versuchen" button.
- Polls `GET /api/state` every second (no WebSocket needed).
- German UI text, consistent with the console messages.

## 7. SAC-aware start and diagnostics

- `Install-GuiShortcut.ps1` (run once by the user from PowerShell) creates
  `WorkspaceShare.lnk` on the desktop and in the Start menu through
  `WScript.Shell.CreateShortcut`. Target:
  `%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe`, arguments
  `-NoLogo -NoProfile -STA -WindowStyle Hidden -File "<repo>\Start-WorkspaceShareGui.ps1"`.
  No `.cmd`, no `Bypass`.
- If a share fails with an unexpected native-process error, the backend queries
  CodeIntegrity events 3033/3077 since the start time that name `miniserve`,
  `gitleaks`, `7za`, `cloudflared` or a temp `*.dll`. If it finds one, it shows:
  "Windows Smart App Control hat <Datei> blockiert – das ist kein Fehler im Tool."
  It never suggests disabling SAC.
- A `-Diagnose` switch on the GUI script prints the same check on the console.

## 8. Implementation steps (in order)

1. `Write-ShareEvent` + `-EventStream`, `-ParentProcessId` in `Share-Workspace.ps1`.
   Add tests: event lines are valid JSON, the `ready` event is the only line that
   carries the URL, and no file in the session folder contains the token while
   `-EventStream` is on.
2. `scripts\WorkspaceShare.Gui.Http.psm1`: minimal request parser and response
   writer, Host/token checks, static file serving with a fixed allow-list (no path
   from the request touches the file system).
   Unit tests: malformed requests, oversized headers/body, wrong Host, missing or
   wrong token, path traversal attempts, preflight rejection.
3. `Start-WorkspaceShareGui.ps1`: loop, child-process management, state machine,
   folder picker, single-instance mutex.
4. `gui\index.html`, `gui\app.js`, `gui\app.css`.
5. `Install-GuiShortcut.ps1`.
6. Tests in `tests\Test-WorkspaceShareGui.ps1`, no public tunnel needed:
   - start the backend with a `-TestMode` that runs a fake share script emitting
     scripted events; drive the API with `curl.exe` (start → steps → ready → stop →
     ended), check the security headers, and check that the link is absent from all
     files written under `%LOCALAPPDATA%\WorkspaceShare`;
   - run the CodeIntegrity 3033/3077 check after the test and fail with a distinct
     exit code 42 ("Umgebung blockiert") if anything was blocked.
   Add the suite to `.github/workflows/windows-tests.yml`.
7. README section "GUI" (German): one-time `Install-GuiShortcut.ps1`, then start via the
   shortcut.
8. Manual acceptance on this SAC machine: start via the shortcut, share a small test
   folder for 15 minutes, download the link from a second device, stop early, and
   confirm 0 CodeIntegrity events.

Rough size: about 600–900 lines of PowerShell + 300 lines of HTML/JS/CSS + about 300
lines of tests.

## 9. Fallback if the browser route is ever not acceptable

Same backend logic, but a source-only **WinForms** window
(`System.Windows.Forms`, loaded with `Add-Type -AssemblyName`) in the same
`powershell.exe -STA` host. This is the exact pattern the SAC guide measured as
working (§9, ClipPlayer with WPF). No HTTP server is needed then; the child-process
and event-stream parts (§4) stay identical. It is less pretty, but even more
self-contained.

Not recommended: Electron/Tauri/.NET/Go GUI executables, PowerShell
`Add-Type -TypeDefinition` for the GUI, PS2EXE-style wrappers. Each produces a new
unsigned PE image that SAC can block (SAC guide §3, §6, §10, §12), and distributing
them would need a CA or Store signature.

## 10. Open risks

- **Existing `Add-Type -TypeDefinition` modules** (`WorkspaceShare.Job.psm1`,
  `WorkspaceShare.Path.psm1`, `Enable-SystemAwake`) compile C# at runtime. They
  loaded with 0 Code Integrity events on 2026-10-16, but that can change (SAC guide
  §9.2). The diagnostics in §7 make a block visible. Removing these modules would
  mean losing the Job Object and handle-identity checks, so they stay for now.
- **Unsigned third-party binaries** (`miniserve`, `gitleaks`, `7za`) rely on public
  reputation. A future version bump gives a new hash that needs a new SAC verdict.
  Test every pin update on this machine with the CodeIntegrity check before release.
- **Browser autofill and extensions** can read the page. The link is shown only in
  the active state, and closing the tab does not end the share.
