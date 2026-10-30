using System.ComponentModel;
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Text;
using System.Text.Json.Serialization;

namespace CodexDual.Core;

public sealed record ProcessIdentity(int Id, long Started, string Path, [property: JsonIgnore] string Command);
public sealed record InstanceStatus(string InstanceId, string State, string Reason, ProcessIdentity? Process);
public sealed record InstanceRecord(string InstanceId, string Home, string Profile, string LaunchMode, int Pid, string Started, string Executable);
public static class InstanceLease
{
    public static T Run<T>(InstanceConfig i, Func<T> operation)
    {
        string hash = Paths.Hash((i.Home + "|" + i.Profile).ToLowerInvariant()).ToUpperInvariant();
        using var mutex = new Mutex(false, "Local\\CodexDual.Instance." + hash);
        bool held; try { held = mutex.WaitOne(0); } catch (AbandonedMutexException) { held = true; }
        if (!held) throw new InvalidOperationException("该环境正在处理另一个操作，请稍后。");
        try { return operation(); } finally { mutex.ReleaseMutex(); }
    }
}

public static class PackageLocator
{
    public const string Family = "OpenAI.Codex_2p2nqsd0c76g0";
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode)] private static extern int GetPackagesByPackageFamily(string family, ref uint count, IntPtr names, ref uint length, IntPtr buffer);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode)] private static extern int GetPackagePathByFullName(string name, ref uint length, StringBuilder? path);
    public static string FindDesktop(string explicitPath = "")
    {
        if (!string.IsNullOrWhiteSpace(explicitPath))
        {
            if (Directory.Exists(explicitPath))
            {
                foreach (var rel in new[] { "app/ChatGPT.exe", "app/Codex.exe", "ChatGPT.exe", "Codex.exe" })
                { var candidate = Path.GetFullPath(Path.Combine(explicitPath, rel)); if (File.Exists(candidate) && Native.IsGuiImage(candidate)) return candidate; }
            }
            if (File.Exists(explicitPath) && Native.IsGuiImage(explicitPath)) return Path.GetFullPath(explicitPath);
            throw new IOException("指定的 Codex 桌面程序不存在或不是 GUI 程序。");
        }
        uint count = 0, length = 0;
        int rc = GetPackagesByPackageFamily(Family, ref count, IntPtr.Zero, ref length, IntPtr.Zero);
        if (count == 0 || rc is not (0 or 122)) throw new IOException("未找到当前用户安装的 Codex Desktop。");
        var names = Marshal.AllocHGlobal(checked((int)count * IntPtr.Size));
        var buffer = Marshal.AllocHGlobal(checked((int)length * 2));
        try
        {
            rc = GetPackagesByPackageFamily(Family, ref count, names, ref length, buffer);
            if (rc != 0) throw new Win32Exception(rc);
            var packages = new List<(Version Version, string Name)>();
            for (int n = 0; n < count; n++)
            {
                string name = Marshal.PtrToStringUni(Marshal.ReadIntPtr(names, n * IntPtr.Size))!;
                var parts = name.Split('_');
                if (parts.Length > 2 && Version.TryParse(parts[1], out var version) && parts[2] == "x64") packages.Add((version, name));
            }
            foreach (var package in packages.OrderByDescending(x => x.Version))
            {
                uint size = 0; GetPackagePathByFullName(package.Name, ref size, null);
                if (size == 0 || size > 32768) continue;
                var path = new StringBuilder((int)size);
                if (GetPackagePathByFullName(package.Name, ref size, path) != 0) continue;
                foreach (var exe in new[] { "ChatGPT.exe", "Codex.exe" })
                { var full = Path.Combine(path.ToString(), "app", exe); if (File.Exists(full) && Native.IsGuiImage(full)) return full; }
            }
        }
        finally { Marshal.FreeHGlobal(buffer); Marshal.FreeHGlobal(names); }
        throw new IOException("已安装的包中没有可用 Codex Desktop。");
    }
}

