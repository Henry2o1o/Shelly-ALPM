using System.CommandLine;
using PackageManager.AppImage.AppImageV2;
using Shelly.Cli.Interactions;
using Shelly.Utilities;
using Shelly.Utilities.Enums;
using Shelly.Utilities.Eventing;

namespace Shelly.Cli.Commands.AppImage;

public partial class AppImageList : GlobalSettingsCommand
{
    public static Command Create()
    {
        var command = new Command("list", "Lists all AppImages");

        command.SetAction(async (parseResult, cancellationToken) =>
        {
            var instance = new AppImageList();
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
                    console.WriteLine(AnsiUtilities.Colorize($"[Info] {e.Message}", ConsoleColor.Blue));
            };
        }

        var appImages = await manager.GetAppImagesFromLocalDb();

        if (UiMode)
        {
            JsonPackFrame.WriteToStdout(appImages);
        }
        else
        {
            var displaySize = Enum.Parse<SizeDisplay>(ConfigManager.ReadConfig().FileSizeDisplay);
            console.WriteLine(BasicTable.Execute(["Name", "Version", "Size", "Update Info"], appImages, c => c.Name,
                c => c.Version,
                c => SizeUtilities.FormatSize(displaySize, c.SizeOnDisk),
                c => string.IsNullOrEmpty(c.UpdateURl)
                    ? string.IsNullOrEmpty(c.RepoOwner) ? "" : $"{c.RepoOwner}/{c.RepoOwner}"
                    : c.UpdateURl));
        }
    }

    public async override ValueTask ExecuteUiMode()
    {
        //Not Implemented
    }
}