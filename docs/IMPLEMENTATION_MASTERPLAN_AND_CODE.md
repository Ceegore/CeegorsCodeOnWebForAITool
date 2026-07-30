# WorkspaceShare 3.1 – finaler Umsetzungs-, Implementierungs- und Abnahmeplan

**Dokumentstatus:** implementierungsbereit  
**Zielplattform:** Windows 10/11 x64  
**Technologiestack:** Windows PowerShell 5.1 + unveränderte Drittanbieter-Binärdateien  
**Betriebsmodell:** intern, temporär, send-only/read-only  
**Releaseziel:** `3.1.0-internal`  
**Ausgangsbasis:** `_internetKonzept3_SOURCE.md`

---

## 1. Zielbild und verbindliche Produktinvarianten

WorkspaceShare soll mit einem Befehl aus genau einem lokalen Workspace-Root einen unveränderlichen, bereinigten ZIP64-Snapshot erzeugen und diesen wenige Minuten oder Stunden über einen direkt nutzbaren HTTPS-Link bereitstellen.

Der Empfänger benötigt:

- keinen Account;
- keine zusätzliche Clientsoftware;
- keine Cloudflare-Anmeldung;
- keinen Dateibrowser;
- keine Schreibberechtigung.

Die Implementierung ist nur dann abgeschlossen, wenn alle folgenden Invarianten technisch erzwungen und getestet sind:

1. **Original-Workspace niemals servieren.**
2. **Exakt eine bereits fertige Archivdatei servieren.**
3. **Lokalen Server ausschließlich an `127.0.0.1` binden.**
4. **Capability-Pfad mit 32 kryptografisch zufälligen Bytes verwenden.**
5. **Token nicht in Prozesskommandozeile, Lockfile, Sessiondatei oder Logdatei schreiben.**
6. **Keine Upload-, mkdir-, Delete-, Pastebin- oder WebDAV-Funktion aktivieren.**
7. **Bei jedem unklaren Zustand fail closed handeln.**
8. **Abhängigkeiten vor jedem Start über SHA-256-Lock verifizieren.**
9. **Snapshot vor Linkausgabe erstellen, testen, manifestieren und hashen.**
10. **Root, falscher Token, Range, Cache und Unveränderlichkeit lokal und öffentlich prüfen.**
11. **Tunnel immer vor dem lokalen Server beenden.**
12. **Watchdog und Stop-Skript dürfen nie allein anhand einer PID töten.**
13. **Ablaufzeit beginnt erst nach dem Start des Tunnelprozesses.**
14. **Standardmäßig alle temporären Sitzungsdaten löschen.**
15. **`-KeepArchive` darf ausschließlich lokale Daten behalten und den Link nicht verlängern.**

Diese Invarianten sind Scope-Lock. Änderungen daran benötigen eine neue Architekturentscheidung und mindestens eine Minor-Version.

---

## 2. Finale Architektur

```text
Workspace-Root
    │
    ├─ vollständige Lesbarkeitsprüfung
    ├─ Reparse-/Junction-/Symlink-Gate
    ├─ sensible Dateinamen blockieren
    └─ Gitleaks-Verzeichnisscan
           │
           ▼
7za.exe erzeugt ZIP64
    ├─ Pflichtausschlüsse
    ├─ optionale Generated-Ausschlüsse
    ├─ projektspezifische 7-Zip-Wildcards
    ├─ 7za t Integritätsprüfung
    ├─ Inhaltsmanifest
    └─ SHA-256
           │
           ▼
miniserve.exe
    ├─ Serve-Path = genau eine ZIP-Datei
    ├─ Interface = 127.0.0.1
    ├─ zufälliger Port
    ├─ Route-Prefix über Environment
    ├─ 256-Bit-Capability-Token
    └─ No-Store- und Sicherheitsheader
           │
           ▼
cloudflared.exe Quick Tunnel
           │
           ▼
https://<zufall>.trycloudflare.com/d/<token>/
```

### 2.1 Prozessrollen

| Prozess | Aufgabe | Darf Quelle ändern? | Besitzt Token? |
|---|---|---:|---:|
| Launcher | Orchestrierung, Gates, Ausgabe, Cleanup | nur temporäre Sitzungsdaten | ja, nur im RAM |
| Gitleaks | Secret-Erkennung | nein | nein |
| 7-Zip | Snapshot, Test, Manifest | erzeugt Snapshot | nein |
| miniserve | einzelne Datei lesen und streamen | nein | ja, als Kindprozess-Environment |
| cloudflared | Tunnel zum lokalen Origin | nein | nein |
| Watchdog | Prozessende und Cleanup | nur Sessionordner | nein |

### 2.2 Laufzeitdaten

```text
%LOCALAPPDATA%\WorkspaceShare\sessions\<UTC-Zeit>-<Zufall>\
├─ workspace-YYYYMMDD-HHMMSS.zip
├─ archive.sha256.txt
├─ archive-manifest.txt
├─ 7zip-create.log
├─ 7zip-test.log
├─ gitleaks-redacted.json
├─ public-headers.txt
├─ cloudflared.stdout.log
├─ cloudflared.stderr.log
├─ session.json
├─ normal.exit
└─ keep.archive
```

`normal.exit` und `keep.archive` entstehen nur bei Bedarf. Keine Datei darf das Capability-Token oder die vollständige URL enthalten.

---

## 3. Projektstruktur

```text
WorkspaceShare/
├─ Share-Workspace.ps1
├─ Stop-WorkspaceShare.ps1
├─ Install-Dependencies.ps1
├─ WorkspaceShare.cmd
├─ Install.cmd
├─ Stop.cmd
├─ Test.cmd
├─ VERSION
├─ README.md
├─ SECURITY.md
├─ THIRD_PARTY_NOTICES.md
├─ dependencies.lock.json
├─ bin/
│  ├─ cloudflared.exe
│  ├─ miniserve.exe
│  ├─ gitleaks.exe
│  ├─ 7za.exe
│  └─ licenses/
├─ config/
│  ├─ mandatory-excludes.txt
│  ├─ generated-excludes.txt
│  └─ gitleaks-workspaceshare.toml
├─ scripts/
│  ├─ Watch-WorkspaceShare.ps1
│  └─ Build-InternalRelease.ps1
├─ tests/
│  ├─ Test-WorkspaceShare.ps1
│  └─ New-TestFixtures.ps1
└─ docs/
   ├─ _internetKonzept3_SOURCE.md
   └─ IMPLEMENTATION_MASTERPLAN_AND_CODE.md
```

---

# 4. Phasenübersicht

| Phase | Name | Hauptziel | Gate |
|---:|---|---|---|
| 0 | Architektur- und Repository-Lock | Scope und SSOT einfrieren | G0 |
| 1 | Reproduzierbare Abhängigkeiten | offizielle Assets, Hashes, Lizenzen | G1 |
| 2 | Launcher-Grundgerüst | Parameter, Fehlercodes, Lockprüfung | G2 |
| 3 | Workspace-Sicherheitsprüfung | Lesbarkeit, Reparse, Dateinamen, Gitleaks | G3 |
| 4 | Snapshot-Pipeline | ZIP64, Ausschlüsse, Test, Manifest, Hash | G4 |
| 5 | Lokaler Read-only-Origin | Loopback, Tokenroute, Range, Mutation-Gates | G5 |
| 6 | Öffentlicher Quick Tunnel | URL-Erkennung, öffentliche Negativ- und Cachetests | G6 |
| 7 | Lifecycle und Notfall-Cleanup | Timer, Watchdog, PID-Reuse-Schutz | G7 |
| 8 | Automatisierte Qualitätssicherung | reproduzierbare Testausführung | G8 |
| 9 | Last-, Resume- und 10-GB-Abnahme | reale Betriebsfähigkeit | G9 |
| 10 | Packaging, Lizenzen und internes Release | reproduzierbares Distributionspaket | G10 |
| 11 | Pilot und Rollout | kontrollierte interne Einführung | G11 |
| 12 | Wartung | sichere Dependency- und Regression-Updates | fortlaufend |

Die Reihenfolge ist verbindlich. Eine Phase darf erst als abgeschlossen gelten, wenn ihr Gate dokumentiert grün ist.

---

# 5. Phase 0 – Architektur- und Repository-Lock

## 5.1 Ziel

Alle Produktentscheidungen werden vor dem ersten Entwicklungscommit eingefroren. Der Agent darf während der Implementierung keine Funktionsausweitung vornehmen.

## 5.2 Subphase 0.1 – SSOT festlegen

Arbeit:

1. `_internetKonzept3_SOURCE.md` unverändert unter `docs/` ablegen.
2. Dieses Dokument als operative Implementierungs-SSOT hinzufügen.
3. `VERSION` auf `3.1.0-internal` setzen.
4. Alte Versuche nur archivieren, nicht löschen.
5. Repository-Root exakt auf die definierte Projektstruktur bringen.

Ergebnis:

- historische Architektur bleibt nachvollziehbar;
- operative Änderungen werden nur in 3.1 vorgenommen;
- kein Agent muss aus mehreren konkurrierenden Dokumenten wählen.

## 5.3 Subphase 0.2 – Scope-Lock

Verbotene Erweiterungen im ersten Release:

- GUI;
- dauerhafte Domain;
- Accounts;
- mehrere parallele Workspaces in einer Sitzung;
- Dateibrowser;
- einzelne Datei-Links;
- Upload;
- Synchronisierung;
- Telemetrie;
- automatische Selbstaktualisierung;
- Windows-Dienst;
- eigener HTTP-Server;
- eigener Tunnel;
- eigener ZIP-Writer;
- eigener Secret-Scanner.

## 5.4 Subphase 0.3 – Branch- und Commit-Plan

Empfohlene Commits:

1. `chore: lock architecture and project skeleton`
2. `build: add pinned dependency installer`
3. `feat: add strict preflight and snapshot pipeline`
4. `feat: add loopback capability server gates`
5. `feat: add quick tunnel and public gates`
6. `feat: add watchdog and emergency stop`
7. `test: add local integration and fixture suite`
8. `docs: add operations security and release runbooks`
9. `release: prepare 3.1.0-internal`

Jeder Commit muss eigenständig reviewbar sein. Keine Mischung aus Dependency-Update, Feature und Refactoring.

## 5.5 Gate G0

- [ ] SSOT ist festgelegt.
- [ ] Zielplattform Windows 10/11 x64 bestätigt.
- [ ] PowerShell 5.1 bleibt Mindestversion.
- [ ] Ein Workspace-Root pro Link akzeptiert.
- [ ] Read-only/send-only bestätigt.
- [ ] Quick-Tunnel-Testdienst ohne SLA akzeptiert.
- [ ] Keine Erweiterung außerhalb des MVP-Scope beauftragt.

---

# 6. Phase 1 – Reproduzierbare Abhängigkeiten

## 6.1 Ziel

Kein ausführbares Fremdprogramm darf unversioniert, aus einem Downloadportal oder ohne Hashprüfung verwendet werden.

## 6.2 Fest gepinnte Baseline

| Komponente | Version | Installiertes Ziel |
|---|---:|---|
| cloudflared | 2026.7.3 | `bin\cloudflared.exe` |
| miniserve | 0.35.0 | `bin\miniserve.exe` |
| Gitleaks | 8.30.1 | `bin\gitleaks.exe` |
| 7-Zip | 26.02 | `bin\7za.exe` |

Die im Installer hinterlegten Hashes beziehen sich zunächst auf offizielle Release-Assets. Nach Installation wird zusätzlich der Hash jeder tatsächlich verwendeten EXE in `dependencies.lock.json` geschrieben.

**Gitleaks-8.30.1-Härtung:** Für das Windows-x64-Asset wird der Digest des offiziellen GitHub-Release-Assets gepinnt. Der separat veröffentlichte Upstream-Checksumsatz war zum Erstellungszeitpunkt für dieses Asset Gegenstand einer dokumentierten Abweichung. Der Bootstrap darf deshalb nicht auf einen ungeprüften Austausch gegen den Checksumsatz umgestellt werden. Ein Versionswechsel verlangt eine neue unabhängige Herkunfts-, Digest-, Lizenz- und Funktionsprüfung.

## 6.3 Subphase 1.1 – Installer implementieren

`Install-Dependencies.ps1` muss:

1. TLS 1.2 aktivieren;
2. in ein zufälliges Temp-Verzeichnis herunterladen;
3. ausschließlich feste URLs verwenden;
4. jeden Download vor Entpacken hashen;
5. bei einer Abweichung sofort abbrechen;
6. Gitleaks mit `Expand-Archive` entpacken;
7. für das 7-Zip-Extra-Paket eine vorhandene `7z.exe` nutzen;
8. fehlende `7z.exe` optional über gepinntes WinGet-Paket beschaffen;
9. x64-Binärdateien auswählen;
10. Versionsausgabe jeder EXE prüfen;
11. Lizenzen ablegen;
12. erst danach nach `bin\` kopieren;
13. abschließend das EXE-Lockfile erzeugen;
14. das Temp-Verzeichnis immer löschen.

## 6.4 Subphase 1.2 – Runtime-Lockprüfung

Vor jedem Share-Vorgang:

1. Lockfile laden;
2. Schema und `installed=true` prüfen;
3. vier Pflichtabhängigkeiten verlangen;
4. jeden Pfad auflösen;
5. SHA-256 neu berechnen;
6. mit Lockwert vergleichen;
7. bei jeder Abweichung mit Fehlercode 11 abbrechen.

Ein Benutzer darf eine manipulierte EXE nicht durch eine Warnung übergehen.

## 6.5 Subphase 1.3 – Lizenz- und Herkunftsnachweis

Zu jeder Abhängigkeit müssen vor internem Release vorhanden sein:

- Name;
- Version;
- offizielle Release-Quelle;
- Lizenzbezeichnung;
- vollständiger Lizenztext;
- Asset-Hash;
- finaler EXE-Hash.

## 6.6 Tests

Positive Tests:

- saubere Erstinstallation;
- erneute Installation mit `-Force`;
- Versionsprüfung aller vier Programme;
- Lockfile enthält vier Einträge;
- EXE-Hashes stimmen nach Neustart.

Negative Tests:

- ein Downloadbyte verändern;
- eine EXE nach Installation verändern;
- Lockfile löschen;
- `installed=false`;
- Pflichtabhängigkeit aus Lock entfernen;
- ungültigen SHA-256 eintragen;
- Netzwerk während Download unterbrechen.

Erwartung: kein Share-Flow startet.

## 6.7 Gate G1

- [ ] alle vier Assets stammen aus offiziellen Quellen;
- [ ] Asset-Hashes geprüft;
- [ ] EXE-Versionen geprüft;
- [ ] EXE-Lock erstellt;
- [ ] Manipulation führt zu Exit 11;
- [ ] Lizenzdateien vorhanden;
- [ ] keine `latest`-URL;
- [ ] kein Downloadportal.

---

# 7. Phase 2 – Launcher-Grundgerüst

## 7.1 Ziel

Ein deterministischer, fail-closed PowerShell-Prozess mit klaren Parametern und Fehlerklassen.

## 7.2 Subphase 2.1 – Parametervertrag

Verbindliche Parameter:

```powershell
-Path <Ordner>
-Hours 1..24
-Minutes 1..1440
-Compression Fast|Store
-IncludeGenerated
-KeepArchive
-NoClipboard
-KeepClipboard
-UnsafeSkipSecretScan -TestMode
-ToolRoot <Pfad>
```

Regeln:

- `Hours` und `Minutes` sind getrennte Parametersets;
- Laufwerksroot ist unzulässig;
- `UnsafeSkipSecretScan` ohne `TestMode` ist unzulässig;
- normaler Betrieb besitzt immer Gitleaks;
- Standarddauer ist vier Stunden;
- Standardkompression ist `Fast`.

## 7.3 Subphase 2.2 – Fehlerklassen

| Code | Klasse | Beispiele |
|---:|---|---|
| 10 | Umgebung/Parameter | curl fehlt, Cloudflared-Konflikt |
| 11 | Dependency-Integrität | Lock fehlt, Hash falsch |
| 20 | Workspace-Struktur | Zugriff verweigert, Reparse-Point |
| 21 | Speicherplatz | Snapshotziel zu klein |
| 22 | Secret-Risiko | `.env`, Gitleaks-Fund |
| 23 | Archiv | 7-Zip-Erstellung/Test/Manifest |
| 30 | Serverstart | miniserve bindet nicht |
| 31 | lokale Security-Gates | Root 200, Range defekt, Mutation |
| 41 | Tunnelprozess | cloudflared beendet sich |
| 42 | URL-Erkennung | keine Quick-Tunnel-URL |
| 43 | öffentliche Gates | falsche Route, Cache, Range |
| 50 | Laufzeit | Kindprozess unerwartet beendet |

## 7.4 Subphase 2.3 – Log- und Geheimnisregeln

Erlaubt:

- Fortschritt;
- lokale Quellpfade;
- EXE-Versionen;
- Archivgröße;
- Archivhash;
- lokale Portnummer;
- Ablaufzeit.

Nur einmal sichtbar:

- vollständiger Capability-Link.

Verboten in Dateien:

- Token;
- vollständiger Link;
- Zwischenablageinhalt;
- HTTP Authorization;
- URL mit Capability-Pfad.

## 7.5 Gate G2

- [ ] Parametersets funktionieren;
- [ ] ungültige Werte werden vor Arbeit abgelehnt;
- [ ] Fehlercode bleibt maschinenlesbar;
- [ ] kein Token in persistenten Daten;
- [ ] `try/catch/finally` umschließt kompletten Flow.

---

# 8. Phase 3 – Workspace-Sicherheitsprüfung

## 8.1 Ziel

Vor Snapshot-Erstellung muss bewiesen sein, dass der einzuschließende Baum vollständig lesbar ist und keine strukturell riskanten Verweise besitzt.

## 8.2 Subphase 3.1 – Root-Auflösung

1. `Resolve-Path -LiteralPath`;
2. abschließenden Separator entfernen;
3. Parent und Leaf bestimmen;
4. Laufwerksroot blockieren;
5. Originalpfad nicht mehr ungeprüft verwenden.

## 8.3 Subphase 3.2 – Iterative Baumprüfung

Kein rekursives Pipeline-Konstrukt mit unkontrolliertem Speicherverbrauch. Stattdessen:

- `Stack[DirectoryInfo]`;
- Verzeichnisse iterativ abarbeiten;
- Datei- und Bytezahl zählen;
- Zugriffsfehler sammeln;
- Reparse-Points sammeln;
- verbotene Namen sammeln;
- maximal begrenzte Vorschau in Fehlermeldung.

## 8.4 Subphase 3.3 – Reparse-Gate

Jeder Eintrag mit `FileAttributes.ReparsePoint` führt zum Abbruch.

Begründung:

- Junction kann außerhalb des Roots zeigen;
- Symlink kann nach Prüfung geändert werden;
- Directory Traversal wird sonst zu einer Dateisystemfrage;
- Snapshot und Sicherheitsprüfung könnten verschiedene Bäume sehen.

Keine automatische Auflösung und kein stilles Überspringen im MVP.

## 8.5 Subphase 3.4 – sensible Dateinamen

Harte Blockliste unter anderem:

- `.env`, `.env.*`;
- `*.pem`, `*.key`;
- `*.pfx`, `*.p12`;
- `*.jks`, `*.keystore`;
- `id_rsa*`, `id_ed25519*`;
- `credentials.json`;
- `service-account*.json`;
- `secrets.json`;
- `*.mobileprovision`;
- `*.ovpn`.

Erlaubte Dokumentationsvarianten:

- `.example`;
- `.template`;
- `.sample`.

## 8.6 Subphase 3.5 – Gitleaks

Verbindlicher Aufruf:

```powershell
gitleaks dir `
  --config <strict-config> `
  --no-banner `
  --no-color `
  --redact=100 `
  --report-format json `
  --report-path <session>\gitleaks-redacted.json `
  --exit-code 20 `
  --timeout 900 `
  <workspace>
```

Die Konfiguration erweitert die Defaultregeln und enthält bewusst keine Pfad-Allowlist. Das kann konservative False Positives erzeugen, verhindert aber, dass `-IncludeGenerated` Dateien einschließt, die vom Scanner pauschal ignoriert wurden.

## 8.7 Gate G3

- [ ] unlesbares Verzeichnis blockiert;
- [ ] Junction blockiert;
- [ ] Symlink blockiert;
- [ ] `.env` blockiert;
- [ ] `.env.example` erlaubt;
- [ ] Gitleaks-Testtoken blockiert;
- [ ] Gitleaks-Fehler blockiert;
- [ ] normaler Clean-Workspace passiert.

---

# 9. Phase 4 – Snapshot-Pipeline

## 9.1 Ziel

Erst nach vollständiger Sicherheitsprüfung wird ein unveränderliches, getestetes Einzelarchiv erzeugt.

## 9.2 Ausschlussschichten

Reihenfolge:

