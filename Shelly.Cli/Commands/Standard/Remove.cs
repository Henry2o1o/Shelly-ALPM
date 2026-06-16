using System.CommandLine;
using PackageManager.Alpm;
using PackageManager.Local;
using Shelly.Cli.Interactions;
using Shelly.Cli.Outputs;

namespace Shelly.Cli.Commands.Standard;

public class Remove : GlobalSettingsCommand
{
    private bool Cascade { get; set; }

    private bool OptDeps { get; set; }

    private bool Ripple { get; set; }

    private bool RemoveConfig { get; set; }

    private bool Local { get; set; }

    private string[] Package { get; set; } = Array.Empty<string>();

    public static Command Create()
    {
        var cascade = new Option<bool>("--cascade", "-c")
            { Description = "Removes all things the removed package(s) are dependent on that have no other uses" };
        var optDeps = new Option<bool>("--opt-deps", "-o")
            { Description = "Removes optional dependencies installed with the package, that don't depend on other packages" };
        var ripple = new Option<bool>("--ripple", "-i")
            { Description = "Removes packages that depend on the package being removed" };
        var removeConfig = new Option<bool>("--remove-config", "-r")
            { Description = "Removes any files in your ~/.config that can be tied exclusively to the removed package(s). EXPERIMENTAL" };
        var local = new Option<bool>("--local", "-l")
            { Description = "Force removal as a locally-installed binary package" };
        var package = new Argument<string[]>("package")
            { Description = "The packages to remove (repo names or local binary packages)", Arity = ArgumentArity.ZeroOrMore };

        var command = new Command("remove", "Remove packages (repo or local binary)")
        {
            cascade, optDeps, ripple, removeConfig, local, package
        };

        command.SetAction(async (parseResult, _) =>
        {
            var instance = new Remove
            {
                Cascade = parseResult.GetValue(cascade),
                OptDeps = parseResult.GetValue(optDeps),
                Ripple = parseResult.GetValue(ripple),
                RemoveConfig = parseResult.GetValue(removeConfig),
                Local = parseResult.GetValue(local),
                Package = parseResult.GetValue(package) ?? Array.Empty<string>()
            };
            GlobalOptions.Apply(instance, parseResult);
            await instance.ExecuteAsync(new SystemShellyConsole());
            return 0;
        });

        return command;
    }

    private (List<string> Repo, List<string> Local) PartitionPackages()
    {
        if (Local)
            return ([], Package.ToList());

        var installedBinaries = LocalManager.GetInstalledBinaryPackages()
            .Select(p => p.Name)
            .ToHashSet(StringComparer.OrdinalIgnoreCase);

        var repo = new List<string>();
        var local = new List<string>();
        foreach (var name in Package)
            (installedBinaries.Contains(name) ? local : repo).Add(name);

        return (repo, local);
    }

    public override async ValueTask ExecuteAsync(IShellyConsole console)
    {
        if (UiMode)
        {
            await ExecuteUiMode();
            return;
        }

        if (Package.Length == 0)
        {
            console.WriteLine(AnsiUtilities.Colorize("Error: No packages specified", ConsoleColor.Red));
            return;
        }

        RootElevator.EnsureRootExectuion();

        var (repo, local) = PartitionPackages();

        console.WriteLine(AnsiUtilities.Colorize(
            $"Packages to remove: {string.Join(", ", Package)}", ConsoleColor.Yellow));

        if (!NoConfirm && !Confirm.Execute("Do you want to proceed?"))
        {
            console.WriteLine(AnsiUtilities.Colorize("Operation cancelled.", ConsoleColor.Yellow));
            return;
        }

        if (repo.Count > 0)
            await RemoveRepoPackages(repo, console);

        if (local.Count > 0)
            await RemoveLocalPackages(local, console);

        if (RemoveConfig)
            HandleConfigRemoval(Package, console);
    }

