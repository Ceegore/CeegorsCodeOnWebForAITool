# Binärdateien

Dieser Ordner wird absichtlich ohne ausführbare Drittanbieterdateien ausgeliefert.

Führe im Projektroot aus:

```powershell
.\Install-Dependencies.ps1
```

Das Skript lädt die fest gepinnten offiziellen Release-Assets, prüft deren SHA-256-Werte und Versionen und erzeugt anschließend `dependencies.lock.json` aus den tatsächlich installierten EXE-Dateien. Ein Share-Vorgang ist ohne gültigen Lock nicht möglich.
