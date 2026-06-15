using System.Drawing;
using System.Globalization;
using System.Net;
using System.Text.Json;
using System.Text.RegularExpressions;
using System.CommandLine;
using PackageManager.Alpm;
using Pastel;
using Shelly.Cli.Interactions;
using Shelly.Cli.Models.Standard.Downgrade;
using Shelly.Cli.Outputs;
using Shelly.Utilities;

namespace Shelly.Cli.Commands.Standard;

public partial class DowngradePackage : GlobalSettingsCommand
{
    private bool UseOldest { get; set; }

    private bool AddIgnore { get; set; }

    private bool ListOptions { get; set; }

    private string? Target { get; set; }

    private string? Package { get; set; }

    public static Command Create()
    {
        var oldest = new Option<bool>("--oldest", "-o") { Description = "Installs the oldest matched version (default newest)" };
        var ignore = new Option<bool>("--ignore", "-i") { Description = "Add to IgnorePkg list" };
        var listOptions = new Option<bool>("--list-options", "-l") { Description = "List available downgrade versions" };
        var target = new Option<string?>("--target", "-t") { Description = "Install a specific downgrade target by exact version or package filename" };
        var package = new Argument<string?>("package") { Description = "The package to downgrade", Arity = ArgumentArity.ZeroOrOne };

        var command = new Command("downgrade", "Downgrade a package") { oldest, ignore, listOptions, target, package };

        command.SetAction(async (parseResult, cancellationToken) =>
        {
            var instance = new DowngradePackage
            {
                UseOldest = parseResult.GetValue(oldest),
                AddIgnore = parseResult.GetValue(ignore),
                ListOptions = parseResult.GetValue(listOptions),
                Target = parseResult.GetValue(target),
                Package = parseResult.GetValue(package)
            };
            GlobalOptions.Apply(instance, parseResult);
            await instance.ExecuteAsync(new SystemShellyConsole());
            return 0;
        });

        return command;
    }

    private const string ArchRepo = "https://archive.archlinux.org/packages/";
    private const string CachyosRepo = "https://archive.cachyos.org/archive/cachyos/";
    private const string CachyosV3Repo = "https://archive.cachyos.org/archive/cachyos-v3/";
    private const string CachyosV4Repo = "https://archive.cachyos.org/archive/cachyos-v4/";

    private const string PacmanCache = "/var/cache/pacman/pkg/";

    [GeneratedRegex("[0-9][a-zA-Z0-9._]+")]
    private static partial Regex VersionRegex();

    [GeneratedRegex("([0-9]+(\\.[0-9]+)?|[a-z0-9]{6,})")]
    private static partial Regex ReleaseOrHashRegex();

