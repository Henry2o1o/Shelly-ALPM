using System.CommandLine;
using PackageManager.Flatpak;
using static Shelly.Cli.Interactions.AnsiUtilities;

namespace Shelly.Cli.Commands.Flatpak;

public class Upgrade : GlobalSettingsCommand
{
    public static Command Create()
    {
        var command = new Command("upgrade", "Upgrade all flatpak apps");

        command.SetAction(async (parseResult, _) =>
        {
            var instance = new Upgrade();
            GlobalOptions.Apply(instance, parseResult);
            await instance.ExecuteAsync(new SystemShellyConsole());
            return 0;
        });

        return command;
    }

    public override async ValueTask ExecuteAsync(IShellyConsole console)
    {
        if (UiMode)
        {
            await ExecuteUiMode();
            return;
        }

        console.WriteLine(Colorize("Updating all flatpak apps...", ConsoleColor.Yellow));
        var result = FlatpakManager.UpdateAllFlatpak();
        console.WriteLine(Colorize(result, ConsoleColor.Yellow));
    }

    public override ValueTask ExecuteUiMode()
    {
        UiFrames.Info("Updating all flatpak apps...", Shelly.Utilities.Eventing.AlpmEvents.TransactionStart);
        var result = FlatpakManager.UpdateAllFlatpak();
        UiFrames.Info(result);
        UiFrames.TxFinish(true, "Flatpak upgrade complete.", "Flatpak upgrade failed.");
        return ValueTask.CompletedTask;
    }
}
