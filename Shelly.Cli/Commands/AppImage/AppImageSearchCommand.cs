using System.Drawing;
using CliFx.Binding;
using CliFx.Infrastructure;
using PackageManager.AppImage.AppImageV2;
using Shelly.Cli.Interactions;
using Shelly.Utilities;
using Shelly.Utilities.Enums;

namespace Shelly.Cli.Commands.AppImage;

[Command("appimage list", Description = "Lists all AppImages")]
public partial class AppImageListCommand : GlobalSettingsCommand
{
    public override async ValueTask ExecuteAsync(IConsole console)
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
            manager.MessageEvent += (_, e) =>
                console.WriteLine(AnsiUtilities.Colorize($"[Info] {e.Message}", Color.Blue));
            manager.ErrorEvent += (_, e) => console.WriteLine(AnsiUtilities.Colorize($"[ERROR]{e.Error}", Color.Red));
        }

        var appImages = await manager.GetAppImagesFromLocalDb();

        if (UiMode)
        {
            JsonPackFrame.WriteToStdout(appImages);
        }
        else
        {
            
            var displaySize = Enum.Parse<SizeDisplay>(ConfigManager.ReadConfig().FileSizeDisplay);
            console.WriteLine(BasicTable.Execute(["Name", "Version", "Size", "Update URL"], appImages, c => c.Name, c => c.Version,
                c => SizeUtilities.FormatSize(displaySize, c.SizeOnDisk), c => c.UpdateURl));
        }
    }

    public async override ValueTask ExecuteUiMode()
    {
        //Not Implemented
    }
}