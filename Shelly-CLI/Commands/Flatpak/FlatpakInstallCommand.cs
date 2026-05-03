using System.Diagnostics.CodeAnalysis;
using PackageManager.Flatpak;
using Shelly_CLI.Utility;
using Spectre.Console;
using Spectre.Console.Cli;

namespace Shelly_CLI.Commands.Flatpak;

public class FlatpakInstallCommand : Command<FlatpakPackageSettings>
{
    public override int Execute([NotNull] CommandContext context, [NotNull] FlatpakPackageSettings settings)
    {
        if (Program.IsUiMode)
        {
            return HandleUiModeInstall(settings);
        }

        AnsiConsole.MarkupLine("[yellow]Flatpak App installieren …[/]");
        var manager = new FlatpakManager();
        var result = manager.InstallApp(settings.Packages, settings.Remote, settings.IsUser, settings.Branch ?? "stable", settings.IsRuntime);

        AnsiConsole.MarkupLine("[yellow]Installed: " + result.EscapeMarkup() + "[/]");

        return 0;
    }

    private static int HandleUiModeInstall(FlatpakPackageSettings settings)
    {
        Console.Error.WriteLine("Flatpak App installieren  …");
        var manager = new FlatpakManager();
        var result = manager.InstallApp(settings.Packages, settings.Remote, settings.IsUser);

        Console.Error.WriteLine("Installiert: " + result);

        return 0;
    }
}
