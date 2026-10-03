using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Net;
using System.Net.Sockets;
using System.Text;
using System.Threading;
using System.Web.Script.Serialization;

// Loopback-only fixture for an independently launched Desktop. Never drives or answers UI.
internal static class DesktopQuestionFixture {
 static readonly object Gate=new object();
 static readonly JavaScriptSerializer Json=new JavaScriptSerializer {MaxJsonLength=16*1024*1024,RecursionLimit=120};
 static string Root,ToolNamespace;
 static int Requests,Held,Completed;
 static bool AnswerReached;
 static readonly List<string> Errors=new List<string>();
 static Dictionary<string,object> Map(object value){return value as Dictionary<string,object>??new Dictionary<string,object>();}
 static object Get(Dictionary<string,object> map,string key){object value;return map.TryGetValue(key,out value)?value:null;}
 static string Str(object value){return value as string??"";}
 static void Save(string name,object value){File.WriteAllText(Path.Combine(Root,name),Json.Serialize(value),new UTF8Encoding(false));}
 static void State(){Save("state.json",new {requests=Requests,heldResponses=Held,completedResponses=Completed,answerReachedRuntime=AnswerReached,releaseRequested=File.Exists(Path.Combine(Root,"RELEASE")),errors=Errors.ToArray()});}
 static bool FindTool(object[] tools,string ns){
  foreach(object tool in tools){var map=Map(tool);string name=Str(Get(map,"name"));
   if(Str(Get(map,"type"))=="namespace"&&FindTool(Get(map,"tools") as object[]??new object[0],name))return true;
   if(name=="request_user_input_async"){ToolNamespace=ns;return true;}
  }return false;
 }
 static void Event(Stream stream,string name,object value){byte[] bytes=Encoding.UTF8.GetBytes("event: "+name+"\ndata: "+Json.Serialize(value)+"\n\n");stream.Write(bytes,0,bytes.Length);stream.Flush();}
 static void Respond(object state){var context=(HttpListenerContext)state;bool held=false;
  try{
   if(context.Request.Url.AbsolutePath!="/v1/responses"&&context.Request.Url.AbsolutePath!="/responses"){context.Response.StatusCode=404;context.Response.Close();return;}
   Dictionary<string,object> body;using(var reader=new StreamReader(context.Request.InputStream,Encoding.UTF8))body=Map(Json.DeserializeObject(reader.ReadToEnd()));
   object[] input=Get(body,"input") as object[]??new object[0];int request;bool first;string ns;
   lock(Gate){
    request=++Requests;first=request==1;
    foreach(object item in input){var entry=Map(item);if(Str(Get(entry,"role"))!="user")continue;
     string encoded=Json.Serialize(entry);if(encoded.Contains("send_user_message_question_reply")){AnswerReached=true;Save("answer-arrived.json",new {request=request,answerReachedRuntime=true,syntheticReply=entry});}
    }
    if(first){var tools=new List<object>(Get(body,"tools") as object[]??new object[0]);foreach(object item in input){var entry=Map(item);if(Str(Get(entry,"type"))=="additional_tools")tools.AddRange(Get(entry,"tools") as object[]??new object[0]);}
     if(!FindTool(tools.ToArray(),null))throw new InvalidOperationException("request_user_input_async was not offered by the CLI");
    }
    ns=ToolNamespace;held=!first;if(held)Held++;State();
   }
   context.Response.StatusCode=200;context.Response.ContentType="text/event-stream";context.Response.SendChunked=true;
   if(held){
    // Keep the turn active for answering and subsequent completion-notification inspection.
    DateTime deadline=DateTime.UtcNow.AddMinutes(5);
    while(!File.Exists(Path.Combine(Root,"RELEASE"))&&!File.Exists(Path.Combine(Root,"STOP"))&&DateTime.UtcNow<deadline){byte[] ping=Encoding.UTF8.GetBytes(": fixture awaiting RELEASE\n\n");context.Response.OutputStream.Write(ping,0,ping.Length);context.Response.OutputStream.Flush();Thread.Sleep(250);}
    if(!File.Exists(Path.Combine(Root,"RELEASE")))throw new TimeoutException("Fixture stopped or RELEASE was not created within five minutes");
   }
   object itemOutput;
   lock(Gate){
    if(first){var call=new Dictionary<string,object>{{"id","call_desktop_question"},{"type","function_call"},{"name","request_user_input_async"},{"call_id","desktop_fixture_call"},{"status","completed"},{"arguments",Json.Serialize(new {questions=new[]{new {title="本地桌面验收：请选择 B，然后等待完成。",options=new[]{"A","B"}}}})}};if(ns!=null)call["namespace"]=ns;itemOutput=call;}
    else itemOutput=new {id="msg_desktop_final_"+request,type="message",role="assistant",status="completed",content=new[]{new {type="output_text",text="本地桌面验收已完成。",annotations=new object[0]}}};
   }
   var response=new {id="resp_desktop_fixture_"+request,@object="response",created_at=DateTimeOffset.UtcNow.ToUnixTimeSeconds(),model=Str(Get(body,"model")),status="completed",output=new[]{itemOutput},parallel_tool_calls=false,usage=new {input_tokens=10,output_tokens=12,total_tokens=22,input_tokens_details=new {cached_tokens=0},output_tokens_details=new {reasoning_tokens=0}}};
   lock(Gate){
    Event(context.Response.OutputStream,"response.created",new {type="response.created",response=response,sequence_number=0});
    Event(context.Response.OutputStream,"response.output_item.added",new {type="response.output_item.added",output_index=0,item=itemOutput,sequence_number=1});
    Event(context.Response.OutputStream,"response.output_item.done",new {type="response.output_item.done",output_index=0,item=itemOutput,sequence_number=2});
    Event(context.Response.OutputStream,"response.completed",new {type="response.completed",response=response,sequence_number=3});
    Completed++;State();
   }
  }catch(Exception ex){lock(Gate){Errors.Add(ex.GetType().Name+": "+ex.Message);State();}try{context.Response.StatusCode=500;}catch{}}
  finally{if(held)lock(Gate){Held--;State();}try{context.Response.Close();}catch{}}
 }
 public static int Main(string[] args){
  if(args.Length<1)return 2;Root=Path.GetFullPath(args[0]);Directory.CreateDirectory(Root);
  int port=args.Length>1?int.Parse(args[1]):0;if(port==0){var socket=new TcpListener(IPAddress.Loopback,0);socket.Start();port=((IPEndPoint)socket.LocalEndpoint).Port;socket.Stop();}
  using(var server=new HttpListener()){
   server.Prefixes.Add("http://127.0.0.1:"+port+"/");server.Start();
   lock(Gate){Save("server.json",new {pid=System.Diagnostics.Process.GetCurrentProcess().Id,baseUrl="http://127.0.0.1:"+port+"/v1",questionMode="async",releaseFile=Path.Combine(Root,"RELEASE"),stopFile=Path.Combine(Root,"STOP")});State();}
   Console.WriteLine("Loopback Desktop fixture ready: "+Path.Combine(Root,"server.json"));
   var listener=new Thread(()=>{try{while(server.IsListening)ThreadPool.QueueUserWorkItem(Respond,server.GetContext());}catch(HttpListenerException){}catch(ObjectDisposedException){}}){IsBackground=true};listener.Start();
   while(!File.Exists(Path.Combine(Root,"STOP")))Thread.Sleep(250);server.Stop();
  }return 0;
 }
}
