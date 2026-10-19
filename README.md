# WorkspaceShare

Teilt einen Ordner oder ein paar Dateien für eine Weile über einen geheimen Link – z. B. um Code in einen KI-Webchat zu geben, ohne ihn auf GitHub zu stellen. Der Empfänger bekommt ein ZIP, mehr nicht. Kein Konto, keine Portfreigabe.

## Windows

1. `WorkspaceShare-<Version>.zip` von den [Releases](https://github.com/Ceegore/CeegorsCodeOnWebForAITool/releases/latest) laden und entpacken.
2. PowerShell im entpackten Ordner öffnen und einmalig:

   ```powershell
   Get-ChildItem -Recurse | Unblock-File; powershell -NoProfile -File .\Install-GuiShortcut.ps1
   ```

   (Der erste Teil nimmt Windows' „aus dem Internet“-Markierung von diesem Ordner, sonst blockt PowerShell die Skripte.)
3. Desktop-Verknüpfung **WorkspaceShare** öffnen → Dateien reinziehen oder Ordner wählen → **Freigeben** → Link kopieren.

## Linux (experimentell)

`WorkspaceShare-<Version>-linux-x64.tar.gz` von den [Releases](https://github.com/Ceegore/CeegorsCodeOnWebForAITool/releases/latest) laden (enthält die geprüften Programme), dann:

```bash
tar -xzf WorkspaceShare-*-linux-x64.tar.gz && cd WorkspaceShare
pwsh ./Install-GuiShortcut.ps1   # optional: Menüeintrag
pwsh ./Start-WorkspaceShareGui.ps1
```

Oder aus dem Quellcode: `git clone` dieses Repos, dann `pwsh ./Install-Dependencies.ps1 && pwsh ./Start-WorkspaceShareGui.ps1`. Braucht PowerShell 7 (`pwsh`).

## Gut zu wissen

- Mehrere Freigaben gleichzeitig gehen, jede in einem eigenen Tab.
- Eine Freigabe endet von selbst nach der gewählten Zeit – oder per Klick.

Alles Weitere (Kommandozeile, Parameter, Tests): [docs/DETAILS.md](docs/DETAILS.md)

## Sicherheit

Es wird nicht einfach ein Ordner ins Netz gehängt: Das Tool baut eine Kopie, wirft `.env`, Schlüsseldateien und Ordner wie `.ssh`/`.aws` raus, scannt den Rest nach Passwörtern und Tokens (gitleaks) und hält bei Funden an. Die GUI zeigt dann kurz, welche Datei, Zeile und Regel betroffen ist (das Geheimnis selbst geschwärzt); Fehlalarme lassen sich nach ausdrücklicher Bestätigung trotzdem freigeben – nur genau die gesehenen Funde. Geteilt wird nur dieses eine geprüfte ZIP, nur lesend, hinter einem zufälligen 256-Bit-Link, der mit der Freigabe verfällt. Wer den Link hat, kann das ZIP laden – also nur an die richtigen Leute geben.
