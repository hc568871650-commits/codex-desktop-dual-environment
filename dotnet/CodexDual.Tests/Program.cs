using CodexDual.Core;
using CodexDual;
using System.Diagnostics;
using System.Net;
using System.Text;
using System.Text.Json;

string root = Path.Combine(Path.GetTempPath(), "codex-dual-dotnet-tests", Guid.NewGuid().ToString("N")); Directory.CreateDirectory(root);
var results = new List<object>(); int passed = 0, failed = 0;
string instanceId = new('a', 32), thread = Guid.NewGuid().ToString(), turn = Guid.NewGuid().ToString();
string Meta(string id, string source = "vscode", string extras = "") => $"{{\"type\":\"session_meta\",\"payload\":{{\"id\":\"{id}\",\"source\":\"{source}\",\"originator\":\"Codex Desktop\"{extras}}}}}\n";
string Complete(string turnId) => $"{{\"type\":\"event_msg\",\"payload\":{{\"type\":\"task_complete\",\"turn_id\":\"{turnId}\"}}}}\n";
void Assert(bool value, string description) { if (!value) throw new Exception(description); }
void Throws(Action action) { try { action(); } catch { return; } throw new Exception("Expected rejection"); }
async Task Rejects(Func<Task> action) { try { await action(); } catch { return; } throw new Exception("Expected rejection"); }
async Task Check(string name, Func<Task> action)
{
    var clock = Stopwatch.StartNew();
    try { await action(); passed++; results.Add(new { name, passed = true, milliseconds = clock.Elapsed.TotalMilliseconds }); }
    catch (Exception e) { failed++; results.Add(new { name, passed = false, error = e.Message }); Console.Error.WriteLine(name + ": " + e.Message); }
}
Task Sync(Action action) { action(); return Task.CompletedTask; }
string Log(string name, string text) { string path = Path.Combine(root, name + ".jsonl"); File.WriteAllText(path, text, new UTF8Encoding(false)); return path; }
LogCheckpoint Fresh(string file) => new() { Path = file };

