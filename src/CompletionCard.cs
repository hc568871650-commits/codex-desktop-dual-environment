using System.Windows.Forms;
using System;
using System.Drawing;
using System.Drawing.Drawing2D;
namespace CodexDual {
 // One accessible click surface shared by completion, question and feedback cards.
 // The close control is a sibling, so closing never bubbles into opening a task.
 public sealed class NoticeBody : Button {
  public NoticeBody() {
   Name="NoticeBody";FlatStyle=FlatStyle.Flat;FlatAppearance.BorderSize=0;
   SetStyle(ControlStyles.UserPaint|ControlStyles.AllPaintingInWmPaint|ControlStyles.OptimizedDoubleBuffer|ControlStyles.ResizeRedraw,true);
   UseVisualStyleBackColor=false;Cursor=Cursors.Hand;TextAlign=ContentAlignment.TopLeft;
  }
  protected override void OnPaint(PaintEventArgs e) {
   Color background=Parent==null?BackColor:Parent.BackColor;var ink=ForeColor;
   e.Graphics.Clear(background);
   int top=12;
   using(var title=new Font(Font.FontFamily,Font.Size+2.5f,FontStyle.Bold))
    TextRenderer.DrawText(e.Graphics,Text,title,new Rectangle(12,top,Math.Max(1,Width-24),Math.Max(1,Height-top-10)),ink,TextFormatFlags.Left|TextFormatFlags.Top|TextFormatFlags.WordBreak|TextFormatFlags.EndEllipsis|TextFormatFlags.NoPrefix);
   if(Focused&&ShowFocusCues)ControlPaint.DrawFocusRectangle(e.Graphics,new Rectangle(3,3,Width-7,Height-7),ink,background);
  }
 }
 public sealed class CompletionCard : Form {
  readonly Timer lifetime = new Timer { Interval=250 };
  readonly Timer fade = new Timer { Interval=30 };
  readonly System.Diagnostics.Stopwatch elapsed = System.Diagnostics.Stopwatch.StartNew();
  long lastTick;
  double remainingMilliseconds;
  bool fadingOut;
  public int AutoDismissMilliseconds { get; set; }
  public bool FadeEnabled { get; set; }
  public bool PauseDismissal { get; set; }
  public void SetDisplaySettings(int milliseconds, bool fadeEnabled) {
   AutoDismissMilliseconds=milliseconds; FadeEnabled=fadeEnabled;
   fadingOut=false;fade.Stop();
   remainingMilliseconds=milliseconds;lastTick=elapsed.ElapsedMilliseconds;
   if(Visible) Opacity=1;
   else if(fadeEnabled) Opacity=0.01;
   if(IsHandleCreated) { if(milliseconds>0) lifetime.Start(); else lifetime.Stop(); }
  }
  public string ThreadId { get; set; }
  Color borderColor = Color.FromArgb(65,65,65);
  public Color BorderColor { get { return borderColor; } set { borderColor=value; Invalidate(); } }
  public CompletionCard() {
   DoubleBuffered=true; AutoDismissMilliseconds=15000; FadeEnabled=false;
   FormBorderStyle=FormBorderStyle.None; BackColor=Color.FromArgb(34,34,34);
   lifetime.Tick += delegate {
    var now=elapsed.ElapsedMilliseconds;
    if(!PauseDismissal && AutoDismissMilliseconds>0 && !fadingOut) {
     remainingMilliseconds-=now-lastTick;
     if(remainingMilliseconds<=0) { if(FadeEnabled) { fadingOut=true;fade.Start(); } else { lifetime.Stop();Close(); } }
    }
    lastTick=now;
   };
   fade.Tick += delegate {
    if(fadingOut) {
     if(PauseDismissal) {
      fadingOut=false;remainingMilliseconds=AutoDismissMilliseconds;lastTick=elapsed.ElapsedMilliseconds;
      Opacity=1;fade.Stop();return;
     }
     Opacity=Math.Max(0,Opacity-0.2); if(Opacity<=0) Close();
    }
    else { Opacity=Math.Min(1,Opacity+0.2); if(Opacity>=1) fade.Stop(); }
   };
  }
  protected override void OnShown(EventArgs e) {
   base.OnShown(e);
   if(FadeEnabled) Opacity=0.01;
   lastTick=elapsed.ElapsedMilliseconds;remainingMilliseconds=AutoDismissMilliseconds;
   if(AutoDismissMilliseconds>0) lifetime.Start();
   if(FadeEnabled) fade.Start();
  }
  GraphicsPath CardOutline() {
   var path=new GraphicsPath();
   int width=Math.Max(2,ClientSize.Width),height=Math.Max(2,ClientSize.Height);
   int d=Math.Min(22,Math.Min(width-1,height-1));
   path.AddArc(0,0,d,d,180,90);path.AddArc(width-d-1,0,d,d,270,90);
   path.AddArc(width-d-1,height-d-1,d,d,0,90);path.AddArc(0,height-d-1,d,d,90,90);path.CloseFigure();
   return path;
  }
  protected override void OnSizeChanged(EventArgs e) {
   base.OnSizeChanged(e);
   if(ClientSize.Width<2 || ClientSize.Height<2)return;
   using(var path=CardOutline()) {
    var old=Region;Region=new Region(path);if(old!=null)old.Dispose();
   }
   Invalidate();
  }
  protected override void OnPaint(PaintEventArgs e) {
   base.OnPaint(e);
   e.Graphics.SmoothingMode=SmoothingMode.AntiAlias;
   using(var path=CardOutline()) {
    using(var pen=new Pen(BorderColor))e.Graphics.DrawPath(pen,path);
   }
  }
  protected override void Dispose(bool disposing) { if(disposing) { lifetime.Dispose();fade.Dispose(); }base.Dispose(disposing); }
  // A completion should not interrupt typing in another application.
  protected override bool ShowWithoutActivation { get { return true; } }
 }
}
