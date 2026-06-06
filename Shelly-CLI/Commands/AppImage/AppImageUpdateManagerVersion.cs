using System.Diagnostics.CodeAnalysis;
using PackageManager.AppImage.AppImageV2;
using Spectre.Console;
using Spectre.Console.Cli;

namespace Shelly_CLI.Commands.AppImage;

public class AppImageUpdateManagerVersion : AsyncCommand
{
    public override async Task<int> ExecuteAsync(CommandContext context)
    {
        var manger = new AppImageManagerV2();
        var result = await manger.MigrateAppImages();
        if (result)
        {
            AnsiConsole.WriteLine("AppImage manager version updated successfully.");
            return 0;
        }

        AnsiConsole.WriteLine("AppImage manager version updated unsuccessfully.");
        return 0;
    }
}