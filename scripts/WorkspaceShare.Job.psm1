Set-StrictMode -Version Latest

# Non-Windows hosts (PowerShell 7 on Linux) use the platform implementation with the same function names.
if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) {
    . (Join-Path $PSScriptRoot 'WorkspaceShare.Job.Linux.ps1')
    return
}

if (-not ('WorkspaceShare.NativeJob' -as [type])) {
Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Security.Principal;
using System.Text;

namespace WorkspaceShare {
  public static class NativeJob {
    const int ERROR_ALREADY_EXISTS=183, JobObjectExtendedLimitInformation=9;
    const uint JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE=0x2000;
    const uint CREATE_SUSPENDED=0x4,CREATE_UNICODE_ENVIRONMENT=0x400,CREATE_NO_WINDOW=0x08000000,STARTF_USESTDHANDLES=0x100;
    const uint GENERIC_READ=0x80000000,GENERIC_WRITE=0x40000000,FILE_SHARE_READ=1,FILE_SHARE_WRITE=2,CREATE_ALWAYS=2,OPEN_EXISTING=3,FILE_ATTRIBUTE_NORMAL=0x80,HANDLE_FLAG_INHERIT=1;
    [StructLayout(LayoutKind.Sequential)] struct SECURITY_ATTRIBUTES{public int nLength;public IntPtr lpSecurityDescriptor;[MarshalAs(UnmanagedType.Bool)]public bool bInheritHandle;}
    [StructLayout(LayoutKind.Sequential)] struct IO_COUNTERS{public ulong ReadOperationCount,WriteOperationCount,OtherOperationCount,ReadTransferCount,WriteTransferCount,OtherTransferCount;}
    [StructLayout(LayoutKind.Sequential)] struct BASIC_LIMIT{public long PerProcessUserTimeLimit,PerJobUserTimeLimit;public uint LimitFlags;public UIntPtr MinimumWorkingSetSize,MaximumWorkingSetSize;public uint ActiveProcessLimit;public UIntPtr Affinity;public uint PriorityClass,SchedulingClass;}
    [StructLayout(LayoutKind.Sequential)] struct EXT_LIMIT{public BASIC_LIMIT BasicLimitInformation;public IO_COUNTERS IoInfo;public UIntPtr ProcessMemoryLimit,JobMemoryLimit,PeakProcessMemoryUsed,PeakJobMemoryUsed;}
    [StructLayout(LayoutKind.Sequential,CharSet=CharSet.Unicode)] struct STARTUPINFO{public int cb;public string lpReserved,lpDesktop,lpTitle;public uint dwX,dwY,dwXSize,dwYSize,dwXCountChars,dwYCountChars,dwFillAttribute,dwFlags;public short wShowWindow,cbReserved2;public IntPtr lpReserved2,hStdInput,hStdOutput,hStdError;}
    [StructLayout(LayoutKind.Sequential)] struct PROCESS_INFORMATION{public IntPtr hProcess,hThread;public uint dwProcessId,dwThreadId;}
    [DllImport("kernel32.dll",CharSet=CharSet.Unicode,SetLastError=true)] static extern IntPtr CreateJobObject(ref SECURITY_ATTRIBUTES attributes,string name);
    [DllImport("advapi32.dll",CharSet=CharSet.Unicode,SetLastError=true)] static extern bool ConvertStringSecurityDescriptorToSecurityDescriptor(string value,uint revision,out IntPtr descriptor,out uint size);
    [DllImport("kernel32.dll")] static extern IntPtr LocalFree(IntPtr memory);
    [DllImport("kernel32.dll",CharSet=CharSet.Unicode,SetLastError=true)] static extern IntPtr OpenJobObject(uint access,bool inherit,string name);
    [DllImport("kernel32.dll",SetLastError=true)] static extern bool SetInformationJobObject(IntPtr handle,int infoClass,IntPtr info,uint length);
    [DllImport("kernel32.dll",SetLastError=true)] static extern bool AssignProcessToJobObject(IntPtr job,IntPtr process);
    [DllImport("kernel32.dll",SetLastError=true)] static extern bool TerminateJobObject(IntPtr job,uint exitCode);
    [DllImport("kernel32.dll",SetLastError=true)] static extern bool TerminateProcess(IntPtr process,uint exitCode);
    [DllImport("kernel32.dll",SetLastError=true)] static extern bool GetExitCodeProcess(IntPtr process,out uint exitCode);
    [DllImport("kernel32.dll",SetLastError=true)] static extern uint WaitForSingleObject(IntPtr handle,uint milliseconds);
    [DllImport("kernel32.dll",SetLastError=true)] static extern bool CloseHandle(IntPtr handle);
    [DllImport("kernel32.dll",SetLastError=true)] static extern uint ResumeThread(IntPtr thread);
    [DllImport("kernel32.dll",SetLastError=true)] static extern bool SetHandleInformation(IntPtr handle,uint mask,uint flags);
    [DllImport("kernel32.dll",SetLastError=true)] static extern bool CreatePipe(out IntPtr read,out IntPtr write,ref SECURITY_ATTRIBUTES attributes,uint size);
    [DllImport("kernel32.dll",SetLastError=true)] static extern bool WriteFile(IntPtr handle,byte[] buffer,uint bytes,out uint written,IntPtr overlapped);
    [DllImport("kernel32.dll",CharSet=CharSet.Unicode,SetLastError=true)] static extern IntPtr CreateFile(string name,uint access,uint share,IntPtr security,uint creation,uint flags,IntPtr template);
    [DllImport("kernel32.dll",CharSet=CharSet.Unicode,SetLastError=true)] static extern bool CreateProcess(string app,StringBuilder command,IntPtr processAttributes,IntPtr threadAttributes,bool inherit,uint flags,IntPtr environment,string cwd,ref STARTUPINFO startup,out PROCESS_INFORMATION processInfo);
    static void Fail(string operation){throw new Win32Exception(Marshal.GetLastWin32Error(),operation);}
    static IntPtr BuildEnvironment(string[] entries){string block=String.Join("\0",entries??new string[0])+"\0\0";return Marshal.StringToHGlobalUni(block);}
    public static IntPtr Create(string name){string sid=WindowsIdentity.GetCurrent().User.Value;IntPtr descriptor;uint descriptorSize;if(!ConvertStringSecurityDescriptorToSecurityDescriptor("D:P(A;;GA;;;"+sid+")",1,out descriptor,out descriptorSize))Fail("ConvertStringSecurityDescriptorToSecurityDescriptor");IntPtr handle=IntPtr.Zero;int creationError=0;try{SECURITY_ATTRIBUTES attributes=new SECURITY_ATTRIBUTES();attributes.nLength=Marshal.SizeOf(attributes);attributes.lpSecurityDescriptor=descriptor;attributes.bInheritHandle=false;handle=CreateJobObject(ref attributes,name);creationError=Marshal.GetLastWin32Error();}finally{LocalFree(descriptor);}if(handle==IntPtr.Zero){Marshal.ThrowExceptionForHR(Marshal.GetHRForLastWin32Error());}if(creationError==ERROR_ALREADY_EXISTS){CloseHandle(handle);throw new InvalidOperationException("A Job Object with this name already exists.");}EXT_LIMIT info=new EXT_LIMIT();info.BasicLimitInformation.LimitFlags=JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;int size=Marshal.SizeOf(info);IntPtr data=Marshal.AllocHGlobal(size);try{Marshal.StructureToPtr(info,data,false);if(!SetInformationJobObject(handle,JobObjectExtendedLimitInformation,data,(uint)size)){CloseHandle(handle);Fail("SetInformationJobObject");}}finally{Marshal.FreeHGlobal(data);}return handle;}
    public static IntPtr Open(string name){IntPtr handle=OpenJobObject(0x1F001F,false,name);if(handle==IntPtr.Zero)Fail("OpenJobObject");return handle;}
    public static void Assign(IntPtr job,int pid){using(Process process=Process.GetProcessById(pid)){if(!AssignProcessToJobObject(job,process.Handle))Fail("AssignProcessToJobObject");}}
    public static Process StartSuspended(IntPtr job,string file,string args,string cwd,string stdout,string stderr,string stdinText,string[] environmentEntries,bool forceResumeFailure){
      IntPtr input=IntPtr.Zero,inputWrite=IntPtr.Zero,output=IntPtr.Zero,error=IntPtr.Zero,environment=IntPtr.Zero;bool created=false;PROCESS_INFORMATION pi=new PROCESS_INFORMATION();Process child=null;
      try{
        if(stdinText==null){input=CreateFile("NUL",GENERIC_READ,FILE_SHARE_READ|FILE_SHARE_WRITE,IntPtr.Zero,OPEN_EXISTING,FILE_ATTRIBUTE_NORMAL,IntPtr.Zero);if(input.ToInt64()==-1)Fail("CreateFile stdin");if(!SetHandleInformation(input,HANDLE_FLAG_INHERIT,HANDLE_FLAG_INHERIT))Fail("SetHandleInformation stdin");}
        else{SECURITY_ATTRIBUTES security=new SECURITY_ATTRIBUTES();security.nLength=Marshal.SizeOf(security);security.bInheritHandle=true;if(!CreatePipe(out input,out inputWrite,ref security,0))Fail("CreatePipe stdin");if(!SetHandleInformation(inputWrite,HANDLE_FLAG_INHERIT,0))Fail("SetHandleInformation stdin writer");}
        output=CreateFile(stdout,GENERIC_WRITE,FILE_SHARE_READ|FILE_SHARE_WRITE,IntPtr.Zero,CREATE_ALWAYS,FILE_ATTRIBUTE_NORMAL,IntPtr.Zero);if(output.ToInt64()==-1)Fail("CreateFile stdout");
        error=CreateFile(stderr,GENERIC_WRITE,FILE_SHARE_READ|FILE_SHARE_WRITE,IntPtr.Zero,CREATE_ALWAYS,FILE_ATTRIBUTE_NORMAL,IntPtr.Zero);if(error.ToInt64()==-1)Fail("CreateFile stderr");
        if(!SetHandleInformation(output,HANDLE_FLAG_INHERIT,HANDLE_FLAG_INHERIT)||!SetHandleInformation(error,HANDLE_FLAG_INHERIT,HANDLE_FLAG_INHERIT))Fail("SetHandleInformation output");
        environment=BuildEnvironment(environmentEntries);STARTUPINFO startup=new STARTUPINFO();startup.cb=Marshal.SizeOf(startup);startup.dwFlags=STARTF_USESTDHANDLES;startup.hStdInput=input;startup.hStdOutput=output;startup.hStdError=error;
        if(!CreateProcess(file,new StringBuilder("\""+file+"\" "+args),IntPtr.Zero,IntPtr.Zero,true,CREATE_SUSPENDED|CREATE_NO_WINDOW|CREATE_UNICODE_ENVIRONMENT,environment,cwd,ref startup,out pi))Fail("CreateProcess");created=true;
        if(!AssignProcessToJobObject(job,pi.hProcess))Fail("AssignProcessToJobObject");
        if(forceResumeFailure){InvalidOperationException injected=new InvalidOperationException("Injected ResumeThread failure.");injected.Data["ProcessId"]=(int)pi.dwProcessId;throw injected;}
        child=Process.GetProcessById((int)pi.dwProcessId);IntPtr cachedHandle=child.Handle;
        if(ResumeThread(pi.hThread)==0xFFFFFFFF)Fail("ResumeThread");
        if(inputWrite!=IntPtr.Zero){byte[] bytes=Encoding.UTF8.GetBytes(stdinText);uint written;if(bytes.Length>0&&(!WriteFile(inputWrite,bytes,(uint)bytes.Length,out written,IntPtr.Zero)||written!=(uint)bytes.Length))Fail("WriteFile stdin");CloseHandle(inputWrite);inputWrite=IntPtr.Zero;}
        return child;
      }catch{if(child!=null)child.Dispose();if(created&&pi.hProcess!=IntPtr.Zero){TerminateProcess(pi.hProcess,1);WaitForSingleObject(pi.hProcess,5000);}throw;}
      finally{if(pi.hThread!=IntPtr.Zero)CloseHandle(pi.hThread);if(pi.hProcess!=IntPtr.Zero)CloseHandle(pi.hProcess);if(input!=IntPtr.Zero&&input.ToInt64()!=-1)CloseHandle(input);if(inputWrite!=IntPtr.Zero)CloseHandle(inputWrite);if(output!=IntPtr.Zero&&output.ToInt64()!=-1)CloseHandle(output);if(error!=IntPtr.Zero&&error.ToInt64()!=-1)CloseHandle(error);if(environment!=IntPtr.Zero)Marshal.FreeHGlobal(environment);}
    }
    public static void Terminate(IntPtr handle){if(!TerminateJobObject(handle,1))Fail("TerminateJobObject");}
    public static int GetExitCode(IntPtr process){uint exitCode;if(!GetExitCodeProcess(process,out exitCode))Fail("GetExitCodeProcess");return unchecked((int)exitCode);}
    public static void Close(IntPtr handle){if(handle!=IntPtr.Zero)CloseHandle(handle);}
  }
}
'@
}