    private async Task RemoveRepoPackages(List<string> packageList, IShellyConsole console)
    {
        using var manager = new AlpmManager();
        console.WriteLine(AnsiUtilities.Colorize("Initializing ALPM...", ConsoleColor.Yellow));
        manager.Initialize(true);

        console.WriteLine(AnsiUtilities.Colorize("Removing packages...", ConsoleColor.Yellow));

        var flags = AlpmTransFlag.None;
        if (Cascade)
            flags |= AlpmTransFlag.NoSave | AlpmTransFlag.Recurse;
        else if (Ripple)
            flags |= AlpmTransFlag.Cascade;

        var result = await StandardSinglePaneOutput.Output(console, manager,
            x => x.RemovePackages(packageList, flags, OptDeps), NoConfirm);

        if (!result)
        {
            console.WriteLine(AnsiUtilities.Colorize("Removal failed. See errors above.", ConsoleColor.Red));
            return;
        }

        console.WriteLine(AnsiUtilities.Colorize("Packages removed successfully!", ConsoleColor.Green));
    }

    private async Task RemoveLocalPackages(List<string> packageList, IShellyConsole console)
    {
        var localManager = new LocalManager();
        localManager.Message += (_, e) =>
        {
            var color = e.Level switch
            {
                LocalManagerMessageLevel.Info => ConsoleColor.Cyan,
                LocalManagerMessageLevel.Warning => ConsoleColor.Yellow,
                LocalManagerMessageLevel.Error => ConsoleColor.Red,
                LocalManagerMessageLevel.Success => ConsoleColor.Green,
                _ => ConsoleColor.White
            };
            console.WriteLine(AnsiUtilities.Colorize(e.Message, color));
        };

        await localManager.RemoveBinaryPackages(packageList);
    }

    public override async ValueTask ExecuteUiMode()
    {
        if (Package.Length == 0)
        {
            UiFrames.Error("No packages specified");
            return;
        }

        var (repo, local) = PartitionPackages();

        if (repo.Count > 0)
            await RemoveRepoPackagesUi(repo);

        if (local.Count > 0)
            await RemoveLocalPackagesUi(local);

        if (RemoveConfig)
            HandleConfigRemoval(Package, null);
    }

    private async Task RemoveRepoPackagesUi(List<string> packageList)
    {
        var flags = AlpmTransFlag.None;
        if (Cascade)
            flags |= AlpmTransFlag.NoSave | AlpmTransFlag.Recurse;
        else if (Ripple)
            flags |= AlpmTransFlag.Cascade;

        using var manager = new AlpmManager();
        manager.Question += (_, args) => QuestionHandler.HandleQuestion(args, true, NoConfirm);
        manager.Initialize(true);

        UiFrames.TxStart($"Removing packages: {string.Join(", ", packageList)}");

        var ok = await UiModeOutput.Run(manager, m => m.RemovePackages(packageList, flags, OptDeps));

        UiFrames.TxFinish(ok, "Packages removed successfully!", "Removal failed.");
    }

    private async Task RemoveLocalPackagesUi(List<string> packageList)
    {
        var localManager = new LocalManager();
        localManager.Message += (_, e) =>
        {
            switch (e.Level)
            {
                case LocalManagerMessageLevel.Info:
                case LocalManagerMessageLevel.Success:
                    UiFrames.Info(e.Message);
                    break;
                case LocalManagerMessageLevel.Warning:
                    UiFrames.Info($"Warning: {e.Message}");
                    break;
                case LocalManagerMessageLevel.Error:
                    UiFrames.Error(e.Message);
                    break;
            }
        };

        await localManager.RemoveBinaryPackages(packageList);
    }

    private static void HandleConfigRemoval(string[] packageNames, IShellyConsole? console)
    {
        foreach (var package in packageNames)
        {
            var path = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), package);
            try
            {
                Directory.Delete(path, true);
            }
            catch (Exception)
            {
                console?.WriteLine(AnsiUtilities.Colorize(
                    $"Failed to find directory for {package} moving on", ConsoleColor.Yellow));
            }
        }
    }
}
