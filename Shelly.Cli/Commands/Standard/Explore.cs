using System.Drawing;
using System.Text;
using System.Text.Json;
using CliFx.Binding;
using CliFx.Infrastructure;
using PackageManager.Alpm;
using PackageManager.Local;
using Shelly.Cli.Interactions;
using Shelly.Utilities;
using Shelly.Utilities.Enums;
using Shelly.Utilities.Eventing;

namespace Shelly.Cli.Commands.Standard;

[Command("explore", Description = "Explore repositories and packages")]
public partial class Explore : GlobalSettingsCommand
{
    [CommandOption("repos", 'r', Description = "List available repositories. This supercedes any other modifiers.")]
    private bool Repos { get; set; }

    [CommandOption("available", 'a', Description = "Include available packages in the search")]
    private bool Available { get; set; }

    [CommandOption("installed", 'i', Description = "Include installed packages in the search")]
    private bool Installed { get; set; }

    [CommandOption("local", 'l', Description = "Include local packages in the search")]
    private bool Local { get; set; }

    [CommandOption("take", 't', Description = "Number of results to return")]
    private int Take { get; set; } = 100;

    [CommandOption("page", 'p', Description = "Page number")]
    private int Page { get; set; } = 1;

    [CommandOption("show-hidden", 'w', Description = "Show hidden packages")]
    private bool ShowHidden { get; set; }

    [CommandParameter(0, Description = "The package to search for")]
    private string? Package { get; set; }


    public override async ValueTask ExecuteAsync(IConsole console)
    {
        if (UiMode)
        {
            await ExecuteUiMode();
            return;
        }

        if (Repos)
        {
            var repo = AlpmManager.GetRepositories();
            foreach (var r in repo)
            {
                console.WriteLine(AnsiUtilities.Colorize(r, Color.BlanchedAlmond));
            }

            return;
        }

        List<AlpmPackageDto> packages = [];
        using var manager = new AlpmManager();
        manager.Initialize(showHiddenPackages: ShowHidden);
        List<LocalPackageDto> localPackages = [];
        if (Installed)
            packages.AddRange(manager.GetInstalledPackages());
        if (Available)
            packages.AddRange(manager.GetAvailablePackages());
        if (Local)
            localPackages.AddRange(LocalManager.GetInstalledBinaryPackages());

        var config = ConfigManager.ReadConfig();
        var sizeDisplay = config.FileSizeDisplay;
        if (Package != null)
        {
            packages = packages
                .Select(x => new { Package = x, Score = StringMatcher.PartialRatio(Package, x.Name) })
                .Where(x => x.Score >= 90)
                .Select(x => x.Package)
                .ToList();

            localPackages = localPackages
                .Select(x => new { Package = x, Score = StringMatcher.PartialRatio(Package, x.Name) })
                .Where(x => x.Score >= 90).Select(x => x.Package).ToList();
        }

        if (JsonOutput)
        {
            if (packages.Count > 0)
                console.WriteLine(JsonSerializer.Serialize(packages, ShellyCliJsonContext.Default.ListAlpmPackageDto));
            if (localPackages.Count > 0)
                console.WriteLine(JsonSerializer.Serialize(localPackages,
                    ShellyCliJsonContext.Default.ListLocalPackageDto));
            return;
        }

        if (localPackages.Count > 0)
        {
            var table = BasicTable.Execute(["Name", "Size"], localPackages, c => c.Name,
                c => SizeUtilities.FormatSize(Enum.Parse<SizeDisplay>(sizeDisplay), c.Size));
            console.WriteLine(table);
        }

        if (packages.Count > 0)
        {
            var table = BasicTable.Execute(["Name", "Repository", "Version", "Size", "Description"], packages,
                c => c.Name,
                c => c.Repository,
                c => c.Version,
                c => SizeUtilities.FormatSize(Enum.Parse<SizeDisplay>(sizeDisplay), c.Size),
                c => c.Description.Truncate(50));
            console.WriteLine(table);
        }

        var stringBuilder = new StringBuilder();
        if (packages.Count > 0)
        {
            stringBuilder.AppendLine($"Total: {packages.Count} packages");
        }

        if (localPackages.Count > 0)
        {
            stringBuilder.AppendLine($"Total: {localPackages.Count} local packages");
        }

        console.WriteLine(AnsiUtilities.Colorize(stringBuilder.ToString(), Color.BlanchedAlmond));
    }

    public override async ValueTask ExecuteUiMode()
    {
        if (Repos)
        {
            var repos = AlpmManager.GetRepositories();
            JsonPackFrame.WriteToStdout(repos);
            JsonPackFrame.WriteToStdout<Event>(new AlpmInformationalEvent(AlpmEvents.InformationalOutput,
                $"Total: {repos.Count} repositories"));
            return;
        }
    }
}