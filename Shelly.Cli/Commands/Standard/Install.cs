using CliFx.Binding;
using CliFx.Infrastructure;

namespace Shelly.Cli.Commands.Standard;

[Command("install", Description = "Install a package")]
public partial class Install : GlobalSettingsCommand
{
    [CommandOption("build-deps", 'b', Description = "Install build dependencies")]
    private bool BuildDeps { get; set; }
    
    [CommandOption("make-deps", 'm', Description = "Install make dependencies")]
    private bool MakeDeps { get; set; }
    
    [CommandOption("no-deps", 'd', Description = "Install without checking/installing dependencies")]
    private bool NoDeps { get; set; }
    
    [CommandOption("upgrade", 'u', Description = "Upgrades the package if it is already installed")]
    private bool Upgrade { get; set; }
    
    [CommandParameter(0, Description = "The packages to install")]
    private string[] Package { get; set; } = Array.Empty<string>();
    

    public override async ValueTask ExecuteAsync(IConsole console)
    {
        throw new NotImplementedException();
    }

    public override async ValueTask ExecuteUiMode()
    {
        throw new NotImplementedException();
    }
}