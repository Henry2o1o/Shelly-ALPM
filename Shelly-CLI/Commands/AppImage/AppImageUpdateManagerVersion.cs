using System.Diagnostics.CodeAnalysis;
using PackageManager.AppImage.AppImageV2;
using Shelly_CLI.Configuration;
using Shelly_CLI.Utility;
using Spectre.Console;
using Spectre.Console.Cli;

namespace Shelly_CLI.Commands.AppImage;

public class AppImageUpdateManagerVersion : AsyncCommand
{
    public override async Task<int> ExecuteAsync(CommandContext context)
    {
        RootElevator.EnsureRootExectuion();
        
        var manger = new AppImageManagerV2(ConfigManager.ReadConfig().AppImageInstallPath ?? "");;
        if (Program.IsUiMode)
        {
            manger.MessageEvent += (_, e) => UiFrames.Info(e.Message);
            manger.ErrorEvent += (_, e) => UiFrames.Error(e.Error);
            UiFrames.Info("Starting AppImage manager migration...", Shelly.Utilities.Eventing.AlpmEvents.TransactionStart);
        }
        else
        {
            manger.MessageEvent += (_, e) => AnsiConsole.MarkupLine($"[blue][[INFO]][/] {e.Message.EscapeMarkup()}");
            manger.ErrorEvent += (_, e) => AnsiConsole.MarkupLine($"[red][[ERROR]][/] {e.Error.EscapeMarkup()}");
        }

        var result = await manger.MigrateAppImages();

        if (Program.IsUiMode)
            UiFrames.TxFinish(result, "AppImage manager version updated successfully.", "AppImage manager version updated unsuccessfully.");
        else
            AnsiConsole.MarkupLine(result
                ? "[green]AppImage manager version updated successfully.[/]"
                : "[red]AppImage manager version updated unsuccessfully.[/]");

        return result ? 0 : 1;
    }
}