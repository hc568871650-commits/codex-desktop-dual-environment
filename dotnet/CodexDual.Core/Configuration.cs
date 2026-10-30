using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using System.Text.RegularExpressions;

namespace CodexDual.Core;

public static class Json
{
    public static readonly JsonSerializerOptions Options = new() { PropertyNameCaseInsensitive = true, PropertyNamingPolicy = JsonNamingPolicy.CamelCase, WriteIndented = true };
    public static T Read<T>(string path, int limit = 16 * 1024 * 1024)
    {
        Paths.Regular(path);
        using var stream = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete);
        if (stream.Length > limit) throw new InvalidDataException("配置文件超过大小限制。");
        return JsonSerializer.Deserialize<T>(stream, Options) ?? throw new InvalidDataException("配置为空。");
    }
    public static void Write<T>(string path, T value) => Paths.Write(path, JsonSerializer.SerializeToUtf8Bytes(value, Options));
    public static string Text(this JsonElement element, string name, string fallback = "") => element.ValueKind == JsonValueKind.Object && element.TryGetProperty(name, out var p) && p.ValueKind == JsonValueKind.String ? p.GetString() ?? fallback : fallback;
    public static bool Flag(this JsonElement element, string name) => element.ValueKind == JsonValueKind.Object && element.TryGetProperty(name, out var p) && p.ValueKind == JsonValueKind.True;
}

public static class Paths
{
    public static string Full(string path)
    {
        if (string.IsNullOrWhiteSpace(path) || !Path.IsPathFullyQualified(path) || path.StartsWith(@"\\") || path.Any(c => c < 32 || "\"<>|".Contains(c))) throw new InvalidDataException("需要本机绝对路径。");
        var full = Path.GetFullPath(path).TrimEnd('\\', '/');
        if (full.Length <= 3 || full[1] != ':' || full[2] != '\\' || full[2..].Contains(':')) throw new InvalidDataException("不能使用磁盘根目录或设备路径。");
        return full;
    }
    public static bool Same(string? a, string? b) => string.IsNullOrEmpty(a) || string.IsNullOrEmpty(b) ? string.IsNullOrEmpty(a) && string.IsNullOrEmpty(b) : string.Equals(Path.GetFullPath(a).TrimEnd('\\', '/'), Path.GetFullPath(b).TrimEnd('\\', '/'), StringComparison.OrdinalIgnoreCase);
    public static bool Inside(string child, string root) => Path.GetFullPath(child).StartsWith(Path.GetFullPath(root).TrimEnd('\\', '/') + Path.DirectorySeparatorChar, StringComparison.OrdinalIgnoreCase);
    public static bool Overlap(string a, string b) => Same(a, b) || Inside(a, b) || Inside(b, a);
    public static void Regular(string path)
    {
        for (string? p = Path.GetFullPath(path); p != null; p = Path.GetDirectoryName(p))
        {
            try { if ((File.GetAttributes(p) & FileAttributes.ReparsePoint) != 0) throw new InvalidDataException("路径含符号链接或目录联接。"); }
            catch (FileNotFoundException) { }
            catch (DirectoryNotFoundException) { }
        }
    }
    public static void Write(string path, byte[] bytes)
    {
        Regular(path);
        Directory.CreateDirectory(Path.GetDirectoryName(path)!);
        Regular(path);
        var temp = path + "." + Guid.NewGuid().ToString("N") + ".tmp";
        try
        {
            using (var file = new FileStream(temp, FileMode.CreateNew, FileAccess.Write, FileShare.None)) { file.Write(bytes); file.Flush(true); }
            if (File.Exists(path)) File.Replace(temp, path, null); else File.Move(temp, path);
        }
        finally { if (File.Exists(temp)) File.Delete(temp); }
    }
    public static string Hash(string text) => Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(text))).ToLowerInvariant();
}