1. `mandatory-excludes.txt`;
2. `generated-excludes.txt`, außer `-IncludeGenerated`;
3. `.workspace-share.exclude.txt` im Workspace.

Pflichtausschlüsse können nicht aufgehoben werden.

## 9.3 Semantik

Die Projektdatei nutzt 7-Zip-Wildcards, keine Gitignore-Regeln.

Unterstützt:

```text
Folder
Folder\*
*.psd
*.blend1
```

Nicht unterstützt:

- `!re-include`;
- verschachtelte Gitignore-Vererbung;
- automatische `.gitignore`-Interpretation;
- reguläre Ausdrücke.

## 9.4 Archivierung

Eigenschaften:

- `-tzip`;
- `-mx=1` für Fast;
- `-mx=0` für Store;
- Multithreading;
- Stop bei nicht lesbarer Eingabedatei;
- keine PowerShell-`Compress-Archive`;
- Parent als Working Directory;
- Root-Leaf im Archiv erhalten.

## 9.5 Nachgelagerte Gates

1. Archiv existiert und ist nicht leer;
2. `7za t` erfolgreich;
3. `7za l -slt` erzeugt Manifest;
4. SHA-256 erzeugen;
5. Archivgröße bestimmen;
6. Hashdatei schreiben;
7. danach Archiv nicht mehr verändern.

## 9.6 Speicherplatz

Vor Start:

```text
benötigt = konservative Quellgröße + 2 GB Reserve
```

Für sehr große oder schlecht komprimierbare Workspaces ist zusätzlich eine betriebliche Reserve von mindestens 10 % sinnvoll. Bei knappen Laufwerken muss der Session-Root später konfigurierbar gemacht werden; dies ist kein MVP-Blocker.

## 9.7 Gate G4

- [ ] `.git` fehlt;
- [ ] Generated-Verzeichnisse fehlen standardmäßig;
- [ ] erlaubte versteckte Dateien bleiben;
- [ ] Projekt-Wildcards greifen;
- [ ] gesperrte Eingabedatei bricht ab;
- [ ] Datei über 2 GB funktioniert;
- [ ] ZIP über 4 GB funktioniert;
- [ ] `7za t` grün;
- [ ] Manifest plausibel;
- [ ] SHA-256 reproduzierbar.

---

# 10. Phase 5 – Lokaler Read-only-Origin

## 10.1 Ziel

miniserve darf nur eine Datei, nur auf Loopback und nur hinter dem Capability-Pfad bereitstellen.

## 10.2 Token

Erzeugung:

1. `RandomNumberGenerator.Create()`;
2. 32 Bytes;
3. Base64url;
4. Padding entfernen;
5. erwartete Länge 43 Zeichen.

Das Token wird über `MINISERVE_ROUTE_PREFIX=d/<token>` in die Kindprozessumgebung geschrieben. Es darf nicht in `ProcessStartInfo.Arguments` vorkommen.

## 10.3 Startparameter

Erlaubt:

- `--quiet`;
- `--log-color never`;
- `--interfaces 127.0.0.1`;
- `--port <random>`;
- `--workers 2`;
- `--no-symlinks`;
- feste Header;
- Archivpfad.

Verboten:

- `--upload-files`;
- `--mkdir`;
- `--rm-files`;
- `--enable-webdav`;
- `--pastebin`.

## 10.4 Port-Race

Ablauf:

1. freien Port über temporären Listener ermitteln;
2. Listener schließen;
3. miniserve starten;
4. Secret-Route pollen;
5. bei Fehlschlag Prozess sicher stoppen;
6. maximal fünf neue Ports versuchen.

Wichtig: Ein erfolglos gestarteter Versuch muss vor dem nächsten Versuch beendet werden.

## 10.5 Lokale Gates

Vor Tunnelstart:

1. Secret-Route → HTTP 200;
2. Root → nicht 200;
3. zufälliger falscher Token → nicht 200;
4. Range `0-1023` → 206 und 1024 Bytes;
5. Snapshot-Hash vor und nach Mutation-Probes identisch;
6. Sessiondateiliste vor und nach Probes identisch;
7. Methoden: POST, PUT, PATCH, DELETE, PROPFIND, MKCOL, MOVE, COPY;
8. Listening-Socket nur Loopback;
9. Token nicht in Prozesskommandozeile.

## 10.6 Header

Mindestens:

```text
Cache-Control: private, no-store, no-cache, max-age=0, must-revalidate
Cloudflare-CDN-Cache-Control: no-store
Pragma: no-cache
Expires: 0
Referrer-Policy: no-referrer
X-Content-Type-Options: nosniff
X-Frame-Options: DENY
Cross-Origin-Resource-Policy: same-origin
```

## 10.7 Gate G5

- [ ] lokaler Happy Path 200;
- [ ] Root nicht 200;
- [ ] falscher Token nicht 200;
- [ ] Range 206/1024;
- [ ] Resume-Hash korrekt;
- [ ] Mutation-Probes wirkungslos;
- [ ] nur Loopback;
- [ ] Token nicht in CommandLine;
- [ ] keine gefährlichen Flags.

---

# 11. Phase 6 – Öffentlicher Quick Tunnel

## 11.1 Ziel

Der öffentliche Link wird erst nach lokalen Gates und nur bei vollständig bestandenen öffentlichen Gates ausgegeben.

## 11.2 Cloudflared-Konfliktprüfung

Vor Start blockieren:

```text
%USERPROFILE%\.cloudflared\config.yml
%USERPROFILE%\.cloudflared\config.yaml
```

Der MVP ändert oder verschiebt diese Dateien nicht automatisch.

## 11.3 Start und URL-Erkennung

Start:

```powershell
cloudflared.exe tunnel --url http://127.0.0.1:<port> --loglevel info
```

Stdout und Stderr werden getrennt in der Session protokolliert. Aus beiden wird maximal 60 Sekunden nach einer Adresse dieses Musters gesucht:

```text
https://[a-z0-9-]+.trycloudflare.com
```

Der endgültige Capability-Link entsteht ausschließlich im Launcher-RAM:

```text
<base>/d/<token>/
```

## 11.4 Öffentliche Gates

1. Secret-Link innerhalb 60 Sekunden → 200;
2. Tunnelroot → nicht 200;
3. falsches Token → nicht 200;
4. Range → 206/1024;
5. `Cache-Control` enthält `no-store`;
6. `CF-Cache-Status` ist nicht `HIT`;
7. erst danach Link ausgeben.

## 11.5 Gate G6

- [ ] Tunnel-URL erkannt;
- [ ] Secret-Link 200;
- [ ] Root blockiert;
- [ ] falscher Token blockiert;
- [ ] Range funktioniert;
- [ ] No-Store bestätigt;
- [ ] kein Cache-HIT;
- [ ] bei Gatefehler kein Link ausgegeben.

---

# 12. Phase 7 – Lifecycle und Notfall-Cleanup

## 12.1 Ziel

Es darf nach regulärem Ende, Fehler, `Strg+C`, Launcher-Kill oder Ablauf kein funktionsfähiger Tunnel zurückbleiben.

## 12.2 Prozessidentität

Für Launcher, miniserve, cloudflared und Watchdog werden gespeichert:

- PID;
- vollständiger erwarteter Executable-Pfad;
- UTC-Startzeit als Ticks.

Ein Prozess darf nur beendet werden, wenn alle drei Werte übereinstimmen.

## 12.3 Session-Metadaten

`session.json` Schema 2 enthält:

- Erstellungs- und Ablaufzeit;
- SourceRoot und ArchivePath;
- Prozessidentitäten;
- `keepArchive`;
- niemals Token oder URL.

## 12.4 Watchdog-Start

Reihenfolge:

1. cloudflared starten;
2. erste Sessionmetadaten schreiben;
3. Watchdog sofort starten;
4. Sessionmetadaten um Watchdogidentität ergänzen;
5. URL-Erkennung fortsetzen.

Damit bleibt nur ein sehr kleines technisch unvermeidbares Fenster zwischen Prozessstart und Watchdogstart. Dieses Fenster muss im Kill-Test beobachtet und dokumentiert werden.

## 12.5 Cleanup-Reihenfolge

Regulärer Launcher:

1. cloudflared stoppen;
2. 300 ms warten;
3. miniserve stoppen;
4. erst jetzt `normal.exit` setzen;
5. Watchdog stoppen;
6. Sleep Prevention zurücksetzen;
7. Capability-Link aus Clipboard entfernen, falls noch unverändert;
8. Session löschen oder `keep.archive` setzen.

Der Marker darf nie vor dem Stoppen des Tunnels gesetzt werden. Sonst könnte der Watchdog regulär aussteigen, während der öffentliche Prozess noch läuft.

## 12.6 Watchdog-Verhalten

Watchdog räumt auf bei:

- Parentprozess fehlt;
- Parent-PID wurde wiederverwendet;
- Ablaufzeit erreicht.

Bei `normal.exit` beendet er sich erst, nachdem miniserve und cloudflared nicht mehr als die erwarteten Prozesse laufen.

## 12.7 Stale Sessions

Automatische Bereinigung nur, wenn:

- älter als 48 Stunden;
- kein `keep.archive`;
- gültiges Schema-2-`session.json`;
- keiner der verifizierten Prozesse aktiv.

Unbekannte oder beschädigte Sitzungsordner bleiben unangetastet und erzeugen eine Warnung.

## 12.8 Notfall-Stop

`Stop-WorkspaceShare.ps1`:

- liest alle Sessions;
- ignoriert unbekannte/alte Formate;
- verifiziert Prozessidentitäten;
- beendet Tunnel, Server, Watchdog;
- löscht nur nach erneuter Aktivitätsprüfung;
- respektiert `-KeepArchives` und `keepArchive`.

## 12.9 Gate G7

- [ ] Ablauf beendet Link;
- [ ] `Strg+C` beendet Link;
- [ ] Launcher-Kill wird bereinigt;
- [ ] cloudflared-Kill beendet Sitzung;
- [ ] miniserve-Kill beendet Sitzung;
- [ ] Watchdog-Kill wird erkannt;
- [ ] PID-Reuse-Test tötet keinen Fremdprozess;
- [ ] KeepArchive bleibt lokal;
- [ ] Standard löscht Session;
- [ ] Zwischenablage wird sicher bereinigt.

---

# 13. Phase 8 – Automatisierte Qualitätssicherung

## 13.1 Ziel

Ein Entwickler soll mit einem Befehl feststellen können, ob die lokale Build- und Security-Baseline intakt ist.

## 13.2 Testskript

```powershell
.\tests\Test-WorkspaceShare.ps1
```

Prüft:

- Pflichtdateien;
- Lockfile-Schema;
- installierte Hashes;
- statische gefährliche Flags;
- Environment-Tokenkonfiguration;
- Loopback-Konfiguration;
- Tokenlänge und Zeichensatz;
- lokales 200;
- Root-Negativtest;
- Falsch-Token-Negativtest;
- Token nicht in Prozesskommandozeile;
- Listening-Socket;
- Range;
- Resume;
- acht Mutation-/WebDAV-Methoden;
- Hash- und Dateilisten-Unveränderlichkeit;
- lokales No-Store;
- optional öffentliche Gates.

## 13.3 Fixtures

`New-TestFixtures.ps1` erzeugt:

1. Clean Workspace;
2. `.env`-Blockfall;
3. Gitleaks-Muster;
4. Locked-File-Grundlage;
5. Projekt-Exclude;
6. Junction;
7. optional Datei >2 GB.

## 13.4 Manuelle Ergänzungstests

Automatisierung kann folgende Fälle nicht vollständig zuverlässig simulieren:

- echter Launcher-Hard-Kill im Task Manager;
- Rechner-Sleep/Wake;
- Netzwerkwechsel;
- Unternehmensfirewall;
- zweites Gerät im LAN;
- realer 8–12-GB-Upload;
- Browser-/Chat-Linkpreview;
- Cloudflare-Ausfall.

Dafür existieren Gate-Protokolle in Phase 9.

## 13.5 Gate G8

- [ ] Testskript Exit 0;
- [ ] alle PASS;
- [ ] Fixtures verhalten sich erwartungsgemäß;
- [ ] keine Platzhalter im Releasecode;
- [ ] keine Tokenpersistenz;
- [ ] Testprotokoll archiviert.

---

# 14. Phase 9 – Last-, Resume- und 10-GB-Abnahme

## 14.1 Ziel

Die reale Zielgröße muss auf dem vorgesehenen Windows-System und Anschluss funktionieren. Kleine Unit-/Integrationstests ersetzen dies nicht.

## 14.2 Testdaten

Ein 8–12-GB-Workspace mit:

- vielen kleinen Dateien;
- mindestens einer Datei >2 GB;
- bereits komprimierten Assets;
- Unicode-Dateinamen;
- langen, aber Windows-zulässigen Pfaden;
- versteckten Projektdateien;
- Standard-Generated-Verzeichnissen;
- einem projektspezifischen Ausschluss.

Keine echten Secrets.

## 14.3 Messpunkte

Pro Lauf dokumentieren:

- Hardware;
- Windows-Build;
- Laufwerkstyp;
- Quellgröße;
- Dateianzahl;
- Snapshotdauer;
- Archivgröße;
- Gitleaksdauer;
- 7-Zip-Testdauer;
- Uploadbandbreite;
- vollständige Downloaddauer;
- durchschnittliche CPU;
- Peak-RAM;
- Peak-Disk;
- Ergebnis-Hash.

## 14.4 Testfälle

### A – Vollständiger Download

1. Share für mindestens zwei Stunden starten.
2. Link auf zweitem Gerät öffnen.
3. komplett herunterladen.
4. SHA-256 mit lokaler Hashdatei vergleichen.

### B – Resume

1. Download beginnen.
2. Verbindung nach mehreren GB abbrechen.
3. mit `curl.exe -C -` fortsetzen.
4. finalen Hash vergleichen.

### C – Ablauf

1. Laufzeit auf 15 Minuten setzen.
2. Download/HEAD vor Ablauf bestätigen.
3. Ablauf abwarten.
4. derselbe Link darf nicht mehr funktionieren.

### D – Launcher-Kill

1. Link aktivieren.
2. Launcher im Task Manager hart beenden.
3. maximal wenige Sekunden später müssen Tunnel und Server enden.
4. kein Fremdprozess darf beendet werden.

### E – Kindprozess-Kill

Jeweils miniserve und cloudflared separat hart beenden. Launcher muss Fehler erkennen und die gesamte Sitzung schließen.

### F – Netzwerkwechsel

Während aktivem Tunnel WLAN/Ethernet kurz unterbrechen und wiederherstellen. Erwartung:

- kein lokaler Datenverlust;
- bei irreparabel beendetem cloudflared Gesamtcleanup;
- kein stilles Ausgeben eines neuen Links.

## 14.5 Akzeptanzschwellen

Verbindlich:

- kein vollständiges Archiv im RAM;
- Peak-RAM bleibt betrieblich klein gegenüber Archivgröße;
- vollständiger Hash identisch;
- Resume identisch;
- kein Zugriff nach Ende;
- keine Session ohne Prozess;
- keine lokale LAN-Erreichbarkeit;
- keine Änderung des Original-Workspace.

Zeitwerte sind auf Zielhardware zu messen und organisatorisch zu akzeptieren; es gibt keinen universellen festen Grenzwert.

## 14.6 Gate G9

- [ ] 8–12 GB Snapshot erstellt;
- [ ] vollständiger Download;
- [ ] Resume;
- [ ] Hashgleichheit;
- [ ] Ablauf;
- [ ] Launcher-Kill;
- [ ] Kindprozess-Kill;
- [ ] kein RAM-Puffern;
- [ ] Uploadbandbreite akzeptabel;
- [ ] Testprotokoll signiert/abgelegt.

---

# 15. Phase 10 – Packaging, Lizenzen und internes Release

## 15.1 Ziel

Ein Empfänger erhält eine reproduzierbare, in sich geschlossene interne Distribution.

## 15.2 Release-Builder

```powershell
.\scripts\Build-InternalRelease.ps1
```

Ablauf:

1. Lockfile validieren;
2. automatisierte Tests starten;
3. Platzhalter suchen;
4. Lizenzdateien verlangen;
5. Staging-Verzeichnis erzeugen;
6. nur definierte Releasepfade kopieren;
7. Entwicklungsfixtures entfernen;
8. ZIP erstellen;
9. ZIP testen;
10. SHA-256-Nebendatei erzeugen.

## 15.3 Releaseinhalt

Enthalten:

- Runtime-Skripte;
- Wrapper;
- Konfiguration;
- gepinnte Binärdateien;
- Lockfile;
- Lizenzen;
- README;
- Security Policy;
- Tests;
- Watchdog.

Nicht enthalten:

- alte Sessions;
- echte Workspaces;
- Token;
- Cloudflare-Logs aus Tests;
- persönliche Konfiguration;
- Quell-Snapshots;
- Entwicklungsfixtures;
- nicht geprüfte Binaries.

## 15.4 Versionsregeln

- Patch: Fehlerkorrektur ohne Dependency-/Scopeänderung;
- Minor: neue optionale Funktion oder Architekturhärtung;
- Major: Sicherheitsmodell, URL-Modell oder Schreibfähigkeit geändert;
- Dependency-Update erzeugt mindestens Patch-Release und vollständige Regression.

## 15.5 Gate G10

- [ ] alle vorherigen Gates grün;
- [ ] Release-Builder Exit 0;
- [ ] Distributions-ZIP testbar;
- [ ] Release-SHA dokumentiert;
- [ ] Lockfile vollständig;
- [ ] Lizenzen vollständig;
- [ ] Versionsdatei korrekt;
- [ ] keine Laufzeitdaten enthalten;
- [ ] interne Freigabe dokumentiert.

---

# 16. Phase 11 – Pilot und Rollout

## 16.1 Pilotgruppe

Zunächst maximal zwei technisch versierte interne Nutzer.

Pilotdauer:

- mindestens fünf reale Sitzungen;
- mindestens ein großer Workspace;
- mindestens ein kontrollierter Abbruch;
- keine sensiblen Produktionsdaten im ersten Lauf.

## 16.2 Pilot-Checkliste pro Sitzung

Vorher:

- Datenklassifizierung erlaubt Cloudflare-Verarbeitung;
- Workspace ohne echte Credentials;
- Empfänger und Kanal festgelegt;
- Laufzeit passend;
- Uploadbandbreite ausreichend.

Währenddessen:

- Terminal offen;
- Link nicht öffentlich posten;
- keine Linkpreview erzeugen;
- Prozesszustand beobachten.

Danach:

- Link unbrauchbar;
- Session entfernt;
- Zwischenablage bereinigt;
- Empfänger bestätigt Hash/Archiv;
- Auffälligkeiten protokolliert.

## 16.3 Rolloutkriterien

- null Sicherheits-Gate-Bypässe;
- null verwaiste Tunnel;
- null falsche Prozessabschüsse;
- null Tokenpersistenz;
- dokumentierte False Positives handhabbar;
- Bedienung ohne Entwicklerhilfe möglich;
- Runbook ausreichend.

## 16.4 Gate G11

- [ ] Pilot abgeschlossen;
- [ ] fünf Sitzungen dokumentiert;
- [ ] mindestens ein 8–12-GB-Lauf;
- [ ] Supportfälle ausgewertet;
- [ ] Security Owner gibt frei;
- [ ] interne Distribution und Hash veröffentlicht.

---

# 17. Phase 12 – Wartung

## 17.1 Monatlich

- offene Security Advisories der vier Projekte prüfen;
- Cloudflare-Quick-Tunnel-Verhalten stichprobenartig testen;
- Windows-Updates berücksichtigen;
- Testlauf auf Referenzsystem.

## 17.2 Quartalsweise

- aktuelle Releases gegen gepinnte Versionen vergleichen;
- Upgrade nur in separatem Branch;
- neue Asset-Hashes dokumentieren;
- vollständige lokale Regression;
- öffentlicher Smoke-Test;
- Release neu bauen.

## 17.3 Jährlich

- Architektur und Datenklassifizierung neu bewerten;
- prüfen, ob Quick Tunnels noch angemessen sind;
- Alternativen für feste interne Infrastruktur bewerten;
- Gitleaks-Regelabdeckung überprüfen;
- Lizenz- und Notice-Dateien aktualisieren;
- 10-GB-Abnahme wiederholen.

## 17.4 Dependency-Upgrade-Prozess

1. Changelog lesen.
2. Security Advisories lesen.
3. CLI-Flags gegen offiziellen Help-Output prüfen.
4. neue Version und Asset-Hash im Installer ändern.
5. frische Installation.
6. EXE-Lock erzeugen.
7. alle automatisierten Tests.
8. alle öffentlichen Gates.
9. Kill-/Lifecycle-Test.
10. großes Resume-Gate.
11. neue interne Version.

Nie alle vier Komponenten gleichzeitig aktualisieren. Pro Pull Request nur eine Dependency, außer ein zwingender Kompatibilitätsverbund ist dokumentiert.

