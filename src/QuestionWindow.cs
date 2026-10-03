using System;
using System.Collections.Generic;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Runtime.InteropServices;
using System.Web.Script.Serialization;
using System.Windows.Forms;

namespace CodexDual {
 public sealed class QuestionWindow : ShellForm {
  [DllImport("user32.dll")] static extern bool ReleaseCapture();
  [DllImport("uxtheme.dll",CharSet=CharSet.Unicode)] static extern int SetWindowTheme(IntPtr handle,string app,string id);
  [DllImport("user32.dll")] static extern IntPtr SendMessage(IntPtr handle,int message,IntPtr wParam,IntPtr lParam);
  readonly JavaScriptSerializer json=new JavaScriptSerializer { MaxJsonLength=4*1024*1024,RecursionLimit=100 };
  readonly Panel caption=new Panel { Name="QuestionCaption",Dock=DockStyle.Top,Height=38 };
  readonly Panel introduction=new Panel { Name="QuestionIntroduction",Dock=DockStyle.Top,Height=28 };
  readonly Panel list=new Panel { Name="Questions",Dock=DockStyle.Fill,AutoScroll=true };
  readonly Panel footer=new Panel { Name="QuestionFooter",Dock=DockStyle.Bottom,Height=52 };
  readonly Label context=new Label { Name="QuestionContext",AutoEllipsis=true };
  readonly Label status=new Label { Name="QuestionStatus",AutoSize=false };
  readonly QuietButton submit=new QuietButton { Name="SubmitAnswer",Text="提交",Primary=true,Size=new Size(86,32) };
  readonly QuietButton returnButton=new QuietButton { Name="ReturnToCodex",Text="返回 Codex",Size=new Size(114,32) };
  readonly List<QuestionEditor> editors=new List<QuestionEditor>();
  readonly Dictionary<string,Dictionary<string,EditorDraft>> drafts=new Dictionary<string,Dictionary<string,EditorDraft>>(StringComparer.Ordinal);
  Dictionary<string,object> request;
  string token="";
  bool valid,busy,resizeLayout,placed;
  public string RequestToken { get { return token; } }
  public string RequestConnectionId { get { return request==null?"":FieldText(request,"connectionId"); } }
  public bool IsRequestValid { get { return valid; } }
  public string AnswerJson { get; private set; }
  public event EventHandler SubmitRequested;
  public event EventHandler ReturnRequested;

