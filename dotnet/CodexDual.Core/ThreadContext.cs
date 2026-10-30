using System.Runtime.InteropServices;
using System.Text;
using System.Text.Json;

namespace CodexDual.Core;

// Uses the Windows SQLite library in read-only mode. Never writes Codex databases.
public sealed class ReadOnlySqlite : IDisposable
{
    private IntPtr database;
    [DllImport("winsqlite3", CallingConvention = CallingConvention.Cdecl)] private static extern int sqlite3_open_v2([MarshalAs(UnmanagedType.LPUTF8Str)] string name, out IntPtr db, int flags, IntPtr vfs);
    [DllImport("winsqlite3", CallingConvention = CallingConvention.Cdecl)] private static extern int sqlite3_close_v2(IntPtr db);
    [DllImport("winsqlite3", CallingConvention = CallingConvention.Cdecl)] private static extern int sqlite3_busy_timeout(IntPtr db, int ms);
    [DllImport("winsqlite3", CallingConvention = CallingConvention.Cdecl)] private static extern int sqlite3_prepare_v2(IntPtr db, [MarshalAs(UnmanagedType.LPUTF8Str)] string sql, int length, out IntPtr statement, IntPtr tail);
    [DllImport("winsqlite3", CallingConvention = CallingConvention.Cdecl)] private static extern int sqlite3_bind_text(IntPtr statement, int index, [MarshalAs(UnmanagedType.LPUTF8Str)] string text, int length, IntPtr destructor);
    [DllImport("winsqlite3", CallingConvention = CallingConvention.Cdecl)] private static extern int sqlite3_step(IntPtr statement);
    [DllImport("winsqlite3", CallingConvention = CallingConvention.Cdecl)] private static extern int sqlite3_finalize(IntPtr statement);
    [DllImport("winsqlite3", CallingConvention = CallingConvention.Cdecl)] private static extern int sqlite3_column_count(IntPtr statement);
    [DllImport("winsqlite3", CallingConvention = CallingConvention.Cdecl)] private static extern IntPtr sqlite3_column_text(IntPtr statement, int index);
    [DllImport("winsqlite3", CallingConvention = CallingConvention.Cdecl)] private static extern int sqlite3_column_bytes(IntPtr statement, int index);
    public ReadOnlySqlite(string path)
    {
        Paths.Regular(path); foreach (var suffix in new[] { "-wal", "-shm", "-journal" }) Paths.Regular(path + suffix);
        if (!File.Exists(path)) throw new IOException("聊天索引不存在。");
        if (sqlite3_open_v2(path, out database, 1 /* SQLITE_OPEN_READONLY */, IntPtr.Zero) != 0) { Dispose(); throw new IOException("聊天索引无法只读打开。"); }
        sqlite3_busy_timeout(database, 1000);
    }
    public List<string?[]> Query(string sql, params string[] parameters)
    {
        if (sqlite3_prepare_v2(database, sql, -1, out var statement, IntPtr.Zero) != 0) throw new IOException("聊天索引结构不兼容。");
        try
        {
            for (int n = 0; n < parameters.Length; n++) if (sqlite3_bind_text(statement, n + 1, parameters[n], -1, new IntPtr(-1)) != 0) throw new IOException("查询参数无效。");
            var rows = new List<string?[]>(); int rc;
            while ((rc = sqlite3_step(statement)) == 100)
            {
                if (rows.Count >= 1024) throw new IOException("查询结果超过上限。");
                int count = sqlite3_column_count(statement); var row = new string?[count];
                for (int n = 0; n < count; n++) { int length = sqlite3_column_bytes(statement, n); if (length > 131072) throw new IOException("索引字段过长。"); var pointer = sqlite3_column_text(statement, n); row[n] = pointer == IntPtr.Zero ? null : Marshal.PtrToStringUTF8(pointer, length); }
                rows.Add(row);
            }
            if (rc != 101) throw new IOException("聊天索引暂时不可读取。");
            return rows;
        }
        finally { sqlite3_finalize(statement); }
    }
    public void Dispose() { if (database != IntPtr.Zero) { sqlite3_close_v2(database); database = IntPtr.Zero; } }
}

