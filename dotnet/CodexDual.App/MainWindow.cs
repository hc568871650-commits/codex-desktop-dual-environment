using System.Diagnostics;
using System.Reflection;
using System.Text.Json;
using System.Text.Json.Nodes;
using Microsoft.Win32;

namespace CodexDual.App;

public sealed partial class MainWindow : ShellForm
{
    private readonly ControllerConfig config;
    private readonly string[] args;
    private readonly Preferences preferences;
    private readonly ProcessManager processes;
    private readonly HealthStore health;
    private readonly TitleService titles;
    private readonly CancellationTokenSource lifetime = new();
    private CompletionMonitor? monitor;
    private TitleAdapter? adapter;
    private Task? background, consume;
    private readonly NotifyIcon tray = new();
    private readonly TrayClick trayClick = new();
    private readonly QuietMenu trayMenu = new();
    private readonly Panel sidebar = new() { Name = "Sidebar" };
    private readonly Panel body = new();
    private readonly Label feedback = new() { AutoEllipsis = true };
    private readonly Dictionary<string, Panel> pages = new();
    private readonly Dictionary<string, QuietButton> navigation = new();
    private readonly Dictionary<string, Label> statusLabels = new();
    private readonly List<(EventWaitHandle Handle, RegisteredWaitHandle Wait)> events = [];
    private readonly List<Completion> history = [];
    private readonly ModernList recent = new();
    private readonly Label diagnostics = new() { AutoSize = false };
    private readonly Label titleStatus = new() { AutoSize = false };
    private JsonObject notificationSettings;
    private CompletionCard? notice;
    private bool quitting, closed, busy;
    private volatile bool panelVisible;
    private readonly Stopwatch startup = Stopwatch.StartNew();
    private long readyMilliseconds;