    public override async ValueTask ExecuteAsync(IShellyConsole console)
    {
        var isAnsiSupported = AnsiUtilities.SupportsAnsi;
        string message;
        if (UiMode)
        {
            await ExecuteUiMode();
            return;
        }

        if (!string.IsNullOrWhiteSpace(Target) && UseOldest)
        {
            message = isAnsiSupported
                ? $"Error: Cannot combine --target with --latest or --oldest.".Pastel(Color.Red)
                : "Error: Cannot combine --target with --latest or --oldest.";
            console.WriteLine(message);
            return;
        }

        if (!string.IsNullOrWhiteSpace(Target) && ListOptions)
        {
            message = isAnsiSupported
                ? $"Error: Cannot combine --target with --list-options.".Pastel(Color.Red)
                : "Error: Cannot combine --target with --list-options.";
            console.WriteLine(message);
            return;
        }

        if (string.IsNullOrWhiteSpace(Package))
        {
            message = isAnsiSupported
                ? $"Error: No package specified.".Pastel(Color.Red)
                : "Error: No package specified.";
            console.WriteLine(message);
            return;
        }

        RootElevator.EnsureRootExectuion();
        using var manager = new AlpmManager();
        manager.Initialize(true, showHiddenPackages: true);
        var installedPackages = manager.GetInstalledPackage(Package);
        if (installedPackages == null)
        {
            message = "Error: Package must be installed to downgrade";
            console.WriteLine(isAnsiSupported ? message.Pastel(Color.Red) : message);
            return;
        }

        message = isAnsiSupported
            ? $"Looking for downgrade options for: {Package}".Pastel(Color.Green)
            : $"Looking for downgrade options for: {Package}";
        console.WriteLine(message);
        var packages = await GatherDowngradeOptions(manager, installedPackages);
        if (packages.Count == 0)
        {
            message = isAnsiSupported
                ? $"No downgrade options found for: {Package}".Pastel(Color.Red)
                : $"No downgrade options found for: {Package}";
            console.WriteLine(message);
            return;
        }

        if (ListOptions)
        {
            message = isAnsiSupported
                ? $"Available downgrade options for: {Package}".Pastel(Color.Green)
                : $"Available downgrade options for: {Package}";
            console.WriteLine(message);
            if (JsonOutput)
            {
                var json = JsonSerializer.Serialize(packages, ShellyCliJsonContext.Default.ListPackageInfo);
                console.WriteLine(json);
                return;
            }

            message = BasicTable.Execute(["Filename", "Location", "Installed"], packages, c => c.Filename,
                c => c.Location.ToString(),
                c => c.IsInstalled.ToString());
            console.WriteLine(message);
            return;
        }

        PackageInfo selectedPackage;
        if (NoConfirm || UseOldest)
        {
            selectedPackage = UseOldest ? packages[^1] : packages[0];
        }
        else
        {
            if (string.IsNullOrWhiteSpace(Target))
            {
                var selection = BasicSelection.Execute("Select Package", packages.Select(x => x.Filename).ToList());
                selectedPackage = packages[selection];
            }
            else
            {
                try
                {
                    selectedPackage = MatchPackageToTargetVersion(packages, installedPackages, Target);
                }
                catch (Exception ex)
                {
                    message = isAnsiSupported ? $"Error: {ex.Message}".Pastel(Color.Red) : $"Error: {ex.Message}";
                    console.WriteLine(message);
                    if (Verbose)
                    {
                        message = isAnsiSupported
                            ? ex.StackTrace.Pastel(Color.Red) ?? $"No stacktrace found.".Pastel(Color.Red)
                            : ex.StackTrace ?? "No stacktrace found.";
                        console.WriteLine(message);
                    }

                    return;
                }

                var path = await ResolveFilePathCli(selectedPackage, console);

                if (path == null) return;
                if (!NoConfirm && !Confirm.Execute("Do you want to proceed with the installation?", true))
                {
                    message = isAnsiSupported ? $"Operation Cancelled.".Pastel(Color.Yellow) : $"Operation Cancelled.";
                    console.WriteLine(message);
                    return;
                }

                message = isAnsiSupported
                    ? $"Installing: {selectedPackage.Filename}".Pastel(Color.Green)
                    : $"Installing: {selectedPackage.Filename}";
                console.WriteLine(message);

                var isSuccess = await StandardSinglePaneOutput.Output(console, manager,
                    m => m.InstallLocalPackage(path),
                    NoConfirm);

                if (selectedPackage.Location == Location.Remote && File.Exists(path))
                {
                    try
                    {
                        File.Delete(path);
                    }
                    catch (Exception e)
                    {
                        message = isAnsiSupported ? $"Error: {e.Message}".Pastel(Color.Red) : $"Error: {e.Message}";
                        console.WriteLine(message);
                        if (Verbose)
                        {
                            message = isAnsiSupported
                                ? e.StackTrace.Pastel(Color.Red) ?? $"No stacktrace found.".Pastel(Color.Red)
                                : e.StackTrace ?? "No stacktrace found.";
                            console.WriteLine(message);
                        }
                    }
                }

                if (!isSuccess)
                {
                    message = isAnsiSupported
                        ? $"Downgrade failed. See errors above.".Pastel(Color.Red)
                        : $"Downgrade failed. See errors above.";
                    console.WriteLine(message);
                    return;
                }

                if (AddIgnore || (!NoConfirm && Confirm.Execute("Do you want to add package to IgnorePkg list?", true)))
                {
                    message = isAnsiSupported
                        ? $"Adding to IgnorePkg: {Package}".Pastel(Color.Green)
                        : $"Adding to IgnorePkg: {Package}";
                    console.WriteLine(message);
                    try
                    {
                        manager.IgnorePackage(selectedPackage.Name);
                    }
                    catch (Exception e)
                    {
                        message = isAnsiSupported ? $"Error: {e.Message}".Pastel(Color.Red) : $"Error: {e.Message}";
                        console.WriteLine(message);
                        if (Verbose)
                        {
                            message = isAnsiSupported
                                ? e.StackTrace.Pastel(Color.Red) ?? $"No stacktrace found.".Pastel(Color.Red)
                                : e.StackTrace ?? "No stacktrace found.";
                            console.WriteLine(message);
                        }

                        return;
                    }
                }

                message = isAnsiSupported ? $"Downgrade complete.".Pastel(Color.Green) : $"Downgrade complete.";
                console.WriteLine(message);
            }
        }
    }

