using Shelly.Keys.Gpg;
using Spectre.Console;
using Spectre.Console.Cli;

namespace Shelly.Keys.Commands.Populate;

public class PopulateCommand : AsyncCommand<Settings>
{
    public override async Task<int> ExecuteAsync(CommandContext context, Settings settings)
    {
        RootElevator.EnsureRootExectuion();
        if (!Directory.Exists(settings.KeyringsDir))
        {
            AnsiConsole.MarkupLine($"[bold red]Keyrings directory does not exist: {Markup.Escape(settings.KeyringsDir)}[/]");
            return 1;
        }

        string masterFingerprint;
        try
        {
            masterFingerprint = await GpgHelpers.GetMasterFingerprintAsync(settings.KeyringsDir);
        }
        catch (InvalidOperationException)
        {
            AnsiConsole.MarkupLine("[bold red]Keyring does not contain a master key. Run `shelly keys init` first[/]");
            return 1;
        }
        throw new NotImplementedException();
    }
}