# WorkspaceShare on Linux – Plan (not implemented)

Status: plan only, 2026-10-16. Windows remains the primary product. The GUI is already
built so that this port needs no second code base (see `docs/GUI_CONTRACT.md` §1 and §3).

## 1. Decision: one PowerShell code base, PowerShell 7 on Linux

| Option | Effort | Verdict |
|---|---|---|
| **Same scripts on PowerShell 7 (`pwsh`) + a platform layer** | about 1–1.5 weeks | **Chosen.** One code base, same tests, same GUI. |
| Rewrite in Python or Go for Linux | 2–3 weeks, then two code bases forever | Rejected: duplicate security logic is the expensive part. |
| Bash rewrite | similar, and much harder to make fail-closed | Rejected. |

Why the current stack is *not* too complicated for Linux:

- About 85 % of the code is plain PowerShell/.NET logic: snapshot rules, exclusions,
  manifest hashing, gitleaks/7-Zip orchestration, curl probes, health classification,
  event stream and GUI backend. All of it runs on `pwsh` 7.4+ unchanged once it parses
  there (the GUI code is already written to the shared syntax subset).
- All four external tools ship official Linux x64 builds: `cloudflared-linux-amd64`,
  `miniserve-*-x86_64-unknown-linux-musl`, `gitleaks_*_linux_x64.tar.gz` and
  7-Zip `7z*-linux-x64.tar.xz` (`7zz`).
- The Windows-only part is small and already isolated in a few places (table below).

The Windows build keeps running on Windows PowerShell 5.1, which is the measured SAC-safe
host. Linux has no SAC, so there are no code-integrity constraints there.

## 2. Windows-specific pieces and their Linux replacement

| Area | Windows today | Linux replacement | Where |
|---|---|---|---|
| Process lifetime | Job Object with kill-on-close via P/Invoke (`WorkspaceShare.Job.psm1`) | each child started with `setsid`; kill the process group (`kill -TERM -<pgid>`, then `-KILL`); the watchdog checks the parent via `/proc/<pid>/stat` start time | new `WorkspaceShare.Job.Linux.psm1` with the same exported function names |
| Child start with private stdin/env | `CreateProcess` suspended + stdin pipe | `System.Diagnostics.Process` with `RedirectStandardInput` (curl reads its config from stdin, same as now) | same module |
| Path identity, reparse points | `GetFileInformationByHandle`, reparse attribute (`WorkspaceShare.Path.psm1`) | `stat -c '%d:%i'` or `[IO.File]::ResolveLinkTarget`; reject symlinks (`LinkTarget -ne $null`) | new `WorkspaceShare.Path.Linux.psm1` |
| Process identity | `Process.StartTime` + path | same .NET API works; path from `/proc/<pid>/exe` | `WorkspaceShare.Process.psm1` (small branch) |
| DNS checks | `Resolve-DnsName` (Windows-only cmdlet) | `[System.Net.Dns]::GetHostAddresses` for the system resolver; `dig +short @1.1.1.1` (optional) for the public resolvers | `Share-Workspace.ps1` DNS helpers behind one function |
| Keep awake | `SetThreadExecutionState` (P/Invoke) | `systemd-inhibit --what=sleep --why=WorkspaceShare sleep infinity` as a tracked child; skip if missing | platform module |
| Clipboard | WinForms DataObject | `wl-copy` / `xclip -selection clipboard`; capability false if neither exists | platform module (already stubbed) |
| Folder picker | `FolderBrowserDialog` | `zenity --file-selection --directory` or `kdialog --getexistingdirectory`; capability false otherwise (the GUI then shows only the text field) | platform module (already stubbed) |
| Open browser | `Start-Process <url>` | `xdg-open <url>` | platform module (already stubbed) |
| Data folder | `%LOCALAPPDATA%\WorkspaceShare` | `$XDG_DATA_HOME/workspaceshare` or `~/.local/share/workspaceshare` | platform module (`Get-WsDataRoot`, done) |
| Named mutexes | `Threading.Mutex` named `Local\…` | .NET named mutexes work on Linux only inside one session, so use an exclusive lock file (`[IO.File]::Open(..., FileShare.None)`) | `WorkspaceShare.Dependency.psm1`, installer, GUI single instance |
| Executable names | `bin\cloudflared.exe` etc. | `bin/linux-x64/cloudflared` etc.; the lockfile gets a `platform` field (already present: `windows-x64`) | `Install-Dependencies.ps1` asset table per platform |
| Archive listing paths | `\` separators | normalise to `/` when comparing on Linux | `Test-SourcePathExcluded`, manifest |
| Shortcut | `.lnk` to `powershell.exe` | `~/.local/share/applications/workspaceshare.desktop` with `Exec=pwsh -NoProfile -File …/Start-WorkspaceShareGui.ps1` | `Install-GuiShortcut.ps1` branch |
| Tests | `cmd.exe`, `ping -n`, junctions via `mklink` | `/bin/sh -c`, `sleep`, `ln -s` | test helpers |

## 3. Port phases (when it is started)

1. **Parse gate:** CI job `ubuntu-latest` that only parses every `.ps1`/`.psm1` with `pwsh`.
   This is cheap and keeps new code portable from day one. It can be added already.
2. **Installer:** per-platform asset table (URLs + SHA-256 for linux-x64), extraction of
   `.tar.gz` / `.tar.xz` with `tar`, `chmod +x`, lockfile `platform: linux-x64`.
3. **Platform modules:** `Job.Linux`, `Path.Linux`, DNS helper, keep-awake. Module loader
   picks the implementation by `Get-WsPlatform`; exported names stay identical.
4. **Launcher branches:** replace the remaining direct Windows calls in `Share-Workspace.ps1`
   (about 15 call sites: DNS, keep-awake, clipboard, `System32` paths, path separators).
5. **Tests on Linux:** run the existing suites with `pwsh` on `ubuntu-latest`. The GUI HTTP
   tests and the snapshot-stage end-to-end test need no network and should pass unchanged.
6. **GUI:** implement the three stubs (`Open-WsBrowser`, `Show-WsFolderPicker`, clipboard) and
   the `.desktop` shortcut. The front end needs no change (it already hides the folder
   button when `capabilities.folderPicker` is false).

Estimate: phases 1–2 one day, phase 3 two to three days, phase 4 one to two days,
phases 5–6 two days.

## 4. Rules that keep the port cheap (apply now)

- New code follows `docs/GUI_CONTRACT.md` §1: shared PowerShell 5.1/7 syntax, no runtime
  C# compilation, OS calls only through the platform module.
- Build paths with `Join-Path`, never with hard-coded `\`.
- Never hard-code `powershell.exe`; use `Get-WsPowerShellHost`.
- Keep the security gates platform-neutral; only the mechanics (processes, paths, DNS)
  get per-OS implementations.
