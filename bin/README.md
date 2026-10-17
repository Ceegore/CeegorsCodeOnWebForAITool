# Binärdateien

In der Git-Repository-Version enthält dieser Ordner **keine** Drittanbieter-EXE-Dateien;
sie sind per `.gitignore` ausgeschlossen.

Nach `Install-Dependencies.ps1` enthält er die vier geprüften EXE-Dateien
(`7za.exe`, `cloudflared.exe`, `gitleaks.exe`, `miniserve.exe`) und den Ordner
`licenses\`. Die interne Release-ZIP enthält diese Dateien bereits.

Führe im Projektroot aus:

```powershell
.\Install-Dependencies.ps1
```

Das Skript lädt die fest gepinnten offiziellen Release-Assets, prüft deren SHA-256-Werte und Versionen und erzeugt anschließend `dependencies.lock.json` aus den tatsächlich installierten EXE-Dateien.

`Share-Workspace.ps1` startet nur mit einer gültigen `dependencies.lock.json`
(`installed: true` und übereinstimmende Hashes). Ein Share-Vorgang ist ohne gültigen Lock nicht möglich.

## Linux (experimentell)

Unter Linux legt `pwsh ./Install-Dependencies.ps1` die Programme in `bin/linux-x64/` ab (`cloudflared`, `miniserve`, `gitleaks`, `7zz` und `licenses/`); das Lockfile erhält `platform: linux-x64`.

