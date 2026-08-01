Set-StrictMode -Version Latest

function Protect-DiagnosticText {
    param([AllowNull()][string]$Text,[string[]]$KnownSecretUrls=@(),[string[]]$SecretTokens=@())
    if([string]::IsNullOrEmpty($Text)){return ''}
    $safe=$Text
    foreach($secret in @($SecretTokens)){if(-not[string]::IsNullOrWhiteSpace($secret)){$safe=$safe.Replace($secret,'<redacted-token>')}}
    foreach($url in @($KnownSecretUrls)){if($url){$safe=$safe.Replace($url,'https://<redacted>.trycloudflare.com/d/<redacted>/')}}
    $safe=$safe -replace '(?i)\b[a-z0-9-]+\.trycloudflare\.com\b','<redacted>.trycloudflare.com'
    $safe=$safe -replace '(?i)/d/[A-Za-z0-9_-]{43}(?=/|\?|#|\s|"|''|$)','/d/<redacted>'
    $safe=$safe -replace '(?i)%2f(?:d|%64)%2f[A-Za-z0-9_-]{43}','%2Fd%2F<redacted>'
    $safe=$safe -replace '(?i)%252f(?:d|%2564)%252f[A-Za-z0-9_-]{43}','%252Fd%252F<redacted>'
    return $safe
}

function ConvertTo-CurlConfigQuoted {
    param([Parameter(Mandatory=$true)][string]$Value)
    return $Value.Replace('\','\\').Replace('"','\"').Replace("`r",'\r').Replace("`n",'\n')
}

function Invoke-CurlWithPrivateUrl {
    param([Parameter(Mandatory=$true)][string]$CurlPath,[Parameter(Mandatory=$true)][string]$Url,[Parameter(Mandatory=$true)][string[]]$Arguments,[string[]]$PrivateConfigLines=@(),[ValidateRange(1,600)][int]$ProcessTimeoutSeconds=90,[IntPtr]$Job=[IntPtr]::Zero)
    $privateInput=('url = "{0}"' -f (ConvertTo-CurlConfigQuoted $Url))+[Environment]::NewLine+(($PrivateConfigLines|ForEach-Object{$_}) -join [Environment]::NewLine)+[Environment]::NewLine
    if($Job -eq [IntPtr]::Zero){
        $jobModulePath=Join-Path $PSScriptRoot 'WorkspaceShare.Job.psm1'
        if(-not(Get-Module -Name 'WorkspaceShare.Job')){Import-Module $jobModulePath -ErrorAction Stop}
        $ephemeralJob=WorkspaceShare.Job\New-WorkspaceJob -Name ('Local\WorkspaceShare.Curl.'+[Guid]::NewGuid().ToString('N'))
        try{return Invoke-CurlWithPrivateUrl -CurlPath $CurlPath -Url $Url -Arguments $Arguments -PrivateConfigLines $PrivateConfigLines -ProcessTimeoutSeconds $ProcessTimeoutSeconds -Job $ephemeralJob}
        finally{try{WorkspaceShare.Job\Stop-WorkspaceJob -Job $ephemeralJob}catch{};try{WorkspaceShare.Job\Close-WorkspaceJob -Job $ephemeralJob}catch{}}
    }
    $base=[IO.Path]::GetTempPath();$id=[Guid]::NewGuid().ToString('N');$stdout=Join-Path $base ('workspace-curl-'+$id+'.stdout');$stderr=Join-Path $base ('workspace-curl-'+$id+'.stderr');$process=$null
    try{$environment=New-WorkspaceChildEnvironment;$process=Start-WorkspaceProcessInJob -Job $Job -FilePath $CurlPath -Arguments (@('--disable')+@($Arguments)+@('--config','-')) -WorkingDirectory $base -StdOutPath $stdout -StdErrPath $stderr -StandardInputText $privateInput -Environment $environment;$nativeProcessHandle=$process.Handle;if(-not$process.WaitForExit($ProcessTimeoutSeconds*1000)){try{Stop-WorkspaceJob -Job $Job}catch{};throw 'curl.exe exceeded its process timeout; the session Job was terminated.'};$exitCode=[WorkspaceShare.NativeJob]::GetExitCode($nativeProcessHandle);return [pscustomobject]@{ExitCode=$exitCode;StdOut=if(Test-Path $stdout){[IO.File]::ReadAllText($stdout)}else{''};StdErr=if(Test-Path $stderr){[IO.File]::ReadAllText($stderr)}else{''}}}
    finally{try{if($process){$process.Dispose()}}catch{};Remove-Item -LiteralPath $stdout,$stderr -Force -ErrorAction SilentlyContinue}
}

Export-ModuleMember -Function @('Protect-DiagnosticText','ConvertTo-CurlConfigQuoted','Invoke-CurlWithPrivateUrl')
