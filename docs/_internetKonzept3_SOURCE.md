# InternetKonzept 3
## Maximaleffiziente, temporäre Read-only-Freigabe lokaler Code-Workspaces

**Dokumenttyp:** finale Architektur-, Umsetzungs-, Code- und Abnahmespezifikation  
**Stand:** 30.07.2026  
**Zielplattform:** Windows 10/11 x64  
**Vorgänger:** `_internetKonzept2.md` bleibt unverändert erhalten  
**Betriebsmodell:** intern, send-only/read-only, wenige Stunden je Sitzung  
**Typische Datenmenge:** bis etwa 10 GB je Snapshot  
**Cloud-Kosten:** 0 € bei Verwendung eines Cloudflare Quick Tunnels  
**UX-Ziel:** ein Befehl erzeugt einen direkt aufrufbaren HTTPS-Link; keine Login-Maske

> **Historischer Architekturstand:** Dieses Quelldokument enthält den ursprünglichen
> Referenzcode vom 30.07.2026 und ist keine ausführbare Implementationsquelle. Der
> aktuelle Stand scannt ausschließlich den exakt extrahierten finalen ZIP-Inhalt,
> schützt alle nativen Kinder mit einem Windows Job Object, verwendet eine
> Leser-/Schreiber-Lease für Dependencies und prüft nur tatsächlich eingeschlossene
> Quelldateien vor/nach der Snapshot-Erstellung. Die aktuelle Betriebsbeschreibung
> steht in `README.md` und `SECURITY.md`.

---

# 1. Abschließendes Urteil

## 1.1 Ist das Tool wie beschrieben umsetzbar?

**Ja.** Das Vorhaben ist technisch klar, mit überschaubarem Risiko und sehr
geringem eigenem Entwicklungsumfang umsetzbar.

Die wichtigste Verbesserung gegenüber Version 2 lautet:

> Es wird kein eigener HTTP-Server mehr entwickelt.

Stattdessen werden vier etablierte Bausteine kombiniert:

1. **7-Zip/7za.exe** erzeugt und prüft den ZIP64-Snapshot.
2. **Gitleaks** prüft den Workspace auf häufige Secrets.
3. **miniserve** liefert exakt eine Datei mit Range-Unterstützung aus.
4. **cloudflared** erzeugt den kostenlosen temporären HTTPS-Tunnel.

Eigener Code ist auf kleine PowerShell-Skripte begrenzt, die:

- Parameter prüfen;
- Sicherheits-Gates ausführen;
- die externen Programme starten;
- den Capability-Link bilden;
- Laufzeit und Prozesse überwachen;
- alles zuverlässig beenden und löschen.

Dadurch werden die technisch schwierigsten und fehleranfälligsten Aufgaben nicht
selbst neu implementiert:

- kein eigener HTTP-Parser;
- kein eigenes Range-Handling;
- kein eigenes Streaming;
- kein eigener ZIP64-Writer;
- keine eigene Secret-Regeldatenbank;
- kein TLS- oder Tunnelprotokoll;
- keine Weboberfläche;
- keine Schreib-API.

## 1.2 Ist der Plan „perfekt“?

Kein Netzwerkwerkzeug kann seriös als absolut perfekt oder endgültig
unverbesserbar bezeichnet werden. Abhängigkeiten, Betriebssysteme und
Cloudflare-Verhalten können sich ändern.

Nach dieser Überarbeitung gilt jedoch:

- keine offene Produktentscheidung blockiert die Implementierung;
- das MVP ist bewusst minimal;
- alle sicherheitsrelevanten Annahmen besitzen messbare Gates;
- Drittprogramme sind austauschbar;
- der Codepfad bleibt read-only;
- ein vollständiger Windows-End-to-End-Test entscheidet über die Freigabe;
- eine fehlgeschlagene Prüfung führt immer zu **fail closed**.

Die empfohlene Entscheidung lautet daher:

**GO für die Implementierung, aber erst GO für den internen Betrieb, nachdem alle
Pflicht-Gates dieses Dokuments bestanden wurden.**

---

# 2. Verbindlicher Scope

## 2.1 Muss-Funktionen

Das Tool muss:

1. genau einen lokalen Workspace-Ordner entgegennehmen;
2. daraus einen bereinigten, unveränderlichen Snapshot erzeugen;
3. offensichtliche Schlüsseldateien und Gitleaks-Funde blockieren;
4. den Snapshot als einzelne ZIP-Datei bereitstellen;
5. nur an `127.0.0.1` lauschen;
6. einen mindestens 256 Bit starken Geheimtoken im URL-Pfad verwenden;
7. einen kostenlosen Cloudflare Quick Tunnel starten;
8. genau einen direkt nutzbaren HTTPS-Link ausgeben;
9. Range-Downloads und Download-Fortsetzung unterstützen;
10. keine Anmeldung und keine Passwortmaske benötigen;
11. nach Ablauf oder `Strg+C` Tunnel und Server beenden;
12. den temporären Snapshot standardmäßig löschen;
13. bei Launcher-Absturz über einen Watchdog aufräumen;
14. niemals Uploads, Änderungen oder Löschungen von außen ermöglichen.

## 2.2 Verbindliches read-only/send-only-Modell

Extern wird nur eine bereits fertig erzeugte Datei gelesen.

Es gibt ausdrücklich nicht:

- Upload;
- Formular;
- `PUT`-Speicherung;
- `PATCH`;
- Löschfunktion;
- Verzeichnisanlage;
- WebDAV;
- Git-Push;
- Dateieditor;
- Synchronisierung;
- Live-Schreibzugriff auf den Workspace;
- direkten Zugriff auf das Originalverzeichnis.

Selbst wenn ein HTTP-Client ungewöhnliche Methoden sendet, existiert im
konfigurierten Serverpfad keine aktivierte Mutationsfunktion. Zusätzlich wird
vor jeder Freigabe der SHA-256-Hash des Snapshots vor und nach
POST/PUT/PATCH/DELETE-Probes verglichen.

## 2.3 Bewusst nicht im MVP

Für maximale Entwicklungseffizienz werden nicht umgesetzt:

- grafische Oberfläche;
- mehrere getrennte Quelllaufwerke in einem Link;
- Dateibrowser;
- einzelne Quelldatei-URLs;
- Konten und Rollen;
- feste Domain;
- Cloudflare-Dashboard-Setup;
- eigener Tunnel;
- eigene Kryptografie außer Token-Erzeugung;
- eigener HTTP-Server;
- eigener ZIP-Code;
- eigener Secret-Scanner;
- automatische Cloud-Uploads;
- Telemetrie;
- Datenbank;
- Windows-Dienst;
- automatische Selbstaktualisierung;
- öffentliches Hosting.

Ein Parent-Ordner kann beliebig viele Repositories enthalten. Wenn Repositories
auf verschiedenen Laufwerken liegen, werden im MVP entweder zwei Freigaben
erzeugt oder vorübergehend unter einem gemeinsamen Workspace-Root organisiert.
Diese Einschränkung spart unverhältnismäßig viel Staging- und Pfadlogik.

---

# 3. Recherche nach wiederverwendbaren GitHub-Projekten

Der umgangssprachliche Wunsch, bestehende Projekte zu „beklauen“, wird technisch
und rechtlich korrekt als **lizenzkonforme Wiederverwendung etablierter
Open-Source-Bausteine** umgesetzt.

## 3.1 Entscheidungsmatrix

| Baustein | Aufgabe | Lizenz | Übernahme | Entscheidung |
|---|---|---|---|---|
| `svenstaro/miniserve` | Einzeldatei-HTTP, Range, Header, Loopback | MIT | unveränderte EXE | **verwenden** |
| `cloudflare/cloudflared` | HTTPS-Quick-Tunnel | Apache-2.0 | unveränderte EXE | **verwenden** |
| `ip7z/7zip` / `7za.exe` | ZIP64, Test, Manifest | LGPL + Notices | unveränderte EXE | **verwenden** |
| `gitleaks/gitleaks` | Secret-Erkennung | MIT | unveränderte EXE | **verwenden** |
| Python `http.server` | einfacher HTTP-Server | PSF | Laufzeit + Eigenhärtung | ablehnen |
| RangeHTTPServer-Forks/Gists | Range-Support | unterschiedlich | fremder Python-Code | ablehnen |
| `dufs` | Datei-/WebDAV-Server | MIT/Apache-Umfeld prüfen | deutlich mehr Funktionen | ablehnen |
| `simple-http-server` | HTTP-Dateiserver | frei | ähnlich geeignet | Reserve |
| `croc` | verschlüsselte Dateiübertragung | MIT | Client auf Empfängerseite nötig | ablehnen |
| OnionShare | anonyme Freigabe | GPL | Tor-/UI-Komplexität | ablehnen |
| Rclone Serve | Datei-Serving | MIT | unnötig großer Funktionsumfang | Reserve |
| eigener Rust/Go-Server | volle Kontrolle | eigener Code | hoher Testaufwand | ablehnen |

## 3.2 Warum miniserve ideal passt

miniserve ist ein einzelnes, plattformübergreifendes Binary. Es kann direkt eine
einzelne Datei bereitstellen, unterstützt Range-Requests, eigene Header,
explizites Interface-Binding und einen frei gewählten Route-Prefix.

Wichtig:

- Der eingebaute `--random-route`-Modus erzeugt nur sechs Hex-Zeichen und wird
  deshalb **nicht** verwendet.
- WorkspaceShare erzeugt selbst 32 Zufallsbytes.
- Der Token wird über `MINISERVE_ROUTE_PREFIX` an den Kindprozess übergeben und
  nicht als sichtbares Kommandozeilenargument.
