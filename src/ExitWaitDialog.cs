using System;
using System.Diagnostics;
using System.Drawing;
using System.Windows.Forms;

namespace CodexDual {
 public sealed class ExitWaitResult {
  public bool Exited;
  public int PumpCount;
  public long ElapsedMilliseconds;
 }

 public static class ExitWaitDialog {
  public static ExitWaitResult Show(Process process, string title, string message, int timeoutMilliseconds, IWin32Window owner) {
   if(process==null)throw new ArgumentNullException("process");
   if(timeoutMilliseconds<1)throw new ArgumentOutOfRangeException("timeoutMilliseconds");
   var result=new ExitWaitResult();
   Exception failure=null;
   using(var dialog=new Form())
   using(var timer=new Timer())
   using(var status=new Label())
   using(var progress=new ProgressBar()) {
    dialog.Text=title;
    dialog.ClientSize=new Size(440,116);
    dialog.FormBorderStyle=FormBorderStyle.FixedDialog;
    dialog.MaximizeBox=false;
    dialog.MinimizeBox=false;
    dialog.ControlBox=false;
    dialog.ShowInTaskbar=false;
    dialog.StartPosition=owner==null?FormStartPosition.CenterScreen:FormStartPosition.CenterParent;
    var ownerControl=owner as Control;
    if(ownerControl!=null)dialog.Font=ownerControl.Font;
    status.Text=message;
    status.UseMnemonic=false;
    status.SetBounds(20,18,400,44);
    progress.SetBounds(20,73,400,18);
    progress.Style=ProgressBarStyle.Marquee;
    progress.MarqueeAnimationSpeed=24;
    dialog.Controls.Add(status);
    dialog.Controls.Add(progress);
    var watch=Stopwatch.StartNew();
    timer.Interval=100;
    timer.Tick+=delegate {
     result.PumpCount++;
     try {
      if(process.HasExited) { result.Exited=true;timer.Stop();dialog.Close();return; }
      int remaining=Math.Max(0,(int)Math.Ceiling((timeoutMilliseconds-watch.ElapsedMilliseconds)/1000.0));
      status.Text=message+" "+remaining+" s";
      if(watch.ElapsedMilliseconds>=timeoutMilliseconds) { timer.Stop();dialog.Close(); }
     } catch(Exception error) { failure=error;timer.Stop();dialog.Close(); }
    };
    dialog.Shown+=delegate { timer.Start(); };
    try { if(owner==null)dialog.ShowDialog();else dialog.ShowDialog(owner); }
    finally { timer.Stop();watch.Stop();result.ElapsedMilliseconds=watch.ElapsedMilliseconds; }
   }
   if(failure!=null)throw new InvalidOperationException("Process exit wait failed",failure);
   return result;
  }
 }
}