  public QuestionWindow() {
   Name="QuestionWindow";Text="回答问题";ClientSize=new Size(480,380);MinimumSize=new Size(320,280);
   Font=new Font("Microsoft YaHei UI",9f);StartPosition=FormStartPosition.Manual;
   FormBorderStyle=FormBorderStyle.None;ShowInTaskbar=false;KeyPreview=true;TopMost=true;ShowWithoutFocus=true;
   caption.MouseDown+=DragCaption;
   var captionText=new Label { Name="CaptionMuted",Text="回答问题",AutoSize=false,TextAlign=ContentAlignment.MiddleLeft,Font=new Font(Font.FontFamily,9f,FontStyle.Bold) };
   captionText.SetBounds(16,3,420,30);captionText.Anchor=AnchorStyles.Left|AnchorStyles.Top|AnchorStyles.Right;captionText.MouseDown+=DragCaption;
   var close=new QuietButton { Name="CloseQuestionWindow",Text="×",Quiet=true,Size=new Size(30,28),Anchor=AnchorStyles.Top|AnchorStyles.Right,AccessibleName="关闭问题窗口" };
   close.Location=new Point(ClientSize.Width-38,5);close.Click+=delegate { Close(); };
   caption.Resize+=delegate { close.Left=caption.ClientSize.Width-close.Width-8;captionText.Width=Math.Max(100,close.Left-22); };
   caption.Controls.Add(captionText);caption.Controls.Add(close);
   context.SetBounds(16,4,ClientSize.Width-32,18);context.Anchor=AnchorStyles.Left|AnchorStyles.Top|AnchorStyles.Right;
   context.Font=new Font(Font.FontFamily,8f,FontStyle.Bold);
   introduction.Controls.Add(context);introduction.Visible=false;
   status.SetBounds(16,3,ClientSize.Width-32,23);status.Anchor=AnchorStyles.Left|AnchorStyles.Right|AnchorStyles.Top;
   returnButton.Location=new Point(16,32);returnButton.Anchor=AnchorStyles.Left|AnchorStyles.Bottom;
   submit.Location=new Point(ClientSize.Width-122,32);submit.Anchor=AnchorStyles.Right|AnchorStyles.Bottom;
   returnButton.Click+=delegate { if(ReturnRequested!=null)ReturnRequested(this,EventArgs.Empty); };
   submit.Click+=delegate { Submit(); };
   footer.Controls.Add(status);footer.Controls.Add(returnButton);footer.Controls.Add(submit);
   footer.Resize+=delegate { ArrangeFooter(); };
   Controls.Add(list);Controls.Add(footer);Controls.Add(introduction);Controls.Add(caption);
   list.Resize+=delegate { ArrangeEditors(); };
   list.HandleCreated+=delegate { SetWindowTheme(list.Handle,AppTheme.IsDark?"DarkMode_Explorer":"Explorer",null); };
   Resize+=delegate { ArrangeEditors(); };
   KeyDown+=delegate(object sender,KeyEventArgs e) { if(e.KeyCode==Keys.Escape){Close();e.Handled=true;} };
   close.Left=caption.ClientSize.Width-close.Width-8;
   submit.Left=footer.ClientSize.Width-submit.Width-16;
   ArrangeFooter();ApplyAppearance();UpdateSubmit();
  }
  protected override void OnLoad(EventArgs e) {
   if(!placed)PlaceNearNotifications(Screen.FromPoint(Cursor.Position).WorkingArea);
   base.OnLoad(e);
  }
  public void PlaceNearNotifications(Rectangle workingArea) {
   if(workingArea.Width<=0||workingArea.Height<=0)return;
   MinimumSize=new Size(Math.Min(320,workingArea.Width),Math.Min(280,workingArea.Height));
   Size=new Size(Math.Min(480,workingArea.Width),Math.Min(380,workingArea.Height));
   int margin=20;
   Location=new Point(workingArea.Right-Width-Math.Min(margin,Math.Max(0,workingArea.Width-Width)),
                      workingArea.Bottom-Height-Math.Min(margin,Math.Max(0,workingArea.Height-Height)));
   placed=true;
  }
  protected override void OnFormClosing(FormClosingEventArgs e) {
   if(e.CloseReason==CloseReason.UserClosing){e.Cancel=true;Hide();return;}
   base.OnFormClosing(e);
  }
  protected override void WndProc(ref Message m) {
   if(m.Msg==0x84 && WindowState==FormWindowState.Normal) {
    base.WndProc(ref m);
    var screen=new Point(unchecked((short)((long)m.LParam&0xffff)),unchecked((short)(((long)m.LParam>>16)&0xffff)));
    Point p=PointToClient(screen);const int edge=7;
    if(p.X<edge)m.Result=(IntPtr)(p.Y<edge?13:p.Y>=Height-edge?16:10);
    else if(p.X>=Width-edge)m.Result=(IntPtr)(p.Y<edge?14:p.Y>=Height-edge?17:11);
    else if(p.Y<edge)m.Result=(IntPtr)12;
    else if(p.Y>=Height-edge)m.Result=(IntPtr)15;
    return;
   }
   base.WndProc(ref m);
  }
  void DragCaption(object sender,MouseEventArgs e) {
   if(e.Button!=MouseButtons.Left)return;
   ReleaseCapture();SendMessage(Handle,0xA1,(IntPtr)2,IntPtr.Zero);
  }
  static Dictionary<string,object> Map(object value) { return value as Dictionary<string,object> ?? new Dictionary<string,object>(); }
  static object[] Array(Dictionary<string,object> value,string key) { object item;return value.TryGetValue(key,out item)?item as object[] ?? new object[0]:new object[0]; }
  static string FieldText(Dictionary<string,object> value,string key) { object item;return value.TryGetValue(key,out item)&&item!=null?Convert.ToString(item):""; }
  static bool Flag(Dictionary<string,object> value,string key) { object item;return value.TryGetValue(key,out item)&&item is bool&&(bool)item; }

