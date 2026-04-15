using System;
using System.Collections.Generic;
using System.Linq;
using PackageManager.Aur.Models;

namespace PackageManager.Aur;

/// <summary>
/// Parses PKGBUILD/SRCINFO source entries for VCS (git) sources,
/// following the same logic as yay's parseSource function.
/// </summary>
public static class VcsSourceParser
{
    /// <summary>
    /// Parses a single PKGBUILD source entry and returns a <see cref="VcsSourceEntry"/> if it is
    /// a trackable git source (i.e., not pinned with #commit= or #tag=). Returns null otherwise.
    /// </summary>
    public static VcsSourceEntry? ParseSource(string sourceEntry)
    {
        if (string.IsNullOrWhiteSpace(sourceEntry))
            return null;

        var entry = sourceEntry.Trim();

        // Strip "name::" prefix (e.g., "pkgname::git+https://...")
        var colonColonIndex = entry.IndexOf("::", StringComparison.Ordinal);
        if (colonColonIndex >= 0)
        {
            entry = entry[(colonColonIndex + 2)..];
        }

        // Parse protocols (e.g., "git+https://..." -> protocols=["git","https"], url="https://...")
        var protocols = new List<string>();
        var url = entry;

        // Extract protocols before "://"
        var schemeEnd = entry.IndexOf("://", StringComparison.Ordinal);
        if (schemeEnd < 0)
            return null;

        var schemePart = entry[..schemeEnd];
        url = entry; // keep full URL for git operations

        // Split protocols by "+"
        protocols.AddRange(schemePart.Split('+', StringSplitOptions.RemoveEmptyEntries));

        // Only process git sources
        if (!protocols.Contains("git", StringComparer.OrdinalIgnoreCase))
            return null;

        // Remove the "git+" prefix from the URL for actual git operations
        // e.g., "git+https://github.com/foo/bar.git" -> "https://github.com/foo/bar.git"
        if (url.StartsWith("git+", StringComparison.OrdinalIgnoreCase))
        {
            url = url[4..];
        }

        // Parse fragment (#branch=, #commit=, #tag=)
        string branch = "HEAD";
        var fragmentIndex = url.IndexOf('#');
        if (fragmentIndex >= 0)
        {
            var fragment = url[(fragmentIndex + 1)..];
            url = url[..fragmentIndex];

            // Skip sources pinned to a specific commit or tag — these are not VCS-tracking
            if (fragment.StartsWith("commit=", StringComparison.OrdinalIgnoreCase) ||
                fragment.StartsWith("tag=", StringComparison.OrdinalIgnoreCase))
            {
                return null;
            }

            if (fragment.StartsWith("branch=", StringComparison.OrdinalIgnoreCase))
            {
                branch = fragment.Split('=', 2)[1];
            }
        }

        // Strip query parameters (e.g., "?signed")
        var queryIndex = url.IndexOf('?');
        if (queryIndex >= 0)
        {
            url = url[..queryIndex];
        }

        return new VcsSourceEntry
        {
            Url = url,
            Branch = branch,
            Protocols = protocols.Where(p => !p.Equals("git", StringComparison.OrdinalIgnoreCase)).ToList(),
            CommitSha = string.Empty
        };
    }

    /// <summary>
    /// Parses all source entries from a PKGBUILD and returns the trackable git sources.
    /// </summary>
    public static List<VcsSourceEntry> ParseSources(IEnumerable<string> sources)
    {
        var results = new List<VcsSourceEntry>();
        foreach (var source in sources)
        {
            var parsed = ParseSource(source);
            if (parsed != null)
                results.Add(parsed);
        }
        return results;
    }
}
