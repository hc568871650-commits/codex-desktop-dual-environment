using System.Buffers;
using System.Collections.Concurrent;
using System.Runtime.InteropServices;
using System.Text;
using System.Text.Json;
using System.Threading.Channels;
using Microsoft.Win32.SafeHandles;

namespace CodexDual.Core;

public sealed record Completion(string InstanceId, string ThreadId, string TurnId, DateTimeOffset ObservedAt);
public sealed class LogCheckpoint
{
    public string Path { get; set; } = "";
    public string FileIdentity { get; set; } = "";
    public long Offset { get; set; }
    public string ThreadId { get; set; } = "";
    public string Status { get; set; } = "AwaitingMeta";
    public HashSet<string> SeenTurns { get; set; } = new(StringComparer.OrdinalIgnoreCase);
    public long Length { get; set; }
    public long Written { get; set; }
    public bool SkippingOversizedLine { get; set; }
    public int SkippedLines { get; set; }
    [System.Text.Json.Serialization.JsonIgnore] public bool More { get; set; }
}
public static class FileIdentity
{
    [StructLayout(LayoutKind.Sequential)] private struct Info
    {
        public uint Attributes; public System.Runtime.InteropServices.ComTypes.FILETIME Created, Accessed, Written;
        public uint Volume, SizeHigh, SizeLow, Links, IndexHigh, IndexLow;
    }
    [DllImport("kernel32.dll", SetLastError = true)] private static extern bool GetFileInformationByHandle(SafeFileHandle handle, out Info info);
    public static string Of(FileStream stream)
    {
        if (!GetFileInformationByHandle(stream.SafeFileHandle, out var i)) throw new IOException("无法验证文件身份。");
        return $"{i.Volume:X8}:{i.IndexHigh:X8}{i.IndexLow:X8}";
    }
}

