# WorkspaceShare

Teilt einen Ordner oder ein paar Dateien für eine Weile über einen geheimen Link – z. B. um Code in einen KI-Webchat zu geben, ohne ihn auf GitHub zu stellen. Der Empfänger bekommt ein ZIP, mehr nicht. Kein Konto, keine Portfreigabe.

## Windows

1. ZIP von den [Releases](https://github.com/Ceegore/CeegorsCodeOnWebForAITool/releases/latest) laden und entpacken
   (meckert Windows später: vor dem Entpacken Rechtsklick auf die ZIP → Eigenschaften → „Zulassen“).
2. Im entpackten Ordner einmalig:

   ```powershell
   powershell -NoProfile -File .\Install-GuiShortcut.ps1
   ```

3. Desktop-Verknüpfung **WorkspaceShare** öffnen → Dateien reinziehen oder Ordner wählen → **Freigeben** → Link kopieren.

## Linux (experimentell)

```bash
git clone https://github.com/Ceegore/CeegorsCodeOnWebForAITool.git && cd CeegorsCodeOnWebForAITool
pwsh ./Install-Dependencies.ps1 && pwsh ./Start-WorkspaceShareGui.ps1
```

Braucht PowerShell 7 (`pwsh`).

## Gut zu wissen

- Wer den Link hat, kann die Datei laden. Nur an die richtigen Leute geben.
- Geteilt wird eine geprüfte ZIP-Kopie, nie der Originalordner. `.env`, Schlüsseldateien und Ordner wie `.ssh`/`.aws` kommen nicht mit.
- Mehrere Freigaben gleichzeitig gehen, jede in einem eigenen Tab. Die Freigabe endet von selbst nach der gewählten Zeit.

Alles Weitere (Kommandozeile, Parameter, Sicherheitsdetails, Tests): [docs/DETAILS.md](docs/DETAILS.md)
