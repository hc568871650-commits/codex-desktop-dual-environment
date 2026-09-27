using System;
using System.Diagnostics;
using System.Runtime.InteropServices;
namespace CodexBridgeTrial {
 [ComImport,Guid("F158268A-D5A5-45CE-99CF-00D6C3F3FC0A"),InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
 interface IDesktopAppXActivator {
  [PreserveSig] int Activate([MarshalAs(UnmanagedType.LPWStr)]string id,[MarshalAs(UnmanagedType.LPWStr)]string exe,[MarshalAs(UnmanagedType.LPWStr)]string args,out IntPtr handle);
  [PreserveSig] int ActivateWithOptions([MarshalAs(UnmanagedType.LPWStr)]string id,[MarshalAs(UnmanagedType.LPWStr)]string exe,[MarshalAs(UnmanagedType.LPWStr)]string args,uint options,uint parent,out IntPtr handle);
 }
 public static class AppxLauncher {
  [DllImport("kernel32.dll")]static extern bool CloseHandle(IntPtr h);
  [DllImport("kernel32.dll")]static extern uint GetProcessId(IntPtr h);
  public static uint Start(string id,string exe,string args) {
   object instance=Activator.CreateInstance(Type.GetTypeFromCLSID(new Guid("168EB462-775F-42AE-9111-D714B2306C2E")));
   IntPtr h=IntPtr.Zero;
   try{Marshal.ThrowExceptionForHR(((IDesktopAppXActivator)instance).ActivateWithOptions(id,exe,args,14,(uint)Process.GetCurrentProcess().Id,out h));return GetProcessId(h);}
   finally{if(h!=IntPtr.Zero)CloseHandle(h);Marshal.FinalReleaseComObject(instance);}
  }
 }
}
