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

function Remove-UnsafeEnvironment {
    param([Diagnostics.ProcessStartInfo]$StartInfo)
    $exact=@('WORKSPACESHARE_PUBLIC_URL','WORKSPACESHARE_LOCAL_URL','SSLKEYLOGFILE','CURL_CA_BUNDLE','CURL_HOME','CURLRC')
    foreach($key in @($StartInfo.EnvironmentVariables.Keys)){
        $name=[string]$key
        if($exact -contains $name.ToUpperInvariant()){[void]$StartInfo.EnvironmentVariables.Remove($name)}
    }
}

function Invoke-CurlWithPrivateUrl {
    param([Parameter(Mandatory=$true)][string]$CurlPath,[Parameter(Mandatory=$true)][string]$Url,[Parameter(Mandatory=$true)][string[]]$Arguments,[string[]]$PrivateConfigLines=@(),[ValidateRange(1,600)][int]$ProcessTimeoutSeconds=90,[IntPtr]$Job=[IntPtr]::Zero)
    $quote={param([string]$v) if($null -eq $v -or $v.Length -eq 0){'""'}elseif($v -notmatch '[\s"]'){$v}else{'"'+($v -replace '(\\*)"','$1$1\\"' -replace '(\\+)$','$1$1')+'"'}}
    $privateInput=('url = "{0}"' -f (ConvertTo-CurlConfigQuoted $Url))+[Environment]::NewLine+(($PrivateConfigLines|ForEach-Object{$_}) -join [Environment]::NewLine)+[Environment]::NewLine
    if($Job -ne [IntPtr]::Zero){
        $base=[IO.Path]::GetTempPath();$id=[Guid]::NewGuid().ToString('N');$stdout=Join-Path $base ('workspace-curl-'+$id+'.stdout');$stderr=Join-Path $base ('workspace-curl-'+$id+'.stderr');$process=$null
        try{$environment=New-WorkspaceChildEnvironment;$process=Start-WorkspaceProcessInJob -Job $Job -FilePath $CurlPath -Arguments (@('--disable')+@($Arguments)+@('--config','-')) -WorkingDirectory $base -StdOutPath $stdout -StdErrPath $stderr -StandardInputText $privateInput -Environment $environment;$nativeProcessHandle=$process.Handle;if(-not$process.WaitForExit($ProcessTimeoutSeconds*1000)){try{Stop-WorkspaceJob -Job $Job}catch{};throw 'curl.exe exceeded its process timeout; the session Job was terminated.'};$exitCode=[WorkspaceShare.NativeJob]::GetExitCode($nativeProcessHandle);return [pscustomobject]@{ExitCode=$exitCode;StdOut=if(Test-Path $stdout){[IO.File]::ReadAllText($stdout)}else{''};StdErr=if(Test-Path $stderr){[IO.File]::ReadAllText($stderr)}else{''}}}
        finally{try{if($process){$process.Dispose()}}catch{};Remove-Item -LiteralPath $stdout,$stderr -Force -ErrorAction SilentlyContinue}
    }
    $info=New-Object Diagnostics.ProcessStartInfo
    $info.FileName=$CurlPath
    $info.Arguments=((@('--disable')+@($Arguments)+@('--config','-')|ForEach-Object {&$quote $_}) -join ' ')
    $info.UseShellExecute=$false;$info.CreateNoWindow=$true;$info.RedirectStandardInput=$true;$info.RedirectStandardOutput=$true;$info.RedirectStandardError=$true
    Remove-UnsafeEnvironment $info
    $process=New-Object Diagnostics.Process;$process.StartInfo=$info
    try {
        if(-not $process.Start()){throw 'curl.exe could not be started.'}
        $process.StandardInput.Write($privateInput)
        $process.StandardInput.Close()
        $stdoutTask=$process.StandardOutput.ReadToEndAsync();$stderrTask=$process.StandardError.ReadToEndAsync()
        if(-not $process.WaitForExit($ProcessTimeoutSeconds*1000)){
            try{$process.Kill();[void]$process.WaitForExit(5000)}catch{}
            if(-not $process.HasExited){throw 'curl.exe exceeded its process timeout and termination was not confirmed.'}
            throw 'curl.exe exceeded its process timeout.'
        }
        return [pscustomobject]@{ExitCode=$process.ExitCode;StdOut=$stdoutTask.Result;StdErr=$stderrTask.Result}
    } finally {try{$process.Dispose()}catch{}}
}

Export-ModuleMember -Function @('Protect-DiagnosticText','ConvertTo-CurlConfigQuoted','Invoke-CurlWithPrivateUrl')