- Als Serve-Path wird eine Datei, kein Verzeichnis, übergeben.
- Upload-, mkdir-, rm- und WebDAV-Flags werden niemals gesetzt.

## 3.3 Warum 7-Zip statt PowerShell Compress-Archive

PowerShell `Compress-Archive` ist für diesen Anwendungsfall ungeeignet:

- die zugrunde liegende API begrenzt einzelne Dateien auf 2 GB;
- versteckte Dateien und Ordner können ignoriert werden;
- 10-GB-Workspaces und große Binärdateien brauchen verlässliches ZIP64;
- wir benötigen zusätzlich Archivtest und maschinenlesbare Inhaltsliste.

7-Zip liefert all das als bestehendes Kommandozeilenwerkzeug.

## 3.4 Warum Gitleaks statt eigener Regex-Sammlung

Eine eigene Regex-Sammlung altert schnell und übersieht neue Tokenformate.
Gitleaks enthält eine gewachsene Regeldatenbank und kann direkt Verzeichnisse
scannen. Die eigene Logik bleibt auf besonders gefährliche Dateinamen und
Reparse-Points beschränkt.

Gitleaks ist laut Projekt derzeit „feature complete“ und soll hauptsächlich
Sicherheitsupdates erhalten. Das ist für einen stabilen internen Scanner
vertretbar; die Abhängigkeit wird trotzdem versioniert und jährlich neu bewertet.

## 3.5 Warum kein direkter Live-Workspace-Server

Der Original-Workspace wird nie direkt serviert. Ein Snapshot verhindert:

- gleichzeitige Dateiveränderungen;
- unbeabsichtigte Symlink-/Junction-Ausbrüche;
- Zugriff auf Dateien, die nach Linkausgabe entstehen;
- externe Navigation durch die lokale Ordnerstruktur;
- versehentliches Aktivieren von Schreibfunktionen;
- instabile Downloads während Build- oder Agentenprozessen.

---

# 4. Finale Architektur

```text
Lokaler Workspace
      │
      │ Sicherheitsprüfung
      ▼
Dateinamen-/Reparse-Gate + Gitleaks
      │
      │ Snapshot
      ▼
7za.exe → einzelnes geprüftes ZIP64 + SHA-256 + Manifest
      │
      │ read-only Datei
      ▼
miniserve.exe
  bind: 127.0.0.1:<zufälliger Port>
  route: /d/<256-Bit-Token>/
  kein Upload / kein WebDAV / kein Verzeichnis
      │
      │ localhost
      ▼
cloudflared Quick Tunnel
      │
      │ HTTPS, zufällige trycloudflare.com-Subdomain
      ▼
https://zufall.trycloudflare.com/d/<Token>/
      │
      ▼
Empfänger liest/lädt ZIP; keine Schreibmöglichkeit
```

## 4.1 Vertrauensgrenzen

| Bereich | Darf Klartext sehen? | Darf lokale Dateien ändern? |
|---|---:|---:|
| lokaler WorkspaceShare-Prozess | ja | nur temporäre Sitzung |
| 7-Zip | ja | erstellt nur Snapshot |
| Gitleaks | ja | nein |
| miniserve | ja | nein, nur Serve-Path lesen |
| cloudflared/Cloudflare | technisch ja, während Transport | nein |
| Empfänger mit Link | ja | nein; kann Kopie behalten |
| Dritter ohne Link | praktisch nicht bei ausreichender Entropie | nein |

## 4.2 Capability-Link

Der vollständige Link ist ein Bearer-Secret:

```text
https://<zufällige-subdomain>.trycloudflare.com/d/<256-bit-token>/
```

Sicherheitsstärke:

- zufällige Cloudflare-Subdomain;
- zusätzlich 256 Bit kryptografischer Zufall;
- kurze Lebensdauer;
- keine öffentliche Verlinkung;
- Root und falsche Tokens liefern nicht HTTP 200.

Das Token gehört nicht in:

- Logdateien;
- `session.json`;
- Screenshots;
- Tickets;
- öffentliche Chats;
- Git-Commits;
- Prozesskommandozeile.

Es erscheint nur:

- im Arbeitsspeicher des Launchers;
- in der Umgebung des miniserve-Kindprozesses;
- einmal in der Terminalausgabe;
- optional in der Zwischenablage;
- im vom Nutzer gewählten Übertragungskanal.

---

# 5. Sicherheitsmodell und Restrisiken

## 5.1 Abgedeckte Risiken

- zufälliges Erraten des Links;
- ungeschützter LAN-Port;
- öffentliches Directory Listing;
- Live-Zugriff auf das Arbeitsverzeichnis;
- Upload und Remote-Änderung;
- abgebrochene große Downloads;
- Launcher-Absturz;
- Schlafmodus während einer Sitzung;
- offensichtliche Schlüsseldateien;
- bekannte Tokenformate;
- Cloudflare-/Browser-Caching;
- vergessene temporäre ZIPs;
- Port-Race beim Start;
- falsche Prozess-PID beim Notfall-Cleanup.

## 5.2 Nicht vollständig eliminierbare Risiken

1. Wer den Link besitzt, kann ihn weitergeben.
2. Der Empfänger kann die heruntergeladene Kopie behalten.
3. Chat-/Ticket-/Browser-Systeme können URLs protokollieren.
4. Cloudflare terminiert HTTPS und verarbeitet den Inhalt technisch.
5. Quick Tunnels besitzen keine SLA.
6. Ein sehr langer Download kann bei Ablauf abgeschnitten werden.
7. Lokale Malware mit Benutzerrechten kann Prozesse oder Dateien beobachten.
8. Secret-Scanner können False Negatives und False Positives haben.
9. Ein externes Programm stellt immer ein Supply-Chain-Risiko dar.
10. Ein Strom- oder Netzwerkausfall beendet die Sitzung.

Für den beschriebenen internen, kurzzeitigen Zweck sind diese Restrisiken
vertretbar, sofern die Pflicht-Gates eingehalten werden.

## 5.3 Fail-closed-Regel

Bei Unsicherheit wird kein Link ausgegeben.

Harte Abbruchbedingungen:

- Abhängigkeit fehlt oder Checksumme stimmt nicht;
- Verzeichnis nicht vollständig lesbar;
- Reparse-Point gefunden;
- verbotene Schlüsseldatei gefunden;
- Gitleaks-Fund;
- Archiv kann nicht erstellt oder getestet werden;
- lokaler Root liefert 200;
- falscher Token liefert 200;
- Range-Test schlägt fehl;
- Archivhash ändert sich;
- Tunnel-URL fehlt;
- öffentlicher Test schlägt fehl;
- Cache meldet `HIT`;
- Watchdog startet nicht.

---

# 6. Projektstruktur

```text
WorkspaceShare/
├─ _internetKonzept3.md
├─ README.md
├─ Share-Workspace.ps1
├─ Stop-WorkspaceShare.ps1
├─ Install-Dependencies.ps1
├─ dependencies.lock.json
├─ THIRD_PARTY_NOTICES.md
├─ bin/
│  ├─ cloudflared.exe
│  ├─ miniserve.exe
│  ├─ 7za.exe
│  ├─ gitleaks.exe
│  └─ licenses/
│     ├─ cloudflared-LICENSE
│     ├─ cloudflared-NOTICE
│     ├─ miniserve-LICENSE
│     ├─ 7zip-LICENSE.txt
│     └─ gitleaks-LICENSE
├─ config/
│  ├─ mandatory-excludes.txt
│  ├─ generated-excludes.txt
│  └─ gitleaks-workspaceshare.toml
├─ scripts/
│  └─ Watch-WorkspaceShare.ps1
└─ tests/
   └─ Test-WorkspaceShare.ps1
```

Laufzeitdaten:

```text
%LOCALAPPDATA%\WorkspaceShare\sessions\<Session-ID>\
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
└─ normal.exit
```

`session.json` enthält niemals URL oder Token.

---

# 7. Manuelle Cloudflare-Einrichtung

## 7.1 Für Quick Tunnels ist kein Dashboard nötig

Nicht erforderlich:

- kein Cloudflare-Konto;
- keine Kreditkarte;
- kein Tarif;
- keine Domain;
- kein DNS-Eintrag;
- keine Nameserver-Änderung;
- kein Zero-Trust-Team;
- keine Access-App;
- kein Login-Befehl;
- kein Tunnel-Token;
- kein Windows-Dienst.

Der einzige Cloudflare-Baustein ist `cloudflared.exe`.

## 7.2 Schnellste Entwicklungsinstallation

```powershell
winget install -e --id Cloudflare.cloudflared
winget install -e --id svenstaro.miniserve
winget install -e --id 7zip.7zip
winget install -e --id Gitleaks.Gitleaks
```

Oder:

```powershell
.\Install-Dependencies.ps1
```

