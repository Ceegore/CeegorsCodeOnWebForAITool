#requires -Version 5.1
# OS-specific helpers for the WorkspaceShare GUI. The only GUI file allowed to touch
# System.Windows.Forms, LOCALAPPDATA, explorer/Start-Process etc. (GUI_CONTRACT section 3).
# Windows implementation is complete; Linux/macOS branches report "unsupported" for now.
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-WsPlatform {
    [CmdletBinding()]
    param()
    if ([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT) { return 'windows' }
    $mac = Get-Variable -Name IsMacOS -ErrorAction SilentlyContinue
    if ($null -ne $mac -and [bool]$mac.Value) { return 'macos' }
    return 'linux'
}

function Test-WsSta {
    # Internal: WinForms dialogs and the clipboard need a single-threaded apartment.
    return ([Threading.Thread]::CurrentThread.GetApartmentState() -eq [Threading.ApartmentState]::STA)
}

function Initialize-WsWinForms {
    # Internal: inbox assemblies only, no runtime-compiled code.
    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing
}

function Get-WsCapabilities {
    [CmdletBinding()]
    param()
    if ((Get-WsPlatform) -eq 'windows') {
        $sta = Test-WsSta
        return @{ folderPicker = [bool]$sta; clipboard = [bool]$sta; openBrowser = $true }
    }
    return @{ folderPicker = $false; clipboard = $false; openBrowser = $false }
}

function Get-WsDataRoot {
    [CmdletBinding()]
    param()
    if ((Get-WsPlatform) -eq 'windows') {
        $base = $env:LOCALAPPDATA
        if ([string]::IsNullOrWhiteSpace($base)) { $base = [Environment]::GetFolderPath('LocalApplicationData') }
        $root = Join-Path $base 'WorkspaceShare'
    }
    else {
        $base = $env:XDG_DATA_HOME
        if ([string]::IsNullOrWhiteSpace($base)) {
            $home1 = $env:HOME
            if ([string]::IsNullOrWhiteSpace($home1)) { $home1 = [Environment]::GetFolderPath('UserProfile') }
            $base = Join-Path (Join-Path $home1 '.local') 'share'
        }
        $root = Join-Path $base 'workspaceshare'
    }
    if (-not (Test-Path -LiteralPath $root -PathType Container)) {
        [void](New-Item -ItemType Directory -Path $root -Force)
    }
    return $root
}

function Get-WsPowerShellHost {
    [CmdletBinding()]
    param()
    if ((Get-WsPlatform) -eq 'windows') {
        return (Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe')
    }
    return (Get-Command pwsh -ErrorAction Stop).Source
}

function Open-WsBrowser {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Url)
    # Only the local GUI URL is ever opened.
    if ($Url -notmatch '^http://127\.0\.0\.1:[0-9]{1,5}(/[^\s]*)?$') { return $false }
    if ((Get-WsPlatform) -ne 'windows') {
        # Linux port: xdg-open (docs/LINUX_PLAN.md)
        return $false
    }
    try {
        Start-Process -FilePath $Url
        return $true
    }
    catch { return $false }
}

function Show-WsFolderPicker {
    [CmdletBinding()]
    param([string]$InitialPath)
    if ((Get-WsPlatform) -ne 'windows') { return $null }
    if (-not (Test-WsSta)) { return $null }
    Initialize-WsWinForms
    $owner = $null
    $dialog = $null
    try {
        # Hidden TopMost owner so the dialog opens in front of the browser.
        $owner = New-Object System.Windows.Forms.Form
        $owner.TopMost = $true
        $owner.ShowInTaskbar = $false
        $owner.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::None
        $owner.StartPosition = [System.Windows.Forms.FormStartPosition]::CenterScreen
        $owner.Size = New-Object System.Drawing.Size(0, 0)
        $owner.Opacity = 0
        $owner.Show()
        $owner.Activate()
        $dialog = New-Object System.Windows.Forms.FolderBrowserDialog
        $dialog.Description = 'Ordner für die Freigabe auswählen'
        $dialog.ShowNewFolderButton = $false
        if (-not [string]::IsNullOrWhiteSpace($InitialPath) -and (Test-Path -LiteralPath $InitialPath -PathType Container)) {
            $dialog.SelectedPath = $InitialPath
        }
        $result = $dialog.ShowDialog($owner)
        if ($result -eq [System.Windows.Forms.DialogResult]::OK -and -not [string]::IsNullOrWhiteSpace($dialog.SelectedPath)) {
            return [string]$dialog.SelectedPath
        }
        return $null
    }
    finally {
        if ($null -ne $dialog) { try { $dialog.Dispose() } catch { } }
        if ($null -ne $owner) { try { $owner.Dispose() } catch { } }
    }
}

function Set-WsClipboardText {
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text)
    if ((Get-WsPlatform) -ne 'windows') { return $false }
    if (-not (Test-WsSta)) { return $false }
    try {
        Initialize-WsWinForms
        $data = New-Object System.Windows.Forms.DataObject
        $data.SetData([System.Windows.Forms.DataFormats]::UnicodeText, $Text)
        # Four zero bytes (DWORD 0): keep out of Win+V history, cloud clipboard and monitors.
        foreach ($format in @('ExcludeClipboardContentFromMonitorProcessing', 'CanIncludeInClipboardHistory', 'CanUploadToCloudClipboard')) {
            $stream = New-Object System.IO.MemoryStream (, (New-Object byte[] 4))
            $data.SetData($format, $stream)
        }
        [System.Windows.Forms.Clipboard]::SetDataObject($data, $true, 10, 100)
        return $true
    }
    catch { return $false }
}

function Clear-WsClipboardText {
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Expected)
    if ((Get-WsPlatform) -ne 'windows') { return $false }
    if (-not (Test-WsSta)) { return $false }
    try {
        Initialize-WsWinForms
        $current = [System.Windows.Forms.Clipboard]::GetText()
        if ($current -ceq $Expected) {
            [System.Windows.Forms.Clipboard]::Clear()
            return $true
        }
        return $false
    }
    catch { return $false }
}

Export-ModuleMember -Function Get-WsPlatform, Get-WsCapabilities, Get-WsDataRoot, Get-WsPowerShellHost, Open-WsBrowser, Show-WsFolderPicker, Set-WsClipboardText, Clear-WsClipboardText