await Check("new completion and duplicate turn", () => Sync(() => { var c = Fresh(Log("complete", Meta(thread) + Complete(turn) + Complete(turn))); var events = CompletionReader.Read(c, instanceId); Assert(events.Count == 1 && events[0].ThreadId == thread, "Duplicate or identity mismatch"); Assert(CompletionReader.Read(c, instanceId).Count == 0, "Replay on unchanged file"); }));
await Check("historical file is baselined", () => Sync(() => { var c = CompletionReader.Baseline(Log("history", Meta(thread) + Complete(turn))); Assert(CompletionReader.Read(c, instanceId).Count == 0, "Historical replay"); File.AppendAllText(c.Path, Complete(Guid.NewGuid().ToString())); Assert(CompletionReader.Read(c, instanceId).Count == 1, "Missed new event"); }));
await Check("partial UTF8 record across restart", () => Sync(() => { string line = Complete(turn); string file = Log("partial", Meta(thread) + line[..^5]); var c = Fresh(file); Assert(CompletionReader.Read(c, instanceId).Count == 0, "Partial delivered"); var resumed = JsonSerializer.Deserialize<LogCheckpoint>(JsonSerializer.Serialize(c))!; File.AppendAllText(file, line[^5..]); Assert(CompletionReader.Read(resumed, instanceId).Count == 1, "Partial lost on restart"); }));
await Check("historical incomplete line not replayed", () => Sync(() => { string line = Complete(turn); string file = Log("old-partial", Meta(thread) + line[..^5]); var c = CompletionReader.Baseline(file); File.AppendAllText(file, line[^5..] + Complete(Guid.NewGuid().ToString())); Assert(CompletionReader.Read(c, instanceId).Count == 1, "Replayed historical partial"); }));
await Check("invalid encoding fails closed", () => Sync(() => { string file = Log("utf8", Meta(thread)); using (var stream = File.Open(file, FileMode.Append)) stream.Write([255, 10]); var c = Fresh(file); Assert(CompletionReader.Read(c, instanceId).Count == 0 && c.Status == "InvalidJson", "Invalid UTF8 accepted"); }));
await Check("subagent and CLI logs rejected", () => Sync(() => { foreach (var text in new[] { Meta(thread, "cli"), Meta(thread, extras: ",\"agent_path\":\"/root/a\""), Meta(thread, extras: ",\"parent_thread_id\":\"" + Guid.NewGuid() + "\"") }) { var c = Fresh(Log(Guid.NewGuid().ToString(), text + Complete(turn))); Assert(CompletionReader.Read(c, instanceId).Count == 0 && c.Status == "InvalidMeta", "Foreign session accepted"); } }));
await Check("truncate fails closed", () => Sync(() => { var c = CompletionReader.Baseline(Log("truncate", Meta(thread) + Complete(turn))); File.WriteAllText(c.Path, ""); Assert(CompletionReader.Read(c, instanceId).Count == 0 && c.Status == "Truncated", "Truncate not detected"); }));
await Check("replacement detected even same length", () => Sync(() => { var c = CompletionReader.Baseline(Log("replace", Meta(thread))); File.Move(c.Path, c.Path + ".old"); File.WriteAllText(c.Path, Meta(thread)); Assert(CompletionReader.Read(c, instanceId).Count == 0 && c.Status == "Replaced", "Replacement not detected"); }));
await Check("oversized attachment skipped without losing completion", () => Sync(() => { var c = Fresh(Log("large", Meta(thread) + new string('x', CompletionReader.LineLimit + 1) + "\n" + Complete(turn))); Assert(CompletionReader.Read(c, instanceId).Count == 1 && c.Status == "Ready" && c.SkippedLines == 1, "Large attachment disabled notifications"); }));
await Check("oversized record recovery survives restart", () => Sync(() => { string file = Log("large-partial", Meta(thread) + new string('x', CompletionReader.LineLimit + 128)); var c = Fresh(file); Assert(CompletionReader.Read(c, instanceId).Count == 0 && c.SkippingOversizedLine, "Oversized partial not remembered"); var resumed = JsonSerializer.Deserialize<LogCheckpoint>(JsonSerializer.Serialize(c))!; File.AppendAllText(file, "tail\n" + Complete(turn)); Assert(CompletionReader.Read(resumed, instanceId).Count == 1 && !resumed.SkippingOversizedLine, "Post-restart completion lost"); }));
await Check("oversized metadata remains rejected", () => Sync(() => { var c = Fresh(Log("large-meta", new string('x', CompletionReader.LineLimit + 1) + "\n" + Complete(turn))); Assert(CompletionReader.Read(c, instanceId).Count == 0 && c.Status == "InvalidMeta", "Unverified file accepted"); }));
await Check("manual context excludes tools and instructions", () => Sync(() =>
{
    JsonElement Record(string role, string type, string text, string phase = "") => JsonSerializer.SerializeToElement(new { type = "response_item", payload = new { type, role, phase, content = new[] { new { type = "input_text", text } } } });
    Assert(ThreadContext.Message(Record("user", "message", "<environment_context>secret")) == null, "Injected instructions leaked");
    Assert(ThreadContext.Message(Record("assistant", "function_call", "secret")) == null, "Tool call leaked");
    Assert(ThreadContext.Message(Record("assistant", "message", "analysis", "analysis")) == null, "Analysis leaked");
    Assert(ThreadContext.Message(Record("user", "message", "实际的问题"))?.Text == "实际的问题", "User question lost");
}));
await Check("DPAPI compatible roundtrip", () => Sync(() => { string secret = "test-key-中文"; string encrypted = SecretStore.Protect(secret); Assert(SecretStore.Unprotect(encrypted) == secret, "DPAPI roundtrip failed"); }));
await Check("latest native title overrides initial database title", () => Sync(() => { string home = Path.Combine(root, "names"); Directory.CreateDirectory(home); File.WriteAllText(Path.Combine(home, "session_index.jsonl"), JsonSerializer.Serialize(new { id = thread, thread_name = "old" }) + "\n" + JsonSerializer.Serialize(new { id = thread, thread_name = "new" }) + "\n"); Assert(new ThreadContext(home).Title(thread) == "new", "Native rename index was ignored"); }));
await Check("chunk budget signals unread tail", () => Sync(() => { var c = Fresh(Log("budget", Meta(thread) + Complete(turn) + new string(' ', 1024))); CompletionReader.Read(c, instanceId, 64); Assert(c.More, "Unread chunk not rescheduled"); }));
await Check("TOML merge preserves unrelated config", () => Sync(() =>
{
    string original = "# preserved\nmodel_provider = 'dual-api'\nmodel = 'old'\n[custom]\nmessage = 'keep # this'\n";
    string updated = ApiProfiles.Merge(original, Path.Combine(root, "api"), "https://example.invalid/v1", "new-model");
    Assert(updated.Contains("# preserved") && updated.Contains("message = 'keep # this'"), "Unrelated text changed");
    Assert(new TomlConfig(updated).GetString("model") == "new-model", "Managed model not updated");
    Throws(() => ApiProfiles.Merge("model_provider='external'", root, "https://example.invalid", "x"));
}));
await Check("headers quoted commas and escaped values", () => Sync(() => { var values = RouteReader.InlineHeaders("{ 'x-one' = 'a,b', \"x-two\" = \"c\\\"d\" }"); Assert(TomlConfig.Decode(values["x-one"]) == "a,b" && TomlConfig.Decode(values["x-two"]) == "c\"d", "Inline headers corrupted"); Throws(() => RouteReader.InlineHeaders("{x={nested='no'}}")); }));
await Check("response validation and interrupted stream", async () =>
{
    Assert(TitleService.ValidateTitle("{\"title\":\"稳定的聊天标题\"}") == "稳定的聊天标题", "Title invalid");
    Throws(() => TitleService.ValidateTitle("{\"title\":\"ok\",\"extra\":1}")); Throws(() => TitleService.ValidateTitle("{\"title\":\"a\\nb\"}"));
    using var broken = new MemoryStream(Encoding.UTF8.GetBytes("data: {\"type\":\"response.output_text.delta\",\"delta\":\"partial\"}\n\ndata: [DONE]\n")); await Rejects(() => TitleService.ReadEvents(broken, CancellationToken.None));
});
await Check("CDP only accepts native local chat pages", () => Sync(() =>
{
    JsonElement Page(string url, string ws, string type = "page") => JsonSerializer.SerializeToElement(new { id = "ABC", type, url, webSocketDebuggerUrl = ws });
    Assert(DebugEndpoint.AllowedPage(Page("app://-/index.html", "ws://127.0.0.1:9222/devtools/page/ABC"), 9222), "Native page rejected");
    foreach (var p in new[] { Page("https://example.com", "ws://127.0.0.1:9222/devtools/page/ABC"), Page("app://-/index.html?browser", "ws://127.0.0.1:9222/devtools/page/ABC"), Page("app://-/index.html", "ws://example.com:9222/devtools/page/ABC"), Page("app://-/index.html", "ws://127.0.0.1:9222/devtools/page/OTHER") }) Assert(!DebugEndpoint.AllowedPage(p, 9222), "Foreign page accepted");
}));
await Check("title transport routing cache and zero tools", async () =>
{
    string home = Path.Combine(root, "title-home"), state = Path.Combine(root, "title-state"); Directory.CreateDirectory(home); Directory.CreateDirectory(state);
    string keyFile = Path.Combine(root, "fixture.dpapi"); File.WriteAllText(keyFile, SecretStore.Protect("fixture-key"));
    string config = "model_provider='test'\n[model_providers.test]\nbase_url='https://example.invalid/v1'\nenv_key='CODEX_DUAL_TEST_KEY'\nwire_api='responses'\nhttp_headers={ 'x-fixture'='a,b' }\n";
    Assert(!TitleSettings.Load(state).Enabled, "New installations must not enable title requests");
    File.WriteAllText(Path.Combine(home, "config.toml"), config); Json.Write(Path.Combine(state, "dotnet-title.local.json"), new TitleSettings { Enabled = true, Model = "test-model", Transport = "responses", CredentialFiles = new() { ["CODEX_DUAL_TEST_KEY"] = keyFile } });
    var handler = new RecordingHandler(); using var service = new TitleService(new() { Home = home }, state, new HealthStore(state), handler);
    var first = await service.GenerateAsync(Guid.NewGuid().ToString(), thread, "old", [new("user", "synthetic topic")], false, CancellationToken.None);
    var second = await service.GenerateAsync(Guid.NewGuid().ToString(), thread, "old", [new("user", "synthetic topic")], false, CancellationToken.None);
    Assert(!first.Cached && second.Cached && handler.Count == 1, "Cache not hit");
    Assert(handler.Key == "Bearer fixture-key" && handler.Header == "a,b" && handler.Endpoint == "https://example.invalid/v1/responses", "Route not preserved");
    using var body = JsonDocument.Parse(handler.Body); Assert(body.RootElement.GetProperty("tools").GetArrayLength() == 0 && body.RootElement.Text("tool_choice") == "none" && !body.RootElement.Flag("store"), "Unexpected tools/storage");
    File.WriteAllText(Path.Combine(home, "config.toml"), config.Replace("a,b", "changed"));
    await service.GenerateAsync(Guid.NewGuid().ToString(), thread, "old", [new("user", "synthetic topic")], false, CancellationToken.None); Assert(handler.Count == 2, "Config change hidden by cache");
});
await Check("file watcher delivers once and resumes", async () =>
{
    string home = Path.Combine(root, "watch-home"), state = Path.Combine(root, "watch-state"), sessions = Path.Combine(home, "sessions"); Directory.CreateDirectory(sessions);
    var api = new InstanceConfig { Id = instanceId, Role = "api", Home = home }; var health = new HealthStore(state);
    string file = Path.Combine(sessions, "active.jsonl"); File.WriteAllText(file, Meta(thread) + Complete(turn));
    await using (var monitor = new CompletionMonitor(api, state, health))
    {
        await monitor.StartAsync(); using var deadline = new CancellationTokenSource(TimeSpan.FromSeconds(5));
        while (health.Snapshot().All(h => h.State != "ready")) await Task.Delay(20, deadline.Token);
        string newTurn = Guid.NewGuid().ToString(); File.AppendAllText(file, Complete(newTurn));
        var result = await monitor.Completions.ReadAsync(deadline.Token); Assert(result.TurnId == newTurn, "History replayed or event lost");
        File.AppendAllText(file, Complete(newTurn)); await Task.Delay(300); Assert(!monitor.Completions.TryRead(out _), "Duplicate notification");
    }
    await using var resumed = new CompletionMonitor(api, state, health); await resumed.StartAsync(); await Task.Delay(300); Assert(!resumed.Completions.TryRead(out _), "Restart replayed history");
});
await Check("legacy checkpoint survives language migration", async () =>
{
    string home = Path.Combine(root, "legacy-home"), state = Path.Combine(root, "legacy-state"), sessions = Path.Combine(home, "sessions"), notices = Path.Combine(state, "notifications"); Directory.CreateDirectory(sessions); Directory.CreateDirectory(notices);
    string file = Path.Combine(sessions, "history.jsonl"); File.WriteAllText(file, Meta(thread) + Complete(turn));
    var baseline = CompletionReader.Baseline(file); string epoch = Guid.NewGuid().ToString("N");
    Json.Write(Path.Combine(notices, "settings.local.json"), new { epoch });
    Json.Write(Path.Combine(notices, "monitor-" + epoch + ".local.json"), new { schema = 1, instances = new[] { new { id = instanceId, home } }, files = new[] { new { path = file, instanceId, fileIdentity = baseline.FileIdentity, offset = baseline.Offset, threadId = thread, status = "Ready", idleLength = baseline.Length, lastWriteTicks = baseline.Written, seenTurns = new[] { turn } } } });
    string missed = Guid.NewGuid().ToString(); File.AppendAllText(file, Complete(missed));
    await using var monitor = new CompletionMonitor(new() { Id = instanceId, Role = "api", Home = home }, state, new HealthStore(state)); await monitor.StartAsync();
    using var timeout = new CancellationTokenSource(TimeSpan.FromSeconds(5)); var completion = await monitor.Completions.ReadAsync(timeout.Token); Assert(completion.TurnId == missed, "Migration skipped unread event or replayed history");
});

