Set-StrictMode -Version Latest

if (-not ('WorkspaceShare.NativePath' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Text;

namespace WorkspaceShare {
  public static class NativePath {
    const uint FILE_SHARE_READ=1, FILE_SHARE_WRITE=2, FILE_SHARE_DELETE=4;
    const uint OPEN_EXISTING=3, FILE_FLAG_BACKUP_SEMANTICS=0x02000000;
    const uint FILE_NAME_NORMALIZED=0, VOLUME_NAME_GUID=1;
    [StructLayout(LayoutKind.Sequential)] struct FILETIME { public uint Low, High; }
    [StructLayout(LayoutKind.Sequential)] struct BY_HANDLE_FILE_INFORMATION {
      public uint Attributes; public FILETIME Creation, Access, Write; public uint VolumeSerialNumber;
      public uint FileSizeHigh, FileSizeLow, NumberOfLinks, FileIndexHigh, FileIndexLow;
    }
    [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)]
    static extern IntPtr CreateFile(string name,uint access,uint share,IntPtr security,uint creation,uint flags,IntPtr template);
    [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)]
    static extern uint GetFinalPathNameByHandle(IntPtr handle,StringBuilder path,uint length,uint flags);
    [DllImport("kernel32.dll", SetLastError=true)] static extern bool GetFileInformationByHandle(IntPtr handle,out BY_HANDLE_FILE_INFORMATION info);
    [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr handle);
    static void Fail(string operation) { throw new Win32Exception(Marshal.GetLastWin32Error(), operation); }
    public static string[] ResolveDirectory(string path) {
      IntPtr handle=CreateFile(path,0,FILE_SHARE_READ|FILE_SHARE_WRITE|FILE_SHARE_DELETE,IntPtr.Zero,OPEN_EXISTING,FILE_FLAG_BACKUP_SEMANTICS,IntPtr.Zero);
      if(handle.ToInt64()==-1) Fail("CreateFile(directory)");
      try {
        BY_HANDLE_FILE_INFORMATION info; if(!GetFileInformationByHandle(handle,out info)) Fail("GetFileInformationByHandle");
        StringBuilder value=new StringBuilder(1024); uint size=GetFinalPathNameByHandle(handle,value,(uint)value.Capacity,FILE_NAME_NORMALIZED|VOLUME_NAME_GUID);
        if(size==0) Fail("GetFinalPathNameByHandle");
        if(size>=value.Capacity){value.Capacity=(int)size+1;size=GetFinalPathNameByHandle(handle,value,(uint)value.Capacity,FILE_NAME_NORMALIZED|VOLUME_NAME_GUID);if(size==0)Fail("GetFinalPathNameByHandle");}
        ulong index=((ulong)info.FileIndexHigh<<32)|info.FileIndexLow;
        return new[]{value.ToString(),info.VolumeSerialNumber.ToString("X8")+":"+index.ToString("X16")};
      } finally { CloseHandle(handle); }
    }
  }
}
'@
}

function Resolve-WorkspaceDirectoryIdentity {
    param([Parameter(Mandatory=$true)][string]$Path)
    $resolved = [WorkspaceShare.NativePath]::ResolveDirectory([IO.Path]::GetFullPath($Path))
    [pscustomobject]@{ FinalPath=$resolved[0].TrimEnd('\'); Identity=$resolved[1] }
}

Export-ModuleMember -Function 'Resolve-WorkspaceDirectoryIdentity'