function New-WorkspaceChildEnvironment {
    param([hashtable]$Additional=@{},[switch]$AllowProxy)
    $environment=@{}
    foreach($name in @('SystemRoot','SystemDrive','TEMP','TMP','COMSPEC','NUMBER_OF_PROCESSORS','PROCESSOR_ARCHITECTURE')){$value=[Environment]::GetEnvironmentVariable($name,'Process');if(-not[string]::IsNullOrWhiteSpace($value)){$environment[$name]=$value}}
    $systemRoot=[Environment]::GetEnvironmentVariable('SystemRoot','Process')
    if($systemRoot){$environment['PATH']=@((Join-Path $systemRoot 'System32'),$systemRoot,$PSHOME)-join ';';$environment['PATHEXT']='.COM;.EXE;.BAT;.CMD'}
    foreach($name in @('USERPROFILE','LOCALAPPDATA','APPDATA','ProgramFiles','ProgramData')){$value=[Environment]::GetEnvironmentVariable($name,'Process');if(-not[string]::IsNullOrWhiteSpace($value)){$environment[$name]=$value}}
    if($AllowProxy){foreach($name in @('HTTP_PROXY','HTTPS_PROXY','NO_PROXY')){$value=[Environment]::GetEnvironmentVariable($name,'Process');if(-not[string]::IsNullOrWhiteSpace($value)){$environment[$name]=$value}}}
    foreach($name in $Additional.Keys){$environment[[string]$name]=[string]$Additional[$name]}
    return $environment
}

