#requires -Version 5.1
[CmdletBinding()]
param(
    [string]$PublicUrl,
    [string]$LocalUrl,
    [Parameter(Mandatory = $true)][ValidateRange(1, 65535)][int]$MetricsPort,
    [ValidateRange(1, 1440)][int]$Minutes = 60,
    [ValidateRange(5, 300)][int]$IntervalSeconds = 15,
    [ValidateRange(0, 3600)][int]$MaximumAllowedOutageSeconds = 0,
    [string]$OutputPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$curl = (Get-Command curl.exe -ErrorAction Stop).Source
Import-Module (Join-Path (Split-Path $PSScriptRoot -Parent) 'scripts\WorkspaceShare.Health.psm1') -Force -ErrorAction Stop

function Read-SecretString {
    param([Parameter(Mandatory = $true)][string]$Prompt)
    $secure = Read-Host $Prompt -AsSecureString; $pointer = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
    try { return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($pointer) } finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($pointer) }
}
function ConvertTo-NativeArgument {
    param([AllowEmptyString()][string]$Value)
    if ($null -eq $Value -or $Value.Length -eq 0) { return '""' }
    if ($Value -notmatch '[\s"]') { return $Value }
    return '"' + ($Value -replace '(\\*)"', '$1$1\\"' -replace '(\\+)$', '$1$1') + '"'
}
function Invoke-CurlWithPrivateUrl {
    param([Parameter(Mandatory = $true)][string]$Url, [Parameter(Mandatory = $true)][string[]]$Arguments)
    $info = New-Object Diagnostics.ProcessStartInfo
    $info.FileName = $curl; $info.Arguments = ((@($Arguments) + @('--config','-') | ForEach-Object { ConvertTo-NativeArgument $_ }) -join ' ')
    $info.UseShellExecute = $false; $info.CreateNoWindow = $true; $info.RedirectStandardInput = $true; $info.RedirectStandardOutput = $true; $info.RedirectStandardError = $true
    $process = New-Object Diagnostics.Process; $process.StartInfo = $info
    if (-not $process.Start()) { throw 'curl.exe could not be started.' }
    $process.StandardInput.WriteLine(('url = "{0}"' -f $Url.Replace('\','\\').Replace('"','\"'))); $process.StandardInput.Close()
    $stdout = $process.StandardOutput.ReadToEnd(); $stderr = $process.StandardError.ReadToEnd(); [void]$process.WaitForExit()
    return [pscustomobject]@{ ExitCode=$process.ExitCode; StdOut=$stdout; StdErr=$stderr }
}
function Protect-DiagnosticText {
    param([AllowNull()][string]$Text, [string[]]$KnownSecretUrls = @())
    if ([string]::IsNullOrEmpty($Text)) { return '' }
    $safe=$Text; foreach($url in @($KnownSecretUrls)){if($url){$safe=$safe.Replace($url,'https://<redacted>.trycloudflare.com/d/<redacted>/')}}
    $safe=$safe -replace '(?i)\b[a-z0-9-]+\.trycloudflare\.com\b','<redacted>.trycloudflare.com'
    $safe=$safe -replace '(?i)/d/[A-Za-z0-9_-]{43}(?=/|\s|"|''|$)','/d/<redacted>'
    return $safe
}
function Invoke-Probe {
    param([Parameter(Mandatory = $true)][string]$Url,[int]$TimeoutSeconds=12,[int64]$Start=0,[int]$ExpectedBytes=0,[switch]$AllowFullFileResponse)
    $id=[Guid]::NewGuid().ToString('N'); $root=[IO.Path]::GetTempPath(); $body=Join-Path $root "ws-soak-body-$id.tmp"; $headers=Join-Path $root "ws-soak-headers-$id.tmp"; $errors=Join-Path $root "ws-soak-error-$id.tmp"
    try {
        $end=$Start+[Math]::Max(0,$ExpectedBytes-1); $args=@('--silent','--show-error','--stderr',$errors,'--output',$body,'--dump-header',$headers,'--max-time',[string]$TimeoutSeconds,'--max-filesize','65536','--write-out','%{http_code}|%{remote_ip}|%{time_total}')
        if($ExpectedBytes -gt 0){$args+=@('--range',("{0}-{1}" -f $Start,$end))}; $result=Invoke-CurlWithPrivateUrl -Url $Url -Arguments $args; $parts=@($result.StdOut.Trim().Split('|'))
        $status=0; if($parts.Count -gt 0){[void][int]::TryParse($parts[0],[ref]$status)}; $remoteIp=if($parts.Count -gt 1){$parts[1]}else{''}; $seconds=0.0; if($parts.Count -gt 2){[void][double]::TryParse($parts[2],[Globalization.NumberStyles]::Float,[Globalization.CultureInfo]::InvariantCulture,[ref]$seconds)}
        $actual=if(Test-Path $body){[int](Get-Item $body).Length}else{0}; $sha=if($actual -gt 0){(Get-FileHash $body -Algorithm SHA256).Hash}else{''}; $headerText=if(Test-Path $headers){[string](Get-Content $headers -Raw)}else{''}; $errorText=if(Test-Path $errors){[string](Get-Content $errors -Raw)}else{''}; if($result.StdErr){$errorText+=[Environment]::NewLine+$result.StdErr}; $bodyText=if(Test-Path $body){[string](Get-Content $body -Raw)}else{''}
        $contentRange=''; $match=[regex]::Match($headerText,'(?im)^Content-Range:\s*([^\r\n]+)'); if($match.Success){$contentRange=$match.Groups[1].Value.Trim()}; $totalBytes=0; $totalMatch=[regex]::Match($contentRange,'/(\d+)$'); if($totalMatch.Success){[void][int]::TryParse($totalMatch.Groups[1].Value,[ref]$totalBytes)}elseif($status -eq 200){$totalBytes=$actual}
        $retry=0; $retryMatch=[regex]::Match($headerText,'(?im)^Retry-After:\s*(\d+)\s*$'); if($retryMatch.Success){[void][int]::TryParse($retryMatch.Groups[1].Value,[ref]$retry)}; $cf=0; $cfMatch=[regex]::Match($bodyText,'(?i)(?:"code"\s*:\s*|\berror\s+)(10\d{2})|\b(1033)\b'); if($cfMatch.Success){[void][int]::TryParse(($cfMatch.Groups[1].Value+$cfMatch.Groups[2].Value),[ref]$cf)}
        $valid=if($ExpectedBytes -gt 0){$rangeValid=($status -eq 206 -and $contentRange -match ('^bytes\s+{0}-{1}/' -f $Start,$end)); if($AllowFullFileResponse){$rangeValid=$rangeValid -or ($status -eq 200 -and $Start -eq 0)}; $result.ExitCode -eq 0 -and $rangeValid -and $actual -eq $ExpectedBytes}else{$result.ExitCode -eq 0 -and $status -in @(200,206)}
        return [pscustomobject]@{Exit=$result.ExitCode;Status=$status;RemoteIp=$remoteIp;Seconds=$seconds;Error=(Protect-DiagnosticText $errorText @($PublicUrl,$LocalUrl));CloudflareError=$cf;RetryAfter=$retry;ActualBytes=$actual;TotalBytes=$totalBytes;Sha256=$sha;SampleValid=$valid;Body=(Protect-DiagnosticText $bodyText @($PublicUrl,$LocalUrl))}
    } finally { Remove-Item $body,$headers,$errors -Force -ErrorAction SilentlyContinue }
}
function Get-QuickTunnelHostnameState {
    param([int]$Port,[string]$ExpectedHostname)
    $path=Join-Path ([IO.Path]::GetTempPath()) ("ws-soak-quick-{0}.json" -f [Guid]::NewGuid().ToString('N'))
    try {$result=Invoke-CurlWithPrivateUrl -Url "http://127.0.0.1:$Port/quicktunnel" -Arguments @('--silent','--show-error','--max-time','5','--max-filesize','65536','--output',$path); if($result.ExitCode -ne 0 -or -not(Test-Path $path)){return [pscustomobject]@{Available=$false;Matches=$false}}; $actual=([string]((Get-Content $path -Raw|ConvertFrom-Json).hostname)).Trim().ToLowerInvariant(); return [pscustomobject]@{Available=-not [string]::IsNullOrWhiteSpace($actual);Matches=($actual -eq $ExpectedHostname.Trim().ToLowerInvariant())}}catch{return [pscustomobject]@{Available=$false;Matches=$false}}finally{Remove-Item $path -Force -ErrorAction SilentlyContinue}
}

if([string]::IsNullOrWhiteSpace($PublicUrl)){$PublicUrl=[Environment]::GetEnvironmentVariable('WORKSPACESHARE_PUBLIC_URL','Process')}; if([string]::IsNullOrWhiteSpace($LocalUrl)){$LocalUrl=[Environment]::GetEnvironmentVariable('WORKSPACESHARE_LOCAL_URL','Process')}; if([string]::IsNullOrWhiteSpace($PublicUrl)){$PublicUrl=Read-SecretString 'Paste the public WorkspaceShare URL'}; if([string]::IsNullOrWhiteSpace($LocalUrl)){$LocalUrl=Read-SecretString 'Paste the local WorkspaceShare URL'}; if([string]::IsNullOrWhiteSpace($OutputPath)){$OutputPath=Join-Path $PWD ('tunnel-soak-{0}.jsonl' -f [DateTime]::UtcNow.ToString('yyyyMMdd-HHmmss'))}
$hostname=([Uri]$PublicUrl).DnsSafeHost; $discovery=Invoke-Probe -Url $LocalUrl -TimeoutSeconds 5 -Start 0 -ExpectedBytes 1 -AllowFullFileResponse; $archiveSize=[int64][Math]::Max(1,$discovery.TotalBytes); $samples=@(Get-HealthSamplePlan -ArchiveSize $archiveSize); $deadline=[DateTime]::UtcNow.AddMinutes($Minutes); $lastUtc=[DateTime]::UtcNow; $iteration=0; $failedSamples=0; $currentOutageStartedUtc=$null; $longestOutageSeconds=0.0
Write-Host "Soak test: <redacted>.trycloudflare.com for $Minutes minute(s); output: $OutputPath"
while([DateTime]::UtcNow -lt $deadline){$iteration++;$now=[DateTime]::UtcNow;$gap=($now-$lastUtc).TotalSeconds;$lastUtc=$now;$sample=$samples[($iteration-1)%$samples.Count];$local=Invoke-Probe $LocalUrl 5 $sample.Start $sample.Length -AllowFullFileResponse:$sample.AllowFullFileResponse;$ready=Invoke-Probe "http://127.0.0.1:$MetricsPort/ready" 5;$public=Invoke-Probe $PublicUrl 12 $sample.Start $sample.Length -AllowFullFileResponse:$sample.AllowFullFileResponse;$hostnameState=Get-QuickTunnelHostnameState $MetricsPort $hostname;$readyConnections=0;try{$readyConnections=[int](($ready.Body|ConvertFrom-Json).readyConnections)}catch{};$healthy=$local.SampleValid -and $public.SampleValid -and $local.Sha256 -eq $public.Sha256;if($healthy){if($currentOutageStartedUtc){$longestOutageSeconds=[Math]::Max($longestOutageSeconds,($now-$currentOutageStartedUtc).TotalSeconds);$currentOutageStartedUtc=$null}}else{$failedSamples++;if(-not $currentOutageStartedUtc){$currentOutageStartedUtc=$now}};[ordered]@{utc=$now.ToString('o');iteration=$iteration;loopGapSeconds=[Math]::Round($gap,3);tunnelHost='<redacted>.trycloudflare.com';sampleStart=$sample.Start;sampleLength=$sample.Length;localSampleValid=$local.SampleValid;localStatus=$local.Status;readySuccess=($ready.Status -eq 200);readyConnections=$readyConnections;quickTunnelHostnameAvailable=$hostnameState.Available;quickTunnelHostnameMatches=$hostnameState.Matches;publicSampleValid=$public.SampleValid;publicExit=$public.Exit;publicStatus=$public.Status;cloudflareError=$public.CloudflareError;retryAfter=$public.RetryAfter;remoteIp=$public.RemoteIp;publicSeconds=$public.Seconds;publicError=$public.Error}|ConvertTo-Json -Compress|Add-Content $OutputPath -Encoding UTF8;Write-Host ("[{0}] {1} local={2}/{3} ready={4}/{5} public={6}/{7}/cf{8} gap={9:N0}s" -f $now.ToLocalTime().ToString('HH:mm:ss'),$(if($healthy){'HEALTHY'}else{'FAILED'}),$local.SampleValid,$local.Status,$ready.Status,$readyConnections,$public.SampleValid,$public.Status,$public.CloudflareError,$gap);Start-Sleep $IntervalSeconds}
if($currentOutageStartedUtc){$longestOutageSeconds=[Math]::Max($longestOutageSeconds,([DateTime]::UtcNow-$currentOutageStartedUtc).TotalSeconds)};Write-Host ("Samples: {0}; failed: {1}; longest outage: {2:N0}s" -f $iteration,$failedSamples,$longestOutageSeconds);$failed=if($MaximumAllowedOutageSeconds -eq 0){$failedSamples -gt 0}else{$longestOutageSeconds -gt $MaximumAllowedOutageSeconds};if($failed){exit 1};exit 0
