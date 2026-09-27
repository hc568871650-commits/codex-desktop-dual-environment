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
    private static NamedPipeServerStream waitingPipe;

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
        return new { ok = true, instanceId = instanceId, pending = PendingById.Values.Select(p => new {
            connectionId = p.ConnectionId, requestToken = p.RequestToken, requestId = p.Id, threadId = p.ThreadId,
            turnId = p.TurnId, itemId = p.ItemId, isBlocking = p.IsBlocking, questions = p.Questions
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
            if (running) { running = false; ClearWhere(p => true); }
            return true;
        }
        return !running;
    }
    private static void FromChild(string line)
    {
        lock (Gate)
        {
            parentOutput.WriteLine(line);
            if (Disabled()) return;
            try
            {
                var msg = Map(Json.DeserializeObject(line));
                string method = String(Get(msg, "method"));
                var param = Map(Get(msg, "params"));
                if (method == "item/tool/requestUserInput")
                {
                    object id = Get(msg, "id"); string key = Key(id);
                    string thread = String(Get(param, "threadId")), turn = String(Get(param, "turnId"));
                    object[] questions = Array(Get(param, "questions"));
                    if (key != null && thread != null && turn != null && questions != null)
                    {
                        Pending prior;
                        if (PendingById.TryGetValue(key, out prior)) Resolved(prior);
                        AnsweredExternally.Remove(key);
                        var p = new Pending { Id = id, Key = key, ConnectionId = connectionId,
                            RequestToken = Guid.NewGuid().ToString("N"),
                            ThreadId = thread, TurnId = turn, ItemId = String(Get(param, "itemId")),
                            Questions = questions, IsBlocking = Get(param, "isBlocking") is bool && (bool)Get(param, "isBlocking") };
                        PendingById[key] = p;
                        Broadcast(new { @event = "pending", instanceId = instanceId, connectionId = p.ConnectionId,
                            requestToken = p.RequestToken,
                            requestId = p.Id, threadId = p.ThreadId, turnId = p.TurnId, itemId = p.ItemId,
                            isBlocking = p.IsBlocking, questions = p.Questions });
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
                    if (thread != null && turn != null) ClearWhere(p => p.ThreadId == thread && p.TurnId == turn);
                }
            }
            catch (ArgumentException) { } catch (InvalidOperationException) { }
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
            childInput.WriteLine(Json.Serialize(new { id = p.Id, result = new { answers = answers } }));
            AnsweredExternally.Add(p.Key);
            Resolved(p);
            Emit(new { method = "serverRequest/resolved", @params = new { requestId = p.Id, threadId = p.ThreadId } });
            return new { ok = true };
        }
        catch (IOException) { return new { ok = false, error = "disconnected" }; }
        catch (ObjectDisposedException) { return new { ok = false, error = "disconnected" }; }
    }
    private static void HandlePipe(object state)
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
                        bool disabled = Disabled();
                        try
                        {
                            var command = Map(Json.DeserializeObject(line));
                            string name = String(Get(command, "command"));
                            if (name == "snapshot") response = Snapshot();
                            else if (name == "answer") response = Answer(command);
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
    private static void PipeLoop(string name)
    {
        while (running)
        {
            try
            {
                var security = new PipeSecurity();
                security.SetAccessRuleProtection(true, false);
                security.AddAccessRule(new PipeAccessRule(WindowsIdentity.GetCurrent().User,
                    PipeAccessRights.ReadWrite | PipeAccessRights.CreateNewInstance, AccessControlType.Allow));
                var pipe = new NamedPipeServerStream(name, PipeDirection.InOut, 254,
                    PipeTransmissionMode.Byte, PipeOptions.Asynchronous, 4096, 4096, security);
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
        try
        {
            string directory = AppDomain.CurrentDomain.BaseDirectory;
            var config = Map(Json.DeserializeObject(File.ReadAllText(Path.Combine(directory, "bridge.config.json"), Encoding.UTF8)));
            string real = String(Get(config, "realCli")), home = String(Get(config, "apiHome"));
            instanceId = String(Get(config, "instanceId")); string pipeName = String(Get(config, "pipeName"));
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
            if (bridge)
            {
                bool created;
                lease = new Mutex(true, MutexName(pipeName), out created);
                ownsLease = created;
                if (!created)
                {
                    try { ownsLease = lease.WaitOne(0); }
                    catch (AbandonedMutexException) { ownsLease = true; }
                }
                if (!ownsLease) { bridge = false; Console.Error.WriteLine("Bridge pipe already owned; using native passthrough."); }
            }
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
                connectionId = Guid.NewGuid().ToString("N");
                running = true;
                var listener = new Thread(() => PipeLoop(pipeName)) { IsBackground = true }; listener.Start();
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
                                    if (String(Get(msg, "method")) == "turn/interrupt")
                                    {
                                        var param = Map(Get(msg, "params"));
                                        string thread = String(Get(param, "threadId"));
                                        string turn = String(Get(param, "turnId"));
                                        if (thread != null && turn != null)
                                            ClearWhere(p => p.ThreadId == thread && p.TurnId == turn);
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
            if (child != null && !child.HasExited) { child.Kill(); child.WaitForExit(); }
            lock (Gate) ClearWhere(p => true);
            if (ownsLease) lease.ReleaseMutex();
            if (lease != null) lease.Dispose();
        }
    }
}