    public override async ValueTask ExecuteUiMode()
    {
        if (Package == null)
        {
            UiFrames.Error("UI mode downgrade requires exactly one package.");
            return;
        }

        using var manager = new AlpmManager();
        manager.Initialize(true, showHiddenPackages: true);
        var package = manager.GetInstalledPackage(Package);
        if (package == null)
        {
            UiFrames.Error("Package must be installed to downgrade");
            return;
        }

        var packages = await GatherDowngradeOptions(manager, package);
        if (packages.Count == 0)
        {
            UiFrames.Error("No downgrade options found");
            return;
        }

        if (ListOptions)
        {
            var options = packages
                .Select(p => new DowngradeOptionDto(p.Name, p.Filename, p.Location.ToString(), p.IsInstalled)).ToList();
            UiFrames.Frame(options);
            return;
        }

        if (string.IsNullOrWhiteSpace(Target))
        {
            UiFrames.Error("UI mode downgrade requires --target. Use --list-options to inspect available versions.");
            return;
        }

        PackageInfo selection;
        try
        {
            selection = MatchPackageToTargetVersion(packages, package, Target);
        }
        catch (Exception ex)
        {
            UiFrames.Error($"Failed to resolve downgrade target: {ex.Message}");
            return;
        }

        string filePath;
        try
        {
            filePath = selection.Location switch
            {
                Location.Local => Path.Combine(PacmanCache, selection.Filename),
                Location.Remote => await FetchRemotePackage(selection),
                _ => throw new InvalidOperationException()
            };
        }
        catch (Exception ex)
        {
            UiFrames.Error($"Failed to download package: {ex.Message}");
            return;
        }

        UiFrames.TxStart($"Installing {selection.Name} {selection.Filename}...");

        var isSuccess = await UiModeOutput.Run(manager,
            m => m.InstallLocalPackage(Path.GetFullPath(filePath)));
        if (!isSuccess)
        {
            UiFrames.TxFailed("Downgrade failed.");
            return;
        }

        if (selection.Location == Location.Remote && File.Exists(filePath))
            try
            {
                File.Delete(filePath);
            }
            catch
            {
                if (Verbose)
                {
                    UiFrames.Info("Failed to delete downloaded file.");
                }
            }

        if (AddIgnore)
            try
            {
                manager.IgnorePackage(selection.Name);
            }
            catch
            {
                if (Verbose)
                {
                    UiFrames.Info("Failed to add package to IgnorePkg list.");
                }
            }

        UiFrames.TxDone("Package downgraded successfully!");
    }


