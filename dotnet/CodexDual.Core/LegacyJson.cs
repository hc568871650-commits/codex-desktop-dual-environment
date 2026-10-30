// Preserve the established question protocol while moving off System.Web/.NET Framework.
namespace System.Web.Script.Serialization;
public sealed class JavaScriptSerializer
{
    public int MaxJsonLength { get; set; } = 2 * 1024 * 1024;
    public int RecursionLimit { get; set; } = 100;
    public object? DeserializeObject(string json)
    {
        if (json.Length > MaxJsonLength) throw new FormatException("JSON limit exceeded.");
        using var document = Text.Json.JsonDocument.Parse(json);
        return Convert(document.RootElement);
    }
    private static object? Convert(Text.Json.JsonElement e) => e.ValueKind switch
    {
        Text.Json.JsonValueKind.Object => e.EnumerateObject().ToDictionary(x => x.Name, x => Convert(x.Value)),
        Text.Json.JsonValueKind.Array => e.EnumerateArray().Select(Convert).ToArray(),
        Text.Json.JsonValueKind.String => e.GetString(),
        Text.Json.JsonValueKind.Number => e.TryGetInt32(out var n) ? n : e.TryGetInt64(out var l) ? l : e.GetDouble(),
        Text.Json.JsonValueKind.True => true, Text.Json.JsonValueKind.False => false, _ => null
    };
    public string Serialize(object value) => Text.Json.JsonSerializer.Serialize(value, new Text.Json.JsonSerializerOptions { IncludeFields = true });
}
