using System.Text.Json;
using System.Text.Json.Nodes;

namespace CodexDual.App;

public sealed partial class MainWindow
{
    private QuestionBridgeClient? questionClient;
    private BridgeBinding? questionBinding;
    private QuestionWindow? questionWindow, previewWindow;
    private List<JsonElement> pendingQuestions = [];
    private readonly HashSet<string> seenQuestions = [];
    private Task? questionLoop;
    private DateTime nextQuestionPoll;
    private string? returnThread;
    private string? returnToken;
    private void StartQuestions()
    {
        questionLoop = Task.Run(async () =>
        {
            var nextBinding = DateTime.MinValue;
            try
            {
                while (!lifetime.IsCancellationRequested)
                {
                    if (DateTime.UtcNow >= nextBinding)
                    {
                        nextBinding = DateTime.UtcNow.AddSeconds(15);
                        try
                        {
                            var binding = BridgeValidation.Read(config);
                            Post(() =>
                            {
                                if (pendingQuestions.Count > 0 || questionWindow?.HasUnresolvedDraft == true || questionClient?.Busy == true || questionClient?.HasPendingResults == true || returnThread != null) return;
                                if (binding?.Root == questionBinding?.Root) return;
                                questionClient?.Dispose(); questionBinding = binding;
                                questionClient = binding == null ? null : new(binding.Pipe, binding.Proxy, binding.InstanceId, binding.Disabled);
                            });
                            if (binding == null) health.Set("questions", "native", "未连接提问桥接，可在 Codex 中作答");
                        }
                        catch { health.Set("questions", "native", "提问桥接与当前运行环境不匹配，可在 Codex 中作答"); }
                    }
                    Post(UpdateQuestions);
                    await Task.Delay(200, lifetime.Token);
                }
            }
            catch (OperationCanceledException) { }
        });
    }
    private void UpdateQuestions()
    {
        if (questionClient == null || questionBinding == null) return;
        if (File.Exists(questionBinding.Disabled)) { questionWindow?.InvalidateRequest("提问桥接已停用，请在 Codex 中作答。"); return; }
        while (questionClient.Take() is { } reply)
        {
            if (!string.IsNullOrEmpty(reply.Error)) { questionWindow?.InvalidateRequest("连接暂时不可用，请等待同步；不会自动重复提交。"); health.Set("questions", "retrying", "提问连接暂时不可用"); continue; }
            try
            {
                using var doc = JsonDocument.Parse(reply.Json); var response = doc.RootElement;
                if (reply.Kind is "answer" or "release")
                {
                    if (response.Flag("ok"))
                    {
                        pendingQuestions.RemoveAll(p => p.Text("requestToken") == reply.Token);
                        if (questionWindow?.RequestToken == reply.Token) questionWindow.ResolveRequest();
                        if (reply.Kind == "release" && returnToken == reply.Token && returnThread != null) { string thread = returnThread; returnThread = returnToken = null; RunUi(() => OpenInstance(config.Api, thread)); }
                        nextQuestionPoll = DateTime.MinValue;
                    }
                    else if (questionWindow?.RequestToken == reply.Token) questionWindow.InvalidateRequest("提交结果未确认，等待同步；不会自动重复提交。");
                    continue;
                }
                if (!response.Flag("ok") || response.Text("instanceId") != questionBinding.InstanceId) { health.Set("questions", "retrying", "提问状态身份不匹配"); continue; }
                var incoming = response.GetProperty("pending").EnumerateArray().Select(p => p.Clone()).ToList();
                if (questionWindow is { HasUnresolvedDraft: true } window)
                {
                    var current = incoming.FirstOrDefault(p => p.Text("requestToken") == window.RequestToken);
                    bool confirmed = response.TryGetProperty("confirmedConnections", out var connections) ? connections.EnumerateArray().Any(c => c.GetString() == window.RequestConnectionId) : !response.TryGetProperty("unavailableConnections", out var failures) || failures.GetInt32() == 0;
                    if (current.ValueKind == JsonValueKind.Undefined && confirmed) window.ResolveRequest();
                    else if (current.ValueKind != JsonValueKind.Undefined && current.Flag("outcomeUnknown")) window.InvalidateRequest("上次提交结果未确认，等待同步。");
                    else if (current.ValueKind != JsonValueKind.Undefined && current.Text("delivery") != "exclusive" && ApiForeground()) window.ResolveRequest();
                    else if (current.ValueKind != JsonValueKind.Undefined && !window.IsRequestValid) window.SetRequestJson(current.GetRawText());
                }
                pendingQuestions = incoming;
                health.Set("questions", "ready", pendingQuestions.Count == 0 ? "提问服务已连接" : $"有 {pendingQuestions.Count} 个待处理问题");
                foreach (var request in pendingQuestions)
                {
                    string token = request.Text("requestToken");
                    if (token.Length == 0 || !seenQuestions.Add(token) || ApiForeground() || Snoozed() || notificationSettings["enabled"]?.GetValue<bool>() == false) continue;
                    string mode = preferences.Behavior("questionMode", "notice");
                    if (mode != "notice" && (questionWindow == null || !questionWindow.Visible)) ShowQuestion(token, mode == "focus");
                    else ShowNotice(request.TryGetProperty("questions", out var q) && q.GetArrayLength() > 0 ? q[0].Text("question") : "需要你回答", "待回答", () => ShowQuestion(token, true));
                }
            }
            catch (Exception e) when (e is JsonException or InvalidOperationException or KeyNotFoundException) { health.Set("questions", "failed", "提问服务响应不兼容，可在 Codex 中作答"); }
        }
        if (DateTime.UtcNow >= nextQuestionPoll && !questionClient.Busy) { nextQuestionPoll = DateTime.UtcNow.AddMilliseconds(900); questionClient.StartSnapshot(!ApiForeground()); }
    }
    private bool ApiForeground()
    {
        try { var status = processes.Status(config.Api); return status.Process != null && Native.IsInstanceForeground(status.Process.Path, config.Api.Home, config.Api.Profile); } catch { return false; }
    }
    private void ShowPending()
    {
        if (pendingQuestions.Count == 0) { feedback.Text = "暂无已连接的待处理问题；原生问题可在 Codex 中作答。"; return; }
        ShowQuestion(pendingQuestions[0].Text("requestToken"), true);
    }
    private void ShowQuestion(string token, bool focus)
    {
        var request = pendingQuestions.FirstOrDefault(p => p.Text("requestToken") == token);
        if (request.ValueKind == JsonValueKind.Undefined) { feedback.Text = "问题已失效，请刷新。"; return; }
        if (questionWindow == null || questionWindow.IsDisposed)
        {
            questionWindow = new();
            questionWindow.SubmitRequested += (_, _) =>
            {
                if (questionClient == null || !pendingQuestions.Any(p => p.Text("requestToken") == questionWindow.RequestToken)) { questionWindow.InvalidateRequest("问题已变化，请等待同步。"); return; }
                if (questionClient.StartAnswer(questionWindow.AnswerJson, questionWindow.RequestToken)) questionWindow.SetSubmissionState(true, "正在提交…");
                else questionWindow.SetSubmissionState(false, "正在同步问题，请稍后提交。");
            };
            questionWindow.ReturnRequested += (_, _) =>
            {
                var current = pendingQuestions.FirstOrDefault(p => p.Text("requestToken") == questionWindow.RequestToken);
                if (current.ValueKind == JsonValueKind.Undefined || !CompletionReader.IsUuid(current.Text("threadId"))) { questionWindow.InvalidateRequest("问题入口已变化。"); return; }
                if (current.Flag("outcomeUnknown")) { questionWindow.InvalidateRequest("提交结果尚未确认，请等待同步。"); return; }
                if (current.Text("delivery") == "exclusive")
                {
                    string command = JsonSerializer.Serialize(new { command = "release", connectionId = current.Text("connectionId"), requestToken = current.Text("requestToken"), requestId = current.GetProperty("requestId").Clone(), threadId = current.Text("threadId"), turnId = current.Text("turnId") });
                    if (questionClient?.StartRelease(command, questionWindow.RequestToken) == true) { returnThread = current.Text("threadId"); returnToken = questionWindow.RequestToken; questionWindow.SetSubmissionState(true, "正在恢复原生作答…"); }
                }
                else { string thread = current.Text("threadId"); RunUi(() => OpenInstance(config.Api, thread)); questionWindow.Hide(); }
            };
        }
        questionWindow.SetRequestJson(request.GetRawText());
        if (request.Flag("outcomeUnknown")) questionWindow.InvalidateRequest("提交结果尚未确认，正在同步。");
        questionWindow.ApplyAppearance(); questionWindow.PlaceNearNotifications(Screen.FromPoint(Cursor.Position).WorkingArea); questionWindow.Present(focus, preferences.Overlay("questionOverlay", true));
    }
    private void PreviewQuestion()
    {
        if (previewWindow == null || previewWindow.IsDisposed)
        {
            previewWindow = new(); previewWindow.SetRequestJson(File.ReadAllText(Path.Combine(AppContext.BaseDirectory, "config/question-preview.json")));
            previewWindow.SubmitRequested += (_, _) => previewWindow.SetSubmissionState(false, "这是界面预览，答案未发送。");
            previewWindow.ReturnRequested += (_, _) => previewWindow.SetSubmissionState(false, "这是界面预览，没有关联真实任务。");
        }
        previewWindow.ApplyAppearance(); previewWindow.Present(true, true);
    }
    private async Task StopQuestions()
    {
        if (questionLoop != null) await questionLoop;
        questionClient?.Dispose(); questionWindow?.Dispose(); previewWindow?.Dispose();
    }
}
