using System.Drawing;
using CliFx.Binding;
using CliFx.Infrastructure;
using PackageManager.AppImage.AppImageV2;
using Shelly.Cli.Interactions;
using Shelly.Utilities;

namespace Shelly.Cli.Commands.AppImage;

[Command("appimage migrate-manager", Description = "Syncs meta data for an AppImage")]
public partial class AppImageUpdateManagerVersion : GlobalSettingsCommand
{
    public override async ValueTask ExecuteAsync(IConsole console)
    {
        RootElevator.EnsureRootExectuion();

        var installPath = ConfigManager.ReadConfig().AppImageInstallPath ?? XdgPaths.BinHome();
        var manger = new AppImageManagerV2(installPath);
        if (UiMode)
        {
            manger.MessageEvent += (_, e) => UiFrames.Info(e.Message);
            manger.ErrorEvent += (_, e) => UiFrames.Error(e.Error);
        }
        else
        {
            manger.MessageEvent += (_, e) =>
            {
                console.WriteLine(AnsiUtilities.Colorize($"[INFO]{e.Message}", Color.Blue));
            };
            manger.ErrorEvent += (_, e) =>
            {
                console.WriteLine(AnsiUtilities.Colorize($"[ERROR]{e.Error}", Color.Red));
            };
        }

        var result = await manger.MigrateAppImages();

        if (UiMode)
            UiFrames.TxFinish(result, "AppImage manager version updated successfully.",
                "AppImage manager version updated unsuccessfully.");
        else
        {
            console.WriteLine(result
                ? AnsiUtilities.Colorize("AppImage manager version updated successfully.", Color.Green)
                : AnsiUtilities.Colorize("AppImage manager version updated unsuccessfully.", Color.Red));
        }
    }

    public override async ValueTask ExecuteUiMode()
    {
        //Unneeded as the command is not interactive.
    }
}