---

# 18. Exakter Implementierungsablauf für einen autonomen Entwicklungsagenten

Der Agent arbeitet streng in dieser Reihenfolge:

1. Projektstruktur erstellen.
2. Quelldokument unverändert archivieren.
3. `VERSION`, README und Security Policy anlegen.
4. Installer mit festen Quellen und Asset-Hashes implementieren.
5. Initiales `installed=false` Lockfile anlegen.
6. Installer auf sauberem Windows-System ausführen.
7. generiertes Lockfile committen beziehungsweise im internen Binärpaket sperren.
8. Launcher-Parameter und globale Cleanup-Struktur implementieren.
9. Lockprüfung implementieren.
10. Workspace-Inspektion implementieren.
11. Gitleaks implementieren.
12. Ausschlussdateien implementieren.
13. 7-Zip-Erstellung, Test, Manifest und Hash implementieren.
14. Token und korrektes Windows-Argumentquoting implementieren.
15. miniserve-Start mit Loopback und Environment-Route implementieren.
16. lokale Positiv-, Negativ-, Range- und Mutation-Gates implementieren.
17. cloudflared-Start und URL-Erkennung implementieren.
18. öffentliche Gates implementieren.
19. Sessionmetadaten Schema 2 implementieren.
20. Watchdog mit PID+Pfad+Startzeit implementieren.
21. Notfall-Stop mit denselben Identitätsregeln implementieren.
22. Cleanup-Reihenfolge implementieren.
23. Clipboard-Bereinigung implementieren.
24. Stale-Session-Regeln implementieren.
25. automatisierte lokale Tests implementieren.
26. Fixtures implementieren.
27. Testfehler beheben, ohne Gates abzuschwächen.
28. 10-GB- und Kill-Abnahme durchführen.
29. Release-Builder implementieren.
30. Lizenzen und Notices prüfen.
31. internes ZIP erzeugen.
32. Pilot durchführen.
33. erst nach G11 als betriebsbereit markieren.

Der Agent darf einen fehlgeschlagenen Test nie durch Entfernen, Überspringen oder Abschwächen des Gates „lösen“. Er muss die Ursache beheben oder den Release blockieren.

---

# 19. Definition of Done

Das Tool ist **implementiert**, wenn:

- Code und Konfiguration vollständig vorliegen;
- Dependency-Installer erfolgreich ist;
- Lockfile generiert und verifiziert wird;
- lokale Tests grün sind;
- Cloudflare-Smoke-Test grün ist.

Das Tool ist **releasefähig**, wenn zusätzlich:

- alle Gates G0–G10 grün sind;
- 10-GB-Test bestanden ist;
- Kill-/Watchdog-Tests bestanden sind;
- Lizenzen vollständig sind;
- Release-ZIP und Hash erzeugt sind.

Das Tool ist **intern betriebsbereit**, wenn zusätzlich:

- Pilot G11 bestanden ist;
- Owner für Wartung benannt ist;
- Datenklassifizierung und Nutzungskanal freigegeben sind.

---

# 20. Abnahmematrix

| ID | Test | Erwartung | Automatisch |
|---|---|---|---:|
| A01 | Lock fehlt | Exit 11, kein Snapshot | ja |
| A02 | EXE manipuliert | Exit 11 | ja |
| A03 | unlesbares Verzeichnis | Exit 20 | teilweise |
| A04 | Junction | Exit 20 | Fixture |
| A05 | `.env` | Exit 22 | Fixture |
| A06 | Gitleaks-Muster | Exit 22 | Fixture |
| A07 | Clean Workspace | Snapshot | manuell/E2E |
| A08 | `.git` | nicht im ZIP | manuell |
| A09 | Generated default | nicht im ZIP | manuell |
| A10 | `-IncludeGenerated` | im ZIP | manuell |
| A11 | Datei >2 GB | erfolgreich | groß/manuell |
| A12 | ZIP >4 GB | erfolgreich | groß/manuell |
| A13 | Archivtest | Exit 0 | E2E |
| A14 | Root lokal | nicht 200 | ja |
| A15 | falscher Token lokal | nicht 200 | ja |
| A16 | Range lokal | 206/1024 | ja |
| A17 | Resume lokal | Hash identisch | ja |
| A18 | Mutation-Probes | keine Änderung | ja |
| A19 | LAN-Zugriff | nicht möglich | manuell |
| A20 | Token CommandLine | nicht vorhanden | ja |
| A21 | Root öffentlich | nicht 200 | ja |
| A22 | falscher Token öffentlich | nicht 200 | ja |
| A23 | Range öffentlich | 206 | ja |
| A24 | Cache | no-store, kein HIT | ja |
| A25 | Ablauf | Link tot | manuell |
| A26 | Strg+C | Link tot | manuell |
| A27 | Launcher-Kill | Watchdog räumt auf | manuell |
| A28 | PID-Reuse | Fremdprozess bleibt | manuell |
| A29 | KeepArchive | lokal vorhanden, Link tot | manuell |
| A30 | Standardende | Session gelöscht | manuell |
| A31 | 10-GB-Download | Hash identisch | manuell |
| A32 | 10-GB-Resume | Hash identisch | manuell |
| A33 | Release-ZIP | testbar, Hash vorhanden | automatisiert |

---

# 21. Betriebliches Runbook

## 21.1 Einmalige Installation

```powershell
Set-Location "C:\Tools\WorkspaceShare"
.\Install-Dependencies.ps1
.\tests\Test-WorkspaceShare.ps1
```

## 21.2 Normale Freigabe

```powershell
.\Share-Workspace.ps1 -Path "D:\Projekte\Roswell" -Hours 4
```

## 21.3 Schnelle Freigabe bereits komprimierter Assets

```powershell
.\Share-Workspace.ps1 `
  -Path "D:\Projekte\Roswell" `
  -Hours 2 `
  -Compression Store
```

## 21.4 Lokales Archiv behalten

```powershell
.\Share-Workspace.ps1 `
  -Path "D:\Projekte\Roswell" `
  -Minutes 30 `
  -KeepArchive
```

## 21.5 Sofort stoppen

```powershell
.\Stop-WorkspaceShare.ps1
```

## 21.6 Release bauen

```powershell
.\scripts\Build-InternalRelease.ps1
```

---

# 22. Troubleshooting

## Fehler 10 – cloudflared-Konfiguration vorhanden

Prüfen:

```powershell
Test-Path "$env:USERPROFILE\.cloudflared\config.yml"
Test-Path "$env:USERPROFILE\.cloudflared\config.yaml"
```

Die Datei für den Testzeitraum manuell umbenennen oder einen separaten Windows-Benutzer verwenden. Das Tool verändert sie nicht.

## Fehler 11 – Hashabweichung

Keine Ausnahme zulassen. Vorgehen:

```powershell
.\Install-Dependencies.ps1 -Force
.\tests\Test-WorkspaceShare.ps1
```

Bleibt die Abweichung, Releasequelle und Security Advisories prüfen.

## Fehler 20 – Reparse-Point

Den gemeldeten Link/Junction aus dem Share-Root entfernen oder den realen Inhalt in einen normalen Ordner kopieren.

## Fehler 22 – Secret-Fund

Fund prüfen, echte Credentials rotieren und aus dem Workspace entfernen. Keine pauschale Allowlist hinzufügen, nur um den Flow fortzusetzen.

## Fehler 23 – 7-Zip

- gesperrte Dateien;
- zu wenig Speicher;
- ungültige Pfade;
- defekte Eingabedateien;
- Antivirus-Interaktion

prüfen. Die Logs liegen im Sessionordner, solange dieser noch existiert oder mit `-KeepArchive` erhalten wurde.

## Fehler 42 – keine Tunnel-URL

- ausgehende Netzwerkverbindung;
- Proxy;
- Unternehmensfirewall;
- Cloudflare-Störung;
- bestehende Cloudflared-Konfiguration

prüfen. Keine eingehende Firewallregel und keine Router-Portweiterleitung anlegen.

## Fehler 43 – Cache-/Range-Gate

Nicht umgehen. Versionen, Headerausgabe und aktuelles Cloudflare-Verhalten prüfen. Bis zur Ursachenklärung kein Release.

---

# 23. Vollständiger kopierbereiter Code

Die nachfolgenden Dateien bilden zusammen die vollständige Implementierung. Binärdateien werden aus Lizenz- und Supply-Chain-Gründen nicht eingebettet, sondern durch `Install-Dependencies.ps1` aus den fest gepinnten offiziellen Release-Assets geladen und geprüft.

## Datei: `Share-Workspace.ps1`

````powershell
#requires -Version 5.1
<#
.SYNOPSIS
    Erstellt einen read-only Workspace-Snapshot und veröffentlicht ihn für kurze Zeit
    über einen geheimen Cloudflare-Quick-Tunnel-Link.

.DESCRIPTION
    Sicherheitsmodell:
    - exakt ein ZIP-Snapshot wird bereitgestellt;
    - keine Verzeichnisfreigabe;
    - keine Upload-, Lösch-, mkdir- oder WebDAV-Funktionen;
    - lokaler Server bindet ausschließlich an 127.0.0.1;
    - 256-Bit-Capability-Token im URL-Pfad;
    - Cloudflare Quick Tunnel;
    - automatische Abschaltung und Bereinigung;
    - Token und vollständige URL werden nicht dauerhaft protokolliert.

    Diese Referenzimplementierung ist absichtlich Windows-/PowerShell-5.1-kompatibel.
    Vor produktiver interner Nutzung müssen alle Gates aus _internetKonzept3.md
    erfolgreich bestanden werden.

.EXAMPLE
    .\Share-Workspace.ps1 -Path "D:\Projekte\Roswell" -Hours 4

.EXAMPLE
    .\Share-Workspace.ps1 -Path "D:\Projekte\Roswell" -Minutes 15 -KeepArchive
#>

