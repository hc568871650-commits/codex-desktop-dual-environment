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
  // Read-only, x64 Windows only. Only the two allowlisted routing paths leave these methods.
  // PEB layout is not a public compatibility promise: fail closed on unsupported layout/access.
  public static string CodexHome(int pid) { return ReadEnvironmentPath(pid,"CODEX_HOME"); }
  public static string ElectronUserData(int pid) { return ReadEnvironmentPath(pid,"CODEX_ELECTRON_USER_DATA_PATH"); }
  static string ReadEnvironmentPath(int pid,string name) {
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
     if(c=='\0') { if(entry.Length==0) return null; string s=entry.ToString(); entry.Clear(); if(s.StartsWith(name+"=",StringComparison.OrdinalIgnoreCase)) return s.Substring(name.Length+1); }
     else entry.Append(c);
    }
    throw new InvalidOperationException("Environment limit exceeded");
   } finally {CloseHandle(h);}
  }
  static bool SameRoutingPath(string a,string b) {
   if(string.IsNullOrEmpty(a)||string.IsNullOrEmpty(b))return string.IsNullOrEmpty(a)&&string.IsNullOrEmpty(b);
   return string.Equals(System.IO.Path.GetFullPath(a).TrimEnd('\\'),System.IO.Path.GetFullPath(b).TrimEnd('\\'),StringComparison.OrdinalIgnoreCase);
  }
  // Same x64 process-parameter boundary as the existing routing-path reader. Never log command contents.
  static string ReadCommandLine(int pid) {
   if(IntPtr.Size!=8)throw new NotSupportedException();
   IntPtr h=OpenProcess(0x410,false,pid);if(h==IntPtr.Zero)throw new InvalidOperationException("Cannot inspect process");
   try {
    bool wow;if(!IsWow64Process(h,out wow)||wow)throw new NotSupportedException();
    var info=new IntPtr[6];int returned;if(NtQueryInformationProcess(h,0,info,48,out returned)!=0)throw new InvalidOperationException("Cannot query process");
    long parameters=BitConverter.ToInt64(Read(h,info[1].ToInt64()+0x20,8),0);
    byte[] command=Read(h,parameters+0x70,16);int length=BitConverter.ToUInt16(command,0),maximum=BitConverter.ToUInt16(command,2);
    long pointer=BitConverter.ToInt64(command,8);
    if(length<2||length>maximum||(length&1)!=0||pointer==0)throw new InvalidOperationException("Unsupported command layout");
    return Encoding.Unicode.GetString(Read(h,pointer,length));
   }finally{CloseHandle(h);}
  }
  // Fast focus is strictly for an already-discovered process with ONE visible main window.
  // It cannot launch an executable or force-show a hidden Electron overlay.
  static bool MatchesKnownProcess(Process process,int pid,long started,string path,string command,string home,string profile) {
     IntPtr held=process.Handle; // Hold a process handle until the last window ownership check.
     if(process.HasExited||Math.Abs(process.StartTime.ToUniversalTime().Ticks-started)>=10||!SameRoutingPath(process.MainModule.FileName,path))return false;
     string actualCommand=ReadCommandLine(pid);if(!string.Equals(actualCommand,command,StringComparison.Ordinal))return false;
     var args=Arguments(actualCommand);string actualProfile="";int profiles=0;
     for(int i=1;i<args.Length;i++) {
      if(args[i]=="--type"||args[i].StartsWith("--type="))return false;
      if(args[i]=="--user-data-dir"){if(++i>=args.Length)return false;actualProfile=args[i];profiles++;}
      else if(args[i].StartsWith("--user-data-dir=")){actualProfile=args[i].Substring(16);profiles++;}
     }
     if(profiles>1||!SameRoutingPath(actualProfile,profile)||!SameRoutingPath(CodexHome(pid),home))return false;
   return true;
  }
  public static bool IsKnownProcess(int pid,long started,string path,string command,string home,string profile) {
   try {using(var process=Process.GetProcessById(pid)){return MatchesKnownProcess(process,pid,started,path,command,home,profile);}}
   catch(ArgumentException){return false;}catch(InvalidOperationException){return false;}catch(System.ComponentModel.Win32Exception){return false;}catch(NotSupportedException){return false;}
  }
  // Notification attention check. Inspect only the foreground owner, never activate it.
  // Both routing paths and the executable must match; the official instance shares
  // the same image and window title, so neither alone establishes API ownership.
  public static bool IsInstanceForeground(string path,string home,string profile) {
   try {
    if(string.IsNullOrEmpty(path)||string.IsNullOrEmpty(home)||string.IsNullOrEmpty(profile))return false;
    IntPtr window=GetForegroundWindow();int pid;
    if(window==IntPtr.Zero||!IsWindowVisible(window)||IsIconic(window))return false;
    GetWindowThreadProcessId(window,out pid);
    using(var process=Process.GetProcessById(pid)) {
     if(!SameRoutingPath(process.MainModule.FileName,path))return false;
     string command=ReadCommandLine(pid);
     if(!MatchesKnownProcess(process,pid,process.StartTime.ToUniversalTime().Ticks,path,command,home,profile))return false;
     foreach(var candidate in Windows(pid)) {
      if(candidate.Handle==window.ToInt64()&&candidate.Visible)
       return !process.HasExited&&GetForegroundWindow()==window&&!IsIconic(window);
     }
    }
   }catch(ArgumentException){}catch(InvalidOperationException){}catch(System.ComponentModel.Win32Exception){}catch(NotSupportedException){}catch(System.IO.IOException){}
   return false;
  }
  public static string FocusKnownVisible(int pid,long started,string path,string command,string home,string profile) {
   try {
    using(var process=Process.GetProcessById(pid)) {
     if(!MatchesKnownProcess(process,pid,started,path,command,home,profile))return "Fallback";
     WindowInfo target=null;
     foreach(var window in Windows(pid)){if(!window.Visible)continue;if(target!=null)return "Fallback";target=window;}
     if(target==null||process.HasExited)return "Fallback";
     return FocusVisible(target.Handle,pid)?"Shown":"Running";
    }
   }catch(ArgumentException){return "Fallback";}catch(InvalidOperationException){return "Fallback";}catch(System.ComponentModel.Win32Exception){return "Fallback";}catch(NotSupportedException){return "Fallback";}
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
