using System.Drawing;
using CliFx.Binding;
using CliFx.Infrastructure;
using PackageManager.AppImage.AppImageV2;
using Shelly.Cli.Interactions;
using Shelly.Utilities;

namespace Shelly.Cli.Commands.AppImage;

[Command("appimage remove", Description = "Remove an AppImage")]
public partial class AppImageRemoveCommand : GlobalSettingsCommand
{
    [CommandParameter(0, Description = "Name of the AppImage")]
    public required string AppImage { get; set; }

    [CommandOption("remove-config", 'c', Description = "Remove Config")]
    private bool RemoveConfig { get; set; }

    public override async ValueTask ExecuteAsync(IConsole console)
    {
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

        string targetAppImage;
        if (matches.Count == 1)
        {
            targetAppImage = matches[0];
        }
        else
        {
            console.WriteLine(AnsiUtilities.Colorize(
                $"Multiple matches found, please refine your input to match a singular installed AppImage.",
                Color.Red));
            return;
        }

        if (NoConfirm &&
            !Confirm.Execute($"Are you sure you want to remove [red]{Path.GetFileName(targetAppImage)}[/]?"))
        {
            return;
        }

        var manager = new AppImageManagerV2(ConfigManager.ReadConfig().AppImageInstallPath ?? "");
        if (UiMode)
        {
            manager.ErrorEvent += (_, args) => UiFrames.Error(args.Error);
            manager.MessageEvent += (_, args) => UiFrames.Info(args.Message);
            UiFrames.Info("Removing AppImage...", Utilities.Eventing.AlpmEvents.TransactionStart);
        }
        else
        {
            manager.ErrorEvent += (_, args) => console.WriteLine(AnsiUtilities.Colorize($"{args.Error}", Color.Red));
            manager.MessageEvent += (_, args) =>
                console.WriteLine(AnsiUtilities.Colorize($"{args.Message}", Color.Blue));
        }

        var result = await manager.RemoveAppImage(targetAppImage, RemoveConfig);
        if (UiMode)
            UiFrames.TxFinish(result == 0, "AppImage removed.", "Failed to remove AppImage.");
    }

    public override ValueTask ExecuteUiMode()
    {
        throw new NotImplementedException();
    }
}