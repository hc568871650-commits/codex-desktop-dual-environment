using System.Collections.Concurrent;
using System.Net;
using System.Net.WebSockets;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.RegularExpressions;

namespace CodexDual.Core;

public sealed class CdpConnection : IAsyncDisposable
{
    private readonly ClientWebSocket socket = new();
    private readonly ConcurrentDictionary<int, TaskCompletionSource<JsonElement>> pending = new();
    private readonly SemaphoreSlim sending = new(1);
    private readonly CancellationTokenSource closed = new();
    private Task? reader; private int sequence;
    public event Action<JsonElement>? Event;
    public bool IsOpen => socket.State == WebSocketState.Open;
    public async Task ConnectAsync(Uri uri, CancellationToken cancel)
    {
        socket.Options.Proxy = null;
        await socket.ConnectAsync(uri, cancel); reader = Read();
    }
    public async Task<JsonElement> CallAsync(string method, object? parameters = null, CancellationToken cancel = default)
    {
        int id = Interlocked.Increment(ref sequence);
        var source = new TaskCompletionSource<JsonElement>(TaskCreationOptions.RunContinuationsAsynchronously);
        pending[id] = source;
        try
        {
            var bytes = JsonSerializer.SerializeToUtf8Bytes(new { id, method, @params = parameters ?? new { } });
            await sending.WaitAsync(cancel);
            try { await socket.SendAsync(bytes, WebSocketMessageType.Text, true, cancel); } finally { sending.Release(); }
            return await source.Task.WaitAsync(TimeSpan.FromSeconds(5), cancel);
        }
        finally { pending.TryRemove(id, out _); }
    }
    private async Task Read()
    {
        var buffer = new byte[16384];
        try
        {
            while (!closed.IsCancellationRequested)
            {
                using var message = new MemoryStream(); WebSocketReceiveResult result;
                do
                {
                    result = await socket.ReceiveAsync(new ArraySegment<byte>(buffer), closed.Token);
                    if (result.MessageType == WebSocketMessageType.Close) return;
                    if (result.MessageType != WebSocketMessageType.Text || message.Length + result.Count > 2 * 1024 * 1024) throw new IOException("调试消息大小或类型异常。");
                    message.Write(buffer, 0, result.Count);
                } while (!result.EndOfMessage);
                using var doc = JsonDocument.Parse(message.ToArray()); var root = doc.RootElement;
                if (root.TryGetProperty("id", out var id) && id.TryGetInt32(out int number) && pending.TryRemove(number, out var source))
                {
                    if (root.TryGetProperty("error", out _)) source.TrySetException(new IOException("Codex 页面接口不兼容。"));
                    else source.TrySetResult(root.GetProperty("result").Clone());
                }
                else if (root.TryGetProperty("method", out _)) Event?.Invoke(root.Clone());
            }
        }
        catch (Exception e) when (e is OperationCanceledException or WebSocketException or IOException or JsonException) { }
        finally { foreach (var item in pending.Values) item.TrySetException(new IOException("页面连接已断开。")); }
    }
    public async ValueTask DisposeAsync()
    {
        closed.Cancel(); socket.Abort(); if (reader != null) await reader; socket.Dispose(); closed.Dispose(); sending.Dispose();
    }
}

