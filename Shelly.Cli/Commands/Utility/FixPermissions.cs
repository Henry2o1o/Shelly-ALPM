using System.Diagnostics;
using System.CommandLine;
using System.Drawing;
using Pastel;
using Shelly.Cli.Interactions;
using Shelly.Utilities;

namespace Shelly.Cli.Commands.Utility;

public partial class FixPermissions : GlobalSettingsCommand
{
    public static Command Create()
    {
        var command = new Command("fix-permissions", "Fix permissions for Shelly directories");

        command.SetAction(async (parseResult, cancellationToken) =>
        {
            var instance = new FixPermissions();
            GlobalOptions.Apply(instance, parseResult);
            await instance.ExecuteAsync(new SystemShellyConsole());
            return 0;
        });

        return command;
    }

    public override async ValueTask ExecuteAsync(IShellyConsole console)
    {
        RootElevator.EnsureRootExectuion();

        var isAnsiSupported = AnsiUtilities.SupportsAnsi;
        string message;
        var user = Environment.GetEnvironmentVariable("SUDO_USER");
        if (string.IsNullOrEmpty(user) || user == "root")
        {
            message = isAnsiSupported
                ? "Could not determin invoking user (SUDO_USER not set).".Pastel(Color.Red)
                : "Could not determin invoking user (SUDO_USER not set).";
            console.WriteLine(message);
        }

        string[] paths = [XdgPaths.ShellyConfig(), XdgPaths.ShellyCache(), XdgPaths.ShellyData()];

        var existing = paths.Where(Directory.Exists).ToList();
        if (existing.Count == 0)
        {
            if (UiMode)
            {
                UiFrames.Info("No directories to fix permissions for.");
                return;
            }

            message = isAnsiSupported
                ? "No directories to fix permissions for.".Pastel(Color.Green)
                : "No directories to fix permissions for.";
            console.WriteLine(message);
            return;
        }

        foreach (var path in existing)
        {
            var args = new List<string> { "-R", $"{user}:{user}", path };
            var psi = new ProcessStartInfo
            {
                FileName = "chown",
                RedirectStandardOutput = true,
                RedirectStandardError = true,
                UseShellExecute = false,
                CreateNoWindow = true,
            };
            foreach (var a in args) psi.ArgumentList.Add(a);
            try
            {
                using var proc = Process.Start(psi);
                if (proc == null)
                {
                    message = isAnsiSupported
                        ? $"Failed to start chown for {path}".Pastel(Color.Red)
                        : $"Failed to start chown for {path}";
                    console.WriteLine(message);
                    continue;
                }

                await proc.WaitForExitAsync();
                if (proc.ExitCode != 0)
                {
                    var err = await proc.StandardError.ReadToEndAsync();
                    message = isAnsiSupported
                        ? $"chown failed for {path} (exit {proc.ExitCode}): {err.Trim()}".Pastel(Color.Red)
                        : $"chown failed for {path} (exit {proc.ExitCode}): {err.Trim()}";
                    console.WriteLine(message);
                }

                if (UiMode)
                {
                    UiFrames.Info($"Fixed ownership: {path}");
                    continue;
                }

                message = isAnsiSupported ? $"Fixed ownership: {path}".Pastel(Color.Green) : $"Fixed ownership: {path}";
                console.WriteLine(message);
            }
            catch (Exception e)
            {
                if (UiMode)
                {
                    UiFrames.Error($"Failed to fix ownership for {path}: {e.Message}");
                    continue;
                }

                message = isAnsiSupported
                    ? $"Failed to fix ownership for {path}: {e.Message}".Pastel(Color.Red)
                    : $"Failed to fix ownership for {path}: {e.Message}";
                console.WriteLine(message);
            }
        }
    }

    public override async ValueTask ExecuteUiMode()
    {
        //Unneeded as the command is not interactive.
        throw new NotImplementedException();
    }
}