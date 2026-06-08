using CliFx;
using CliFx.Binding;
using CliFx.Infrastructure;
using PackageManager.Alpm;
using Pastel;

namespace Shelly.Cli.Commands;

[Command("upgrade", Description = "Perform a full system upgrade")]
public partial class UpgradeCommand : GlobalSettingsCommand
{
    public override async ValueTask ExecuteAsync(IConsole console)
    {
        if (UiMode)
        {
            await ExecuteUiMode();
            return;
        }
        Console.WriteLine("Performing full system upgrade...".Pastel(ConsoleColor.Yellow));
        throw new NotImplementedException();
    }

    public override async ValueTask ExecuteUiMode()
    {
        UiFrames.Info("Performing full system upgrade...");

        using var manager = new AlpmManager();
        
        throw new NotImplementedException();
    }
}