using CliFx.Binding;
using CliFx.Infrastructure;

namespace Shelly.Cli.Commands.Utility;

[Command("cache-clean", Description = "Clean the local cache")]
public partial class CacheClean : GlobalSettingsCommand
{
    [CommandOption("keep", 'k', Description = "Keep the specified number of versions in the cache. Defaults to 3.")]
    private int Keep { get; set; } = 3;

    [CommandOption("uninstalled", 'i', Description = "Remove only uninstalled packages from the cache.")]
    private bool TargetUninstalled { get; set; } = false;

    [CommandOption("dry-run", 'd', Description = "Show what would be removed.")]
    private bool DryRun { get; set; } = false;

    [CommandOption("cache-dir", 'c', Description = "Path to the cache directory.")]
    private string? CacheDir { get; set; } = "/var/cache/pacman/pkg";

    [CommandOption("target", 't', Description = "Remove only the specified packages from the cache.")]
    private string[] TargetPackages { get; set; } = Array.Empty<string>();


    public override async ValueTask ExecuteAsync(IConsole console)
    {
        throw new NotImplementedException();
    }

    public override async ValueTask ExecuteUiMode()
    {
        throw new NotImplementedException();
    }
}