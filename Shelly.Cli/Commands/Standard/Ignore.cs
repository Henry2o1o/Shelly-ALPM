using System.Drawing;
using System.Text.Json;
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

    [CommandParameter(0,Description = "The packages to interact with")]
    private string[] Packages { get; set; } = Array.Empty<string>();

    private string _message = "";
    private bool _isAnsiSupported;

    public override async ValueTask ExecuteAsync(IConsole console)
    {
        _isAnsiSupported = AnsiUtilities.SupportsAnsi;
        if (Packages.Length == 0 && !List && !Clear)
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
        if (Add)
        {
            manager.IgnorePackages(Packages);
            var formatPackages = string.Join(", ", Packages);
            if (UiMode)
            {
                UiFrames.Info($"Added to IgnorePkg list: {formatPackages}");
                return;
            }

            _message = _isAnsiSupported
                ? $"Added to IgnorePkg list: {formatPackages}".Pastel(Color.Green)
                : $"Added to IgnorePkg list: {formatPackages}";
            console.WriteLine(_message);
            return;
        }

        if (Remove)
        {
            manager.UnignorePackages(Packages);
            var formatPackages = string.Join(", ", Packages);
            if (UiMode)
            {
                UiFrames.Info($"Removed from IgnorePkg list: {formatPackages}");
                return;
            }

            _message = _isAnsiSupported
                ? $"Removed from IgnorePkg list: {formatPackages}".Pastel(Color.Green)
                : $"Removed from IgnorePkg list: {formatPackages}";
            console.WriteLine(_message);
            return;
        }

        var ignored = manager.GetIgnoredPackages();
        if (Clear)
        {
            manager.UnignorePackages(ignored);
            if (UiMode)
            {
                UiFrames.Info($"Cleared ignored pacakges.");
                return;
            }

            _message = _isAnsiSupported
                ? $"Cleared ignored pacakges.".Pastel(Color.Green)
                : $"Cleared ignored pacakges.";
            console.WriteLine(_message);
            return;
        }

        if (List)
        {
            if (UiMode)
            {
                UiFrames.Frame(ignored);
                UiFrames.Info(ignored.Count == 0 ? "IgnorePkg list is empty." : $"Total: {ignored.Count} ignored packages");
                return;
            }

            if (JsonOutput)
            {
                var json = JsonSerializer.Serialize(ignored, ShellyCliJsonContext.Default.ListString);
                console.WriteLine(json);
                return;
            }

            if (ignored.Count == 0)
            {
                _message = _isAnsiSupported ? "IgnorePkg list is empty.".Pastel(Color.Yellow) : "IgnorePkg list is empty.";
                console.WriteLine(_message);
                return;
            }
            var formatPackages = string.Join(", ", ignored);
            _message = _isAnsiSupported
                ? $"Total: {ignored.Count} ignored packages: {formatPackages}".Pastel(Color.Green)
                : $"Total: {ignored.Count} ignored packages: {formatPackages}";
            console.WriteLine(_message);
        }
    }

    public override async ValueTask ExecuteUiMode()
    {
        //Unneeded as the command is not interactive.
    }
    
}