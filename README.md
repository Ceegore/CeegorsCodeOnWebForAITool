# WorkspaceShare 3.1

Temporäre, read-only Freigabe eines lokalen Windows-Code-Workspaces als geprüfter ZIP64-Snapshot über einen geheimen Cloudflare-Quick-Tunnel-Link.

## Sicherheitsmodell

WorkspaceShare gibt niemals das Originalverzeichnis frei. Der Ablauf ist:

1. Workspace vollständig prüfen.
2. offensichtliche Schlüsseldateien und Reparse-Points blockieren;
3. Gitleaks-Scan ausführen;
4. bereinigtes ZIP64 erzeugen, testen, manifestieren und hashen;
5. exakt dieses eine Archiv mit miniserve auf `127.0.0.1` bereitstellen;
6. 256-Bit-Capability-Token als geheimen Route-Prefix setzen;
7. Cloudflare Quick Tunnel starten;
8. lokale und öffentliche Sicherheits-Gates ausführen;
9. Link nur bei vollständig grünen Gates ausgeben;
10. Tunnel, Server und Snapshot nach Ablauf oder Abbruch beseitigen.

Der vollständige Link ist ein Bearer-Secret. Jeder Besitzer kann die Datei herunterladen und weitergeben.

## Voraussetzungen

- Windows 10/11 x64
- Windows PowerShell 5.1
- `curl.exe`
- ausgehender Internetzugriff für GitHub-Downloads und Cloudflare Tunnel
- WinGet oder eine vorhandene `7z.exe` für den einmaligen Dependency-Bootstrap
- ausreichend freier lokaler Speicher für den Snapshot

Keine Domain, kein Cloudflare-Konto, keine Portweiterleitung und keine eingehende Firewallregel sind erforderlich.

## Erstinstallation

```powershell
Set-Location "C:\Tools\WorkspaceShare"
.\Install-Dependencies.ps1
```

Oder:

```bat
Install.cmd
```

Das Installationsskript:

- lädt ausschließlich fest gepinnte offizielle Release-Assets;
- prüft deren SHA-256-Werte;
- entpackt sie in ein temporäres Staging-Verzeichnis;
- prüft die gemeldeten Versionen;
- kopiert die vier EXE-Dateien nach `bin\`;
- erzeugt `dependencies.lock.json` mit den Hashes der tatsächlich ausgeführten Dateien.

Ohne gültiges Lockfile startet `Share-Workspace.ps1` nicht.

> **Hinweis zur gepinnten Gitleaks-Baseline 8.30.1:** Für das Windows-x64-Asset wird der Digest des offiziellen GitHub-Release-Assets fest im Installer geprüft. Der separat veröffentlichte Upstream-Checksumsatz war für dieses Asset zum Erstellungszeitpunkt Gegenstand einer dokumentierten Abweichung. Der Installer vertraut deshalb nicht blind auf diese Datei, sondern ausschließlich auf den hier geprüften Asset-Digest. Bei einem Versionsupdate müssen Release-Asset, Digest und Lizenz erneut unabhängig geprüft und gemeinsam geändert werden.

## Automatisierter lokaler Test

```powershell
.\tests\Test-WorkspaceShare.ps1
```

Oder:

```bat
Test.cmd
```

## Workspace freigeben

```powershell
.\Share-Workspace.ps1 -Path "D:\Projekte\Roswell" -Hours 4
```

Kurzer Test:

```powershell
.\Share-Workspace.ps1 -Path "D:\Projekte\Roswell" -Minutes 15
```

CMD-Wrapper:

```bat
WorkspaceShare.cmd "D:\Projekte\Roswell" -Hours 4
```

Der Link wird standardmäßig einmal ausgegeben und in die Zwischenablage kopiert. Am Sitzungsende wird die Zwischenablage nur dann geleert, wenn sie noch exakt diesen Link enthält.

## Wichtige Parameter

| Parameter | Wirkung |
|---|---|
| `-Hours 1..24` | Freigabedauer in Stunden; Standard 4 |
| `-Minutes 1..1440` | alternative Freigabedauer in Minuten |
| `-Compression Fast` | ZIP Deflate mit niedriger Kompressionsstufe; Standard |
| `-Compression Store` | keine Kompression; schnell bei bereits komprimierten Assets |
| `-IncludeGenerated` | schließt normalerweise ausgelassene Build-/Cache-Ordner ein |
| `-KeepArchive` | behält lokalen Sitzungsordner nach Ende |
| `-NoClipboard` | kopiert den Link nicht |
| `-KeepClipboard` | leert den Link nach Ende nicht automatisch |
| `-UnsafeSkipSecretScan -TestMode` | ausschließlich für isolierte Tests; im normalen Betrieb verboten |

## Projektspezifische Ausschlüsse

Optional im freizugebenden Workspace:

```text
.workspace-share.exclude.txt
```

Syntax: einfache 7-Zip-Wildcards, keine Gitignore-Semantik.

Beispiel:

```text
HugeRawAssets
HugeRawAssets\*
*.psd
*.blend1
```

Die Pflichtausschlüsse aus `config\mandatory-excludes.txt` können projektseitig nicht aufgehoben werden.

## Freigabe sofort beenden

Im aktiven Terminal:

```text
Strg+C
```

Notfall-Stop aus einem zweiten Terminal:

```powershell
.\Stop-WorkspaceShare.ps1
```

Oder:

```bat
Stop.cmd
```

## Test-Fixtures

```powershell
.\tests\New-TestFixtures.ps1
```

Optional mit einer Datei über 2 GB:

```powershell
.\tests\New-TestFixtures.ps1 -IncludeLargeFiles
```

Die erzeugten Fixtures enthalten absichtlich blockierbare Inhalte und dürfen nicht produktiv geteilt werden.

## Interne Release-Datei bauen

Nach vollständig bestandener Abnahme:

```powershell
.\scripts\Build-InternalRelease.ps1
```

Ergebnis:

```text
dist\WorkspaceShare-3.1.0-internal.zip
dist\WorkspaceShare-3.1.0-internal.zip.sha256.txt
```

## Laufzeitdaten

```text
%LOCALAPPDATA%\WorkspaceShare\sessions\<Session-ID>\
```

`session.json` enthält Prozessidentitäten und lokale Pfade, aber niemals Capability-Token oder vollständigen Link.

## Fehlercodes

| Bereich | Code |
|---|---:|
| Umgebung/Parameter | 10 |
| Dependency-Lock/Hash | 11 |
| Workspace-Lesbarkeit/Reparse | 20 |
| Speicherplatz | 21 |
| Secret-Prüfung | 22 |
| ZIP-Erstellung/Integrität | 23 |
| lokaler Serverstart | 30 |
| lokale HTTP-/Read-only-Gates | 31 |
| Cloudflare-Prozess | 41 |
| Tunnel-URL | 42 |
| öffentliche Gates | 43 |
| Laufzeit/unerwarteter Prozessabbruch | 50 |

## Bewusste Grenzen

- Linkbesitzer können die Datei speichern oder weitergeben.
- Cloudflare verarbeitet den Klartext technisch am HTTPS-Endpunkt.
- Quick Tunnels sind ein temporärer Test-/Entwicklungsdienst ohne Produktiv-SLA.
- Secret-Scanner können False Positives und False Negatives haben.
- Das Tool ist für interne, kurzzeitige Send-only-Freigaben gedacht, nicht für dauerhaftes Hosting.
