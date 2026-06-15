using System.Drawing;
using CliFx.Infrastructure;
using PackageManager.AppImage.AppImageV2;
using Pastel;
using Shelly.Cli.Interactions;
using Shelly.Utilities;

namespace Shelly.Cli.Commands.AppImage;

public class AppImageUpdateManagerVersion : GlobalSettingsCommand
{
    private string? Message { get; set; }

    public override async ValueTask ExecuteAsync(IConsole console)
    {
        var ansiSupport = AnsiUtilities.SupportsAnsi;
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
                Message = ansiSupport ? $"[INFO]{e.Message}".Pastel(Color.Blue) : $"[INFO]{e.Message}";
                console.WriteLine(Message);
            };
            manger.ErrorEvent += (_, e) =>
            {
                Message = ansiSupport ? $"[ERROR]{e.Error}".Pastel(Color.Red) : $"[ERROR]{e.Error}";
                console.WriteLine(Message);
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