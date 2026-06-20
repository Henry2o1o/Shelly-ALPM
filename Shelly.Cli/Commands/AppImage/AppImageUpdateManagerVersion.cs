using System.CommandLine;
using PackageManager.AppImage.AppImageV2;
using Shelly.Cli.Interactions;
using Shelly.Utilities;
using Shelly.Utilities.Eventing;

namespace Shelly.Cli.Commands.AppImage;

public partial class AppImageUpdateManagerVersion : GlobalSettingsCommand
{
    public static Command Create()
    {
        var command = new Command("migrate-manager", "Updates the AppImage manager version");

        command.SetAction(async (parseResult, cancellationToken) =>
        {
            var instance = new AppImageUpdateManagerVersion();
            GlobalOptions.Apply(instance, parseResult);
            await instance.ExecuteAsync(new SystemShellyConsole());
            return 0;
        });

        return command;
    }

    public override async ValueTask ExecuteAsync(IShellyConsole console)
    {
        RootElevator.EnsureRootExectuion();

        var installPath = ConfigManager.ReadConfig().AppImageInstallPath ?? XdgPaths.BinHome();
        var manager = new AppImageManagerV2(installPath);
        if (UiMode)
        {
            manager.StatusEvent += (_, e) =>
            {
                if (e.Severity == AppImageEvents.Error) UiFrames.Error(e.Message);
                else UiFrames.Info(e.Message);
            };
        }
        else
        {
            manager.StatusEvent += (_, e) =>
            {
                if (e.Severity == AppImageEvents.Error)
                    console.WriteLine(AnsiUtilities.Colorize($"[ERROR]{e.Message}", ConsoleColor.Red));
                else
                    console.WriteLine(AnsiUtilities.Colorize($"[INFO]{e.Message}", ConsoleColor.Blue));
            };
        }

        var result = await manager.MigrateAppImages();

        if (UiMode)
            UiFrames.TxFinish(result, "AppImage manager version updated successfully.",
                "AppImage manager version updated unsuccessfully.");
        else
        {
            console.WriteLine(result
                ? AnsiUtilities.Colorize("AppImage manager version updated successfully.", ConsoleColor.Green)
                : AnsiUtilities.Colorize("AppImage manager version updated unsuccessfully.", ConsoleColor.Red));
        }
    }

    public override async ValueTask ExecuteUiMode()
    {
        //Unneeded as the command is not interactive.
    }
}