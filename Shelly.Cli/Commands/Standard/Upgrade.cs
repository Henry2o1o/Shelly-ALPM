using System.CommandLine;
using System.Drawing;
using PackageManager.Alpm;
using PackageManager.Utilities;
using Pastel;
using Shelly.Cli.Interactions;
using Shelly.Cli.Outputs;
using Shelly.Utilities;
using Shelly.Utilities.Enums;
using static System.Enum;

namespace Shelly.Cli.Commands.Standard;

public partial class UpgradeCommand : GlobalSettingsCommand
{
    public static Command Create()
    {
        var command = new Command("upgrade", "Perform a full system upgrade");

        command.SetAction(async (parseResult, cancellationToken) =>
        {
            var instance = new UpgradeCommand();
            GlobalOptions.Apply(instance, parseResult);
            await instance.ExecuteAsync(new SystemShellyConsole());
            return 0;
        });

        return command;
    }

    public override async ValueTask ExecuteAsync(IShellyConsole console)
    {
        var message = "";
        var ansiSupport = AnsiUtilities.SupportsAnsi;
        if (UiMode)
        {
            await ExecuteUiMode();
            return;
        }

        RootElevator.EnsureRootExectuion();
        var archNews = new ArchNews();
        await archNews.ExecuteAsync(console);
        message = ansiSupport
            ? "Performing full system upgrade...".Pastel(Color.Yellow)
            : "Performing full system upgrade...";
        console.WriteLine(message);
        message = ansiSupport
            ? "Initializing and syncing repositories...".Pastel(Color.Yellow)
            : "Initializing and syncing repositories...";
        console.WriteLine(message);
        var manager = new AlpmManager();
        manager.Initialize(true);
        manager.Sync();
        var packagesNeedingUpdate = manager.GetPackagesNeedingUpdate();
        if (packagesNeedingUpdate.Count == 0)
        {
            message = ansiSupport
                ? "Standard Packages are up to date!".Pastel(Color.Green)
                : "Standard Packages are up to date!";
            console.WriteLine(message);
            return;
        }

        var config = ConfigManager.ReadConfig();
        var parsedSize = Parse<SizeDisplay>(config.FileSizeDisplay);
        var headers = new[] { "Repository", "Package", "Old Version", "New Version", "Net Change", "Download Size" };
        var table = BasicTable.Execute(headers, packagesNeedingUpdate, p => p.Repository,
            p => ansiSupport ? p.Name.Pastel(Color.Cyan) : p.Name,
            p => ansiSupport ? p.CurrentVersion.Pastel(Color.Cyan) : p.CurrentVersion,
            p => ansiSupport ? p.NewVersion.Pastel(Color.Cyan) : p.NewVersion,
            p => ansiSupport
                ? SizeUtilities.FormatSize(parsedSize, p.SizeDifference).Pastel(Color.Cyan)
                : SizeUtilities.FormatSize(parsedSize, p.SizeDifference),
            p => ansiSupport
                ? SizeUtilities.FormatSize(parsedSize, p.DownloadSize).Pastel(Color.Cyan)
                : SizeUtilities.FormatSize(parsedSize, p.DownloadSize));
        console.Write(table);
        console.WriteLine();
        message = ansiSupport
            ? $"Total Download Size: {SizeUtilities.FormatSize(parsedSize, packagesNeedingUpdate.Sum(p => p.DownloadSize))}"
                .Pastel(Color.DarkGreen)
            : $"Total Download Size: {SizeUtilities.FormatSize(parsedSize, packagesNeedingUpdate.Sum(p => p.DownloadSize))}";
        console.WriteLine(message);
        message = ansiSupport
            ? $"Net Upgrade Size: {SizeUtilities.FormatSize(parsedSize, packagesNeedingUpdate.Sum(p => p.SizeDifference))}"
                .Pastel(Color.DarkGreen)
            : $"Net Upgrade Size: {SizeUtilities.FormatSize(parsedSize, packagesNeedingUpdate.Sum(p => p.SizeDifference))}";
        console.WriteLine(message);
        console.WriteLine();

        var result = Confirm.Execute("Proceed with upgrade?", false);
        if (!result)
        {
            message = ansiSupport ? "Upgrade cancelled.".Pastel(Color.Red) : "Upgrade cancelled.";
            console.WriteLine(message);
            return;
        }

        message = ansiSupport ? "Starting Systeam Upgrade...".Pastel(Color.Green) : "Starting Systeam Upgrade...";
        console.WriteLine(message);
        var upgradeResult =
            await StandardSinglePaneOutput.Output(console, manager, x => x.SyncSystemUpdate(), NoConfirm);
        manager.Dispose();
        if (!upgradeResult)
        {
            message = ansiSupport ? "System upgrade failed.".Pastel(Color.Red) : "System upgrade failed.";
            console.WriteLine(message);
        }

        message = ansiSupport ? "System upgrade complete.".Pastel(Color.Green) : "System upgrade complete.";
        console.WriteLine(message);
    }

    public override async ValueTask ExecuteUiMode()
    {
        UiFrames.Info("Performing full system upgrade...");

        using var manager = new AlpmManager();
        manager.Question += (_, args) => QuestionHandler.HandleQuestion(args, true, NoConfirm);

        UiFrames.Info("Initializing and syncing repositories...");
        manager.IntializeWithSync();
        var packagesNeedingUpdate = manager.GetPackagesNeedingUpdate();
        if (packagesNeedingUpdate.Count == 0)
        {
            UiFrames.Info("Standard Packages are up to date!");
            return;
        }

        UiFrames.TxStart($"Upgrading {packagesNeedingUpdate.Count} packages...");
        var ok = await UiModeOutput.Run(manager, m => m.SyncSystemUpdate());
        UiFrames.TxFinish(ok, "System upgraded successfully!", "System upgrade failed.");
        var (needsReboot, services) = RestartManager.CheckForRequiredRestarts();
        if (needsReboot)
        {
            UiFrames.Info("[RESTART_REQUIRED]reboot");
        }
        else if (services.Count > 0)
        {
            var failures = await RestartManager.RestartServicesAsync(services);
            foreach (var (svc, error) in failures)
                UiFrames.Error($"[RESTART_FAILED]service:{svc}|{error}");
        }
    }
}