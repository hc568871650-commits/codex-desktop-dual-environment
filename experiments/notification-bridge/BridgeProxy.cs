using System;
using System.Collections;
using System.Collections.Generic;
using System.Diagnostics;
using System.Globalization;
using System.IO;
using System.IO.Pipes;
using System.Linq;
using System.Security.AccessControl;
using System.Security.Cryptography;
using System.Security.Principal;
using System.Text;
using System.Threading;
using System.Web.Script.Serialization;

internal sealed class Pending
{
    internal object Id;
    internal string Key, ConnectionId, RequestToken, ThreadId, TurnId, ItemId;
    internal bool IsBlocking;
    internal object[] Questions;
    internal bool Async, Hidden;
    internal string OriginalLine, Identity, Submission;
}

internal sealed class Submission
{
    internal Pending Pending;
    internal bool Done, Success;
    internal string Error;
}

internal sealed class Subscriber
{
    internal StreamWriter Writer;
    internal readonly object Gate = new object();
}

internal static class BridgeProxy
{
    private static readonly object Gate = new object();
    private static readonly JavaScriptSerializer Json = new JavaScriptSerializer { MaxJsonLength = 16 * 1024 * 1024, RecursionLimit = 100 };
    private static readonly Dictionary<string, Pending> PendingById = new Dictionary<string, Pending>();
    private static readonly HashSet<string> AnsweredExternally = new HashSet<string>();
    private static readonly List<Subscriber> Subscribers = new List<Subscriber>();
    private static StreamWriter childInput, parentOutput;
    private static string instanceId, connectionId;
    private static string disablePath;
    private static volatile bool running;
    private static bool takeoverQuestions;
    private static readonly Stopwatch Clock = Stopwatch.StartNew();
    private static long readyUntil;
    private static readonly Dictionary<string, Pending> Held = new Dictionary<string, Pending>();
    private static readonly HashSet<string> Released = new HashSet<string>();
    private static readonly HashSet<string> CompletedTurns = new HashSet<string>();
    private static readonly Dictionary<string, Submission> Submissions = new Dictionary<string, Submission>();
    private static readonly Dictionary<string, string> ParentReads = new Dictionary<string, string>();
    private static NamedPipeServerStream waitingPipe;
    private static string registrationPath, basePipeName;

    private static void AssertPlainPath(string path)
    {
        for (string cursor = Path.GetFullPath(path); !string.IsNullOrEmpty(cursor); cursor = Path.GetDirectoryName(cursor))
            if ((Directory.Exists(cursor) || File.Exists(cursor)) && (File.GetAttributes(cursor) & FileAttributes.ReparsePoint) != 0)
                throw new InvalidOperationException("Bridge registration path contains a reparse point.");
    }
    private static bool LiveRegistration(string path)
    {
        try {
            AssertPlainPath(path);
            var record = Map(Json.DeserializeObject(File.ReadAllText(path, Encoding.UTF8)));
            if (Convert.ToInt32(Get(record, "schema"), CultureInfo.InvariantCulture) != 1 || String(Get(record, "instanceId")) != instanceId) return false;
            int pid = Convert.ToInt32(Get(record, "processId"), CultureInfo.InvariantCulture);
            long ticks = Convert.ToInt64(Get(record, "startedUtcTicks"), CultureInfo.InvariantCulture);
            string connection = String(Get(record, "connectionId")); Guid guid;
            if (pid <= 0 || !Guid.TryParseExact(connection, "N", out guid) ||
                String(Get(record, "pipeName")) != basePipeName + "-" + pid + "-" + connection ||
                Path.GetFileName(path) != pid + "-" + connection + ".json") return false;
            using (var process = Process.GetProcessById(pid)) return !process.HasExited && process.StartTime.ToUniversalTime().Ticks == ticks &&
                EqualPath(process.MainModule.FileName, Process.GetCurrentProcess().MainModule.FileName);
        } catch (ArgumentException) { } catch (InvalidOperationException) { } catch (IOException) { }
        catch (System.ComponentModel.Win32Exception) { } catch (FormatException) { } catch (OverflowException) { }
        return false;
    }
    private static void RegisterConnection(string directory, string pipe)
    {
        string registry = Path.Combine(directory, "connections"); AssertPlainPath(registry); Directory.CreateDirectory(registry);
        string lockPath = Path.Combine(registry, ".registration.lock"); FileStream registryLock = null;
        long deadline = Clock.ElapsedMilliseconds + 5000;
        while (registryLock == null) {
            AssertPlainPath(lockPath);
            try { registryLock = new FileStream(lockPath, FileMode.OpenOrCreate, FileAccess.ReadWrite, FileShare.None); }
            catch (IOException) { if (Clock.ElapsedMilliseconds >= deadline) throw; Thread.Sleep(25); }
        }
        using (registryLock) {
            AssertPlainPath(registry);
            string[] records = Directory.EnumerateFiles(registry, "*.json").Take(257).ToArray();
            if (records.Length > 256 || records.Count(LiveRegistration) >= 32) throw new InvalidOperationException("Bridge connection registry limit reached.");
            using (var process = Process.GetCurrentProcess()) {
                string record = Path.Combine(registry, process.Id + "-" + connectionId + ".json");
                string temporary = record + ".tmp-" + Guid.NewGuid().ToString("N");
                try {
                    File.WriteAllText(temporary, Json.Serialize(new { schema = 1, pipeName = pipe, instanceId = instanceId,
                        connectionId = connectionId, processId = process.Id, startedUtcTicks = process.StartTime.ToUniversalTime().Ticks }), new UTF8Encoding(false));
                    File.Move(temporary, record); registrationPath = record;
                } finally { if (File.Exists(temporary)) File.Delete(temporary); }
            }
        }
    }
    private static void RemoveRegistration()
    {
        if (registrationPath == null) return;
        try { AssertPlainPath(registrationPath); File.Delete(registrationPath); }
        catch (IOException) { } catch (UnauthorizedAccessException) { } catch (InvalidOperationException) { }
        registrationPath = null;
    }