public static class ProcessTree
{
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)] private struct Entry
    {
        public uint Size, Usage, Id; public UIntPtr Heap; public uint Module, Threads, Parent; public int Priority; public uint Flags;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 260)] public string Name;
    }
    [DllImport("kernel32.dll", SetLastError = true)] private static extern IntPtr CreateToolhelp32Snapshot(uint flags, uint pid);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode)] private static extern bool Process32FirstW(IntPtr snapshot, ref Entry entry);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode)] private static extern bool Process32NextW(IntPtr snapshot, ref Entry entry);
    [DllImport("kernel32.dll")] private static extern bool CloseHandle(IntPtr handle);
    public static Dictionary<int, int> Parents()
    {
        var result = new Dictionary<int, int>(); var handle = CreateToolhelp32Snapshot(2, 0);
        if (handle == new IntPtr(-1)) throw new Win32Exception();
        try { var e = new Entry { Size = (uint)Marshal.SizeOf<Entry>(), Name = "" }; if (Process32FirstW(handle, ref e)) do { result[(int)e.Id] = (int)e.Parent; } while (Process32NextW(handle, ref e)); }
        finally { CloseHandle(handle); }
        return result;
    }
    public static void ProtectAncestors(int target)
    {
        var parents = Parents(); int cursor = Environment.ProcessId; var visited = new HashSet<int>();
        while (cursor > 0 && visited.Add(cursor))
        { if (cursor == target) throw new InvalidOperationException("不能退出承载当前开发任务的 Codex 实例。"); if (!parents.TryGetValue(cursor, out cursor)) break; }
    }
}