public static class DebugEndpoint
{
    [DllImport("iphlpapi.dll")] private static extern uint GetExtendedTcpTable(IntPtr table, ref int length, bool order, int family, int tableClass, uint reserved);
    public static void VerifyOwner(int port, int processId)
    {
        bool found = false;
        foreach (int family in new[] { 2, 23 })
        {
            int length = 0; GetExtendedTcpTable(IntPtr.Zero, ref length, false, family, 3, 0);
            if (length < 4 || length > 8 * 1024 * 1024) throw new IOException("无法核验本机调试端口。");
            IntPtr table = Marshal.AllocHGlobal(length);
            try
            {
                if (GetExtendedTcpTable(table, ref length, false, family, 3, 0) != 0) throw new IOException("无法核验本机调试端口。");
                int count = Marshal.ReadInt32(table), size = family == 2 ? 24 : 56;
                if (count < 0 || 4L + (long)count * size > length) throw new IOException("端口表无效。");
                for (int n = 0; n < count; n++)
                {
                    int offset = 4 + n * size, portAt = offset + (family == 2 ? 8 : 20);
                    int actualPort = (Marshal.ReadByte(table, portAt) << 8) | Marshal.ReadByte(table, portAt + 1);
                    if (actualPort != port) continue;
                    int pid = Marshal.ReadInt32(table, offset + (family == 2 ? 20 : 52));
                    var address = new byte[family == 2 ? 4 : 16]; Marshal.Copy(table + offset + (family == 2 ? 4 : 0), address, 0, address.Length);
                    if (pid != processId || !IPAddress.IsLoopback(new IPAddress(address))) throw new IOException("调试端口不属于已核验的本机 API 实例。");
                    found = true;
                }
            }
            finally { Marshal.FreeHGlobal(table); }
        }
        if (!found) throw new IOException("API 实例尚未开放本机调试接口。");
    }
    public static bool AllowedPage(JsonElement item, int port)
    {
        string id = item.Text("id");
        if (item.Text("type") != "page" || !Regex.IsMatch(id, "^[A-Za-z0-9_-]{1,100}$") || !Uri.TryCreate(item.Text("url"), UriKind.Absolute, out var page) || !Uri.TryCreate(item.Text("webSocketDebuggerUrl"), UriKind.Absolute, out var ws)) return false;
        return page.Scheme == "app" && page.Host == "-" && page.AbsolutePath == "/index.html" && !Regex.IsMatch(page.Query, "avatar|quick.?chat|codex.?micro|devtools|browser|spotlight", RegexOptions.IgnoreCase) && ws.Scheme == "ws" && ws.Host == "127.0.0.1" && ws.Port == port && ws.UserInfo.Length == 0 && ws.Query.Length == 0 && ws.Fragment.Length == 0 && ws.AbsolutePath == "/devtools/page/" + id;
    }
}