public sealed record ChatInfo(string Id, string Title, string RolloutPath);
public sealed record Excerpt(string Role, string Text);
public sealed class ThreadContext(string home)
{
    private static readonly UTF8Encoding Utf8 = new(false, true);
    private static readonly string[] Synthetic = ["# AGENTS.md instructions", "<environment_context>", "<permissions instructions>", "<turn_aborted>", "<system-reminder>", "<INSTRUCTIONS>", "<user_instructions>", "<local-command-caveat>"];
    public Dictionary<string, string> Names()
    {
        var result = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
        string path = Path.Combine(home, "session_index.jsonl");
        if (!File.Exists(path)) return result;
        Paths.Regular(path); using var stream = CompletionReader.Open(path);
        if (stream.Length > 16 * 1024 * 1024) throw new IOException("标题索引过大，请通过原生重命名窗口操作。");
        using var reader = new StreamReader(stream, new UTF8Encoding(false, true)); string? line;
        while ((line = reader.ReadLine()) != null)
        {
            if (line.Length > 65536) continue;
            try { using var doc = JsonDocument.Parse(line); string id = doc.RootElement.Text("id"), title = doc.RootElement.Text("thread_name"); if (CompletionReader.IsUuid(id) && title.Length is > 0 and <= 200) result[id] = title; } catch (JsonException) { }
        }
        return result;
    }
    public List<ChatInfo> List()
    {
        using var db = new ReadOnlySqlite(Path.Combine(home, "state_5.sqlite"));
        var names = Names();
        return db.Query("SELECT id, substr(title,1,200), rollout_path FROM threads WHERE archived=0 ORDER BY updated_at DESC LIMIT 100")
            .Where(r => CompletionReader.IsUuid(r[0])).Select(r => new ChatInfo(r[0]!, names.GetValueOrDefault(r[0]!) ?? r[1] ?? "未命名聊天", r[2] ?? "")).ToList();
    }
    public string Title(string threadId)
    {
        if (!CompletionReader.IsUuid(threadId)) return "任务已完成";
        try { var names = Names(); if (names.TryGetValue(threadId, out var title)) return title; using var db = new ReadOnlySqlite(Path.Combine(home, "state_5.sqlite")); return db.Query("SELECT substr(title,1,100) FROM threads WHERE id=?", threadId).FirstOrDefault()?[0] ?? "任务已完成"; }
        catch (IOException) { return "任务已完成"; }
    }
    public List<Excerpt> Read(string threadId)
    {
        if (!CompletionReader.IsUuid(threadId)) throw new InvalidDataException("聊天标识无效。");
        Paths.Regular(home);
        string?[] row;
        using (var db = new ReadOnlySqlite(Path.Combine(home, "state_5.sqlite")))
        {
            var columns = db.Query("PRAGMA table_info(threads)").Select(r => r[1]).ToHashSet();
            string first = columns.Contains("first_user_message") ? "substr(first_user_message,1,2000)" : "NULL";
            row = db.Query($"SELECT rollout_path, archived, {first} FROM threads WHERE id=?", threadId).SingleOrDefault() ?? throw new IOException("聊天不在当前 API 环境中。");
        }
        if (row[1] != "0") throw new InvalidDataException("已归档聊天不能生成标题。");
        string path = row[0] ?? "";
        if (path.StartsWith(@"\\?\") && path.Length > 7 && char.IsAsciiLetter(path[4]) && path[5] == ':' && path[6] == '\\') path = path[4..];
        path = Paths.Full(path); Paths.Regular(path);
        if (!Paths.Inside(path, Path.Combine(home, "sessions")) || Path.GetExtension(path) != ".jsonl") throw new InvalidDataException("聊天文件不属于 API 会话目录。");
        byte[] tail;
        using (var file = CompletionReader.Open(path))
        {
            string identity = FileIdentity.Of(file);
            byte[] first = CompletionReader.ReadLine(file, 65536) ?? throw new IOException("聊天元数据未写入完成。");
            using var meta = JsonDocument.Parse(Utf8.GetString(first));
            if (!CompletionReader.Metadata(meta.RootElement, out var id) || id != threadId) throw new InvalidDataException("聊天文件身份不匹配。");
            long firstEnd = file.Position, start = Math.Max(firstEnd, file.Length - 2 * 1024 * 1024);
            file.Position = start; tail = new byte[(int)(file.Length - start)]; file.ReadExactly(tail);
            if (start > firstEnd) { int end = tail.AsSpan().IndexOf((byte)10); tail = end < 0 ? [] : tail[(end + 1)..]; }
            int last = tail.AsSpan().LastIndexOf((byte)10); tail = last < 0 ? [] : tail[..last];
            Paths.Regular(path); using var probe = CompletionReader.Open(path);
            if (identity != FileIdentity.Of(probe)) throw new IOException("读取期间聊天文件发生替换。");
        }
        var messages = new List<Excerpt>();
        // Decode each bounded record independently; oversized tool/image records never enter context.
        int cursor = tail.Length, rounds = 0, remaining = 8000;
        while (cursor > 0 && messages.Count < 10 && remaining > 0)
        {
            int previous = tail.AsSpan(0, cursor).LastIndexOf((byte)10); int start = previous + 1, length = cursor - start; cursor = previous;
            if (length == 0 || length > 65536) continue;
            Excerpt? item;
            try { using var doc = JsonDocument.Parse(Utf8.GetString(tail, start, length)); item = Message(doc.RootElement); }
            catch (Exception e) when (e is JsonException or DecoderFallbackException) { continue; }
            if (item == null) continue;
            if (item.Role == "user" && ++rounds > 5) break;
            string text = item.Text[..Math.Min(item.Text.Length, remaining)]; remaining -= text.Length; messages.Add(item with { Text = text });
        }
        messages.Reverse();
        if (messages.All(x => x.Role != "user"))
        {
            string first = Clean(row[2] ?? "");
            if (first.Length == 0) throw new IOException("没有可用于标题的用户文本。");
            remaining = 8000 - first.Length;
            var latest = new List<Excerpt>();
            foreach (var item in messages.AsEnumerable().Reverse()) { if (remaining <= 0) break; string text = item.Text[..Math.Min(remaining, item.Text.Length)]; remaining -= text.Length; latest.Add(item with { Text = text }); }
            latest.Reverse(); messages = [new("user", first), .. latest];
        }
        return messages;
    }
    public static string Clean(string text)
    {
        if (Synthetic.Any(p => text.TrimStart().StartsWith(p, StringComparison.Ordinal))) return "";
        return new string(text.Where(c => !char.IsControl(c) || c is '\n' or '\t').Take(2000).ToArray()).Trim();
    }
    public static Excerpt? Message(JsonElement record)
    {
        if (record.Text("type") != "response_item" || !record.TryGetProperty("payload", out var p) || p.Text("type") != "message") return null;
        string role = p.Text("role");
        if (role is not ("user" or "assistant") || p.Text("channel") is not ("" or "final") || role == "assistant" && p.Text("phase") is not ("" or "final" or "final_answer")) return null;
        if (!p.TryGetProperty("content", out var content) || content.ValueKind != JsonValueKind.Array) return null;
        var chunks = new List<string>();
        foreach (var block in content.EnumerateArray())
        {
            if (block.Text("type") is not ("input_text" or "output_text" or "text")) continue;
            string raw = block.Text("text"); if (Synthetic.Any(s => raw.TrimStart().StartsWith(s))) return null;
            string text = Clean(raw); if (text.Length > 0) chunks.Add(text);
        }
        string all = string.Join('\n', chunks); if (all.Length > 2000) all = all[..2000];
        return all.Length > 0 ? new(role, all) : null;
    }
}
