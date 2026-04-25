using System.Text.Json;
using System.Text.Json.Serialization.Metadata;

namespace Shelly_CLI.Utility;

public static class JsonOutput
{
    public static async Task WriteJsonAsync<T>(T value, JsonTypeInfo<T> typeInfo)
    {
        var json = JsonSerializer.Serialize(value, typeInfo);
        await using var stdout = Console.OpenStandardOutput();
        await using var writer = new StreamWriter(stdout, System.Text.Encoding.UTF8);
        await writer.WriteLineAsync(json);
        await writer.FlushAsync();
    }

    public static void WriteJson<T>(T value, JsonTypeInfo<T> typeInfo)
    {
        var json = JsonSerializer.Serialize(value, typeInfo);
        using var stdout = Console.OpenStandardOutput();
        using var writer = new StreamWriter(stdout, System.Text.Encoding.UTF8);
        writer.WriteLine(json);
        writer.Flush();
    }

    public static async Task WriteRawAsync(string value)
    {
        await using var stdout = Console.OpenStandardOutput();
        await using var writer = new StreamWriter(stdout, System.Text.Encoding.UTF8);
        await writer.WriteLineAsync(value);
        await writer.FlushAsync();
    }

    public static void WriteRaw(string value)
    {
        using var stdout = Console.OpenStandardOutput();
        using var writer = new StreamWriter(stdout, System.Text.Encoding.UTF8);
        writer.WriteLine(value);
        writer.Flush();
    }
}