    private static async Task<string?> ResolveFilePathCli(PackageInfo selection, IShellyConsole console)
    {
        try
        {
            return selection.Location switch
            {
                Location.Local => Path.Combine(PacmanCache, selection.Filename),
                Location.Remote => await DownloadRemotePackageCli(selection, console),
                _ => throw new InvalidOperationException()
            };
        }
        catch (Exception ex)
        {
            var message = AnsiUtilities.SupportsAnsi ? $"Error: {ex.Message}".Pastel(Color.Red) : ex.Message;
            console.WriteLine(message);
            return null;
        }
    }

    private static async Task<string> DownloadRemotePackageCli(PackageInfo packageInfo, IShellyConsole console)
    {
        var message = AnsiUtilities.SupportsAnsi
            ? $"Downloading {packageInfo.Filename}".Pastel(Color.Green)
            : $"Downloading {packageInfo.Filename}";
        console.WriteLine(message);
        var path = await FetchRemotePackage(packageInfo);
        message = AnsiUtilities.SupportsAnsi ? $"Downloaded to {path}".Pastel(Color.Green) : $"Downloaded to {path}";
        console.WriteLine(message);
        return path;
    }

    private static async Task<List<PackageInfo>> GatherDowngradeOptions(AlpmManager manager, AlpmPackageDto package)
    {
        var packages = SearchLocalCache(package);
        var archivedPackages = await SearchArchives(manager, package);
        packages.AddRange(archivedPackages);
        return SortDowngradeOptions(packages);
    }


    private static List<PackageInfo> SortDowngradeOptions(List<PackageInfo> packages)
    {
        var naturalComparer = StringComparer.Create(CultureInfo.InvariantCulture, CompareOptions.NumericOrdering);
        return packages
            .OrderByDescending(info => info.Filename, naturalComparer)
            .ThenByDescending(info => info.IsInstalled)
            .ThenByDescending(info => info.Location)
            .ToList();
    }

    private static HttpClient CreateHttpClient()
    {
        return new HttpClient(new SocketsHttpHandler
        {
            AllowAutoRedirect = true,
            AutomaticDecompression = DecompressionMethods.All,
            MaxAutomaticRedirections = 10,
            PooledConnectionLifetime = TimeSpan.FromMinutes(2)
        })
        {
            Timeout = TimeSpan.FromMinutes(15),
            DefaultRequestHeaders = { UserAgent = { Http.UserAgent } }
        };
    }

    private static PackageInfo MatchPackageToTargetVersion(
        List<PackageInfo> packages,
        AlpmPackageDto package,
        string target)
    {
        return target.Contains(".pkg.tar.", StringComparison.Ordinal)
            ? ResolveLocalPackage(packages, package, target)
            : ResolveRemotePackage(packages, target);
    }

    private static PackageInfo ResolveLocalPackage(List<PackageInfo> packages, AlpmPackageDto package, string target)
    {
        var localPath = Path.Combine(PacmanCache, target);
        var location = File.Exists(localPath) ? Location.Local : Location.Remote;
        var isInstalled = target.StartsWith($"{package.Name}-{package.Version}", StringComparison.Ordinal);
        var uri = packages.Find(p => p.Filename == target)?.Uri;

        return new PackageInfo(package.Name, target, location, isInstalled, uri);
    }

    private static PackageInfo ResolveRemotePackage(List<PackageInfo> packages, string target)
    {
        var byFilename =
            packages.Find(p => string.Equals(p.Filename, target, StringComparison.Ordinal));
        var byVersion =
            packages.Find(p => string.Equals(ParsePackageVersion(p), target, StringComparison.Ordinal));

        return byFilename
               ?? byVersion
               ?? throw new InvalidOperationException(
                   $"No downgrade option matched '{target}'. Use --list-options to inspect valid targets.");
    }