public sealed class InstanceConfig
{
    public string Id { get; set; } = "";
    public string Role { get; set; } = "";
    public string Home { get; set; } = "";
    public string Profile { get; set; } = "";
    public string Projects { get; set; } = "";
    public string Projectless { get; set; } = "";
    public string ProjectlessMode { get; set; } = "";
    public string Executable { get; set; } = "";
    public string LaunchMode { get; set; } = "";
    public string ExternalLauncher { get; set; } = "";
    public string ApiRoot { get; set; } = "";
}
public sealed class ControllerConfig
{
    public int Schema { get; set; } = 1;
    public string DisplayName { get; set; } = "Codex 双环境";
    public string StateDirectory { get; set; } = "";
    public List<InstanceConfig> Instances { get; set; } = [];
    public InstanceConfig Api => Instances.Single(x => x.Role == "api");
    public InstanceConfig Official => Instances.Single(x => x.Role == "official");
    public static ControllerConfig Load(string path)
    {
        var config = Json.Read<ControllerConfig>(path, 1024 * 1024);
        config.Validate(); return config;
    }
    public void Validate()
    {
        if (Schema != 1 || Instances.Count != 2 || Instances.Select(x => x.Id).Distinct().Count() != 2 || !Instances.Select(x => x.Role).Order().SequenceEqual(new[] { "api", "official" })) throw new InvalidDataException("配置需要独立的官方和 API 两个实例。");
        var paths = new List<string>();
        foreach (var i in Instances)
        {
            if (!Regex.IsMatch(i.Id, "^[a-f0-9]{32}$") || i.LaunchMode is not ("official" or "managed-api" or "external")) throw new InvalidDataException("实例身份或启动方式无效。");
            var data = new List<string> { i.Home, i.Projects };
            if (i.Projectless.Length > 0) data.Add(i.Projectless);
            else if (i.Role != "official" || i.ProjectlessMode != "inherit") throw new InvalidDataException("缺少无项目工作目录。");
            if (i.Profile.Length > 0) data.Add(i.Profile); else if (i.Role != "official") throw new InvalidDataException("API 实例必须设置独立 profile。");
            foreach (var p in data)
            {
                var full = Paths.Full(p); Paths.Regular(full);
                if (paths.Any(prior => Paths.Overlap(prior, full))) throw new InvalidDataException("实例数据目录不能重叠。");
                paths.Add(full);
            }
            if (i.LaunchMode == "external") { Paths.Full(i.ExternalLauncher); Paths.Regular(i.ExternalLauncher); }
            if (i.LaunchMode == "managed-api" && (!Paths.Same(i.Home, Path.Combine(i.ApiRoot, "CodexHome")) || !Paths.Same(i.Profile, Path.Combine(i.ApiRoot, "DesktopProfile")) || !Paths.Same(i.Projects, Path.Combine(i.ApiRoot, "Projects")) || !Paths.Same(i.Projectless, Path.Combine(i.ApiRoot, "Projectless")))) throw new InvalidDataException("托管目录与 apiRoot 不符。");
        }
        StateDirectory = Paths.Full(StateDirectory); Paths.Regular(StateDirectory);
        if (paths.Any(p => Paths.Overlap(p, StateDirectory))) throw new InvalidDataException("运行记录与聊天目录重叠。");
        if (Official.Profile.Length == 0 && new[] { "Codex", "ChatGPT" }.Any(n => Paths.Overlap(Api.Profile, Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), n)))) throw new InvalidDataException("API profile 与官方数据重叠。");
    }
}

public sealed class Preferences
{
    private readonly string path;
    public JsonObject Data { get; }
    public Preferences(string state)
    {
        path = Path.Combine(state, "preferences.local.json");
        Data = File.Exists(path) ? Json.Read<JsonObject>(path) : new JsonObject { ["schema"] = 1 };
    }
    public string Mode => Data["appearance"]?["mode"]?.GetValue<string>() ?? "dark";
    public string Accent => Data["appearance"]?["accent"]?.GetValue<string>() ?? "neutral";
    public string Name(InstanceConfig i) => Data["names"]?[i.Id]?.GetValue<string>() is { Length: > 0 } n ? n : i.Role == "api" ? "API 环境" : "官方环境";
    public string Behavior(string key, string fallback) => Data["windowBehavior"]?[key]?.GetValue<string>() ?? fallback;
    public bool Overlay(string key, bool fallback) => Data["windowBehavior"]?[key]?.GetValue<bool>() ?? fallback;
    public void Save() => Json.Write(path, Data);
}

public sealed record Health(string Component, string State, string Reason, DateTimeOffset CheckedAt, string? Version = null);
public sealed class HealthStore(string state)
{
    private readonly Dictionary<string, Health> values = new();
    public event Action<Health>? Changed;
    public void Set(string component, string status, string reason, string? version = null)
    {
        var item = new Health(component, status, reason, DateTimeOffset.UtcNow, version);
        lock (values) { if (values.TryGetValue(component, out var old) && old.State == status && old.Reason == reason && old.Version == version && item.CheckedAt - old.CheckedAt < TimeSpan.FromMinutes(1)) return; values[component] = item; Json.Write(Path.Combine(state, "dotnet-health.local.json"), values.Values.ToArray()); }
        Changed?.Invoke(item);
    }
    public Health[] Snapshot() { lock (values) return values.Values.ToArray(); }
}
