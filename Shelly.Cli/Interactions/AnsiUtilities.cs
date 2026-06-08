namespace Shelly.Cli.Interactions;

internal static class AnsiUtilities
{
    internal static bool SupportsAnsi => !Console.IsOutputRedirected && !Console.IsInputRedirected &&
                                         Environment.GetEnvironmentVariable("TERM") != "dumb" &&
                                         Environment.GetEnvironmentVariable("NO_Color") is null;
}