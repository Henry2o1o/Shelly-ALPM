using System.ComponentModel;
using PackageManager.AppImage;
using Shelly_CLI.Commands.Standard;
using Spectre.Console;
using Spectre.Console.Cli;

namespace Shelly_CLI.Commands.AppImage;

public class AppImageUpdateCommand : AsyncCommand<AppImageUpdateSettings>
{
    public override async Task<int> ExecuteAsync(CommandContext context, AppImageUpdateSettings settings)
    {
        var manager = new AppImageManager();
        var updates = await AppImageManager.CheckForAppImageUpdates();

        if (updates.Count == 0)
        {
            AnsiConsole.MarkupLine("[yellow]No updates available for any AppImage.[/]");
            return 0;
        }
        
        RootElevator.EnsureRootExectuion();

        if (!string.IsNullOrEmpty(settings.Name))
        {
            var update = updates.FirstOrDefault(u => u.Name.Equals(settings.Name, StringComparison.OrdinalIgnoreCase));
            if (update == null)
            {
                AnsiConsole.MarkupLine($"[yellow]No update available for AppImage '{settings.Name}'.[/]");
                return 0;
            }

            return await PerformUpdate(manager, update);
        }


        var exitCode = 0;
        foreach (var update in updates)
        {
            if (!settings.NoConfirm)
            {
                if (!AnsiConsole.Confirm($"Update {update.Name} to {update.Version}?"))
                {
                    continue;
                }
            }

            var result = await PerformUpdate(manager, update);
            if (result != 0) exitCode = result;
        }

        return exitCode;
    }

    private async Task<int> PerformUpdate(AppImageManager manager, AppImageUpdateDto update)
    {
        AnsiConsole.MarkupLine($"[blue]Updating {update.Name} to {update.Version}...[/]");
        return await manager.RunUpdate(update);
    }
}