[CmdletBinding(DefaultParameterSetName = 'Hours')]
param(
    [Parameter(Mandatory = $true, Position = 0)]
    [ValidateScript({ Test-Path -LiteralPath $_ -PathType Container })]
    [string]$Path,

    [Parameter(ParameterSetName = 'Hours')]
    [ValidateRange(1, 24)]
    [int]$Hours = 4,

    [Parameter(Mandatory = $true, ParameterSetName = 'Minutes')]
    [ValidateRange(1, 1440)]
    [int]$Minutes,

    [ValidateSet('Fast', 'Store')]
    [string]$Compression = 'Fast',

    [switch]$IncludeGenerated,
    [switch]$UnsafeSkipSecretScan,
    [switch]$TestMode,
    [switch]$KeepArchive,
    [switch]$KeepClipboard,
    [switch]$NoClipboard,

    [string]$ToolRoot = $PSScriptRoot
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

# ---------------------------------------------------------------------------
# Konstanten
# ---------------------------------------------------------------------------

$script:ExitCode = 0
$script:SessionDirectory = $null
$script:ArchivePath = $null
$script:MiniserveProcess = $null
$script:CloudflaredProcess = $null
$script:WatchdogProcess = $null
$script:SleepPreventionEnabled = $false
$script:NormalExitMarker = $null
$script:ClipboardUrl = $null
$script:KeepArchiveMarker = $null

$BinDirectory = Join-Path $ToolRoot 'bin'
$ConfigDirectory = Join-Path $ToolRoot 'config'
$ScriptsDirectory = Join-Path $ToolRoot 'scripts'

$SevenZipPath = Join-Path $BinDirectory '7za.exe'
$MiniservePath = Join-Path $BinDirectory 'miniserve.exe'
$CloudflaredPath = Join-Path $BinDirectory 'cloudflared.exe'
$GitleaksPath = Join-Path $BinDirectory 'gitleaks.exe'
$curlCommand = Get-Command 'curl.exe' -ErrorAction SilentlyContinue
$CurlPath = if ($curlCommand) { $curlCommand.Source } else { $null }

$MandatoryExcludesPath = Join-Path $ConfigDirectory 'mandatory-excludes.txt'
$GeneratedExcludesPath = Join-Path $ConfigDirectory 'generated-excludes.txt'
$GitleaksConfigPath = Join-Path $ConfigDirectory 'gitleaks-workspaceshare.toml'
$DependencyLockPath = Join-Path $ToolRoot 'dependencies.lock.json'
$WatchdogScriptPath = Join-Path $ScriptsDirectory 'Watch-WorkspaceShare.ps1'

$SessionBase = if ($env:LOCALAPPDATA) {
    Join-Path $env:LOCALAPPDATA 'WorkspaceShare\sessions'
} else {
    Join-Path ([IO.Path]::GetTempPath()) 'WorkspaceShare\sessions'
}

# ---------------------------------------------------------------------------
# Hilfsfunktionen
# ---------------------------------------------------------------------------

function Write-Step {
    param(
        [Parameter(Mandatory = $true)][int]$Number,
        [Parameter(Mandatory = $true)][int]$Total,
        [Parameter(Mandatory = $true)][string]$Text
    )
    Write-Host ("[{0}/{1}] {2}" -f $Number, $Total, $Text)
}

function Stop-WithError {
    param(
        [Parameter(Mandatory = $true)][string]$Message,
        [int]$Code = 50
    )
    throw [System.Exception]::new(("E{0}: {1}" -f $Code, $Message))
}

function Require-File {
    param(
        [Parameter(Mandatory = $true)][string]$FilePath,
        [Parameter(Mandatory = $true)][string]$FriendlyName,
        [int]$Code = 10
    )
    if (-not (Test-Path -LiteralPath $FilePath -PathType Leaf)) {
        Stop-WithError -Code $Code -Message (
            "{0} wurde nicht gefunden.`nErwarteter Pfad: {1}" -f
            $FriendlyName, $FilePath
        )
    }
}


function Get-ProcessStartTicksSafe {
    param([System.Diagnostics.Process]$Process)

    if ($null -eq $Process) {
        return [int64]0
    }

    try {
        $Process.Refresh()
        return [int64]$Process.StartTime.ToUniversalTime().Ticks
    }
    catch {
        return [int64]0
    }
}

function Test-ProcessIdentity {
    param(
        [int]$ProcessId,
        [string]$ExpectedPath,
        [long]$ExpectedStartTicks
    )

    if ($ProcessId -le 0 -or -not $ExpectedPath -or $ExpectedStartTicks -le 0) {
        return $false
    }

    try {
        $process = Get-Process -Id $ProcessId -ErrorAction Stop
        if (-not $process.Path) {
            return $false
        }

        $samePath = (
            [IO.Path]::GetFullPath($process.Path) -eq
            [IO.Path]::GetFullPath($ExpectedPath)
        )
        $sameStart = (
            $process.StartTime.ToUniversalTime().Ticks -eq
            $ExpectedStartTicks
        )
        return ($samePath -and $sameStart)
    }
    catch {
        return $false
    }
}

function Assert-DependencyLock {
    Require-File -FilePath $DependencyLockPath -FriendlyName 'dependencies.lock.json' -Code 11

    try {
        $lock = Get-Content -LiteralPath $DependencyLockPath -Raw | ConvertFrom-Json
    }
    catch {
        Stop-WithError -Code 11 -Message (
            "dependencies.lock.json ist ungültig. " +
            "Führe .\Install-Dependencies.ps1 erneut aus."
        )
    }

    if ([int]$lock.schema -ne 2 -or -not $lock.installed) {
        Stop-WithError -Code 11 -Message (
            "Die Abhängigkeiten wurden noch nicht reproduzierbar installiert. " +
            "Führe zuerst .\Install-Dependencies.ps1 aus."
        )
    }

    $seen = @{}
    foreach ($dependency in @($lock.dependencies)) {
        $relative = ([string]$dependency.file).Replace('/', [IO.Path]::DirectorySeparatorChar)
        $filePath = Join-Path $ToolRoot $relative
        Require-File -FilePath $filePath -FriendlyName ([string]$dependency.name) -Code 11

        $expectedHash = ([string]$dependency.sha256).ToUpperInvariant()
        if ($expectedHash -notmatch '^[A-F0-9]{64}$') {
            Stop-WithError -Code 11 -Message (
                "Ungültiger SHA-256-Lockwert für $($dependency.name). " +
                "Führe .\Install-Dependencies.ps1 erneut aus."
            )
        }

        $actualHash = (Get-FileHash -LiteralPath $filePath -Algorithm SHA256).Hash.ToUpperInvariant()
        if ($actualHash -ne $expectedHash) {
            Stop-WithError -Code 11 -Message (
                "Checksumme stimmt nicht für $($dependency.name).`n" +
                "Erwartet: $expectedHash`nTatsächlich: $actualHash`n" +
                "Die Freigabe wurde fail-closed abgebrochen."
            )
        }

        $seen[[string]$dependency.name] = $true
    }

    foreach ($requiredName in @('cloudflared','miniserve','7-Zip','Gitleaks')) {
        if (-not $seen.ContainsKey($requiredName)) {
            Stop-WithError -Code 11 -Message (
                "Lockfile enthält die Pflichtabhängigkeit '$requiredName' nicht."
            )
        }
    }
}

function Get-ExecutableVersionText {
    param(
        [Parameter(Mandatory = $true)][string]$FilePath,
        [string[]]$Arguments = @('--version')
    )
    try {
        $output = & $FilePath @Arguments 2>&1
        if ($LASTEXITCODE -ne 0) {
            return "Version konnte nicht gelesen werden (Exit $LASTEXITCODE)"
        }
        return (($output | Out-String).Trim())
    }
    catch {
        return "Version konnte nicht gelesen werden: $($_.Exception.Message)"
    }
}

function New-CapabilityToken {
    # 32 kryptografisch zufällige Bytes = 256 Bit Entropie.
    $bytes = New-Object byte[] 32
    $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    try {
        $rng.GetBytes($bytes)
    }
    finally {
        $rng.Dispose()
    }

    return [Convert]::ToBase64String($bytes).
        TrimEnd('=').
        Replace('+', '-').
        Replace('/', '_')
}

function Get-FreeTcpPort {
    # Zwischen Freigabe und Serverstart besteht theoretisch eine kleine Port-Race.
    # Der Aufrufer versucht deshalb bei Bindefehlern mehrere Ports.
    $listener = New-Object System.Net.Sockets.TcpListener(
        [System.Net.IPAddress]::Loopback, 0
    )
    try {
        $listener.Start()
        return ([System.Net.IPEndPoint]$listener.LocalEndpoint).Port
    }
    finally {
        $listener.Stop()
    }
}

function ConvertTo-NativeArgument {
    <#
        Korrektes Windows-Quoting für ProcessStartInfo.Arguments.
        Notwendig für Pfade und Header mit Leerzeichen/Anführungszeichen.
    #>
    param([AllowEmptyString()][string]$Value)

    if ($null -eq $Value -or $Value.Length -eq 0) {
        return '""'
    }

    if ($Value -notmatch '[\s"]') {
        return $Value
    }

    $builder = New-Object System.Text.StringBuilder
    [void]$builder.Append('"')
    $backslashes = 0

    foreach ($character in $Value.ToCharArray()) {
        if ($character -eq '\') {
            $backslashes++
            continue
        }

        if ($character -eq '"') {
            [void]$builder.Append(('\' * (($backslashes * 2) + 1)))
            [void]$builder.Append('"')
            $backslashes = 0
            continue
        }

        if ($backslashes -gt 0) {
            [void]$builder.Append(('\' * $backslashes))
            $backslashes = 0
        }

        [void]$builder.Append($character)
    }

    if ($backslashes -gt 0) {
        # Backslashes direkt vor dem schließenden Quote müssen verdoppelt werden.
        [void]$builder.Append(('\' * ($backslashes * 2)))
    }

    [void]$builder.Append('"')
    return $builder.ToString()
}

function Join-NativeArguments {
    param([string[]]$Arguments)
    return (($Arguments | ForEach-Object { ConvertTo-NativeArgument $_ }) -join ' ')
}

function Start-NativeProcess {
    param(
        [Parameter(Mandatory = $true)][string]$FilePath,
        [string[]]$Arguments = @(),
        [hashtable]$Environment = @{},
        [string]$WorkingDirectory = $ToolRoot,
        [switch]$CreateNoWindow
    )

    $startInfo = New-Object System.Diagnostics.ProcessStartInfo
    $startInfo.FileName = $FilePath
    $startInfo.Arguments = Join-NativeArguments $Arguments
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = [bool]$CreateNoWindow
    $startInfo.WorkingDirectory = $WorkingDirectory

    foreach ($key in $Environment.Keys) {
        $startInfo.EnvironmentVariables[$key] = [string]$Environment[$key]
    }

    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $startInfo

    if (-not $process.Start()) {
        Stop-WithError -Code 30 -Message "Prozess konnte nicht gestartet werden: $FilePath"
    }

    return $process
}

function Get-ProcessSafe {
    param([int]$ProcessId)
    try {
        return Get-Process -Id $ProcessId -ErrorAction Stop
    }
    catch {
        return $null
    }
}

function Stop-ProcessSafe {
    param(
        [System.Diagnostics.Process]$Process,
        [int]$WaitMilliseconds = 2000
    )

    if ($null -eq $Process) {
        return
    }

    try {
        $Process.Refresh()
        if (-not $Process.HasExited) {
            Stop-Process -Id $Process.Id -Force -ErrorAction SilentlyContinue
            [void]$Process.WaitForExit($WaitMilliseconds)
        }
    }
    catch {
        # Cleanup ist best effort; der finale Verfügbarkeitstest erkennt Restfehler.
    }
}

function Get-CurlStatus {
    param(
        [Parameter(Mandatory = $true)][string]$Url,
        [int]$TimeoutSeconds = 10,
        [switch]$Head
    )

    $arguments = @(
        '--silent',
        '--show-error',
        '--output', 'NUL',
        '--write-out', '%{http_code}',
        '--max-time', [string]$TimeoutSeconds
    )

    if ($Head) {
        $arguments += '--head'
    }

    $arguments += $Url

    $result = & $CurlPath @arguments 2>$null
    $curlExit = $LASTEXITCODE

    if ($curlExit -ne 0 -and -not $result) {
        return 0
    }

    $statusText = (($result | Select-Object -Last 1) | Out-String).Trim()
    $status = 0
    if ([int]::TryParse($statusText, [ref]$status)) {
        return $status
    }

    return 0
}

function Wait-ForHttpStatus {
    param(
        [Parameter(Mandatory = $true)][string]$Url,
        [int[]]$AcceptedStatus = @(200),
        [int]$TimeoutSeconds = 30
    )

    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)

    do {
        $status = Get-CurlStatus -Url $Url -TimeoutSeconds 5 -Head
        if ($AcceptedStatus -contains $status) {
            return $status
        }
        Start-Sleep -Milliseconds 500
    } while ([DateTime]::UtcNow -lt $deadline)

    return 0
}

function Test-RangeRequest {
    param(
        [Parameter(Mandatory = $true)][string]$Url,
        [Parameter(Mandatory = $true)][string]$TemporaryDirectory
    )

    $bodyPath = Join-Path $TemporaryDirectory ('range-' + [Guid]::NewGuid().ToString('N') + '.bin')
    $headerPath = Join-Path $TemporaryDirectory ('headers-' + [Guid]::NewGuid().ToString('N') + '.txt')

    try {
        $result = & $CurlPath @(
            '--silent',
            '--show-error',
            '--max-time', '30',
            '--header', 'Range: bytes=0-1023',
            '--dump-header', $headerPath,
            '--output', $bodyPath,
            '--write-out', '%{http_code}',
            $Url
        ) 2>$null

        if ($LASTEXITCODE -ne 0) {
            return $false
        }

        $statusText = (($result | Select-Object -Last 1) | Out-String).Trim()
        $length = if (Test-Path -LiteralPath $bodyPath) {
            (Get-Item -LiteralPath $bodyPath).Length
        } else {
            0
        }

        return ($statusText -eq '206' -and $length -eq 1024)
    }
    finally {
        Remove-Item -LiteralPath $bodyPath -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $headerPath -Force -ErrorAction SilentlyContinue
    }
}

function Get-HeaderDump {
    param(
        [Parameter(Mandatory = $true)][string]$Url,
        [Parameter(Mandatory = $true)][string]$OutputPath
    )

    & $CurlPath @(
        '--silent',
        '--show-error',
        '--max-time', '20',
        '--head',
        '--dump-header', $OutputPath,
        '--output', 'NUL',
        $Url
    ) 2>$null | Out-Null

    return $LASTEXITCODE
}

function Read-PatternFile {
    param([Parameter(Mandatory = $true)][string]$FilePath)

    if (-not (Test-Path -LiteralPath $FilePath -PathType Leaf)) {
        return @()
    }

    return @(
        Get-Content -LiteralPath $FilePath |
        ForEach-Object { $_.Trim() } |
        Where-Object {
            $_ -and -not $_.StartsWith('#')
        }
    )
}

function Test-ForbiddenFilename {
    param([Parameter(Mandatory = $true)][string]$Name)

    $lower = $Name.ToLowerInvariant()

    # Dokumentations-/Beispieldateien sind erlaubt.
    if (
        $lower -in @('.env.example', '.env.template', '.env.sample') -or
        $lower.EndsWith('.example') -or
        $lower.EndsWith('.template') -or
        $lower.EndsWith('.sample')
    ) {
        return $false
    }

    if ($lower -eq '.env' -or $lower.StartsWith('.env.')) {
        return $true
    }

    $patterns = @(
        '*.pem',
        '*.key',
        '*.pfx',
        '*.p12',
        '*.jks',
        '*.keystore',
        'id_rsa',
        'id_rsa.*',
        'id_ed25519',
        'id_ed25519.*',
        'credentials.json',
        'service-account*.json',
        'service_account*.json',
        'secrets.json',
        'secret.json',
        '*.mobileprovision',
        '*.ovpn'
    )

    foreach ($pattern in $patterns) {
        if ($lower -like $pattern) {
            return $true
        }
    }

    return $false
}

function Inspect-Workspace {
    param(
        [Parameter(Mandatory = $true)][string]$Root,
        [switch]$IncludeGeneratedContent
    )

    $skipDirectoryNames = @{
        '.git' = $true
        '.svn' = $true
        '.hg' = $true
    }

    if (-not $IncludeGeneratedContent) {
        foreach ($name in @(
            'node_modules', 'Library', 'Temp', 'obj', 'dist', 'build',
            'out', 'coverage', '.cache', '.gradle', 'DerivedData',
            '.vs', 'Logs'
        )) {
            $skipDirectoryNames[$name] = $true
        }
    }

    $stack = New-Object 'System.Collections.Generic.Stack[System.IO.DirectoryInfo]'
    $stack.Push((Get-Item -LiteralPath $Root))

    $estimatedBytes = [int64]0
    $fileCount = [int64]0
    $forbiddenFiles = New-Object System.Collections.Generic.List[string]
    $reparsePoints = New-Object System.Collections.Generic.List[string]
    $accessErrors = New-Object System.Collections.Generic.List[string]

    while ($stack.Count -gt 0) {
        $directory = $stack.Pop()

        try {
            $entries = $directory.EnumerateFileSystemInfos()
        }
        catch {
            $accessErrors.Add($directory.FullName)
            continue
        }

        foreach ($entry in $entries) {
            $isReparse = (
                ($entry.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0
            )

            if ($isReparse) {
                $reparsePoints.Add($entry.FullName)
                continue
            }

            if ($entry -is [System.IO.DirectoryInfo]) {
                if (-not $skipDirectoryNames.ContainsKey($entry.Name)) {
                    $stack.Push($entry)
                }
                continue
            }

            if ($entry -is [System.IO.FileInfo]) {
                $fileCount++
                $estimatedBytes += $entry.Length

                if (Test-ForbiddenFilename -Name $entry.Name) {
                    $forbiddenFiles.Add($entry.FullName)
                }
            }
        }
    }

    return [pscustomobject]@{
        EstimatedBytes = $estimatedBytes
        FileCount = $fileCount
        ForbiddenFiles = @($forbiddenFiles)
        ReparsePoints = @($reparsePoints)
        AccessErrors = @($accessErrors)
    }
}

function Get-CloudflaredConfigConflicts {
    $directory = Join-Path $env:USERPROFILE '.cloudflared'
    return @(
        Join-Path $directory 'config.yml'
        Join-Path $directory 'config.yaml'
    ) | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf }
}

function Assert-FreeDiskSpace {
    param(
        [Parameter(Mandatory = $true)][string]$TargetDirectory,
        [Parameter(Mandatory = $true)][int64]$EstimatedSourceBytes
    )

    $root = [IO.Path]::GetPathRoot([IO.Path]::GetFullPath($TargetDirectory))
    $drive = New-Object System.IO.DriveInfo($root)
    $required = $EstimatedSourceBytes + 2GB

    if ($drive.AvailableFreeSpace -lt $required) {
        Stop-WithError -Code 21 -Message (
            "Nicht genügend freier Speicher für den Snapshot.`n" +
            "Konservativ benötigt: {0:N2} GB`nVerfügbar: {1:N2} GB" -f
            ($required / 1GB), ($drive.AvailableFreeSpace / 1GB)
        )
    }
}

function Invoke-GitleaksScan {
    param(
        [Parameter(Mandatory = $true)][string]$SourceRoot,
        [Parameter(Mandatory = $true)][string]$ReportPath
    )

    $arguments = @(
        'dir',
        '--config', $GitleaksConfigPath,
        '--no-banner',
        '--no-color',
        '--redact=100',
        '--report-format', 'json',
        '--report-path', $ReportPath,
        '--exit-code', '20',
        '--timeout', '900',
        $SourceRoot
    )

    & $GitleaksPath @arguments
    $code = $LASTEXITCODE

    if ($code -eq 20) {
        Stop-WithError -Code 22 -Message (
            "Gitleaks hat mögliche Geheimnisse gefunden. " +
            "Der redigierte Bericht liegt unter:`n$ReportPath"
        )
    }

    if ($code -ne 0) {
        Stop-WithError -Code 22 -Message (
            "Gitleaks konnte den Workspace nicht zuverlässig prüfen (Exit $code). " +
            "Die Freigabe wurde sicherheitshalber abgebrochen."
        )
    }
}

function Invoke-SevenZipSnapshot {
    param(
        [Parameter(Mandatory = $true)][string]$SourceRoot,
        [Parameter(Mandatory = $true)][string]$DestinationArchive,
        [Parameter(Mandatory = $true)][string[]]$ExclusionPatterns,
        [Parameter(Mandatory = $true)][string]$LogPath
    )

    $parent = Split-Path -LiteralPath $SourceRoot -Parent
    $leaf = Split-Path -LiteralPath $SourceRoot -Leaf

    if (-not $parent -or -not $leaf) {
        Stop-WithError -Code 23 -Message (
            "Ein Laufwerksstamm kann im MVP nicht direkt freigegeben werden: $SourceRoot"
        )
    }

    $compressionArgument = if ($Compression -eq 'Store') { '-mx=0' } else { '-mx=1' }

    $arguments = @(
        'a',
        '-tzip',
        $compressionArgument,
        '-mmt=on',
        '-sse',
        '-y',
        '-bd',
        '-bb1',
        $DestinationArchive,
        $leaf
    )

    foreach ($pattern in $ExclusionPatterns) {
        $arguments += ("-xr!{0}" -f $pattern)
    }

    Push-Location $parent
    try {
        & $SevenZipPath @arguments 2>&1 |
            Tee-Object -FilePath $LogPath |
            Write-Host
        $code = $LASTEXITCODE
    }
    finally {
        Pop-Location
    }

    if ($code -ne 0) {
        Stop-WithError -Code 23 -Message (
            "7-Zip konnte keinen vollständigen Snapshot erstellen (Exit $code). " +
            "Details: $LogPath"
        )
    }

    if (
        -not (Test-Path -LiteralPath $DestinationArchive -PathType Leaf) -or
        (Get-Item -LiteralPath $DestinationArchive).Length -le 0
    ) {
        Stop-WithError -Code 23 -Message "Das erzeugte Archiv fehlt oder ist leer."
    }
}

function Test-SevenZipArchive {
    param(
        [Parameter(Mandatory = $true)][string]$ArchivePath,
        [Parameter(Mandatory = $true)][string]$LogPath
    )

    & $SevenZipPath @('t', '-bd', '-bb1', $ArchivePath) 2>&1 |
        Tee-Object -FilePath $LogPath |
        Write-Host

    if ($LASTEXITCODE -ne 0) {
        Stop-WithError -Code 23 -Message (
            "Die Integritätsprüfung des ZIP-Archivs ist fehlgeschlagen. Details: $LogPath"
        )
    }
}

function Write-SevenZipManifest {
    param(
        [Parameter(Mandatory = $true)][string]$ArchivePath,
        [Parameter(Mandatory = $true)][string]$ManifestPath
    )

    & $SevenZipPath @('l', '-slt', $ArchivePath) 2>&1 |
        Set-Content -LiteralPath $ManifestPath -Encoding UTF8

    if ($LASTEXITCODE -ne 0) {
        Stop-WithError -Code 23 -Message "Das Archivmanifest konnte nicht erstellt werden."
    }
}

function Start-MiniserveReadOnly {
    param(
        [Parameter(Mandatory = $true)][string]$Archive,
        [Parameter(Mandatory = $true)][string]$CapabilityToken,
        [Parameter(Mandatory = $true)][int]$Port
    )

    $arguments = @(
        '--quiet',
        '--log-color', 'never',
        '--interfaces', '127.0.0.1',
        '--port', [string]$Port,
        '--workers', '2',
        '--no-symlinks',

        '--header', 'Cache-Control: private, no-store, no-cache, max-age=0, must-revalidate',
        '--header', 'Cloudflare-CDN-Cache-Control: no-store',
        '--header', 'Pragma: no-cache',
        '--header', 'Expires: 0',
        '--header', 'Referrer-Policy: no-referrer',
        '--header', 'X-Content-Type-Options: nosniff',
        '--header', 'X-Frame-Options: DENY',
        '--header', 'Cross-Origin-Resource-Policy: same-origin',

        $Archive
    )

    # Token bewusst nicht in der Prozesskommandozeile:
    $environment = @{
        MINISERVE_ROUTE_PREFIX = ("d/{0}" -f $CapabilityToken)
    }

    return Start-NativeProcess `
        -FilePath $MiniservePath `
        -Arguments $arguments `
        -Environment $environment `
        -WorkingDirectory $script:SessionDirectory `
        -CreateNoWindow
}

function Start-CloudflaredQuickTunnel {
    param(
        [Parameter(Mandatory = $true)][string]$OriginUrl,
        [Parameter(Mandatory = $true)][string]$StdOutPath,
        [Parameter(Mandatory = $true)][string]$StdErrPath
    )

    return Start-Process `
        -FilePath $CloudflaredPath `
        -ArgumentList @('tunnel', '--url', $OriginUrl, '--loglevel', 'info') `
        -RedirectStandardOutput $StdOutPath `
        -RedirectStandardError $StdErrPath `
        -WindowStyle Hidden `
        -PassThru
}

function Wait-ForQuickTunnelUrl {
    param(
        [Parameter(Mandatory = $true)][System.Diagnostics.Process]$Process,
        [Parameter(Mandatory = $true)][string[]]$LogPaths,
        [int]$TimeoutSeconds = 60
    )

    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    $regex = 'https://[a-z0-9-]+\.trycloudflare\.com'

    do {
        $Process.Refresh()
        if ($Process.HasExited) {
            Stop-WithError -Code 41 -Message (
                "cloudflared wurde vor Bereitstellung des Tunnels beendet (Exit " +
                "$($Process.ExitCode))."
            )
        }

        $combined = ''
        foreach ($logPath in $LogPaths) {
            if (Test-Path -LiteralPath $logPath) {
                $combined += "`n" + (Get-Content -LiteralPath $logPath -Raw -ErrorAction SilentlyContinue)
            }
        }

        $match = [regex]::Match($combined, $regex)
        if ($match.Success) {
            return $match.Value.TrimEnd('/')
        }

        Start-Sleep -Milliseconds 500
    } while ([DateTime]::UtcNow -lt $deadline)

    Stop-WithError -Code 42 -Message (
        "Cloudflare hat innerhalb von $TimeoutSeconds Sekunden keine Quick-Tunnel-URL geliefert."
    )
}

function Assert-CacheHeaders {
    param(
        [Parameter(Mandatory = $true)][string]$Url,
        [Parameter(Mandatory = $true)][string]$HeaderPath
    )

    $curlExit = Get-HeaderDump -Url $Url -OutputPath $HeaderPath
    if ($curlExit -ne 0) {
        Stop-WithError -Code 43 -Message "Öffentliche Antwortheader konnten nicht geprüft werden."
    }

    $headers = Get-Content -LiteralPath $HeaderPath -Raw

    if ($headers -match '(?im)^cf-cache-status:\s*HIT\s*$') {
        Stop-WithError -Code 43 -Message (
            "Cloudflare meldet CF-Cache-Status: HIT. Die Freigabe wird nicht fortgesetzt."
        )
    }

    if ($headers -notmatch '(?im)^cache-control:.*\bno-store\b') {
        Stop-WithError -Code 43 -Message (
            "Der öffentliche Endpunkt liefert keinen bestätigten Cache-Control:no-store-Header."
        )
    }
}

function Enable-SystemAwake {
    try {
        if (-not ('WorkspaceShare.NativePower' -as [type])) {
            Add-Type @'
using System;
using System.Runtime.InteropServices;

namespace WorkspaceShare {
    public static class NativePower {
        [DllImport("kernel32.dll", SetLastError = true)]
        public static extern uint SetThreadExecutionState(uint esFlags);
    }
}
'@
        }

        # ES_CONTINUOUS | ES_SYSTEM_REQUIRED
        [void][WorkspaceShare.NativePower]::SetThreadExecutionState(0x80000001)
        $script:SleepPreventionEnabled = $true
    }
    catch {
        Write-Warning (
            "Windows-Energiesparmodus konnte nicht automatisch verhindert werden. " +
            "Bitte den Rechner während der Freigabe wach halten."
        )
    }
}

function Disable-SystemAwake {
    if ($script:SleepPreventionEnabled) {
        try {
            # ES_CONTINUOUS
            [void][WorkspaceShare.NativePower]::SetThreadExecutionState(0x80000000)
        }
        catch {
        }
    }
}

function Copy-LinkToClipboard {
    param([Parameter(Mandatory = $true)][string]$Url)

    if ($NoClipboard) {
        return
    }

    $setClipboard = Get-Command 'Set-Clipboard' -ErrorAction SilentlyContinue
    if ($setClipboard) {
        $Url | Set-Clipboard
        $script:ClipboardUrl = $Url
        return
    }

    $Url | & "$env:SystemRoot\System32\clip.exe"
    $script:ClipboardUrl = $Url
}

function Clear-SensitiveClipboard {
    if ($NoClipboard -or $KeepClipboard -or -not $script:ClipboardUrl) {
        return
    }

    try {
        $getClipboard = Get-Command 'Get-Clipboard' -ErrorAction SilentlyContinue
        $setClipboard = Get-Command 'Set-Clipboard' -ErrorAction SilentlyContinue
        if ($getClipboard -and $setClipboard) {
            $current = Get-Clipboard -Raw -ErrorAction Stop
            if ($current.TrimEnd([char[]]"`r`n") -eq $script:ClipboardUrl) {
                '' | Set-Clipboard
            }
        }
    }
    catch {
        # Keine Freigabe darf wegen einer Clipboard-Bereinigung scheitern.
    }
}

function Write-SessionMetadata {
    param(
        [Parameter(Mandatory = $true)][datetime]$ExpiresUtc,
        [Parameter(Mandatory = $true)][string]$SourceRoot,
        [Parameter(Mandatory = $true)][string]$Archive,
        [int]$WatchdogPid = 0,
        [long]$WatchdogStartTicks = 0
    )

    $powershellExe = Join-Path $PSHOME 'powershell.exe'
    $launcherProcess = Get-Process -Id $PID

    $metadata = [ordered]@{
        schema = 2
        createdUtc = [DateTime]::UtcNow.ToString('o')
        expiresUtc = $ExpiresUtc.ToString('o')
        sourceRoot = $SourceRoot
        archivePath = $Archive

        launcherPid = $PID
        launcherStartTicks = $launcherProcess.StartTime.ToUniversalTime().Ticks
        launcherPath = $powershellExe

        miniservePid = if ($script:MiniserveProcess) { $script:MiniserveProcess.Id } else { 0 }
        miniserveStartTicks = Get-ProcessStartTicksSafe $script:MiniserveProcess
        miniservePath = $MiniservePath

        cloudflaredPid = if ($script:CloudflaredProcess) { $script:CloudflaredProcess.Id } else { 0 }
        cloudflaredStartTicks = Get-ProcessStartTicksSafe $script:CloudflaredProcess
        cloudflaredPath = $CloudflaredPath

        watchdogPid = $WatchdogPid
        watchdogStartTicks = $WatchdogStartTicks
        watchdogPath = $powershellExe

        keepArchive = [bool]$KeepArchive
        # Bewusst keine URL und kein Capability-Token.
    }

    $metadata |
        ConvertTo-Json -Depth 4 |
        Set-Content -LiteralPath (Join-Path $script:SessionDirectory 'session.json') -Encoding UTF8
}

function Start-Watchdog {
    param(
        [Parameter(Mandatory = $true)][datetime]$ExpiresUtc
    )

    Require-File -FilePath $WatchdogScriptPath -FriendlyName 'Watchdog-Skript' -Code 10

    $parent = Get-Process -Id $PID
    $parentStartTicks = $parent.StartTime.ToUniversalTime().Ticks
    $miniserveStartTicks = Get-ProcessStartTicksSafe $script:MiniserveProcess
    $cloudflaredStartTicks = Get-ProcessStartTicksSafe $script:CloudflaredProcess

    $arguments = @(
        '-NoProfile',
        '-ExecutionPolicy', 'Bypass',
        '-File', $WatchdogScriptPath,
        '-ParentPid', [string]$PID,
        '-ParentStartTicks', [string]$parentStartTicks,
        '-MiniservePid', [string]$script:MiniserveProcess.Id,
        '-MiniserveStartTicks', [string]$miniserveStartTicks,
        '-CloudflaredPid', [string]$script:CloudflaredProcess.Id,
        '-CloudflaredStartTicks', [string]$cloudflaredStartTicks,
        '-SessionPath', $script:SessionDirectory,
        '-NormalExitMarker', $script:NormalExitMarker,
        '-ExpiresUtc', $ExpiresUtc.ToString('o'),
        '-ExpectedMiniservePath', $MiniservePath,
        '-ExpectedCloudflaredPath', $CloudflaredPath
    )

    if ($KeepArchive) {
        $arguments += '-KeepArchive'
    }

    $powershellExe = Join-Path $PSHOME 'powershell.exe'
    return Start-NativeProcess `
        -FilePath $powershellExe `
        -Arguments $arguments `
        -WorkingDirectory $ToolRoot `
        -CreateNoWindow
}

function Remove-StaleSessions {
    if (-not (Test-Path -LiteralPath $SessionBase -PathType Container)) {
        return
    }

    $cutoff = [DateTime]::UtcNow.AddHours(-48)

    foreach ($directory in Get-ChildItem -LiteralPath $SessionBase -Directory -ErrorAction SilentlyContinue) {
        if ($directory.LastWriteTimeUtc -ge $cutoff) {
            continue
        }

        if (Test-Path -LiteralPath (Join-Path $directory.FullName 'keep.archive') -PathType Leaf) {
            continue
        }

        $metadataPath = Join-Path $directory.FullName 'session.json'
        if (-not (Test-Path -LiteralPath $metadataPath -PathType Leaf)) {
            Write-Warning "Alte Sitzung ohne verifizierbare Metadaten bleibt bestehen: $($directory.FullName)"
            continue
        }

        try {
            $session = Get-Content -LiteralPath $metadataPath -Raw | ConvertFrom-Json
        }
        catch {
            Write-Warning "Alte Sitzung mit ungültigen Metadaten bleibt bestehen: $($directory.FullName)"
            continue
        }

        $active = $false
        foreach ($identity in @(
            @{ Pid = [int]$session.miniservePid; Path = [string]$session.miniservePath; Ticks = [long]$session.miniserveStartTicks },
            @{ Pid = [int]$session.cloudflaredPid; Path = [string]$session.cloudflaredPath; Ticks = [long]$session.cloudflaredStartTicks },
            @{ Pid = [int]$session.watchdogPid; Path = [string]$session.watchdogPath; Ticks = [long]$session.watchdogStartTicks }
        )) {
            if (Test-ProcessIdentity -ProcessId $identity.Pid -ExpectedPath $identity.Path -ExpectedStartTicks $identity.Ticks) {
                $active = $true
                break
            }
        }

        if (-not $active) {
            Remove-Item -LiteralPath $directory.FullName -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

# ---------------------------------------------------------------------------
# Hauptablauf
# ---------------------------------------------------------------------------

try {
    Write-Host ''
    Write-Host 'WorkspaceShare 3.1 – read-only Quick-Tunnel-Freigabe'
    Write-Host '====================================================='
    Write-Host ''

    $totalSteps = 8

    Write-Step 1 $totalSteps 'Abhängigkeiten und Umgebung prüfen ...'

    if ($UnsafeSkipSecretScan -and -not $TestMode) {
        Stop-WithError -Code 10 -Message (
            "-UnsafeSkipSecretScan ist ausschließlich zusammen mit -TestMode zulässig. " +
            "Im normalen Betrieb ist der Secret-Scan verpflichtend."
        )
    }

    Assert-DependencyLock

    foreach ($required in @(
        @{ Path = $SevenZipPath; Name = '7za.exe'; Code = 10 },
        @{ Path = $MiniservePath; Name = 'miniserve.exe'; Code = 10 },
        @{ Path = $CloudflaredPath; Name = 'cloudflared.exe'; Code = 10 },
        @{ Path = $MandatoryExcludesPath; Name = 'mandatory-excludes.txt'; Code = 10 },
        @{ Path = $GeneratedExcludesPath; Name = 'generated-excludes.txt'; Code = 10 }
    )) {
        Require-File -FilePath $required.Path -FriendlyName $required.Name -Code $required.Code
    }

    if (-not $CurlPath) {
        Stop-WithError -Code 10 -Message (
            "curl.exe wurde nicht gefunden. Moderne Windows-10/11-Versionen enthalten curl.exe."
        )
    }

    if (-not $UnsafeSkipSecretScan) {
        Require-File -FilePath $GitleaksPath -FriendlyName 'gitleaks.exe' -Code 10
        Require-File -FilePath $GitleaksConfigPath -FriendlyName 'Gitleaks-Konfiguration' -Code 10
    }

    $cloudflaredConflicts = @(Get-CloudflaredConfigConflicts)
    if ($cloudflaredConflicts.Count -gt 0) {
        Stop-WithError -Code 10 -Message (
            "Eine bestehende cloudflared-Konfiguration kann Quick Tunnels blockieren:`n" +
            ($cloudflaredConflicts -join "`n") +
            "`nDatei vorübergehend umbenennen oder einen separaten Windows-Benutzer verwenden."
        )
    }

    Remove-StaleSessions

    $resolvedRoot = (Resolve-Path -LiteralPath $Path).Path.TrimEnd('\')
    $rootParent = Split-Path -LiteralPath $resolvedRoot -Parent
    $rootLeaf = Split-Path -LiteralPath $resolvedRoot -Leaf

    if (-not $rootParent -or -not $rootLeaf) {
        Stop-WithError -Code 10 -Message "Ein Laufwerksstamm kann nicht freigegeben werden."
    }

    $duration = if ($PSCmdlet.ParameterSetName -eq 'Minutes') {
        [TimeSpan]::FromMinutes($Minutes)
    } else {
        [TimeSpan]::FromHours($Hours)
    }

    $expiresUtc = $null

    Write-Host ("      Quelle: {0}" -f $resolvedRoot)
    Write-Host ("      Laufzeit: {0}" -f $duration)
    Write-Host ("      7-Zip: {0}" -f (Get-ExecutableVersionText -FilePath $SevenZipPath -Arguments @('i')))
    Write-Host ("      miniserve: {0}" -f (Get-ExecutableVersionText -FilePath $MiniservePath))
    Write-Host ("      cloudflared: {0}" -f (Get-ExecutableVersionText -FilePath $CloudflaredPath))
    if (-not $UnsafeSkipSecretScan) {
        Write-Host ("      Gitleaks: {0}" -f (Get-ExecutableVersionText -FilePath $GitleaksPath -Arguments @('version')))
    }

    Write-Step 2 $totalSteps 'Workspace auf offensichtliche Risiken prüfen ...'

    $inspection = Inspect-Workspace `
        -Root $resolvedRoot `
        -IncludeGeneratedContent:$IncludeGenerated

    if ($inspection.AccessErrors.Count -gt 0) {
        $preview = $inspection.AccessErrors | Select-Object -First 20
        Stop-WithError -Code 20 -Message (
            "Mindestens ein Verzeichnis konnte nicht gelesen werden. " +
            "Ein unvollständiger Snapshot wird nicht erzeugt:`n" +
            ($preview -join "`n")
        )
    }

    if ($inspection.ReparsePoints.Count -gt 0) {
        $preview = $inspection.ReparsePoints | Select-Object -First 20
        Stop-WithError -Code 20 -Message (
            "Symlinks/Junctions/Reparse-Points wurden gefunden. " +
            "Sie müssen entfernt oder bewusst außerhalb des Share-Roots abgelegt werden:`n" +
            ($preview -join "`n")
        )
    }

    if ($inspection.ForbiddenFiles.Count -gt 0) {
        $preview = $inspection.ForbiddenFiles | Select-Object -First 30
        Stop-WithError -Code 22 -Message (
            "Potenziell sensible Schlüssel-/Konfigurationsdateien wurden gefunden:`n" +
            ($preview -join "`n") +
            "`nDiese Dateien dürfen nicht stillschweigend mitgeteilt werden."
        )
    }

    Write-Host ("      Geprüfte Dateien: {0:N0}" -f $inspection.FileCount)
    Write-Host ("      Konservative Quellgröße: {0:N2} GB" -f ($inspection.EstimatedBytes / 1GB))

    $sessionId = "{0}-{1}" -f (
        [DateTime]::UtcNow.ToString('yyyyMMdd-HHmmss'),
        [Guid]::NewGuid().ToString('N').Substring(0, 8)
    )
    $script:SessionDirectory = Join-Path $SessionBase $sessionId
    New-Item -ItemType Directory -Path $script:SessionDirectory -Force | Out-Null

    $script:NormalExitMarker = Join-Path $script:SessionDirectory 'normal.exit'
    $script:KeepArchiveMarker = Join-Path $script:SessionDirectory 'keep.archive'
    $script:ArchivePath = Join-Path $script:SessionDirectory (
        "workspace-{0}.zip" -f [DateTime]::UtcNow.ToString('yyyyMMdd-HHmmss')
    )

    Assert-FreeDiskSpace `
        -TargetDirectory $script:SessionDirectory `
        -EstimatedSourceBytes $inspection.EstimatedBytes

    if (-not $UnsafeSkipSecretScan) {
        Write-Step 3 $totalSteps 'Workspace mit Gitleaks prüfen ...'
        $gitleaksReport = Join-Path $script:SessionDirectory 'gitleaks-redacted.json'
        Invoke-GitleaksScan -SourceRoot $resolvedRoot -ReportPath $gitleaksReport
        Write-Host '      Keine von Gitleaks erkannten Secrets.'
    } else {
        Write-Step 3 $totalSteps 'Gitleaks-Prüfung wurde explizit übersprungen.'
        Write-Warning (
            'Die inhaltliche Secret-Prüfung ist deaktiviert. ' +
            'Dateinamen- und Reparse-Point-Gates bleiben aktiv.'
        )
    }

    Write-Step 4 $totalSteps 'Bereinigten ZIP64-Snapshot erzeugen ...'

    $exclusions = New-Object System.Collections.Generic.List[string]

    foreach ($pattern in Read-PatternFile $MandatoryExcludesPath) {
        $exclusions.Add($pattern)
    }

    if (-not $IncludeGenerated) {
        foreach ($pattern in Read-PatternFile $GeneratedExcludesPath) {
            $exclusions.Add($pattern)
        }
    }

    $projectExcludePath = Join-Path $resolvedRoot '.workspace-share.exclude.txt'
    if (Test-Path -LiteralPath $projectExcludePath -PathType Leaf) {
        foreach ($pattern in Read-PatternFile $projectExcludePath) {
            $exclusions.Add($pattern)
        }
        Write-Host ("      Projektausschlüsse geladen: {0}" -f $projectExcludePath)
    }

    $archiveCreateLog = Join-Path $script:SessionDirectory '7zip-create.log'
    $archiveTestLog = Join-Path $script:SessionDirectory '7zip-test.log'
    $archiveManifest = Join-Path $script:SessionDirectory 'archive-manifest.txt'

    Invoke-SevenZipSnapshot `
        -SourceRoot $resolvedRoot `
        -DestinationArchive $script:ArchivePath `
        -ExclusionPatterns @($exclusions | Select-Object -Unique) `
        -LogPath $archiveCreateLog

    Test-SevenZipArchive `
        -ArchivePath $script:ArchivePath `
        -LogPath $archiveTestLog

    Write-SevenZipManifest `
        -ArchivePath $script:ArchivePath `
        -ManifestPath $archiveManifest

    $archiveHash = (Get-FileHash -LiteralPath $script:ArchivePath -Algorithm SHA256).Hash
    $archiveSize = (Get-Item -LiteralPath $script:ArchivePath).Length

    Set-Content `
        -LiteralPath (Join-Path $script:SessionDirectory 'archive.sha256.txt') `
        -Value ("{0}  {1}" -f $archiveHash, (Split-Path $script:ArchivePath -Leaf)) `
        -Encoding ASCII

    Write-Host ("      Archivgröße: {0:N2} GB" -f ($archiveSize / 1GB))
    Write-Host ("      SHA-256: {0}" -f $archiveHash)

    Write-Step 5 $totalSteps 'Read-only-Dateiserver auf Loopback starten ...'

    $token = New-CapabilityToken
    $miniserveStarted = $false
    $port = 0

    for ($attempt = 1; $attempt -le 5; $attempt++) {
        $port = Get-FreeTcpPort
        try {
            $script:MiniserveProcess = Start-MiniserveReadOnly `
                -Archive $script:ArchivePath `
                -CapabilityToken $token `
                -Port $port

            $localUrl = "http://127.0.0.1:{0}/d/{1}/" -f $port, $token
            $localStatus = Wait-ForHttpStatus `
                -Url $localUrl `
                -AcceptedStatus @(200) `
                -TimeoutSeconds 10

            if ($localStatus -eq 200) {
                $miniserveStarted = $true
                break
            }

            Stop-ProcessSafe $script:MiniserveProcess
            $script:MiniserveProcess = $null
        }
        catch {
            Stop-ProcessSafe $script:MiniserveProcess
            $script:MiniserveProcess = $null
        }
    }

    if (-not $miniserveStarted) {
        Stop-WithError -Code 30 -Message (
            "miniserve konnte nach fünf Versuchen nicht zuverlässig auf Loopback starten."
        )
    }

    # Negativtest: ohne Capability-Pfad darf der Root nicht erfolgreich sein.
    $localRootStatus = Get-CurlStatus `
        -Url ("http://127.0.0.1:{0}/" -f $port) `
        -TimeoutSeconds 5 `
        -Head

    if ($localRootStatus -eq 200) {
        Stop-WithError -Code 31 -Message (
            "Der lokale Server liefert ohne Geheimtoken HTTP 200. Sicherheits-Gate fehlgeschlagen."
        )
    }

    $localWrongTokenUrl = "http://127.0.0.1:{0}/d/{1}/" -f $port, (New-CapabilityToken)
    $localWrongTokenStatus = Get-CurlStatus -Url $localWrongTokenUrl -TimeoutSeconds 5 -Head
    if ($localWrongTokenStatus -eq 200) {
        Stop-WithError -Code 31 -Message (
            "Der lokale Server liefert mit einem falschen Capability-Token HTTP 200."
        )
    }

    if (-not (Test-RangeRequest -Url $localUrl -TemporaryDirectory $script:SessionDirectory)) {
        Stop-WithError -Code 31 -Message (
            "Lokaler Range-Test (206/1024 Bytes) ist fehlgeschlagen."
        )
    }

    # Read-only-Prüfung: Methoden dürfen weder Datei noch Sitzungsverzeichnis verändern.
    $hashBeforeMethodTests = (Get-FileHash -LiteralPath $script:ArchivePath -Algorithm SHA256).Hash
    $filesBeforeMethodTests = @(
        Get-ChildItem -LiteralPath $script:SessionDirectory -File -Recurse |
        ForEach-Object { $_.FullName.Substring($script:SessionDirectory.Length).ToLowerInvariant() } |
        Sort-Object
    )

    foreach ($method in @('POST', 'PUT', 'PATCH', 'DELETE', 'PROPFIND', 'MKCOL', 'MOVE', 'COPY')) {
        & $CurlPath @(
            '--silent',
            '--show-error',
            '--max-time', '10',
            '--request', $method,
            '--header', 'Destination: /d/forbidden-target',
            '--data-binary', 'WorkspaceShare mutation probe',
            '--output', 'NUL',
            $localUrl
        ) 2>$null | Out-Null
    }

    $hashAfterMethodTests = (Get-FileHash -LiteralPath $script:ArchivePath -Algorithm SHA256).Hash
    $filesAfterMethodTests = @(
        Get-ChildItem -LiteralPath $script:SessionDirectory -File -Recurse |
        ForEach-Object { $_.FullName.Substring($script:SessionDirectory.Length).ToLowerInvariant() } |
        Sort-Object
    )

    if (
        $hashBeforeMethodTests -ne $hashAfterMethodTests -or
        (Compare-Object $filesBeforeMethodTests $filesAfterMethodTests)
    ) {
        Stop-WithError -Code 31 -Message (
            "Die Mutation-Probes haben Datei- oder Verzeichnisinhalt verändert. Read-only-Gate fehlgeschlagen."
        )
    }

    Write-Host ("      Lokaler Port: {0} (nur 127.0.0.1)" -f $port)
    Write-Host '      HEAD, Geheimroute, Range und Unveränderlichkeit bestätigt.'

    Write-Step 6 $totalSteps 'Kostenlosen Cloudflare Quick Tunnel starten ...'

    # Die bestellte Link-Laufzeit beginnt erst jetzt. Langsame Secret-Scans und
    # Snapshot-Erstellung verbrauchen keine Freigabezeit.
    $expiresUtc = [DateTime]::UtcNow.Add($duration)

    $cloudflaredStdOut = Join-Path $script:SessionDirectory 'cloudflared.stdout.log'
    $cloudflaredStdErr = Join-Path $script:SessionDirectory 'cloudflared.stderr.log'
    $originUrl = "http://127.0.0.1:{0}" -f $port

    $script:CloudflaredProcess = Start-CloudflaredQuickTunnel `
        -OriginUrl $originUrl `
        -StdOutPath $cloudflaredStdOut `
        -StdErrPath $cloudflaredStdErr

    # Ab dem Moment, in dem ein öffentlicher Tunnelprozess existiert, muss der
    # Watchdog aktiv sein. Ein harter Launcher-Abbruch während URL-Erkennung oder
    # öffentlicher Tests darf keinen verwaisten Tunnel hinterlassen.
    Write-SessionMetadata `
        -ExpiresUtc $expiresUtc `
        -SourceRoot $resolvedRoot `
        -Archive $script:ArchivePath

    $script:WatchdogProcess = Start-Watchdog -ExpiresUtc $expiresUtc

    Write-SessionMetadata `
        -ExpiresUtc $expiresUtc `
        -SourceRoot $resolvedRoot `
        -Archive $script:ArchivePath `
        -WatchdogPid $script:WatchdogProcess.Id `
        -WatchdogStartTicks (Get-ProcessStartTicksSafe $script:WatchdogProcess)

    $publicBaseUrl = Wait-ForQuickTunnelUrl `
        -Process $script:CloudflaredProcess `
        -LogPaths @($cloudflaredStdOut, $cloudflaredStdErr) `
        -TimeoutSeconds 60

    $finalUrl = "{0}/d/{1}/" -f $publicBaseUrl, $token

    Write-Step 7 $totalSteps 'Öffentlichen Endpunkt vollständig prüfen ...'

    $publicStatus = Wait-ForHttpStatus `
        -Url $finalUrl `
        -AcceptedStatus @(200) `
        -TimeoutSeconds 60

    if ($publicStatus -ne 200) {
        Stop-WithError -Code 43 -Message (
            "Der öffentliche Geheimlink lieferte nicht rechtzeitig HTTP 200."
        )
    }

    $publicRootStatus = Get-CurlStatus `
        -Url ($publicBaseUrl + '/') `
        -TimeoutSeconds 10 `
        -Head

    if ($publicRootStatus -eq 200) {
        Stop-WithError -Code 43 -Message (
            "Die öffentliche Tunnelwurzel ist ohne Geheimtoken erfolgreich erreichbar."
        )
    }

    $wrongTokenUrl = "{0}/d/{1}/" -f $publicBaseUrl, (New-CapabilityToken)
    $wrongTokenStatus = Get-CurlStatus `
        -Url $wrongTokenUrl `
        -TimeoutSeconds 10 `
        -Head

    if ($wrongTokenStatus -eq 200) {
        Stop-WithError -Code 43 -Message "Ein falsches Capability-Token lieferte HTTP 200."
    }

    if (-not (Test-RangeRequest -Url $finalUrl -TemporaryDirectory $script:SessionDirectory)) {
        Stop-WithError -Code 43 -Message (
            "Der öffentliche Range-Test (206/1024 Bytes) ist fehlgeschlagen."
        )
    }

    $publicHeadersPath = Join-Path $script:SessionDirectory 'public-headers.txt'
    Assert-CacheHeaders -Url $finalUrl -HeaderPath $publicHeadersPath

    Write-Host '      Öffentliche HEAD-, Negativ-, Range- und Cache-Gates bestanden.'

    Write-Step 8 $totalSteps 'Freigabe aktivieren und Ablauf überwachen ...'

    Enable-SystemAwake

    Copy-LinkToClipboard -Url $finalUrl

    Write-Host ''
    Write-Host 'FREIGABE BEREIT'
    Write-Host '================'
    Write-Host ''
    Write-Host 'Direktlink:'
    Write-Host $finalUrl
    Write-Host ''
    if (-not $NoClipboard) {
        Write-Host 'Der Link wurde in die Zwischenablage kopiert.'
    }
    Write-Host ("Aktiv bis: {0}" -f $expiresUtc.ToLocalTime().ToString('dd.MM.yyyy HH:mm:ss'))
    Write-Host ("Archiv: {0:N2} GB" -f ($archiveSize / 1GB))
    Write-Host ("SHA-256: {0}" -f $archiveHash)
    Write-Host ''
    Write-Host 'Dieses Fenster geöffnet lassen. Vorzeitig beenden: Strg+C'
    Write-Host ''

    $lastMinuteShown = -1

    while ([DateTime]::UtcNow -lt $expiresUtc) {
        $script:MiniserveProcess.Refresh()
        $script:CloudflaredProcess.Refresh()
        $script:WatchdogProcess.Refresh()

        if ($script:MiniserveProcess.HasExited) {
            Stop-WithError -Code 50 -Message (
                "miniserve wurde unerwartet beendet (Exit $($script:MiniserveProcess.ExitCode))."
            )
        }

        if ($script:CloudflaredProcess.HasExited) {
            Stop-WithError -Code 50 -Message (
                "cloudflared wurde unerwartet beendet (Exit $($script:CloudflaredProcess.ExitCode))."
            )
        }

        if ($script:WatchdogProcess.HasExited) {
            Stop-WithError -Code 50 -Message (
                "Der Sicherheits-Watchdog wurde unerwartet beendet."
            )
        }

        $remaining = $expiresUtc - [DateTime]::UtcNow
        $wholeMinutes = [Math]::Max(0, [Math]::Ceiling($remaining.TotalMinutes))

        if ($wholeMinutes -ne $lastMinuteShown) {
            Write-Host ("      Verbleibend: ca. {0} Minute(n)" -f $wholeMinutes)
            $lastMinuteShown = $wholeMinutes
        }

        Start-Sleep -Seconds 2
    }

    Write-Host ''
    Write-Host 'Die festgelegte Freigabezeit ist abgelaufen.'
    $script:ExitCode = 0
}
catch {
    $message = $_.Exception.Message
    $parsedCode = 50

    if ($message -match '^E(\d+):\s*(.*)$') {
        $parsedCode = [int]$matches[1]
        $message = $matches[2]
    }

    $script:ExitCode = $parsedCode
    Write-Host ''
    Write-Error $message
}
finally {
    # Öffentliches Ende zuerst. Der Watchdog bleibt bis nach dem Prozessende aktiv.
    Stop-ProcessSafe $script:CloudflaredProcess
    Start-Sleep -Milliseconds 300
    Stop-ProcessSafe $script:MiniserveProcess

    # Erst jetzt darf der Watchdog regulär aussteigen. So entsteht kein Fenster,
    # in dem der Marker gesetzt ist, aber der Tunnel noch läuft.
    if ($script:NormalExitMarker -and $script:SessionDirectory) {
        try {
            New-Item -ItemType File -Path $script:NormalExitMarker -Force | Out-Null
        }
        catch {
        }
    }

    Stop-ProcessSafe $script:WatchdogProcess
    Disable-SystemAwake
    Clear-SensitiveClipboard

    if ($script:SessionDirectory -and (Test-Path -LiteralPath $script:SessionDirectory)) {
        if ($KeepArchive) {
            try {
                New-Item -ItemType File -Path $script:KeepArchiveMarker -Force | Out-Null
            }
            catch {
            }

            Write-Warning (
                "Der lokale Sitzungsordner bleibt wegen -KeepArchive bestehen:`n" +
                $script:SessionDirectory
            )
        }
        else {
            Remove-Item `
                -LiteralPath $script:SessionDirectory `
                -Recurse `
                -Force `
                -ErrorAction SilentlyContinue
        }
    }

    Write-Host ''
    Write-Host 'Tunnel und lokaler Server wurden beendet.'
    if (-not $KeepArchive) {
        Write-Host 'Der temporäre Snapshot wurde gelöscht.'
    }
}

exit $script:ExitCode
````

## Datei: `Stop-WorkspaceShare.ps1`

````powershell
#requires -Version 5.1
<#
.SYNOPSIS
    Beendet ausschließlich eindeutig verifizierte WorkspaceShare-Sitzungen.

.DESCRIPTION
    Eine Prozessbeendigung erfolgt nur, wenn PID, Executable-Pfad und
    Prozessstartzeit mit session.json übereinstimmen. Unbekannte oder beschädigte
    Sitzungsordner werden nicht automatisch gelöscht.
#>

[CmdletBinding()]
param(
    [switch]$KeepArchives
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Continue'

$sessionBase = if ($env:LOCALAPPDATA) {
    Join-Path $env:LOCALAPPDATA 'WorkspaceShare\sessions'
} else {
    Join-Path ([IO.Path]::GetTempPath()) 'WorkspaceShare\sessions'
}

function Get-VerifiedProcess {
    param(
        [int]$ProcessId,
        [string]$ExpectedPath,
        [long]$ExpectedStartTicks
    )

    if ($ProcessId -le 0 -or -not $ExpectedPath -or $ExpectedStartTicks -le 0) {
        return $null
    }

    try {
        $process = Get-Process -Id $ProcessId -ErrorAction Stop
        if (-not $process.Path) {
            return $null
        }

        if (
            [IO.Path]::GetFullPath($process.Path) -ne
            [IO.Path]::GetFullPath($ExpectedPath)
        ) {
            return $null
        }

        if ($process.StartTime.ToUniversalTime().Ticks -ne $ExpectedStartTicks) {
            return $null
        }

        return $process
    }
    catch {
        return $null
    }
}

function Stop-VerifiedProcess {
    param(
        [int]$ProcessId,
        [string]$ExpectedPath,
        [long]$ExpectedStartTicks,
        [string]$Role
    )

    $process = Get-VerifiedProcess `
        -ProcessId $ProcessId `
        -ExpectedPath $ExpectedPath `
        -ExpectedStartTicks $ExpectedStartTicks

    if (-not $process) {
        if ($ProcessId -gt 0) {
            Write-Host "$Role PID $ProcessId ist bereits beendet oder nicht eindeutig verifizierbar."
        }
        return
    }

    try {
        Stop-Process -Id $process.Id -Force -ErrorAction Stop
        try { [void]$process.WaitForExit(3000) } catch {}
        Write-Host "$Role PID $($process.Id) beendet."
    }
    catch {
        Write-Warning "$Role PID $($process.Id) konnte nicht beendet werden: $($_.Exception.Message)"
    }
}

if (-not (Test-Path -LiteralPath $sessionBase -PathType Container)) {
    Write-Host 'Keine WorkspaceShare-Sitzungen gefunden.'
    exit 0
}

$sessionDirectories = @(Get-ChildItem -LiteralPath $sessionBase -Directory)

if ($sessionDirectories.Count -eq 0) {
    Write-Host 'Keine WorkspaceShare-Sitzungen gefunden.'
    exit 0
}

foreach ($directory in $sessionDirectories) {
    Write-Host ''
    Write-Host "Prüfe Sitzung: $($directory.Name)"

    $metadataPath = Join-Path $directory.FullName 'session.json'
    if (-not (Test-Path -LiteralPath $metadataPath -PathType Leaf)) {
        Write-Warning (
            "Sitzung ohne verifizierbare Metadaten bleibt unangetastet: " +
            $directory.FullName
        )
        continue
    }

    try {
        $session = Get-Content -LiteralPath $metadataPath -Raw | ConvertFrom-Json
    }
    catch {
        Write-Warning (
            "Ungültige Sitzungsmetadaten; Ordner bleibt unangetastet: " +
            $directory.FullName
        )
        continue
    }

    if ([int]$session.schema -lt 2) {
        Write-Warning (
            "Altes Sitzungsformat ohne vollständigen PID-Reuse-Schutz. " +
            "Ordner bleibt unangetastet: $($directory.FullName)"
        )
        continue
    }

    # Tunnel zuerst, danach Dateiserver, zuletzt Watchdog.
    Stop-VerifiedProcess `
        -ProcessId ([int]$session.cloudflaredPid) `
        -ExpectedPath ([string]$session.cloudflaredPath) `
        -ExpectedStartTicks ([long]$session.cloudflaredStartTicks) `
        -Role 'cloudflared'

    Start-Sleep -Milliseconds 300

    Stop-VerifiedProcess `
        -ProcessId ([int]$session.miniservePid) `
        -ExpectedPath ([string]$session.miniservePath) `
        -ExpectedStartTicks ([long]$session.miniserveStartTicks) `
        -Role 'miniserve'

    Stop-VerifiedProcess `
        -ProcessId ([int]$session.watchdogPid) `
        -ExpectedPath ([string]$session.watchdogPath) `
        -ExpectedStartTicks ([long]$session.watchdogStartTicks) `
        -Role 'Watchdog'

    $effectiveKeep = $KeepArchives -or [bool]$session.keepArchive
    if ($effectiveKeep) {
        try {
            New-Item -ItemType File -Path (Join-Path $directory.FullName 'keep.archive') -Force | Out-Null
        }
        catch {}
        Write-Host "Sitzung beendet; lokale Dateien behalten: $($directory.FullName)"
        continue
    }

    # Vor dem Löschen erneut sicherstellen, dass keine verifizierten Prozesse laufen.
    $stillActive = $false
    foreach ($identity in @(
        @{ Pid = [int]$session.cloudflaredPid; Path = [string]$session.cloudflaredPath; Ticks = [long]$session.cloudflaredStartTicks },
        @{ Pid = [int]$session.miniservePid; Path = [string]$session.miniservePath; Ticks = [long]$session.miniserveStartTicks },
        @{ Pid = [int]$session.watchdogPid; Path = [string]$session.watchdogPath; Ticks = [long]$session.watchdogStartTicks }
    )) {
        if (Get-VerifiedProcess -ProcessId $identity.Pid -ExpectedPath $identity.Path -ExpectedStartTicks $identity.Ticks) {
            $stillActive = $true
            break
        }
    }

    if ($stillActive) {
        Write-Warning "Sitzungsordner wird nicht gelöscht, weil noch ein verifizierter Prozess läuft."
        continue
    }

    Remove-Item -LiteralPath $directory.FullName -Recurse -Force -ErrorAction SilentlyContinue
    if (Test-Path -LiteralPath $directory.FullName) {
        Write-Warning "Sitzungsordner konnte nicht vollständig entfernt werden: $($directory.FullName)"
    } else {
        Write-Host "Sitzung entfernt: $($directory.FullName)"
    }
}

exit 0
````

## Datei: `Install-Dependencies.ps1`

````powershell
#requires -Version 5.1
<#
.SYNOPSIS
    Installiert die exakt gepinnten WorkspaceShare-Abhängigkeiten.

.DESCRIPTION
    Lädt ausschließlich fest definierte offizielle Release-Assets, prüft deren
    SHA-256-Werte vor dem Entpacken und erzeugt anschließend ein Lockfile mit
    den SHA-256-Werten der tatsächlich ausgeführten EXE-Dateien.

    Für das Entpacken des offiziellen 7-Zip-Extra-Pakets wird eine vorhandene
    7z.exe verwendet. Fehlt sie, installiert das Skript 7-Zip 26.02 über WinGet.

.EXAMPLE
    .\Install-Dependencies.ps1

.EXAMPLE
    .\Install-Dependencies.ps1 -Force
#>

[CmdletBinding()]
param(
    [switch]$Force,
    [string]$ToolRoot = $PSScriptRoot
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$bin = Join-Path $ToolRoot 'bin'
$licenses = Join-Path $bin 'licenses'
$lockPath = Join-Path $ToolRoot 'dependencies.lock.json'
$temp = Join-Path ([IO.Path]::GetTempPath()) ('WorkspaceShare-Dependencies-' + [Guid]::NewGuid().ToString('N'))
$stage = Join-Path $temp 'stage'

$assets = @(
    [ordered]@{
        name = 'cloudflared'
        version = '2026.7.3'
        url = 'https://github.com/cloudflare/cloudflared/releases/download/2026.7.3/cloudflared-windows-amd64.exe'
        sha256 = '8635DA433B6DF8194746E88ED9D2589566C20E38BFC2A80E431A348B7C765841'
        type = 'exe'
        output = 'cloudflared.exe'
        license = 'Apache-2.0'
        licenseUrl = 'https://raw.githubusercontent.com/cloudflare/cloudflared/2026.7.3/LICENSE'
        source = 'https://github.com/cloudflare/cloudflared/releases/tag/2026.7.3'
    },
    [ordered]@{
        name = 'miniserve'
        version = '0.35.0'
        url = 'https://github.com/svenstaro/miniserve/releases/download/v0.35.0/miniserve-0.35.0-x86_64-pc-windows-msvc.exe'
        sha256 = '3229E75B40B3870382D23C9A0ECEC880B9BD5F6E49160CE602BB15D00F275B6A'
        type = 'exe'
        output = 'miniserve.exe'
        license = 'MIT'
        licenseUrl = 'https://raw.githubusercontent.com/svenstaro/miniserve/v0.35.0/LICENSE'
        source = 'https://github.com/svenstaro/miniserve/releases/tag/v0.35.0'
    },
    [ordered]@{
        name = 'Gitleaks'
        version = '8.30.1'
        url = 'https://github.com/gitleaks/gitleaks/releases/download/v8.30.1/gitleaks_8.30.1_windows_x64.zip'
        # GitHub-Asset-Digest des aktuellen offiziellen Assets.
        sha256 = 'D29144DEFF3A68AA93CED33DDDF84B7FDC26070ADD4AA0F4513094C8332AFC4E'
        type = 'zip'
        output = 'gitleaks.exe'
        license = 'MIT'
        licenseUrl = 'https://raw.githubusercontent.com/gitleaks/gitleaks/v8.30.1/LICENSE'
        source = 'https://github.com/gitleaks/gitleaks/releases/tag/v8.30.1'
    },
    [ordered]@{
        name = '7-Zip'
        version = '26.02'
        url = 'https://github.com/ip7z/7zip/releases/download/26.02/7z2602-extra.7z'
        sha256 = '081DF9E9311DFD9C9E0E98C1C80180B99BB51E4CB24156B5F3057FE3C259D70A'
        type = '7z'
        output = '7za.exe'
        license = 'LGPL-2.1-or-later plus bundled notices/exceptions'
        licenseUrl = ''
        source = 'https://github.com/ip7z/7zip/releases/tag/26.02'
    }
)

function Write-Phase {
    param([int]$Number, [int]$Total, [string]$Text)
    Write-Host ("[{0}/{1}] {2}" -f $Number, $Total, $Text)
}

function Get-Sha256 {
    param([string]$Path)
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToUpperInvariant()
}

function Assert-Hash {
    param(
        [string]$Path,
        [string]$Expected,
        [string]$Name
    )

    $actual = Get-Sha256 $Path
    if ($actual -ne $Expected.ToUpperInvariant()) {
        throw (
            "SHA-256-Prüfung fehlgeschlagen für $Name.`n" +
            "Erwartet: $Expected`nTatsächlich: $actual`n" +
            "Die Datei wurde nicht installiert."
        )
    }
}

function Download-File {
    param(
        [string]$Url,
        [string]$Destination
    )

    $directory = Split-Path -LiteralPath $Destination -Parent
    New-Item -ItemType Directory -Path $directory -Force | Out-Null

    $client = New-Object System.Net.WebClient
    $client.Headers['User-Agent'] = 'WorkspaceShare-DependencyInstaller/3.1'
    try {
        $client.DownloadFile($Url, $Destination)
    }
    finally {
        $client.Dispose()
    }

    if (-not (Test-Path -LiteralPath $Destination -PathType Leaf)) {
        throw "Download wurde nicht erstellt: $Destination"
    }
}

function Find-SevenZip {
    $command = Get-Command '7z.exe' -ErrorAction SilentlyContinue
    if ($command) {
        return $command.Source
    }

    $candidates = @()
    if ($env:ProgramFiles) {
        $candidates += (Join-Path $env:ProgramFiles '7-Zip\7z.exe')
    }
    if (${env:ProgramFiles(x86)}) {
        $candidates += (Join-Path ${env:ProgramFiles(x86)} '7-Zip\7z.exe')
    }

    foreach ($candidate in $candidates) {
        if (Test-Path -LiteralPath $candidate -PathType Leaf) {
            return $candidate
        }
    }

    return $null
}

function Ensure-SevenZipExtractor {
    $sevenZip = Find-SevenZip
    if ($sevenZip) {
        return $sevenZip
    }

    $winget = Get-Command 'winget.exe' -ErrorAction SilentlyContinue
    if (-not $winget) {
        throw (
            "Zum einmaligen Entpacken des offiziellen 7-Zip-Extra-Pakets wird 7z.exe benötigt. " +
            "Installiere 7-Zip 26.02 oder stelle winget.exe bereit und starte erneut."
        )
    }

    Write-Host '      7z.exe fehlt; installiere 7-Zip 26.02 über WinGet ...'
    & $winget.Source install `
        --id 7zip.7zip `
        --version 26.02 `
        --exact `
        --accept-package-agreements `
        --accept-source-agreements `
        --disable-interactivity

    if ($LASTEXITCODE -ne 0) {
        throw "WinGet konnte 7-Zip 26.02 nicht installieren (Exit $LASTEXITCODE)."
    }

    $sevenZip = Find-SevenZip
    if (-not $sevenZip) {
        throw '7-Zip wurde angefordert, aber 7z.exe konnte anschließend nicht gefunden werden.'
    }

    return $sevenZip
}

function Get-VersionText {
    param(
        [string]$FilePath,
        [string[]]$Arguments
    )

    $output = & $FilePath @Arguments 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "Versionsabfrage fehlgeschlagen: $FilePath"
    }
    return (($output | Out-String).Trim())
}

try {
    if ((Test-Path -LiteralPath $lockPath -PathType Leaf) -and -not $Force) {
        $existing = $null
        try {
            $existing = Get-Content -LiteralPath $lockPath -Raw | ConvertFrom-Json
        }
        catch {
            # Ungültige oder leere Lockdatei darf repariert werden.
        }

        if ($existing -and $existing.installed) {
            throw (
                "dependencies.lock.json zeigt bereits eine Installation an. " +
                "Nutze -Force für eine bewusste Neuinstallation."
            )
        }
    }

    New-Item -ItemType Directory -Path $temp -Force | Out-Null
    New-Item -ItemType Directory -Path $stage -Force | Out-Null
    New-Item -ItemType Directory -Path $licenses -Force | Out-Null

    Write-Phase 1 5 'Offizielle Release-Assets herunterladen und prüfen ...'

    $downloaded = @{}
    foreach ($asset in $assets) {
        $extension = switch ($asset.type) {
            'exe' { '.exe' }
            'zip' { '.zip' }
            '7z'  { '.7z' }
            default { '.bin' }
        }

        $downloadPath = Join-Path $temp ($asset.name.Replace(' ','-') + $extension)
        Write-Host ("      {0} {1}" -f $asset.name, $asset.version)
        Download-File -Url $asset.url -Destination $downloadPath
        Assert-Hash -Path $downloadPath -Expected $asset.sha256 -Name $asset.name
        $downloaded[$asset.name] = $downloadPath
    }

    Write-Phase 2 5 'Archive sicher entpacken und Binärdateien bereitstellen ...'

    Copy-Item -LiteralPath $downloaded['cloudflared'] -Destination (Join-Path $stage 'cloudflared.exe') -Force
    Copy-Item -LiteralPath $downloaded['miniserve'] -Destination (Join-Path $stage 'miniserve.exe') -Force

    $gitleaksExtract = Join-Path $temp 'gitleaks'
    Expand-Archive -LiteralPath $downloaded['Gitleaks'] -DestinationPath $gitleaksExtract -Force
    $gitleaksExe = Get-ChildItem -LiteralPath $gitleaksExtract -Filter 'gitleaks.exe' -File -Recurse |
        Select-Object -First 1
    if (-not $gitleaksExe) {
        throw 'gitleaks.exe fehlt im geprüften Release-Archiv.'
    }
    Copy-Item -LiteralPath $gitleaksExe.FullName -Destination (Join-Path $stage 'gitleaks.exe') -Force

    $sevenZipExtractor = Ensure-SevenZipExtractor
    $sevenZipExtract = Join-Path $temp '7zip-extra'
    New-Item -ItemType Directory -Path $sevenZipExtract -Force | Out-Null
    & $sevenZipExtractor x $downloaded['7-Zip'] "-o$sevenZipExtract" -y -bd | Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw "Das geprüfte 7-Zip-Extra-Paket konnte nicht entpackt werden (Exit $LASTEXITCODE)."
    }

    $sevenZipCandidates = @(
        Get-ChildItem -LiteralPath $sevenZipExtract -Filter '7za.exe' -File -Recurse
    )
    $sevenZipExe = $sevenZipCandidates |
        Where-Object { $_.FullName -match '(?i)[\\/]x64[\\/]' } |
        Select-Object -First 1
    if (-not $sevenZipExe) {
        $sevenZipExe = $sevenZipCandidates | Select-Object -First 1
    }
    if (-not $sevenZipExe) {
        throw '7za.exe fehlt im geprüften 7-Zip-Extra-Paket.'
    }
    Copy-Item -LiteralPath $sevenZipExe.FullName -Destination (Join-Path $stage '7za.exe') -Force

    Write-Phase 3 5 'Versionen der ausführbaren Dateien prüfen ...'

    $versionChecks = @(
        @{ File = 'cloudflared.exe'; Args = @('--version'); Expected = '2026.7.3' },
        @{ File = 'miniserve.exe'; Args = @('--version'); Expected = '0.35.0' },
        @{ File = 'gitleaks.exe'; Args = @('version'); Expected = '8.30.1' },
        @{ File = '7za.exe'; Args = @('i'); Expected = '26.02' }
    )

    foreach ($check in $versionChecks) {
        $path = Join-Path $stage $check.File
        $text = Get-VersionText -FilePath $path -Arguments $check.Args
        if ($text -notmatch [regex]::Escape($check.Expected)) {
            throw (
                "Unerwartete Version für $($check.File).`n" +
                "Erwartet: $($check.Expected)`nAusgabe: $text"
            )
        }
        Write-Host ("      {0}: {1}" -f $check.File, $check.Expected)
    }

    Write-Phase 4 5 'Lizenztexte und Notices ablegen ...'

    foreach ($asset in $assets) {
        if ($asset.licenseUrl) {
            $licensePath = Join-Path $licenses ($asset.name.Replace(' ','-') + '-LICENSE.txt')
            try {
                Download-File -Url $asset.licenseUrl -Destination $licensePath
            }
            catch {
                throw "Lizenztext für $($asset.name) konnte nicht geladen werden: $($_.Exception.Message)"
            }
        }
    }

    $sevenZipLicense = Get-ChildItem -LiteralPath $sevenZipExtract -File -Recurse |
        Where-Object { $_.Name -match '(?i)^(license|copying)(\..+)?$' } |
        Select-Object -First 1
    if ($sevenZipLicense) {
        Copy-Item -LiteralPath $sevenZipLicense.FullName -Destination (Join-Path $licenses '7-Zip-LICENSE.txt') -Force
    }
    else {
        @'
7-Zip 26.02
Siehe die Lizenz- und Copyright-Hinweise der offiziellen 7-Zip-Distribution
sowie THIRD_PARTY_NOTICES.md. Vor interner Weitergabe muss das vollständige
Original-Lizenzpaket mitgeführt werden.
'@ | Set-Content -LiteralPath (Join-Path $licenses '7-Zip-LICENSE.txt') -Encoding UTF8
    }

    Write-Phase 5 5 'Binärdateien atomar übernehmen und Lockfile erzeugen ...'

    New-Item -ItemType Directory -Path $bin -Force | Out-Null
    foreach ($file in @('cloudflared.exe','miniserve.exe','gitleaks.exe','7za.exe')) {
        $source = Join-Path $stage $file
        $destination = Join-Path $bin $file
        Copy-Item -LiteralPath $source -Destination $destination -Force
    }

    $lockDependencies = @()
    foreach ($asset in $assets) {
        $fileName = [string]$asset.output
        $installedPath = Join-Path $bin $fileName
        $lockDependencies += [ordered]@{
            name = [string]$asset.name
            file = ('bin/' + $fileName)
            version = [string]$asset.version
            sha256 = Get-Sha256 $installedPath
            license = [string]$asset.license
            source = [string]$asset.source
            sourceAssetSha256 = [string]$asset.sha256
        }
    }

    $lock = [ordered]@{
        schema = 2
        installed = $true
        generatedUtc = [DateTime]::UtcNow.ToString('o')
        platform = 'windows-x64'
        installerVersion = '3.1.0'
        dependencies = $lockDependencies
    }

    $lock | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $lockPath -Encoding UTF8

    Write-Host ''
    Write-Host 'Abhängigkeiten wurden erfolgreich installiert und gesperrt.'
    Write-Host ("Lockfile: {0}" -f $lockPath)
    Write-Host ''
    foreach ($dependency in $lockDependencies) {
        Write-Host ("{0,-12} {1}  {2}" -f $dependency.name, $dependency.version, $dependency.sha256)
    }
}
finally {
    Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue
}
````

## Datei: `scripts/Watch-WorkspaceShare.ps1`

````powershell
#requires -Version 5.1
<#
.SYNOPSIS
    Sicherheits-Watchdog für WorkspaceShare.

.DESCRIPTION
    Besitzt niemals Capability-Token oder vollständige URL.
    Beendet ausschließlich über PID, Executable-Pfad und Prozessstartzeit
    verifizierte Prozesse. Dadurch werden PID-Reuse-Fehlabschüsse verhindert.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][int]$ParentPid,
    [Parameter(Mandatory = $true)][long]$ParentStartTicks,
    [Parameter(Mandatory = $true)][int]$MiniservePid,
    [Parameter(Mandatory = $true)][long]$MiniserveStartTicks,
    [Parameter(Mandatory = $true)][int]$CloudflaredPid,
    [Parameter(Mandatory = $true)][long]$CloudflaredStartTicks,
    [Parameter(Mandatory = $true)][string]$SessionPath,
    [Parameter(Mandatory = $true)][string]$NormalExitMarker,
    [Parameter(Mandatory = $true)][datetime]$ExpiresUtc,
    [Parameter(Mandatory = $true)][string]$ExpectedMiniservePath,
    [Parameter(Mandatory = $true)][string]$ExpectedCloudflaredPath,
    [switch]$KeepArchive
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'SilentlyContinue'

