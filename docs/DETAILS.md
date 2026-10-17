# WorkspaceShare – Details

Temporäre, read-only Freigabe eines lokalen Windows-Code-Workspaces als geprüfter ZIP64-Snapshot über einen geheimen Cloudflare-Quick-Tunnel-Link.

## So benutzt du WorkspaceShare

### 1. Herunterladen

Du hast zwei Möglichkeiten:

**a) GitHub Release (empfohlen):** Lade `WorkspaceShare-3.4.0.zip` von der [Releases-Seite](https://github.com/Ceegore/CeegorsCodeOnWebForAITool/releases) herunter. Vergleiche den SHA-256-Wert mit der Prüfsumme auf der Release-Seite:

```powershell
Get-FileHash .\WorkspaceShare-3.4.0.zip
```

Entpacke das ZIP in einen lokalen Ordner, z. B. `C:\Tools\WorkspaceShare`. Es enthält bereits die geprüften Hilfsprogramme (cloudflared, miniserve, gitleaks, 7-Zip) und das Lockfile.

Windows markiert heruntergeladene Dateien (Mark-of-the-Web). Blockiert PowerShell die Skripte, entscheidest du selbst, ob du den entpackten Ordner freigibst – und zwar nur bei einem Download, dem du vertraust. Im entpackten Ordner:

```powershell
Get-ChildItem -File -Recurse | Unblock-File
```

**b) git clone (für Entwickler):**

```powershell
git clone https://github.com/Ceegore/CeegorsCodeOnWebForAITool.git
cd .\CeegorsCodeOnWebForAITool
.\Install-Dependencies.ps1
```

Der Repository-Root ist der Tool-Ordner. `Install-Dependencies.ps1` lädt die festgelegten Hilfsprogramme einmalig und prüft sie. Beim Release-ZIP entfällt dieser Schritt.

### 2. Verknüpfung anlegen (einmalig)

```powershell
powershell -NoProfile -File "<Pfad>\Install-GuiShortcut.ps1"
```

Das legt die Verknüpfung „WorkspaceShare“ auf dem Desktop und im Startmenü an.

### 3. Teilen

1. Doppelklick auf die Verknüpfung „WorkspaceShare“ – der Browser öffnet sich.
2. Ziehe Dateien oder Ordner aus dem Explorer in das Feld „Dateien oder Ordner hierher ziehen“, oder wähle sie mit „Dateien auswählen…“. Alternativ wähle einen Projektordner mit „Ordner wählen…“.
3. Dauer wählen und auf „Freigeben“ klicken.
4. Nach etwa einer Minute erscheint der Link. Klicke auf „Link kopieren“ und schicke ihn an den Empfänger – oder füge ihn in den KI-Web-Chat ein.

Mehrere Freigaben können gleichzeitig laufen (bis zu 5), jede mit eigenem Tab; über „+ Neue Freigabe“ startest du eine weitere. Der Tab-Name kommt standardmäßig von den geteilten Dateien (eine Datei: ihr Name; mehrere: z. B. „Bericht.pdf +2“; ein Ordner: sein Name) und lässt sich mit dem Stift-Symbol oder Doppelklick auf den Tab ändern – der Name ist nur eine Beschriftung, Link und ZIP ändern sich nicht. Im Formular kannst du optional das Feld „Name (optional)“ ausfüllen, um den Namen gleich festzulegen.

Der Empfänger lädt über den Link eine ZIP-Datei herunter. Auf seiner Seite muss nichts installiert werden.

### 4. Beenden

- „Freigabe beenden“ beendet nur die Freigabe des aktuellen Tabs sofort.
- „Tab schließen“ entfernt eine beendete Freigabe aus der Liste.
- Ohne Eingriff endet sie automatisch nach der gewählten Zeit.
- „Beenden“ unten auf der Seite beendet nach Bestätigung alle laufenden Freigaben und schließt WorkspaceShare.
- Per Drag & Drop übernommene Dateien werden in einen temporären, privaten Ordner kopiert und gelöscht, sobald die Freigabe endet.

