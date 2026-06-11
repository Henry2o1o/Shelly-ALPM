using System.Drawing;
using CliFx.Binding;
using CliFx.Infrastructure;
using PackageManager.Alpm;
using PackageManager.Aur;
using PackageManager.Aur.Models;
using PackageManager.Flatpak;
using Pastel;
using Shelly.Cli.Interactions;
using Shelly.Cli.Models.Sync;
using Shelly.Utilities;
using Shelly.Utilities.Enums;

namespace Shelly.Cli.Commands.Utility;

[Command("check-updates", Description = "Check for package updates")]
public partial class CheckPackageUpdateNonRootCommand : GlobalSettingsCommand
{
    [CommandOption("aur", 'a', Description = "Check for AUR updates")]
    private bool Aur { get; set; }

    [CommandOption("flatpak", 'l', Description = "Check for Flatpak updates")]
    private bool Flatpak { get; set; }

    [CommandOption("count", 'c', Description = "Returns the number of updates")]
    private bool Count { get; set; }


    public override ValueTask ExecuteAsync(IConsole console)
    {
        if (UiMode)
        {
            return ExecuteUiMode();
        }

        string message;
        var isAnsiSupported = AnsiUtilities.SupportsAnsi;
        var config = ConfigManager.ReadConfig();
        var sizeDisplay = Enum.Parse<SizeDisplay>(config.FileSizeDisplay);
        List<AlpmPackageUpdateDto> alpmPackages = [];
        var aurManager = new AurPackageManager();
        List<AurUpdateDto> aurPackages = [];
        List<FlatpakPackageDto> flatpakPackages = [];
        var dbPath = XdgPaths.ShellyCache("db");
        Directory.CreateDirectory(dbPath);
        if (Verbose)
        {
            message = isAnsiSupported ? $"Using {dbPath}".Pastel(Color.Chartreuse) : $"Using {dbPath}";
            console.WriteLine(message);
        }


        throw new NotImplementedException();
    }

    public override ValueTask ExecuteUiMode()
    {
        throw new NotImplementedException();
    }

    private List<SyncStandard> GetSyncStandards(string tempPath)
    {
        var alpmManager = new AlpmManager();
        alpmManager.Initialize(useTempPath: true, tempPath: tempPath);
        alpmManager.Sync();
        var alpmPackages = alpmManager.GetPackagesNeedingUpdate();
        alpmManager.Dispose();
        return alpmPackages.Select(pkg => new SyncStandard(pkg.Name, pkg.NewVersion, pkg.CurrentVersion,
            pkg.DownloadSize.ToString()
        )).ToList();
    }
}