    public MainWindow(ControllerConfig config, string[] args, string eventName)
    {
        this.config = config; this.args = args; preferences = new(config.StateDirectory);
        processes = new(config, Environment.ProcessPath!); health = new(config.StateDirectory); titles = new(config.Api, config.StateDirectory, health, cliResolver: () => ThreadRename.FindCli(config.Api, processes.Status(config.Api).Process ?? throw new IOException("请先打开 API 环境。"), config));
        AppTheme.SetAppearance(preferences.Mode, preferences.Accent);
        Text = config.DisplayName + (args.Contains("--trial") ? " · 独立验证" : "");
        Name = "CodexDualControllerDotNet"; Font = new Font("Microsoft YaHei UI", 11.5f); ClientSize = new Size(1080, 760); MinimumSize = new Size(1040, 720); StartPosition = FormStartPosition.Manual;
        string icon = Path.Combine(AppContext.BaseDirectory, "assets/controller.ico"); if (File.Exists(icon)) Icon = new Icon(icon);
        FormBorderStyle = FormBorderStyle.None;
        sidebar.SetBounds(1, 1, 210, 758); sidebar.Anchor = AnchorStyles.Top | AnchorStyles.Bottom | AnchorStyles.Left; Controls.Add(sidebar);
        body.SetBounds(250, 78, 792, 622); body.Anchor = AnchorStyles.Top | AnchorStyles.Bottom | AnchorStyles.Left | AnchorStyles.Right; Controls.Add(body);
        feedback.SetBounds(250, 716, 790, 28); feedback.Name = "Muted"; feedback.Font = new Font(Font.FontFamily, 10.5f); feedback.Anchor = AnchorStyles.Bottom | AnchorStyles.Left | AnchorStyles.Right; Controls.Add(feedback);
        var brand = AddLabel(sidebar, "Codex 双环境", 23, 28, 174, 36); brand.Font = new Font(Font.FontFamily, 13, FontStyle.Bold);
        BuildChrome(brand);
        (string Key, string Label)[] labels = [("概览", "工作台"), ("通知与提问", "通知"), ("API 渠道", "连接"), ("偏好设置", "设置"), ("诊断", "高级"), ("标题建议", "标题工具")];
        for (int n = 0; n < labels.Length; n++)
        {
            string key = labels[n].Key; var page = new Panel { Dock = DockStyle.Fill, AutoScroll = true, Visible = false }; body.Controls.Add(page); pages[key] = page;
            if (key == "标题建议") continue;
            var button = AddButton(sidebar, labels[n].Label, 14, key == "诊断" ? 628 : 98 + n * 56, 182, () => SelectPage(key)); button.Quiet = true; button.TextAlign = ContentAlignment.MiddleLeft; navigation[key] = button;
            if (key == "诊断") button.Anchor = AnchorStyles.Bottom | AnchorStyles.Left;
        }
        var quit = AddButton(sidebar, "退出", 14, 688, 182, Quit); quit.Quiet = true; quit.TextAlign = ContentAlignment.MiddleLeft; quit.Anchor = AnchorStyles.Bottom | AnchorStyles.Left;
        notificationSettings = LoadNotificationSettings();
        BuildOverview(pages["概览"]); BuildTitles(pages["标题建议"]); BuildNotifications(pages["通知与提问"]); BuildApi(pages["API 渠道"]); BuildPreferences(pages["偏好设置"]);
        BuildAdvanced(pages["诊断"]);
        health.Changed += _ => Post(UpdateHealth);
        tray.Icon = Icon ?? SystemIcons.Application; tray.Text = "Codex 双环境"; tray.Visible = true; tray.ContextMenuStrip = trayMenu;
        tray.MouseDown += (_, e) => trayClick.HandleMouseDown(e.Button);
        trayClick.SingleClick += (_, _) => RunUi(() => OpenInstance(config.Api)); trayClick.DoubleClick += (_, _) => PresentPanel();
        trayMenu.Items.Add("打开控制面板", null, (_, _) => PresentPanel());
        trayMenu.Items.Add("打开 API 环境", null, (_, _) => RunUi(() => OpenInstance(config.Api)));
        trayMenu.Items.Add("打开官方环境", null, (_, _) => RunUi(() => OpenInstance(config.Official)));
        trayMenu.Items.Add("退出控制器", null, (_, _) => Quit());
        _ = Handle;
        Register(eventName, PresentPanel); Register(eventName + ".Configure", () => { PresentPanel(); SelectPage("API 渠道"); }); Register(eventName + ".Quit", Quit);
        VisibleChanged += (_, _) => panelVisible = Visible;
        FormClosing += Closing;
        SystemEvents.UserPreferenceChanged += SystemPreferenceChanged;
        SelectPage(args.Contains("--configure") ? "API 渠道" : "概览"); ApplyTheme(); RestorePosition();
        Shown += async (_, _) =>
        {
            readyMilliseconds = startup.ElapsedMilliseconds;
            if (args.Contains("--background")) Hide();
            if (!args.Contains("--smoke-ui")) StartBackground();
            await RefreshStatus();
            if (args.Contains("--smoke-ui")) await Smoke();
        };
    }
    private static Label AddLabel(Control parent, string text, int x, int y, int width, int height)
    { var label = new Label { Text = text, AutoSize = false, AutoEllipsis = true, TextAlign = ContentAlignment.MiddleLeft }; label.SetBounds(x, y, width, height); parent.Controls.Add(label); return label; }
    private static QuietButton AddButton(Control parent, string text, int x, int y, int width, Action click)
    { var button = new ActionButton { Text = text, AccessibleName = text }; button.SetBounds(x, y, width, 46); button.Click += (_, _) => click(); parent.Controls.Add(button); return button; }
    private static TextBox AddInput(Control parent, string text, int x, int y, int width, bool secret = false)
    { var box = new TextBox { Text = text, UseSystemPasswordChar = secret }; PlaceInput(parent, box, x, y, width); return box; }
    private static InputFrame PlaceInput(Control parent, TextBox box, int x, int y, int width)
    { var frame = new InputFrame(box); frame.SetBounds(x, y, width, 48); parent.Controls.Add(frame); return frame; }
    private void PageTitle(Panel page, string title)
    {
        // Reserve the right-hand header area for actions. An empty Label still
        // paints its background and can cover sibling buttons in a live window.
        AddLabel(page, title, 0, 0, 520, 48).Font = new Font(Font.FontFamily, 21, FontStyle.Bold);
    }
    private static void Divider(Control parent, int y, int width = 770)
    { var line = new Hairline { Location = new Point(0, y), Width = width }; parent.Controls.Add(line); }
    [System.Runtime.InteropServices.DllImport("user32.dll")] private static extern bool ReleaseCapture();
    [System.Runtime.InteropServices.DllImport("user32.dll")] private static extern IntPtr SendMessage(IntPtr window, int message, IntPtr w, IntPtr l);
    private void BuildChrome(Control brand)
    {
        var drag = new Panel { Location = new Point(212, 1), Size = new Size(ClientSize.Width - 314, 48), Anchor = AnchorStyles.Top | AnchorStyles.Left | AnchorStyles.Right }; Controls.Add(drag);
        MouseEventHandler move = (_, e) => { if (e.Button == MouseButtons.Left) { ReleaseCapture(); SendMessage(Handle, 0xA1, new IntPtr(2), IntPtr.Zero); } };
        drag.MouseDown += move; brand.MouseDown += move;
        var minimize = AddButton(this, "−", ClientSize.Width - 100, 5, 44, () => WindowState = FormWindowState.Minimized); minimize.Quiet = true; minimize.Height = 36; minimize.Anchor = AnchorStyles.Top | AnchorStyles.Right; minimize.AccessibleName = "最小化";
        var close = AddButton(this, "×", ClientSize.Width - 52, 5, 44, Close); close.Quiet = true; close.Height = 36; close.Anchor = AnchorStyles.Top | AnchorStyles.Right; close.AccessibleName = "收起到托盘";
    }
    private void Register(string name, Action action)
    {
        var handle = new EventWaitHandle(false, EventResetMode.AutoReset, name);
        var wait = ThreadPool.RegisterWaitForSingleObject(handle, (_, _) => Post(action), null, Timeout.Infinite, false); events.Add((handle, wait));
    }
    private void Post(Action action) { if (closed || IsDisposed || !IsHandleCreated) return; try { BeginInvoke(() => { if (!closed) action(); }); } catch (InvalidOperationException) { } }
    private void RunUi(Func<Task> operation)
    {
        if (busy) { feedback.Text = "正在处理上一项操作…"; return; }
        _ = Execute();
        async Task Execute() { busy = true; try { await operation(); } catch (OperationCanceledException) { feedback.Text = "操作已取消"; } catch (Exception e) { feedback.Text = e.Message; } finally { busy = false; } }
    }
    private void PresentPanel() { Present(preferences.Behavior("panelMode", "focus") == "focus", preferences.Overlay("panelOverlay", false)); _ = RefreshStatus(); }
    private void SelectPage(string name)
    {
        foreach (var pair in pages) pair.Value.Visible = pair.Key == name;
        foreach (var pair in navigation) { pair.Value.Selected = pair.Key == name || name == "标题建议" && pair.Key == "诊断"; pair.Value.Invalidate(); }
        pages[name].BringToFront();
        if (name == "标题建议") _ = RefreshThreads();
        if (name == "诊断") UpdateHealth();
    }
    private void ApplyTheme() { AppTheme.ApplyTo(this); BackColor = ModernStyle.Canvas; ModernStyle.Apply(this); AppTheme.ApplyTo(trayMenu); notice?.Invalidate(); }
    private void SystemPreferenceChanged(object sender, UserPreferenceChangedEventArgs e) => Post(() => { if (preferences.Mode == "system") { AppTheme.SetAppearance(preferences.Mode, preferences.Accent); ApplyTheme(); } });
    private void RestorePosition()
    {
        var point = preferences.Data["panel"]; var area = Screen.PrimaryScreen!.WorkingArea;
        int x = point?["x"]?.GetValue<int>() ?? area.Left + (area.Width - Width) / 2, y = point?["y"]?.GetValue<int>() ?? area.Top + (area.Height - Height) / 2;
        area = Screen.FromPoint(new Point(x, y)).WorkingArea;
        Location = new Point(Math.Clamp(x, area.Left, Math.Max(area.Left, area.Right - Width)), Math.Clamp(y, area.Top, Math.Max(area.Top, area.Bottom - Height)));
    }
    private void SavePosition() { preferences.Data["panel"] = new JsonObject { ["x"] = Left, ["y"] = Top }; preferences.Save(); }
    private void BuildOverview(Panel page)
    {
        PageTitle(page, "工作台");
        for (int n = 0; n < config.Instances.Count; n++)
        {
            var instance = config.Instances[n]; var card = new SoftSurface(); card.SetBounds(n * 394, 88, 376, 250); page.Controls.Add(card);
            var name = AddLabel(card, preferences.Name(instance), 24, 24, 328, 36); name.Font = new Font(Font.FontFamily, 15, FontStyle.Bold);
            statusLabels[instance.Id] = AddLabel(card, "检查中", 24, 67, 328, 32); statusLabels[instance.Id].Name = "Muted";
            AddButton(card, "打开", 24, 123, 160, () => RunUi(() => OpenInstance(instance))).Primary = true;
            AddButton(card, "退出", 202, 123, 148, () => RunUi(() => StopInstance(instance))).Quiet = true;
            AddButton(card, "项目", 8, 186, 94, () => OpenFolder(instance.Projects)).Quiet = true;
            AddButton(card, "数据", 110, 186, 94, () => OpenFolder(instance.Home)).Quiet = true;
        }
        AddButton(page, "打开全部", 0, 365, 160, () => RunUi(async () => { foreach (var i in config.Instances) await OpenInstance(i); }));
        AddButton(page, "刷新", 180, 365, 112, () => RunUi(RefreshStatus)).Quiet = true;
        Divider(page, 440);
        AddLabel(page, "标题建议", 0, 464, 160, 36);
        titleStatus.SetBounds(180, 464, 438, 36); titleStatus.Name = "Muted"; titleStatus.TextAlign = ContentAlignment.MiddleLeft; page.Controls.Add(titleStatus);
        AddButton(page, "设置", 650, 459, 120, () => SelectPage("偏好设置")).Quiet = true;
    }
    private async Task RefreshStatus()
    {
        if (closed) return;
        try
        {
            var statuses = await Task.Run(() => processes.Snapshot(), lifetime.Token);
            if (closed) return;
            foreach (var s in statuses) if (statusLabels.TryGetValue(s.InstanceId, out var label)) label.Text = s.State == "Running" ? "运行中" : s.State == "Stopped" ? "未运行" : "待检查";
            health.Set("instances", statuses.Any(s => s.State == "Unknown") ? "warning" : "ready", string.Join("；", statuses.Select(s => preferences.Name(config.Instances.First(i => i.Id == s.InstanceId)) + "：" + s.Reason)));
        }
        catch (OperationCanceledException) { }
        catch (Exception e) { feedback.Text = e.Message; }
    }
    private async Task OpenInstance(InstanceConfig instance, string? thread = null)
    {
        if (args.Contains("--smoke-ui")) { feedback.Text = "界面验证不会启动 Codex"; return; }
        var target = await processes.OpenAsync(instance, thread, lifetime.Token);
        var windows = Native.Windows(target.Id).Where(w => w.Visible).ToArray();
        if (windows.Length == 1) feedback.Text = Native.FocusKnownVisible(target.Id, target.Started, target.Path, target.Command, instance.Home, instance.Profile) == "Shown" ? "已打开 " + preferences.Name(instance) : "窗口已运行；Windows 未允许抢占前台，请点击任务栏。";
        else if (windows.Length > 1)
        {
            using var picker = new ShellForm { Text = "选择窗口", ClientSize = new Size(620, 300), Font = Font, StartPosition = FormStartPosition.CenterParent };
            var list = new ListBox { Dock = DockStyle.Fill, DisplayMember = "Title" }; foreach (var w in windows) list.Items.Add(w.Title); list.SelectedIndex = 0; picker.Controls.Add(list);
            var button = new Button { Dock = DockStyle.Bottom, Text = "显示选中窗口", DialogResult = DialogResult.OK }; picker.Controls.Add(button); picker.AcceptButton = button;
            if (picker.ShowDialog(this) == DialogResult.OK && ProcessManager.Valid(instance, target)) Native.FocusVisible(windows[list.SelectedIndex].Handle, target.Id);
        }
        else feedback.Text = "进程已启动，等待原生主窗口显示。";
        await RefreshStatus();
    }
    private async Task StopInstance(InstanceConfig instance)
    {
        var status = await Task.Run(() => processes.Status(instance, true));
        if (status.State != "Running") { feedback.Text = status.Reason; return; }
        if (MessageBox.Show(this, "退出 " + preferences.Name(instance) + " 会中断该窗口中的任务，未保存内容可能丢失。确认退出？", "退出 Codex 环境", MessageBoxButtons.OKCancel, MessageBoxIcon.Warning) != DialogResult.OK) return;
        await Task.Run(() => ProcessManager.StopConfirmed(instance, status.Process!)); feedback.Text = "已结束核验的桌面进程；未按名称结束任务子进程。"; await RefreshStatus();
    }
    private static void OpenFolder(string path) { if (Directory.Exists(path)) Process.Start(new ProcessStartInfo(path) { UseShellExecute = true }); }
    private void StartBackground()
    {
        if (notificationSettings["enabled"]?.GetValue<bool>() != false) StartMonitor();
        if (!args.Contains("--trial") || args.Contains("--enable-attach"))
        {
            using var stream = Assembly.GetExecutingAssembly().GetManifestResourceStream("CodexDual.App.title-renderer.js") ?? Assembly.GetExecutingAssembly().GetManifestResourceStream("CodexDualController.title-renderer.js")!;
            using var reader = new StreamReader(stream);
            adapter = new(config.Api, config.StateDirectory, reader.ReadToEnd(), processes, titles, health); adapter.Start();
        }
        else health.Set("title-adapter", "trial", "独立验证模式未连接日常原生窗口");
        StartQuestions();
        background = Task.Run(async () =>
        {
            using var timer = new PeriodicTimer(TimeSpan.FromSeconds(10));
            try { while (await timer.WaitForNextTickAsync(lifetime.Token)) if (panelVisible) Post(() => _ = RefreshStatus()); } catch (OperationCanceledException) { }
        });
    }
    private void UpdateHealth()
    {
        var values = health.Snapshot();
        var title = values.FirstOrDefault(x => x.Component == "title-adapter");
        titleStatus.Text = title?.State switch { "ready" => "已连接", "restart-required" => "重启 API 版后生效", "disabled" => "已关闭", "trial" => "预览", _ => "等待连接" };
        string Name(string key) => key switch { "instances" => "环境", "notifications" => "通知", "questions" => "提问", "title-adapter" => "标题建议", "title-generation" => "标题生成", "title-compatibility" => "运行兼容性", _ => key };
        diagnostics.Text = "内存 " + (Process.GetCurrentProcess().PrivateMemorySize64 / 1048576) + " MiB   ·   .NET " + Environment.Version + "\r\n\r\n" + string.Join("\r\n\r\n", values.Select(h => Name(h.Component) + "\r\n" + h.Reason));
    }
    private void Quit() { quitting = true; Close(); }
    private async void Closing(object? sender, FormClosingEventArgs e)
    {
        Trace("closing " + closed + " " + quitting);
        if (closed) return;
        if (!quitting && e.CloseReason == CloseReason.UserClosing) { e.Cancel = true; SavePosition(); Hide(); return; }
        e.Cancel = true; if (lifetime.IsCancellationRequested) return;
        lifetime.Cancel(); SavePosition(); titleCancellation?.Cancel(); notice?.Close(); Trace("position-saved");
        foreach (var item in events) { item.Wait.Unregister(null); item.Handle.Dispose(); }
        if (adapter != null) await adapter.DisposeAsync();
        await Task.WhenAll(titleTasks);
        if (monitor != null) await monitor.DisposeAsync();
        if (background != null) await background;
        if (consume != null) await consume;
        await StopQuestions(); Trace("workers-stopped");
        SystemEvents.UserPreferenceChanged -= SystemPreferenceChanged;
        titles.Dispose(); trayClick.Dispose(); tray.Visible = false; tray.Dispose(); trayMenu.Dispose(); closed = true;
        // Close on the next message-loop turn: recursive Close during FormClosing is ignored.
        Trace("close-queued"); BeginInvoke(Close);
    }
    private void Trace(string stage)
    {
        var path = Path.Combine(config.StateDirectory, "dotnet-lifecycle.log");
        try { Directory.CreateDirectory(config.StateDirectory); if (File.Exists(path) && new FileInfo(path).Length > 1024 * 1024) File.WriteAllText(path, ""); File.AppendAllText(path, DateTimeOffset.UtcNow.ToString("o") + " " + stage + "\n"); } catch { }
    }
    private async Task Smoke()
    {
        string folder = Program.Option(args, "--screenshots"); if (folder.Length > 0) Directory.CreateDirectory(folder);
        foreach (string name in pages.Keys)
        {
            SelectPage(name); await Task.Delay(100);
            foreach (var button in pages[name].Controls.OfType<Button>().Where(b => b.Top < 48))
            {
                foreach (int x in new[] { button.Left + 5, button.Left + button.Width / 2, button.Right - 5 })
                    if (!ReferenceEquals(pages[name].GetChildAtPoint(new Point(x, button.Top + button.Height / 2)), button))
                        throw new InvalidOperationException("Header action is covered: " + name + "/" + button.Text);
            }
            if (folder.Length > 0) { using var bitmap = new Bitmap(Width, Height); DrawToBitmap(bitmap, new Rectangle(0, 0, Width, Height)); bitmap.Save(Path.Combine(folder, name + ".png")); }
        }
        string report = Program.Option(args, "--report");
        if (report.Length > 0) Json.Write(report, new { success = true, pages = pages.Keys, headerActionsHitTestPassed = true, readyMilliseconds, privateBytes = Process.GetCurrentProcess().PrivateMemorySize64, scope = "isolated real WinForms controls; no model call, no native chat rename" });
        Quit();
    }
}