### Was passiert im Hintergrund?

- Der Link enthält ein zufälliges 256-Bit-Geheimnis. Wer ihn hat, kann die Datei laden – gib ihn nur an Berechtigte weiter.
- Geteilt wird ein schreibgeschützter ZIP-Snapshot, nie der Originalordner.
- Vor der Freigabe läuft ein Geheimnis-Scan mit gitleaks. Schlüsseldateien wie `.env`, `*.pem` oder `id_rsa` blockieren die Freigabe.
- Zugangsdaten-Ordner wie `.ssh`, `.aws` oder `.npmrc` werden immer ausgelassen.
- Der Link ist nur erreichbar, solange die Freigabe läuft. Es braucht kein Konto, keine Portweiterleitung und keine Firewall-Regel.

### Kommandozeile

```powershell
.\Share-Workspace.ps1 -Path "D:\Projekte\MeinProjekt" -Hours 4
```

Parameter, Ablauf und Fehlercodes stehen in den Abschnitten „Workspace freigeben“, „Wichtige Parameter“ und „Fehlercodes“ weiter unten.

## Linux (experimentell)

WorkspaceShare läuft mit demselben Code auch unter Linux x64 – dort mit **PowerShell 7 (`pwsh`)**; Windows bleibt das Hauptprodukt und nutzt weiter Windows PowerShell 5.1. Der Linux-Port ist neu und bisher nur in GitHub Actions (`ubuntu-latest`) getestet.

Voraussetzungen: `pwsh` 7.4+, `curl`, `tar` mit `xz`, `setsid` (util-linux), Internetzugang. Optional: `dig` (Vergleich mit öffentlichen DNS-Resolvern), `systemd-inhibit` (Rechner wach halten), `xdg-open`, `zenity`/`kdialog`, `wl-copy`/`xclip` (Browser starten, Ordnerauswahl, Zwischenablage).

```bash
pwsh ./Install-Dependencies.ps1                              # lädt cloudflared, miniserve, gitleaks, 7-Zip nach bin/linux-x64/
pwsh ./Share-Workspace.ps1 -Path ~/projekte/demo -Hours 4    # Kommandozeile
pwsh ./Start-WorkspaceShareGui.ps1                           # Browser-Oberfläche (Drag & Drop, Tabs)
pwsh ./Install-GuiShortcut.ps1                               # optional: Menüeintrag workspaceshare.desktop
pwsh ./Stop-WorkspaceShare.ps1                               # alles Laufende beenden
```

Unterschiede zu Windows: Prozesse laufen je in einer eigenen Prozessgruppe (`setsid`) und werden mit `kill -TERM/-KILL` auf die Gruppe beendet; Sitzungsordner sind `chmod 700` unter `~/.local/share/workspaceshare`; Symlinks im Workspace werden wie Junctions abgelehnt; ohne Desktop-Sitzung entfallen Ordnerauswahl und Zwischenablage. Einzelheiten und offene Punkte: `docs/LINUX_PLAN.md`.

## In English (short)

- WorkspaceShare shares files or a project folder for a limited time as a read-only ZIP, behind a secret, temporary Cloudflare Quick Tunnel link. The original folder is never shared.
- Step 1: download the release ZIP and compare its SHA-256 hash (or `git clone` and run `.\Install-Dependencies.ps1`).
- Step 2: run `Install-GuiShortcut.ps1` once to create the "WorkspaceShare" shortcut.
- Step 3: double-click the shortcut, drop files or folders in, choose the duration, click "Freigeben" and copy the link.
- Step 4: the recipient downloads a ZIP from the link and installs nothing. The share ends automatically or with "Freigabe beenden".
- Several shares can run at once (up to 5), each in its own tab that you can rename; reloading the page with F5 works.
- Releases: https://github.com/Ceegore/CeegorsCodeOnWebForAITool/releases
- The UI labels and the rest of this README are in German.

## Sicherheitsmodell

WorkspaceShare gibt niemals das Originalverzeichnis frei. Der Ablauf ist:

