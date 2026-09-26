using System;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Windows.Forms;
using System.Runtime.InteropServices;
using Microsoft.Win32;
namespace CodexDual {
 public static class AppTheme {
  static string mode="dark",accent="neutral";
  static bool dark=true;
  static Color background=Color.FromArgb(24,24,24),sidebar=Color.FromArgb(31,33,35),surface=Color.FromArgb(34,34,34),border=Color.FromArgb(65,65,65),textColor=Color.FromArgb(238,238,238),muted=Color.FromArgb(166,166,166);
  static Color hover=Color.FromArgb(62,62,62),pressed=Color.FromArgb(72,72,72),input=Color.FromArgb(34,34,34),primary=Color.FromArgb(242,242,242),primaryText=Color.FromArgb(28,28,28),accentColor=Color.FromArgb(238,238,238),button=Color.FromArgb(51,51,51),selected=Color.FromArgb(57,59,61),focus=Color.FromArgb(151,185,229),disabled=Color.FromArgb(146,146,146);
  public static string Mode{get{return mode;}} public static string Accent{get{return accent;}} public static bool IsDark{get{return dark;}}
  public static Color Background{get{return background;}} public static Color Sidebar{get{return sidebar;}} public static Color Surface{get{return surface;}} public static Color Border{get{return border;}} public static Color Text{get{return textColor;}} public static Color Muted{get{return muted;}}
  public static Color Hover{get{return hover;}} public static Color Pressed{get{return pressed;}} public static Color Input{get{return input;}} public static Color Primary{get{return primary;}} public static Color PrimaryText{get{return primaryText;}} public static Color AccentColor{get{return accentColor;}}
  public static Color Button{get{return button;}} public static Color Selected{get{return selected;}} public static Color Focus{get{return focus;}} public static Color Disabled{get{return disabled;}}
  public static Color PrimaryHover{get{return dark?ControlPaint.Dark(primary,0.06f):ControlPaint.Light(primary,0.10f);}}
  public static Color PrimaryPressed{get{return dark?ControlPaint.Dark(primary,0.20f):ControlPaint.Light(primary,0.18f);}}
  static bool SystemIsDark(){try{using(var key=Registry.CurrentUser.OpenSubKey(@"Software\Microsoft\Windows\CurrentVersion\Themes\Personalize")){if(key!=null){object value=key.GetValue("AppsUseLightTheme");if(value!=null)return Convert.ToInt32(value)!=1;}}}catch(Exception){}return true;}
  // Returns whether the rendered palette changed; the requested mode is retained even if system currently matches it.
  public static bool SetAppearance(string newMode,string newAccent){
   newMode=(newMode??"dark").ToLowerInvariant();if(newMode!="dark"&&newMode!="light"&&newMode!="system")newMode="dark";
   newAccent=(newAccent??"neutral").ToLowerInvariant();if(newAccent!="neutral"&&newAccent!="blue"&&newAccent!="green"&&newAccent!="purple")newAccent="neutral";
   bool nextDark=newMode=="system"?SystemIsDark():newMode=="dark";
   bool changed=dark!=nextDark||accent!=newAccent;mode=newMode;accent=newAccent;dark=nextDark;
   background=nextDark?Color.FromArgb(24,24,24):Color.FromArgb(248,249,250);
   sidebar=nextDark?Color.FromArgb(31,33,35):Color.FromArgb(237,239,241);
   surface=nextDark?Color.FromArgb(34,34,34):Color.White;
   border=nextDark?Color.FromArgb(65,65,65):Color.FromArgb(207,211,215);
   textColor=nextDark?Color.FromArgb(238,238,238):Color.FromArgb(31,34,38);
   muted=nextDark?Color.FromArgb(166,166,166):Color.FromArgb(91,96,102);
   input=surface;button=nextDark?Color.FromArgb(51,51,51):Color.FromArgb(241,243,245);
   hover=nextDark?Color.FromArgb(62,62,62):Color.FromArgb(225,230,234);
   pressed=nextDark?Color.FromArgb(72,72,72):Color.FromArgb(210,217,223);
   selected=nextDark?Color.FromArgb(57,59,61):Color.FromArgb(220,226,231);
   disabled=nextDark?Color.FromArgb(146,146,146):Color.FromArgb(111,117,123);
   if(newAccent=="blue")accentColor=nextDark?Color.FromArgb(130,180,249):Color.FromArgb(29,93,180);
   else if(newAccent=="green")accentColor=nextDark?Color.FromArgb(117,201,151):Color.FromArgb(24,121,72);
   else if(newAccent=="purple")accentColor=nextDark?Color.FromArgb(189,156,236):Color.FromArgb(119,73,171);
   else accentColor=textColor;
   primary=newAccent=="neutral"?(nextDark?Color.FromArgb(242,242,242):Color.FromArgb(39,43,48)):accentColor;
   primaryText=nextDark?Color.FromArgb(28,28,28):Color.White;
   focus=newAccent=="neutral"?(nextDark?Color.FromArgb(151,185,229):Color.FromArgb(44,102,184)):accentColor;
   return changed;
  }
  public static void ApplyTo(Control root){if(root==null||root.IsDisposed)return;ApplyControl(root);}
  static void ApplyControl(Control control){
   string name=control.Name??"";
   bool isSurface=control is Surface || name.Equals("Surface",StringComparison.OrdinalIgnoreCase) || control.GetType().Name=="TrayPopup" || control.GetType().Name=="CompletionCard";
   bool isInput=control is TextBoxBase || control is ComboBox || control is ListBox || control is NumericUpDown;
   if(name.Equals("Sidebar",StringComparison.OrdinalIgnoreCase))control.BackColor=Sidebar;
   else if(isSurface)control.BackColor=Surface;
   else if(isInput)control.BackColor=Input;
   else if(control is Label)control.BackColor=control.Parent==null?Background:control.Parent.BackColor;
   else if(control is QuietMenu || control is ContextMenuStrip)control.BackColor=Surface;
   else if(control is QuickActionButton)control.BackColor=Surface;
   else if(control is Button)control.BackColor=Button;
   else control.BackColor=control.Parent==null?Background:control.Parent.BackColor;
   control.ForeColor=(name.Equals("Muted",StringComparison.OrdinalIgnoreCase)||name.Equals("CaptionMuted",StringComparison.OrdinalIgnoreCase))?Muted:Text;
   var borderProperty=control.GetType().GetProperty("BorderColor");if(borderProperty!=null&&borderProperty.CanWrite&&borderProperty.PropertyType==typeof(Color))borderProperty.SetValue(control,Border,null);
   var shell=control as ShellForm;if(shell!=null)shell.UpdateWindowTheme();
   var menu=control as ContextMenuStrip;if(menu!=null)ApplyMenu(menu);
   if(control.ContextMenuStrip!=null)ApplyMenu(control.ContextMenuStrip);
   foreach(Control child in control.Controls)ApplyControl(child);
   control.Invalidate();
  }
  static void ApplyMenu(ContextMenuStrip menu){menu.BackColor=Surface;menu.ForeColor=Text;foreach(ToolStripItem item in menu.Items)ApplyMenuItem(item);menu.Invalidate();}
  static void ApplyMenuItem(ToolStripItem item){item.BackColor=Surface;item.ForeColor=item.Enabled?Text:Disabled;var drop=item as ToolStripDropDownItem;if(drop!=null)foreach(ToolStripItem child in drop.DropDownItems)ApplyMenuItem(child);}
  public static GraphicsPath Round(Rectangle r,int radius) {
   var p=new GraphicsPath();int d=Math.Max(2,Math.Min(radius*2,Math.Min(r.Width,r.Height)));
   p.AddArc(r.Left,r.Top,d,d,180,90);p.AddArc(r.Right-d,r.Top,d,d,270,90);p.AddArc(r.Right-d,r.Bottom-d,d,d,0,90);p.AddArc(r.Left,r.Bottom-d,d,d,90,90);p.CloseFigure();return p;
  }
 }
 public sealed class QuietMenu:ContextMenuStrip {
  public QuietMenu(){Renderer=new QuietMenuRenderer();BackColor=AppTheme.Surface;ForeColor=AppTheme.Text;Font=new Font("Microsoft YaHei UI",9.5f);ShowImageMargin=false;ShowCheckMargin=true;Padding=new Padding(6);MinimumSize=new Size(260,0);}
  protected override void OnItemAdded(ToolStripItemEventArgs e){base.OnItemAdded(e);e.Item.Padding=e.Item is ToolStripSeparator?new Padding(0,3,0,3):new Padding(6,6,12,6);}
 }
 public sealed class QuietMenuRenderer:ToolStripProfessionalRenderer {
  public QuietMenuRenderer(){RoundedEdges=false;}
  protected override void OnRenderToolStripBackground(ToolStripRenderEventArgs e){e.Graphics.Clear(AppTheme.Surface);}
  protected override void OnRenderImageMargin(ToolStripRenderEventArgs e){}
  protected override void OnRenderToolStripBorder(ToolStripRenderEventArgs e){using(var p=new Pen(AppTheme.Border))e.Graphics.DrawRectangle(p,0,0,e.ToolStrip.Width-1,e.ToolStrip.Height-1);}
  protected override void OnRenderMenuItemBackground(ToolStripItemRenderEventArgs e){if(!e.Item.Selected||!e.Item.Enabled)return;e.Graphics.SmoothingMode=SmoothingMode.AntiAlias;using(var p=AppTheme.Round(new Rectangle(2,1,e.Item.Width-4,e.Item.Height-2),6))using(var b=new SolidBrush(AppTheme.Hover))e.Graphics.FillPath(b,p);}
  protected override void OnRenderItemText(ToolStripItemTextRenderEventArgs e){e.TextColor=e.Item.Enabled?AppTheme.Text:AppTheme.Disabled;base.OnRenderItemText(e);}
  protected override void OnRenderArrow(ToolStripArrowRenderEventArgs e){e.ArrowColor=e.Item.Enabled?AppTheme.Muted:AppTheme.Disabled;base.OnRenderArrow(e);}
  protected override void OnRenderSeparator(ToolStripSeparatorRenderEventArgs e){using(var p=new Pen(AppTheme.Border))e.Graphics.DrawLine(p,10,e.Item.Height/2,e.Item.Width-10,e.Item.Height/2);}
  protected override void OnRenderItemCheck(ToolStripItemImageRenderEventArgs e){using(var p=new Pen(AppTheme.Text,1.6f)){var r=e.ImageRectangle;e.Graphics.DrawLines(p,new[]{new Point(r.Left+3,r.Top+r.Height/2),new Point(r.Left+6,r.Bottom-4),new Point(r.Right-2,r.Top+3)});}}
 }
 public class ShellForm:Form {
  [DllImport("user32.dll")]static extern bool ReleaseCapture();
  [DllImport("user32.dll")]static extern IntPtr SendMessage(IntPtr h,int msg,IntPtr w,IntPtr l);
  [DllImport("dwmapi.dll")]static extern int DwmSetWindowAttribute(IntPtr h,int attribute,ref int value,int size);
  bool titleAdded;public bool AppWindow{get;set;}
  public ShellForm(){DoubleBuffered=true;BackColor=AppTheme.Background;ForeColor=AppTheme.Text;AutoScaleMode=AutoScaleMode.Dpi;}
  protected override void OnHandleCreated(EventArgs e){base.OnHandleCreated(e);UpdateWindowTheme();}
  public void UpdateWindowTheme(){if(!IsHandleCreated)return;try{int dark=AppTheme.IsDark?1:0,round=2;DwmSetWindowAttribute(Handle,20,ref dark,4);DwmSetWindowAttribute(Handle,33,ref round,4);}catch(DllNotFoundException){}catch(EntryPointNotFoundException){}}
  protected override void WndProc(ref Message m){
   base.WndProc(ref m);
   if((m.Msg==0x1A || m.Msg==0x31A) && AppTheme.Mode=="system" && AppTheme.SetAppearance("system",AppTheme.Accent))
    foreach(Form form in Application.OpenForms)AppTheme.ApplyTo(form);
  }
  public void AddTitleBar(){
   if(titleAdded)return;titleAdded=true;FormBorderStyle=FormBorderStyle.None;
   foreach(Control c in Controls)if(c.Dock==DockStyle.None)c.Top+=40;
   Padding=new Padding(Padding.Left,40,Padding.Right,Padding.Bottom);ClientSize=new Size(ClientSize.Width,ClientSize.Height+40);
   var title=new Panel{Name="WindowCaption",Location=new Point(1,1),Size=new Size(ClientSize.Width-2,38),BackColor=AppTheme.Background,Anchor=AnchorStyles.Top|AnchorStyles.Left|AnchorStyles.Right};
   var caption=new Label{Name="CaptionMuted",Text=AppWindow?"Codex / 双环境":Text,Location=new Point(20,6),Size=new Size(Width-130,26),ForeColor=AppTheme.Muted,TextAlign=ContentAlignment.MiddleLeft};
   MouseEventHandler drag=delegate(object sender,MouseEventArgs e){if(e.Button==MouseButtons.Left){ReleaseCapture();SendMessage(Handle,0xA1,new IntPtr(2),IntPtr.Zero);}};caption.MouseDown+=drag;title.MouseDown+=drag;
   var minimize=new QuietButton{Quiet=true,Text="−",AccessibleName="最小化",Location=new Point(Width-88,3),Size=new Size(38,30),TabStop=false,Anchor=AnchorStyles.Top|AnchorStyles.Right};
   var close=new QuietButton{Quiet=true,Text="×",AccessibleName=AppWindow?"关闭并收起到托盘":"关闭",Location=new Point(Width-46,3),Size=new Size(38,30),TabStop=false,Anchor=AnchorStyles.Top|AnchorStyles.Right};
   minimize.Click+=delegate{WindowState=FormWindowState.Minimized;};close.Click+=delegate{Close();};title.Controls.Add(caption);if(MinimizeBox)title.Controls.Add(minimize);else minimize.Dispose();title.Controls.Add(close);Controls.Add(title);title.BringToFront();
  }
  protected override void OnPaint(PaintEventArgs e){base.OnPaint(e);using(var p=new Pen(AppTheme.Border))e.Graphics.DrawRectangle(p,0,0,Width-1,Height-1);}
 }
 public class Surface:Panel {
  public Surface(){DoubleBuffered=true;ResizeRedraw=true;BackColor=AppTheme.Surface;ForeColor=AppTheme.Text;}
  protected override void OnPaintBackground(PaintEventArgs e){e.Graphics.Clear(Parent==null?AppTheme.Background:Parent.BackColor);e.Graphics.SmoothingMode=SmoothingMode.AntiAlias;using(var p=AppTheme.Round(new Rectangle(0,0,Width-1,Height-1),14))using(var b=new SolidBrush(BackColor))e.Graphics.FillPath(b,p);}
  protected override void OnPaint(PaintEventArgs e){base.OnPaint(e);e.Graphics.SmoothingMode=SmoothingMode.AntiAlias;using(var p=AppTheme.Round(new Rectangle(0,0,Width-1,Height-1),14))using(var pen=new Pen(AppTheme.Border))e.Graphics.DrawPath(pen,p);}
 }
 public sealed class QuietSwitch:CheckBox {
  public QuietSwitch(){SetStyle(ControlStyles.UserPaint|ControlStyles.AllPaintingInWmPaint|ControlStyles.OptimizedDoubleBuffer|ControlStyles.ResizeRedraw,true);AutoSize=false;Cursor=Cursors.Hand;UseVisualStyleBackColor=false;}
  protected override void OnCheckedChanged(EventArgs e){base.OnCheckedChanged(e);Invalidate();}
  protected override void OnPaint(PaintEventArgs e){
   var g=e.Graphics;g.Clear(Parent==null?AppTheme.Background:Parent.BackColor);g.SmoothingMode=SmoothingMode.AntiAlias;
   int y=(Height-22)/2;var track=new Rectangle(1,y,40,22);
   using(var path=AppTheme.Round(track,11))using(var brush=new SolidBrush(!Enabled?AppTheme.Button:Checked?AppTheme.Primary:AppTheme.Border))g.FillPath(brush,path);
   using(var brush=new SolidBrush(Checked?AppTheme.PrimaryText:AppTheme.Surface))g.FillEllipse(brush,Checked?22:4,y+3,16,16);
   TextRenderer.DrawText(g,Text,Font,new Rectangle(53,0,Width-54,Height),Enabled?AppTheme.Text:AppTheme.Disabled,TextFormatFlags.Left|TextFormatFlags.VerticalCenter|TextFormatFlags.EndEllipsis|TextFormatFlags.NoPrefix);
   if(Focused&&ShowFocusCues)using(var pen=new Pen(AppTheme.Focus,1.4f))g.DrawRectangle(pen,0,0,Width-1,Height-1);
  }
 }
 public class QuietButton:Button {
  bool hover,pressed;public bool Primary{get;set;}public bool Quiet{get;set;}public bool Selected{get;set;}
  public QuietButton(){SetStyle(ControlStyles.UserPaint|ControlStyles.AllPaintingInWmPaint|ControlStyles.OptimizedDoubleBuffer|ControlStyles.ResizeRedraw,true);FlatStyle=FlatStyle.Flat;FlatAppearance.BorderSize=0;Cursor=Cursors.Hand;UseVisualStyleBackColor=false;BackColor=AppTheme.Button;ForeColor=AppTheme.Text;}
  protected override void OnMouseEnter(EventArgs e){hover=true;Invalidate();base.OnMouseEnter(e);}protected override void OnMouseLeave(EventArgs e){hover=pressed=false;Invalidate();base.OnMouseLeave(e);}protected override void OnMouseDown(MouseEventArgs e){pressed=e.Button==MouseButtons.Left;Invalidate();base.OnMouseDown(e);}protected override void OnMouseUp(MouseEventArgs e){pressed=false;Invalidate();base.OnMouseUp(e);}
  protected override void OnPaint(PaintEventArgs e){
   e.Graphics.Clear(Parent==null?AppTheme.Background:Parent.BackColor);e.Graphics.SmoothingMode=SmoothingMode.AntiAlias;var r=new Rectangle(1,1,Width-3,Height-3);
   var fill=!Enabled?AppTheme.Button:Primary?(pressed?AppTheme.PrimaryPressed:hover?AppTheme.PrimaryHover:AppTheme.Primary):pressed?AppTheme.Pressed:hover||Selected?AppTheme.Hover:AppTheme.Button;if(Quiet&&!hover&&!pressed&&!Selected&&Parent!=null)fill=Parent.BackColor;
   using(var p=AppTheme.Round(r,9)){using(var b=new SolidBrush(fill))e.Graphics.FillPath(b,p);if(!Quiet&&!Primary)using(var pen=new Pen(AppTheme.Border))e.Graphics.DrawPath(pen,p);if(Focused&&ShowFocusCues)using(var pen=new Pen(AppTheme.Focus,2))e.Graphics.DrawPath(pen,p);}
   var flags=TextFormatFlags.VerticalCenter|TextFormatFlags.EndEllipsis|TextFormatFlags.NoPrefix;if(TextAlign==ContentAlignment.MiddleLeft){r.X+=12;r.Width-=18;flags|=TextFormatFlags.Left;}else flags|=TextFormatFlags.HorizontalCenter;
   TextRenderer.DrawText(e.Graphics,Text,Font,r,!Enabled?AppTheme.Disabled:Primary?AppTheme.PrimaryText:AppTheme.Text,flags);
  }
 }
 // Two-line command row for the tray popup; ordinary Button semantics keep keyboard and accessibility support.
 public sealed class QuickActionButton:Button {
  bool hover,pressed;string detail="";
  public string Detail{get{return detail;}set{detail=value??"";AccessibleDescription=detail;Invalidate();}}
  public string ActionIcon{get;set;}
  public QuickActionButton(){SetStyle(ControlStyles.UserPaint|ControlStyles.AllPaintingInWmPaint|ControlStyles.OptimizedDoubleBuffer|ControlStyles.ResizeRedraw,true);FlatStyle=FlatStyle.Flat;FlatAppearance.BorderSize=0;UseVisualStyleBackColor=false;Cursor=Cursors.Hand;TextAlign=ContentAlignment.MiddleLeft;BackColor=AppTheme.Surface;ForeColor=AppTheme.Text;}
  protected override void OnMouseEnter(EventArgs e){hover=true;Invalidate();base.OnMouseEnter(e);}
  protected override void OnMouseLeave(EventArgs e){hover=pressed=false;Invalidate();base.OnMouseLeave(e);}
  protected override void OnMouseDown(MouseEventArgs e){pressed=e.Button==MouseButtons.Left;Invalidate();base.OnMouseDown(e);}
  protected override void OnMouseUp(MouseEventArgs e){pressed=false;Invalidate();base.OnMouseUp(e);}
  protected override void OnPaint(PaintEventArgs e){
   var g=e.Graphics;g.Clear(Parent==null?AppTheme.Surface:Parent.BackColor);g.SmoothingMode=SmoothingMode.AntiAlias;
   var bounds=new Rectangle(1,1,Width-3,Height-3);bool twoLines=detail.Length>0;
   using(var path=AppTheme.Round(bounds,11)){
    var fill=!Enabled?AppTheme.Surface:pressed?AppTheme.Pressed:hover?AppTheme.Hover:twoLines?AppTheme.Button:AppTheme.Surface;
    using(var brush=new SolidBrush(fill))g.FillPath(brush,path);
    if(Focused&&ShowFocusCues)using(var pen=new Pen(AppTheme.Focus,1.5f))g.DrawPath(pen,path);
   }
   var ink=Enabled?AppTheme.Text:AppTheme.Disabled;
   using(var pen=new Pen(ink,1.4f)){
    int x=16,y=(Height-18)/2;string kind=ActionIcon??"arrow";
    if(kind=="window"||kind=="panel"){g.DrawRectangle(pen,x,y,18,16);g.DrawLine(pen,x,y+5,x+18,y+5);if(kind=="panel")g.DrawLine(pen,x+6,y+5,x+6,y+16);}
    else if(kind=="folder"){g.DrawLines(pen,new[]{new Point(x,y+3),new Point(x+7,y+3),new Point(x+10,y+6),new Point(x+19,y+6),new Point(x+19,y+17),new Point(x,y+17),new Point(x,y+3)});}
    else if(kind=="clock"){g.DrawEllipse(pen,x,y,18,18);g.DrawLines(pen,new[]{new Point(x+9,y+4),new Point(x+9,y+9),new Point(x+13,y+11)});}
    else if(kind=="bell"){g.DrawArc(pen,x+3,y,12,14,180,180);g.DrawLine(pen,x+3,y+7,x+3,y+13);g.DrawLine(pen,x+15,y+7,x+15,y+13);g.DrawLine(pen,x+1,y+14,x+17,y+14);g.DrawArc(pen,x+7,y+14,4,4,0,180);}
    else if(kind=="settings"){for(int i=0;i<3;i++){int yy=y+3+i*6;g.DrawLine(pen,x,yy,x+18,yy);int xx=x+(i==1?11:5);g.DrawEllipse(pen,xx-2,yy-2,4,4);}}
    else if(kind=="close"){g.DrawLine(pen,x+4,y+4,x+14,y+14);g.DrawLine(pen,x+14,y+4,x+4,y+14);}
    else if(kind=="more"){for(int i=0;i<3;i++)g.DrawEllipse(pen,x+1+i*7,y+8,2,2);}
    else{g.DrawLines(pen,new[]{new Point(x+6,y+3),new Point(x+12,y+9),new Point(x+6,y+15)});}
    g.DrawLines(pen,new[]{new Point(Width-20,Height/2-3),new Point(Width-17,Height/2),new Point(Width-20,Height/2+3)});
   }
   var flags=TextFormatFlags.Left|TextFormatFlags.VerticalCenter|TextFormatFlags.EndEllipsis|TextFormatFlags.NoPrefix|TextFormatFlags.SingleLine;
   using(var titleFont=new Font(Font.FontFamily,Font.Size+0.5f,FontStyle.Regular))TextRenderer.DrawText(g,Text,titleFont,new Rectangle(49,twoLines?8:0,Width-82,twoLines?25:Height),ink,flags);
   if(twoLines)using(var detailFont=new Font(Font.FontFamily,Math.Max(8,Font.Size-1)))TextRenderer.DrawText(g,detail,detailFont,new Rectangle(49,33,Width-78,22),Enabled?AppTheme.Muted:AppTheme.Disabled,flags);
  }
 }
 public sealed class QuietComboBox:ComboBox {
  public QuietComboBox(){DrawMode=DrawMode.OwnerDrawFixed;ItemHeight=25;FlatStyle=FlatStyle.Flat;BackColor=AppTheme.Surface;ForeColor=AppTheme.Text;}
  protected override void WndProc(ref Message m){
   base.WndProc(ref m);
   if(m.Msg==0xF||m.Msg==0x317||m.Msg==0x318){using(var g=m.Msg==0xF?Graphics.FromHwnd(Handle):Graphics.FromHdc(m.WParam)){using(var b=new SolidBrush(AppTheme.Input))g.FillRectangle(b,Width-23,1,22,Height-2);using(var p=new Pen(AppTheme.Border))g.DrawRectangle(p,0,0,Width-1,Height-1);using(var p=new Pen(AppTheme.Muted,1.4f)){g.DrawLines(p,new[]{new Point(Width-16,Height/2-2),new Point(Width-12,Height/2+2),new Point(Width-8,Height/2-2)});}}}
  }
  protected override void OnDrawItem(DrawItemEventArgs e){using(var b=new SolidBrush((e.State&DrawItemState.Selected)!=0?AppTheme.Selected:AppTheme.Input))e.Graphics.FillRectangle(b,e.Bounds);string text=e.Index<0?Text:GetItemText(Items[e.Index]);var r=e.Bounds;r.X+=8;r.Width-=12;TextRenderer.DrawText(e.Graphics,text,Font,r,Enabled?AppTheme.Text:AppTheme.Disabled,TextFormatFlags.Left|TextFormatFlags.VerticalCenter|TextFormatFlags.EndEllipsis);if((e.State&DrawItemState.Focus)!=0)e.DrawFocusRectangle();}
 }
 public sealed class QuietListBox:ListBox {
  public QuietListBox(){BorderStyle=BorderStyle.None;DrawMode=DrawMode.OwnerDrawFixed;ItemHeight=34;BackColor=AppTheme.Surface;ForeColor=AppTheme.Text;}
  protected override void OnDrawItem(DrawItemEventArgs e){if(e.Index<0)return;bool selected=(e.State&DrawItemState.Selected)!=0;using(var b=new SolidBrush(selected?AppTheme.Selected:AppTheme.Input))e.Graphics.FillRectangle(b,e.Bounds);var r=e.Bounds;r.X+=10;r.Width-=16;TextRenderer.DrawText(e.Graphics,GetItemText(Items[e.Index]),Font,r,Enabled?AppTheme.Text:AppTheme.Disabled,TextFormatFlags.Left|TextFormatFlags.VerticalCenter|TextFormatFlags.EndEllipsis);if((e.State&DrawItemState.Focus)!=0)e.DrawFocusRectangle();}
 }
 public sealed class QuietTabs:Panel {
  readonly Panel header=new Panel{Height=52,Dock=DockStyle.Top};
  readonly Panel body=new Panel{Dock=DockStyle.Fill};
  readonly System.Collections.Generic.List<Panel> pages=new System.Collections.Generic.List<Panel>();
  readonly System.Collections.Generic.List<QuietButton> buttons=new System.Collections.Generic.List<QuietButton>();
  Panel selected;
  public QuietTabs(){BackColor=AppTheme.Background;body.BackColor=AppTheme.Background;header.BackColor=AppTheme.Background;Controls.Add(body);Controls.Add(header);}
  public Panel SelectedTab{get{return selected;}set{if(value==null||!pages.Contains(value))return;selected=value;for(int i=0;i<pages.Count;i++){pages[i].Visible=pages[i]==value;buttons[i].Selected=pages[i]==value;buttons[i].Invalidate();}value.BringToFront();}}
  public void AddPage(Panel page){
   int index=pages.Count;pages.Add(page);page.Dock=DockStyle.Fill;body.Controls.Add(page);
   var button=new QuietButton{Text=page.Text,Quiet=true,Location=new Point(16+index*154,8),Size=new Size(146,36)};
   button.Click+=delegate{SelectedTab=page;};buttons.Add(button);header.Controls.Add(button);
   if(selected==null)SelectedTab=page;else page.Visible=false;
  }
 }
}
