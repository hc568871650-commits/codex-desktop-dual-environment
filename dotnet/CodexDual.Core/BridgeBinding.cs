using System.Security.Cryptography;
using System.Security.Principal;
using System.Text.Json;

namespace CodexDual.Core;

public sealed record BridgeBinding(string Root, string Pipe, string Proxy, string InstanceId, string Disabled);
public static class BridgeValidation
{
    private static void Hash(string file, string expected)
    {
        Paths.Regular(Paths.Full(file));
        using var stream = File.OpenRead(file);
        if (!string.Equals(Convert.ToHexString(SHA256.HashData(stream)), expected, StringComparison.OrdinalIgnoreCase)) throw new IOException("提问服务文件发生变化，保留原生作答。");
    }
    public static BridgeBinding? Read(ControllerConfig config)
    {
        string registration = Path.Combine(config.StateDirectory, "question-bridge.local.json");
        if (!File.Exists(registration)) return null;
        using var rdoc = Json.Read<JsonDocument>(registration, 8192); var r = rdoc.RootElement;
        if (r.GetProperty("schema").GetInt32() != 1 || r.Text("instanceId") != config.Api.Id) throw new IOException("提问登记不属于 API 环境。");
        string root = Paths.Full(r.Text("directory")); Paths.Regular(root);
        if (File.Exists(Path.Combine(root, "DISABLED"))) return null;
        using var mdoc = Json.Read<JsonDocument>(Path.Combine(root, "binding.json"), 65536); var m = mdoc.RootElement;
        using var bdoc = Json.Read<JsonDocument>(Path.Combine(root, "bridge.config.json"), 65536); var b = bdoc.RootElement;
        if (m.GetProperty("schema").GetInt32() != 1 || m.Text("kind") != "api-question-bridge-installation" || m.Text("controllerInstanceId") != config.Api.Id || !Paths.Same(m.Text("root"), root) || !Paths.Same(m.Text("apiHome"), config.Api.Home) || !Paths.Same(m.Text("profile"), config.Api.Profile) || m.Text("userSid") != WindowsIdentity.GetCurrent().User!.Value) throw new IOException("提问服务身份校验失败。");
        string id = m.Text("id");
        if (!Guid.TryParseExact(id, "N", out _) || b.Text("instanceId") != "api-live-" + id || b.Text("pipeName") != "codex-api-questions-" + id || !b.Flag("takeoverQuestions") || !Paths.Same(b.Text("apiHome"), config.Api.Home) || !Paths.Same(b.Text("realCli"), m.Text("realCli"))) throw new IOException("提问服务配置不一致。");
        string proxy = Path.Combine(root, "BridgeProxy.exe");
        Hash(Path.Combine(root, "bridge.config.json"), m.Text("configHash")); Hash(proxy, m.Text("proxyHash")); Hash(m.Text("realCli"), m.Text("realCliHash")); Hash(m.Text("desktopExe"), m.Text("desktopHash"));
        return new(root, b.Text("pipeName"), proxy, b.Text("instanceId"), Path.Combine(root, "DISABLED"));
    }
}
