# WorkspaceShare on Linux – Plan and status

Status: stage 1 implemented, 2026-10-16 (**experimental**, only exercised on GitHub Actions
`ubuntu-latest` so far). Windows remains the primary product and stays on Windows PowerShell 5.1.
The GUI is built so that this port needs no second code base (see `docs/GUI_CONTRACT.md` §1 and §3).

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

## 2. Windows-specific pieces and their Linux replacement (as implemented)

| Area | Windows | Linux (implemented) | Where |
|---|---|---|---|
| Process lifetime | Job Object with kill-on-close (P/Invoke) | every child starts through `/bin/sh -c 'umask 077; exec setsid …'` (own session and process group, stdout/stderr redirected to files, stdin `/dev/null` or a private pipe); a "job" is a registry file under `~/.local/share/workspaceshare/jobs/` listing `pid starttime mode`; `Stop-WorkspaceJob` sends `kill -s TERM -- -<pgid>`, waits 2 s, then `KILL`; a process is only signalled while `/proc/<pid>/stat` still shows the recorded start time and `pgrp == pid`; the owner's `Close-WorkspaceJob` kills what is left | `scripts/WorkspaceShare.Job.Linux.ps1` (loaded by `WorkspaceShare.Job.psm1`, same function names) |
| Child environment | allowlist (`SystemRoot`, `TEMP`, …) | allowlist (`PATH`, `HOME`, `USER`, `LANG`/`LC_ALL`, `TMPDIR`, `TZ`, `SSL_CERT_*`) | same file |
| Path identity, reparse points | `GetFileInformationByHandle` | `realpath -e` + `stat -L -c %d:%i`; symlinks carry `FileAttributes.ReparsePoint` in .NET, so the existing gates reject them unchanged | `scripts/WorkspaceShare.Path.Linux.ps1` |
| Process identity | `Process.StartTime` + path | start time = `/proc/<pid>/stat` field 22 (+1) in **every** process (`Process.StartTime` derives from the wall clock and differs by ms between processes); path from `/proc/<pid>/exe`, compared after `realpath` when the plain paths differ | `WorkspaceShare.Process.psm1` (`Get-WorkspaceProcessStartTicks`), `WorkspaceShare.Platform.psm1` (`Get-WsProcessStartTicks`) |
| DNS checks | `Resolve-DnsName` | `[System.Net.Dns]` (system resolver); public resolvers 1.1.1.1/8.8.8.8/9.9.9.9 through `dig` – **without `dig` the public-resolver comparison is skipped** (HTTP gates stay authoritative) | `Get-WsResolvedAddress`, `Test-WsPublicResolverSupport` |
| Keep awake | `SetThreadExecutionState` | `systemd-inhibit … tail --pid=<launcher> -f /dev/null`; silently skipped when missing | `Start-WsKeepAwake` |
| Clipboard | WinForms | `wl-copy` (Wayland) / `xclip` / `xsel` when a display exists; capability false otherwise | `Set-WsClipboardText`, `Clear-WsClipboardText` |
| Folder picker | `FolderBrowserDialog` | `zenity --file-selection --directory` or `kdialog --getexistingdirectory` when a display exists; otherwise capability false and the GUI shows only the text field | `Show-WsFolderPicker` |
| Open browser | `Start-Process <url>` | `xdg-open <url>` (only `http://127.0.0.1:<port>/…`) | `Open-WsBrowser` |
| Data folder | `%LOCALAPPDATA%\WorkspaceShare` | `$XDG_DATA_HOME/workspaceshare` or `~/.local/share/workspaceshare`, mode 700; sessions below `sessions/` | `Get-WsDataRoot` |
| Private folders | `icacls` | `chmod 700`, files created with `umask 077` | `Set-WsPrivateDirectory` |
| Named mutexes | `Threading.Mutex` | GUI single instance: exclusive lock file (`FileShare.None` = `flock`) in `<data root>/locks`; installer: the dependency lease file is enough | `New-WsInstanceLock` |
| Executables | `bin\*.exe` | `bin/linux-x64/{cloudflared,miniserve,gitleaks,7zz}`; lockfile `platform: linux-x64` | `Install-Dependencies.ps1` asset table |
| Archive paths | `\`, lower-cased manifest | `/`, case kept (names that differ only in case are legal); 7-Zip gets `-spd` so names are matched literally | `Share-Workspace.ps1` |
| Watchdog | `powershell.exe` | `pwsh`, started under `setsid` so a Ctrl+C / hangup aimed at the launcher does not reach it | `Start-Watchdog` |
| Shortcut | `.lnk` | `~/.local/share/applications/workspaceshare.desktop` (`Exec="…/pwsh" -NoLogo -NoProfile -File "…/Start-WorkspaceShareGui.ps1"`) | `Install-GuiShortcut.ps1` |

Known differences / limits on Linux:

- No kill-on-close when the launcher is killed with SIGKILL – the watchdog (own session) covers it, exactly as on Windows
  where the watchdog is the second line of defence.
- The archive "read lock" is advisory on Linux (`flock`); the session folder is `chmod 700`, the archive is only
  reachable for the same user.
- The per-file identity (file index) in the source consistency manifest is not collected on Linux (size, mtime and SHA-256 still are).
- Only x64 (glibc or musl host). arm64 and macOS are not supported.
- Without a display (SSH, CI) the GUI works in the browser you open yourself; folder picker and clipboard are off.

## 3. Port phases and status

| Phase | Scope | Status |
|---|---|---|
| 1 Parse gate | CI job on `ubuntu-latest` parses every `.ps1`/`.psm1` with `pwsh` | **done** (`.github/workflows/linux-tests.yml`) |
| 2 Installer | per-platform asset table (linux-x64 URLs + SHA-256), `tar` extraction, `chmod +x`, lockfile `platform: linux-x64`, licenses | **done**, hashes cross-checked with the GitHub asset digests and the upstream gitleaks checksum file; version checks run in CI only |
| 3 Platform modules | `Job.Linux`, `Path.Linux`, DNS helper, keep-awake, process identity | **done**, untested outside CI |
| 4 Launcher branches | `Share-Workspace.ps1`, `Watch-WorkspaceShare.ps1`, `Stop-WorkspaceShare.ps1` | **done**; a full share through a real tunnel is only covered by the optional manual workflow input |
| 5 Tests on Linux | `tests/Test-LinuxPlatform.ps1` (new), existing suites made platform-aware ([SKIP] for Windows-only checks) | **partly** – see the CI result of the current commit; `Test-LifecycleHardening` runs only its portable subset |
| 6 GUI | `Open-WsBrowser`, `Show-WsFolderPicker`, clipboard, `.desktop` file, lock-file instance lock | **done**, folder picker / clipboard untested on a real desktop |
| 7 Real-world soak | long Quick Tunnel run, desktop session, different distributions | **open** |

## 4. How to run on Linux

Requirements: x64 Linux, PowerShell 7.4+ (`pwsh`), `curl`, `tar` with `xz`, `setsid` (util-linux), outbound internet.
Optional: `dig` (public DNS comparison), `systemd-inhibit` (keep awake), `xdg-open` + `zenity`/`kdialog`
+ `wl-copy`/`xclip` (desktop integration).

```bash
git clone https://github.com/Ceegore/CeegorsCodeOnWebForAITool.git
cd CeegorsCodeOnWebForAITool
pwsh ./Install-Dependencies.ps1          # downloads and verifies the four tools into bin/linux-x64/

