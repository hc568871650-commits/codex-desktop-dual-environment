using System;
using System.Collections.Generic;
using System.Web.Script.Serialization;

internal static class FakeAppServer
{
    private static readonly JavaScriptSerializer Json = new JavaScriptSerializer();
    private static void Send(object value) { Console.WriteLine(Json.Serialize(value)); }
    public static int Main(string[] args)
    {
        Console.InputEncoding = new System.Text.UTF8Encoding(false);
        Console.OutputEncoding = new System.Text.UTF8Encoding(false);
        if (Array.IndexOf(args, "app-server") < 0 || Array.IndexOf(args, "generate-json-schema") >= 0)
        {
            Send(new { method = "mock/argv", @params = new { argv = args } });
            string passthrough;
            while ((passthrough = Console.ReadLine()) != null) Console.WriteLine(passthrough);
            return 0;
        }
        Send(new { method = "mock/unknown", @params = new { value = "transparent", cliPath = Environment.GetEnvironmentVariable("CODEX_CLI_PATH") } });
        if (Array.IndexOf(args, "--mock-exit") >= 0) return 0;
        object requestId = Array.IndexOf(args, "--string-id") >= 0 ? (object)"request-42" : 42;
        Send(new { id = 43, method = "item/tool/requestOptionPicker", @params = new { threadId = "mock-thread", turnId = "mock-turn" } });
        Send(new { id = requestId, method = "item/tool/requestUserInput", @params = new {
            threadId = "mock-thread", turnId = "mock-turn", itemId = "mock-item", isBlocking = true,
            questions = new object[] {
                new { id = "choice", header = "Choice", question = "Select a choice", isOther = false,
                    options = new object[] { new { label = "A", description = "First" }, new { label = "B", description = "Second" } } },
                new { id = "detail", header = "Detail", question = "Type a detail", isOther = true, isSecret = true,
                    options = (object)null }
            } } });
        string line;
        while ((line = Console.ReadLine()) != null)
        {
            object parsed;
            try { parsed = Json.DeserializeObject(line); }
            catch { parsed = new { invalid = true }; }
            var map = parsed as IDictionary<string, object>;
            object method;
            if (map != null && map.TryGetValue("method", out method))
            {
                if ("mock/resolve".Equals(method))
                {
                    Send(new { method = "serverRequest/resolved", @params = new { requestId = requestId, threadId = "mock-thread" } });
                    continue;
                }
                if ("mock/complete".Equals(method) || "mock/interrupt".Equals(method))
                {
                    Send(new { method = "mock/complete".Equals(method) ? "turn/completed" : "turn/interrupted",
                        @params = new { threadId = "mock-thread", turn = new { id = "mock-turn" } } });
                    continue;
                }
                if ("mock/reuse".Equals(method))
                {
                    Send(new { id = requestId, method = "item/tool/requestUserInput", @params = new {
                        threadId = "mock-thread", turnId = "mock-turn", itemId = "mock-item-2", isBlocking = false,
                        questions = new object[] { new { id = "choice", header = "Choice", question = "New request",
                            options = (object)null } } } });
                    continue;
                }
            }
            Send(new { method = "mock/received", @params = new { message = parsed } });
        }
        return 0;
    }
}
