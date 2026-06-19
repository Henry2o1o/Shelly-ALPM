using PackageManager.AppImage.AppImageV2;
using PackageManager.Flatpak.Events;
using Pastel;
using Shelly.Cli.Commands;
using Shelly.Cli.Interactions;

namespace Shelly.Cli.Outputs;

public class AppImageSinglePaneOutput
{
    public static async Task<bool> Output(
        IShellyConsole console,
        AppImageManagerV2 manager,
        Func<AppImageManagerV2, Task<bool>> operation,
        bool noConfirm = false)
    {
        var ansi = AnsiUtilities.SupportsAnsi;

        var cfg = ConfigManager.ReadConfig();
        using var region = BottomBarRegion.CreateFromConfig(cfg, console);

        // One-shot section banner.
        var emittedRetrieving = false;

        string Color(string text, ConsoleColor color) => ansi ? text.Pastel(color) : text;

        manager.ProgressEvent += (_, e) =>
        {
            var name = e.AppName ?? "unknown";
            var pct = e.ProgressPercentage ?? 0;

            region.UpdateBar(name, (ulong)(e.ProgressPercentage ?? 0), 100, (int)pct, "");
        };

        manager.MessageEvent += (_, e) => { region.WriteLine(Color(e.Message, ConsoleColor.DarkGray)); };

        manager.ErrorEvent += (_, e) => { region.WriteLine(Color(e.Error, ConsoleColor.Red)); };

        bool result;
        try
        {
            result = await operation(manager);
        }
        catch (Exception ex)
        {
            region.WriteLine(Color($"error: {ex.Message}", ConsoleColor.Red));
            result = false;
        }

        // Dispose region (finalize stickies, clear bars, join ticker) before flushing pacfiles.
        region.Dispose();
        return result;
    }
}