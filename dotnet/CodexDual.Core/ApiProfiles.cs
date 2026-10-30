using System.Diagnostics;
using System.Text;
using System.Text.Json.Nodes;

namespace CodexDual.Core;

public sealed class ApiProfile
{
    public string Id { get; set; } = "";
    public string Name { get; set; } = "";
    public string BaseUrl { get; set; } = "";
    public string Model { get; set; } = "";
    public string KeyDpapi { get; set; } = "";
    public override string ToString() => Name;
}
public sealed class ProfileList
{
    public int Schema { get; set; } = 1;
    public string ActiveId { get; set; } = "";
    public ApiProfile? PendingProfile { get; set; }
    public List<ApiProfile> Profiles { get; set; } = [];
}
public static class ApiProfiles
{
    private static readonly string[] Files = ["CodexHome/config.toml", "CodexHome/auth.json", "Credentials/api-key.dpapi", ".codex-dual.json", "api-providers.local.json"];
    public static string Mode(InstanceConfig instance)
    {
        if (instance.LaunchMode != "managed-api") return "external";
        return Json.Read<JsonObject>(Path.Combine(instance.ApiRoot, ".codex-dual.json"))["managementMode"]?.GetValue<string>() ?? "builtin";
    }
    private static void AssertManaged(InstanceConfig i)
    {
        if (i.Role != "api" || i.LaunchMode != "managed-api" || Mode(i) != "builtin") throw new InvalidOperationException("此环境由外部工具管理，请在原管理工具中修改渠道。");
        Paths.Regular(i.ApiRoot);
    }
    private static string ListPath(InstanceConfig i) => Path.Combine(i.ApiRoot, "api-providers.local.json");
    public static ProfileList Read(InstanceConfig instance)
    {
        AssertManaged(instance);
        if (File.Exists(ListPath(instance)))
        {
            var data = Json.Read<ProfileList>(ListPath(instance));
            if (data.Schema != 1 || data.Profiles.Count > 256 || data.Profiles.Select(p => p.Id).Distinct().Count() != data.Profiles.Count) throw new InvalidDataException("API 渠道列表无效。");
            return data;
        }
        var meta = Json.Read<JsonObject>(Path.Combine(instance.ApiRoot, ".codex-dual.json"));
        string keyPath = Path.Combine(instance.ApiRoot, "Credentials/api-key.dpapi"); Paths.Regular(keyPath);
        return new() { ActiveId = "legacy", Profiles = [new() { Id = "legacy", Name = "原有 API", BaseUrl = meta["baseUrl"]!.GetValue<string>(), Model = meta["model"]!.GetValue<string>(), KeyDpapi = File.ReadAllText(keyPath).Trim() }] };
    }
    public static void Save(InstanceConfig instance, string? id, string name, string url, string model, string? key)
        => InstanceLease.Run(instance, () => { SaveCore(instance, id, name, url, model, key); return true; });
    private static void SaveCore(InstanceConfig instance, string? id, string name, string url, string model, string? key)
    {
        AssertManaged(instance); Validate(url, model);
        if (string.IsNullOrWhiteSpace(name) || name.Trim().Length > 40 || name.Any(char.IsControl)) throw new InvalidDataException("渠道名称应为 1–40 个字符。");
        var data = Read(instance); var old = data.Profiles.SingleOrDefault(x => x.Id == id);
        if (id != null && old == null) throw new InvalidDataException("渠道已变化，请刷新。");
        if (data.Profiles.Any(p => p.Id != id && p.Name == name.Trim())) throw new InvalidDataException("已有同名渠道。");
        string encrypted = !string.IsNullOrEmpty(key) ? SecretStore.Protect(key) : old?.KeyDpapi ?? throw new InvalidDataException("新增渠道需要密钥。");
        data.Profiles.RemoveAll(p => p.Id == id); data.Profiles.Add(new() { Id = id ?? Guid.NewGuid().ToString("N"), Name = name.Trim(), BaseUrl = url.Trim().TrimEnd('/'), Model = model.Trim(), KeyDpapi = encrypted }); Json.Write(ListPath(instance), data);
    }
    public static void Remove(InstanceConfig instance, string id)
        => InstanceLease.Run(instance, () => { RemoveCore(instance, id); return true; });
    private static void RemoveCore(InstanceConfig instance, string id)
    {
        var data = Read(instance);
        if (data.ActiveId == id || data.PendingProfile?.Id == id) throw new InvalidOperationException("不能删除当前或等待应用的渠道。");
        data.Profiles.RemoveAll(p => p.Id == id); Json.Write(ListPath(instance), data);
    }
    public static string Apply(ControllerConfig config, InstanceConfig instance, string id, ProcessManager manager)
        => InstanceLease.Run(instance, () => ApplyCore(config, instance, id, manager));
    private static string ApplyCore(ControllerConfig config, InstanceConfig instance, string id, ProcessManager manager)
    {
        AssertManaged(instance); var data = Read(instance); var profile = data.Profiles.Single(p => p.Id == id); var status = manager.Status(instance, true);
        if (status.State == "Running") { data.PendingProfile = profile; Json.Write(ListPath(instance), data); return "已暂存，API 环境下次启动时应用。"; }
        if (status.State != "Stopped") throw new InvalidOperationException("无法确认 API 环境已经停止。");
        ApplyNow(instance, data, profile); return "渠道已应用。";
    }
    private static void Validate(string url, string model)
    {
        if (!Uri.TryCreate(url.Trim(), UriKind.Absolute, out var uri) || uri.Scheme is not ("http" or "https") || uri.Scheme == "http" && !uri.IsLoopback || uri.UserInfo.Length > 0 || uri.Query.Length > 0 || uri.Fragment.Length > 0) throw new InvalidDataException("API 地址需要 HTTPS 或本机 HTTP。");
        if (string.IsNullOrWhiteSpace(model) || model.Length > 100 || model.Any(char.IsControl)) throw new InvalidDataException("模型 ID 无效。");
    }
    public static string Merge(string text, string root, string url, string model)
    {
        Validate(url, model); var doc = new TomlConfig(text);
        if (doc.GetString("model_provider") is { } provider && provider != "dual-api" || doc.HasPrefix("model_providers.dual-api.auth") || doc.HasPrefix("model_providers.dual-api.experimental_bearer_token")) throw new InvalidDataException("API 配置由其他服务商管理，未覆盖。");
        var fields = new Dictionary<string, string>
        {
            ["forced_login_method"] = "\"api\"", ["cli_auth_credentials_store"] = "\"file\"", ["model_provider"] = "\"dual-api\"", ["model"] = Quote(model.Trim()),
            ["model_providers.dual-api.name"] = "\"API Environment\"", ["model_providers.dual-api.base_url"] = Quote(url.Trim().TrimEnd('/')), ["model_providers.dual-api.wire_api"] = "\"responses\"", ["model_providers.dual-api.requires_openai_auth"] = "false", ["model_providers.dual-api.env_key"] = "\"CODEX_DUAL_API_KEY\"", ["desktop.projectlessWorkspaceRoot"] = Quote(Path.Combine(root, "Projectless"))
        };
        foreach (var field in fields) text = new TomlConfig(text).Set(field.Key, field.Value);
        return text;
    }
    private static string Quote(string text) => System.Text.Json.JsonSerializer.Serialize(text);
    private static void ApplyNow(InstanceConfig i, ProfileList data, ApiProfile profile)
    {
        var text = Merge(File.ReadAllText(Path.Combine(i.Home, "config.toml")), i.ApiRoot, profile.BaseUrl, profile.Model);
        var meta = Json.Read<JsonObject>(Path.Combine(i.ApiRoot, ".codex-dual.json"));
        var auth = Json.Read<JsonObject>(Path.Combine(i.Home, "auth.json"));
        if (auth["auth_mode"]?.GetValue<string>() != "apikey" || auth["OPENAI_API_KEY"]?.GetValue<string>() != "CODEX_DUAL_ENV_KEY" || auth.Count != 2) throw new InvalidOperationException("认证已由其他工具修改，未覆盖。");
        Backup(i, "应用渠道前");
        var before = Files.ToDictionary(f => f, f => File.Exists(Path.Combine(i.ApiRoot, f)) ? File.ReadAllBytes(Path.Combine(i.ApiRoot, f)) : null);
        try
        {
            Paths.Write(Path.Combine(i.Home, "config.toml"), Encoding.UTF8.GetBytes(text));
            Paths.Write(Path.Combine(i.ApiRoot, "Credentials/api-key.dpapi"), Encoding.UTF8.GetBytes(profile.KeyDpapi));
            meta["baseUrl"] = profile.BaseUrl; meta["model"] = profile.Model; Json.Write(Path.Combine(i.ApiRoot, ".codex-dual.json"), meta);
            data.ActiveId = profile.Id; data.PendingProfile = null; Json.Write(ListPath(i), data);
        }
        catch { foreach (var pair in before) { string path = Path.Combine(i.ApiRoot, pair.Key); if (pair.Value != null) Paths.Write(path, pair.Value); else if (File.Exists(path)) File.Delete(path); } throw; }
    }
    public static string Backup(InstanceConfig i, string reason)
    {
        AssertManaged(i); var files = new Dictionary<string, string?>();
        foreach (var rel in Files) { string path = Path.Combine(i.ApiRoot, rel); Paths.Regular(path); files[rel.Replace('/', '\\')] = File.Exists(path) ? Convert.ToBase64String(File.ReadAllBytes(path)) : null; }
        string snapshot = Path.Combine(i.ApiRoot, "Backup", "snapshot-" + DateTime.Now.ToString("yyyyMMdd-HHmmss") + "-" + Guid.NewGuid().ToString("N") + ".local.json");
        Json.Write(snapshot, new { schema = 1, instanceId = i.Id, root = i.ApiRoot, created = DateTimeOffset.Now, reason, protectedFiles = SecretStore.Protect(System.Text.Json.JsonSerializer.Serialize(files)) }); return snapshot;
    }
    public static void Restore(InstanceConfig i, string snapshot, ProcessManager manager)
        => InstanceLease.Run(i, () => { RestoreCore(i, snapshot, manager); return true; });
    private static void RestoreCore(InstanceConfig i, string snapshot, ProcessManager manager)
    {
        AssertManaged(i); if (manager.Status(i, true).State != "Stopped") throw new InvalidOperationException("恢复前请退出 API 环境。");
        if (!Paths.Same(Path.GetDirectoryName(snapshot), Path.Combine(i.ApiRoot, "Backup"))) throw new InvalidDataException("备份不在本环境的备份目录。");
        var saved = Json.Read<JsonObject>(snapshot);
        if (saved["instanceId"]?.GetValue<string>() != i.Id || !Paths.Same(saved["root"]?.GetValue<string>(), i.ApiRoot)) throw new InvalidDataException("备份不属于此环境。");
        var files = System.Text.Json.JsonSerializer.Deserialize<Dictionary<string, string?>>(SecretStore.Unprotect(saved["protectedFiles"]!.GetValue<string>()))!;
        if (files.Keys.Any(k => !Files.Contains(k.Replace('\\', '/')))) throw new InvalidDataException("备份含未受管理的文件。");
        var decoded = files.ToDictionary(x => x.Key, x => x.Value == null ? null : Convert.FromBase64String(x.Value));
        var before = new Dictionary<string, byte[]?>();
        foreach (var pair in decoded) { string path = Path.Combine(i.ApiRoot, pair.Key); Paths.Regular(path); before[pair.Key] = File.Exists(path) ? File.ReadAllBytes(path) : null; }
        Backup(i, "恢复前");
        try { foreach (var pair in decoded) { var path = Path.Combine(i.ApiRoot, pair.Key); if (pair.Value != null) Paths.Write(path, pair.Value); else if (File.Exists(path)) File.Delete(path); } }
        catch { foreach (var pair in before) { var path = Path.Combine(i.ApiRoot, pair.Key); if (pair.Value != null) Paths.Write(path, pair.Value); else if (File.Exists(path)) File.Delete(path); } throw; }
    }
    public static void PrepareLaunch(ControllerConfig config, InstanceConfig i, ProcessStartInfo info)
    {
        var doc = new TomlConfig(File.ReadAllText(Path.Combine(i.Home, "config.toml")));
        if (doc.GetString("forced_login_method") != "api" || doc.GetString("cli_auth_credentials_store") != "file") throw new InvalidDataException("API 登录隔离设置缺失。");
        if (Mode(i) == "builtin")
        {
            var profiles = Read(i); if (profiles.PendingProfile != null) ApplyNow(i, profiles, profiles.PendingProfile);
            var auth = Json.Read<JsonObject>(Path.Combine(i.Home, "auth.json"));
            if (auth["auth_mode"]?.GetValue<string>() != "apikey" || auth["OPENAI_API_KEY"]?.GetValue<string>() != "CODEX_DUAL_ENV_KEY") throw new InvalidDataException("API 认证模式发生变化。");
            string keyPath = Path.Combine(i.ApiRoot, "Credentials/api-key.dpapi"); Paths.Regular(keyPath); info.Environment["CODEX_DUAL_API_KEY"] = SecretStore.Unprotect(File.ReadAllText(keyPath));
        }
        else
        {
            var meta = Json.Read<JsonObject>(Path.Combine(i.ApiRoot, ".codex-dual.json"));
            var ccs = Json.Read<JsonObject>(meta["ccsSettingsPath"]!.GetValue<string>());
            if (!Paths.Same(ccs["codexConfigDir"]?.GetValue<string>(), i.Home)) throw new InvalidDataException("CC Switch 已切换到其他 Codex 目录。");
        }
    }
}
