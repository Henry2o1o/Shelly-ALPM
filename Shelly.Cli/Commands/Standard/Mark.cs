using System.CommandLine;
using System.Drawing;
using Shelly.Cli.Interactions;

namespace Shelly.Cli.Commands.Standard;

public class Mark : GlobalSettingsCommand
{
    private bool Explicit { get; set; }

    private bool Depends { get; set; }

    private string? Package { get; set; }

    public static Command Create()
    {
        var explicitOption = new Option<bool>("--explicit", "-e") { Description = "Mark the package as explicit" };
        var dependsOption = new Option<bool>("--depends", "-d") { Description = "Mark the package as a dependency" };
        var packageOption = new Argument<string?>("package")
            { Description = "The package to mark", Arity = ArgumentArity.ZeroOrOne };
        var command = new Command("mark", "Mark a package as explicit or a dependency")
        {
            explicitOption, dependsOption, packageOption
        };
        command.SetAction(async (parseResult, cancellationToken) =>
        {
            var instance = new Mark()
            {
                Explicit = parseResult.GetValue(explicitOption),
                Depends = parseResult.GetValue(dependsOption),
                Package = parseResult.GetValue(packageOption)
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

        if (Package is null)
        {
            console.WriteLine(AnsiUtilities.Colorize("Error: No packages specified", Color.Red));
            return;
        }
        RootElevator.EnsureRootExectuion();

        throw new NotImplementedException();
    }

    public override async ValueTask ExecuteUiMode()
    {
        throw new NotImplementedException();
    }
}