# command line
pwsh ./Share-Workspace.ps1 -Path ~/projects/demo -Hours 4

# browser GUI (drag & drop, tabs)
pwsh ./Start-WorkspaceShareGui.ps1       # opens the browser with xdg-open if possible
pwsh ./Install-GuiShortcut.ps1           # optional: menu entry (workspaceshare.desktop)

# stop everything that is still running
pwsh ./Stop-WorkspaceShare.ps1
```

Release package: every published GitHub release gets `WorkspaceShare-<version>-linux-x64.tar.gz` (+ `.sha256.txt`)
from `.github/workflows/release-linux.yml`: it checks out the tag, installs the pinned tools, runs the Linux
suites and packs with `scripts/Build-LinuxRelease.ps1` (tools must match `dependencies.lock.json`). Unpack it and
run `pwsh ./Start-WorkspaceShareGui.ps1` in the `WorkspaceShare` folder; `Install-Dependencies.ps1` is not needed.

Tests: `pwsh tests/Test-LinuxPlatform.ps1`, `pwsh tests/Test-WorkspaceShareGui.Http.ps1`,
`pwsh tests/Test-WorkspaceShare.ps1`, `pwsh tests/Test-WorkspaceShareGui.ps1` (the CI workflow runs all of them and uploads the logs).

## 5. Rules that keep the port cheap (apply to all new code)

- New code follows `docs/GUI_CONTRACT.md` §1: shared PowerShell 5.1/7 syntax, no runtime
  C# compilation on Windows paths, OS calls only through the platform layer.
- Build paths with `Join-Path` (one segment per call), never with hard-coded `\`.
- Never hard-code `powershell.exe`; use `Get-WsPowerShellHost` (or `Get-WatchdogHostPath` in the launcher).
- Never read `Process.StartTime` for identity; use `Get-WorkspaceProcessStartTicks` / `Get-WsProcessStartTicks`.
- Keep the security gates platform-neutral; only the mechanics (processes, paths, DNS) get per-OS implementations.