public static class CompletionReader
{
    public const int ChunkLimit = 1024 * 1024, LineLimit = 2 * 1024 * 1024;
    private static readonly UTF8Encoding Utf8 = new(false, true);
    public static bool IsUuid(string? value) => value != null && Guid.TryParseExact(value, "D", out var id) && id != Guid.Empty;
    public static bool Metadata(JsonElement item, out string id)
    {
        id = "";
        if (item.Text("type") != "session_meta" || !item.TryGetProperty("payload", out var p)) return false;
        if (!IsUuid(p.Text("id")) || p.Text("source") != "vscode" || p.Text("originator") != "Codex Desktop" || p.Text("parent_thread_id").Length != 0 || p.Text("agent_path").Length != 0 || p.Text("thread_source") == "subagent") return false;
        id = Guid.Parse(p.Text("id")).ToString(); return true;
    }
    public static LogCheckpoint Baseline(string path)
    {
        Paths.Regular(path);
        using var file = Open(path);
        var entry = new LogCheckpoint { Path = path, FileIdentity = FileIdentity.Of(file), Length = file.Length, Written = File.GetLastWriteTimeUtc(path).Ticks };
        // Inspect metadata only. Existing completion history is never replayed.
        var first = ReadLine(file, 65536);
        if (first == null) return entry;
        try
        {
            using var doc = JsonDocument.Parse(Utf8.GetString(first));
            if (!Metadata(doc.RootElement, out var id)) { entry.Status = "InvalidMeta"; return entry; }
            entry.ThreadId = id; entry.Status = "Ready";
            // If an old file ends in a partial line, skip that whole historical line when it finishes.
            entry.Offset = file.Length;
            if (file.Length > 0) { file.Position = file.Length - 1; if (file.ReadByte() != 10) entry.Status = "SkipHistoricalTail"; }
        }
        catch (Exception e) when (e is JsonException or DecoderFallbackException) { entry.Status = "InvalidMeta"; }
        return entry;
    }
    public static FileStream Open(string path) => new(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete, 65536, FileOptions.SequentialScan);
    public static byte[]? ReadLine(Stream stream, int limit)
    {
        var line = new ArrayBufferWriter<byte>();
        while (line.WrittenCount <= limit)
        {
            int b = stream.ReadByte(); if (b < 0) return null; if (b == 10) return line.WrittenSpan.ToArray();
            line.GetSpan(1)[0] = (byte)b; line.Advance(1);
        }
        throw new InvalidDataException("日志单行过长。");
    }
    public static List<Completion> Read(LogCheckpoint entry, string instanceId, int maxBytes = 4 * ChunkLimit)
    {
        var events = new List<Completion>();
        if (entry.Status == "LineTooLong" && IsUuid(entry.ThreadId)) entry.Status = "Ready";
        if (entry.Status is not ("Ready" or "AwaitingMeta" or "SkipHistoricalTail")) return events;
        try
        {
            Paths.Regular(entry.Path);
            using var stream = Open(entry.Path);
            var identity = FileIdentity.Of(stream);
            if (entry.FileIdentity.Length == 0) entry.FileIdentity = identity;
            if (identity != entry.FileIdentity) { entry.Status = "Replaced"; return events; }
            if (stream.Length < entry.Offset) { entry.Status = "Truncated"; return events; }
            stream.Position = entry.Offset;
            var buffer = ArrayPool<byte>.Shared.Rent(ChunkLimit);
            var pending = new ArrayBufferWriter<byte>();
            long committed = entry.Offset;
            try
            {
                int remaining = maxBytes;
                while (remaining > 0)
                {
                    var count = stream.Read(buffer, 0, Math.Min(ChunkLimit, remaining));
                    if (count == 0) break;
                    remaining -= count;
                    int start = 0;
                    while (start < count)
                    {
                        int relative = buffer.AsSpan(start, count - start).IndexOf((byte)10);
                        int length = relative < 0 ? count - start : relative;
                        if (!entry.SkippingOversizedLine && pending.WrittenCount + length > LineLimit)
                        {
                            if (entry.ThreadId.Length == 0) { entry.Status = "InvalidMeta"; break; }
                            entry.SkippingOversizedLine = true; pending.Clear();
                        }
                        if (!entry.SkippingOversizedLine) pending.Write(buffer.AsSpan(start, length));
                        start += length;
                        if (relative < 0) { if (entry.SkippingOversizedLine) committed = stream.Position - count + start; break; }
                        start++;
                        committed = stream.Position - count + start;
                        if (entry.SkippingOversizedLine) { entry.SkippingOversizedLine = false; entry.SkippedLines++; entry.Status = "Ready"; }
                        else if (entry.Status == "SkipHistoricalTail") entry.Status = "Ready";
                        else ParseLine(entry, pending.WrittenSpan, instanceId, events);
                        pending.Clear();
                        if (entry.Status is not ("Ready" or "AwaitingMeta")) break;
                    }
                    if (entry.Status is not ("Ready" or "AwaitingMeta" or "SkipHistoricalTail")) break;
                }
                entry.Offset = committed; // Partial bytes are reread after append/restart.
                entry.More = remaining == 0 && stream.Position < stream.Length;
                entry.Length = stream.Length; entry.Written = File.GetLastWriteTimeUtc(entry.Path).Ticks;
                if (entry.Status != "Ready") events.Clear();
            }
            finally { ArrayPool<byte>.Shared.Return(buffer); }
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException or DecoderFallbackException)
        { entry.Status = e is InvalidDataException ? "InvalidPath" : "ReadError"; events.Clear(); }
        return events;
    }
    private static void ParseLine(LogCheckpoint entry, ReadOnlySpan<byte> bytes, string instanceId, List<Completion> events)
    {
        try
        {
            using var doc = JsonDocument.Parse(Utf8.GetString(bytes));
            var item = doc.RootElement;
            if (entry.ThreadId.Length == 0)
            {
                if (!Metadata(item, out var id)) { entry.Status = "InvalidMeta"; return; }
                entry.ThreadId = id; entry.Status = "Ready"; return;
            }
            if (item.Text("type") != "event_msg" || !item.TryGetProperty("payload", out var p) || p.Text("type") != "task_complete" || !IsUuid(p.Text("turn_id"))) return;
            var turn = Guid.Parse(p.Text("turn_id")).ToString();
            if (entry.SeenTurns.Count >= 65536) { entry.Status = "TurnLimit"; return; }
            if (entry.SeenTurns.Add(turn)) events.Add(new(instanceId, entry.ThreadId, turn, DateTimeOffset.UtcNow));
        }
        catch (Exception e) when (e is JsonException or DecoderFallbackException)
        { entry.Status = entry.ThreadId.Length == 0 ? "InvalidMeta" : "InvalidJson"; }
    }
}

