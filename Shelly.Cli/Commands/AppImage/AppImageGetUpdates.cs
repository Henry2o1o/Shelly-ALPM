using System.CommandLine;
using System.Drawing;
using PackageManager.AppImage.AppImageV2;
using Shelly.Cli.Interactions;
using Shelly.Utilities;

namespace Shelly.Cli.Commands.AppImage;

public partial class AppImageGetUpdates : GlobalSettingsCommand
{
    public static Command Create()
    {
        var command = new Command("list-updates", "Find Updates for an AppImage");

        command.SetAction(async (parseResult, cancellationToken) =>
        {
            var instance = new AppImageGetUpdates();
            GlobalOptions.Apply(instance, parseResult);
            await instance.ExecuteAsync(new SystemShellyConsole());
            return 0;
        });

        return command;
    }

    public override async ValueTask ExecuteAsync(IShellyConsole console)
    {
        var installPath = ConfigManager.ReadConfig().AppImageInstallPath ?? XdgPaths.BinHome();
        var manager = new AppImageManagerV2(installPath);
        if (UiMode)
        {
            manager.MessageEvent += (_, e) => UiFrames.Info(e.Message);
            manager.ErrorEvent += (_, e) => UiFrames.Error(e.Error);
        }
        else
        {
            manager.MessageEvent +=
                (_, e) => console.WriteLine(AnsiUtilities.Colorize($"[INFO]{e.Message}", Color.Blue));
            manager.ErrorEvent += (_, e) => console.WriteLine(AnsiUtilities.Colorize($"[ERROR]]{e.Error}", Color.Red));
        }

        var result = await manager.CheckForAppImageUpdates();

        if (UiMode)
        {
            JsonPackFrame.WriteToStdout(result);
        }

        else
        {
            foreach (var update in result)
            {
                console.WriteLine(AnsiUtilities.Colorize($"{update.Name} {update.Version} is available", Color.Green));
            }

            if (result.Count == 0)
            {
                console.WriteLine(AnsiUtilities.Colorize("No updates available", Color.Yellow));
            }
        }
    }

    public override async ValueTask ExecuteUiMode()
    {
        //Not Implemented 
    }
}