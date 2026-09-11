using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Text;
namespace CodexDual {
 public sealed class WindowInfo { public long Handle; public int ProcessId; public string Title; public bool Visible; }
 public static class Native {
  public static bool IsGuiImage(string path) {
   using(var stream=new System.IO.FileStream(path,System.IO.FileMode.Open,System.IO.FileAccess.Read,System.IO.FileShare.ReadWrite|System.IO.FileShare.Delete))
   using(var reader=new System.IO.BinaryReader(stream)) {
    if(stream.Length<64 || reader.ReadUInt16()!=0x5A4D)return false;
    stream.Position=0x3C;int pe=reader.ReadInt32();if(pe<0 || (long)pe+94>stream.Length)return false;
    stream.Position=pe;if(reader.ReadUInt32()!=0x4550)return false;
    stream.Position=pe+24;ushort magic=reader.ReadUInt16();if(magic!=0x10B && magic!=0x20B)return false;
    stream.Position=pe+24+68;return reader.ReadUInt16()==2;
   }
  }
  [StructLayout(LayoutKind.Sequential,CharSet=CharSet.Unicode)] struct StartupInfo { public int cb; public string reserved,desktop,title; public int x,y,xSize,ySize,xChars,yChars,fill,flags; public short show,reserved2; public IntPtr reservedPtr,input,output,error; }
  [StructLayout(LayoutKind.Sequential)] struct StartupInfoEx {public StartupInfo startup;public IntPtr attributes;}
  [StructLayout(LayoutKind.Sequential)] struct ProcessInfo { public IntPtr process,thread; public int pid,tid; }
  [StructLayout(LayoutKind.Sequential)] struct SecurityAttributes {public int length;public IntPtr descriptor;[MarshalAs(UnmanagedType.Bool)] public bool inherit;}
  [DllImport("kernel32.dll",CharSet=CharSet.Unicode,SetLastError=true)] static extern IntPtr CreateFile(string name,uint access,uint share,ref SecurityAttributes security,uint disposition,uint flags,IntPtr template);
  [DllImport("kernel32.dll",CharSet=CharSet.Unicode,SetLastError=true)] static extern bool CreateProcess(string app,StringBuilder command,IntPtr processAttributes,IntPtr threadAttributes,bool inherit,uint flags,IntPtr environment,string cwd,ref StartupInfoEx startup,out ProcessInfo process);
  [DllImport("kernel32.dll",SetLastError=true)] static extern bool InitializeProcThreadAttributeList(IntPtr list,int count,int flags,ref IntPtr size);
  [DllImport("kernel32.dll",SetLastError=true)] static extern bool UpdateProcThreadAttribute(IntPtr list,uint flags,IntPtr attribute,IntPtr value,IntPtr size,IntPtr previous,IntPtr returned);
  [DllImport("kernel32.dll")] static extern void DeleteProcThreadAttributeList(IntPtr list);
  public static int StartDetached(ProcessStartInfo info) {
   // Stable NUL handles prevent background Electron logs from leaking into a terminal or breaking when the controller exits.
   var security=new SecurityAttributes{length=Marshal.SizeOf(typeof(SecurityAttributes)),inherit=true};
   IntPtr nul=CreateFile("NUL",0xC0000000,3,ref security,3,0,IntPtr.Zero);
   if(nul==new IntPtr(-1))throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error());
   IntPtr environment=IntPtr.Zero,attributes=IntPtr.Zero,handles=IntPtr.Zero;int bytes=0;bool initialized=false;
   try {
    var entries=new List<string>();foreach(string key in info.EnvironmentVariables.Keys)entries.Add(key+"="+info.EnvironmentVariables[key]);entries.Sort(StringComparer.OrdinalIgnoreCase);
    string block=string.Join("\0",entries.ToArray())+"\0\0";bytes=(block.Length+1)*2;environment=Marshal.StringToHGlobalUni(block);
    IntPtr size=IntPtr.Zero;InitializeProcThreadAttributeList(IntPtr.Zero,1,0,ref size);attributes=Marshal.AllocHGlobal(size);
    if(!InitializeProcThreadAttributeList(attributes,1,0,ref size))throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error());initialized=true;
    handles=Marshal.AllocHGlobal(IntPtr.Size);Marshal.WriteIntPtr(handles,nul);
    if(!UpdateProcThreadAttribute(attributes,0,new IntPtr(0x20002),handles,new IntPtr(IntPtr.Size),IntPtr.Zero,IntPtr.Zero))throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error());
    var startup=new StartupInfoEx{startup=new StartupInfo{cb=Marshal.SizeOf(typeof(StartupInfoEx)),flags=0x100,input=nul,output=nul,error=nul},attributes=attributes};ProcessInfo pi;
    if(!CreateProcess(info.FileName,new StringBuilder("\""+info.FileName+"\" "+info.Arguments),IntPtr.Zero,IntPtr.Zero,true,0x80000|0x400|0x08000000,environment,string.IsNullOrEmpty(info.WorkingDirectory)?null:info.WorkingDirectory,ref startup,out pi))throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error());
    CloseHandle(pi.thread);CloseHandle(pi.process);return pi.pid;
   }finally{if(initialized)DeleteProcThreadAttributeList(attributes);if(attributes!=IntPtr.Zero)Marshal.FreeHGlobal(attributes);if(handles!=IntPtr.Zero)Marshal.FreeHGlobal(handles);if(environment!=IntPtr.Zero){for(int n=0;n<bytes;n++)Marshal.WriteByte(environment,n,0);Marshal.FreeHGlobal(environment);}CloseHandle(nul);}
  }
  [DllImport("kernel32.dll", SetLastError=true)] static extern IntPtr OpenProcess(uint access, bool inherit, int pid);
  [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr h);
  [DllImport("kernel32.dll")] static extern bool ReadProcessMemory(IntPtr h, IntPtr address, byte[] buffer, int size, out IntPtr read);
  [DllImport("kernel32.dll")] static extern bool IsWow64Process(IntPtr h, out bool wow64);
  [DllImport("ntdll.dll")] static extern int NtQueryInformationProcess(IntPtr h,int kind,IntPtr[] info,int size,out int returned);
  [DllImport("shell32.dll")] static extern IntPtr CommandLineToArgvW([MarshalAs(UnmanagedType.LPWStr)] string command, out int count);
  [DllImport("kernel32.dll")] static extern IntPtr LocalFree(IntPtr value);
  delegate bool EnumProc(IntPtr h,IntPtr p);
  [DllImport("user32.dll")] static extern bool EnumWindows(EnumProc callback,IntPtr p);
  [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr h,out int pid);
  [DllImport("user32.dll",CharSet=CharSet.Unicode)] static extern int GetWindowText(IntPtr h,StringBuilder text,int length);
  [DllImport("user32.dll",CharSet=CharSet.Unicode)] static extern int GetClassName(IntPtr h,StringBuilder text,int length);
  [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr h);
  [DllImport("user32.dll")] static extern bool IsIconic(IntPtr h);
  [DllImport("user32.dll",EntryPoint="GetWindowLongPtrW")] static extern IntPtr GetWindowLongPtr(IntPtr h,int index);
  [DllImport("user32.dll")] static extern bool ShowWindowAsync(IntPtr h,int command);
  [DllImport("user32.dll")] static extern bool SetForegroundWindow(IntPtr h);
  [DllImport("user32.dll")] static extern bool PostMessage(IntPtr h,uint message,IntPtr w,IntPtr l);
  [DllImport("user32.dll")] static extern IntPtr GetForegroundWindow();
  public static string[] Arguments(string command) {
   int count; IntPtr ptr=CommandLineToArgvW(command,out count); if(ptr==IntPtr.Zero) throw new InvalidOperationException("Cannot parse command line");
   try { var result=new string[count]; for(int i=0;i<count;i++) result[i]=Marshal.PtrToStringUni(Marshal.ReadIntPtr(ptr,i*IntPtr.Size)); return result; } finally {LocalFree(ptr);}
  }
  static byte[] Read(IntPtr h,long address,int size) {
   var data=new byte[size]; IntPtr read;
   if(!ReadProcessMemory(h,new IntPtr(address),data,size,out read)||read.ToInt64()!=size) throw new InvalidOperationException("Process environment unavailable");
   return data;
  }
  // Read-only, x64 Windows only. Only CODEX_HOME leaves this method; no credentials are returned or logged.
  // PEB layout is not a public compatibility promise: fail closed on unsupported layout/access.
  public static string CodexHome(int pid) {
   if(IntPtr.Size!=8) throw new NotSupportedException("64-bit PowerShell required");
   IntPtr h=OpenProcess(0x410,false,pid); if(h==IntPtr.Zero) throw new InvalidOperationException("Cannot inspect process");
   try {
    bool wow; if(!IsWow64Process(h,out wow)||wow) throw new NotSupportedException("Only native x64 targets supported");
    var info=new IntPtr[6];int returned;
    if(NtQueryInformationProcess(h,0,info,48,out returned)!=0) throw new InvalidOperationException("Cannot query process");
    long parameters=BitConverter.ToInt64(Read(h,info[1].ToInt64()+0x20,8),0);
    long environment=BitConverter.ToInt64(Read(h,parameters+0x80,8),0);
    var entry=new StringBuilder();
    for(int offset=0;offset<1048576;offset+=2) {
     char c=(char)BitConverter.ToUInt16(Read(h,environment+offset,2),0);
     if(c=='\0') { if(entry.Length==0) return null; string s=entry.ToString(); entry.Clear(); if(s.StartsWith("CODEX_HOME=",StringComparison.OrdinalIgnoreCase)) return s.Substring(11); }
     else entry.Append(c);
    }
    throw new InvalidOperationException("Environment limit exceeded");
   } finally {CloseHandle(h);}
  }
  public static WindowInfo[] Windows(int pid) {
   var list=new List<WindowInfo>();
   EnumWindows(delegate(IntPtr h,IntPtr p) {int owner;GetWindowThreadProcessId(h,out owner);if(owner!=pid)return true;
    // Electron also owns captionless topmost overlays. Restoring those can cover the desktop/taskbar.
    // Tool/no-activate windows are never user-selectable main windows, even when they have a title.
    long extended=GetWindowLongPtr(h,-20).ToInt64();
    if((extended & (0x80L|0x08000000L))!=0)return true;
    var cls=new StringBuilder(256);GetClassName(h,cls,256);
    if(cls.ToString()!="Chrome_WidgetWin_1" && !cls.ToString().StartsWith("WindowsForms10.Window"))return true;
    var title=new StringBuilder(2048);GetWindowText(h,title,2048); if(title.Length==0)return true;
    list.Add(new WindowInfo{Handle=h.ToInt64(),ProcessId=pid,Title=title.ToString(),Visible=IsWindowVisible(h)}); return true;
   },IntPtr.Zero);return list.ToArray();
  }
  static void CheckWindow(long handle,int pid) {int owner;IntPtr h=new IntPtr(handle);GetWindowThreadProcessId(h,out owner);if(owner!=pid || (GetWindowLongPtr(h,-20).ToInt64() & (0x80L|0x08000000L))!=0)throw new InvalidOperationException("Window changed or is an internal tool window; retry");}
  public static bool FocusVisible(long handle,int pid) {
   CheckWindow(handle,pid);IntPtr h=new IntPtr(handle);
   if(!IsWindowVisible(h))throw new InvalidOperationException("Hidden window requires native application activation; refusing direct ShowWindow");
   if(IsIconic(h))ShowWindowAsync(h,9);
   return SetForegroundWindow(h);
  }
  public static void Close(long handle,int pid) {CheckWindow(handle,pid);if(!PostMessage(new IntPtr(handle),0x10,IntPtr.Zero,IntPtr.Zero))throw new InvalidOperationException("Close request failed");}
  public static long Foreground() { return GetForegroundWindow().ToInt64(); }
 }
}
