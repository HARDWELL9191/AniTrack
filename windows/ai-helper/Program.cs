// AniTrack's Windows AI helper. One JSON request per line on stdin, one JSON reply per line on
// stdout:
//   {"cmd":"status"}                -> {"ok":true,"state":"Ready"}  (or NotReady, NotSupportedOnCurrentSystem, ...)
//   {"cmd":"explain","prompt":"…"}  -> {"ok":true,"text":"…"}       or {"ok":false,"error":"…"}
// The app starts it when you ask for an explanation and closes it after a minute of quiet, so
// the language model is only loaded while it's being used.

using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using Microsoft.Windows.AI;
using Microsoft.Windows.AI.Text;

var utf8 = new UTF8Encoding(false);
Console.InputEncoding = utf8;
Console.OutputEncoding = utf8;
var output = new StreamWriter(Console.OpenStandardOutput(), utf8) { AutoFlush = true };
var input = new StreamReader(Console.OpenStandardInput(), utf8);

LanguageModel? model = null;

void Reply(JsonObject reply) => output.WriteLine(reply.ToJsonString());

JsonObject Error(string message) => new() { ["ok"] = false, ["error"] = message };

string Describe(Exception e) => $"{e.Message.Trim()} (0x{e.HResult:X8})";

while (await input.ReadLineAsync() is { } line)
{
    if (string.IsNullOrWhiteSpace(line)) continue;
    JsonObject reply;
    try
    {
        var request = JsonNode.Parse(line)?.AsObject() ?? throw new InvalidDataException("empty request");
        switch ((string?)request["cmd"])
        {
            case "status":
                reply = new JsonObject { ["ok"] = true, ["state"] = LanguageModel.GetReadyState().ToString() };
                break;

            case "explain":
                var prompt = (string?)request["prompt"] ?? "";
                reply = await Explain(prompt);
                break;

            default:
                reply = Error("unknown command");
                break;
        }
    }
    catch (Exception e)
    {
        reply = Error(Describe(e));
    }
    Reply(reply);
}

model?.Dispose();
return 0;

async Task<JsonObject> Explain(string prompt)
{
    if (model is null)
    {
        var state = LanguageModel.GetReadyState();
        if (state == AIFeatureReadyState.NotReady)
        {
            // The model is part of Windows (AI components); this finishes setting it up.
            var ready = await LanguageModel.EnsureReadyAsync();
            if (ready.ExtendedError is { } failed) return Error($"Windows couldn't prepare its language model: {Describe(failed)}");
            state = LanguageModel.GetReadyState();
        }
        if (state != AIFeatureReadyState.Ready) return Error($"Windows' language model isn't available ({state}).");
        model = await LanguageModel.CreateAsync();
    }
    var result = await model.GenerateResponseAsync(prompt);
    var status = result.Status.ToString();
    if (status != "Complete") return Error($"Windows' language model didn't answer ({status}).");
    return new JsonObject { ["ok"] = true, ["text"] = result.Text.Trim() };
}