1. Workspace vollständig prüfen.
2. offensichtliche Schlüsseldateien und Reparse-Points blockieren;
3. bereinigtes ZIP64 aus den eingeschlossenen Dateien erzeugen und die Quelle davor/danach vergleichen;
4. das fertige ZIP extrahieren, die Ausschlussregeln erneut erzwingen und genau diesen Inhalt mit Gitleaks scannen;
5. exakt dieses eine Archiv mit miniserve auf `127.0.0.1` bereitstellen;
6. 256-Bit-Capability-Token als geheimen Route-Prefix setzen;
7. Cloudflare Quick Tunnel starten;
8. lokale und öffentliche Sicherheits-Gates ausführen;
9. Link nur bei vollständig grünen Gates ausgeben;
10. alle nativen Prozesse in einem Windows Job Object überwachen und Tunnel, Server und Snapshot nach Ablauf oder Abbruch beseitigen.

Der vollständige Link ist ein Bearer-Secret. Jeder Besitzer kann die Datei herunterladen und weitergeben.

## Voraussetzungen

- Windows 10/11 x64
- Windows PowerShell 5.1
- `curl.exe`
- ausgehender Internetzugriff für GitHub-Downloads und Cloudflare Tunnel
- Netzwerkzugriff auf die gepinnten offiziellen Release-Assets; falls keine exakt passende `7z.exe` vorhanden ist, wird der SHA-256-geprüfte eigenständige `7zr.exe`-Bootstrapper verwendet
- ausreichend freier lokaler Speicher für den Snapshot

Keine Domain, kein Cloudflare-Konto, keine Portweiterleitung und keine eingehende Firewallregel sind erforderlich.

## Details für Entwickler: Abhängigkeiten und Sicherheitsrichtlinien

Die Kurzanleitung oben genügt für die Nutzung. Dieser Abschnitt erklärt die
Hintergründe für Entwicklung und Installation aus dem Quellcode. Das Tool läuft
direkt aus dem Ordner mit den Dateien; es muss nicht kopiert werden.

Öffne PowerShell in diesem Ordner, zum Beispiel:

```powershell
Set-Location "<Pfad zum Ordner mit den Tool-Dateien>"
```

Ausführungsrichtlinie: Meldet PowerShell „nicht digital signiert“, gilt auf dem
Rechner eine restriktive Richtlinie. Erlaube die Skripte nur für das **aktuell
geöffnete PowerShell-Fenster**; die Einstellung ändert keine Systemrichtlinie und
endet mit dem Fenster. (Zur Mark-of-the-Web siehe Schritt 1 der Kurzanleitung.)

```powershell
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass -Force
```

> **Hinweis:** Auf Rechnern mit Smart App Control oder WDAC-Richtlinien sollten
> `Unblock-File` und `Set-ExecutionPolicy` nur für Dateien verwendet werden, denen
> du vertraust. Ein `git clone`-Checkout trägt keine Mark-of-the-Web; mit der
> Richtlinie `RemoteSigned` sind beide Schritte dann nicht nötig. Unter `Restricted`
> (Standard auf Windows-Clients) bleibt `Set-ExecutionPolicy` erforderlich.

Danach die geprüften Laufzeitabhängigkeiten einrichten:

```powershell
.\Install-Dependencies.ps1
```

Neuinstallation bei vorhandenem Lockfile:

```powershell
.\Install-Dependencies.ps1 -Force
```

`Install.cmd` ist nicht erforderlich und wird nicht empfohlen. Der direkte
PowerShell-Aufruf liefert verständliche Fehler und vermeidet Warnungen durch
Batch-zu-PowerShell-Launcher. Die vier `.cmd`-Dateien (`Install.cmd`,
`WorkspaceShare.cmd`, `Test.cmd`, `Stop.cmd`) sind nur Hinweis-Stubs, die eine
Meldung ausgeben und mit Exit 1 enden; die `.ps1`-Skripte müssen direkt verwendet werden.

Das Installationsskript:

