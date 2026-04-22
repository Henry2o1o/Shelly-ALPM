using System.ComponentModel;
using Spectre.Console.Cli;

namespace Shelly_CLI.Commands.Standard.Pacfile;

public class PacfileSettings : CommandSettings
{
    [CommandArgument(0, "[pacfiles]")]
    [Description("One or more pacfiles to interact with (space-separated). If empty uses all pacfiles")]
    public string[] Pacfiles { get; set; } = [];

    [CommandOption("-d|--delete")] public bool Delete { get; set; }

    [CommandOption("-j|--json")] public bool Json { get; set; }
}