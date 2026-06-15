using CliFx;
using CliFx.Binding;
using CliFx.Infrastructure;

namespace Shelly.Cli.Commands;

public abstract class GlobalSettingsCommand : ICommand
{
    [CommandOption("no-confirm",'n',Description = "Disable confirmation prompts")]
    public bool NoConfirm { get; set; }
    
    [CommandOption("ui-mode",'U',Description = "Enable UI mode")]
    public bool UiMode { get; set; }
    
    [CommandOption("json",'j',Description = "Output results in JSON format for scripting.")]
    public bool JsonOutput { get; set; }
    
    [CommandOption("verbose",'v',Description = "Enable verbose logging.")]
    public bool Verbose { get; set; }
    
    public abstract ValueTask ExecuteAsync(IConsole console);

    public abstract ValueTask ExecuteUiMode();
}