using System.Diagnostics.CodeAnalysis;
using PackageManager.Flatpak;
using Shelly_CLI.Utility;
using Spectre.Console;
using Spectre.Console.Cli;

namespace Shelly_CLI.Commands.Flatpak;

public class FlatpakRepairCommand : CommandSettings
{
    [CommandOption("-u|--user")]
    public bool User { get; set; }
    [CommandOption("--dry-run")]
    public bool DryRun { get; set; }
}

