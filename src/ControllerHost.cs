using System;
using System.IO;
using System.Threading;
using System.Windows.Forms;
using System.Management.Automation;
using System.Management.Automation.Runspaces;
class ControllerHost {
 static string tracePath;
 static void Trace(string stage) {
  try {
   Directory.CreateDirectory(Path.GetDirectoryName(tracePath));
   File.AppendAllText(tracePath,DateTimeOffset.Now.ToString("o")+" pid="+System.Diagnostics.Process.GetCurrentProcess().Id+" "+stage+Environment.NewLine);
  } catch { /* Diagnostics must not prevent startup, including read-only installations. */ }
 }
 [STAThread] static void Main(string[] args) {
  string root=AppDomain.CurrentDomain.BaseDirectory;
  tracePath=Path.Combine(root,"state","controller-startup.log");
  Trace("host-start");
  try {
   string config=Path.Combine(root,"instances.local.json"), action="panel";
   for(int i=0;i<args.Length;i++) {
    if(args[i]=="--background")action="tray";
    else if(args[i]=="--configure")action="configure";
    else if(args[i]=="--config" && i+1<args.Length)config=Path.GetFullPath(args[++i]);
    else throw new ArgumentException("不支持的控制器参数。");
   }
   Trace("mode-"+action);
   using(var runspace=RunspaceFactory.CreateRunspace()) {
    runspace.ApartmentState=ApartmentState.STA;runspace.ThreadOptions=PSThreadOptions.UseCurrentThread;runspace.Open();
    using(var ps=PowerShell.Create()) {
     ps.Runspace=runspace;
     ps.AddCommand("Set-ExecutionPolicy").AddParameter("Scope","Process").AddParameter("ExecutionPolicy","Bypass").AddParameter("Force").Invoke();
     ps.Commands.Clear();ps.Streams.Error.Clear();
     ps.AddCommand(Path.Combine(root,"src","Controller.ps1")).AddParameter("ConfigPath",config).AddParameter("Action",action).AddParameter("LifecycleObserver",new Action<string>(Trace)).Invoke();
     foreach(var error in ps.Streams.Error)Trace("pipeline-error-"+error.Exception.GetType().FullName);
     if(ps.HadErrors)MessageBox.Show("控制器未正常启动，请检查配置或使用命令行状态检查。","Codex 双环境");
    }
   }
  } catch(Exception e) {Trace("host-failed-"+e.GetType().FullName);MessageBox.Show(e.Message,"Codex 双环境");}
  finally {Trace("host-exit");}
 }
}
