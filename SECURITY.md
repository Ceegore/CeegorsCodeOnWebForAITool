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