public sealed class ProcessManager(ControllerConfig config, string controllerExe)
{
    private readonly Dictionary<string, ProcessIdentity> cache = new();
    private bool discoveryUncertain;
    private readonly SemaphoreSlim operations = new(1);
    public static string Profile(string command)
    {
        var args = Native.Arguments(command); string found = ""; int count = 0;
        for (int n = 1; n < args.Length; n++)
        {
            if (args[n] == "--type" || args[n].StartsWith("--type=")) return "<child>";
            if (args[n] == "--user-data-dir") { if (++n == args.Length) throw new InvalidDataException("缺少 profile 参数。"); found = args[n]; count++; }
            else if (args[n].StartsWith("--user-data-dir=")) { found = args[n][16..]; count++; }
        }
        if (count > 1) throw new InvalidDataException("重复 profile 参数。");
        return found.Length > 0 ? Paths.Full(found) : "";
    }
    public static ProcessIdentity Inspect(Process process) => new(process.Id, process.StartTime.ToUniversalTime().Ticks, process.MainModule!.FileName!, Native.ReadCommandLine(process.Id));
    public static bool Valid(InstanceConfig instance, ProcessIdentity p) => Native.IsKnownProcess(p.Id, p.Started, p.Path, p.Command, instance.Home, instance.Profile);
    public InstanceStatus[] Snapshot(bool discover = false)
    {
        lock (cache) return SnapshotCore(discover);
    }
    private InstanceStatus[] SnapshotCore(bool discover)
    {
        // One lightweight list for both environments; stable instances use their known PID.
        var results = new List<InstanceStatus>(); List<ProcessIdentity>? candidates = null;
        foreach (var instance in config.Instances)
        {
            if (!discover && cache.TryGetValue(instance.Id, out var known) && Valid(instance, known)) { results.Add(new(instance.Id, "Running", "运行中", known)); continue; }
            candidates ??= Discover();
            try
            {
                var matches = new List<ProcessIdentity>(); bool uncertain = discoveryUncertain;
                var current = PackageLocator.FindDesktop(instance.Executable);
                string? recorded = null;
                var recordPath = Path.Combine(config.StateDirectory, instance.Id + ".json");
                if (File.Exists(recordPath))
                {
                    var r = Json.Read<InstanceRecord>(recordPath, 65536);
                    if (r.InstanceId == instance.Id && Paths.Same(r.Home, instance.Home) && candidates.Any(p => p.Id == r.Pid && p.Started.ToString() == r.Started && Paths.Same(p.Path, r.Executable))) recorded = r.Executable;
                }
                foreach (var p in candidates)
                {
                    try
                    {
                        if (!Paths.Same(Profile(p.Command), instance.Profile)) continue;
                        var home = Native.CodexHome(p.Id);
                        if (home == null) { uncertain = true; continue; }
                        if (!Paths.Same(home, instance.Home)) continue;
                        if (!Paths.Same(p.Path, current) && !Paths.Same(p.Path, recorded)) { uncertain = true; continue; }
                        matches.Add(p);
                    }
                    catch (Exception e) when (e is InvalidOperationException or Win32Exception or IOException or NotSupportedException) { uncertain = true; }
                }
                if (uncertain || matches.Count > 1) { results.Add(new(instance.Id, "Unknown", "进程身份无法唯一确认", null)); cache.Remove(instance.Id); }
                else if (matches.Count == 1) { cache[instance.Id] = matches[0]; results.Add(new(instance.Id, "Running", "运行中", matches[0])); }
                else { cache.Remove(instance.Id); results.Add(new(instance.Id, "Stopped", "未运行", null)); }
            }
            catch (Exception e) when (e is IOException or Win32Exception or InvalidDataException) { results.Add(new(instance.Id, "Unknown", e.Message, null)); }
        }
        return results.ToArray();
    }
    private List<ProcessIdentity> Discover()
    {
        discoveryUncertain = false;
        var list = new List<ProcessIdentity>();
        foreach (var name in new[] { "ChatGPT", "Codex" })
        foreach (var process in Process.GetProcessesByName(name))
        {
            using (process)
            {
                try { var p = Inspect(process); if (Profile(p.Command) != "<child>" && Native.IsGuiImage(p.Path)) list.Add(p); }
                catch (Exception e) when (e is InvalidOperationException or Win32Exception or IOException or NotSupportedException) { try { if (!process.HasExited && name == "ChatGPT") discoveryUncertain = true; } catch (InvalidOperationException) { } }
            }
        }
        return list;
    }
    public InstanceStatus Status(InstanceConfig i, bool discover = false) => Snapshot(discover).Single(x => x.InstanceId == i.Id);
    public static ProcessStartInfo CleanStart(string exe, InstanceConfig instance)
    {
        var info = new ProcessStartInfo(exe) { UseShellExecute = false, CreateNoWindow = true, WorkingDirectory = instance.Projects };
        foreach (var name in info.Environment.Keys.ToArray()) if (name.StartsWith("CODEX_") || name.StartsWith("OPENAI_") || name.StartsWith("CHATGPT_") || name.StartsWith("ELECTRON_") || name is "CUSTOM_API_KEY" or "NODE_OPTIONS" or "FREEHYY_API_KEY" or "PSModulePath") info.Environment.Remove(name);
        info.Environment["CODEX_HOME"] = instance.Home;
        if (instance.Profile.Length > 0) info.Environment["CODEX_ELECTRON_USER_DATA_PATH"] = instance.Profile;
        return info;
    }
    private string RecordPath(InstanceConfig i) => Path.Combine(config.StateDirectory, i.Id + ".json");
    private void Save(InstanceConfig i, ProcessIdentity p) => Json.Write(RecordPath(i), new InstanceRecord(i.Id, i.Home, i.Profile, i.LaunchMode, p.Id, p.Started.ToString(), p.Path));
    public async Task<ProcessIdentity> OpenAsync(InstanceConfig i, string? threadId, CancellationToken cancel)
    {
        await operations.WaitAsync(cancel);
        try
        {
            var target = await Task.Run(() => InstanceLease.Run(i, () =>
            {
                var status = Status(i);
                if (status.State == "Unknown") throw new InvalidOperationException(status.Reason);
                if (status.State == "Stopped")
                {
                    ColdStart(i);
                    for (int n = 0; n < 30; n++) { cancel.ThrowIfCancellationRequested(); Thread.Sleep(300); status = Status(i, true); if (status.State == "Running") break; }
                    if (status.Process == null) throw new IOException("启动后未能确认目标实例，未重复启动。");
                }
                Save(i, status.Process!); return status.Process!;
            }), cancel);
            if (threadId != null && !CompletionReader.IsUuid(threadId)) throw new InvalidDataException("聊天标识无效。");
            if (threadId != null || !Native.Windows(target.Id).Any(w => w.Visible)) await ActivateAsync(i, target, threadId, cancel);
            return target;
        }
        finally { operations.Release(); }
    }
    private void ColdStart(InstanceConfig i)
    {
        foreach (var dir in new[] { i.Home, i.Projects, i.Projectless, i.Profile }.Where(p => p.Length > 0)) if (!Directory.Exists(dir)) throw new DirectoryNotFoundException("环境目录不存在：" + dir);
        if (i.Projectless.Length > 0)
        {
            var actual = new TomlConfig(File.ReadAllText(Path.Combine(i.Home, "config.toml"))).GetString("desktop.projectlessWorkspaceRoot");
            if (!Paths.Same(actual, i.Projectless)) throw new InvalidDataException("无项目工作目录与登记不一致。");
        }
        if (i.LaunchMode == "external")
        {
            Paths.Regular(i.ExternalLauncher); if (!File.Exists(i.ExternalLauncher)) throw new FileNotFoundException("外部启动器不存在。");
            var info = CleanStart(Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.Windows), "System32/WindowsPowerShell/v1.0/powershell.exe"), i);
            info.Arguments = "-NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File \"" + i.ExternalLauncher + "\"";
            Native.StartDetached(info); return;
        }
        // An app-package identity is required on recent Windows builds. Bootstrap our own short-lived C# helper.
        var args = "--launch-helper --config \"" + RuntimePaths.ConfigPath + "\" --role " + i.Role;
        PackageActivation.Start(controllerExe, args);
    }
    public static async Task ActivateAsync(InstanceConfig i, ProcessIdentity p, string? threadId, CancellationToken cancel)
    {
        if (!Valid(i, p)) throw new InvalidOperationException("目标进程已变化。");
        var info = CleanStart(p.Path, i);
        info.Arguments = i.Profile.Length > 0 ? "--user-data-dir=\"" + i.Profile + "\" " : "";
        if (threadId != null) info.Arguments += "\"codex://threads/" + Guid.Parse(threadId) + "\"";
        int pid = Native.StartDetached(info);
        try { using var secondary = Process.GetProcessById(pid); await secondary.WaitForExitAsync(cancel).WaitAsync(TimeSpan.FromSeconds(5), cancel); }
        catch (ArgumentException) { }
        if (!Valid(i, p)) throw new InvalidOperationException("目标进程已变化。");
    }
    public static void StopConfirmed(InstanceConfig i, ProcessIdentity p)
    {
        ProcessTree.ProtectAncestors(p.Id);
        if (!Valid(i, p)) throw new InvalidOperationException("退出前进程身份发生变化。");
        var parents = ProcessTree.Parents(); var owned = new List<ProcessIdentity> { p };
        bool added;
        do
        {
            added = false;
            foreach (var pair in parents)
            {
                if (owned.Any(x => x.Id == pair.Key) || !owned.Any(x => x.Id == pair.Value)) continue;
                try
                {
                    using var process = Process.GetProcessById(pair.Key); var child = Inspect(process);
                    if (Paths.Same(child.Path, p.Path) && Profile(child.Command) == "<child>" && child.Started >= owned.First(x => x.Id == pair.Value).Started) { owned.Add(child); added = true; }
                }
                catch (Exception e) when (e is ArgumentException or Win32Exception or InvalidOperationException) { }
            }
        } while (added);
        foreach (var expected in owned.OrderByDescending(x => x.Started))
        {
            try
            {
                using var process = Process.GetProcessById(expected.Id); _ = process.Handle;
                var actual = Inspect(process);
                if (actual.Started != expected.Started || !Paths.Same(actual.Path, expected.Path) || actual.Command != expected.Command) throw new InvalidOperationException("PID 身份发生变化，退出已中止。");
                process.Kill();
            }
            catch (ArgumentException) { }
        }
    }
}