Danach die tatsächlich verwendeten EXE-Dateien in `.\bin\` kopieren und
umbenennen:

```text
cloudflared.exe
miniserve.exe
7za.exe
gitleaks.exe
```

## 7.3 Reproduzierbare interne Distribution

Für die freigegebene Toolversion nicht blind `latest` verwenden.

Vorgehen:

1. Releases nur aus offiziellen Quellen herunterladen.
2. Versionen festlegen.
3. jede EXE mit SHA-256 hashen;
4. Werte in `dependencies.lock.json` eintragen;
5. Lizenz- und NOTICE-Dateien kopieren;
6. Binärpaket intern archivieren;
7. Release-Gate ausführen;
8. erst dann Version markieren.

Hash erzeugen:

```powershell
Get-FileHash .\bin\cloudflared.exe -Algorithm SHA256
Get-FileHash .\bin\miniserve.exe -Algorithm SHA256
Get-FileHash .\bin\7za.exe -Algorithm SHA256
Get-FileHash .\bin\gitleaks.exe -Algorithm SHA256
```

## 7.4 Quick-Tunnel-Konflikt prüfen

```powershell
Test-Path "$env:USERPROFILE\.cloudflared\config.yml"
Test-Path "$env:USERPROFILE\.cloudflared\config.yaml"
```

Existiert eine Datei, wird im MVP abgebrochen. Sie kann für die Sitzung manuell
umbenannt oder das Tool unter einem separaten Windows-Benutzer ausgeführt
werden.

## 7.5 Firewall

Benötigt wird nur ausgehender Verkehr von `cloudflared`.

Keine Aktion:

- keine Router-Portweiterleitung;
- keine eingehende Windows-Firewallregel;
- keinen lokalen Port im LAN öffnen.

Wenn Unternehmensfirewalls den Tunnel blockieren, müssen ausgehende
Cloudflare-Tunnel-Verbindungen nach aktueller Cloudflare-Dokumentation
freigegeben werden. Der Toolcode darf nicht automatisch Firewallregeln ändern.

## 7.6 Manueller Smoke-Test

Terminal 1:

```powershell
.\bin\miniserve.exe `
  --interfaces 127.0.0.1 `
  --port 8080 `
  "C:\Temp\test.zip"
```

Terminal 2:

```powershell
.\bin\cloudflared.exe tunnel --url http://127.0.0.1:8080
```

Die ausgegebene `trycloudflare.com`-Adresse testen und beide Prozesse mit
`Strg+C` beenden.

---

# 8. Snapshot-Regeln

## 8.1 Ein unveränderlicher Snapshot statt Live-Verzeichnis

Ablauf:

1. Root auflösen;
2. Dateibaum prüfen;
3. Gitleaks ausführen;
4. ZIP vollständig erzeugen;
5. ZIP mit `7za t` prüfen;
6. Inhaltsmanifest erzeugen;
7. SHA-256 berechnen;
8. erst danach Server/Tunnel starten.

Nach Linkausgabe wird das Archiv nicht mehr verändert.

## 8.2 Ausschlusssemantik

`.workspace-share.exclude.txt` verwendet absichtlich **7-Zip-Wildcards**, nicht
Gitignore-Syntax.

Beispiel:

```text
# Projektlokal
HugeRawAssets
HugeRawAssets\*
*.psd
*.blend1
```

Nicht unterstützt:

- `!re-include`;
- komplexe Gitignore-Vererbung;
- automatische Interpretation von `.gitignore`.

Diese bewusste Vereinfachung vermeidet einen eigenen Ignore-Parser.

## 8.3 Git-basierter Alternativmodus

Ein späterer optionaler Modus kann Dateien über:

```bash
git ls-files --cached --others --exclude-standard -z
```

ermitteln. Damit werden getrackte Dateien sowie nicht ignorierte ungetrackte
Dateien erfasst.

Dieser Modus ist **nicht MVP-Standard**, weil:

- Parent-Workspaces mehrere Repositories enthalten können;
- getrackte, aber lokal gelöschte Dateien gesondert behandelt werden müssen;
- Submodule und Worktrees zusätzliche Semantik benötigen;
- unversionierte projektrelevante Dateien möglicherweise bewusst geteilt werden;
- eine Null-separierte Dateiliste sauber an 7-Zip übergeben werden müsste.

Der direkte Workspace-Snapshot mit klaren Ausschlüssen ist für den internen
Zweck einfacher und weniger überraschend.

## 8.4 Geheimdateien

Folgende Kandidaten führen standardmäßig zum Abbruch:

- `.env`, `.env.*` außer Example/Template/Sample;
- private Schlüssel;
- PFX/P12;
- Keystores;
- SSH-Schlüssel;
- Service-Account-Dateien;
- Mobile Provisioning;
- VPN-Konfigurationen.

Sie werden nicht nur still ausgeschlossen. Ein stilles Ausschließen könnte
einen Nutzer fälschlich glauben lassen, dass die vollständige Projektumgebung
übergeben wurde.

---

# 9. HTTP- und Read-only-Verhalten

## 9.1 Exakt eine Datei

miniserve erhält als Serve-Path:

```text
...\workspace-20260730-021500.zip
```

Nicht:

```text
D:\Projekte\Roswell\
```

Dadurch existiert keine Webnavigation durch den Workspace.

miniserve besitzt interne Support-Routen, etwa einen Healthcheck. Da wir einen
eigenen Route-Prefix verwenden, liegen auch diese nur hinter dem geheimen Token.
Sie geben keine Workspace-Dateien preis und besitzen im gewählten Modus keine
Schreibfunktion. Das Sicherheitsziel lautet deshalb präzise: **Ohne korrektes
Token existiert keine erfolgreiche Route; mit Token ist ausschließlich
read-only Verhalten zulässig.**

## 9.2 Keine Schreibflags

Folgende miniserve-Funktionen dürfen nie gesetzt werden:

```text
--upload-files
--mkdir
--rm
--enable-webdav
--pastebin
```

Die Referenzimplementierung enthält keine dieser Optionen.

## 9.3 HTTP-Methoden

Einige Dateiserver können eine statische Datei auch bei ungewöhnlichen Methoden
zurückgeben. Entscheidend ist daher nicht, ob jeder Server zwingend `405`
antwortet, sondern:

- es existiert kein Schreibhandler;
- die Quelle ist eine einzelne fertige Datei;
- der SHA-256-Hash bleibt vor/nach Mutation-Probes identisch;
- der Original-Workspace wird nie serviert.

Das Pflicht-Gate prüft genau diese unveränderliche Wirkung.

## 9.4 Range und Resume

Für große Archive müssen funktionieren:

```http
Range: bytes=0-1023
```

Erwartet:

```text
HTTP 206
1024 Bytes
```

Download-Fortsetzung:

```powershell
curl.exe -C - -o workspace.zip "<LINK>"
```

Der vollständige Hash des fortgesetzten Downloads muss mit dem lokalen
Snapshot-Hash übereinstimmen.

---

# 10. Phasen und Gates

## Phase 0 – Architektur-Lock

**Arbeit:**

- Version 3 als SSOT übernehmen;
- Version 2 nur archivieren;
- Scope „ein Root, eine ZIP, read-only“ sperren;
- keine GUI und keine eigenen Netzwerkprotokolle zulassen.

**Gate G0:**

- [ ] Product Owner bestätigt send-only/read-only.
- [ ] Kein Remote-Write-Use-Case existiert.
- [ ] Ein Parent-Workspace pro Link ist akzeptiert.
- [ ] Quick-Tunnel-Risiko ohne SLA ist akzeptiert.

## Phase 1 – Dependencies

**Arbeit:**

- vier offizielle Binärdateien beschaffen;
- Versionen und SHA-256 sperren;
- Lizenztexte ablegen;
- `THIRD_PARTY_NOTICES.md` finalisieren.

**Gate G1:**

- [ ] alle vier EXEs starten;
- [ ] Versionen stimmen mit Lockfile überein;
- [ ] SHA-256 stimmt;
- [ ] Quellen sind offiziell;
- [ ] Lizenztexte liegen bei;
- [ ] keine unverified „download portal“-Binärdateien.

## Phase 2 – Snapshot

**Arbeit:**

- Ausschlussdateien;
- Reparse-/Secret-Dateinamenprüfung;
- Gitleaks;
- 7-Zip-Archiv;
- Test, Manifest, Hash.

**Gate G2:**

- [ ] `.git` fehlt im Archiv;
- [ ] `node_modules` fehlt standardmäßig;
- [ ] erlaubte versteckte Projektdateien bleiben erhalten;
- [ ] einzelne Dateien über 2 GB funktionieren;
- [ ] ZIP größer als 4 GB funktioniert;
- [ ] Secret-Testfixture stoppt den Flow;
- [ ] Symlink/Junction stoppt den Flow;
- [ ] gesperrte Datei stoppt den Flow;
- [ ] `7za t` erfolgreich;
- [ ] Manifest plausibel;
- [ ] SHA-256 erzeugt.

## Phase 3 – Lokaler Server

**Arbeit:**

- miniserve als Einzeldateiserver;
- Loopback;
- Token-Umgebungsvariable;
- no-store Header;
- lokale Negativtests.

**Gate G3:**

- [ ] richtiger Token → 200;
- [ ] Root → nicht 200;
- [ ] falscher Token → nicht 200;
- [ ] Range → 206/1024;
- [ ] Resume-Hash stimmt;
- [ ] POST/PUT/PATCH/DELETE ändern Hash nicht;
- [ ] LAN-Gerät kann lokalen Port nicht direkt erreichen;
- [ ] Task Manager zeigt Token nicht in Kommandozeile;
- [ ] keine Upload-/WebDAV-Option aktiv.

## Phase 4 – Quick Tunnel

**Arbeit:**

- cloudflared starten;
- URL aus Logs extrahieren;
- finalen Link zusammensetzen;
- öffentliche Gates.

**Gate G4:**

- [ ] URL innerhalb 60 Sekunden;
- [ ] Geheimlink → 200;
- [ ] Tunnelroot → nicht 200;
- [ ] falscher Token → nicht 200;
- [ ] Range → 206;
- [ ] `Cache-Control` enthält `no-store`;
- [ ] `CF-Cache-Status` ist nicht `HIT`;
- [ ] vollständiger Download möglich.

## Phase 5 – Lifecycle

**Arbeit:**

- Timer;
- `try/finally`;
- Watchdog;
- Sleep Prevention;
- Notfall-Stop.

**Gate G5:**

