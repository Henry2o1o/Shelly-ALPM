using System.Drawing;
using CliFx.Binding;
using CliFx.Infrastructure;
using PackageManager.Alpm;
using Pastel;
using Shelly.Cli.Interactions;

namespace Shelly.Cli.Commands.Standard;

[Command("ignore", Description = "Manage ignored packages")]
public partial class Ignore : GlobalSettingsCommand
{
    [CommandOption("list", 'l', Description = "List ignored packages")]
    private bool List { get; set; }

    [CommandOption("add", 'a', Description = "Add a package to the ignore list")]
    private bool Add { get; set; }

    [CommandOption("remove", 'r', Description = "Remove a package from the ignore list")]
    private bool Remove { get; set; }

    [CommandOption("clear", 'c', Description = "Clear the ignore list")]
    private bool Clear { get; set; }

    [CommandParameter(0, Description = "The packages to interact with")]
    private string[] Packages { get; set; } = Array.Empty<string>();

    private string _message;
    private bool _isAnsiSupported;

    public override async ValueTask ExecuteAsync(IConsole console)
    {
        _isAnsiSupported = AnsiUtilities.SupportsAnsi;
        if (Packages.Length == 0)
        {
            if (UiMode)
            {
                UiFrames.Error("No packages specified");
            }
            else
            {
                _message = _isAnsiSupported ? $"No packages specified".Pastel(Color.Red) : $"No packages specified";
                console.WriteLine(_message);
            }

            return;
        }

        if (UiMode)
        {
            await ExecuteUiMode();
            return;
        }


        RootElevator.EnsureRootExectuion();
        using var manager = new AlpmManager();
        
    }

    public override async ValueTask ExecuteUiMode()
    {
        throw new NotImplementedException();
    }

    private async ValueTask AddIgnore(string[] packages, IConsole console, IAlpmManager manager)
    {
        manager.IgnorePackages(packages);
    }
}