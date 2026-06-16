using System.CommandLine;
using PackageManager.Alpm;
using PackageManager.Local;
using Pastel;
using Shelly.Cli.Interactions;
using Shelly.Cli.Outputs;

namespace Shelly.Cli.Commands.Standard;

public partial class Install : GlobalSettingsCommand
{
    private bool BuildDeps { get; set; }

    private bool MakeDeps { get; set; }

    private bool NoDeps { get; set; }

    private bool Upgrade { get; set; }

    private string[] Package { get; set; } = Array.Empty<string>();

    public static Command Create()
    {
        var buildDeps = new Option<bool>("--build-deps", "-b") { Description = "Install build dependencies" };
        var makeDeps = new Option<bool>("--make-deps", "-m") { Description = "Install make dependencies" };
        var noDeps = new Option<bool>("--no-deps", "-d") { Description = "Install without checking/installing dependencies" };
        var upgrade = new Option<bool>("--upgrade", "-u") { Description = "Upgrades the package if it is already installed" };
        var package = new Argument<string[]>("package") { Description = "The packages to install (repo names, local files or URLs)", Arity = ArgumentArity.ZeroOrMore };

        var command = new Command("install", "Install a package")
        {
            buildDeps, makeDeps, noDeps, upgrade, package
        };

        command.SetAction(async (parseResult, cancellationToken) =>
        {
            var instance = new Install
            {
                BuildDeps = parseResult.GetValue(buildDeps),
                MakeDeps = parseResult.GetValue(makeDeps),
                NoDeps = parseResult.GetValue(noDeps),
                Upgrade = parseResult.GetValue(upgrade),
                Package = parseResult.GetValue(package) ?? Array.Empty<string>()
            };
            GlobalOptions.Apply(instance, parseResult);
            await instance.ExecuteAsync(new SystemShellyConsole());
            return 0;
        });

        return command;
    }

    public override async ValueTask ExecuteAsync(IShellyConsole console)
    {
        if (UiMode)
        {
            await ExecuteUiMode();
            return;
        }

        if (Package.Length == 0)
        {
            console.WriteLine(AnsiUtilities.Colorize("Error: No packages specified", ConsoleColor.Red));
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

    private async Task InstallRepoPackages(List<string> packageList, IShellyConsole console)
    {
        console.WriteLine(AnsiUtilities.Colorize(
            $"Packages to install: {string.Join(", ", packageList)}", ConsoleColor.Yellow));

        if (!NoConfirm && !Confirm.Execute("Do you want to proceed?"))
        {
            console.WriteLine(AnsiUtilities.Colorize("Operation cancelled.", ConsoleColor.Yellow));
            return;
        }

        using var manager = new AlpmManager();
        console.WriteLine(AnsiUtilities.Colorize("Initializing ALPM...", ConsoleColor.Yellow));
        manager.Initialize(true);

        Task<bool> RunOutput(Func<IAlpmManager, Task<bool>> op) =>
            StandardSinglePaneOutput.Output(console, manager, op, NoConfirm);

        if (Upgrade)
        {
            console.WriteLine(AnsiUtilities.Colorize("Running system upgrade", ConsoleColor.Yellow));
            if (!await RunOutput(x => x.SyncSystemUpdate()))
            {
                console.WriteLine(AnsiUtilities.Colorize("System upgrade failed. See errors above.", ConsoleColor.Red));
                return;
            }
        }

        if (BuildDeps)
        {
            if (packageList.Count > 1)
            {
                console.WriteLine(AnsiUtilities.Colorize(
                    "Cannot build dependencies for multiple packages at once.", ConsoleColor.Yellow));
                return;
            }

            console.WriteLine(AnsiUtilities.Colorize("Installing packages...", ConsoleColor.Yellow));
            var depsResult = await RunOutput(x => x.InstallDependenciesOnly(packageList[0], MakeDeps));
            if (!depsResult)
            {
                console.WriteLine(AnsiUtilities.Colorize("Installation failed. See errors above.", ConsoleColor.Red));
                return;
            }

            console.WriteLine(AnsiUtilities.Colorize("Packages installed successfully!", ConsoleColor.Green));
            return;
        }

        if (NoDeps)
        {
            console.WriteLine(AnsiUtilities.Colorize("Skipping dependency installation.", ConsoleColor.Yellow));
            console.WriteLine(AnsiUtilities.Colorize("Installing packages...", ConsoleColor.Yellow));
            if (!await RunOutput(x => x.InstallPackages(packageList, AlpmTransFlag.NoDeps)))
            {
                console.WriteLine(AnsiUtilities.Colorize("Installation failed. See errors above.", ConsoleColor.Red));
                return;
            }

            console.WriteLine(AnsiUtilities.Colorize("Packages installed successfully!", ConsoleColor.Green));
            return;
        }

        console.WriteLine(AnsiUtilities.Colorize("Installing packages...", ConsoleColor.Yellow));
        var installResult = await RunOutput(x => x.InstallPackages(packageList));
        console.WriteLine();
        if (!installResult)
        {
            console.WriteLine(AnsiUtilities.Colorize("Installation failed. See errors above.", ConsoleColor.Red));
            return;
        }

        console.WriteLine(AnsiUtilities.Colorize("Packages installed successfully!", ConsoleColor.Green));
    }

    private async Task InstallLocalPackage(string location, IShellyConsole console)
    {
        if (!File.Exists(location))
        {
            console.WriteLine(AnsiUtilities.Colorize($"Error: Specified file does not exist: {location}", ConsoleColor.Red));
            return;
        }

        if (await FileInspector.IsArchPackage(location))
        {
            using var manager = new AlpmManager();
            console.WriteLine(AnsiUtilities.Colorize("Initializing ALPM...", ConsoleColor.Yellow));
            manager.Initialize();
            var result = await StandardSinglePaneOutput.Output(console, manager,
                x => x.InstallLocalPackage(Path.GetFullPath(location)), NoConfirm);
            if (!result)
                console.WriteLine(AnsiUtilities.Colorize("Installation failed. See errors above.", ConsoleColor.Red));
            return;
        }

        if (await FileInspector.IsBinariesPackage(location))
        {
            var localManager = new LocalManager();
            localManager.Message += (_, e) =>
            {
                var color = e.Level switch
                {
                    LocalManagerMessageLevel.Info => ConsoleColor.Cyan,
                    LocalManagerMessageLevel.Warning => ConsoleColor.Yellow,
                    LocalManagerMessageLevel.Error => ConsoleColor.Red,
                    LocalManagerMessageLevel.Success => ConsoleColor.Green,
                    _ => ConsoleColor.White
                };
                console.WriteLine(AnsiUtilities.Colorize(e.Message, color));
            };

            await localManager.InstallBinariesPackage(Path.GetFullPath(location));
            return;
        }

        console.WriteLine(AnsiUtilities.Colorize("Error: Unsupported local package format.", ConsoleColor.Red));
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

    private static async Task<string?> DownloadToTempFile(string url, IShellyConsole console)
    {
        try
        {
            console.WriteLine(AnsiUtilities.Colorize($"Downloading {url}...", ConsoleColor.Yellow));
            return await DownloadCore(url);
        }
        catch (Exception ex)
        {
            console.WriteLine(AnsiUtilities.Colorize($"Error: Failed to download {url}: {ex.Message}", ConsoleColor.Red));
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
        return IsFilePath(value) ? PackageSourceKind.FilePath : PackageSourceKind.PackageName;
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
