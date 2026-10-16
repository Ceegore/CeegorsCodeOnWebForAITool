# Third-Party Notices

WorkspaceShare ruft die folgenden unveränderten externen Programme als getrennte
Prozesse auf. Es werden keine Quelltexte dieser Projekte in WorkspaceShare
hineinkopiert und keine veränderten Binärdateien verteilt.

## miniserve

- Projekt: svenstaro/miniserve
- Version: 0.35.0
- Lizenz: MIT
- Verwendung: read-only Auslieferung genau einer Snapshot-Datei über HTTP
- Quelle: https://github.com/svenstaro/miniserve
- Mitzuliefern: vollständige MIT-Lizenz aus der verwendeten Version

## cloudflared

- Projekt: cloudflare/cloudflared
- Version: 2026.7.2
- Lizenz: Apache License 2.0
- Verwendung: ausgehender Cloudflare Quick Tunnel
- Quelle: https://github.com/cloudflare/cloudflared
- Mitzuliefern: LICENSE (das Installationsskript legt die Upstream-LICENSE unter `bin\licenses\` ab)

## 7-Zip / 7za.exe

- Projekt: 7-Zip
- Version: 26.02
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
- Version: 8.30.1
- Lizenz: MIT
- Verwendung: optionale, standardmäßig aktive Secret-Prüfung
- Quelle: https://github.com/gitleaks/gitleaks
- Mitzuliefern: vollständige MIT-Lizenz aus der verwendeten Version

## Keine Rechtsberatung

Diese Datei ist eine technische Compliance-Checkliste und keine Rechtsberatung.
Vor externer kommerzieller Weitergabe sollte die konkrete Binärdistribution samt
Lizenzdateien geprüft werden.
