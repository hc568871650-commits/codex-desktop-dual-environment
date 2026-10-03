using System;
using System.Collections.Generic;
using System.Text;
using System.Web.Script.Serialization;

internal static class TakeoverFixture {
    static readonly JavaScriptSerializer Json = new JavaScriptSerializer();
    static string mode = "success";
    static object lastId;
    static string lastTurn;
    static int count;
    static object Get(IDictionary<string, object> m, string k) { object v; return m != null && m.TryGetValue(k, out v) ? v : null; }
    static void Send(object m) { Console.WriteLine(Json.Serialize(m)); }
    public static int Main(string[] args) {
        Console.InputEncoding = new UTF8Encoding(false); Console.OutputEncoding = new UTF8Encoding(false);
        string line;
        while ((line = Console.ReadLine()) != null) {
            var m = Json.DeserializeObject(line) as IDictionary<string, object>;
            string method = Get(m, "method") as string;
            var p = Get(m, "params") as IDictionary<string, object>;
            if (method == "mock/emit") Send(Get(p, "message"));
            else if (method == "mock/mode") { mode = (string)Get(p, "mode"); Send(new { method = "mock/ack" }); }
            else if (method == "mock/barrier") Send(new { method = "mock/barrier", @params = new { count = count } });
            else if (method == "mock/late") { Send(new { id = lastId, result = new { turnId = lastTurn } }); Send(new { method = "mock/late-done" }); }
            else if (method == "thread/read" || method == "thread/resume" || method == "thread/turns/list" || method == "thread/timeline/list") {
                Send(new { id = Get(m, "id"), result = Get(p, "fixtureResult") });
            }
            else if (method == "turn/steer") {
                count++; lastId = Get(m, "id"); lastTurn = (string)Get(p, "expectedTurnId");
                Send(new { method = "mock/steer", @params = new { message = m, count = count } });
                if (mode == "success") Send(new { id = lastId, result = new { turnId = lastTurn } });
                else if (mode == "error") Send(new { id = lastId, error = new { code = -32602, message = "expectedTurnId mismatch" } });
                else if (mode == "wrong-success") Send(new { id = lastId, result = new { turnId = "wrong-turn" } });
            }
            else Send(new { method = "mock/received", @params = new { message = m } });
        }
        return 0;
    }
}
