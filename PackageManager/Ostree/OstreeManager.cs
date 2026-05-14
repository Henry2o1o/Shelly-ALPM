using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;

namespace PackageManager.Ostree;

public class OstreeManager()
{
    public List<OstreeRef> ListRefs(string repoPath)
    {
        var refs = new  List<OstreeRef>();

        if (string.IsNullOrWhiteSpace(repoPath))
        {
            return refs;
        }

        if (!Directory.Exists(repoPath))
        {
            return refs;
        }

        var process = new Process();

        process.StartInfo = new ProcessStartInfo
        {
            FileName = "/usr/bin/ostree",
            Arguments = $"refs --repo=\"{repoPath}\"",
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            UseShellExecute = false,
            CreateNoWindow = true
        };

        process.Start();
        
        var stdout = process.StandardOutput.ReadToEnd();
        var stderr = process.StandardError.ReadToEnd();
        
        process.WaitForExit();

        if (process.ExitCode != 0)
        {
            Console.Error.WriteLine(
                $"Failed to list OSTree refs: {stderr}");

            return refs;
        }
        
        var lines = stdout.Split(
            '\n',
            StringSplitOptions.RemoveEmptyEntries);

        foreach (var line in lines)
        {
            var trimmed = line.Trim();

            if (string.IsNullOrWhiteSpace(trimmed))
            {
                continue;
            }

            var split = trimmed.Split(':', 2);

            if (split.Length != 2)
            {
                continue;
            }
            
            var reference = split[1];

            // Ignoring non-flatpak refs
            if (!reference.StartsWith("app/") &&
                !reference.StartsWith("runtime/"))
            {
                continue;
            }

            refs.Add(new OstreeRef
            {
                Remote = split[0],
                Ref = split[1]
            });
        }

        return refs;
        
    }

    public string? GetCommitForRef(
        string repoPath,
        string fullRef)
    {
        if (string.IsNullOrWhiteSpace(repoPath))
        {
            return null;
        }

        if (!Directory.Exists(repoPath))
        {
            return null;
        }

        var process = new Process();

        process.StartInfo = new ProcessStartInfo
        {
            FileName = "/usr/bin/ostree",
            Arguments =
                $"rev-parse --repo=\"{repoPath}\" \"{fullRef}\"",
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            UseShellExecute = false,
            CreateNoWindow = true
        };

        process.Start();

        var stdout = process.StandardOutput.ReadToEnd();
        var stderr = process.StandardError.ReadToEnd();

        process.WaitForExit();

        if (process.ExitCode != 0)
        {
            Console.Error.WriteLine(
                $"Failed to resolve commit for ref '{fullRef}': {stderr}");
            return null;
        }

        var commit = stdout.Trim();

        return string.IsNullOrWhiteSpace(commit)
            ? null
            : commit;
    }
    
    public bool DeleteRef(string repoPath, string remote, string reference)
    {
        return false;
    }

    public bool Prune(string repoPath)
    {
        return true;
    }

    public FsckResult Result(string repoPath)
    {
        return new FsckResult();
    }
}