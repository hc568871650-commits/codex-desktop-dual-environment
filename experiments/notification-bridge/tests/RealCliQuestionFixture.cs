using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.IO.Pipes;
using System.Linq;
using System.Net;
using System.Net.Sockets;
using System.Text;
using System.Threading;
using System.Threading.Tasks;
using System.Web.Script.Serialization;

internal static class RealCliQuestionFixture {
 static readonly JavaScriptSerializer Json=new JavaScriptSerializer { MaxJsonLength=16*1024*1024,RecursionLimit=120 };
 static readonly List<string> Events=new List<string>();
 static readonly List<string> Tools=new List<string>();
 static string Failure,ChosenTool;
 static int Requests;
 static bool AnswerReachedRuntime;
 static bool TakeoverMode,AsyncMode;
 static string ModelName="fixture-model";
 static string FixtureDirectory,ToolNamespace;
 static int NativeQuestions;
 static readonly ManualResetEvent AnswerAccepted=new ManualResetEvent(false);
 static Process Proxy;
 static StreamWriter Input;
 static readonly Queue<Dictionary<string,object>> Messages=new Queue<Dictionary<string,object>>();
 static readonly AutoResetEvent Signal=new AutoResetEvent(false);
 static readonly object Gate=new object();
 static Dictionary<string,object> Map(object o){return o as Dictionary<string,object> ?? new Dictionary<string,object>();}
 static object Get(Dictionary<string,object> o,string key){object value;return o.TryGetValue(key,out value)?value:null;}
 static string Str(object o){return o==null?"":Convert.ToString(o);}
 static Dictionary<string,object> Message(int id,string method,object value){return Map(Json.DeserializeObject(Json.Serialize(new { id=id,method=method,@params=value })));}
 static void Send(object value){Input.WriteLine(Json.Serialize(value));Input.Flush();}
 static Dictionary<string,object> ReadUntil(Func<Dictionary<string,object>,bool> predicate,int seconds) {
  DateTime until=DateTime.UtcNow.AddSeconds(seconds);
  while(DateTime.UtcNow<until){
   lock(Gate)while(Messages.Count>0){var item=Messages.Dequeue();if(predicate(item))return item;}
   if(Proxy.HasExited)throw new Exception("Proxy exited: "+Proxy.ExitCode+" "+Failure);
   Signal.WaitOne(100);
  }
  throw new TimeoutException("App-server event timeout; last="+String.Join(",",Events.Skip(Math.Max(0,Events.Count-12)).ToArray())+"; fixture="+Failure);
 }
 static void ReadOutput() {
   try{string line;while((line=Proxy.StandardOutput.ReadLine())!=null){var value=Map(Json.DeserializeObject(line));lock(Gate){Messages.Enqueue(value);string method=Str(Get(value,"method"));if(method.Length>0)Events.Add(method);var item=Map(Get(Map(Get(value,"params")),"item"));if(method=="item/tool/requestUserInput"||(Get(item,"questions") as object[] ?? new object[0]).Length>0)NativeQuestions++;}Signal.Set();}}
  catch(Exception ex){Failure="stdout: "+ex.Message;Signal.Set();}
 }
 static void Respond(HttpListenerContext context) {
  try {
   if(context.Request.Url.AbsolutePath!="/v1/responses"&&context.Request.Url.AbsolutePath!="/responses") {context.Response.StatusCode=404;context.Response.Close();return;}
   Dictionary<string,object> body;
   using(var reader=new StreamReader(context.Request.InputStream,Encoding.UTF8))body=Map(Json.DeserializeObject(reader.ReadToEnd()));
   Requests++;
   File.WriteAllText(Path.Combine(FixtureDirectory,"request-shape.json"),Json.Serialize(new {keys=body.Keys.ToArray(),model=Get(body,"model"),request=Requests,inputTypes=(Get(body,"input") as object[]??new object[0]).Select(x=>Str(Get(Map(x),"type"))).ToArray()}),new UTF8Encoding(false));
   if(Requests>1)foreach(object input in Get(body,"input") as object[] ?? new object[0]) {
    var entry=Map(input);
    if(!AsyncMode&&Str(Get(entry,"type"))=="function_call_output"&&Str(Get(entry,"output")).Contains("B"))AnswerReachedRuntime=true;
    if(AsyncMode&&Str(Get(entry,"role"))=="user"&&Json.Serialize(entry).Contains("send_user_message_question_reply")&&Json.Serialize(entry).Contains("B"))AnswerReachedRuntime=true;
   }
   var allTools=new List<object>(Get(body,"tools") as object[]??new object[0]);
   foreach(object input in Get(body,"input") as object[]??new object[0]){var entry=Map(input);if(Str(Get(entry,"type"))=="additional_tools"){allTools.AddRange(Get(entry,"tools") as object[]??new object[0]);File.WriteAllText(Path.Combine(FixtureDirectory,"additional-tools.json"),Json.Serialize(entry),new UTF8Encoding(false));}}
   File.WriteAllText(Path.Combine(FixtureDirectory,"offered-tools.json"),Json.Serialize(allTools),new UTF8Encoding(false));
   CollectTools(allTools.ToArray(),null);
   ChosenTool=Tools.FirstOrDefault(x=>AsyncMode?x=="request_user_input_async":x=="request_user_input");
   if(ChosenTool==null)throw new Exception("No request_user_input tool offered: "+String.Join(",",Tools));
   bool subsequent=Requests>1;
   if(AsyncMode&&subsequent&&!AnswerReachedRuntime&&!AnswerAccepted.WaitOne(15000))throw new TimeoutException("Async answer was not accepted while the model response was held.");
   object questionArgs=AsyncMode?(object)new {questions=new[]{new {title="Choose B for the fixture.",options=new[]{"A","B"}}}}:new { questions=new[]{new { id="choice",header="Choice",question="Choose B for the fixture.",options=new[]{new { label="A",description="Wrong" },new { label="B",description="Continue" }} }} };
   object[] output=subsequent
    ?new object[]{new { id="msg_final",type="message",role="assistant",status="completed",content=new[]{new { type="output_text",text="Fixture completed after the user's answer.",annotations=new object[0] }} }}
    :new object[]{new { id="call_question",type="function_call",name=ChosenTool,call_id="fixture_call_1",status="completed",arguments=Json.Serialize(questionArgs) }};
   if(!subsequent&&ToolNamespace!=null){var toolCall=Map(Json.DeserializeObject(Json.Serialize(output[0])));toolCall["namespace"]=ToolNamespace;output[0]=toolCall;}
   var response=new { id="resp_fixture_"+Requests, @object="response",created_at=DateTimeOffset.UtcNow.ToUnixTimeSeconds(),model=Str(Get(body,"model")),status="completed",output=output,parallel_tool_calls=false,usage=new { input_tokens=10,output_tokens=12,total_tokens=22,input_tokens_details=new { cached_tokens=0 },output_tokens_details=new { reasoning_tokens=0 } } };
   string stream="event: response.created\ndata: "+Json.Serialize(new { type="response.created",response=response,sequence_number=0 })+"\n\n";
   stream+="event: response.output_item.added\ndata: "+Json.Serialize(new { type="response.output_item.added",output_index=0,item=output[0],sequence_number=1 })+"\n\n";
   stream+="event: response.output_item.done\ndata: "+Json.Serialize(new { type="response.output_item.done",output_index=0,item=output[0],sequence_number=2 })+"\n\n";
   stream+="event: response.completed\ndata: "+Json.Serialize(new { type="response.completed",response=response,sequence_number=3 })+"\n\n";
   byte[] bytes=Encoding.UTF8.GetBytes(stream);
   context.Response.StatusCode=200;context.Response.ContentType="text/event-stream";context.Response.SendChunked=true;context.Response.OutputStream.Write(bytes,0,bytes.Length);context.Response.Close();
  } catch(Exception ex) {Failure="fixture: "+ex.Message;try{context.Response.StatusCode=500;context.Response.Close();}catch{} }
 }
 static Dictionary<string,object> Pipe(string pipeName,object command) {
  using(var pipe=new NamedPipeClientStream(".",pipeName,PipeDirection.InOut)) {
   pipe.Connect(2000);
   using(var writer=new StreamWriter(pipe,new UTF8Encoding(false),4096,true)){writer.AutoFlush=true;writer.WriteLine(Json.Serialize(command));}
   using(var reader=new StreamReader(pipe,Encoding.UTF8,false,4096,true)){
    var task=reader.ReadLineAsync();if(!task.Wait(3000))throw new Exception("Pipe response timeout");return Map(Json.DeserializeObject(task.Result));
   }
  }
 }
 static void CollectTools(object[] tools,string ns){foreach(object tool in tools){var entry=Map(tool);string name=Str(Get(entry,"name"));if(Str(Get(entry,"type"))=="namespace"){CollectTools(Get(entry,"tools") as object[]??new object[0],name);continue;}if(name.Length>0&&!Tools.Contains(name))Tools.Add(name);if((AsyncMode&&name=="request_user_input_async")||(!AsyncMode&&name=="request_user_input"))ToolNamespace=ns;}}
 static void Require(bool condition,string message){if(!condition)throw new Exception(message);}
 static int Main(string[] args) {
  if(args.Length<3){Console.Error.WriteLine("Usage: RealCliQuestionFixture CLI BRIDGE OUTPUT-DIRECTORY [mirror|sync|async]");return 2;}
  TakeoverMode=args.Length>3&&args[3]!="mirror";AsyncMode=args.Length>3&&args[3]=="async";
  bool codeModeHost=args.Length>4&&string.Equals(args[4],"True",StringComparison.OrdinalIgnoreCase);
  bool multiConnection=args.Length>5&&string.Equals(args[5],"True",StringComparison.OrdinalIgnoreCase);
  ModelName=AsyncMode?"gpt-6-astra":"fixture-model";
  string directory=Path.GetFullPath(args[2]);Directory.CreateDirectory(directory);
  FixtureDirectory=directory;
  string home=Path.Combine(directory,"empty-home"),cwd=Path.Combine(directory,"work");Directory.CreateDirectory(home);Directory.CreateDirectory(cwd);
  string pipeName="codex-real-question-"+Guid.NewGuid().ToString("N");
  HttpListener server=null;
  System.Threading.Timer heartbeat=null;
  try {
   var socket=new TcpListener(IPAddress.Loopback,0);socket.Start();int port=((IPEndPoint)socket.LocalEndpoint).Port;socket.Stop();
   server=new HttpListener();server.Prefixes.Add("http://127.0.0.1:"+port+"/");server.Start();
   var listener=Task.Run(()=>{while(server.IsListening){try{var context=server.GetContext();Task.Run(()=>Respond(context));}catch(HttpListenerException){break;}catch(ObjectDisposedException){break;}}});
   string config="model = \"fixture-model\"\nmodel_provider = \"fixture\"\nmodel_reasoning_effort = \"low\"\n[model_providers.fixture]\nname = \"Local fixture\"\nbase_url = \"http://127.0.0.1:"+port+"/v1\"\nwire_api = \"responses\"\n";
   File.WriteAllText(Path.Combine(home,"config.toml"),config.Replace("fixture-model",ModelName),new UTF8Encoding(false));
   File.WriteAllText(Path.Combine(directory,"bridge.config.json"),Json.Serialize(new { realCli=Path.GetFullPath(args[0]),apiHome=home,pipeName=pipeName,instanceId="real-fixture-"+Guid.NewGuid().ToString("N"),takeoverQuestions=TakeoverMode,multiConnection=multiConnection }),new UTF8Encoding(false));
   var start=new ProcessStartInfo { FileName=Path.GetFullPath(args[1]),Arguments=AsyncMode?"-c features.send_message_to_user_async=true app-server":"app-server",WorkingDirectory=directory,UseShellExecute=false,CreateNoWindow=true,RedirectStandardInput=true,RedirectStandardOutput=true,RedirectStandardError=true,StandardOutputEncoding=Encoding.UTF8 };
   if(codeModeHost)start.Arguments="-c features.code_mode_host=true "+start.Arguments;
   foreach(string name in new List<string>(start.EnvironmentVariables.Keys.Cast<string>()))if(name.StartsWith("CODEX_",StringComparison.OrdinalIgnoreCase)||name.StartsWith("OPENAI_",StringComparison.OrdinalIgnoreCase)||name.StartsWith("CHATGPT_",StringComparison.OrdinalIgnoreCase)||name.IndexOf("API_KEY",StringComparison.OrdinalIgnoreCase)>=0)start.EnvironmentVariables.Remove(name);
   start.EnvironmentVariables["CODEX_HOME"]=home;
   Proxy=Process.Start(start);Input=Proxy.StandardInput;
   if(multiConnection){
    string registry=Path.Combine(directory,"connections");DateTime deadline=DateTime.UtcNow.AddSeconds(5);string record=null;
    while(DateTime.UtcNow<deadline){if(Directory.Exists(registry))record=Directory.GetFiles(registry,Proxy.Id+"-*.json").SingleOrDefault();if(record!=null)break;Thread.Sleep(20);}
    Require(record!=null,"Multi-connection registry was not published");
    var registration=Map(Json.DeserializeObject(File.ReadAllText(record)));Require(Convert.ToInt32(Get(registration,"processId"))==Proxy.Id,"Registered process differs");
    pipeName=Str(Get(registration,"pipeName"));
   }
   Task.Run((Action)ReadOutput);
   var stderr=Proxy.StandardError.ReadToEndAsync();
   Send(Message(1,"initialize",new { clientInfo=new { name="real_question_fixture",version="0.1.0" },capabilities=new { experimentalApi=true } }));
   var initialized=ReadUntil(x=>Str(Get(x,"id"))=="1",15);Require(Get(initialized,"result")!=null,"initialize failed: "+Json.Serialize(initialized));
   Send(new { method="initialized" });
   if(TakeoverMode){Pipe(pipeName,new {command="snapshot",takeoverReady=true});heartbeat=new System.Threading.Timer(_=>{try{Pipe(pipeName,new {command="snapshot",takeoverReady=true});}catch{}},null,500,500);}
   Send(Message(2,"thread/start",new { cwd=cwd,model=ModelName,modelProvider="fixture",approvalPolicy="never",sandbox="read-only",ephemeral=true }));
   var started=ReadUntil(x=>Str(Get(x,"id"))=="2",20);Require(Get(started,"result")!=null,"thread/start failed: "+Json.Serialize(started));
   var thread=Map(Get(Map(Get(started,"result")),"thread"));string threadId=Str(Get(thread,"id"));Require(threadId.Length>0,"No thread ID: "+Json.Serialize(started));
   Send(Message(3,"turn/start",new { threadId=threadId,input=new[]{new { type="text",text="Fixture: ask the user to choose B and then finish. No file access." }},collaborationMode=new { mode=AsyncMode?"default":"plan",settings=new { model=ModelName,reasoning_effort="low" } } }));
   var turn=ReadUntil(x=>Str(Get(x,"id"))=="3",20);Require(Get(turn,"result")!=null,"turn/start failed: "+Json.Serialize(turn));
   if(!TakeoverMode)ReadUntil(x=>Str(Get(x,"method"))=="item/tool/requestUserInput",25);
   object[] pending=null;DateTime pendingDeadline=DateTime.UtcNow.AddSeconds(25);
   do{pending=Get(Pipe(pipeName,new {command="snapshot",takeoverReady=TakeoverMode}),"pending") as object[];if(pending!=null&&pending.Length==1)break;Thread.Sleep(80);}while(DateTime.UtcNow<pendingDeadline);
   Require(pending!=null&&pending.Length==1,"Bridge did not capture genuine request");
   var item=Map(pending[0]);Require(Str(Get(item,"threadId"))==threadId,"Captured request thread differs");
   var normalized=Map(((object[])Get(item,"questions"))[0]);var answers=new Dictionary<string,object>{{Str(Get(normalized,"id")),new {answers=new[]{"B"}}}};
   var answer=Pipe(pipeName,new { command="answer",connectionId=Get(item,"connectionId"),requestToken=Get(item,"requestToken"),requestId=Get(item,"requestId"),threadId=Get(item,"threadId"),turnId=Get(item,"turnId"),answers=answers });
   Require(Get(answer,"ok") is bool&&(bool)Get(answer,"ok"),"Bridge rejected answer: "+Json.Serialize(answer));
   AnswerAccepted.Set();
   if(!TakeoverMode)ReadUntil(x=>Str(Get(x,"method"))=="serverRequest/resolved",10);
   ReadUntil(x=>Str(Get(x,"method"))=="turn/completed",25);
   Require(Requests>=2&&AnswerReachedRuntime,"Runtime did not pass user answer into next Responses request");
   Require(!TakeoverMode||NativeQuestions==0,"Takeover leaked a native question");
   File.WriteAllText(Path.Combine(directory,"evidence.json"),Json.Serialize(new { success=true,scope="real CLI with local Responses fixture",mode=args.Length>3?args[3]:"mirror",codeModeHost=codeModeHost,multiConnection=multiConnection,nativeQuestions=NativeQuestions,requests=Requests,offeredTools=Tools,chosenTool=ChosenTool,threadId=threadId,requestId=Get(item,"requestId"),bridgeAnswerAccepted=true,answerReachedRuntime=AnswerReachedRuntime,events=Events }),new UTF8Encoding(false));
   Console.WriteLine("PASS real CLI "+ChosenTool+" -> bridge answer -> runtime continued; native questions="+NativeQuestions+"; evidence: "+Path.Combine(directory,"evidence.json"));return 0;
  } catch(Exception ex) {
   File.WriteAllText(Path.Combine(directory,"failure.json"),Json.Serialize(new { success=false,error=ex.ToString(),fixtureError=Failure,requests=Requests,answerReachedRuntime=AnswerReachedRuntime,offeredTools=Tools,events=Events }),new UTF8Encoding(false));
   Console.Error.WriteLine(ex.Message+"; fixture="+Failure+"; evidence: "+Path.Combine(directory,"failure.json"));return 1;
  } finally {
   if(heartbeat!=null)heartbeat.Dispose();AnswerAccepted.Set();
   if(Proxy!=null){try{Input.Close();if(!Proxy.WaitForExit(2500)){Proxy.Kill();Proxy.WaitForExit(2000);}}catch{}Proxy.Dispose();}
   if(server!=null)server.Close();
  }
 }
}
