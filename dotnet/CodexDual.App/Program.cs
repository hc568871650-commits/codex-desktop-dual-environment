using System.Diagnostics;
using System.Reflection;
using System.Security.Principal;
using System.Text.Json;

namespace CodexDual.App;

internal static class Program
{
    public static string Option(string[] args, string name, string fallback = "") { int at = Array.IndexOf(args, name); return at >= 0 && at + 1 < args.Length ? args[at + 1] : fallback; }
    [STAThread] private static int Main(string[] args)
    {
        string configPath = Option(args, "--config", Path.Combine(AppContext.BaseDirectory, "instances.local.json"));
        string report = Option(args, "--report");
        try
        {
            Application.SetHighDpiMode(HighDpiMode.PerMonitorV2); Application.EnableVisualStyles(); Application.SetCompatibleTextRenderingDefault(false);
            Application.ThreadException += (_, ev) =>
            {
                if (report.Length > 0) { Json.Write(report + ".exception.json", new { error = ev.Exception.GetType().Name, message = ev.Exception.Message, stack = ev.Exception.StackTrace }); Application.Exit(); }
                else MessageBox.Show("操作失败：" + ev.Exception.Message, "Codex 双环境");
            };
            var config = ControllerConfig.Load(configPath); RuntimePaths.ConfigPath = Path.GetFullPath(configPath);
            string alternate = Option(args, "--state-directory"); if (alternate.Length > 0) { config.StateDirectory = Paths.Full(alternate); config.Validate(); }
            string exe = Environment.ProcessPath!;
            if (args.Contains("--launch-helper")) { LaunchHelper(config, Option(args, "--role")); return 0; }
            if (args.Contains("--open-instance"))
            {
                var instance = config.Instances.Single(i => i.Role == Option(args, "--role"));
                var target = new ProcessManager(config, exe).OpenAsync(instance, null, CancellationToken.None).GetAwaiter().GetResult();
                Native.FocusKnownVisible(target.Id, target.Started, target.Path, target.Command, instance.Home, instance.Profile);
                return 0;
            }
            if (args.Contains("--open-thread"))
            {
                var manager = new ProcessManager(config, exe);
                manager.OpenAsync(config.Api, Option(args, "--thread"), CancellationToken.None).GetAwaiter().GetResult(); return 0;
            }
            if (args.Contains("--probe-rename"))
            {
                if (!config.Api.Home.Contains("native-fixture", StringComparison.OrdinalIgnoreCase)) throw new InvalidOperationException("改名验收仅允许独立测试环境。");
                var manager = new ProcessManager(config, exe); var process = manager.Status(config.Api).Process ?? throw new IOException("测试 Desktop 未运行。");
                string cli = ThreadRename.FindCli(config.Api, process);
                string id = Option(args, "--thread"), before = new ThreadContext(config.Api.Home).Title(id);
                ThreadRename.RenameAsync(cli, config.Api, id, before, "C# 原生改名持久化验证", CancellationToken.None).GetAwaiter().GetResult();
                ThreadRename.RenameAsync(cli, config.Api, id, "C# 原生改名持久化验证", before, CancellationToken.None).GetAwaiter().GetResult();
                Json.Write(report, new { success = true, synthetic = true, nativeApiWriteAndReadback = true, restoredOriginal = true, modelCalls = 0 }); return 0;
            }
            if (args.Contains("--diagnose"))
            {
                var statuses = new ProcessManager(config, exe).Snapshot(true);
                Json.Write(report, new { utc = DateTimeOffset.UtcNow, runtime = Environment.Version.ToString(), statuses, memory = Process.GetCurrentProcess().PrivateMemorySize64, title = TitleSettings.Load(config.StateDirectory).Enabled }); return 0;
            }
            if (args.Contains("--probe-title") || args.Contains("--probe-compatibility"))
            {
                var manager = new ProcessManager(config, exe);
                using var service = new TitleService(config.Api, config.StateDirectory, new HealthStore(config.StateDirectory), cliResolver: () => ThreadRename.FindCli(config.Api, manager.Status(config.Api).Process ?? throw new IOException("API 环境未运行。"), config));
                if (args.Contains("--probe-compatibility")) { service.CheckCliAsync(CancellationToken.None).GetAwaiter().GetResult(); Json.Write(report, new { success = true, offline = true, modelCalls = 0 }); return 0; }
                string id = Guid.NewGuid().ToString(); var watch = Stopwatch.StartNew();
                var answer = service.GenerateAsync(Guid.NewGuid().ToString(), id, "测试", [new("user", "改进 Windows 双环境控制器的性能与标题建议稳定性。")], false, CancellationToken.None).GetAwaiter().GetResult();
                double milliseconds = watch.Elapsed.TotalMilliseconds;
                var cached = service.GenerateAsync(Guid.NewGuid().ToString(), id, "测试", [new("user", "改进 Windows 双环境控制器的性能与标题建议稳定性。")], false, CancellationToken.None).GetAwaiter().GetResult();
                Json.Write(report, new { success = true, synthetic = true, savedTitle = false, milliseconds, titleLength = answer.Title.Length, cacheHit = cached.Cached }); return 0;
            }
            string sid = WindowsIdentity.GetCurrent().User!.Value, hash = Paths.Hash(Path.GetFullPath(configPath).ToLowerInvariant()).ToUpperInvariant();
            string suffix = args.Contains("--trial") ? ".Trial." + hash : "";
            string panelName = "Local\\CodexDual.Panel." + sid + "." + hash + suffix;
            if (args.Contains("--quit")) { using var quit = EventWaitHandle.OpenExisting(panelName + ".Quit"); quit.Set(); return 0; }
            using var mutex = new Mutex(false, "Local\\CodexDual.Controller." + sid + suffix);
            bool held; try { held = mutex.WaitOne(0); } catch (AbandonedMutexException) { held = true; }
            if (!held)
            {
                if (args.Contains("--background")) return 0;
                using var show = EventWaitHandle.OpenExisting(panelName + (args.Contains("--configure") ? ".Configure" : "")); show.Set(); return 0;
            }
            try
            {
                using var form = new MainWindow(config, args, panelName);
                Application.Run(form);
                if (report.Length > 0) File.WriteAllText(report + ".exited", DateTimeOffset.UtcNow.ToString("o"));
            }
            finally { mutex.ReleaseMutex(); }
            return 0;
        }
        catch (Exception e)
        {
            string message = e is JsonException ? "配置格式无效。" : e.Message;
            if (report.Length > 0) Json.Write(report, new { success = false, error = message, exception = e.GetType().Name });
            else MessageBox.Show(message, "Codex 双环境", MessageBoxButtons.OK, MessageBoxIcon.Warning);
            return 1;
        }
    }
    private static void LaunchHelper(ControllerConfig config, string role)
    {
        var instance = config.Instances.Single(i => i.Role == role);
        var manager = new ProcessManager(config, Environment.ProcessPath!);
        if (manager.Status(instance, true).State != "Stopped") throw new InvalidOperationException("目标环境已经运行或归属未确认。");
        string path = PackageLocator.FindDesktop(instance.Executable);
        var info = ProcessManager.CleanStart(path, instance);
        if (instance.Profile.Length > 0) info.Arguments = "--user-data-dir=\"" + instance.Profile + "\"";
        if (instance.Role == "api")
        {
            if (instance.LaunchMode != "managed-api") throw new InvalidOperationException("外部环境应通过登记的启动器启动。");
            ApiProfiles.PrepareLaunch(config, instance, info);
            if (TitleSettings.Load(config.StateDirectory).Enabled) info.Arguments += " --remote-debugging-port=0 --remote-debugging-address=127.0.0.1";
        }
        try { Native.StartDetached(info); } finally { info.Environment.Remove("CODEX_DUAL_API_KEY"); }
    }
}
