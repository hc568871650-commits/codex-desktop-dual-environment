using System;
using System.Collections.Concurrent;
using System.Diagnostics;
using System.IO;
using System.IO.Pipes;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;
using System.Threading.Tasks;
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
  public bool StartSnapshot(){return Start("snapshot","{\"command\":\"snapshot\"}","");}
  public bool StartAnswer(string json,string token){return Start("answer",json,token);}
  bool Start(string kind,string command,string token) {
   if(disposed||Interlocked.CompareExchange(ref busy,1,0)!=0)return false;
   Task.Run(()=>{
    var result=new QuestionBridgeReply { Kind=kind,Token=token };
    try{
     if(File.Exists(disabledPath))throw new InvalidOperationException("disabled");
     using(var pipe=new NamedPipeClientStream(".",pipeName,PipeDirection.InOut,PipeOptions.Asynchronous)) {
      pipe.Connect(600);
      uint pid;if(!GetNamedPipeServerProcessId(pipe.SafePipeHandle.DangerousGetHandle(),out pid))throw new IOException("identity");
      using(var server=Process.GetProcessById((int)pid))if(!String.Equals(server.MainModule.FileName,proxyPath,StringComparison.OrdinalIgnoreCase))throw new IOException("identity");
      if(File.Exists(disabledPath))throw new InvalidOperationException("disabled");
      byte[] input=new UTF8Encoding(false).GetBytes(command+"\n");
      var write=pipe.WriteAsync(input,0,input.Length);if(!write.Wait(1000))throw new IOException("timeout");
      var timer=Stopwatch.StartNew();var bytes=new MemoryStream();var buffer=new byte[4096];bool ended=false;
      while(!ended){
       int wait=Math.Max(1,1800-(int)timer.ElapsedMilliseconds);var read=pipe.ReadAsync(buffer,0,buffer.Length);
       if(!read.Wait(wait))throw new IOException("timeout");int count=read.Result;if(count==0)throw new IOException("disconnected");
       for(int n=0;n<count;n++){if(buffer[n]==10){ended=true;break;}bytes.WriteByte(buffer[n]);}
       if(bytes.Length>1024*1024)throw new IOException("oversized");
       if(timer.ElapsedMilliseconds>1800&&!ended)throw new IOException("timeout");
      }
      string response=new UTF8Encoding(false,true).GetString(bytes.ToArray());
      var parser=new JavaScriptSerializer { MaxJsonLength=1024*1024 };
      var obj=parser.DeserializeObject(response) as System.Collections.Generic.Dictionary<string,object>;
      object identity;if(obj==null)throw new IOException("invalid");
      if(kind=="snapshot"&&(!obj.TryGetValue("instanceId",out identity)||(string)identity!=instanceId))throw new IOException("identity");
      result.Json=response;
     }
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
