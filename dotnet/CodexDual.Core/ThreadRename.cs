using System.Diagnostics;
using System.Text;
using System.Text.Json;

namespace CodexDual.Core;

public static class ThreadRename
{
    public static string FindCli(InstanceConfig instance, ProcessIdentity desktop, ControllerConfig? config = null)
    {
        if (!ProcessManager.Valid(instance, desktop)) throw new IOException("API 实例身份变化。");
        var parents = ProcessTree.Parents(); var candidates = new List<string>();
        foreach (var pair in parents.Where(p => p.Value == desktop.Id))
        {
            try
            {
                using var child = Process.GetProcessById(pair.Key); string path = child.MainModule!.FileName!;
                if (Path.GetFileName(path).Equals("codex.exe", StringComparison.OrdinalIgnoreCase) && child.StartTime.ToUniversalTime().Ticks >= desktop.Started && Paths.Same(Native.CodexHome(child.Id), instance.Home)) candidates.Add(path);
            }
            catch (Exception e) when (e is ArgumentException or InvalidOperationException or System.ComponentModel.Win32Exception) { }
        }
        if (candidates.Count == 0 && config != null)
        {
            var binding = BridgeValidation.Read(config);
            if (binding != null)
            {
                using var descriptor = Json.Read<JsonDocument>(Path.Combine(binding.Root, "bridge.config.json"), 65536);
                string expectedCli = descriptor.RootElement.Text("realCli");
                foreach (var proxyId in parents.Where(p => p.Value == desktop.Id).Select(p => p.Key))
                {
                    try
                    {
                        using var proxy = Process.GetProcessById(proxyId);
                        if (!Paths.Same(proxy.MainModule?.FileName, binding.Proxy) || proxy.StartTime.ToUniversalTime().Ticks < desktop.Started) continue;
                        foreach (var childId in parents.Where(p => p.Value == proxyId).Select(p => p.Key))
                        {
                            using var child = Process.GetProcessById(childId);
                            if (Paths.Same(child.MainModule?.FileName, expectedCli) && child.StartTime >= proxy.StartTime && Paths.Same(Native.CodexHome(child.Id), instance.Home)) candidates.Add(expectedCli);
                        }
                    }
                    catch (Exception e) when (e is ArgumentException or InvalidOperationException or System.ComponentModel.Win32Exception) { }
                }
            }
        }
        if (candidates.Distinct(StringComparer.OrdinalIgnoreCase).Count() != 1) throw new IOException("没有唯一可验证的原生 CLI；请在 Codex 原生窗口保存标题。");
        return candidates[0];
    }
    public static async Task RenameAsync(string cli, InstanceConfig instance, string threadId, string expectedTitle, string newTitle, CancellationToken cancel)
    {
        if (!CompletionReader.IsUuid(threadId) || string.IsNullOrWhiteSpace(newTitle) || newTitle.Length > 200 || newTitle.Any(char.IsControl)) throw new InvalidDataException("聊天标题或标识无效。");
        Paths.Regular(cli);
        var info = ProcessManager.CleanStart(cli, instance); info.Arguments = "app-server --listen stdio://";
        info.RedirectStandardInput = info.RedirectStandardOutput = info.RedirectStandardError = true; info.StandardInputEncoding = new UTF8Encoding(false); info.StandardOutputEncoding = new UTF8Encoding(false);
        using var process = Process.Start(info) ?? throw new IOException("无法启动原生标题保存接口。");
        using var timeout = CancellationTokenSource.CreateLinkedTokenSource(cancel); timeout.CancelAfter(TimeSpan.FromSeconds(15));
        var stderr = process.StandardError.BaseStream.CopyToAsync(Stream.Null, timeout.Token);
        int sequence = 0;
        async Task<JsonElement> Call(string method, object parameters)
        {
            int id = ++sequence;
            await process.StandardInput.WriteLineAsync(JsonSerializer.Serialize(new { id, method, @params = parameters }).AsMemory(), timeout.Token); await process.StandardInput.FlushAsync(timeout.Token);
            while (true)
            {
                string? line = await process.StandardOutput.ReadLineAsync(timeout.Token);
                if (line == null || line.Length > 1024 * 1024) throw new IOException("原生保存接口断开或响应过大。");
                using var doc = JsonDocument.Parse(line); var message = doc.RootElement;
                if (!message.TryGetProperty("id", out var responseId) || responseId.ValueKind != JsonValueKind.Number || responseId.GetInt32() != id) continue;
                if (message.TryGetProperty("error", out _)) throw new IOException("当前 Codex 不支持此标题操作；请使用原生重命名保存。");
                return message.GetProperty("result").Clone();
            }
        }
        try
        {
            await Call("initialize", new { clientInfo = new { name = "codex_dual_title", version = "0.9.0" }, capabilities = new { experimentalApi = true } });
            await process.StandardInput.WriteLineAsync("{\"method\":\"initialized\",\"params\":{}}".AsMemory(), timeout.Token); await process.StandardInput.FlushAsync(timeout.Token);
            var before = await Call("thread/read", new { threadId }); string actual = before.GetProperty("thread").Text("name");
            if (actual != expectedTitle) throw new IOException("聊天标题已在其他入口变化，请刷新列表后再保存。");
            await Call("thread/name/set", new { threadId, name = newTitle.Trim() });
            var after = await Call("thread/read", new { threadId });
            if (after.GetProperty("thread").Text("name") != newTitle.Trim()) throw new IOException("未确认标题写回，请刷新查看，不要重复提交。");
        }
        finally
        {
            process.StandardInput.Close();
            try { await process.WaitForExitAsync().WaitAsync(TimeSpan.FromSeconds(2)); } catch (TimeoutException) { if (!process.HasExited) process.Kill(); }
            try { await stderr; } catch (OperationCanceledException) { }
        }
    }
}
