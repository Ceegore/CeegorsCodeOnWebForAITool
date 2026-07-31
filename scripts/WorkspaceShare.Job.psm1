Set-StrictMode -Version Latest
if(-not('WorkspaceShare.NativeJob' -as [type])){
Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Diagnostics;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;

namespace WorkspaceShare {
  public static class NativeJob {
    const uint JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE=0x2000;
    const int JobObjectExtendedLimitInformation=9;
    const uint CREATE_SUSPENDED=0x4,CREATE_NO_WINDOW=0x08000000,STARTF_USESTDHANDLES=0x100;
    const uint GENERIC_READ=0x80000000,GENERIC_WRITE=0x40000000,FILE_SHARE_READ=1,FILE_SHARE_WRITE=2,CREATE_ALWAYS=2,OPEN_EXISTING=3,FILE_ATTRIBUTE_NORMAL=0x80,HANDLE_FLAG_INHERIT=1;
    [StructLayout(LayoutKind.Sequential)] struct IO_COUNTERS{public ulong ReadOperationCount,WriteOperationCount,OtherOperationCount,ReadTransferCount,WriteTransferCount,OtherTransferCount;}
    [StructLayout(LayoutKind.Sequential)] struct BASIC_LIMIT{public long PerProcessUserTimeLimit,PerJobUserTimeLimit;public uint LimitFlags;public UIntPtr MinimumWorkingSetSize,MaximumWorkingSetSize;public uint ActiveProcessLimit;public UIntPtr Affinity;public uint PriorityClass,SchedulingClass;}
    [StructLayout(LayoutKind.Sequential)] struct EXT_LIMIT{public BASIC_LIMIT BasicLimitInformation;public IO_COUNTERS IoInfo;public UIntPtr ProcessMemoryLimit,JobMemoryLimit,PeakProcessMemoryUsed,PeakJobMemoryUsed;}
    [StructLayout(LayoutKind.Sequential,CharSet=CharSet.Unicode)] struct STARTUPINFO{public int cb;public string lpReserved,lpDesktop,lpTitle;public uint dwX,dwY,dwXSize,dwYSize,dwXCountChars,dwYCountChars,dwFillAttribute,dwFlags;public short wShowWindow,cbReserved2;public IntPtr lpReserved2,hStdInput,hStdOutput,hStdError;}
    [StructLayout(LayoutKind.Sequential)] struct PROCESS_INFORMATION{public IntPtr hProcess,hThread;public uint dwProcessId,dwThreadId;}
    [DllImport("kernel32.dll",CharSet=CharSet.Unicode,SetLastError=true)] static extern IntPtr CreateJobObject(IntPtr a,string n);
    [DllImport("kernel32.dll",CharSet=CharSet.Unicode,SetLastError=true)] static extern IntPtr OpenJobObject(uint access,bool inherit,string name);
    [DllImport("kernel32.dll",SetLastError=true)] static extern bool SetInformationJobObject(IntPtr h,int c,IntPtr i,uint l);
    [DllImport("kernel32.dll",SetLastError=true)] static extern bool AssignProcessToJobObject(IntPtr j,IntPtr p);
    [DllImport("kernel32.dll",SetLastError=true)] static extern bool TerminateJobObject(IntPtr j,uint e);
    [DllImport("kernel32.dll",SetLastError=true)] static extern bool CloseHandle(IntPtr h);
    [DllImport("kernel32.dll",SetLastError=true)] static extern uint ResumeThread(IntPtr h);
    [DllImport("kernel32.dll",SetLastError=true)] static extern bool SetHandleInformation(IntPtr h,uint mask,uint flags);
    [DllImport("kernel32.dll",CharSet=CharSet.Unicode,SetLastError=true)] static extern IntPtr CreateFile(string n,uint a,uint s,IntPtr sa,uint d,uint f,IntPtr t);
    [DllImport("kernel32.dll",CharSet=CharSet.Unicode,SetLastError=true)] static extern bool CreateProcess(string app,StringBuilder cmd,IntPtr pa,IntPtr ta,bool inherit,uint flags,IntPtr env,string cwd,ref STARTUPINFO si,out PROCESS_INFORMATION pi);
    static void Fail(string op){throw new Win32Exception(Marshal.GetLastWin32Error(),op);}
    public static IntPtr Create(string name){IntPtr h=CreateJobObject(IntPtr.Zero,name);if(h==IntPtr.Zero)Fail("CreateJobObject");EXT_LIMIT info=new EXT_LIMIT();info.BasicLimitInformation.LimitFlags=JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;int size=Marshal.SizeOf(info);IntPtr p=Marshal.AllocHGlobal(size);try{Marshal.StructureToPtr(info,p,false);if(!SetInformationJobObject(h,JobObjectExtendedLimitInformation,p,(uint)size))Fail("SetInformationJobObject");}finally{Marshal.FreeHGlobal(p);}return h;}
    public static IntPtr Open(string name){IntPtr h=OpenJobObject(0x1F001F,false,name);if(h==IntPtr.Zero)Fail("OpenJobObject");return h;}
    public static void Assign(IntPtr job,int pid){using(Process p=Process.GetProcessById(pid)){if(!AssignProcessToJobObject(job,p.Handle))Fail("AssignProcessToJobObject");}}
    public static int StartSuspended(IntPtr job,string file,string args,string cwd,string stdout,string stderr){IntPtr input=CreateFile("NUL",GENERIC_READ,FILE_SHARE_READ|FILE_SHARE_WRITE,IntPtr.Zero,OPEN_EXISTING,FILE_ATTRIBUTE_NORMAL,IntPtr.Zero);if(input.ToInt64()==-1)Fail("CreateFile stdin");IntPtr o=CreateFile(stdout,GENERIC_WRITE,FILE_SHARE_READ|FILE_SHARE_WRITE,IntPtr.Zero,CREATE_ALWAYS,FILE_ATTRIBUTE_NORMAL,IntPtr.Zero);if(o.ToInt64()==-1){CloseHandle(input);Fail("CreateFile stdout");}IntPtr e=CreateFile(stderr,GENERIC_WRITE,FILE_SHARE_READ|FILE_SHARE_WRITE,IntPtr.Zero,CREATE_ALWAYS,FILE_ATTRIBUTE_NORMAL,IntPtr.Zero);if(e.ToInt64()==-1){CloseHandle(input);CloseHandle(o);Fail("CreateFile stderr");}try{if(!SetHandleInformation(input,HANDLE_FLAG_INHERIT,HANDLE_FLAG_INHERIT)||!SetHandleInformation(o,HANDLE_FLAG_INHERIT,HANDLE_FLAG_INHERIT)||!SetHandleInformation(e,HANDLE_FLAG_INHERIT,HANDLE_FLAG_INHERIT))Fail("SetHandleInformation");STARTUPINFO si=new STARTUPINFO();si.cb=Marshal.SizeOf(si);si.dwFlags=STARTF_USESTDHANDLES;si.hStdInput=input;si.hStdOutput=o;si.hStdError=e;PROCESS_INFORMATION pi;if(!CreateProcess(file,new StringBuilder("\""+file+"\" "+args),IntPtr.Zero,IntPtr.Zero,true,CREATE_SUSPENDED|CREATE_NO_WINDOW,IntPtr.Zero,cwd,ref si,out pi))Fail("CreateProcess");try{if(!AssignProcessToJobObject(job,pi.hProcess)){TerminateJobObject(job,1);Fail("AssignProcessToJobObject");}if(ResumeThread(pi.hThread)==0xFFFFFFFF)Fail("ResumeThread");return (int)pi.dwProcessId;}finally{CloseHandle(pi.hThread);CloseHandle(pi.hProcess);}}finally{CloseHandle(input);CloseHandle(o);CloseHandle(e);}}
    public static void Terminate(IntPtr h){if(!TerminateJobObject(h,1))Fail("TerminateJobObject");}
    public static void Close(IntPtr h){if(h!=IntPtr.Zero)CloseHandle(h);}
  }
}
'@
}
function New-WorkspaceJob{param([Parameter(Mandatory=$true)][string]$Name);[WorkspaceShare.NativeJob]::Create($Name)}
function Open-WorkspaceJob{param([Parameter(Mandatory=$true)][string]$Name);[WorkspaceShare.NativeJob]::Open($Name)}
function Add-ProcessToWorkspaceJob{param([Parameter(Mandatory=$true)][IntPtr]$Job,[Parameter(Mandatory=$true)][int]$ProcessId);[WorkspaceShare.NativeJob]::Assign($Job,$ProcessId)}
function Start-WorkspaceProcessInJob{param([Parameter(Mandatory=$true)][IntPtr]$Job,[Parameter(Mandatory=$true)][string]$FilePath,[string[]]$Arguments=@(),[string]$WorkingDirectory,[Parameter(Mandatory=$true)][string]$StdOutPath,[Parameter(Mandatory=$true)][string]$StdErrPath);$quote={param([string]$v)if($v -notmatch '[\s"]'){$v}else{'"'+($v -replace '(\\*)"','$1$1\\"' -replace '(\\+)$','$1$1')+'"'}};$argsText=(@($Arguments)|ForEach-Object{&$quote $_}) -join ' ';$pid=[WorkspaceShare.NativeJob]::StartSuspended($Job,$FilePath,$argsText,$WorkingDirectory,$StdOutPath,$StdErrPath);[Diagnostics.Process]::GetProcessById($pid)}
function Stop-WorkspaceJob{param([Parameter(Mandatory=$true)][IntPtr]$Job);[WorkspaceShare.NativeJob]::Terminate($Job)}
function Close-WorkspaceJob{param([Parameter(Mandatory=$true)][IntPtr]$Job);[WorkspaceShare.NativeJob]::Close($Job)}
Export-ModuleMember -Function @('New-WorkspaceJob','Open-WorkspaceJob','Add-ProcessToWorkspaceJob','Start-WorkspaceProcessInJob','Stop-WorkspaceJob','Close-WorkspaceJob')