- lädt ausschließlich fest gepinnte offizielle Release-Assets;
- prüft deren SHA-256-Werte;
- entpackt sie in ein temporäres Staging-Verzeichnis;
- prüft die gemeldeten Versionen;
- kopiert die vier EXE-Dateien nach `bin\`;
- erzeugt `dependencies.lock.json` mit den Hashes der tatsächlich ausgeführten Dateien.

Die Übernahme von `bin\` und Lockfile ist journalgestützt und wird nach einem
Abbruch auf den letzten konsistenten Stand zurückgesetzt. Aktive und vorbereitende
Freigaben halten eine gemeinsame Lesesperre; Installer und Release-Build benötigen
die exklusive Sperre und können deshalb keine bereits geprüften Binärdateien ersetzen.

Ohne gültiges Lockfile startet `Share-Workspace.ps1` nicht.

> **Hinweis zur gepinnten Gitleaks-Baseline 8.30.1:** Für das Windows-x64-Asset wird der Digest des offiziellen GitHub-Release-Assets fest im Installer geprüft. Der separat veröffentlichte Upstream-Checksumsatz war für dieses Asset zum Erstellungszeitpunkt Gegenstand einer dokumentierten Abweichung. Der Installer vertraut deshalb nicht blind auf diese Datei, sondern ausschließlich auf den hier geprüften Asset-Digest. Bei einem Versionsupdate müssen Release-Asset, Digest und Lizenz erneut unabhängig geprüft und gemeinsam geändert werden.

## Automatisierter lokaler Test

```powershell
.\tests\Test-WorkspaceShare.ps1
```

## Workspace freigeben

Bleibe im selben Tool-Ordner und führe aus:

```powershell
.\Share-Workspace.ps1 -Path "D:\Projekte\Roswell" -Hours 4
```

Kurzer Test:

```powershell
.\Share-Workspace.ps1 -Path "D:\Projekte\Roswell" -Minutes 15
```

Der Link wird standardmäßig einmal ausgegeben und in die Zwischenablage kopiert. Am Sitzungsende wird die Zwischenablage nur dann geleert, wenn sie noch exakt diesen Link enthält.

Für Automatisierung schreibt `-EventStream` maschinenlesbare Fortschrittsereignisse (siehe `docs\GUI_CONTRACT.md`).

## Grafische Oberfläche (GUI)

Die GUI ist eine einfache Browser-Seite, die ausschließlich auf `127.0.0.1` läuft und von `Start-WorkspaceShareGui.ps1` bereitgestellt wird. Sie benötigt nur Windows PowerShell 5.1, keine zusätzlichen Programme und kompiliert nichts; sie ist mit Smart App Control kompatibel. Sie verwendet dasselbe `Share-Workspace.ps1` mit allen Sicherheitsprüfungen. Die GUI startet es nur, zeigt Fortschritt und Link an und beendet es.

Einmalige Einrichtung:

```powershell
.\Install-GuiShortcut.ps1
```

Das Skript erstellt die Verknüpfungen „WorkspaceShare“ auf dem Desktop und im Startmenü. Mit `-Desktop` oder `-StartMenu` wird auf einen der Orte beschränkt, mit `-Remove` werden die Verknüpfungen gelöscht. Die Verknüpfung startet `powershell.exe -NoLogo -NoProfile -STA -WindowStyle Hidden -File ...\Start-WorkspaceShareGui.ps1`; es gibt keine .cmd-Datei und keine ExecutionPolicy-Umgehung.

Direkter Start ohne Verknüpfung (öffnet den Browser automatisch):

```powershell
powershell.exe -NoProfile -STA -File .\Start-WorkspaceShareGui.ps1
```

Nach einem Update ersetzt ein Start der Verknüpfung eine ungenutzte alte Instanz automatisch; läuft gerade eine Freigabe, läuft sie in der alten Version weiter, bis sie endet.

Bedienung:

1. Dateien oder Ordner per Drag & Drop in das Feld ziehen, „Dateien auswählen…“ klicken, „Ordner wählen…“ klicken oder den Pfad eintippen.
2. Dauer festlegen.
3. Optional „Erweitert“ öffnen (Kompression, Build-/Cache-Ordner).
4. „Freigeben“ klicken. Der Fortschritt zeigt 8 Schritte.
5. Danach den Link mit „Link kopieren“ übernehmen. Er wird ohne Windows-Zwischenablageverlauf und ohne Cloud-Zwischenablage kopiert.
6. „Freigabe beenden“ beendet die Freigabe des aktuellen Tabs.

„Beenden“ unten auf der Seite beendet nach Bestätigung alle laufenden Freigaben und schließt den GUI-Dienst.

### Dateien und Ordner per Drag & Drop

Ziehe Dateien oder ganze Ordner aus dem Explorer in das Feld „Dateien oder Ordner hierher ziehen“. Alternativ klickst du „Dateien auswählen…“. Die Auswahl wird zuerst in einen privaten, temporären Ordner kopiert (mit Fortschrittsanzeige). Danach zeigt das Feld den Pfad, eine Zusammenfassung wie „3 Dateien, 12,4 MB“ und den Button „Entfernen“. Wird ein anderer Ordner gewählt oder eingetippt, wird die Auswahl verworfen.

- Grenzen: maximal 4 GiB pro Datei und insgesamt, maximal 10.000 Dateien (Standardwerte).
- Temporärer Ordner: `%LOCALAPPDATA%\WorkspaceShare\drops`. Er wird gelöscht, sobald die Freigabe endet oder „Entfernen“ geklickt wird.
- Linux (experimentell): Dieselbe Drag-&-Drop-Bedienung funktioniert auch unter Linux, weil sie nur Browser und .NET nutzt. Siehe den Abschnitt „Linux (experimentell)“ weiter unten und `docs/LINUX_PLAN.md`.

Sicherheitshinweise:

- Die Seite ist nur vom eigenen PC aus erreichbar (`127.0.0.1`) und durch ein zufälliges Sitzungs-Token geschützt. Das Token steht in der Adresse und wird nach dem Laden aus der Adresszeile entfernt.
- Das Schließen des Browser-Tabs beendet eine laufende Freigabe **nicht**. Über die Verknüpfung erneut öffnen; die GUI verbindet sich mit dem laufenden Dienst.
- Endet der GUI-Dienst, werden alle laufenden Freigaben automatisch gestoppt.

### Mehrere Freigaben und Tabs

Jede Freigabe hat einen eigenen Tab; der letzte Tab „+ Neue Freigabe“ öffnet das Formular für eine weitere. Maximal 5 Freigaben laufen gleichzeitig, weil jede einen eigenen Cloudflare-Quick-Tunnel öffnet. Beendete Tabs bleiben sichtbar, bis du sie mit „Tab schließen“ entfernst; es werden höchstens 20 Einträge angezeigt, der älteste beendete Tab wird dann automatisch entfernt. Mit F5 lädst du die Seite jederzeit neu, ohne die Verknüpfung erneut zu öffnen; der Zugriffsschlüssel wird nur für diesen Browser-Tab gespeichert. Nach dem Schließen des Browser-Tabs öffnest du die Oberfläche über die Verknüpfung erneut.

Tests (ohne Netzwerk):

```powershell
.\tests\Test-WorkspaceShareGui.Http.ps1
.\tests\Test-WorkspaceShareGui.ps1
```

Technische Details stehen in `docs\GUI_PLAN.md` und `docs\GUI_CONTRACT.md`. Der Linux-Port (Plan, Status, Einschränkungen) ist in `docs/LINUX_PLAN.md` beschrieben.

## Wichtige Parameter

| Parameter | Wirkung |
|---|---|
| `-Path <Ordner>` | Pflicht, Position 0; existierender Quellordner; ungültiger Pfad: Exit 10 |
| `-Hours 1..24` | Freigabedauer in Stunden; Standard 4; schließt `-Minutes` aus |
| `-Minutes 1..1440` | alternative Freigabedauer in Minuten; schließt `-Hours` aus |
| `-Compression Fast` | ZIP Deflate mit niedriger Kompressionsstufe; Standard |
| `-Compression Store` | keine Kompression; schnell bei bereits komprimierten Assets |
| `-IncludeGenerated` | schließt normalerweise ausgelassene Build-/Cache-Ordner ein |
| `-KeepArchive` | behält lokalen Sitzungsordner nach Ende |
| `-NoClipboard` | kopiert den Link nicht |
| `-KeepClipboard` | leert den Link nach Ende nicht automatisch |
| `-UnsafeSkipSecretScan -TestMode` | ausschließlich für isolierte Tests; im normalen Betrieb verboten |
| `-TunnelProtocol auto\|quic\|http2` | Cloudflared-Transport; Standard `auto` mit QUIC-/HTTP2-Fallback |
| `-TunnelEdgeIpVersion auto\|4\|6` | Edge-IP-Modus; Standard `auto` |
| `-HealthCheckSeconds 5..120` | Intervall für lokale, Edge-, DNS- und öffentliche Byte-Prüfungen; Standard 15 |
| `-HealthFailureThreshold 2..12` | veralteter Kompatibilitätsparameter; Ausfälle werden zeitbasiert bewertet; Standard 4; andere Werte erzeugen nur eine Warnung |
| `-TunnelRetries 5..12` | Cloudflared-Verbindungsversuche; Standard 8 |
| `-KeepDiagnosticsOnError $true\|$false` | speichert bei Fehlern sichere Logs außerhalb des Snapshot-Ordners; Standard `$true` |

## Langzeittest

Während einer aktiven Freigabe kann ein unabhängiger Soak-Test die lokale Route,
Cloudflared-Readiness und einen exakten öffentlichen Byte-Abruf protokollieren.

```powershell
.\scripts\Test-TunnelSoak.ps1 `
  -MetricsPort <port> `
  -Minutes 60
