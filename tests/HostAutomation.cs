using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;
namespace CodexDualTests {
 public static class HostAutomation {
  delegate bool Callback(IntPtr h,IntPtr p);
  [DllImport("user32.dll")] static extern bool EnumChildWindows(IntPtr h,Callback callback,IntPtr p);
  [DllImport("user32.dll")] static extern bool EnumWindows(Callback callback,IntPtr p);
  [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr h,out int pid);
  [DllImport("user32.dll",CharSet=CharSet.Unicode)] static extern int GetWindowText(IntPtr h,StringBuilder text,int count);
  [DllImport("user32.dll",CharSet=CharSet.Unicode)] static extern int GetClassName(IntPtr h,StringBuilder text,int count);
  [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr h);
  [DllImport("user32.dll")] static extern bool PostMessage(IntPtr h,uint msg,IntPtr w,IntPtr l);
  [DllImport("user32.dll",CharSet=CharSet.Unicode)] static extern IntPtr SendMessage(IntPtr h,uint msg,IntPtr w,string text);
  public static long[] Children(long parent,string classPart,string caption) {
   var result=new List<long>();
   EnumChildWindows(new IntPtr(parent),(h,p)=>{
    var cls=new StringBuilder(256);GetClassName(h,cls,256);
    var text=new StringBuilder(512);GetWindowText(h,text,512);
    if(IsWindowVisible(h)&&cls.ToString().IndexOf(classPart,StringComparison.OrdinalIgnoreCase)>=0&&(String.IsNullOrEmpty(caption)||text.ToString()==caption))result.Add(h.ToInt64());return true;
   },IntPtr.Zero);return result.ToArray();
  }
  public static void Click(long handle) {if(!PostMessage(new IntPtr(handle),0xF5,IntPtr.Zero,IntPtr.Zero))throw new InvalidOperationException("Cannot post button click");}
  public static void SetText(long handle,string text) {SendMessage(new IntPtr(handle),0xC,IntPtr.Zero,text);}
  // WM_SYSCOMMAND/SC_CLOSE matches the title-bar X. Bare WM_CLOSE is classified
  // as TaskManagerClosing by .NET Framework and intentionally disposes a form.
  public static void CloseLikeUser(long handle) {PostMessage(new IntPtr(handle),0x112,new IntPtr(0xF060),IntPtr.Zero);}
  public static string Describe(int pid) {
   var result=new StringBuilder();
   EnumWindows((h,p)=>{int owner;GetWindowThreadProcessId(h,out owner);if(owner!=pid)return true;
    var name=new StringBuilder(512);GetWindowText(h,name,512);result.AppendLine("Window "+h+" visible="+IsWindowVisible(h)+" "+name);
    EnumChildWindows(h,(child,ignored)=>{var text=new StringBuilder(512);GetWindowText(child,text,512);if(text.Length>0)result.AppendLine("  "+text);return true;},IntPtr.Zero);return true;
   },IntPtr.Zero);return result.ToString();
  }
 }
}