function Get-VerifiedProcess {
    param(
        [int]$ProcessId,
        [string]$ExpectedPath,
        [long]$ExpectedStartTicks
    )

    if ($ProcessId -le 0 -or -not $ExpectedPath -or $ExpectedStartTicks -le 0) {
        return $null
    }

    try {
        $process = Get-Process -Id $ProcessId -ErrorAction Stop
        if (-not $process.Path) {
            return $null
        }

        if (
            [IO.Path]::GetFullPath($process.Path) -ne
            [IO.Path]::GetFullPath($ExpectedPath)
        ) {
            return $null
        }

        if ($process.StartTime.ToUniversalTime().Ticks -ne $ExpectedStartTicks) {
            return $null
        }

        return $process
    }
    catch {
        return $null
    }
}

function Stop-VerifiedProcess {
    param(
        [int]$ProcessId,
        [string]$ExpectedPath,
        [long]$ExpectedStartTicks
    )

    $process = Get-VerifiedProcess `
        -ProcessId $ProcessId `
        -ExpectedPath $ExpectedPath `
        -ExpectedStartTicks $ExpectedStartTicks

    if ($process) {
        Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue
        try { [void]$process.WaitForExit(3000) } catch {}
    }
}

function Test-OriginalParentAlive {
    try {
        $parent = Get-Process -Id $ParentPid -ErrorAction Stop
        return ($parent.StartTime.ToUniversalTime().Ticks -eq $ParentStartTicks)
    }
    catch {
        return $false
    }
}

while ($true) {
    $normalExitRequested = Test-Path -LiteralPath $NormalExitMarker -PathType Leaf

    if ($normalExitRequested) {
        # Der Launcher setzt den Marker erst nach dem Stoppen beider Kindprozesse.
        $cloudAlive = Get-VerifiedProcess `
            -ProcessId $CloudflaredPid `
            -ExpectedPath $ExpectedCloudflaredPath `
            -ExpectedStartTicks $CloudflaredStartTicks
        $serverAlive = Get-VerifiedProcess `
            -ProcessId $MiniservePid `
            -ExpectedPath $ExpectedMiniservePath `
            -ExpectedStartTicks $MiniserveStartTicks

        if (-not $cloudAlive -and -not $serverAlive) {
            exit 0
        }
    }

    if (-not (Test-OriginalParentAlive)) {
        break
    }

    if ([DateTime]::UtcNow -ge $ExpiresUtc.ToUniversalTime()) {
        break
    }

    Start-Sleep -Seconds 2
}

# Öffentliches Ende zuerst.
Stop-VerifiedProcess `
    -ProcessId $CloudflaredPid `
    -ExpectedPath $ExpectedCloudflaredPath `
    -ExpectedStartTicks $CloudflaredStartTicks

Start-Sleep -Milliseconds 300

Stop-VerifiedProcess `
    -ProcessId $MiniservePid `
    -ExpectedPath $ExpectedMiniservePath `
    -ExpectedStartTicks $MiniserveStartTicks

if ($KeepArchive) {
    try {
        New-Item -ItemType File -Path (Join-Path $SessionPath 'keep.archive') -Force | Out-Null
    }
    catch {}
}
else {
    Remove-Item -LiteralPath $SessionPath -Recurse -Force -ErrorAction SilentlyContinue
}

exit 0
````

## Datei: `scripts/Build-InternalRelease.ps1`

````powershell
#requires -Version 5.1
<#
.SYNOPSIS
    Führt das lokale Release-Gate aus und erzeugt ein internes Distributions-ZIP.

.EXAMPLE
    .\scripts\Build-InternalRelease.ps1
#>

[CmdletBinding()]
param(
    [string]$ToolRoot = (Split-Path $PSScriptRoot -Parent),
    [string]$OutputDirectory = (Join-Path (Split-Path $PSScriptRoot -Parent) 'dist')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$version = (Get-Content -LiteralPath (Join-Path $ToolRoot 'VERSION') -Raw).Trim()
$lockPath = Join-Path $ToolRoot 'dependencies.lock.json'
$testScript = Join-Path $ToolRoot 'tests\Test-WorkspaceShare.ps1'
$sevenZip = Join-Path $ToolRoot 'bin\7za.exe'
$temp = Join-Path ([IO.Path]::GetTempPath()) ('WorkspaceShare-Release-' + [Guid]::NewGuid().ToString('N'))
$stage = Join-Path $temp 'WorkspaceShare'
$archive = Join-Path $OutputDirectory ("WorkspaceShare-{0}.zip" -f $version)
$hashFile = $archive + '.sha256.txt'

function Require-File {
    param([string]$Path, [string]$Name)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "$Name fehlt: $Path"
    }
}

try {
    Require-File $lockPath 'Lockfile'
    Require-File $testScript 'Testskript'
    Require-File $sevenZip '7za.exe'

    $lock = Get-Content -LiteralPath $lockPath -Raw | ConvertFrom-Json
    if ([int]$lock.schema -ne 2 -or -not $lock.installed) {
        throw 'Abhängigkeiten sind nicht installiert oder nicht gesperrt.'
    }

    Write-Host '[1/5] Automatisierte Tests ausführen ...'
    & powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File $testScript -ToolRoot $ToolRoot
    if ($LASTEXITCODE -ne 0) {
        throw "Automatisierte Tests fehlgeschlagen (Exit $LASTEXITCODE)."
    }

    Write-Host '[2/5] Release-Inhalt statisch prüfen ...'
    $textFiles = @(
        Get-ChildItem -LiteralPath $ToolRoot -File -Recurse |
        Where-Object {
            $_.FullName -notmatch '(?i)[\\/](bin|dist|docs)[\\/]' -and
            $_.Extension -in @('.ps1','.psm1','.cmd','.json','.toml','.txt','.md')
        }
    )

    $placeholderPattern = '(?i)\b(TODO|TBD|FILL_SHA256|PIN_TESTED_VERSION)\b'
    $placeholderHits = @()
    foreach ($file in $textFiles) {
        $matches = Select-String -LiteralPath $file.FullName -Pattern $placeholderPattern -AllMatches
        if ($matches) {
            $placeholderHits += $matches
        }
    }
    if ($placeholderHits.Count -gt 0) {
        $preview = $placeholderHits | Select-Object -First 20
        throw ("Nicht aufgelöste Platzhalter gefunden:`n" + ($preview -join "`n"))
    }

    foreach ($requiredLicense in @(
        'cloudflared-LICENSE.txt',
        'miniserve-LICENSE.txt',
        'Gitleaks-LICENSE.txt',
        '7-Zip-LICENSE.txt'
    )) {
        Require-File (Join-Path $ToolRoot ('bin\licenses\' + $requiredLicense)) $requiredLicense
    }

    Write-Host '[3/5] Staging-Verzeichnis erzeugen ...'
    New-Item -ItemType Directory -Path $stage -Force | Out-Null

    $releasePaths = @(
        'Share-Workspace.ps1',
        'Stop-WorkspaceShare.ps1',
        'Install-Dependencies.ps1',
        'WorkspaceShare.cmd',
        'Install.cmd',
        'Stop.cmd',
        'Test.cmd',
        'VERSION',
        'README.md',
        'SECURITY.md',
        'THIRD_PARTY_NOTICES.md',
        'dependencies.lock.json',
        'config',
        'scripts',
        'tests',
        'bin'
    )

    foreach ($relative in $releasePaths) {
        $source = Join-Path $ToolRoot $relative
        if (-not (Test-Path -LiteralPath $source)) {
            throw "Release-Pfad fehlt: $relative"
        }
        Copy-Item -LiteralPath $source -Destination $stage -Recurse -Force
    }

    # Keine Laufzeitdaten oder Entwicklungsartefakte verteilen.
    Remove-Item -LiteralPath (Join-Path $stage 'scripts\Build-InternalRelease.ps1') -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath (Join-Path $stage 'tests\New-TestFixtures.ps1') -Force -ErrorAction SilentlyContinue

    Write-Host '[4/5] Distributions-ZIP erzeugen und testen ...'
    New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null
    Remove-Item -LiteralPath $archive -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $hashFile -Force -ErrorAction SilentlyContinue

    Push-Location $temp
    try {
        & $sevenZip a -tzip -mx=9 -mmt=on -sse -y -bd $archive 'WorkspaceShare'
        if ($LASTEXITCODE -ne 0) {
            throw "Release-ZIP konnte nicht erstellt werden (Exit $LASTEXITCODE)."
        }
    }
    finally {
        Pop-Location
    }

    & $sevenZip t -bd $archive | Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw "Release-ZIP-Integritätsprüfung fehlgeschlagen (Exit $LASTEXITCODE)."
    }

    Write-Host '[5/5] Release-Hash schreiben ...'
    $hash = (Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash
    ("{0}  {1}" -f $hash, (Split-Path $archive -Leaf)) |
        Set-Content -LiteralPath $hashFile -Encoding ASCII

    Write-Host ''
    Write-Host 'Interne Distribution erfolgreich erzeugt:'
    Write-Host $archive
    Write-Host $hashFile
    Write-Host ("SHA-256: {0}" -f $hash)
}
finally {
    Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue
}
````

## Datei: `tests/Test-WorkspaceShare.ps1`

````powershell
#requires -Version 5.1
<#
.SYNOPSIS
    Automatisierte lokale und optionale öffentliche Abnahmetests.

.DESCRIPTION
    Prüft Lockfile, EXE-Hashes, Tokenentropie, Loopback-Bindung, Geheimroute,
    Negativrouten, Range, Resume, No-Store-Header, Prozesskommandozeile und
    Read-only-Wirkung ungewöhnlicher HTTP-/WebDAV-Methoden.

.EXAMPLE
    .\tests\Test-WorkspaceShare.ps1

.EXAMPLE
    .\tests\Test-WorkspaceShare.ps1 -PublicUrl $env:WORKSPACESHARE_TEST_URL
#>

[CmdletBinding()]
param(
    [string]$ToolRoot = (Split-Path $PSScriptRoot -Parent),
    [string]$PublicUrl
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$bin = Join-Path $ToolRoot 'bin'
$miniserve = Join-Path $bin 'miniserve.exe'
$lockPath = Join-Path $ToolRoot 'dependencies.lock.json'
$shareScript = Join-Path $ToolRoot 'Share-Workspace.ps1'
$curl = (Get-Command 'curl.exe' -ErrorAction Stop).Source
$temp = Join-Path ([IO.Path]::GetTempPath()) ('WorkspaceShare-Test-' + [Guid]::NewGuid().ToString('N'))
$server = $null
$failed = 0
$passed = 0

function Assert-True {
    param([bool]$Condition, [string]$Message)

    if ($Condition) {
        $script:passed++
        Write-Host "[PASS] $Message"
    }
    else {
        $script:failed++
        Write-Host "[FAIL] $Message" -ForegroundColor Red
    }
}

function New-Token {
    $bytes = New-Object byte[] 32
    $rng = [Security.Cryptography.RandomNumberGenerator]::Create()
    try { $rng.GetBytes($bytes) } finally { $rng.Dispose() }
    return [Convert]::ToBase64String($bytes).TrimEnd('=').Replace('+','-').Replace('/','_')
}

function Get-Port {
    $listener = New-Object Net.Sockets.TcpListener([Net.IPAddress]::Loopback, 0)
    try {
        $listener.Start()
        return ([Net.IPEndPoint]$listener.LocalEndpoint).Port
    }
    finally {
        $listener.Stop()
    }
}

function ConvertTo-NativeArgument {
    param([AllowEmptyString()][string]$Value)

    if ($null -eq $Value -or $Value.Length -eq 0) {
        return '""'
    }
    if ($Value -notmatch '[\s"]') {
        return $Value
    }

    $builder = New-Object Text.StringBuilder
    [void]$builder.Append('"')
    $backslashes = 0

    foreach ($character in $Value.ToCharArray()) {
        if ($character -eq '\') {
            $backslashes++
            continue
        }
        if ($character -eq '"') {
            [void]$builder.Append(('\' * (($backslashes * 2) + 1)))
            [void]$builder.Append('"')
            $backslashes = 0
            continue
        }
        if ($backslashes -gt 0) {
            [void]$builder.Append(('\' * $backslashes))
            $backslashes = 0
        }
        [void]$builder.Append($character)
    }

    if ($backslashes -gt 0) {
        [void]$builder.Append(('\' * ($backslashes * 2)))
    }
    [void]$builder.Append('"')
    return $builder.ToString()
}

function Curl-Status {
    param(
        [string]$Url,
        [string[]]$Extra = @()
    )

    $arguments = @(
        '--silent','--show-error',
        '--output','NUL',
        '--write-out','%{http_code}',
        '--max-time','15'
    )
    $arguments += $Extra
    $arguments += $Url

    $output = & $curl @arguments 2>$null
    if ($LASTEXITCODE -ne 0 -and -not $output) {
        return 0
    }

    $status = 0
    [void][int]::TryParse(
        (($output | Select-Object -Last 1) | Out-String).Trim(),
        [ref]$status
    )
    return $status
}

function Wait-Ready {
    param([string]$Url)

    $deadline = [DateTime]::UtcNow.AddSeconds(20)
    do {
        if ((Curl-Status -Url $Url -Extra @('--head')) -eq 200) {
            return $true
        }
        Start-Sleep -Milliseconds 300
    } while ([DateTime]::UtcNow -lt $deadline)
    return $false
}

function Get-RelativeFiles {
    param([string]$Root)

    return @(
        Get-ChildItem -LiteralPath $Root -File -Recurse |
        ForEach-Object { $_.FullName.Substring($Root.Length).ToLowerInvariant() } |
        Sort-Object
    )
}

try {
    New-Item -ItemType Directory -Path $temp -Force | Out-Null

    Write-Host 'WorkspaceShare – automatisierte Abnahmetests'
    Write-Host '=========================================='
    Write-Host ''

    Assert-True (Test-Path -LiteralPath $miniserve -PathType Leaf) 'miniserve.exe vorhanden'
    Assert-True (Test-Path -LiteralPath $lockPath -PathType Leaf) 'dependencies.lock.json vorhanden'
    Assert-True (Test-Path -LiteralPath $shareScript -PathType Leaf) 'Share-Workspace.ps1 vorhanden'
    Assert-True ([bool]$curl) 'curl.exe vorhanden'

    $lock = $null
    try {
        $lock = Get-Content -LiteralPath $lockPath -Raw | ConvertFrom-Json
    }
    catch {}

    Assert-True ($null -ne $lock) 'Lockfile ist gültiges JSON'
    if ($lock) {
        Assert-True ([int]$lock.schema -eq 2) 'Lockfile-Schema ist 2'
        Assert-True ([bool]$lock.installed) 'Lockfile bestätigt installierte Abhängigkeiten'

        foreach ($dependency in @($lock.dependencies)) {
            $path = Join-Path $ToolRoot ([string]$dependency.file).Replace('/', '\')
            $exists = Test-Path -LiteralPath $path -PathType Leaf
            Assert-True $exists ("Lockdatei vorhanden: " + $dependency.name)
            if ($exists) {
                $actual = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash
                Assert-True ($actual -eq [string]$dependency.sha256) ("Lockhash stimmt: " + $dependency.name)
            }
        }
    }

    $shareText = Get-Content -LiteralPath $shareScript -Raw
    foreach ($forbiddenFlag in @(
        '--upload-files','--mkdir','--rm-files','--enable-webdav','--pastebin'
    )) {
        Assert-True ($shareText -notmatch [regex]::Escape("'$forbiddenFlag'")) (
            "Gefährliches miniserve-Flag nicht aktiviert: $forbiddenFlag"
        )
    }

    Assert-True ($shareText -match "MINISERVE_ROUTE_PREFIX") 'Capability-Token wird über Environment gesetzt'
    Assert-True ($shareText -match "'--interfaces', '127.0.0.1'") 'Loopback-Bindung ist statisch konfiguriert'

    $token = New-Token
    Assert-True ($token.Length -eq 43) '256-Bit-Token hat Base64url-Länge 43'
    Assert-True ($token -match '^[A-Za-z0-9_-]{43}$') 'Token enthält nur URL-sichere Zeichen'

    # Mehrere MiB, damit Range-/Resume-Tests sinnvoll sind.
    $sample = Join-Path $temp 'sample.zip'
    $buffer = New-Object byte[] (8MB)
    $rng = [Security.Cryptography.RandomNumberGenerator]::Create()
    try { $rng.GetBytes($buffer) } finally { $rng.Dispose() }
    [IO.File]::WriteAllBytes($sample, $buffer)
    $originalHash = (Get-FileHash -LiteralPath $sample -Algorithm SHA256).Hash

    $port = Get-Port
    $localUrl = "http://127.0.0.1:$port/d/$token/"

    $psi = New-Object Diagnostics.ProcessStartInfo
    $psi.FileName = $miniserve
    $arguments = @(
        '--quiet',
        '--log-color','never',
        '--interfaces','127.0.0.1',
        '--port',"$port",
        '--workers','2',
        '--no-symlinks',
        '--header','Cache-Control: private, no-store, no-cache, max-age=0, must-revalidate',
        $sample
    )
    $psi.Arguments = (($arguments | ForEach-Object { ConvertTo-NativeArgument $_ }) -join ' ')
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.EnvironmentVariables['MINISERVE_ROUTE_PREFIX'] = "d/$token"

    $server = New-Object Diagnostics.Process
    $server.StartInfo = $psi
    [void]$server.Start()

    Assert-True (Wait-Ready $localUrl) 'Geheimroute liefert lokal HTTP 200'
    Assert-True ((Curl-Status -Url "http://127.0.0.1:$port/" -Extra @('--head')) -ne 200) 'Root ohne Token liefert nicht 200'
    Assert-True ((Curl-Status -Url "http://127.0.0.1:$port/d/$(New-Token)/" -Extra @('--head')) -ne 200) 'Falsches Token liefert nicht 200'

    try {
        $commandLine = (Get-CimInstance Win32_Process -Filter "ProcessId=$($server.Id)").CommandLine
        Assert-True ($commandLine -notmatch [regex]::Escape($token)) 'Token fehlt in miniserve-Prozesskommandozeile'
    }
    catch {
        Write-Host '[WARN] Prozesskommandozeile konnte nicht über CIM gelesen werden.'
    }

    try {
        $connections = @(Get-NetTCPConnection -OwningProcess $server.Id -State Listen -ErrorAction Stop)
        Assert-True ($connections.Count -gt 0) 'miniserve besitzt einen Listening-Socket'
        foreach ($connection in $connections) {
            Assert-True ($connection.LocalAddress -in @('127.0.0.1','::1')) 'Listening-Socket ist nur Loopback'
        }
    }
    catch {
        Write-Host '[WARN] Get-NetTCPConnection konnte nicht ausgeführt werden.'
    }

    $rangeFile = Join-Path $temp 'range.bin'
    $rangeStatus = & $curl @(
        '--silent','--show-error',
        '--header','Range: bytes=0-1023',
        '--output',$rangeFile,
        '--write-out','%{http_code}',
        $localUrl
    ) 2>$null

    Assert-True (((($rangeStatus | Select-Object -Last 1) | Out-String).Trim()) -eq '206') 'Range liefert HTTP 206'
    Assert-True ((Get-Item -LiteralPath $rangeFile).Length -eq 1024) 'Range liefert exakt 1024 Bytes'

    $resume = Join-Path $temp 'resume.zip'
    & $curl @(
        '--silent','--show-error',
        '--header','Range: bytes=0-1048575',
        '--output',$resume,
        $localUrl
    ) | Out-Null
    Assert-True ($LASTEXITCODE -eq 0) 'Erster Teil des Resume-Downloads erfolgreich'

    & $curl @(
        '--silent','--show-error',
        '--continue-at','-',
        '--output',$resume,
        $localUrl
    ) | Out-Null
    Assert-True ($LASTEXITCODE -eq 0) 'Resume-Aufruf erfolgreich'
    Assert-True ((Get-FileHash -LiteralPath $resume -Algorithm SHA256).Hash -eq $originalHash) 'Fortgesetzter Download besitzt korrekten Hash'

    $beforeFiles = Get-RelativeFiles $temp
    foreach ($method in @('POST','PUT','PATCH','DELETE','PROPFIND','MKCOL','MOVE','COPY')) {
        & $curl @(
            '--silent','--show-error',
            '--request',$method,
            '--header','Destination: /d/forbidden-target',
            '--data-binary','mutation-test',
            '--output','NUL',
            $localUrl
        ) 2>$null | Out-Null
    }
    $afterFiles = Get-RelativeFiles $temp

    Assert-True ((Get-FileHash -LiteralPath $sample -Algorithm SHA256).Hash -eq $originalHash) 'Mutation-Probes verändern die bereitgestellte Datei nicht'
    Assert-True (-not (Compare-Object $beforeFiles $afterFiles)) 'Mutation-Probes erzeugen keine zusätzlichen Dateien'

    $headers = Join-Path $temp 'local-headers.txt'
    & $curl @('--silent','--head','--dump-header',$headers,'--output','NUL',$localUrl) | Out-Null
    $headerText = Get-Content -LiteralPath $headers -Raw
    Assert-True ($headerText -match '(?im)^cache-control:.*no-store') 'Lokales Cache-Control enthält no-store'

    if ($PublicUrl) {
        Write-Host ''
        Write-Host 'Öffentliche Tests'
        Write-Host '------------------'

        $publicUri = [Uri]$PublicUrl
        $segments = @($publicUri.AbsolutePath.Trim('/').Split('/'))
        Assert-True ($segments.Count -ge 2 -and $segments[0] -eq 'd') 'Öffentlicher Link besitzt erwarteten Capability-Pfad'

        $publicBase = "{0}://{1}" -f $publicUri.Scheme, $publicUri.Authority
        $publicWrong = "{0}/d/{1}/" -f $publicBase, (New-Token)

        Assert-True ((Curl-Status -Url $PublicUrl -Extra @('--head')) -eq 200) 'Öffentliche Geheimroute liefert 200'
        Assert-True ((Curl-Status -Url ($publicBase + '/') -Extra @('--head')) -ne 200) 'Öffentliche Root-Route liefert nicht 200'
        Assert-True ((Curl-Status -Url $publicWrong -Extra @('--head')) -ne 200) 'Öffentliches falsches Token liefert nicht 200'

        $publicRange = Join-Path $temp 'public-range.bin'
        $publicStatus = & $curl @(
            '--silent','--show-error',
            '--header','Range: bytes=0-1023',
            '--output',$publicRange,
            '--write-out','%{http_code}',
            $PublicUrl
        ) 2>$null

        Assert-True (((($publicStatus | Select-Object -Last 1) | Out-String).Trim()) -eq '206') 'Öffentliche Range liefert 206'
        Assert-True ((Get-Item -LiteralPath $publicRange).Length -eq 1024) 'Öffentliche Range liefert 1024 Bytes'

        $publicHeaders = Join-Path $temp 'public-headers.txt'
        & $curl @('--silent','--head','--dump-header',$publicHeaders,'--output','NUL',$PublicUrl) | Out-Null
        $publicHeaderText = Get-Content -LiteralPath $publicHeaders -Raw
        Assert-True ($publicHeaderText -match '(?im)^cache-control:.*no-store') 'Öffentliches Cache-Control enthält no-store'
        Assert-True ($publicHeaderText -notmatch '(?im)^cf-cache-status:\s*HIT\s*$') 'Cloudflare meldet keinen Cache-HIT'
    }
}
finally {
    if ($server) {
        try {
            $server.Refresh()
            if (-not $server.HasExited) {
                Stop-Process -Id $server.Id -Force -ErrorAction SilentlyContinue
                [void]$server.WaitForExit(3000)
            }
        }
        catch {}
    }
    Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host ''
Write-Host "Bestanden: $passed"
Write-Host "Fehlgeschlagen: $failed"

if ($failed -gt 0) {
    exit 1
}

exit 0
````

## Datei: `tests/New-TestFixtures.ps1`

````powershell
#requires -Version 5.1
<#
.SYNOPSIS
    Erzeugt lokale Test-Workspaces für die Snapshot- und Sicherheits-Gates.

.DESCRIPTION
    Die Fixtures enthalten absichtlich verbotene Dateien oder Reparse-Points.
    Sie dürfen niemals produktiv freigegeben werden.

.EXAMPLE
    .\tests\New-TestFixtures.ps1

.EXAMPLE
    .\tests\New-TestFixtures.ps1 -IncludeLargeFiles
#>

[CmdletBinding()]
param(
    [string]$OutputRoot = (Join-Path ([IO.Path]::GetTempPath()) 'WorkspaceShare-Fixtures'),
    [switch]$IncludeLargeFiles
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (Test-Path -LiteralPath $OutputRoot) {
    Remove-Item -LiteralPath $OutputRoot -Recurse -Force
}
New-Item -ItemType Directory -Path $OutputRoot -Force | Out-Null

function New-Fixture {
    param([string]$Name)

    $path = Join-Path $OutputRoot $Name
    New-Item -ItemType Directory -Path $path -Force | Out-Null
    return $path
}

$clean = New-Fixture '01-clean'
@'
# Clean fixture
This workspace contains ordinary source files.
'@ | Set-Content -LiteralPath (Join-Path $clean 'README.md') -Encoding UTF8
New-Item -ItemType Directory -Path (Join-Path $clean 'src') | Out-Null
'console.log("hello");' | Set-Content -LiteralPath (Join-Path $clean 'src\index.js') -Encoding UTF8
'EXAMPLE_KEY=not-a-real-secret' | Set-Content -LiteralPath (Join-Path $clean '.env.example') -Encoding UTF8
New-Item -ItemType Directory -Path (Join-Path $clean 'node_modules\demo') -Force | Out-Null
'generated' | Set-Content -LiteralPath (Join-Path $clean 'node_modules\demo\index.js') -Encoding UTF8

$forbidden = New-Fixture '02-forbidden-filename'
'REAL_SECRET=must-block' | Set-Content -LiteralPath (Join-Path $forbidden '.env') -Encoding UTF8

$gitleaks = New-Fixture '03-gitleaks-content'
@'
This fixture intentionally contains a fake AWS access key pattern for scanner tests:
AKIAIOSFODNN7EXAMPLE
'@ | Set-Content -LiteralPath (Join-Path $gitleaks 'intentional-secret-fixture.txt') -Encoding UTF8

$locked = New-Fixture '04-locked-file'
'This file should be opened exclusively by the manual gate test.' |
    Set-Content -LiteralPath (Join-Path $locked 'locked.bin') -Encoding UTF8

$exclude = New-Fixture '05-project-excludes'
'keep' | Set-Content -LiteralPath (Join-Path $exclude 'keep.txt') -Encoding UTF8
'remove' | Set-Content -LiteralPath (Join-Path $exclude 'large.psd') -Encoding UTF8
@'
*.psd
'@ | Set-Content -LiteralPath (Join-Path $exclude '.workspace-share.exclude.txt') -Encoding UTF8

$reparse = New-Fixture '06-reparse-point'
$target = Join-Path $OutputRoot 'reparse-target'
New-Item -ItemType Directory -Path $target -Force | Out-Null
'target' | Set-Content -LiteralPath (Join-Path $target 'outside.txt') -Encoding UTF8
$link = Join-Path $reparse 'junction-outside'
try {
    cmd.exe /c "mklink /J `"$link`" `"$target`"" | Out-Null
    if ($LASTEXITCODE -ne 0) {
        Write-Warning 'Junction konnte nicht erstellt werden; Fixture 06 ist unvollständig.'
    }
}
catch {
    Write-Warning 'Junction konnte nicht erstellt werden; Fixture 06 ist unvollständig.'
}

