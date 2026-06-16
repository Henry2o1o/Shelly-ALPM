using System.CommandLine;
using PackageManager.Alpm;
using Shelly.Cli.Interactions;
using Shelly.Cli.Outputs;

namespace Shelly.Cli.Commands.Standard;

public class Update : GlobalSettingsCommand
{
    private string[] Package { get; set; } = Array.Empty<string>();

    public static Command Create()
    {
        var package = new Argument<string[]>("package")
        {
            Description = "The packages to update",
            Arity = ArgumentArity.ZeroOrMore
        };

        var command = new Command("update", "Update specific packages") { package };

        command.SetAction(async (parseResult, _) =>
        {
            var instance = new Update
            {
                Package = parseResult.GetValue(package) ?? Array.Empty<string>()
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

        if (Package.Length == 0)
        {
            console.WriteLine(AnsiUtilities.Colorize("Error: No packages specified", ConsoleColor.Red));
            return;
        }

        RootElevator.EnsureRootExectuion();

        var packageList = Package.ToList();

        console.WriteLine(AnsiUtilities.Colorize(
            $"Packages to update: {string.Join(", ", packageList)}", ConsoleColor.Yellow));

        if (!NoConfirm)
        {
            console.WriteLine(AnsiUtilities.Colorize(
                "WARNING: Updating individual packages is a partial upgrade and is strongly discouraged on Arch Linux.",
                ConsoleColor.Red));
            console.WriteLine(AnsiUtilities.Colorize(
                "Partial upgrades can break your system. The supported way to update is a full system upgrade (shelly upgrade).",
                ConsoleColor.Red));

            if (!Confirm.Execute("Are you absolutely sure you want to continue with this partial upgrade?"))
            {
                console.WriteLine(AnsiUtilities.Colorize("Operation cancelled.", ConsoleColor.Yellow));
                return;
            }

            if (!Confirm.Execute("Do you want to proceed?"))
            {
                console.WriteLine(AnsiUtilities.Colorize("Operation cancelled.", ConsoleColor.Yellow));
                return;
            }
        }

        using var manager = new AlpmManager();
        console.WriteLine(AnsiUtilities.Colorize("Initializing and syncing ALPM...", ConsoleColor.Yellow));
        manager.IntializeWithSync();

        console.WriteLine(AnsiUtilities.Colorize("Updating packages...", ConsoleColor.Yellow));
        var result = await StandardSinglePaneOutput.Output(
            console, manager, m => m.UpdatePackages(packageList), NoConfirm);

        console.WriteLine(result
            ? AnsiUtilities.Colorize("Packages updated successfully!", ConsoleColor.Green)
            : AnsiUtilities.Colorize("Update failed. See errors above.", ConsoleColor.Red));
    }

    public override async ValueTask ExecuteUiMode()
    {
        if (Package.Length == 0)
        {
            UiFrames.Error("No packages specified");
            return;
        }

        var packageList = Package.ToList();

        using var manager = new AlpmManager();
        manager.Question += (_, args) => QuestionHandler.HandleQuestion(args, true, NoConfirm);
        manager.IntializeWithSync();

        UiFrames.TxStart($"Updating packages: {string.Join(", ", packageList)}");

        var ok = await UiModeOutput.Run(manager, m => m.UpdatePackages(packageList));

        UiFrames.TxFinish(ok, "Packages updated successfully!", "Update failed.");
    }
}
