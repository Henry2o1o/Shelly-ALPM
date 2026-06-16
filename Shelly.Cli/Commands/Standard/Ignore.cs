using System.CommandLine;
using System.Drawing;
using System.Text.Json;
using PackageManager.Alpm;
using Pastel;
using Shelly.Cli.Interactions;
using static System.CommandLine.ArgumentArity;

namespace Shelly.Cli.Commands.Standard;

public class Ignore : GlobalSettingsCommand
{
    private bool List { get; set; }

    private bool Add { get; set; }

    private bool Remove { get; set; }

    private bool Clear { get; set; }

    private string[] Packages { get; set; } = [];

    public static Command Create()
    {
        var list = new Option<bool>("--list", "-l") { Description = "List ignored packages" };
        var add = new Option<bool>("--add", "-a") { Description = "Add a package to the ignore list" };
        var remove = new Option<bool>("--remove", "-r") { Description = "Remove a package from the ignore list" };
        var clear = new Option<bool>("--clear", "-c") { Description = "Clear the ignore list" };
        var packages = new Argument<string[]>("packages") { Description = "The packages to interact with", Arity = ZeroOrMore };

        var command = new Command("ignore", "Manage ignored packages") { list, add, remove, clear, packages };

        command.SetAction(async (parseResult, _) =>
        {
            var instance = new Ignore
            {
                List = parseResult.GetValue(list),
                Add = parseResult.GetValue(add),
                Remove = parseResult.GetValue(remove),
                Clear = parseResult.GetValue(clear),
                Packages = parseResult.GetValue(packages) ?? []
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

        var isAnsiSupported = AnsiUtilities.SupportsAnsi;
        string message;
        if (Packages.Length == 0 && !List && !Clear)
        {
            message = isAnsiSupported ? "No packages specified".Pastel(Color.Red) : "No packages specified";
            console.WriteLine(message);

            return;
        }

        RootElevator.EnsureRootExectuion();
        using var manager = new AlpmManager();
        if (Add)
        {
            manager.IgnorePackages(Packages);
            var formatPackages = string.Join(", ", Packages);

            message = isAnsiSupported
                ? $"Added to IgnorePkg list: {formatPackages}".Pastel(Color.Green)
                : $"Added to IgnorePkg list: {formatPackages}";
            console.WriteLine(message);
            return;
        }

        if (Remove)
        {
            manager.UnignorePackages(Packages);
            var formatPackages = string.Join(", ", Packages);

            message = isAnsiSupported
                ? $"Removed from IgnorePkg list: {formatPackages}".Pastel(Color.Green)
                : $"Removed from IgnorePkg list: {formatPackages}";
            console.WriteLine(message);
            return;
        }

        var ignored = manager.GetIgnoredPackages();
        if (Clear)
        {
            manager.UnignorePackages(ignored);

            message = isAnsiSupported
                ? "Cleared ignored packages.".Pastel(Color.Green)
                : "Cleared ignored packages.";
            console.WriteLine(message);
            return;
        }

        if (List)
        {
            if (JsonOutput)
            {
                message = JsonSerializer.Serialize(ignored, ShellyCliJsonContext.Default.ListString);
            }
            else if (ignored.Count == 0)
            {
                message = isAnsiSupported
                    ? "IgnorePkg list is empty.".Pastel(Color.Yellow)
                    : "IgnorePkg list is empty.";
            }
            else
            {
                var formatPackages = string.Join(", ", ignored);
                message = isAnsiSupported
                    ? $"Total: {ignored.Count} ignored packages: {formatPackages}".Pastel(Color.Green)
                    : $"Total: {ignored.Count} ignored packages: {formatPackages}";
            }

            console.WriteLine(message);
        }
    }

    public override async ValueTask ExecuteUiMode()
    {
        if (Packages.Length == 0 && !List && !Clear) UiFrames.Error("No packages specified");

        using var manager = new AlpmManager();
        if (Add)
        {
            manager.IgnorePackages(Packages);
            var formatPackages = string.Join(", ", Packages);
            UiFrames.Info($"Added to IgnorePkg list: {formatPackages}");
            return;
        }

        if (Remove)
        {
            manager.UnignorePackages(Packages);
            var formatPackages = string.Join(", ", Packages);
            UiFrames.Info($"Removed from IgnorePkg list: {formatPackages}");
            return;
        }

        var ignored = manager.GetIgnoredPackages();
        if (Clear)
        {
            manager.UnignorePackages(ignored);
            UiFrames.Info("Cleared ignored packages.");
            return;
        }

        if (List)
        {
            UiFrames.Frame(ignored);
            UiFrames.Info(ignored.Count == 0
                ? "IgnorePkg list is empty."
                : $"Total: {ignored.Count} ignored packages");
        }
    }
}