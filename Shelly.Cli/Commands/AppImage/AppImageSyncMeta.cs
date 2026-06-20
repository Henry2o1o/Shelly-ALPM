using System.CommandLine;
using PackageManager.AppImage.AppImageV2;
using Pastel;
using Shelly.Cli.Interactions;
using Shelly.Utilities;
using Shelly.Utilities.Eventing;

namespace Shelly.Cli.Commands.AppImage;

public partial class AppImageSyncMeta : GlobalSettingsCommand
{
    private string? Package { get; set; }

    private string? Message { get; set; }

    public static Command Create()
    {
        var package = new Argument<string?>("package") { Description = "The search query for the AppImage", Arity = ArgumentArity.ZeroOrOne };

        var command = new Command("sync-meta", "Syncs meta data for an AppImage") { package };

        command.SetAction(async (parseResult, cancellationToken) =>
        {
            var instance = new AppImageSyncMeta
            {
                Package = parseResult.GetValue(package)
            };
            GlobalOptions.Apply(instance, parseResult);
            await instance.ExecuteAsync(new SystemShellyConsole());
            return 0;
        });

        return command;
    }

    public override async ValueTask ExecuteAsync(IShellyConsole console)
    {
        var ansiSupport = AnsiUtilities.SupportsAnsi;
        var installDir = ConfigManager.ReadConfig().AppImageInstallPath ?? XdgPaths.BinHome();
        if (!Directory.Exists(installDir))
        {
            Message = ansiSupport
                ? $"Info: {installDir} directory does not exist. No AppImages to sync.".Pastel(ConsoleColor.Yellow)
                : $"Info: {installDir} directory does not exist. No AppImages to sync.";
            console.WriteLine(Message);
            return;
        }

        var manager = new AppImageManagerV2(ConfigManager.ReadConfig().AppImageInstallPath ?? "");
        
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
                    Message = ansiSupport ? $"[ERROR]{e.Message}".Pastel(ConsoleColor.Red) : $"[ERROR]{e.Message}";
                else
                    Message = ansiSupport ? $"[INFO]{e.Message}".Pastel(ConsoleColor.Blue) : $"[INFO]{e.Message}";
                console.WriteLine(Message);
            };
        }

        if (!string.IsNullOrEmpty(Package))
        {
            var appImages = Directory.GetFiles(installDir, "*.AppImage", SearchOption.TopDirectoryOnly);
            var matches = appImages
                .Where(f => Path.GetFileName(f).Contains(Package, StringComparison.OrdinalIgnoreCase))
                .ToList();

            if (matches.Count == 0)
            {
                Message = ansiSupport
                    ? $"No AppImage matching \"{Package}\" found in {installDir}".Pastel(ConsoleColor.Yellow)
                    : $"No AppImage matching \"{Package}\" found in {installDir}";
                return;
            }
            
            var package = new List<string> { Path.GetFileNameWithoutExtension(matches.First()) };
            await manager.SyncAppImageMeta(package);
        }
        else
        {
            var appImages = Directory.GetFiles(installDir, "*.AppImage", SearchOption.TopDirectoryOnly);
            var appImageNames = appImages.Select(Path.GetFileNameWithoutExtension).Cast<string>().ToList();
            await manager.SyncAppImageMeta(appImageNames);
        }
    }

    public override async ValueTask ExecuteUiMode()
    {
        //Unneeded as the command is not interactive.
    }
}