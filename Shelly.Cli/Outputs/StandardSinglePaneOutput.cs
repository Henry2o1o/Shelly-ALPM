using System.Drawing;
using CliFx.Infrastructure;
using PackageManager.Alpm;
using PackageManager.Alpm.Pacfile;
using Pastel;
using Shelly.Cli.Interactions;
using Shelly.Cli.Models.Pacfile;


namespace Shelly.Cli.Outputs;

public static class StandardSinglePaneOutput
{
    public static async Task<bool> Output(
        IConsole console,
        IAlpmManager manager,
        Func<IAlpmManager, Task<bool>> operation,
        bool noConfirm = false)
    {
        var ansi = AnsiUtilities.SupportsAnsi;

        var pendingPacfiles = new List<PendingPacfile>();
        var pacfileLock = new object();

        // One-shot section banner.
        var emittedRetrieving = false;

        // Tracks whether the last thing we wrote was an in-place "\r" progress line,
        // so we can break to a fresh line before emitting normal output or prompts.
        var progressLineOpen = false;
        var finalizedBars = new HashSet<(string Name, string Action)>();
        var sync = new object();

        void Line(string text, ConsoleColor? color = null)
        {
            lock (sync)
            {
                if (progressLineOpen)
                {
                    console.Output.WriteLine();
                    progressLineOpen = false;
                }

                console.Output.WriteLine(ansi && color is { } c ? text.Pastel(c) : text);
            }
        }

        manager.Progress += (_, e) =>
        {
            var name = e.PackageName ?? "unknown";
            var pct = e.Percent ?? 0;
            var action = e.ProgressType.ToString();

            if (!emittedRetrieving
                && action.StartsWith("Download", StringComparison.OrdinalIgnoreCase))
            {
                emittedRetrieving = true;
                Line(":: Retrieving packages...", ConsoleColor.White);
            }

            lock (sync)
            {
                // Plain / redirected mode: suppress intermediates, emit one finalized
                // line per (name, action) at 100%.
                if (!ansi || console.IsOutputRedirected)
                {
                    if (pct < 100) return;
                    if (!finalizedBars.Add((name, action))) return;
                    console.Output.WriteLine(
                        $"({e.Current ?? 0}/{e.HowMany ?? 0}) {action} {name} {pct,3}%");
                    return;
                }

                // Animated mode: in-place update with carriage return.
                var max = Math.Max(20, Console.WindowWidth - 1);
                var lineText = $"({e.Current ?? 0}/{e.HowMany ?? 0}) {action} {name} {pct,3}%";
                if (lineText.Length > max) lineText = lineText[..max];

                console.Output.Write($"\r\x1b[2K{lineText}");
                progressLineOpen = true;

                if (pct >= 100)
                {
                    console.Output.WriteLine();
                    progressLineOpen = false;
                }
            }
        };

        manager.ScriptletInfo += (_, e) =>
        {
            var line = e.Line.TrimEnd();
            Line(string.IsNullOrEmpty(line) ? "Running scriptlet..." : $"Scriptlet: {line}",
                ConsoleColor.DarkGray);
        };

        manager.HookRun += (_, e) =>
        {
            var line = e.Description ?? string.Empty;
            Line(string.IsNullOrEmpty(line) ? "Running hook..." : $"Hook: {line}",
                ConsoleColor.DarkGray);
        };

        manager.Replaces += (_, e) =>
        {
            Line($":: {e.Repository}/{e.PackageName} replaces {string.Join(",", e.Replaces)}",
                ConsoleColor.White);
        };

        manager.PacnewInfo += (_, e) =>
        {
            Line($":: pacnew stored @ {e.FileLocation}.pacnew", ConsoleColor.Yellow);
            lock (pacfileLock)
            {
                pendingPacfiles.Add(new PendingPacfile(
                    PacfileType.Pacnew, null, e.FileLocation + ".pacnew", DateTime.UtcNow));
            }
        };

        manager.PacsaveInfo += (_, e) =>
        {
            Line($":: pacsave stored @ {e.FileLocation}.pacsave", ConsoleColor.Yellow);
            lock (pacfileLock)
            {
                pendingPacfiles.Add(new PendingPacfile(
                    PacfileType.Pacsave, e.OldPackage, e.FileLocation + ".pacsave", DateTime.UtcNow));
            }
        };

        manager.ErrorEvent += (_, e) => { Line($"error: {e.Error}", ConsoleColor.Red); };

        manager.Question += (_, e) =>
        {
            // Break out of any open progress line so the prompt doesn't collide with "\r".
            lock (sync)
            {
                if (progressLineOpen)
                {
                    console.Output.WriteLine();
                    progressLineOpen = false;
                }
            }

            QuestionHandler.HandleQuestion(e, uiMode: false, noConfirm: noConfirm);
        };

        Line(":: Synchronizing package databases...", ConsoleColor.White);

        bool result;
        try
        {
            result = await operation(manager);
        }
        catch (Exception ex)
        {
            Line($"error: {ex.Message}", ConsoleColor.Red);
            result = false;
        }

        Line(result ? ":: Transaction complete." : ":: Transaction failed.",
            result ? ConsoleColor.Green : ConsoleColor.Red);

        try
        {
            await PacfileFlusher.FlushAsync(pendingPacfiles, pacfileLock);
        }
        catch (Exception ex)
        {
            Line($"warning: failed to store pacfiles: {ex.Message}", ConsoleColor.Yellow);
        }

        return result;
    }
}