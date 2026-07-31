Set-StrictMode -Version Latest

function Protect-DiagnosticText {
    param([AllowNull()][string]$Text,[string[]]$KnownSecretUrls=@())
    if([string]::IsNullOrEmpty($Text)){return ''};$safe=$Text;foreach($url in @($KnownSecretUrls)){if($url){$safe=$safe.Replace($url,'https://<redacted>.trycloudflare.com/d/<redacted>/')}};$safe=$safe -replace '(?i)\b[a-z0-9-]+\.trycloudflare\.com\b','<redacted>.trycloudflare.com';$safe=$safe -replace '(?i)/d/[A-Za-z0-9_-]{43}(?=/|\s|"|''|$)','/d/<redacted>';$safe=$safe -replace '(?i)%2Fd%2F[A-Za-z0-9_-]{43}','%2Fd%2F<redacted>';return $safe
}
function ConvertTo-CurlConfigQuoted { param([Parameter(Mandatory = $true)][string]$Value); return $Value.Replace('\','\\').Replace('"','\"').Replace("`r",'\r').Replace("`n",'\n') }
function Invoke-CurlWithPrivateUrl {
    param([Parameter(Mandatory = $true)][string]$CurlPath,[Parameter(Mandatory = $true)][string]$Url,[Parameter(Mandatory = $true)][string[]]$Arguments,[string[]]$PrivateConfigLines=@(),[ValidateRange(1,600)][int]$ProcessTimeoutSeconds=90)
    $quote={param([string]$v) if($null -eq $v -or $v.Length -eq 0){'""'}elseif($v -notmatch '[\s"]'){$v}else{'"'+($v -replace '(\\*)"','$1$1\\"' -replace '(\\+)$','$1$1')+'"'}}
    $info=New-Object Diagnostics.ProcessStartInfo;$info.FileName=$CurlPath;$info.Arguments=((@('--disable')+@($Arguments)+@('--config','-')|ForEach-Object {&$quote $_}) -join ' ');$info.UseShellExecute=$false;$info.CreateNoWindow=$true;$info.RedirectStandardInput=$true;$info.RedirectStandardOutput=$true;$info.RedirectStandardError=$true;[void]$info.EnvironmentVariables.Remove('WORKSPACESHARE_PUBLIC_URL');[void]$info.EnvironmentVariables.Remove('WORKSPACESHARE_LOCAL_URL');$process=New-Object Diagnostics.Process;$process.StartInfo=$info
    try{if(-not $process.Start()){throw 'curl.exe could not be started.'};$process.StandardInput.WriteLine(('url = "{0}"' -f (ConvertTo-CurlConfigQuoted $Url)));foreach($line in $PrivateConfigLines){$process.StandardInput.WriteLine($line)};$process.StandardInput.Close();$stdoutTask=$process.StandardOutput.ReadToEndAsync();$stderrTask=$process.StandardError.ReadToEndAsync();if(-not $process.WaitForExit($ProcessTimeoutSeconds*1000)){try{Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue}catch{};throw 'curl.exe exceeded its process timeout.'};return [pscustomobject]@{ExitCode=$process.ExitCode;StdOut=$stdoutTask.Result;StdErr=$stderrTask.Result}}finally{try{$process.Dispose()}catch{}}
}
Export-ModuleMember -Function @('Protect-DiagnosticText','ConvertTo-CurlConfigQuoted','Invoke-CurlWithPrivateUrl')
