using System.Drawing;
using CliFx.Binding;
using CliFx.Infrastructure;
using Pastel;
using Shelly.Cli.Commands.Utility.Helpers;
using Shelly.Cli.Interactions;

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
        var isAnsiSupported = AnsiUtilities.SupportsAnsi;
        var message = "";
        if (!Directory.Exists(CacheDir))
        {
            message = isAnsiSupported
                ? $"Cache directory does not exist: {CacheDir}".Pastel(Color.Red)
                : $"Cache directory does not exist: {CacheDir}";
            console.WriteLine(message);
            return;
        }

        var entries = Directory.EnumerateFiles(CacheDir)
            .Select(CacheCleanHelper.ParsePackageFilename)
            .Where(e => e != null)
            .Cast<CacheEntry>()
            .ToList();
        if (entries.Count == 0)
        {
            message = isAnsiSupported
                ? "No package files found in cache directory.".Pastel(Color.Yellow)
                : "No package files found in cache directory.";
            console.WriteLine(message);
            return;
        }

        var grouped = entries.GroupBy(e => e.Name).ToDictionary(g => g.Key, g => g.ToList());
        var candidates = new List<CacheEntry>();
        foreach (var (name, pkgEntries) in grouped)
        {
            
        }
    }

    public override async ValueTask ExecuteUiMode()
    {
        throw new NotImplementedException();
    }
}