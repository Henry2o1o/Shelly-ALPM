using System.Drawing;
using CliFx.Infrastructure;
using Pastel;
using Shelly.Cli.Interactions;

namespace Shelly.Cli.Commands.Utility;

public class FixPermissions : GlobalSettingsCommand
{
    public override async ValueTask ExecuteAsync(IConsole console)
    {
        RootElevator.EnsureRootExectuion();

        var isAnsiSupported = AnsiUtilities.SupportsAnsi;
        string message;
        var user = Environment.GetEnvironmentVariable("SUDO_USER");
        if (string.IsNullOrEmpty(user) || user == "root")
        {
            message = isAnsiSupported
                ? "Could not determin invoking user (SUDO_USER not set).".Pastel(Color.Red)
                : "Could not determin invoking user (SUDO_USER not set).";
            console.WriteLine(message);
        }
    }

    public override async ValueTask ExecuteUiMode()
    {
        throw new NotImplementedException();
    }
}