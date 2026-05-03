using PackageManager.Alpm;
using Spectre.Console;
using Spectre.Console.Cli;

namespace Shelly_CLI.Commands.Utility;

public class CacheClean : AsyncCommand<CacheCleanSettings>
{
    public override Task<int> ExecuteAsync(CommandContext context, CacheCleanSettings settings)
    {

        var cacheDir = settings.CacheDir ?? "/var/cache/pacman/pkg";

        if (!Directory.Exists(cacheDir))
        {
            AnsiConsole.MarkupLine($"[red]Cache-Verzeichnis existiert nicht:{cacheDir.EscapeMarkup()}[/]");
            return Task.FromResult(1);
        }

        var entries = Directory.EnumerateFiles(cacheDir)
            .Select(CacheCleanHelper.ParsePackageFilename)
            .Where(e => e != null)
            .Cast<CacheEntry>()
            .ToList();

        if (entries.Count == 0)
        {
            AnsiConsole.MarkupLine("[yellow]Im Cache-Verzeichnis wurden keine Paketdateien gefunden.[/]");
            return Task.FromResult(0);
        }

        var grouped = entries.GroupBy(e => e.Name).ToDictionary(g => g.Key, g => g.ToList());

        var candidates = new List<CacheEntry>();
        foreach (var (name, pkgEntries) in grouped)
        {
            pkgEntries.Sort((a, b) => AlpmManager.VersionCompare(a.Version, b.Version));
            var toRemove = pkgEntries.Take(Math.Max(0, pkgEntries.Count - settings.Keep));
            candidates.AddRange(toRemove);
        }

        if (settings.Uninstalled)
        {
            using var manager = new AlpmManager();
            var installedNames = manager.GetInstalledPackages().Select(p => p.Name).ToHashSet();
            candidates = candidates.Where(c => !installedNames.Contains(c.Name)).ToList();
        }
        
        if (candidates.Count == 0)
        {
            AnsiConsole.MarkupLine("[green]Keine zu entfernenden Kandidatenpakete.[/]");
            return Task.FromResult(0);
        }

        var totalSize = candidates.Sum(c => c.FileSize);
        
        if (settings.DryRun)
        {
            AnsiConsole.MarkupLine("[blue]Testlauf – die folgenden Dateien würden entfernt:[/]");
            foreach (var entry in candidates)
            {
                AnsiConsole.MarkupLine($"  {entry.FullPath.EscapeMarkup()} [dim]({CacheCleanHelper.FormatSize(entry.FileSize)})[/]");
            }
            AnsiConsole.MarkupLine($"\n[blue]Gesamt: {candidates.Count} Datei(n), {CacheCleanHelper.FormatSize(totalSize)}[/]");
            return Task.FromResult(0);
        }

        if (settings.Remove)
        {
            RootElevator.EnsureRootExectuion();

            foreach (var entry in candidates)
            {
                File.Delete(entry.FullPath);
            }

            AnsiConsole.MarkupLine($"[green]{candidates.Count} Datei(n) entfernt, Speicher freigeben {CacheCleanHelper.FormatSize(totalSize)}[/]");
            return Task.FromResult(0);
        }

        // Default: list candidates
        AnsiConsole.MarkupLine("[blue]Kandidaten zum Bereinigen:[/]");
        foreach (var entry in candidates)
        {
            AnsiConsole.MarkupLine($"  {entry.FullPath.EscapeMarkup()} [dim]({CacheCleanHelper.FormatSize(entry.FileSize)})[/]");
        }
        AnsiConsole.MarkupLine($"\n[blue]Total: {candidates.Count} files, {CacheCleanHelper.FormatSize(totalSize)}[/]");
        AnsiConsole.MarkupLine("[dim]Use -r/--remove to delete these files, or -d/--dry-run to preview.[/]");

        return Task.FromResult(0);
    }
}