- [ ] Ablauf beendet Tunnel;
- [ ] `Strg+C` beendet Tunnel;
- [ ] Launcher-Kill beendet Tunnel über Watchdog;
- [ ] cloudflared-Kill beendet gesamte Sitzung;
- [ ] miniserve-Kill beendet gesamte Sitzung;
- [ ] Neustart macht Link unbrauchbar;
- [ ] Sessiondaten werden entfernt;
- [ ] `-KeepArchive` behält nur lokale Daten;
- [ ] Stop-Skript beendet keine fremden Prozesse.

## Phase 6 – 10-GB-Abnahme

**Arbeit:**

- realer 8–12-GB-Workspace;
- vollständiger Download;
- Unterbrechung und Fortsetzung;
- Hashvergleich;
- Ablauf.

**Gate G6:**

- [ ] Snapshot erfolgreich;
- [ ] Quell-/Archivzeit akzeptabel;
- [ ] vollständiger Download;
- [ ] Resume funktioniert;
- [ ] SHA-256 identisch;
- [ ] nach Ende kein Zugriff;
- [ ] Uploadbandbreite bleibt betrieblich akzeptabel;
- [ ] kein Speicherleck / keine vollständige RAM-Pufferung.

## Phase 7 – Release

**Gate G7:**

- [ ] alle vorherigen Gates grün;
- [ ] README stimmt;
- [ ] Lockfile vollständig;
- [ ] Lizenznotices vollständig;
- [ ] Testprotokoll archiviert;
- [ ] Version `3.0.0-internal` markiert;
- [ ] keine Funktion außerhalb des Scopes eingebaut.

---

# 11. Kopierbare Referenzimplementierung

Die folgenden Dateien können direkt als Ausgangspunkt übernommen werden. Sie
sind bewusst vollständig genug, um den Großteil der Implementierung zu sparen.
Trotzdem gilt: **Sie werden erst nach bestandenen Gates freigegeben.**

## 11.1 `Share-Workspace.ps1`

```powershell
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
    [switch]$SkipSecretScan,
    [switch]$KeepArchive,
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

    try {
        $result = & $CurlPath @arguments 2>$null
        $curlExit = $LASTEXITCODE
    }
    catch {
        # DNS-Propagation eines neuen Quick Tunnels kann kurzzeitig fehlschlagen.
        # Das ist kein Launcherfehler; der Aufrufer wiederholt die Prüfung.
        return 0
    }

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

    $parentInfo = [IO.Directory]::GetParent($SourceRoot)
    $parent = if ($parentInfo) { $parentInfo.FullName } else { $null }
    $leaf = [IO.Path]::GetFileName($SourceRoot)

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
        return
    }

    $Url | & "$env:SystemRoot\System32\clip.exe"
}

function Write-SessionMetadata {
    param(
        [Parameter(Mandatory = $true)][datetime]$ExpiresUtc,
        [Parameter(Mandatory = $true)][string]$SourceRoot,
        [Parameter(Mandatory = $true)][string]$Archive,
        [int]$WatchdogPid = 0
    )

    $metadata = [ordered]@{
        schema = 1
        createdUtc = [DateTime]::UtcNow.ToString('o')
        expiresUtc = $ExpiresUtc.ToString('o')
        sourceRoot = $SourceRoot
        archivePath = $Archive
        launcherPid = $PID
        miniservePid = if ($script:MiniserveProcess) { $script:MiniserveProcess.Id } else { 0 }
        cloudflaredPid = if ($script:CloudflaredProcess) { $script:CloudflaredProcess.Id } else { 0 }
        watchdogPid = $WatchdogPid
        miniservePath = $MiniservePath
        cloudflaredPath = $CloudflaredPath
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

    $arguments = @(
        '-NoProfile',
        '-ExecutionPolicy', 'Bypass',
        '-File', $WatchdogScriptPath,
        '-ParentPid', [string]$PID,
        '-ParentStartTicks', [string]$parentStartTicks,
        '-MiniservePid', [string]$script:MiniserveProcess.Id,
        '-CloudflaredPid', [string]$script:CloudflaredProcess.Id,
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
        if ($directory.LastWriteTimeUtc -lt $cutoff) {
            Remove-Item -LiteralPath $directory.FullName -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

# ---------------------------------------------------------------------------
# Hauptablauf
# ---------------------------------------------------------------------------

try {
    Write-Host ''
    Write-Host 'WorkspaceShare 3.0 – read-only Quick-Tunnel-Freigabe'
    Write-Host '====================================================='
    Write-Host ''

    $totalSteps = 8

    Write-Step 1 $totalSteps 'Abhängigkeiten und Umgebung prüfen ...'

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

    if (-not $SkipSecretScan) {
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
    $rootParentInfo = [IO.Directory]::GetParent($resolvedRoot)
    $rootParent = if ($rootParentInfo) { $rootParentInfo.FullName } else { $null }
    $rootLeaf = [IO.Path]::GetFileName($resolvedRoot)

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
    if (-not $SkipSecretScan) {
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
    $script:ArchivePath = Join-Path $script:SessionDirectory (
        "workspace-{0}.zip" -f [DateTime]::UtcNow.ToString('yyyyMMdd-HHmmss')
    )

    Assert-FreeDiskSpace `
        -TargetDirectory $script:SessionDirectory `
        -EstimatedSourceBytes $inspection.EstimatedBytes

    if (-not $SkipSecretScan) {
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

    if (-not (Test-RangeRequest -Url $localUrl -TemporaryDirectory $script:SessionDirectory)) {
        Stop-WithError -Code 31 -Message (
            "Lokaler Range-Test (206/1024 Bytes) ist fehlgeschlagen."
        )
    }

    # Read-only-Prüfung: Methoden dürfen den Snapshot keinesfalls verändern.
    $hashBeforeMethodTests = (Get-FileHash -LiteralPath $script:ArchivePath -Algorithm SHA256).Hash
    foreach ($method in @('POST', 'PUT', 'PATCH', 'DELETE')) {
        & $CurlPath @(
            '--silent',
            '--show-error',
            '--max-time', '10',
            '--request', $method,
            '--data-binary', 'WorkspaceShare mutation probe',
            '--output', 'NUL',
            $localUrl
        ) 2>$null | Out-Null
    }
    $hashAfterMethodTests = (Get-FileHash -LiteralPath $script:ArchivePath -Algorithm SHA256).Hash

    if ($hashBeforeMethodTests -ne $hashAfterMethodTests) {
        Stop-WithError -Code 31 -Message (
            "Der Snapshot wurde während des Methoden-Tests verändert. Read-only-Gate fehlgeschlagen."
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
        -WatchdogPid $script:WatchdogProcess.Id

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
    # Normalmarker zuerst setzen: Der Watchdog darf nun dem Launcher die Bereinigung überlassen.
    if ($script:NormalExitMarker -and $script:SessionDirectory) {
        try {
            New-Item -ItemType File -Path $script:NormalExitMarker -Force | Out-Null
        }
        catch {
        }
    }

    # Öffentliches Ende zuerst: Tunnel schließen, erst danach lokalen Server.
    Stop-ProcessSafe $script:CloudflaredProcess
    Start-Sleep -Milliseconds 300
    Stop-ProcessSafe $script:MiniserveProcess
    Stop-ProcessSafe $script:WatchdogProcess

    Disable-SystemAwake

    if ($script:SessionDirectory -and (Test-Path -LiteralPath $script:SessionDirectory)) {
        if ($KeepArchive) {
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

```

## 11.2 `scripts/Watch-WorkspaceShare.ps1`

```powershell
#requires -Version 5.1
<#
.SYNOPSIS
    Sicherheits-Watchdog für WorkspaceShare.

.DESCRIPTION
    Besitzt niemals Capability-Token oder vollständige URL.
    Beendet Tunnel/Server und löscht die Sitzung, wenn:
    - der Launcher unerwartet stirbt;
    - die Ablaufzeit erreicht ist;
    - die Launcher-PID wiederverwendet wurde.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][int]$ParentPid,
    [Parameter(Mandatory = $true)][long]$ParentStartTicks,
    [Parameter(Mandatory = $true)][int]$MiniservePid,
    [Parameter(Mandatory = $true)][int]$CloudflaredPid,
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
        [string]$ExpectedPath
    )

    try {
        $process = Get-Process -Id $ProcessId -ErrorAction Stop
        $actualPath = $process.Path

        if (-not $actualPath) {
            return $null
        }

        if (
            [IO.Path]::GetFullPath($actualPath) -ne
            [IO.Path]::GetFullPath($ExpectedPath)
        ) {
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
        [string]$ExpectedPath
    )

    $process = Get-VerifiedProcess -ProcessId $ProcessId -ExpectedPath $ExpectedPath
    if ($process) {
        Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue
    }
}

function Test-OriginalParentAlive {
    try {
        $parent = Get-Process -Id $ParentPid -ErrorAction Stop
        $ticks = $parent.StartTime.ToUniversalTime().Ticks
        return ($ticks -eq $ParentStartTicks)
    }
    catch {
        return $false
    }
}

while ($true) {
    if (Test-Path -LiteralPath $NormalExitMarker -PathType Leaf) {
        exit 0
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
    -ExpectedPath $ExpectedCloudflaredPath

Start-Sleep -Milliseconds 300

Stop-VerifiedProcess `
    -ProcessId $MiniservePid `
    -ExpectedPath $ExpectedMiniservePath

if (-not $KeepArchive) {
    Remove-Item -LiteralPath $SessionPath -Recurse -Force -ErrorAction SilentlyContinue
}

exit 0

```

## 11.3 `Stop-WorkspaceShare.ps1`