```

| Parameter | Wirkung |
|---|---|
| `-MetricsPort 1..65535` | Pflicht; Port des lokalen Cloudflared-Metrics-Endpunkts (`/ready`) |
| `-Minutes 1..1440` | Testdauer in Minuten; Standard 60 |
| `-IntervalSeconds 5..300` | Abstand zwischen den Proben; Standard 15 |
| `-OutputPath <Datei>` | JSONL-Protokoll; Standard `tunnel-soak-<UTC>.jsonl` im aktuellen Ordner |
| `-MaximumAllowedOutageSeconds 0..3600` | zulässige Dauer der längsten zusammenhängenden Störung; Standard 0 (dann führt bereits ein fehlgeschlagenes Sample zu Exit 1) |

Die URLs werden aus den Umgebungsvariablen `WORKSPACESHARE_PUBLIC_URL` und
`WORKSPACESHARE_LOCAL_URL` gelesen (danach aus dem Prozess entfernt) oder sicher
abgefragt. URL-Argumente auf der Befehlszeile werden abgelehnt (Exit 2), damit ein
Capability-Token nicht in Prozesslisten oder im Verlauf erscheint.

Exit-Codes von `Test-TunnelSoak`: `0` gesund, `1` Ausfall, `2` ungültige Eingabe.

Vor einer echten Langzeitabnahme muss der ausgegebene Quick-Tunnel-Hostname auch
über den normalen Windows-DNS-Resolver erreichbar sein. Der Preflight schreibt
keinen Hostnamen oder Link in Dateien:

```powershell
.\scripts\Test-QuickTunnelDns.ps1 -Hostname '<Quick-Tunnel-Hostname>'
```

Der Soak-Test ist im Standardmodus strikt: bereits ein fehlgeschlagener Sample
liefert Exit-Code 1. Mit `-MaximumAllowedOutageSeconds` größer als null wird
nur die längste zusammenhängende Störung gegen dieses Budget geprüft.

## Projektspezifische Ausschlüsse

Optional im freizugebenden Workspace:

```text
.workspace-share.exclude.txt
```

Syntax: PowerShell-`-like`-Wildcards, nämlich `*` (beliebig viele Zeichen) und `?`
(ein Zeichen). `[` und `]` gelten wörtlich (z. B. `pages\[id]` für Next.js-Routen),
es gibt keine Zeichenklassen. Keine Gitignore-Semantik und keine 7-Zip-Syntax.
Ein Muster trifft den relativen Pfad, den Dateinamen oder einen beliebigen einzelnen
Pfadbestandteil. Ein nackter Name wie `HugeRawAssets` trifft in jeder Tiefe,
`HugeRawAssets\*` nur im Workspace-Root.

Beispiel:

```text
HugeRawAssets
HugeRawAssets\*
*.psd
*.blend1
```

Die Pflichtausschlüsse aus `config\mandatory-excludes.txt` können projektseitig nicht
aufgehoben werden. Dazu gehören Git-Verzeichnisse sowie Zugangsdaten-Dateien und
-Ordner wie `.ssh`, `.aws`, `.npmrc`, `.pypirc`, `.netrc`, `.git-credentials`,
`*.tfstate` und `*.tfvars`; sie werden stillschweigend ausgelassen.

Private-Key- und Passwortdatenbank-Dateien (`*.pem`, `*.key`, `*.pfx`, `*.ppk`,
`*.kdbx`, `id_rsa`, `id_ecdsa`, `id_dsa`, `id_ed25519`, `.env`) blockieren die
Freigabe mit Exit 22. Beispieldateien wie `.env.example` sind davon ausgenommen.

## Snapshot-Konsistenz

WorkspaceShare verwendet keine Volume Shadow Copy. Der Snapshot ist deshalb eine
bestmögliche, verifizierte Momentaufnahme: Nur Dateien, die nach den aktiven Regeln
tatsächlich enthalten werden, fließen in den Vorher-/Nachher-Hashvergleich ein.
Ändert sich eine enthaltene Datei während 7-Zip liest, wird das Archiv verworfen.
Änderungen an ausgeschlossenen Build- und Cache-Inhalten brechen die Freigabe nicht
ab. Für Workspaces mit dauerhaft schreibenden Prozessen sollten diese Prozesse vor
dem Snapshot pausiert oder eine außerhalb des Tools erzeugte VSS-Kopie geteilt werden.

## Freigabe sofort beenden

Im aktiven Terminal:

```text
Strg+C
```

Notfall-Stop aus einem zweiten Terminal:

```powershell
.\Stop-WorkspaceShare.ps1
```

Der Notfall-Stop signalisiert zuerst kooperativ. Ist der Launcher nicht mehr
vorhanden, beendet er anschließend das in den Sitzungsmetadaten gespeicherte Job
Object und prüft die einzelnen Prozessidentitäten als Fallback. `-KeepArchives`
oder ein vorhandener `keep.archive`-Marker betrifft nur die lokale Aufbewahrung.

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
dist\WorkspaceShare-3.4.0.zip
dist\WorkspaceShare-3.4.0.zip.sha256.txt
```

Das ZIP enthält außerdem die `LICENSE` des Projekts.

## Laufzeitdaten

```text
%LOCALAPPDATA%\WorkspaceShare\sessions\<Session-ID>\
```

`session.json` enthält Prozessidentitäten und lokale Pfade, aber niemals Capability-Token oder vollständigen Link.

## Fehlercodes

| Bereich | Code |
|---|---:|
| Normaler Ablauf oder manueller Stopp | 0 |
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

Exit-Code 1 ohne Meldung deutet auf einen PowerShell-Startfehler (z. B. Ausführungsrichtlinie) hin.

## Bewusste Grenzen

- Linkbesitzer können die Datei speichern oder weitergeben.
- Cloudflare verarbeitet den Klartext technisch am HTTPS-Endpunkt.
- Quick Tunnels sind ein temporärer Test-/Entwicklungsdienst ohne Produktiv-SLA.
- Secret-Scanner können False Positives und False Negatives haben.
- Das Tool ist für interne, kurzzeitige Send-only-Freigaben gedacht, nicht für dauerhaftes Hosting.
