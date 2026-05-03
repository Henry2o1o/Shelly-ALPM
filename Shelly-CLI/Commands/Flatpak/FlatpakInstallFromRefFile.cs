using System.Diagnostics.CodeAnalysis;
using PackageManager.Flatpak;
using Spectre.Console;
using Spectre.Console.Cli;

namespace Shelly_CLI.Commands.Flatpak;

public class FlatpakInstallFromRefFile : Command<FlatpakRemoteRefFileInstallSettings>
{
    public override int Execute([NotNull] CommandContext context, [NotNull] FlatpakRemoteRefFileInstallSettings settings)
    {
        AnsiConsole.MarkupLine("[yellow]Flatpak App installieren …[/]");
        var result = FlatpakManager.InstallAppFromRef(settings.RefFilePath, settings.SystemWide);

        AnsiConsole.MarkupLine("[yellow]Installiert: " + result.EscapeMarkup() + "[/]");

        return 0;
    }
}
