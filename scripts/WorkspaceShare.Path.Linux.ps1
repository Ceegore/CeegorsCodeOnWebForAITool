# Linux implementation of WorkspaceShare.Path (loaded by WorkspaceShare.Path.psm1 on non-Windows hosts).
# Directory identity = real path (symlinks resolved by realpath -e) plus device:inode from stat -L.
Set-StrictMode -Version Latest

function Invoke-WsPathTool {
    param([string]$FilePath, [string[]]$Arguments)
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $FilePath
    foreach ($argument in @($Arguments)) { [void]$psi.ArgumentList.Add([string]$argument) }
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $psi
    try {
        [void]$process.Start()
        $outTask = $process.StandardOutput.ReadToEndAsync()
        $errTask = $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit(15000)) { try { $process.Kill() } catch { }; throw ($FilePath + ' timed out.') }
        $process.WaitForExit()
        if ($process.ExitCode -ne 0) { throw ($FilePath + ' failed: ' + $errTask.Result.Trim()) }
        return ([string]$outTask.Result).TrimEnd("`n")
    }
    finally { $process.Dispose() }
}

function Resolve-WorkspaceDirectoryIdentity {
    param([Parameter(Mandatory=$true)][string]$Path)
    $full = [IO.Path]::GetFullPath($Path)
    $real = Invoke-WsPathTool 'realpath' @('-e', '--', $full)
    $identity = (Invoke-WsPathTool 'stat' @('-L', '-c', '%d:%i', '--', $real)).Trim()
    if ($real.Length -gt 1) { $real = $real.TrimEnd('/') }
    [pscustomobject]@{ FinalPath = $real; Identity = $identity }
}

function Test-WorkspaceSymbolicLink {
    # True for a symbolic link (file or directory); the link itself is inspected, never its target.
    param([Parameter(Mandatory=$true)][string]$Path)
    $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
    return (-not [string]::IsNullOrEmpty([string]$item.LinkTarget))
}

Export-ModuleMember -Function 'Resolve-WorkspaceDirectoryIdentity', 'Test-WorkspaceSymbolicLink'