function ConvertTo-WorkspaceEnvironmentEntries {
    param([hashtable]$Environment)
    @($Environment.Keys|Sort-Object|ForEach-Object{$name=[string]$_;$value=[string]$Environment[$_];if($name -match '[=\x00]' -or $value -match '\x00'){throw 'Invalid child environment entry.'};'{0}={1}' -f $name,$value})
}

function ConvertTo-WorkspaceNativeArgument {
    param([AllowEmptyString()][string]$Value)
    if($null -eq $Value -or $Value.Length -eq 0){return '""'}
    if($Value -notmatch '[\s"]'){return $Value}
    return '"'+($Value -replace '(\\*)"','$1$1\"' -replace '(\\+)$','$1$1')+'"'
}

function New-WorkspaceJob { param([Parameter(Mandatory=$true)][string]$Name);[WorkspaceShare.NativeJob]::Create($Name) }
function Open-WorkspaceJob { param([Parameter(Mandatory=$true)][string]$Name);[WorkspaceShare.NativeJob]::Open($Name) }
function Add-ProcessToWorkspaceJob { param([Parameter(Mandatory=$true)][IntPtr]$Job,[Parameter(Mandatory=$true)][int]$ProcessId);[WorkspaceShare.NativeJob]::Assign($Job,$ProcessId) }
function Start-WorkspaceProcessInJob {
    param([Parameter(Mandatory=$true)][IntPtr]$Job,[Parameter(Mandatory=$true)][string]$FilePath,[string[]]$Arguments=@(),[string]$WorkingDirectory,[Parameter(Mandatory=$true)][string]$StdOutPath,[Parameter(Mandatory=$true)][string]$StdErrPath,[AllowNull()][string]$StandardInputText=$null,[hashtable]$Environment,[switch]$TestForceResumeFailure)
    if($null -eq $Environment){$Environment=New-WorkspaceChildEnvironment}
    $argumentText=(@($Arguments)|ForEach-Object{ConvertTo-WorkspaceNativeArgument $_}) -join ' '
    $entries=ConvertTo-WorkspaceEnvironmentEntries $Environment
    # The Process object is opened before the child resumes, so its handle and exit code survive even an immediate exit.
    [WorkspaceShare.NativeJob]::StartSuspended($Job,$FilePath,$argumentText,$WorkingDirectory,$StdOutPath,$StdErrPath,$StandardInputText,$entries,[bool]$TestForceResumeFailure)
}