object? benchmark = null;
if (args.Contains("--benchmark"))
{
    string path = Path.Combine(root, "benchmark.jsonl");
    var payload = new StringBuilder(Meta(thread));
    for (int n = 0; n < 1000; n++) payload.Append(JsonSerializer.Serialize(new { type = "response_item", payload = new { type = "message", role = "assistant", content = new[] { new { type = "output_text", text = new string('x', 512) } } } })).Append('\n');
    payload.Append(Complete(turn)); File.WriteAllText(path, payload.ToString(), new UTF8Encoding(false));
    var durations = new List<double>(); var allocations = new List<long>();
    for (int n = 0; n < 6; n++) { var c = Fresh(path); long allocated = GC.GetAllocatedBytesForCurrentThread(); var clock = Stopwatch.StartNew(); var events = CompletionReader.Read(c, instanceId); Assert(events.Count == 1, "Benchmark correctness failed"); if (n > 0) { durations.Add(clock.Elapsed.TotalMilliseconds); allocations.Add(GC.GetAllocatedBytesForCurrentThread() - allocated); } }
    benchmark = new { fileBytes = new FileInfo(path).Length, milliseconds = durations, allocatedBytes = allocations, fixture = path };
}
var output = new { passed, failed, results, benchmark };
int reportAt = Array.IndexOf(args, "--report");
if (reportAt >= 0) Json.Write(args[reportAt + 1], output);
Console.WriteLine(JsonSerializer.Serialize(new { passed, failed, benchmark }, Json.Options));
return failed == 0 ? 0 : 1;

sealed class RecordingHandler : HttpMessageHandler
{
    public int Count; public string Key = "", Header = "", Endpoint = "", Body = "";
    protected override async Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancellationToken)
    {
        Count++; Key = request.Headers.Authorization?.ToString() ?? ""; Header = request.Headers.GetValues("x-fixture").Single(); Endpoint = request.RequestUri!.AbsoluteUri; Body = await request.Content!.ReadAsStringAsync(cancellationToken);
        string response = JsonSerializer.Serialize(new { type = "response.completed", response = new { status = "completed", output = new[] { new { type = "message", role = "assistant", content = new[] { new { type = "output_text", text = "{\"title\":\"合成标题验证\"}" } } } } } });
        return new(HttpStatusCode.OK) { Content = new StringContent("data: " + response + "\n\ndata: [DONE]\n", Encoding.UTF8, "text/event-stream") };
    }
}