public sealed class CompletionMonitor : IAsyncDisposable
{
    private sealed record Saved(int Schema, string InstanceId, string Home, List<LogCheckpoint> Files, List<string> Delivered);
    private readonly InstanceConfig instance;
    private readonly string root, checkpoint;
    private readonly HealthStore health;
    private readonly Dictionary<string, LogCheckpoint> entries = new(StringComparer.OrdinalIgnoreCase);
    private readonly HashSet<string> delivered = new(StringComparer.OrdinalIgnoreCase);
    private readonly ConcurrentDictionary<string, byte> changed = new(StringComparer.OrdinalIgnoreCase);
    private readonly Channel<bool> wake = Channel.CreateBounded<bool>(new BoundedChannelOptions(1) { FullMode = BoundedChannelFullMode.DropWrite });
    private readonly Channel<Completion> completed = Channel.CreateUnbounded<Completion>(new() { SingleWriter = true, SingleReader = true });
    private readonly CancellationTokenSource stop = new();
    private FileSystemWatcher? watcher;
    private Task? running;
    private volatile bool rescan;
    private DateTime nextScan;
    public ChannelReader<Completion> Completions => completed.Reader;
    public int FileCount => entries.Count;
    public CompletionMonitor(InstanceConfig api, string state, HealthStore health)
    {
        if (api.Role != "api") throw new InvalidDataException("通知仅监测 API 环境。");
        instance = api; root = Path.Combine(api.Home, "sessions"); checkpoint = Path.Combine(state, "notifications", "dotnet-monitor.local.json"); this.health = health;
        if (Paths.Overlap(state, api.Home)) throw new InvalidDataException("状态目录与聊天目录重叠。");
    }
    public Task StartAsync() { running ??= Task.Run(Run); return Task.CompletedTask; }
    private void Signal(string path) { if (Paths.Inside(path, root) && path.EndsWith(".jsonl", StringComparison.OrdinalIgnoreCase)) changed[path] = 0; wake.Writer.TryWrite(true); }
    private IEnumerable<string> Files()
    {
        if (!Directory.Exists(root)) yield break;
        Paths.Regular(root);
        var stack = new Stack<string>(); stack.Push(root); int dirs = 0, files = 0;
        while (stack.Count > 0)
        {
            var dir = stack.Pop(); if (++dirs > 20000) throw new IOException("会话目录超过监测上限。");
            foreach (var child in Directory.EnumerateDirectories(dir)) if ((File.GetAttributes(child) & FileAttributes.ReparsePoint) == 0) stack.Push(child);
            foreach (var file in Directory.EnumerateFiles(dir, "*.jsonl"))
            {
                if ((File.GetAttributes(file) & FileAttributes.ReparsePoint) != 0) continue;
                if (++files > 10000) throw new IOException("会话文件超过监测上限。");
                yield return file;
            }
        }
    }
    private void Watch()
    {
        if (watcher != null || !Directory.Exists(root)) return;
        Paths.Regular(root);
        watcher = new FileSystemWatcher(root, "*.jsonl") { IncludeSubdirectories = true, NotifyFilter = NotifyFilters.FileName | NotifyFilters.LastWrite | NotifyFilters.Size | NotifyFilters.DirectoryName, InternalBufferSize = 32768 };
        watcher.Changed += (_, e) => Signal(e.FullPath); watcher.Created += (_, e) => Signal(e.FullPath); watcher.Renamed += (_, e) => Signal(e.FullPath);
        watcher.Error += (_, _) => { rescan = true; wake.Writer.TryWrite(true); };
        watcher.EnableRaisingEvents = true;
    }
    private void Initialize()
    {
        if (File.Exists(checkpoint))
        {
            var saved = Json.Read<Saved>(checkpoint, 32 * 1024 * 1024);
            if (saved.Schema != 1 || saved.InstanceId != instance.Id || !Paths.Same(saved.Home, instance.Home) || saved.Files.Count > 10000) throw new InvalidDataException("通知记录不属于此环境。");
            foreach (var e in saved.Files)
            {
                if (!Paths.Inside(e.Path, root) || e.Offset < 0 || e.SeenTurns.Count > 65536) throw new InvalidDataException("通知文件记录无效。");
                entries[e.Path] = e;
                if (e.Status == "LineTooLong" && CompletionReader.IsUuid(e.ThreadId)) { e.Status = "Ready"; changed[e.Path] = 0; }
            }
            foreach (var key in saved.Delivered.TakeLast(65536)) delivered.Add(key);
        }
        else if (!ImportLegacy())
        {
            foreach (var file in Files())
            {
                try { entries[file] = CompletionReader.Baseline(file); }
                catch (IOException) { entries[file] = new() { Path = file, Status = "ReadError" }; }
            }
        }
        Watch(); rescan = true; Save();
    }
    private bool ImportLegacy()
    {
        string folder = Path.GetDirectoryName(checkpoint)!, settingsPath = Path.Combine(folder, "settings.local.json");
        if (!File.Exists(settingsPath)) return false;
        using var settings = Json.Read<JsonDocument>(settingsPath, 65536);
        string epoch = settings.RootElement.Text("epoch");
        if (!Guid.TryParseExact(epoch, "N", out _)) return false;
        string oldPath = Path.Combine(folder, "monitor-" + epoch + ".local.json");
        if (!File.Exists(oldPath)) return false;
        using var saved = Json.Read<JsonDocument>(oldPath, 32 * 1024 * 1024); var value = saved.RootElement;
        if (value.GetProperty("schema").GetInt32() != 1 || !value.GetProperty("instances").EnumerateArray().Any(i => i.Text("id") == instance.Id && Paths.Same(i.Text("home"), instance.Home))) throw new InvalidDataException("旧通知记录不属于当前 API 环境。");
        foreach (var file in value.GetProperty("files").EnumerateArray())
        {
            if (file.Text("instanceId") != instance.Id) continue;
            string path = file.Text("path");
            if (!Paths.Inside(path, root) || entries.Count >= 10000) throw new InvalidDataException("旧通知记录中的文件路径无效。");
            var entry = new LogCheckpoint { Path = path, FileIdentity = file.Text("fileIdentity"), Offset = file.GetProperty("offset").GetInt64(), ThreadId = file.Text("threadId"), Status = file.Text("status"), Length = file.GetProperty("idleLength").GetInt64(), Written = file.GetProperty("lastWriteTicks").GetInt64() };
            if (entry.Offset < 0) throw new InvalidDataException("旧通知读取位置无效。");
            foreach (var turn in file.GetProperty("seenTurns").EnumerateArray()) if (CompletionReader.IsUuid(turn.GetString())) { entry.SeenTurns.Add(turn.GetString()!); delivered.Add(entry.ThreadId + "/" + turn.GetString()); }
            if (entry.SeenTurns.Count > 65536) throw new InvalidDataException("旧通知去重记录超过上限。");
            entries[path] = entry;
            if (entry.Status == "LineTooLong" && CompletionReader.IsUuid(entry.ThreadId)) { entry.Status = "Ready"; changed[path] = 0; }
        }
        return true;
    }
    private void Save() => Json.Write(checkpoint, new Saved(1, instance.Id, instance.Home, entries.Values.ToList(), delivered.TakeLast(65536).ToList()));
    private async Task Run()
    {
        try
        {
            Initialize(); health.Set("notifications", "ready", "正在监听新增完成事件");
            while (!stop.IsCancellationRequested)
            {
                bool dirty = false;
                if (rescan || DateTime.UtcNow >= nextScan)
                {
                    Watch();
                    foreach (var file in Files())
                    {
                        if (!entries.TryGetValue(file, out var e)) { entries[file] = new() { Path = file }; changed[file] = 0; dirty = true; }
                        else { var info = new FileInfo(file); if (info.Length != e.Length || info.LastWriteTimeUtc.Ticks != e.Written) changed[file] = 0; }
                    }
                    rescan = false; nextScan = DateTime.UtcNow.AddSeconds(60);
                }
                int budget = 8;
                foreach (var path in changed.Keys)
                {
                    if (budget-- <= 0) break;
                    if (!changed.TryRemove(path, out _) || !File.Exists(path)) continue;
                    Paths.Regular(path);
                    if (!entries.TryGetValue(path, out var entry)) { if (entries.Count >= 10000) throw new IOException("会话文件超过监测上限。"); entries[path] = entry = new() { Path = path }; }
                    var events = CompletionReader.Read(entry, instance.Id);
                    dirty = true;
                    if (entry.Status == "Ready")
                    {
                        foreach (var e in events) if (delivered.Add(e.ThreadId + "/" + e.TurnId)) await completed.Writer.WriteAsync(e, stop.Token);
                        if (entry.More) Signal(path);
                    }
                    else if (entry.Status is not ("AwaitingMeta" or "InvalidMeta" or "SkipHistoricalTail")) health.Set("notifications", "warning", "部分日志读取异常：" + entry.Status);
                }
                if (dirty) Save();
                if (!changed.IsEmpty) { await Task.Delay(50, stop.Token); continue; }
                using var wait = CancellationTokenSource.CreateLinkedTokenSource(stop.Token);
                wait.CancelAfter(TimeSpan.FromSeconds(10));
                try { await wake.Reader.ReadAsync(wait.Token); await Task.Delay(100, stop.Token); } catch (OperationCanceledException) when (!stop.IsCancellationRequested) { }
            }
        }
        catch (OperationCanceledException) when (stop.IsCancellationRequested) { }
        catch (Exception e) { health.Set("notifications", "failed", e is IOException ? e.Message : "通知监测失败，请重新检查。"); }
        finally { watcher?.Dispose(); completed.Writer.TryComplete(); }
    }
    public async ValueTask DisposeAsync()
    {
        stop.Cancel(); if (running != null) await running; stop.Dispose();
    }
}