```powershell
#requires -Version 5.1
<#
.SYNOPSIS
    Beendet ausschließlich eindeutig verifizierte WorkspaceShare-Sitzungen.
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

function Stop-VerifiedProcess {
    param(
        [int]$ProcessId,
        [string]$ExpectedPath,
        [string]$Role
    )

    if ($ProcessId -le 0 -or -not $ExpectedPath) {
        return
    }

    try {
        $process = Get-Process -Id $ProcessId -ErrorAction Stop
        $actualPath = $process.Path

        if (-not $actualPath) {
            Write-Warning "$Role PID $ProcessId konnte nicht sicher verifiziert werden."
            return
        }

        if (
            [IO.Path]::GetFullPath($actualPath) -ne
            [IO.Path]::GetFullPath($ExpectedPath)
        ) {
            Write-Warning (
                "$Role PID $ProcessId gehört nicht zur erwarteten Binärdatei. " +
                "Der Prozess wird nicht beendet."
            )
            return
        }

        Stop-Process -Id $ProcessId -Force -ErrorAction Stop
        Write-Host "$Role PID $ProcessId beendet."
    }
    catch {
        # Bereits beendete Prozesse sind kein Fehler.
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
    $metadataPath = Join-Path $directory.FullName 'session.json'

    if (-not (Test-Path -LiteralPath $metadataPath -PathType Leaf)) {
        Write-Warning "Sitzung ohne gültige Metadaten: $($directory.FullName)"
        if (-not $KeepArchives) {
            Remove-Item -LiteralPath $directory.FullName -Recurse -Force -ErrorAction SilentlyContinue
        }
        continue
    }

    try {
        $session = Get-Content -LiteralPath $metadataPath -Raw | ConvertFrom-Json
    }
    catch {
        Write-Warning "Ungültige Sitzungsmetadaten: $metadataPath"
        continue
    }

    # Tunnel zuerst, danach Dateiserver.
    Stop-VerifiedProcess `
        -ProcessId ([int]$session.cloudflaredPid) `
        -ExpectedPath ([string]$session.cloudflaredPath) `
        -Role 'cloudflared'

    Start-Sleep -Milliseconds 300

    Stop-VerifiedProcess `
        -ProcessId ([int]$session.miniservePid) `
        -ExpectedPath ([string]$session.miniservePath) `
        -Role 'miniserve'

    if ($session.watchdogPid -gt 0) {
        try {
            Stop-Process -Id ([int]$session.watchdogPid) -Force -ErrorAction SilentlyContinue
        }
        catch {
        }
    }

    if (-not $KeepArchives) {
        Remove-Item -LiteralPath $directory.FullName -Recurse -Force -ErrorAction SilentlyContinue
        Write-Host "Sitzung entfernt: $($directory.FullName)"
    }
    else {
        Write-Host "Sitzung beendet; Dateien behalten: $($directory.FullName)"
    }
}

exit 0

```

## 11.4 `tests/Test-WorkspaceShare.ps1`

```powershell
#requires -Version 5.1
<#
.SYNOPSIS
    Standalone-Abnahmetests für WorkspaceShare.

.DESCRIPTION
    Ohne -PublicUrl werden lokale miniserve-Gates geprüft.
    Mit -PublicUrl werden zusätzlich öffentliche HTTP-/Range-/Cache-Gates geprüft.

.EXAMPLE
    .\Test-WorkspaceShare.ps1

.EXAMPLE
    .\Test-WorkspaceShare.ps1 -PublicUrl "https://...trycloudflare.com/d/TOKEN/"
#>

[CmdletBinding()]
param(
    [string]$ToolRoot = (Split-Path $PSScriptRoot -Parent),
    [string]$PublicUrl
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$bin = Join-Path $ToolRoot 'bin'
$miniserve = Join-Path $bin 'miniserve.exe'
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
        Write-Error "[FAIL] $Message"
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

function Quote-Arg([string]$Value) {
    if ($Value -notmatch '[\s"]') { return $Value }
    return '"' + $Value.Replace('\','\\').Replace('"','\"') + '"'
}

function Curl-Status {
    param([string]$Url, [string[]]$Extra = @())

    $args = @('--silent','--show-error','--output','NUL','--write-out','%{http_code}','--max-time','10')
    $args += $Extra
    $args += $Url

    $output = & $curl @args 2>$null
    if ($LASTEXITCODE -ne 0 -and -not $output) { return 0 }
    return [int](($output | Select-Object -Last 1) | Out-String).Trim()
}

function Wait-Ready([string]$Url) {
    $deadline = [DateTime]::UtcNow.AddSeconds(15)
    do {
        if ((Curl-Status $Url @('--head')) -eq 200) { return $true }
        Start-Sleep -Milliseconds 300
    } while ([DateTime]::UtcNow -lt $deadline)
    return $false
}

try {
    New-Item -ItemType Directory -Path $temp -Force | Out-Null

    Assert-True (Test-Path -LiteralPath $miniserve) 'miniserve.exe vorhanden'
    Assert-True ([bool]$curl) 'curl.exe vorhanden'

    # Mehrere MiB, damit Range-/Resume-Tests sinnvoll sind.
    $sample = Join-Path $temp 'sample.zip'
    $bytes = New-Object byte[] (5MB)
    $rng = [Security.Cryptography.RandomNumberGenerator]::Create()
    try { $rng.GetBytes($bytes) } finally { $rng.Dispose() }
    [IO.File]::WriteAllBytes($sample, $bytes)
    $originalHash = (Get-FileHash $sample -Algorithm SHA256).Hash

    $token = New-Token
    $port = Get-Port
    $localUrl = "http://127.0.0.1:$port/d/$token/"

    $psi = New-Object Diagnostics.ProcessStartInfo
    $psi.FileName = $miniserve
    $args = @(
        '--quiet',
        '--interfaces','127.0.0.1',
        '--port',"$port",
        '--header','Cache-Control: private, no-store',
        $sample
    )
    $psi.Arguments = (($args | ForEach-Object { Quote-Arg $_ }) -join ' ')
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.EnvironmentVariables['MINISERVE_ROUTE_PREFIX'] = "d/$token"

    $server = New-Object Diagnostics.Process
    $server.StartInfo = $psi
    [void]$server.Start()

    Assert-True (Wait-Ready $localUrl) 'Geheimroute liefert lokal HTTP 200'
    Assert-True ((Curl-Status "http://127.0.0.1:$port/" @('--head')) -ne 200) 'Root ohne Token liefert nicht 200'
    Assert-True ((Curl-Status "http://127.0.0.1:$port/d/$(New-Token)/" @('--head')) -ne 200) 'Falsches Token liefert nicht 200'

    $rangeFile = Join-Path $temp 'range.bin'
    $rangeStatus = & $curl @(
        '--silent','--show-error',
        '--header','Range: bytes=0-1023',
        '--output',$rangeFile,
        '--write-out','%{http_code}',
        $localUrl
    ) 2>$null
    Assert-True (((($rangeStatus | Select-Object -Last 1) | Out-String).Trim()) -eq '206') 'Range liefert HTTP 206'
    Assert-True ((Get-Item $rangeFile).Length -eq 1024) 'Range liefert exakt 1024 Bytes'

    # Resume: erste 1 MiB, danach mit curl -C - fortsetzen.
    $resume = Join-Path $temp 'resume.zip'
    & $curl @(
        '--silent','--show-error',
        '--header','Range: bytes=0-1048575',
        '--output',$resume,
        $localUrl
    ) | Out-Null

    & $curl @(
        '--silent','--show-error',
        '--continue-at','-',
        '--output',$resume,
        $localUrl
    ) | Out-Null

    Assert-True ((Get-FileHash $resume -Algorithm SHA256).Hash -eq $originalHash) 'Abgebrochener Download kann korrekt fortgesetzt werden'

    # Mutation probes: Statuscode ist zweitrangig; Datei darf sich nie ändern.
    foreach ($method in @('POST','PUT','PATCH','DELETE')) {
        & $curl @(
            '--silent','--show-error',
            '--request',$method,
            '--data-binary','mutation-test',
            '--output','NUL',
            $localUrl
        ) 2>$null | Out-Null
    }

    Assert-True ((Get-FileHash $sample -Algorithm SHA256).Hash -eq $originalHash) 'Schreibmethoden verändern die Datei nicht'

    if ($PublicUrl) {
        Assert-True ((Curl-Status $PublicUrl @('--head')) -eq 200) 'Öffentliche Geheimroute liefert 200'

        $publicRange = Join-Path $temp 'public-range.bin'
        $publicStatus = & $curl @(
            '--silent','--show-error',
            '--header','Range: bytes=0-1023',
            '--output',$publicRange,
            '--write-out','%{http_code}',
            $PublicUrl
        ) 2>$null

        Assert-True (((($publicStatus | Select-Object -Last 1) | Out-String).Trim()) -eq '206') 'Öffentliche Range liefert 206'
        Assert-True ((Get-Item $publicRange).Length -eq 1024) 'Öffentliche Range liefert 1024 Bytes'

        $headers = Join-Path $temp 'public-headers.txt'
        & $curl @('--silent','--head','--dump-header',$headers,'--output','NUL',$PublicUrl) | Out-Null
        $headerText = Get-Content $headers -Raw
        Assert-True ($headerText -match '(?im)^cache-control:.*no-store') 'Öffentliches Cache-Control enthält no-store'
        Assert-True ($headerText -notmatch '(?im)^cf-cache-status:\s*HIT\s*$') 'Cloudflare meldet keinen Cache-HIT'
    }
}
finally {
    if ($server) {
        try { Stop-Process -Id $server.Id -Force -ErrorAction SilentlyContinue } catch {}
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

```

## 11.5 `Install-Dependencies.ps1`

