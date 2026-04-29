using System.Text.Json;
using System.Text.Json.Serialization.Metadata;
using Nerdbank.MessagePack;
using Shelly.Gtk.Services;
using Shelly.Gtk.UiModels.PackageManagerObjects;

namespace Shelly.Gtk.Helpers;

public static class ResultDeserializers
{
    public static List<T> DeserializeCliResultJson<T>(OperationResult result, JsonTypeInfo<List<T>> context) where T : class
    {
        if (!result.Success || string.IsNullOrWhiteSpace(result.Output))
        {
            return [];
        }

        try
        {
            var lines = result.Output.Split('\n', StringSplitOptions.RemoveEmptyEntries);
            foreach (var line in lines)
            {
                var trimmedLine = StripBom(line.Trim());
                if (!trimmedLine.StartsWith("[") || !trimmedLine.EndsWith("]")) continue;
                var updates = JsonSerializer.Deserialize(trimmedLine,
                    context);
                return updates ?? [];
            }

            var allUpdates = JsonSerializer.Deserialize(StripBom(result.Output.Trim()),
                context);
            return allUpdates ?? [];
        }
        catch (Exception ex)
        {
            Console.WriteLine($"Failed to parse updates JSON: {ex.Message}");
            return [];
        }
    }
    
    public static List<T> DeserializeCliResult<T>(OperationResult result) where T : class
    {
        if (!result.Success || string.IsNullOrWhiteSpace(result.Output))
        {
            return [];
        }

        try
        {
            var bytes = Convert.FromBase64String(result.Output.Trim());
            return new MessagePackSerializer().Deserialize<List<T>, MessagePackWitness>(bytes) ?? [];
        }
        catch (Exception ex)
        {
            Console.WriteLine($"Failed to parse MessagePack: {ex.Message}");
            return [];
        }
    }

    public static T? DeserializeCliResultSingle<T>(OperationResult result) where T : class
    {
        if (!result.Success || string.IsNullOrWhiteSpace(result.Output))
        {
            return null;
        }

        try
        {
            var bytes = Convert.FromBase64String(result.Output.Trim());
            return new MessagePackSerializer().Deserialize<T, MessagePackWitness>(bytes);
        }
        catch (Exception ex)
        {
            Console.WriteLine($"Failed to parse MessagePack: {ex.Message}");
            return null;
        }
    }

    private static string StripBom(string input)
    {
        return string.IsNullOrEmpty(input) ? input : input.TrimStart('\uFEFF');
    }
}