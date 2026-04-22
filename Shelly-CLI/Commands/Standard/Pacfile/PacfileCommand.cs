using System.Text.Json;
using PackageManager;
using PackageManager.Alpm.Pacfile;
using Spectre.Console;
using Spectre.Console.Cli;

namespace Shelly_CLI.Commands.Standard.Pacfile;

public class PacfileCommand : AsyncCommand<PacfileSettings>
{
    public override async Task<int> ExecuteAsync(CommandContext context, PacfileSettings settings)
    {
        if (Program.IsUiMode)
        {
            return 0;
        }

        RootElevator.EnsureRootExectuion();
        var pacfileStoragePath = ShellyDatastore.GetPacfileStoragePath();
        await using PacfileManager manager = new(Path.Combine(pacfileStoragePath, ".pacfiles"));
        if (settings.Pacfiles.Length == 0)
        {
            //Running for all
            var result = await manager.GetPacfiles();
            if (settings.Json)
            {
                var serializedResult = JsonSerializer.Serialize(result, ShellyCLIJsonContext.Default.ListPacfileRecord);
                Console.WriteLine(serializedResult);
            }

            AnsiConsole.MarkupLine($"[blue]Pacfiles:[/]");
            Table table = new();
            table.AddColumns("Name", "Content");
            foreach (var pacfile in result)
            {
                table.AddRow(pacfile.Name,
                    pacfile.Text.Truncate(pacfile.Text.Length > 100 ? 100 : pacfile.Text.Length));
            }

            AnsiConsole.Write(table);
        }
        
        return 0;
    }
}