function Read-WorkspaceBoundedText { param([string]$Path,[int]$MaximumBytes=4194304);if(-not(Test-Path -LiteralPath $Path -PathType Leaf)){return ''};$stream=New-Object IO.FileStream($Path,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::ReadWrite);try{$length=[Math]::Min([int64]$MaximumBytes,$stream.Length);[void]$stream.Seek(-$length,[IO.SeekOrigin]::End);$bytes=New-Object byte[] ([int]$length);[void]$stream.Read($bytes,0,$bytes.Length);try{(New-Object Text.UTF8Encoding($false,$true)).GetString($bytes)}catch{[Text.Encoding]::GetEncoding([Globalization.CultureInfo]::CurrentCulture.TextInfo.OEMCodePage).GetString($bytes)}}finally{$stream.Dispose()}}

function Invoke-WorkspaceNativeProcess {
    param([Parameter(Mandatory=$true)][IntPtr]$Job,[Parameter(Mandatory=$true)][string]$FilePath,[string[]]$Arguments=@(),[string]$WorkingDirectory,[ValidateRange(1,86400)][int]$TimeoutSeconds=300,[int[]]$ExpectedExitCodes=@(0),[string]$StdOutPath,[string]$StdErrPath,[AllowNull()][string]$StandardInputText=$null,[hashtable]$Environment,[switch]$KeepLogs)
    $base=if($WorkingDirectory){$WorkingDirectory}else{[IO.Path]::GetTempPath()};$id=[Guid]::NewGuid().ToString('N');$createdOut=[string]::IsNullOrWhiteSpace($StdOutPath);$createdErr=[string]::IsNullOrWhiteSpace($StdErrPath);if($createdOut){$StdOutPath=Join-Path $base ('.workspace-native-'+$id+'.stdout.log')};if($createdErr){$StdErrPath=Join-Path $base ('.workspace-native-'+$id+'.stderr.log')}
    $process=$null
    try{$process=Start-WorkspaceProcessInJob -Job $Job -FilePath $FilePath -Arguments $Arguments -WorkingDirectory $WorkingDirectory -StdOutPath $StdOutPath -StdErrPath $StdErrPath -StandardInputText $StandardInputText -Environment $Environment;$nativeProcessHandle=$process.Handle;if(-not$process.WaitForExit($TimeoutSeconds*1000)){try{Stop-WorkspaceJob -Job $Job}catch{};throw "Native process exceeded $TimeoutSeconds seconds; the session Job was terminated."};$exitCode=[WorkspaceShare.NativeJob]::GetExitCode($nativeProcessHandle);$stdout=Read-WorkspaceBoundedText $StdOutPath;$stderr=Read-WorkspaceBoundedText $StdErrPath;if($ExpectedExitCodes -notcontains $exitCode){throw "Native process failed with exit $exitCode. $stderr"};[pscustomobject]@{ExitCode=$exitCode;StdOut=$stdout;StdErr=$stderr;StdOutPath=$StdOutPath;StdErrPath=$StdErrPath}}
    finally{try{if($process){$process.Dispose()}}catch{};if(-not$KeepLogs){if($createdOut){Remove-Item -LiteralPath $StdOutPath -Force -ErrorAction SilentlyContinue};if($createdErr){Remove-Item -LiteralPath $StdErrPath -Force -ErrorAction SilentlyContinue}}}
}

function Stop-WorkspaceJob { param([Parameter(Mandatory=$true)][IntPtr]$Job);[WorkspaceShare.NativeJob]::Terminate($Job) }
function Close-WorkspaceJob { param([Parameter(Mandatory=$true)][IntPtr]$Job);[WorkspaceShare.NativeJob]::Close($Job) }

Export-ModuleMember -Function @('New-WorkspaceChildEnvironment','New-WorkspaceJob','Open-WorkspaceJob','Add-ProcessToWorkspaceJob','Start-WorkspaceProcessInJob','Invoke-WorkspaceNativeProcess','Stop-WorkspaceJob','Close-WorkspaceJob')