    private static string? ParsePackageVersion(PackageInfo package)
    {
        var prefix = $"{package.Name}-";
        if (!package.Filename.StartsWith(prefix, StringComparison.Ordinal)) return null;

        var extensionIndex = package.Filename.IndexOf(".pkg.tar.", StringComparison.Ordinal);
        if (extensionIndex < 0) return null;

        var versionAndArch = package.Filename[prefix.Length..extensionIndex];
        var archSeparatorIndex = versionAndArch.LastIndexOf('-');
        return archSeparatorIndex > 0 ? versionAndArch[..archSeparatorIndex] : null;
    }

    private static async Task<List<PackageInfo>> SearchArchives(AlpmManager alpmManager, AlpmPackageDto package)
    {
        using var client = CreateHttpClient();

        List<string> archiveUrls = [$"{ArchRepo}{package.Name[0]}/{package.Name}/"];

        if (alpmManager.IsCachyOs)
        {
            archiveUrls.Add(CachyosRepo);
            var architectures = alpmManager.GetAllowedArchitectures();
            if (architectures.Exists(s => s.EndsWith("v4"))) archiveUrls.Add(CachyosV4Repo);
            if (architectures.Exists(s => s.EndsWith("v3"))) archiveUrls.Add(CachyosV3Repo);
        }

        var tasks = archiveUrls
            .Select(async url =>
            {
                try
                {
                    var content = await client.GetStringAsync(url);
                    return (content, url);
                }
                catch
                {
                    return (null, url);
                }
            })
            .ToList();

        var results = await Task.WhenAll(tasks);

        var archiveLinkRegex = new Regex($"""<a href="(?<filename>{CreatePackageRegex(package.Name)})".*>""",
            RegexOptions.Multiline);

        return results
            .Where(r => r.content is not null)
            .SelectMany(r => archiveLinkRegex.Matches(r.content!)
                .Select(match => match.Groups["filename"].Value)
                .Where(filename => !filename.EndsWith(".sig"))
                .Select(filename => new PackageInfo(
                    package.Name,
                    filename,
                    Location.Remote,
                    Uri.UnescapeDataString(filename).StartsWith($"{package.Name}-{package.Version}"),
                    $"{r.url}{filename}")))
            .ToList();
    }

    private static async Task<string> FetchRemotePackage(PackageInfo packageInfo)
    {
        using var client = CreateHttpClient();
        var url = packageInfo.Uri ?? $"{ArchRepo}{packageInfo.Name[0]}/{packageInfo.Name}/{packageInfo.Filename}";

        using var response = await client.GetAsync(url, HttpCompletionOption.ResponseHeadersRead);
        response.EnsureSuccessStatusCode();

        var path = Path.Combine(Path.GetTempPath(), packageInfo.Filename);
        await using var fs = new FileStream(path, FileMode.Create, FileAccess.Write, FileShare.None);
        await response.Content.CopyToAsync(fs);

        return path;
    }

    private static List<PackageInfo> SearchLocalCache(AlpmPackageDto package)
    {
        if (!Directory.Exists(PacmanCache)) return [];

        var packageRegex = new Regex($"^{CreatePackageRegex(package.Name)}$");

        return Directory.GetFiles(PacmanCache)
            .Where(filePath => !filePath.EndsWith(".sig"))
            .Select(filePath => Path.GetFileName(filePath))
            .Where(filename => packageRegex.IsMatch(filename))
            .Select(filename => new PackageInfo(
                package.Name,
                filename,
                Location.Local,
                Uri.UnescapeDataString(filename).StartsWith($"{package.Name}-{package.Version}")))
            .ToList();
    }

    private static string CreatePackageRegex(string packageName)
    {
        return $"""{Regex.Escape(packageName)}-{VersionRegex()}-{ReleaseOrHashRegex()}-[^"]+\.pkg\.tar\.[^"]+""";
    }
}