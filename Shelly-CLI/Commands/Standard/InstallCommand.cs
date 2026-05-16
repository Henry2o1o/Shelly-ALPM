using PackageManager.Alpm;
using Shelly_CLI.Configuration;
using Shelly_CLI.ConsoleLayouts;
using Shelly_CLI.Utility;
using Spectre.Console;
using Spectre.Console.Cli;

namespace Shelly_CLI.Commands.Standard;

public class InstallCommand : AsyncCommand<InstallPackageSettings>
{
    public override async Task<int> ExecuteAsync(CommandContext context, InstallPackageSettings settings)
    {
        if (Program.IsUiMode)
        {
            return await HandleUiModeInstall(context, settings);
        }

        if (settings.Packages.Length == 0)
        {
            AnsiConsole.MarkupLine("[red]Error: No packages specified[/]");
            return 1;
        }

        RootElevator.EnsureRootExectuion();

        var packageList = settings.Packages.ToList();

        AnsiConsole.MarkupLine(
            $"[yellow]Packages to install:[/] {string.Join(", ", packageList.Select(p => p.EscapeMarkup()))}");
        if (!settings.NoConfirm)
        {
            if (!AnsiConsole.Confirm("Do you want to proceed?"))
            {
                AnsiConsole.MarkupLine("[yellow]Operation cancelled.[/]");
                return 0;
            }
        }


        using var manager = new AlpmManager();
        AnsiConsole.MarkupLine("[yellow]Initializing ALPM...[/]");
        manager.Initialize(true);

        var cfg = ConfigManager.ReadConfig();
        var useSinglePane = settings.SinglePane
            || string.Equals(cfg.OutputMode, "singlepane", StringComparison.OrdinalIgnoreCase)
            || Console.IsOutputRedirected;
        Func<IAlpmManager, Func<IAlpmManager, Task<bool>>, bool, Task<bool>> runOutput =
            useSinglePane
                ? (m, op, nc) => StandardSinglePaneOutput.Output(m, op, nc)
                : (m, op, nc) => SplitOutput.Output(m, op, nc);

        if (settings.Upgrade)
        {
            AnsiConsole.Markup("[yellow]Running system upgrade[/yellow]");
            var upgradeResult = await runOutput(manager, x => x.SyncSystemUpdate(), settings.NoConfirm);
            if (!upgradeResult)
            {
                AnsiConsole.MarkupLine("[red]System upgrade failed. See errors above.[/]");
                return 1;
            }
        }

        if (settings.BuildDepsOn)
        {
            if (settings.Packages.Length > 1)
            {
                AnsiConsole.MarkupLine("[yellow]Cannot build dependencies for multiple packages at once.[/]");
                return 0;
            }

            if (settings.MakeDepsOn)
            {
                AnsiConsole.MarkupLine("[yellow]Installing packages...[/]");
                var result = await runOutput(manager,
                    x => x.InstallDependenciesOnly(packageList.First(), true),
                    settings.NoConfirm);
                if (!result)
                {
                    AnsiConsole.MarkupLine("[red]Installation failed. See errors above.[/]");
                    return 1;
                }

                return 0;
            }

            AnsiConsole.MarkupLine("[yellow]Installing packages...[/]");
            var depsResult = await runOutput(manager, x => x.InstallDependenciesOnly(packageList.First()),
                settings.NoConfirm);
            if (!depsResult)
            {
                AnsiConsole.MarkupLine("[red]Installation failed. See errors above.[/]");
                return 1;
            }

            AnsiConsole.MarkupLine("[green]Packages installed successfully![/]");
            return 0;
        }

        if (settings.NoDeps)
        {
            AnsiConsole.MarkupLine("[yellow]Skipping dependency installation.[/]");
            AnsiConsole.MarkupLine("[yellow]Installing packages...[/]");
            var noDepsResult = await runOutput(manager,
                x => x.InstallPackages(packageList, AlpmTransFlag.NoDeps),
                settings.NoConfirm);
            if (!noDepsResult)
            {
                AnsiConsole.MarkupLine("[red]Installation failed. See errors above.[/]");
                return 1;
            }

            AnsiConsole.MarkupLine("[green]Packages installed successfully![/]");
            return 0;
        }

        AnsiConsole.MarkupLine("[yellow]Installing packages...[/]");

        var installResult = await runOutput(manager, x => x.InstallPackages(packageList), settings.NoConfirm);
        Console.WriteLine(); // Final newline after last package

        if (!installResult)
        {
            AnsiConsole.MarkupLine("[red]Installation failed. See errors above.[/]");
            return 1;
        }

        AnsiConsole.MarkupLine("[green]Packages installed successfully![/]");
        return 0;
    }

    private static Task<int> HandleUiModeInstall(CommandContext context, InstallPackageSettings settings)
    {
        if (settings.Packages.Length == 0)
        {
            Console.Error.WriteLine("Error: No packages specified");
            return Task.FromResult(1);
        }

        if (settings.BuildDepsOn && settings.Packages.Length > 1)
        {
            Console.Error.WriteLine("Cannot build dependencies for multiple packages at once.");
            return Task.FromResult(1);
        }

        if (settings.Upgrade)
        {
            var command = new UpgradeCommand();
            command.ExecuteAsync(context, new UpgradeSettings
            {
                JsonOutput = true,
            }).Wait();
        }

        var pkgs = settings.Packages.ToList();

        return UiModeRunner.RunAsync(
            settings.NoConfirm,
            r => settings.BuildDepsOn
                ? r.Manager.InstallDependenciesOnly(pkgs[0], settings.MakeDepsOn)
                : settings.NoDeps
                    ? r.Manager.InstallPackages(pkgs, AlpmTransFlag.NoDeps)
                    : r.Manager.InstallPackages(pkgs),
            successMessage: "Finished installing packages.",
            failureMessage: "Installation failed.");
    }
}