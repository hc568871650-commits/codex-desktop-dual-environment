using System.Diagnostics;
using System.Text.Json;
using System.Text.Json.Nodes;
using Microsoft.Win32;

namespace CodexDual.App;

public sealed partial class MainWindow
{
    private readonly QuietListBox chats = new();
    private readonly TextBox titleText = new();
    private readonly Label generationStatus = new();
    private CancellationTokenSource? titleCancellation;
    private bool editingSuggestion;
    private int editEpoch;
    private List<ChatInfo> chatItems = [];
    private int refreshEpoch;
    private readonly List<Task> titleTasks = [];
    private void BuildTitles(Panel page)
    {
        AddLabel(page, "为 API 聊天生成标题", 0, 0, 660, 32).Font = new Font(Font.FontFamily, 15, FontStyle.Bold);
        AddLabel(page, "选择聊天，生成建议后可编辑；点击保存才会改名。", 0, 40, 660, 35);
        chats.SetBounds(0, 85, 670, 210); chats.Anchor = AnchorStyles.Top | AnchorStyles.Left | AnchorStyles.Right; page.Controls.Add(chats);
        chats.SelectedIndexChanged += (_, _) =>
        {
            titleCancellation?.Cancel(); editEpoch++;
            editingSuggestion = true; titleText.Text = chats.SelectedIndex >= 0 && chats.SelectedIndex < chatItems.Count ? chatItems[chats.SelectedIndex].Title : ""; editingSuggestion = false;
            generationStatus.Text = "";
        };
        AddButton(page, "刷新聊天", 0, 310, 120, () => _ = RefreshThreads());
        AddButton(page, "生成建议", 140, 310, 120, () => TrackGeneration(false)).Primary = true;
        AddButton(page, "再想一个", 280, 310, 120, () => TrackGeneration(true));
        AddButton(page, "打开聊天", 420, 310, 120, () => { if (SelectedChat() is { } c) RunUi(() => OpenInstance(config.Api, c.Id)); });
        titleText.SetBounds(0, 366, 670, 32); titleText.MaxLength = 200; titleText.AccessibleName = "聊天标题"; page.Controls.Add(titleText);
        titleText.TextChanged += (_, _) => { if (!editingSuggestion) { editEpoch++; titleCancellation?.Cancel(); generationStatus.Text = "已保留手动输入"; } };
        AddButton(page, "保存标题", 0, 417, 120, () => RunUi(SaveTitle));
        AddButton(page, "复制标题", 140, 417, 120, () => { if (titleText.Text.Length > 0) { Clipboard.SetText(titleText.Text); generationStatus.Text = "已复制"; } });
        generationStatus.SetBounds(0, 470, 670, 60); page.Controls.Add(generationStatus);
    }
    private ChatInfo? SelectedChat() => chats.SelectedIndex >= 0 && chats.SelectedIndex < chatItems.Count ? chatItems[chats.SelectedIndex] : null;
    private async Task RefreshThreads()
    {
        if (closed) return;
        string? selected = SelectedChat()?.Id; int epoch = ++refreshEpoch; int edits = editEpoch;
        try
        {
            List<ChatInfo> incoming;
            if (args.Contains("--smoke-ui")) incoming = [new(Guid.NewGuid().ToString(), "改进双环境性能与标题建议", ""), new(Guid.NewGuid().ToString(), "整理项目资料与开发计划", "")];
            else incoming = await Task.Run(() => new ThreadContext(config.Api.Home).List(), lifetime.Token);
            if (closed || epoch != refreshEpoch || edits != editEpoch) return;
            chatItems = incoming;
            chats.BeginUpdate(); chats.Items.Clear(); foreach (var item in chatItems) chats.Items.Add(item.Title); chats.EndUpdate();
            if (chatItems.Count > 0) chats.SelectedIndex = Math.Max(0, chatItems.FindIndex(c => c.Id == selected));
        }
        catch (OperationCanceledException) { }
        catch (Exception e) { generationStatus.Text = e.Message; }
    }
    private void TrackGeneration(bool refresh) { titleTasks.RemoveAll(t => t.IsCompleted); titleTasks.Add(GenerateTitle(refresh)); }
    private async Task GenerateTitle(bool refresh)
    {
        if (SelectedChat() is not { } chat || args.Contains("--smoke-ui")) return;
        titleCancellation?.Cancel(); titleCancellation = CancellationTokenSource.CreateLinkedTokenSource(lifetime.Token); var cancel = titleCancellation;
        int epoch = editEpoch; generationStatus.Text = "正在生成标题建议…";
        try
        {
            var result = await titles.SuggestAsync(Guid.NewGuid().ToString(), chat.Id, chat.Title, refresh, cancel.Token);
            if (closed || cancel.IsCancellationRequested || epoch != editEpoch || SelectedChat()?.Id != chat.Id) return;
            editingSuggestion = true; titleText.Text = result.Title; editingSuggestion = false; generationStatus.Text = result.Cached ? "已读取缓存建议；确认后点击保存" : "建议已生成；可编辑后保存";
        }
        catch (OperationCanceledException) { if (epoch == editEpoch) generationStatus.Text = "生成已取消或超时"; }
        catch (Exception e) { if (!closed && epoch == editEpoch) generationStatus.Text = e.Message; }
        finally { if (ReferenceEquals(titleCancellation, cancel)) titleCancellation = null; cancel.Dispose(); }
    }
    private async Task SaveTitle()
    {
        var chat = SelectedChat() ?? throw new InvalidOperationException("请先选择聊天。"); string text = titleText.Text.Trim();
        if (text.Length == 0 || text == chat.Title) return;
        titleCancellation?.Cancel();
        var status = await Task.Run(() => processes.Status(config.Api));
        if (status.Process == null) throw new IOException("请先打开 API 环境；也可复制建议后在原生窗口保存。");
        string cli = await Task.Run(() => ThreadRename.FindCli(config.Api, status.Process, config));
        await ThreadRename.RenameAsync(cli, config.Api, chat.Id, chat.Title, text, lifetime.Token);
        generationStatus.Text = "标题已保存，并通过原生接口回读确认"; await RefreshThreads();
    }
    private JsonObject LoadNotificationSettings()
    {
        string path = Path.Combine(config.StateDirectory, "notifications/settings.local.json");
        return File.Exists(path) ? Json.Read<JsonObject>(path) : new JsonObject { ["schema"] = 1, ["enabled"] = true, ["epoch"] = Guid.NewGuid().ToString("N"), ["displaySeconds"] = 15, ["fadeEnabled"] = false };
    }
    private void SaveNotificationSettings() => Json.Write(Path.Combine(config.StateDirectory, "notifications/settings.local.json"), notificationSettings);
    private bool Snoozed() => DateTimeOffset.TryParse(notificationSettings["snoozedUntilUtc"]?.GetValue<string>(), out var time) && time > DateTimeOffset.UtcNow;
    private void BuildNotifications(Panel page)
    {
        AddLabel(page, "完成提醒", 0, 0, 660, 32).Font = new Font(Font.FontFamily, 15, FontStyle.Bold);
        var enabled = new QuietSwitch { Text = "显示 API 任务完成提醒", Checked = notificationSettings["enabled"]?.GetValue<bool>() != false }; enabled.SetBounds(0, 45, 350, 36); page.Controls.Add(enabled);
        enabled.CheckedChanged += (_, _) => RunUi(async () => { notificationSettings["enabled"] = enabled.Checked; SaveNotificationSettings(); if (enabled.Checked) StartMonitor(); else if (monitor != null) { await monitor.DisposeAsync(); monitor = null; notice?.Close(); } });
        AddButton(page, "预览提醒", 0, 95, 120, () => ShowNotice("完成提醒预览", "已完成", () => { }, true));
        AddButton(page, "暂停 15 分钟", 140, 95, 150, () => { notificationSettings["snoozedUntilUtc"] = DateTimeOffset.UtcNow.AddMinutes(15).ToString("o"); SaveNotificationSettings(); notice?.Close(); feedback.Text = "通知已暂停 15 分钟"; });
        AddButton(page, "恢复提醒", 310, 95, 120, () => { notificationSettings["snoozedUntilUtc"] = ""; SaveNotificationSettings(); feedback.Text = "通知已恢复"; });
        AddLabel(page, "显示秒数（0 为常驻）", 0, 150, 230, 30);
        var seconds = new NumericUpDown { Minimum = 0, Maximum = 3600, Value = notificationSettings["displaySeconds"]?.GetValue<int>() ?? 15 }; seconds.SetBounds(245, 150, 100, 30); page.Controls.Add(seconds);
        var fade = new QuietSwitch { Text = "淡入淡出", Checked = notificationSettings["fadeEnabled"]?.GetValue<bool>() ?? false }; fade.SetBounds(375, 147, 180, 36); page.Controls.Add(fade);
        seconds.ValueChanged += (_, _) => { notificationSettings["displaySeconds"] = (int)seconds.Value; SaveNotificationSettings(); };
        fade.CheckedChanged += (_, _) => { notificationSettings["fadeEnabled"] = fade.Checked; SaveNotificationSettings(); };
        AddLabel(page, "最近完成", 0, 204, 660, 30); recent.SetBounds(0, 240, 670, 200); page.Controls.Add(recent);
        recent.DoubleClick += (_, _) => { if (recent.SelectedIndex >= 0 && recent.SelectedIndex < history.Count) RunUi(() => OpenInstance(config.Api, history[recent.SelectedIndex].ThreadId)); };
        AddButton(page, "待处理问题", 0, 460, 140, ShowPending);
        AddButton(page, "预览提问窗口", 160, 460, 160, PreviewQuestion);
    }
    private void StartMonitor()
    {
        if (monitor != null || args.Contains("--smoke-ui")) return;
        monitor = new(config.Api, config.StateDirectory, health); var current = monitor; current.StartAsync();
        consume = Task.Run(async () =>
        {
            try
            {
                await foreach (var completion in current.Completions.ReadAllAsync(lifetime.Token))
                {
                    string title = new ThreadContext(config.Api.Home).Title(completion.ThreadId);
                    var status = processes.Status(config.Api);
                    bool foreground = status.Process != null && Native.IsInstanceForeground(status.Process.Path, config.Api.Home, config.Api.Profile);
                    Post(() =>
                    {
                        history.Insert(0, completion); recent.Items.Insert(0, title); while (history.Count > 128) { history.RemoveAt(128); recent.Items.RemoveAt(128); }
                        if (!foreground && !Snoozed() && notificationSettings["enabled"]?.GetValue<bool>() != false) ShowNotice(title, "已完成", () => RunUi(() => OpenInstance(config.Api, completion.ThreadId)));
                    });
                }
            }
            catch (OperationCanceledException) { }
        });
    }
    private void ShowNotice(string text, string summary, Action click, bool preview = false)
    {
        notice?.Close(); notice?.Dispose();
        var card = notice = new CompletionCard { Text = summary, ClientSize = new Size(420, 146), ShowInTaskbar = false, TopMost = true, Font = Font, StartPosition = FormStartPosition.Manual };
        AddLabel(card, summary, 20, 12, 340, 24).Name = "Muted";
        var body = new NoticeBody { Text = text, AccessibleName = "打开：" + text }; body.SetBounds(8, 40, 402, 98); body.Click += (_, _) => { card.Close(); if (!preview) click(); }; card.Controls.Add(body);
        AddButton(card, "×", 376, 8, 30, card.Close).Quiet = true;
        card.SetDisplaySettings((notificationSettings["displaySeconds"]?.GetValue<int>() ?? 15) * 1000, notificationSettings["fadeEnabled"]?.GetValue<bool>() ?? false);
        var area = Screen.FromPoint(Cursor.Position).WorkingArea; card.Location = new Point(area.Right - card.Width - 20, area.Bottom - card.Height - 20); AppTheme.ApplyTo(card); card.Show();
    }
    private void BuildPreferences(Panel page)
    {
        AddLabel(page, "外观与窗口", 0, 0, 660, 35).Font = new Font(Font.FontFamily, 15, FontStyle.Bold);
        AddLabel(page, "主题", 0, 60, 150, 30); var mode = new QuietComboBox { DropDownStyle = ComboBoxStyle.DropDownList }; mode.Items.AddRange(["dark", "light", "system"]); mode.SelectedItem = preferences.Mode; mode.SetBounds(180, 60, 200, 32); page.Controls.Add(mode);
        AddLabel(page, "强调色", 0, 110, 150, 30); var accent = new QuietComboBox { DropDownStyle = ComboBoxStyle.DropDownList }; accent.Items.AddRange(["neutral", "blue", "green", "purple"]); accent.SelectedItem = preferences.Accent; accent.SetBounds(180, 110, 200, 32); page.Controls.Add(accent);
        void Appearance() { preferences.Data["appearance"] = new JsonObject { ["mode"] = mode.Text, ["accent"] = accent.Text }; preferences.Save(); AppTheme.SetAppearance(mode.Text, accent.Text); ApplyTheme(); }
        mode.SelectedIndexChanged += (_, _) => Appearance(); accent.SelectedIndexChanged += (_, _) => Appearance();
        var panelFocus = new QuietSwitch { Text = "打开控制面板时获取焦点", Checked = preferences.Behavior("panelMode", "focus") == "focus" }; panelFocus.SetBounds(0, 165, 480, 34); page.Controls.Add(panelFocus);
        var panelTop = new QuietSwitch { Text = "控制面板置顶", Checked = preferences.Overlay("panelOverlay", false) }; panelTop.SetBounds(0, 210, 480, 34); page.Controls.Add(panelTop);
        AddLabel(page, "后台提问方式", 0, 260, 170, 30); var questionMode = new QuietComboBox { DropDownStyle = ComboBoxStyle.DropDownList }; questionMode.Items.AddRange(["notice", "passive", "focus"]); questionMode.SelectedItem = preferences.Behavior("questionMode", "notice"); questionMode.SetBounds(180, 260, 200, 32); page.Controls.Add(questionMode);
        void Behavior() { var behavior = preferences.Data["windowBehavior"] as JsonObject ?? new JsonObject(); behavior["panelMode"] = panelFocus.Checked ? "focus" : "passive"; behavior["panelOverlay"] = panelTop.Checked; behavior["questionMode"] = questionMode.Text; if (preferences.Data["windowBehavior"] == null) preferences.Data["windowBehavior"] = behavior; preferences.Save(); }
        panelFocus.CheckedChanged += (_, _) => Behavior(); panelTop.CheckedChanged += (_, _) => Behavior(); questionMode.SelectedIndexChanged += (_, _) => Behavior();
        var titleSettings = TitleSettings.Load(config.StateDirectory);
        AddLabel(page, "标题模型", 0, 320, 170, 30); var model = AddInput(page, titleSettings.Model, 180, 320, 310);
        AddButton(page, "保存", 510, 316, 100, () => { titleSettings.Model = model.Text.Trim(); Json.Write(Path.Combine(config.StateDirectory, "dotnet-title.local.json"), titleSettings); feedback.Text = "标题模型已保存"; });
        AddLabel(page, "凭据来源", 0, 375, 170, 30); var variable = AddInput(page, titleSettings.CredentialFiles.Keys.FirstOrDefault() ?? "", 180, 375, 220); variable.PlaceholderText = "渠道 env_key 名称";
        AddButton(page, "选择 DPAPI 文件", 420, 370, 190, () =>
        {
            using var dialog = new OpenFileDialog { Filter = "加密凭据|*.dpapi", CheckFileExists = true };
            if (dialog.ShowDialog(this) != DialogResult.OK) return;
            titleSettings.CredentialFiles[variable.Text.Trim()] = dialog.FileName; Json.Write(Path.Combine(config.StateDirectory, "dotnet-title.local.json"), titleSettings); feedback.Text = "已登记加密凭据文件；没有复制明文密钥";
        });
        AddLabel(page, "标题默认沿用 API 环境的地址与请求头，模型可单独设置。", 0, 430, 660, 45);
        var auto = new QuietSwitch { Text = "登录 Windows 时启动控制器", Enabled = !args.Contains("--trial") }; auto.SetBounds(0, 480, 480, 34); page.Controls.Add(auto);
        string startupName = "CodexDualController." + Paths.Hash(RuntimePaths.ConfigPath.ToLowerInvariant()).ToUpperInvariant()[..16];
        using (var key = Registry.CurrentUser.OpenSubKey(@"Software\Microsoft\Windows\CurrentVersion\Run")) auto.Checked = key?.GetValue(startupName) is string;
        auto.CheckedChanged += (_, _) =>
        {
            if (!auto.Enabled) return;
            using var key = Registry.CurrentUser.CreateSubKey(@"Software\Microsoft\Windows\CurrentVersion\Run");
            if (auto.Checked) key.SetValue(startupName, "\"" + Environment.ProcessPath + "\" --background --config \"" + RuntimePaths.ConfigPath + "\""); else key.DeleteValue(startupName, false);
        };
    }
    private void BuildApi(Panel page)
    {
        AddLabel(page, "API 渠道与配置", 0, 0, 660, 35).Font = new Font(Font.FontFamily, 15, FontStyle.Bold);
        string management;
        try { management = ApiProfiles.Mode(config.Api); } catch { management = "unavailable"; }
        if (management != "builtin")
        {
            AddLabel(page, management == "external" ? "此环境使用已有外部启动器，渠道由原管理工具维护。" : "此环境由 CC Switch 管理。", 0, 60, 650, 60);
            AddButton(page, "打开 API 配置", 0, 150, 180, () => { var info = new ProcessStartInfo("notepad.exe") { UseShellExecute = false }; info.ArgumentList.Add(Path.Combine(config.Api.Home, "config.toml")); Process.Start(info); });
            AddButton(page, "打开环境目录", 200, 150, 180, () => OpenFolder(config.Api.Home));
            AddButton(page, "选择并打开 CC Switch", 0, 210, 240, () =>
            {
                using var picker = new OpenFileDialog { Filter = "CC Switch|*.exe", CheckFileExists = true };
                string path = preferences.Data["ccsExecutable"]?.GetValue<string>() ?? "";
                if (!File.Exists(path)) { if (picker.ShowDialog(this) != DialogResult.OK) return; path = picker.FileName; preferences.Data["ccsExecutable"] = path; preferences.Save(); }
                var info = ProcessManager.CleanStart(path, config.Api); info.Environment.Remove("CODEX_HOME"); info.Environment.Remove("CODEX_ELECTRON_USER_DATA_PATH"); info.WorkingDirectory = Path.GetDirectoryName(path)!; Native.StartDetached(info);
            });
            return;
        }
        var list = new QuietListBox(); list.SetBounds(0, 55, 670, 160); page.Controls.Add(list); ProfileList? profiles = null;
        void Reload() { try { profiles = ApiProfiles.Read(config.Api); list.Items.Clear(); foreach (var item in profiles.Profiles) list.Items.Add(item); } catch (Exception e) { feedback.Text = e.Message; } }
        AddButton(page, "新增", 0, 235, 100, () => Edit(null));
        AddButton(page, "编辑", 120, 235, 100, () => { if (list.SelectedItem is ApiProfile item) Edit(item); });
        AddButton(page, "应用", 240, 235, 100, () => { if (list.SelectedItem is ApiProfile item) RunUi(async () => { feedback.Text = await Task.Run(() => ApiProfiles.Apply(config, config.Api, item.Id, processes)); Reload(); }); });
        AddButton(page, "删除", 360, 235, 100, () => { if (list.SelectedItem is ApiProfile item && MessageBox.Show(this, "删除渠道“" + item.Name + "”？", "删除渠道", MessageBoxButtons.OKCancel) == DialogResult.OK) RunUi(() => { ApiProfiles.Remove(config.Api, item.Id); Reload(); return Task.CompletedTask; }); });
        AddButton(page, "备份配置", 0, 300, 150, () => RunUi(() => { ApiProfiles.Backup(config.Api, "手动备份"); feedback.Text = "配置已加密备份"; return Task.CompletedTask; }));
        AddButton(page, "恢复配置…", 170, 300, 150, () =>
        {
            using var picker = new OpenFileDialog { InitialDirectory = Path.Combine(config.Api.ApiRoot, "Backup"), Filter = "配置快照|snapshot-*.local.json" };
            if (picker.ShowDialog(this) == DialogResult.OK) RunUi(async () => { await Task.Run(() => ApiProfiles.Restore(config.Api, picker.FileName, processes)); Reload(); feedback.Text = "配置已恢复"; });
        });
        AddLabel(page, "运行期间应用渠道会暂存，等待 API 环境下次启动。", 0, 365, 660, 55);
        void Edit(ApiProfile? item)
        {
            using var dialog = new ShellForm { Text = item == null ? "新增 API 渠道" : "编辑 API 渠道", Font = Font, ClientSize = new Size(580, 340), StartPosition = FormStartPosition.CenterParent };
            string[] labels = ["名称", "API 地址", "模型", "密钥（留空保留）"]; var boxes = new List<TextBox>(); string[] values = [item?.Name ?? "", item?.BaseUrl ?? "", item?.Model ?? "", ""];
            for (int n = 0; n < labels.Length; n++) { AddLabel(dialog, labels[n], 16, 25 + n * 60, 150, 30); boxes.Add(AddInput(dialog, values[n], 180, 25 + n * 60, 370, n == 3)); }
            AddButton(dialog, "保存", 420, 275, 130, () => { try { ApiProfiles.Save(config.Api, item?.Id, boxes[0].Text, boxes[1].Text, boxes[2].Text, boxes[3].Text); boxes[3].Clear(); dialog.DialogResult = DialogResult.OK; } catch (Exception e) { MessageBox.Show(dialog, e.Message); } });
            AppTheme.ApplyTo(dialog); if (dialog.ShowDialog(this) == DialogResult.OK) Reload();
        }
        Reload();
    }
}
