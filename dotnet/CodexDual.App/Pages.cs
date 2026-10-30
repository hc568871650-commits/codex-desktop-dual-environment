using System.Diagnostics;
using System.Text.Json;
using System.Text.Json.Nodes;
using Microsoft.Win32;

namespace CodexDual.App;

public sealed partial class MainWindow
{
    private readonly ModernList chats = new();
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
        PageTitle(page, "标题工具");
        AddHeaderButton(page, "返回高级", 140, () => SelectPage("诊断")).Quiet = true;
        var listFrame = new SoftSurface(); listFrame.SetBounds(0, 88, 770, 268); page.Controls.Add(listFrame);
        chats.SetBounds(10, 12, 750, 244); chats.Anchor = AnchorStyles.Top | AnchorStyles.Bottom | AnchorStyles.Left | AnchorStyles.Right; listFrame.Controls.Add(chats);
        chats.SelectedIndexChanged += (_, _) =>
        {
            titleCancellation?.Cancel(); editEpoch++;
            editingSuggestion = true; titleText.Text = chats.SelectedIndex >= 0 && chats.SelectedIndex < chatItems.Count ? chatItems[chats.SelectedIndex].Title : ""; editingSuggestion = false;
            generationStatus.Text = "";
        };
        AddButton(page, "生成建议", 0, 376, 150, () => TrackGeneration(false)).Primary = true;
        AddButton(page, "换一个", 166, 376, 120, () => TrackGeneration(true)).Quiet = true;
        AddButton(page, "打开聊天", 302, 376, 140, () => { if (SelectedChat() is { } c) RunUi(() => OpenInstance(config.Api, c.Id)); }).Quiet = true;
        AddButton(page, "刷新", 658, 376, 112, () => _ = RefreshThreads()).Quiet = true;
        titleText.MaxLength = 200; titleText.AccessibleName = "聊天标题"; PlaceInput(page, titleText, 0, 448, 770);
        titleText.TextChanged += (_, _) => { if (!editingSuggestion) { editEpoch++; titleCancellation?.Cancel(); generationStatus.Text = "已保留手动输入"; } };
        AddButton(page, "保存", 0, 516, 120, () => RunUi(SaveTitle));
        AddButton(page, "复制", 136, 516, 120, () => { if (titleText.Text.Length > 0) { Clipboard.SetText(titleText.Text); generationStatus.Text = "已复制"; } }).Quiet = true;
        generationStatus.SetBounds(0, 580, 770, 32); generationStatus.Name = "Muted"; page.Controls.Add(generationStatus);
    }
    private ChatInfo? SelectedChat() => chats.SelectedIndex >= 0 && chats.SelectedIndex < chatItems.Count ? chatItems[chats.SelectedIndex] : null;
    private async Task RefreshThreads()
    {
        if (closed) return;
        string? selected = SelectedChat()?.Id; int epoch = ++refreshEpoch; int edits = editEpoch;
        try
        {
            List<ChatInfo> incoming;
            if (args.Contains("--smoke-ui")) incoming = [new(Guid.NewGuid().ToString(), "改进双环境性能与标题建议", ""), new(Guid.NewGuid().ToString(), "一条很长的聊天标题：整理开发计划、交互设计、环境设置与验收记录，检查单行省略显示是否正确\n这是第二行，不应该覆盖下一项", ""), new(Guid.NewGuid().ToString(), "整理项目资料与开发计划", ""), new(Guid.NewGuid().ToString(), "优化消息提醒", ""), new(Guid.NewGuid().ToString(), "检查环境设置", ""), new(Guid.NewGuid().ToString(), "完成日常开发", "")];
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
            editingSuggestion = true; titleText.Text = result.Title; editingSuggestion = false; generationStatus.Text = "建议已生成";
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
        generationStatus.Text = "已保存"; await RefreshThreads();
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
        PageTitle(page, "通知");
        AddHeaderButton(page, "预览", 120, () => ShowNotice("完成提醒预览", "已完成", () => { }, true)).Quiet = true;
        var enabled = new ModernToggle { Text = "完成提醒", Checked = notificationSettings["enabled"]?.GetValue<bool>() != false }; enabled.SetBounds(0, 88, 770, 48); page.Controls.Add(enabled);
        enabled.CheckedChanged += (_, _) => RunUi(async () => { notificationSettings["enabled"] = enabled.Checked; SaveNotificationSettings(); if (enabled.Checked) StartMonitor(); else if (monitor != null) { await monitor.DisposeAsync(); monitor = null; notice?.Close(); } });
        Divider(page, 145); Divider(page, 213); Divider(page, 292);
        AddLabel(page, "显示时长", 0, 156, 300, 46);
        var seconds = new DurationPicker { Value = notificationSettings["displaySeconds"]?.GetValue<int>() ?? 15 }; seconds.SetBounds(530, 156, 240, 46); page.Controls.Add(seconds);
        var fade = new ModernToggle { Text = "淡入淡出", Checked = notificationSettings["fadeEnabled"]?.GetValue<bool>() ?? false }; fade.SetBounds(0, 224, 770, 48); page.Controls.Add(fade);
        seconds.ValueChanged += (_, _) => { notificationSettings["displaySeconds"] = (int)seconds.Value; SaveNotificationSettings(); };
        fade.CheckedChanged += (_, _) => { notificationSettings["fadeEnabled"] = fade.Checked; SaveNotificationSettings(); };
        AddLabel(page, "最近完成", 0, 318, 300, 38);
        QuietButton? snooze = null; snooze = AddButton(page, Snoozed() ? "恢复提醒" : "暂停 15 分钟", 590, 312, 180, () => { bool paused = Snoozed(); notificationSettings["snoozedUntilUtc"] = paused ? "" : DateTimeOffset.UtcNow.AddMinutes(15).ToString("o"); SaveNotificationSettings(); if (!paused) notice?.Close(); snooze!.Text = paused ? "暂停 15 分钟" : "恢复提醒"; }); snooze.Quiet = true;
        var listFrame = new SoftSurface(); listFrame.SetBounds(0, 376, 770, 164); page.Controls.Add(listFrame); recent.SetBounds(10, 10, 750, 144); listFrame.Controls.Add(recent);
        if (args.Contains("--smoke-ui")) { recent.Items.Add("整理项目资料"); recent.Items.Add("完成界面调整"); }
        recent.DoubleClick += (_, _) => { if (recent.SelectedIndex >= 0 && recent.SelectedIndex < history.Count) RunUi(() => OpenInstance(config.Api, history[recent.SelectedIndex].ThreadId)); };
        AddButton(page, "待处理问题", 0, 564, 170, ShowPending);
        AddButton(page, "提问预览", 188, 564, 150, PreviewQuestion).Quiet = true;
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
        var card = notice = new CompletionCard { Text = summary, ClientSize = new Size(460, 164), ShowInTaskbar = false, TopMost = true, Font = Font, StartPosition = FormStartPosition.Manual };
        AddLabel(card, summary, 20, 12, 374, 28).Name = "Muted";
        var body = new NoticeBody { Text = text, AccessibleName = "打开：" + text }; body.SetBounds(8, 44, 444, 110); body.Click += (_, _) => { card.Close(); if (!preview) click(); }; card.Controls.Add(body);
        var dismiss = AddButton(card, "×", 410, 8, 40, card.Close); dismiss.Quiet = true; dismiss.Height = 36;
        card.SetDisplaySettings((notificationSettings["displaySeconds"]?.GetValue<int>() ?? 15) * 1000, notificationSettings["fadeEnabled"]?.GetValue<bool>() ?? false);
        var area = Screen.FromPoint(Cursor.Position).WorkingArea; card.Location = new Point(area.Right - card.Width - 20, area.Bottom - card.Height - 20); AppTheme.ApplyTo(card); card.Show();
    }
    private void BuildPreferences(Panel page)
    {
        PageTitle(page, "设置");
        AddLabel(page, "主题", 0, 88, 320, 46); var mode = new ChoicePicker(("dark", "深色"), ("light", "浅色"), ("system", "跟随系统")) { Value = preferences.Mode, AccessibleName = "主题" }; mode.SetBounds(530, 88, 240, 46); page.Controls.Add(mode);
        AddLabel(page, "强调色", 0, 156, 320, 46); var accent = new ChoicePicker(("neutral", "中性"), ("blue", "蓝色"), ("green", "绿色"), ("purple", "紫色")) { Value = preferences.Accent, AccessibleName = "强调色" }; accent.SetBounds(530, 156, 240, 46); page.Controls.Add(accent);
        void Appearance() { preferences.Data["appearance"] = new JsonObject { ["mode"] = mode.Value, ["accent"] = accent.Value }; preferences.Save(); AppTheme.SetAppearance(mode.Value, accent.Value); ApplyTheme(); }
        mode.ValueChanged += (_, _) => Appearance(); accent.ValueChanged += (_, _) => Appearance();
        foreach (int y in new[] { 145, 220, 295, 363, 438, 522 }) Divider(page, y);
        var panelFocus = new ModernToggle { Text = "打开时聚焦", Checked = preferences.Behavior("panelMode", "focus") == "focus" }; panelFocus.SetBounds(0, 238, 770, 48); page.Controls.Add(panelFocus);
        var panelTop = new ModernToggle { Text = "窗口置顶", Checked = preferences.Overlay("panelOverlay", false) }; panelTop.SetBounds(0, 306, 770, 48); page.Controls.Add(panelTop);
        AddLabel(page, "后台提问", 0, 374, 320, 46); var questionMode = new ChoicePicker(("notice", "通知提醒"), ("passive", "浮窗 · 不抢焦点"), ("focus", "浮窗 · 自动聚焦")) { Value = preferences.Behavior("questionMode", "notice"), AccessibleName = "后台提问方式" }; questionMode.SetBounds(530, 374, 240, 46); page.Controls.Add(questionMode);
        void Behavior() { var behavior = preferences.Data["windowBehavior"] as JsonObject ?? new JsonObject(); behavior["panelMode"] = panelFocus.Checked ? "focus" : "passive"; behavior["panelOverlay"] = panelTop.Checked; behavior["questionMode"] = questionMode.Value; if (preferences.Data["windowBehavior"] == null) preferences.Data["windowBehavior"] = behavior; preferences.Save(); }
        panelFocus.CheckedChanged += (_, _) => Behavior(); panelTop.CheckedChanged += (_, _) => Behavior(); questionMode.ValueChanged += (_, _) => Behavior();
        var titleSettings = TitleSettings.Load(config.StateDirectory);
        AddLabel(page, "标题模型", 0, 456, 300, 46); var model = AddInput(page, titleSettings.Model, 390, 456, 260);
        AddButton(page, "保存", 666, 456, 104, () => { titleSettings.Model = model.Text.Trim(); Json.Write(Path.Combine(config.StateDirectory, "dotnet-title.local.json"), titleSettings); feedback.Text = "已保存"; });
        var auto = new ModernToggle { Text = "开机启动", Enabled = !args.Contains("--trial") }; auto.SetBounds(0, 540, 770, 48); page.Controls.Add(auto);
        string startupName = "CodexDualController." + Paths.Hash(RuntimePaths.ConfigPath.ToLowerInvariant()).ToUpperInvariant()[..16];
        using (var key = Registry.CurrentUser.OpenSubKey(@"Software\Microsoft\Windows\CurrentVersion\Run")) auto.Checked = key?.GetValue(startupName) is string;
        auto.CheckedChanged += (_, _) =>
        {
            if (!auto.Enabled) return;
            using var key = Registry.CurrentUser.CreateSubKey(@"Software\Microsoft\Windows\CurrentVersion\Run");
            if (auto.Checked) key.SetValue(startupName, "\"" + Environment.ProcessPath + "\" --background --config \"" + RuntimePaths.ConfigPath + "\""); else key.DeleteValue(startupName, false);
        };
    }
    private void BuildAdvanced(Panel page)
    {
        PageTitle(page, "高级");
        AddButton(page, "重新检查", 0, 88, 150, () => RunUi(RefreshStatus));
        AddButton(page, "打开日志", 166, 88, 150, () => OpenFolder(config.StateDirectory)).Quiet = true;
        AddButton(page, "标题工具", 332, 88, 150, () => SelectPage("标题建议")).Quiet = true;
        AddButton(page, "凭据设置", 498, 88, 150, OpenCredentialSettings).Quiet = true;
        diagnostics.SetBounds(0, 168, 770, 440); diagnostics.Name = "Muted"; diagnostics.Font = new Font(Font.FontFamily, 10.5f); pages["诊断"].Controls.Add(diagnostics);
    }
    private void OpenCredentialSettings()
    {
        var settings = TitleSettings.Load(config.StateDirectory);
        using var dialog = new ShellForm { Text = "标题凭据", Font = Font, ClientSize = new Size(660, 230), StartPosition = FormStartPosition.CenterParent };
        AddLabel(dialog, "环境变量", 28, 32, 180, 48); var variable = AddInput(dialog, settings.CredentialFiles.Keys.FirstOrDefault() ?? "", 210, 32, 418); variable.PlaceholderText = "env_key";
        AddButton(dialog, "选择凭据文件", 210, 116, 206, () =>
        {
            using var picker = new OpenFileDialog { Filter = "加密凭据|*.dpapi", CheckFileExists = true };
            if (picker.ShowDialog(dialog) != DialogResult.OK) return;
            settings.CredentialFiles[variable.Text.Trim()] = picker.FileName; Json.Write(Path.Combine(config.StateDirectory, "dotnet-title.local.json"), settings); feedback.Text = "已保存"; dialog.Close();
        });
        AppTheme.ApplyTo(dialog); ModernStyle.Apply(dialog); dialog.ShowDialog(this);
    }
    private void BuildApi(Panel page)
    {
        PageTitle(page, "连接");
        string management;
        try { management = ApiProfiles.Mode(config.Api); } catch { management = "unavailable"; }
        if (management != "builtin")
        {
            AddLabel(page, "API 渠道", 0, 96, 400, 36);
            AddLabel(page, management == "external" ? "外部管理" : "CC Switch", 530, 96, 240, 36).Name = "Muted";
            Divider(page, 146);
            AddButton(page, "配置文件", 0, 164, 170, () => { var info = new ProcessStartInfo("notepad.exe") { UseShellExecute = false }; info.ArgumentList.Add(Path.Combine(config.Api.Home, "config.toml")); Process.Start(info); });
            AddButton(page, "数据目录", 188, 164, 170, () => OpenFolder(config.Api.Home)).Quiet = true;
            AddButton(page, "打开 CC Switch", 0, 246, 220, () =>
            {
                using var picker = new OpenFileDialog { Filter = "CC Switch|*.exe", CheckFileExists = true };
                string path = preferences.Data["ccsExecutable"]?.GetValue<string>() ?? "";
                if (!File.Exists(path)) { if (picker.ShowDialog(this) != DialogResult.OK) return; path = picker.FileName; preferences.Data["ccsExecutable"] = path; preferences.Save(); }
                var info = ProcessManager.CleanStart(path, config.Api); info.Environment.Remove("CODEX_HOME"); info.Environment.Remove("CODEX_ELECTRON_USER_DATA_PATH"); info.WorkingDirectory = Path.GetDirectoryName(path)!; Native.StartDetached(info);
            });
            return;
        }
        var frame = new SoftSurface(); frame.SetBounds(0, 88, 770, 242); page.Controls.Add(frame);
        var list = new ModernList(); list.SetBounds(10, 10, 750, 222); frame.Controls.Add(list); ProfileList? profiles = null;
        void Reload() { try { profiles = ApiProfiles.Read(config.Api); list.Items.Clear(); foreach (var item in profiles.Profiles) list.Items.Add(item); } catch (Exception e) { feedback.Text = e.Message; } }
        AddButton(page, "新增", 0, 354, 120, () => Edit(null));
        AddButton(page, "编辑", 138, 354, 120, () => { if (list.SelectedItem is ApiProfile item) Edit(item); }).Quiet = true;
        AddButton(page, "应用", 276, 354, 120, () => { if (list.SelectedItem is ApiProfile item) RunUi(async () => { feedback.Text = await Task.Run(() => ApiProfiles.Apply(config, config.Api, item.Id, processes)); Reload(); }); }).Primary = true;
        AddButton(page, "删除", 650, 354, 120, () => { if (list.SelectedItem is ApiProfile item && MessageBox.Show(this, "删除渠道“" + item.Name + "”？", "删除渠道", MessageBoxButtons.OKCancel) == DialogResult.OK) RunUi(() => { ApiProfiles.Remove(config.Api, item.Id); Reload(); return Task.CompletedTask; }); }).Quiet = true;
        AddButton(page, "备份", 0, 442, 120, () => RunUi(() => { ApiProfiles.Backup(config.Api, "手动备份"); feedback.Text = "已备份"; return Task.CompletedTask; })).Quiet = true;
        AddButton(page, "恢复…", 138, 442, 120, () =>
        {
            using var picker = new OpenFileDialog { InitialDirectory = Path.Combine(config.Api.ApiRoot, "Backup"), Filter = "配置快照|snapshot-*.local.json" };
            if (picker.ShowDialog(this) == DialogResult.OK) RunUi(async () => { await Task.Run(() => ApiProfiles.Restore(config.Api, picker.FileName, processes)); Reload(); feedback.Text = "配置已恢复"; });
        }).Quiet = true;
        void Edit(ApiProfile? item)
        {
            using var dialog = new ShellForm { Text = item == null ? "新增渠道" : "编辑渠道", Font = Font, ClientSize = new Size(720, 410), StartPosition = FormStartPosition.CenterParent };
            string[] labels = ["名称", "API 地址", "模型", "密钥"]; var boxes = new List<TextBox>(); string[] values = [item?.Name ?? "", item?.BaseUrl ?? "", item?.Model ?? "", ""];
            for (int n = 0; n < labels.Length; n++) { AddLabel(dialog, labels[n], 28, 28 + n * 74, 150, 48); boxes.Add(AddInput(dialog, values[n], 190, 28 + n * 74, 500, n == 3)); }
            boxes[3].PlaceholderText = item == null ? "输入密钥" : "留空保留";
            AddButton(dialog, "保存", 550, 336, 140, () => { try { ApiProfiles.Save(config.Api, item?.Id, boxes[0].Text, boxes[1].Text, boxes[2].Text, boxes[3].Text); boxes[3].Clear(); dialog.DialogResult = DialogResult.OK; } catch (Exception e) { MessageBox.Show(dialog, e.Message); } }).Primary = true;
            AppTheme.ApplyTo(dialog); ModernStyle.Apply(dialog); if (dialog.ShowDialog(this) == DialogResult.OK) Reload();
        }
        Reload();
    }
}
