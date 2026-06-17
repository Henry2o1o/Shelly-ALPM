using System.CommandLine;
using Shelly.Cli.Interactions;
using static Shelly.Cli.Interactions.AnsiUtilities;
using AurUpgrade = Shelly.Cli.Commands.Aur.Upgrade;
using FlatpakUpgrade = Shelly.Cli.Commands.Flatpak.Upgrade;
using AppImageUpgrade = Shelly.Cli.Commands.AppImage.AppImageUpgrade;

namespace Shelly.Cli.Commands.Standard;

public class UpgradeAll : GlobalSettingsCommand
{
    public static Command Create()
    {
        var command = new Command("upgrade-all",
            "Upgrade all packages from every source (repo, AUR, Flatpak, AppImage)");

        command.SetAction(async (parseResult, _) =>
        {
            var instance = new UpgradeAll();
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

        RootElevator.EnsureRootExectuion();

        await RunChild(new Upgrade(), console);
        await RunChild(new AurUpgrade(), console);
        await RunChild(new FlatpakUpgrade(), console);
        await RunChild(new AppImageUpgrade(), console);

        console.WriteLine(Colorize("All upgrades complete.", ConsoleColor.Green));
    }

    public override async ValueTask ExecuteUiMode()
    {
        await RunChild(new Upgrade(), null);
        await RunChild(new AurUpgrade(), null);
        await RunChild(new FlatpakUpgrade(), null);
        await RunChild(new AppImageUpgrade(), null);
    }

    private async ValueTask RunChild(GlobalSettingsCommand child, IShellyConsole? console)
    {
        child.NoConfirm = NoConfirm;
        child.UiMode = UiMode;
        child.JsonOutput = JsonOutput;
        child.Verbose = Verbose;

        try
        {
            if (UiMode)
                await child.ExecuteAsync(new SystemShellyConsole());
            else
                await child.ExecuteAsync(console!);
        }
        catch (Exception ex)
        {
            if (console is not null)
                console.WriteLine(Colorize($"Upgrade step failed: {ex.Message}", ConsoleColor.Red));
            else
                UiFrames.Error($"Upgrade step failed: {ex.Message}");
        }
    }
}
