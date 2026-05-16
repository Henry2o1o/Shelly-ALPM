using System.Text;
using PackageManager.Alpm;
using PackageManager.Alpm.Events;

namespace Shelly_CLI.Utility;

public enum IpcMode
{
    Alpm,
    Aur
}

public static class ProgressFormatter
{
    public static string FormatProgress(
        AlpmProgressType type,
        string? packageName,
        int? percent,
        string? message = null,
        IpcMode mode = IpcMode.Alpm)
    {
        var prefix = mode == IpcMode.Aur ? "[AUR_PROGRESS]" : "[ALPM_PROGRESS]";
        var builder = new StringBuilder();
        builder.Append($"{prefix} Type: {type.ToToken()} ");
        builder.Append($"Package: {packageName ?? "unknown"} ");
        builder.Append($"Percent: {percent ?? 0}% ");
        builder.Append("Message: ");
        builder.Append(message ?? $"{type.ToFriendlyLabel()} {packageName ?? string.Empty}".Trim());
        return builder.ToString();
    }

    public static string FormatProgress(AlpmProgressEventArgs args, IpcMode mode = IpcMode.Alpm)
        => FormatProgress(args.ProgressType, args.PackageName, args.Percent, null, mode);

    public static void WriteUiLine(AlpmProgressEventArgs args, IpcMode mode = IpcMode.Alpm)
        => Console.Error.WriteLine(FormatProgress(args, mode));
}
