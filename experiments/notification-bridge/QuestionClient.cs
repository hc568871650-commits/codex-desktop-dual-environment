using System;
using System.Collections;
using System.Collections.Generic;
using System.Diagnostics;
using System.Drawing;
using System.IO;
using System.IO.Pipes;
using System.Text;
using System.Threading.Tasks;
using System.Web.Script.Serialization;
using System.Windows.Forms;

namespace CodexBridgeTrial {
 public sealed class QuestionWindow : Form {
  readonly string root, pipeName, instanceId;
  readonly JavaScriptSerializer json=new JavaScriptSerializer { MaxJsonLength=4*1024*1024 };
  readonly ListBox requests=new ListBox { Dock=DockStyle.Left,Width=190,Name="PendingRequests" };
  readonly FlowLayoutPanel questions=new FlowLayoutPanel { Dock=DockStyle.Fill,FlowDirection=FlowDirection.TopDown,WrapContents=false,AutoScroll=true,Padding=new Padding(12),Name="Questions" };
  readonly Label status=new Label { Dock=DockStyle.Bottom,Height=46,Padding=new Padding(12,4,12,4),Name="Status" };
  readonly Button submit=new Button { Text="提交回答",Name="SubmitAnswer",Width=110,Height=34 };
  readonly Button open=new Button { Text="返回 Codex 作答",Name="OpenCodex",Width=160,Height=34 };
  readonly System.Windows.Forms.Timer poll=new System.Windows.Forms.Timer { Interval=800 };
  readonly List<QuestionEditor> editors=new List<QuestionEditor>();
  readonly Dictionary<string,Dictionary<string,string>> drafts=new Dictionary<string,Dictionary<string,string>>();
  bool busy, closed;
  Pending selected;
  public QuestionWindow(string directory) {
   root=Path.GetFullPath(directory);
   var cfg=Map(json.DeserializeObject(File.ReadAllText(Path.Combine(root,"bridge.config.json"))));
   var manifest=Map(json.DeserializeObject(File.ReadAllText(Path.Combine(root,"trial.json"))));
   if(TextValue(manifest,"kind")!="isolated-api-bridge-trial" || !String.Equals(TextValue(manifest,"root"),root,StringComparison.OrdinalIgnoreCase))throw new InvalidOperationException("Invalid trial manifest.");
   instanceId=TextValue(cfg,"instanceId");pipeName=TextValue(cfg,"pipeName");
   if(instanceId!="api-trial-"+TextValue(manifest,"id") || pipeName!="codex-api-question-trial-"+TextValue(manifest,"id"))throw new InvalidOperationException("Trial pipe binding changed.");
   Text="API 提问 · 隔离验证";Name="BridgeQuestions";ClientSize=new Size(830,590);MinimumSize=new Size(680,450);
   StartPosition=FormStartPosition.CenterScreen;Font=new Font("Microsoft YaHei UI",10);BackColor=Color.FromArgb(245,245,245);
   var footer=new FlowLayoutPanel { Dock=DockStyle.Bottom,Height=52,Padding=new Padding(12,8,12,4),FlowDirection=FlowDirection.RightToLeft };
   footer.Controls.Add(submit);footer.Controls.Add(open);
   Controls.Add(questions);Controls.Add(requests);Controls.Add(footer);Controls.Add(status);
   requests.SelectedIndexChanged+=(s,e)=>RenderSelected();submit.Click+=(s,e)=>Submit();open.Click+=(s,e)=>OpenTask();
   poll.Tick+=(s,e)=>RefreshPending();Shown+=(s,e)=>{poll.Start();RefreshPending();};
   FormClosed+=(s,e)=>{closed=true;poll.Stop();foreach(var editor in editors)editor.ClearSecret();};
   SetAvailable(false);status.Text="等待隔离桥接连接。关闭此窗口不会回答或取消问题。";
  }
  static Dictionary<string,object> Map(object value) { return value as Dictionary<string,object> ?? new Dictionary<string,object>(); }
  static string TextValue(Dictionary<string,object> map,string key) { object value;return map.TryGetValue(key,out value)&&value!=null?Convert.ToString(value):""; }
  static object[] ArrayValue(Dictionary<string,object> map,string key) { object value;return map.TryGetValue(key,out value)?value as object[] ?? new object[0]:new object[0]; }
  static bool BoolValue(Dictionary<string,object> map,string key) { object value;return map.TryGetValue(key,out value)&&value is bool&&(bool)value; }
  void SetAvailable(bool available) { submit.Enabled=available;open.Enabled=available&&File.Exists(Path.Combine(root,"desktop-process.json")); }
  Dictionary<string,object> Exchange(object command) {
   using(var pipe=new NamedPipeClientStream(".",pipeName,PipeDirection.InOut,PipeOptions.Asynchronous)) {
    pipe.Connect(700);
    using(var reader=new StreamReader(pipe,new UTF8Encoding(false),false,4096,true))
    using(var writer=new StreamWriter(pipe,new UTF8Encoding(false),4096,true) { AutoFlush=true }) {
     writer.WriteLine(json.Serialize(command));
     var read=reader.ReadLineAsync();if(!read.Wait(1800)){pipe.Dispose();throw new IOException("Bridge timeout.");}
     string line=read.Result;if(line==null||line.Length>4*1024*1024)throw new IOException("Invalid bridge response.");
     return Map(json.DeserializeObject(line));
    }
   }
  }
  void Dispatch(Action action) { if(closed||IsDisposed)return;try{BeginInvoke(action);}catch(InvalidOperationException){} }
  void RefreshPending() {
   if(busy||closed)return;
   if(File.Exists(Path.Combine(root,"DISABLED"))) { ClearPending();status.Text="桥接已停用。请在 Codex 原窗口继续作答。";return; }
   busy=true;
   Task.Run(()=>{
    try { var response=Exchange(new { command="snapshot" });Dispatch(()=>{
      busy=false;
      if(!BoolValue(response,"ok")||TextValue(response,"instanceId")!=instanceId){ClearPending();status.Text="桥接身份不匹配或已停用，请回 Codex 作答。";return;}
      UpdatePending(ArrayValue(response,"pending"));
     });
    }catch{Dispatch(()=>{busy=false;ClearPending();status.Text="连接不可用。请在 Codex 原窗口作答；连接恢复后会自动刷新。";});}
   });
  }
  void ClearPending() { selected=null;ClearEditors();requests.Items.Clear();drafts.Clear();SetAvailable(false); }
  void ClearEditors() { foreach(var editor in editors)editor.ClearSecret();editors.Clear();while(questions.Controls.Count>0)questions.Controls[0].Dispose(); }
  void UpdatePending(object[] items) {
   string keep=selected==null?null:selected.Key;
   var incoming=new List<Pending>();foreach(var item in items)incoming.Add(new Pending(Map(item)));
   bool unchanged=incoming.Count==requests.Items.Count;
   if(unchanged)for(int i=0;i<incoming.Count;i++)if(incoming[i].Key!=((Pending)requests.Items[i]).Key){unchanged=false;break;}
   if(!unchanged){
    SaveDraft();selected=null;
    requests.BeginUpdate();requests.Items.Clear();foreach(var item in incoming)requests.Items.Add(item);requests.EndUpdate();
    int index=incoming.FindIndex(p=>p.Key==keep);requests.SelectedIndex=index>=0?index:(incoming.Count>0?0:-1);
    foreach(var key in new List<string>(drafts.Keys))if(!incoming.Exists(p=>p.Key==key))drafts.Remove(key);
   }
   status.Text=incoming.Count==0?"没有待回答的问题。关闭窗口不会影响原任务。":"待回答 "+incoming.Count+" 项。仅点击提交才会发送答案；原窗口回答后这里会同步清除。";
   SetAvailable(selected!=null);
  }
  void RenderSelected() {
   SaveDraft();ClearEditors();selected=requests.SelectedItem as Pending;
   if(selected==null){SetAvailable(false);return;}
   foreach(var value in ArrayValue(selected.Value,"questions")) {
    var editor=new QuestionEditor(Map(value),Math.Max(420,questions.ClientSize.Width-42),Font);editors.Add(editor);questions.Controls.Add(editor.Panel);
    Dictionary<string,string> draft;string answer;if(drafts.TryGetValue(selected.Key,out draft)&&draft.TryGetValue(editor.Id,out answer))editor.Restore(answer);
   }
   SetAvailable(editors.Count>0);
  }
  void SaveDraft(){if(selected==null)return;var draft=new Dictionary<string,string>();foreach(var editor in editors)draft[editor.Id]=editor.Answer;drafts[selected.Key]=draft;}
  void Submit() {
   if(busy||selected==null)return;
   var answers=new Dictionary<string,object>();
   foreach(var editor in editors){string answer=editor.Answer;if(String.IsNullOrWhiteSpace(answer)){status.Text="请为每个问题选择选项或填写答案。";return;}answers[editor.Id]=new { answers=new[]{answer} };}
   var request=selected.Value;
   object id;request.TryGetValue("requestId",out id);
   var command=new { command="answer",connectionId=TextValue(request,"connectionId"),requestToken=TextValue(request,"requestToken"),requestId=id,threadId=TextValue(request,"threadId"),turnId=TextValue(request,"turnId"),answers=answers };
   busy=true;SetAvailable(false);status.Text="正在提交…";
   Task.Run(()=>{
    try{var response=Exchange(command);Dispatch(()=>{busy=false;status.Text=BoolValue(response,"ok")?"回答已转发，等待原任务继续。":"未提交：问题已变化、已回答或连接失效，请回 Codex 确认。";ClearPending();});}
    catch{Dispatch(()=>{busy=false;ClearPending();status.Text="无法确认提交结果，请回 Codex 检查；不会自动重发。";});}
   });
  }
  void OpenTask() {
   if(selected==null)return;
   Guid id;if(!Guid.TryParseExact(TextValue(selected.Value,"threadId"),"D",out id)){status.Text="该测试问题没有可打开的真实任务。";return;}
   var info=new ProcessStartInfo { FileName=Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.System),"WindowsPowerShell\\v1.0\\powershell.exe"),UseShellExecute=false,CreateNoWindow=true,RedirectStandardOutput=true,RedirectStandardError=true,
    Arguments="-NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File \""+Path.Combine(root,"Open-TrialTask.ps1")+"\" -TrialDirectory \""+root+"\" -ThreadId "+id.ToString() };
   status.Text="正在请求返回原任务…";
   Task.Run(()=>{try{using(var p=Process.Start(info)){p.StandardOutput.ReadToEndAsync();p.StandardError.ReadToEndAsync();if(!p.WaitForExit(15000)){Dispatch(()=>status.Text="打开请求尚未完成，请手动返回 Codex；没有重复发起。");return;}bool success=p.ExitCode==0;Dispatch(()=>status.Text=success?"已请求返回原任务，请在 Codex 确认。":"无法确认隔离窗口身份，请手动返回 Codex。");}}catch{Dispatch(()=>status.Text="无法打开原窗口，请手动返回 Codex。");}});
  }
  protected override void Dispose(bool disposing) { if(disposing)poll.Dispose();base.Dispose(disposing); }
  sealed class Pending {
   public readonly Dictionary<string,object> Value;public readonly string Key;
   public Pending(Dictionary<string,object> value){Value=value;Key=TextValue(value,"connectionId")+"/"+TextValue(value,"requestToken")+"/"+(value.ContainsKey("requestId")?new JavaScriptSerializer().Serialize(value["requestId"]):"")+"/"+TextValue(value,"threadId")+"/"+TextValue(value,"turnId");}
   public override string ToString(){var q=ArrayValue(Value,"questions");return q.Length==0?"待回答":TextValue(Map(q[0]),"header")+" · "+q.Length+" 题";}
  }
  sealed class QuestionEditor {
   public readonly Panel Panel;public readonly string Id;
   readonly List<RadioButton> options=new List<RadioButton>();readonly TextBox free;readonly RadioButton other;
   public QuestionEditor(Dictionary<string,object> question,int width,Font font) {
    Id=TextValue(question,"id");Panel=new Panel { Width=width,AutoSize=false,Margin=new Padding(0,0,0,16),Font=font };
    int y=0;var label=new Label { Name="Question_"+Id,Text=TextValue(question,"question"),Width=width-8,AutoSize=false,Font=font };
    label.Height=TextRenderer.MeasureText(label.Text,font,new Size(width-20,10000),TextFormatFlags.WordBreak).Height+20;Panel.Controls.Add(label);y+=label.Height;
    var values=ArrayValue(question,"options");foreach(var value in values){var option=Map(value);string text=TextValue(option,"label"),description=TextValue(option,"description");string display=text+(description.Length>0?" — "+description:"");var radio=new RadioButton { Name="Option_"+Id+"_"+options.Count,Text=display,Tag=text,Left=4,Top=y,Width=width-12,Height=Math.Max(32,TextRenderer.MeasureText(display,font,new Size(width-42,10000),TextFormatFlags.WordBreak).Height+16),AutoSize=false,Font=font };options.Add(radio);Panel.Controls.Add(radio);y+=radio.Height;}
    if(values.Length==0||BoolValue(question,"isOther")){
     if(values.Length>0){other=new RadioButton { Text="其他",Left=4,Top=y,Width=width-12,Height=28 };Panel.Controls.Add(other);y+=28;}
     free=new TextBox { Name="Answer_"+Id,Left=4,Top=y,Width=width-12,Height=58,Multiline=!BoolValue(question,"isSecret"),UseSystemPasswordChar=BoolValue(question,"isSecret") };
     free.TextChanged+=(s,e)=>{if(other!=null)other.Checked=true;};Panel.Controls.Add(free);y+=free.Height+4;
    }
    Panel.Height=y+4;
   }
   public string Answer { get { if(free!=null&&(other==null||other.Checked))return free.Text;foreach(var option in options)if(option.Checked)return (string)option.Tag;return ""; } }
   public void Restore(string answer){if(String.IsNullOrEmpty(answer))return;foreach(var option in options)if((string)option.Tag==answer){option.Checked=true;return;}if(free!=null){free.Text=answer;if(other!=null)other.Checked=true;}}
   public void ClearSecret(){if(free!=null&&!free.IsDisposed)free.Clear();}
  }
 }
 static class QuestionClient {
  [STAThread]static void Main(){Application.EnableVisualStyles();Application.SetCompatibleTextRenderingDefault(false);try{Application.Run(new QuestionWindow(AppDomain.CurrentDomain.BaseDirectory.TrimEnd(Path.DirectorySeparatorChar)));}catch{MessageBox.Show("无法读取隔离桥接配置。请使用原 Codex 窗口作答。","API 提问",MessageBoxButtons.OK,MessageBoxIcon.Warning);}}
 }
}
