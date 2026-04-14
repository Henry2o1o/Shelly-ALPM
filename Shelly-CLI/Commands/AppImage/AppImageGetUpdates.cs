using PackageManager.AppImage;
using Spectre.Console;
using Spectre.Console.Cli;

namespace Shelly_CLI.Commands.Standard;

public class AppImageGetUpdates : AsyncCommand
{
    public override async Task<int> ExecuteAsync(CommandContext context)
    {
        var manager = new AppImageManager();
        var result = await AppImageManager.CheckForAppImageUpdates();

        foreach (var update in result)
        {
            AnsiConsole.MarkupLine($"[green]{update.Name} {update.Version} is available[/]");
        }
        
        if (result.Count == 0)
        {
            AnsiConsole.MarkupLine("[yellow]No updates available[/]");
        }
        
        return 0;
    }
}