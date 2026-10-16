Set-StrictMode -Version Latest

function Get-WorkspaceDependencyLeasePath {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$ToolRoot)

    $normalized = [IO.Path]::GetFullPath($ToolRoot).TrimEnd('\','/').ToUpperInvariant()
    $bytes = [Text.Encoding]::UTF8.GetBytes($normalized)
    $sha = [Security.Cryptography.SHA256]::Create()
    try { $key = ([BitConverter]::ToString($sha.ComputeHash($bytes))).Replace('-', '') }
    finally { $sha.Dispose() }

    $base = Join-Path (Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'WorkspaceShare') 'locks'
    New-Item -ItemType Directory -Path $base -Force -ErrorAction Stop | Out-Null
    return (Join-Path $base ($key + '.lease'))
}

function Enter-WorkspaceDependencyLease {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ToolRoot,
        [ValidateSet('Shared','Exclusive')][string]$Mode = 'Shared',
        [ValidateRange(1,3600)][int]$TimeoutSeconds = 30
    )

    $path = Get-WorkspaceDependencyLeasePath -ToolRoot $ToolRoot
    if(-not(Test-Path -LiteralPath $path -PathType Leaf)){
        $initializer=$null
        try{$initializer=[IO.File]::Open($path,[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::ReadWrite)}finally{if($initializer){$initializer.Dispose()}}
    }
    $timer = [Diagnostics.Stopwatch]::StartNew()
    $lastError = $null
    while ($timer.Elapsed.TotalSeconds -lt $TimeoutSeconds) {
        try {
            if($Mode -eq 'Shared'){return [IO.File]::Open($path,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)}
            return [IO.File]::Open($path,[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
        }
        catch [IO.IOException] {
            $lastError = $_.Exception
            Start-Sleep -Milliseconds 100
        }
    }

    throw "The $Mode dependency lease could not be acquired within $TimeoutSeconds seconds: $($lastError.Message)"
}

Export-ModuleMember -Function Get-WorkspaceDependencyLeasePath,Enter-WorkspaceDependencyLease
