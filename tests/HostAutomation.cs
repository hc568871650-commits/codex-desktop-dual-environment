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
  [DllImport("user32.dll")] static extern bool IsWindowEnabled(IntPtr h);
  [DllImport("user32.dll")] static extern bool PostMessage(IntPtr h,uint msg,IntPtr w,IntPtr l);
  [DllImport("user32.dll")] static extern IntPtr GetDlgItem(IntPtr h,int id);
  [DllImport("user32.dll")] static extern IntPtr SendMessageTimeout(IntPtr h,uint msg,IntPtr w,IntPtr l,uint flags,uint timeout,out IntPtr result);
  public static bool Responds(long handle) {IntPtr result;return SendMessageTimeout(new IntPtr(handle),0,IntPtr.Zero,IntPtr.Zero,2,500,out result)!=IntPtr.Zero;}
  public static long FindDialog(int pid,string title) {
   long found=0;
   EnumWindows((h,p)=>{int owner;GetWindowThreadProcessId(h,out owner);if(owner!=pid || !IsWindowVisible(h))return true;
    var text=new StringBuilder(512);GetWindowText(h,text,512);if(text.ToString()==title){found=h.ToInt64();return false;}return true;
   },IntPtr.Zero);return found;
  }
  public static void Answer(long handle,int id) {
   IntPtr button=IntPtr.Zero;
   for(int attempt=0;attempt<40;attempt++){button=GetDlgItem(new IntPtr(handle),id);if(button!=IntPtr.Zero)break;System.Threading.Thread.Sleep(50);}
   if(button==IntPtr.Zero && id==1){var only=Children(handle,"BUTTON",null);if(only.Length==1)button=new IntPtr(only[0]);}
   if(button==IntPtr.Zero)throw new InvalidOperationException("Dialog button missing: "+id);Click(button.ToInt64());
  }
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
  public static void CloseLikeUser(long handle) {
   var window=new IntPtr(handle);
   for(int attempt=0;attempt<60 && !IsWindowEnabled(window);attempt++)System.Threading.Thread.Sleep(50);
   if(!IsWindowEnabled(window))throw new InvalidOperationException("Close target is not enabled");
   IntPtr result;
   if(SendMessageTimeout(window,0x112,new IntPtr(0xF060),IntPtr.Zero,2,5000,out result)==IntPtr.Zero)throw new InvalidOperationException("Close target did not respond");
  }
  public static string Describe(int pid) {
   var result=new StringBuilder();
   EnumWindows((h,p)=>{int owner;GetWindowThreadProcessId(h,out owner);if(owner!=pid)return true;
    var name=new StringBuilder(512);GetWindowText(h,name,512);result.AppendLine("Window "+h+" visible="+IsWindowVisible(h)+" enabled="+IsWindowEnabled(h)+" "+name);
    EnumChildWindows(h,(child,ignored)=>{var text=new StringBuilder(512);GetWindowText(child,text,512);if(text.Length>0)result.AppendLine("  "+text);return true;},IntPtr.Zero);return true;
   },IntPtr.Zero);return result.ToString();
  }
 }
}
