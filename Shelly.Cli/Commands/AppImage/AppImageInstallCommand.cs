using System.Drawing;
using CliFx.Binding;
using CliFx.Infrastructure;
using PackageManager.AppImage;
using PackageManager.AppImage.AppImageV2;
using Shelly.Cli.Interactions;
using Shelly.Utilities;

namespace Shelly.Cli.Commands.AppImage;

[Command("appimage install", Description = "Install an AppImage")]
public partial class AppImageInstallCommand : GlobalSettingsCommand
{
    [CommandParameter(0, Description = "Location of the AppImage")]
    public required string AppImageLocation { get; set; }

    public override async ValueTask ExecuteAsync(IConsole console)
    {
        if (!File.Exists(AppImageLocation))
        {
            if (UiMode)
                UiFrames.Error("Specified file does not exist.");
            else
                console.WriteLine(AnsiUtilities.Colorize("Error: Specified file does not exist.", Color.Red));
            return;
        }

        if (await AppImageManagerV2.IsAppImage(AppImageLocation))
        {
            var installPath = ConfigManager.ReadConfig().AppImageInstallPath ?? XdgPaths.BinHome();
            var manager = new AppImageManagerV2(installPath);
            if (UiMode)
            {
                manager.ErrorEvent += (_, args) => UiFrames.Error(args.Error);
                manager.MessageEvent += (_, args) => UiFrames.Info(args.Message);
            }
            else
            {
                manager.ErrorEvent += (_, args) =>
                    console.WriteLine(AnsiUtilities.Colorize($"{args.Error}", Color.Red));
                manager.MessageEvent += (_, args) =>
                    console.WriteLine(AnsiUtilities.Colorize($"{args.Message}", Color.Red));
            }

            var result = await manager.InstallAppImage(AppImageLocation);

            if (UiMode)
                UiFrames.TxFinish(result, "Successfully installed appimage.", "Failed to install appimage.");
            else if (result)
            {
                console.WriteLine(AnsiUtilities.Colorize("Successfully installed appimage.", Color.Green));
            }

            console.WriteLine(AnsiUtilities.Colorize("Failled to install appimage.", Color.Red));
        }
    }

    public override async ValueTask ExecuteUiMode()
    {
        //Not Implemented.
    }
}