  public void SetRequestJson(string value) {
   var incoming=Map(json.DeserializeObject(value));
   string nextToken=FieldText(incoming,"requestToken");
   if(String.IsNullOrWhiteSpace(nextToken)||Array(incoming,"questions").Length==0)throw new ArgumentException("Request needs a token and questions.","value");
   SaveDraft();
   if(token!=nextToken)drafts.Clear();
   token=nextToken;request=incoming;valid=true;busy=false;AnswerJson=null;
   foreach(var editor in editors)editor.Dispose();editors.Clear();list.Controls.Clear();
   var questions=Array(incoming,"questions");
   for(int i=0;i<questions.Length;i++) {
    var editor=new QuestionEditor(Map(questions[i]),i,Font,UpdateSubmit);
    editors.Add(editor);list.Controls.Add(editor.Host);
    Dictionary<string,EditorDraft> saved;EditorDraft draft;
    if(drafts.TryGetValue(token,out saved)&&saved.TryGetValue(editor.Id,out draft))editor.Restore(draft);
   }
   string taskTitle=FieldText(incoming,"taskTitle");context.Text=taskTitle;
   introduction.Visible=!String.IsNullOrWhiteSpace(taskTitle);
   SetStatus("");
   ArrangeEditors();ApplyAppearance();UpdateSubmit();
  }
  void SaveDraft() {
   if(String.IsNullOrEmpty(token)||editors.Count==0)return;
   var values=new Dictionary<string,EditorDraft>(StringComparer.Ordinal);
   foreach(var editor in editors)values[editor.Id]=editor.Capture();
   drafts[token]=values;
  }
  public void SetSubmissionState(bool submitting,string message) {
   busy=submitting;
   SetStatus(!String.IsNullOrWhiteSpace(message)?message:submitting?"正在提交…":valid?"":"该问题已失效。");
   UpdateSubmit();
  }
  public void InvalidateRequest(string reason) {
   valid=false;busy=false;AnswerJson=null;
   SetStatus(String.IsNullOrWhiteSpace(reason)?"该问题已失效，请返回 Codex 查看。":reason);
   UpdateSubmit();
  }
  void UpdateSubmit() {
   if(IsDisposed)return;
   bool complete=editors.Count>0;
   foreach(var editor in editors)if(String.IsNullOrWhiteSpace(editor.Answer))complete=false;
   submit.Enabled=valid&&!busy&&complete;
  }
  void Submit() {
   if(!valid||busy||request==null)return;
   UpdateSubmit();if(!submit.Enabled){SetStatus("请为每一项选择或填写答案。");return;}
   var answers=new Dictionary<string,object>(StringComparer.Ordinal);
   foreach(var editor in editors)answers[editor.Id]=new { answers=new[]{editor.Answer} };
   object id;request.TryGetValue("requestId",out id);
   AnswerJson=json.Serialize(new { command="answer",connectionId=FieldText(request,"connectionId"),requestToken=token,requestId=id,threadId=FieldText(request,"threadId"),turnId=FieldText(request,"turnId"),answers=answers });
   busy=true;SetStatus("正在提交…");UpdateSubmit();
   if(SubmitRequested!=null)SubmitRequested(this,EventArgs.Empty);
  }
  void SetStatus(string message) {
   status.Text=message;ArrangeFooter();
  }
  void ArrangeFooter() {
   int width=Math.Max(100,footer.ClientSize.Width-32);
   bool hasStatus=!String.IsNullOrWhiteSpace(status.Text);
   int height=hasStatus?TextRenderer.MeasureText(status.Text,Font,new Size(width,10000),TextFormatFlags.WordBreak|TextFormatFlags.NoPrefix).Height+4:0;
   footer.Height=52+(hasStatus?height+8:0);
   status.Visible=hasStatus;status.SetBounds(16,6,width,height);
   returnButton.Location=new Point(16,footer.Height-42);
   submit.Location=new Point(footer.ClientSize.Width-submit.Width-16,footer.Height-42);
  }
  void ArrangeEditors() {
   if(resizeLayout||list.ClientSize.Width<100)return;
   resizeLayout=true;
   try {
    list.AutoScroll=false;
    list.AutoScrollMinSize=Size.Empty;
    list.SuspendLayout();
    int width=Math.Max(100,list.ClientSize.Width-16-12-SystemInformation.VerticalScrollBarWidth-8);
    int offset=-list.AutoScrollPosition.Y,y=4;
    foreach(var editor in editors) {
     editor.Arrange(width);editor.Host.Location=new Point(16,y-offset);
     y+=editor.Host.Height+12;
    }
    list.AutoScrollMinSize=new Size(0,y+8);
    list.ResumeLayout(true);
    list.AutoScroll=true;
    list.HorizontalScroll.Visible=false;
    list.HorizontalScroll.Enabled=false;
   } finally { resizeLayout=false; }
  }
  public void ApplyAppearance() {
   AppTheme.ApplyTo(this);
   if(list.IsHandleCreated)SetWindowTheme(list.Handle,AppTheme.IsDark?"DarkMode_Explorer":"Explorer",null);
   BackColor=AppTheme.Background;caption.BackColor=AppTheme.Background;introduction.BackColor=AppTheme.Background;
   list.BackColor=AppTheme.Background;footer.BackColor=AppTheme.Background;
   context.ForeColor=AppTheme.AccentColor;status.ForeColor=valid?AppTheme.Muted:AppTheme.AccentColor;
   foreach(var editor in editors)editor.ApplyAppearance();
   Invalidate(true);
  }
  protected override void OnPaint(PaintEventArgs e) {
   base.OnPaint(e);
   using(var pen=new Pen(AppTheme.Border)) {
    e.Graphics.DrawLine(pen,16,caption.Bottom,Width-17,caption.Bottom);
    e.Graphics.DrawLine(pen,16,footer.Top,Width-17,footer.Top);
   }
  }
  sealed class EditorDraft { public int Selected=-1;public bool Other;public string Free=""; }
  sealed class QuestionEditor : IDisposable {
   public readonly Panel Host=new Panel();public readonly string Id;
   readonly Label title=new Label();readonly List<Choice> choices=new List<Choice>();
   readonly Choice other;readonly TextBox free;readonly Label inputLabel;
   readonly bool secret;readonly Action changed;readonly Font titleFont;
   bool restoring;
   public QuestionEditor(Dictionary<string,object> question,int index,Font font,Action onChange) {
    changed=onChange;Id=FieldText(question,"id");if(String.IsNullOrWhiteSpace(Id))Id="question_"+index;
    Host.Name="Question_"+Id;Host.Margin=new Padding(0,0,0,20);Host.BackColor=AppTheme.Background;
    titleFont=new Font(font.FontFamily,9.5f,FontStyle.Bold);
    title.Name="QuestionTitle_"+Id;title.Font=titleFont;title.Text=(index+1)+".  "+FieldText(question,"header");
    string prompt=FieldText(question,"question");if(prompt.Length>0)title.Text+=Environment.NewLine+prompt;
    Host.Controls.Add(title);
    foreach(var item in Array(question,"options")) {
     var value=Map(item);var choice=new Choice(FieldText(value,"label"),FieldText(value,"description"),font);
     choice.Name="Option_"+Id+"_"+choices.Count;
     choice.CheckedChanged+=delegate { if(!restoring)changed(); };
     choices.Add(choice);Host.Controls.Add(choice);
    }
    secret=Flag(question,"isSecret");
    if(choices.Count==0||Flag(question,"isOther")) {
     if(choices.Count>0) {
      other=new Choice("其他","",font) { Name="Other_"+Id };
      other.CheckedChanged+=delegate { if(!restoring)changed(); };
      Host.Controls.Add(other);
     }
     inputLabel=new Label { Name="InputLabel_"+Id,Text=secret?"敏感内容（输入时隐藏）":"你的回答",Font=font };
     free=new TextBox { Name="Answer_"+Id,Multiline=!secret,UseSystemPasswordChar=secret,BorderStyle=BorderStyle.FixedSingle,Font=font,ScrollBars=secret?ScrollBars.None:ScrollBars.Vertical };
     free.HandleCreated+=delegate { SetWindowTheme(free.Handle,AppTheme.IsDark?"DarkMode_Explorer":"Explorer",null); };
     free.TextChanged+=delegate { if(other!=null&&free.TextLength>0)other.Checked=true;if(!restoring)changed(); };
     Host.Controls.Add(inputLabel);Host.Controls.Add(free);
    }
   }
   public string Answer {
    get {
     for(int i=0;i<choices.Count;i++)if(choices[i].Checked)return choices[i].Value;
     return free!=null&&(other==null||other.Checked)?free.Text:"";
    }
   }
   public EditorDraft Capture() {
    var draft=new EditorDraft { Other=other!=null&&other.Checked,Free=free==null?"":free.Text };
    for(int i=0;i<choices.Count;i++)if(choices[i].Checked)draft.Selected=i;
    return draft;
   }
   public void Restore(EditorDraft draft) {
    restoring=true;
    try {
     if(free!=null)free.Text=draft.Free;
     if(draft.Selected>=0&&draft.Selected<choices.Count)choices[draft.Selected].Checked=true;
     else if(other!=null)other.Checked=draft.Other;
    } finally { restoring=false; }
   }
   static int HeightFor(string text,Font font,int width,int minimum) {
    return Math.Max(minimum,TextRenderer.MeasureText(text,font,new Size(Math.Max(50,width),10000),TextFormatFlags.WordBreak|TextFormatFlags.NoPrefix).Height+7);
   }
   public void Arrange(int width) {
    Host.SuspendLayout();Host.Width=width;
    int inner=width-8,y=0;
    title.SetBounds(2,y,inner,HeightFor(title.Text,titleFont,inner,34));y+=title.Height+6;
    foreach(var choice in choices) { choice.SetBounds(2,y,inner,choice.RequiredHeight(inner));y+=choice.Height+5; }
    if(other!=null) { other.SetBounds(2,y,inner,other.RequiredHeight(inner));y+=other.Height+5; }
    if(free!=null) {
     inputLabel.SetBounds(4,y,inner-8,21);y+=24;
     free.SetBounds(4,y,inner-8,secret?30:64);y+=free.Height+4;
    }
    Host.Height=y+2;Host.ResumeLayout(true);
   }
   public void ApplyAppearance() {
    Host.BackColor=AppTheme.Background;title.ForeColor=AppTheme.Text;title.BackColor=Host.BackColor;
    foreach(var choice in choices)choice.ApplyAppearance();
    if(other!=null)other.ApplyAppearance();
    if(inputLabel!=null){inputLabel.BackColor=Host.BackColor;inputLabel.ForeColor=AppTheme.Muted;}
    if(free!=null){free.BackColor=AppTheme.Surface;free.ForeColor=AppTheme.Text;if(free.IsHandleCreated)SetWindowTheme(free.Handle,AppTheme.IsDark?"DarkMode_Explorer":"Explorer",null);}
   }
   public void Dispose() { Host.Dispose();titleFont.Dispose(); }
  }
  sealed class Choice : RadioButton {
   readonly Font detailFont;readonly string detail;
   public readonly string Value;
   public Choice(string label,string description,Font font) {
    Value=label;Text=label;detail=description;detailFont=new Font(font.FontFamily,8.5f);
    Font=font;SetStyle(ControlStyles.UserPaint|ControlStyles.AllPaintingInWmPaint|ControlStyles.OptimizedDoubleBuffer|ControlStyles.ResizeRedraw,true);
    Cursor=Cursors.Hand;AutoSize=false;TabStop=true;
    AccessibleDescription=description;
   }
   public int RequiredHeight(int width) {
    int textWidth=Math.Max(80,width-66);
    int titleHeight=TextRenderer.MeasureText(Text,Font,new Size(textWidth,10000),TextFormatFlags.WordBreak|TextFormatFlags.NoPrefix).Height;
    int detailHeight=detail.Length==0?0:TextRenderer.MeasureText(detail,detailFont,new Size(textWidth,10000),TextFormatFlags.WordBreak|TextFormatFlags.NoPrefix).Height+5;
    return Math.Max(43,titleHeight+detailHeight+17);
   }
   public void ApplyAppearance(){BackColor=AppTheme.Surface;ForeColor=AppTheme.Text;Invalidate();}
   protected override void OnPaint(PaintEventArgs e) {
    var g=e.Graphics;g.SmoothingMode=SmoothingMode.AntiAlias;g.Clear(Parent==null?AppTheme.Background:Parent.BackColor);
    var bounds=new Rectangle(1,1,Width-3,Height-3);
    using(var path=AppTheme.Round(bounds,7))using(var fill=new SolidBrush(Checked?AppTheme.Selected:AppTheme.Surface))using(var border=new Pen(Checked?AppTheme.AccentColor:AppTheme.Border,Checked?1.5f:1f)) { g.FillPath(fill,path);g.DrawPath(border,path); }
    using(var ring=new Pen(Checked?AppTheme.AccentColor:AppTheme.Muted,1.6f))g.DrawEllipse(ring,16,Height/2-8,16,16);
    if(Checked)using(var dot=new SolidBrush(AppTheme.AccentColor))g.FillEllipse(dot,21,Height/2-3,6,6);
    int width=Width-68;
    int titleHeight=TextRenderer.MeasureText(Text,Font,new Size(width,10000),TextFormatFlags.WordBreak|TextFormatFlags.NoPrefix).Height;
    int detailHeight=detail.Length==0?0:TextRenderer.MeasureText(detail,detailFont,new Size(width,10000),TextFormatFlags.WordBreak|TextFormatFlags.NoPrefix).Height+5;
    int y=Math.Max(7,(Height-titleHeight-detailHeight)/2);
    TextRenderer.DrawText(g,Text,Font,new Rectangle(49,y,width,titleHeight+2),Enabled?AppTheme.Text:AppTheme.Disabled,TextFormatFlags.WordBreak|TextFormatFlags.NoPrefix);
    if(detail.Length>0)TextRenderer.DrawText(g,detail,detailFont,new Rectangle(49,y+titleHeight+5,width,detailHeight),AppTheme.Muted,TextFormatFlags.WordBreak|TextFormatFlags.NoPrefix);
    if(Focused&&ShowFocusCues)using(var focus=new Pen(AppTheme.Focus))g.DrawRectangle(focus,4,4,Width-9,Height-9);
   }
   protected override void Dispose(bool disposing) { if(disposing)detailFont.Dispose();base.Dispose(disposing); }
  }
 }
}
