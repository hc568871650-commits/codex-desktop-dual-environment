using System.Collections.Concurrent;
using System.Net;
using System.Net.Sockets;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;

namespace CodexDual.Core;

public static class CliCompatibility
{
    private static readonly ConcurrentDictionary<string, byte> verified = new();
    private static readonly SemaphoreSlim gate = new(1);
    public static async Task EnsureAsync(string cli, string state, Func<TitleRoute, string, CancellationToken, Task<string>> invoke, CancellationToken cancel)
    {
        var info = new FileInfo(cli); string stamp = info.FullName + "|" + info.Length + "|" + info.LastWriteTimeUtc.Ticks;
        if (verified.ContainsKey(stamp)) return;
        await gate.WaitAsync(cancel);
        try
        {
            if (verified.ContainsKey(stamp)) return;
            string hash; using (var stream = File.OpenRead(cli)) hash = Convert.ToHexString(SHA256.HashData(stream));
            // Compatibility is checked again once per controller process, even if an old receipt exists.
            string root = Path.Combine(state, "title-probes"), home = Path.Combine(root, Guid.NewGuid().ToString("N")); Paths.Regular(root); Directory.CreateDirectory(home);
            using var stop = CancellationTokenSource.CreateLinkedTokenSource(cancel); stop.CancelAfter(TimeSpan.FromSeconds(25));
            var server = new TcpListener(IPAddress.Loopback, 0); server.Start();
            Task<string>? generation = null;
            try
            {
                int port = ((IPEndPoint)server.LocalEndpoint).Port;
                var route = new TitleRoute(new Uri($"http://127.0.0.1:{port}/v1/responses"), "gpt-6-luna", null, new() { ["x-title-offline-check"] = "offline-only" }, "offline");
                var capture = Capture(server, stop.Token);
                generation = invoke(route, home, stop.Token);
                var winner = await Task.WhenAny(capture, generation);
                if (winner == generation && !capture.IsCompleted) throw new IOException("当前官方 CLI 未通过离线兼容检查，未发送真实标题请求。");
                bool valid = await capture;
                if (!valid) throw new IOException("当前 CLI 的工具隔离或请求头检查失败，未发送真实标题请求。");
                try { await generation; } catch (IOException) { /* The loopback endpoint intentionally returns HTTP 400. */ }
                var after = new FileInfo(cli);
                if (after.Length != info.Length || after.LastWriteTimeUtc != info.LastWriteTimeUtc) throw new IOException("兼容检查期间 CLI 发生升级，请重试。");
                Json.Write(Path.Combine(state, "title-cli-compatibility.local.json"), new { schema = 1, passed = true, cli, sha256 = hash, toolCount = 0, environmentHeaderVerified = true, checkedAt = DateTimeOffset.UtcNow, offline = true });
                verified[stamp] = 0;
            }
            finally
            {
                stop.Cancel(); server.Stop();
                if (generation != null) try { await generation; } catch { }
                if (Paths.Inside(home, root)) Directory.Delete(home, true);
            }
        }
        finally { gate.Release(); }
    }
    private static async Task<bool> Capture(TcpListener server, CancellationToken cancel)
    {
        using var client = await server.AcceptTcpClientAsync(cancel); using var stream = client.GetStream();
        var header = new List<byte>(); var one = new byte[1];
        while (header.Count < 32768)
        {
            if (await stream.ReadAsync(one, cancel) != 1) throw new IOException("离线探针连接中断。"); header.Add(one[0]);
            int n = header.Count; if (n >= 4 && header[n - 4] == 13 && header[n - 3] == 10 && header[n - 2] == 13 && header[n - 1] == 10) break;
        }
        string[] lines = Encoding.ASCII.GetString(header.ToArray()).Split("\r\n");
        var headers = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
        foreach (var line in lines.Skip(1)) { int colon = line.IndexOf(':'); if (colon > 0) headers[line[..colon]] = line[(colon + 1)..].Trim(); }
        if (!lines[0].StartsWith("POST /v1/responses ") || !headers.TryGetValue("Content-Length", out var value) || !int.TryParse(value, out int length) || length is < 1 or > 1024 * 1024 || headers.ContainsKey("Content-Encoding")) throw new IOException("官方 CLI 的离线请求格式发生变化。");
        byte[] body = new byte[length]; await stream.ReadExactlyAsync(body, cancel);
        using var doc = JsonDocument.Parse(body);
        bool valid = headers.GetValueOrDefault("x-title-offline-check") == "offline-only" && (!doc.RootElement.TryGetProperty("tools", out var tools) || tools.ValueKind == JsonValueKind.Array && tools.GetArrayLength() == 0);
        byte[] error = Encoding.UTF8.GetBytes("{\"error\":{\"message\":\"offline compatibility probe complete\",\"type\":\"invalid_request_error\"}}");
        byte[] response = Encoding.ASCII.GetBytes($"HTTP/1.1 400 Bad Request\r\nContent-Type: application/json\r\nContent-Length: {error.Length}\r\nConnection: close\r\n\r\n");
        await stream.WriteAsync(response, cancel); await stream.WriteAsync(error, cancel); return valid;
    }
}