public sealed class TitleAdapter : IAsyncDisposable
{
    private sealed class Page(string id, CdpConnection cdp)
    {
        public string Id = id; public CdpConnection Cdp = cdp;
        public string Binding = "__codexTitleSend_" + Guid.NewGuid().ToString("N"), Receive = "__codexTitleReceive_" + Guid.NewGuid().ToString("N"), Nonce = Convert.ToHexString(RandomNumberGenerator.GetBytes(24));
        public ConcurrentDictionary<string, CancellationTokenSource> Requests = new();
        public bool Closed;
    }
    private readonly InstanceConfig instance;
    private readonly string state, renderer;
    private readonly ProcessManager processes;
    private readonly TitleService titles;
    private readonly HealthStore health;
    private readonly HttpClient http = new(new SocketsHttpHandler { AllowAutoRedirect = false, UseProxy = false }) { Timeout = TimeSpan.FromSeconds(3), MaxResponseContentBufferSize = 1024 * 1024 };
    private readonly Dictionary<string, Page> pages = new();
    private readonly ConcurrentDictionary<Task, byte> handlers = new();
    private readonly CancellationTokenSource stop = new();
    private Task? loop; private int targetPid; private long targetStarted;
    public TitleAdapter(InstanceConfig instance, string state, string renderer, ProcessManager processes, TitleService titles, HealthStore health)
    { this.instance = instance; this.state = state; this.renderer = renderer; this.processes = processes; this.titles = titles; this.health = health; }
    public void Start() => loop ??= Task.Run(Run);
    public static string Bootstrap(string binding, string receive, string nonce, string renderer)
    {
        string b = JsonSerializer.Serialize(binding), r = JsonSerializer.Serialize(receive), n = JsonSerializer.Serialize(nonce);
        return "(()=>{if(location.protocol!=='app:'||location.hostname!=='-'||location.pathname!=='/index.html')return false;window.__codexNativeTitle?.dispose?.();window.__codexTitleBridge?.dispose?.();const pending=new Map();let sequence=0;Object.defineProperty(window," + r + ",{configurable:true,value(message){const p=pending.get(message.id);if(!p)return;clearTimeout(p.timer);pending.delete(message.id);message.error?p.reject(new Error(message.error)):p.resolve(message.result);}});Object.defineProperty(window,'__codexTitleBridge',{configurable:true,value:{post(method,data){return new Promise((resolve,reject)=>{const id=String(++sequence),timer=setTimeout(()=>{pending.delete(id);reject(Error('timeout'));},55000);pending.set(id,{resolve,reject,timer});try{window[" + b + "](JSON.stringify({nonce:" + n + ",id,method,data}));}catch{clearTimeout(timer);pending.delete(id);reject(Error('unavailable'));}});},dispose(){for(const p of pending.values()){clearTimeout(p.timer);p.reject(Error('closed'));}pending.clear();delete window[" + r + "];}}});\n" + renderer + "\nreturn !!window.__codexNativeTitle;})()";
    }
    private async Task<JsonDocument> Get(int port, string route, CancellationToken cancel)
    {
        using var response = await http.GetAsync($"http://127.0.0.1:{port}{route}", cancel);
        response.EnsureSuccessStatusCode(); return JsonDocument.Parse(await response.Content.ReadAsByteArrayAsync(cancel));
    }
    private async Task Run()
    {
        int failures = 0;
        while (!stop.IsCancellationRequested)
        {
            try
            {
                if (!TitleSettings.Load(state).Enabled) { await DetachAll(); health.Set("title-adapter", "disabled", "标题建议已关闭"); }
                else
                {
                    var status = processes.Status(instance);
                    if (status.State != "Running" || status.Process == null) { await DetachAll(); health.Set("title-adapter", "waiting", status.State == "Unknown" ? status.Reason : "等待 API 环境启动"); }
                    else
                    {
                        var process = status.Process;
                        if (targetPid != process.Id || targetStarted != process.Started) { await DetachAll(); targetPid = process.Id; targetStarted = process.Started; }
                        string endpoint = Path.Combine(instance.Profile, "DevToolsActivePort");
                        if (!process.Command.Contains("--remote-debugging-port", StringComparison.Ordinal) || !File.Exists(endpoint) || File.GetLastWriteTimeUtc(endpoint).Ticks < process.Started - TimeSpan.FromSeconds(2).Ticks)
                        { await DetachAll(); health.Set("title-adapter", "restart-required", "标题服务已就绪；API 窗口需完整退出并重新打开一次，才能显示原生标题建议"); }
                        else
                        {
                            Paths.Regular(endpoint);
                            if (new FileInfo(endpoint).Length > 512) throw new IOException("调试端点文件异常。");
                            string[] lines = File.ReadAllLines(endpoint);
                            if (lines.Length != 2 || !int.TryParse(lines[0], out int port) || port is < 1 or > 65535 || !Regex.IsMatch(lines[1], "^/devtools/browser/[A-Za-z0-9_-]{1,100}$")) throw new IOException("调试端点格式不兼容。");
                            DebugEndpoint.VerifyOwner(port, process.Id);
                            if (!ProcessManager.Valid(instance, process)) throw new IOException("API 实例身份发生变化。");
                            using var version = await Get(port, "/json/version", stop.Token);
                            string expected = $"ws://127.0.0.1:{port}{lines[1]}";
                            if (version.RootElement.Text("webSocketDebuggerUrl") != expected) throw new IOException("调试浏览器身份不匹配。");
                            using var list = await Get(port, "/json/list", stop.Token);
                            if (list.RootElement.ValueKind != JsonValueKind.Array) throw new IOException("页面列表不兼容。");
                            var targets = list.RootElement.EnumerateArray().Where(p => DebugEndpoint.AllowedPage(p, port)).Take(8).ToArray();
                            foreach (var p in pages.Values.Where(p => p.Closed || !p.Cdp.IsOpen || !targets.Any(t => t.Text("id") == p.Id)).ToArray()) await Detach(p);
                            foreach (var t in targets) if (!pages.ContainsKey(t.Text("id"))) await Attach(t);
                            health.Set("title-adapter", pages.Count > 0 ? "ready" : "waiting", pages.Count > 0 ? "原生标题建议已连接" : "等待主聊天页面", FileVersion(process.Path));
                        }
                    }
                }
                failures = 0;
            }
            catch (OperationCanceledException) when (stop.IsCancellationRequested) { break; }
            catch (Exception e)
            {
                await DetachAll(); failures = Math.Min(failures + 1, 6);
                health.Set("title-adapter", "retrying", e is IOException ? e.Message : "标题窗口暂时无法连接，正在自动重试");
            }
            try { await Task.Delay(TimeSpan.FromSeconds(Math.Min(30, 3 + failures * 4)), stop.Token); } catch (OperationCanceledException) { break; }
        }
        await DetachAll();
    }
    private static string FileVersion(string path) => System.Diagnostics.FileVersionInfo.GetVersionInfo(path).FileVersion ?? Path.GetFileName(Path.GetDirectoryName(Path.GetDirectoryName(path)));
    private async Task Attach(JsonElement target)
    {
        var cdp = new CdpConnection(); var page = new Page(target.Text("id"), cdp);
        try
        {
            using var timeout = CancellationTokenSource.CreateLinkedTokenSource(stop.Token); timeout.CancelAfter(TimeSpan.FromSeconds(5));
            await cdp.ConnectAsync(new Uri(target.Text("webSocketDebuggerUrl")), timeout.Token);
            cdp.Event += ev =>
            {
                if (ev.Text("method") == "Runtime.executionContextsCleared") { page.Closed = true; foreach (var c in page.Requests.Values) c.Cancel(); }
                else if (ev.Text("method") == "Runtime.bindingCalled") { var task = Handle(page, ev); handlers[task] = 0; _ = task.ContinueWith(t => { handlers.TryRemove(t, out _); }, TaskScheduler.Default); }
            };
            await cdp.CallAsync("Runtime.enable", cancel: stop.Token);
            await cdp.CallAsync("Runtime.addBinding", new { name = page.Binding }, stop.Token);
            var result = await cdp.CallAsync("Runtime.evaluate", new { expression = Bootstrap(page.Binding, page.Receive, page.Nonce, renderer), returnByValue = true }, stop.Token);
            if (result.TryGetProperty("exceptionDetails", out _) || !result.TryGetProperty("result", out var value) || !value.Flag("value")) throw new IOException("当前原生页面不兼容；可使用控制器中的标题工具。");
            pages[page.Id] = page;
        }
        catch { await cdp.DisposeAsync(); throw; }
    }
    private async Task Handle(Page page, JsonElement ev)
    {
        string? requestId = null;
        try
        {
            if (page.Closed || !ev.TryGetProperty("params", out var parameters) || parameters.Text("name") != page.Binding) return;
            string payload = parameters.Text("payload"); if (payload.Length > 16384) return;
            using var doc = JsonDocument.Parse(payload); var message = doc.RootElement;
            if (message.Text("nonce") != page.Nonce || !Regex.IsMatch(message.Text("id"), "^[0-9]{1,12}$") || !message.TryGetProperty("data", out var data)) return;
            string method = message.Text("method"); requestId = data.Text("requestId");
            if (!CompletionReader.IsUuid(requestId)) return;
            object response;
            if (method == "/native/cancel") { if (page.Requests.TryGetValue(requestId, out var c)) c.Cancel(); response = new { id = message.Text("id"), result = new { cancelled = true } }; }
            else if (method == "/native/suggest")
            {
                if (page.Requests.Count >= 2) response = new { id = message.Text("id"), error = "busy" };
                else
                {
                    using var cancel = CancellationTokenSource.CreateLinkedTokenSource(stop.Token);
                    if (!page.Requests.TryAdd(requestId, cancel)) return;
                    try
                    {
                        if (!TitleSettings.Load(state).Enabled || page.Closed) return;
                        var result = await titles.SuggestAsync(requestId, data.Text("threadId"), data.Text("currentTitle"), data.Flag("refresh"), cancel.Token);
                        response = new { id = message.Text("id"), result };
                    }
                    catch { response = new { id = message.Text("id"), error = "generation_failed" }; }
                    finally { page.Requests.TryRemove(requestId, out _); }
                }
            }
            else return;
            if (!page.Closed) await page.Cdp.CallAsync("Runtime.evaluate", new { expression = $"window[{JsonSerializer.Serialize(page.Receive)}]?.({JsonSerializer.Serialize(response, Json.Options)})", contextId = parameters.GetProperty("executionContextId").GetInt32() }, stop.Token);
        }
        catch (Exception e) when (e is IOException or JsonException or OperationCanceledException or InvalidOperationException or WebSocketException or TimeoutException) { }
    }
    private async Task Detach(Page page)
    {
        page.Closed = true; pages.Remove(page.Id);
        foreach (var request in page.Requests.Values) request.Cancel();
        try { if (page.Cdp.IsOpen) await page.Cdp.CallAsync("Runtime.evaluate", new { expression = $"if(location.protocol==='app:'&&location.hostname==='-'&&location.pathname==='/index.html'){{window.__codexNativeTitle?.dispose?.();window.__codexTitleBridge?.dispose?.();delete window.__codexTitleBridge;delete window[{JsonSerializer.Serialize(page.Binding)}];}}" }); } catch { }
        await page.Cdp.DisposeAsync();
    }
    private async Task DetachAll() { foreach (var p in pages.Values.ToArray()) await Detach(p); }
    public async ValueTask DisposeAsync() { stop.Cancel(); if (loop != null) await loop; await Task.WhenAll(handlers.Keys); http.Dispose(); stop.Dispose(); }
}
