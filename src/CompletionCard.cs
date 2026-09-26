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
  Color borderColor = Color.FromArgb(65,65,65);
  public Color BorderColor { get { return borderColor; } set { borderColor=value; Invalidate(); } }
  public CompletionCard() {
   DoubleBuffered=true; AutoDismissMilliseconds=15000;
   FormBorderStyle=FormBorderStyle.None; BackColor=Color.FromArgb(34,34,34);
   lifetime.Tick += delegate {
    if(Bounds.Contains(Cursor.Position) || ContainsFocus) lastInteraction=DateTime.UtcNow;
    if(AutoDismissMilliseconds>0 && (DateTime.UtcNow-lastInteraction).TotalMilliseconds>=AutoDismissMilliseconds) Close();
   };
  }
  protected override void OnShown(EventArgs e) { base.OnShown(e);lastInteraction=DateTime.UtcNow;lifetime.Start(); }
  protected override void OnPaint(PaintEventArgs e) {
   base.OnPaint(e);
   e.Graphics.SmoothingMode=SmoothingMode.AntiAlias;
      using(var path=new GraphicsPath()) {
    int d=22;path.AddArc(0,0,d,d,180,90);path.AddArc(Width-d-1,0,d,d,270,90);path.AddArc(Width-d-1,Height-d-1,d,d,0,90);path.AddArc(0,Height-d-1,d,d,90,90);path.CloseFigure();
    using(var pen=new Pen(BorderColor))e.Graphics.DrawPath(pen,path);
   }
  }
  protected override void Dispose(bool disposing) { if(disposing) lifetime.Dispose();base.Dispose(disposing); }
  // A completion should not interrupt typing in another application.
  protected override bool ShowWithoutActivation { get { return true; } }
 }
}
