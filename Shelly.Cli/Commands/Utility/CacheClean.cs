using System.Drawing;
using CliFx.Binding;
using CliFx.Infrastructure;
using PackageManager.Alpm;
using Pastel;
using Shelly.Cli.Commands.Utility.Helpers;
using Shelly.Cli.Interactions;
using Shelly.Utilities;
using Shelly.Utilities.Enums;

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
        if (!DryRun)
        {
            RootElevator.EnsureRootExectuion();
        }

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
            pkgEntries.Sort((a, b) => AlpmManager.VersionCompare(a.Version, b.Version));
            var toRemove = pkgEntries.Take(Math.Max(0, pkgEntries.Count - Keep));
            candidates.AddRange(toRemove);
        }

        if (TargetUninstalled)
        {
            using var manager = new AlpmManager();
            var installedNames = manager.GetInstalledPackages().Select(p => p.Name).ToHashSet();
            candidates = candidates.Where(e => !installedNames.Contains(e.Name)).ToList();
        }

        if (TargetPackages.Length > 0)
        {
            candidates = candidates.Where(e => TargetPackages.Contains(e.Name)).ToList();
        }

        if (candidates.Count == 0)
        {
            message = isAnsiSupported
                ? $"No candidate packages to remove.".Pastel(Color.Green)
                : "No candidate packages to remove.";
            console.WriteLine(message);
            return;
        }

        var totalSize = candidates.Sum(c => c.FileSize);
        var config = ConfigManager.ReadConfig();
        var parsedSize = Enum.Parse<SizeDisplay>(config.FileSizeDisplay);
        var sizedTotalSize = SizeUtilities.FormatSize(parsedSize, totalSize);
        if (DryRun)
        {
            message = isAnsiSupported
                ? $"Dry run: {candidates.Count} packages would be removed. Removing a total size amount {sizedTotalSize}."
                    .Pastel(Color.Yellow)
                : $"Dry run: {candidates.Count} packages would be removed. Removing a total size amount {sizedTotalSize}.";
            console.WriteLine(message);
            BasicTable.Execute(["Package", "Version", "Size"], candidates, c => c.Name,
                c => c.Version,
                c => SizeUtilities.FormatSize(parsedSize, c.FileSize));
            return;
        }

        List<string> sigFiles = [];
        sigFiles.AddRange(candidates.Select(candidate => $"{candidate.FullPath}.sig")
            .Where(File.Exists));
        message = isAnsiSupported
            ? $"Removing {candidates.Count} packages. Removing a total size amount {sizedTotalSize}.".Pastel(
                Color.Yellow)
            : $"Removing {candidates.Count} packages. Removing a total size amount {sizedTotalSize}.";
        console.WriteLine(message);

        if (Verbose)
        {
            BasicTable.Execute(["Package", "Version", "Size"], candidates, c => c.Name,
                c => c.Version,
                c => SizeUtilities.FormatSize(parsedSize, c.FileSize));
        }

        foreach (var sig in sigFiles)
        {
            if (Verbose)
            {
                message = isAnsiSupported
                    ? $"Removing signature file: {sig}".Pastel(Color.Yellow)
                    : $"Removing signature file: {sig}";
                console.WriteLine(message);
            }

            File.Delete(sig);
        }

        foreach (var candidate in candidates)
        {
            try
            {
                if (Verbose)
                {
                    message = isAnsiSupported
                        ? $"Removing package file: {candidate.FullPath}".Pastel(Color.Yellow)
                        : $"Removing package file: {candidate.FullPath}";
                    console.WriteLine(message);
                }

                File.Delete(candidate.FullPath);
                var sigPath = $"{candidate.FullPath}.sig";
                if (Verbose)
                {
                    message = isAnsiSupported
                        ? $"Removing signature file: {sigPath}".Pastel(Color.Yellow)
                        : $"Removing signature file: {sigPath}";
                    console.WriteLine(message);
                }

                if (File.Exists(sigPath))
                {
                    File.Delete(sigPath);
                }
            }
            catch (Exception e)
            {
                message = isAnsiSupported
                    ? $"Failed to remove package file: {candidate.FullPath}".Pastel(Color.Red)
                    : $"Failed to remove package file: {candidate.FullPath}";
                console.WriteLine(message);
                if (Verbose)
                {
                    console.WriteLine(e.Message.Pastel(Color.Red));
                    console.WriteLine(e.StackTrace ?? (isAnsiSupported
                        ? "No stack trace available.".Pastel(Color.Red)
                        : "No stack trace available."));
                }
            }
        }
    }


    public override async ValueTask ExecuteUiMode()
    {
        throw new NotImplementedException();
    }
}