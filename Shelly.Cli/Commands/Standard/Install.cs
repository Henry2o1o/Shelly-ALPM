using System.Drawing;
using CliFx.Binding;
using CliFx.Infrastructure;
using PackageManager.Alpm;
using PackageManager.Local;
using Pastel;
using Shelly.Cli.Interactions;
using Shelly.Cli.Outputs;

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

    [CommandParameter(0, Description = "The packages to install (repo names, local files or URLs)")]
    private string[] Package { get; set; } = Array.Empty<string>();


    public override async ValueTask ExecuteAsync(IConsole console)
    {
        if (UiMode)
        {
            await ExecuteUiMode();
            return;
        }

        if (Package.Length == 0)
        {
            console.WriteLine(AnsiUtilities.Colorize("Error: No packages specified", Color.Red));
            return;
        }

        RootElevator.EnsureRootExectuion();

        var names = new List<string>();
        var files = new List<string>();

        foreach (var entry in Package)
        {
            switch (Classify(entry))
            {
                case PackageSourceKind.Url:
                    var downloaded = await DownloadToTempFile(entry, console);
                    if (downloaded is not null)
                        files.Add(downloaded);
                    break;
                case PackageSourceKind.FilePath:
                    files.Add(entry);
                    break;
                default:
                    names.Add(entry);
                    break;
            }
        }

        if (names.Count > 0)
            await InstallRepoPackages(names, console);

        foreach (var file in files)
            await InstallLocalPackage(file, console);
    }

    private async Task InstallRepoPackages(List<string> packageList, IConsole console)
    {
        console.WriteLine(AnsiUtilities.Colorize(
            $"Packages to install: {string.Join(", ", packageList)}", Color.Yellow));

        if (!NoConfirm && !Confirm.Execute("Do you want to proceed?"))
        {
            console.WriteLine(AnsiUtilities.Colorize("Operation cancelled.", Color.Yellow));
            return;
        }

        using var manager = new AlpmManager();
        console.WriteLine(AnsiUtilities.Colorize("Initializing ALPM...", Color.Yellow));
        manager.Initialize(true);

        Task<bool> RunOutput(Func<IAlpmManager, Task<bool>> op) =>
            StandardSinglePaneOutput.Output(console, manager, op, NoConfirm);

        if (Upgrade)
        {
            console.WriteLine(AnsiUtilities.Colorize("Running system upgrade", Color.Yellow));
            if (!await RunOutput(x => x.SyncSystemUpdate()))
            {
                console.WriteLine(AnsiUtilities.Colorize("System upgrade failed. See errors above.", Color.Red));
                return;
            }
        }

        if (BuildDeps)
        {
            if (packageList.Count > 1)
            {
                console.WriteLine(AnsiUtilities.Colorize(
                    "Cannot build dependencies for multiple packages at once.", Color.Yellow));
                return;
            }

            console.WriteLine(AnsiUtilities.Colorize("Installing packages...", Color.Yellow));
            var depsResult = await RunOutput(x => x.InstallDependenciesOnly(packageList[0], MakeDeps));
            if (!depsResult)
            {
                console.WriteLine(AnsiUtilities.Colorize("Installation failed. See errors above.", Color.Red));
                return;
            }

            console.WriteLine(AnsiUtilities.Colorize("Packages installed successfully!", Color.Green));
            return;
        }

        if (NoDeps)
        {
            console.WriteLine(AnsiUtilities.Colorize("Skipping dependency installation.", Color.Yellow));
            console.WriteLine(AnsiUtilities.Colorize("Installing packages...", Color.Yellow));
            if (!await RunOutput(x => x.InstallPackages(packageList, AlpmTransFlag.NoDeps)))
            {
                console.WriteLine(AnsiUtilities.Colorize("Installation failed. See errors above.", Color.Red));
                return;
            }

            console.WriteLine(AnsiUtilities.Colorize("Packages installed successfully!", Color.Green));
            return;
        }

        console.WriteLine(AnsiUtilities.Colorize("Installing packages...", Color.Yellow));
        var installResult = await RunOutput(x => x.InstallPackages(packageList));
        console.WriteLine();
        if (!installResult)
        {
            console.WriteLine(AnsiUtilities.Colorize("Installation failed. See errors above.", Color.Red));
            return;
        }

        console.WriteLine(AnsiUtilities.Colorize("Packages installed successfully!", Color.Green));
    }

    private async Task InstallLocalPackage(string location, IConsole console)
    {
        if (!File.Exists(location))
        {
            console.WriteLine(AnsiUtilities.Colorize($"Error: Specified file does not exist: {location}", Color.Red));
            return;
        }

        if (await FileInspector.IsArchPackage(location))
        {
            using var manager = new AlpmManager();
            console.WriteLine(AnsiUtilities.Colorize("Initializing ALPM...", Color.Yellow));
            manager.Initialize();
            var result = await StandardSinglePaneOutput.Output(console, manager,
                x => x.InstallLocalPackage(Path.GetFullPath(location)), NoConfirm);
            if (!result)
                console.WriteLine(AnsiUtilities.Colorize("Installation failed. See errors above.", Color.Red));
            return;
        }

        if (await FileInspector.IsBinariesPackage(location))
        {
            var localManager = new LocalManager();
            localManager.Message += (_, e) =>
            {
                var color = e.Level switch
                {
                    LocalManagerMessageLevel.Info => Color.Cyan,
                    LocalManagerMessageLevel.Warning => Color.Yellow,
                    LocalManagerMessageLevel.Error => Color.Red,
                    LocalManagerMessageLevel.Success => Color.Green,
                    _ => Color.White
                };
                console.WriteLine(AnsiUtilities.Colorize(e.Message, color));
            };

            await localManager.InstallBinariesPackage(Path.GetFullPath(location));
            return;
        }

        console.WriteLine(AnsiUtilities.Colorize("Error: Unsupported local package format.", Color.Red));
    }

    public override async ValueTask ExecuteUiMode()
    {
        if (Package.Length == 0)
        {
            UiFrames.Error("No packages specified");
            return;
        }

        var names = new List<string>();
        var files = new List<string>();

        foreach (var entry in Package)
        {
            switch (Classify(entry))
            {
                case PackageSourceKind.Url:
                    var downloaded = await DownloadToTempFileUi(entry);
                    if (downloaded is not null)
                        files.Add(downloaded);
                    break;
                case PackageSourceKind.FilePath:
                    files.Add(entry);
                    break;
                default:
                    names.Add(entry);
                    break;
            }
        }

        if (names.Count > 0)
            await InstallRepoPackagesUi(names);

        foreach (var file in files)
            await InstallLocalPackageUi(file);
    }

    private async Task InstallRepoPackagesUi(List<string> packageList)
    {
        using var manager = new AlpmManager();
        manager.Initialize(true);
        manager.Question += (_, args) => QuestionHandler.HandleQuestion(args, true, NoConfirm);

        if (Upgrade)
        {
            UiFrames.TxStart("Running system upgrade...");
            var upgradeOk = await UiModeOutput.Run(manager, m => m.SyncSystemUpdate());
            if (!upgradeOk)
            {
                UiFrames.TxFailed("System upgrade failed.");
                return;
            }
        }

        if (BuildDeps)
        {
            if (packageList.Count > 1)
            {
                UiFrames.Error("Cannot build dependencies for multiple packages at once.");
                return;
            }

            UiFrames.TxStart(MakeDeps
                ? "Installing dependencies (including make dependencies)..."
                : "Installing dependencies...");
            var depsOk = await UiModeOutput.Run(manager, m => m.InstallDependenciesOnly(packageList[0], MakeDeps));
            UiFrames.TxFinish(depsOk, "Dependencies installed successfully!", "Dependency installation failed.");
            return;
        }

        var flags = NoDeps ? AlpmTransFlag.NoDeps : AlpmTransFlag.None;
        UiFrames.TxStart($"Installing packages: {string.Join(", ", packageList)}");
        var ok = await UiModeOutput.Run(manager, m => m.InstallPackages(packageList, flags));
        UiFrames.TxFinish(ok, "Packages installed successfully!", "Installation failed.");
    }

    private async Task InstallLocalPackageUi(string location)
    {
        if (!File.Exists(location))
        {
            UiFrames.Error($"Specified file does not exist: {location}");
            return;
        }

        if (await FileInspector.IsArchPackage(location))
        {
            using var manager = new AlpmManager();
            manager.Question += (_, args) => QuestionHandler.HandleQuestion(args, true, NoConfirm);
            manager.Initialize();

            UiFrames.TxStart($"Installing local package: {location}");
            var ok = await UiModeOutput.Run(manager, m => m.InstallLocalPackage(Path.GetFullPath(location)));
            UiFrames.TxFinish(ok, "Installation complete.", "Installation failed.");
            return;
        }

        if (await FileInspector.IsBinariesPackage(location))
        {
            var localManager = new LocalManager();
            localManager.Message += (_, e) =>
            {
                switch (e.Level)
                {
                    case LocalManagerMessageLevel.Info:
                    case LocalManagerMessageLevel.Success:
                        UiFrames.Info(e.Message);
                        break;
                    case LocalManagerMessageLevel.Warning:
                        UiFrames.Info($"Warning: {e.Message}");
                        break;
                    case LocalManagerMessageLevel.Error:
                        UiFrames.Error(e.Message);
                        break;
                }
            };

            await localManager.InstallBinariesPackage(Path.GetFullPath(location));
            return;
        }

        UiFrames.Error("Unsupported local package format.");
    }

    private static async Task<string?> DownloadToTempFile(string url, IConsole console)
    {
        try
        {
            console.WriteLine(AnsiUtilities.Colorize($"Downloading {url}...", Color.Yellow));
            return await DownloadCore(url);
        }
        catch (Exception ex)
        {
            console.WriteLine(AnsiUtilities.Colorize($"Error: Failed to download {url}: {ex.Message}", Color.Red));
            return null;
        }
    }

    private static async Task<string?> DownloadToTempFileUi(string url)
    {
        try
        {
            UiFrames.Info($"Downloading {url}...");
            return await DownloadCore(url);
        }
        catch (Exception ex)
        {
            UiFrames.Error($"Failed to download {url}: {ex.Message}");
            return null;
        }
    }

    private static async Task<string> DownloadCore(string url)
    {
        using var client = new HttpClient();
        var fileName = Path.GetFileName(new Uri(url).LocalPath);
        if (string.IsNullOrWhiteSpace(fileName))
            fileName = Path.GetRandomFileName();
        var tempPath = Path.Combine(Path.GetTempPath(), fileName);

        await using var response = await client.GetStreamAsync(url);
        await using var fileStream = File.Create(tempPath);
        await response.CopyToAsync(fileStream);
        return tempPath;
    }

    public enum PackageSourceKind
    {
        Url,
        FilePath,
        PackageName
    }

    private static PackageSourceKind Classify(string value)
    {
        if (IsUrl(value))
            return PackageSourceKind.Url;
        if (IsFilePath(value))
            return PackageSourceKind.FilePath;
        return PackageSourceKind.PackageName;
    }

    public static bool IsUrl(string value)
    {
        return Uri.TryCreate(value, UriKind.Absolute, out var uri)
               && (uri.Scheme == Uri.UriSchemeHttp
                   || uri.Scheme == Uri.UriSchemeHttps
                   || uri.Scheme == Uri.UriSchemeFtp);
    }

    public static bool IsFilePath(string value)
    {
        if (string.IsNullOrWhiteSpace(value))
            return false;

        if (IsUrl(value))
            return false;

        if (value.Contains(Path.DirectorySeparatorChar)
            || value.Contains(Path.AltDirectorySeparatorChar)
            || value.StartsWith('~')
            || Path.IsPathRooted(value))
        {
            return true;
        }

        return Path.HasExtension(value);
    }
}
