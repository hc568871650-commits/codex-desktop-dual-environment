using System;
using System.IO;
using System.Threading;
using System.Windows.Forms;
using System.Management.Automation;
using System.Management.Automation.Runspaces;
class ControllerHost {
 [STAThread] static void Main() {
  string root=AppDomain.CurrentDomain.BaseDirectory;
  try {
   using(var runspace=RunspaceFactory.CreateRunspace()) {
    runspace.ApartmentState=ApartmentState.STA;runspace.ThreadOptions=PSThreadOptions.UseCurrentThread;runspace.Open();
    using(var ps=PowerShell.Create()) {
     ps.Runspace=runspace;
     ps.AddCommand("Set-ExecutionPolicy").AddParameter("Scope","Process").AddParameter("ExecutionPolicy","Bypass").AddParameter("Force").Invoke();
     ps.Commands.Clear();ps.Streams.Error.Clear();
     ps.AddCommand(Path.Combine(root,"src","Controller.ps1")).AddParameter("ConfigPath",Path.Combine(root,"instances.local.json")).AddParameter("Action","panel").Invoke();
     if(ps.HadErrors)MessageBox.Show("控制器未正常启动，请检查配置或使用命令行状态检查。","Codex 双环境");
    }
   }
  } catch(Exception e) {MessageBox.Show(e.Message,"Codex 双环境");}
 }
}