```powershell
#requires -Version 5.1
<#
.SYNOPSIS
    Schnelle Entwicklungsinstallation der externen Werkzeuge über WinGet.

.DESCRIPTION
    Für eine reproduzierbare interne Auslieferung ist danach trotzdem der portable
    bin\-Ordner mit geprüften SHA-256-Werten zu erstellen. WinGet ist primär der
    schnellste Weg für den Entwicklungsrechner.
#>

[CmdletBinding()]
param(
    [switch]$SkipGitleaks
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (-not (Get-Command winget.exe -ErrorAction SilentlyContinue)) {
    throw 'winget.exe wurde nicht gefunden. App Installer über Microsoft Store aktualisieren.'
}

$common = @(
    '--exact',
    '--accept-package-agreements',
    '--accept-source-agreements',
    '--disable-interactivity'
)

$packages = @(
    'Cloudflare.cloudflared',
    'svenstaro.miniserve',
    '7zip.7zip'
)

if (-not $SkipGitleaks) {
    $packages += 'Gitleaks.Gitleaks'
}

foreach ($package in $packages) {
    Write-Host "Installiere/aktualisiere $package ..."
    & winget.exe install --id $package @common

    if ($LASTEXITCODE -ne 0) {
        Write-Warning (
            "WinGet meldete für $package Exit $LASTEXITCODE. " +
            "Prüfe mit: winget list --id $package"
        )
    }
}

Write-Host ''
Write-Host 'Werkzeuge wurden über WinGet angefordert.'
Write-Host 'Als nächstes: exakte EXE-Dateien in .\bin kopieren und Checksummen sperren.'

```

## 11.6 `config/mandatory-excludes.txt`

```text
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

```

## 11.7 `config/generated-excludes.txt`

```text
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

```

## 11.8 `config/gitleaks-workspaceshare.toml`

```toml
# WorkspaceShare: Gitleaks-Konfiguration
# Verwendet die vollständigen eingebauten Regeln und reduziert typische
# Treffer in rekonstruierbaren Verzeichnissen.

[extend]
useDefault = true

[[allowlists]]
description = "WorkspaceShare: rekonstruierbare Drittanbieter- und Build-Verzeichnisse"
paths = [
  '''(?i)(^|[\\/])node_modules([\\/]|$)''',
  '''(?i)(^|[\\/])Library([\\/]|$)''',
  '''(?i)(^|[\\/])Temp([\\/]|$)''',
  '''(?i)(^|[\\/])obj([\\/]|$)''',
  '''(?i)(^|[\\/])dist([\\/]|$)''',
  '''(?i)(^|[\\/])build([\\/]|$)''',
  '''(?i)(^|[\\/])coverage([\\/]|$)''',
  '''(?i)(^|[\\/])\.gradle([\\/]|$)'''
]

```

## 11.9 `dependencies.lock.json`

```json
{
  "schema": 1,
  "generatedUtc": "FILL_AFTER_TRUSTED_DOWNLOAD",
  "platform": "windows-x64",
  "dependencies": [
    {
      "name": "cloudflared",
      "file": "bin/cloudflared.exe",
      "version": "PIN_TESTED_VERSION",
      "sha256": "FILL_SHA256",
      "license": "Apache-2.0",
      "source": "https://github.com/cloudflare/cloudflared/releases"
    },
    {
      "name": "miniserve",
      "file": "bin/miniserve.exe",
      "version": "0.35.0",
      "sha256": "FILL_SHA256",
      "license": "MIT",
      "source": "https://github.com/svenstaro/miniserve/releases"
    },
    {
      "name": "7-Zip standalone console",
      "file": "bin/7za.exe",
      "version": "26.02",
      "sha256": "FILL_SHA256",
      "license": "LGPL-2.1-or-later plus bundled notices/exceptions",
      "source": "https://www.7-zip.org/download.html"
    },
    {
      "name": "Gitleaks",
      "file": "bin/gitleaks.exe",
      "version": "8.30.1",
      "sha256": "FILL_SHA256",
      "license": "MIT",
      "source": "https://github.com/gitleaks/gitleaks/releases"
    }
  ]
}

```

## 11.10 `THIRD_PARTY_NOTICES.md`

```markdown
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

```

## 11.11 `README.md`

```markdown
# WorkspaceShare

WorkspaceShare stellt einen bereinigten Snapshot eines lokalen Workspace-Ordners
für kurze Zeit über genau einen geheimen HTTPS-Link bereit.

## Eigenschaften

- read-only / send-only;
- kein Login;
- kein Cloudflare-Konto;
- keine Router-Portfreigabe;
- kein Upload und keine Dateibearbeitung;
- automatische Abschaltung;
- temporäres ZIP wird standardmäßig gelöscht.

## Schnellstart

```powershell
Set-ExecutionPolicy -Scope Process Bypass

.\Share-Workspace.ps1 `
  -Path "D:\Projekte\MeinWorkspace" `
  -Hours 4
```

Der fertige Link wird angezeigt und in die Zwischenablage kopiert.

## Vorzeitig beenden

Im aktiven Fenster:

```text
Strg+C
```

Notfall:

```powershell
.\Stop-WorkspaceShare.ps1
```

## Wichtige Regel

Jeder, der den vollständigen Link besitzt, kann den Snapshot während seiner
Gültigkeit herunterladen und dauerhaft behalten. Der Link ist deshalb wie ein
temporäres Passwort zu behandeln.

## Ausführliche Spezifikation

Siehe `_internetKonzept3.md`.

```

---

# 12. Zusätzliche Implementierungshinweise

## 12.1 Warum der Token nicht als CLI-Argument übergeben wird

Windows-Prozesskommandozeilen sind für andere Prozesse desselben Nutzers und
Administratoren sichtbar. Deshalb:

```text
MINISERVE_ROUTE_PREFIX=d/<TOKEN>
```

als Kindprozess-Umgebungsvariable.

Das eliminiert nicht jede lokale Sichtbarkeit, reduziert aber zufällige Leaks in:

- Task-Manager-Details;
- Prozessinventaren;
- Diagnoseausgaben;
- Copy/Paste von Kommandos.

## 12.2 Warum keine URL in session.json steht

Das Stop-Skript braucht nur:

- PIDs;
- erwartete EXE-Pfade;
- Sessionpfad;
- Ablaufzeit.

Die URL wäre ein unnötiges persistentes Secret.

## 12.3 Warum externe Logs lokal bleiben

cloudflared schreibt seine Startinformationen in temporäre Logs. Diese Logs
können die öffentliche Subdomain enthalten, jedoch nicht den zusätzlichen
Capability-Token. Sie liegen nur im Sessionordner und werden standardmäßig
gelöscht.

Debug-Logging darf nicht aktiviert werden.

## 12.4 Warum der Watchdog keine URL kennt

Der Watchdog benötigt nur Prozess- und Ablaufdaten. Ein kleiner kompromittierter
Hilfsprozess soll nicht automatisch Zugriff auf den Share-Link erhalten.

## 12.5 Race Conditions

### Freier Port

Zwischen Portermittlung und miniserve-Bindung kann ein anderer Prozess den Port
belegen. Lösung: bis zu fünf vollständige Startversuche.

### PID-Wiederverwendung

Der Watchdog prüft nicht nur die Launcher-PID, sondern auch deren
Startzeit-Ticks.

### Doppelte Bereinigung

Launcher und Watchdog dürfen gleichzeitig Cleanup versuchen. Alle
Lösch-/Stop-Aktionen sind idempotent und `best effort`.

### Watchdog-Aktivierungszeitpunkt

Der Watchdog startet unmittelbar nachdem `cloudflared` als Prozess existiert,
also noch vor URL-Erkennung und öffentlichen Tests. Ein harter Launcher-Abbruch
in dieser Phase hinterlässt deshalb keinen öffentlichen Tunnel.

Zwischen dem Start des lokalen miniserve-Prozesses und dem Start von
`cloudflared` existiert nur ein sehr kurzes Fenster ohne Watchdog. In diesem
Fenster gibt es noch keinen öffentlichen Tunnel; miniserve bindet ausschließlich
an Loopback. Es entsteht daher keine externe Erreichbarkeit.

### Ablauf während Download

Ablauf bedeutet hartes Ende. Ein noch laufender Download kann abbrechen.
Die Laufzeit muss deshalb größer als die erwartete Snapshot- und Downloadzeit
gewählt werden.

---

# 13. Vollständiger Testkatalog

## 13.1 Dependency-Tests

| ID | Test | Erwartung |
|---|---|---|
| DEP-01 | EXE fehlt | Start vor Snapshot abgebrochen |
| DEP-02 | falscher Hash | Release-Gate rot |
| DEP-03 | unbekannte Version | Release-Gate rot |
| DEP-04 | Lizenzdatei fehlt | Release-Gate rot |
| DEP-05 | miniserve `--version` | erwartete Version |
| DEP-06 | cloudflared `--version` | erwartete Version |
| DEP-07 | Gitleaks `version` | erwartete Version |
| DEP-08 | 7za `i` | erwartete Version |

## 13.2 Dateisystem-Tests

| ID | Test | Erwartung |
|---|---|---|
| FS-01 | normaler Workspace | Snapshot |
| FS-02 | Unicodepfade | korrekt im ZIP |
| FS-03 | sehr lange Pfade | klarer Erfolg oder sicherer Abbruch |
| FS-04 | Leerzeichen | korrekt |
| FS-05 | Junction nach außen | Abbruch |
| FS-06 | Symlink | Abbruch |
| FS-07 | unlesbares Verzeichnis | Abbruch |
| FS-08 | Datei während Archivierung gesperrt | `-sse`, Abbruch |
| FS-09 | Laufwerksroot | Abbruch |
| FS-10 | Snapshotziel im Workspace | durch Architektur ausgeschlossen |
| FS-11 | wenig Speicher | Abbruch |
| FS-12 | `.git` als Ordner | ausgeschlossen |
| FS-13 | `.git` als Datei/Worktree-Hinweis | ausgeschlossen |
| FS-14 | versteckte Quelldatei | enthalten, sofern nicht ausgeschlossen |
| FS-15 | Datei > 2 GB | erfolgreich |
| FS-16 | Archiv > 4 GB | erfolgreich |

