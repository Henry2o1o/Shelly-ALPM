using System.Drawing;
using System.CommandLine;
using System.Text;
using System.Text.Json;
using PackageManager.Alpm;
using PackageManager.Local;
using Shelly.Cli.Interactions;
using Shelly.Utilities;
using Shelly.Utilities.Enums;
using Shelly.Utilities.Eventing;

namespace Shelly.Cli.Commands.Standard;

public partial class Explore : GlobalSettingsCommand
{
    private bool Repos { get; set; }

    private bool Available { get; set; }

    private bool Installed { get; set; }

    private bool Local { get; set; }

    private int Take { get; set; } = 100;

    private int Page { get; set; } = 1;

    private bool ShowHidden { get; set; }

    private string? Package { get; set; }

    public static Command Create()
    {
        var repos = new Option<bool>("--repos", "-r") { Description = "List available repositories. This supercedes any other modifiers." };
        var available = new Option<bool>("--available", "-a") { Description = "Include available packages in the search" };
        var installed = new Option<bool>("--installed", "-i") { Description = "Include installed packages in the search" };
        var local = new Option<bool>("--local", "-l") { Description = "Include local packages in the search" };
        var take = new Option<int>("--take", "-t") { Description = "Number of results to return", DefaultValueFactory = _ => 100 };
        var page = new Option<int>("--page", "-p") { Description = "Page number", DefaultValueFactory = _ => 1 };
        var showHidden = new Option<bool>("--show-hidden", "-w") { Description = "Show hidden packages" };
        var package = new Argument<string?>("package") { Description = "The package to search for", Arity = ArgumentArity.ZeroOrOne };

        var command = new Command("explore", "Explore repositories and packages")
        {
            repos, available, installed, local, take, page, showHidden, package
        };

        command.SetAction(async (parseResult, cancellationToken) =>
        {
            var instance = new Explore
            {
                Repos = parseResult.GetValue(repos),
                Available = parseResult.GetValue(available),
                Installed = parseResult.GetValue(installed),
                Local = parseResult.GetValue(local),
                Take = parseResult.GetValue(take),
                Page = parseResult.GetValue(page),
                ShowHidden = parseResult.GetValue(showHidden),
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