public static class RuntimePaths { public static string ConfigPath { get; set; } = ""; }
public static class PackageActivation
{
    [ComImport, Guid("F158268A-D5A5-45CE-99CF-00D6C3F3FC0A"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)] private interface IActivator
    {
        [PreserveSig] int Activate([MarshalAs(UnmanagedType.LPWStr)] string id, [MarshalAs(UnmanagedType.LPWStr)] string exe, [MarshalAs(UnmanagedType.LPWStr)] string args, out IntPtr handle);
        [PreserveSig] int ActivateWithOptions([MarshalAs(UnmanagedType.LPWStr)] string id, [MarshalAs(UnmanagedType.LPWStr)] string exe, [MarshalAs(UnmanagedType.LPWStr)] string args, uint options, uint parent, out IntPtr handle);
    }
    [DllImport("kernel32.dll")] private static extern bool CloseHandle(IntPtr handle);
    public static void Start(string exe, string args)
    {
        var instance = Activator.CreateInstance(Type.GetTypeFromCLSID(new Guid("168EB462-775F-42AE-9111-D714B2306C2E"))!)!;
        IntPtr handle = IntPtr.Zero;
        try { Marshal.ThrowExceptionForHR(((IActivator)instance).ActivateWithOptions(PackageLocator.Family + "!App", exe, args, 14, (uint)Environment.ProcessId, out handle)); }
        finally { if (handle != IntPtr.Zero) CloseHandle(handle); Marshal.FinalReleaseComObject(instance); }
    }
}