## 13.3 Secret-Tests

Fixtures:

```text
.env
private.pem
id_rsa
service-account-prod.json
Datei mit Test-AWS-Key
Datei mit GitHub-Testtoken
Datei mit Private-Key-Header
```

Erwartung:

- Dateinamen-Gate oder Gitleaks bricht ab;
- Bericht ist redigiert;
- kein Link wird erzeugt;
- kein Secret steht im Terminal;
- Beispiel-/Template-Dateien bleiben möglich.

## 13.4 Archivtests

- `7za t` Exit 0;
- Inhaltsmanifest vorhanden;
- `.git` nicht im Manifest;
- generierte Verzeichnisse standardmäßig nicht im Manifest;
- Projektdateien vollständig;
- Hash vor und nach HTTP-Methodenprobes gleich;
- Downloadhash identisch;
- Entpacken auf Testziel erfolgreich.

## 13.5 HTTP-Negativtests

Anfragen:

```text
/
 /favicon.ico
 /robots.txt
 /d/
 /d/FALSCH/
 /d/<TOKEN>/extra
 URL-encoded Traversal
 doppelte Slashes
 Query-Parameter
```

Ohne korrektes Token darf keine Route erfolgreich sein. Mit korrektem Token
dürfen neben der einzelnen Snapshot-Datei nur miniserve-interne, read-only
Support-Routen antworten; sie dürfen weder Workspace-Inhalte auflisten noch
Schreibvorgänge ermöglichen.

## 13.6 Schreibprobes

Methoden:

```text
POST
PUT
PATCH
DELETE
PROPFIND
MKCOL
MOVE
COPY
```

Pflichtaussage:

- kein Original-Workspace wird berührt;
- Snapshot-Hash bleibt identisch;
- keine neue Datei entsteht;
- kein Upload-Verzeichnis entsteht.

Es ist nicht zwingend erforderlich, dass jede Methode `405` liefert. Zwingend ist
die nachgewiesene Unveränderlichkeit.

## 13.7 Range-Tests

- `bytes=0-1023`;
- `bytes=1024-`;
- Suffix-Range;
- ungültige Range;
- Abbruch nach 30 %;
- Fortsetzung mit `curl -C -`;
- parallele zwei Downloads;
- Hash identisch.

## 13.8 Tunneltests

- normal;
- Internet kurz getrennt;
- UDP blockiert;
- Proxy/VPN aktiv;
- Cloudflare-Konfigurationsdatei vorhanden;
- Tunnelprozess beendet;
- 60-Sekunden-Timeout;
- öffentliche Root-Negativprüfung;
- falscher Token;
- Cache-Header;
- kein Cache-HIT.

## 13.9 Lifecycle-/Chaos-Tests

1. Launcher normal ablaufen lassen.
2. `Strg+C`.
3. Launcher per Task Manager beenden.
4. miniserve beenden.
5. cloudflared beenden.
6. Watchdog beenden.
7. Rechner abmelden.
8. Rechner neu starten.
9. Energiesparmodus provozieren.
10. Festplatte während Snapshot fast füllen.
11. Snapshotdatei lokal löschen.
12. Sessionordner schreibschützen.

Jeder Fehler muss entweder:

- sicher aufräumen;
- oder die öffentliche Auslieferung unmöglich machen.

## 13.10 LAN-Test

Von einem zweiten Gerät im selben Netzwerk:

```text
http://<LAN-IP-DES-RECHNERS>:<PORT>/
```

Erwartung: keine Verbindung, da miniserve nur an `127.0.0.1` bindet.

## 13.11 10-GB-Testprotokoll

Aufzeichnen:

```text
Workspacegröße:
Dateizahl:
Archivgröße:
Snapshotdauer:
Gitleaksdauer:
Uploadrate:
Volldownloaddauer:
Resume-Punkt:
Hash lokal:
Hash remote:
Ablaufzeit:
Cleanup-Ergebnis:
Windows-Version:
Toolversionen:
```

---

# 14. Performance

## 14.1 Erwartete Engpässe

1. lokale Dateianzahl;
2. Gitleaks-Scan;
3. ZIP-Kompression;
4. lokaler Datenträger;
5. Internet-Upload;
6. Empfänger-Download.

## 14.2 Empfohlene Kompression

Standard:

```text
ZIP, -mx=1, Multithreading
```

Für bereits komprimierte Assets:

```powershell
-Compression Store
```

Das spart lokale Zeit, erhöht aber Transfergröße.

## 14.3 Uploaddauer für 10 GB

Idealisierte Größenordnung:

| Upload | Mindestdauer für 10 GB |
|---:|---:|
| 5 Mbit/s | ca. 4 h 27 min |
| 10 Mbit/s | ca. 2 h 13 min |
| 20 Mbit/s | ca. 1 h 7 min |
| 50 Mbit/s | ca. 27 min |
| 100 Mbit/s | ca. 13 min |

Planungsreserve: mindestens 25 %, bei instabilen Leitungen mehr.

## 14.4 Laufzeitregel

Empfehlung:

```text
Freigabedauer >= Snapshotzeit + erwartete Downloaddauer × 1,5
```

Die Referenzimplementierung speichert zunächst nur die gewünschte Dauer. Die
konkrete Ablaufzeit wird unmittelbar vor dem Start des Cloudflare-Tunnels
berechnet. Secret-Scan, Archivierung und Integritätsprüfung verbrauchen daher
keine Freigabezeit.

## 14.5 Token- und Entwicklungsökonomie

Die Architektur spart gegenüber Version 2:

- vollständige Python-Serverentwicklung;
- HTTP-/Range-Unit-Tests auf Protokollebene;
- eigene ZIP-Implementierung;
- eigene Secret-Regelpflege;
- Python-Installation;
- mehrsprachige Runtime-Probleme;
- größere Wartungsfläche.

Voraussichtlich besteht die eigentliche Implementierung überwiegend aus:

- Dateien aus diesem Dokument übernehmen;
- Binärdateien beschaffen;
- Pfade/Argumente auf Testrechner korrigieren;
- Gates automatisieren;
- 10-GB-Test;
- kleine Bugfixes.

---

# 15. Betrieb

## 15.1 Normaler Start

```powershell
Set-Location C:\Tools\WorkspaceShare

.\Share-Workspace.ps1 `
  -Path "D:\Projekte\RoswellWorkspace" `
  -Hours 4
```

## 15.2 Kurzer Test

```powershell
.\Share-Workspace.ps1 `
  -Path "D:\Projekte\TestWorkspace" `
  -Minutes 10 `
  -KeepArchive
```

## 15.3 Generierte Inhalte bewusst einbeziehen

```powershell
.\Share-Workspace.ps1 `
  -Path "D:\Projekte\RoswellWorkspace" `
  -Hours 6 `
  -IncludeGenerated
```

## 15.4 Secret-Scan bewusst überspringen

Nur in kontrollierten Tests:

```powershell
.\Share-Workspace.ps1 `
  -Path "D:\Projekte\TestFixture" `
  -Minutes 5 `
  -SkipSecretScan
