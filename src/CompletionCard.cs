using System.Windows.Forms;
using System;
using System.Drawing;
using System.Drawing.Drawing2D;
namespace CodexDual {
 public sealed class CompletionCard : Form {
  readonly Timer lifetime = new Timer { Interval=250 };
  DateTime lastInteraction;
  public int AutoDismissMilliseconds { get; set; }
  public string ThreadId { get; set; }
  public CompletionCard() {
   DoubleBuffered=true; AutoDismissMilliseconds=15000;
   FormBorderStyle=FormBorderStyle.None; BackColor=Color.FromArgb(250,250,249);
   lifetime.Tick += delegate {
    if(Bounds.Contains(Cursor.Position) || ContainsFocus) lastInteraction=DateTime.UtcNow;
    if(AutoDismissMilliseconds>0 && (DateTime.UtcNow-lastInteraction).TotalMilliseconds>=AutoDismissMilliseconds) Close();
   };
  }
  protected override void OnShown(EventArgs e) { base.OnShown(e);lastInteraction=DateTime.UtcNow;lifetime.Start(); }
  protected override void OnPaint(PaintEventArgs e) {
   base.OnPaint(e);
   e.Graphics.SmoothingMode=SmoothingMode.AntiAlias;
   using(var pen=new Pen(Color.FromArgb(216,216,214))) e.Graphics.DrawRectangle(pen,0,0,Width-1,Height-1);
  }
  protected override void Dispose(bool disposing) { if(disposing) lifetime.Dispose();base.Dispose(disposing); }
  // A completion should not interrupt typing in another application.
  protected override bool ShowWithoutActivation { get { return true; } }
 }
}
