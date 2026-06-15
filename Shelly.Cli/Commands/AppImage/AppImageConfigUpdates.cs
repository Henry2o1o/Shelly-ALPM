using System.Drawing;
using CliFx.Binding;
using CliFx.Infrastructure;
using PackageManager.AppImage;
using PackageManager.AppImage.AppImageV2;
using Shelly.Cli.Interactions;
using Shelly.Utilities;

namespace Shelly.Cli.Commands.AppImage;

[Command("appimage configure-updates", Description = "Syncs meta data for an AppImage")]
public partial class AppImageConfigUpdates : GlobalSettingsCommand
{
    [CommandParameter(0, Description = "AppImage name to configure updates")]
    public required string AppImage { get; set; }

    [CommandParameter(1, Description = "Update URL")]
    public required string Url { get; set; }

    [CommandParameter(2, Description = "Update Type")]
    public required UpdateType Type { get; set; }

    [CommandOption("prerelease", 'p', Description = "Allow prerelease updates")]
    private bool AllowPrerelease { get; set; }

    public override async ValueTask ExecuteAsync(IConsole console)
    {
        if (string.IsNullOrEmpty(AppImage))
        {
            console.WriteLine(AnsiUtilities.Colorize("Error: AppImage name is required)", Color.Red));
            return;
        }

        if (string.IsNullOrEmpty(Url))
        {
            console.WriteLine(AnsiUtilities.Colorize("Error: Update URL is required", Color.Red));
            return;
        }

        var config = ConfigManager.ReadConfig();
        var installDir = config.AppImageInstallPath ?? XdgPaths.BinHome();
        var oldDefaultPath = XdgPaths.BinHome();

        var searchPaths = new List<string> { installDir };
        if (installDir != oldDefaultPath)
        {
            searchPaths.Add(oldDefaultPath);
        }

        var matches = new List<string>();
        foreach (var appImages in from path in searchPaths
                 where Directory.Exists(path)
                 select Directory.GetFiles(path, "*.AppImage", SearchOption.TopDirectoryOnly))
        {
            matches.AddRange(appImages.Where(f =>
                Path.GetFileName(f).Contains(AppImage, StringComparison.OrdinalIgnoreCase)));
        }

        if (matches.Count == 0)
        {
            console.WriteLine(AnsiUtilities.Colorize($"No AppImage matching \"{AppImage}\" found in searched paths.",
                Color.Red));
            return;
        }


        var manager = new AppImageManagerV2(ConfigManager.ReadConfig().AppImageInstallPath ?? "");

        if (UiMode)
        {
            manager.MessageEvent += (_, e) => UiFrames.Info(e.Message);
            manager.ErrorEvent += (_, e) => UiFrames.Error(e.Error);
        }
        else
        {
            manager.MessageEvent += (_, e) =>
                console.WriteLine(AnsiUtilities.Colorize($"[[INFO]]{e.Message}", Color.Blue));
            manager.ErrorEvent += (_, e) => console.WriteLine(AnsiUtilities.Colorize($"[ERROR] {e.Error}", Color.Red));
        }

        var success = await manager.AppImageConfigureUpdates(Url, AppImage, Type,
            AllowPrerelease);

        if (success)
        {
            console.WriteLine(AnsiUtilities.Colorize($"Successfully configured updates for {AppImage}", Color.Green));
            return;
        }

        console.WriteLine(AnsiUtilities.Colorize($"Failed to configure updates for {AppImage}. Is it installed?",
            Color.Red));
    }

    public override async ValueTask ExecuteUiMode()
    {
        //Unneeded as the command is not interactive.
    }
}