```

Für reale Quellcodefreigaben nicht empfohlen.

## 15.5 Vorzeitiges Ende

```text
Strg+C
```

Notfall:

```powershell
.\Stop-WorkspaceShare.ps1
```

## 15.6 Empfängerseite

Browser:

```text
Link öffnen
```

PowerShell/curl:

```powershell
curl.exe -L -o workspace.zip "<LINK>"
```

Fortsetzen:

```powershell
curl.exe -L -C - -o workspace.zip "<LINK>"
```

Hash prüfen:

```powershell
Get-FileHash .\workspace.zip -Algorithm SHA256
```

---

# 16. Zugriff durch ChatGPT und vergleichbare Dienste

## 16.1 Allgemeine Dienste

Ein externer Service kann den Link vollständig verwenden, wenn er:

- ausgehendes HTTPS zu `trycloudflare.com` erlaubt;
- Weiterleitungen und große Responses unterstützt;
- lange genug laufende Downloads erlaubt;
- Range-Requests unterstützt oder nicht benötigt;
- den Link nicht durch Sicherheitsfilter entfernt;
- eine 10-GB-Datei verarbeiten kann.

Ein normaler Browser, `curl`, `wget` oder eigener Serverprozess erfüllt dies
grundsätzlich.

## 16.2 ChatGPT speziell

Ein beliebiger 10-GB-Link ist **kein verlässlicher universeller
ChatGPT-Dateiimport**. ChatGPT-Dateiuploads besitzen eine feste
Einzeldateigrenze von 512 MB. Außerdem kann die Fähigkeit, einen beliebigen
externen Downloadlink abzurufen, je nach Modus, App, Netzwerkwerkzeug und
Sicherheitsrichtlinie variieren.

Daher kann dieses Tool beweisen:

- Der HTTP-Link ist extern erreichbar.
- Standardclients können vollständig herunterladen.
- Ein vergleichbarer Dienst mit normalen HTTPS-Downloads kann ihn nutzen.

Es kann nicht garantieren:

- dass jede ChatGPT-Oberfläche 10 GB direkt importiert;
- dass ein Modell den gesamten Inhalt gleichzeitig kontextuell verarbeitet;
- dass ein fremder Dienst `trycloudflare.com` zulässt.

## 16.3 Für ChatGPT theoretisch bessere Varianten

### Variante A – private GitHub-Verbindung

Für ChatGPT ist die offizielle GitHub-App oft besser geeignet:

- privates Repository bleibt privat;
- ChatGPT liest autorisierte Codeausschnitte;
- kein 10-GB-Einzelupload;
- read-only Analyse;
- gezielte Suche statt vollständigem Kontextdump.

### Variante B – AI-Bundle

Zusätzlicher optionaler Export:

```text
ai-bundle.zip
```

Enthält nur:

- Quellcode;
- relevante Konfiguration;
- Dokumentation;
- keine Builds;
- keine Rohassets;
- keine großen Binärdateien.

Ziel: deutlich unter 512 MB.

### Variante C – Chunk-Manifest

```text
manifest.json
part-001.zip
part-002.zip
...
```

Jeder Teil unter Clientlimit. Dies verletzt jedoch das Ein-Link-Minimalziel und
wird deshalb nicht in Version 3 eingebaut.

## 16.4 Bestätigung des Flows

Die korrekte Bestätigung erfolgt zweistufig:

1. **Protokollprüfung:** externer neutraler Rechner lädt den Link vollständig,
   setzt einen Download fort und bestätigt SHA-256.
2. **Zieldienstprüfung:** der konkrete Service wird mit einer kleinen Testdatei
   und anschließend mit einer realistischen Datei getestet.

Diese Prüfung ist belastbarer als die Annahme, dass „jeder KI-Dienst“ identische
Netzwerk- und Uploadregeln besitzt.

---

# 17. Fehlerdiagnose

## `cloudflared` liefert keine URL

Prüfen:

- Internet;
- `.cloudflared\config.yml`;
- VPN/Proxy;
- Firewall;
- aktuelle unterstützte cloudflared-Version;
- Cloudflare-Störung;
- Logdateien im Sessionordner.

## Geheimlink liefert 404

- miniserve noch aktiv?
- Token vollständig kopiert?
- abschließender Slash erhalten?
- Tunnel schon bereit?
- Laufzeit abgelaufen?

## Download bricht ab

- Rechner schläft;
- Upload instabil;
- Freigabezeit abgelaufen;
- Tunnelprozess beendet;
- VPN-Wechsel;
- Empfänger nutzt keinen Resume-fähigen Client.

Lösung:

```powershell
curl.exe -L -C - -o workspace.zip "<LINK>"
```

## Gitleaks False Positive

Nicht sofort `-SkipSecretScan` als Dauerlösung verwenden.

Vorgehen:

1. Fund prüfen;
2. echtes Secret rotieren/entfernen;
3. Testwert in eine eng begrenzte Gitleaks-Allowlist aufnehmen;
4. Allowlist reviewen;
5. Regressionstest hinzufügen.

## ZIP zu groß

- Generated Excludes prüfen;
- Rohassets projektspezifisch ausschließen;
- `-Compression Fast`;
- optional separaten AI-Bundle-Modus planen;
- nicht heimlich Dateien entfernen, die der Empfänger benötigt.

---

# 18. Wartung

## Monatlich

- keine Pflicht, sofern Tool nicht genutzt wird.

## Vor jedem internen Release

- Versionen prüfen;
- Release Notes lesen;
- Checksummen aktualisieren;
- lokale Tests;
- Tunneltests;
- Lizenzdateien kontrollieren.

## Vierteljährlich

- Quick-Tunnel-Dokumentation prüfen;
- miniserve-Sicherheitsmeldungen prüfen;
- Gitleaks-Regeln/Release prüfen;
- 7-Zip aktualisieren;
- cloudflared aktualisieren;
- 10-GB-Smoke-Test, falls Tool geschäftskritisch ist.

## Bei Abhängigkeitsupdate

Nie alle vier Werkzeuge gleichzeitig aktualisieren.

Reihenfolge:

1. neue Binärdatei isoliert;
2. Checksumme;
3. Komponententest;
4. vollständige Gates;
5. Lockfile;
6. Lizenznotices;
7. interne Freigabe.

Rollback: vorherigen kompletten `bin`-Ordner behalten.

---

# 19. Migration von Version 2 auf Version 3

| Version-2-Baustein | Version 3 |
|---|---|
| eigener Python-HTTP-Server | miniserve |
| eigener Range-Code | miniserve/Actix |
| eigener ZIP-Builder | 7za.exe |
| Python-Runtime | entfällt |
| eigenes Secret-Regex-System | Gitleaks + kleines Dateinamen-Gate |
| mehrere Roots | MVP bewusst ein Root |
| komplexe Server-Headerlogik | miniserve-Header |
| eigener Parent-PID-Servercheck | separater PowerShell-Watchdog |
| Upload-/WebDAV-Diskussion | vollständig aus Scope entfernt |
| striktes 405-Ziel | unveränderlicher Hash als maßgebliches Gate |

Keine wichtige Schutzidee geht verloren:

- Loopback;
- geheimer Pfad;
- 256 Bit;
- no-store;
- Range;
- Ablauf;
- Watchdog;
- Secret-Prüfung;
- ZIP64;
- Hash;
- 10-GB-Test;
- keine Dashboard-Einrichtung.

---

# 20. Definition of Done

## Funktion

- [ ] ein Befehl;
- [ ] ein Link;
- [ ] keine Anmeldung;
- [ ] keine Cloudflare-Konfiguration;
- [ ] read-only;
- [ ] Download/Resume;
- [ ] automatische Abschaltung.

## Sicherheit

- [ ] 256-Bit-Token;
- [ ] Token nicht im CLI;
- [ ] Token nicht in session.json;
- [ ] Loopback-only;
- [ ] Root und falscher Token blockiert;
- [ ] keine Write-Flags;
- [ ] Hash unverändert;
- [ ] Secret-Gates;
- [ ] no-store;
- [ ] kein Cache-HIT;
- [ ] Watchdog;
- [ ] Cleanup.

## Qualität

- [ ] PowerShell 5.1;
- [ ] Windows 10;
- [ ] Windows 11;
- [ ] 10-GB-Test;
- [ ] Resume-Hash;
- [ ] Lizenznotices;
- [ ] Dependency-Lock;
- [ ] reproduzierbare Binärdateien;
- [ ] verständliche Fehlermeldungen;
- [ ] keine offenen Entscheidungen.

---

# 21. Quellen und Versionsstand der Recherche

Recherchezeitpunkt: 30.07.2026.

## Cloudflare Quick Tunnels

- Cloudflare-Dokumentation „Quick Tunnels“
- kostenloser Startbefehl;
- kein Konto für Quick Tunnel;
- zufällige `trycloudflare.com`-Subdomain;
- Test-/Entwicklungszweck;
- keine SLA;
- 200 gleichzeitig laufende Requests;
- kein SSE.

```text
https://developers.cloudflare.com/cloudflare-one/networks/connectors/cloudflare-tunnel/do-more-with-tunnels/trycloudflare/
```

## miniserve

- Version 0.35.0 zum Recherchezeitpunkt;
- einzelne Datei;
- Range-Requests;
- eigene Header;
- Route Prefix;
- Loopback-Binding;
- MIT.

```text
https://github.com/svenstaro/miniserve
https://docs.rs/crate/miniserve/latest/source/README.md
```

## Gitleaks

- Version 8.30.1 zum Recherchezeitpunkt;
- `dir`-Scan;
- Default-Regeln;
- Report/Redaction;
- MIT;
- Projekt bezeichnet sich als feature complete, Sicherheitswartung bleibt.

```text
https://github.com/gitleaks/gitleaks
https://github.com/gitleaks/gitleaks/releases
```

## 7-Zip

- Version 26.02 vom 25.06.2026 zum Recherchezeitpunkt;
- Standalone Console verfügbar;
- kommerzielle Nutzung unter Einhaltung der Lizenzbedingungen möglich;
- Dokumentations-/Quellcodehinweise beachten.

```text
https://www.7-zip.org/download.html
https://www.7-zip.org/faq.html
```

## PowerShell Compress-Archive

- einzelne Dateien maximal 2 GB;
- versteckte Dateien/Ordner können ignoriert werden.

```text
https://learn.microsoft.com/powershell/module/microsoft.powershell.archive/compress-archive
```

## Git-Dateiliste

```text
https://git-scm.com/docs/git-ls-files
```

## ChatGPT

- GitHub-App kann autorisierte Repository-Inhalte lesen und analysieren;
- Dateiuploads: 512 MB harte Grenze pro Datei zum Recherchezeitpunkt.

```text
https://help.openai.com/de-de/articles/11145903-connecting-github-to-chatgpt
https://help.openai.com/de-de/articles/8555545-faq-zu-datei-uploads
```

---

# 22. Schlussentscheidung

Die beste Lösung ist nicht mehr „kleinen eigenen Server schreiben“, sondern:

```text
PowerShell-Orchestrator
+ 7-Zip
+ Gitleaks
+ miniserve
+ cloudflared Quick Tunnel
```

Das erreicht das Ziel mit der geringsten sinnvollen Eigenentwicklung und nutzt
vorhandene, frei lizenzierte Arbeit genau dort, wo eigene Implementierungen
besonders fehleranfällig wären.

Der Flow ist realistisch, testbar und intern sehr effizient:

```text
Workspace wählen
→ Sicherheitsprüfung
→ Snapshot
→ Link
→ read-only Download
→ automatische Abschaltung
```

**Freigabeempfehlung:** Implementieren, Pflicht-Gates ausführen, realen
10-GB-End-to-End-Test bestehen lassen und erst danach intern verwenden.

---

**Ende von `_internetKonzept3.md`**