if ($IncludeLargeFiles) {
    $large = New-Fixture '07-large-files'
    $single = Join-Path $large 'single-over-2gb.bin'
    $stream = [IO.File]::Open($single, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
    try {
        $stream.SetLength(2GB + 1MB)
    }
    finally {
        $stream.Dispose()
    }

    Write-Warning (
        "Eine Datei mit logischer Größe über 2 GB wurde erzeugt. " +
        "Je nach Dateisystem belegt sie real entsprechend viel Speicher."
    )
}

Write-Host ''
Write-Host "Fixtures erstellt: $OutputRoot"
Get-ChildItem -LiteralPath $OutputRoot -Directory | Select-Object Name, FullName | Format-Table -AutoSize
````

## Datei: `config/mandatory-excludes.txt`

````text
# 7-Zip-Wildcardmuster; eine Regel pro Zeile.
# Keine gitignore-Syntax, keine Negation, kein automatisches Re-Include.

.git
.git\*
.svn
.svn\*
.hg
.hg\*

# Das Tool selbst darf nicht rekursiv in einen Workspace aufgenommen werden.
.workspace-share
.workspace-share\*
WorkspaceShare\sessions
WorkspaceShare\sessions\*
````

## Datei: `config/generated-excludes.txt`

````text
# Große, rekonstruierbare oder lokale Inhalte.
# Mit -IncludeGenerated werden diese Regeln nicht angewendet.

node_modules
node_modules\*
Library
Library\*
Temp
Temp\*
obj
obj\*
dist
dist\*
build
build\*
out
out\*
coverage
coverage\*
.cache
.cache\*
.gradle
.gradle\*
DerivedData
DerivedData\*
.vs
.vs\*
Logs
Logs\*
*.log
Thumbs.db
.DS_Store
````

## Datei: `config/gitleaks-workspaceshare.toml`

````toml
# WorkspaceShare 3.1 – Gitleaks-Konfiguration
# Vollständige eingebaute Regeln, bewusst ohne Pfad-Allowlist.
# Der Scan ist konservativer als der spätere ZIP-Ausschluss und darf dadurch
# eher einen False Positive erzeugen als ein enthaltenes Secret übersehen.

title = "WorkspaceShare strict directory scan"

[extend]
useDefault = true
````

## Datei: `dependencies.lock.json`

````json
{
  "schema": 2,
  "installed": false,
  "generatedUtc": null,
  "platform": "windows-x64",
  "installerVersion": "3.1.0",
  "message": "Run .\\Install-Dependencies.ps1. This file will be replaced with hashes of installed executables.",
  "dependencies": []
}
````

## Datei: `WorkspaceShare.cmd`

````bat
@echo off
setlocal
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0Share-Workspace.ps1" %*
exit /b %ERRORLEVEL%
````

## Datei: `Install.cmd`

````bat
@echo off
setlocal
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0Install-Dependencies.ps1" %*
exit /b %ERRORLEVEL%
````

## Datei: `Stop.cmd`

````bat
@echo off
setlocal
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0Stop-WorkspaceShare.ps1" %*
exit /b %ERRORLEVEL%
````

## Datei: `Test.cmd`

````bat
@echo off
setlocal
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0tests\Test-WorkspaceShare.ps1" %*
exit /b %ERRORLEVEL%
````

## Datei: `VERSION`

````text
3.1.0-internal
````

## Datei: `README.md`

````markdown
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
````

## Datei: `SECURITY.md`

````markdown
# Security Policy

## Unterstützter Einsatz

WorkspaceShare 3.1 ist ausschließlich für kurzzeitige, interne, read-only Dateiübertragung eines zuvor erzeugten Workspace-Snapshots vorgesehen.

Nicht vorgesehen:

- öffentliche Distribution;
- vertrauliche Daten mit regulatorischem Verbot externer Verarbeitung;
- dauerhaftes Hosting;
- Uploads oder bidirektionale Synchronisierung;
- Live-Zugriff auf Quellverzeichnisse;
- Umgehung organisatorischer Freigabe- oder Klassifizierungsregeln.

## Sicherheitsinvarianten

1. Das Originalverzeichnis wird nie als HTTP-Root verwendet.
2. miniserve bindet ausschließlich an Loopback.
3. Der Route-Prefix besitzt 256 Bit kryptografische Entropie.
4. Token und vollständige URL werden nicht in Sitzungsdateien geschrieben.
5. Keine Upload-, Delete-, mkdir-, Pastebin- oder WebDAV-Flags.
6. Abhängigkeiten müssen dem lokalen SHA-256-Lock entsprechen.
7. Ein Fehler vor Linkausgabe führt zum Abbruch.
8. Tunnel wird vor dem lokalen Server beendet.
9. Watchdog und Stop-Skript verifizieren PID, Executable-Pfad und Startzeit.
10. `-KeepArchive` betrifft nur lokale Daten und verlängert die URL nicht.

## Umgang mit dem Link

Der Link ist ein Bearer-Secret:

- nur über den vorgesehenen privaten Kanal senden;
- nicht in Tickets, öffentliche Chats, Screenshots oder Quellcode kopieren;
- Browser-/Chat-Linkvorschauen möglichst vermeiden;
- nach Nutzung die Sitzung beenden;
- bei Verdacht auf Weitergabe sofort `Stop-WorkspaceShare.ps1` ausführen.

## Meldung eines Problems

Bei einem vermuteten Sicherheitsproblem:

1. aktive Sitzungen sofort stoppen;
2. betroffene Archive lokal sichern, falls sie für die Analyse benötigt werden;
3. Logs ohne Capability-Link und Token sammeln;
4. genaue Toolversion, Dependency-Lock und Reproduktionsschritte dokumentieren;
5. bis zur Klärung keine weiteren Freigaben starten.

Keine Sicherheitsberichte oder Beispiel-Links in öffentliche Issues einstellen.
````

## Datei: `THIRD_PARTY_NOTICES.md`

````markdown
# Third-Party Notices

WorkspaceShare ruft die folgenden unveränderten externen Programme als getrennte
Prozesse auf. Es werden keine Quelltexte dieser Projekte in WorkspaceShare
hineinkopiert und keine veränderten Binärdateien verteilt.

## miniserve

- Projekt: svenstaro/miniserve
- Lizenz: MIT
- Verwendung: read-only Auslieferung genau einer Snapshot-Datei über HTTP
- Quelle: https://github.com/svenstaro/miniserve
- Mitzuliefern: vollständige MIT-Lizenz aus der verwendeten Version

## cloudflared

- Projekt: cloudflare/cloudflared
- Lizenz: Apache License 2.0
- Verwendung: ausgehender Cloudflare Quick Tunnel
- Quelle: https://github.com/cloudflare/cloudflared
- Mitzuliefern: LICENSE und NOTICE der verwendeten Version

## 7-Zip / 7za.exe

- Projekt: 7-Zip
- Lizenz: überwiegend GNU LGPL; zusätzliche Bestandteile und Hinweise beachten
- Verwendung: Erstellen, Testen und Auflisten des ZIP64-Snapshots
- Quelle und Quellcodehinweis: https://www.7-zip.org/
- Dokumentationspflicht laut 7-Zip-FAQ:
  1. nennen, dass Teile/Programme von 7-Zip verwendet werden;
  2. GNU-LGPL-Lizenz nennen;
  3. auf 7-zip.org als Quellcodequelle verweisen.
- Mitzuliefern: die mit der konkreten Distribution gelieferten Lizenzdateien

## Gitleaks

- Projekt: gitleaks/gitleaks
- Lizenz: MIT
- Verwendung: optionale, standardmäßig aktive Secret-Prüfung
- Quelle: https://github.com/gitleaks/gitleaks
- Mitzuliefern: vollständige MIT-Lizenz aus der verwendeten Version

## Keine Rechtsberatung

Diese Datei ist eine technische Compliance-Checkliste und keine Rechtsberatung.
Vor externer kommerzieller Weitergabe sollte die konkrete Binärdistribution samt
Lizenzdateien geprüft werden.
````

## Datei: `bin/README.md`

````markdown
# Binärdateien

Dieser Ordner wird absichtlich ohne ausführbare Drittanbieterdateien ausgeliefert.

Führe im Projektroot aus:

```powershell
.\Install-Dependencies.ps1
```

Das Skript lädt die fest gepinnten offiziellen Release-Assets, prüft deren SHA-256-Werte und Versionen und erzeugt anschließend `dependencies.lock.json` aus den tatsächlich installierten EXE-Dateien. Ein Share-Vorgang ist ohne gültigen Lock nicht möglich.
````

