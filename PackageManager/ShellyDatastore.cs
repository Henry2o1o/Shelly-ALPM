using System;
using System.ComponentModel;
using System.IO;
using System.Threading.Tasks;
using PackageManager.Alpm.Pacfile;

namespace PackageManager;

/// <summary>
/// Manages storage locations for Shelly only storage. This is to be used to support features that don't exist
/// inside pacman.
/// </summary>
public static class ShellyDatastore
{
    private const string PacfileStoragePath = "pacfiles.d";
    private const string ConfigPath = "/var/lib/shelly";

    public static string GetPacfileStoragePath()
    {
        var path = Path.Combine(ConfigPath, PacfileStoragePath);
        Directory.CreateDirectory(path);
        return path;
    }
}