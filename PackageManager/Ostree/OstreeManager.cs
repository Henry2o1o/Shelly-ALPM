using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Runtime.InteropServices;

namespace PackageManager.Ostree;

public class OstreeManager()
{
    public List<OstreeRef> ListRefs(string repoPath)
    {
        var refs = new List<OstreeRef>();

        if (string.IsNullOrWhiteSpace(repoPath))
        {
            return refs;
        }

        if (!Directory.Exists(repoPath))
        {
            return refs;
        }

        var file = OstreeReference.GFileNewForPath(repoPath);

        if (file == IntPtr.Zero)
        {
            return refs;
        }

        try
        {
            var repo = OstreeReference.RepoNew(file);

            if (repo == IntPtr.Zero)
            {
                return refs;
            }

            try
            {
                if (!OstreeReference.RepoOpen(
                        repo,
                        IntPtr.Zero,
                        out var error))
                {
                    if (error != IntPtr.Zero)
                    {
                        OstreeReference.GErrorFree(error);
                    }

                    return refs;
                }

                if (!OstreeReference.RepoListRefs(
                        repo,
                        null,
                        out var refsTable,
                        IntPtr.Zero,
                        out error))
                {
                    if (error != IntPtr.Zero)
                    {
                        OstreeReference.GErrorFree(error);
                    }

                    return refs;
                }

                refs.AddRange(
                    ParseRefsTable(refsTable));
            }
            finally
            {
                OstreeReference.GObjectUnref(repo);
            }
        }
        finally
        {
            OstreeReference.GObjectUnref(file);
        }

        return refs;
    }
    
    private List<OstreeRef> ParseRefsTable(
        IntPtr refsTable)
    {
        var refs = new List<OstreeRef>();

        OstreeReference.GHashTableIterInit(
            out var iter,
            refsTable);

        while (OstreeReference.GHashTableIterNext(
                   ref iter,
                   out var keyPtr,
                   out var valuePtr))
        {
            var fullRef =
                Marshal.PtrToStringUTF8(keyPtr);

            if (string.IsNullOrWhiteSpace(fullRef))
            {
                continue;
            }

            var split =
                fullRef.Split(':', 2);

            if (split.Length != 2)
            {
                continue;
            }

            var reference = split[1];

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
        var file = OstreeReference.GFileNewForPath(repoPath);

        if (file == IntPtr.Zero)
        {
            return null;
        }

        try
        {
            var repo = OstreeReference.RepoNew(file);

            if (repo == IntPtr.Zero)
            {
                return null;
            }

            try
            {
                if (!OstreeReference.RepoOpen(
                        repo,
                        IntPtr.Zero,
                        out var error))
                {
                    if (error != IntPtr.Zero)
                    {
                        OstreeReference.GErrorFree(error);
                    }

                    return null;
                }

                if (!OstreeReference.RepoResolveRev(
                        repo,
                        fullRef,
                        false,
                        out var revisionPtr,
                        IntPtr.Zero,
                        out error))
                {
                    if (error != IntPtr.Zero)
                    {
                        OstreeReference.GErrorFree(error);
                    }

                    return null;
                }

                if (revisionPtr == IntPtr.Zero)
                {
                    return null;
                }

                try
                {
                    return Marshal.PtrToStringUTF8(revisionPtr);
                }
                finally
                {
                    OstreeReference.GFree(revisionPtr);
                }
            }
            finally
            {
                OstreeReference.GObjectUnref(repo);
            }
        }
        finally
        {
            OstreeReference.GObjectUnref(file);
        }
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