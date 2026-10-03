using System;
using System.Collections.Concurrent;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.IO.Pipes;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;
using System.Threading.Tasks;
using System.Linq;
using System.Web.Script.Serialization;
namespace CodexDual {
 public sealed class QuestionBridgeReply {
  public string Kind,Json,Error,Token;
 }
 public sealed class QuestionBridgeClient : IDisposable {
  readonly string pipeName,proxyPath,instanceId,disabledPath;
  readonly ConcurrentQueue<QuestionBridgeReply> results=new ConcurrentQueue<QuestionBridgeReply>();
  int busy;volatile bool disposed;
  public bool Busy { get { return Volatile.Read(ref busy)!=0; } }
  [DllImport("kernel32.dll",SetLastError=true)]static extern bool GetNamedPipeServerProcessId(IntPtr pipe,out uint pid);
  public QuestionBridgeClient(string pipe,string proxy,string instance,string disabled) { pipeName=pipe;proxyPath=Path.GetFullPath(proxy);instanceId=instance;disabledPath=disabled; }
  public bool StartSnapshot(){return StartSnapshot(true);}
  public bool StartSnapshot(bool takeoverReady){return Start("snapshot","{\"command\":\"snapshot\",\"takeoverReady\":"+(takeoverReady?"true":"false")+"}","");}
  public bool StartAnswer(string json,string token){return Start("answer",json,token);}
  public bool StartRelease(string json,string token){return Start("release",json,token);}
  sealed class Endpoint { public string Pipe,Connection; public int Pid; public long Started; }
  static Dictionary<string,object> Map(object value){return value as Dictionary<string,object>;}
  static object Get(Dictionary<string,object> map,string key){object value;return map!=null&&map.TryGetValue(key,out value)?value:null;}
  static string Text(object value){return value as string??"";}
  static bool Plain(string path){return (File.GetAttributes(path)&FileAttributes.ReparsePoint)==0;}
  List<Endpoint> Endpoints() {
   string directory=Path.Combine(Path.GetDirectoryName(proxyPath),"connections");
   if(!Directory.Exists(directory))return new List<Endpoint>{new Endpoint{Pipe=pipeName}};
   if(!Plain(directory))throw new IOException("identity");
   var endpoints=new List<Endpoint>();
   // Bound work even if crash residues or unrelated files accumulate.
   foreach(string file in Directory.EnumerateFiles(directory,"*.json").Take(256)) {
    try {
     var info=new FileInfo(file);if(info.Length>8192||!Plain(file))continue;
     var obj=Map(new JavaScriptSerializer().DeserializeObject(File.ReadAllText(file,Encoding.UTF8)));
     if(Convert.ToInt32(Get(obj,"schema"))!=1||Text(Get(obj,"instanceId"))!=instanceId)continue;
     string connection=Text(Get(obj,"connectionId"));Guid guid;
     if(!Guid.TryParseExact(connection,"N",out guid))continue;
     int pid=Convert.ToInt32(Get(obj,"processId"));long started=Convert.ToInt64(Get(obj,"startedUtcTicks"));
     string pipe=pipeName+"-"+pid+"-"+connection;
     if(pid<=0||Text(Get(obj,"pipeName"))!=pipe||Path.GetFileName(file)!=pid+"-"+connection+".json")continue;
     using(var process=Process.GetProcessById(pid)) {
      if(process.HasExited||process.StartTime.ToUniversalTime().Ticks!=started||!String.Equals(process.MainModule.FileName,proxyPath,StringComparison.OrdinalIgnoreCase))continue;
     }
     endpoints.Add(new Endpoint{Pipe=pipe,Connection=connection,Pid=pid,Started=started});
     if(endpoints.Count==32)break;
    }catch(IOException){}catch(ArgumentException){}catch(InvalidOperationException){}catch(System.ComponentModel.Win32Exception){}catch(UnauthorizedAccessException){}catch(FormatException){}catch(OverflowException){}
   }
   return endpoints;
  }
  static async Task Within(Task operation,int milliseconds) {
   if(await Task.WhenAny(operation,Task.Delay(milliseconds)).ConfigureAwait(false)!=operation)throw new IOException("timeout");
   await operation.ConfigureAwait(false);
  }
  async Task<string> Exchange(Endpoint endpoint,string kind,string command) {
     if(File.Exists(disabledPath))throw new InvalidOperationException("disabled");
     using(var pipe=new NamedPipeClientStream(".",endpoint.Pipe,PipeDirection.InOut,PipeOptions.Asynchronous)) {
      await pipe.ConnectAsync(600).ConfigureAwait(false);
      uint pid;if(!GetNamedPipeServerProcessId(pipe.SafePipeHandle.DangerousGetHandle(),out pid))throw new IOException("identity");
      using(var server=Process.GetProcessById((int)pid)) {
       if(!String.Equals(server.MainModule.FileName,proxyPath,StringComparison.OrdinalIgnoreCase))throw new IOException("identity");
       if(endpoint.Pid!=0&&(endpoint.Pid!=pid||server.StartTime.ToUniversalTime().Ticks!=endpoint.Started))throw new IOException("identity");
      }
      if(File.Exists(disabledPath))throw new InvalidOperationException("disabled");
      byte[] input=new UTF8Encoding(false).GetBytes(command+"\n");
      await Within(pipe.WriteAsync(input,0,input.Length),1000).ConfigureAwait(false);
      var timer=Stopwatch.StartNew();var bytes=new MemoryStream();var buffer=new byte[4096];bool ended=false;
      while(!ended){
       int wait=Math.Max(1,1800-(int)timer.ElapsedMilliseconds);var read=pipe.ReadAsync(buffer,0,buffer.Length);
       await Within(read,wait).ConfigureAwait(false);int count=await read.ConfigureAwait(false);if(count==0)throw new IOException("disconnected");
       for(int n=0;n<count;n++){if(buffer[n]==10){ended=true;break;}bytes.WriteByte(buffer[n]);}
       if(bytes.Length>1024*1024)throw new IOException("oversized");
       if(timer.ElapsedMilliseconds>1800&&!ended)throw new IOException("timeout");
      }
      string response=new UTF8Encoding(false,true).GetString(bytes.ToArray());
      var obj=Map(new JavaScriptSerializer { MaxJsonLength=1024*1024 }.DeserializeObject(response));
      if(obj==null)throw new IOException("invalid");
      if(kind=="snapshot"&&Text(Get(obj,"instanceId"))!=instanceId)throw new IOException("identity");
      if(kind=="snapshot"&&endpoint.Connection!=null) {
       foreach(object item in Get(obj,"pending") as object[]??new object[0])
        if(Text(Get(Map(item),"connectionId"))!=endpoint.Connection)throw new IOException("identity");
      }
      return response;
     }
  }
  async Task<string> TrySnapshot(Endpoint endpoint,string command){try{return await Exchange(endpoint,"snapshot",command).ConfigureAwait(false);}catch(Exception){return null;}}
  async Task<string> Request(string kind,string command) {
   var endpoints=Endpoints();if(endpoints.Count==0)throw new IOException("unavailable");
   if(kind!="snapshot") {
    string connection=Text(Get(Map(new JavaScriptSerializer().DeserializeObject(command)),"connectionId"));
    var target=endpoints.SingleOrDefault(e=>e.Connection==null||e.Connection==connection);
    if(target==null)throw new IOException("stale");
    return await Exchange(target,kind,command).ConfigureAwait(false);
   }
   if(endpoints.Count==1&&endpoints[0].Connection==null)return await Exchange(endpoints[0],kind,command).ConfigureAwait(false);
   var tasks=endpoints.Select(e=>TrySnapshot(e,command)).ToArray();
   await Task.WhenAll(tasks).ConfigureAwait(false);
   var pending=new List<object>();var confirmedConnections=new List<string>();int available=0,failed=0;bool active=false;
   for(int index=0;index<tasks.Length;index++) {
    var task=tasks[index];
    if(task.Result==null){failed++;continue;}
    var obj=Map(new JavaScriptSerializer {MaxJsonLength=1024*1024}.DeserializeObject(task.Result));
    if(!(Get(obj,"ok") is bool)||!(bool)Get(obj,"ok")){failed++;continue;}
    available++;active|=Get(obj,"takeoverActive") is bool&&(bool)Get(obj,"takeoverActive");
    confirmedConnections.Add(endpoints[index].Connection);
    pending.AddRange(Get(obj,"pending") as object[]??new object[0]);
   }
   if(available==0)throw new IOException("unavailable");
   return new JavaScriptSerializer {MaxJsonLength=32*1024*1024}.Serialize(new {ok=true,instanceId=instanceId,takeoverActive=active,pending=pending,connections=available,unavailableConnections=failed,confirmedConnections=confirmedConnections});
  }
  bool Start(string kind,string command,string token) {
   if(disposed||Interlocked.CompareExchange(ref busy,1,0)!=0)return false;
   Task.Run(async ()=>{
    var result=new QuestionBridgeReply { Kind=kind,Token=token };
    try{
     if(File.Exists(disabledPath))throw new InvalidOperationException("disabled");
     result.Json=await Request(kind,command).ConfigureAwait(false);
    }catch(InvalidOperationException ex){result.Error=ex.Message=="disabled"?"disabled":"unavailable";}
     catch(Exception){result.Error="unavailable";}
    if(!disposed)results.Enqueue(result);Interlocked.Exchange(ref busy,0);
   });
   return true;
  }
  public QuestionBridgeReply Take(){QuestionBridgeReply result;return results.TryDequeue(out result)?result:null;}
  public void Dispose(){disposed=true;QuestionBridgeReply result;while(results.TryDequeue(out result)){} }
 }
}
