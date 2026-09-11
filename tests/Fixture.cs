using System;
using System.Windows.Forms;
using System.IO;
using System.Diagnostics;
class Fixture {
 [STAThread] static void Main(string[] args) {
  string profile="";foreach(string arg in args)if(arg.StartsWith("--user-data-dir="))profile=arg.Substring(16);
  bool stubborn=Array.IndexOf(args,"--close-to-tray")>=0 || File.Exists(Path.Combine(profile,"stubborn.fixture"));
  var first=new Form {Text="Controller test primary",Width=360,Height=180};
  var second=new Form {Text="Controller test secondary",Width=360,Height=180};
  var overlay=new Form {Text="Internal overlay must stay hidden",Width=900,Height=700,FormBorderStyle=FormBorderStyle.FixedToolWindow,ShowInTaskbar=false,TopMost=true};
  // Create a titled hidden tool window, exactly the category the controller must not restore.
  var overlayHandle=overlay.Handle;
  if(stubborn){ first.FormClosing+=(s,e)=>{e.Cancel=true;first.Hide();}; second.FormClosing+=(s,e)=>{e.Cancel=true;second.Hide();}; }
  first.Shown+=(s,e)=>{second.Show(); if(Array.IndexOf(args,"--hidden")>=0 || File.Exists(Path.Combine(profile,"hidden.fixture"))){first.Hide();second.Hide();} else {first.WindowState=FormWindowState.Minimized;} };
  first.FormClosed+=(s,e)=>Application.ExitThread();
  Application.Run(first);
 }
}
