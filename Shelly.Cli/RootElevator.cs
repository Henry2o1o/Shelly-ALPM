using System.Diagnostics;

namespace Shelly.Cli;

public static class RootElevator
{
    public static void EnsureRootExectuion()
    {
        if (Environment.UserName.Equals("root", StringComparison.OrdinalIgnoreCase)) return;

        var args = Environment.GetCommandLineArgs();
        var exe = Environment.ProcessPath ?? args[0];

        using var process = new Process();
        process.StartInfo = new ProcessStartInfo
        {
            FileName = ResolveElevator(),
            ArgumentList = { exe },
            UseShellExecute = false
        };
        foreach (var arg in args.Skip(1)) process.StartInfo.ArgumentList.Add(arg);

        process.Start();
        process.WaitForExit();
        Environment.Exit(process.ExitCode);
    }
    
    private static string ResolveElevator()
    {
        var configured = Environment.GetEnvironmentVariable("SHELLY_ELEVATOR");
        if (!string.IsNullOrWhiteSpace(configured))
            return configured;

        
        foreach (var tool in new[] { "doas", "sudo" })
        {
            if (IsOnPath(tool))
                return tool;
        }

        return "sudo";
    }
    
    private static bool IsOnPath(string tool)
    {
        var pathVar = Environment.GetEnvironmentVariable("PATH");
        if (string.IsNullOrEmpty(pathVar))
            return false;

        foreach (var dir in pathVar.Split(Path.PathSeparator))
        {
            if (string.IsNullOrWhiteSpace(dir))
                continue;

            var candidate = Path.Combine(dir, tool);
            if (File.Exists(candidate))
                return true;
        }

        return false;
    }
}