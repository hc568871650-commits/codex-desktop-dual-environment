using System;
using System.IO;
using System.Management.Automation;
using System.Management.Automation.Runspaces;
using System.Threading;
using System.Windows.Forms;
class NotificationExperiment {
 [STAThread] static void Main(string[] args) {
  string output=null;
  try {
   if(args.Length!=4)throw new ArgumentException("Expected script, config, output, duration.");
   output=Path.GetFullPath(args[2]);
   Environment.SetEnvironmentVariable("PSModulePath",null);
   using(var runspace=RunspaceFactory.CreateRunspace()) {
    runspace.ApartmentState=ApartmentState.STA;runspace.ThreadOptions=PSThreadOptions.UseCurrentThread;runspace.Open();
    using(var ps=PowerShell.Create()) {
     ps.Runspace=runspace;
     ps.AddCommand("Set-ExecutionPolicy").AddParameter("Scope","Process").AddParameter("ExecutionPolicy","Bypass").AddParameter("Force").Invoke();
     ps.Commands.Clear();ps.Streams.Error.Clear();
     ps.AddCommand(Path.GetFullPath(args[0])).AddParameter("ConfigPath",Path.GetFullPath(args[1])).AddParameter("OutputDirectory",output).AddParameter("DurationSeconds",int.Parse(args[3])).Invoke();
     if(ps.HadErrors)throw new InvalidOperationException(ps.Streams.Error[0].ToString());
    }
   }
  }catch(Exception e){
   if(output!=null)File.WriteAllText(Path.Combine(output,"host-error.txt"),e.ToString());
   MessageBox.Show("实验未能完成，请检查实验目录中的记录。","Codex 通知实验");
  }
 }
}