    private static IDictionary<string, object> Map(object value) { return value as IDictionary<string, object>; }
    private static object Get(IDictionary<string, object> map, string key) { object value; return map != null && map.TryGetValue(key, out value) ? value : null; }
    private static string String(object value) { return value as string; }
    private static object[] Array(object value) { return value as object[]; }
    private static string Key(object id)
    {
        if (id is string) return "s:" + id;
        if (id is int || id is long || id is decimal) return "n:" + Convert.ToString(id, CultureInfo.InvariantCulture);
        return null;
    }
    private static bool EqualPath(string left, string right)
    {
        return string.Equals(Path.GetFullPath(left).TrimEnd(Path.DirectorySeparatorChar),
            Path.GetFullPath(right).TrimEnd(Path.DirectorySeparatorChar), StringComparison.OrdinalIgnoreCase);
    }
    private static bool SameBinary(string left, string right)
    {
        if (EqualPath(left, right)) return true;
        using (var hash = SHA256.Create())
        using (var first = File.OpenRead(left))
        using (var second = File.OpenRead(right))
            return hash.ComputeHash(first).SequenceEqual(hash.ComputeHash(second));
    }
    private static bool IsStdioAppServer(string[] args)
    {
        int command = -1;
        for (int i = 0; i < args.Length; i++)
        {
            string arg = args[i];
            if (arg == "--") { if (i + 1 < args.Length) command = i + 1; break; }
            if (arg == "-c" || arg == "--config" || arg == "--enable" || arg == "--disable" ||
                arg == "-p" || arg == "--profile" || arg == "-s" || arg == "--sandbox" ||
                arg == "-a" || arg == "--ask-for-approval" || arg == "-C" || arg == "--cd" ||
                arg == "--add-dir" || arg == "-m" || arg == "--model" || arg == "--remote" ||
                arg == "--remote-auth-token-env" || arg == "--local-provider") { i++; continue; }
            if (arg.StartsWith("-", StringComparison.Ordinal)) continue;
            command = i; break;
        }
        if (command < 0 || args[command] != "app-server") return false;
        for (int i = command + 1; i < args.Length; i++)
        {
            if (args[i] == "--listen")
            {
                if (++i >= args.Length || !args[i].Equals("stdio://", StringComparison.OrdinalIgnoreCase)) return false;
            }
            else if (args[i].StartsWith("--listen=", StringComparison.Ordinal) &&
                !args[i].Substring(9).Equals("stdio://", StringComparison.OrdinalIgnoreCase)) return false;
            else if (args[i] == "-c" || args[i] == "--config" || args[i] == "--enable" || args[i] == "--disable" ||
                args[i].StartsWith("--ws-", StringComparison.Ordinal)) i++;
            else if (args[i] == "-h" || args[i] == "--help" || args[i] == "-V" || args[i] == "--version") return false;
            else if (!args[i].StartsWith("-", StringComparison.Ordinal)) return false;
        }
        return true;
    }
    private static string Quote(string argument)
    {
        if (argument.Length > 0 && !argument.Any(c => char.IsWhiteSpace(c) || c == '"')) return argument;
        var b = new StringBuilder("\""); int slashes = 0;
        foreach (char c in argument)
        {
            if (c == '\\') { slashes++; continue; }
            if (c == '"') { b.Append('\\', slashes * 2 + 1).Append('"'); slashes = 0; continue; }
            b.Append('\\', slashes).Append(c); slashes = 0;
        }
        b.Append('\\', slashes * 2).Append('"'); return b.ToString();
    }
    private static string MutexName(string pipe)
    {
        string scope = WindowsIdentity.GetCurrent().User.Value + ":" + pipe;
        using (var hash = SHA256.Create())
            return "Local\\CodexBridge-" + BitConverter.ToString(hash.ComputeHash(Encoding.UTF8.GetBytes(scope))).Replace("-", "");
    }
    private static StreamWriter Writer(Stream stream) { return new StreamWriter(stream, new UTF8Encoding(false)) { AutoFlush = true }; }
    private static void CopyBytes(Stream source, Stream destination)
    {
        byte[] buffer = new byte[8192]; int count;
        while ((count = source.Read(buffer, 0, buffer.Length)) != 0)
        {
            destination.Write(buffer, 0, count);
            destination.Flush();
        }
    }
    private static void Emit(object message)
    {
        parentOutput.WriteLine(Json.Serialize(message));
    }
    private static object Snapshot()
    {
        return new { ok = true, instanceId = instanceId, takeoverEnabled = takeoverQuestions, takeoverActive = ActiveLease(), pending = PendingById.Values.Select(p => new {
            connectionId = p.ConnectionId, requestToken = p.RequestToken, requestId = p.Id, threadId = p.ThreadId,
            turnId = p.TurnId, itemId = p.ItemId, isBlocking = p.IsBlocking, questions = p.Questions,
            kind = p.Async ? "async" : "traditional", delivery = p.Hidden ? "exclusive" : "mirror", outcomeUnknown = p.Submission != null
        }).ToArray() };
    }
    private static void Broadcast(object item)
    {
        string line = Json.Serialize(item);
        foreach (Subscriber subscriber in Subscribers.ToArray())
        {
            ThreadPool.QueueUserWorkItem(_ => {
                try { lock (subscriber.Gate) subscriber.Writer.WriteLine(line); }
                catch (IOException) { lock (Gate) Subscribers.Remove(subscriber); }
                catch (ObjectDisposedException) { lock (Gate) Subscribers.Remove(subscriber); }
            });
        }
    }
    private static void Resolved(Pending p)
    {
        PendingById.Remove(p.Key);
        Broadcast(new { @event = "resolved", instanceId = instanceId, connectionId = p.ConnectionId,
            requestToken = p.RequestToken, requestId = p.Id, threadId = p.ThreadId, turnId = p.TurnId });
    }
    private static void ClearWhere(Func<Pending, bool> predicate)
    {
        foreach (Pending p in PendingById.Values.Where(predicate).ToArray()) Resolved(p);
    }
    private static bool Disabled()
    {
        if (disablePath != null && File.Exists(disablePath))
        {
            if (running) { ReleaseAll(); running = false; ClearWhere(p => p.Submission == null); }
            return true;
        }
        return !running;
    }
    private static bool ActiveLease() { return running && takeoverQuestions && Clock.ElapsedMilliseconds < readyUntil; }
    private static string Identity(string thread, string turn, string item) { return Json.Serialize(new [] { thread, turn, item }); }
    private static string TurnKey(string thread, string turn) { return Json.Serialize(new [] { thread, turn }); }
    private static void ReleaseOne(Pending p)
    {
        if (p.Hidden) {
            parentOutput.WriteLine(p.OriginalLine);
            p.Hidden = false; Held.Remove(p.Identity); Released.Add(p.Identity);
        }
        Resolved(p);
        Monitor.PulseAll(Gate);
    }
    private static void ReleaseAll()
    {
        // An in-flight/unknown steer may already have reached the runtime. Replaying its
        // native question could permit a second answer; wait for a definitive response.
        foreach (Pending p in PendingById.Values.Where(p => p.Hidden && p.Submission == null).ToArray()) ReleaseOne(p);
    }
    private static void Watchdog()
    {
        if (Disabled()) return;
        if (takeoverQuestions && !ActiveLease()) ReleaseAll();
    }
    private static object[] AsyncQuestions(object[] questions)
    {
        if (questions == null || questions.Length == 0 || questions.Length > 100) return null;
        var result = new List<object>();
        for (int i = 0; i < questions.Length; i++) {
            var question = Map(questions[i]); string title = String(Get(question, "title"));
            object raw = Get(question, "options"); object[] options = Array(raw);
            if (question == null || string.IsNullOrWhiteSpace(title) || question.Keys.Any(k => k != "title" && k != "options") ||
                (raw != null && options == null) || (options != null && options.Any(o => !(o is string) || string.IsNullOrWhiteSpace((string)o)))) return null;
            result.Add(new Dictionary<string, object> { { "id", i.ToString(CultureInfo.InvariantCulture) }, { "header", "提问" }, { "question", title },
                { "options", (options ?? new object[0]).Select(o => (object)new Dictionary<string, object> { { "label", (string)o }, { "description", "" } }).ToArray() },
                { "isOther", true }, { "isSecret", false } });
        }
        return result.ToArray();
    }
    private static bool TraditionalQuestions(IDictionary<string, object> param, object[] questions)
    {
        if (questions == null || questions.Length == 0 || questions.Length > 100) return false;
        if (param.ContainsKey("isBlocking") && !(Get(param, "isBlocking") is bool)) return false;
        var ids = new HashSet<string>(StringComparer.Ordinal);
        foreach (object value in questions) {
            var question = Map(value); if (question == null) return false;
            string id = String(Get(question, "id")), text = String(Get(question, "question"));
            if (string.IsNullOrWhiteSpace(id) || !ids.Add(id) || string.IsNullOrWhiteSpace(text) ||
                question.Keys.Any(k => k != "id" && k != "header" && k != "question" && k != "options" && k != "isOther" && k != "isSecret")) return false;
            if (question.ContainsKey("header") && !(Get(question, "header") is string)) return false;
            foreach (string flag in new [] { "isOther", "isSecret" }) if (question.ContainsKey(flag) && !(Get(question, flag) is bool)) return false;
            object raw = Get(question, "options"); if (raw == null) continue;
            object[] options = Array(raw); if (options == null) return false;
            foreach (object optionValue in options) {
                var option = Map(optionValue); if (option == null || string.IsNullOrWhiteSpace(String(Get(option, "label"))) ||
                    option.Keys.Any(k => k != "label" && k != "description") ||
                    (option.ContainsKey("description") && !(Get(option, "description") is string))) return false;
            }
        }
        return true;
    }
    private static void AddPending(Pending p)
    {
        PendingById[p.Key] = p;
        if (p.Hidden) Held[p.Identity] = p;
        Broadcast(new { @event = "pending", instanceId = instanceId, connectionId = p.ConnectionId, requestToken = p.RequestToken,
            requestId = p.Id, threadId = p.ThreadId, turnId = p.TurnId, itemId = p.ItemId,
            isBlocking = p.IsBlocking, questions = p.Questions, kind = p.Async ? "async" : "traditional", delivery = p.Hidden ? "exclusive" : "mirror" });
    }
    // Only known projection paths and exact thread/turn/item identities are scrubbed.
    private static bool Scrub(object value, string thread, string turn)
    {
        bool changed = false;
        var map = Map(value);
        if (map != null) {
            string explicitThread = String(Get(map, "threadId")); if (explicitThread != null) thread = explicitThread;
            string explicitTurn = String(Get(map, "turnId")); if (explicitTurn != null) turn = explicitTurn;
            if (Get(map, "items") is object[] && String(Get(map, "id")) != null) turn = String(Get(map, "id"));
            string item = String(Get(map, "id"));
            if (String(Get(map, "type")) == "agentMessage" && thread != null && turn != null && item != null && Held.ContainsKey(Identity(thread, turn, item))) {
                if (Get(map, "questions") != null) { map["questions"] = null; changed = true; }
            }
            foreach (string key in new [] { "thread", "turn", "turns", "items", "item", "history", "turnHistory", "entitiesByKey", "records", "entries", "data", "result" }) {
                object child = Get(map, key); if (child == null) continue;
                if (key == "thread") { var childMap = Map(child); string id = String(Get(childMap, "id")); changed |= Scrub(child, id ?? thread, turn); }
                else if (key == "turn") { var childMap = Map(child); changed |= Scrub(child, thread, String(Get(childMap, "id")) ?? turn); }
                else if (key == "entitiesByKey") { var entities = Map(child); if (entities != null) foreach (object entity in entities.Values) changed |= Scrub(entity, thread, turn); }
                else changed |= Scrub(child, thread, turn);
            }
        } else { object[] array = Array(value); if (array != null) foreach (object child in array) changed |= Scrub(child, thread, turn); }
        return changed;
    }
    private static void FromChild(string line)
    {
        lock (Gate)
        {
            Watchdog();
            try
            {
                var msg = Map(Json.DeserializeObject(line));
                string method = String(Get(msg, "method"));
                var param = Map(Get(msg, "params"));
                string responseKey = Key(Get(msg, "id")); Submission submission;
                if (method == null && responseKey != null && Submissions.TryGetValue(responseKey, out submission)) {
                    submission.Done = true;
                    submission.Success = Get(msg, "error") == null && String(Get(Map(Get(msg, "result")), "turnId")) == submission.Pending.TurnId;
                    bool rejected = Get(msg, "error") != null;
                    submission.Error = submission.Success ? null : rejected ? "steer-rejected" : "outcome-unknown";
                    // A malformed success envelope is not proof of rejection. Retrying
                    // could duplicate an already accepted steer; retain the ambiguity.
                    if (!submission.Success && !rejected) { Monitor.PulseAll(Gate); return; }
                    Pending p = submission.Pending; p.Submission = null;
                    if (submission.Success && PendingById.ContainsKey(p.Key)) { Resolved(p); }
                    else if (!submission.Success && PendingById.ContainsKey(p.Key) && !ActiveLease()) ReleaseOne(p);
                    Monitor.PulseAll(Gate); return;
                }
                if (!running) { parentOutput.WriteLine(line); return; }
                if (method == "item/tool/requestUserInput")
                {
                    object id = Get(msg, "id"); string key = Key(id);
                    string thread = String(Get(param, "threadId")), turn = String(Get(param, "turnId"));
                    object[] questions = Array(Get(param, "questions"));
                    if (key != null && !string.IsNullOrWhiteSpace(thread) && !string.IsNullOrWhiteSpace(turn) && TraditionalQuestions(param, questions))
                    {
                        string item = String(Get(param, "itemId")); string identity = Identity(thread, turn, item ?? key);
                        if (takeoverQuestions && (Released.Contains(identity) || CompletedTurns.Contains(TurnKey(thread, turn)))) { parentOutput.WriteLine(line); return; }
                        if (takeoverQuestions && !ActiveLease()) { Released.Add(identity); parentOutput.WriteLine(line); return; }
                        Pending heldRequest;
                        if (ActiveLease() && Held.TryGetValue(identity, out heldRequest) && !heldRequest.Async && heldRequest.Key == key) return;
                        Pending prior;
                        if (PendingById.TryGetValue(key, out prior)) Resolved(prior);
                        AnsweredExternally.Remove(key);
                        var p = new Pending { Id = id, Key = key, ConnectionId = connectionId,
                            RequestToken = Guid.NewGuid().ToString("N"),
                            ThreadId = thread, TurnId = turn, ItemId = item,
                            Hidden = ActiveLease(), OriginalLine = line, Identity = identity,
                            Questions = questions, IsBlocking = Get(param, "isBlocking") is bool && (bool)Get(param, "isBlocking") };
                        AddPending(p);
                        if (p.Hidden) return;
                    }
                    else if (takeoverQuestions && key != null && !string.IsNullOrWhiteSpace(thread) && !string.IsNullOrWhiteSpace(turn)) {
                        Released.Add(Identity(thread, turn, String(Get(param, "itemId")) ?? key));
                    }
                }
                else if ((method == "item/started" || method == "item/completed") && takeoverQuestions) {
                    string thread = String(Get(param, "threadId")), turn = String(Get(param, "turnId"));
                    var item = Map(Get(param, "item")); string itemId = String(Get(item, "id"));
                    if (thread != null && turn != null && itemId != null && String(Get(item, "type")) == "agentMessage") {
                        string identity = Identity(thread, turn, itemId); Pending p;
                        if (!ActiveLease() || Released.Contains(identity)) {
                            if (Get(item, "questions") != null) Released.Add(identity);
                            parentOutput.WriteLine(line); return;
                        }
                        object[] questions = AsyncQuestions(Array(Get(item, "questions")));
                        if (questions == null && Get(item, "questions") != null && !Held.ContainsKey(identity)) {
                            Released.Add(identity); parentOutput.WriteLine(line); return;
                        }
                        if (!Held.TryGetValue(identity, out p) && questions != null && !Released.Contains(identity) && !CompletedTurns.Contains(TurnKey(thread, turn))) {
                            string id = "async:" + identity;
                            p = new Pending { Id = id, Key = Key(id), Async = true, Hidden = true, OriginalLine = line, Identity = identity,
                                ConnectionId = connectionId, RequestToken = Guid.NewGuid().ToString("N"), ThreadId = thread, TurnId = turn, ItemId = itemId, Questions = questions };
                            AddPending(p);
                        }
                        if (p != null && Scrub(param, thread, turn)) { Emit(msg); return; }
                    }
                }
                else if (method == "serverRequest/resolved")
                {
                    string key = Key(Get(param, "requestId"));
                    Pending p;
                    if (key != null && PendingById.TryGetValue(key, out p) && p.ThreadId == String(Get(param, "threadId"))) Resolved(p);
                }
                else if (method == "turn/completed" || method == "turn/interrupted")
                {
                    string thread = String(Get(param, "threadId"));
                    string turn = String(Get(param, "turnId")) ?? String(Get(Map(Get(param, "turn")), "id"));
                    if (thread != null && turn != null) { CompletedTurns.Add(TurnKey(thread, turn)); ClearWhere(p => p.ThreadId == thread && p.TurnId == turn); Monitor.PulseAll(Gate); }
                }
                string historyThread;
                if (method == null && responseKey != null && ParentReads.TryGetValue(responseKey, out historyThread)) {
                    ParentReads.Remove(responseKey);
                    if (ActiveLease() && Scrub(Get(msg, "result"), historyThread, null)) { Emit(msg); return; }
                }
            }
            catch (ArgumentException) { } catch (InvalidOperationException) { }
            parentOutput.WriteLine(line);
        }
    }
    private static bool ValidAnswers(Pending p, object value)
    {
        var answers = Map(value);
        if (answers == null || answers.Count != p.Questions.Length) return false;
        var ids = new HashSet<string>(StringComparer.Ordinal);
        foreach (object question in p.Questions)
        {
            string id = String(Get(Map(question), "id"));
            if (id == null || !ids.Add(id)) return false;
            var answer = Map(Get(answers, id));
            object[] strings = Array(Get(answer, "answers"));
            if (answer == null || answer.Count != 1 || strings == null || strings.Any(x => !(x is string))) return false;
            if (p.Async && (strings.Length == 0 || strings.Any(x => string.IsNullOrWhiteSpace((string)x)))) return false;
        }
        return true;
    }
    private static object Answer(IDictionary<string, object> command)
    {
        if (Disabled()) return new { ok = false, error = "disabled" };
        string key = Key(Get(command, "requestId")); Pending p;
        if (key == null || !PendingById.TryGetValue(key, out p) ||
            p.ConnectionId != String(Get(command, "connectionId")) ||
            p.RequestToken != String(Get(command, "requestToken")) ||
            p.ThreadId != String(Get(command, "threadId")) || p.TurnId != String(Get(command, "turnId")))
            return new { ok = false, error = "stale" };
        object answers = Get(command, "answers");
        if (!ValidAnswers(p, answers)) return new { ok = false, error = "invalid" };
        try
        {
            if (p.Async) {
                if (!ActiveLease() || !p.Hidden) return new { ok = false, error = "stale" };
                if (p.Submission != null) return new { ok = false, error = "outcome-unknown" };
                var answerMap = Map(answers); var replies = new List<object>();
                for (int i = 0; i < p.Questions.Length; i++) {
                    var q = Map(p.Questions[i]); string qid = String(Get(q, "id"));
                    object[] strings = Array(Get(Map(Get(answerMap, qid)), "answers"));
                    replies.Add(new { questionItemId = Json.Serialize(new object[] { "request_user_input_async", p.ItemId, i }),
                        question = String(Get(q, "question")), answer = string.Join("\n", strings.Cast<string>().ToArray()) });
                }
                string rpcId = "codex-bridge-steer:" + connectionId + ":" + Guid.NewGuid().ToString("N");
                var operation = new Submission { Pending = p }; string rpcKey = Key(rpcId); Submissions[rpcKey] = operation; p.Submission = rpcKey;
                string text = "<send_user_message_question_reply>\n" + Json.Serialize(replies) + "\n</send_user_message_question_reply>";
                childInput.WriteLine(Json.Serialize(new { id = rpcId, method = "turn/steer", @params = new { threadId = p.ThreadId, expectedTurnId = p.TurnId,
                    input = new [] { new { type = "text", text = text, text_elements = new object[0] } } } }));
                long until = Clock.ElapsedMilliseconds + 1200;
                while (!operation.Done && PendingById.ContainsKey(p.Key) && Clock.ElapsedMilliseconds < until) Monitor.Wait(Gate, (int)Math.Max(1, until - Clock.ElapsedMilliseconds));
                if (operation.Done) return new { ok = operation.Success, error = operation.Error };
                return new { ok = false, error = p.Hidden ? "outcome-unknown" : "stale" };
            }
            childInput.WriteLine(Json.Serialize(new { id = p.Id, result = new { answers = answers } }));
            AnsweredExternally.Add(p.Key);
            Resolved(p);
            if (!p.Hidden) Emit(new { method = "serverRequest/resolved", @params = new { requestId = p.Id, threadId = p.ThreadId } });
            return new { ok = true };
        }
        catch (IOException) { return new { ok = false, error = "disconnected" }; }
        catch (ObjectDisposedException) { return new { ok = false, error = "disconnected" }; }
    }
    private static object Release(IDictionary<string, object> command)
    {
        Pending p; string key = Key(Get(command, "requestId"));
        if (key == null || !PendingById.TryGetValue(key, out p) || p.ConnectionId != String(Get(command, "connectionId")) ||
            p.RequestToken != String(Get(command, "requestToken")) || p.ThreadId != String(Get(command, "threadId")) || p.TurnId != String(Get(command, "turnId")))
            return new { ok = false, error = "stale" };
        if (p.Submission != null) return new { ok = false, error = "outcome-unknown" };
        ReleaseOne(p); return new { ok = true };
    }
    private static void HandlePipe(object state)
    {
        // StreamWriter.Dispose flushes again, even after a failed response write.
        // A disconnected UI client must not tear down the app-server transport.
        try
        {
        using (var pipe = (NamedPipeServerStream)state)
        using (var reader = new StreamReader(pipe, Encoding.UTF8))
        using (var writer = Writer(pipe))
        {
            Subscriber subscriber = null;
            try
            {
                string line;
                while ((line = reader.ReadLine()) != null)
                {
                    object response;
                    string responseLine;
                    lock (Gate)
                    {
                        Watchdog(); bool disabled = !running;
                        try
                        {
                            var command = Map(Json.DeserializeObject(line));
                            string name = String(Get(command, "command"));
                            if (name == "snapshot") {
                                if (!disabled && takeoverQuestions && Get(command, "takeoverReady") is bool) {
                                    if ((bool)Get(command, "takeoverReady")) readyUntil = Clock.ElapsedMilliseconds + 5000;
                                    else { readyUntil = 0; ReleaseAll(); }
                                }
                                response = Snapshot();
                            }
                            else if (name == "answer") response = Answer(command);
                            else if (name == "release" && !disabled) response = Release(command);
                            else if (name == "subscribe" && !disabled)
                            {
                                if (subscriber == null) { subscriber = new Subscriber { Writer = writer }; Subscribers.Add(subscriber); }
                                response = Snapshot();
                            }
                            else response = new { ok = false, error = disabled ? "disabled" : "unknown-command" };
                        }
                        catch (ArgumentException) { response = new { ok = false, error = "invalid-json" }; }
                        catch (InvalidOperationException) { response = new { ok = false, error = "invalid-json" }; }
                        responseLine = Json.Serialize(response);
                    }
                    lock (subscriber == null ? (object)writer : subscriber.Gate) writer.WriteLine(responseLine);
                }
            }
            catch (IOException) { }
            catch (ObjectDisposedException) { }
            finally { lock (Gate) { if (subscriber != null) Subscribers.Remove(subscriber); } }
        }
        }
        catch (IOException) { }
        catch (ObjectDisposedException) { }
    }
    private static NamedPipeServerStream CreatePipe(string name)
    {
        var security = new PipeSecurity();
        security.SetAccessRuleProtection(true, false);
        security.AddAccessRule(new PipeAccessRule(WindowsIdentity.GetCurrent().User,
            PipeAccessRights.ReadWrite | PipeAccessRights.CreateNewInstance, AccessControlType.Allow));
        return new NamedPipeServerStream(name, PipeDirection.InOut, 254,
            PipeTransmissionMode.Byte, PipeOptions.Asynchronous, 4096, 4096, security);
    }
    private static void PipeLoop(string name, NamedPipeServerStream firstPipe)
    {
        while (running)
        {
            try
            {
                var pipe = firstPipe ?? CreatePipe(name); firstPipe = null;
                waitingPipe = pipe;
                pipe.WaitForConnection();
                waitingPipe = null;
                if (!running) { pipe.Dispose(); break; }
                ThreadPool.QueueUserWorkItem(HandlePipe, pipe);
            }
            catch (ObjectDisposedException) { break; }
            catch (IOException) { if (!running) break; }
        }
    }
    public static int Main(string[] args)
    {
        Process child = null;
        Mutex lease = null;
        bool ownsLease = false;
        NamedPipeServerStream initialPipe = null;
        try
        {
            string directory = AppDomain.CurrentDomain.BaseDirectory;
            var config = Map(Json.DeserializeObject(File.ReadAllText(Path.Combine(directory, "bridge.config.json"), Encoding.UTF8)));
            string real = String(Get(config, "realCli")), home = String(Get(config, "apiHome"));
            instanceId = String(Get(config, "instanceId")); string pipeName = String(Get(config, "pipeName"));
            basePipeName = pipeName;
            takeoverQuestions = Get(config, "takeoverQuestions") is bool && (bool)Get(config, "takeoverQuestions");
            bool multiConnection = Get(config, "multiConnection") is bool && (bool)Get(config, "multiConnection");
            if (string.IsNullOrEmpty(real) || !Path.IsPathRooted(real) || !File.Exists(real) ||
                SameBinary(real, Process.GetCurrentProcess().MainModule.FileName) ||
                string.IsNullOrEmpty(home) || !Path.IsPathRooted(home) || !Directory.Exists(home) ||
                string.IsNullOrEmpty(Environment.GetEnvironmentVariable("CODEX_HOME")) ||
                !EqualPath(home, Environment.GetEnvironmentVariable("CODEX_HOME")) ||
                string.IsNullOrEmpty(instanceId) || string.IsNullOrEmpty(pipeName) ||
                pipeName.IndexOfAny(new [] { '\\', '/', ':' }) >= 0)
                throw new InvalidOperationException("Invalid bridge configuration or CODEX_HOME.");
            bool bridge = !File.Exists(Path.Combine(directory, "DISABLED")) && IsStdioAppServer(args);
            disablePath = Path.Combine(directory, "DISABLED");
            if (bridge && !multiConnection)
            {
                bool created;
                lease = new Mutex(true, MutexName(pipeName), out created);
                ownsLease = created;
                if (!created)
                {
                    // Desktop can spawn a replacement before the previous transport
                    // finishes its three-second EOF shutdown. Wait for that owner,
                    // then keep the bounded native fallback for a genuinely live peer.
                    try { ownsLease = lease.WaitOne(5000); }
                    catch (AbandonedMutexException) { ownsLease = true; }
                }
                if (!ownsLease) { bridge = false; Console.Error.WriteLine("Bridge pipe already owned; using native passthrough."); }
            }
            if (bridge) {
                connectionId = Guid.NewGuid().ToString("N");
                if (multiConnection) {
                    pipeName += "-" + Process.GetCurrentProcess().Id + "-" + connectionId;
                    try {
                        initialPipe = CreatePipe(pipeName); waitingPipe = initialPipe;
                        RegisterConnection(directory, pipeName);
                    } catch (Exception ex) {
                        if (!(ex is IOException || ex is UnauthorizedAccessException || ex is InvalidOperationException || ex is ArgumentException)) throw;
                        if (initialPipe != null) initialPipe.Dispose(); initialPipe = null; waitingPipe = null;
                        RemoveRegistration(); bridge = false;
                        Console.Error.WriteLine("Bridge multi-connection registration unavailable; using native passthrough (" + ex.GetType().Name + ").");
                    }
                }
            }
            Console.Error.WriteLine(bridge ? "Bridge transport mode: " + (takeoverQuestions ? "question-takeover" : "question-mirror") + (multiConnection ? "; independent connection registered." : "; lease acquired.") : "Bridge transport mode: native passthrough.");
            var start = new ProcessStartInfo(real, string.Join(" ", args.Select(Quote).ToArray())) {
                UseShellExecute = false, CreateNoWindow = true, RedirectStandardInput = true,
                RedirectStandardOutput = true, RedirectStandardError = true,
                StandardOutputEncoding = new UTF8Encoding(false), StandardErrorEncoding = new UTF8Encoding(false)
            };
            start.EnvironmentVariables["CODEX_CLI_PATH"] = real;
            child = Process.Start(start);
            childInput = bridge ? Writer(child.StandardInput.BaseStream) : child.StandardInput;
            if (bridge) parentOutput = Writer(Console.OpenStandardOutput());
            if (bridge)
            {
                running = true;
                var listener = new Thread(() => PipeLoop(pipeName, initialPipe)) { IsBackground = true }; listener.Start();
            }
            var output = new Thread(() => {
                string line;
                try {
                    if (bridge) while ((line = child.StandardOutput.ReadLine()) != null) FromChild(line);
                    else CopyBytes(child.StandardOutput.BaseStream, Console.OpenStandardOutput());
                }
                catch (IOException) { }
                finally { if (bridge) lock (Gate) { running = false; ClearWhere(p => true); } }
            }) { IsBackground = true }; output.Start();
            var error = new Thread(() => {
                try { CopyBytes(child.StandardError.BaseStream, Console.OpenStandardError()); }
                catch (IOException) { }
            }) { IsBackground = true }; error.Start();
            var parentEof = new ManualResetEvent(false);
            var inputThread = new Thread(() => {
                try {
                    if (!bridge) CopyBytes(Console.OpenStandardInput(), child.StandardInput.BaseStream);
                    else
                    {
                        string input;
                        var parentInput = new StreamReader(Console.OpenStandardInput(), new UTF8Encoding(false));
                        while ((input = parentInput.ReadLine()) != null)
                        {
                            lock (Gate)
                            {
                                Disabled();
                                try
                                {
                                    var msg = Map(Json.DeserializeObject(input));
                                    string requestMethod = String(Get(msg, "method"));
                                    if (takeoverQuestions && (requestMethod == "thread/read" || requestMethod == "thread/resume" || requestMethod == "thread/turns/list" || requestMethod == "thread/timeline/list")) {
                                        string requestKey = Key(Get(msg, "id")), requestThread = String(Get(Map(Get(msg, "params")), "threadId"));
                                        if (requestKey != null && requestThread != null) ParentReads[requestKey] = requestThread;
                                    }
                                    if (String(Get(msg, "method")) == "turn/interrupt")
                                    {
                                        var param = Map(Get(msg, "params"));
                                        string thread = String(Get(param, "threadId"));
                                        string turn = String(Get(param, "turnId"));
                                        if (thread != null && turn != null)
                                            { CompletedTurns.Add(TurnKey(thread, turn)); ClearWhere(p => p.ThreadId == thread && p.TurnId == turn); Monitor.PulseAll(Gate); }
                                    }
                                    if (Get(msg, "method") == null && Get(msg, "id") != null)
                                    {
                                        Pending p; string key = Key(Get(msg, "id"));
                                        if (key != null && AnsweredExternally.Contains(key)) continue;
                                        if (key != null && PendingById.TryGetValue(key, out p))
                                        {
                                            Resolved(p);
                                            childInput.WriteLine(input);
                                            continue;
                                        }
                                    }
                                }
                                catch (ArgumentException) { } catch (InvalidOperationException) { }
                                childInput.WriteLine(input);
                            }
                        }
                    }
                }
                catch (IOException) { }
                catch (ObjectDisposedException) { }
                finally { try { childInput.Close(); } catch (IOException) { } parentEof.Set(); }
            }) { IsBackground = true }; inputThread.Start();
            DateTime? eofAt = null;
            while (!child.WaitForExit(100))
            {
                if (bridge) lock (Gate) Watchdog();
                if (parentEof.WaitOne(0))
                {
                    if (!eofAt.HasValue) eofAt = DateTime.UtcNow;
                    if ((DateTime.UtcNow - eofAt.Value).TotalSeconds >= 3) { child.Kill(); child.WaitForExit(); break; }
                }
            }
            output.Join(3000); error.Join(3000);
            return child.ExitCode;
        }
        catch (Exception ex)
        {
            Console.Error.WriteLine("Bridge startup/transport failed: " + ex.GetType().Name + ": " + ex.Message);
            return 1;
        }
        finally
        {
            running = false;
            if (waitingPipe != null) waitingPipe.Dispose();
            RemoveRegistration();
            if (child != null && !child.HasExited) { child.Kill(); child.WaitForExit(); }
            lock (Gate) ClearWhere(p => true);
            if (ownsLease) lease.ReleaseMutex();
            if (lease != null) lease.Dispose();
        }
    }
}
